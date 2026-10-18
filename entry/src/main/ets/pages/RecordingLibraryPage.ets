import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { RecordingClip, RecordingScope } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import { MAX_MIC_SHIFT_US, RECORDING_MIX_VERSION } from '../recording/RecordingMixer';
import { PendingVideoShare, RecordingShareService } from '../sharing/RecordingShareService';
import { ShareCheckInResult } from '../store/ShareCheckInStore';
import { formatTrialExpiry } from '../store/EntitlementStore';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import { ComicButton, PAPER, INK, CORAL, LILAC, WHITE, CONTROL_SHADOW, CARD_SHADOW } from '../components/ComicKit';
import { ShareCalendarSheet } from '../components/ShareCalendarSheet';

const LIBRARY_SIDE_INSET: number = 20;
const LIBRARY_HERO_HEIGHT: number = 154;
const VIDEO_PREVIEW_HEIGHT: number = 242;
const SHARE_SHEET_WIDTH: string = '90%';
const SHARE_SHEET_MAX_HEIGHT: string = '88%';
const CALENDAR_ENTRY_HEIGHT: number = 42;
const PREVIEW_LOAD_TIMEOUT_MS: number = 8000;
const MIC_SHIFT_LIMIT_MS: number = MAX_MIC_SHIFT_US / 1000;
const MIC_SHIFT_STEP_MS: number = 10;
const MIC_ALIGNMENT_RULER_HEIGHT: number = 34;
const MIC_ALIGNMENT_TICK_COUNT: number = 13;

interface RecordingLibraryParams {
  clipId?: string;
  scope?: RecordingScope;
}

interface PreviewContinuation {
  clipId: string;
  path: string;
  timeSeconds: number;
  playing: boolean;
  prepared: boolean;
}

@Entry
@Component
struct RecordingLibraryPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('recordingLibraryEpoch') @Watch('refresh') libraryEpoch: number = 0;
  @StorageLink('recordingShareEpoch') @Watch('refreshPending') shareEpoch: number = 0;
  @StorageLink('sessionEpoch') @Watch('refreshPlayback') sessionEpoch: number = 0;
  @State clips: RecordingClip[] = [];
  @State selectedId: string = '';
  @State previewMuted: boolean = false;
  @State scope: RecordingScope = 'solo';
  @State micGain: number = 1;
  @State micShiftMs: number = 0;
  @State renderingAudio: boolean = false;
  @State previewLoading: boolean = false;
  @State previewReady: boolean = false;
  @State previewCoverVisible: boolean = true;
  @State calendarVisible: boolean = false;
  @State busy: boolean = false;
  @State pauseConfirmVisible: boolean = false;
  @State deleteConfirmVisible: boolean = false;
  @State sharePanelVisible: boolean = false;
  @State rulesVisible: boolean = false;
  @State practiceActive: boolean = false;
  @State pauseAction: string = 'share';
  @State pendingId: string = '';
  @State pendingClipId: string = '';
  @State pendingHandedOff: boolean = false;
  @State resultTitle: string = '';
  @State resultDetail: string = '';
  private videoController: VideoController = new VideoController();
  private active: boolean = true;
  private audioRenderSequence: number = 0;
  private audioRenderTask: Promise<RecordingClip | undefined> | undefined = undefined;
  private coverLoadTask: Promise<void> | undefined = undefined;
  private requestedMicGain: number = 1;
  private requestedMicShiftUs: number = 0;
  private previewTimeSeconds: number = 0;
  private previewPlaying: boolean = false;
  private coverPlayRequested: boolean = false;
  private previewContinuation: PreviewContinuation | undefined = undefined;
  private previewLoadTimer: number = -1;
  private alignmentCanvas: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private alignmentCanvasReady: boolean = false;
  private alignmentCanvasWidth: number = 220;

  aboutToAppear(): void {
    this.active = true;
    const params = router.getParams() as RecordingLibraryParams;
    this.scope = params?.scope === 'team' ? 'team' : 'solo';
    this.selectedId = params?.clipId ?? '';
    this.refresh();
    this.refreshPending();
    this.refreshPlayback();
  }

  onPageShow(): void {
    this.active = true;
    this.refresh();
    this.refreshPending();
    this.refreshPlayback();
  }

  onPageHide(): void {
    this.active = false;
    this.audioRenderSequence++;
    this.stopPreview();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.audioRenderSequence++;
    this.stopPreview();
  }

  onBackPress(): boolean {
    if (this.busy || this.renderingAudio) { return true; }
    if (this.calendarVisible) { this.calendarVisible = false; return true; }
    if (this.pauseConfirmVisible) { this.pauseConfirmVisible = false; return true; }
    if (this.deleteConfirmVisible) { this.deleteConfirmVisible = false; return true; }
    if (this.sharePanelVisible) { this.sharePanelVisible = false; return true; }
    return false;
  }

  private hostContext(): common.UIAbilityContext {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { throw new Error('无法获取应用上下文'); }
    return context as common.UIAbilityContext;
  }

  refresh(): void {
    // A render commits the repository before its promise resolves. Delay this
    // projection so the live player can bookmark its latest position first.
    if (this.renderingAudio) { return; }
    this.clips = RecordingRepository.list(this.scope);
    if (!this.clips.some((clip: RecordingClip) => clip.id === this.selectedId)) {
      this.selectedId = this.clips.length > 0 ? this.clips[0].id : '';
    }
    if (!this.renderingAudio) {
      this.micGain = this.selectedClip()?.renderedGain ?? 1;
      this.micShiftMs = Math.round((this.selectedClip()?.renderedMicShiftUs ?? 0) / 1000);
      this.requestedMicGain = this.desiredMicGain();
      this.requestedMicShiftUs = this.desiredMicShiftUs();
      this.drawMicAlignmentRuler();
    }
    this.prepareMissingCovers();
  }

  private prepareMissingCovers(): void {
    if (this.coverLoadTask !== undefined) { return; }
    const ids = this.clips.filter((clip: RecordingClip) => clip.coverPath === undefined)
      .map((clip: RecordingClip) => clip.id);
    if (ids.length === 0) { return; }
    const task = this.loadMissingCovers(ids).finally(() => {
      if (this.coverLoadTask === task) { this.coverLoadTask = undefined; }
    });
    this.coverLoadTask = task;
  }

  private async loadMissingCovers(ids: string[]): Promise<void> {
    for (const id of ids) {
      try {
        await RecordingRepository.ensureCover(id);
      } catch (error) {
        logUserFailure('recording-cover', error);
      }
    }
  }

  refreshPending(): void {
    const pending = RecordingShareService.getPending();
    this.pendingId = pending?.id ?? '';
    this.pendingClipId = pending?.clipId ?? '';
    this.pendingHandedOff = pending?.handedOff ?? false;
    if (this.pendingId.length > 0 && this.active) { this.sharePanelVisible = true; }
  }

  private selectedClip(): RecordingClip | undefined {
    return this.clips.find((clip: RecordingClip) => clip.id === this.selectedId);
  }

  private videoSource(): string {
    const clip = this.selectedClip();
    return clip === undefined ? '' : fileUri.getUriFromPath(clip.path);
  }

  private durationLabel(durationMs: number): string {
    const seconds = Math.floor(Math.max(0, durationMs) / 1000);
    return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
  }

  private dateLabel(timeMs: number): string {
    const time = new Date(timeMs);
    return `${time.getMonth() + 1}月${time.getDate()}日 ${time.getHours().toString().padStart(2, '0')}:${time.getMinutes().toString().padStart(2, '0')}`;
  }

  private practicePlaying(): boolean {
    const state = AppSession.get()?.controller.state;
    return state === 'playing' || state === 'countdown';
  }

  refreshPlayback(): void {
    const playing = this.practicePlaying();
    if (playing) {
      this.stopPreview();
      this.previewReady = false;
    }
    this.practiceActive = playing;
    if (!playing) { this.prepareSelectedPreview(); }
  }

  private requestPreview(): void {
    if (this.busy || this.renderingAudio) { return; }
    if (!this.practicePlaying()) { this.refreshPlayback(); return; }
    if (AppSession.get()?.controller.isLeader) {
      this.pauseAction = 'preview';
      this.pauseConfirmVisible = true;
    } else {
      showUserNotice('请等队长暂停后再预览，视频已保存在本机', 'recording-preview-playing');
    }
  }

  private stopPreview(): void {
    this.previewPlaying = false;
    this.coverPlayRequested = false;
    this.cancelPreviewContinuation();
    try { this.videoController.pause(); } catch (_error) {}
  }

  private cancelPreviewContinuation(): void {
    if (this.previewLoadTimer >= 0) { clearTimeout(this.previewLoadTimer); }
    this.previewLoadTimer = -1;
    this.previewContinuation = undefined;
    this.previewLoading = false;
  }

  private watchPreviewLoad(id: string, path: string): void {
    this.previewLoadTimer = setTimeout(() => {
      this.previewLoadTimer = -1;
      if (!this.previewSourceMatches(id, path) || this.previewContinuation?.path !== path) { return; }
      // A missing native prepare/seek event must not disable MIC editing forever.
      this.cancelPreviewContinuation();
      showUserNotice('新音量已生成，预览加载较慢，可点播放或重新打开作品', 'recording-preview-load');
    }, PREVIEW_LOAD_TIMEOUT_MS);
  }

  private previewSourceMatches(id: string, path: string): boolean {
    return this.active && this.selectedId === id && this.selectedClip()?.path === path;
  }

  private previewProgress(id: string, path: string, time: number): void {
    if (!this.previewSourceMatches(id, path) || !Number.isFinite(time)) { return; }
    const resume = this.previewContinuation;
    if (resume !== undefined) {
      // Programmatic VideoController seeks report completion through onUpdate;
      // onSeeked is emitted by the built-in progress slider on some devices.
      if (resume.prepared && resume.path === path && Math.floor(time) === resume.timeSeconds) {
        this.finishPreviewContinuation(id, path);
      }
      return;
    }
    this.previewTimeSeconds = Math.max(0, time);
  }

  private previewStarted(id: string, path: string): void {
    if (this.previewSourceMatches(id, path)) {
      this.coverPlayRequested = false;
      this.previewCoverVisible = false;
      this.previewPlaying = true;
    }
  }

  private previewPaused(id: string, path: string): void {
    if (this.previewSourceMatches(id, path)) { this.previewPlaying = false; }
  }

  private previewFinished(id: string, path: string): void {
    if (!this.previewSourceMatches(id, path)) { return; }
    this.previewPlaying = false;
    this.previewTimeSeconds = 0;
    this.previewCoverVisible = true;
    this.cancelPreviewContinuation();
  }

  private previewPrepared(id: string, path: string): void {
    const resume = this.previewContinuation;
    if (!this.previewSourceMatches(id, path) || this.practicePlaying()) { return; }
    this.previewReady = true;
    if (resume === undefined) {
      if (this.coverPlayRequested) {
        this.coverPlayRequested = false;
        this.videoController.start();
      }
      return;
    }
    if (resume.clipId !== id || resume.path !== path) { return; }
    resume.prepared = true;
    if (resume.timeSeconds > 0) {
      // Wait for the seek update before starting audio; starting immediately
      // after prepare can briefly replay the opening beat on slower players.
      this.videoController.setCurrentTime(resume.timeSeconds, SeekMode.Accurate);
    } else {
      this.finishPreviewContinuation(id, path);
    }
  }

  private previewSeeked(id: string, path: string, time: number): void {
    const resume = this.previewContinuation;
    if (resume !== undefined && resume.prepared && resume.clipId === id && resume.path === path &&
      Math.floor(time) === resume.timeSeconds) {
      this.finishPreviewContinuation(id, path);
    } else {
      this.previewProgress(id, path, time);
    }
  }

  private finishPreviewContinuation(id: string, path: string): void {
    const resume = this.previewContinuation;
    if (resume === undefined || resume.clipId !== id || resume.path !== path ||
      !this.previewSourceMatches(id, path)) { return; }
    this.cancelPreviewContinuation();
    this.previewTimeSeconds = resume.timeSeconds;
    if (resume.playing && !this.practicePlaying()) { this.videoController.start(); }
  }

  private selectClip(clip: RecordingClip): void {
    if (this.busy || this.renderingAudio || this.selectedId === clip.id) { return; }
    this.stopPreview();
    this.videoController = new VideoController();
    this.previewReady = false;
    this.coverPlayRequested = false;
    this.audioRenderSequence++;
    this.selectedId = clip.id;
    this.previewTimeSeconds = 0;
    this.previewCoverVisible = true;
    this.micGain = clip.renderedGain ?? 1;
    this.micShiftMs = Math.round((clip.renderedMicShiftUs ?? 0) / 1000);
    this.requestedMicGain = this.desiredMicGain();
    this.requestedMicShiftUs = this.desiredMicShiftUs();
    this.drawMicAlignmentRuler();
    this.previewMuted = false;
    this.prepareSelectedPreview();
  }

  private prepareSelectedPreview(): void {
    const clip = this.selectedClip();
    if (clip === undefined || !this.active || this.busy || this.renderingAudio || this.practicePlaying() ||
      this.pendingClipId === clip.id || !this.hasSeparateAudio() ||
      (clip.renderedMixVersion ?? 0) >= RECORDING_MIX_VERSION) { return; }
    void this.renderSelectedAudio();
  }

  private togglePreviewSound(): void {
    if (this.practicePlaying()) {
      showUserNotice('练习仍在进行，请先暂停后试听视频', 'recording-preview-sound');
      return;
    }
    this.previewMuted = !this.previewMuted;
  }

  private hasSeparateAudio(): boolean {
    const clip = this.selectedClip();
    return clip?.sourcePath !== undefined && clip.micPath !== undefined && clip.innerPath !== undefined;
  }

  private canAdjustMic(): boolean {
    return this.hasSeparateAudio() && !this.busy && !this.practiceActive &&
      this.pendingClipId !== this.selectedId;
  }

  private desiredMicGain(): number {
    return Math.max(0, Math.min(2, Math.round(this.micGain * 100) / 100));
  }

  private desiredMicShiftUs(): number {
    return Math.max(-MIC_SHIFT_LIMIT_MS,
      Math.min(MIC_SHIFT_LIMIT_MS, Math.round(this.micShiftMs))) * 1000;
  }

  private clipHasSeparateAudio(clip: RecordingClip): boolean {
    return clip.sourcePath !== undefined && clip.micPath !== undefined && clip.innerPath !== undefined;
  }

  private renderMatches(clip: RecordingClip, gain: number, micShiftUs: number): boolean {
    return Math.abs((clip.renderedGain ?? 1) - gain) < 0.001 &&
      (clip.renderedMicShiftUs ?? 0) === micShiftUs &&
      ((clip.renderedMixVersion ?? 0) >= RECORDING_MIX_VERSION || !this.clipHasSeparateAudio(clip));
  }

  private renderSelectedAudio(): Promise<RecordingClip | undefined> {
    this.requestedMicGain = this.desiredMicGain();
    this.requestedMicShiftUs = this.desiredMicShiftUs();
    if (this.audioRenderTask !== undefined) { return this.audioRenderTask; }
    const clip = this.selectedClip();
    if (clip === undefined) { return Promise.resolve(undefined); }
    if (this.renderMatches(clip, this.requestedMicGain, this.requestedMicShiftUs)) {
      return Promise.resolve(clip);
    }
    if (this.practicePlaying()) {
      showUserNotice('请先暂停练习，再调整视频中的麦克风声音或对齐', 'recording-mix-playing');
      return Promise.resolve(undefined);
    }
    this.renderingAudio = true;
    const sequence = ++this.audioRenderSequence;
    const selectedId = this.selectedId;
    const task: Promise<RecordingClip | undefined> = this.drainAudioEdits(clip, selectedId, sequence)
      .catch((error: Object): undefined => {
        logUserFailure('recording-mix', error);
        if (this.active && this.audioRenderSequence === sequence && this.selectedId === selectedId) {
          const latest = RecordingRepository.get(selectedId);
          if (latest !== undefined) {
            this.micGain = latest.renderedGain ?? 1;
            this.micShiftMs = Math.round((latest.renderedMicShiftUs ?? 0) / 1000);
            this.requestedMicGain = this.desiredMicGain();
            this.requestedMicShiftUs = this.desiredMicShiftUs();
            this.applyRenderedClip(latest, latest.renderedGain ?? 1, latest.renderedMicShiftUs ?? 0);
          }
          showUserNotice('声音处理未完成，原视频和独立音轨已保留，请重试', 'recording-mix');
        }
        return undefined;
      }).finally(() => {
        if (this.audioRenderTask === task) {
          this.audioRenderTask = undefined;
          this.renderingAudio = false;
          if (this.active && (this.audioRenderSequence !== sequence || this.selectedId !== selectedId)) {
            this.refresh();
          }
        }
      });
    this.audioRenderTask = task;
    return task;
  }

  private async drainAudioEdits(initial: RecordingClip, selectedId: string,
    sequence: number): Promise<RecordingClip | undefined> {
    let current = initial;
    while (this.active && this.audioRenderSequence === sequence && this.selectedId === selectedId) {
      const gain = this.requestedMicGain;
      const micShiftUs = this.requestedMicShiftUs;
      if (this.renderMatches(current, gain, micShiftUs)) {
        this.applyRenderedClip(current, gain, micShiftUs);
        return current;
      }
      // The repository always rebuilds from immutable stems. Its cached
      // floating-point MIC residual avoids repeating echo fitting; if the user
      // keeps editing, this loop skips intermediate preview source swaps.
      const updated = await RecordingRepository.render(current, gain, micShiftUs);
      if (!this.active || this.audioRenderSequence !== sequence || this.selectedId !== selectedId) {
        return updated;
      }
      current = updated;
      if (this.renderMatches(updated, this.requestedMicGain, this.requestedMicShiftUs)) {
        this.applyRenderedClip(updated, gain, micShiftUs);
        return updated;
      }
    }
    return undefined;
  }

  private applyRenderedClip(updated: RecordingClip, gain: number, micShiftUs: number): void {
    const displayed = this.selectedClip();
    if (displayed !== undefined && updated.path !== displayed.path) {
      this.cancelPreviewContinuation();
      this.previewContinuation = {
        clipId: updated.id, path: updated.path,
        // ArkUI reports native video progress as whole seconds. Seeking
        // to a fractional zero may produce no update and cannot be awaited.
        timeSeconds: Math.floor(Math.min(this.previewTimeSeconds, Math.max(0, updated.durationMs / 1000 - 0.05))),
        playing: this.previewPlaying && !this.practicePlaying(), prepared: false
      };
      this.previewLoading = true;
      this.videoController = new VideoController();
      this.previewReady = false;
      this.coverPlayRequested = false;
      this.watchPreviewLoad(updated.id, updated.path);
    }
    this.clips = RecordingRepository.list(this.scope);
    if (Math.abs(this.desiredMicGain() - gain) < 0.001 && this.desiredMicShiftUs() === micShiftUs) {
      this.micGain = gain;
      this.micShiftMs = Math.round(micShiftUs / 1000);
    }
    this.drawMicAlignmentRuler();
  }

  private changeMicGain(value: number, mode: SliderChangeMode): void {
    if (!this.canAdjustMic()) { return; }
    this.micGain = Math.max(0, Math.min(2, value));
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { void this.renderSelectedAudio(); }
  }

  private changeMicShift(value: number, mode: SliderChangeMode): void {
    if (!this.canAdjustMic()) { return; }
    this.micShiftMs = Math.max(-MIC_SHIFT_LIMIT_MS,
      Math.min(MIC_SHIFT_LIMIT_MS, Math.round(value / MIC_SHIFT_STEP_MS) * MIC_SHIFT_STEP_MS));
    this.drawMicAlignmentRuler();
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { void this.renderSelectedAudio(); }
  }

  private nudgeMicShift(deltaMs: number): void {
    if (!this.canAdjustMic()) { return; }
    this.changeMicShift(this.micShiftMs + deltaMs, SliderChangeMode.Click);
  }

  private micShiftLabel(): string {
    const clip = this.selectedClip();
    const automatic = clip?.autoMicShiftUs ?? 0;
    const reliable = clip?.autoMicShiftReliable === true;
    if (this.micShiftMs < 0) {
      return `${reliable ? '自动基准上' : '人声'}提前 ${Math.abs(this.micShiftMs)} 毫秒`;
    }
    if (this.micShiftMs > 0) {
      return `${reliable ? '自动基准上' : '人声'}延后 ${this.micShiftMs} 毫秒`;
    }
    if (!reliable) { return '人声不提前或延后'; }
    if (automatic < 0) { return `已自动提前 ${Math.round(Math.abs(automatic) / 1000)} 毫秒`; }
    if (automatic > 0) { return `已自动延后 ${Math.round(automatic / 1000)} 毫秒`; }
    return '已自动对齐，可继续微调';
  }

  private drawMicAlignmentRuler(): void {
    if (!this.alignmentCanvasReady) { return; }
    const width = this.alignmentCanvasWidth;
    const height = MIC_ALIGNMENT_RULER_HEIGHT;
    const middle = height / 2;
    this.alignmentCanvas.clearRect(0, 0, width, height);
    this.alignmentCanvas.strokeStyle = '#71817D';
    this.alignmentCanvas.lineCap = 'round';
    this.alignmentCanvas.lineWidth = 1;
    this.alignmentCanvas.beginPath();
    this.alignmentCanvas.moveTo(0, middle);
    this.alignmentCanvas.lineTo(width, middle);
    this.alignmentCanvas.stroke();
    for (let index = 0; index < MIC_ALIGNMENT_TICK_COUNT; index++) {
      const x = width * index / (MIC_ALIGNMENT_TICK_COUNT - 1);
      const tickHalfHeight = index % 2 === 0 ? 6 : 3;
      this.alignmentCanvas.beginPath();
      this.alignmentCanvas.moveTo(x, middle - tickHalfHeight);
      this.alignmentCanvas.lineTo(x, middle + tickHalfHeight);
      this.alignmentCanvas.stroke();
    }
    const center = width / 2;
    this.alignmentCanvas.strokeStyle = '#A34530';
    this.alignmentCanvas.lineWidth = 1.5;
    this.alignmentCanvas.beginPath();
    this.alignmentCanvas.moveTo(center, middle - 13);
    this.alignmentCanvas.lineTo(center, middle + 13);
    this.alignmentCanvas.stroke();
    const ratio = (this.micShiftMs + MIC_SHIFT_LIMIT_MS) / (MIC_SHIFT_LIMIT_MS * 2);
    const marker = Math.max(1.5, Math.min(width - 1.5, ratio * width));
    this.alignmentCanvas.strokeStyle = CORAL;
    this.alignmentCanvas.lineWidth = 3;
    this.alignmentCanvas.beginPath();
    this.alignmentCanvas.moveTo(marker, middle - 15);
    this.alignmentCanvas.lineTo(marker, middle + 15);
    this.alignmentCanvas.stroke();
  }

  private requestShare(): void {
    if (this.busy || this.renderingAudio || this.selectedClip() === undefined) { return; }
    if (this.pendingId.length > 0) {
      this.sharePanelVisible = true;
      return;
    }
    if (this.practicePlaying()) {
      if (AppSession.get()?.controller.isLeader) {
        this.pauseAction = 'share';
        this.pauseConfirmVisible = true;
      } else {
        showUserNotice('视频已保存在本机。请等队长暂停后再分享，也可离队后稍后分享', 'recording-share-playing');
      }
      return;
    }
    void this.shareSelected();
  }

  private async pauseAndContinue(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    const session = AppSession.get();
    try {
      if (session?.controller.isLeader && this.practicePlaying()) { await session.leaderPause(); }
      if (session !== AppSession.get() || this.practicePlaying()) {
        showUserNotice('练习状态已变化，请返回后重新分享', 'recording-share-session');
        return;
      }
      this.pauseConfirmVisible = false;
      this.refreshPlayback();
    } catch (error) {
      logUserFailure('recording-share-pause', error);
      showUserNotice('暂停练习失败，视频已保存在本机', 'recording-share-pause');
      return;
    } finally {
      this.busy = false;
    }
    if (this.pauseAction === 'share') { await this.shareSelected(); }
    if (this.pauseAction === 'confirm') { await this.confirmPublished(); }
    if (this.pauseAction === 'preview') { this.prepareSelectedPreview(); }
  }

  private async shareSelected(): Promise<void> {
    const selected = this.selectedClip();
    if (selected === undefined || this.busy) { return; }
    this.stopPreview();
    this.busy = true;
    this.resultTitle = '';
    this.resultDetail = '';
    try {
      const clip = await this.renderSelectedAudio();
      if (clip === undefined || !this.active || this.selectedId !== selected.id) { return; }
      if (this.practicePlaying()) {
        showUserNotice('练习已恢复，请先暂停后再分享', 'recording-share-resumed');
        return;
      }
      const pending: PendingVideoShare = await RecordingShareService.share(clip, this.hostContext());
      this.pendingId = pending.id;
      this.pendingClipId = pending.clipId;
      this.pendingHandedOff = pending.handedOff;
      this.sharePanelVisible = true;
    } catch (error) {
      logUserFailure('recording-share', error);
      showUserNotice(userErrorMessage(error, '分享未完成。可保存相册，在小红书发布；重新分享后再确认打卡'), 'recording-share');
    } finally {
      this.busy = false;
      this.refreshPending();
    }
  }

  private async confirmPublished(): Promise<void> {
    if (this.busy || this.renderingAudio || !this.pendingHandedOff || this.pendingId.length === 0) { return; }
    if (this.practicePlaying()) {
      if (AppSession.get()?.controller.isLeader) {
        this.pauseAction = 'confirm';
        this.pauseConfirmVisible = true;
      } else {
        showUserNotice('请等队长暂停后再确认打卡，本次待确认分享会保留', 'recording-confirm-playing');
      }
      return;
    }
    this.busy = true;
    try {
      const result: ShareCheckInResult = await RecordingShareService.confirmPublished(this.pendingId);
      this.resultTitle = result.rewardGranted ? '24 小时鼓机试用已到账！' : '今天的分享，记下啦！';
      if (result.monthlySkipped) {
        this.resultDetail = `已连续分享 ${result.streakDays} 天。月卡权益生效中，今天继续记卡，不重复赠送试用。`;
      } else if (result.rewardGranted) {
        this.resultDetail = `已连续分享 ${result.streakDays} 天。试用截止 ${formatTrialExpiry(result.trialExpiresAt)}，回到队伍大厅即可使用鼓机。`;
      } else if (result.streakDays < 3) {
        this.resultDetail = `已连续分享 ${result.streakDays} 天，再连续分享 ${3 - result.streakDays} 天，即可领取 24 小时鼓机试用。`;
      } else {
        this.resultDetail = `已连续分享 ${result.streakDays} 天。今天的奖励已经领取，多次分享不重复延长试用。`;
      }
      this.refreshPending();
    } catch (error) {
      logUserFailure('recording-check-in', error);
      showUserNotice(userErrorMessage(error, '打卡暂未保存，请稍后重试；本次待确认分享会保留'), 'recording-check-in');
    } finally { this.busy = false; }
  }

  private async dismissPending(): Promise<void> {
    if (this.busy || this.pendingId.length === 0) { return; }
    this.busy = true;
    try {
      await RecordingShareService.dismissPending(this.pendingId);
      this.refreshPending();
      this.sharePanelVisible = false;
    } catch (error) {
      logUserFailure('recording-dismiss-share', error);
      showUserNotice('暂时无法取消，请稍后重试', 'recording-dismiss-share');
    } finally { this.busy = false; }
  }

  private async saveSelected(): Promise<void> {
    const selected = this.selectedClip();
    if (selected === undefined || this.busy) { return; }
    this.stopPreview();
    this.busy = true;
    try {
      const clip = await this.renderSelectedAudio();
      if (clip === undefined || !this.active || this.selectedId !== selected.id) { return; }
      if (this.practicePlaying()) {
        showUserNotice('练习已恢复，请先暂停后再保存视频', 'recording-save-resumed');
        return;
      }
      await RecordingRepository.saveToAlbum(clip, this.hostContext());
      showUserNotice('视频已保存到相册', 'recording-save');
    } catch (error) {
      logUserFailure('recording-save', error);
      showUserNotice(userErrorMessage(error, '未保存到相册，本机作品仍然保留'), 'recording-save');
    } finally { this.busy = false; }
  }

  private async deleteSelected(): Promise<void> {
    if (this.busy || this.renderingAudio || this.selectedId.length === 0) { return; }
    this.stopPreview();
    if (this.pendingClipId === this.selectedId) {
      this.deleteConfirmVisible = false;
      this.sharePanelVisible = true;
      showUserNotice('请先确认或取消这段视频的待确认分享', 'recording-delete-pending');
      return;
    }
    this.busy = true;
    try {
      await RecordingRepository.remove(this.selectedId);
      this.deleteConfirmVisible = false;
      this.refresh();
    } catch (error) {
      logUserFailure('recording-delete', error);
      showUserNotice('删除未完成，请稍后重试', 'recording-delete');
    } finally { this.busy = false; }
  }

  private selectedCoverSource(): string {
    const path = this.selectedClip()?.coverPath;
    return path === undefined ? '' : fileUri.getUriFromPath(path);
  }

  private startPreviewFromCover(): void {
    if (this.previewLoading || this.busy) { return; }
    if (this.practicePlaying()) {
      this.requestPreview();
      return;
    }
    if (this.previewReady) {
      this.videoController.start();
    } else {
      this.coverPlayRequested = true;
    }
  }

  @Builder
  private previewCover() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.selectedCoverSource()).width('100%').height('100%')
        .objectFit(ImageFit.Contain).interpolation(ImageInterpolation.High)
      Column({ space: 7 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle().width(48).height(48).fill('#D9FFF9EE').stroke(PAPER).strokeWidth(1.5)
          Image($rawfile('comic/icons/play.svg')).width(19).height(19)
        }.width(48).height(48)
        if (this.previewLoading) {
          Text('正在准备预览…').fontSize(10).fontWeight(900).fontColor(PAPER)
        }
      }
    }.width('100%').height('100%').backgroundColor(INK)
      .enabled(!this.previewLoading && !this.busy)
      .onClick(() => this.startPreviewFromCover())
  }

  @Builder
  private previewVideo() {
    // A two-value @Builder captures its initial parameters. Key the real Video
    // node by the immutable export path so a new mix gets a new player and callbacks.
    ForEach(this.clips.filter((clip: RecordingClip) => clip.id === this.selectedId), (clip: RecordingClip) => {
      Video({ src: fileUri.getUriFromPath(clip.path), controller: this.videoController })
      .width('100%').height(VIDEO_PREVIEW_HEIGHT).autoPlay(false).controls(true)
      .muted(this.previewMuted).loop(false).objectFit(ImageFit.Contain)
      .onStart(() => this.previewStarted(clip.id, clip.path))
      .onPause(() => this.previewPaused(clip.id, clip.path))
      .onFinish(() => this.previewFinished(clip.id, clip.path))
      .onUpdate((event) => this.previewProgress(clip.id, clip.path, event.time))
      .onPrepared(() => this.previewPrepared(clip.id, clip.path))
      .onSeeked((event) => this.previewSeeked(clip.id, clip.path, event.time))
      .onError(() => {
        if (!this.previewSourceMatches(clip.id, clip.path)) { return; }
        this.cancelPreviewContinuation();
        this.previewReady = false;
        this.coverPlayRequested = false;
        this.previewPlaying = false;
        this.previewCoverVisible = true;
        showUserNotice('这段视频暂时无法预览，可尝试保存相册后查看', 'recording-video-preview');
      })
    }, (clip: RecordingClip) => `${clip.id}:${clip.path}`)
  }

  @Builder
  private clipCard(clip: RecordingClip) {
    Row({ space: 12 }) {
      Stack() {
        if (clip.coverPath !== undefined) {
          Image(fileUri.getUriFromPath(clip.coverPath)).width('100%').height('100%')
            .objectFit(ImageFit.Cover).interpolation(ImageInterpolation.High)
        } else {
          Image($rawfile('comic/decor/recording_share_hero.png')).width(68).height(48).objectFit(ImageFit.Contain)
        }
        Circle().width(28).height(28).fill('#E6FFF9EE').stroke(INK).strokeWidth(1)
        Image($rawfile('comic/icons/play.svg')).width(14).height(14)
      }.width(76).height(58).backgroundColor(this.selectedId === clip.id ? LILAC : '#E4F2EB')
        .border({ width: 1, color: INK }).borderRadius(5).clip(true)
      Column({ space: 5 }) {
        Text(this.dateLabel(clip.createdAt)).fontSize(14).fontWeight(900).fontColor(INK).width('100%')
        Text(`${this.durationLabel(clip.durationMs)} · ${clip.interrupted ? '中断后已保留' : '画面 / 节奏 / MIC'}`)
          .fontSize(10).fontColor('#625C54').width('100%')
      }.layoutWeight(1)
      Text(this.selectedId === clip.id ? '正在预览' : '›').fontSize(this.selectedId === clip.id ? 10 : 25)
        .fontWeight(900).fontColor(INK)
    }.width('100%').padding(11).backgroundColor(this.selectedId === clip.id ? '#FFF0D1' : WHITE)
      .border({ width: this.selectedId === clip.id ? 2 : 1, color: INK }).borderRadius(7)
      .onClick(() => this.selectClip(clip))
  }

  @Builder
  private calendarEntry() {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text('分享日历').fontSize(14).fontWeight(900).fontColor(INK)
        Blank()
        Text('打卡记录与玩法 ›').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#625C54')
      }.width('100%')
    }.width('100%').height(CALENDAR_ENTRY_HEIGHT).padding({ left: 13, right: 13 }).backgroundColor('#EEE6FA')
      .border({ width: 1, color: INK }).borderRadius(6).enabled(!this.busy && !this.renderingAudio)
      .onClick(() => this.calendarVisible = true)
  }

  @Builder
  private shareSheet() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
        Column({ space: 13 }) {
          Row() {
            Text(this.resultTitle.length > 0 ? '打卡完成' : '小红书分享').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            Text('×').fontSize(25).fontWeight(900).width(30).height(30).textAlign(TextAlign.Center)
              .enabled(!this.busy && !this.renderingAudio).onClick(() => this.sharePanelVisible = false)
          }.width('100%')
          Image($rawfile('comic/decor/recording_share_hero.png')).width('100%').height(108).objectFit(ImageFit.Contain)
          if (this.resultTitle.length > 0) {
            Text(this.resultTitle).fontSize(20).fontWeight(900).fontColor(INK).width('100%')
            Text(this.resultDetail).fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
            ComicButton({ label: '收好这一拍', active: !this.busy, action: () => this.sharePanelVisible = false })
          } else {
            Text('在小红书发布完成了吗？').fontSize(19).fontWeight(900).fontColor(INK).width('100%')
            Text('请选择小红书发布本次视频，完成后回到这里明确确认。打开分享面板、取消分享或只保存相册，都不会自动打卡。')
              .fontSize(12).fontColor('#625C54').lineHeight(20).width('100%')
            if (!this.pendingHandedOff) {
              Text('这次分享尚未完成交接，可先取消本次确认后重新分享。')
                .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#A34530').width('100%')
            }
            Button(this.busy ? '正在保存打卡…' : '我已在小红书发布', { type: ButtonType.Normal })
              .width('100%').height(48).fontSize(16).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
              .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
              .enabled(!this.busy && this.pendingHandedOff).onClick(() => { void this.confirmPublished(); })
            Row() {
              Text('稍后确认').fontSize(12).fontWeight(900).padding(8)
                .enabled(!this.busy && !this.renderingAudio).onClick(() => this.sharePanelVisible = false)
              Blank()
              Text('取消本次打卡确认').fontSize(11).fontColor('#625C54').padding(8)
                .enabled(!this.busy && !this.renderingAudio).onClick(() => { void this.dismissPending(); })
            }.width('100%')
          }
          Text(this.rulesVisible ? '收起玩法 ˄' : '分享玩法 ˅').fontSize(11).fontWeight(900).fontColor(INK)
            .padding(4).onClick(() => this.rulesVisible = !this.rulesVisible)
          if (this.rulesVisible) {
            Text('按北京时间自然日连续分享。第 3 天起，每天首次符合条件的分享赠送接下来 24 小时鼓机试用；同日多次不叠加，漏一天重新累计。月卡有效时只记卡，不重复赠送。记录仅保存在本机，卸载或换设备后不恢复。')
              .fontSize(11).fontColor('#625C54').lineHeight(18).width('100%')
          }
        }.width('100%').padding(18)
      }.width(SHARE_SHEET_WIDTH).constraintSize({ maxHeight: SHARE_SHEET_MAX_HEIGHT }).scrollBar(BarState.Off)
        .backgroundColor(PAPER).border({ width: 2, color: INK }).borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(100)
  }

  @Builder
  private pauseConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('先让练习停一拍').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text(this.pauseAction === 'share' ?
          '分享会切换到其他应用。请先暂停全队练习，再选择小红书；视频已经保存在本机。' :
          this.pauseAction === 'confirm' ? '请先暂停全队练习，再保存这次分享打卡；待确认分享会一直保留。' :
            '先暂停全队练习，再打开视频预览，避免视频播放器影响现场声音。视频已经保存在本机。')
          .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
        Button(this.pauseAction === 'share' ? '暂停练习并分享' :
          this.pauseAction === 'confirm' ? '暂停练习并确认打卡' : '暂停练习并预览', { type: ButtonType.Normal })
          .width('100%').height(48).fontSize(16).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
          .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
          .enabled(!this.busy && !this.renderingAudio).onClick(() => { void this.pauseAndContinue(); })
        Text('继续练习，稍后再看').fontSize(12).fontWeight(900).padding(6)
          .enabled(!this.busy && !this.renderingAudio).onClick(() => this.pauseConfirmVisible = false)
      }.width(SHARE_SHEET_WIDTH).padding(20).backgroundColor(PAPER).border({ width: 2, color: INK })
        .borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
  }

  @Builder
  private deleteConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('删除这段视频？').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text('将从本机作品中移除，已经保存到相册的副本不受影响。').fontSize(13).fontColor('#625C54').lineHeight(21)
        Row({ space: 10 }) {
          Button('留下', { type: ButtonType.Normal }).layoutWeight(1).height(46).fontColor(INK).fontWeight(900)
            .backgroundColor(WHITE).border({ width: 1.5, color: INK }).borderRadius(6)
            .enabled(!this.busy && !this.renderingAudio).onClick(() => this.deleteConfirmVisible = false)
          Button('删除视频', { type: ButtonType.Normal }).layoutWeight(1).height(46).fontColor(INK).fontWeight(900)
            .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6)
            .enabled(!this.busy && !this.renderingAudio).onClick(() => { void this.deleteSelected(); })
        }.width('100%')
      }.width(SHARE_SHEET_WIDTH).padding(20).backgroundColor(PAPER).border({ width: 2, color: INK })
        .borderRadius(9).shadow(CARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 16 }) {
          Row() {
            Text('‹').fontSize(35).width(30).enabled(!this.busy && !this.renderingAudio).onClick(() => router.back())
            Text(this.scope === 'solo' ? '单人练习作品' : '多人练习作品')
              .fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            Text('LOCAL\nTAKES').fontSize(9).fontWeight(900).letterSpacing(1).textAlign(TextAlign.End)
          }.width('100%')
          if (this.clips.length === 0) {
            Image($rawfile('comic/decor/recording_share_hero.png')).width('100%').height(LIBRARY_HERO_HEIGHT)
              .objectFit(ImageFit.Contain).margin({ top: 30 })
            Text('还没有录下的同拍时刻').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic)
            Text('回到行进页，点击红色录制按钮。\n画面、节奏与周围声音，会一起留下来。')
              .fontSize(13).fontColor('#625C54').lineHeight(22).textAlign(TextAlign.Center)
            this.calendarEntry()
            ComicButton({ label: '返回首页', fill: LILAC, action: () => router.back() })
          } else {
            Column({ space: 10 }) {
              Stack() {
                if (this.practiceActive) {
                  // A muted Video can still request system audio focus. Do not
                  // create its player while the shared practice is running.
                  Column({ space: 13 }) {
                    Image($rawfile('comic/decor/recording_share_hero.png'))
                      .width('86%').height(112).objectFit(ImageFit.Contain)
                    Text('练习仍在进行，先收好这一拍')
                      .fontSize(12).fontWeight(900).fontColor(PAPER)
                    if (!this.renderingAudio) {
                      Button('暂停练习后预览', { type: ButtonType.Normal })
                        .height(34).fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(LILAC)
                        .border({ width: 1, color: PAPER }).borderRadius(5)
                        .onClick(() => this.requestPreview())
                    }
                  }.width('100%')
                } else {
                  this.previewVideo()
                  if (this.selectedClip()?.coverPath !== undefined &&
                    (this.previewCoverVisible || this.previewLoading)) {
                    this.previewCover()
                  }
                }
              }.width('100%').height(VIDEO_PREVIEW_HEIGHT).backgroundColor(INK)
                .border({ width: 2, color: INK }).borderRadius(8).clip(true)
              Row() {
                Text('已保存在本机').fontSize(11).fontWeight(900).fontColor('#467A70')
                Blank()
                Text(this.previewMuted ? '已静音 · 点击开声' : '有声预览 · 点击静音')
                  .fontSize(10).fontWeight(FontWeight.Bold).fontColor(INK).padding(5)
                  .onClick(() => this.togglePreviewSound())
              }.width('100%')
              Text(this.practiceActive ? '为保护现场节奏，请先暂停练习再预览或分享。成品保留声波与停止控件。' :
                '成品保留实时声波与停止控件。预览默认有声，可单独调整麦克风收到的声音。')
                .fontSize(11).fontColor('#625C54').lineHeight(18).width('100%')
              Column({ space: 5 }) {
                Row() {
                  Text('MIC / 外部声音').fontSize(12).fontWeight(900).fontColor(INK)
                  Blank()
                  Text(`${Math.round(this.micGain * 100)}%`).fontSize(13).fontWeight(900).fontColor(INK)
                }.width('100%')
                Slider({ value: this.micGain, min: 0, max: 2, step: 0.05, style: SliderStyle.OutSet })
                  .width('100%').height(28).trackThickness(4).selectedColor('#29B5AE').trackColor('#BED8D1')
                  .blockColor(INK).enabled(this.canAdjustMic())
                  .onChange((value: number, mode: SliderChangeMode) => this.changeMicGain(value, mode))
                Row() {
                  Text('0%').fontSize(9).fontColor('#625C54')
                  Blank()
                  Text('应用内节奏声固定 100%').fontSize(10).fontWeight(FontWeight.Bold).fontColor('#467A70')
                  Blank()
                  Text('200%').fontSize(9).fontColor('#625C54')
                }.width('100%')
                Divider().strokeWidth(1).color('#B9CCC6').margin({ top: 7, bottom: 5 })
                Row() {
                  Text('人声对齐').fontSize(12).fontWeight(900).fontColor(INK)
                  Blank()
                  Text('范围 ±300ms').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#625C54')
                }.width('100%')
                Row({ space: 8 }) {
                  Button({ type: ButtonType.Normal }) {
                    Text('‹').fontSize(27).fontWeight(900).fontColor(INK)
                  }.width(38).height(38).padding(0).backgroundColor('#D4DDDA')
                    .border({ width: 1, color: INK }).borderRadius(7).enabled(this.canAdjustMic())
                    .accessibilityText('人声提前 10 毫秒')
                    .onClick(() => this.nudgeMicShift(-MIC_SHIFT_STEP_MS))
                  Stack({ alignContent: Alignment.Center }) {
                    Canvas(this.alignmentCanvas).width('100%').height(MIC_ALIGNMENT_RULER_HEIGHT)
                      .hitTestBehavior(HitTestMode.None)
                      .onReady(() => {
                        this.alignmentCanvasReady = true;
                        this.drawMicAlignmentRuler();
                      })
                      .onAreaChange((_oldArea, area) => {
                        this.alignmentCanvasWidth = Number(area.width);
                        this.drawMicAlignmentRuler();
                      })
                    Slider({
                      value: this.micShiftMs, min: -MIC_SHIFT_LIMIT_MS, max: MIC_SHIFT_LIMIT_MS,
                      step: MIC_SHIFT_STEP_MS, style: SliderStyle.OutSet
                    }).width('100%').height(MIC_ALIGNMENT_RULER_HEIGHT).opacity(0.01)
                      .enabled(this.canAdjustMic())
                      .accessibilityText(this.micShiftLabel())
                      .onChange((value: number, mode: SliderChangeMode) => this.changeMicShift(value, mode))
                  }.layoutWeight(1).height(MIC_ALIGNMENT_RULER_HEIGHT)
                  Button({ type: ButtonType.Normal }) {
                    Text('›').fontSize(27).fontWeight(900).fontColor(INK)
                  }.width(38).height(38).padding(0).backgroundColor('#D4DDDA')
                    .border({ width: 1, color: INK }).borderRadius(7).enabled(this.canAdjustMic())
                    .accessibilityText('人声延后 10 毫秒')
                    .onClick(() => this.nudgeMicShift(MIC_SHIFT_STEP_MS))
                }.width('100%')
                Text(this.micShiftLabel()).fontSize(10).fontWeight(FontWeight.Bold)
                  .fontColor(this.micShiftMs === 0 ? '#625C54' : '#A34530')
                  .textAlign(TextAlign.Center).width('100%')
                if (!this.hasSeparateAudio()) {
                  Text('旧版视频已合并声音，重新录制可单独调 MIC。')
                    .fontSize(10).fontColor('#777065').lineHeight(17).width('100%')
                } else if (this.pendingClipId === this.selectedId) {
                  Text('请先确认或取消本次分享，再调整这段作品的 MIC。')
                    .fontSize(10).fontColor('#777065').lineHeight(17).width('100%')
                } else {
                  Text(this.renderingAudio ?
                    '正在应用声音设置；可继续调节，将自动合并到最后一次，完成后从当前位置续播…' :
                    '松开后应用音量与对齐。首次会准备快速 MIC 轨，之后调整更快；保存与分享使用当前设置。')
                    .fontSize(10).fontColor('#625C54').lineHeight(17).width('100%')
                }
              }.width('100%').padding(12).backgroundColor('#E8F2EB').border({ width: 1, color: INK }).borderRadius(7)
              this.calendarEntry()
              ComicButton({ label: this.renderingAudio ? '声音处理中…' : this.busy ? '处理中…' : '分享小红书',
                active: !this.busy && !this.renderingAudio,
                action: () => this.requestShare() })
              Row({ space: 10 }) {
                Button('保存相册', { type: ButtonType.Normal }).layoutWeight(1).height(42)
                  .fontSize(13).fontWeight(900).fontColor(INK).backgroundColor(WHITE)
                  .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
                  .enabled(!this.busy && !this.renderingAudio).onClick(() => { void this.saveSelected(); })
                Button('删除', { type: ButtonType.Normal }).width(72).height(42)
                  .fontSize(12).fontWeight(900).fontColor('#625C54').backgroundColor(PAPER)
                  .border({ width: 1, color: INK }).borderRadius(5)
                  .enabled(!this.busy && !this.renderingAudio).onClick(() => this.deleteConfirmVisible = true)
              }.width('100%')
            }.width('100%')
            if (this.pendingId.length > 0) {
              Row() {
                Text('有一段分享等待你确认').fontSize(12).fontWeight(900).layoutWeight(1)
                Text('去确认 ›').fontSize(12).fontWeight(900)
              }.width('100%').padding(13).backgroundColor('#FFE2A3').border({ width: 1.5, color: INK }).borderRadius(6)
                .onClick(() => { this.resultTitle = ''; this.resultDetail = ''; this.sharePanelVisible = true; })
            }
            Row() {
              Text('TAKES / 录制作品').fontSize(12).fontWeight(900).letterSpacing(0.7)
              Blank()
              Text(`${this.clips.length} 段`).fontSize(11).fontWeight(FontWeight.Bold)
            }.width('100%').margin({ top: 6 })
            ForEach(this.clips, (clip: RecordingClip) => { this.clipCard(clip) }, (clip: RecordingClip) => clip.id)
            Text('视频与待确认分享仅保存在本机，请及时保存到相册。')
              .fontSize(10).fontColor('#777065').lineHeight(18).width('100%')
          }
        }.width('100%').padding({
          left: LIBRARY_SIDE_INSET, right: LIBRARY_SIDE_INSET,
          top: 10 + this.topSafeInset, bottom: 28 + this.bottomSafeInset
        })
      }.width('100%').height('100%').scrollBar(BarState.Off)
      if (this.sharePanelVisible) { this.shareSheet() }
      if (this.pauseConfirmVisible) { this.pauseConfirm() }
      if (this.deleteConfirmVisible) { this.deleteConfirm() }
      if (this.calendarVisible) {
        ShareCalendarSheet({
          scope: this.scope,
          bottomInset: this.bottomSafeInset,
          onClose: (): void => { this.calendarVisible = false; }
        })
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
