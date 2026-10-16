// Run with Node and a typescript/lib/typescript.js path, matching the sync gate.
const assert = require('node:assert/strict');
const { harness, bank, catalog, flush } = require('./drum-preview-session-ownership.cjs');
const RATE = 44100;
const BAR = RATE * 2;
const initial = () => [
  { key: 'key-a', repeats: 3, velocity: 0.2 },
  { key: 'key-b', repeats: 4, velocity: 0.4 },
  { key: 'key-c', repeats: 1, velocity: 0.6 }
];
function request(sections, styleKey = 'rock') {
  return {
    keys: sections.map(section => section.key),
    raw: catalog.serializeDrumProgram({ styleKey, beatsPerBar: 4, beatUnit: 4,
      sections: sections.map((section, index) => ({ id: String.fromCharCode(65 + index),
        patternIndex: 0, repeats: section.repeats, fillIndex: 0, fillEvery: 0,
        customPattern: { subdivision: 4, events: [
          { tick: 0, sampleKey: 'kick', velocity: section.velocity },
          ...(section.beatVelocity === undefined ? [] : [{ tick: 480, sampleKey: 'kick', velocity: section.beatVelocity }])
        ] }
      })) })
  };
}

function write(h, frames, advance = true) {
  const result = new Int16Array(frames);
  for (let offset = 0; offset < frames; offset += 4096) {
    const count = Math.min(4096, frames - offset);
    const data = new ArrayBuffer(count * 2);
    h.inWrite = true;
    try { assert.equal(h.engine.handleWriteData(data), 0); }
    finally { h.inWrite = false; }
    result.set(new Int16Array(data), offset);
    if (advance) h.advanceClock(count * 1000 / RATE);
  }
  return result;
}

async function start(sections = initial(), options = {}) {
  const h = harness({ engineOptions: { compensationMs: 0, physicalLatencyMs: 0 } });
  h.session.keepRendererAliveForSession = true;
  const originalRender = h.engine.renderBar.bind(h.engine);
  h.engine.renderBar = (...args) => {
    assert.notEqual(h.inWrite, true, 'PCM preparation must never run inside writeData');
    return originalRender(...args);
  };
  const plan = request(sections);
  const operation = h.session.previewDrumProgram(plan.raw, options.looping ?? true, 120, 4, 0,
    options.attach === false ? undefined : plan.keys);
  h.loads[0].resolve(bank(20000));
  await operation;
  await h.fireDueTimers();
  const transition = h.engine.pendingAudioTransition;
  assert.ok(transition, 'Use the actual renderer play transition');
  const targetAt = h.now + (transition.targetFrame - h.engine.audioSubmittedFrames) * 1000 / RATE;
  write(h, transition.targetFrame - h.engine.audioSubmittedFrames, false);
  h.advanceClock(targetAt - h.now);
  write(h, 1);
  h.inWrite = undefined;
  return h;
}

function position(h, key, repeatIndex) {
  const current = h.engine.getDrumPreviewPosition();
  assert.ok(current, 'The audible local song must expose its applied logical position');
  assert.equal(current.sectionKey, key);
  assert.equal(current.repeatIndex, repeatIndex);
}

function nextBar(h) {
  write(h, h.engine.activeBar.frameCount - h.engine.audioFrameCursor);
  h.inWrite = undefined;
}

function marker(h, expected) {
  assert.equal(write(h, 1)[0], expected, 'The next rendered bar must contain the selected section’s actual prepared PCM');
  h.inWrite = undefined;
}

function enter(h, key, repeatIndex) {
  for (let bars = 0; bars < 32; bars++) {
    const current = h.engine.getDrumPreviewPosition();
    if (current?.sectionKey === key && current.repeatIndex === repeatIndex) return;
    nextBar(h);
    write(h, 1);
    h.inWrite = undefined;
  }
  assert.fail(`Could not reach ${key}/${repeatIndex}`);
}

async function update(h, sections, style) {
  const plan = request(sections, style);
  return await h.session.updateDrumPreviewProgram(plan.raw, plan.keys);
}

function assertUninterrupted(h, before) {
  assert.equal(h.engine.runToken, before.run);
  assert.equal(h.engine.transportRevision, before.transport);
  assert.equal(h.engine.renderer, before.renderer);
  assert.equal(h.engine.rendererPhysicalStartCount, before.starts);
  assert.equal(h.starts.length, 1, 'Live editing must not schedule another transport');
  assert.equal(h.suspends(), 0);
}

function continuity(h) {
  return { run: h.engine.runToken, transport: h.engine.transportRevision,
    renderer: h.engine.renderer, starts: h.engine.rendererPhysicalStartCount };
}

async function testNextBoundaryAndLogicalIdentity() {
  const h = await start();
  enter(h, 'key-a', 1);
  const before = continuity(h);
  const oldBar = h.engine.activeBar;
  const cursor = h.engine.audioFrameCursor;
  const revised = initial().map(section => ({ ...section, velocity: section.key === 'key-b' ? 0.8 : section.velocity }));
  assert.equal(await update(h, revised), true);
  assert.equal(h.engine.activeBar, oldBar, 'Preparing new B PCM cannot replace the sounding A2 bar');
  position(h, 'key-a', 1);
  const remainder = write(h, BAR - cursor);
  assert.deepEqual(Array.from(remainder), Array.from(oldBar.samples.subarray(cursor)),
    'The complete remainder of the current bar must retain its original PCM');
  h.inWrite = undefined;
  marker(h, 4000);
  position(h, 'key-a', 2);
  nextBar(h);
  marker(h, 16000);
  position(h, 'key-b', 0);
  assertUninterrupted(h, before);

  enter(h, 'key-b', 1);
  const shortenEarlier = revised.map(section => ({ ...section,
    repeats: section.key === 'key-a' ? 1 : section.repeats }));
  assert.equal(await update(h, shortenEarlier), true);
  position(h, 'key-b', 1);
  nextBar(h);
  marker(h, 16000);
  position(h, 'key-b', 2);
  const reduceCurrent = shortenEarlier.map(section => ({ ...section,
    repeats: section.key === 'key-b' ? 1 : section.repeats }));
  assert.equal(await update(h, reduceCurrent), true);
  nextBar(h);
  marker(h, 12000);
  position(h, 'key-c', 0);
  assertUninterrupted(h, before);
}

async function testStructureChanges() {
  const h = await start();
  enter(h, 'key-b', 0);
  const withoutA = initial().filter(section => section.key !== 'key-a');
  assert.equal(await update(h, withoutA), true);
  nextBar(h);
  marker(h, 8000);
  position(h, 'key-b', 1);
  assert.equal(await update(h, withoutA.filter(section => section.key !== 'key-b')), true);
  nextBar(h);
  marker(h, 12000);
  position(h, 'key-c', 0);
  const added = [{ ...withoutA[1] }, { key: 'key-d', repeats: 2, velocity: 0.9 }];
  assert.equal(await update(h, added), true);
  nextBar(h);
  marker(h, 18000);
  position(h, 'key-d', 0);
  assert.equal(h.starts.length, 1);
}

async function testLatestWinsAndFailure() {
  const h = await start();
  const one = initial().map(section => ({ ...section, velocity: 0.7 }));
  const two = initial().map(section => ({ ...section, velocity: 0.9 }));
  assert.equal(await update(h, one), true);
  assert.equal(await update(h, two), true);
  nextBar(h);
  marker(h, 18000);
  position(h, 'key-a', 1);

  assert.equal(await update(h, one), true);
  const slow = update(h, two, 'jazz');
  assert.equal(h.loads.length, 2);
  nextBar(h);
  marker(h, 18000);
  position(h, 'key-a', 2);
  h.loads[1].resolve(bank(10000));
  assert.equal(await slow, true);
  nextBar(h);
  marker(h, 9000);
  position(h, 'key-b', 0);
  const loadCount = h.loads.length;
  assert.equal(await update(h, one, 'jazz'), true);
  assert.equal(h.loads.length, loadCount, 'Changing notes in an already loaded style must reuse its sound bank');
  nextBar(h);
  marker(h, 7000);

  const old = update(h, two, 'latin');
  const fresh = update(h, one, 'reggae');
  h.loads[3].resolve(bank(12000));
  assert.equal(await fresh, true);
  h.loads[2].resolve(bank(30000));
  assert.equal(await old, false, 'A late older bank cannot replace a newer prepared plan');
  nextBar(h);
  marker(h, 8400);

  const failed = update(h, two, 'funk');
  const rejected = assert.rejects(failed, /Missing current style/);
  h.loads[4].reject(new Error('Missing current style'));
  await rejected;
  assert.equal(h.session.isDrumPreviewActive(), true);
  assert.equal(h.session.isDrumPreviewReady(), true, 'An update failure must preserve the still-playing old plan');
  nextBar(h);
  marker(h, 8400);
  assert.equal(h.starts.length, 1);
  h.session.stopDrumPreview();
  assert.equal(h.session.isDrumPreviewReady(), false);
  assert.equal(h.engine.getDrumPreviewPosition(), undefined);
}

async function testCancellationAndOwners() {
  const actions = [
    { name: 'stop', run: async h => h.session.stopDrumPreview() },
    { name: 'editor', run: async h => {
      const raw = request(initial()).raw;
      await h.session.previewDrumProgram(raw, true, 120, 4, 1);
    } },
    { name: 'calibration', run: async h => h.session.scheduleLatencyPreview(h.now + 650, 0) },
    { name: 'transport', run: async h => {
      h.session.controller.state = 'playing';
      h.storage.set('lastTransportMessage', JSON.stringify({ type: 'TRANSPORT', payload: {
        startAtLeaderMonoMs: h.now + 650, beatIndex: 0, countInBeats: 0
      } }));
      h.session.controller.emit();
      await flush();
    } },
    { name: 'shutdown', run: async h => h.session.shutdown() }
  ];
  for (const action of actions) {
    const h = await start();
    const staged = initial().map(section => ({ ...section, velocity: 0.9 }));
    assert.equal(await update(h, staged), true);
    const pending = update(h, staged, 'jazz');
    await action.run(h);
    const scheduled = h.starts.length;
    h.loads[1].resolve(bank(30000));
    assert.equal(await pending, false, `${action.name} must cancel in-flight local plan preparation`);
    assert.equal(h.starts.length, scheduled, `${action.name} cannot be overwritten by a late update`);
    assert.equal(h.engine.getDrumPreviewPosition(), undefined, `${action.name} must release the local song position`);
  }
  const h = await start();
  const revised = initial().map(section => ({ ...section, velocity: 0.9 }));
  assert.equal(await update(h, revised), true);
  h.session.invalidateDrumPreviewUpdate();
  nextBar(h);
  marker(h, 4000);
  position(h, 'key-a', 1);
}

async function testUnsupportedAndSharedIsolation() {
  for (const looping of [false, true]) {
    const h = await start(initial(), { attach: false, looping });
    const before = continuity(h);
    assert.equal(await update(h, initial()), false, 'Standalone and cursor editor auditions must not use whole-song live updates');
    assert.equal(h.engine.getDrumPreviewPosition(), undefined);
    assertUninterrupted(h, before);
  }
  const h = await start(initial(), { attach: false });
  const revised = request(initial().map(section => ({ ...section, velocity: 0.9 })));
  assert.equal(await h.engine.configureProgram(revised.raw), true);
  nextBar(h);
  marker(h, 4000);
  assert.equal(h.engine.deferPendingSequenceActivation, true,
    'Ordinary shared configuration must still wait for its explicit transport boundary');
}

async function testRouteRecoveryPosition() {
  const h = await start();
  enter(h, 'key-b', 0);
  const revised = initial().map(section => ({ ...section, repeats: section.key === 'key-a' ? 1 : section.repeats }));
  assert.equal(await update(h, revised), true);
  nextBar(h);
  marker(h, 8000);
  position(h, 'key-b', 1);
  const before = h.engine.getDrumPreviewPosition();
  const snapshot = h.engine.getVisualSnapshot();
  h.engine.prepareRouteAudioCursor(snapshot.mainBeatIndex, true);
  assert.equal(h.engine.activeBar.samples[0], 8000,
    'Route recovery after a changed earlier section must seek the applied logical B, not an obsolete absolute bar index');
  const after = h.engine.getDrumPreviewPosition();
  assert.equal(after.sectionKey, before.sectionKey);
  assert.equal(after.repeatIndex, before.repeatIndex);
  assert.equal(h.starts.length, 1);
}

async function testAudiblePlanLagsSubmittedPcm() {
  const h = await start();
  const before = continuity(h);
  const revised = initial().map(section => ({ ...section,
    repeats: section.key === 'key-a' ? 1 : section.repeats,
    velocity: section.key === 'key-b' ? 0.8 : section.velocity }));
  assert.equal(await update(h, revised), true);
  write(h, BAR - h.engine.audioFrameCursor, false);
  assert.equal(write(h, 1, false)[0], 16000, 'Queued future PCM must use the newly applied B plan');
  h.inWrite = undefined;
  position(h, 'key-a', 0);
  h.advanceClock(2000);
  position(h, 'key-b', 0);
  assert.equal(await update(h, revised.slice(1)), true);
  write(h, BAR - h.engine.audioFrameCursor, false);
  assert.equal(write(h, 1, false)[0], 16000);
  h.inWrite = undefined;
  position(h, 'key-b', 0);
  h.advanceClock(2000);
  position(h, 'key-b', 1);
  assertUninterrupted(h, before);
}

async function testOrdinaryRecoveryPosition() {
  const sections = initial().map(section => ({ ...section, beatVelocity: section.velocity / 2 }));
  const h = await start(sections);
  enter(h, 'key-b', 0);
  const revised = sections.map(section => ({ ...section, repeats: section.key === 'key-a' ? 1 : section.repeats }));
  assert.equal(await update(h, revised), true);
  nextBar(h);
  marker(h, 8000);
  position(h, 'key-b', 1);
  const before = continuity(h);
  const origin = h.engine.transportStartLocalMs;
  const originalBeat = h.engine.transportStartBeatIndex;
  for (const beatIndex of [16, 17]) {
    const audibleAt = Math.max(h.now, origin + beatIndex * 500);
    await h.engine.startAudioStream(audibleAt, beatIndex, 0, h.engine.runToken, 0);
    const transition = h.engine.pendingAudioTransition;
    assert.ok(transition && !transition.routeRephase,
      'Ordinary focus/stall recovery must exercise its actual non-route playback transition');
    assert.equal(transition.beatIndex, beatIndex);
    write(h, transition.targetFrame - h.engine.audioSubmittedFrames);
    marker(h, beatIndex === 16 ? 8000 : 4000);
    position(h, 'key-b', 1);
    assert.equal(h.engine.activeBar.samples[0], 8000, 'Recovery must select applied B2 PCM rather than pendingSequence A1');
    assert.equal(h.engine.audioFrameCursor, (beatIndex % 4) * RATE / 2 + 1,
      'An ordinary recovery inside a bar must retain its correct source beat offset');
    assert.equal(h.engine.transportStartLocalMs, origin, 'Local recovery cannot reset the audible transport origin');
    assert.equal(h.engine.transportStartBeatIndex, originalBeat);
    assertUninterrupted(h, before);
  }
}

async function testAudiblePresentationClock() {
  for (const options of [
    { queueMs: 120, compensationMs: 180, recoveryPhaseMs: -120 },
    { queueMs: 650, compensationMs: 180, recoveryPhaseMs: 0 }
  ]) {
    const h = harness({ engineOptions: { queueMs: options.queueMs,
      compensationMs: options.compensationMs, physicalLatencyMs: options.compensationMs } });
    h.session.keepRendererAliveForSession = true;
    const sections = initial().map((section, index) => ({ ...section, repeats: index === 0 ? 1 : 2 }));
    const plan = request(sections);
    const starting = h.session.previewDrumProgram(plan.raw, true, 120, 4, 0, plan.keys);
    h.loads[0].resolve(bank(20000));
    await starting;
    await h.fireDueTimers();
    const first = h.engine.pendingAudioTransition;
    assert.ok(first);
    const sharedOrigin = h.engine.transportStartLocalMs;
    write(h, first.targetFrame - h.engine.audioSubmittedFrames, false);
    assert.equal(write(h, 1, false)[0], 4000);
    h.inWrite = undefined;
    let boundaryFrame = first.targetFrame + BAR;
    if (options.recoveryPhaseMs !== 0) {
      await h.engine.startAudioStream(sharedOrigin + 2000 + options.recoveryPhaseMs,
        4, 0, h.engine.runToken, options.compensationMs);
      const recovery = h.engine.pendingAudioTransition;
      assert.ok(recovery && !recovery.routeRephase);
      boundaryFrame = recovery.targetFrame;
      write(h, boundaryFrame - h.engine.audioSubmittedFrames, false);
      assert.equal(write(h, 1, false)[0], 8000, 'Use B’s real PCM marker at the recovery presentation frame');
    } else {
      write(h, boundaryFrame - h.engine.audioSubmittedFrames, false);
      assert.equal(write(h, 1, false)[0], 8000, 'Use B’s real PCM marker following the queue-clamped start');
    }
    write(h, BAR, false);
    h.inWrite = undefined;
    const audibleBoundary = h.audibleAtFrame(boundaryFrame);
    const phase = audibleBoundary - (sharedOrigin + 2000);
    assert.ok(Math.abs(phase) > 80, 'The fixture must expose a real presentation phase different from the shared wall clock');
    const firstAudible = h.audibleAtFrame(first.targetFrame);
    h.advanceClock(firstAudible - h.now - 1000 / RATE);
    assert.equal(h.engine.getDrumPreviewPosition(), undefined,
      'A valid native clock before the first audible PCM anchor must not fall back to the requested wall-clock start');
    h.advanceClock(2 * 1000 / RATE);
    position(h, 'key-a', 0);
    h.advanceClock(audibleBoundary - h.now - 1000 / RATE);
    position(h, 'key-a', 0);
    const deadline = h.engine.getDrumPreviewPosition().nextBoundaryDelayMs;
    assert.ok(deadline > 0 && deadline <= 2.01 * 1000 / RATE,
      'The adaptive UI deadline must describe the queued native PCM boundary within a frame');
    h.advanceClock(2 * 1000 / RATE);
    position(h, 'key-b', 0);
    assert.equal(h.engine.transportStartLocalMs, sharedOrigin, 'Correct local highlighting cannot move the shared walking clock');
    assert.equal(h.starts.length, 1);
  }
}

async function testActualInsertedDroppedFrames() {
  for (const correction of [-4410, 2205]) {
    const h = harness({ engineOptions: { queueMs: 120, compensationMs: 180, physicalLatencyMs: 180 } });
    h.session.keepRendererAliveForSession = true;
    const plan = request(initial().map(section => ({ ...section, repeats: 1 })));
    const start = h.session.previewDrumProgram(plan.raw, true, 120, 4, 0, plan.keys);
    h.loads[0].resolve(bank(20000));
    await start;
    await h.fireDueTimers();
    const transition = h.engine.pendingAudioTransition;
    write(h, transition.targetFrame - h.engine.audioSubmittedFrames, false);
    assert.equal(write(h, 1, false)[0], 4000);
    const origin = h.engine.transportStartLocalMs;
    h.engine.phaseCorrectionFrames = correction;
    const bufferStart = h.engine.audioSubmittedFrames;
    const pcm = write(h, BAR + Math.abs(correction) + 64, false);
    h.inWrite = undefined;
    const boundaryOffset = pcm.findIndex(value => value === 8000);
    assert.ok(boundaryOffset >= 0, 'Locate the real B downbeat after native callback frame insertion/deletion');
    assert.equal(boundaryOffset, BAR - 1 + correction,
      'The controlled correction must actually shift the submitted B PCM boundary');
    // A compensated audible boundary occurs after the renderer consumed its
    // hardware frame. Keep data submitted beyond that time so the production
    // played<=submitted clamp does not turn this into an artificial underflow.
    write(h, Math.ceil(0.30 * RATE), false);
    h.inWrite = undefined;
    const audibleAt = h.audibleAtFrame(bufferStart + boundaryOffset);
    assert.ok(Math.abs(audibleAt - (origin + 2000)) > 40);
    h.advanceClock(audibleAt - h.now - 1000 / RATE);
    position(h, 'key-a', 0);
    const deadline = h.engine.getDrumPreviewPosition().nextBoundaryDelayMs;
    assert.ok(deadline > 0 && deadline <= 2.01 * 1000 / RATE,
      'Inserted/dropped frames must also move the reported next PCM boundary deadline');
    h.advanceClock(2 * 1000 / RATE);
    assert.equal(h.engine.getDrumPreviewPosition()?.sectionKey, 'key-b',
      `The highlight must cross B's actual presentation boundary after a ${correction}-frame correction`);
    position(h, 'key-b', 0);
    assert.equal(h.engine.transportStartLocalMs, origin,
      'Following inserted/deleted local PCM cannot shift the shared transport clock');
  }
}

async function testPersistentAgedNativeClockAfterEdits() {
  for (const ageMs of [20, 600]) {
    const h = harness({ engineOptions: { queueMs: 120, compensationMs: 180, physicalLatencyMs: 180 } });
    h.session.keepRendererAliveForSession = true;
    const sections = initial();
    const plan = request(sections);
    const starting = h.session.previewDrumProgram(plan.raw, true, 120, 4, 0, plan.keys);
    h.loads[0].resolve(bank(20000));
    await starting;
    await h.fireDueTimers();
    const first = h.engine.pendingAudioTransition;
    write(h, first.targetFrame - h.engine.audioSubmittedFrames, false);
    write(h, Math.round(1.5 * RATE), false);
    h.inWrite = undefined;
    h.advanceClock(h.audibleAtFrame(first.targetFrame) + 650 - h.now);
    // Warm mapping is already established. The aged pair still advances
    // monotonically, so this tests age extrapolation rather than raw resets.
    const nativeTimestamp = h.renderer.getAudioTimestampInfoSync.bind(h.renderer);
    h.renderer.getAudioTimestampInfoSync = () => {
      const actual = nativeTimestamp();
      const reportedAtMs = Math.floor((actual.timestamp / 1000000 - ageMs) / 20) * 20;
      const elapsedMs = actual.timestamp / 1000000 - reportedAtMs;
      return { framePos: actual.framePos - Math.round(elapsedMs * RATE / 1000),
        timestamp: reportedAtMs * 1000000 };
    };
    const mismatches = [];
    const expectedBars = sections.flatMap(section => Array.from({ length: section.repeats },
      (_value, repeatIndex) => ({ sectionKey: section.key, repeatIndex })));
    for (let barNumber = 1; barNumber <= 28; barNumber++) {
      if (barNumber <= 20) {
        const revised = sections.map(section => ({ ...section,
          velocity: section.key === 'key-b' && barNumber % 2 === 0 ? 0.8 : section.velocity }));
        assert.equal(await update(h, revised), true);
      }
      write(h, BAR - h.engine.audioFrameCursor, false);
      const boundary = h.engine.audioSubmittedFrames;
      const pcm = write(h, Math.round(0.9 * RATE), false);
      h.inWrite = undefined;
      assert.ok(pcm[0] > 1000, 'Every tested boundary must be a real emitted drum onset');
      h.advanceClock(h.audibleAtFrame(boundary) + 80 - h.now);
      const expected = expectedBars[barNumber % expectedBars.length];
      const actual = h.engine.getDrumPreviewPosition();
      if (actual?.sectionKey !== expected.sectionKey || actual?.repeatIndex !== expected.repeatIndex) {
        mismatches.push({ barNumber, editsStopped: barNumber > 20,
          expected, actual: actual === undefined ? undefined : {
            sectionKey: actual.sectionKey, repeatIndex: actual.repeatIndex } });
      }
    }
    assert.deepEqual(mismatches, [],
      `${ageMs} ms-aged, 20 ms-quantized native timestamps must follow PCM through 20 edits and after editing stops: ` +
      JSON.stringify({ count: mismatches.length, afterEdits: mismatches.filter(item => item.editsStopped).length,
        cardMismatches: mismatches.filter(item => item.actual?.sectionKey !== item.expected.sectionKey).length,
        cardMismatchesAfterEdits: mismatches.filter(item => item.editsStopped &&
          item.actual?.sectionKey !== item.expected.sectionKey).length,
        first: mismatches[0], last: mismatches.at(-1) }));
    assert.equal(h.starts.length, 1);
    assert.equal(h.session.isDrumPreviewReady(), true);
    h.session.stopDrumPreview();
    assert.equal(h.engine.getDrumPreviewPosition(), undefined);
  }
}

async function testPersistentNativeOriginRegressions(counterStep = 4410 + 882) {
  const sections = initial().map(section => ({ ...section, repeats: 1 }));
  const h = await start(sections);
  const before = continuity(h);
  const sharedOrigin = h.engine.transportStartLocalMs;
  const firstFrame = h.engine.audioTimelineLeadFrames;
  const nativeTimestamp = h.renderer.getAudioTimestampInfoSync.bind(h.renderer);
  let originShift = 0;
  h.renderer.getAudioTimestampInfoSync = () => {
    const sample = nativeTimestamp();
    return { ...sample, framePos: sample.framePos + originShift };
  };
  h.engine.getDrumPreviewPosition();
  const supplied = write(h, 3 * BAR, false);
  h.inWrite = undefined;
  assert.equal(supplied[BAR - 1], 8000, 'The native queue must already contain the real B downbeat');
  for (let edit = 0; edit < 8; edit++) {
    assert.equal(await update(h, sections.map(section => ({ ...section,
      velocity: section.velocity + (edit % 2) * 0.01 }))), true);
    h.advanceClock(100);
    // Test both backward origin jumps and repeated one-quantum losses that
    // leave raw frames increasing; fresh timestamps still expose elapsed time.
    originShift -= counterStep;
    h.engine.getDrumPreviewPosition();
  }
  h.advanceClock(h.audibleAtFrame(firstFrame + BAR) + 50 - h.now);
  position(h, 'key-b', 0);
  write(h, 3 * BAR, false);
  h.inWrite = undefined;
  h.advanceClock(6000);
  position(h, 'key-b', 0);
  assert.equal(h.engine.transportStartLocalMs, sharedOrigin,
    'Repairing the local presentation clock cannot change the shared walk origin');
  assertUninterrupted(h, before);
  const shiftedTimestamp = h.renderer.getAudioTimestampInfoSync;
  h.renderer.getAudioTimestampInfoSync = () => { throw new Error('Transient native timestamp unavailable'); };
  position(h, 'key-b', 0);
  h.renderer.getAudioTimestampInfoSync = shiftedTimestamp;
  position(h, 'key-b', 0);
  h.advanceClock(450);
  const frozen = shiftedTimestamp();
  h.renderer.getAudioTimestampInfoSync = () => frozen;
  h.advanceClock(1600);
  position(h, 'key-c', 0);
  h.renderer.getAudioTimestampInfoSync = shiftedTimestamp;
  position(h, 'key-c', 0);
  const plan = request(sections);
  for (let cycle = 0; cycle < 2; cycle++) {
    // The queued PCM kept playing during the accelerated clock probes. Supply
    // a real callback now, so this warm-cycle check does not inject a separate
    // fake writeData-stall recovery into the native-clock regression.
    write(h, 1, false);
    h.inWrite = undefined;
    h.session.stopDrumPreview();
    await h.session.previewDrumProgram(plan.raw, true, 120, 4, 1);
    await h.fireDueTimers();
    assert.equal(h.engine.getDrumPreviewPosition(), undefined, 'An editor cursor audition must never expose a whole-song highlight');
    h.session.stopDrumPreview();
    await h.session.previewDrumProgram(plan.raw, true, 120, 4, 0, plan.keys);
    await h.fireDueTimers();
    const transition = h.engine.pendingAudioTransition;
    assert.ok(transition);
    write(h, transition.targetFrame - h.engine.audioSubmittedFrames, false);
    const pcm = write(h, 3 * BAR + RATE, false);
    h.inWrite = undefined;
    assert.equal(pcm[BAR], 8000, 'The warm restarted song must contain the actual B downbeat');
    h.advanceClock(h.audibleAtFrame(transition.targetFrame + BAR) + 50 - h.now);
    position(h, 'key-b', 0);
    assert.equal(h.engine.renderer, before.renderer);
    assert.equal(h.engine.rendererPhysicalStartCount, before.starts,
      'A local clock repair must survive Stop/editor/song cycles on the same physical stream');
  }
}

async function testTransientNativeCounterRegression() {
  const h = await start(initial().map(section => ({ ...section, repeats: 1 })));
  const firstFrame = h.engine.audioTimelineLeadFrames;
  const nativeTimestamp = h.renderer.getAudioTimestampInfoSync.bind(h.renderer);
  h.engine.getDrumPreviewPosition();
  const previousRaw = nativeTimestamp().framePos;
  write(h, 3 * BAR, false);
  h.inWrite = undefined;
  h.advanceClock(100);
  h.renderer.getAudioTimestampInfoSync = () => ({ ...nativeTimestamp(), framePos: previousRaw - 882 });
  h.engine.getDrumPreviewPosition();
  h.renderer.getAudioTimestampInfoSync = nativeTimestamp;
  h.advanceClock(16);
  h.engine.getDrumPreviewPosition();
  const boundary = h.audibleAtFrame(firstFrame + BAR);
  h.advanceClock(boundary - h.now - 1000 / RATE);
  position(h, 'key-a', 0);
  h.advanceClock(2 * 1000 / RATE);
  position(h, 'key-b', 0);
  assert.equal(h.starts.length, 1);
}

async function main() {
  await testNextBoundaryAndLogicalIdentity();
  await testStructureChanges();
  await testLatestWinsAndFailure();
  await testCancellationAndOwners();
  await testUnsupportedAndSharedIsolation();
  await testRouteRecoveryPosition();
  await testAudiblePlanLagsSubmittedPcm();
  await testOrdinaryRecoveryPosition();
  await testAudiblePresentationClock();
  await testActualInsertedDroppedFrames();
  await testPersistentAgedNativeClockAfterEdits();
  await testPersistentNativeOriginRegressions();
  await testPersistentNativeOriginRegressions(882);
  await testTransientNativeCounterRegression();
  console.log('PASS whole-song live drum update: actual next-boundary PCM, stable section/repeat mapping, structural edits, latest async/staged plan, cached sounds, failure continuity, owner cancellation, callback-safe rendering, shared defer, route and ordinary recovery position');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
