// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const pageSource = fs.readFileSync('entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets', 'utf8');
const builderStart = pageSource.indexOf('  @Builder');
assert.ok(builderStart > 0, 'The page must expose its business methods before UI builders');
// ArkUI's builders need the device runtime. Keep the actual business methods
// and strip only their UI decorators so persistence races run in ordinary JS.
const businessSource = pageSource.slice(0, builderStart)
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct MicLoopbackCalibrationPage', 'export class MicLoopbackCalibrationPage') + '\n}\n';
const compiled = ts.transpileModule(businessSource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
  'The actual page business methods must transpile');

function harness(options = {}) {
  let persistedMs = options.previousMs ?? 72;
  let onFirstSave = options.onFirstSave;
  let page;
  const trace = [];
  const toasts = [];
  const writes = [];
  const bridge = {
    rendererEpoch: 19,
    streamId: 123,
    frameMappingOffsetMs: 213,
    sampledAtMonoMs: 100000,
    ...options.reference
  };
  let currentReference = { ...bridge };
  let referenceSequence = [];
  const session = {
    metronome: { refreshOutputCalibration() { trace.push('refresh'); } },
    controller: { async setBluetoothCalibrationActive() {} },
    readMicCalibrationPlaybackReference(expected) {
      trace.push('reference');
      const next = referenceSequence.shift();
      if (next instanceof Error) throw next;
      if (next !== undefined) currentReference = { ...next };
      if (currentReference.rendererEpoch !== expected.rendererEpoch ||
        currentReference.streamId !== expected.streamId ||
        Math.abs(currentReference.frameMappingOffsetMs - expected.frameMappingOffsetMs) > 30) {
        throw new Error('测量所用的播放基准发生变化，请重新测量');
      }
      return { ...currentReference };
    },
    async verifyMicCalibrationPlaybackReference(expected) {
      return this.readMicCalibrationPlaybackReference(expected);
    },
    keepLatencyCalibrationRendererAlive() { trace.push('keep-alive'); },
    markLatencyCalibrationRoute(wireless) { trace.push(`mark-route:${wireless}`); },
    pauseLatencyCalibration() { trace.push('pause'); },
    async stopLatencyCalibration() { trace.push('stop'); }
  };
  const mocks = {
    '@kit.ArkUI': {
      router: { back(args) { trace.push(`back:${args.url}`); } },
      promptAction: { showToast(args) { toasts.push(args.message); } }
    },
    '../audio/MicLoopbackCalibrator': { MicLoopbackCalibrator: class { cancel() { trace.push('cancel'); } } },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: { isBuiltInSpeakerActive: () => false } },
    '../app/AppSession': { AppSession: { get: () => options.noSession ? undefined : session } },
    '../network/join/TeamNetworkPermissions': {},
    '../store/AudioLatencyPersistence': {
      getCalibrationMs: () => persistedMs,
      getInputLatencyMs: () => options.inputMs ?? 54,
      async saveCalibrationMs(value) {
        if (!Number.isFinite(value) || value < 0) throw new Error('无效的输出补偿');
        writes.push(value);
        trace.push(`save:${value}`);
        const hook = onFirstSave;
        onFirstSave = undefined;
        if (hook !== undefined) await hook({ page, session, setReference, setReferenceSequence });
        persistedMs = value;
      },
      async clearCalibrationMs() {
        trace.push('clear');
        persistedMs = -1;
      },
      async saveInputLatencyMs() {}
    }
  };
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected page dependency ${name}`);
      return mocks[name];
    },
    console: { info() {}, warn() {} }
  };
  vm.runInNewContext(compiled.outputText, context);
  page = new context.exports.MicLoopbackCalibrationPage();
  page.aboutToAppear();
  Object.assign(page, {
    btAudioActive: true,
    hasResult: true,
    resultMs: options.rawMs ?? 97.1,
    snrDb: 25,
    validRuns: 4,
    detectedRuns: 4,
    spreadMs: 5,
    playbackReference: { ...bridge },
    playbackFrameOffsetMs: bridge.frameMappingOffsetMs
  });
  function setReference(reference) { currentReference = { ...reference }; }
  function setReferenceSequence(sequence) { referenceSequence = sequence.slice(); }
  return { page, bridge, session, trace, toasts, writes, setReference, setReferenceSequence,
    persistedMs: () => persistedMs };
}

function assertNotActivated(h, label) {
  for (const action of ['refresh', 'keep-alive', 'mark-route:true', 'back:pages/LeaderLobbyPage']) {
    assert.ok(!h.trace.includes(action), `${label}: stale output must not reach ${action}`);
  }
}

(async () => {
  const candidate = harness();
  assert.equal(candidate.page.outputCompensationMs(), 256.1,
    'A positive production frame offset must increase raw RT minus input');
  assert.equal(candidate.page.resultSaveable(), true);
  await candidate.page.finishAndSave();
  assert.deepEqual(candidate.writes, [256.1]);
  assert.equal(candidate.persistedMs(), 256.1);
  assert.deepEqual(candidate.trace, [
    'reference', 'save:256.1', 'reference', 'refresh', 'keep-alive',
    'mark-route:true', 'back:pages/LeaderLobbyPage'
  ], 'Normal save must validate the retained stream before activation and keep it alive');

  for (const cancel of ['route', 'page-exit', 'disconnect']) {
    const interrupted = harness();
    interrupted.session.verifyMicCalibrationPlaybackReference = async () => {
      if (cancel === 'route') interrupted.page.onAudioOutputRouteChanged();
      if (cancel === 'page-exit') interrupted.page.aboutToDisappear();
      if (cancel === 'disconnect') interrupted.page.btAudioActive = false;
      return { ...interrupted.bridge };
    };
    await interrupted.page.finishAndSave();
    assert.deepEqual(interrupted.writes, [], `${cancel} during recovery must not write a candidate`);
    assert.equal(interrupted.persistedMs(), 72);
    assert.equal(interrupted.page.saving, false);
  }
  const unrecovered = harness();
  unrecovered.session.verifyMicCalibrationPlaybackReference = async () => {
    throw new Error('录音结束后的播放时钟未在 4 秒内恢复');
  };
  await unrecovered.page.finishAndSave();
  assert.deepEqual(unrecovered.writes, [], 'Recovery timeout must preserve the existing compensation');

  const negativeOffset = harness({ rawMs: 120, inputMs: 60,
    reference: { frameMappingOffsetMs: -50 } });
  assert.equal(negativeOffset.page.outputCompensationMs(), 10);
  await negativeOffset.page.finishAndSave();
  assert.deepEqual(negativeOffset.writes, [10], 'A negative bridge must reduce output compensation');

  for (const [label, changes] of [
    ['missing result', { hasResult: false }],
    ['too few stable samples', { validRuns: 2 }],
    ['unstable sample cluster', { spreadMs: 30.1 }],
    ['missing spread', { spreadMs: -1 }],
    ['missing playback reference', { playbackReference: undefined }],
    ['negative raw input difference despite positive bridge', { resultMs: 53, playbackFrameOffsetMs: 300 }],
    ['missing input calibration', { inputLatencyMs: -1 }],
    ['negative output after bridge', { playbackFrameOffsetMs: -100 }],
    ['non-finite result', { resultMs: Number.NaN }]
  ]) {
    const invalid = harness();
    Object.assign(invalid.page, changes);
    assert.equal(invalid.page.resultSaveable(), false, label);
    await invalid.page.finishAndSave();
    assert.deepEqual(invalid.writes, [], `${label} must preserve the previous output value`);
    assert.equal(invalid.persistedMs(), 72);
    assertNotActivated(invalid, label);
  }
  const boundary = harness({ rawMs: 54 });
  Object.assign(boundary.page, { validRuns: 3, spreadMs: 30 });
  assert.equal(boundary.page.resultSaveable(), true, 'Zero raw residual and a 30ms stable cluster are valid');

  for (const change of [{ rendererEpoch: 20 }, { streamId: 124 }, { frameMappingOffsetMs: 244 }]) {
    const shifted = harness();
    shifted.setReference({ ...shifted.bridge, ...change });
    await shifted.page.finishAndSave();
    assert.deepEqual(shifted.writes, [], 'A reference shift before save must not write even temporarily');
    assert.equal(shifted.persistedMs(), 72);
    assert.equal(shifted.page.saving, false);
    assertNotActivated(shifted, 'pre-save reference shift');
  }
  const preReadFailure = harness();
  preReadFailure.setReferenceSequence([new Error('播放时钟不可用')]);
  await preReadFailure.page.finishAndSave();
  assert.deepEqual(preReadFailure.writes, []);
  assert.equal(preReadFailure.persistedMs(), 72);

  const refreshed = harness();
  refreshed.setReference({ ...refreshed.bridge, frameMappingOffsetMs: 217.3 });
  await refreshed.page.finishAndSave();
  assert.deepEqual(refreshed.writes, [260.4], 'Small valid bridge updates must be used in the saved value');
  assert.equal(refreshed.page.playbackFrameOffsetMs, 217.3);

  for (const previousMs of [72, -1]) {
    for (const failure of ['epoch', 'timestamp', 'route-token', 'disconnect', 'page-exit']) {
      const stale = harness({ previousMs, onFirstSave({ page, setReference, setReferenceSequence }) {
        if (failure === 'epoch') setReference({ ...page.playbackReference, rendererEpoch: 20 });
        if (failure === 'timestamp') setReferenceSequence([new Error('播放时钟不可用')]);
        if (failure === 'route-token') page.onAudioOutputRouteChanged();
        if (failure === 'disconnect') {
          page.btAudioActive = false;
          page.onBluetoothAudioRouteChanged();
        }
        if (failure === 'page-exit') page.aboutToDisappear();
      } });
      await stale.page.finishAndSave();
      assert.deepEqual(stale.writes, previousMs >= 0 ? [256.1, previousMs] : [256.1],
        `${failure} during preferences flush must restore the previous persisted value`);
      assert.equal(stale.persistedMs(), previousMs, `${failure} must roll back output compensation`);
      assert.equal(stale.page.saving, false);
      assert.equal(stale.trace.includes('clear'), previousMs < 0);
      assertNotActivated(stale, failure);
    }
  }

  console.log('PASS: actual mic page saves bridged compensation, rejects unstable results and rolls back stale flushes');
})().catch(error => { console.error(error); process.exitCode = 1; });
