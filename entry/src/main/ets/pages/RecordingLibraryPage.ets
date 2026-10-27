import { COMIC_CARD_INK_OFFSET, COMIC_CONTROL_INK_OFFSET } from '../components/ComicInkSurface';
import { DrumPaper } from '../components/DrumPaper';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { RecordingClip, RecordingScope } from '../recording/RecordingModels';
import { RecordingRepository } from '../recording/RecordingRepository';
import { MAX_MIC_SHIFT_US, RecordingMixer } from '../recording/RecordingMixer';
import { RecordingShareService } from '../sharing/RecordingShareService';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import { ComicButton, PAPER, INK, CORAL, LILAC, WHITE } from '../components/ComicKit';
import { ShareCalendarSheet } from '../components/ShareCalendarSheet';
import { ActionButton } from '../components/ActionButton';

const LIBRARY_SIDE_INSET: number = 20;
const LIBRARY_HERO_HEIGHT: number = 154;
const VIDEO_PREVIEW_HEIGHT: number = 242;
const SHARE_SHEET_WIDTH: string = '90%';
const SHARE_SHEET_MAX_HEIGHT: string = '88%';
const CALENDAR_ENTRY_HEIGHT: number = 42;
const CALENDAR_ENTRY_WIDTH: number = 72;
const CALENDAR_ENTRY_ICON_SIZE: number = 22;
const LIBRARY_GRID_GAP: number = 12;
const LIBRARY_CARD_COVER_HEIGHT: number = 84;
// Image must exceed the clip frame height so Cover crop can anchor on the top; keep
// LIBRARY_CARD_COVER_IMAGE_HEIGHT >= LIBRARY_CARD_COVER_HEIGHT * LIBRARY_CARD_COVER_IMAGE_SCALE.
const LIBRARY_CARD_COVER_IMAGE_SCALE: number = 1.54;
const LIBRARY_CARD_COVER_IMAGE_HEIGHT: number = 219;
// Negative Y shifts the crop window downward on the source frame (shows more lower body/scene).
const LIBRARY_CARD_COVER_FOCUS_OFFSET_Y: number = -124;
const LIBRARY_CARD_INFO_HEIGHT: number = 44;
const LIBRARY_CARD_INFO_SPACE: number = 2;
const LIBRARY_CARD_INFO_PADDING_TOP: number = 4;
const LIBRARY_CARD_INFO_PADDING_BOTTOM: number = 3;
const LIBRARY_CARD_DATE_HEIGHT: number = 15;
const LIBRARY_CARD_META_ROW_HEIGHT: number = 18;
const LIBRARY_CARD_PREVIEW_BADGE_WIDTH: number = 54;
const LIBRARY_CARD_PREVIEW_BADGE_HEIGHT: number = 20;
const LIBRARY_CARD_DELETE_SIZE: number = 14;
const LIBRARY_CARD_CONTROL_HIT_SIZE: number = 44;
const LIBRARY_MANAGEMENT_BAR_HEIGHT: number = 64;
const LIBRARY_MIC_NUDGE_SIZE: number = 38;
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
  @State managing: boolean = false;
  @State managementSelection: string[] = [];
  @State deleteClipIds: string[] = [];
  @State deleteIsBatch: boolean = false;
  private readonly pageScroller: Scroller = new Scroller();
  private managementPreview: PreviewContinuation | undefined = undefined;
  private managementScrollY: number = 0;
  private pendingScrollY: number | undefined = undefined;
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
    if (this.managing) { this.exitManagement(); return true; }
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
    this.managementSelection = this.managementSelection.filter((id: string) =>
      this.clips.some((clip: RecordingClip) => clip.id === id));
    if (!this.clips.some((clip: RecordingClip) => clip.id === this.selectedId)) {
      this.selectedId = this.clips.length > 0 ? this.clips[0].id : '';
    }
    if (this.managing && this.clips.length === 0 && !this.busy) { this.exitManagement(); return; }
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
    return `${time.getFullYear()}年${time.getMonth() + 1}月${time.getDate()}日`;
  }

  private timeLabel(timeMs: number): string {
    const time = new Date(timeMs);
    return `${time.getHours().toString().padStart(2, '0')}:${time.getMinutes().toString().padStart(2, '0')}`;
  }

  private clipRows(): RecordingClip[][] {
    const rows: RecordingClip[][] = [];
    for (let index = 0; index < this.clips.length; index += 2) { rows.push(this.clips.slice(index, index + 2)); }
    return rows;
  }

  private enterManagement(): void {
    if (this.busy || this.renderingAudio || this.clips.length === 0 || this.managing) { return; }
    const clip = this.selectedClip();
    this.managementScrollY = this.pageScroller.currentOffset().yOffset;
    this.managementPreview = clip === undefined ? undefined : {
      clipId: clip.id, path: clip.path, timeSeconds: Math.floor(this.previewTimeSeconds), playing: false, prepared: false
    };
    this.stopPreview();
    this.previewReady = false;
    this.alignmentCanvasReady = false;
    this.managementSelection = [];
    this.managing = true;
    this.pendingScrollY = 0;
  }

  private exitManagement(): void {
    if (this.busy || !this.managing) { return; }
    const bookmark = this.managementPreview;
    this.managing = false;
    this.managementSelection = [];
    this.deleteConfirmVisible = false;
    this.deleteClipIds = [];
    this.managementPreview = undefined;
    this.refresh();
    this.videoController = new VideoController();
    this.previewReady = false;
    this.previewCoverVisible = true;
    const clip = this.selectedClip();
    // The Video was unmounted during management. Restore its position after
    // prepare, but never resume sound automatically when finishing deletion.
    if (clip !== undefined && bookmark?.clipId === clip.id && !this.practicePlaying()) {
      this.previewTimeSeconds = Math.floor(Math.min(bookmark.timeSeconds, Math.max(0, clip.durationMs / 1000 - 0.05)));
      this.previewContinuation = { clipId: clip.id, path: clip.path,
        timeSeconds: this.previewTimeSeconds, playing: false, prepared: false };
      this.previewLoading = true;
      this.watchPreviewLoad(clip.id, clip.path);
    } else { this.previewTimeSeconds = 0; }
    this.pendingScrollY = this.managementScrollY;
    this.prepareSelectedPreview();
  }

  private restorePendingScroll(): void {
    if (this.pendingScrollY === undefined) { return; }
    const y = this.pendingScrollY;
    this.pendingScrollY = undefined;
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: y, animation: false });
  }

  private scrollToPreview(): void {
    if (this.managing || this.busy) { return; }
    this.pendingScrollY = undefined;
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: true });
  }

  private isManagementSelected(id: string): boolean { return this.managementSelection.includes(id); }

  private toggleManagementSelection(id: string): void {
    if (!this.managing || this.busy || this.deleteConfirmVisible || !this.clips.some((clip: RecordingClip) => clip.id === id)) { return; }
    this.managementSelection = this.isManagementSelected(id) ?
      this.managementSelection.filter((selected: string) => selected !== id) : this.managementSelection.concat(id);
  }

  private allManagementSelected(): boolean {
    return this.clips.length > 0 && this.managementSelection.length === this.clips.length;
  }

  private toggleSelectAll(): void {
    if (!this.managing || this.busy || this.deleteConfirmVisible) { return; }
    this.managementSelection = this.allManagementSelected() ? [] : this.clips.map((clip: RecordingClip) => clip.id);
  }

  private activateClipCard(clip: RecordingClip): void {
    if (this.managing) { this.toggleManagementSelection(clip.id); }
    else { this.selectClip(clip); }
  }

  private requestBatchDelete(): void {
    if (!this.managing || this.busy || this.renderingAudio || this.deleteConfirmVisible || this.managementSelection.length === 0) { return; }
    this.deleteClipIds = this.managementSelection.slice();
    this.deleteIsBatch = true;
    this.deleteConfirmVisible = true;
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
    return this.active && !this.managing && this.selectedId === id && this.selectedClip()?.path === path;
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
    if (this.managing || this.busy || this.renderingAudio || this.selectedId === clip.id) { return; }
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
    this.scrollToPreview();
  }

  private prepareSelectedPreview(): void {
    const clip = this.selectedClip();
    if (clip === undefined || !this.active || this.managing || this.busy || this.renderingAudio || this.practicePlaying() ||
      !this.hasSeparateAudio() ||
      (clip.renderedMixVersion ?? 0) >= RecordingMixer.mixVersion(clip)) { return; }
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
      ((clip.renderedMixVersion ?? 0) >= RecordingMixer.mixVersion(clip) || !this.clipHasSeparateAudio(clip));
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
    if (!this.managing || this.busy || this.renderingAudio || this.deleteConfirmVisible ||
      !this.clips.some((clip: RecordingClip) => clip.id === clipId)) { return; }
    this.deleteClipIds = [clipId];
    this.deleteIsBatch = false;
    this.deleteConfirmVisible = true;
  }

  private async deleteSelected(): Promise<void> {
    if (!this.managing || this.busy || this.renderingAudio || !this.deleteConfirmVisible || this.deleteClipIds.length === 0) { return; }
    const targets = this.deleteClipIds.slice();
    this.busy = true;
    const failed: string[] = [];
    const removed: string[] = [];
    try {
      for (const clipId of targets) {
        try { await RecordingRepository.remove(clipId); }
        catch (error) {
          logUserFailure('recording-delete', error);
          // The repository commits its index before file cleanup. An orphaned
          // derived file must not make an already-removed item look retryable.
          if (RecordingRepository.get(clipId) !== undefined) { failed.push(clipId); continue; }
        }
        removed.push(clipId);
        try { await RecordingShareService.dismissForClip(clipId); }
        catch (error) { logUserFailure('recording-delete-share-cleanup', error); }
      }
      this.deleteConfirmVisible = false;
      this.deleteClipIds = [];
      this.refresh();
      this.managementSelection = this.deleteIsBatch ? failed : this.managementSelection.filter((id: string) => !removed.includes(id));
      showUserNotice(failed.length > 0 ? (removed.length > 0 ? `已删除 ${removed.length} 段，${failed.length} 段未完成，可重试` :
        '删除未完成，请稍后重试') : `已删除 ${removed.length} 段作品`, 'recording-delete');
    } finally { this.busy = false; }
    if (this.clips.length === 0 && this.active) { this.exitManagement(); }
  }

  private selectedCoverSource(): string {
    const path = this.selectedClip()?.coverPath;
    return path === undefined ? '' : fileUri.getUriFromPath(path);
  }

  private startPreviewFromCover(): void {
    if (this.managing || this.previewLoading || this.busy) { return; }
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
    ActionButton({
      active: !this.previewLoading && !this.busy, controlHeight: VIDEO_PREVIEW_HEIGHT, fill: INK,
      cornerRadius: 0, accessibilityLabel: this.previewLoading ? '正在准备预览' : '播放作品预览',
      action: () => this.startPreviewFromCover()
    }) {
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
      }.width('100%').height('100%')
    }
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
      DrumPaper({
        fill: this.managing ? (this.isManagementSelected(clip.id) ? '#EEE6FA' : WHITE) :
          (this.selectedId === clip.id ? '#FFF0D1' : WHITE),
        paperWidth: '100%',
        cornerRadius: 6,
        clipContent: true,
        paperLineWidth: 1,
        offsetX: COMIC_CARD_INK_OFFSET,
        offsetY: COMIC_CARD_INK_OFFSET
      }) {
        Column() {
          Stack({ alignContent: Alignment.TopStart }) {
            Stack({ alignContent: Alignment.TopStart }) {
              if (clip.coverPath !== undefined) {
                Image(fileUri.getUriFromPath(clip.coverPath)).width('100%').height(LIBRARY_CARD_COVER_IMAGE_HEIGHT)
                  .objectFit(ImageFit.Cover).interpolation(ImageInterpolation.High)
                  .translate({ x: 0, y: LIBRARY_CARD_COVER_FOCUS_OFFSET_Y })
              } else {
                Image($rawfile('comic/decor/recording_share_hero.png')).width('82%').height(76).objectFit(ImageFit.Contain)
                  .margin({ top: 18 })
              }
            }.width('100%').height(LIBRARY_CARD_COVER_HEIGHT).backgroundColor('#E4F2EB').clip(true)
            Stack({ alignContent: Alignment.BottomEnd }) {
              Text(this.durationLabel(clip.durationMs)).fontSize(10).fontWeight(900).fontColor(WHITE)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 }).backgroundColor(INK).borderRadius(3)
            }.width('100%').height(LIBRARY_CARD_COVER_HEIGHT).padding({ right: 6, bottom: 6 })
              .hitTestBehavior(HitTestMode.None)
          }.width('100%').height(LIBRARY_CARD_COVER_HEIGHT)
          Column({ space: LIBRARY_CARD_INFO_SPACE }) {
            Text(this.dateLabel(clip.createdAt)).fontSize(11).fontWeight(900).fontColor(INK).width('100%')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .height(LIBRARY_CARD_DATE_HEIGHT).lineHeight(LIBRARY_CARD_DATE_HEIGHT)
            Row({ space: 3 }) {
              Text(`${this.timeLabel(clip.createdAt)}${clip.interrupted ? ' · 中断' : ''}`)
                .fontSize(10).fontColor('#625C54').layoutWeight(1).maxLines(1)
                .height(LIBRARY_CARD_META_ROW_HEIGHT).lineHeight(LIBRARY_CARD_META_ROW_HEIGHT)
              Stack({ alignContent: Alignment.Center }) {
                if (!this.managing && this.selectedId === clip.id) {
                  Button('正在预览', { type: ButtonType.Normal }).fontSize(9).fontWeight(900).fontColor(INK)
                    .width(LIBRARY_CARD_PREVIEW_BADGE_WIDTH).height(LIBRARY_CARD_PREVIEW_BADGE_HEIGHT)
                    .padding(0).backgroundColor(LILAC).borderRadius(4)
                    .accessibilityText('正在预览，返回页面顶部视频区域')
                    .onClick(() => this.scrollToPreview())
                }
              }.width(LIBRARY_CARD_PREVIEW_BADGE_WIDTH).height(LIBRARY_CARD_META_ROW_HEIGHT)
            }.width('100%').height(LIBRARY_CARD_META_ROW_HEIGHT)
          }.width('100%').height(LIBRARY_CARD_INFO_HEIGHT)
            .padding({
              left: 7, right: 7, top: LIBRARY_CARD_INFO_PADDING_TOP, bottom: LIBRARY_CARD_INFO_PADDING_BOTTOM
            })
        }.width('100%').onClick(() => this.activateClipCard(clip))
      }
      if (this.managing) {
        Stack() {
          ActionButton({
            active: !this.busy, controlWidth: LIBRARY_CARD_CONTROL_HIT_SIZE,
            controlHeight: LIBRARY_CARD_CONTROL_HIT_SIZE, fill: '#00000000',
            accessibilityLabel: this.isManagementSelected(clip.id) ? '取消选择这段作品' : '选择这段作品',
            action: () => this.toggleManagementSelection(clip.id)
          }) {
            Stack() {
              Circle().width(20).height(20).fill(this.isManagementSelected(clip.id) ? LILAC : WHITE)
                .stroke(INK).strokeWidth(1.2)
              if (this.isManagementSelected(clip.id)) { Text('✓').fontSize(14).fontWeight(900).fontColor(WHITE) }
            }.width(20).height(20)
          }
        }.position({ x: 0, y: 0 })
        // A small visual cross retains a full finger target, separate from selection/preview.
        ActionButton({
          active: !this.busy, controlWidth: LIBRARY_CARD_CONTROL_HIT_SIZE,
          controlHeight: LIBRARY_CARD_CONTROL_HIT_SIZE, fill: '#00000000',
          accessibilityLabel: '删除这段作品', action: () => this.requestDeleteClip(clip.id)
        }) {
          DrumPaper({ fill: '#FFF1E8', paperWidth: 'auto', cornerRadius: 3, paperLineWidth: 1,
            offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
            Text('×').width(LIBRARY_CARD_DELETE_SIZE).height(LIBRARY_CARD_DELETE_SIZE).textAlign(TextAlign.Center)
              .fontSize(12).fontWeight(900).fontColor('#A34530')
          }
        }
      }
    }.width('100%').clip(false)
  }

  @Builder
  private managementButton(label: string, action: () => void) {
    ActionButton({
      label, active: !this.busy && !this.renderingAudio, controlWidth: 'auto', controlHeight: 32,
      contentPadding: { left: 12, right: 12 }, labelSize: 12, labelWeight: 900, labelColor: INK,
      fill: LILAC, cornerRadius: 5, lineWidth: 1, lineColor: INK,
      hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK }, action
    })
  }

  @Builder
  private managementBar() {
    Row({ space: 8 }) {
      ActionButton({
        active: !this.busy, controlWidth: 86, controlHeight: 40, fill: '#00000000',
        accessibilityLabel: this.allManagementSelected() ? '取消全选' : '全选作品',
        action: () => this.toggleSelectAll()
      }) {
        Row({ space: 5 }) {
          Stack() {
            Circle().width(18).height(18).fill(this.allManagementSelected() ? LILAC : WHITE).stroke(INK).strokeWidth(1)
            if (this.allManagementSelected()) { Text('✓').fontSize(12).fontWeight(900).fontColor(WHITE) }
          }.width(18).height(18)
          Text(this.allManagementSelected() ? '取消全选' : '全选').fontSize(11).fontWeight(900).fontColor(INK)
        }
      }
      Text(`已选 ${this.managementSelection.length} 项`).fontSize(10).fontWeight(900).fontColor(INK).width(64)
      Column() {
        ActionButton({
          label: this.busy ? '正在删除…' : `删除所选 (${this.managementSelection.length})`,
          active: !this.busy && this.managementSelection.length > 0, controlHeight: 40,
          labelSize: 12, labelWeight: 900, labelColor: INK,
          fill: this.managementSelection.length > 0 ? CORAL : '#DED8CF', cornerRadius: 6,
          lineWidth: 1.5, lineColor: INK,
          hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
          action: () => this.requestBatchDelete()
        })
      }.layoutWeight(1)
    }.width('100%').height(LIBRARY_MANAGEMENT_BAR_HEIGHT)
      .padding({
        left: LIBRARY_SIDE_INSET, right: LIBRARY_SIDE_INSET,
        top: 10, bottom: 10
      }).backgroundColor(PAPER)
      .border({ width: { top: 1 }, color: INK })
  }

  @Builder
  private calendarEntry(compact: boolean) {
    Column() {
      ActionButton({
        active: !this.busy && !this.renderingAudio, controlHeight: CALENDAR_ENTRY_HEIGHT,
        fill: compact ? PAPER : '#EEE6FA', cornerRadius: 5, lineWidth: 1, lineColor: INK,
        hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
        accessibilityLabel: '打开打卡日历', action: () => this.calendarVisible = true
      }) {
          Image($rawfile('comic/icons/calendar.svg')).width(CALENDAR_ENTRY_ICON_SIZE).height(CALENDAR_ENTRY_ICON_SIZE)
            .objectFit(ImageFit.Contain).accessibilityLevel('no')
      }
    }.width(compact ? CALENDAR_ENTRY_WIDTH : '100%')
  }

  @Builder
  private pauseConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        DrumPaper({
          fill: PAPER,
          paperWidth: '100%',
          cornerRadius: 9,
          paperLineWidth: 2,
          offsetX: COMIC_CARD_INK_OFFSET,
          offsetY: COMIC_CARD_INK_OFFSET
        }) {
          Column({ space: 14 }) {
            Text('先让练习停一拍').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
            Text('先暂停全队练习，再打开视频预览，避免播放器影响现场声音。视频已经保存在本机。')
              .fontSize(13).fontColor('#625C54').lineHeight(21).width('100%')
            Column() {
              ActionButton({
                label: '暂停练习并预览', active: !this.busy && !this.renderingAudio, controlHeight: 48,
                labelSize: 16, labelWeight: 900, labelColor: INK, fill: CORAL,
                cornerRadius: 6, lineWidth: 1.5, lineColor: INK,
                hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
                action: () => { void this.pauseAndContinue(); }
              })
            }.width('100%')
            ActionButton({
              label: '继续练习，稍后再看', active: !this.busy && !this.renderingAudio,
              controlWidth: 'auto', controlHeight: 'auto', contentPadding: 6,
              labelSize: 12, labelWeight: 900, fill: Color.Transparent,
              action: () => this.pauseConfirmVisible = false
            })
          }.width('100%').padding(20)
        }
      }.width(SHARE_SHEET_WIDTH)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
      .padding({ right: COMIC_CARD_INK_OFFSET, bottom: COMIC_CARD_INK_OFFSET })
  }

  @Builder
  private deleteConfirm() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        DrumPaper({
          fill: PAPER,
          paperWidth: '100%',
          cornerRadius: 9,
          paperLineWidth: 2,
          offsetX: COMIC_CARD_INK_OFFSET,
          offsetY: COMIC_CARD_INK_OFFSET
        }) {
          Column({ space: 14 }) {
            Text(this.deleteIsBatch ? `删除这 ${this.deleteClipIds.length} 段作品？` : '删除这段作品？')
              .fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
            Text('将从本机作品中移除，已经保存到相册的副本不受影响。').fontSize(13).fontColor('#625C54').lineHeight(21)
            Row({ space: 10 }) {
              Column() {
                ActionButton({
                  label: '取消', active: !this.busy && !this.renderingAudio, controlHeight: 46,
                  labelColor: INK, labelWeight: 900, fill: WHITE, cornerRadius: 6, lineWidth: 1.5, lineColor: INK,
                  hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                  action: () => this.deleteConfirmVisible = false
                })
              }.layoutWeight(1)
              Column() {
                ActionButton({
                  label: this.busy ? '正在删除…' : (this.deleteIsBatch ? `删除 ${this.deleteClipIds.length} 段` : '删除作品'),
                  active: !this.busy && !this.renderingAudio, controlHeight: 46,
                  labelColor: INK, labelWeight: 900, fill: CORAL, cornerRadius: 6, lineWidth: 1.5, lineColor: INK,
                  hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
                  action: () => { void this.deleteSelected(); }
                })
              }.layoutWeight(1)
            }.width('100%')
          }.width('100%').padding(20)
        }
      }.width(SHARE_SHEET_WIDTH)
    }.width('100%').height('100%').backgroundColor('#82000000').zIndex(110)
      .padding({ right: COMIC_CARD_INK_OFFSET, bottom: COMIC_CARD_INK_OFFSET })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.pageScroller) {
        Column({ space: 16 }) {
          Row() {
            ActionButton({
              active: !this.busy && !this.renderingAudio, controlWidth: 30, controlHeight: 'auto', fill: Color.Transparent,
              accessibilityLabel: this.managing ? '退出作品管理' : '返回',
              action: () => { if (this.managing) { this.exitManagement(); } else { router.back(); } }
            }) {
              Text('‹').fontSize(35).fontColor(INK).width('100%').textAlign(TextAlign.Start)
            }
            Text(this.managing ? '管理作品' : (this.scope === 'solo' ? '单人练习作品' : '多人练习作品'))
              .fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            if (this.managing) { this.managementButton('完成', () => this.exitManagement()) }
            else { Text('LOCAL\nTAKES').fontSize(9).fontWeight(900).letterSpacing(1).textAlign(TextAlign.End) }
          }.width('100%')
          if (this.clips.length === 0) {
            Image($rawfile('comic/decor/recording_share_hero.png')).width('100%').height(LIBRARY_HERO_HEIGHT)
              .objectFit(ImageFit.Contain).margin({ top: 30 })
            Text('还没有录下的同拍时刻').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic)
            Text('回到行进页，点击红色录制按钮。\n画面、节奏与周围声音，会一起留下来。')
              .fontSize(13).fontColor('#625C54').lineHeight(22).textAlign(TextAlign.Center)
            this.calendarEntry(false)
            ComicButton({
              label: '返回首页', fill: LILAC,
              hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
              action: () => router.back()
            })
          } else {
            if (!this.managing) {
            Column({ space: 10 }) {
              Column() {
                DrumPaper({
                  fill: INK,
                  paperWidth: '100%',
                  cornerRadius: 8,
                  paperLineWidth: 2,
                  clipContent: true,
                  offsetX: COMIC_CARD_INK_OFFSET,
                  offsetY: COMIC_CARD_INK_OFFSET
                }) {
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
                        DrumPaper({
                          fill: LILAC,
                          cornerRadius: 5,
                          paperLineWidth: 1,
                          paperLineColor: PAPER,
                          offsetX: COMIC_CONTROL_INK_OFFSET,
                          offsetY: COMIC_CONTROL_INK_OFFSET
                        }) {
                          Button('暂停练习后预览', { type: ButtonType.Normal })
                            .height(34).fontSize(12).fontWeight(900).fontColor(INK).backgroundColor('#00000000')
                            .onClick(() => this.requestPreview())
                        }
                      }
                    }.width('100%')
                  } else {
                    this.previewVideo()
                    if (this.selectedClip()?.coverPath !== undefined &&
                      (this.previewCoverVisible || this.previewLoading)) {
                      this.previewCover()
                    }
                  }
                  }.width('100%').height(VIDEO_PREVIEW_HEIGHT).backgroundColor(INK).clip(true)
                }
              }.width('100%').margin({ bottom: COMIC_CARD_INK_OFFSET })
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
              Column() {
                DrumPaper({
                  fill: '#E8F2EB',
                  paperWidth: '100%',
                  cornerRadius: 7,
                  paperLineWidth: 1,
                  offsetX: COMIC_CARD_INK_OFFSET,
                  offsetY: COMIC_CARD_INK_OFFSET
                }) {
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
                    ActionButton({
                      active: this.canAdjustMic(), controlWidth: LIBRARY_MIC_NUDGE_SIZE,
                      controlHeight: LIBRARY_MIC_NUDGE_SIZE, fill: '#D4DDDA',
                      cornerRadius: 7, lineWidth: 1, lineColor: INK,
                      hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                      accessibilityLabel: '人声提前 10 毫秒', action: () => this.nudgeMicShift(-MIC_SHIFT_STEP_MS)
                    }) {
                      Text('‹').fontSize(27).fontWeight(900).fontColor(INK)
                    }
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
                    ActionButton({
                      active: this.canAdjustMic(), controlWidth: LIBRARY_MIC_NUDGE_SIZE,
                      controlHeight: LIBRARY_MIC_NUDGE_SIZE, fill: '#D4DDDA',
                      cornerRadius: 7, lineWidth: 1, lineColor: INK,
                      hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                      accessibilityLabel: '人声延后 10 毫秒', action: () => this.nudgeMicShift(MIC_SHIFT_STEP_MS)
                    }) {
                      Text('›').fontSize(27).fontWeight(900).fontColor(INK)
                    }
                  }.width('100%').alignItems(VerticalAlign.Center)
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
                  }.width('100%').padding(12)
                }
              }.width('100%').margin({ bottom: COMIC_CARD_INK_OFFSET })
              Row({ space: 10 }) {
                Column() {
                  ActionButton({
                    active: !this.busy && !this.renderingAudio, controlHeight: ALBUM_SAVE_BUTTON_HEIGHT,
                    fill: WHITE, cornerRadius: 5, lineWidth: 1.5, lineColor: INK,
                    contentPadding: { left: ALBUM_SAVE_HORIZONTAL_PADDING, right: ALBUM_SAVE_HORIZONTAL_PADDING },
                    hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
                    accessibilityLabel: this.savingToAlbum ? '正在保存到相册' : '保存到相册',
                    action: () => { void this.saveSelected(); }
                  }) {
                    Row({ space: ALBUM_SAVE_LABEL_GAP }) {
                      Image($rawfile('comic/icons/save_to_album.svg'))
                        .width(ALBUM_SAVE_ICON_SIZE).height(ALBUM_SAVE_ICON_SIZE).objectFit(ImageFit.Contain)
                      Text(this.savingToAlbum ? '正在保存…' : '保存到相册')
                        .fontSize(13).fontWeight(900).fontColor(INK)
                    }
                  }
                }.layoutWeight(1)
                this.calendarEntry(true)
              }.width('100%')
            }.width('100%').clip(false)
            }
            Row({ space: 10 }) {
              Text(this.managing ? `共 ${this.clips.length} 段作品` : 'TAKES / 录制作品')
                .fontSize(12).fontWeight(900).letterSpacing(0.7)
              Blank()
              Text(this.managing ? `已选 ${this.managementSelection.length} 项` : `${this.clips.length} 段`)
                .fontSize(11).fontWeight(FontWeight.Bold)
              if (!this.managing) { this.managementButton('管理', () => this.enterManagement()) }
            }.width('100%').margin({ top: 6 })
            Column({ space: LIBRARY_GRID_GAP }) {
              ForEach(this.clipRows(), (row: RecordingClip[]) => {
                Row({ space: LIBRARY_GRID_GAP }) {
                  ForEach(row, (clip: RecordingClip) => {
                    Column() { this.clipCard(clip) }.layoutWeight(1)
                  }, (clip: RecordingClip) => `${clip.id}:${clip.path}:${clip.coverPath ?? ''}`)
                  if (row.length === 1) { Blank().layoutWeight(1) }
                }.width('100%').alignItems(VerticalAlign.Top)
              }, (row: RecordingClip[]) => row.map((clip: RecordingClip) => `${clip.id}:${clip.path}:${clip.coverPath ?? ''}`).join('|'))
            }.width('100%')
            if (!this.managing) {
              Text('视频与打卡记录保存在本机。分享后回到票根页，点击“去打卡”确认。')
                .fontSize(10).fontColor('#777065').lineHeight(18).width('100%')
            }
          }
        }.width('100%').clip(false)
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
          .padding({
            left: LIBRARY_SIDE_INSET, right: LIBRARY_SIDE_INSET,
            top: 10 + this.topSafeInset,
            bottom: (this.managing ? LIBRARY_MANAGEMENT_BAR_HEIGHT + 16 : 28) + this.bottomSafeInset + COMIC_CARD_INK_OFFSET
          })
          .onAreaChange(() => this.restorePendingScroll())
      }.width('100%').height('100%').scrollBar(BarState.Off).clip(false).align(Alignment.TopStart)
      if (this.managing) {
        Column() {
          this.managementBar()
        }.width('100%').padding({ bottom: this.bottomSafeInset }).backgroundColor(PAPER)
      }
      if (this.pauseConfirmVisible) {
        Stack({ alignContent: Alignment.Center }) {
          this.pauseConfirm()
        }.width('100%').height('100%').zIndex(110)
      }
      if (this.deleteConfirmVisible) {
        Stack({ alignContent: Alignment.Center }) {
          this.deleteConfirm()
        }.width('100%').height('100%').zIndex(110)
      }
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
