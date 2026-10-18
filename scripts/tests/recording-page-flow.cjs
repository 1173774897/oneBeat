const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const mainPageSource = fs.readFileSync('entry/src/main/ets/pages/MainPage.ets', 'utf8');
assert.match(mainPageSource,
  /private recordingSavedOverlay\(\)[\s\S]*Button\('继续行进'[\s\S]*Button\('退出去查看'/,
  'Recording success must offer continue and exit-to-view actions');
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

const clip = { id: 'clip-1', path: '/private/clip.mp4', createdAt: 1, durationMs: 2000,
  width: 720, height: 1280, interrupted: false, stopReason: 'user', scope: 'solo',
  sourcePath: '/private/source.mp4', micPath: '/private/mic.pcm', innerPath: '/private/inner.pcm', renderedGain: 1,
  renderedMixVersion: 3 };

function harness(options = {}) {
  const trace = [], routes = [], notices = [];
  const timeouts = new Map();
  let timeoutId = 0;
  let snapshot = { state: 'idle', elapsedMs: 0, amplitude: 0, error: '', saveFailureDetail: '', micMuted: false };
  let pending;
  let storedClips = [clip];
  const controller = { isLeader: true, state: 'playing' };
  const session = { controller, async leaderPause() { trace.push('pause-practice'); controller.state = 'paused'; } };
  const storage = new Map();
  const context = {
    exports: {}, Map, Date, RECORDING_MIX_VERSION: 3, VideoController: class {
      pause() { trace.push('pause-preview'); }
      start() { trace.push('start-preview'); }
      setCurrentTime(time, mode) { trace.push(`seek-preview:${time}:${mode}`); }
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
      async stop(reason) { trace.push(`stop:${reason}`); snapshot = { ...snapshot, state: 'idle' }; },
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
      async render(source, gain) { trace.push(`render:${gain}`);
        const updated = { ...source, path: `/private/mix-${gain}.mp4`, renderedGain: gain, renderedMixVersion: 3 };
        storedClips = storedClips.map(item => item.id === updated.id ? updated : item); return updated; },
      async saveToAlbum(source) { trace.push(`save:${source.renderedGain}`); }
    },
    RecordingShareService: {
      getPending: () => pending,
      async share() { trace.push('system-share'); pending = { id: 'attempt-1', clipId: clip.id, handedOff: true }; return pending; },
      async confirmPublished(id) { trace.push(`confirm:${id}`); pending = undefined;
        return { streakDays: 3, rewardGranted: true, monthlySkipped: false, trialExpiresAt: 10000 }; }
    },
    formatTrialExpiry: () => '明天',
    fileUri: { getUriFromPath: value => value }
  };
  return { context, trace, routes, notices, controller, timeouts, setSnapshot: value => { snapshot = { ...snapshot, ...value }; } };
}

(async () => {
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
  assert.equal(viewing.routes.length, 1);
  assert.equal(viewing.routes[0].url, 'pages/RecordingLibraryPage');
  assert.equal(viewing.routes[0].params.scope, 'team');
  assert.equal(viewing.routes[0].params.clipId, teamClip.id,
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

  const member = harness();
  member.controller.isLeader = false;
  const memberLibrary = loadPage('RecordingLibraryPage', member.context);
  memberLibrary.clips = [clip]; memberLibrary.selectedId = clip.id;
  memberLibrary.refreshPlayback();
  memberLibrary.requestPreview(); memberLibrary.requestShare(); memberLibrary.togglePreviewSound();
  assert.equal(memberLibrary.practiceActive, true, 'An active practice keeps the actual Video player unmounted');
  assert.equal(memberLibrary.previewMuted, false, 'Blocking playback does not change the default sound preference');
  assert.equal(member.trace.includes('pause-practice'), false, 'A member cannot force the leader to pause');
  assert.equal(member.trace.includes('system-share'), false, 'A member must wait for pause before leaving to share');
  memberLibrary.pendingId = 'attempt-member'; memberLibrary.pendingHandedOff = true;
  await memberLibrary.confirmPublished();
  assert.equal(member.trace.some(item => item.startsWith('confirm:')), false,
    'A member must wait for pause before committing an existing pending check-in');
  assert.equal(member.trace.includes('pause-practice'), false);

  const sharing = harness();
  const sharingLibrary = loadPage('RecordingLibraryPage', sharing.context);
  sharingLibrary.clips = [clip]; sharingLibrary.selectedId = clip.id; sharingLibrary.hostContext = () => ({});
  sharingLibrary.requestShare();
  assert.equal(sharingLibrary.pauseConfirmVisible, true);
  assert.equal(sharing.trace.includes('pause-practice'), false, 'Share does not pause until the leader explicitly confirms');
  await sharingLibrary.pauseAndContinue();
  assert.equal(sharing.trace.filter(item => item === 'pause-practice').length, 1);
  assert.equal(sharing.trace.filter(item => item === 'system-share').length, 1);

  await library.shareSelected();
  assert.equal(library.pendingHandedOff, true);
  assert.equal(playback.trace.some(item => item.startsWith('confirm:')), false, 'System handoff must not count as publication');
  playback.controller.state = 'playing';
  await library.confirmPublished();
  assert.equal(library.pauseAction, 'confirm');
  assert.equal(library.pauseConfirmVisible, true);
  assert.equal(playback.trace.some(item => item.startsWith('confirm:')), false,
    'Confirming an old pending share also requires an explicit leader pause');
  await library.pauseAndContinue();
  assert.equal(playback.trace.filter(item => item === 'system-share').length, 1,
    'Pausing to confirm a pending publication must not launch another system share');
  assert.equal(playback.trace.filter(item => item === 'confirm:attempt-1').length, 1);
  assert.match(library.resultTitle, /24 小时/);

  const mixing = harness(); mixing.controller.state = 'paused';
  const mixLibrary = loadPage('RecordingLibraryPage', mixing.context);
  mixLibrary.clips = [clip]; mixLibrary.selectedId = clip.id; mixLibrary.hostContext = () => ({});
  mixLibrary.changeMicGain(1.6, mixing.context.SliderChangeMode.Moving);
  assert.equal(mixing.trace.some(item => item.startsWith('render:')), false, 'Moving each slider pixel must not export');
  mixLibrary.changeMicGain(1.6, mixing.context.SliderChangeMode.End);
  await mixLibrary.audioRenderTask;
  assert.equal(mixLibrary.selectedClip().renderedGain, 1.6);
  assert.equal(mixLibrary.previewMuted, false);
  mixLibrary.micGain = 0.3;
  await mixLibrary.saveSelected();
  assert.ok(mixing.trace.indexOf('render:0.3') < mixing.trace.indexOf('save:0.3'),
    'Saving must await the current independent MIC render');
  mixLibrary.micGain = 0.5;
  await mixLibrary.shareSelected();
  assert.ok(mixing.trace.indexOf('render:0.5') < mixing.trace.indexOf('system-share'),
    'Sharing must await the current independent MIC render');

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
  continuingLibrary.previewProgress(clip.id, clip.path, 6.75);
  continuationClips = [{ ...clip, durationMs: 20000, path: '/private/resume.mp4', renderedGain: 1.25 }];
  continuingLibrary.refresh();
  assert.equal(continuingLibrary.clips[0].path, clip.path, 'Repository epoch cannot swap the source before its bookmark');
  completeRender(continuationClips[0]); await continuingTask;
  assert.equal(continuingLibrary.canAdjustMic(), false, 'A second gain change waits for the pending source seek');
  continuingLibrary.previewPrepared(clip.id, '/private/resume.mp4');
  assert.ok(continuing.trace.includes('seek-preview:6:accurate'), 'Loading the new mix seeks to the latest whole-second native position, not render-start time');
  assert.equal(continuing.trace.includes('start-preview'), false, 'Playback waits for seek completion to avoid repeating the opening beat');
  continuingLibrary.previewProgress(clip.id, '/private/resume.mp4', 0);
  assert.equal(continuingLibrary.canAdjustMic(), false, 'An initial zero update cannot confirm a later seek target');
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
  assert.equal(repeatedLibrary.canAdjustMic(), false);
  const pendingLoad = [...repeated.timeouts.values()][0];
  pendingLoad();
  assert.equal(repeatedLibrary.canAdjustMic(), true, 'A missing native prepare event cannot permanently lock the slider');
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
  console.log('PASS: capture consent, saved/error dialogs, exit-to-view cleanup, preview focus gate, explicit check-in and independent MIC render ordering');
})().catch(error => { console.error(error); process.exitCode = 1; });
