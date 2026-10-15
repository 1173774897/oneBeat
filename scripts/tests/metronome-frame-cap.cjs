// Offline counterfactual, not a measurement of the user's headphones. The model
// assumes one continuous native counter whose frame/time relationship is fixed,
// a fixed software base bias, fixed physical output latency, and zero human tap
// bias. Only the accepted PCM queue changes. Those assumptions are not proved by
// the device logs. Production source remains unchanged; the control below removes
// only the rendered-frame upper bound inside this isolated VM.
const assert = require('node:assert/strict');
const { fixture, diagnostic, RATE } = require('./metronome-start-timing.cjs');

const FRAME_MS = 1000 / RATE;
const BIAS_FRAMES = 13230; // A simulated, constant 300 ms legacy coordinate bias.
const CASES = [
  {
    side: 'leader', calibrationCapFrames: 734,
    productionCapFrames: [3008, 2388, 544, 4228],
    // Independent fixed downstream latency of this simulated device. Together
    // with its biased initial coordinate this produces a roughly 515 ms tap D.
    physicalLatencyMs: 231.64, expectedSavedMs: 515
  },
  {
    side: 'member', calibrationCapFrames: 3126,
    // -188 means submitted is ahead of the biased raw position, so no cap acts.
    productionCapFrames: [-188, 4170, 1444, 1914],
    physicalLatencyMs: 207.88, expectedSavedMs: 437
  }
];

function near(actual, expected, label, tolerance = FRAME_MS * 2) {
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${label}: expected ${expected.toFixed(5)} ms, received ${actual.toFixed(5)} ms`);
}

function useUncappedReference(h) {
  const read = h.engine.readRenderedStreamFrames.bind(h.engine);
  h.engine.readRenderedStreamFrames = function(renderer, nowMs) {
    const production = read(renderer, nowMs);
    if (production === undefined) return production;
    // This is a test-only counterfactual for the existing target formula. The
    // model's native counter is independently driven by time, never by the
    // target or expected onset. Its true PCM frame zero is known in the VM.
    const uncapped = Math.max(0, h.physicalFrame - this.audioTimestampBaseFrame);
    this.lastRenderedStreamFrame = uncapped;
    this.queueDepthFrames = Math.max(0, this.audioSubmittedFrames - uncapped);
    return uncapped;
  };
}

async function renderStart(h, compensationOverrideMs) {
  const e = h.engine;
  const audibleAt = h.now + (compensationOverrideMs === 0 ? 1270 : 650);
  const logStart = h.logs.length;
  const bias = e.audioTimestampBaseFrame;
  const capBefore = Math.max(0,
    h.physicalFrame - e.audioTimestampBaseFrame - e.audioSubmittedFrames);
  await e.scheduleFromLeaderStart(audibleAt, 0, 0, compensationOverrideMs);
  await h.fireDueTimers();
  const transition = e.pendingAudioTransition;
  assert.ok(transition, 'The real shared-clock API must install a play transition');
  const before = e.audioSubmittedFrames;
  const click = e.pendingSequence[0].samples;
  const sourceOnset = click.findIndex(sample => sample !== 0);
  assert.ok(sourceOnset >= 0, 'The synthesized ClickSound must contain real PCM');
  assert.ok(transition.targetFrame >= before);
  const buffer = new ArrayBuffer((transition.targetFrame - before + sourceOnset + 512) * 2);
  e.handleWriteData(buffer);
  const actualOnset = new Int16Array(buffer).findIndex(sample => sample !== 0);
  assert.ok(actualOnset >= 0, 'The actual write callback must emit a click');
  const signalFrame = before + actualOnset - sourceOnset;
  const result = { logs: h.logs.slice(logStart) };
  const target = diagnostic(result, 'target');
  assert.equal(Number(target.clampMs), 0,
    'This reproduction must not depend on an overdue target or target clamp');
  assert.equal(signalFrame, transition.targetFrame,
    'Measure the origin from real PCM, independently of the predicted error');
  assert.equal(e.audioTimestampBaseFrame, bias, 'The coordinate base must stay fixed');
  assert.equal(e.rendererPhysicalStartCount, 1, 'All samples reuse one native stream');
  return {
    errorMs: h.audibleAtFrame(signalFrame) - audibleAt,
    compensationMs: transition.outputLatencyMs, capFrames: capBefore,
    signalFrame, headroomMs: Number(target.headroomMs)
  };
}

async function scenario(input, mode) {
  const h = fixture({
    compensationMs: 0,
    queueMs: (BIAS_FRAMES - input.calibrationCapFrames) * FRAME_MS,
    frameBiasFrames: BIAS_FRAMES,
    physicalLatencyMs: input.physicalLatencyMs
  });
  const renderer = h.engine.renderer;
  if (mode === 'raw-recalibrated') useUncappedReference(h);
  const calibration = await renderStart(h, 0);
  // A zero-reaction simulated user measures the actual native-model PCM onset.
  // Saved D is not filled from the error expectations asserted further below.
  const savedMs = Math.round(calibration.errorMs);
  h.setCompensationMs(savedMs);
  if (mode === 'raw-old-calibration') useUncappedReference(h);
  const starts = [];
  for (const capFrames of input.productionCapFrames) {
    h.engine.pause();
    h.setQueueFrames(BIAS_FRAMES - capFrames);
    h.advanceKeepAlive(4000);
    const start = await renderStart(h);
    assert.equal(start.compensationMs, savedMs, 'Saved D stays fixed through every start');
    assert.equal(h.engine.renderer, renderer, 'No native renderer is replaced');
    assert.equal(start.capFrames, Math.max(0, capFrames));
    starts.push(start);
  }
  return { savedMs, calibration, starts };
}

async function main() {
  const outcomes = [];
  for (const input of CASES) {
    const production = await scenario(input, 'production');
    const rawOld = await scenario(input, 'raw-old-calibration');
    const rawFresh = await scenario(input, 'raw-recalibrated');
    assert.equal(production.savedMs, input.expectedSavedMs);
    assert.equal(rawOld.savedMs, production.savedMs,
      'The first control deliberately preserves the old calibration');
    const calibrationRoundingMs = production.calibration.errorMs - production.savedMs;
    for (let i = 0; i < production.starts.length; i++) {
      const cap = Math.max(0, input.productionCapFrames[i]);
      // Expected cap deltas are asserted against actual PCM/native-model time,
      // rather than using these values to schedule or locate the emitted click.
      near(production.starts[i].errorMs,
        (input.calibrationCapFrames - cap) * FRAME_MS + calibrationRoundingMs,
        `${input.side} production round ${i + 1}`);
      near(rawOld.starts[i].errorMs - production.starts[i].errorMs,
        cap * FRAME_MS, `${input.side} removing the production cap`);
      near(rawOld.starts[i].errorMs, rawOld.starts[0].errorMs,
        `${input.side} uncapped reference stays stable with old D`);
      near(rawOld.starts[i].errorMs,
        input.calibrationCapFrames * FRAME_MS + calibrationRoundingMs,
        `${input.side} old D retains the calibration's constant cap component`);
      near(rawFresh.starts[i].errorMs, 0,
        `${input.side} uncapped reference after its own calibration`, 0.51);
    }
    assert.ok(Math.abs(rawOld.starts[0].errorMs) > 10,
      'Removing the bound alone must not be mistaken for a compatible calibration fix');
    outcomes.push({ input, production, rawOld, rawFresh });
  }
  const [leader, member] = outcomes;
  const gaps = leader.production.starts.map((start, i) =>
    member.production.starts[i].errorMs - start.errorMs);
  for (let i = 0; i < gaps.length; i++) {
    const l = leader.input, m = member.input;
    near(gaps[i], (m.calibrationCapFrames - Math.max(0, m.productionCapFrames[i]) -
      l.calibrationCapFrames + Math.max(0, l.productionCapFrames[i])) * FRAME_MS,
    `two-model relative PCM error round ${i + 1}`);
    assert.ok(gaps[i] > 0, 'In this model the member is later in all four rounds');
  }
  console.log(`PASS: actual Engine/ClickSound/RhythmTimeline PCM reproduces cap-state drift ` +
    `with fixed streams and saved D; simulated member-minus-leader gaps ` +
    `${gaps.map(value => value.toFixed(2)).join('/')} ms; uncapped control is stable, ` +
    `but requires compatible calibration. This is a counterfactual, not acoustic evidence.`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
