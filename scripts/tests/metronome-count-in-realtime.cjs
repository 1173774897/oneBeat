// Real scheduling and PCM, with an injected render cost rather than a desktop
// timing threshold. Heavy preparation must never run inside native writeData.
const assert = require('node:assert/strict');
const { fixture, diagnostic, RATE } = require('./metronome-start-timing.cjs');

function harness(options = {}) {
  const h = fixture({ queueMs: 0, ...options });
  const e = h.engine;
  let inCallback = false;
  const work = [];
  for (const method of ['renderCountInBar', 'renderBar', 'rebuildPendingSequence']) {
    const original = e[method].bind(e);
    e[method] = (...args) => {
      const item = { method, inCallback, startedAt: h.now };
      work.push(item);
      const result = original(...args);
      if (method === 'renderCountInBar') {
        // Charge 120 ms only to the actual full-bar allocation/dither/mixing.
        // Console and buffer copying do not advance this virtual clock.
        h.advanceClock(120);
        item.frames = result.frameCount;
        item.beats = args[0];
      }
      item.completedAt = h.now;
      return result;
    };
  }
  const write = e.handleWriteData.bind(e);
  e.handleWriteData = data => {
    inCallback = true;
    try { return write(data); }
    finally { inCallback = false; }
  };
  // A real changed configuration exercises cache preparation even when the
  // fixture's initial configuration already prepared a default rehearsal bar.
  e.configure(0, 1);
  h.advanceKeepAlive(0);
  return { ...h, work, get now() { return h.now; } };
}

async function schedule(h, countInBeats = 4, beatIndex = 0, audibleAt = h.now + 2000) {
  await h.engine.scheduleFromLeaderStart(audibleAt, beatIndex, countInBeats);
  await h.fireDueTimers();
  assert.ok(h.engine.pendingAudioTransition, 'Use a transition installed by the public shared-clock API');
  return h.engine.pendingAudioTransition;
}

function writeTarget(h, transition, framesAfterTarget) {
  const e = h.engine;
  const start = e.audioSubmittedFrames;
  const targetOffset = transition.targetFrame - start;
  assert.ok(targetOffset >= 0);
  const output = new Int16Array(targetOffset + framesAfterTarget);
  for (let offset = 0; offset < output.length; offset += 4096) {
    const frames = Math.min(4096, output.length - offset);
    const data = new ArrayBuffer(frames * 2);
    assert.equal(e.handleWriteData(data), 0);
    output.set(new Int16Array(data), offset);
  }
  assert.equal(e.audioTimelineToken, e.runToken);
  return output.subarray(targetOffset);
}

function assertNoCallbackPreparation(h) {
  const inside = h.work.filter(item => item.inCallback);
  assert.deepEqual(inside, [],
    'Full-bar render/rebuild must precede writeData, not consume its realtime buffer budget: ' + JSON.stringify(inside));
  for (const line of h.logs.filter(line => line.includes('stage=write-complete '))) {
    const duration = line.match(/callbackDurationMs=([^ ]+)/)[1];
    assert.equal(Number(duration), 0, 'Injected render cost must not occur within a PCM callback');
  }
}

function assertClick(samples, offset, source, message) {
  const expected = new Int16Array(source).subarray(0, 128);
  assert.deepEqual(Array.from(samples.subarray(offset, offset + 128)), Array.from(expected), message);
  assert.ok(expected.some(sample => Math.abs(sample) > 100));
}

async function main() {
  {
    const h = harness();
    const transition = await schedule(h);
    const pcm = writeTarget(h, transition, 4 * RATE / 2 + 512);
    assertNoCallbackPreparation(h);
    assert.ok(h.work.some(item => item.method === 'renderCountInBar' && item.frames === 88200),
      'Exercise a real four-beat count-in, including its full per-sample dither loop');
    for (let beat = 0; beat < 4; beat++) {
      assertClick(pcm, beat * RATE / 2, beat === 0 ? h.engine.accentBuffer : h.engine.weakBuffer,
        `Count-in beat ${beat + 1} must preserve its real accent/weak sound`);
    }
    assertClick(pcm, 4 * RATE / 2, h.engine.accentBuffer, 'The main downbeat follows all four rehearsal beats');
    assert.equal(h.engine.mainStartBeatIndex, 4);
    assert.equal(diagnostic(h, 'applied').targetFrame, String(transition.targetFrame));

    h.engine.pause();
    const resumed = await schedule(h, 4, 12);
    const resumedPcm = writeTarget(h, resumed, 512);
    assertClick(resumedPcm, 0, h.engine.accentBuffer, 'Resume keeps the rehearsal accent at its committed frame');
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    const e = h.engine;
    const renderer = e.renderer;
    const physicalStarts = e.rendererPhysicalStartCount;
    const rendersBefore = h.work.length;
    const before = h.now;
    // Session synchronization repeats unchanged configuration. Re-preparing a
    // bar there would consume the shared 650 ms start budget before scheduling.
    e.configure(0, 1);
    e.setBpm(120, 4);
    e.setBeatPointStates(['accent', 'normal', 'normal', 'normal']);
    assert.equal(h.now, before, 'Unchanged configuration must reuse prepared PCM');
    assert.equal(h.work.length, rendersBefore, 'Unchanged configuration must not render or rebuild');
    for (const beatIndex of [0, 12]) {
      const startedAt = h.now;
      const audibleAt = h.now + 650;
      const transition = await schedule(h, 4, beatIndex, audibleAt);
      assert.equal(h.now, startedAt, 'A warm start/resume must not pay the injected 120 ms preparation cost');
      assert.equal(h.work.length, rendersBefore, 'Warm start/resume must reuse the same prepared revision');
      const expectedTarget = Math.round((audibleAt - h.compensationMs - e.rendererStartedAtLocalMs) * RATE / 1000);
      assert.equal(transition.targetFrame, expectedTarget, 'Preserve the shared target instead of spending its lead on preparation');
      const pcm = writeTarget(h, transition, 512);
      assertClick(pcm, 0, e.accentBuffer, 'First start and resume both keep the prepared rehearsal accent');
      assert.equal(e.renderer, renderer);
      assert.equal(e.rendererPhysicalStartCount, physicalStarts);
      assert.equal(transition.outputLatencyMs, h.compensationMs);
      e.pause();
      h.advanceKeepAlive(1000);
    }
    assertNoCallbackPreparation(h);
  }

  {
    let h;
    const loads = new Map();
    h = harness({ moduleMocks: {
      './DrumMachineCatalog': {
        parseDrumProgram: raw => ({ styleKey: raw, sections: [] }),
        drumProgramStyleKeys: program => [program.styleKey],
        buildProgramSequence: () => [h.engine.pattern]
      },
      './DrumSampleBank': { DrumSampleBank: {
        loadStyle: key => new Promise(resolve => loads.set(key, resolve))
      } }
    } });
    const e = h.engine;
    e.setBeatPointStates(['normal', 'normal', 'normal', 'normal']);
    const transition = await schedule(h);
    const committed = transition.targetFrame;
    const oldRequest = e.configureProgram('old-bank');
    const newRequest = e.configureProgram('current-bank');
    const accent = new Int16Array(128).fill(13000).buffer;
    const weak = new Int16Array(128).fill(7000).buffer;
    loads.get('current-bank')(new Map([['accent', accent], ['weak', weak]]));
    await newRequest;
    loads.get('old-bank')(new Map([
      ['accent', new Int16Array(128).fill(-13000).buffer],
      ['weak', new Int16Array(128).fill(-7000).buffer]
    ]));
    await oldRequest;
    assert.equal(e.pendingAudioTransition.targetFrame, committed, 'An asynchronous sample load cannot move a committed start');
    const pcm = writeTarget(h, transition, 4 * RATE / 2 + 512);
    assertClick(pcm, 0, accent, 'Count-in must use the winning asynchronous bank, not its stale predecessor');
    assertClick(pcm, RATE / 2, weak, 'The winning weak sample must update the prepared count-in too');
    assertClick(pcm, 4 * RATE / 2, weak, 'The normal main beat must use the same winning bank as count-in');
    assertNoCallbackPreparation(h);
  }

  for (const fault of ['missing-count-in', 'stale-revision', 'missing-main']) {
    const h = harness();
    const e = h.engine;
    const transition = await schedule(h);
    // Simulate an invalidated plan after the target is already committed. The
    // callback must fail closed, never substitute the main bar for rehearsal.
    if (fault === 'missing-count-in') e.preparedCountInBars.clear();
    if (fault === 'stale-revision') e.preparedCountInRevision--;
    if (fault === 'missing-main') e.pendingSequence = [];
    const framesToTarget = transition.targetFrame - e.audioSubmittedFrames;
    const data = new ArrayBuffer((framesToTarget + 512) * 2);
    assert.equal(e.handleWriteData(data), 0);
    assert.ok(new Int16Array(data).every(sample => sample === 0), `${fault}: invalid preparation must remain silent`);
    assert.equal(e.audioStreaming, false, `${fault}: do not claim that audio has started`);
    assert.ok(h.logs.some(line => line.includes('start buffers unavailable:')), `${fault}: preserve a diagnosable failure`);
    assertNoCallbackPreparation(h);

    e.pause();
    e.configure(0, 2);
    // Control-side recovery may take CPU time; keep the simulated native stream
    // healthy before retrying through the real public scheduling entry point.
    h.advanceKeepAlive(3000);
    const retry = await schedule(h);
    const pcm = writeTarget(h, retry, 512);
    assertClick(pcm, 0, e.accentBuffer, `${fault}: a newly prepared start must recover normally`);
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    const transition = await schedule(h, 4, 0, h.now - 600);
    assert.equal(transition.beatIndex, 2);
    assert.equal(transition.countInBeats, 2, 'Late arrival retains only the remaining two count-in beats');
    const pcm = writeTarget(h, transition, 2 * RATE / 2 + 512);
    assertClick(pcm, 0, h.engine.accentBuffer, 'A partial count-in starts with the existing accent semantics');
    assertClick(pcm, RATE / 2, h.engine.weakBuffer, 'The remaining rehearsal beat stays weak');
    assertClick(pcm, 2 * RATE / 2, h.engine.accentBuffer, 'Main beat four begins immediately after the partial count-in');
    assert.equal(h.engine.mainStartBeatIndex, 4);
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    h.engine.setBeatPointStates(['silent', 'silent', 'silent', 'silent']);
    const transition = await schedule(h);
    const pcm = writeTarget(h, transition, 4 * RATE / 2 + 512);
    assertClick(pcm, 0, h.engine.accentBuffer, 'Muted practice beats cannot mute the rehearsal accent');
    assertClick(pcm, RATE / 2, h.engine.weakBuffer, 'Muted practice beats cannot mute rehearsal weak clicks');
    assert.ok(pcm.subarray(4 * RATE / 2).every(sample => sample === 0), 'The main muted pattern remains silent');
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    const transition = await schedule(h);
    const committed = transition.targetFrame;
    // A configuration may finish after a target was installed. Its PCM and
    // rehearsal bar must agree without shifting that already shared boundary.
    h.engine.setBpm(90, 4);
    h.engine.configure(0, 2);
    assert.equal(h.engine.pendingAudioTransition.targetFrame, committed);
    const samplesPerBeat = RATE * 60 / 90;
    const pcm = writeTarget(h, transition, 4 * samplesPerBeat + 512);
    assertClick(pcm, 0, h.engine.accentBuffer, 'A pending start uses the latest committed tone');
    assertClick(pcm, samplesPerBeat, h.engine.weakBuffer, 'A pending start uses the latest committed tempo');
    assertClick(pcm, 4 * samplesPerBeat, h.engine.accentBuffer, 'Prepared count-in and main PCM share the new tempo');
    assertNoCallbackPreparation(h);

    h.engine.pause();
    h.engine.setBpm(90, 3);
    const changedMeter = await schedule(h, 3, 15);
    writeTarget(h, changedMeter, 512);
    assert.equal(h.engine.activeSequence[0].beatsPerBar, 3);
    assert.equal(h.engine.activeSequence[0].samplesPerBeat, samplesPerBeat);
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    const rendersBefore = h.work.filter(item => item.method === 'renderCountInBar').length;
    const transition = await schedule(h, 0);
    const pcm = writeTarget(h, transition, 512);
    assertClick(pcm, 0, h.engine.accentBuffer, 'A start without rehearsal begins directly with the main downbeat');
    assert.equal(h.work.filter(item => item.method === 'renderCountInBar').length, rendersBefore);
    assertNoCallbackPreparation(h);
  }

  {
    const h = harness();
    h.engine.setBpm(123, 3);
    const transition = await schedule(h, 2);
    const samplesPerBeat = RATE * 60 / 123;
    const countInFrames = Math.round(2 * samplesPerBeat);
    const pcm = writeTarget(h, transition, countInFrames + 512);
    assertClick(pcm, 0, h.engine.accentBuffer, 'A partial bar at a fractional sample tempo keeps its accent');
    assertClick(pcm, Math.round(samplesPerBeat), h.engine.weakBuffer, 'Per-beat rounding stays identical');
    assertClick(pcm, countInFrames, h.engine.weakBuffer,
      'The rounded partial-bar boundary seeks main beat two within the three-beat meter');
    assert.equal(h.engine.activeSequence[0].frameCount, countInFrames);
    assertNoCallbackPreparation(h);
  }

  for (const preserveActiveSequence of [false, true]) {
    const h = harness();
    const first = await schedule(h);
    writeTarget(h, first, 512);
    const route = {
      kind: 'play', token: h.engine.runToken, targetFrame: h.engine.audioSubmittedFrames + 123,
      beatIndex: 2, countInBeats: 0, outputLatencyMs: 300, routeRephase: true,
      preserveActiveSequence, timelineElapsedFrames: RATE, hardwareAtLocalMs: h.now + 2000
    };
    h.engine.scheduleRunningTransition(route);
    const pcm = writeTarget(h, route, 512);
    assertClick(pcm, 0, h.engine.weakBuffer, 'Route rephase seeks the remaining original count-in beat');
    assert.equal(h.engine.mainStartBeatIndex, 4);
    assertNoCallbackPreparation(h);
  }
  console.log('PASS count-in realtime: no callback preparation; cached 650 ms start/resume; asynchronous bank ownership; invalid-plan silence/recovery; actual PCM count-in, tempo/tone/meter and route seek');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
