// Run with Node and the DevEco typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

function near(actual, expected, message, tolerance = 0.51 * 1000 / RATE) {
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${message}: expected ${expected}, received ${actual}`);
}

async function playing({ enabled = true, compensationMs = 100, queueMs = 200 } = {}) {
  const h = fixture({ compensationMs, queueMs });
  const e = h.engine;
  assert.equal(e.phaseCorrectionEnabled, true, 'New engines enable shared phase feedback by default');
  if (!enabled) assert.equal(e.setPhaseCorrectionEnabled(false), true);
  const audibleAt = h.now + 650;
  await e.scheduleFromLeaderStart(audibleAt, 0, 0);
  await h.fireDueTimers();
  assert.ok(e.pendingAudioTransition, 'The real warm-start path must prepare a stream transition');
  h.advanceKeepAlive(650);
  assert.equal(e.audioStreaming, true);
  assert.equal(e.audioTimelineToken, e.runToken);
  return h;
}

function imposePhaseError(h, frames) {
  // Move the requested musical epoch relative to the already submitted PCM;
  // this models a known target error without replacing the production reader.
  h.engine.transportStartLocalMs += frames * 1000 / RATE;
}

async function testStartupAndGate() {
  const disabled = await playing({ enabled: false });
  imposePhaseError(disabled, 100);
  disabled.engine.checkAudioProgress(disabled.now);
  assert.equal(disabled.engine.phaseCorrectionFrames, 0, 'Explicit rollback must leave PCM phase correction disabled');
  disabled.engine.setPhaseCorrectionEnabled(true);
  assert.equal(disabled.engine.phaseCorrectionEnabled, false, 'Changing feedback mode requires a stopped transport');
  disabled.engine.pause();
  disabled.engine.setPhaseCorrectionEnabled(true);
  assert.equal(disabled.engine.phaseCorrectionEnabled, true);

  const h = await playing();
  assert.equal(h.engine.audioClockLocked, false, 'A new transition has no prior feedback sample');
  imposePhaseError(h, 100);
  assert.equal(h.engine.measurePhaseErrorFrames(), 100,
    'A valid owner must sample hardware and acquire feedback without requiring an existing lock');
  assert.equal(h.engine.audioClockLocked, true);
  assert.ok(h.audioCalls.includes('timestamp'));
}

async function testAudibleAndQueuedFeedback(sign) {
  const h = await playing();
  const e = h.engine;
  imposePhaseError(h, sign * 48);
  const before = e.readAudioPlayheadMs(h.now);
  const cursor = e.audioFrameCursor;
  const eventFrame = e.audioSubmittedFrames;
  e.checkAudioProgress(h.now);
  assert.equal(e.phaseCorrectionFrames, sign * 16);
  e.checkAudioProgress(h.now);
  assert.equal(e.phaseCorrectionFrames, sign * 16,
    'A pending correction must be accounted for before another correction is requested');
  e.fillAudioData(new ArrayBuffer(64 * 2));
  assert.equal(e.phaseCorrectionFrames, 0);
  assert.equal(e.audioFrameCursor - cursor, 64 - sign * 16,
    'The real PCM source cursor must reflect the inserted or dropped source span');
  near(e.readAudioPlayheadMs(h.now), before,
    'Submission must not immediately change the content that is currently audible');
  assert.equal(e.measurePhaseErrorFrames(), sign * 32,
    'Submitted but unheard correction must count once toward the remaining control error');
  e.checkAudioProgress(h.now);
  assert.equal(e.phaseCorrectionFrames, 0, 'Queued correction must not trigger a duplicate request');

  const audibleEventAt = h.audibleAtFrame(eventFrame);
  h.advanceKeepAlive(audibleEventAt - h.now - 1);
  const beforeCrossing = e.readAudioPlayheadMs(h.now);
  near(beforeCrossing, h.now - e.transportStartLocalMs + sign * 48 * 1000 / RATE,
    'Unheard correction must not enter the actual source playhead');
  h.advanceKeepAlive(3);
  const afterCrossing = e.readAudioPlayheadMs(h.now);
  near(afterCrossing, h.now - e.transportStartLocalMs + sign * 32 * 1000 / RATE,
    'Crossing the output latency boundary must apply the source correction exactly once');
  assert.equal(e.measurePhaseErrorFrames(), sign * 32);
  e.checkAudioProgress(h.now);
  assert.equal(e.phaseCorrectionFrames, 0);
}

async function testInsertionHoldsSourceTime() {
  const h = await playing();
  const e = h.engine;
  const eventFrame = e.audioSubmittedFrames;
  e.phaseCorrectionFrames = 16;
  e.fillAudioData(new ArrayBuffer(64 * 2));
  h.advanceKeepAlive(h.audibleAtFrame(eventFrame) - h.now);
  const first = e.readAudioPlayheadMs(h.now);
  h.advanceKeepAlive(8 * 1000 / RATE);
  near(e.readAudioPlayheadMs(h.now), first,
    'The source playhead must stand still while inserted silence is audible');
  h.advanceKeepAlive(8 * 1000 / RATE);
  near(e.readAudioPlayheadMs(h.now), first,
    'The entire inserted span must hold source time');
  h.advanceKeepAlive(16 * 1000 / RATE);
  near(e.readAudioPlayheadMs(h.now), first + 16 * 1000 / RATE,
    'Source progression must resume after the inserted span');
}

async function testQuietPcmSafety() {
  for (const sign of [-1, 1]) {
    const h = await playing();
    const e = h.engine;
    const bar = e.activeBar;
    const start = e.audioFrameCursor;
    // A sustained ride tail occupies the old beat-based "safe" area too.
    for (let i = 0; i < 256; i++) bar.samples[start + i] = 1000 + i;
    e.phaseCorrectionFrames = sign * 16;
    const pcm = new ArrayBuffer(128 * 2);
    e.fillAudioData(pcm);
    assert.deepEqual(Array.from(new Int16Array(pcm)), Array.from(bar.samples.subarray(start, start + 128)),
      'Sustained nonquiet PCM must survive byte-for-byte, without a silent hole or missing tail');
    assert.equal(e.audioFrameCursor, start + 128);
    assert.equal(e.phaseCorrectionFrames, sign * 16,
      'No safe window means correction remains pending, not reported as completed');

    // A click/transient crossing the beginning of the next native buffer must
    // be copied first. The following quiet span is a valid correction point.
    for (let i = 0; i < 512; i++) bar.samples[start + 128 + i] = i < 24 ? 5000 - i : 0;
    const next = new ArrayBuffer(128 * 2);
    const nextCursor = e.audioFrameCursor;
    e.fillAudioData(next);
    assert.deepEqual(Array.from(new Int16Array(next).subarray(0, 24)),
      Array.from(bar.samples.subarray(nextCursor, nextCursor + 24)));
    assert.equal(e.phaseCorrectionFrames, 0, 'A quiet span later in the same callback must remain usable');
    assert.equal(e.audioFrameCursor - nextCursor, 128 - sign * 16);
  }
}

async function testZeroCrossingSafety() {
  for (const sign of [-1, 1]) {
    const h = await playing();
    const e = h.engine;
    const start = e.audioFrameCursor;
    for (let i = -32; i < 256; i++) e.activeBar.samples[start + i] = i % 4 === 0 ? 0 : 1000;
    const before = Array.from(e.activeBar.samples.subarray(start, start + 128));
    e.phaseCorrectionFrames = sign * 16;
    const buffer = new ArrayBuffer(128 * 2);
    e.fillAudioData(buffer);
    assert.deepEqual(Array.from(new Int16Array(buffer)), before, 'Zero crossings are not safe silent splices');
    assert.equal(e.phaseCorrectionFrames, sign * 16);
  }
}

async function testResumedElapsedOrigin() {
  const h = await playing();
  const e = h.engine;
  h.advanceKeepAlive(2000);
  const start = e.transportStartLocalMs + 3000;
  await e.startAudioStream(start, e.transportStartBeatIndex + 6, 0, e.runToken);
  assert.equal(e.pendingAudioTransition.timelineElapsedFrames, 3 * RATE,
    'A restart at a later beat must retain the original shared elapsed origin');
  h.advanceKeepAlive(start - h.now + 5);
  near(e.readAudioPlayheadMs(h.now), 3005, 'Resumed PCM has the original elapsed coordinate');
  assert.ok(Math.abs(e.measurePhaseErrorFrames()) <= 1,
    'A resumed beat is not thousands of milliseconds of clock drift');
}

async function testCorrectionBudget() {
  const h = await playing();
  const e = h.engine;
  for (const bar of e.activeSequence) bar.samples.fill(1000);
  // 12ms: far above one interval's slew budget (44 frames), below the 15ms
  // re-phase threshold that now applies on every envelope route, Bluetooth
  // included (larger slips are covered by phase-resync.cjs).
  imposePhaseError(h, 529);
  e.checkAudioProgress(h.now);
  assert.equal(e.phaseCorrectionFrames, 16, 'First feedback uses a small acquisition step');
  for (let i = 0; i < 20; i++) {
    h.advanceKeepAlive(500);
    e.checkAudioProgress(h.now);
    assert.ok(Math.abs(e.phaseCorrectionFrames) <= 44,
      'No quiet window cannot accumulate more than one interval of pending correction');
    const pending = e.phaseCorrectionFrames;
    e.checkAudioProgress(h.now);
    assert.equal(e.phaseCorrectionFrames, pending, 'Repeated checks at one time earn no extra budget');
  }
  assert.equal(e.phaseCorrectionSubmittedFrames, 0, 'A sustained source cannot be cut to satisfy the budget');
  h.advanceKeepAlive(10000);
  e.checkAudioProgress(h.now);
  assert.ok(Math.abs(e.phaseCorrectionFrames) <= 176, 'A long suspension must cap accumulated control time');
  e.activeBar.samples.fill(0);
  e.fillAudioData(new ArrayBuffer(256 * 2));
  assert.equal(e.phaseCorrectionFrames, 0);
  assert.ok(e.phaseCorrectionCount > 1, 'A time budget is realized through multiple small quiet splices');
  for (let i = 0; i < e.phaseCorrectionCount; i++) {
    assert.ok(Math.abs(e.phaseCorrectionDeltas[i]) <= 16);
  }
}

async function testIsolationAndFreshness() {
  const cases = [
    ['old transport token', e => { e.audioTimelineToken--; }],
    ['old transport revision', e => { e.audioSequenceTransportRevision--; }],
    ['route preparation', e => { e.outputRouteRephasePreparing = true; }],
    ['queued transition', e => { e.pendingAudioTransition = { kind: 'pause', token: e.runToken,
      targetFrame: e.audioSubmittedFrames + RATE, outputLatencyMs: 100 }; }],
    ['local seek preview', e => { e.transportPreviewStartPositionBeats = 1.25; }],
    ['live drum preview', e => { e.drumPreviewPlan = {}; }],
    ['calibration override', e => { e.transportOutputCompensationOverrideMs = 0; }],
    ['calibration signal', e => { e.calibrationSignal = { samples: new Int16Array(0), startFrame: 0 }; }],
    ['finished finite sequence', e => { e.activeSequenceFinished = true; }]
  ];
  for (const [name, isolate] of cases) {
    const h = await playing();
    imposePhaseError(h, 100);
    isolate(h.engine);
    h.engine.checkAudioProgress(h.now);
    assert.equal(h.engine.phaseCorrectionFrames, 0, `${name} must not steer another audio owner`);
  }

  const regressed = await playing();
  regressed.engine.measurePhaseErrorFrames();
  const current = regressed.renderer.getAudioTimestampInfoSync();
  regressed.renderer.getAudioTimestampInfoSync = () => ({ ...current, framePos: current.framePos - 1 });
  regressed.engine.checkAudioProgress(regressed.now);
  assert.equal(regressed.engine.phaseCorrectionFrames, 0);
  assert.equal(regressed.engine.audioClockLocked, false);
  assert.equal(regressed.engine.phaseFeedbackStartFrame, -1,
    'A regressed frame coordinate must wait for a new anchor before consuming the ledger');

  const stale = await playing();
  imposePhaseError(stale, 100);
  stale.engine.measurePhaseErrorFrames();
  const old = stale.renderer.getAudioTimestampInfoSync();
  stale.renderer.getAudioTimestampInfoSync = () => old;
  stale.advanceKeepAlive(300);
  stale.engine.checkAudioProgress(stale.now);
  assert.equal(stale.engine.phaseCorrectionFrames, 0, 'A stale timestamp must not drive phase correction');
  stale.renderer.getAudioTimestampInfoSync = () => { throw new Error('Unavailable'); };
  stale.engine.checkAudioProgress(stale.now);
  assert.equal(stale.engine.phaseCorrectionFrames, 0,
    'An extrapolated playhead after hardware failure must not masquerade as a fresh measurement');
}

async function testTransitionAndReset() {
  const h = await playing();
  const e = h.engine;
  e.phaseCorrectionFrames = 16;
  e.fillAudioData(new ArrayBuffer(64 * 2));
  const target = e.audioSubmittedFrames;
  const transition = { kind: 'play', token: e.runToken, targetFrame: target,
    beatIndex: 2, countInBeats: 0, outputLatencyMs: 100, routeRephase: true,
    preserveActiveSequence: true, timelineElapsedFrames: RATE };
  e.pendingAudioTransition = transition;
  e.applyAudioTransition(transition);
  assert.equal(e.phaseCorrectionSubmittedFrames, 0, 'A newly anchored route owns a fresh content mapping');
  assert.equal(e.measurePhaseErrorFrames(), 0,
    'An applied transition must not measure the previous queue against its new origin');
  assert.equal(e.audioClockLocked, false);
  e.pause();
  assert.equal(e.phaseCorrectionFrames, 0);
  assert.equal(e.phaseCorrectionCount, 0);
  assert.equal(e.phaseFeedbackStartFrame, -1);
  assert.equal(e.audioClockLocked, false);
}

async function main() {
  await testStartupAndGate();
  await testAudibleAndQueuedFeedback(1);
  await testAudibleAndQueuedFeedback(-1);
  await testInsertionHoldsSourceTime();
  await testQuietPcmSafety();
  await testZeroCrossingSafety();
  await testResumedElapsedOrigin();
  await testCorrectionBudget();
  await testIsolationAndFreshness();
  await testTransitionAndReset();
  console.log('PASS phase feedback: default-on feedback and explicit rollback, first hardware lock, true audible insert/drop mapping, pending/queued correction accounting, PCM-tail safety, owner isolation, timestamp freshness and route reset');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
