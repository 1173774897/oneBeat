// Exercises the production estimator and its real SessionController admission path.
const assert = require('node:assert/strict');
const { harness, memberController } = require('./clock-sync-fit.cjs');

function accepted(h, offsetMs = 5000, rttMs = 12, count = 5) {
  return { offsetMs, rttMs, localMidpointMs: h.clock.now, validSampleCount: count };
}

function member(h) {
  const controller = memberController(h);
  const sent = [];
  controller.scheduleRandomAvatarReveals = () => {};
  controller.notifyUi = () => {};
  controller.isMemberTransportConnected = () => true;
  controller.sendToLeader = async message => sent.push(message);
  return { controller, sent };
}

async function main() {
  const h = harness();
  const E = h.Estimator;
  const samples = [{ offsetMs: 0, rttMs: 2, localMidpointMs: 100 },
    { offsetMs: 40, rttMs: 100, localMidpointMs: 200 },
    { offsetMs: 45, rttMs: 110, localMidpointMs: 300 }];
  const three = E.medianFromSamples(samples);
  assert.equal(three.offsetMs, 0);
  assert.equal(three.rttMs, 2);
  assert.equal(three.localMidpointMs, 100);
  const five = E.medianFromSamples([...samples, { offsetMs: 10, rttMs: 200 },
    { offsetMs: 0, rttMs: 300 }]);
  assert.equal(five.offsetMs, 40);
  assert.equal(five.rttMs, 100, 'The median must retain its own uncertainty, not the fastest packet RTT');
  assert.equal(five.localMidpointMs, 200);
  assert.equal(five.validSampleCount, 5);
  assert.ok(five.offsetMs - five.rttMs / 2 <= 0);
  assert.throws(() => E.medianFromSamples([]), /no valid/);
  assert.throws(() => E.medianFromSamples([{ offsetMs: NaN, rttMs: 1 }]), /no valid/);

  const good = accepted(h);
  assert.equal(h.estimator.applySample(good), true);
  assert.equal(h.estimator.getReadiness().ready, true);
  const before = JSON.stringify(h.estimator);
  for (const bad of [{ ...good, offsetMs: NaN }, { ...good, rttMs: -1 },
    { ...good, localMidpointMs: h.clock.now + 1 }, { ...good, localMidpointMs: h.clock.now - 1 }]) {
    assert.equal(h.estimator.applySample(bad), false);
    assert.equal(JSON.stringify(h.estimator), before, 'Rejected samples must preserve the entire mapping');
  }
  assert.equal(h.estimator.applySample(good), true);
  assert.equal(JSON.stringify(h.estimator), before, 'A reused measurement must not become another fit point');
  h.clock.now += 100;
  h.estimator.applySample(accepted(h, 5004));
  assert.equal(h.estimator.getSkewPpm(), 0);
  assert.equal(h.estimator.getOffsetAt(h.clock.now + 5000), 5004,
    'Four milliseconds of two-point noise must not become a 204 ms projection');

  const drift = harness();
  const origin = drift.clock.now;
  for (let i = 0; i <= 12; i++) {
    drift.clock.now = origin + i * 5000;
    drift.estimator.applySample(accepted(drift, 90000000 + i * .5));
  }
  assert.ok(Math.abs(drift.estimator.getSkewPpm() - 100) < 0.001);
  assert.ok(Math.abs(drift.estimator.getOffsetAt(origin + 65000) - 90000006.5) < 0.001);
  const expiry = drift.estimator.getMappingValidUntilMs();
  assert.equal(drift.estimator.getOffsetAt(expiry + 100000), drift.estimator.getOffsetAt(expiry));
  assert.equal(drift.estimator.getSkewPpm(expiry), 0);
  assert.equal(drift.estimator.getReadiness(expiry + 1).mode, 'stale');
  drift.clock.now = expiry + 1;
  drift.estimator.smoothAdjust(accepted(drift, 90000020));
  assert.equal(drift.estimator.getOffsetMs(), 90000020, 'Expired training must restart from the fresh measurement');

  const noisy = harness();
  const noisyStart = noisy.clock.now;
  for (let i = 0; i < 3; i++) {
    noisy.clock.now = noisyStart + i * 5000;
    noisy.estimator.applySample(accepted(noisy, 20 * i, 100));
  }
  assert.equal(noisy.estimator.getSkewPpm(), 0, 'An implausible fit is rejected, not clipped');
  assert.equal(noisy.estimator.getOffsetAt(noisy.clock.now + 5000), 40);
  assert.equal(E.getSampleReadiness({ ...good, validSampleCount: 1 }, good.localMidpointMs).ready, false);
  assert.equal(E.getSampleReadiness({ ...good, rttMs: 30 }, good.localMidpointMs).reason, 'uncertain_offset');
  assert.equal(E.getSampleReadiness(good, good.localMidpointMs + 3001).reason, 'stale_sample');

  const measured = harness();
  const firstAt = measured.clock.now;
  const real = member(measured);
  real.controller.sendPing = async (_id, t0) => {
    measured.clock.now = t0 + 12;
    return { serverMono: t0 + 5006, leaderMono: t0 + 5006 };
  };
  const batch = await real.controller.measureClockSync(5);
  assert.equal(batch.localMidpointMs, firstAt + 38, 'A batch keeps the selected packet midpoint');
  assert.ok(batch.localMidpointMs < measured.clock.now);
  real.controller.measureClockSync = async () => batch;
  await real.controller.handleTransportPreparation({ id: 'ready', requireClockReady: true });
  assert.equal(real.sent.at(-1).payload.clockReady, true);
  const retained = measured.estimator.getOffsetMs();
  for (const bad of [{ ...batch, validSampleCount: 1 }, { ...batch, rttMs: 100 },
    { ...batch, localMidpointMs: measured.clock.now - 4000 }]) {
    real.controller.measureClockSync = async () => bad;
    await real.controller.handleTransportPreparation({ id: 'reject', requireClockReady: true });
    assert.equal(real.sent.at(-1).payload.clockReady, false);
    assert.equal(measured.estimator.getOffsetMs(), retained);
  }
  real.controller.measureClockSync = async () => { throw Object.assign(new Error('invalid batch'),
    { name: 'ClockSyncMeasurementError' }); };
  await real.controller.runLightResync();
  assert.equal(real.controller.consecutiveResyncFailures, 0,
    'A precision failure must not masquerade as an unreachable peer');
  real.controller.measureClockSync = async () => { throw new Error('ping timeout'); };
  await real.controller.runLightResync();
  assert.equal(real.controller.consecutiveResyncFailures, 1);

  real.controller.transportPreparationHandler = async () => true;
  let completeAudio;
  real.controller.prepareLocalTransportConfiguration = () => new Promise(resolve => { completeAudio = resolve; });
  real.controller.measureClockSync = async () => accepted(measured);
  const waitingForAudio = real.controller.handleTransportPreparation({ id: 'expired-after-audio', requireClockReady: true });
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(measured.estimator.getReadiness().ready, true);
  measured.clock.now += 3100;
  completeAudio(true);
  await waitingForAudio;
  assert.equal(real.sent.at(-1).payload.clockReady, false, 'Audio await must not hide expired clock readiness');
  console.log('PASS clock readiness: paired midpoint/RTT, invalid and duplicate isolation, bounded trained drift, expiry, real measurement and strict READY rejection, quality versus disconnect');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
