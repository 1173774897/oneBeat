const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const compiled = ts.transpileModule(fs.readFileSync('entry/src/main/ets/recording/RecordingMixer.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const calls = [];
// Native mock mirrors EnsureProcessedMic: a known baseline is retained; otherwise a speaker
// AEC take reports its own measured lag, or no shift.
let measured = { lagUs: 134000, share: .28 };
function nativeMix(options) {
  const base = nativeBaseline(options);
  // Mirrors MixFile: an upgrade of a tuned take rebases the manual edit (whole ms, +/-300 ms).
  const manual = options.preserveEffectiveMicShift ? Math.max(-300000, Math.min(300000,
    Math.round((options.micShiftUs + options.previousAutoMicShiftUs - base.autoMicShiftUs) / 1000) * 1000)) : options.micShiftUs;
  return { ...base, micShiftUs: manual };
}
function nativeBaseline(options) {
  if (options.autoMicShiftKnown) {
    return { autoMicShiftUs: options.autoMicShiftUs, autoMicShiftConfidence: options.autoMicShiftConfidence,
      autoMicShiftReliable: options.autoMicShiftReliable === 1 };
  }
  if (options.estimateResidualLag) {
    if (measured.share >= .2) return { autoMicShiftUs: -measured.lagUs, autoMicShiftConfidence: measured.share, autoMicShiftReliable: true };
    return { autoMicShiftUs: 0, autoMicShiftConfidence: measured.share, autoMicShiftReliable: false };
  }
  if (options.normalizeSystemMic) return { autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false };
  return { autoMicShiftUs: -900, autoMicShiftConfidence: .81, autoMicShiftReliable: true };
}
assert.ok(!fs.existsSync('entry/src/main/ets/recording/RecordingRoundTripMemory.ets'),
  'The lag belongs to each take (134 ms residual vs 62 ms performance on one phone); no device memory');
const context = { exports: {}, console: { info() {} }, require(name) {
  assert.equal(name, 'libonebeat_recording.so');
  return { async mix(options) { calls.push(options); return nativeMix(options); } };
} };
vm.runInNewContext(compiled.outputText, context);
const mixer = context.exports.RecordingMixer;
const clip = { id: 'captured-team', scope: 'team', path: '/works/take.mp4', sourcePath: '/works/source.mp4',
  micPath: '/works/mic.pcm', innerPath: '/works/inner.pcm', createdAt: 1000, durationMs: 3000,
  width: 1080, height: 2340, interrupted: false, stopReason: 'user',
  audioSampleRate: 48000, audioChannels: 2, innerOffsetUs: -11000, micOffsetUs: 17000,
  captureSyncValid: true, captureMappingVersion: 2, videoTimestampDivisor: 1000,
  builtInSpeakerCapture: true };
const aec = { ...clip, micCaptureMode: 'system-aec', captureMappingVersion: 3 };

(async () => {
  assert.equal(mixer.processedMicPath(clip.micPath), `${clip.micPath}.clean-v3.f32`);
  assert.equal(mixer.processedMicPath(clip.micPath, 'screen-mic'), `${clip.micPath}.clean-v3.f32`);
  assert.equal(mixer.mixVersion(clip), 6, 'The legacy export version must remain unchanged');
  assert.equal(mixer.mixVersion(aec), 10, 'Existing AEC exports re-measure the speaker round trip once');
  assert.equal(mixer.processedMicPath(clip.micPath, 'system-aec'), `${clip.micPath}.system-aec-v5.f32`,
    'System AEC stems must never reuse a legacy echo-cleaned sidecar');
  mixer.validateCaptureTiming(clip);
  mixer.validateCaptureTiming({ ...clip, micCaptureMode: 'screen-mic' });
  mixer.validateCaptureTiming(aec);
  mixer.validateCaptureTiming({ ...aec, videoTimestampDivisor: 1 });
  for (const invalid of [
    { ...aec, captureMappingVersion: 2 },
    { ...aec, captureMappingVersion: 0 },
    { ...aec, captureSyncValid: false },
    { ...aec, videoTimestampDivisor: 0 },
    { ...clip, captureMappingVersion: 3 },
    { ...clip, micCaptureMode: 'screen-mic', captureMappingVersion: 3 }
  ]) {
    assert.throws(() => mixer.validateCaptureTiming(invalid), /时间戳不兼容/,
      'The capture mode must agree with the native timestamp mapping provenance');
  }
  mixer.validateCaptureTiming({ ...clip, captureSyncValid: undefined, captureMappingVersion: undefined,
    videoTimestampDivisor: undefined });

  await mixer.exportMixed(clip, 1, '/works/legacy.mp4');
  assert.equal(calls.at(-1).speakerBleedCancel, 4, 'Legacy speaker captures retain the offline FIR path');
  assert.equal(calls.at(-1).normalizeSystemMic, false);
  assert.equal(calls.at(-1).autoMicShiftKnown, 0, 'Legacy captures retain their measured automatic baseline');
  assert.equal(calls.at(-1).processedMicPath, `${clip.micPath}.clean-v3.f32`);

  // 1. Speaker AEC, clearly locked MIC content: the take's own lag advances the MIC.
  let result = await mixer.exportMixed(aec, 1, '/works/aec-1.mp4', 0);
  let options = calls.at(-1);
  assert.equal(options.speakerBleedCancel, 0, 'System AEC must bypass offline echo cancellation');
  assert.equal(options.normalizeSystemMic, true, 'Device level correction must affect only AEC MIC');
  assert.equal(options.estimateResidualLag, true);
  assert.equal(options.autoMicShiftKnown, 0);
  assert.equal('fallbackAutoMicShiftKnown' in options, false, 'Native never receives a borrowed baseline');
  assert.equal(options.processedMicPath, `${clip.micPath}.system-aec-v5.f32`);
  assert.equal(options.innerOffsetUs, clip.innerOffsetUs, 'Alignment never edits capture timestamps');
  assert.equal(options.micOffsetUs, clip.micOffsetUs);
  assert.equal(result.autoMicShiftUs, -134000);
  // 2. A measured take keeps its own baseline on later gain/shift edits.
  for (const gain of [0, .5, 1, 4]) for (const shift of [-300000, 0, 300000]) {
    result = await mixer.exportMixed({ ...aec, autoMicShiftUs: -134000, autoMicShiftConfidence: .28,
      autoMicShiftReliable: true, renderedMixVersion: 10, renderedMicShiftUs: shift }, gain, '/works/aec-edit.mp4', shift);
    options = calls.at(-1);
    assert.equal(options.autoMicShiftKnown, 1);
    assert.equal(options.autoMicShiftUs, -134000);
    assert.equal(options.micShiftUs, shift);
    assert.equal(options.gain, gain);
    assert.equal(options.preserveEffectiveMicShift, false, 'Ordinary edits apply the request as-is');
    assert.equal(result.micShiftUs, shift);
  }
  // 2b. Upgrading a user-tuned take keeps its audible alignment: manual -130 ms on a zero
  // baseline becomes +4 ms on the measured -134 ms baseline (effective stays -130 ms).
  result = await mixer.exportMixed({ ...aec, autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false,
    renderedMixVersion: 8, renderedMicShiftUs: -130000 }, 1, '/works/aec-upgrade.mp4', -130000);
  assert.equal(calls.at(-1).autoMicShiftKnown, 0, 'An upgrade re-measures from the stems');
  assert.equal(calls.at(-1).preserveEffectiveMicShift, true);
  assert.equal(result.autoMicShiftUs, -134000);
  assert.equal(result.micShiftUs, 4000);
  assert.equal(result.autoMicShiftUs + result.micShiftUs, -130000);
  // 2c. Upgrading an untouched take simply adopts the measurement.
  result = await mixer.exportMixed({ ...aec, autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false,
    renderedMixVersion: 8, renderedMicShiftUs: 0 }, 1, '/works/aec-upgrade0.mp4', 0);
  assert.equal(calls.at(-1).preserveEffectiveMicShift, false);
  assert.deepEqual([result.autoMicShiftUs, result.micShiftUs], [-134000, 0]);
  // 3. Weak take (the 10:27 team take: performance only ~30 ms late): keep a zero
  // baseline even after another take on this device measured a lag.
  measured = { lagUs: 111000, share: .1 };
  result = await mixer.exportMixed(aec, 1, '/works/aec-weak.mp4', 0);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { micShiftUs: 0, autoMicShiftUs: 0, autoMicShiftConfidence: .1, autoMicShiftReliable: false });
  const weak = { ...aec, ...result, renderedMixVersion: 10, renderedMicShiftUs: 0 };
  assert.equal(mixer.isRenderCurrent(weak), true, 'A saved unreliable zero baseline stays current');
  // 3b. A take that adopted the removed device memory (reliable, confidence 0) re-measures
  // from its own stems; untouched it becomes the take's own result.
  const adopted = { ...aec, autoMicShiftUs: -61617, autoMicShiftConfidence: 0, autoMicShiftReliable: true,
    renderedMixVersion: 10, renderedMicShiftUs: 0 };
  assert.equal(mixer.hasDeviceMemoryBaseline(adopted), true);
  assert.equal(mixer.isRenderCurrent(adopted), false);
  result = await mixer.exportMixed(adopted, 1, '/works/aec-unadopt.mp4', 0);
  assert.equal(calls.at(-1).autoMicShiftKnown, 0, 'A borrowed baseline is never retained');
  assert.equal(calls.at(-1).preserveEffectiveMicShift, false);
  assert.deepEqual([result.autoMicShiftUs, result.micShiftUs, result.autoMicShiftReliable], [0, 0, false]);
  assert.equal(mixer.isRenderCurrent({ ...adopted, ...result, renderedMicShiftUs: 0 }), true);
  // A tuned take on a borrowed baseline keeps what the user tuned by ear.
  result = await mixer.exportMixed({ ...adopted, renderedMicShiftUs: 20000 }, 1, '/works/aec-unadopt-tuned.mp4', 20000);
  assert.equal(calls.at(-1).preserveEffectiveMicShift, true);
  assert.equal(calls.at(-1).previousAutoMicShiftUs, -61617);
  assert.equal(result.autoMicShiftUs + result.micShiftUs, -42000);
  // Own measurements (confidence > 0) and zero baselines are never treated as borrowed.
  assert.equal(mixer.hasDeviceMemoryBaseline({ ...adopted, autoMicShiftConfidence: .35 }), false);
  assert.equal(mixer.hasDeviceMemoryBaseline({ ...adopted, autoMicShiftUs: 0 }), false);
  // 4. Earphone AEC takes (pre-change captures) never measure a speaker lag.
  result = await mixer.exportMixed({ ...aec, builtInSpeakerCapture: false }, 1, '/works/aec-ear.mp4', 0);
  assert.equal(calls.at(-1).estimateResidualLag, false);
  assert.equal(result.autoMicShiftUs, 0);
  measured = { lagUs: 134000, share: .28 };
  const beforeInvalid = calls.length;
  for (const [gain, shift] of [[NaN, 0], [-.1, 0], [4.01, 0], [1, NaN], [1, 300001]]) {
    await assert.rejects(mixer.exportMixed(aec, gain, '/works/invalid.mp4', shift));
  }
  assert.equal(calls.length, beforeInvalid, 'Invalid edits must never reach native export');
  console.log('PASS production system AEC mix: mapping provenance, isolated v4 cache, no FIR, per-take measured speaker lag (no device memory), MIC-only manual gain/alignment');
})().catch(error => { console.error(error); process.exitCode = 1; });
