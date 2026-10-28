// Shared musical-clock regression using the real MetronomeEngine methods.
const assert = require('node:assert/strict');
const { fixture } = require('./metronome-start-timing.cjs');

function near(actual, expected, label, tolerance = .02) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${label}: ${actual} vs ${expected}`);
}

async function setup({ enabled = true, offset = 5000, skew = 100, preview, override } = {}) {
  const h = fixture({ compensationMs: 45, queueMs: 100 });
  const e = h.engine;
  const origin = h.now;
  e.setOffsetMs(offset, skew, origin + 15000);
  assert.equal(e.phaseCorrectionEnabled, true, 'Shared clocks are active on a new engine');
  if (!enabled) assert.equal(e.setPhaseCorrectionEnabled(false), true);
  const leaderStart = origin + offset + 650;
  await e.scheduleFromLeaderStart(leaderStart, 0, 0, override, preview);
  await h.fireDueTimers();
  return { h, e, origin, offset, leaderStart };
}

async function main() {
  const s = await setup();
  for (let i = 1; i <= 120; i++) {
    s.h.advanceClock(5000);
    const offset = s.offset + (s.h.now - s.origin) * 100 / 1e6;
    s.e.setOffsetMs(offset, 100, s.h.now + 15000);
    const actual = s.e.transportElapsedAt(s.h.now);
    const expected = s.h.now + offset - s.leaderStart;
    near(actual, expected, 'Ten-minute 100 ppm trajectory must follow leader musical time');
    near(s.e.getVisualSnapshot().playheadMs, actual, 'Visuals share the same musical clock');
  }
  near(s.e.transportClockAdjustmentAt(s.h.now), 60 - .065, 'Remote drift reaches the timeline');

  const before = s.e.transportElapsedAt(s.h.now);
  s.e.setOffsetMs(s.offset + 120, 0, s.h.now + 15000);
  near(s.e.transportElapsedAt(s.h.now), before, 'A newly received offset must not jump an active clock');
  s.h.advanceClock(5000);
  near(s.e.transportElapsedAt(s.h.now) - before, 5005, 'The clock absorbs at most one ms per second');
  s.e.setOffsetMs(s.offset - 120, 0, s.h.now + 15000);
  let last = s.e.transportElapsedAt(s.h.now);
  for (let i = 0; i < 20; i++) {
    s.h.advanceClock(1);
    const next = s.e.transportElapsedAt(s.h.now);
    assert.ok(next > last, 'Negative corrections must never reverse musical time');
    last = next;
  }

  const expiry = await setup();
  expiry.h.advanceClock(30000);
  near(expiry.e.transportClockAdjustmentAt(expiry.h.now), 1.5 - .065,
    'Expired skew stops advancing after the retained mapping lifetime');
  expiry.h.advanceClock(30000);
  near(expiry.e.transportClockAdjustmentAt(expiry.h.now), 1.5 - .065, 'Holdover cannot extrapolate forever');

  for (const options of [{ enabled: false }, { preview: 1.25 }, { override: 0 }]) {
    const isolated = await setup(options);
    isolated.e.setOffsetMs(5060, 100, isolated.h.now + 15000);
    isolated.h.advanceClock(5000);
    near(isolated.e.transportClockAdjustmentAt(isolated.h.now), 0,
      'Explicit rollback, local audition and calibration retain their own time domain');
  }

  const timer = await setup({ skew: 0, offset: 0 });
  const emitted = [];
  timer.e.setBeatCallback((beat, _inBar, at) => emitted.push({ beat, at }));
  timer.h.advanceClock(650);
  timer.e.emitBeatAndScheduleNext(timer.e.runToken);
  assert.equal(emitted.length, 1);
  timer.e.setOffsetMs(-10, 0, timer.h.now + 15000);
  timer.h.advanceClock(500);
  timer.e.emitBeatAndScheduleNext(timer.e.runToken);
  assert.equal(emitted.length, 1, 'A timer armed before resync cannot emit before its adjusted deadline');
  timer.h.advanceClock(1);
  timer.e.emitBeatAndScheduleNext(timer.e.runToken);
  assert.equal(emitted.length, 2);
  assert.ok(emitted[1].at > emitted[0].at + 500, 'Callbacks carry actual local deadlines');

  timer.e.phaseCorrectionFrames = 16;
  timer.e.beginTransport();
  assert.equal(timer.e.phaseCorrectionFrames, 0, 'A new transport cannot inherit unsubmitted corrections');
  console.log('PASS shared musical clock: ten-minute drift, continuous bounded slew, monotonic negative corrections, expiry, preview/calibration isolation, adjusted timer deadlines and transport reset');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
