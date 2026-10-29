// Research probe (not a regression gate): does the production phase-feedback
// frame map turn hardware-position quantization into steering noise, and does a
// small filter remove it?
//
// Device evidence (2026-10-28 hilog, two phones, 120 BPM):
// - PhaseLockDiag residuals were bimodal (about -820 and +60 frames) and the
//   change between consecutive logged residuals was ~18-19 ms at P90, although
//   each step moved content only 44 frames (1 ms).
// - Corrections were balanced (+108/-111 on the leader); within one 4-minute
//   member run the cumulative splice wandered between -9 and +12 ms with no
//   linear trend, i.e. it followed measurement noise, not crystal drift.
// - ProductionClockDiag showed rawAgeMs ~ -1..0 (timestamp ~= query time) while
//   rawFrame repeated between reads (cold lock: rawFrame=0, rendered=1764), i.e.
//   framePos advances in HAL-period steps but the timestamp does not.
//
// Model "stale-position" reproduces that: framePos holds the last period
// boundary, timestamp is the query instant. Model "consistent-pair" (both at
// the boundary) is kept as a control. The real MetronomeEngine runs; only the
// native boundary and the candidate estimators live in this script.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

const PERIOD_MS = 20;              // typical HAL period, 882 frames at 44.1 kHz
// STARTUP - ACTIVE is ~37634183ms on the leader device; the fixture clock starts
// at 100000ms, so use a smaller non-integer offset that keeps ACTIVE positive.
const ACTIVE_OFFSET_MS = 61234.7;
const BPM = 120;
const DURATION_MS = 240000;
const RUNS = 12;
const ENVELOPE_SAMPLES = 16;
const MEDIAN_SAMPLES = 5;

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2 ** 32; };
}

// Candidate: framePos can only lag the true position, so the most advanced
// observation on a common time axis (upper envelope) is the least-lagged one.
// Window = 16 reads; DAC drift over that span is far below one frame.
function envelopeFrameMap(e, systemDateTime) {
  const offsets = [];
  return function readRenderedStreamFrames(renderer, nowMs) {
    const startupBefore = systemDateTime.getUptime(0, true) / 1e6;
    const activeBefore = systemDateTime.getUptime(1, true) / 1e6;
    const info = renderer.getAudioTimestampInfoSync();
    const activeAfter = systemDateTime.getUptime(1, true) / 1e6;
    const startupAfter = systemDateTime.getUptime(0, true) / 1e6;
    const timestampMs = info.timestamp / 1e6 + (startupBefore + startupAfter) / 2 - (activeBefore + activeAfter) / 2;
    offsets.push(info.framePos - timestampMs * RATE / 1000);
    if (offsets.length > ENVELOPE_SAMPLES) offsets.shift();
    const best = Math.max(...offsets);
    e.lastAudioTimestampAgeMs = 0;
    e.lastAudioRawFrame = info.framePos;
    const rendered = Math.min(e.audioSubmittedFrames,
      Math.max(0, best + nowMs * RATE / 1000 - e.audioTimestampBaseFrame));
    e.lastRenderedStreamFrame = rendered;
    e.queueDepthFrames = Math.max(0, e.audioSubmittedFrames - rendered);
    return rendered;
  };
}

// Cheaper candidate: leave the map alone and take a running median of the
// residual before thresholding (shairport-sync style tolerance on noise).
function medianResidual(e) {
  const original = e.readPhaseErrorFrames.bind(e);
  const window = [];
  return function readPhaseErrorFrames() {
    const value = original();
    if (value === undefined) return undefined;
    window.push(value);
    if (window.length > MEDIAN_SAMPLES) window.shift();
    return [...window].sort((a, b) => a - b)[Math.floor(window.length / 2)];
  };
}

// shairport-sync style drift tolerance: ignore residuals below the measured noise.
function deadband(e, frames) {
  const original = e.readPhaseErrorFrames.bind(e);
  return function readPhaseErrorFrames() {
    const value = original();
    return value === undefined || Math.abs(value) >= frames ? value : 0;
  };
}

async function run(model, variant, seed) {
  const random = rng(seed);
  const halPhaseMs = random() * PERIOD_MS;
  let clock = () => 0;
  const systemDateTime = {
    TimeType: { STARTUP: 0, ACTIVE: 1 },
    getUptime(type, ns) {
      const ms = type === 1 ? clock() - ACTIVE_OFFSET_MS : clock();
      return ns ? ms * 1e6 : Math.floor(ms);
    }
  };
  const h = fixture({ compensationMs: 45, queueMs: 100, moduleMocks: {
    '@kit.BasicServicesKit': { systemDateTime },
    // Production MonotonicClock returns integer STARTUP milliseconds.
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => Math.floor(clock()) } },
    // Model a speaker/wired HAL; Bluetooth keeps the legacy map by design.
    './AudioOutputMonitor': { AudioOutputMonitor: {
      isBluetoothA2dpActive: () => false, estimateBluetoothLinkLatencyMs: () => 240 } }
  } });
  clock = () => h.now;
  const e = h.engine;
  const nativeStartedAt = h.now - 4000;
  const truthFrame = t => (t - nativeStartedAt) * RATE / 1000;
  h.renderer.getAudioTimestampInfoSync = () => {
    const since = h.now - nativeStartedAt - halPhaseMs;
    const boundary = nativeStartedAt + halPhaseMs + Math.floor(since / PERIOD_MS) * PERIOD_MS;
    const stampAt = model === 'stale-position' ? h.now : boundary;
    return { framePos: Math.round(truthFrame(boundary)), timestamp: (stampAt - ACTIVE_OFFSET_MS) * 1e6 };
  };
  // Cold production map: offset frozen at the first read, no previous raw frame.
  e.audioTimestampClockOffsetMs = undefined;
  e.lastAudioRawFrame = -1;
  // 'production' is the legacy single-read map (envelope-off rollback);
  // 'engine-envelope' is the default-on estimator implemented in MetronomeEngine.
  if (variant !== 'engine-envelope') e.playbackPositionEnvelopeEnabled = false;
  if (variant.startsWith('envelope')) e.readRenderedStreamFrames = envelopeFrameMap(e, systemDateTime);
  if (variant === 'envelope+2ms-deadband') e.readPhaseErrorFrames = deadband(e, Math.round(2 * RATE / 1000));
  // Reference only: no steering at all, so any in-run error is not feedback-made.
  if (variant === 'feedback-off') e.checkAudioProgress = () => {};
  if (variant === 'median-residual') e.readPhaseErrorFrames = medianResidual(e);

  e.setOffsetMs(0, 0, h.now + 15000);
  e.setBpm(BPM, 4);
  await e.scheduleFromLeaderStart(h.now + 650, 0, 0);
  await h.fireDueTimers();
  h.advanceKeepAlive(650);
  const beatMs = 60000 / BPM;
  const measured = [], actual = [], steadyActual = [];
  let corrections = 0;
  for (let elapsed = 0; elapsed < DURATION_MS;) {
    // On device beat checks are timer driven, so their phase against the HAL
    // period varies; non-integer jitter also exercises integer-ms reads.
    const step = beatMs + (random() - 0.5) * 18.6;
    elapsed += step;
    // Feed PCM at the device writeData cadence (~93ms for 4096 frames, jittered)
    // so callback-side envelope sampling sees realistic read phases.
    for (let left = step; left > 0;) {
      const chunk = Math.min(left, 88 + random() * 10);
      h.advanceKeepAlive(chunk);
      left -= chunk;
    }
    e.setOffsetMs(0, 0, h.now + 15000);
    const before = e.phaseCorrectionFrames + e.phaseCorrectionSubmittedFrames;
    e.checkAudioProgress(Math.floor(h.now));
    if (e.phaseCorrectionFrames + e.phaseCorrectionSubmittedFrames !== before) corrections++;
    const residual = e.readPhaseErrorFrames();
    if (residual === undefined) continue;
    // Remove this read's own map error to get what the ear would hear relative
    // to the shared grid (zero true skew, so ideal is a constant 0).
    const mapError = e.lastRenderedStreamFrame - truthFrame(Math.floor(h.now));
    measured.push(residual * 1000 / RATE);
    actual.push((residual - mapError) * 1000 / RATE);
    if (elapsed >= 10000) steadyActual.push((residual - mapError) * 1000 / RATE);
  }
  const stats = values => {
    const mean = values.reduce((a, b) => a + b, 0) / values.length;
    const sd = Math.sqrt(values.reduce((a, b) => a + (b - mean) ** 2, 0) / values.length);
    return { mean, sd, min: Math.min(...values), max: Math.max(...values) };
  };
  const changes = measured.slice(1).map((r, i) => Math.abs(r - measured[i])).sort((x, y) => x - y);
  return { seed, halPhaseMs, measured: stats(measured), actual: stats(actual), steady: stats(steadyActual),
    measuredChangeP90Ms: changes[Math.floor(changes.length * 0.9)], corrections, checks: measured.length };
}

(async () => {
  const results = {};
  for (const model of ['stale-position', 'consistent-pair']) {
    results[model] = {};
    for (const variant of ['feedback-off', 'production', 'median-residual', 'envelope', 'envelope+2ms-deadband',
      'engine-envelope']) {
      const runs = [];
      for (let i = 0; i < RUNS; i++) runs.push(await run(model, variant, 1000 + i));
      const means = runs.map(r => r.actual.mean);
      const s = {
        measuredSdMs: runs.reduce((a, r) => a + r.measured.sd, 0) / RUNS,
        measuredChangeP90Ms: Math.max(...runs.map(r => r.measuredChangeP90Ms)),
        correctionsPerCheck: runs.reduce((a, r) => a + r.corrections, 0) / runs.reduce((a, r) => a + r.checks, 0),
        // Constant per-start error vs the shared grid; differs per device/run.
        actualMeanRangeMs: [Math.min(...means), Math.max(...means)],
        // Error that varies within a run (jitter/wander the ear hears).
        actualWithinRunSdMs: runs.reduce((a, r) => a + r.actual.sd, 0) / RUNS,
        actualWorstAbsMs: Math.max(...runs.map(r => Math.max(Math.abs(r.actual.min), Math.abs(r.actual.max)))),
        // After the first 10 s, once a 16-read envelope has filled at one read per beat.
        steadyWorstAbsMs: Math.max(...runs.map(r => Math.max(Math.abs(r.steady.min), Math.abs(r.steady.max)))),
        steadyWithinRunSdMs: runs.reduce((a, r) => a + r.steady.sd, 0) / RUNS,
        runs
      };
      results[model][variant] = s;
      console.log(`${model.padEnd(16)} ${variant.padEnd(16)} measuredSd=${s.measuredSdMs.toFixed(2)}ms ` +
        `changeP90=${s.measuredChangeP90Ms.toFixed(2)}ms corrections/check=${s.correctionsPerCheck.toFixed(2)} ` +
        `actualMean=[${s.actualMeanRangeMs.map(v => v.toFixed(2)).join(',')}]ms ` +
        `actualSd=${s.actualWithinRunSdMs.toFixed(2)}ms actualWorst=${s.actualWorstAbsMs.toFixed(2)}ms ` +
        `steadySd=${s.steadyWithinRunSdMs.toFixed(2)}ms steadyWorst=${s.steadyWorstAbsMs.toFixed(2)}ms`);
    }
  }
  const out = process.env.PROBE_OUT;
  if (out) {
    const engine = fs.readFileSync(path.resolve('entry/src/main/ets/audio/MetronomeEngine.ets'));
    const sha = require('node:crypto').createHash('sha256').update(engine).digest('hex');
    for (const model of Object.values(results)) for (const v of Object.values(model)) delete v.runs;
    fs.writeFileSync(out, JSON.stringify({ date: '2026-10-28', engineSha256: sha,
      model: { PERIOD_MS, BPM, DURATION_MS, RUNS, ENVELOPE_SAMPLES, MEDIAN_SAMPLES, trueSkewPpm: 0,
        monotonicClock: 'integer STARTUP ms' }, results }, null, 2) + '\n');
  }
  const stale = results['stale-position'];
  assert.ok(stale.envelope.actualWithinRunSdMs < stale.production.actualWithinRunSdMs,
    'Probe expectation: the envelope estimator should reduce in-run audible error');
  assert.ok(stale['engine-envelope'].actualWithinRunSdMs < stale.production.actualWithinRunSdMs,
    'The engine implementation should reproduce the candidate improvement');
  console.log('PASS phase timestamp quantization probe (research model, not acoustic certification)');
})().catch(error => { console.error(error); process.exitCode = 1; });
