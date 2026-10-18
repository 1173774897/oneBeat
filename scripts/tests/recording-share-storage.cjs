const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');

function load(file, mocks, globals = {}) {
  const compiled = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const context = { exports: {}, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
    return mocks[name];
  }, ...globals };
  vm.runInNewContext(compiled.outputText, context);
  return context.exports;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
function plain(value) { return JSON.parse(JSON.stringify(value)); }

function durableEnvironment() {
  const durable = new Map(), files = new Map(), directories = new Set(), failNames = new Set(), trace = [];
  const failRenames = new Set();
  const descriptors = new Map();
  let nextFd = 1, nextUuid = 1;
  let chunkSize = Number.MAX_SAFE_INTEGER;
  const fileIo = {
    OpenMode: { WRITE_ONLY: 1, CREATE: 2, TRUNC: 4 },
    async access(name) { return files.has(name) || directories.has(name); },
    async mkdir(name) { directories.add(name); },
    async listFile(name) { return [...files.keys()].filter(file => file.startsWith(`${name}/`) &&
      !file.substring(name.length + 1).includes('/')).map(file => file.substring(name.length + 1)); },
    async stat(name) {
      assert.ok(files.has(name), `Missing virtual file ${name}`);
      return { size: files.get(name).length, isFile: () => true };
    },
    async readText(name) { assert.ok(files.has(name)); return files.get(name).toString('utf8'); },
    async open(name, mode) {
      if ((mode & 2) || name.startsWith('content://')) files.set(name, Buffer.alloc(0));
      assert.ok(files.has(name), `Open requires existing file ${name}`);
      const fd = nextFd++; descriptors.set(fd, { name, position: 0 }); return { fd };
    },
    async write(fd, buffer) {
      const descriptor = descriptors.get(fd);
      const bytes = Buffer.from(buffer).subarray(0, chunkSize);
      const current = files.get(descriptor.name);
      const output = Buffer.alloc(Math.max(current.length, descriptor.position + bytes.length));
      current.copy(output); bytes.copy(output, descriptor.position);
      descriptor.position += bytes.length;
      files.set(descriptor.name, output); return bytes.length;
    },
    async fsync(fd) { trace.push(`fsync:${descriptors.get(fd).name}`); },
    async close(fd) { descriptors.delete(fd); },
    async rename(from, to) {
      if (failRenames.has(to)) throw new Error(`simulated atomic rename failure: ${to}`);
      assert.ok(files.has(from)); files.set(to, files.get(from)); files.delete(from); trace.push(`rename:${to}`);
    },
    async unlink(name) { assert.ok(files.has(name)); files.delete(name); trace.push(`unlink:${name}`); },
    async copyFile(from, fd) { files.set(descriptors.get(fd).name, Buffer.from(files.get(from))); }
  };
  const arkData = {
    preferences: { async getPreferences(_context, name) {
      const pending = new Map();
      return {
        async get(key, fallback) { return durable.get(`${name}:${key}`) ?? fallback; },
        async put(key, value) {
          if (typeof value === 'string' && value.length > 8192) throw new Error('Preferences string exceeds MAX_VALUE_LENGTH=8192');
          pending.set(key, value);
        },
        async flush() {
          trace.push(`flush:${name}`);
          if (failNames.has(name)) throw new Error(`simulated flush failure: ${name}`);
          for (const [key, value] of pending) durable.set(`${name}:${key}`, value);
        }
      };
    } },
    uniformTypeDescriptor: { UniformDataType: { VIDEO: 'video' } }
  };
  return { durable, files, failNames, failRenames, trace, fileIo, arkData,
    chunks(size) { chunkSize = size; },
    coreFile: { fileIo, fileUri: { getUriFromPath: value => `file://${value}` } },
    arkTs: { util: { generateRandomUUID: () => `test-uuid-${nextUuid++}`,
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } } };
}

function services(environment = durableEnvironment()) {
  const storage = new Map(), ledgerCalls = [], controllers = [], mixCalls = [];
  const globals = { AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    setInterval: () => 1, console: { warn() {} } };
  const atomic = load('common/AtomicTextFile.ets', {
    '@kit.CoreFileKit': environment.coreFile, '@kit.ArkTS': environment.arkTs
  }, globals);
  const rules = load('store/ShareCheckInRules.ets', {}, globals);
  const ledger = load('store/ShareCheckInStore.ets', {
    '@kit.ArkData': environment.arkData,
    '../common/AtomicTextFile': atomic,
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 1000 } },
    './EntitlementStore': { isMonthlyPassActive: () => false,
      isMonthlyPassRewardStateKnown: () => true, waitForMonthlyPassCache: async () => {} },
    './ShareCheckInRules': rules
  }, globals);
  const repository = load('recording/RecordingRepository.ets', {
    '@kit.ArkData': environment.arkData, '@kit.CoreFileKit': environment.coreFile,
    '../common/AtomicTextFile': atomic,
    '@kit.ArkTS': environment.arkTs,
    './RecordingMixer': { RecordingMixer: { async exportMixed(clip, gain, output) {
      mixCalls.push({ clip: plain(clip), gain, output });
      environment.files.set(output, Buffer.from(`rendered-gain=${gain};source=${clip.sourcePath}`));
    } } },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoType: { VIDEO: 'video' },
      getPhotoAccessHelper: () => ({ showAssetsCreationDialog: async () => ['content://album/video'], release() {} }) } }
  }, globals).RecordingRepository;
  let showGate, showFailure = false;
  class ShareController {
    constructor(data) { this.data = data; controllers.push(this); }
    async show() { if (showGate) await showGate; if (showFailure) throw new Error('simulated platform share failure'); }
  }
  const share = load('sharing/RecordingShareService.ets', {
    '@kit.ArkData': environment.arkData, '@kit.CoreFileKit': environment.coreFile, '@kit.ArkTS': environment.arkTs,
    '@kit.ShareKit': { systemShare: { SharedData: class { constructor(data) { this.data = data; } }, ShareController,
      SharePreviewMode: { DETAIL: 1 }, SelectionMode: { SINGLE: 1 } } },
    '../recording/RecordingRepository': { RecordingRepository: repository },
    '../store/ShareCheckInStore': { async acceptShareCheckIn(id) { ledgerCalls.push(id); return ledger.acceptShareCheckIn(id); } }
  }, globals).RecordingShareService;
  async function initialize() {
    await repository.initialize({ filesDir: '/app/files' });
    await share.initialize({});
    await ledger.initializeShareCheckInStore({ filesDir: '/app/files' });
  }
  async function clip(extra = {}) {
    const target = await repository.createTarget();
    environment.files.set(target.path, Buffer.from('synthetic-completed-mp4'));
    const entry = { ...target, durationMs: 3000, width: 720, height: 1280, interrupted: false, stopReason: 'user', ...extra };
    await repository.add(entry);
    return repository.get(entry.id);
  }
  return { environment, storage, ledger, repository, share, ledgerCalls, controllers, mixCalls, initialize, clip, atomic,
    gate(value) { showGate = value; }, failShow(value) { showFailure = value; } };
}

async function testExplicitShareConfirmation() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const gate = deferred(); h.gate(gate.promise);
  const opening = h.share.share(clip, {}); await flush();
  assert.equal(h.share.getPending().handedOff, false);
  assert.equal(h.ledgerCalls.length, 0);
  await assert.rejects(h.share.confirmPublished(h.share.getPending().id), /没有待确认/);
  await assert.rejects(h.share.share(clip, {}), /分享正在处理中/);
  gate.resolve(); h.gate(undefined);
  const attempt = await opening;
  assert.equal(attempt.handedOff, true);
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, false, 'Opening or completing system share never counts as publication');
  assert.equal(h.ledgerCalls.length, 0);
  await assert.rejects(h.share.share(clip, {}), /请先确认或取消/);
  await assert.rejects(h.repository.remove(clip.id), /请先完成或取消/);
  const confirmation = await h.share.confirmPublished(attempt.id);
  assert.equal(confirmation.streakDays, 1);
  assert.equal(h.ledgerCalls.length, 1);
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, true);
  assert.equal(h.share.getPending(), undefined);
  await assert.rejects(h.share.confirmPublished(attempt.id), /没有待确认/);
  const sameDay = await h.share.share(clip, {});
  const repeated = await h.share.confirmPublished(sameDay.id);
  assert.equal(repeated.rewardGranted, false);
  assert.equal(h.ledger.getShareCheckInSummary().history[0].shareCount, 2);
  assert.equal(h.ledger.getShareCheckInSummary().history.length, 1);
  h.failShow(true);
  await assert.rejects(h.share.share(clip, {}), /未能打开系统分享面板/);
  assert.equal(h.share.getPending(), undefined, 'Rejected platform show clears its pending attempt');
  assert.equal(h.ledgerCalls.length, 2);
  assert.equal(h.environment.durable.get('onebeat_video_share:pendingVideoShareV1'), '');
  await h.repository.remove(clip.id);
  assert.equal(h.environment.files.has(clip.path), false);
}

async function testShareCrashReplay() {
  const first = services(); await first.initialize();
  const clip = await first.clip();
  const pending = await first.share.share(clip, {});
  first.environment.failNames.add('onebeat_video_share');
  await assert.rejects(first.share.confirmPublished(pending.id), /simulated flush failure/);
  assert.equal(first.ledger.getShareCheckInSummary().history[0].shareCount, 1,
    'Ledger commits before clearing pending; a failed cleanup must not undo its day');
  assert.equal(first.share.getPending().id, pending.id);
  first.environment.failNames.delete('onebeat_video_share');
  const restart = services(first.environment); await restart.initialize();
  assert.equal(restart.share.getPending().id, pending.id);
  const result = await restart.share.confirmPublished(pending.id);
  assert.equal(result.alreadyProcessed, true);
  assert.equal(result.rewardGranted, false);
  assert.equal(restart.ledger.getShareCheckInSummary().history[0].shareCount, 1);
  assert.equal(restart.share.getPending(), undefined);
}

async function testLibraryRecovery() {
  const h = services(); await h.initialize();
  const target = await h.repository.createTarget();
  const clip = { ...target, durationMs: 4000, width: 720, height: 1280, interrupted: true, stopReason: 'background' };
  h.environment.files.set(clip.path, Buffer.from('synthetic-finished-mp4'));
  h.environment.failRenames.add('/app/files/recordings/library-v1.json');
  await assert.rejects(h.repository.add(clip), /simulated atomic rename failure/);
  assert.equal(h.repository.list().length, 0, 'Failed index publication must not expose a saved work');
  assert.equal(h.environment.files.has(`${clip.path}.recovery.json`), true);
  const recoveryFsync = h.environment.trace.findIndex(entry => entry.startsWith(`fsync:${clip.path}.recovery.json.tmp-`));
  assert.ok(recoveryFsync >= 0 && recoveryFsync < h.environment.trace.indexOf(`rename:${clip.path}.recovery.json`));
  h.environment.failRenames.delete('/app/files/recordings/library-v1.json');
  const restart = services(h.environment); await restart.initialize();
  assert.deepEqual(plain(restart.repository.get(clip.id)), { ...clip, scope: 'solo', renderedGain: 1, renderedAt: clip.createdAt },
    'Restart recovers the completed MP4 after failed index flush');
  assert.equal(h.environment.files.has(`${clip.path}.recovery.json`), false);
  const again = services(h.environment); await again.initialize();
  assert.equal(again.repository.list().length, 1, 'Recovery is idempotent after index commit');
  await again.repository.saveToAlbum(clip, {});
  assert.equal(h.environment.files.get('content://album/video').toString(), 'synthetic-finished-mp4');
  const external = { ...clip, id: 'outside', path: '/outside/unrelated.mp4' };
  await assert.rejects(again.repository.add(external), /录制视频无效/);
  await again.repository.remove(clip.id);
  assert.equal(again.repository.list().length, 0);
  assert.equal(h.environment.files.has(clip.path), false);
}

async function testLargeSnapshotsAndAtomicWrites() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  for (let i = 0; i < 70; i++) {
    const attempt = await h.share.share(clip, {});
    await h.share.confirmPublished(attempt.id);
  }
  assert.ok(h.environment.files.get('/app/files/share-check-in-v1.json').length > 8192,
    'Many same-day shares must preserve all consumed attempts beyond Preferences MAX_VALUE_LENGTH');
  const priorLedger = Buffer.from(h.environment.files.get('/app/files/share-check-in-v1.json'));
  await h.ledger.refreshShareCheckInClock();
  assert.deepEqual(h.environment.files.get('/app/files/share-check-in-v1.json'), priorLedger,
    'The real minute-checkpoint path does not serialize or replace the growing ledger');
  assert.ok(h.environment.files.get('/app/files/clock-watermark-v1.json').length < 128);
  for (let i = 0; i < 60; i++) await h.clip();
  assert.ok(h.environment.files.get('/app/files/recordings/library-v1.json').length > 8192,
    'A growing work list must not depend on an 8192-character Preferences string');
  const restart = services(h.environment); await restart.initialize();
  assert.equal(restart.repository.list().length, 61);
  assert.equal(restart.ledger.getShareCheckInSummary().history[0].shareCount, 70);

  h.environment.chunks(7);
  const path = '/app/files/partial-snapshot.json';
  const text = '同拍录制 / microphone\n'.repeat(80);
  await h.atomic.writeAtomic(path, text);
  assert.equal(await h.atomic.readOptional(path), text, 'Partial native writes must advance the file position without truncating UTF-8 data');
  h.environment.failRenames.add(path);
  await assert.rejects(h.atomic.writeAtomic(path, 'replacement'), /simulated atomic rename failure/);
  assert.equal(await h.atomic.readOptional(path), text, 'A failed rename must preserve the previous committed snapshot');
  assert.equal([...h.environment.files.keys()].some(name => name.startsWith(`${path}.tmp-`)), false);

  const legacyEnvironment = durableEnvironment();
  legacyEnvironment.files.set(clip.path, Buffer.from('legacy-completed-mp4'));
  legacyEnvironment.durable.set('onebeat_recording_library:recordingLibraryV1', JSON.stringify({ version: 1, clips: [clip] }));
  const legacy = services(legacyEnvironment); await legacy.initialize();
  assert.equal(legacy.repository.list().length, 1);
  assert.ok(legacyEnvironment.files.has('/app/files/recordings/library-v1.json'), 'Legacy work Preferences migrate to an atomic file');
}

async function addStemClip(h, scope = 'team') {
  const target = await h.repository.createTarget();
  const base = target.path.substring(0, target.path.length - 4);
  const clip = { ...target, durationMs: 3000, width: 720, height: 1280, interrupted: false,
    stopReason: 'user', scope, sourcePath: `${base}.source.mp4`, micPath: `${base}.mic.pcm`,
    innerPath: `${base}.inner.pcm`, micOffsetUs: 300, innerOffsetUs: 100,
    audioSampleRate: 44100, audioChannels: 2, renderedGain: 1 };
  h.environment.files.set(clip.path, Buffer.from('initial-gain=1'));
  h.environment.files.set(clip.sourcePath, Buffer.from('immutable-video'));
  h.environment.files.set(clip.micPath, Buffer.from('immutable-mic'));
  h.environment.files.set(clip.innerPath, Buffer.from('immutable-internal-audio'));
  await h.repository.add(clip);
  return h.repository.get(clip.id);
}

async function testWorkScopeAndNonDestructiveGain() {
  const h = services(); await h.initialize();
  const legacy = await h.clip();
  const team = await addStemClip(h);
  assert.equal(legacy.scope, 'solo', 'Pre-scope works remain reachable from the solo list');
  assert.equal(h.repository.count('solo'), 1); assert.equal(h.repository.count('team'), 1);
  assert.deepEqual(plain(h.repository.list('solo').map(clip => clip.id)), [legacy.id]);
  assert.deepEqual(plain(h.repository.list('team').map(clip => clip.id)), [team.id]);
  await assert.rejects(h.repository.render(legacy, 0.5), /旧视频已合并声音/);
  const immutable = new Map([team.sourcePath, team.micPath, team.innerPath].map(path => [path, Buffer.from(h.environment.files.get(path))]));
  const first = await h.repository.render(team, 1.234);
  assert.equal(first.renderedGain, 1.23);
  assert.equal(h.mixCalls[0].gain, 1.23, 'The repository passes the desired mic gain once rather than compounding it with prior gain');
  assert.equal(h.mixCalls[0].clip.sourcePath, team.sourcePath);
  assert.equal(h.mixCalls[0].clip.micPath, team.micPath);
  assert.equal(h.mixCalls[0].clip.innerPath, team.innerPath);
  const unchanged = await h.repository.render(team, 1.234);
  assert.equal(unchanged.path, first.path); assert.equal(h.mixCalls.length, 1);
  const muted = await h.repository.render(team, 0);
  assert.equal(muted.renderedGain, 0);
  assert.equal(h.mixCalls[1].clip.sourcePath, team.sourcePath);
  assert.equal(h.environment.files.has(first.path), false, 'A successful newer gain render removes the superseded derived MP4');
  for (const [path, bytes] of immutable) assert.deepEqual(h.environment.files.get(path), bytes, 'Gain renders must never overwrite source stems');
  await h.repository.saveToAlbum(team, {});
  assert.deepEqual(h.environment.files.get('content://album/video'), h.environment.files.get(muted.path),
    'Saving a stale UI clip reads the latest indexed render');
  const attempt = await h.share.share(team, {});
  assert.equal(h.controllers.at(-1).data.data.uri, `file://${muted.path}`, 'System share reads the latest render rather than a stale UI path');
  await assert.rejects(h.repository.render(team, 1), /请先完成或取消这次分享/);
  assert.equal(h.mixCalls.length, 2, 'Pending publication freezes its exact shared render');
  await h.share.dismissPending(attempt.id);
  await assert.rejects(h.repository.render(team, NaN), /麦克风音量无效/);
  await h.repository.remove(team.id);
  assert.equal(h.repository.count('team'), 0);
  for (const path of [...immutable.keys(), muted.path, team.path]) assert.equal(h.environment.files.has(path), false);
  assert.equal(h.environment.files.has(legacy.path), true, 'Deleting one work preserves unrelated works');
}

async function testRenderedRecovery() {
  const h = services(); await h.initialize();
  const original = await addStemClip(h);
  h.environment.failRenames.add('/app/files/recordings/library-v1.json');
  await assert.rejects(h.repository.render(original, 0.5), /声音处理未完成/);
  assert.equal(h.repository.get(original.id).path, original.path);
  const render = h.mixCalls[0].output;
  assert.equal(h.environment.files.has(`${render}.recovery.json`), true);
  assert.equal(h.environment.files.has(original.sourcePath), true);
  h.environment.failRenames.delete('/app/files/recordings/library-v1.json');
  const restart = services(h.environment); await restart.initialize();
  assert.equal(restart.repository.get(original.id).path, render, 'A newer gain recovery note supersedes the old indexed render after a failed index commit');
  assert.equal(restart.repository.get(original.id).renderedGain, 0.5);
  assert.equal(h.environment.files.has(`${render}.recovery.json`), false);
  await restart.repository.remove(original.id);
  for (const path of [original.path, original.sourcePath, original.micPath, original.innerPath, render]) {
    assert.equal(h.environment.files.has(path), false);
  }
}

function backgroundHarness({ avFailures = 0 } = {}) {
  const trace = [];
  let remainingFailures = avFailures, createCount = 0, updateFailures = 0;
  const keeper = load('session/SessionBackgroundKeeper.ets', {
    '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => 'agent',
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      async startBackgroundRunning(_context, modes) { trace.push({ action: 'start', modes: [...modes] }); },
      async updateBackgroundRunning(_context, modes) {
        if (updateFailures-- > 0) throw new Error('simulated background mode update failure');
        trace.push({ action: 'update', modes: [...modes] });
      },
      async stopBackgroundRunning() { trace.push({ action: 'stop' }); }
    } },
    '@kit.AVSessionKit': { avSession: {
      PlaybackState: { PLAYBACK_STATE_PLAY: 1, PLAYBACK_STATE_PAUSE: 2 },
      async createAVSession() {
        createCount++;
        if (remainingFailures-- > 0) throw new Error('simulated optional media card failure');
        return { on() {}, async setAVMetadata() {}, async activate() {}, async deactivate() {},
          async setAVPlaybackState() {}, async destroy() {} };
      }
    } },
    '@kit.BasicServicesKit': { runningLock: { isSupported: () => false, RunningLockType: { BACKGROUND: 1 } } }
  }, { console: { warn() {} }, setInterval: () => 1, clearInterval() {} }).SessionBackgroundKeeper;
  keeper.initialize({});
  return { keeper, trace, createCount: () => createCount, failUpdate(count) { updateFailures = count; } };
}

async function testBackgroundOwners() {
  const h = backgroundHarness();
  await h.keeper.start(true);
  await h.keeper.setRecordingActive(true);
  await h.keeper.setRecordingActive(false);
  assert.deepEqual(h.trace, [
    { action: 'start', modes: ['audioPlayback', 'multiDeviceConnection'] },
    { action: 'update', modes: ['audioPlayback', 'multiDeviceConnection', 'audioRecording'] },
    { action: 'update', modes: ['audioPlayback', 'multiDeviceConnection'] }
  ]);
  await h.keeper.stop();
  assert.equal(h.trace.at(-1).action, 'stop', 'Only removing the final owner stops the native task');

  const reverse = backgroundHarness();
  await reverse.keeper.setRecordingActive(true);
  await reverse.keeper.start(false);
  await reverse.keeper.stop();
  assert.deepEqual(reverse.trace.at(-1), { action: 'update', modes: ['audioRecording'] });
  assert.equal(reverse.trace.filter(item => item.action === 'stop').length, 0);
  await reverse.keeper.setRecordingActive(false);
  assert.equal(reverse.trace.at(-1).action, 'stop');

  const concurrent = backgroundHarness();
  await Promise.all([concurrent.keeper.start(true), concurrent.keeper.setRecordingActive(true),
    concurrent.keeper.setRecordingActive(false), concurrent.keeper.stop()]);
  assert.deepEqual(concurrent.trace.map(item => item.action), ['start', 'update', 'update', 'stop']);

  const mediaFailure = backgroundHarness({ avFailures: 1 });
  await mediaFailure.keeper.start(true);
  await mediaFailure.keeper.setRecordingActive(true);
  assert.deepEqual(mediaFailure.trace.at(-1), {
    action: 'update', modes: ['audioPlayback', 'multiDeviceConnection', 'audioRecording']
  }, 'Optional AVSession failure cannot release the already-started team background owner');
  await mediaFailure.keeper.start(true);
  assert.equal(mediaFailure.createCount(), 2, 'The optional media card can be retried without creating another task');
  assert.equal(mediaFailure.trace.filter(item => item.action === 'start').length, 1);
  await mediaFailure.keeper.setRecordingActive(false);
  assert.deepEqual(mediaFailure.trace.at(-1).modes, ['audioPlayback', 'multiDeviceConnection']);
  await mediaFailure.keeper.stop();
  assert.equal(mediaFailure.trace.at(-1).action, 'stop');

  const failedUpdate = backgroundHarness();
  await failedUpdate.keeper.start(true);
  failedUpdate.failUpdate(1);
  await assert.rejects(failedUpdate.keeper.setRecordingActive(true), /simulated background mode/);
  await failedUpdate.keeper.setRecordingActive(true);
  assert.deepEqual(failedUpdate.trace.at(-1).modes, ['audioPlayback', 'multiDeviceConnection', 'audioRecording'],
    'A rejected recording mode update must not poison the serial queue or claim ownership');
}

function testLobbyToast() {
  const source = fs.readFileSync(path.join(root, 'pages/LeaderLobbyPage.ets'), 'utf8');
  function between(start, end) {
    const first = source.indexOf(start), last = source.indexOf(end, first);
    assert.ok(first >= 0 && last > first); return source.slice(first, last);
  }
  const business = (source.slice(0, source.indexOf('  @Builder')) +
    between('  private refreshDrumAccess(): void {', '  private async initialize(): Promise<void> {') +
    between('  private editDrumMachine(): void {', '  private async switchToBasicBeat(): Promise<void> {') +
    between('  onBackPress(): boolean {', '  onPageShow(): void {') + '\n}')
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace('struct LeaderLobbyPage', 'export class LeaderLobbyPage');
  const result = ts.transpileModule(business, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  let access = { allowed: false, source: 'locked', expiresAt: 0 };
  const routes = [], animations = [];
  const history = [{ dayKey: '2026-10-18', streakOrdinal: 3, rewardGranted: true }];
  const context = { exports: {}, Scroller: class {}, Map,
    resolveDrumAccess: () => access, isProDrumMachineAccessible: () => access.allowed,
    formatTrialExpiry: () => '10/19 20:00',
    getShareCheckInSummary: () => ({ streakDays: 3, todayCompleted: true, history }),
    router: { pushUrl: value => routes.push(value.url) },
    Curve: { EaseOut: 'ease-out' }, animateTo: (options, action) => { animations.push(options); action(); } };
  vm.runInNewContext(result.outputText, context);
  const page = new context.exports.LeaderLobbyPage();
  page.editDrumMachine();
  assert.equal(page.proDrumToastVisible, true);
  assert.equal(page.proDrumEntryScale, 1);
  assert.equal(animations.length, 1);
  assert.deepEqual(routes, [], 'A locked entry bounces into its toast without navigating to a new activity page');
  assert.equal(page.onBackPress(), true);
  assert.equal(page.proDrumToastVisible, false);
  access = { allowed: true, source: 'trial', expiresAt: 10000 };
  page.showProDrumAccessToast();
  assert.equal(page.proDrumToastVisible, true, 'An unlocked status label can still inspect records and rules');
  assert.equal(page.drumAccessLabel(), '试用中 · 截止 10/19 20:00');
  page.proDrumToastVisible = false;
  page.editDrumMachine();
  assert.deepEqual(routes, ['pages/DrumMachinePage'], 'The unlocked title/arrow retains direct editor entry');
  access = { allowed: true, source: 'monthly', expiresAt: 10000 };
  page.showProDrumAccessToast();
  assert.equal(page.drumAccessLabel(), '月卡已解锁');
  const entryBuilder = between('  private proDrumMachineEntryWithChain(', '  @Builder\n  private proDrumMachineEntry()');
  assert.match(entryBuilder, /Text\(this\.drumAccessLabel\(\)\)[\s\S]*?\.onClick\(\(\) => this\.showProDrumAccessToast\(\)\)/);
  assert.doesNotMatch(entryBuilder, /stopPropagation/, 'ArkUI handlers must not depend on a DOM-only event API');
  const toast = between('  private proDrumAccessToast() {', '  @Builder\n  private scenePreview(');
  assert.match(toast, /ShareCalendarSheet\(\{/);
  const calendar = fs.readFileSync(path.join(root, 'components/ShareCalendarSheet.ets'), 'utf8');
  assert.match(calendar, /Text\('打卡记录'\)/); assert.match(calendar, /Text\('玩法说明'\)/);
  assert.match(calendar, /ForEach\(this\.cells/);
  assert.match(calendar, /columnsTemplate\('1fr 1fr 1fr 1fr 1fr 1fr 1fr'\)/);
  assert.doesNotMatch(toast, /pages\/ShareCheckInPage/, 'Records and rules remain inside the toast');
}

function testSharedCalendar() {
  const source = fs.readFileSync(path.join(root, 'components/ShareCalendarSheet.ets'), 'utf8');
  const business = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@Component\b\s*/g, '').replace(/@(?:Prop|State)\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace('export struct ShareCalendarSheet', 'export class ShareCalendarSheet');
  const result = ts.transpileModule(business, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  let now = Date.parse('2026-10-18T12:00:00+08:00');
  class CalendarDate extends Date { static now() { return now; } }
  const history = [{ dayKey: '2026-10-18', streakOrdinal: 3, shareCount: 2, rewardGranted: true, trialExpiresAt: 1000 }];
  const context = { exports: {}, Date: CalendarDate, Map,
    getShareCheckInSummary: () => ({ history, streakDays: 3, todayCompleted: true, ready: true, clockBlocked: false }),
    resolveDrumAccess: () => ({ source: 'trial', expiresAt: 1000 }), formatTrialExpiry: () => '10/19 20:00' };
  vm.runInNewContext(result.outputText, context);
  const calendar = new context.exports.ShareCalendarSheet();
  calendar.scope = 'team'; calendar.aboutToAppear();
  assert.equal(calendar.selectedDayKey, '2026-10-18');
  assert.equal(calendar.monthTitle, '2026 年 10 月');
  assert.equal(calendar.cells.length, 35);
  assert.equal(calendar.cells[3].day, 1, 'Monday-first October 2026 places Thursday 1 in column four');
  assert.equal(calendar.cells.find(cell => cell.day === 18).rewarded, true);
  assert.match(calendar.selectedDetail(), /分享 2 次\n已领 24h/);
  assert.equal(calendar.history.length, 1, 'Work scope never filters the install-wide reward ledger');
  calendar.moveMonth(-1); assert.equal(calendar.monthTitle, '2026 年 9 月');
  calendar.moveMonth(1); calendar.moveMonth(1);
  assert.equal(calendar.monthOffset, 0, 'Month navigation cannot advance beyond the current month');
  now = Date.parse('2028-02-29T12:00:00+08:00'); calendar.refresh();
  assert.equal(calendar.cells.filter(cell => cell.day > 0).length, 29, 'The calendar includes leap-day records');
  now = Date.parse('2026-10-18T15:59:59Z'); assert.equal(calendar.todayKey(), '2026-10-18');
  now = Date.parse('2026-10-18T16:00:00Z'); assert.equal(calendar.todayKey(), '2026-10-19', 'Day boundaries use Beijing rather than device timezone');
}

(async () => {
  await testExplicitShareConfirmation(); await testShareCrashReplay(); await testLibraryRecovery();
  await testLargeSnapshotsAndAtomicWrites(); await testWorkScopeAndNonDestructiveGain(); await testRenderedRecovery();
  await testBackgroundOwners(); testLobbyToast(); testSharedCalendar();
  console.log('PASS recording share/storage: explicit publication only, durable pending and crash replay, failed-index MP4 recovery, album copy and background owner union/optional media card failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
