// Default-on playback-position envelope in the real MetronomeEngine.
// Device evidence: framePos advances in HAL-period steps while the timestamp is
// the query instant, so a single read lags by 0..one period. See
// docs/design/team-sync-optimization-review-2026-10-28.md.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

const PERIOD_MS = 20;

// The envelope is used only off Bluetooth; the shared fixture defaults to A2DP.
const route = { wireless: false };
const routeMocks = { './AudioOutputMonitor': { AudioOutputMonitor: {
  isBluetoothA2dpActive: () => route.wireless, estimateBluetoothLinkLatencyMs: () => 240 } } };

function stalePositionFixture() {
  const h = fixture({ compensationMs: 45, queueMs: 100, moduleMocks: routeMocks });
  const nativeStartedAt = h.now - 4000;
  const state = { stalledAt: undefined, rawShift: 0 };
  const truth = t => (t - nativeStartedAt) * RATE / 1000;
  h.renderer.getAudioTimestampInfoSync = () => {
    h.audioCalls.push('timestamp');
    const t = state.stalledAt ?? h.now;
    const boundary = nativeStartedAt + Math.floor((t - nativeStartedAt) / PERIOD_MS) * PERIOD_MS;
    return { framePos: Math.round(truth(boundary)) - state.rawShift, timestamp: h.now * 1e6 };
  };
  h.engine.audioTimestampClockOffsetMs = undefined;
  h.engine.lastAudioRawFrame = -1;
  // A restarted renderer: its counter origin is unproven, so the elapsed-time
  // base and the envelope rebase apply (a fresh renderer uses its exact origin).
  h.engine.rendererPhysicalStartCount = 2;
  return { h, e: h.engine, truth, state, nativeStartedAt };
}

function read(f) {
  return f.e.readRenderedStreamFrames(f.h.renderer, f.h.now);
}

function errorMs(f) {
  return (read(f) - f.truth(f.h.now)) * 1000 / RATE;
}

// 1. The envelope removes the one-sided per-read lag that the legacy map keeps.
{
  const legacy = stalePositionFixture();
  legacy.e.playbackPositionEnvelopeEnabled = false;
  const envelope = stalePositionFixture();
  assert.equal(envelope.e.isPlaybackPositionEnvelopeEnabled(), true, 'Envelope is the production default');
  const legacyErrors = [], envelopeErrors = [];
  let seed = 20261028;
  for (let i = 0; i < 64; i++) {
    // Device writeData cadence (~93ms for 4096 frames) with scheduling jitter
    // spreads read phases over the HAL period; seeded for reproducibility.
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const step = 88 + (seed / 2 ** 32) * 10;
    legacy.h.advanceKeepAlive(step); envelope.h.advanceKeepAlive(step);
    legacyErrors.push(errorMs(legacy)); envelopeErrors.push(errorMs(envelope));
  }
  const tail = values => values.slice(16);
  const span = values => Math.max(...values) - Math.min(...values);
  assert.ok(span(tail(legacyErrors)) > 10, 'Legacy reads should jump by most of a HAL period');
  assert.ok(span(tail(envelopeErrors)) < 4, `Envelope reads must stay consistent: ${span(tail(envelopeErrors))}`);
  assert.ok(Math.max(...tail(envelopeErrors).map(Math.abs)) < 4,
    'Envelope must track the true raw position within a few ms');
  assert.ok(Math.max(...tail(envelopeErrors)) < 0.5, 'A least-lagged read can never run ahead of the truth');
}

// 2. One rebase per physical start replaces the first read's lag in the base.
{
  const f = stalePositionFixture();
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = f.nativeStartedAt;
  f.h.advanceClock(13.7); // first read lands mid-period, i.e. lagged
  read(f);
  assert.equal(f.e.envelopeRebasePending, true);
  // Same-period reads are merged, so ~220ms of reads yields the 8 distinct periods.
  for (let i = 0; i < 24; i++) { f.h.advanceKeepAlive(9.1); read(f); }
  const rebases = f.h.logs.filter(line => line.includes('reason=envelope-rebase'));
  assert.equal(rebases.length, 1, 'Exactly one envelope rebase per physical start');
  assert.equal(f.e.envelopeRebasePending, false);
  assert.ok(Math.abs(errorMs(f)) < 4, 'Rebased map must match elapsed-time position without first-read lag');
  for (let i = 0; i < 12; i++) { f.h.advanceKeepAlive(9.1); read(f); }
  assert.equal(f.h.logs.filter(line => line.includes('reason=envelope-rebase')).length, 1,
    'Later reads must not rebase a running map again');
}

// 3. A raw counter regression restarts the window instead of trusting old offsets.
{
  const f = stalePositionFixture();
  for (let i = 0; i < 10; i++) { f.h.advanceKeepAlive(11); read(f); }
  const countBefore = f.e.envelopeCount;
  f.state.rawShift = 50000;
  f.h.advanceClock(11);
  f.e.recordPlaybackEnvelopeSample(f.e.readDrumPreviewNativeSample(f.h.renderer));
  assert.ok(countBefore > 1 && f.e.envelopeCount === 1, 'Regression must restart the envelope window');
}

// 4. A stalled counter is not extrapolated through the envelope beyond its age
// bound, even while writeData keeps re-reading the same frozen framePos.
{
  const f = stalePositionFixture();
  for (let i = 0; i < 16; i++) { f.h.advanceKeepAlive(93); read(f); }
  f.state.stalledAt = f.h.now;
  const frozenTruth = f.truth(f.h.now);
  for (let i = 0; i < 30; i++) f.h.advanceKeepAlive(93); // ~2.8s of callbacks on a frozen counter
  const first = read(f);
  for (let i = 0; i < 5; i++) f.h.advanceKeepAlive(93);
  const second = read(f);
  assert.ok(second - first < 0.05 * RATE, 'After the age bound the estimate must stop following wall time');
  assert.ok(first - frozenTruth < 0.05 * RATE, 'Merged same-period reads must not refresh an old maximum');
}

// 5. Switching is owner-safe, and disabling restores the legacy read exactly.
{
  const f = stalePositionFixture();
  f.e.running = true;
  assert.equal(f.e.setPlaybackPositionEnvelopeEnabled(false), false, 'Running transport rejects the switch');
  f.e.running = false;
  f.e.audioStreaming = false;
  assert.equal(f.e.setPlaybackPositionEnvelopeEnabled(false), true);
  const legacy = stalePositionFixture();
  legacy.e.playbackPositionEnvelopeEnabled = false;
  f.h.advanceKeepAlive(17); legacy.h.advanceKeepAlive(17);
  assert.equal(read(f), read(legacy), 'Disabled envelope must equal the legacy map');
  assert.equal(f.e.setPlaybackPositionEnvelopeEnabled(true), true);
  assert.equal(f.e.envelopeRebasePending, true, 'Re-enabling on a warm renderer allows one rebase');
}

// 6. writeData adds exactly one timestamp read per callback, and none when disabled.
{
  for (const enabled of [true, false]) {
    const f = stalePositionFixture();
    f.e.playbackPositionEnvelopeEnabled = enabled;
    const before = f.h.audioCalls.filter(call => call === 'timestamp').length;
    for (let i = 0; i < 5; i++) f.h.advanceKeepAlive(23);
    const added = f.h.audioCalls.filter(call => call === 'timestamp').length - before;
    assert.equal(added, enabled ? 5 : 0, `writeData timestamp reads with envelope=${enabled}`);
  }
}

// 8. The first second after a physical start (unsettled HAL counter) is not sampled.
{
  const f = stalePositionFixture();
  f.e.rendererStartedAtLocalMs = f.h.now;
  f.e.resetPlaybackEnvelope();
  for (let i = 0; i < 9; i++) { f.h.advanceKeepAlive(100); read(f); }
  assert.equal(f.e.envelopeCount, 0, 'Warm-up reads must stay out of the envelope window');
  for (let i = 0; i < 4; i++) { f.h.advanceKeepAlive(100); read(f); }
  assert.ok(f.e.envelopeCount > 0, 'Reads after the warm-up fill the window');
}

// 7. Bluetooth uses the envelope like the speaker; a route switch restarts the
// window because offsets from another route are invalid, and may rebase once.
{
  const f = stalePositionFixture();
  for (let i = 0; i < 12; i++) { f.h.advanceKeepAlive(93); read(f); }
  route.wireless = true;
  f.h.advanceKeepAlive(600); // past the route cache
  read(f);
  assert.ok(f.h.logs.some(line => line.includes('[EnvelopeDiag] stage=route active=true wireless=true')));
  assert.equal(f.e.envelopeCount, 1, 'Speaker -> Bluetooth restarts the envelope window');
  for (let i = 0; i < 12; i++) { f.h.advanceKeepAlive(93); read(f); }
  assert.ok(f.e.envelopeCount > 1, 'Bluetooth reads fill the envelope');
  route.wireless = false;
  f.h.advanceKeepAlive(600);
  read(f);
  assert.ok(f.h.logs.some(line => line.includes('[EnvelopeDiag] stage=route active=true wireless=false')));
  assert.equal(f.e.envelopeCount, 1, 'Bluetooth -> speaker restarts the envelope window');
  assert.equal(f.e.envelopeRebasePending, true, 'A route switch allows one rebase of an elapsed-time base');
}

// 9. A first read of framePos 0 only bounds the start lag: device 2026-10-29 the
// counter began 78ms after that read. The first moving read re-anchors the base
// before the first beat plays; without it the later envelope rebase moves the
// base past the resync threshold and flags an immediate re-phase.
// A restarted renderer can instead report the value frozen at the previous stop.
for (const [reanchor, idleFrame] of [[true, 0], [true, 225882], [false, 0]]) {
  const f = stalePositionFixture();
  const startedAt = f.h.now;
  const counterStartsAt = startedAt + 124;
  f.h.renderer.getAudioTimestampInfoSync = () => {
    const sinceStart = h => Math.max(0, Math.floor((h - counterStartsAt) / PERIOD_MS) * PERIOD_MS);
    return { framePos: idleFrame + Math.round(sinceStart(f.h.now) * RATE / 1000), timestamp: f.h.now * 1e6 };
  };
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = startedAt;
  f.e.resetPlaybackEnvelope();
  f.e.audioSubmittedFrames = 10 * RATE;
  const elapsedErrorMs = () => (read(f) - (f.h.now - startedAt) * RATE / 1000) * 1000 / RATE;
  f.h.advanceClock(46);
  read(f);
  assert.equal(f.e.lastAudioRawFrame, idleFrame, 'Precondition: first read sees the idle counter');
  if (!reanchor) f.e.audioTimestampBaseFromIdleCounter = false;
  f.h.advanceClock(169 + 3); // cold-settle read, mid-period
  const settleError = elapsedErrorMs();
  if (reanchor) {
    assert.ok(Math.abs(settleError) < 1, `Re-anchored base must match elapsed position: ${settleError}`);
    assert.ok(f.h.logs.some(line => line.includes('reason=idle-counter-reanchor')));
  } else {
    assert.ok(settleError < -60, `Without re-anchoring the map runs ~78ms behind: ${settleError}`);
  }
  f.h.advanceClock(1000);
  for (let i = 0; i < 24; i++) { f.h.advanceClock(9.1); read(f); }
  assert.equal(f.e.envelopeRebasePending, false, 'Envelope rebase ran');
  assert.equal(f.e.phaseResyncAfterRebase, !reanchor,
    'Only a rebase past the resync threshold flags an immediate re-phase');
  assert.ok(Math.abs(elapsedErrorMs()) < 4, 'The envelope always converges on the elapsed position');
}

// 10. A counter already moving at the first read is not re-anchored: the next
// read differs only by read lag, which the envelope rebase refines later.
{
  const f = stalePositionFixture();
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = f.nativeStartedAt;
  f.h.advanceClock(13.7);
  read(f);
  const base = f.e.audioTimestampBaseFrame;
  f.h.advanceClock(9.1);
  read(f);
  assert.equal(f.e.audioTimestampBaseFrame, base, 'A moving first read keeps its base');
  assert.ok(!f.h.logs.some(line => line.includes('idle-counter-reanchor')));
}

// 11. A fresh renderer's first start: framePos and the written frames share zero,
// so played = framePos with no re-anchor or envelope rebase, even though the
// counter starts late (device 2026-10-29: ~124ms). origin-off restores the
// elapsed-time base for ear A/B.
for (const exact of [true, false]) {
  const f = stalePositionFixture();
  const startedAt = f.h.now;
  const counterStartsAt = startedAt + 124;
  f.h.renderer.getAudioTimestampInfoSync = () => {
    const since = Math.max(0, Math.floor((f.h.now - counterStartsAt) / PERIOD_MS) * PERIOD_MS);
    return { framePos: Math.round(since * RATE / 1000), timestamp: f.h.now * 1e6 };
  };
  f.e.rendererPhysicalStartCount = 1;
  assert.equal(f.e.setFreshOriginBaseEnabled(exact), true);
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = startedAt;
  f.e.resetPlaybackEnvelope();
  f.e.audioSubmittedFrames = 4096;
  f.h.advanceClock(46);
  read(f);
  assert.ok(Math.abs(f.e.audioTimestampBaseFrame - (exact ? 0 : -46 * RATE / 1000)) < 1,
    exact ? 'A fresh origin maps played = framePos' : 'origin-off keeps the elapsed-time base');
  assert.equal(f.e.envelopeRebasePending, !exact, 'An exact origin is never envelope-rebased');
  f.e.audioSubmittedFrames = 10 * RATE;
  f.h.advanceClock(172);
  read(f);
  assert.equal(f.h.logs.some(line => line.includes('idle-counter-reanchor')), !exact,
    'Only the elapsed-time base is re-anchored on a late-starting counter');
}

// 12. Re-anchoring is a startup correction only: a first moving read that comes
// after the window (Bluetooth has no between-beat reads) keeps the base.
{
  const f = stalePositionFixture();
  const startedAt = f.h.now;
  let frozen = true;
  f.h.renderer.getAudioTimestampInfoSync = () => ({
    framePos: frozen ? 225882 : 225882 + Math.round((f.h.now - startedAt - 150) * RATE / 1000),
    timestamp: f.h.now * 1e6 });
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = startedAt;
  f.e.audioSubmittedFrames = 30 * RATE;
  f.h.advanceClock(20);
  read(f);
  const base = f.e.audioTimestampBaseFrame;
  frozen = false;
  f.h.advanceClock(20000);
  read(f);
  assert.equal(f.e.audioTimestampBaseFrame, base, 'A late first moving read never re-anchors');
  assert.ok(!f.h.logs.some(line => line.includes('idle-counter-reanchor')));
}

// 13. A restart's early first read is the frozen origin the counter resumes
// from (device: frozen until 27–58ms, first read 16–40ms); a later first read
// keeps the elapsed-time estimate.
for (const [readAtMs, expected] of [[20, 'restart-origin'], [60, 'elapsed-time-initialization']]) {
  const f = stalePositionFixture();
  const startedAt = f.h.now;
  f.h.renderer.getAudioTimestampInfoSync = () => ({
    framePos: 823898 + Math.max(0, Math.round((f.h.now - startedAt - 40) * RATE / 1000)),
    timestamp: f.h.now * 1e6 });
  f.e.audioTimestampBaseReady = false;
  f.e.rendererStartedAtLocalMs = startedAt;
  f.e.audioSubmittedFrames = 8192;
  f.h.advanceClock(readAtMs);
  read(f);
  assert.ok(f.h.logs.some(line => line.includes(`origin=${expected === 'restart-origin' ? 'restart' : 'elapsed'}`)),
    `First read at ${readAtMs}ms uses ${expected}`);
  if (expected === 'restart-origin') {
    assert.equal(f.e.audioTimestampBaseFrame, 823898, 'The frozen value is the origin');
    assert.equal(f.e.envelopeRebasePending, false, 'An exact restart origin is never envelope-rebased');
  }
}

// 15. A counter stall (device: ~590ms on speaker -> Bluetooth) leaves the
// counter behind the wall clock. The first moving read far below the window
// maximum restarts the window, so the estimate follows the counter at once
// instead of overstating playback until the old maximum ages out (2s).
{
  const f = stalePositionFixture();
  const stall = { from: Infinity, ms: 0 };
  const counterAt = t => {
    const effective = t < stall.from ? t : t < stall.from + stall.ms ? stall.from : t - stall.ms;
    const boundary = f.nativeStartedAt + Math.floor((effective - f.nativeStartedAt) / PERIOD_MS) * PERIOD_MS;
    return Math.round((boundary - f.nativeStartedAt) * RATE / 1000);
  };
  f.h.renderer.getAudioTimestampInfoSync = () => ({ framePos: counterAt(f.h.now), timestamp: f.h.now * 1e6 });
  for (let i = 0; i < 16; i++) { f.h.advanceKeepAlive(93); read(f); }
  stall.from = f.h.now; stall.ms = 590;
  for (let i = 0; i < 7; i++) f.h.advanceKeepAlive(93); // through the stall
  f.h.advanceKeepAlive(93);
  read(f);
  const estimate = f.e.playbackEnvelopeRawFrameAt(f.h.now);
  const counterNow = f.h.renderer.getAudioTimestampInfoSync().framePos;
  assert.ok(f.h.logs.some(line => line.includes('stage=stall-reset')), 'A stall restarts the window');
  assert.ok(Math.abs(estimate - counterNow) < 0.025 * RATE,
    `After a stall the estimate follows the counter: ${((estimate - counterNow) * 1000 / RATE).toFixed(1)}ms`);
}

console.log('PASS playback position envelope: stale-position lag removal, one rebase per physical start, ' +
  'regression reset, stall age bound, owner-safe switch with exact legacy rollback, one read per callback, Bluetooth envelope with route-switch window reset, start warm-up exclusion, idle (zero or frozen) counter re-anchor before the first beat, moving first read kept, fresh-renderer exact origin with origin-off rollback, re-anchor limited to startup, restart frozen origin, stall reset');
