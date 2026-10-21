const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const compiled = ts.transpileModule(fs.readFileSync('entry/src/main/ets/recording/RecordingMixer.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const calls = [];
const context = { exports: {}, console: { info() {} }, require(name) {
  assert.equal(name, 'libonebeat_recording.so');
  return { async mix(options) {
    calls.push(options);
    return { autoMicShiftUs: options.autoMicShiftKnown ? options.autoMicShiftUs : -900,
      autoMicShiftConfidence: options.autoMicShiftKnown ? options.autoMicShiftConfidence : .81,
      autoMicShiftReliable: options.autoMicShiftKnown ? options.autoMicShiftReliable === 1 : true };
  } };
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
  assert.equal(mixer.mixVersion(aec), 7, 'Existing AEC exports must adopt the level fix once');
  assert.equal(mixer.processedMicPath(clip.micPath, 'system-aec'), `${clip.micPath}.system-aec-v2.f32`,
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

  for (const gain of [0, .5, 1, 2]) {
    for (const shift of [-300000, -60000, 0, 90000, 300000]) {
      const result = await mixer.exportMixed({ ...aec,
        // Even stale imported metadata cannot re-enable a second echo pass or auto shift.
        autoMicShiftUs: -17000, autoMicShiftConfidence: .99, autoMicShiftReliable: true
      }, gain, '/works/aec-mix.mp4', shift);
      const options = calls.at(-1);
      assert.equal(options.speakerBleedCancel, 0, 'System AEC must bypass offline echo cancellation');
      assert.equal(options.normalizeSystemMic, true, 'Device level correction must affect only AEC MIC');
      assert.equal(options.autoMicShiftKnown, 1);
      assert.equal(options.autoMicShiftUs, 0, 'Manual alignment is the only editable AEC baseline');
      assert.equal(options.autoMicShiftReliable, 0);
      assert.equal(options.autoMicShiftConfidence, 0);
      assert.equal(options.micShiftUs, shift);
      assert.equal(options.gain, gain);
      assert.equal(options.processedMicPath, `${clip.micPath}.system-aec-v2.f32`);
      assert.equal(options.innerPath, clip.innerPath);
      assert.equal(options.sourcePath, clip.sourcePath);
      assert.equal(options.innerOffsetUs, clip.innerOffsetUs,
        'Editing the MIC must leave the captured accompaniment timestamp untouched');
      assert.equal(options.micOffsetUs, clip.micOffsetUs,
        'Manual alignment remains a separate edit and must not overwrite capture timestamps');
      assert.deepEqual(JSON.parse(JSON.stringify(result)),
        { autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false });
    }
  }
  const beforeInvalid = calls.length;
  for (const [gain, shift] of [[NaN, 0], [-.1, 0], [2.01, 0], [1, NaN], [1, 300001]]) {
    await assert.rejects(mixer.exportMixed(aec, gain, '/works/invalid.mp4', shift));
  }
  assert.equal(calls.length, beforeInvalid, 'Invalid edits must never reach native export');
  console.log('PASS production system AEC mix: mapping provenance, isolated cache, no FIR/auto shift, MIC-only manual gain/alignment');
})().catch(error => { console.error(error); process.exitCode = 1; });
