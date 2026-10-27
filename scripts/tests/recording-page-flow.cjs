const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const mainPageSource = fs.readFileSync('entry/src/main/ets/pages/MainPage.ets', 'utf8');
const comicInkOffsets = Object.fromEntries([...fs.readFileSync('entry/src/main/ets/components/ComicInkSurface.ets', 'utf8')
  .matchAll(/export const (COMIC_[A-Z_]+): number = ([\d.]+);/g)].map(match => [match[1], Number(match[2])]));
assert.match(mainPageSource,
  /private recordingSaveOverlay\(\)[\s\S]*Button\('继续行进'[\s\S]*ActionButton\(\{\s*label: '退出去查看', active: !this\.exiting[\s\S]*?inkShadow: CONTROL_SHADOW,[\s\S]*?action: \(\) => \{ void this\.exitAndViewSavedRecording\(\); \}/,
  'Recording success must offer continue and exit-to-view actions');
assert.match(mainPageSource,
  /ActionButton\(\{\s*label: '重试保存', active: !this\.retrySaveBusy[\s\S]*?action: \(\) => \{ void this\.retryRecordingSave\(\); \}/,
  'The custom retry face must retain its busy gate and original save action');
assert.match(mainPageSource,
  /private recordingErrorOverlay\(\)[\s\S]*Text\(this\.recordingErrorMessage\)[\s\S]*Button\('知道了，继续行进'/,
  'Recording failures must show their error detail in a dialog');

function loadPage(name, context) {
  const source = fs.readFileSync(`entry/src/main/ets/pages/${name}.ets`, 'utf8');
  const chromeStart = name === 'MainPage' ? source.indexOf('  private toggleChrome(): void {') : -1;
  const chromeMethod = chromeStart < 0 ? '' : source.slice(chromeStart, source.indexOf('  @Builder', chromeStart));
  const business = (source.slice(0, source.indexOf('  @Builder')) + chromeMethod + '\n}')
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@(?:Entry|Component)\b\s*/g, '')
    .replace(/@State\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace(`struct ${name}`, `export class ${name}`);
  const result = ts.transpileModule(business, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(result.outputText, context);
  return new context.exports[name]();
}
async function flush() { for (let index = 0; index < 20; index++) await Promise.resolve(); }

const clip = { id: 'clip-1', path: '/private/clip.mp4', createdAt: 1, durationMs: 2000,
  width: 720, height: 1280, interrupted: false, stopReason: 'user', scope: 'solo',
  sourcePath: '/private/source.mp4', micPath: '/private/mic.pcm', innerPath: '/private/inner.pcm', renderedGain: 1,
  renderedMicShiftUs: 0, autoMicShiftUs: 0, autoMicShiftConfidence: 0,
  autoMicShiftReliable: false, renderedMixVersion: 6 };

function harness(options = {}) {
  const trace = [], routes = [], notices = [];
  const timeouts = new Map();
  let timeoutId = 0;
  let snapshot = { state: 'idle', captureActive: false, elapsedMs: 0, amplitude: 0, error: '', saveFailureDetail: '', micMuted: false };
  let pending = [];
  let todayCompleted = false;
  let storedClips = [clip];
  const controller = { isLeader: true, state: 'playing' };
  const session = { controller, async leaderPause() { trace.push('pause-practice'); controller.state = 'paused'; } };
  const storage = new Map();
  const context = {
    exports: {}, Map, Date,
    ...comicInkOffsets,
    beijingDayKey: now => new Date(now + 8 * 3600000).toISOString().substring(0, 10), SHARE_CHECK_IN_DAY_MS: 86400000,
    getShareCheckInSummary: () => ({ todayCompleted }), MAX_MIC_SHIFT_US: 300000,
    RecordingMixer: { mixVersion: clip => clip.micCaptureMode === 'system-aec' ? 8 : 6 },
    RenderingContextSettings: class {},
    CanvasRenderingContext2D: class {
      clearRect() {} beginPath() {} moveTo() {} lineTo() {} stroke() {}
    },
    VideoController: class {
      pause() { trace.push('pause-preview'); }
      start() { trace.push('start-preview'); }
      setCurrentTime(time, mode) { trace.push(`seek-preview:${time}:${mode}`); }
    },
    Scroller: class {
      offset = { xOffset: 0, yOffset: 0 };
      currentOffset() { return { ...this.offset }; }
      scrollTo(options) { this.offset = { xOffset: options.xOffset, yOffset: options.yOffset };
        trace.push(`scroll:${options.yOffset}:${options.animation}`); }
    },
    SeekMode: { Accurate: 'accurate' },
    SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 },
    Curve: { EaseInOut: 'ease' },
    AppSession: {
      get: () => session,
      async reset() { trace.push('reset-session'); }
    },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    defaultBeatPointStates: () => [], logUserFailure() {},
    userErrorMessage: (_error, fallback) => fallback.trim().length > 0 ? fallback : '操作未完成，请重试',
    showUserNotice: message => notices.push(message),
    router: {
      async pushUrl(args) { routes.push(args); },
      async replaceUrl(args) { routes.push(args); },
      clear() { trace.push('clear-router'); }
    },
    setInterval: () => 1, clearInterval() {},
    setTimeout: callback => { timeouts.set(++timeoutId, callback); return timeoutId; },
    clearTimeout: id => timeouts.delete(id),
    animateTo: (_options, action) => { trace.push('animate'); action(); },
    RecordingCoordinator: {
      getSnapshot: () => snapshot,
      saveFailureNoticeText: view => {
        const state = view ?? snapshot;
        return state.saveFailureDetail ? `${state.error}（${state.saveFailureDetail}）` : state.error;
      },
      async stop(reason) {
        trace.push(`stop:${reason}`);
        if (options.stopGate) {
          snapshot = { ...snapshot, state: 'stopping', captureActive: true };
          await options.stopGate.promise;
        }
        snapshot = { ...snapshot, state: 'idle', captureActive: false };
      },
      async retrySave() { trace.push('retry-save'); snapshot = { ...snapshot, state: 'idle',
        error: '', saveFailureDetail: '', pendingClip: undefined, lastClip: clip }; return clip; },
      async discardPending() { trace.push('discard-pending'); snapshot = { ...snapshot, state: 'idle', pendingClip: undefined }; },
      async start() {
        trace.push('start-recording');
        if (options.startFailure) { throw new Error('synthetic start failure'); }
      }
    },
    RecordingRepository: {
      list: scope => storedClips.filter(item => scope === undefined || item.scope === scope),
      get: id => storedClips.find(item => item.id === id),
      async ensureCover(id) {
        trace.push(`cover:${id}`);
        const current = storedClips.find(item => item.id === id);
        if (!current) return undefined;
        const updated = { ...current, coverPath: `/private/${id}.cover-v1.jpg` };
        storedClips = storedClips.map(item => item.id === id ? updated : item);
        return updated;
      },
      async render(source, gain, micShiftUs) { trace.push(`render:${gain}:${micShiftUs}`);
        const updated = { ...source, path: `/private/mix-${gain}-${micShiftUs}.mp4`,
          renderedGain: gain, renderedMicShiftUs: micShiftUs, renderedMixVersion: 6 };
        storedClips = storedClips.map(item => item.id === updated.id ? updated : item); return updated; },
      async saveToAlbum(source) {
        trace.push(`save:${source.renderedGain}`);
        if (options.albumSaveFailure) throw new Error('simulated album write failure');
        return options.albumSaveResult ?? true;
      },
      async remove(id) {
        trace.push(`remove:${id}`);
        if (options.removeFailureIds?.includes(id)) throw new Error('simulated index failure');
        storedClips = storedClips.filter(item => item.id !== id);
        if (options.removeCleanupFailureIds?.includes(id)) throw new Error('simulated post-index cleanup failure');
      }
    },
    RecordingShareService: {
      async markReturnedToApp() {},
      getPendingListToday: () => todayCompleted ? [] : pending,
      getPendingForClipToday: id => todayCompleted ? undefined : pending.find(item => item.clipId === id),
      async confirmPublished(id) { trace.push(`confirm:${id}`); pending = []; todayCompleted = true;
        return { streakDays: 3, rewardGranted: true, monthlySkipped: false, trialExpiresAt: 10000 }; },
      async dismissForClip(id) { trace.push(`dismiss:${id}`); pending = pending.filter(item => item.clipId !== id); }
    },
    formatTrialExpiry: () => '明天',
    fileUri: { getUriFromPath: value => value }
  };
  return { context, trace, routes, notices, controller, timeouts, setPending: value => { pending = value; },
    setClips: value => { storedClips = value; }, setSnapshot: value => { snapshot = { ...snapshot, ...value }; } };
}

module.exports = { loadPage, harness, clip, flush };
if (require.main === module) (async () => {
  const consent = harness();
  const main = loadPage('MainPage', consent.context);
  consent.setSnapshot({ state: 'preparing' });
  main.recordingState = 'preparing';
  main.onPageHide();
  await Promise.resolve();
  assert.equal(consent.trace.length, 0, 'A system consent hide must not cancel preparation');
  main.aboutToDisappear();
  await Promise.resolve();
  assert.deepEqual(consent.trace, ['stop:page-hidden'], 'Actual destruction cancels pending capture');

  const canceled = harness();
  const preparing = loadPage('MainPage', canceled.context);
  canceled.setSnapshot({ state: 'preparing' }); preparing.recordingState = 'preparing';
  assert.equal(preparing.onBackPress(), true);
  await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(canceled.trace, ['stop:cancelled'], 'Back can cancel a stalled authorization wait');
  assert.equal(preparing.chromeVisible, true);

  const stopped = harness();
  const recorder = loadPage('MainPage', stopped.context);
  stopped.setSnapshot({ state: 'recording' }); recorder.recordingState = 'recording';
  await recorder.stopRecording();
  assert.deepEqual(stopped.trace, ['stop:user'], 'Stop only ends local capture without pausing practice or touching the renderer');

  let releaseNative;
  const stopGate = { promise: new Promise(resolve => { releaseNative = resolve; }) };
  const stopping = harness({ stopGate });
  const tail = loadPage('MainPage', stopping.context);
  stopping.setSnapshot({ state: 'recording', captureActive: true });
  tail.refreshRecordingState();
  const pendingStop = tail.stopRecording();
  await flush();
  assert.equal(tail.recordingState, 'stopping');
  assert.equal(tail.showRecordingSaving, false, 'No save modal while native capture is still stopping');
  tail.refreshRecordingState();
  assert.equal(tail.showRecordingSaving, false, 'Polling cannot expose saving UI before release');
  stopping.setSnapshot({ state: 'stopping', captureActive: false, savePhase: 'finishing' });
  tail.refreshRecordingState();
  assert.equal(tail.showRecordingSaving, true, 'Native release opens saving UI without waiting for export completion');
  releaseNative();
  await pendingStop;
  assert.deepEqual(stopping.trace, ['stop:user'], 'Closing capture never pauses or reschedules practice');

  const finished = harness();
  const walking = loadPage('MainPage', finished.context);
  walking.recordingState = 'recording';
  walking.chromeVisible = false;
  walking.toggleChrome();
  assert.equal(walking.chromeVisible, true, 'Background taps may reopen controls during capture');
  finished.setSnapshot({ state: 'idle', lastClip: clip });
  walking.refreshRecordingState();
  walking.refreshRecordingState();
  assert.equal(finished.routes.length, 0, 'Completing a recording keeps the walking page in place');
  assert.equal(finished.notices.length, 0, 'Successful recording must not use a transient toast');
  assert.equal(walking.showRecordingSaved, true, 'A completed clip opens the saved-location dialog once');
  assert.equal(walking.savedRecordingLabel, '单人练习作品');
  walking.continueWalkingAfterRecording();
  assert.equal(walking.showRecordingSaved, false, 'Continue walking dismisses only the saved dialog');
  assert.equal(finished.routes.length, 0);
  assert.equal(finished.trace.includes('pause-practice'), false, 'Stopping a video does not pause the shared practice');

  const viewing = harness();
  const viewingPage = loadPage('MainPage', viewing.context);
  const teamClip = { ...clip, id: 'clip-team', scope: 'team' };
  viewingPage.recordingState = 'recording';
  viewing.setSnapshot({ state: 'idle', lastClip: teamClip });
  viewingPage.refreshRecordingState();
  assert.equal(viewingPage.savedRecordingLabel, '多人练习作品');
  await viewingPage.exitAndViewSavedRecording();
  assert.equal(viewing.routes.length, 2);
  assert.equal(viewing.routes[0].url, 'pages/Index',
    'Exit-to-view must leave home on the stack so library back does not quit the app');
  assert.equal(viewing.routes[1].url, 'pages/RecordingLibraryPage');
  assert.equal(viewing.routes[1].params.scope, 'team');
  assert.equal(viewing.routes[1].params.clipId, teamClip.id,
    'Exit-to-view opens the matching library and selects the newly saved clip');
  assert.deepEqual(viewing.trace, ['reset-session', 'clear-router'],
    'Exit-to-view releases the session and clears the walking stack before navigation');

  const startFailure = harness({ startFailure: true });
  const startFailurePage = loadPage('MainPage', startFailure.context);
  await startFailurePage.startRecording();
  assert.equal(startFailure.notices.length, 0);
  assert.equal(startFailurePage.showRecordingError, true);
  assert.equal(startFailurePage.recordingErrorTitle, '无法开始录制');
  assert.match(startFailurePage.recordingErrorMessage, /麦克风和录屏授权/);

  const failedStart = harness();
  const failedStartPage = loadPage('MainPage', failedStart.context);
  failedStart.setSnapshot({ state: 'failed', error: '麦克风不可用，录制已结束' });
  failedStartPage.refreshRecordingState();
  failedStartPage.refreshRecordingState();
  assert.equal(failedStart.notices.length, 0, 'Recording failures must not use toast');
  assert.equal(failedStartPage.showRecordingError, true);
  assert.equal(failedStartPage.recordingErrorTitle, '录制未完成');
  assert.equal(failedStartPage.recordingErrorMessage, '麦克风不可用，录制已结束');
  assert.equal(failedStartPage.onBackPress(), true);
  assert.equal(failedStartPage.showRecordingError, false, 'Back dismisses the recording failure dialog');

  const recovery = harness();
  const saving = loadPage('MainPage', recovery.context);
  recovery.setSnapshot({ state: 'failed', pendingClip: clip,
    error: '原始音轨已保留，合成成品视频失败', saveFailureDetail: '编码器暂时不可用' });
  saving.refreshRecordingState();
  assert.equal(saving.showSaveRecovery, true);
  assert.equal(saving.showRecordingError, false, 'A retained capture uses the actionable recovery dialog');
  assert.equal(recovery.notices.length, 0, 'Save failures must not also show toast');
  assert.equal(saving.recordingSaveSummary, '原始音轨已保留，合成成品视频失败');
  assert.equal(saving.recordingSaveDetail, '编码器暂时不可用');
  saving.requestRecording();
  assert.equal(recovery.trace.includes('start-recording'), false, 'A pending video must be saved before another recording');
  await saving.retryRecordingSave();
  assert.equal(recovery.routes.length, 0, 'Recovering a save waits for an explicit dialog choice');
  assert.equal(recovery.notices.length, 0);
  assert.equal(saving.showRecordingSaved, true, 'A recovered save uses the same saved-location dialog');

  const discarded = harness();
  const failedRecording = loadPage('MainPage', discarded.context);
  discarded.setSnapshot({ state: 'failed', pendingClip: clip });
  failedRecording.refreshRecordingState();
  assert.equal(discarded.trace.includes('discard-pending'), false, 'Displaying recovery must preserve the failed work');
  await failedRecording.discardPendingRecording();
  assert.equal(discarded.trace.includes('discard-pending'), false, 'Discard cannot run without an explicit confirmation');
  failedRecording.requestDiscardPendingRecording();
  assert.equal(failedRecording.showDiscardRecordingConfirm, true);
  assert.equal(discarded.trace.includes('discard-pending'), false, 'Opening the confirmation must not delete media');
  await failedRecording.discardPendingRecording();
  assert.equal(discarded.trace.filter(item => item === 'discard-pending').length, 1);
  assert.equal(failedRecording.showSaveRecovery, false);
  discarded.context.AppStorage.setOrCreate('recordingIntroAccepted', true);
  failedRecording.requestRecording();
  await Promise.resolve();
  assert.equal(discarded.trace.includes('start-recording'), true, 'Discarding the failed pending work reopens recording');

  const playback = harness();
  const library = loadPage('RecordingLibraryPage', playback.context);
  library.clips = [clip]; library.selectedId = clip.id;
  library.hostContext = () => ({});
  library.requestPreview();
  assert.equal(library.pauseConfirmVisible, true);
  assert.equal(playback.trace.includes('pause-practice'), false, 'Preview requires an explicit leader pause confirmation');
  await library.pauseAndContinue();
  assert.equal(library.practiceActive, false);
  assert.equal(library.previewMuted, false, 'A new preview defaults to sound on');
  assert.equal(playback.trace.filter(item => item === 'pause-practice').length, 1);
  assert.equal(playback.trace.includes('system-share'), false, 'Pausing for preview must not launch a share');

  const covered = harness(); covered.controller.state = 'paused';
  const coveredLibrary = loadPage('RecordingLibraryPage', covered.context);
  coveredLibrary.clips = [{ ...clip, coverPath: '/private/clip.cover-v1.jpg' }];
  coveredLibrary.selectedId = clip.id;
  assert.equal(coveredLibrary.selectedCoverSource(), '/private/clip.cover-v1.jpg');
  assert.equal(coveredLibrary.previewCoverVisible, true);
  coveredLibrary.startPreviewFromCover();
  assert.equal(covered.trace.includes('start-preview'), false, 'Cover taps wait for the native player to prepare');
  coveredLibrary.previewPrepared(clip.id, clip.path);
  assert.equal(covered.trace.includes('start-preview'), true,
    'The idle cover remains a functional play surface for the underlying preview');
  coveredLibrary.previewStarted(clip.id, clip.path);
  coveredLibrary.previewPaused(clip.id, clip.path);
  assert.equal(coveredLibrary.previewCoverVisible, false,
    'Pausing after playback keeps the native player visible at its current frame');
  coveredLibrary.previewFinished(clip.id, clip.path);
  assert.equal(coveredLibrary.previewCoverVisible, true, 'A finished preview returns to its cover');

  const member = harness();
  member.controller.isLeader = false;
  const memberLibrary = loadPage('RecordingLibraryPage', member.context);
  memberLibrary.clips = [clip]; memberLibrary.selectedId = clip.id;
  memberLibrary.refreshPlayback();
  memberLibrary.requestPreview(); memberLibrary.togglePreviewSound();
  assert.equal(memberLibrary.practiceActive, true, 'An active practice keeps the actual Video player unmounted');
  assert.equal(memberLibrary.previewMuted, false, 'Blocking playback does not change the default sound preference');
  assert.equal(member.trace.includes('pause-practice'), false, 'A member cannot force the leader to pause');

  const secondClip = { ...clip, id: 'clip-2', path: '/private/clip-2.mp4' };
  const deletion = harness();
  deletion.setClips([clip, secondClip]);
  deletion.setPending([{ id: 'delete-todo', clipId: secondClip.id }]);
  const deleteLibrary = loadPage('RecordingLibraryPage', deletion.context);
  deleteLibrary.clips = [clip, secondClip]; deleteLibrary.selectedId = clip.id;
  deleteLibrary.managing = true;
  deleteLibrary.requestDeleteClip(secondClip.id);
  assert.equal(deleteLibrary.selectedId, clip.id, 'A card close control cannot switch the selected preview');
  assert.equal(deletion.trace.some(item => item.startsWith('remove:')), false, 'The close control requires explicit deletion confirmation');
  await deleteLibrary.deleteSelected();
  assert.equal(deleteLibrary.selectedId, clip.id);
  assert.equal(deletion.trace.includes('pause-preview'), false, 'Deleting a different work does not pause the current video');
  assert.ok(deletion.trace.indexOf('remove:clip-2') < deletion.trace.indexOf('dismiss:clip-2'));

  const mixing = harness(); mixing.controller.state = 'paused';
  const mixLibrary = loadPage('RecordingLibraryPage', mixing.context);
  mixLibrary.clips = [clip]; mixLibrary.selectedId = clip.id; mixLibrary.hostContext = () => ({});
  mixLibrary.changeMicGain(1.6, mixing.context.SliderChangeMode.Moving);
  assert.equal(mixing.trace.some(item => item.startsWith('render:')), false, 'Moving each slider pixel must not export');
  mixLibrary.changeMicGain(1.6, mixing.context.SliderChangeMode.End);
  await mixLibrary.audioRenderTask;
  assert.equal(mixLibrary.selectedClip().renderedGain, 1.6);
  assert.equal(mixLibrary.previewMuted, false);
  mixLibrary.changeMicShift(-60, mixing.context.SliderChangeMode.End);
  await mixLibrary.audioRenderTask;
  assert.equal(mixLibrary.selectedClip().renderedMicShiftUs, -60000);
  assert.equal(mixLibrary.micShiftLabel(), '人声提前 60 毫秒');
  mixLibrary.clips = [{ ...mixLibrary.selectedClip(), autoMicShiftUs: -1000,
    autoMicShiftConfidence: .8, autoMicShiftReliable: true, renderedMicShiftUs: 0 }];
  mixLibrary.micShiftMs = 0;
  assert.equal(mixLibrary.micShiftLabel(), '已自动提前 1 毫秒');
  mixLibrary.micShiftMs = -60;
  assert.equal(mixLibrary.micShiftLabel(), '自动基准上提前 60 毫秒');
  mixLibrary.changeMicGain(0.3, mixing.context.SliderChangeMode.End);
  await mixLibrary.audioRenderTask;
  const beforeSaveRenders = mixing.trace.filter(item => item.startsWith('render:')).length;
  await mixLibrary.saveSelected();
  assert.ok(mixing.trace.includes('save:0.3'));
  assert.equal(mixing.trace.filter(item => item.startsWith('render:')).length, beforeSaveRenders,
    'Saving uses the committed MIC render without starting another export');
  assert.equal(mixing.routes.at(-1).url, 'pages/SavedRecordingPage');
  assert.equal(mixing.routes.at(-1).params.clipId, clip.id);

  for (const options of [{ albumSaveResult: false }, { albumSaveFailure: true }]) {
    const album = harness(options);
    const albumLibrary = loadPage('RecordingLibraryPage', album.context);
    albumLibrary.clips = [clip]; albumLibrary.selectedId = clip.id;
    albumLibrary.hostContext = () => ({});
    await albumLibrary.saveSelected();
    assert.equal(album.routes.length, 0, 'Cancellation or a failed write must not open the saved page');
    assert.equal(albumLibrary.busy, false);
    assert.equal(albumLibrary.savingToAlbum, false, 'The button must become usable after every outcome');
    assert.equal(album.notices.length, options.albumSaveFailure ? 1 : 0,
      'User cancellation is silent; a real write failure remains visible');
  }

  const queued = harness(); queued.controller.state = 'paused';
  let queuedClips = [clip];
  const renderRequests = [];
  queued.context.RecordingRepository.list = () => queuedClips;
  queued.context.RecordingRepository.get = id => queuedClips.find(item => item.id === id);
  queued.context.RecordingRepository.render = (source, gain, micShiftUs) =>
    new Promise(resolve => renderRequests.push({ source, gain, micShiftUs, resolve }));
  const queuedLibrary = loadPage('RecordingLibraryPage', queued.context);
  queuedLibrary.clips = queuedClips; queuedLibrary.selectedId = clip.id;
  queuedLibrary.changeMicGain(1.2, queued.context.SliderChangeMode.End);
  const queuedTask = queuedLibrary.audioRenderTask;
  queuedLibrary.changeMicGain(1.3, queued.context.SliderChangeMode.Moving);
  queuedLibrary.changeMicGain(1.4, queued.context.SliderChangeMode.End);
  assert.equal(renderRequests.length, 1, 'A running export accepts edits without starting parallel work');
  let request = renderRequests[0];
  queuedClips = [{ ...request.source, path: '/private/queued-1.mp4',
    renderedGain: request.gain, renderedMicShiftUs: request.micShiftUs, renderedMixVersion: 6 }];
  request.resolve(queuedClips[0]); await flush();
  assert.equal(renderRequests.length, 2, 'Completed work immediately drains the latest committed edit');
  request = renderRequests[1];
  assert.equal(request.gain, 1.4, 'Moving values are skipped and only the last released value is rendered');
  queuedClips = [{ ...request.source, path: '/private/queued-2.mp4',
    renderedGain: request.gain, renderedMicShiftUs: request.micShiftUs, renderedMixVersion: 6 }];
  request.resolve(queuedClips[0]); await queuedTask;
  assert.equal(queuedLibrary.selectedClip().renderedGain, 1.4);

  const legacy = { ...clip, id: 'legacy', sourcePath: undefined, micPath: undefined, innerPath: undefined };
  mixLibrary.clips = [legacy]; mixLibrary.selectedId = legacy.id;
  assert.equal(mixLibrary.canAdjustMic(), false, 'An already-mixed legacy video cannot pretend to expose MIC gain');

  const continuing = harness(); continuing.controller.state = 'paused';
  const continuingLibrary = loadPage('RecordingLibraryPage', continuing.context);
  continuingLibrary.clips = [{ ...clip, durationMs: 20000 }]; continuingLibrary.selectedId = clip.id;
  continuingLibrary.previewStarted(clip.id, clip.path);
  continuingLibrary.previewProgress(clip.id, clip.path, 3.5);
  let completeRender;
  let continuationClips = continuingLibrary.clips;
  continuing.context.RecordingRepository.list = () => continuationClips;
  continuing.context.RecordingRepository.render = () => new Promise(resolve => { completeRender = resolve; });
  continuingLibrary.changeMicGain(1.25, continuing.context.SliderChangeMode.Begin);
  continuingLibrary.changeMicGain(1.25, continuing.context.SliderChangeMode.End);
  const continuingTask = continuingLibrary.audioRenderTask;
  assert.equal(continuing.trace.includes('pause-preview'), false, 'Dragging and exporting keep the current video playing');
  assert.equal(continuingLibrary.canAdjustMic(), true,
    'A slow export must not freeze subsequent MIC edits');
  continuingLibrary.previewProgress(clip.id, clip.path, 6.75);
  continuationClips = [{ ...clip, durationMs: 20000, path: '/private/resume.mp4', renderedGain: 1.25 }];
  continuingLibrary.refresh();
  assert.equal(continuingLibrary.clips[0].path, clip.path, 'Repository epoch cannot swap the source before its bookmark');
  completeRender(continuationClips[0]); await continuingTask;
  assert.equal(continuingLibrary.canAdjustMic(), true, 'A pending source seek does not freeze the edit controls');
  continuingLibrary.previewPrepared(clip.id, '/private/resume.mp4');
  assert.ok(continuing.trace.includes('seek-preview:6:accurate'), 'Loading the new mix seeks to the latest whole-second native position, not render-start time');
  assert.equal(continuing.trace.includes('start-preview'), false, 'Playback waits for seek completion to avoid repeating the opening beat');
  continuingLibrary.previewProgress(clip.id, '/private/resume.mp4', 0);
  assert.equal(continuingLibrary.previewLoading, true, 'An initial zero update cannot confirm a later seek target');
  continuingLibrary.previewProgress(clip.id, '/private/resume.mp4', 6);
  assert.equal(continuing.trace.filter(item => item === 'start-preview').length, 1);
  assert.equal(continuingLibrary.canAdjustMic(), true);
  assert.equal(continuing.timeouts.size, 0, 'The native progress update releases the load watchdog without onSeeked');
  continuingLibrary.previewProgress(clip.id, '/private/resume.mp4', 6);
  assert.equal(continuing.trace.filter(item => item === 'start-preview').length, 1, 'Repeated seek events cannot restart playback');
  continuingLibrary.previewContinuation = { clipId: clip.id, path: '/private/resume.mp4', timeSeconds: 8, playing: true };
  continuingLibrary.onPageHide();
  continuingLibrary.previewPrepared(clip.id, '/private/resume.mp4');
  assert.equal(continuing.trace.filter(item => item === 'start-preview').length, 1, 'Leaving the page cancels deferred resume');

  const pausedMix = harness(); pausedMix.controller.state = 'paused';
  const pausedLibrary = loadPage('RecordingLibraryPage', pausedMix.context);
  pausedLibrary.clips = [{ ...clip, durationMs: 20000 }]; pausedLibrary.selectedId = clip.id;
  pausedLibrary.previewStarted(clip.id, clip.path);
  let finishPausedRender;
  const pausedReplacement = { ...clip, durationMs: 20000, path: '/private/paused-mix.mp4', renderedGain: 0.75 };
  pausedMix.context.RecordingRepository.render = () => new Promise(resolve => { finishPausedRender = resolve; });
  pausedMix.context.RecordingRepository.list = () => [pausedReplacement];
  pausedLibrary.changeMicGain(0.75, pausedMix.context.SliderChangeMode.End);
  const pausedTask = pausedLibrary.audioRenderTask;
  pausedLibrary.previewProgress(clip.id, clip.path, 9.25);
  pausedLibrary.previewPaused(clip.id, clip.path);
  finishPausedRender(pausedReplacement); await pausedTask;
  pausedLibrary.previewProgress(clip.id, clip.path, 0);
  pausedLibrary.previewPrepared(clip.id, pausedReplacement.path);
  assert.ok(pausedMix.trace.includes('seek-preview:9:accurate'), 'Late events from the old source cannot overwrite the bookmark');
  pausedLibrary.previewProgress(clip.id, pausedReplacement.path, 9);
  assert.equal(pausedMix.trace.includes('start-preview'), false, 'Pausing during export remains paused after the new mix loads');

  const repeated = harness(); repeated.controller.state = 'paused';
  const repeatedLibrary = loadPage('RecordingLibraryPage', repeated.context);
  repeatedLibrary.clips = [clip]; repeatedLibrary.selectedId = clip.id;
  repeatedLibrary.previewStarted(clip.id, clip.path);
  repeatedLibrary.previewProgress(clip.id, clip.path, 0.75);
  for (const gain of [0, 2, 0.5]) {
    const priorController = repeatedLibrary.videoController;
    repeatedLibrary.changeMicGain(gain, repeated.context.SliderChangeMode.End);
    await repeatedLibrary.audioRenderTask;
    assert.notEqual(repeatedLibrary.videoController, priorController, 'Each new immutable export gets its own native controller');
    const path = repeatedLibrary.selectedClip().path;
    repeatedLibrary.previewPrepared(clip.id, path);
    assert.equal(repeatedLibrary.canAdjustMic(), true, 'A zero-second resume needs no absent seek callback');
    assert.equal(repeatedLibrary.selectedClip().renderedGain, gain);
  }
  assert.equal(repeated.trace.filter(item => item.startsWith('render:')).length, 3);

  repeatedLibrary.changeMicGain(1, repeated.context.SliderChangeMode.End);
  await repeatedLibrary.audioRenderTask;
  assert.equal(repeatedLibrary.canAdjustMic(), true);
  assert.equal(repeatedLibrary.previewLoading, true);
  const pendingLoad = [...repeated.timeouts.values()][0];
  pendingLoad();
  assert.equal(repeatedLibrary.previewLoading, false, 'A missing native prepare event cannot leave preview loading stuck');
  assert.equal(repeatedLibrary.previewContinuation, undefined);

  const staleMix = harness(); staleMix.controller.state = 'paused';
  let finishMix;
  staleMix.context.RecordingRepository.render = () => new Promise(resolve => { finishMix = resolve; });
  const staleLibrary = loadPage('RecordingLibraryPage', staleMix.context);
  staleLibrary.clips = [clip]; staleLibrary.selectedId = clip.id; staleLibrary.micGain = 1.8;
  const delayedMix = staleLibrary.renderSelectedAudio();
  staleLibrary.onPageHide();
  staleLibrary.selectedId = 'another-clip';
  finishMix({ ...clip, path: '/private/stale.mp4', renderedGain: 1.8 });
  await delayedMix;
  assert.equal(staleLibrary.selectedId, 'another-clip', 'A late render must not restore the previously selected clip');
  assert.equal(staleLibrary.clips[0].path, clip.path, 'A hidden page must not apply a stale preview source');
  console.log('PASS: capture consent, saved/error dialogs, exit-to-view cleanup, preview focus gate, deletion ownership and independent MIC render ordering');
})().catch(error => { console.error(error); process.exitCode = 1; });
