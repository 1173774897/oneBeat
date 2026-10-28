// Run with Node and a typescript/lib/typescript.js path, matching the sync gate.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);

function drumCatalog() {
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {};
    cache.set(file, exports);
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    });
    vm.runInNewContext(compiled.outputText, { exports,
      require: name => load(path.resolve(path.dirname(file), `${name}.ets`)) });
    return exports;
  }
  return load(path.resolve(__dirname, '../../entry/src/main/ets/audio/DrumMachineCatalog.ets'));
}


function writeTarget(h, transition, frames) {
  const e = h.engine;
  const beforeTarget = transition.targetFrame - e.audioSubmittedFrames;
  assert.ok(beforeTarget >= 0);
  const result = new Int16Array(beforeTarget + frames);
  for (let cursor = 0; cursor < result.length; cursor += 4096) {
    const buffer = new ArrayBuffer(Math.min(4096, result.length - cursor) * 2);
    assert.equal(e.handleWriteData(buffer), 0);
    result.set(new Int16Array(buffer), cursor);
  }
  return result.subarray(beforeTarget);
}

function assertSource(pcm, bar, offsetFrame, message) {
  for (let i = 0; i < pcm.length; i++) {
    assert.equal(pcm[i], bar.samples[(offsetFrame + i) % bar.frameCount], `${message}, frame ${i}`);
  }
  assert.ok(pcm.some(sample => Math.abs(sample) > 100), 'Comparison must include actual synthesized drum hits');
}

async function schedule(h, positionBeats, audibleAt = h.now + 650) {
  await h.engine.scheduleFromLeaderStart(audibleAt, 0, 0, undefined, positionBeats);
  await h.fireDueTimers();
  assert.ok(h.engine.pendingAudioTransition, 'Use the real scheduled renderer transition');
  return h.engine.pendingAudioTransition;
}

async function testEventProgramSeek() {
  const catalog = drumCatalog();
  for (const subdivision of [3, 6]) {
    const bank = new Map([['snare', new Int16Array([10000, 7000, -5000, 0]).buffer]]);
    const h = fixture({ queueMs: 0, moduleMocks: {
      './DrumMachineCatalog': catalog,
      './DrumSampleBank': { DrumSampleBank: { loadStyle: async () => bank } }
    } });
    h.engine.beatPointStates = Array(4).fill('normal');
    const tick = 480 / subdivision;
    const program = { styleKey: 'jazz', beatsPerBar: 4, beatUnit: 4, sections: [{
      id: 'A', patternIndex: 0, repeats: 1, fillIndex: 0, fillEvery: 0,
      customPattern: { subdivision, events: [
        { tick, sampleKey: 'snare', velocity: 0.5 },
        { tick: 480 + tick, sampleKey: 'snare', velocity: 0.8 }
      ] }
    }] };
    await h.engine.configureProgram(catalog.serializeDrumProgram(program), true);
    const position = 1 / subdivision;
    const audibleAt = h.now + 650;
    const transition = await schedule(h, position, audibleAt);
    const bar = h.engine.pendingSequence[0];
    assert.equal(bar.frameCount, 88200, 'An event program must still render a two-second 4/4 bar at 120 BPM');
    const firstFrame = Math.round(position * bar.samplesPerBeat);
    assert.equal(bar.samples[firstFrame], 5000, 'Saved triplet/six-tuplet event velocity must reach actual PCM');
    const pcm = writeTarget(h, transition, bar.frameCount + 64);
    assertSource(pcm, bar, firstFrame, 'Triplet/six-tuplet event program must seek and loop from its exact musical position');
    assert.equal(pcm[0], 5000, 'Auditioning from a triplet/six-tuplet cursor must start at the chosen hit');
    h.advanceClock(audibleAt - h.now);
    const snapshot = h.engine.getVisualSnapshot();
    assert.ok(Math.abs(snapshot.mainPlayheadMs - position * 500) < 1e-9);
    assert.ok(Math.abs(snapshot.beatPhase - position) < 1e-9,
      'The walking/visual clock must retain the original beat phase despite the new event grid');
  }
}

async function main() {
  await testEventProgramSeek();
  {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    let insideCallback = false;
    const renderBar = e.renderBar.bind(e);
    e.renderBar = (...args) => {
      assert.equal(insideCallback, false, 'A seek must reuse prepared PCM outside the native callback');
      return renderBar(...args);
    };
    const write = e.handleWriteData.bind(e);
    e.handleWriteData = data => {
      insideCallback = true;
      try { return write(data); }
      finally { insideCallback = false; }
    };
    const position = 2.325;
    const audibleAt = h.now + 650;
    const transition = await schedule(h, position, audibleAt);
    assert.ok(e.getVisualSnapshot().mainPlayheadMs < 0,
      'A held editor cursor must not jump ahead during preview pre-roll');
    const bar = e.pendingSequence[0];
    const firstFrame = Math.round(position * bar.samplesPerBeat);
    const pcm = writeTarget(h, transition, bar.frameCount + 512);
    assertSource(pcm, bar, firstFrame, 'Fractional restart must seek audio and retain the complete loop');
    assert.equal(transition.timelineElapsedFrames, 0, 'Source seek is separate from elapsed audio time');
    assert.equal(e.audioTimelineLeadFrames,
      transition.targetFrame + Math.round(transition.outputLatencyMs * RATE / 1000));

    h.advanceClock(audibleAt - h.now);
    let snapshot = e.getVisualSnapshot();
    assert.equal(snapshot.mainPlayheadMs, position * 500);
    assert.equal(snapshot.mainBeatIndex, 2);
    assert.equal(snapshot.beatIndex, 2);
    assert.equal(snapshot.beatInBar, 3);
    assert.ok(Math.abs(snapshot.beatPhase - 0.325) < 1e-10);
    h.advanceClock(500);
    snapshot = e.getVisualSnapshot();
    assert.equal(snapshot.mainPlayheadMs, (position + 1) * 500);

    // The route selector uses elapsed transport beats. Its source cursor must
    // include the initial fractional source position without adding an accent.
    const routeFrame = Math.round(((position + 5) % 4) * bar.samplesPerBeat);
    const route = { kind: 'play', token: e.runToken, targetFrame: e.audioSubmittedFrames,
      beatIndex: 5, countInBeats: 0, outputLatencyMs: 300, routeRephase: true,
      preserveActiveSequence: true, timelineElapsedFrames: 5 * RATE / 2 };
    e.scheduleRunningTransition(route);
    assertSource(writeTarget(h, route, bar.frameCount), bar, routeFrame,
      'Route source seek retains the requested position');

    // Recovery rebuilds from a later elapsed beat on the same preview clock.
    e.prepareAudioCursor(6, 0);
    assert.equal(e.audioFrameCursor, Math.round(((position + 6) % 4) * bar.samplesPerBeat));
    const recovered = { kind: 'play', token: e.runToken, targetFrame: e.audioSubmittedFrames,
      beatIndex: 6, countInBeats: 0, outputLatencyMs: 300 };
    e.scheduleRunningTransition(recovered);
    assert.equal(recovered.timelineElapsedFrames, 6 * RATE / 2);
    e.applyAudioTransition(recovered);
    assert.equal(e.audioTimelineLeadFrames,
      recovered.targetFrame + Math.round(300 * RATE / 1000) - 6 * RATE / 2,
      'Recovery must not turn six elapsed beats into phase-lock drift');

    // A shared transport following audition must discard every local seek.
    e.pause();
    await e.scheduleFromLeaderStart(h.now + 650, 0, 0);
    await h.fireDueTimers();
    const shared = e.pendingAudioTransition;
    assert.ok(shared);
    const sharedPcm = writeTarget(h, shared, 512);
    assert.equal(e.transportPreviewStartPositionBeats, undefined);
    assert.equal(shared.timelineElapsedFrames, 0,
      'The default shared-clock feedback starts at elapsed zero without inheriting the preview seek');
    assertSource(sharedPcm, e.pendingSequence[0], 0, 'Shared transport starts at its original downbeat');
  }

  {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    let release;
    const gate = new Promise(done => { release = done; });
    e.ensureRenderer = () => gate;
    const pending = e.scheduleFromLeaderStart(h.now + 350, 0, 0, undefined, 1.125);
    e.pause();
    release();
    await pending;
    await h.fireDueTimers();
    assert.equal(e.running, false);
    assert.equal(e.pendingAudioTransition, undefined,
      'Stop during preview preparation must prevent a delayed restart');
  }

  {
    const h = fixture({ queueMs: 0 });
    const e = h.engine;
    const transition = await schedule(h, 1.125, h.now - 750);
    assert.equal(transition.beatIndex, 0,
      'Slow preparation may postpone preview, but must preserve the cursor instead of skipping beats');
    const bar = e.pendingSequence[0];
    assertSource(writeTarget(h, transition, bar.frameCount), bar,
      Math.round(1.125 * bar.samplesPerBeat), 'Late audition still starts at the held cursor');
  }

  console.log('PASS drum-preview seek: fractional real PCM, saved triplet/six-tuplet event onsets and clock phase, full loop, pre-roll, visual position, route/recovery origin, shared reset and cancellation');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
