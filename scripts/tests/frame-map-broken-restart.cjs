// A frame map that claims more played than was written is broken, and the next
// start restarts the stream instead of reusing it. Device evidence (2026-10-29):
// a Bluetooth->speaker switch while paused underflowed ~300ms; the counter ran on
// over that silence, raw - base exceeded the written frames by 336ms, and the
// clamped playhead hid ~one buffer of error from phase feedback.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

// Enum namespaces the engine reads while creating a renderer; values are opaque here.
const anyEnum = new Proxy({}, { get: () => 0 });

function silenceCountedFixture({ counterStartDelayMs = 0 } = {}) {
  const calls = [];
  let created;
  const startedAtRef = { at: -1 };
  const audioMock = new Proxy({
    AudioState: { STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 5 },
    AudioLatencyType: { LATENCY_TYPE_ALL: 'all', LATENCY_TYPE_HARDWARE: 'hardware', LATENCY_TYPE_SOFTWARE: 'software' },
    AudioDataCallbackResult: { VALID: 0, INVALID: 1 },
    getAudioManager: () => ({ getAudioSceneSync: () => 0 }),
    // A replacement renderer: its counter starts at zero with the new stream.
    createAudioRenderer: async () => {
      calls.push('create');
      const startedAt = startedAtRef;
      created = {
        state: 1,
        on() {}, off() {},
        getAudioStreamIdSync: () => 43,
        getLatency: () => 45,
        getUnderflowCountSync: () => 0,
        getCurrentOutputDevices: async () => [],
        getAudioTimestampInfoSync: () => ({
          framePos: startedAt.at < 0 ? 0 :
            Math.max(0, Math.round((h.now - startedAt.at - counterStartDelayMs) * RATE / 1000)),
          timestamp: h.now * 1e6 }),
        async start() { calls.push('start'); this.state = 2; startedAt.at = h.now; },
        async stop() { calls.push('stop-new'); this.state = 3; },
        async release() {}
      };
      return created;
    }
  }, { get: (target, key) => key in target ? target[key] : anyEnum });
  const h = fixture({ compensationMs: 45, queueMs: 100, moduleMocks: { '@kit.AudioKit': { audio: audioMock } } });
  const state = { silenceMs: 0 };
  const original = h.renderer.getAudioTimestampInfoSync.bind(h.renderer);
  h.renderer.getAudioTimestampInfoSync = () => {
    const info = original();
    return { framePos: info.framePos + Math.round(state.silenceMs * RATE / 1000), timestamp: info.timestamp };
  };
  h.renderer.stop = async () => { calls.push('stop'); h.renderer.state = 3; };
  h.renderer.start = async () => { calls.push('restart-old'); h.renderer.state = 2; };
  h.renderer.on = () => {};
  h.renderer.off = () => {};
  h.renderer.release = async () => { calls.push('release'); };
  return { h, e: h.engine, state, calls, get created() { return created; }, get startedAt() { return startedAtRef.at; } };
}

(async () => {
  {
    // Healthy map: written frames stay ahead of the counter; no restart.
    const f = silenceCountedFixture();
    f.e.readRenderedStreamFrames(f.h.renderer, f.h.now);
    assert.equal(f.e.audioTimestampBaseBroken, false, 'A queue-positive map is not broken');
  }
  {
    // Lag can only make a read fall short, so 300ms of counted silence is decisive.
    const f = silenceCountedFixture();
    f.state.silenceMs = 300;
    f.e.readRenderedStreamFrames(f.h.renderer, f.h.now);
    assert.equal(f.e.audioTimestampBaseBroken, true, 'Counted silence beyond written frames breaks the map');
    assert.ok(f.h.logs.some(line => line.includes('state=base-broken ') && line.includes('excessMs=200.0')),
      'The broken-map log reports how far the map overshoots the written frames');
  }
  {
    // Startup reads (first callbacks still settling) never flag the map.
    const f = silenceCountedFixture();
    f.e.rendererStartedAtLocalMs = f.h.now - 500;
    f.state.silenceMs = 300;
    f.e.readRenderedStreamFrames(f.h.renderer, f.h.now);
    assert.equal(f.e.audioTimestampBaseBroken, false, 'Reads within the startup grace window are ignored');
  }
  {
    // The pause case: no beat-time reads while paused, so the start itself checks.
    const f = silenceCountedFixture();
    f.state.silenceMs = 300;
    await f.e.scheduleFromLeaderStart(f.h.now + 650, 0, 0);
    await f.h.fireDueTimers();
    assert.deepEqual(f.calls.slice(0, 4), ['stop', 'release', 'create', 'start'],
      'A broken map replaces the renderer instead of restarting the old stream');
    assert.ok(f.h.logs.some(line => line.includes('state=base-broken-restart')));
    assert.ok(f.h.logs.some(line => line.includes('stage=renderer-rebuild reason=start')));
    assert.equal(f.e.renderer, f.created, 'The new renderer owns the stream');
    assert.equal(f.e.audioTimestampBaseBroken, false, 'The new stream starts a fresh, unbroken map');
    assert.ok(f.h.logs.some(line => line.includes('origin=fresh')), 'The new stream uses its exact zero origin');
  }
  {
    // Bluetooth: the deep queue hides counted silence from the excess check, so
    // an underflow after the base was set is itself the evidence.
    const f = silenceCountedFixture();
    f.e.envelopeUnderflowsAtBase = 0;
    f.h.renderer.getUnderflowCountSync = () => 12;
    await f.e.scheduleFromLeaderStart(f.h.now + 650, 0, 0);
    await f.h.fireDueTimers();
    assert.deepEqual(f.calls.slice(0, 4), ['stop', 'release', 'create', 'start'],
      'An underflow since the base replaces the renderer');
    assert.ok(f.h.logs.some(line => line.includes('state=base-broken reason=underflow') &&
      line.includes('underflowsAtBase=0 underflows=12')));
  }
  {
    // No underflow since the base: the warm renderer is reused (start/stop throw).
    const f = silenceCountedFixture();
    f.e.envelopeUnderflowsAtBase = 0;
    f.h.renderer.getUnderflowCountSync = () => 0;
    await f.e.scheduleFromLeaderStart(f.h.now + 650, 0, 0);
    await f.h.fireDueTimers();
    assert.deepEqual(f.calls, [], 'An unchanged underflow count keeps the warm renderer');
    assert.ok(f.e.pendingAudioTransition, 'The warm start schedules normally');
  }
  {
    // A cold start that cannot reach its target re-phases onto a later beat
    // instead of playing late for the whole segment.
    const f = silenceCountedFixture();
    f.state.silenceMs = 300;
    const rephases = [];
    f.e.rescheduleForOutputRouteChange = async () => { rephases.push(f.h.now); return true; };
    f.e.startAudioStreamNow = async (audible, beat, countIn, token) => {
      f.e.pendingAudioTransition = { kind: 'play', token, targetFrame: 50000, beatIndex: beat, countInBeats: countIn };
      f.e.startTargetEstimate = { token, requestedFrame: 50000 - Math.round(0.137 * RATE) };
      f.e.noteClampedColdStart(token);
    };
    await f.e.scheduleFromLeaderStart(f.h.now + 650, 48, 0);
    await f.h.fireDueTimers();
    assert.equal(rephases.length, 1, 'A 137ms clamp re-phases once after the start operation');
    assert.ok(f.h.logs.some(line => line.includes('stage=clamp-rephase') && line.includes('clampMs=137.0')));
    const small = silenceCountedFixture();
    small.state.silenceMs = 300;
    const none = [];
    small.e.rescheduleForOutputRouteChange = async () => { none.push(1); return true; };
    small.e.startAudioStreamNow = async (audible, beat, countIn, token) => {
      small.e.pendingAudioTransition = { kind: 'play', token, targetFrame: 50000, beatIndex: beat, countInBeats: countIn };
      small.e.startTargetEstimate = { token, requestedFrame: 50000 - Math.round(0.010 * RATE) };
      small.e.noteClampedColdStart(token);
    };
    await small.e.scheduleFromLeaderStart(small.h.now + 650, 48, 0);
    await small.h.fireDueTimers();
    assert.equal(none.length, 0, 'A clamp within 15ms keeps the start');
  }
  {
    // Bluetooth: a new renderer's counter stays at zero for ~300ms. The cold
    // start waits for it to move, so frame k is targeted at counterStart + k.
    const f = silenceCountedFixture({ counterStartDelayMs: 300 });
    f.state.silenceMs = 300;
    const audible = f.h.now + 650;
    await f.e.scheduleFromLeaderStart(audible, 0, 0);
    for (let i = 0; i < 80 && !f.h.logs.some(line => line.includes('path=cold-settle')); i++) {
      f.h.advanceClock(10);
      // writeData keeps ~100ms queued ahead of the (late-starting) counter.
      const played = f.created ? f.created.getAudioTimestampInfoSync().framePos : 0;
      while (f.e.renderer === f.created && f.e.audioSubmittedFrames < played + 0.1 * RATE) {
        f.e.handleWriteData(new ArrayBuffer(4096 * 2));
      }
      await f.h.fireDueTimers();
    }
    const wait = f.h.logs.find(line => line.includes('stage=counter-wait'));
    assert.ok(wait && wait.includes('moved=true'), `The cold start waits for a moving counter: ${wait}`);
    const hardwareAt = audible - f.e.outputLatencyMs;
    const expected = (hardwareAt - (f.startedAt + 300)) * RATE / 1000;
    const settle = f.h.logs.find(line => line.includes('path=cold-settle'));
    const target = Number(/committedFrame=(\d+)/.exec(settle)[1]);
    assert.ok(Math.abs(target - expected) < 0.012 * RATE,
      `Target follows the moving counter, not the frozen start: ${target} vs ${expected.toFixed(0)}`);
  }
  {
    // Bluetooth accepts ~400ms of writes while the counter is frozen. The
    // provisional target must not be written before the cold start validates it.
    const f = silenceCountedFixture({ counterStartDelayMs: 300 });
    f.state.silenceMs = 300;
    await f.e.scheduleFromLeaderStart(f.h.now + 650, 0, 0);
    for (let i = 0; i < 80 && !f.h.logs.some(line => line.includes('path=cold-settle')); i++) {
      f.h.advanceClock(10);
      const played = f.created ? f.created.getAudioTimestampInfoSync().framePos : 0;
      while (f.e.renderer === f.created && f.e.audioSubmittedFrames < played + 0.4 * RATE) {
        f.e.handleWriteData(new ArrayBuffer(4096 * 2));
      }
      await f.h.fireDueTimers();
    }
    const settleAt = f.h.logs.findIndex(line => line.includes('path=cold-settle'));
    const firstApplied = f.h.logs.findIndex(line => line.includes('[StartTimingDiag] stage=applied'));
    assert.ok(settleAt >= 0, 'The cold start settles');
    assert.ok(firstApplied < 0 || firstApplied > settleAt,
      'No beat is written before the counter moves and the target is settled');
    assert.ok(f.h.logs.some(line => line.includes('stage=counter-wait') && line.includes('held=true')));
  }
  console.log('PASS frame map broken restart: a map past the written frames is flagged after the startup grace, ' +
    'or any underflow since the base (Bluetooth), makes the next start replace the renderer (exact zero origin); otherwise it is reused; a cold start clamped >15ms re-phases onto a later beat; cold starts target the moving counter and hold the provisional beat until then');
})().catch(error => { console.error(error); process.exitCode = 1; });
