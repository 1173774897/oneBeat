// Walkers and the road stop at the shared pause instant, the same moment the
// audio switches to silence, even when the running=false timer fires late
// (device StartTimingDiag timerLateMs reached 23ms).
const assert = require('node:assert/strict');
const { fixture } = require('./metronome-start-timing.cjs');

(async () => {
  const h = fixture({ compensationMs: 45, queueMs: 100 });
  const e = h.engine;
  await e.scheduleFromLeaderStart(h.now + 650, 0, 0);
  await h.fireDueTimers();
  h.advanceKeepAlive(650);
  h.advanceKeepAlive(1200);
  assert.equal(e.getVisualSnapshot().running, true, 'Visuals run during playback');

  const pauseAt = h.now + 300;
  e.schedulePauseFromLeader(pauseAt);
  h.advanceKeepAlive(299);
  const before = e.getVisualSnapshot();
  assert.equal(before.running, true, 'Visuals keep walking until the shared instant');

  // Cross the instant without firing the pause timer (a late timer).
  h.advanceKeepAlive(2);
  assert.equal(e.running, true, 'Precondition: the late timer has not flipped running yet');
  const after = e.getVisualSnapshot();
  assert.equal(after.running, false, 'Visuals stop at the shared pause instant, not when the timer fires');

  await h.fireDueTimers();
  assert.equal(e.running, false);
  assert.equal(e.getVisualSnapshot().running, false);
  console.log('PASS visual pause instant: walkers stop on the shared pause deadline despite a late timer');
})().catch(error => { console.error(error); process.exitCode = 1; });
