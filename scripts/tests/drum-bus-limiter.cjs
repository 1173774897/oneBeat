// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
// The drum bus limiter replaces per-voice hard clamps. It must keep every
// onset on its frame (zero latency), stay bit-exact in range, and never clip
// the real built-in kits, which sum to +2..+8 dBFS on overlapping hits.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const sourceRoot = path.join(root, 'entry/src/main/ets');
const cache = new Map();
function load(relative) {
  const file = path.resolve(sourceRoot, relative);
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  });
  vm.runInNewContext(compiled.outputText, { exports, require(name) {
    if (name.startsWith('@kit')) return {};
    return load(path.relative(sourceRoot, path.resolve(path.dirname(file), `${name}.ets`)));
  } }, { filename: file });
  return exports;
}
const { limitDrumBus, DRUM_BUS_CEILING } = load('audio/DrumBusLimiter.ets');
assert.equal(DRUM_BUS_CEILING, 29204, 'Ceiling is -1 dBFS');
const KIT_GAIN = 10 ** (-3 / 20); // Mirrors MetronomeEngine DRUM_KIT_GAIN.
const catalog = load('audio/DrumMachineCatalog.ets');
const WINDOW = 220;
const RELEASE_TAIL = 44100 * 0.06 * 12; // Far past the release curve's snap to unity.

// At or below the ceiling: exact copy across bar boundaries.
{
  const bars = [new Float32Array([0, 29204, -29204, 120, -5]), new Float32Array([7, -29204, 29204])];
  const stats = { overSamples: -1, limitedSamples: -1, peak: 0, minGain: 0 };
  const out = limitDrumBus(bars.map(mix => ({ mix })), true, stats);
  assert.deepEqual(Array.from(out, a => Array.from(a)), bars.map(a => Array.from(a)));
  assert.equal(stats.overSamples, 0);
  assert.equal(stats.limitedSamples, 0);
  assert.equal(stats.minGain, 1);
}

function checkLimited(mixes, looping, label) {
  const out = limitDrumBus(mixes.map(mix => ({ mix })), looping);
  const flatIn = mixes.flatMap(a => [...a]);
  const flatOut = Array.from(out).flatMap(a => Array.from(a));
  assert.equal(flatOut.length, flatIn.length, `${label}: frame count is unchanged`);
  const overs = [];
  flatIn.forEach((x, i) => { if (Math.abs(x) > DRUM_BUS_CEILING) overs.push(i); });
  for (let i = 0; i < flatIn.length; i++) {
    const x = flatIn[i], y = flatOut[i];
    assert.ok(Math.abs(y) <= DRUM_BUS_CEILING, `${label}: no sample above -1 dBFS at ${i}`);
    if (Math.abs(x) > 0.5) {
      assert.ok(Math.sign(y) === Math.sign(x) || y === 0, `${label}: polarity kept at ${i}`);
      assert.ok(Math.abs(y) <= Math.abs(x) + 0.5, `${label}: only attenuates at ${i}`);
    }
    // Far from any over, the sample is untouched: no global loudness change.
    const near = overs.some(o => i >= o - WINDOW && i <= o + RELEASE_TAIL);
    // Looping lookahead ramps the sequence tail down before a loop-restart peak.
    const wrapped = i - flatIn.length;
    const wrapNear = looping && overs.some(o => wrapped >= o - WINDOW && wrapped <= o + RELEASE_TAIL);
    // === treats a float -0 and the stored Int16 0 as the same PCM value.
    if (!near && !wrapNear) assert.ok(y === x, `${label}: identity away from peaks at ${i} (${y} vs ${x})`);
  }
  // Clipping would leave runs of identical full-scale samples; limiting does not.
  let run = 0, longest = 0;
  for (const y of flatOut) { run = Math.abs(y) >= DRUM_BUS_CEILING - 1 ? run + 1 : 0; longest = Math.max(longest, run); }
  assert.ok(longest <= 2, `${label}: no flat-topped clip (run ${longest})`);
  return out;
}

// Synthetic: a hit at a bar boundary, with the loop wrap ramping before frame 0.
{
  const a = new Float32Array(3000), b = new Float32Array(3000);
  for (let i = 0; i < 400; i++) b[i] = 50000 * Math.exp(-i / 120) * Math.cos(i * 0.2);
  a[2999] = 1000;
  checkLimited([a, b], false, 'boundary');
  const looped = checkLimited([b, a], true, 'loop-wrap');
  // The first frame of a peak keeps its exact position (zero latency).
  assert.ok(Math.abs(looped[0][0]) > DRUM_BUS_CEILING * 0.9, 'Onset stays on frame zero');
}

// Real built-in kits at 120 BPM, normal and program-accent dynamics.
const rawDir = path.join(root, 'entry/src/main/resources/rawfile/drums');
const sampleCache = new Map();
function wav(style, key) {
  const id = `${style}/${key}`;
  if (!sampleCache.has(id)) {
    const file = path.join(rawDir, style, `${key}.wav`);
    if (!fs.existsSync(file)) sampleCache.set(id, null);
    else {
      const bytes = fs.readFileSync(file);
      sampleCache.set(id, new Int16Array(bytes.buffer.slice(bytes.byteOffset + 44,
        bytes.byteOffset + 44 + Math.floor((bytes.length - 44) / 2) * 2)));
    }
  }
  return sampleCache.get(id);
}
let limitedStyles = 0;
for (const accent of [1, 1.15]) for (const style of catalog.DRUM_STYLES) {
  const mixes = [];
  for (let variant = 0; variant < 3; variant++) {
    const pattern = catalog.buildDrumPattern(style.key, variant, 4, 4, variant === 2 ? 0 : -1);
    const spb = 44100 * 60 / 120;
    const mix = new Float32Array(Math.round(spb * 4));
    for (const e of pattern.events) {
      const s = wav(style.key, e.sampleKey);
      if (!s) continue;
      const start = Math.round(e.tick * spb / pattern.ticksPerBeat);
      for (let i = 0; i < s.length && start + i < mix.length; i++) {
        mix[start + i] = Math.round(mix[start + i] + s[i] * e.velocity * accent * KIT_GAIN);
      }
    }
    mixes.push(mix);
  }
  if (mixes.some(m => m.some(x => Math.abs(x) > DRUM_BUS_CEILING))) limitedStyles++;
  checkLimited(mixes, true, `${style.key}@${accent}`);
}
assert.ok(limitedStyles >= 10, 'Even with -3 dB kit headroom most built-in kits still need limiting');

// Chunked limiting (head-first drum rendering, 2026-11-03): consecutive chunks
// carrying DrumBusLimiterState must equal one limitDrumBus call sample for sample.
const { limitDrumBusChunk, freshDrumBusLimiterState, DRUM_BUS_LOOKAHEAD_FRAMES } = load('audio/DrumBusLimiter.ets');
function chunked(bars, looping, splits) {
  let state = freshDrumBusLimiterState();
  const out = [];
  const bounds = [0, ...splits, bars.length];
  for (let c = 0; c + 1 < bounds.length; c++) {
    const [a, b] = [bounds[c], bounds[c + 1]];
    const next = b < bars.length ? bars[b] : looping ? bars[0] : undefined;
    const lookahead = next === undefined ? new Float32Array(0) : next.mix.subarray(0, DRUM_BUS_LOOKAHEAD_FRAMES);
    // Cross a structured clone like the TaskPool boundary does.
    const result = limitDrumBusChunk(bars.slice(a, b), lookahead, structuredClone(state));
    state = result.state;
    out.push(...result.outputs);
  }
  return out;
}
let seed = 7;
const random = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
function randomBars(count, overChance) {
  return Array.from({ length: count }, () => {
    const mix = new Float32Array(3000 + Math.floor(random() * 3000));
    for (let i = 0; i < mix.length; i++) {
      mix[i] = Math.round((random() * 2 - 1) * (random() < overChance ? 60000 : 20000));
    }
    return { mix };
  });
}
for (const looping of [false, true]) {
  const bars = randomBars(9, 0.002);
  const whole = limitDrumBus(bars, looping);
  for (const splits of [[1], [2, 4], [1, 2, 3, 4, 5, 6, 7, 8], [8], [3, 6]]) {
    const parts = chunked(bars, looping, splits);
    assert.equal(parts.length, whole.length);
    for (let i = 0; i < whole.length; i++) {
      assert.deepEqual(Array.from(parts[i]), Array.from(whole[i]),
        `Chunked limiting equals one pass (looping=${looping}, splits=${splits}, bar=${i})`);
    }
  }
}
{
  // Overs only at the end of the first chunk: the next chunk has none of its
  // own but is still inside the release, so only a carried state limits it.
  const bars = randomBars(3, 0);
  bars[0].mix.fill(60000, bars[0].mix.length - 50);
  const whole = limitDrumBus(bars, false);
  assert.ok(whole[1].some((value, i) => value !== Math.round(bars[1].mix[i])), 'The release reaches into bar 1');
  const parts = chunked(bars, false, [1]);
  assert.deepEqual(Array.from(parts[1]), Array.from(whole[1]), 'A decaying release continues across chunks');
}

console.log(`PASS drum bus limiter: -1 dBFS ceiling, exact below it, zero latency at bar/loop boundaries, ${limitedStyles} real kit cases limited without clipping or polarity change, chunked limiting identical to one pass`);
