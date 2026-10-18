const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const mainPageSource = fs.readFileSync('entry/src/main/ets/pages/MainPage.ets', 'utf8');
assert.match(mainPageSource,
  /private recordingSavedOverlay\(\)[\s\S]*Button\('继续行进'[\s\S]*Button\('去查看'/,
  'Recording success must offer continue and view actions');
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
  sourcePath: '/private/source.mp4', micPath: '/private/mic.pcm', innerPath: '/private/inner.pcm', renderedGain: 1 };

function harness(options = {}) {
  const trace = [], routes = [], notices = [];
  let snapshot = { state: 'idle', elapsedMs: 0, amplitude: 0, error: '', saveFailureDetail: '', micMuted: false };
  let pending;
  let storedClips = [clip];
  const controller = { isLeader: true, state: 'playing' };
  const session = { controller, async leaderPause() { trace.push('pause-practice'); controller.state = 'paused'; } };
  const storage = new Map();
  const context = {
    exports: {}, Map, Date, VideoController: class { pause() { trace.push('pause-preview'); } },
    SliderChangeMode: { Begin: 0, Moving: 1, End: 2, Click: 3 },
    Curve: { EaseInOut: 'ease' },
    AppSession: { get: () => session },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    defaultBeatPointStates: () => [], logUserFailure() {},
    userErrorMessage: (_error, fallback) => fallback.trim().length > 0 ? fallback : '操作未完成，请重试',
    showUserNotice: message => notices.push(message),
    router: { async pushUrl(args) { routes.push(args); } },
    setInterval: () => 1, clearInterval() {},
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
        const updated = { ...source, path: `/private/mix-${gain}.mp4`, renderedGain: gain };
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
  return { context, trace, routes, notices, controller, setSnapshot: value => { snapshot = { ...snapshot, ...value }; } };
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
  await viewingPage.viewSavedRecording();
  assert.equal(viewing.routes.length, 1);
  assert.equal(viewing.routes[0].url, 'pages/RecordingLibraryPage');
  assert.equal(viewing.routes[0].params.scope, 'team');
  assert.equal(viewing.routes[0].params.clipId, teamClip.id,
    'View opens the matching library and selects the newly saved clip');
  assert.equal(viewing.trace.includes('pause-practice'), false, 'Viewing works does not pause practice implicitly');

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
  console.log('PASS: capture consent, saved/error dialogs, reopenable controls, preview focus gate, explicit check-in and independent MIC render ordering');
})().catch(error => { console.error(error); process.exitCode = 1; });
