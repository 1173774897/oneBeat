import { router } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { WalkReloadFrame } from '../components/WalkReloadFrame';
import { SessionMember } from '../protocol/messages';
import {
  PAPER,
  INK,
  CORAL,
  LILAC,
  WHITE,
  CARD_SHADOW,
  CONTROL_SHADOW,
  INK_SHADOW_RADIUS
} from '../components/ComicKit';
import { WalkScene } from '../scene/WalkScene';
import { EditableBpm } from '../components/EditableBpm';
import { MeterEditorOverlay } from '../components/EditableMeter';
import { BeatPointState, defaultBeatPointStates } from '../common/MeterModel';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import {
  drumProgramStyleKeys,
  styleByKey,
  parseDrumProgram,
  serializeDrumProgram
} from '../audio/DrumMachineCatalog';
import {
  SavedDrumProgram, loadSavedDrumPrograms, rememberRecentDrumProgram, resolveSavedDrumProgram
} from '../audio/DrumProgramLibrary';
import { RecordingCoordinator } from '../recording/RecordingCoordinator';
import { RecordingClip, RecordingScope, RecordingState, RecordingSavePhase } from '../recording/RecordingModels';
import { RecordingOverlay, RECORD_PILL_HEIGHT, RECORD_STOP_BOTTOM } from '../components/RecordingOverlay';
import { isProDrumMachineAccessible } from '../store/EntitlementStore';
import { ActionButton } from '../components/ActionButton';

const COUNTDOWN_FONT_SIZE: number = 138;
const COUNTDOWN_START_SCALE: number = 0.52;
const COUNTDOWN_SCALE_RANGE: number = 1.1;
const COUNTDOWN_MAX_OPACITY: number = 0.76;
const COUNTDOWN_CENTER_Y_OFFSET: number = 0;
const BEAT_POINT_FOUR_BEAT_GAP: number = 18;
const BEAT_POINT_MIN_GAP: number = 3;
const BEAT_POINT_ROW_HEIGHT: number = 16;
const BEAT_POINT_FALLBACK_AREA_WIDTH: number = 332;
const TOP_PANEL_HIDDEN_OFFSET: number = 204;
const RECORD_INTRO_HERO_HEIGHT: number = 140;
const RECORD_INTRO_WIDTH: string = '88%';
const RECORD_RESULT_WIDTH: string = '86%';
const RECORD_SAVE_DIALOG_HEIGHT: number = 380;
const RECORD_SAVE_DIALOG_MAX_HEIGHT: string = '82%';
const RECORD_SAVE_DIALOG_PADDING: number = 20;
const RECORD_SAVE_ACTION_HEIGHT: number = 88;
const RECORD_RESULT_Y_OFFSET: number = 0;
const PROGRAM_DRAWER_HEIGHT: number = 116;
const PROGRAM_CARD_WIDTH: number = 100;
const PROGRAM_CARD_HEIGHT: number = 68;
const PROGRAM_CARD_INNER_SPACE: number = 4;
const PROGRAM_CARD_ROW1_HEIGHT: number = 16;
const PROGRAM_CARD_ROW2_HEIGHT: number = 14;
const PROGRAM_CARD_ROW3_HEIGHT: number = 16;
const PROGRAM_CARD_STATUS_SIZE: number = 14;
const PROGRAM_DRAWER_GAP: number = 10;
const PROGRAM_CARD_SHADOW: number = 3;
const BOTTOM_PANEL_HIDDEN_OFFSET: number = 190;
const WALK_RELOAD_DELAY_MS: number = 300;
const WALK_RELOAD_FADE_MS: number = 120;
const WALK_RELOAD_MIN_VISIBLE_MS: number = 300;
const WALK_RELOAD_LONG_MS: number = 3000;
const WALK_RELOAD_ROW_HEIGHT: number = 16;
const WALK_RELOAD_SPINNER_SIZE: number = 12;
const WALK_RELOAD_TOP_GAP: number = 4;
const WALK_RELOAD_BOTTOM_GAP: number = 5;

type WalkReloadRegion = 'top' | 'bottom';

interface WalkReloadRequest {
  region: WalkReloadRegion;
  session: AppSession;
  label: string;
  startedAt: number;
  slow: boolean;
  settled: boolean;
  slowTimer: number;
  hideTimer: number;
  releaseFrame: () => void;
}

@Entry
@Component
struct MainPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @State members: SessionMember[] = [];
  @State bpm: number = 120;
  @State beats: number = 4;
  @State unit: number = 4;
  @State beatPointStates: BeatPointState[] = defaultBeatPointStates(4);
  @State beat: number = -1;
  @State leader: boolean = false;
  @State state: string = 'idle';
  @State sync: string = '';
  @State sound: number = 0;
  @State showStyles: boolean = false;
  @State rhythm: number = 0;
  @State walkBaseProgram: string = '';
  @State walkBaseProgramName: string = '未命名编排';
  @State savedDrumPrograms: SavedDrumProgram[] = [];
  @State savedDrumProgramsRevision: number = 0;
  @State selectedProgramKey: string = 'base';
  @State switchingProgramKey: string = '';
  @State confirmProgramKey: string = '';
  @State confirmProgramRaw: string = '';
  @State confirmProgramName: string = '';
  @State showProgramMeterConfirm: boolean = false;
  private walkProgramSession: AppSession | undefined = undefined;
  private walkBaseProgramLibraryId: string = '';
  private selectedProgramRaw: string = '';
  private confirmProgramSession: AppSession | undefined = undefined;
  private programSwitchInFlight: boolean = false;
  private switchingVisualOwner: number = 0;
  @State busy: boolean = false;
  @State topReloadPending: boolean = false;
  @State bottomReloadPending: boolean = false;
  @State topReloadOpacity: number = 0;
  @State bottomReloadOpacity: number = 0;
  @State topReloadText: string = '';
  @State bottomReloadText: string = '';
  private reloadSequence: number = 0;
  private busyOwner: number = 0;
  private busySession: AppSession | undefined = undefined;
  private readonly reloadRequests: Map<number, WalkReloadRequest> = new Map();
  @State exiting: boolean = false;
  @State showExitConfirm: boolean = false;
  @State meterEditorVisible: boolean = false;
  @State returningToLobby: boolean = false;
  @State chromeVisible: boolean = true;
  @State visualCountIn: boolean = false;
  @State visualPlaying: boolean = false;
  @State countdownNumber: number = 0;
  @State countdownScale: number = COUNTDOWN_START_SCALE;
  @State countdownOpacity: number = 0;
  @State beatPointAreaWidth: number = BEAT_POINT_FALLBACK_AREA_WIDTH;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') sceneKey: string = 'sunset_coast';
  @State soloTeam: boolean = false;
  @State recordingState: RecordingState = 'idle';
  @State recordingCaptureActive: boolean = false;
  @State recordingElapsedMs: number = 0;
  @State showRecordIntro: boolean = false;
  @State showRecordingSaved: boolean = false;
  @State showRecordingSaving: boolean = false;
  // Set when the user closes the saving dialog. The 200ms poll must not reopen
  // it for the same export; it resets once the snapshot leaves 'stopping', so
  // a retry or the next recording shows progress again.
  private recordingSavingDismissed: boolean = false;
  @State recordingSavePhase: RecordingSavePhase = 'finishing';
  @State savedRecordingLabel: string = '';
  @State savedRecordingScope: RecordingScope = 'solo';
  @State showRecordingError: boolean = false;
  @State recordingErrorTitle: string = '录制未完成';
  @State recordingErrorMessage: string = '';
  @State showSaveRecovery: boolean = false;
  @State showDiscardRecordingConfirm: boolean = false;
  @State retrySaveBusy: boolean = false;
  @State recordingSaveDetail: string = '';
  @State recordingSaveSummary: string = '';
  private sounds: string[] = ['电子', '清脆', '低音'];
  private visualTimer: number = -1;
  private recordingTimer: number = -1;
  private lastHandledClipId: string = '';
  private savedRecordingClipId: string = '';
  private lastRecordingError: string = '';
  private pendingSaveId: string = '';
  private recordingPreparationCancelled: boolean = false;
  private pageActive: boolean = true;
  private actionSequence: number = 0;
  // A native response must still belong to this page's latest action and room.
  private readonly pendingActions: Map<string, number> = new Map();
  private readonly actionSessions: Map<string, AppSession> = new Map();

  aboutToAppear(): void {
    this.pageActive = true;
    this.refresh();
    this.startVisualLoop();
    this.lastHandledClipId = RecordingCoordinator.getSnapshot().lastClip?.id ?? '';
    this.startRecordingLoop();
  }
  aboutToDisappear(): void {
    this.pageActive = false;
    this.clearReloadFeedback();
    this.pendingActions.clear();
    this.actionSessions.clear();
    this.stopVisualLoop();
    this.stopRecordingLoop();
    void this.finishRecordingOnLeave(true);
  }
  onPageShow(): void {
    this.pageActive = true;
    if (this.showStyles) { this.reloadSavedDrumPrograms(); }
    this.refresh();
    this.startVisualLoop();
    this.startRecordingLoop();
  }
  onPageHide(): void {
    this.pageActive = false;
    this.clearReloadFeedback();
    this.pendingActions.clear();
    this.actionSessions.clear();
    this.stopVisualLoop();
    this.stopRecordingLoop();
    void this.finishRecordingOnLeave(false);
  }

  private beginAction(scope: string, trackSession: boolean = true): number {
    const request = ++this.actionSequence;
    this.pendingActions.set(scope, request);
    const session = AppSession.get();
    if (trackSession && session !== undefined) {
      this.actionSessions.set(scope, session);
    } else {
      this.actionSessions.delete(scope);
    }
    return request;
  }

  private isCurrentAction(scope: string, request: number): boolean {
    return this.pageActive && this.pendingActions.get(scope) === request &&
      (!this.actionSessions.has(scope) || this.actionSessions.get(scope) === AppSession.get());
  }

  private reportActionFailure(scope: string, request: number, error: Object, fallback: string): void {
    logUserFailure(scope, error);
    if (this.isCurrentAction(scope, request)) {
      showUserNotice(userErrorMessage(error, fallback), scope);
    }
  }

  private animateReload(region: WalkReloadRegion, visible: boolean, delayed: boolean = false): void {
    const update = (): void => {
      if (region === 'top') { this.topReloadOpacity = visible ? 1 : 0; }
      else { this.bottomReloadOpacity = visible ? 1 : 0; }
    };
    try {
      // The spinner already exists at opacity zero. A native delayed animation
      // can appear even while the following PCM generation occupies JS.
      this.getUIContext().animateTo({ duration: visible ? WALK_RELOAD_FADE_MS : 0,
        delay: delayed ? WALK_RELOAD_DELAY_MS : 0, curve: Curve.Linear }, update);
    } catch (_error) {
      update();
    }
  }

  private syncReloadFeedback(region: WalkReloadRegion): void {
    let pending = false;
    let slow = false;
    let text = '';
    this.reloadRequests.forEach((request: WalkReloadRequest) => {
      if (request.region === region) {
        pending = true;
        slow = slow || request.slow;
        text = request.label;
      }
    });
    const wasPending = region === 'top' ? this.topReloadPending : this.bottomReloadPending;
    if (region === 'top') {
      this.topReloadPending = pending;
      this.topReloadText = slow ? '仍在处理，请稍候' : text;
    } else {
      this.bottomReloadPending = pending;
      this.bottomReloadText = slow ? '仍在处理，请稍候' : text;
    }
    if (pending !== wasPending) { this.animateReload(region, pending, pending); }
  }

  private beginReloadFeedback(region: WalkReloadRegion, session: AppSession,
    label: string = '正在准备节奏…'): number {
    const id = ++this.reloadSequence;
    const request: WalkReloadRequest = {
      region, session, label, startedAt: Date.now(), slow: false, settled: false,
      slowTimer: -1, hideTimer: -1, releaseFrame: () => {}
    };
    this.reloadRequests.set(id, request);
    request.slowTimer = setTimeout(() => {
      if (!this.isReloadCurrent(id)) { return; }
      request.slow = true;
      this.syncReloadFeedback(region);
    }, WALK_RELOAD_LONG_MS);
    this.syncReloadFeedback(region);
    return id;
  }

  private isReloadCurrent(id: number): boolean {
    const request = this.reloadRequests.get(id);
    return request !== undefined && !request.settled && this.pageActive && !this.exiting && !this.returningToLobby &&
      AppSession.get() === request.session;
  }

  private async waitForReloadFrame(id: number): Promise<boolean> {
    const request = this.reloadRequests.get(id);
    if (!this.isReloadCurrent(id) || request === undefined) { return false; }
    await new Promise<void>((resolve: () => void) => {
      request.releaseFrame = resolve;
      try { this.getUIContext().postFrameCallback(new WalkReloadFrame(resolve)); }
      catch (_error) { resolve(); }
    });
    return this.isReloadCurrent(id);
  }

  private finishReloadFeedback(id: number): void {
    const request = this.reloadRequests.get(id);
    if (request === undefined) { return; }
    request.settled = true;
    clearTimeout(request.slowTimer);
    const remove = (): void => {
      if (this.reloadRequests.get(id) !== request) { return; }
      this.reloadRequests.delete(id);
      if (this.switchingVisualOwner === id) {
        this.switchingProgramKey = '';
        this.switchingVisualOwner = 0;
      }
      this.syncReloadFeedback(request.region);
    };
    const elapsed = Date.now() - request.startedAt;
    const remaining = elapsed >= WALK_RELOAD_DELAY_MS ?
      Math.max(0, WALK_RELOAD_DELAY_MS + WALK_RELOAD_MIN_VISIBLE_MS - elapsed) : 0;
    // Only the visual cue may linger; audio and business locks finish immediately.
    if (remaining > 0 && this.pageActive && AppSession.get() === request.session) {
      request.hideTimer = setTimeout(remove, remaining);
    } else { remove(); }
  }

  private clearReloadFeedback(discardBusiness: boolean = false): void {
    const requests: WalkReloadRequest[] = [];
    this.reloadRequests.forEach((request: WalkReloadRequest) => requests.push(request));
    this.reloadRequests.clear();
    requests.forEach((request: WalkReloadRequest) => {
      clearTimeout(request.slowTimer);
      clearTimeout(request.hideTimer);
      request.releaseFrame();
    });
    this.topReloadPending = false;
    this.bottomReloadPending = false;
    this.switchingProgramKey = '';
    this.switchingVisualOwner = 0;
    this.animateReload('top', false);
    this.animateReload('bottom', false);
    // Hiding a page only cancels its visuals. An already submitted native
    // operation still owns its lock when the same page becomes visible again.
    if (discardBusiness) {
      this.busyOwner = 0;
      this.busySession = undefined;
      this.busy = false;
      this.programSwitchInFlight = false;
    }
  }

  private releaseBusy(request: number): void {
    if (this.busyOwner === request) {
      this.busy = false;
      this.busyOwner = 0;
      this.busySession = undefined;
    }
  }

  private async waitForReloadAudio(id: number, session: AppSession): Promise<void> {
    if (!this.isReloadCurrent(id)) { return; }
    const configuration = this.reloadConfigurationKey(session);
    const ready = await session.waitForCurrentAudioConfiguration();
    // Another BPM/meter edit may supersede this preparation without failing.
    // Its own request owns the new configuration and the remaining feedback.
    if (this.isReloadCurrent(id) && !ready && configuration === this.reloadConfigurationKey(session)) {
      throw new Error('节奏准备未完成，请稍后重试');
    }
  }

  private reloadConfigurationKey(session: AppSession): string {
    const c = session.controller;
    return `${c.rhythm}|${c.bpm}|${c.beatsPerBar}|${c.beatUnit}|${c.soundId}|` +
      `${c.drumProgram}|${c.beatPointStates.join(',')}`;
  }
  onBackPress(): boolean {
    if (this.showProgramMeterConfirm) {
      this.showProgramMeterConfirm = false;
      return true;
    }
    if (this.showStyles) {
      this.showStyles = false;
      return true;
    }
    if (this.showRecordingError) {
      this.showRecordingError = false;
      return true;
    }
    if (this.showRecordingSaved || this.showRecordingSaving) {
      this.dismissRecordingSaveDialog();
      return true;
    }
    if (this.showDiscardRecordingConfirm) {
      if (!this.retrySaveBusy) { this.showDiscardRecordingConfirm = false; }
      return true;
    }
    if (this.showSaveRecovery) {
      if (!this.retrySaveBusy) { this.showSaveRecovery = false; }
      return true;
    }
    if (this.showRecordIntro) {
      this.showRecordIntro = false;
      return true;
    }
    if (this.recordingState === 'preparing') {
      void this.cancelRecordingPreparation();
      return true;
    }
    if (this.isRecordingActive()) {
      showUserNotice('请先停止录制，视频会保存在本机', 'recording-back');
      return true;
    }
    if (this.meterEditorVisible) {
      this.meterEditorVisible = false;
      return true;
    }
    if (this.showExitConfirm) {
      this.showExitConfirm = false;
      return true;
    }
    void this.requestExit();
    return true;
  }
  refresh(): void {
    const session = AppSession.get();
    let stale = false;
    this.reloadRequests.forEach((request: WalkReloadRequest) => {
      if (request.session !== session) { stale = true; }
    });
    if (stale || (this.busyOwner !== 0 && this.busySession !== session)) {
      this.clearReloadFeedback(true);
    }
    const c = session?.controller;
    if (c === undefined) { return; }
    this.members = c.getMembers(); this.bpm = c.bpm; this.beats = c.beatsPerBar; this.unit = c.beatUnit;
    this.beatPointStates = c.beatPointStates.slice();
    this.leader = c.isLeader; this.state = c.state; this.sound = c.soundId; this.rhythm = c.rhythm;
    this.refreshProgramSelection();
    if (this.rhythm !== 3 && this.showStyles) { this.showStyles = false; }
    const storedBeatInBar = AppStorage.get<number>('currentBeatInBar') ?? 0;
    this.beat = storedBeatInBar > 0 ? storedBeatInBar - 1 : -1;
    this.sync = c.soloTeam ? '本机练习' : c.isLeader ? '队长时钟' : `同步 ${c.getSyncQuality()}`;
    this.soloTeam = c.soloTeam;
    this.refreshVisualTransport();
    if (!c.soloTeam && !c.isLeader && !c.lobbyDeparted) {
      this.returnToLobby();
    }
  }

  private refreshProgramSelection(): void {
    const session = AppSession.get();
    if (session === undefined) { return; }
    const raw = session.controller.drumProgram;
    if (this.walkProgramSession !== session) {
      this.walkProgramSession = session;
      this.walkBaseProgram = '';
      this.walkBaseProgramName = '未命名编排';
      this.walkBaseProgramLibraryId = '';
      this.selectedProgramRaw = '';
      this.selectedProgramKey = 'base';
    }
    if (session.controller.rhythm !== 3 || raw.length === 0) { return; }
    const canonical = serializeDrumProgram(parseDrumProgram(raw));
    // The return card is the complete entry arrangement, never the latest selection.
    if (this.walkBaseProgram.length === 0) {
      this.reloadSavedDrumPrograms();
      const origin = resolveSavedDrumProgram(canonical, session.controller.drumProgramLibraryId, this.savedDrumPrograms);
      this.walkBaseProgram = canonical;
      this.walkBaseProgramLibraryId = origin?.id ?? '';
      this.walkBaseProgramName = origin?.name ?? '未命名编排';
      this.selectedProgramRaw = canonical;
    }
    if (this.programSwitchInFlight || this.selectedProgramRaw === canonical) { return; }
    this.selectedProgramRaw = canonical;
    this.selectedProgramKey = canonical === this.walkBaseProgram ? 'base' : '';
    if (this.selectedProgramKey.length === 0) {
      const owned = resolveSavedDrumProgram(canonical, session.controller.drumProgramLibraryId, this.savedDrumPrograms);
      if (owned?.program === canonical) { this.selectedProgramKey = owned.id; }
    }
  }

  private reloadSavedDrumPrograms(): void {
    this.savedDrumPrograms = loadSavedDrumPrograms();
    this.savedDrumProgramsRevision++;
    if (this.selectedProgramKey !== 'base' && !this.savedDrumPrograms.some((entry: SavedDrumProgram) =>
      entry.id === this.selectedProgramKey && entry.program === this.selectedProgramRaw)) {
      // A replaced/deleted library version must not claim to be the currently audible snapshot.
      this.selectedProgramRaw = '';
    }
  }

  private toggleStyleDrawer(): void {
    if (!this.leader || this.rhythm !== 3) { return; }
    if (!this.showStyles) {
      this.reloadSavedDrumPrograms();
      if (this.selectedProgramKey.length === 0) { this.selectedProgramRaw = ''; }
      this.refreshProgramSelection();
    }
    this.showStyles = !this.showStyles;
  }

  private programStyleKeys(raw: string): string[] {
    return raw.length > 0 ? drumProgramStyleKeys(parseDrumProgram(raw)) : [];
  }

  private programMeterSummary(raw: string): string {
    const program = parseDrumProgram(raw);
    return `${program.beatsPerBar}/${program.beatUnit} · ${program.sections.length}段`;
  }

  private async chooseDrumArrangement(key: string, raw: string, name: string): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader || controller.rhythm !== 3 ||
      this.busy || this.exiting || this.returningToLobby || raw.length === 0) { return; }
    if (!isProDrumMachineAccessible()) {
      showUserNotice('鼓机权益已到期，本轮播放继续；回到队伍大厅可查看解锁方式', 'walk-drum-program-locked');
      return;
    }
    const program = parseDrumProgram(raw);
    const canonical = serializeDrumProgram(program);
    if (key === this.selectedProgramKey && canonical === this.selectedProgramRaw) { return; }
    if (program.beatsPerBar !== controller.beatsPerBar || program.beatUnit !== controller.beatUnit) {
      this.confirmProgramSession = AppSession.get();
      this.confirmProgramKey = key;
      this.confirmProgramRaw = canonical;
      this.confirmProgramName = name;
      this.showProgramMeterConfirm = true;
      return;
    }
    await this.switchDrumArrangement(key, canonical);
  }

  private async confirmDrumArrangement(): Promise<void> {
    if (!this.pageActive || this.confirmProgramSession !== AppSession.get()) {
      this.showProgramMeterConfirm = false;
      return;
    }
    const key = this.confirmProgramKey;
    const raw = this.confirmProgramRaw;
    this.showProgramMeterConfirm = false;
    await this.switchDrumArrangement(key, raw);
  }

  private async switchDrumArrangement(key: string, raw: string): Promise<void> {
    const session = AppSession.get();
    if (session === undefined || !session.controller.isLeader || this.busy ||
      this.exiting || this.returningToLobby || !isProDrumMachineAccessible()) { return; }
    this.busy = true;
    this.programSwitchInFlight = true;
    this.switchingProgramKey = key;
    const request = this.beginAction('walk-drum-program');
    this.busyOwner = request;
    this.busySession = session;
    const loading = this.beginReloadFeedback('bottom', session, '正在切换编排…');
    this.switchingVisualOwner = loading;
    try {
      if (!await this.waitForReloadFrame(loading)) { return; }
      const libraryId = key === 'base' ? this.walkBaseProgramLibraryId :
        this.savedDrumPrograms.find((entry: SavedDrumProgram) => entry.id === key)?.id ?? '';
      const applied = await session.controller.updateDrumArrangement(raw, libraryId);
      if (!this.isCurrentAction('walk-drum-program', request)) { return; }
      if (!applied) { throw new Error('编排切换未完成，请重试'); }
      await this.waitForReloadAudio(loading, session);
      if (!this.isCurrentAction('walk-drum-program', request)) { return; }
      this.selectedProgramKey = key;
      this.selectedProgramRaw = raw;
      try {
        rememberRecentDrumProgram(raw, libraryId);
      } catch (error) {
        logUserFailure('walk-drum-program-recent', error);
      }
    } catch (error) {
      this.reportActionFailure('walk-drum-program', request, error, '编排切换未完成，请重试');
    } finally {
      this.finishReloadFeedback(loading);
      if (this.busyOwner === request) {
        this.programSwitchInFlight = false;
      }
      this.releaseBusy(request);
      if (this.isCurrentAction('walk-drum-program', request)) { this.refresh(); }
    }
  }

  private startVisualLoop(): void {
    if (this.visualTimer >= 0) { return; }
    this.visualTimer = setInterval(() => this.refreshVisualTransport(), 32);
  }

  private stopVisualLoop(): void {
    if (this.visualTimer >= 0) {
      clearInterval(this.visualTimer);
      this.visualTimer = -1;
    }
  }

  private isRecordingActive(): boolean {
    return this.recordingState === 'preparing' || this.recordingState === 'recording' ||
      this.recordingState === 'stopping';
  }

  private startRecordingLoop(): void {
    if (this.recordingTimer >= 0) { return; }
    this.refreshRecordingState();
    // Recording status has its own low-frequency observer; do not add capture
    // work to refreshVisualTransport or the existing metronome timing path.
    this.recordingTimer = setInterval(() => this.refreshRecordingState(), 200);
  }

  private stopRecordingLoop(): void {
    if (this.recordingTimer >= 0) {
      clearInterval(this.recordingTimer);
      this.recordingTimer = -1;
    }
  }

  private refreshRecordingState(): void {
    const snapshot = RecordingCoordinator.getSnapshot();
    const wasActive = this.isRecordingActive();
    const previousState = this.recordingState;
    if (this.recordingState !== snapshot.state) { this.recordingState = snapshot.state; }
    this.recordingCaptureActive = snapshot.captureActive === true;
    if (this.recordingElapsedMs !== snapshot.elapsedMs) { this.recordingElapsedMs = snapshot.elapsedMs; }
    this.recordingSavePhase = snapshot.savePhase ?? 'finishing';
    if (snapshot.state !== 'stopping') {
      this.recordingSavingDismissed = false;
    }
    if (snapshot.state === 'stopping' && !this.recordingCaptureActive && !this.showDiscardRecordingConfirm &&
      !this.recordingSavingDismissed) {
      this.showRecordingSaving = true;
      this.showSaveRecovery = false;
      this.showRecordingSaved = false;
      this.showRecordingError = false;
    } else if (snapshot.state !== 'stopping' || this.recordingCaptureActive) {
      this.showRecordingSaving = false;
    }
    if (this.recordingState === 'preparing' || (!wasActive && this.recordingState === 'recording')) {
      this.chromeVisible = false;
      this.showStyles = false;
      this.meterEditorVisible = false;
    } else if (wasActive && !this.isRecordingActive()) {
      this.chromeVisible = true;
    }
    if (this.recordingSaveDetail !== snapshot.saveFailureDetail) {
      this.recordingSaveDetail = snapshot.saveFailureDetail;
    }
    if (this.recordingSaveSummary !== snapshot.error) {
      this.recordingSaveSummary = snapshot.error;
    }
    // A stop can carry a capture-interruption reason while export is still running.
    // Surface its result only after export has actually succeeded or failed.
    if (snapshot.state !== 'stopping' && snapshot.error.length > 0 && snapshot.error !== this.lastRecordingError) {
      this.lastRecordingError = snapshot.error;
      const failureAlreadyVisible = this.showRecordingError ||
        (snapshot.pendingClip !== undefined && this.showSaveRecovery);
      if (snapshot.error !== '已取消录制' && !failureAlreadyVisible) {
        this.presentRecordingFailureOrRecovery(
          RecordingCoordinator.saveFailureNoticeText(snapshot),
          snapshot.pendingClip === undefined ? '录制未完成' : '保存未完成'
        );
      }
    }
    if (snapshot.state === 'failed' && snapshot.pendingClip !== undefined &&
      (snapshot.pendingClip.id !== this.pendingSaveId || previousState !== 'failed')) {
      this.pendingSaveId = snapshot.pendingClip.id;
      this.showSaveRecovery = true;
    } else if (snapshot.pendingClip === undefined) {
      this.pendingSaveId = '';
      this.showSaveRecovery = false;
    }
    if (snapshot.lastClip !== undefined && snapshot.lastClip.id !== this.lastHandledClipId) {
      this.lastHandledClipId = snapshot.lastClip.id;
      if (wasActive && this.pageActive && !this.returningToLobby && !this.exiting) {
        this.notifyRecordingSaved(snapshot.lastClip);
      }
    }
  }

  private requestRecording(): void {
    if (this.exiting || this.returningToLobby || this.recordingState === 'stopping') { return; }
    if (this.recordingState === 'recording') { void this.stopRecording(); return; }
    if (this.recordingState === 'preparing') { void this.cancelRecordingPreparation(); return; }
    if (RecordingCoordinator.getSnapshot().pendingClip !== undefined) {
      this.showSaveRecovery = true;
      return;
    }
    if (AppStorage.get<boolean>('recordingIntroAccepted') === true) {
      void this.startRecording();
    } else {
      this.showRecordIntro = true;
    }
  }

  private async startRecording(): Promise<void> {
    if (this.isRecordingActive()) { return; }
    this.showRecordIntro = false;
    this.showStyles = false;
    this.meterEditorVisible = false;
    this.chromeVisible = false;
    this.showRecordingError = false;
    this.recordingState = 'preparing';
    this.recordingPreparationCancelled = false;
    this.lastRecordingError = '';
    try {
      await RecordingCoordinator.start(this.soloTeam ? 'solo' : 'team');
      if (RecordingCoordinator.getSnapshot().state === 'recording') {
        AppStorage.setOrCreate('recordingIntroAccepted', true);
      }
    } catch (error) {
      logUserFailure('recording-start', error);
      const message = RecordingCoordinator.getSnapshot().error;
      if (!this.recordingPreparationCancelled) {
        this.presentRecordingFailureOrRecovery(
          message.length > 0 ? message : '录制未能开始，请检查麦克风和录屏授权',
          '无法开始录制'
        );
      }
    } finally {
      if (this.pageActive) { this.refreshRecordingState(); }
    }
  }

  private async cancelRecordingPreparation(): Promise<void> {
    if (this.recordingState !== 'preparing') { return; }
    this.recordingPreparationCancelled = true;
    try {
      await RecordingCoordinator.stop('cancelled');
    } catch (error) {
      logUserFailure('recording-cancel-prepare', error);
      this.presentRecordingFailureOrRecovery('取消录制时发生异常，请稍后重试', '录制状态异常');
    } finally {
      if (this.pageActive) { this.refreshRecordingState(); }
    }
  }

  private async retryRecordingSave(): Promise<void> {
    if (this.retrySaveBusy) { return; }
    this.retrySaveBusy = true;
    this.showSaveRecovery = false;
    this.showRecordingSaving = true;
    this.recordingSavePhase = 'mixing';
    try {
      const operation = RecordingCoordinator.retrySave();
      this.refreshRecordingState();
      const clip = await operation;
      if (this.pageActive) {
        this.refreshRecordingState();
        if (clip !== undefined) {
          this.lastHandledClipId = clip.id;
          this.showSaveRecovery = false;
          this.notifyRecordingSaved(clip);
        }
      }
    } catch (error) {
      logUserFailure('recording-retry-save', error);
      this.presentRecordingFailureOrRecovery(
        userErrorMessage(error, RecordingCoordinator.saveFailureNoticeText()),
        '保存未完成'
      );
    } finally {
      this.retrySaveBusy = false;
      if (this.pageActive) { this.refreshRecordingState(); }
    }
  }

  private requestDiscardPendingRecording(): void {
    if (this.retrySaveBusy || RecordingCoordinator.getSnapshot().pendingClip === undefined) { return; }
    this.showDiscardRecordingConfirm = true;
  }

  private async discardPendingRecording(): Promise<void> {
    if (this.retrySaveBusy || !this.showDiscardRecordingConfirm) { return; }
    this.retrySaveBusy = true;
    try {
      await RecordingCoordinator.discardPending();
      this.showDiscardRecordingConfirm = false;
      this.showSaveRecovery = false;
      this.pendingSaveId = '';
      if (this.pageActive) {
        this.refreshRecordingState();
        showUserNotice('已放弃这段，可以重新录制', 'recording-discard-pending');
      }
    } catch (error) {
      logUserFailure('recording-discard-pending', error);
      this.showDiscardRecordingConfirm = false;
      this.presentRecordingFailureOrRecovery('暂时无法放弃这段，请稍后再试', '处理未完成');
    } finally { this.retrySaveBusy = false; }
  }

  private async stopRecording(): Promise<void> {
    if (this.recordingState !== 'recording') { return; }
    this.showRecordingSaving = false;
    this.showSaveRecovery = false;
    this.showRecordingSaved = false;
    this.recordingSavePhase = 'finishing';
    try {
      const operation = RecordingCoordinator.stop('user');
      this.refreshRecordingState();
      await operation;
    } catch (error) {
      logUserFailure('recording-stop', error);
      this.presentRecordingFailureOrRecovery(
        userErrorMessage(error, RecordingCoordinator.saveFailureNoticeText()),
        '结束录制失败'
      );
    } finally {
      if (this.pageActive) { this.refreshRecordingState(); }
    }
  }

  private async finishRecordingOnLeave(includePreparing: boolean): Promise<void> {
    const state = RecordingCoordinator.getSnapshot().state;
    // System capture consent may hide a page while start is still pending;
    // only actual destruction cancels that preparation.
    if (state !== 'recording' && !(includePreparing && state === 'preparing')) { return; }
    try {
      const clip = await RecordingCoordinator.stop('page-hidden');
      if (clip !== undefined) { this.lastHandledClipId = clip.id; }
    } catch (error) {
      logUserFailure('recording-leave', error);
    }
  }

  private notifyRecordingSaved(clip: RecordingClip): void {
    const scope = clip.scope ?? (this.soloTeam ? 'solo' : 'team');
    this.savedRecordingClipId = clip.id;
    this.savedRecordingScope = scope;
    this.savedRecordingLabel = scope === 'solo' ? '单人练习作品' : '多人练习作品';
    this.showRecordingError = false;
    this.showRecordingSaving = false;
    this.showSaveRecovery = false;
    this.showRecordingSaved = true;
  }

  private presentRecordingFailureOrRecovery(message: string, title: string): void {
    if (!this.pageActive || message.trim().length === 0) { return; }
    const snapshot = RecordingCoordinator.getSnapshot();
    const pending = snapshot.pendingClip;
    if (snapshot.state === 'stopping') {
      this.showRecordingSaving = snapshot.captureActive !== true;
      this.showRecordingSaved = false;
      this.showSaveRecovery = false;
      this.showRecordingError = false;
      return;
    }
    this.showRecordingSaving = false;
    if (pending !== undefined) {
      this.pendingSaveId = pending.id;
      this.recordingSaveSummary = snapshot.error.trim().length > 0 ? snapshot.error : message;
      this.recordingSaveDetail = snapshot.saveFailureDetail;
      this.showRecordingSaved = false;
      this.showRecordingError = false;
      this.showSaveRecovery = true;
      return;
    }
    this.recordingErrorTitle = title;
    this.recordingErrorMessage = message;
    this.showSaveRecovery = false;
    this.showRecordingSaved = false;
    this.showRecordingError = true;
  }

  private continueWalkingAfterRecording(): void {
    this.dismissRecordingSaveDialog();
  }

  private dismissRecordingSaveDialog(): void {
    if (this.showRecordingSaving) {
      this.recordingSavingDismissed = true;
    }
    this.showRecordingSaving = false;
    this.showRecordingSaved = false;
    this.showSaveRecovery = false;
  }

  private recordingSaveTitle(): string {
    return this.showRecordingSaving ? '正在保存这一拍' :
      (this.showRecordingSaved ? '这一拍已保存' : '这一拍还在等保存');
  }

  private recordingSaveStageNumber(): number {
    return this.recordingSavePhase === 'indexing' ? 3 : (this.recordingSavePhase === 'mixing' ? 2 : 1);
  }

  private recordingSaveStageLabel(): string {
    return this.recordingSavePhase === 'indexing' ? '放入你的练习作品' :
      (this.recordingSavePhase === 'mixing' ? '合成画面、节奏与 MIC 声音' : '整理刚刚录下的画面与声音');
  }

  private async exitAndViewSavedRecording(): Promise<void> {
    if (this.exiting || this.returningToLobby) { return; }
    const clipId = this.savedRecordingClipId;
    const scope = this.savedRecordingScope;
    if (clipId.length === 0) {
      this.showRecordingSaved = false;
      return;
    }
    this.showRecordingSaved = false;
    this.exiting = true;
    const request = this.beginAction('recording-open-saved', false);
    try {
      await AppSession.reset();
    } catch (error) {
      // Match the normal exit path: the active session is already detached,
      // so navigation may continue while retained cleanup remains retryable.
      logUserFailure('recording-open-saved-cleanup', error);
    }
    if (!this.isCurrentAction('recording-open-saved', request)) {
      this.exiting = false;
      return;
    }
    router.clear();
    try {
      // Rebuild Index under the library so back from「我的作品」returns home instead of exiting the app.
      await router.replaceUrl({ url: 'pages/Index' });
      await router.pushUrl({
        url: 'pages/RecordingLibraryPage',
        params: { scope: scope, clipId: clipId }
      });
    } catch (error) {
      logUserFailure('recording-open-saved', error);
      this.exiting = false;
      if (this.pageActive) {
        this.presentRecordingFailureOrRecovery(
          '已退出练习，作品仍保存在本机；暂时无法打开作品页，请稍后从首页进入',
          '暂时无法打开作品'
        );
      }
    }
  }

  private refreshVisualTransport(): void {
    const snapshot = AppSession.get()?.metronome.getVisualSnapshot();
    if (snapshot === undefined || !snapshot.running) {
      if (this.visualCountIn) { this.visualCountIn = false; }
      if (this.visualPlaying) { this.visualPlaying = false; }
      if (this.countdownNumber !== 0) { this.countdownNumber = 0; }
      if (this.countdownOpacity !== 0) { this.countdownOpacity = 0; }
      return;
    }
    const nextBeat = snapshot.beatInBar > 0 ? snapshot.beatInBar - 1 : -1;
    const nextPlaying = snapshot.mainPlayheadMs >= 0;
    if (this.beat !== nextBeat) { this.beat = nextBeat; }
    if (this.visualCountIn !== snapshot.countIn) { this.visualCountIn = snapshot.countIn; }
    if (this.visualPlaying !== nextPlaying) { this.visualPlaying = nextPlaying; }
    if (snapshot.countIn && snapshot.beatInBar > 0) {
      const phase = Math.max(0, Math.min(1, snapshot.beatPhase));
      const nextCountdownNumber = Math.max(1, this.beats - snapshot.beatInBar + 1);
      const nextScale = COUNTDOWN_START_SCALE + phase * COUNTDOWN_SCALE_RANGE;
      const nextOpacity = COUNTDOWN_MAX_OPACITY * (1 - phase * phase);
      if (this.countdownNumber !== nextCountdownNumber) { this.countdownNumber = nextCountdownNumber; }
      if (Math.abs(this.countdownScale - nextScale) > 0.01) { this.countdownScale = nextScale; }
      if (Math.abs(this.countdownOpacity - nextOpacity) > 0.01) { this.countdownOpacity = nextOpacity; }
    } else {
      if (this.countdownNumber !== 0) { this.countdownNumber = 0; }
      if (this.countdownOpacity !== 0) { this.countdownOpacity = 0; }
    }
  }

  private async toggle(): Promise<void> {
    if (!this.leader || this.busy || this.exiting) { return; }
    const session = AppSession.get();
    if (session === undefined) { return; }
    this.busy = true;
    const request = this.beginAction('walk-playback');
    this.busyOwner = request;
    this.busySession = session;
    const pausing = this.state === 'playing' || this.state === 'countdown';
    const loading = this.beginReloadFeedback('bottom', session, pausing ? '正在暂停…' : '正在准备播放…');
    try {
      if (!await this.waitForReloadFrame(loading)) { return; }
      if (pausing) { await session.leaderPause(); }
      else if (this.state === 'paused') { await session.leaderResume(); }
      else { await session.leaderStart(); }
      if (!pausing) { await this.waitForReloadAudio(loading, session); }
    } catch (error) { this.reportActionFailure('walk-playback', request, error, '播放操作失败，请重试'); }
    finally {
      this.finishReloadFeedback(loading);
      this.releaseBusy(request);
      if (this.isCurrentAction('walk-playback', request)) {
        this.refresh();
      }
    }
  }

  private async applyMeter(beats: number, unit: number): Promise<void> {
    if (!this.leader || this.busy || this.exiting || (this.beats === beats && this.unit === unit)) {
      return;
    }
    this.beats = beats;
    this.unit = unit;
    await this.runWalkingConfiguration('top', 'walk-meter', '拍号修改失败，请重试',
      (session: AppSession) => session.controller.updateMeter(beats, unit));
  }

  private async runWalkingConfiguration(region: WalkReloadRegion, scope: string, failure: string,
    operation: (session: AppSession) => Promise<void>): Promise<void> {
    const session = AppSession.get();
    if (!this.leader || this.busy || this.exiting || this.returningToLobby ||
      session === undefined || !session.controller.isLeader) { return; }
    const request = this.beginAction(scope);
    const loading = this.beginReloadFeedback(region, session);
    try {
      if (!await this.waitForReloadFrame(loading)) { return; }
      await operation(session);
      await this.waitForReloadAudio(loading, session);
    } catch (error) {
      this.reportActionFailure(scope, request, error, failure);
    } finally {
      this.finishReloadFeedback(loading);
      if (this.isCurrentAction(scope, request)) { this.refresh(); }
    }
  }

  private async applyBpm(value: number): Promise<void> {
    if (value === AppSession.get()?.controller.bpm) { return; }
    await this.runWalkingConfiguration('top', 'walk-bpm-top', '速度修改失败，请重试',
      (session: AppSession) => session.controller.updateBpm(value));
  }

  private async changeBpm(delta: number): Promise<void> {
    await this.runWalkingConfiguration('bottom', 'walk-bpm-bottom', '速度修改失败，请重试',
      (session: AppSession) => session.controller.updateBpm(session.controller.bpm + delta));
  }

  private async changeSound(): Promise<void> {
    await this.runWalkingConfiguration('bottom', 'walk-sound', '音色修改失败，请重试',
      (session: AppSession) => session.controller.updateSoundId(session.controller.soundId + 1));
  }

  private async cycleBeatPoint(index: number): Promise<void> {
    const controller = AppSession.get()?.controller;
    const session = AppSession.get();
    // A metronome button can deliver a late event after the room switches to drums.
    if (!this.leader || this.busy || this.exiting || session === undefined ||
      this.rhythm === 3 || controller?.rhythm === 3) {
      return;
    }
    this.busy = true;
    const request = this.beginAction('walk-beat-point');
    this.busyOwner = request;
    this.busySession = session;
    const loading = this.beginReloadFeedback('top', session);
    try {
      if (!await this.waitForReloadFrame(loading)) { return; }
      if (this.rhythm === 3 || controller?.rhythm === 3) { return; }
      await controller?.cycleBeatPointState(index);
      await this.waitForReloadAudio(loading, session);
    } catch (error) {
      this.reportActionFailure('walk-beat-point', request, error, '拍点修改失败，请重试');
    } finally {
      this.finishReloadFeedback(loading);
      this.releaseBusy(request);
      if (this.isCurrentAction('walk-beat-point', request)) {
        this.refresh();
      }
    }
  }

  private beatPointFill(index: number): string {
    const state = this.beatPointStates[index] ?? (index === 0 ? 'accent' : 'normal');
    if (state === 'accent') { return LILAC; }
    if (state === 'silent') { return WHITE; }
    return CORAL;
  }

  private beatPointGap(): number {
    if (this.beats <= 4) {
      return BEAT_POINT_FOUR_BEAT_GAP;
    }
    const progress = (this.beats - 4) / 12;
    return BEAT_POINT_FOUR_BEAT_GAP -
      (BEAT_POINT_FOUR_BEAT_GAP - BEAT_POINT_MIN_GAP) * progress;
  }

  private beatPointSize(): number {
    // One to four beats intentionally reserve a four-slot grid so every common meter keeps the same visual weight.
    const slotCount = Math.max(4, this.beats);
    const gap = this.beatPointGap();
    return Math.max(12, (this.beatPointAreaWidth - gap * (slotCount - 1)) / slotCount);
  }

  private beatPointHeight(): number {
    // Height is the width of a sixteen-beat point; only sixteen beats render as squares.
    return Math.max(12,
      (this.beatPointAreaWidth - BEAT_POINT_MIN_GAP * 15) / 16);
  }

  private beatPointGroupWidth(): number {
    return this.beatPointSize() * this.beats + this.beatPointGap() * Math.max(0, this.beats - 1);
  }

  @Builder
  private beatPoint(index: number) {
    if (this.rhythm === 3) {
      // Drum mode uses these as playback indicators; accent editing belongs
      // to the arrangement. Block touches here so they cannot toggle the scene.
      Row().width(this.beatPointSize()).height(this.beatPointHeight())
        .backgroundColor(this.beatPointFill(index)).borderRadius(5)
        .border({
          width: this.beat === index && (this.visualPlaying || this.visualCountIn) ? 3 : 1.5,
          color: this.beat === index && (this.visualPlaying || this.visualCountIn) ? '#35D6E4' : INK
        })
        .shadow(this.beat === index && (this.visualPlaying || this.visualCountIn) ?
          { radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 } :
          { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
        .hitTestBehavior(HitTestMode.Block).focusable(false).accessibilityLevel('no')
    } else {
      ActionButton({
        active: this.leader && !this.busy, controlWidth: this.beatPointSize(), controlHeight: this.beatPointHeight(),
        preserveDisabledAppearance: !this.leader,
        fill: this.beatPointFill(index), cornerRadius: 5,
        lineWidth: this.beat === index && (this.visualPlaying || this.visualCountIn) ? 3 : 1.5,
        lineColor: this.beat === index && (this.visualPlaying || this.visualCountIn) ? '#35D6E4' : INK,
        inkShadow: this.beat === index && (this.visualPlaying || this.visualCountIn) ?
          { radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 } :
          { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 },
        accessibilityLabel: `调整第 ${index + 1} 拍的拍点`, action: () => { void this.cycleBeatPoint(index); }
      })
    }
  }

  private beatUnitIconPath(): string {
    if (this.unit === 1) { return 'comic/icons/note-whole.svg'; }
    if (this.unit === 2) { return 'comic/icons/note-half.svg'; }
    if (this.unit === 4) { return 'comic/icons/note-quarter.svg'; }
    if (this.unit === 8) { return 'comic/icons/note-eighth.svg'; }
    return 'comic/icons/note-sixteenth.svg';
  }

  private async requestExit(): Promise<void> {
    if (this.exiting || this.returningToLobby) { return; }
    const controller = AppSession.get()?.controller;
    if (controller === undefined) {
      await this.exitSessionToHome();
      return;
    }
    if (!controller.isLeader) {
      this.showExitConfirm = true;
      return;
    }
    this.returningToLobby = true;
    const request = this.beginAction('walk-return');
    try {
      await AppSession.get()?.leaderReturnToLobby();
      if (!this.isCurrentAction('walk-return', request)) {
        this.returningToLobby = false;
        return;
      }
      router.back();
    } catch (error) {
      this.reportActionFailure('walk-return', request, error, '返回队伍大厅失败，请重试');
      this.returningToLobby = false;
    }
  }

  private returnToLobby(): void {
    if (this.returningToLobby || this.exiting) { return; }
    this.returningToLobby = true;
    this.showExitConfirm = false;
    router.back();
  }

  private async exitSessionToHome(): Promise<void> {
    if (this.exiting) { return; }
    this.showExitConfirm = false;
    this.exiting = true;
    const request = this.beginAction('walk-exit', false);
    try {
      await AppSession.reset();
    } catch (error) {
      logUserFailure('walk-exit-cleanup', error);
    }
    if (!this.isCurrentAction('walk-exit', request)) {
      this.exiting = false;
      return;
    }
    router.clear();
    try {
      await router.replaceUrl({ url: 'pages/Index' });
    } catch (error) {
      this.reportActionFailure('walk-exit', request, error, '返回首页失败，请重试');
      this.exiting = false;
    }
  }

  private toggleChrome(): void {
    if (this.showStyles) {
      this.showStyles = false;
      return;
    }
    if (this.recordingState === 'preparing' || this.recordingState === 'stopping') { return; }
    animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.chromeVisible = !this.chromeVisible;
    });
  }

  @Builder
  private recordingIntroOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row() {
          Text('把这一拍，留下来').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          Blank()
          Text('×').fontSize(26).fontWeight(900).width(30).height(32).textAlign(TextAlign.Center)
            .onClick(() => this.showRecordIntro = false)
        }.width('100%')
        Image($rawfile('comic/decor/recording_share_hero.png'))
          .width('100%').height(RECORD_INTRO_HERO_HEIGHT).objectFit(ImageFit.Contain)
        Text('画面 + 节奏声 + 你身边的声音').fontSize(15).fontWeight(900).fontColor(INK).width('100%')
        Text('开始后，上下面板会收起，点击舞台可再次展开操作。实时声波与小型停止按钮会保留在成品视频中。')
          .fontSize(12).fontColor('#625C54').lineHeight(19).width('100%')
        Text('接下来请允许麦克风与系统录屏。停止只结束本机录制，行进练习继续。')
          .fontSize(11).fontColor('#625C54').lineHeight(18).width('100%')
        Button('开始录制', { type: ButtonType.Normal })
          .width('100%').height(48).fontSize(17).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
          .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
          .onClick(() => { void this.startRecording(); })
        Text('录完继续行进 · 首页可查看练习作品').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#625C54').padding(3)
      }
      .width(RECORD_INTRO_WIDTH).padding(18).backgroundColor(PAPER).border({ width: 2, color: INK })
      .borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
  }

  @Builder
  private recordingSaveOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row() {
          Text(this.showRecordingSaving ? 'SAVING / 正在保存' :
            (this.showRecordingSaved ? 'SAVED / 已保存' : 'RETRY / 等待保存'))
            .fontSize(11).fontWeight(900).letterSpacing(0.6).fontColor(INK)
            .backgroundColor(this.showRecordingSaved ? LILAC : CORAL)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -2 })
          Blank()
          Text('×').fontSize(25).fontWeight(900).width(28).height(28).textAlign(TextAlign.Center)
            .onClick(() => this.dismissRecordingSaveDialog())
        }.width('100%').height(28)
        Text(this.recordingSaveTitle()).fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic)
          .fontColor(INK).width('100%').height(34).maxLines(1).minFontSize(20).maxFontSize(24)
        Scroll() {
          Column({ space: 10 }) {
            if (this.showRecordingSaving) {
              Text('视频正在保存到本机，行进练习会继续。')
                .fontSize(14).fontWeight(900).fontColor('#7C493A').lineHeight(22).width('100%')
              Text(`正在完成第 ${this.recordingSaveStageNumber()}/3 步`)
                .fontSize(12).fontWeight(900).fontColor(INK).width('100%')
              // This bar advances only when a real save stage completes; the native encoder has no fraction callback.
              Progress({ value: this.recordingSaveStageNumber() - 1, total: 3, type: ProgressType.Linear })
                .width('100%').color(CORAL).backgroundColor('#E7DFD3').style({ strokeWidth: 8 })
              Text(this.recordingSaveStageLabel()).fontSize(12).fontColor('#625C54').lineHeight(19).width('100%')
              Text('较长的视频需要多一点时间。可先收起此窗口，完成后会告诉你。')
                .fontSize(11).fontColor('#777064').lineHeight(18).width('100%')
            } else if (this.showRecordingSaved) {
              Text(`已保存到本机「${this.savedRecordingLabel}」`)
                .fontSize(15).fontWeight(900).fontColor('#7C493A').lineHeight(22).width('100%')
              Text(`之后可从首页「${this.savedRecordingScope === 'solo' ? '单人练习' : '多人练习'}」卡片内的「作品」入口查看、调节 MIC 音量或分享。`)
                .fontSize(12).fontColor('#625C54').lineHeight(20).width('100%')
            } else {
              Text(this.recordingSaveSummary.length > 0 ? this.recordingSaveSummary : '这段视频暂未保存到首页作品列表')
                .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#7C493A').lineHeight(20).width('100%')
              if (this.recordingSaveDetail.length > 0) {
                Text(`原因：${this.recordingSaveDetail}`)
                  .fontSize(12).fontColor('#625C54').lineHeight(18).width('100%')
              }
              Text('画面与音轨仍保留在本机应用内。可以重试保存，也可以稍后处理。')
                .fontSize(12).fontColor('#625C54').lineHeight(19).width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Button('继续行进', { type: ButtonType.Normal }).layoutWeight(1).height(46)
              .fontSize(14).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
              .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
              .onClick(() => this.continueWalkingAfterRecording())
            if (this.showRecordingSaving) {
              ActionButton({
                label: '正在保存…', active: false, controlHeight: 46, labelSize: 14, labelWeight: 900,
                labelColor: '#625C54', fill: '#E7DFD3', lineWidth: 1.5, lineColor: '#A29B90', cornerRadius: 6,
                action: () => {}
              }).layoutWeight(1)
            } else if (this.showRecordingSaved) {
              ActionButton({
                label: '退出去查看', active: !this.exiting, controlHeight: 46,
                labelSize: 14, labelWeight: 900, labelColor: INK, fill: CORAL,
                lineWidth: 1.5, lineColor: INK, cornerRadius: 6, inkShadow: CONTROL_SHADOW,
                action: () => { void this.exitAndViewSavedRecording(); }
              }).layoutWeight(1)
            } else {
              ActionButton({
                label: '重试保存', active: !this.retrySaveBusy, controlHeight: 46,
                labelSize: 14, labelWeight: 900, labelColor: INK, fill: CORAL,
                lineWidth: 1.5, lineColor: INK, cornerRadius: 6, inkShadow: CONTROL_SHADOW,
                action: () => { void this.retryRecordingSave(); }
              }).layoutWeight(1)
            }
          }.width('100%')
          if (!this.showRecordingSaving && !this.showRecordingSaved) {
            ActionButton({
              label: '放弃这段', active: !this.retrySaveBusy, controlWidth: 'auto', controlHeight: 'auto',
              labelSize: 12, labelWeight: 900, labelColor: '#7C493A', fill: Color.Transparent, contentPadding: 5,
              action: () => this.requestDiscardPendingRecording()
            })
          } else {
            Text(this.showRecordingSaving ? '保存只处理本机视频，不会暂停行进' : '关闭窗口后，也能从首页找到这段作品')
              .fontSize(10).fontColor('#777064').lineHeight(18).height(28)
          }
        }.width('100%').height(RECORD_SAVE_ACTION_HEIGHT)
      }.width(RECORD_RESULT_WIDTH).height(RECORD_SAVE_DIALOG_HEIGHT)
        .constraintSize({ maxHeight: RECORD_SAVE_DIALOG_MAX_HEIGHT }).padding(RECORD_SAVE_DIALOG_PADDING)
        .backgroundColor(PAPER).border({ width: 2, color: INK }).borderRadius(9)
        .shadow(CARD_SHADOW).translate({ y: RECORD_RESULT_Y_OFFSET })
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(117)
  }

  @Builder
  private recordingErrorOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('RECORDING / 录制提示').fontSize(11).fontWeight(900).letterSpacing(0.8).fontColor(INK)
          .backgroundColor(CORAL).padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -2 })
        Text(this.recordingErrorTitle)
          .fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text(this.recordingErrorMessage)
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#7C493A').lineHeight(21).width('100%')
        Text('当前行进练习不受影响。关闭后可以继续操作或重新录制。')
          .fontSize(12).fontColor('#625C54').lineHeight(20).width('100%')
        Button('知道了，继续行进', { type: ButtonType.Normal })
          .width('100%').height(46).fontSize(15).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
          .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
          .onClick(() => this.showRecordingError = false)
      }.width(RECORD_RESULT_WIDTH).padding(20).backgroundColor(PAPER).border({ width: 2, color: INK })
        .borderRadius(9).shadow(CARD_SHADOW).translate({ y: RECORD_RESULT_Y_OFFSET })
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(118)
  }

  @Builder
  private discardRecordingConfirmOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('放弃这段未保存的视频？').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text('将删除这段尚未保存的画面和音轨。已保存的练习作品不会受影响。')
          .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
        Row({ space: 10 }) {
          ActionButton({
            label: '保留这段', active: !this.retrySaveBusy, controlHeight: 46,
            labelSize: 13, labelWeight: 900, labelColor: INK, fill: PAPER,
            lineWidth: 1.5, lineColor: INK, cornerRadius: 6, inkShadow: CONTROL_SHADOW,
            action: () => this.showDiscardRecordingConfirm = false
          }).layoutWeight(1)
          ActionButton({
            label: this.retrySaveBusy ? '正在处理…' : '确认放弃', active: !this.retrySaveBusy, controlHeight: 46,
            labelSize: 13, labelWeight: 900, labelColor: INK, fill: CORAL,
            lineWidth: 1.5, lineColor: INK, cornerRadius: 6, inkShadow: CONTROL_SHADOW,
            action: () => { void this.discardPendingRecording(); }
          }).layoutWeight(1)
        }.width('100%')
      }.width(RECORD_INTRO_WIDTH).padding(20).backgroundColor(PAPER).border({ width: 2, color: INK })
        .borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(116)
  }

  @Builder
  private countdownOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.countdownNumber > 0) {
        Text(`${this.countdownNumber}`)
          .fontSize(COUNTDOWN_FONT_SIZE)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(Color.White)
          .textShadow({ radius: 0, offsetX: 7, offsetY: 8, color: '#A8171B1F' })
          .rotate({ angle: -4 })
          .scale({ x: this.countdownScale, y: this.countdownScale })
          .translate({ y: COUNTDOWN_CENTER_Y_OFFSET })
          .opacity(this.countdownOpacity)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .zIndex(40)
  }

  @Builder
  private exitConfirmOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 13 }) {
        Row() {
          Text('先等等！').fontSize(13).fontWeight(900).fontColor(PAPER)
            .backgroundColor(INK).padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .shadow(CONTROL_SHADOW)
            .rotate({ angle: -2 })
          Blank()
          Text('×').fontSize(22).fontWeight(900).width(32).height(32).textAlign(TextAlign.Center)
            .onClick(() => this.showExitConfirm = false)
        }.width('100%')
        Text('要退出这支队伍吗？').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text('退出后需重新加入队伍。')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#625C54').width('100%')
        Row({ space: 10 }) {
          Button('继续行进', { type: ButtonType.Normal })
            .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
            .onClick(() => this.showExitConfirm = false)
          Button('退出队伍', { type: ButtonType.Normal })
            .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
            .onClick(() => { void this.exitSessionToHome(); })
        }.width('100%')
      }
      .width('86%')
      .padding(17)
      .backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK })
      .borderRadius(8)
      .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 4, offsetY: 5, color: INK })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#72000000')
    .zIndex(100)
  }

  @Builder
  private topPanel() {
    Column({ space: 5 }) {
      Row() {
        Text('‹').fontSize(30).width(30).onClick(() => { void this.requestExit(); })
        Text('一起行进').fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic)
        Text(' LIVE ').fontSize(10).fontWeight(FontWeight.Bold).fontColor(PAPER)
          .backgroundColor(CORAL).padding({ left: 4, right: 4, top: 2, bottom: 2 }).rotate({ angle: -4 })
          .shadow(CONTROL_SHADOW)
        Blank()
        Circle().width(8).height(8).fill('#38B68D')
        Text(this.sync).fontSize(10).fontWeight(FontWeight.Bold).maxLines(1)
        Text('⚙').fontSize(21).padding({ left: 7, right: 2 }).onClick(() => { void this.requestExit(); })
      }.width('100%')
      Row({ space: 5 }) {
        EditableBpm({
          value: this.bpm,
          editable: this.leader && !this.busy,
          preserveDisabledAppearance: !this.leader,
          inputId: 'walk-bpm-input',
          controlWidth: 105,
          controlHeight: 62,
          valueFontSize: 58,
          valueColor: CORAL,
          valueShadow: { radius: 0, offsetX: 3, offsetY: 3, color: INK },
          onCommit: (value: number): void => {
            void this.applyBpm(value);
          }
        })
        Text('BPM').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
        Blank()
        ActionButton({
          active: this.leader && !this.busy, controlWidth: 76, controlHeight: 46, fill: Color.Transparent,
          preserveDisabledAppearance: !this.leader,
          accessibilityLabel: `拍号 ${this.beats}/${this.unit}，编辑拍号`,
          action: () => {
            if (this.leader && !this.busy) {
              this.meterEditorVisible = true;
            }
          }
        }) {
          Text(`${this.beats}/${this.unit}`).width(76).height(46).fontSize(27).fontWeight(900)
            .fontStyle(FontStyle.Italic).fontColor(CORAL).textAlign(TextAlign.Center)
            .textShadow(!this.leader || !this.busy ? { radius: 0, offsetX: 2, offsetY: 2, color: INK } :
              { radius: 0, color: '#00000000' })
        }
        Image($rawfile(this.beatUnitIconPath()))
          .width(38)
          .height(46)
          .objectFit(ImageFit.Contain)
      }.height(65).width('100%')
      Row() {
        Row({ space: this.beatPointGap() }) {
          ForEach(Array.from({ length: this.beats }, (_v: number, i: number) => i), (i: number) => {
            this.beatPoint(i)
          }, (i: number) => `${i}`)
        }
        .width(this.beatPointGroupWidth())
        .height(BEAT_POINT_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(BEAT_POINT_ROW_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .onAreaChange((_oldArea, area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.beatPointAreaWidth) > 0.5) {
          this.beatPointAreaWidth = width;
        }
      })
      Stack({ alignContent: Alignment.TopStart }) {
        Text(this.visualCountIn ? '准备拍 · 下一小节出发' :
          this.visualPlaying ? 'STEP BY STEP · SAME BEAT' : 'READY TO WALK?')
          .fontSize(9).fontWeight(FontWeight.Bold).letterSpacing(1).width('100%')
          .height(WALK_RELOAD_ROW_HEIGHT).opacity(1 - this.topReloadOpacity)
          .accessibilityLevel(this.topReloadPending ? 'no' : 'yes')
        Row({ space: WALK_RELOAD_TOP_GAP }) {
          LoadingProgress().width(WALK_RELOAD_SPINNER_SIZE).height(WALK_RELOAD_SPINNER_SIZE)
            .color('#6F6B64').enableLoading(this.topReloadPending).accessibilityLevel('no')
          Text(this.topReloadText).fontSize(11).fontColor('#6F6B64').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').height(WALK_RELOAD_ROW_HEIGHT).opacity(this.topReloadOpacity)
          .accessibilityGroup(true).accessibilityText(this.topReloadText)
          .accessibilityLevel(this.topReloadPending ? 'yes' : 'no-hide-descendants')
      }.width('100%').height(WALK_RELOAD_ROW_HEIGHT).hitTestBehavior(HitTestMode.Block)
    }
    .width('100%').padding({ left: 14, right: 14, top: 8 + this.topSafeInset, bottom: 8 })
    .backgroundColor(WHITE)
    .border({ width: { bottom: 3 }, color: INK })
    .translate({ y: this.chromeVisible ? 0 : -TOP_PANEL_HIDDEN_OFFSET - this.topSafeInset })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  @Builder
  private programCard(key: string, name: string, raw: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width(PROGRAM_CARD_WIDTH).height(PROGRAM_CARD_HEIGHT).backgroundColor(INK).borderRadius(6)
        .translate({ x: PROGRAM_CARD_SHADOW, y: PROGRAM_CARD_SHADOW }).hitTestBehavior(HitTestMode.None)
      Column({ space: PROGRAM_CARD_INNER_SPACE }) {
        Row({ space: 3 }) {
          Text(name).fontSize(12).fontWeight(900).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.selectedProgramKey === key ? '#FFFFFF' : INK).layoutWeight(1)
          // Keep a fixed status slot so selecting a card never reflows the three text rows.
          Stack({ alignContent: Alignment.Center }) {
            LoadingProgress().width(WALK_RELOAD_SPINNER_SIZE).height(WALK_RELOAD_SPINNER_SIZE)
              .color(this.selectedProgramKey === key ? '#FFFFFF' : INK)
              .enableLoading(this.switchingProgramKey === key && this.bottomReloadPending)
              .opacity(this.switchingProgramKey === key ? this.bottomReloadOpacity : 0)
              .accessibilityLevel('no').hitTestBehavior(HitTestMode.None)
            if (this.selectedProgramKey === key) {
              Text('✓').fontSize(14).fontWeight(900).fontColor('#FFFFFF')
                .opacity(this.switchingProgramKey === key ? 1 - this.bottomReloadOpacity : 1)
            }
          }.width(PROGRAM_CARD_STATUS_SIZE).height(PROGRAM_CARD_STATUS_SIZE)
        }.width('100%').height(PROGRAM_CARD_ROW1_HEIGHT)
        Text(this.programMeterSummary(raw)).fontSize(10).fontWeight(FontWeight.Bold)
          .fontColor(this.selectedProgramKey === key ? '#FFFFFF' : INK).width('100%')
          .height(PROGRAM_CARD_ROW2_HEIGHT).lineHeight(PROGRAM_CARD_ROW2_HEIGHT)
        Row({ space: 3 }) {
          ForEach(this.programStyleKeys(raw).slice(0, 2), (styleKey: string) => {
            Text(styleByKey(styleKey).name).fontSize(9).minFontSize(7).maxFontSize(9)
              .maxLines(1).fontWeight(900).fontColor(INK).width(34).height(16).textAlign(TextAlign.Center)
              .padding({ left: 3, right: 3 })
              .backgroundColor(styleByKey(styleKey).color).borderRadius(3)
          }, (styleKey: string) => styleKey)
          if (this.programStyleKeys(raw).length > 2) {
            Text('…').width(12).fontSize(12).fontWeight(900).fontColor(this.selectedProgramKey === key ? '#FFFFFF' : INK)
          }
        }.width('100%').height(PROGRAM_CARD_ROW3_HEIGHT).alignItems(VerticalAlign.Center)
      }.width(PROGRAM_CARD_WIDTH).height(PROGRAM_CARD_HEIGHT).padding(7)
        .justifyContent(FlexAlign.Start)
        .backgroundColor(this.selectedProgramKey === key ? CORAL : '#FFFFFF')
        .border({ width: 1.2, color: INK }).borderRadius(6).alignItems(HorizontalAlign.Start)
    }.width(PROGRAM_CARD_WIDTH + PROGRAM_CARD_SHADOW).height(PROGRAM_CARD_HEIGHT + PROGRAM_CARD_SHADOW)
      .id(`walk-program-${key}`).onClick(() => { void this.chooseDrumArrangement(key, raw, name); })
  }

  @Builder
  private programDrawer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(PROGRAM_DRAWER_HEIGHT).backgroundColor(INK).borderRadius(8)
        .translate({ x: 3, y: 3 }).hitTestBehavior(HitTestMode.None)
      Column({ space: 6 }) {
        Row({ space: PROGRAM_DRAWER_GAP }) {
          Text('本编排').width(PROGRAM_CARD_WIDTH + PROGRAM_CARD_SHADOW).fontSize(11).fontWeight(900)
          Text('我的编排').fontSize(11).fontWeight(900).layoutWeight(1)
          Button('×', { type: ButtonType.Normal }).width(24).height(22).padding(0).fontSize(22)
            .fontColor(INK).backgroundColor(Color.Transparent).onClick(() => { this.showStyles = false; })
        }.width('100%').height(22)
        Row({ space: PROGRAM_DRAWER_GAP }) {
          this.programCard('base', this.walkBaseProgramName, this.walkBaseProgram)
          Scroll() {
            Row({ space: 8 }) {
              if (this.savedDrumPrograms.length === 0) {
                Text('还没有保存的节奏').fontSize(11).fontColor('#625C54').width(140).height(PROGRAM_CARD_HEIGHT)
              }
              ForEach(this.savedDrumPrograms, (entry: SavedDrumProgram) => {
                this.programCard(entry.id, entry.name, entry.program)
              }, (entry: SavedDrumProgram) => `${entry.id}:${this.savedDrumProgramsRevision}`)
            }.padding({ right: PROGRAM_CARD_SHADOW })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
            .height(PROGRAM_CARD_HEIGHT + PROGRAM_CARD_SHADOW).clip(true)
        }.width('100%').alignItems(VerticalAlign.Top)
      }.width('100%').height(PROGRAM_DRAWER_HEIGHT).padding(8).backgroundColor(LILAC)
        .border({ width: 1.5, color: INK }).borderRadius(8)
    }.width('100%').height(PROGRAM_DRAWER_HEIGHT + PROGRAM_CARD_SHADOW).id('walk-program-drawer')
  }

  @Builder
  private programMeterConfirmOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('切换这套编排？').fontSize(23).fontWeight(900).fontColor(INK).width('100%')
        Text(this.confirmProgramName).fontSize(16).fontWeight(900).fontColor(INK).width('100%')
        Text(`将从 ${this.beats}/${this.unit} 切换为 ${parseDrumProgram(this.confirmProgramRaw).beatsPerBar}/${parseDrumProgram(this.confirmProgramRaw).beatUnit}，BPM 保持 ${this.bpm}`)
          .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
        Row({ space: 12 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).backgroundColor(PAPER)
            .fontColor(INK).border({ width: 1.5, color: INK }).borderRadius(6)
            .onClick(() => { this.showProgramMeterConfirm = false; })
          Button('切换编排', { type: ButtonType.Normal }).layoutWeight(1).height(42).backgroundColor(CORAL)
            .fontColor(INK).fontWeight(900).border({ width: 1.5, color: INK }).borderRadius(6)
            .onClick(() => { void this.confirmDrumArrangement(); })
        }.width('100%')
      }.width('86%').padding(20).backgroundColor(PAPER).border({ width: 2, color: INK }).borderRadius(8)
    }.width('100%').height('100%').backgroundColor('#72000000').zIndex(100)
  }

  @Builder
  private bottomPanel() {
    Column({ space: 7 }) {
      if (this.showStyles && this.rhythm === 3) {
        this.programDrawer()
      }
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          if (this.rhythm === 3) {
            ActionButton({
              active: this.leader, controlWidth: 38, controlHeight: 38, fill: this.showStyles ? LILAC : PAPER,
              preserveDisabledAppearance: !this.leader,
              accessibilityLabel: this.showStyles ? '收起鼓机编排' : '展开鼓机编排',
              lineWidth: 1.5, lineColor: INK, cornerRadius: 5, inkShadow: CONTROL_SHADOW,
              action: () => this.toggleStyleDrawer()
            }) {
              Column({ space: 3 }) {
                Row().width(19).height(3).backgroundColor(INK).borderRadius(2)
                Row().width(14).height(3).backgroundColor(INK).borderRadius(2)
                Row().width(19).height(3).backgroundColor(INK).borderRadius(2)
              }.alignItems(HorizontalAlign.Start)
            }
            Text('编排').fontSize(9).fontWeight(FontWeight.Bold)
          } else {
            ActionButton({
              active: this.leader, controlWidth: 38, controlHeight: 38, fill: PAPER,
              preserveDisabledAppearance: !this.leader,
              accessibilityLabel: `切换音色，当前${this.sounds[this.sound]}`,
              lineWidth: 1.5, lineColor: INK, cornerRadius: 5, inkShadow: CONTROL_SHADOW,
              action: () => { void this.changeSound(); }
            }) {
              Text('♪').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
            }
            Text(this.sounds[this.sound]).fontSize(9).fontWeight(FontWeight.Bold)
          }
        }
        ActionButton({
          active: this.leader && !this.busy && this.bpm > 40, controlWidth: 38, controlHeight: 38, fill: PAPER,
          preserveDisabledAppearance: !this.leader,
          accessibilityLabel: '降低 BPM',
          lineWidth: 1.5, lineColor: INK, cornerRadius: 5, inkShadow: CONTROL_SHADOW,
          action: () => { void this.changeBpm(-1); }
        }) {
          Text('−').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
        }
        ActionButton({
          active: this.leader && !this.busy, controlWidth: 68, controlHeight: 68, fill: CORAL,
          preserveDisabledAppearance: !this.leader,
          accessibilityLabel: this.state === 'playing' || this.state === 'countdown' ? '停止播放' : '开始播放',
          lineWidth: 2, lineColor: INK, cornerRadius: 34,
          inkShadow: { radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 3, color: INK },
          action: () => { void this.toggle(); }
        }) {
          Image($rawfile(this.state === 'playing' || this.state === 'countdown' ?
            'comic/icons/stop.svg' : 'comic/icons/play.svg'))
            .width(32).height(32).objectFit(ImageFit.Contain)
        }
        ActionButton({
          active: this.leader && !this.busy && this.bpm < 240, controlWidth: 38, controlHeight: 38, fill: PAPER,
          preserveDisabledAppearance: !this.leader,
          accessibilityLabel: '提高 BPM',
          lineWidth: 1.5, lineColor: INK, cornerRadius: 5, inkShadow: CONTROL_SHADOW,
          action: () => { void this.changeBpm(1); }
        }) {
          Text('+').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
        }
        Column({ space: 2 }) {
          ActionButton({
            active: this.recordingState !== 'stopping', controlWidth: 38, controlHeight: 38, fill: PAPER,
            accessibilityLabel: this.recordingState === 'recording' ? '停止本机录制' : '开始本机录制',
            lineWidth: 1.5, lineColor: INK, cornerRadius: 5, inkShadow: CONTROL_SHADOW,
            action: () => this.requestRecording()
          }) {
            if (this.recordingState === 'recording') {
              Rect().width(15).height(15).radius(2).fill(CORAL).stroke(INK).strokeWidth(1.2)
            } else {
              Circle().width(17).height(17).fill(CORAL).stroke(INK).strokeWidth(1.2)
            }
          }
          Text(this.recordingState === 'recording' ? '停止' : '录制').fontSize(9).fontWeight(FontWeight.Bold)
        }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).alignItems(VerticalAlign.Center)
      Stack({ alignContent: Alignment.Center }) {
        Text(this.leader ? (this.state === 'idle' ? '点击播放 · 全队一起出发' :
          this.state === 'paused' ? '已暂停 · 点击继续' :
            this.visualCountIn ? '准备拍…' : 'ONEBEAT / 同拍进行中') : '节奏由队长控制')
          .fontSize(10).fontWeight(FontWeight.Bold).fontStyle(FontStyle.Italic).letterSpacing(0.5)
          .height(WALK_RELOAD_ROW_HEIGHT).opacity(1 - this.bottomReloadOpacity)
          .accessibilityLevel(this.bottomReloadPending ? 'no' : 'yes')
        Row({ space: WALK_RELOAD_BOTTOM_GAP }) {
          LoadingProgress().width(WALK_RELOAD_SPINNER_SIZE).height(WALK_RELOAD_SPINNER_SIZE)
            .color('#6F6B64').enableLoading(this.bottomReloadPending).accessibilityLevel('no')
          Text(this.bottomReloadText).fontSize(11).fontColor('#6F6B64').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').height(WALK_RELOAD_ROW_HEIGHT).justifyContent(FlexAlign.Center)
          .opacity(this.bottomReloadOpacity).accessibilityGroup(true).accessibilityText(this.bottomReloadText)
          .accessibilityLevel(this.bottomReloadPending ? 'yes' : 'no-hide-descendants')
      }.width('100%').height(WALK_RELOAD_ROW_HEIGHT).hitTestBehavior(HitTestMode.Block)
    }
    .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 12 + this.bottomSafeInset })
    .backgroundColor(WHITE)
    .border({ width: { top: 3 }, color: INK })
    .translate({ y: this.chromeVisible ? 0 : BOTTOM_PANEL_HIDDEN_OFFSET + this.bottomSafeInset +
      (this.showStyles && this.rhythm === 3 ? PROGRAM_DRAWER_HEIGHT + 7 : 0) })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      WalkScene({
        members: this.members,
        bpm: this.bpm,
        isPlaying: this.state === 'playing' || this.state === 'countdown',
        scrollSpeed: this.state === 'playing' || this.state === 'countdown' ? this.bpm * 1.2 : 0,
        sceneKey: this.sceneKey
      })
        .width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onClick(() => this.toggleChrome())
      this.countdownOverlay()
      Column() {
        this.topPanel()
        Blank().hitTestBehavior(HitTestMode.None)
        this.bottomPanel()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(50)
      if (this.recordingState === 'recording' ||
        (this.recordingState === 'stopping' && this.recordingCaptureActive)) {
        RecordingOverlay({
          elapsedMs: this.recordingElapsedMs,
          stopping: this.recordingState === 'stopping',
          chromeVisible: this.chromeVisible,
          topSafeInset: this.topSafeInset,
          bottomSafeInset: this.bottomSafeInset,
          onStop: (): void => { void this.stopRecording(); }
        })
      }
      if (this.recordingState === 'preparing') {
        Column() {
          Blank().hitTestBehavior(HitTestMode.None)
          Row() {
            Row({ space: 10 }) {
              Text('正在准备录制…').fontSize(12).fontWeight(FontWeight.Bold).fontColor(PAPER)
              Button('取消', { type: ButtonType.Normal }).height(30).fontSize(11).fontWeight(900)
                .fontColor(INK).backgroundColor(PAPER).borderRadius(15)
                .onClick(() => { void this.cancelRecordingPreparation(); })
            }.height(RECORD_PILL_HEIGHT).padding({ left: 14, right: 6, top: 6, bottom: 6 })
              .backgroundColor('#D9171B1F').borderRadius(24).id('recording-prepare-pill')
          }.width('100%').justifyContent(FlexAlign.Center)
            .padding({ bottom: RECORD_STOP_BOTTOM + this.bottomSafeInset })
            .hitTestBehavior(HitTestMode.Transparent)
        }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent).zIndex(60)
      }
      if (this.showRecordIntro) {
        this.recordingIntroOverlay()
      }
      if (!this.recordingCaptureActive && !this.showDiscardRecordingConfirm &&
        (this.showRecordingSaving || this.showRecordingSaved || this.showSaveRecovery)) {
        this.recordingSaveOverlay()
      }
      if (this.showRecordingError) {
        this.recordingErrorOverlay()
      }
      if (this.showDiscardRecordingConfirm) {
        this.discardRecordingConfirmOverlay()
      }
      if (this.showExitConfirm) {
        this.exitConfirmOverlay()
      }
      if (this.showProgramMeterConfirm) {
        this.programMeterConfirmOverlay()
      }
      if (this.meterEditorVisible) {
        MeterEditorOverlay({
          initialBeats: this.beats,
          initialUnit: this.unit,
          onChange: (beats: number, unit: number): void => { void this.applyMeter(beats, unit); },
          onDismiss: (): void => { this.meterEditorVisible = false; }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
