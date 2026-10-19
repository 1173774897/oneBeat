import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { RecordingClip, RecordingScope } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import { MAX_MIC_SHIFT_US, RECORDING_MIX_VERSION } from '../recording/RecordingMixer';
import { RecordingShareService } from '../sharing/RecordingShareService';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import { ComicButton, PAPER, INK, CORAL, LILAC, WHITE, CONTROL_SHADOW, CARD_SHADOW } from '../components/ComicKit';
import { ShareCalendarSheet } from '../components/ShareCalendarSheet';

const LIBRARY_SIDE_INSET: number = 20;
const LIBRARY_HERO_HEIGHT: number = 154;
const VIDEO_PREVIEW_HEIGHT: number = 242;
const SHARE_SHEET_WIDTH: string = '90%';
const SHARE_SHEET_MAX_HEIGHT: string = '88%';
const CALENDAR_ENTRY_HEIGHT: number = 42;
const CALENDAR_ENTRY_WIDTH: number = 72;
const CALENDAR_ENTRY_ICON_SIZE: number = 22;
const LIBRARY_CARD_DELETE_SIZE: number = 28;
const LIBRARY_CARD_DELETE_INSET: number = 8;
const LIBRARY_CARD_ACTION_RIGHT_INSET: number = 46;
const ALBUM_SAVE_BUTTON_HEIGHT: number = 42;
const ALBUM_SAVE_ICON_SIZE: number = 16;
const ALBUM_SAVE_LABEL_GAP: number = 6;
const ALBUM_SAVE_HORIZONTAL_PADDING: number = 12;
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
  @State savingToAlbum: boolean = false;
  @State pauseConfirmVisible: boolean = false;
  @State deleteConfirmVisible: boolean = false;
  @State practiceActive: boolean = false;
  @State pauseAction: string = 'share';
  @State deleteClipId: string = '';
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
    this.refreshPlayback();
  }

  onPageShow(): void {
    this.active = true;
    void RecordingShareService.markReturnedToApp().catch((error: Object) => logUserFailure('recording-share-return', error));
    this.refresh();
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
      !this.hasSeparateAudio() ||
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
    return this.hasSeparateAudio() && !this.busy && !this.practiceActive;
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

  private async pauseAndContinue(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    const session = AppSession.get();
    try {
      if (session?.controller.isLeader && this.practicePlaying()) { await session.leaderPause(); }
      if (session !== AppSession.get() || this.practicePlaying()) {
        showUserNotice('练习状态已变化，请稍后重新预览', 'recording-preview-session');
        return;
      }
      this.pauseConfirmVisible = false;
      this.refreshPlayback();
    } catch (error) {
      logUserFailure('recording-preview-pause', error);
      showUserNotice('暂停练习失败，视频已保存在本机', 'recording-preview-pause');
      return;
    } finally { this.busy = false; }
    this.prepareSelectedPreview();
  }

  private async saveSelected(): Promise<void> {
    const selected = this.selectedClip();
    if (selected === undefined || this.busy || this.renderingAudio) { return; }
    this.busy = true;
    this.savingToAlbum = true;
    let saved = false;
    try {
      // Edits are committed before the button becomes available; cancellation
      // of the system album dialog must never look like a successful write.
      saved = await RecordingRepository.saveToAlbum(selected, this.hostContext());
      if (!saved) { return; }
      if (!this.active) { return; }
      await router.pushUrl({ url: 'pages/SavedRecordingPage', params: { clipId: selected.id, scope: this.scope } });
    } catch (error) {
      logUserFailure('recording-save', error);
      showUserNotice(saved ? '已保存到相册，分享页面暂未打开，可返回作品后重试' :
        userErrorMessage(error, '未保存到相册，本机作品仍然保留'), 'recording-save');
    } finally {
      this.savingToAlbum = false;
      this.busy = false;
    }
  }

  private requestDeleteClip(clipId: string): void {
    if (this.busy || this.renderingAudio) { return; }
    this.deleteClipId = clipId;
    this.deleteConfirmVisible = true;
  }

  private async deleteSelected(): Promise<void> {
    if (this.busy || this.renderingAudio || this.deleteClipId.length === 0) { return; }
    const clipId = this.deleteClipId;
    if (clipId === this.selectedId) { this.stopPreview(); }
    this.busy = true;
    try {
      await RecordingRepository.remove(clipId);
      // Keep unfinished shares on file-deletion failure; service ownership checks hide stale shares after removal.
      try { await RecordingShareService.dismissForClip(clipId); }
      catch (error) { logUserFailure('recording-delete-share-cleanup', error); }
      this.deleteConfirmVisible = false;
      this.deleteClipId = '';
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
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
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
        }.width('100%').padding({ left: 11, right: LIBRARY_CARD_ACTION_RIGHT_INSET, top: 11, bottom: 11 })
          .onClick(() => this.selectClip(clip))
      }.width('100%')
        .backgroundColor(this.selectedId === clip.id ? '#FFF0D1' : WHITE)
        .border({ width: this.selectedId === clip.id ? 2 : 1, color: INK }).borderRadius(7)
      // Keep deletion separate from the preview hit area so removing a work never selects it.
      Button('×', { type: ButtonType.Normal }).width(LIBRARY_CARD_DELETE_SIZE).height(LIBRARY_CARD_DELETE_SIZE)
        .padding(0).fontSize(20).fontWeight(900).fontColor('#A34530').backgroundColor('#FFF1E8')
        .border({ width: 1, color: INK }).borderRadius(6)
        .margin({ top: LIBRARY_CARD_DELETE_INSET, right: LIBRARY_CARD_DELETE_INSET })
        .enabled(!this.busy && !this.renderingAudio).accessibilityText('删除这段作品')
        .onClick(() => this.requestDeleteClip(clip.id))
    }.width('100%')
  }

  @Builder
  private calendarEntry(compact: boolean) {
    Button({ type: ButtonType.Normal }) {
      Image($rawfile('comic/icons/calendar.svg')).width(CALENDAR_ENTRY_ICON_SIZE).height(CALENDAR_ENTRY_ICON_SIZE)
        .objectFit(ImageFit.Contain).accessibilityLevel('no')
    }.width(compact ? CALENDAR_ENTRY_WIDTH : '100%').height(CALENDAR_ENTRY_HEIGHT).padding(0)
      .backgroundColor(compact ? PAPER : '#EEE6FA').border({ width: 1, color: INK }).borderRadius(5)
      .enabled(!this.busy && !this.renderingAudio).accessibilityText('打开打卡日历')
      .onClick(() => this.calendarVisible = true)
  }

  @Builder
  private pauseConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
        Text('先让练习停一拍').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text('先暂停全队练习，再打开视频预览，避免播放器影响现场声音。视频已经保存在本机。')
          .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
        Button('暂停练习并预览', { type: ButtonType.Normal })
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
            this.calendarEntry(false)
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
                } else {
                  Text(this.renderingAudio ?
                    '正在应用声音设置；可继续调节，将自动合并到最后一次，完成后从当前位置续播…' :
                    '松开后应用音量与对齐。首次会准备快速 MIC 轨，之后调整更快；保存与分享使用当前设置。')
                    .fontSize(10).fontColor('#625C54').lineHeight(17).width('100%')
                }
              }.width('100%').padding(12).backgroundColor('#E8F2EB').border({ width: 1, color: INK }).borderRadius(7)
              Row({ space: 10 }) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: ALBUM_SAVE_LABEL_GAP }) {
                    Image($rawfile('comic/icons/save_to_album.svg'))
                      .width(ALBUM_SAVE_ICON_SIZE).height(ALBUM_SAVE_ICON_SIZE).objectFit(ImageFit.Contain)
                    Text(this.savingToAlbum ? '正在保存…' : '保存到相册')
                      .fontSize(13).fontWeight(900).fontColor(INK)
                  }
                }.layoutWeight(1).height(ALBUM_SAVE_BUTTON_HEIGHT)
                  .padding({ left: ALBUM_SAVE_HORIZONTAL_PADDING, right: ALBUM_SAVE_HORIZONTAL_PADDING })
                  .backgroundColor(WHITE).border({ width: 1.5, color: INK }).borderRadius(5)
                  .opacity(this.busy || this.renderingAudio ? 0.55 : 1)
                  .accessibilityText(this.savingToAlbum ? '正在保存到相册' : '保存到相册')
                  .enabled(!this.busy && !this.renderingAudio)
                  .onClick(() => { void this.saveSelected(); })
                this.calendarEntry(true)
              }.width('100%')
            }.width('100%')
            Row() {
              Text('TAKES / 录制作品').fontSize(12).fontWeight(900).letterSpacing(0.7)
              Blank()
              Text(`${this.clips.length} 段`).fontSize(11).fontWeight(FontWeight.Bold)
            }.width('100%').margin({ top: 6 })
            ForEach(this.clips, (clip: RecordingClip) => { this.clipCard(clip) },
              (clip: RecordingClip) => `${clip.id}:${clip.coverPath ?? ''}`)
            Text('视频与打卡记录保存在本机。分享后回到票根页，点击“去打卡”确认。')
              .fontSize(10).fontColor('#777065').lineHeight(18).width('100%')
          }
        }.width('100%').padding({
          left: LIBRARY_SIDE_INSET, right: LIBRARY_SIDE_INSET,
          top: 10 + this.topSafeInset, bottom: 28 + this.bottomSafeInset
        })
      }.width('100%').height('100%').scrollBar(BarState.Off)
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
