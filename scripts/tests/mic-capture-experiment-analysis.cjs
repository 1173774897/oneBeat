const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const filename = path.join(__dirname, '../../entry/src/main/ets/audio/MicCaptureExperimentAnalysis.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const context = { exports: {} };
vm.runInNewContext(compiled.outputText, context);
const analyze = context.exports.analyzeMicCaptureClock;

function near(actual, expected, tolerance, reason) {
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${reason}: expected ${expected} ±${tolerance}, got ${actual}`);
}

function anchors({ rate = 48000, ppm = 0, epoch = 7000000000000000, count = 101,
  stepFrames = 4800, frameStart = 12345, offsetFrames = -480, jitter = () => 0 } = {}) {
  const measuredRate = rate * (1 + ppm / 1000000);
  return Array.from({ length: count }, (_, index) => ({
    framePosition: frameStart + index * stepFrames,
    timestampNs: epoch + index * stepFrames * 1e9 / measuredRate + jitter(index) * 1e6,
    receivedFrames: frameStart + index * stepFrames + offsetFrames
  }));
}

{
  const source = anchors();
  const before = JSON.stringify(source);
  const result = analyze(source, 48000);
  assert.equal(result.quality, 'stable');
  assert.equal(result.warmupAnchorCount, 0);
  assert.equal(result.usableAnchorCount, 101);
  near(result.clockRateErrorPpm, 0, 0.001, 'a long absolute hardware epoch does not bias the rate');
  near(result.timestampFitResidualMaxMs, 0, 0.00001, 'known exact hardware frame mapping');
  assert.equal(result.fitStartFrame, 12345);
  near(result.fitStartTimestampNs, source[0].timestampNs, 1, 'fixed frame/timestamp mapping is retained');
  assert.equal(result.frameCursorOffsetMedianFrames, -480);
  assert.equal(result.callbackBatchingSuspected, false);
  assert.equal(JSON.stringify(source), before, 'analysis must never rewrite received capture anchors');
}

{
  const progress = anchors();
  const source = [
    { framePosition: 0, timestampNs: 25000000, receivedFrames: 0 },
    { framePosition: 0, timestampNs: 25000000, receivedFrames: 0 },
    ...progress
  ];
  const before = JSON.stringify(source);
  const result = analyze(source, 48000);
  const baseline = analyze(progress, 48000);
  assert.equal(result.quality, 'stable');
  assert.equal(result.anchorCount, source.length);
  assert.equal(result.warmupAnchorCount, 2);
  assert.equal(result.usableAnchorCount, progress.length);
  assert.equal(result.duplicateAnchorCount, 0, 'Warmup placeholders have their own count');
  assert.equal(result.discontinuityCount, 0, 'A pre-start placeholder is not an active capture clock jump');
  near(result.observedDurationMs, 10000, 0.0001, 'Warmup epoch does not create a multi-day capture span');
  near(result.clockRateErrorPpm, baseline.clockRateErrorPpm, 0.0001, 'Warmup does not bias the fitted rate');
  near(result.timestampFitResidualMaxMs, baseline.timestampFitResidualMaxMs, 0.00001,
    'Warmup timestamp is excluded from active residuals');
  assert.equal(result.frameCursorOffsetRangeFrames, baseline.frameCursorOffsetRangeFrames);
  assert.equal(JSON.stringify(source), before, 'Original anchors including placeholders remain unchanged');

  const onlyWarmup = Array.from({ length: 30 }, () => ({ framePosition: 0, timestampNs: 25000000, receivedFrames: 0 }));
  const insufficient = analyze(onlyWarmup, 48000);
  assert.equal(insufficient.quality, 'insufficient');
  assert.equal(insufficient.warmupAnchorCount, 30);
  assert.equal(insufficient.usableAnchorCount, 0);
  assert.equal(insufficient.observedDurationMs, 0);

  const reset = source.slice();
  reset.splice(60, 0, { framePosition: 0, timestampNs: 25000000, receivedFrames: 0 });
  const restarted = analyze(reset, 48000);
  assert.equal(restarted.warmupAnchorCount, 2, 'Only the continuous initial prefix counts as warmup');
  assert.equal(restarted.discontinuityCount, 1, 'A later zero/zero anchor remains a reset');
  assert.equal(restarted.quality, 'unstable');

  const brokenPrefix = [source[0], { framePosition: NaN, timestampNs: 50, receivedFrames: 5 },
    source[1], ...progress];
  const broken = analyze(brokenPrefix, 48000);
  assert.equal(broken.warmupAnchorCount, 1, 'An intervening non-placeholder ends the continuous prefix');
  assert.equal(broken.invalidAnchorCount, 1);
  assert.equal(broken.discontinuityCount, 1);
  assert.equal(broken.quality, 'unstable');

  const nonzeroDelivery = [{ framePosition: 0, timestampNs: 25000000, receivedFrames: 480 },
    source[1], ...progress];
  const delivered = analyze(nonzeroDelivery, 48000);
  assert.equal(delivered.warmupAnchorCount, 0, 'A zero hardware cursor alone is not a warmup exclusion');
  assert.ok(delivered.discontinuityCount > 0);
  assert.equal(delivered.quality, 'unstable');

  const jittered = [source[0], source[1], ...anchors({
    jitter: index => index % 5 === 2 ? 4 : 0
  })];
  const activeResiduals = analyze(jittered, 48000);
  assert.equal(activeResiduals.warmupAnchorCount, 2);
  assert.equal(activeResiduals.quality, 'unstable', 'Excluding placeholders must not relax active timestamp quality');
  assert.ok(activeResiduals.timestampFitResidualP95Ms > 3.9,
    'Actual multi-millisecond active residuals remain visible');
}

{
  for (const ppm of [-275, 240]) {
    const result = analyze(anchors({ ppm, jitter: index => ((index * 7) % 11 - 5) * 0.006 }), 48000);
    assert.equal(result.quality, 'stable');
    near(result.clockRateErrorPpm, ppm, 2, 'signed frame-clock ppm survives small timestamp quantization');
    assert.ok(result.timestampFitResidualP95Ms < 0.05);
  }
  const source441 = anchors({ rate: 44100, stepFrames: 4410, ppm: 90 });
  near(analyze(source441, 44100).clockRateErrorPpm, 90, 0.01, 'actual configured sample rate is used');
}

{
  const normal = anchors();
  const delayedCallbacks = normal.map((anchor, index) => ({ ...anchor,
    receivedFrames: anchor.receivedFrames + (index % 5) * 1800 }));
  // Retain monotonically delivered bytes while allowing callbacks to batch by
  // several blocks; the hardware timestamp itself stays exactly unchanged.
  for (let index = 1; index < delayedCallbacks.length; index++) {
    delayedCallbacks[index].receivedFrames = Math.max(delayedCallbacks[index].receivedFrames,
      delayedCallbacks[index - 1].receivedFrames);
  }
  const result = analyze(delayedCallbacks, 48000);
  assert.equal(result.quality, 'stable', 'callback delivery must not become hardware clock drift');
  assert.equal(result.callbackBatchingSuspected, true);
  near(result.clockRateErrorPpm, 0, 0.001, 'batched callbacks do not change hardware slope');
  assert.ok(result.frameCursorVariationMs > 100);
}

{
  const source = anchors();
  const repeated = source.flatMap((anchor, index) => index % 7 === 0 ? [anchor, { ...anchor }] : [anchor]);
  repeated.splice(17, 0, { framePosition: NaN, timestampNs: 10, receivedFrames: 20 });
  repeated.splice(40, 0, { framePosition: 10, timestampNs: -1, receivedFrames: 20 });
  const result = analyze(repeated, 48000);
  assert.equal(result.quality, 'stable');
  assert.equal(result.duplicateAnchorCount, 15);
  assert.equal(result.invalidAnchorCount, 2);
  assert.equal(result.usableAnchorCount, source.length);
  near(result.clockRateErrorPpm, 0, 0.001, 'repeated hardware queries do not overweight the fit');
}

{
  const source = anchors();
  const stepped = source.map((anchor, index) => ({ ...anchor,
    timestampNs: anchor.timestampNs + (index >= 50 ? 60e6 : 0) }));
  const result = analyze(stepped, 48000);
  assert.equal(result.quality, 'unstable', 'a clock-domain step invalidates a single continuous mapping');
  assert.ok(result.discontinuityCount > 0);
  assert.ok(result.timestampFitResidualMaxMs > 3);

  const reset = source.map((anchor, index) => ({ ...anchor,
    framePosition: index >= 70 ? anchor.framePosition - 200000 : anchor.framePosition }));
  assert.equal(analyze(reset, 48000).quality, 'unstable', 'hardware frame resets cannot be silently dropped');

  const backwardsDelivery = source.map((anchor, index) => ({ ...anchor,
    receivedFrames: index === 60 ? 0 : anchor.receivedFrames }));
  assert.equal(analyze(backwardsDelivery, 48000).quality, 'unstable',
    'a restarted received-PCM counter is not a continuous capture run');
}

{
  const outlier = anchors();
  outlier[57].timestampNs += 4e6;
  const result = analyze(outlier, 48000);
  near(result.clockRateErrorPpm, 0, 0.001, 'robust fitting resists an isolated timestamp query outlier');
  assert.equal(result.quality, 'unstable', 'a hidden 4 ms anchor error remains visible despite robust slope');
  assert.ok(result.timestampFitResidualMaxMs >= 3.99);
  assert.equal(result.discontinuityCount, 0, 'residual limit also catches errors smaller than the step limit');

  const wrongUnits = anchors().map(anchor => ({ ...anchor, timestampNs: anchor.timestampNs / 1000 }));
  assert.equal(analyze(wrongUnits, 48000).quality, 'unstable', 'microseconds must not be accepted as nanoseconds');
  assert.equal(analyze(anchors({ ppm: 6000 }), 48000).quality, 'unstable',
    'an implausible sample-clock rate is not described as stable');
}

{
  assert.equal(analyze([], 48000).quality, 'insufficient');
  assert.equal(analyze(anchors({ count: 5 }), 48000).quality, 'insufficient');
  assert.equal(analyze(anchors({ count: 20, stepFrames: 1000 }), 48000).quality, 'insufficient',
    'many anchors across a short span do not establish a reliable rate');
  assert.equal(analyze(anchors(), 0).quality, 'insufficient');
  const source = anchors({ count: 1 });
  assert.equal(analyze(Array.from({ length: 100 }, () => ({ ...source[0] })), 48000).quality, 'insufficient',
    'a stalled hardware timestamp cannot pass on callback count alone');
}

console.log('PASS MIC experiment clock analysis: continuous warmup prefix, signed ppm, absolute epochs, callback isolation, duplicate/invalid anchors, jumps, resets, residual outliers, unit errors and insufficient data');
