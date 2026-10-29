const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const testSharedCalendar = require('./share-calendar.cjs');

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
  const failRenames = new Set(), failUnlinks = new Set();
  const failCopies = new Set(), failCloses = new Set(), failOpens = new Set();
  const descriptors = new Map();
  let nextFd = 1, nextUuid = 1;
  let chunkSize = Number.MAX_SAFE_INTEGER;
  const fileIo = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4, READ_WRITE: 8 },
    async access(name) { return files.has(name) || directories.has(name); },
    async mkdir(name) { directories.add(name); },
    async listFile(name) { return [...files.keys()].filter(file => file.startsWith(`${name}/`) &&
      !file.substring(name.length + 1).includes('/')).map(file => file.substring(name.length + 1)); },
    async stat(name) {
      if (typeof name === 'number') name = descriptors.get(name).name;
      assert.ok(files.has(name), `Missing virtual file ${name}`);
      return { size: files.get(name).length, isFile: () => true };
    },
    async readText(name) { assert.ok(files.has(name)); return files.get(name).toString('utf8'); },
    async open(name, mode) {
      if (failOpens.has(name)) throw new Error(`simulated open failure: ${name}`);
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
    async close(file) {
      const fd = typeof file === 'number' ? file : file.fd;
      const name = descriptors.get(fd)?.name;
      descriptors.delete(fd);
      if (failCloses.has(name)) throw new Error(`simulated close failure: ${name}`);
    },
    async rename(from, to) {
      if (failRenames.has(to)) throw new Error(`simulated atomic rename failure: ${to}`);
      assert.ok(files.has(from)); files.set(to, files.get(from)); files.delete(from); trace.push(`rename:${to}`);
    },
    async unlink(name) {
      if (failUnlinks.has(name)) throw new Error(`simulated unlink failure: ${name}`);
      assert.ok(files.has(name)); files.delete(name); trace.push(`unlink:${name}`);
    },
    async copyFile(from, to) {
      const sourceName = typeof from === 'number' ? descriptors.get(from).name : from;
      const targetName = typeof to === 'number' ? descriptors.get(to).name : to;
      if (failCopies.has(targetName)) throw new Error(`simulated copy failure: ${targetName}`);
      files.set(targetName, Buffer.from(files.get(sourceName)));
    }
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
    uniformTypeDescriptor: { UniformDataType: { VIDEO: 'video' },
      getUniformDataTypeByFilenameExtension(extension, fallback) {
        assert.equal(extension, '.mp4'); assert.equal(fallback, 'video');
        return 'video.mp4';
      } }
  };
  return { durable, files, failNames, failRenames, failUnlinks, failCopies, failCloses, failOpens, trace, fileIo, arkData,
    openDescriptorCount: () => descriptors.size,
    chunks(size) { chunkSize = size; },
    coreFile: { fileIo, fileUri: { getUriFromPath: value => `file://${value}` } },
    arkTs: { util: { generateRandomUUID: () => `test-uuid-${nextUuid++}`,
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } } };
}

async function testCoverExtraction() {
  const environment = durableEnvironment();
  const calls = [];
  const pixelMap = { async release() { calls.push('release-pixel'); } };
  const service = load('recording/RecordingCoverService.ets', {
    '@kit.CoreFileKit': environment.coreFile,
    '@kit.MediaKit': { media: {
      AVImageQueryOptions: { AV_IMAGE_QUERY_NEXT_SYNC: 'next-sync' },
      async createAVImageGenerator() {
        return {
          fdSrc: undefined,
          async fetchFrameByTime(timeUs, option, params) {
            calls.push({ action: 'fetch', timeUs, option, params: plain(params), source: plain(this.fdSrc) });
            return pixelMap;
          },
          async release() { calls.push('release-generator'); }
        };
      }
    } },
    '@kit.ImageKit': { image: {
      createImagePacker() {
        return {
          async packToFile(source, fd, options) {
            assert.equal(source, pixelMap);
            calls.push({ action: 'pack', options: plain(options) });
            await environment.fileIo.write(fd, Buffer.from('jpeg-first-frame'));
          },
          async release() { calls.push('release-packer'); }
        };
      }
    } }
  }).RecordingCoverService;
  const videoPath = '/app/files/recordings/cover-source.mp4';
  const coverPath = '/app/files/recordings/cover-source.cover-v1.jpg';
  environment.files.set(videoPath, Buffer.from('synthetic-h264-video'));
  await service.generate(videoPath, coverPath, 1080, 2340);
  const fetch = calls.find(item => item.action === 'fetch');
  assert.deepEqual(fetch.params, { width: 1080, height: 2340 });
  assert.deepEqual(calls.find(item => item.action === 'pack').options, { format: 'image/jpeg', quality: 95 });
  assert.equal(fetch.timeUs, 0); assert.equal(fetch.option, 'next-sync');
  assert.equal(environment.files.get(coverPath).toString(), 'jpeg-first-frame');
  assert.deepEqual(calls.filter(item => typeof item === 'string'),
    ['release-packer', 'release-pixel', 'release-generator']);
  await service.generate(videoPath, coverPath, 1080, 2340);
  assert.equal(calls.filter(item => item.action === 'fetch').length, 1,
    'An existing durable cover must not decode the video again');
}

function services(environment = durableEnvironment()) {
  const storage = new Map(), ledgerCalls = [], controllers = [], mixCalls = [], coverCalls = [], thumbnailCalls = [];
  const album = { destinations: ['content://album/video'], dialogError: undefined, releaseError: undefined,
    dialogs: [], releases: 0 };
  const mediaLibraryKit = { photoAccessHelper: {
    PhotoType: { VIDEO: 'video' },
    getPhotoAccessHelper: () => ({ async showAssetsCreationDialog(uris, configs) {
      album.dialogs.push({ uris: plain(uris), configs: plain(configs) });
      if (album.dialogError) throw album.dialogError;
      return [...album.destinations];
    }, async release() {
      album.releases++;
      if (album.releaseError) throw album.releaseError;
    } }) } };
  let now = environment.now ?? Date.now(), mono = 1000;
  environment.now = now;
  class ShareDate extends Date { static now() { return now; } }
  const globals = { Date: ShareDate, AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    setInterval: () => 1, console: { warn() {} } };
  const atomic = load('common/AtomicTextFile.ets', {
    '@kit.CoreFileKit': environment.coreFile, '@kit.ArkTS': environment.arkTs
  }, globals);
  const rules = load('store/ShareCheckInRules.ets', {}, globals);
  const ledger = load('store/ShareCheckInStore.ets', {
    '@kit.ArkData': environment.arkData,
    '../common/AtomicTextFile': atomic,
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => mono } },
    './EntitlementStore': { isMonthlyPassActive: () => false,
      isMonthlyPassRewardStateKnown: () => true, waitForMonthlyPassCache: async () => {} },
    './ShareCheckInRules': rules
  }, globals);
  const repository = load('recording/RecordingRepository.ets', {
    'libonebeat_recording.so': { chmod() {} },
    '@kit.ArkData': environment.arkData, '@kit.CoreFileKit': environment.coreFile,
    '../common/AtomicTextFile': atomic,
    '@kit.ArkTS': environment.arkTs,
    './RecordingCoverService': { RecordingCoverService: { async generate(videoPath, coverPath, width, height) {
      coverCalls.push({ videoPath, coverPath, width, height });
      environment.files.set(coverPath, Buffer.from(`cover-of=${videoPath}`));
    } } },
    './RecordingMixer': { RECORDING_MIX_VERSION: 6, MAX_MIC_SHIFT_US: 300000,
      RecordingMixer: {
      mixVersion: clip => clip.micCaptureMode === 'system-aec' ? 8 : 6,
      processedMicPath: (micPath, mode) => mode === 'system-aec' ? `${micPath}.system-aec-v3.f32` : `${micPath}.clean-v3.f32`,
      async exportMixed(clip, gain, output, micShiftUs) {
      mixCalls.push({ clip: plain(clip), gain, output, micShiftUs });
      environment.files.set(output, Buffer.from(
        `rendered-gain=${gain};shift=${micShiftUs};source=${clip.sourcePath}`));
      return {
        autoMicShiftUs: clip.micCaptureMode === 'system-aec' ? 0 : clip.autoMicShiftUs ?? -1000,
        autoMicShiftConfidence: clip.micCaptureMode === 'system-aec' ? 0 : clip.autoMicShiftConfidence ?? .8,
        autoMicShiftReliable: clip.micCaptureMode === 'system-aec' ? false : clip.autoMicShiftReliable ?? true
      };
    } } },
    '@kit.MediaLibraryKit': mediaLibraryKit
  }, globals).RecordingRepository;
  let showGate, showFailure = false, completionSupported = true;
  const shareDeviceInfo = { sdkApiVersion: 20 };
  class ShareController {
    constructor(data) { this.data = data; controllers.push(this); }
    callbacks = new Map();
    on(event, callback) {
      if (event === 'shareCompleted' && !completionSupported) throw new Error('unsupported event');
      this.callbacks.set(event, callback);
    }
    complete(name = 'com.test.shareReceiver') { this.callbacks.get('shareCompleted')?.({ targetAbilityInfo: { name } }); }
    dismiss() { this.callbacks.get('dismiss')?.(); }
    async show() { if (showGate) await showGate; if (showFailure) throw new Error('simulated platform share failure'); }
  }
  const share = load('sharing/RecordingShareService.ets', {
    '@kit.BasicServicesKit': { deviceInfo: shareDeviceInfo },
    '@kit.ArkData': environment.arkData, '@kit.CoreFileKit': environment.coreFile, '@kit.ArkTS': environment.arkTs,
    '@kit.MediaLibraryKit': mediaLibraryKit,
    '@kit.MediaKit': { media: {
      AVImageQueryOptions: { AV_IMAGE_QUERY_NEXT_SYNC: 'next-sync' },
      async createAVImageGenerator() {
        return { fdSrc: undefined,
          async fetchFrameByTime(timeUs, option, params) {
            assert.equal(timeUs, 0); assert.equal(option, 'next-sync');
            thumbnailCalls.push({ params: plain(params), source: plain(this.fdSrc) });
            return { async release() { environment.trace.push('share-thumbnail-pixel-release'); } };
          },
          async release() { environment.trace.push('share-thumbnail-generator-release'); } };
      }
    } },
    '@kit.ImageKit': { image: { createImagePacker() {
      return { async packing(_pixelMap, options) {
        assert.deepEqual(plain(options), { format: 'image/jpeg', quality: 80 });
        return new TextEncoder().encode('share-thumbnail-jpeg').buffer;
      }, async release() { environment.trace.push('share-thumbnail-packer-release'); } };
    } } },
    '@kit.ShareKit': { systemShare: { SharedData: class { constructor(data) { this.data = data; } }, ShareController,
      SharePreviewMode: { DETAIL: 1 }, SelectionMode: { SINGLE: 1 } } },
    '../recording/RecordingRepository': { RecordingRepository: repository },
    '../common/AtomicTextFile': atomic,
    '../store/ShareCheckInStore': {
      initializeShareCheckInStore: context => ledger.initializeShareCheckInStore(context),
      getShareCheckInSummary: () => ledger.getShareCheckInSummary(),
      getShareCheckInTodayKey: () => ledger.getShareCheckInTodayKey(),
      async acceptShareCheckIn(id) { ledgerCalls.push(id); return ledger.acceptShareCheckIn(id); } }
  }, globals).RecordingShareService;
  async function initialize() {
    await repository.initialize({ filesDir: '/app/files' });
    await share.initialize({ filesDir: '/app/files' });
    await ledger.initializeShareCheckInStore({ filesDir: '/app/files' });
  }
  async function clip(extra = {}) {
    const target = await repository.createTarget();
    environment.files.set(target.path, Buffer.from('synthetic-completed-mp4'));
    const entry = { ...target, durationMs: 3000, width: 720, height: 1280, interrupted: false, stopReason: 'user', ...extra };
    await repository.add(entry);
    return repository.get(entry.id);
  }
  return { environment, storage, ledger, repository, share, ledgerCalls, controllers, mixCalls, coverCalls, thumbnailCalls, album,
    initialize, clip, atomic,
    gate(value) { showGate = value; }, failShow(value) { showFailure = value; },
    supportCompletion(value) { completionSupported = value; },
    setSdkApiVersion(value) { shareDeviceInfo.sdkApiVersion = value; },
    async handOff(controller = controllers.at(-1), name) { controller.complete(name); await flush(); },
    setNow(value) { mono += Math.max(0, value - now); now = value; environment.now = value; } };
}

async function testExplicitShareConfirmation() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const another = await h.clip();
  const gate = deferred(); h.gate(gate.promise);
  const opening = h.share.share(clip, {}, 'wechat'); await flush();
  assert.equal(h.share.getPending().handedOff, false);
  assert.equal(h.share.getPendingForClipToday(clip.id), undefined);
  assert.equal(h.ledgerCalls.length, 0);
  await assert.rejects(h.share.confirmPublished(h.share.getPending().id), /没有待确认/);
  await assert.rejects(h.share.share(clip, {}), /分享正在处理中/);
  gate.resolve(); h.gate(undefined);
  const attempt = await opening;
  assert.equal(attempt.handedOff, false, 'Showing a chooser is not a target selection');
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, false);
  const sharedUri = h.controllers.at(-1).data.data.uri;
  assert.equal(sharedUri, 'content://album/video', 'A receiver gets the authorized media-library URI');
  assert.equal(h.repository.get(clip.id).albumUri, sharedUri, 'The authorized gallery destination is retained for this exact render');
  assert.equal(h.controllers.at(-1).data.data.utd, 'video.mp4');
  assert.equal(Buffer.from(h.controllers.at(-1).data.data.thumbnail).toString(), 'share-thumbnail-jpeg');
  assert.deepEqual(h.thumbnailCalls[0].params, { width: 270, height: 480 }, 'Share thumbnails preserve the source aspect ratio');
  assert.deepEqual(h.environment.trace.filter(value => value.startsWith('share-thumbnail-')),
    ['share-thumbnail-pixel-release', 'share-thumbnail-packer-release', 'share-thumbnail-generator-release']);
  assert.deepEqual(h.album.dialogs[0].uris, [`file://${attempt.sharedPath}`], 'Gallery export copies the immutable attempt snapshot');
  assert.deepEqual(h.environment.files.get(sharedUri), h.environment.files.get(attempt.sharedPath));
  assert.deepEqual(h.environment.files.get(attempt.sharedPath), h.environment.files.get(clip.path));
  assert.equal(h.environment.openDescriptorCount(), 0, 'Share thumbnail and gallery copy release all opened descriptors before showing the chooser');
  h.controllers.at(-1).dismiss(); await flush();
  assert.equal(h.share.getPendingListToday().length, 0, 'Closing without selecting a target never creates a todo');
  await h.handOff(h.controllers[0]);
  assert.equal(h.share.getPendingForClipToday(clip.id).id, attempt.id,
    'A completion arriving after dismiss still records the actual handoff');
  const second = await h.share.share(another, {}, 'rednote'); await h.handOff();
  const dialogCount = h.album.dialogs.length;
  const third = await h.share.share(clip, {}, 'qq'); await h.handOff();
  assert.equal(h.album.dialogs.length, dialogCount, 'Sharing an unchanged saved render reuses its gallery URI without another save dialog');
  assert.equal(h.share.getPendingListToday().length, 3, 'Multiple works and repeated attempts never lock each other');
  assert.equal(h.share.getPendingForClipToday(clip.id).id, third.id);
  const confirmation = await h.share.confirmPublished(second.id);
  assert.equal(confirmation.streakDays, 1);
  assert.equal(h.ledgerCalls.length, 1);
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, true);
  assert.equal(h.share.getPendingForClipToday(clip.id), undefined);
  assert.equal(h.share.getPendingListToday().length, 0, 'One confirmed work hides todos on every work today');
  for (const pending of [attempt, second, third]) {
    assert.equal(h.environment.files.has(pending.sharedPath), false, 'Confirmation releases every now-hidden share copy from the accepted day');
  }
  assert.equal(h.share.getPending(), undefined);
  await assert.rejects(h.share.confirmPublished(second.id), /没有待确认/);
  const sameDay = await h.share.share(clip, {}, 'moments'); await h.handOff();
  assert.equal(h.share.getPending(), undefined, 'Another successful handoff after checking in is immediately retired');
  assert.equal(h.environment.files.has(sameDay.sharedPath), false);
  assert.equal(h.ledger.getShareCheckInSummary().history[0].shareCount, 1);
  assert.equal(h.ledger.getShareCheckInSummary().history.length, 1);
  const filesBeforeFailure = new Set(h.environment.files.keys());
  h.failShow(true);
  await assert.rejects(h.share.share(clip, {}, 'weibo'), /未能打开系统分享面板/);
  assert.equal(h.ledgerCalls.length, 1);
  assert.deepEqual(new Set([...h.environment.files.keys()].filter(path => path.includes('.share-'))),
    new Set([...filesBeforeFailure].filter(path => path.includes('.share-'))), 'A failed chooser cleans its private video snapshot');
  const before = h.ledger.getShareCheckInSummary().history.length;
  await h.share.dismissForClip(clip.id);
  assert.equal(h.environment.files.has(attempt.sharedPath), false);
  assert.equal(h.environment.files.has(third.sharedPath), false);
  assert.equal(h.ledger.getShareCheckInSummary().history.length, before, 'Deleting a work cannot erase historical check-ins');
  const coverPath = clip.coverPath;
  assert.ok(coverPath && h.environment.files.has(coverPath));
  await h.repository.remove(clip.id);
  assert.equal(h.environment.files.has(clip.path), false);
  assert.equal(h.environment.files.has(coverPath), false);
}

async function testSystemOperationsAndCrossDay() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const attempt = await h.share.share(clip, {});
  await h.handOff(undefined, 'SystemShare_SaveToMediaAsset');
  assert.equal(h.share.getPendingListToday().length, 0, 'Saving/copying in the system action row cannot create a share todo');
  h.controllers.at(-1).dismiss(); await flush();
  const restart = services(h.environment); await restart.initialize();
  assert.equal(restart.share.getPending(), undefined, 'Unhanded chooser records are not restored as selected targets');
  assert.equal(h.environment.files.has(attempt.sharedPath), false, 'Abandoned chooser copies are cleaned on startup');
  const old = await restart.share.share(clip, {}); await restart.handOff();
  restart.setNow(Date.now() + 2 * 86400000);
  assert.equal(restart.share.getPendingForClipToday(clip.id), undefined);
  await assert.rejects(restart.share.confirmPublished(old.id), /不是今天/);
  assert.equal(restart.ledger.getShareCheckInSummary().todayCompleted, false,
    "Yesterday's unconfirmed handoff cannot become today's check-in");
  const fresh = await restart.share.share(clip, {}); await restart.handOff();
  assert.equal(restart.share.getPendingForClipToday(clip.id).id, fresh.id);
  await restart.share.confirmPublished(fresh.id);
  assert.equal(restart.ledger.getShareCheckInSummary().history.length, 1);

  const migrationEnvironment = durableEnvironment();
  const setup = services(migrationEnvironment); await setup.initialize();
  const legacyClip = await setup.clip();
  migrationEnvironment.files.delete('/app/files/video-share-pending-v2.json');
  migrationEnvironment.durable.set('onebeat_video_share:pendingVideoShareV1', JSON.stringify({
    id: 'legacy-share-attempt', clipId: legacyClip.id, createdAt: Date.now(), handedOff: true
  }));
  const migrated = services(migrationEnvironment); await migrated.initialize();
  assert.equal(migrated.share.getPendingForClipToday(legacyClip.id), undefined,
    'An old chooser-open flag cannot be migrated into proof that a target was selected');
}

async function testShareCrashReplay() {
  const first = services(); await first.initialize();
  const clip = await first.clip();
  const pending = await first.share.share(clip, {}); await first.handOff();
  const second = await first.share.share(clip, {}); await first.handOff();
  const sourceBytes = Buffer.from(first.environment.files.get(clip.path));
  first.environment.failRenames.add('/app/files/video-share-pending-v2.json');
  const accepted = await first.share.confirmPublished(pending.id);
  assert.equal(accepted.streakDays, 1, 'A durable check-in stays successful even if pending cleanup fails');
  assert.equal(first.ledger.getShareCheckInSummary().history[0].shareCount, 1);
  assert.equal(first.share.getPendingListToday().length, 0);
  assert.equal(first.share.getPending().id, second.id, 'Failed cleanup keeps its durable records available for restart cleanup');
  const retry = await first.share.confirmPublished(pending.id);
  assert.equal(retry.alreadyProcessed, true, 'An interrupted cleanup retry is idempotent');
  assert.equal(first.ledger.getShareCheckInSummary().history[0].shareCount, 1);
  const failedCleanupRestart = services(first.environment); await failedCleanupRestart.initialize();
  assert.equal(failedCleanupRestart.share.getPendingListToday().length, 0,
    'Repeated cleanup failure on startup cannot turn an already recorded day back into an unfinished todo');
  assert.equal(failedCleanupRestart.ledger.getShareCheckInSummary().todayCompleted, true);
  first.environment.failRenames.delete('/app/files/video-share-pending-v2.json');
  const restart = services(first.environment); await restart.initialize();
  assert.equal(restart.share.getPending(), undefined, 'Startup removes every pending record hidden by an already committed check-in');
  assert.equal(first.environment.files.has(pending.sharedPath), false);
  assert.equal(first.environment.files.has(second.sharedPath), false);
  assert.deepEqual(first.environment.files.get(clip.path), sourceBytes, 'Deferred share cleanup never modifies the source recording');
  assert.equal(restart.ledger.getShareCheckInSummary().history[0].shareCount, 1);
  const replay = await restart.ledger.acceptShareCheckIn(pending.id);
  assert.equal(replay.alreadyProcessed, true);
}

async function testOldSystemSelfReport() {
  const h = services(); await h.initialize(); h.supportCompletion(false);
  const clip = await h.clip();
  const attempt = await h.share.share(clip, {}, 'wechat');
  assert.equal(h.share.getPendingForClipToday(clip.id), undefined,
    'The old-system chooser has to return before a self-report todo becomes eligible');
  await h.share.markReturnedToApp();
  const eligible = h.share.getPendingForClipToday(clip.id);
  assert.equal(eligible.id, attempt.id);
  assert.equal(eligible.verification, 'self_report');
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, false,
    'Returning to oneBeat never automatically checks in or rewards a trial');
  await h.share.confirmPublished(eligible.id);
  assert.equal(h.ledger.getShareCheckInSummary().todayCompleted, true);

  const silentOld = services(); await silentOld.initialize(); silentOld.setSdkApiVersion(12);
  const oldClip = await silentOld.clip();
  await silentOld.share.share(oldClip, {});
  assert.equal(silentOld.controllers.at(-1).callbacks.has('shareCompleted'), false,
    'Pre-18 devices must skip event registration even when an unknown event would be silently accepted');
  await silentOld.share.markReturnedToApp();
  assert.equal(silentOld.share.getPendingForClipToday(oldClip.id).verification, 'self_report');
  assert.equal(silentOld.ledger.getShareCheckInSummary().todayCompleted, false);

  const modern = services(); await modern.initialize();
  const modernClip = await modern.clip();
  await modern.share.share(modernClip, {});
  modern.controllers.at(-1).dismiss(); await flush();
  await modern.share.markReturnedToApp();
  assert.equal(modern.share.getPendingForClipToday(modernClip.id), undefined,
    'Explicit return cannot bypass an available target callback on modern systems');
}

async function testShareCopyCleanup() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const originalBytes = Buffer.from(h.environment.files.get(clip.path));
  const expired = await h.share.share(clip, {}); await h.handOff();
  h.setNow(h.environment.now + 2 * 86400000);
  const restart = services(h.environment); await restart.initialize();
  assert.equal(restart.share.getPending(), undefined, 'Expired pending records cannot stay hidden forever');
  assert.equal(h.environment.files.has(expired.sharedPath), false);
  assert.equal(restart.ledger.getShareCheckInSummary().history.length, 0, 'Expiring an unconfirmed share cannot create a check-in');
  assert.deepEqual(h.environment.files.get(clip.path), originalBytes);

  const pending = await restart.share.share(clip, {}); await restart.handOff();
  h.environment.failUnlinks.add(pending.sharedPath);
  const accepted = await restart.share.confirmPublished(pending.id);
  assert.equal(accepted.streakDays, 1);
  assert.equal(restart.share.getPending(), undefined);
  assert.equal(h.environment.files.has(pending.sharedPath), true, 'A failed unlink may leave a private orphan after metadata cleanup');
  h.environment.failUnlinks.delete(pending.sharedPath);
  const final = services(h.environment); await final.initialize();
  assert.equal(h.environment.files.has(pending.sharedPath), false, 'Startup safely sweeps unreferenced private share snapshots');
  assert.deepEqual(h.environment.files.get(clip.path), originalBytes, 'Orphan cleanup never unlinks the source recording');
  assert.equal(final.ledger.getShareCheckInSummary().history.length, 1);
}

async function testSharePathBoundary() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const originalGet = h.repository.get;
  const externalPath = '/app/outside.mp4';
  h.environment.files.set(externalPath, Buffer.from('unrelated-private-file'));
  const before = new Map(h.environment.files);
  for (const maliciousId of ['../outside', 'bad/id', 'x'.repeat(129)]) {
    const invalid = { ...clip, id: maliciousId };
    h.repository.get = id => id === maliciousId ? invalid : originalGet(id);
    await assert.rejects(h.share.share(invalid, {}), /分享记录无效/);
    assert.deepEqual(h.environment.files, before, 'An unsafe source ID cannot copy or remove any file');
  }
  h.repository.get = originalGet;
  const attempt = await h.share.share(clip, {});
  h.controllers.at(-1).callbacks.get('shareCompleted')({}); await flush();
  assert.equal(h.share.getPendingForClipToday(clip.id), undefined, 'An incomplete platform event cannot grant handoff eligibility');
  await h.share.dismissPending(attempt.id);
  for (const unsafe of [
    { id: '../outside', clipId: clip.id },
    { id: 'normal-id', clipId: '../../outside' },
    { id: 'x'.repeat(129), clipId: clip.id }
  ]) {
    const malicious = { ...attempt, ...unsafe, handedOff: true,
      sharedPath: `/app/files/recordings/${unsafe.clipId}.share-${unsafe.id}.mp4` };
    h.environment.files.set('/app/files/video-share-pending-v2.json', Buffer.from(JSON.stringify({ version: 2, attempts: [malicious] })));
    const snapshot = new Map(h.environment.files);
    const restart = services(h.environment);
    await assert.rejects(restart.initialize(), /分享记录读取失败/);
    assert.deepEqual(h.environment.files.get(externalPath), Buffer.from('unrelated-private-file'));
    assert.deepEqual(h.environment.files, snapshot, 'Invalid restored IDs fail before writing or cleaning any share path');
  }
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
  assert.equal(h.coverCalls.length, 1, 'Cover generation precedes the recoverable library publication');
  const recoveryFsync = h.environment.trace.findIndex(entry => entry.startsWith(`fsync:${clip.path}.recovery.json.tmp-`));
  assert.ok(recoveryFsync >= 0 && recoveryFsync < h.environment.trace.indexOf(`rename:${clip.path}.recovery.json`));
  h.environment.failRenames.delete('/app/files/recordings/library-v1.json');
  const restart = services(h.environment); await restart.initialize();
  assert.deepEqual(plain(restart.repository.get(clip.id)), {
    ...clip, coverPath: `/app/files/recordings/${clip.id}.cover-v1.jpg`,
    scope: 'solo', renderedGain: 1, renderedMicShiftUs: 0, renderedAt: clip.createdAt
  },
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

async function testAlbumSaveLifecycle() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const sourceBytes = Buffer.from(h.environment.files.get(clip.path));
  assert.equal(await h.repository.saveToAlbum({ ...clip, path: '/outside/forged-ui.mp4' }, {}), true,
    'Album saving resolves the latest indexed path, never the caller-provided path');
  assert.deepEqual(h.album.dialogs[0], {
    uris: [`file://${clip.path}`], configs: [{ title: `oneBeat-${clip.id.substring(0, 8)}`,
      fileNameExtension: 'mp4', photoType: 'video' }]
  });
  assert.deepEqual(h.environment.files.get('content://album/video'), sourceBytes);
  assert.equal(h.environment.openDescriptorCount(), 0);

  h.album.destinations = [];
  const beforeCancel = new Map(h.environment.files);
  assert.equal(await h.repository.saveToAlbum(clip, {}), false, 'System cancellation returns false without reporting a save failure');
  assert.deepEqual(h.environment.files, beforeCancel);
  assert.equal(h.environment.openDescriptorCount(), 0);

  h.album.destinations = ['content://album/video'];
  h.album.dialogError = new Error('simulated album authorization failure');
  h.album.releaseError = new Error('simulated helper release failure');
  await assert.rejects(h.repository.saveToAlbum(clip, {}), /album authorization failure/,
    'Cleanup cannot mask the original authorization failure');
  assert.equal(h.environment.openDescriptorCount(), 0);
  h.album.dialogError = undefined;

  h.environment.failCopies.add('content://album/video');
  await assert.rejects(h.repository.saveToAlbum(clip, {}), /simulated copy failure/,
    'A created album destination is not success until the MP4 copy finishes');
  assert.equal(h.environment.openDescriptorCount(), 0, 'Copy failure closes both source and destination handles');
  h.environment.failCopies.clear();

  h.environment.failCloses.add(clip.path);
  h.environment.failCloses.add('content://album/video');
  assert.equal(await h.repository.saveToAlbum(clip, {}), true,
    'Source/destination close or helper release errors cannot turn a completed save into failure');
  assert.deepEqual(h.environment.files.get('content://album/video'), sourceBytes);
  assert.equal(h.environment.openDescriptorCount(), 0);
  h.environment.failCloses.clear(); h.album.releaseError = undefined;

  h.environment.failOpens.add('content://album/video');
  await assert.rejects(h.repository.saveToAlbum(clip, {}), /simulated open failure/);
  assert.equal(h.environment.openDescriptorCount(), 0, 'Destination open failure still closes the pinned source');
  h.environment.failOpens.clear();

  const realGet = h.repository.get;
  const dialogsBeforeInvalid = h.album.dialogs.length;
  h.repository.get = id => id === clip.id ? { ...clip, path: '/app/files/recordings/../outside.mp4' } : realGet(id);
  await assert.rejects(h.repository.saveToAlbum(clip, {}), /视频文件不存在/);
  h.repository.get = realGet;
  h.environment.files.set(clip.path, Buffer.alloc(0));
  await assert.rejects(h.repository.saveToAlbum(clip, {}), /视频文件无效/);
  assert.equal(h.album.dialogs.length, dialogsBeforeInvalid, 'Invalid or non-owned source paths cannot request album authorization');
  assert.equal(h.environment.openDescriptorCount(), 0);
  h.environment.files.set(clip.path, sourceBytes);
  assert.deepEqual(h.environment.files.get(clip.path), sourceBytes, 'Saving and its failures preserve the original work');
  assert.equal(h.album.releases, h.album.dialogs.length, 'Every constructed helper is released on success, cancellation and failure');
}

async function testLargeSnapshotsAndAtomicWrites() {
  const h = services(); await h.initialize();
  const clip = await h.clip();
  const attempts = [];
  for (let i = 0; i < 60; i++) {
    attempts.push(await h.share.share(clip, {})); await h.handOff();
  }
  assert.ok(h.environment.files.get('/app/files/video-share-pending-v2.json').length > 8192,
    'Multiple unfinished shares must exceed Preferences limits without blocking new shares');
  await h.share.confirmPublished(attempts[0].id);
  assert.equal(h.share.getPending(), undefined);
  assert.equal([...h.environment.files.keys()].some(name => name.includes('.share-')), false,
    'Confirming once releases every same-day hidden MP4 snapshot');
  for (let i = 1; i < 70; i++) await h.ledger.acceptShareCheckIn(`ledger-repeat-${i}`);
  assert.ok(h.environment.files.get('/app/files/share-check-in-v1.json').length > 8192,
    'Many same-day confirmations preserve consumed-attempt deduplication beyond Preferences MAX_VALUE_LENGTH');
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
  assert.equal(legacy.repository.get(clip.id).coverPath, undefined);
  const coveredLegacy = await legacy.repository.ensureCover(clip.id);
  assert.ok(coveredLegacy.coverPath.endsWith('.cover-v1.jpg'),
    'Existing works backfill a durable first-frame cover');
}

async function addStemClip(h, scope = 'team', extra = {}) {
  const target = await h.repository.createTarget();
  const base = target.path.substring(0, target.path.length - 4);
  const clip = { ...target, durationMs: 3000, width: 720, height: 1280, interrupted: false,
    stopReason: 'user', scope, sourcePath: `${base}.source.mp4`, micPath: `${base}.mic.pcm`,
    innerPath: `${base}.inner.pcm`, micOffsetUs: 300, innerOffsetUs: 100,
    audioSampleRate: 44100, audioChannels: 2, renderedGain: 1, ...extra };
  h.environment.files.set(clip.path, Buffer.from('initial-gain=1'));
  h.environment.files.set(clip.sourcePath, Buffer.from('immutable-video'));
  h.environment.files.set(clip.micPath, Buffer.from('immutable-mic'));
  h.environment.files.set(clip.innerPath, Buffer.from('immutable-internal-audio'));
  await h.repository.add(clip);
  return h.repository.get(clip.id);
}

async function testWorkScopeAndNonDestructiveGain() {
  const migration = services(); await migration.initialize();
  const oldMix = await addStemClip(migration);
  const refreshedMix = await migration.repository.render(oldMix, 1);
  assert.notEqual(refreshedMix.path, oldMix.path, 'Old separate-track works are regenerated even when MIC gain is unchanged');
  assert.equal(refreshedMix.renderedMixVersion, 6);
  assert.equal(refreshedMix.autoMicShiftUs, -1000);
  assert.equal(refreshedMix.autoMicShiftReliable, true);
  await migration.repository.render(refreshedMix, 1);
  assert.equal(migration.mixCalls.length, 1, 'The current quality version does not re-encode an unchanged gain');
  const versionTwo = { ...await addStemClip(migration), renderedMixVersion: 2 };
  await migration.repository.add(versionTwo);
  const versionThree = await migration.repository.render(versionTwo, 1);
  assert.equal(versionThree.renderedMixVersion, 6);
  assert.notEqual(versionThree.path, versionTwo.path, 'The previous echo version upgrades even at the same MIC gain');
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
  assert.equal(first.renderedMicShiftUs, 0);
  assert.equal(h.mixCalls[0].gain, 1.23, 'The repository passes the desired mic gain once rather than compounding it with prior gain');
  assert.equal(h.mixCalls[0].clip.sourcePath, team.sourcePath);
  assert.equal(h.mixCalls[0].clip.micPath, team.micPath);
  assert.equal(h.mixCalls[0].clip.innerPath, team.innerPath);
  const unchanged = await h.repository.render(team, 1.234);
  assert.equal(unchanged.path, first.path); assert.equal(h.mixCalls.length, 1);
  const shifted = await h.repository.render(team, 1.234, -60000);
  assert.equal(shifted.renderedMicShiftUs, -60000);
  assert.equal(h.mixCalls[1].micShiftUs, -60000,
    'A negative manual shift advances only the cached MIC residual');
  const muted = await h.repository.render(team, 0, -60000);
  assert.equal(muted.renderedGain, 0);
  assert.equal(h.mixCalls[2].clip.sourcePath, team.sourcePath);
  assert.equal(h.environment.files.has(shifted.path), false, 'A successful newer gain render removes the superseded derived MP4');
  for (const [path, bytes] of immutable) assert.deepEqual(h.environment.files.get(path), bytes, 'Gain renders must never overwrite source stems');
  assert.equal(await h.repository.saveToAlbum(team, {}), true);
  assert.deepEqual(h.album.dialogs.at(-1).uris, [`file://${muted.path}`],
    'The system grants the current derived .mix-UUID.mp4 rather than the original stale UI path');
  assert.deepEqual(h.environment.files.get('content://album/video'), h.environment.files.get(muted.path),
    'Saving a stale UI clip reads the latest indexed render');
  await assert.rejects(h.repository.render(team, 1, 300001), /300 毫秒/);
  const dialogsBeforeShare = h.album.dialogs.length;
  const attempt = await h.share.share(team, {});
  assert.equal(h.controllers.at(-1).data.data.uri, 'content://album/video');
  assert.equal(h.album.dialogs.length, dialogsBeforeShare, 'Sharing the current saved mix reuses its approved gallery URI');
  assert.deepEqual(h.environment.files.get(h.controllers.at(-1).data.data.uri), h.environment.files.get(muted.path),
    'The receiver reads the current mix through the previously approved media-library copy');
  assert.deepEqual(h.environment.files.get(attempt.sharedPath), h.environment.files.get(muted.path),
    'System share snapshots the latest indexed render rather than a stale UI path');
  const sharedBytes = Buffer.from(h.environment.files.get(attempt.sharedPath));
  await h.repository.render(team, 1);
  assert.equal(h.mixCalls.length, 4, 'An unfinished share never blocks another MIC edit');
  assert.deepEqual(h.environment.files.get(attempt.sharedPath), sharedBytes, 'The receiver retains the exact shared version while MIC edits replace derived files');
  await h.share.dismissPending(attempt.id);
  await assert.rejects(h.repository.render(team, NaN), /麦克风音量无效/);
  const processedMic = `${team.micPath}.clean-v3.f32`;
  h.environment.files.set(processedMic, Buffer.from('cached-float-mic-residual'));
  h.environment.files.set(`${processedMic}.tmp`, Buffer.from('interrupted-cache-write'));
  await h.repository.remove(team.id);
  assert.equal(h.repository.count('team'), 0);
  for (const path of [...immutable.keys(), muted.path, team.path]) assert.equal(h.environment.files.has(path), false);
  assert.equal(h.environment.files.has(processedMic), false, 'Deleting a work also removes its fast MIC cache');
  assert.equal(h.environment.files.has(`${processedMic}.tmp`), false,
    'Deleting a work cleans an interrupted cache publication');
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

async function testSystemAecProvenanceAndRecovery() {
  const h = services(); await h.initialize();
  const oldAec = await addStemClip(h, 'team', { micCaptureMode: 'system-aec', captureSyncValid: true,
    captureMappingVersion: 3, videoTimestampDivisor: 1000, audioSampleRate: 48000,
    renderedMixVersion: 7, autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false });
  const aec = await h.repository.render(oldAec, 1);
  assert.notEqual(aec.path, oldAec.path, 'Previously quiet AEC exports upgrade at the same user gain');
  assert.equal(aec.renderedMixVersion, 8);
  assert.equal(h.mixCalls.length, 1);
  assert.equal(aec.micCaptureMode, 'system-aec', 'Indexing and public clip copies retain capture provenance');
  assert.equal(h.repository.list('team')[0].micCaptureMode, 'system-aec');
  const unchanged = await h.repository.render(aec, 1);
  assert.equal(unchanged.path, aec.path);
  assert.equal(h.mixCalls.length, 1, 'A current AEC render must not be rebuilt solely because its reliable-auto flag is false');
  const immutable = new Map([aec.sourcePath, aec.innerPath, aec.micPath].map(name =>
    [name, Buffer.from(h.environment.files.get(name))]));
  const shifted = await h.repository.render(aec, .37, 87000);
  assert.equal(shifted.micCaptureMode, 'system-aec');
  assert.equal(shifted.renderedGain, .37);
  assert.equal(shifted.renderedMicShiftUs, 87000);
  assert.equal(shifted.autoMicShiftUs, 0);
  assert.equal(shifted.autoMicShiftConfidence, 0);
  assert.equal(shifted.autoMicShiftReliable, false);
  assert.equal(h.mixCalls.at(-1).clip.micCaptureMode, 'system-aec');
  assert.equal(h.mixCalls.at(-1).micShiftUs, 87000);
  for (const [name, bytes] of immutable) assert.deepEqual(h.environment.files.get(name), bytes,
    'An AEC manual edit leaves every captured stem immutable');
  let restart = services(h.environment); await restart.initialize();
  const restored = restart.repository.get(aec.id);
  assert.equal(restored.micCaptureMode, 'system-aec', 'Capture mode must survive a full app restart');
  assert.equal(restored.captureMappingVersion, 3);
  assert.equal(restored.renderedMicShiftUs, 87000);
  await restart.repository.render(restored, .37, 87000);
  assert.equal(restart.mixCalls.length, 0);

  h.environment.failRenames.add('/app/files/recordings/library-v1.json');
  await assert.rejects(restart.repository.render(restored, .59, -43000), /声音处理未完成/);
  const recoveryPath = restart.mixCalls.at(-1).output;
  assert.equal(JSON.parse(h.environment.files.get(`${recoveryPath}.recovery.json`)).micCaptureMode, 'system-aec');
  h.environment.failRenames.delete('/app/files/recordings/library-v1.json');
  restart = services(h.environment); await restart.initialize();
  const recovered = restart.repository.get(aec.id);
  assert.equal(recovered.path, recoveryPath);
  assert.equal(recovered.micCaptureMode, 'system-aec', 'Failed-index render recovery must not fall back to legacy FIR processing');
  assert.equal(recovered.renderedMicShiftUs, -43000);
  const processed = `${aec.micPath}.system-aec-v3.f32`;
  h.environment.files.set(processed, Buffer.from('raw-system-aec-float-cache'));
  h.environment.files.set(`${processed}.tmp`, Buffer.from('interrupted-aec-cache-write'));
  const oldProcessed = `${aec.micPath}.system-aec-v1.f32`;
  h.environment.files.set(oldProcessed, Buffer.from('old-aec-cache'));
  const peakCappedProcessed = `${aec.micPath}.system-aec-v2.f32`;
  h.environment.files.set(peakCappedProcessed, Buffer.from('peak-capped-aec-cache'));
  h.environment.files.set(`${peakCappedProcessed}.tmp`, Buffer.from('interrupted-old-aec-cache'));
  await restart.repository.remove(aec.id);
  assert.equal(h.environment.files.has(processed), false);
  assert.equal(h.environment.files.has(`${processed}.tmp`), false);
  assert.equal(h.environment.files.has(oldProcessed), false);
  assert.equal(h.environment.files.has(peakCappedProcessed), false);
  assert.equal(h.environment.files.has(`${peakCappedProcessed}.tmp`), false);

  const pendingTarget = await restart.repository.createTarget();
  const base = pendingTarget.path.substring(0, pendingTarget.path.length - 4);
  const pending = { ...aec, ...pendingTarget, path: pendingTarget.path, sourcePath: `${base}-source.mp4`,
    innerPath: `${base}-inner.pcm`, micPath: `${base}-mic.pcm` };
  for (const name of [pending.sourcePath, pending.innerPath, pending.micPath]) {
    h.environment.files.set(name, Buffer.from('unexported-captured-stem'));
  }
  await restart.repository.retainPendingCapture(pending);
  const pendingRecordPath = `${base}.capture.json`;
  const note = JSON.parse(h.environment.files.get(pendingRecordPath));
  assert.equal(note.version, 2, 'The existing atomic capture container remains compatible');
  assert.equal(note.clip.micCaptureMode, 'system-aec');
  const pendingRestart = services(h.environment); await pendingRestart.initialize();
  const recoverable = await pendingRestart.repository.loadPendingCapture();
  assert.equal(recoverable.micCaptureMode, 'system-aec');
  assert.equal(recoverable.captureMappingVersion, 3);
  for (const invalid of [
    { ...pending, captureMappingVersion: 2 },
    { ...pending, micCaptureMode: 'screen-mic' },
    { ...pending, micCaptureMode: undefined }
  ]) {
    await pendingRestart.repository.retainPendingCapture(invalid);
    assert.equal(await pendingRestart.repository.loadPendingCapture(), undefined,
      'A mismatched AEC/mapping provenance note must not authorize a recovered export');
  }
  await pendingRestart.repository.retainPendingCapture({ ...pending, micCaptureMode: 'screen-mic', captureMappingVersion: 2 });
  assert.equal((await pendingRestart.repository.loadPendingCapture()).micCaptureMode, 'screen-mic',
    'Legacy screen-MIC captures remain recoverable in the same container');
}

function backgroundHarness({ avFailures = 0 } = {}) {
  const trace = [];
  let remainingFailures = avFailures, createCount = 0, updateFailures = 0;
  const keeper = load('session/SessionBackgroundKeeper.ets', {
    '@kit.ImageKit': { image: {} },
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
    { action: 'start', modes: ['multiDeviceConnection'] },
    { action: 'update', modes: ['multiDeviceConnection', 'audioRecording'] },
    { action: 'update', modes: ['multiDeviceConnection'] }
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
    action: 'update', modes: ['multiDeviceConnection', 'audioRecording']
  }, 'Media setup failure cannot release the already-started team connection owner');
  await mediaFailure.keeper.start(true);
  assert.equal(mediaFailure.createCount(), 2, 'The optional media card can be retried without creating another task');
  assert.equal(mediaFailure.trace.filter(item => item.action === 'start').length, 1);
  await mediaFailure.keeper.setRecordingActive(false);
  assert.deepEqual(mediaFailure.trace.at(-1).modes, ['multiDeviceConnection']);
  await mediaFailure.keeper.stop();
  assert.equal(mediaFailure.trace.at(-1).action, 'stop');

  const failedUpdate = backgroundHarness();
  await failedUpdate.keeper.start(true);
  failedUpdate.failUpdate(1);
  await assert.rejects(failedUpdate.keeper.setRecordingActive(true), /simulated background mode/);
  await failedUpdate.keeper.setRecordingActive(true);
  assert.deepEqual(failedUpdate.trace.at(-1).modes, ['multiDeviceConnection', 'audioRecording'],
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
  const routes = [], animations = [], notices = [];
  const context = { exports: {}, Scroller: class {}, Map, INK: '#171B1F',
    COMIC_CONTROL_INK_OFFSET: 2, COMIC_CARD_INK_OFFSET: 4,
    resolveDrumAccess: () => access, isProDrumMachineAccessible: () => access.allowed,
    formatTrialExpiry: () => '10/19 20:00',
    showUserNotice: message => notices.push(message),
    router: { pushUrl: value => routes.push(value.url) },
    Curve: { EaseOut: 'ease-out' }, animateTo: (options, action) => { animations.push(options); action(); } };
  vm.runInNewContext(result.outputText, context);
  const page = new context.exports.LeaderLobbyPage();
  page.editDrumMachine();
  assert.deepEqual(notices, ['定制鼓机包含在畅游月卡中']);
  assert.equal(page.proDrumEntryScale, 1);
  assert.equal(animations.length, 1);
  assert.deepEqual(routes, [], 'The locked entry shows its membership notice without opening records or navigating');
  access = { allowed: true, source: 'trial', expiresAt: 10000 };
  page.showProDrumAccessToast();
  assert.equal(page.drumAccessLabel(), '试用中 · 截止 10/19 20:00');
  assert.equal(notices.at(-1), '试用中 · 截止 10/19 20:00');
  page.editDrumMachine();
  assert.deepEqual(routes, ['pages/DrumMachinePage'], 'The unlocked title/arrow retains direct editor entry');
  access = { allowed: true, source: 'monthly', expiresAt: 10000 };
  page.showProDrumAccessToast();
  assert.equal(page.drumAccessLabel(), '月卡已解锁');
  assert.equal(notices.at(-1), '月卡已解锁');
  assert.doesNotMatch(source, /ShareCalendarSheet/, 'The lobby membership notice has no activity calendar');
  const calendar = fs.readFileSync(path.join(root, 'components/ShareCalendarSheet.ets'), 'utf8');
  assert.match(calendar, /Text\('打卡日历'\)/);
  assert.match(calendar, /ForEach\(this\.cells/);
  assert.match(calendar, /columnsTemplate\('1fr 1fr 1fr 1fr 1fr 1fr 1fr'\)/);

}


(async () => {
  await testCoverExtraction(); await testExplicitShareConfirmation(); await testSystemOperationsAndCrossDay(); await testShareCrashReplay(); await testOldSystemSelfReport(); await testShareCopyCleanup(); await testSharePathBoundary(); await testLibraryRecovery(); await testAlbumSaveLifecycle();
  await testLargeSnapshotsAndAtomicWrites(); await testWorkScopeAndNonDestructiveGain(); await testRenderedRecovery();
  await testSystemAecProvenanceAndRecovery();
  await testBackgroundOwners(); testLobbyToast(); testSharedCalendar();
  console.log('PASS recording share/storage: explicit publication only, durable pending and crash replay, failed-index MP4 recovery, album copy and background owner union/optional media card failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
