// Large real phase slips are re-phased onto the shared grid instead of being
// slewed at ~1ms/beat. Device evidence (2026-10-28): rapid BPM changes caused
// render underflows that left a 124ms offset which feedback needed minutes to
// remove.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

const ms = value => Math.round(value * RATE / 1000);

async function playing(wireless = false) {
  // Every route uses the envelope and re-phases; the envelope-off A/B does not.
  const h = fixture({ compensationMs: 45, queueMs: 100, moduleMocks: { './AudioOutputMonitor': {
    AudioOutputMonitor: { isBluetoothA2dpActive: () => wireless, estimateBluetoothLinkLatencyMs: () => 240 } } } });
  const e = h.engine;
  await e.scheduleFromLeaderStart(h.now + 650, 0, 0);
  await h.fireDueTimers();
  h.advanceKeepAlive(650);
  h.advanceKeepAlive(1000);
  const resyncs = [];
  e.rescheduleForOutputRouteChange = async () => { resyncs.push(h.now); return true; };
  return { h, e, resyncs };
}

function feed(t, values) {
  for (const value of values) {
    // undefined models a check without a fresh hardware reading.
    t.e.measurePhaseErrorFrames = () => {
      t.e.lastPhaseErrorAvailable = value !== undefined;
      return value ?? 0;
    };
    t.h.advanceKeepAlive(500);
    t.e.checkAudioProgress(t.h.now);
  }
}

(async () => {
  {
    const t = await playing();
    feed(t, [ms(-124), ms(-122), ms(-121)]);
    assert.equal(t.resyncs.length, 1, 'Three consistent >15ms reads re-phase once');
    assert.ok(t.h.logs.some(line => line.includes('[PhaseLockDiag] stage=resync')));
    feed(t, [ms(-90), ms(-91), ms(-90)]);
    assert.equal(t.resyncs.length, 1, 'Cooldown prevents a second re-phase within 5s');
    feed(t, [ms(-90), ms(-90), ms(-89), ms(-90), ms(-90), ms(-90), ms(-90), ms(-90)]);
    assert.equal(t.resyncs.length, 2, 'A slip that persists after the cooldown re-phases again');
  }
  {
    const t = await playing();
    feed(t, [ms(35), ms(-35), ms(36), ms(-34), ms(40), ms(12), ms(45)]);
    assert.equal(t.resyncs.length, 0, 'Alternating or inconsistent noise never re-phases');
    feed(t, [ms(45), ms(70), ms(46)]);
    assert.equal(t.resyncs.length, 0, 'Reads that disagree by more than 10ms do not confirm');
  }
  {
    const t = await playing();
    feed(t, [ms(12), ms(12), ms(12), ms(12)]);
    assert.equal(t.resyncs.length, 0, 'Small residuals keep the bounded slew path');
    assert.ok(t.e.phaseCorrectionFrames !== 0, 'Slewing still runs below the resync threshold');
  }
  {
    const t = await playing();
    feed(t, [ms(-88), undefined, ms(-87), undefined, ms(-88)]);
    assert.equal(t.resyncs.length, 1, 'Unavailable readings must not reset the confirmation streak');
  }
  {
    const speaker = await playing(false);
    feed(speaker, [ms(-20), ms(-20), ms(-19)]);
    assert.equal(speaker.resyncs.length, 1, 'Speaker routes (envelope) re-phase a consistent 20ms slip');
    const bluetooth = await playing(true);
    feed(bluetooth, [ms(-40), ms(-41), ms(-40)]);
    assert.equal(bluetooth.resyncs.length, 1, 'Bluetooth (an envelope route) re-phases a consistent slip');
    const legacy = await playing(true);
    legacy.e.playbackPositionEnvelopeEnabled = false;
    feed(legacy, [ms(52), ms(48), ms(50), ms(51), ms(49), ms(52)]);
    assert.equal(legacy.resyncs.length, 0, 'With the envelope switched off, feedback only slews');
  }
  {
    // A large envelope rebase already proves the scheduled content is off-grid.
    const t = await playing();
    t.e.phaseResyncAfterRebase = true;
    feed(t, [ms(-75)]);
    assert.equal(t.resyncs.length, 1, 'A large rebase re-phases on the next read without confirmation');
    const settled = await playing();
    settled.e.phaseResyncAfterRebase = true;
    feed(settled, [ms(3), ms(-40)]);
    assert.equal(settled.resyncs.length, 0, 'A read already on grid clears the rebase flag');
  }
  {
    // A route switch can stall the counter (device: a 566ms-old timestamp).
    // The rephase waits until reads are fresh and moving before targeting.
    const h = fixture({ compensationMs: 45, queueMs: 100 });
    const e = h.engine;
    const stallUntil = h.now + 400;
    const frozenFrame = Math.round(4000 * RATE / 1000);
    h.renderer.getAudioTimestampInfoSync = () => h.now < stallUntil ?
      { framePos: frozenFrame, timestamp: (h.now - 566) * 1e6 } :
      { framePos: frozenFrame + Math.round((h.now - stallUntil) * RATE / 1000), timestamp: h.now * 1e6 };
    let done = false;
    const waiting = e.waitForFreshMovingCounter(() => true, Number.POSITIVE_INFINITY).then(() => { done = true; });
    for (let i = 0; i < 100 && !done; i++) {
      h.advanceClock(20);
      await h.fireDueTimers();
    }
    await waiting;
    assert.ok(h.now >= stallUntil, 'The rephase does not target while the timestamp is stale');
    assert.ok(h.now < stallUntil + 100, 'It proceeds within a few polls once the counter moves');
    assert.ok(h.logs.some(line => line.includes('stage=counter-ready')));
  }
  console.log('PASS phase resync: consistent >15ms slips on envelope routes re-phase on the shared grid with cooldown; noise and small residuals keep slewing; unavailable reads keep the streak; Bluetooth re-phases like the speaker, the envelope-off map never does; a large envelope rebase re-phases immediately; route rephase waits for a fresh, moving counter');
})().catch(error => { console.error(error); process.exitCode = 1; });
