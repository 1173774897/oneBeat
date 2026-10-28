// Exercise foreground policy loss and hardware feedback with the actual engine.
// The cold-recovery case also maps real rendered PCM back to its shared deadline.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

async function playing() {
  const h = fixture({ compensationMs: 100, queueMs: 200 });
  await h.engine.scheduleFromLeaderStart(h.now + 650, 0, 0);
  await h.fireDueTimers();
  h.advanceKeepAlive(650);
  h.engine.cancelTimers();
  return h;
}

async function drive(h, operation, step = ms => h.advanceKeepAlive(ms), limitMs = 4000) {
  let complete = false, failure;
  operation.then(() => { complete = true; }, error => { complete = true; failure = error; });
  await h.flushMicrotasks();
  const deadline = h.now + limitMs;
  while (!complete && h.now < deadline) {
    step(20);
    await h.fireDueTimers();
  }
  assert.ok(complete, 'Foreground recovery must finish within its bounded observation window');
  if (failure) throw failure;
}

function observeRecovery(h) {
  const reasons = [];
  h.engine.recoverAudio = async reason => { reasons.push(reason); };
  return reasons;
}

async function testMeasuredPhase() {
  for (const errorMs of [-200, 200]) {
    const h = await playing();
    const reasons = observeRecovery(h);
    h.engine.transportStartLocalMs += errorMs;
    const start = h.now;
    const restoration = h.engine.restoreAfterForeground();
    await h.flushMicrotasks();
    assert.equal(reasons.length, 0, 'A single timestamp cannot establish a stable audible mismatch');
    await drive(h, restoration);
    assert.equal(reasons.length, 1);
    assert.equal(h.now - start, 80, 'Two fresh observations are separated beyond the 20 ms hardware quantum');
  }

  const transient = await playing();
  const origin = transient.engine.transportStartLocalMs;
  const reasons = observeRecovery(transient);
  transient.engine.transportStartLocalMs += 100;
  await drive(transient, transient.engine.restoreAfterForeground(), ms => {
    transient.advanceKeepAlive(ms);
    transient.engine.transportStartLocalMs = origin;
  });
  assert.equal(reasons.length, 0, 'One outlier cannot interrupt an otherwise healthy stream');

  const small = await playing();
  const smallReasons = observeRecovery(small);
  small.engine.transportStartLocalMs += 25;
  await small.engine.restoreAfterForeground();
  assert.equal(smallReasons.length, 0, 'Small residual remains with ordinary phase slew');
}

async function testUnavailableAndLostClock() {
  const transient = await playing();
  const nativeTimestamp = transient.renderer.getAudioTimestampInfoSync;
  const reasons = observeRecovery(transient);
  transient.renderer.getAudioTimestampInfoSync = () => { throw new Error('Temporarily unavailable'); };
  await drive(transient, transient.engine.restoreAfterForeground(), ms => {
    transient.advanceKeepAlive(ms);
    transient.renderer.getAudioTimestampInfoSync = nativeTimestamp;
  });
  assert.equal(reasons.length, 0, 'A recovering timestamp API gets a chance to prove continuity');

  const unavailable = await playing();
  const unavailableReasons = observeRecovery(unavailable);
  unavailable.renderer.getAudioTimestampInfoSync = () => { throw new Error('Unavailable'); };
  const start = unavailable.now;
  await drive(unavailable, unavailable.engine.restoreAfterForeground());
  assert.equal(unavailable.now - start, 2000);
  assert.deepEqual(unavailableReasons, ['foreground phase clock remained unavailable']);
  assert.ok(unavailable.logs.some(line => line.includes('phaseMs=unavailable')));
  assert.ok(!unavailable.logs.some(line => line.startsWith('[ForegroundPlaybackDiag]') && line.includes('phaseMs=0.0')),
    'Missing measurements must not be reported as measured zero error');

  const lost = await playing();
  const lostReasons = observeRecovery(lost);
  lost.engine.measurePhaseErrorFrames();
  const previousFrame = lost.engine.lastAudioRawFrame;
  lost.renderer.getAudioTimestampInfoSync = () => ({ framePos: previousFrame - 882, timestamp: lost.now * 1e6 });
  lost.engine.measurePhaseErrorFrames();
  assert.equal(lost.engine.phaseFeedbackStartFrame, -1);
  assert.equal(lost.engine.audioClockContinuityLost, true);
  await lost.engine.restoreAfterForeground();
  assert.equal(lostReasons.length, 1, 'A lost content coordinate requires a new anchor even when writeData is fresh');

  const policy = await playing();
  const policyReasons = observeRecovery(policy);
  policy.renderer.getAudioTimestampInfoSync = () => { throw new Error('Unavailable throughout playback'); };
  await policy.engine.restoreAfterForeground(true);
  assert.equal(policyReasons.length, 1, 'Confirmed task cancellation repairs immediately without requiring a callback gap');
}

async function testWaitOwnership() {
  for (const busy of ['pendingAudioTransition', 'outputRouteRephasePreparing', 'recoveringAudio']) {
    const h = await playing();
    const reasons = observeRecovery(h);
    h.engine[busy] = busy === 'pendingAudioTransition' ? {
      kind: 'play', token: h.engine.runToken, targetFrame: h.engine.audioSubmittedFrames + 10 * RATE,
      beatIndex: 20, countInBeats: 0, outputLatencyMs: 100
    } : true;
    const start = h.now;
    await drive(h, h.engine.restoreAfterForeground(true), ms => {
      h.advanceKeepAlive(ms);
      if (h.now - start >= 160) h.engine[busy] = busy === 'pendingAudioTransition' ? undefined : false;
    });
    assert.equal(reasons.length, 1, `${busy} must finish before foreground recovery takes the stream`);
    assert.ok(h.now - start >= 160);
  }

  const busy = await playing();
  const busyReasons = observeRecovery(busy);
  busy.engine.outputRouteRephasePreparing = true;
  await drive(busy, busy.engine.restoreAfterForeground(true));
  assert.equal(busyReasons.length, 0, 'Timeout cannot steal an active route transaction');
  assert.equal(busy.engine.backgroundPlaybackInterrupted, true, 'Confirmed loss survives a deferred foreground check');

  const ownershipChanges = [
    ['transport', e => { e.runToken++; }],
    ['revision', e => { e.transportRevision++; }],
    ['pause', e => { e.pause(); }],
    ['focus', e => { e.audioFocusInterrupted = true; }],
    ['preview', e => { e.transportPreviewStartPositionBeats = 0; }],
    ['drum preview', e => { e.drumPreviewPlan = {}; }],
    ['calibration', e => { e.transportOutputCompensationOverrideMs = 0; }],
    ['mic signal', e => { e.calibrationSignal = {}; }]
  ];
  for (const [name, change] of ownershipChanges) {
    const h = await playing();
    const reasons = observeRecovery(h);
    h.engine.transportStartLocalMs += 100;
    let changed = false;
    await drive(h, h.engine.restoreAfterForeground(), ms => {
      // The wait must inspect ownership before the next callback uses it.
      h.advanceClock(ms);
      if (!changed) { changed = true; change(h.engine); }
    });
    assert.equal(reasons.length, 0, `${name} supersedes the pending foreground observation`);
  }
}

async function testRealPcmRecovery() {
  const h = await playing(), e = h.engine, renderer = h.renderer;
  const sharedOrigin = e.transportStartLocalMs;
  const token = e.runToken, revision = e.transportRevision;
  const oldNativeFrame = h.physicalFrame;
  let startAt, stops = 0, starts = 0, firstPcmFrame, applied;
  renderer.stop = async () => {
    stops++;
    renderer.state = 3;
    h.advanceClock(2100);
  };
  renderer.start = async () => {
    starts++;
    startAt = h.now;
    renderer.state = 2;
  };
  renderer.getCurrentOutputDevices = async () => [{ deviceType: 8, id: 1 }];
  renderer.getAudioTimestampInfoSync = () => ({
    // Some devices retain framePos across stop/start. Exercise that mapping.
    framePos: oldNativeFrame + Math.round((h.now - (startAt ?? h.now)) * RATE / 1000),
    timestamp: h.now * 1e6
  });
  const originalApply = e.applyAudioTransition.bind(e);
  e.applyAudioTransition = transition => {
    originalApply(transition);
    applied = { target: transition.targetFrame, beat: transition.beatIndex,
      sourceOnset: e.activeBar.samples.subarray(e.audioFrameCursor).findIndex(sample => sample !== 0) };
  };
  const step = ms => {
    h.advanceClock(ms);
    if (startAt === undefined || renderer.state !== 2) return;
    const submitted = Math.round((h.now - startAt + 200) * RATE / 1000);
    const before = e.audioSubmittedFrames;
    assert.ok(submitted >= before);
    const buffer = new ArrayBuffer((submitted - before) * 2);
    e.handleWriteData(buffer);
    const first = new Int16Array(buffer).findIndex(sample => sample !== 0);
    if (first >= 0 && firstPcmFrame === undefined) firstPcmFrame = before + first;
  };
  // Policy loss with continuously written PCM was the actual observed failure:
  // no callback stall is needed to request the known-lost output to rejoin.
  await drive(h, e.restoreAfterForeground(true), step);
  for (let i = 0; firstPcmFrame === undefined && i < 100; i++) {
    step(20);
    await h.fireDueTimers();
  }
  assert.equal(stops, 1); assert.equal(starts, 1);
  assert.ok(applied && firstPcmFrame !== undefined, 'The real restarted renderer must emit a synthesized beat');
  const gridAt = sharedOrigin + (applied.beat - e.transportStartBeatIndex) * 500;
  const audibleAt = startAt + (firstPcmFrame - applied.sourceOnset) * 1000 / RATE + 100;
  assert.ok(Math.abs(audibleAt - gridAt) <= 1000 / RATE,
    `Recovered PCM must reach the original shared grid: ${audibleAt} versus ${gridAt}`);
  assert.ok(gridAt - startAt >= 750, 'Slow native stop must finish before choosing cold-start lead');
  assert.equal(e.runToken, token); assert.equal(e.transportRevision, revision);
  assert.equal(e.transportStartLocalMs, sharedOrigin);
  assert.equal(e.backgroundPlaybackInterrupted, false);
  assert.equal(e.audioClockContinuityLost, false);
  while (h.now < gridAt + 100) { step(20); await h.fireDueTimers(); }
  assert.ok(Math.abs(e.readPhaseErrorFrames()) <= 1,
    'Recovered feedback must preserve the transport elapsed origin, not restart elapsed time at zero');
}

(async () => {
  await testMeasuredPhase();
  await testUnavailableAndLostClock();
  await testWaitOwnership();
  await testRealPcmRecovery();
  console.log('PASS foreground playback recovery: unavailable versus zero feedback, native task loss, confirmed 50ms residual, bounded retries/ownership guards, and real restarted PCM on the unchanged shared grid');
})().catch(error => { console.error(error); process.exitCode = 1; });
