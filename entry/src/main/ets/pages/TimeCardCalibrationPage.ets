import { router } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { MonotonicClock } from '../common/MonotonicClock';
import { logUserFailure, showUserNotice } from '../common/UserFeedback';
import { saveCalibrationMs } from '../store/AudioLatencyPersistence';
import { BLUE, CARD_SHADOW, CONTROL_SHADOW, CORAL, INK, LILAC, PAPER, TEAL, WHITE } from '../components/ComicKit';

type CalibrationPhase = 'intro' | 'changing' | 'arming' | 'listening' | 'measuring' | 'missed' | 'result';
type ResultAction = 'save' | 'retry';

const CALIBRATION_BPM: number = 120;
const BEAT_INTERVAL_MS: number = 60000 / CALIBRATION_BPM;
const COUNT_IN_BEATS: number = 4;
const TOTAL_TAP_COUNT: number = 32;
const BEATS_PER_BAR: number = 4;
const AUDIO_START_LEAD_MS: number = 1300;
const FIRST_TAP_EARLY_MS: number = 80;
// The first heard Bluetooth beat may be more than one 500 ms period late.
const FIRST_TAP_LATE_MS: number = 2000;
const TAP_INTERVAL_TOLERANCE_MS: number = 150;
const MIN_MEASURED_OFFSET_MS: number = -120;
const MAX_MEASURED_OFFSET_MS: number = 2000;
const PREVIEW_BEAT_COUNT: number = 8;
const COUNTDOWN_FONT_SIZE: number = 138;
const COUNTDOWN_START_SCALE: number = 0.52;
const COUNTDOWN_SCALE_RANGE: number = 1.1;
const COUNTDOWN_MAX_OPACITY: number = 0.76;
const COUNTDOWN_CENTER_Y_OFFSET: number = 0;
const COUNTDOWN_REFRESH_MS: number = 32;
const RESULT_REVIEW_MS: number = 1000;
// Longer than one 500ms beat, so continued tapping cannot unlock the buttons
// in the gap between two otherwise regular taps.
const RESULT_TOUCH_QUIET_MS: number = 700;

// These registrations compensate for the generated PNGs' different artwork
// origins. All positions below use the same 1254-pixel design coordinate space.
const SCENE_DESIGN_SIZE: number = 1254;
const SCENE_DESIGN_HEIGHT: number = 1450;
const SCENE_MAX_WIDTH: number = 360;
const PAGE_SIDE_PADDING: number = 18;
const TAP_PAD_HEIGHT: number = 132;
const CONTENT_ACTIONS_GAP: number = 12;
const CARD_SCALE: number = 0.68;
const CARD_X: number = 170;
const PAPER_DEPTH_SCALE: number = 0.966;
const PAPER_PLANE_ANCHOR_Y: number = 1020;
const PAPER_CENTER_X: number = 628;
const PAPER_PERSPECTIVE: number = 0.00029;
// Rosen's rotation camera passes its Z coordinate to Skia in inches. Convert
// our pixel-sized projection distance at this boundary, not the paper layout.
const ROTATION_CAMERA_PIXELS_PER_INCH: number = 72;
const PUNCH_PLANE_Y: number = 686;
const CARD_START_Y: number = PUNCH_PLANE_Y - PAPER_PLANE_ANCHOR_Y * CARD_SCALE;
const PAPER_WINDOW_BOTTOM: number = 785;
const FRONT_SCALE: number = 0.88;
const FRONT_X: number = 50;
const FRONT_Y: number = 110;
const RAM_SCALE: number = 0.4;
const RAM_CENTER_X: number = 626.5;
const RAM_TIP_Y: number = 781;
const RAM_STROKE: number = 12;
const RAM_Y: number = PUNCH_PLANE_Y - RAM_TIP_Y * RAM_SCALE - RAM_STROKE;
// The foreground bracket has a different source footprint. Register its die
// center with the existing punch axis rather than moving the paper or ram.
const GUIDE_SCALE: number = 0.166;
const GUIDE_CENTER_X: number = 627;
// Source artwork was shifted up 134 px; its physical die anchor moved too.
// Keep this source coordinate current so paper and ram still share its plane.
const GUIDE_DIE_Y: number = 505;
const GUIDE_Y: number = PUNCH_PLANE_Y - GUIDE_DIE_Y * GUIDE_SCALE;
const LEVER_SCALE: number = 0.65;
const LEVER_PIVOT_X: number = 690;
const LEVER_PIVOT_Y: number = 1030;
const LEVER_AXIS_X: number = 1144;
const LEVER_AXIS_Y: number = 676;
const LEVER_PRESS_ANGLE: number = -32;
const HOLE_FIRST_X: number = 420;
const HOLE_STEP_X: number = 150;
const HOLE_FIRST_Y: number = PAPER_PLANE_ANCHOR_Y;
const HOLE_STEP_Y: number = -82;
const HOLE_DIAMETER: number = 26;
const MISSED_CARD_Y: number = -141;
const MISSED_FRAME_Y: number = 140;
const MISSED_CLIP_TOP: number = -160;
const RESULT_CARD_SCALE: number = 0.94;
const RESULT_CARD_X: number = 36;
const RESULT_CARD_Y: number = 30;
const RESULT_TEXT_X: number = 310;
const RESULT_TEXT_Y: number = 165;
const RESULT_TEXT_WIDTH: number = 620;
const RESULT_TEXT_GAP: number = 10;
const RESULT_TITLE_HEIGHT: number = 62;
const RESULT_VALUE_HEIGHT: number = 116;
const RESULT_JITTER_HEIGHT: number = 42;
const RESULT_MACHINE_SCALE: number = 0.58;
const RESULT_MACHINE_Y: number = 775;
const TAP_INDICES: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
];

@Entry
@Component
struct TimeCardCalibrationPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('btAudioActive') @Watch('onBluetoothAudioRouteChanged') btAudioActive: boolean = false;
  @State phase: CalibrationPhase = 'intro';
  @State tapCount: number = 0;
  @State visualTapCount: number = 0;
  @State resultMs: number = 0;
  @State jitterMs: number = 0;
  @State missReason: string = '';
  @State sceneWidth: number = 320;
  @State cardScale: number = CARD_SCALE;
  @State cardX: number = CARD_X;
  @State cardY: number = CARD_START_Y;
  @State paperDepthScale: number = PAPER_DEPTH_SCALE;
  @State paperPerspective: number = PAPER_PERSPECTIVE;
  @State paperWidthScale: number = 1;
  @State paperOpacity: number = 1;
  @State frameY: number = 0;
  @State machineScale: number = 1;
  @State machineOpacity: number = 1;
  @State paperClipTop: number = 0;
  @State paperReleased: boolean = false;
  @State carriageColumn: number = 0;
  @State leverAngle: number = 0;
  @State ramDrop: number = 0;
  @State stampOpacity: number = 0;
  @State retryReady: boolean = false;
  @State touchHeld: boolean = false;
  @State previewPulse: number = 0;
  @State previewLabel: string = '';
  @State operationError: string = '';
  @State measurementDetailsExpanded: boolean = false;
  @State saving: boolean = false;
  @State resultActionsReady: boolean = false;
  @State countdownNumber: number = 0;
  @State countdownScale: number = COUNTDOWN_START_SCALE;
  @State countdownOpacity: number = 0;
  private readonly pageScroller: Scroller = new Scroller();
  private audioStartAtMs: number = 0;
  private measurementStartAtMs: number = 0;
  private lastTapAtMs: number = 0;
  private tapOffsetsMs: number[] = [];
  private missTimer: number = -1;
  private finishTimer: number = -1;
  private previewTimer: number = -1;
  private previewStopTimer: number = -1;
  private countdownTimer: number = -1;
  private countdownStopTimer: number = -1;
  private sceneTimers: number[] = [];
  private runToken: number = 0;
  private previewToken: number = 0;
  private punchAnimationActive: boolean = false;
  private pageActive: boolean = false;
  private resultReviewTimer: number = -1;
  private resultReviewNotBeforeMs: number = Number.POSITIVE_INFINITY;
  private resultLastTouchAtMs: number = 0;
  private resultActionsEnabledAtMs: number = Number.POSITIVE_INFINITY;
  private resultActionTouchToken: number = -1;
  private pendingResultAction: ResultAction | undefined = undefined;

  aboutToAppear(): void {
    this.pageActive = true;
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.runToken++;
    this.clearTimers();
    this.publishCalibrationActivity(false);
    void AppSession.get()?.stopLatencyCalibration();
  }

  onBackPress(): boolean {
    if (!this.saving) {
      router.back();
    }
    return true;
  }

  private cancelSceneTimers(): void {
    for (let i = 0; i < this.sceneTimers.length; i++) {
      clearTimeout(this.sceneTimers[i]);
    }
    this.sceneTimers = [];
    this.punchAnimationActive = false;
  }

  private clearPreviewTimers(): void {
    this.previewToken++;
    if (this.previewTimer >= 0) {
      clearInterval(this.previewTimer);
      this.previewTimer = -1;
    }
    if (this.previewStopTimer >= 0) {
      clearTimeout(this.previewStopTimer);
      this.previewStopTimer = -1;
    }
    this.previewPulse = 0;
    this.previewLabel = '';
  }

  private clearTimers(): void {
    this.clearResultReview();
    if (this.missTimer >= 0) {
      clearTimeout(this.missTimer);
      this.missTimer = -1;
    }
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
    }
    this.cancelSceneTimers();
    this.clearPreviewTimers();
    this.clearCountdown();
  }

  private clearResultReview(): void {
    if (this.resultReviewTimer >= 0) {
      clearTimeout(this.resultReviewTimer);
      this.resultReviewTimer = -1;
    }
    this.resultActionsReady = false;
    this.resultReviewNotBeforeMs = Number.POSITIVE_INFINITY;
    this.resultActionsEnabledAtMs = Number.POSITIVE_INFINITY;
    this.pendingResultAction = undefined;
    this.resultActionTouchToken = -1;
    this.resultLastTouchAtMs = MonotonicClock.nowMs();
  }

  private beginResultReview(token: number): void {
    if (!this.pageActive || token !== this.runToken || this.phase !== 'result') {
      return;
    }
    this.resultReviewNotBeforeMs = MonotonicClock.nowMs() + RESULT_REVIEW_MS;
    this.scheduleResultReviewCheck(token);
  }

  private scheduleResultReviewCheck(token: number): void {
    if (!this.pageActive || token !== this.runToken || this.phase !== 'result' || this.resultActionsReady) {
      return;
    }
    if (this.resultReviewTimer >= 0) {
      clearTimeout(this.resultReviewTimer);
      this.resultReviewTimer = -1;
    }
    if (this.touchHeld || !Number.isFinite(this.resultReviewNotBeforeMs)) {
      return;
    }
    const now = MonotonicClock.nowMs();
    const remainingMs = Math.max(this.resultReviewNotBeforeMs,
      this.resultLastTouchAtMs + RESULT_TOUCH_QUIET_MS) - now;
    if (remainingMs <= 0) {
      this.resultActionsEnabledAtMs = now;
      this.resultActionsReady = true;
      return;
    }
    const timer = setTimeout(() => {
      // Replaced checks and old rounds must not unlock the current result.
      if (this.resultReviewTimer !== timer) {
        return;
      }
      this.resultReviewTimer = -1;
      this.scheduleResultReviewCheck(token);
    }, remainingMs);
    this.resultReviewTimer = timer;
  }

  private onPageTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.touchHeld = true;
    } else if (event.type === TouchType.Up) {
      this.touchHeld = event.touches?.some((touch: TouchObject) =>
        !event.changedTouches?.some((changed: TouchObject) => changed.id === touch.id)) ?? false;
    } else if (event.type === TouchType.Cancel) {
      this.touchHeld = false;
      this.pendingResultAction = undefined;
    } else {
      return;
    }
    if (this.phase === 'result' && !this.resultActionsReady) {
      this.resultLastTouchAtMs = MonotonicClock.nowMs();
      this.scheduleResultReviewCheck(this.runToken);
    }
  }

  private onResultActionTouch(event: TouchEvent, action: ResultAction): void {
    if (event.type === TouchType.Cancel) {
      this.pendingResultAction = undefined;
    } else if (event.type === TouchType.Down) {
      this.resultActionTouchToken = this.runToken;
      this.pendingResultAction = this.pageActive && this.phase === 'result' &&
        this.resultActionsReady && !this.saving &&
        this.touchMonoMs(event) >= this.resultActionsEnabledAtMs ? action : undefined;
    }
  }

  private consumeResultActionClick(action: ResultAction, event: ClickEvent): boolean {
    const freshTouch = this.pendingResultAction === action && this.resultActionTouchToken === this.runToken;
    this.pendingResultAction = undefined;
    // A press begun while locked remains invalid even if its Up/Click arrives
    // after unlock. Keyboard/accessibility clicks do not have a touch Down.
    return this.pageActive && this.phase === 'result' && this.resultActionsReady && !this.saving &&
      (event.source !== SourceType.TouchScreen || freshTouch);
  }

  private clearCountdown(): void {
    if (this.countdownTimer >= 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
    if (this.countdownStopTimer >= 0) {
      clearTimeout(this.countdownStopTimer);
      this.countdownStopTimer = -1;
    }
    this.countdownNumber = 0;
    this.countdownScale = COUNTDOWN_START_SCALE;
    this.countdownOpacity = 0;
  }

  private refreshCountdown(token: number): void {
    if (!this.pageActive || token !== this.runToken) {
      return;
    }
    const now = MonotonicClock.nowMs();
    if (this.phase !== 'listening' || now >= this.measurementStartAtMs) {
      this.clearCountdown();
      return;
    }
    if (now < this.audioStartAtMs) {
      this.countdownNumber = 0;
      this.countdownOpacity = 0;
      return;
    }
    // Derive each pulse from the scheduled audio clock, not accumulated timer
    // ticks. A late startup or busy UI cannot extend the four-beat count-in.
    const beatPosition = (now - this.audioStartAtMs) / BEAT_INTERVAL_MS;
    const beatIndex = Math.floor(beatPosition);
    const phase = beatPosition - beatIndex;
    const scale = COUNTDOWN_START_SCALE + phase * COUNTDOWN_SCALE_RANGE;
    const opacity = COUNTDOWN_MAX_OPACITY * (1 - phase * phase);
    const number = COUNT_IN_BEATS - beatIndex;
    if (this.countdownNumber !== number) { this.countdownNumber = number; }
    if (Math.abs(this.countdownScale - scale) > 0.01) { this.countdownScale = scale; }
    if (Math.abs(this.countdownOpacity - opacity) > 0.01) { this.countdownOpacity = opacity; }
  }

  private startCountdown(token: number): void {
    this.clearCountdown();
    this.refreshCountdown(token);
    if (this.pageActive && token === this.runToken && this.phase === 'listening' &&
      MonotonicClock.nowMs() < this.measurementStartAtMs) {
      this.countdownTimer = setInterval(() => { this.refreshCountdown(token); }, COUNTDOWN_REFRESH_MS);
      this.countdownStopTimer = setTimeout(() => {
        if (this.pageActive && token === this.runToken) { this.clearCountdown(); }
      }, this.measurementStartAtMs - MonotonicClock.nowMs());
    }
  }

  private queueScene(delayMs: number, token: number, action: () => void): void {
    const timer = setTimeout(() => {
      if (this.pageActive && token === this.runToken) {
        action();
      }
    }, delayMs);
    this.sceneTimers.push(timer);
  }

  private publishCalibrationActivity(active: boolean): void {
    const controller = AppSession.get()?.controller;
    if (controller !== undefined) {
      void controller.setBluetoothCalibrationActive(active);
    }
  }

  private onBluetoothAudioRouteChanged(): void {
    if (this.btAudioActive) {
      return;
    }
    this.operationError = '';
    if (this.phaseIsActive() || this.phase === 'changing') {
      this.failMeasurement('蓝牙耳机已断开，请重新连接后再测');
      return;
    }
    this.runToken++;
    this.clearTimers();
    if (this.phase === 'result') {
      // Route invalidation cancels the delayed lift. A completed card must
      // still be readable upright even when saving is disabled by disconnect.
      this.setResultPose();
      this.beginResultReview(this.runToken);
    }
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
    this.retryReady = true;
  }

  private resetMachine(): void {
    this.visualTapCount = 0;
    this.carriageColumn = 0;
    this.leverAngle = 0;
    this.ramDrop = 0;
    this.cardScale = CARD_SCALE;
    this.cardX = CARD_X;
    this.cardY = CARD_START_Y;
    this.paperDepthScale = PAPER_DEPTH_SCALE;
    this.paperPerspective = PAPER_PERSPECTIVE;
    this.paperWidthScale = 1;
    this.paperOpacity = 1;
    this.frameY = 0;
    this.machineScale = 1;
    this.machineOpacity = 1;
    this.paperClipTop = 0;
    this.paperReleased = false;
    this.stampOpacity = 0;
    this.retryReady = false;
  }

  private async startMeasurement(): Promise<void> {
    if (this.saving || this.phaseIsActive() || !this.pageActive) {
      return;
    }
    if (!this.btAudioActive) {
      this.operationError = '请先连接蓝牙耳机，再开始打卡';
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      if (this.phase === 'changing') {
        this.failMeasurement('会话已结束，请返回大厅重新进入');
        return;
      }
      this.operationError = '会话已结束，请返回大厅重新进入';
      return;
    }
    const token = ++this.runToken;
    this.operationError = '';
    this.measurementDetailsExpanded = false;
    this.clearTimers();
    this.publishCalibrationActivity(true);
    this.phase = 'arming';
    this.tapCount = 0;
    this.resultMs = 0;
    this.jitterMs = 0;
    this.missReason = '';
    this.tapOffsetsMs = [];
    this.lastTapAtMs = 0;
    this.resetMachine();
    this.audioStartAtMs = MonotonicClock.nowMs() + AUDIO_START_LEAD_MS;
    this.measurementStartAtMs = this.audioStartAtMs + COUNT_IN_BEATS * BEAT_INTERVAL_MS;
    try {
      await session.scheduleLatencyTapMeasurement(this.audioStartAtMs, COUNT_IN_BEATS);
      if (!this.pageActive || token !== this.runToken || this.phase !== 'arming') {
        return;
      }
      this.phase = 'listening';
      this.startCountdown(token);
      this.armMissTimer(this.measurementStartAtMs + FIRST_TAP_LATE_MS, token);
    } catch (err) {
      if (this.pageActive && token === this.runToken) {
        logUserFailure('calibration.start', err);
        this.failMeasurement('音频启动失败，请稍后重试');
      }
    }
  }

  private retryMeasurement(): void {
    // Result buttons already validate a fresh gesture; its Click may run before
    // the parent's Up handler clears touchHeld. Missed-card retry still waits.
    if (!this.pageActive || this.saving || (this.touchHeld && this.phase !== 'result') ||
      (this.phase === 'result' && !this.resultActionsReady) ||
      this.phase === 'changing' || this.phaseIsActive()) {
      return;
    }
    if (!this.btAudioActive) {
      this.operationError = '请先重新连接蓝牙耳机';
      return;
    }
    if (AppSession.get() === undefined) {
      this.operationError = '会话已结束，请返回大厅重新进入';
      return;
    }
    const token = ++this.runToken;
    this.operationError = '';
    this.clearTimers();
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
    this.phase = 'changing';
    this.queueScene(0, token, () => { this.pageScroller.scrollEdge(Edge.Top); });
    this.retryReady = false;
    // The old paper leaves with its holes. Only then do we install a fresh
    // paper model; clearing the holes in place would look like erasing a card.
    animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.cardY = -1500;
      this.paperOpacity = 0;
    });
    this.queueScene(240, token, () => {
      this.tapCount = 0;
      this.tapOffsetsMs = [];
      this.lastTapAtMs = 0;
      this.resetMachine();
      this.cardY = -1500;
      this.paperOpacity = 0;
      this.queueScene(20, token, () => {
        animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.cardY = CARD_START_Y;
          this.paperOpacity = 1;
        });
      });
      this.queueScene(250, token, () => { void this.startMeasurement(); });
    });
  }

  private armMissTimer(deadlineMs: number, token: number): void {
    if (this.missTimer >= 0) {
      clearTimeout(this.missTimer);
    }
    this.missTimer = setTimeout(() => {
      if (token === this.runToken && this.pageActive && this.phaseIsActive() && this.tapCount < TOTAL_TAP_COUNT) {
        this.failMeasurement(this.tapCount === 0 ? '第一拍没有跟上' : `第 ${this.tapCount + 1} 拍没有接到敲击`);
      }
    }, Math.max(0, deadlineMs - MonotonicClock.nowMs()));
  }

  private phaseIsActive(): boolean {
    return this.phase === 'arming' || this.phase === 'listening' || this.phase === 'measuring';
  }

  /** ArkUI timestamps are boot-time nanoseconds; older epochs need a bounded fallback. */
  private touchMonoMs(event: TouchEvent): number {
    const eventMs = event.timestamp / 1000000;
    const now = MonotonicClock.nowMs();
    return Math.abs(eventMs - now) <= 2000 ? eventMs : now;
  }

  private onTapTouch(event: TouchEvent): void {
    if (event.type !== TouchType.Down || !this.phaseIsActive() || this.tapCount >= TOTAL_TAP_COUNT) {
      return;
    }
    this.touchHeld = true;
    const tapAtMs = this.touchMonoMs(event);
    if (tapAtMs < this.measurementStartAtMs - FIRST_TAP_EARLY_MS || this.phase === 'arming') {
      return;
    }
    this.acceptTap(tapAtMs);
  }

  private acceptTap(tapAtMs: number): void {
    if (this.tapCount === 0) {
      if (tapAtMs > this.measurementStartAtMs + FIRST_TAP_LATE_MS) {
        this.failMeasurement('第一拍没有跟上');
        return;
      }
    } else {
      const interval = tapAtMs - this.lastTapAtMs;
      if (interval < BEAT_INTERVAL_MS - TAP_INTERVAL_TOLERANCE_MS) {
        this.failMeasurement('检测到重复敲击');
        return;
      }
      if (interval > BEAT_INTERVAL_MS + TAP_INTERVAL_TOLERANCE_MS) {
        this.failMeasurement(`第 ${this.tapCount + 1} 拍断拍了`);
        return;
      }
    }
    const scheduledBeatAt = this.measurementStartAtMs + this.tapCount * BEAT_INTERVAL_MS;
    const offsetMs = tapAtMs - scheduledBeatAt;
    if (offsetMs < MIN_MEASURED_OFFSET_MS || offsetMs > MAX_MEASURED_OFFSET_MS) {
      this.failMeasurement('敲击偏离当前拍点太远');
      return;
    }
    // The sample and its hole commit together before any visual work. A busy
    // animation queue must never delay or lock the next touch timestamp.
    this.phase = 'measuring';
    this.tapOffsetsMs.push(offsetMs);
    this.lastTapAtMs = tapAtMs;
    this.tapCount++;
    this.clearCountdown();
    this.enqueuePunchFeedback();
    if (this.tapCount >= TOTAL_TAP_COUNT) {
      if (this.missTimer >= 0) {
        clearTimeout(this.missTimer);
        this.missTimer = -1;
      }
      AppSession.get()?.pauseLatencyCalibration();
      const token = this.runToken;
      this.finishTimer = setTimeout(() => {
        this.finishWhenSettled(token);
      }, 390);
      return;
    }
    this.armMissTimer(tapAtMs + BEAT_INTERVAL_MS + TAP_INTERVAL_TOLERANCE_MS, this.runToken);
  }

  private enqueuePunchFeedback(): void {
    if (this.punchAnimationActive || this.visualTapCount >= this.tapCount || this.phase !== 'measuring') {
      return;
    }
    this.punchAnimationActive = true;
    this.carriageColumn = this.visualTapCount % BEATS_PER_BAR;
    const token = this.runToken;
    animateTo({ duration: 60, curve: Curve.EaseOut }, () => {
      this.leverAngle = LEVER_PRESS_ANGLE;
      this.ramDrop = RAM_STROKE;
    });
    this.queueScene(90, token, () => {
      animateTo({ duration: 80, curve: Curve.EaseOut }, () => {
        this.leverAngle = 0;
        this.ramDrop = 0;
      });
    });
    this.queueScene(190, token, () => {
      this.visualTapCount++;
      animateTo({ duration: 80, curve: Curve.EaseInOut }, () => {
        this.carriageColumn = this.visualTapCount % BEATS_PER_BAR;
        this.updatePaperFeed(this.visualTapCount);
      });
      this.queueScene(90, token, () => {
        this.punchAnimationActive = false;
        this.enqueuePunchFeedback();
      });
    });
  }

  private feedY(count: number): number {
    const row = Math.min(7, Math.floor(count / BEATS_PER_BAR));
    return PUNCH_PLANE_Y - this.paperY(HOLE_FIRST_Y + row * HOLE_STEP_Y) * CARD_SCALE;
  }

  private updatePaperFeed(count: number): void {
    const row = Math.min(7, Math.floor(count / BEATS_PER_BAR));
    const rowY = HOLE_FIRST_Y + row * HOLE_STEP_Y;
    // Perspective narrows rows farther from the viewer. Grow the whole paper
    // by that row's divisor as it feeds in, keeping its punch line as wide as
    // the inlet. Image and holes must share this same transform.
    this.paperWidthScale = this.paperDivisor(rowY);
    this.cardY = this.feedY(count);
  }

  private paperDivisor(sourceY: number): number {
    return 1 + this.paperPerspective * (PAPER_PLANE_ANCHOR_Y - sourceY);
  }

  private paperY(sourceY: number): number {
    return PAPER_PLANE_ANCHOR_Y + (sourceY - PAPER_PLANE_ANCHOR_Y) *
      this.paperDepthScale / this.paperDivisor(sourceY);
  }

  private paperScale(): ScaleOptions {
    return {
      x: this.paperWidthScale, y: 1,
      centerX: PAPER_CENTER_X * this.cardScale * this.q(),
      centerY: PAPER_PLANE_ANCHOR_Y * this.cardScale * this.q()
    };
  }

  private paperRotation(): RotateOptions {
    // The 2D transform(matrix) path decomposes perspective and applies a
    // separate default pivot. Native rotation keeps the image and ink on one
    // plane, with an explicit pivot shared with the feed-width compensation.
    // Keep the camera finite when the result turns upright (angle = 0).
    const cameraDistance = Math.sqrt(1 - PAPER_DEPTH_SCALE * PAPER_DEPTH_SCALE) / PAPER_PERSPECTIVE;
    return {
      x: 1, y: 0, z: 0, angle: Math.acos(this.paperDepthScale) * 180 / Math.PI,
      centerX: PAPER_CENTER_X * this.cardScale * this.q(),
      centerY: PAPER_PLANE_ANCHOR_Y * this.cardScale * this.q(),
      perspective: -vp2px(cameraDistance * this.cardScale * this.q()) / ROTATION_CAMERA_PIXELS_PER_INCH
    };
  }

  private finishWhenSettled(token: number): void {
    if (token !== this.runToken || !this.pageActive || this.phase !== 'measuring') {
      return;
    }
    // Audio and sampling already stopped at touch 32. Renderer/UI stalls can
    // leave valid touches queued, so finish only after every stroke has lifted.
    if (this.punchAnimationActive || this.visualTapCount < this.tapCount) {
      this.finishTimer = setTimeout(() => { this.finishWhenSettled(token); }, 90);
      return;
    }
    this.finishMeasurement();
  }

  private settleMachine(): void {
    this.visualTapCount = this.tapCount;
    this.leverAngle = 0;
    this.ramDrop = 0;
    this.carriageColumn = this.tapCount % BEATS_PER_BAR;
  }

  private finishMeasurement(): void {
    this.finishTimer = -1;
    if (this.tapOffsetsMs.length !== TOTAL_TAP_COUNT || this.tapCount !== TOTAL_TAP_COUNT) {
      return;
    }
    this.cancelSceneTimers();
    this.settleMachine();
    let sum = 0;
    for (let i = 0; i < this.tapOffsetsMs.length; i++) {
      sum += this.tapOffsetsMs[i];
    }
    const mean = sum / this.tapOffsetsMs.length;
    let variance = 0;
    for (let i = 0; i < this.tapOffsetsMs.length; i++) {
      const deviation = this.tapOffsetsMs[i] - mean;
      variance += deviation * deviation;
    }
    this.resultMs = Math.max(0, Math.round(mean));
    this.jitterMs = Math.round(Math.sqrt(variance / this.tapOffsetsMs.length));
    this.clearResultReview();
    this.phase = 'result';
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
    const token = this.runToken;
    this.queueScene(0, token, () => { this.pageScroller.scrollEdge(Edge.Top); });
    animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
      this.cardY = MISSED_CARD_Y;
      this.paperClipTop = MISSED_CLIP_TOP;
      this.frameY = MISSED_FRAME_Y;
    });
    this.queueScene(300, token, () => {
      this.cardY += this.frameY;
      this.paperReleased = true;
      animateTo({ duration: 350, curve: Curve.EaseInOut,
        onFinish: () => { this.beginResultReview(token); } }, () => {
        this.setResultPose();
      });
    });
  }

  private setResultPose(): void {
    this.paperReleased = true;
    this.cardScale = RESULT_CARD_SCALE;
    this.cardX = RESULT_CARD_X;
    this.cardY = RESULT_CARD_Y;
    this.paperDepthScale = 1;
    this.paperPerspective = 0;
    this.paperWidthScale = 1;
    this.frameY = RESULT_MACHINE_Y;
    this.machineScale = RESULT_MACHINE_SCALE;
    this.machineOpacity = 0.72;
  }

  private failMeasurement(reason: string): void {
    // Invalidate pending audio startup as well as timers: arming may fail while
    // scheduleLatencyTapMeasurement is still awaiting renderer preparation.
    const token = ++this.runToken;
    this.clearTimers();
    this.missReason = reason;
    this.operationError = '';
    this.phase = 'missed';
    this.retryReady = false;
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
    this.visualTapCount = this.tapCount;
    animateTo({ duration: 140, curve: Curve.EaseOut }, () => { this.settleMachine(); });
    this.queueScene(180, token, () => {
      animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
        this.paperClipTop = MISSED_CLIP_TOP;
        this.cardY = MISSED_CARD_Y;
        this.frameY = MISSED_FRAME_Y;
      });
    });
    this.queueScene(500, token, () => {
      animateTo({ duration: 150 }, () => { this.stampOpacity = 1; });
    });
    this.queueScene(1000, token, () => { this.retryReady = true; });
  }

  private async finishAndSave(): Promise<void> {
    if (this.saving || !this.pageActive || this.phase !== 'result' || !this.resultActionsReady ||
      this.tapCount !== TOTAL_TAP_COUNT || this.tapOffsetsMs.length !== TOTAL_TAP_COUNT) {
      return;
    }
    if (!this.btAudioActive) {
      this.operationError = '蓝牙耳机已断开，本次结果未保存，请重新测量';
      return;
    }
    const token = this.runToken;
    const result = this.resultMs;
    this.operationError = '';
    this.saving = true;
    this.clearPreviewTimers();
    AppSession.get()?.pauseLatencyCalibration();
    try {
      await saveCalibrationMs(result);
      if (!this.pageActive || token !== this.runToken || !this.btAudioActive) {
        return;
      }
      const session = AppSession.get();
      session?.metronome.refreshOutputCalibration();
      session?.keepLatencyCalibrationRendererAlive();
      session?.markLatencyCalibrationRoute(true);
      showUserNotice('已保存并生效', 'calibration.save');
      router.back();
    } catch (err) {
      if (this.pageActive && token === this.runToken) {
        logUserFailure('calibration.save', err);
        this.operationError = '保存失败，请重试';
      }
    } finally {
      if (this.pageActive) {
        this.saving = false;
      }
    }
  }

  private async startResultPreview(compensationMs: number, label: string): Promise<void> {
    if (this.saving || !this.pageActive || this.phase !== 'result') {
      return;
    }
    if (!this.btAudioActive) {
      this.operationError = '耳机已断开，请重新连接并测量';
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      this.operationError = '会话已结束，请返回大厅重新进入';
      return;
    }
    this.operationError = '';
    this.clearPreviewTimers();
    const token = this.previewToken;
    const run = this.runToken;
    session.pauseLatencyCalibration();
    this.previewLabel = label;
    const visualStartAtMs = MonotonicClock.nowMs() + AUDIO_START_LEAD_MS;
    this.previewTimer = setInterval(() => {
      if (!this.pageActive || token !== this.previewToken || run !== this.runToken || this.phase !== 'result') {
        return;
      }
      const elapsed = MonotonicClock.nowMs() - visualStartAtMs;
      this.previewPulse = elapsed >= 0 && elapsed % BEAT_INTERVAL_MS < 110 ? 1 : 0;
    }, 16);
    this.previewStopTimer = setTimeout(() => {
      if (!this.pageActive || token !== this.previewToken || run !== this.runToken || this.phase !== 'result') {
        return;
      }
      this.clearPreviewTimers();
      session.pauseLatencyCalibration();
    }, AUDIO_START_LEAD_MS + PREVIEW_BEAT_COUNT * BEAT_INTERVAL_MS);
    try {
      await session.scheduleLatencyPreview(visualStartAtMs, compensationMs);
    } catch (err) {
      if (this.pageActive && token === this.previewToken && run === this.runToken && this.phase === 'result') {
        this.clearPreviewTimers();
        session.pauseLatencyCalibration();
        logUserFailure('calibration.preview', err);
        this.operationError = '试听未能开始，请重试';
      }
    }
  }

  private activeInstruction(): string {
    if (this.tapCount === TOTAL_TAP_COUNT) {
      return '打孔完成，正在整理这张时间卡…';
    }
    if (this.phase === 'arming') {
      return '正在准备耳机声音…';
    }
    if (this.phase === 'listening') {
      return '先听完整一小节，从下一个「滴」开始敲';
    }
    return '只跟着耳机里的声音，轻敲下方垫子';
  }

  private errorTitle(): string {
    if (this.missReason.indexOf('会话') >= 0) {
      return '当前会话已结束';
    }
    if (this.missReason.indexOf('断开') >= 0) {
      return '耳机连接中断了';
    }
    if (this.missReason.indexOf('音频启动') >= 0) {
      return '节拍还没开始';
    }
    if (this.missReason.indexOf('重复') >= 0) {
      return '两次敲击太近了';
    }
    if (this.missReason.indexOf('偏离') >= 0) {
      return '节奏偏离了';
    }
    return this.tapCount === 0 ? '第一拍还没接到' : '这一拍没接上';
  }

  private errorAdvice(): string {
    if (this.missReason.indexOf('会话') >= 0) {
      return '返回队伍大厅，重新进入打卡测量。';
    }
    if (!this.btAudioActive) {
      return '重新连接耳机后，再打一张时间卡。';
    }
    if (this.missReason.indexOf('音频启动') >= 0) {
      return '耳机声音没能启动，请确认连接后重试。';
    }
    if (this.missReason.indexOf('重复') >= 0) {
      return '每听到一个节拍，只轻敲一次。';
    }
    return '先完整听一小节，从下一个「滴」开始敲。';
  }

  private stabilityLabel(): string {
    return this.jitterMs <= 20 ? '节拍很稳' : this.jitterMs <= 38 ? '稳定度良好' : '波动较大，建议再测一次';
  }

  private q(): number { return this.sceneWidth / SCENE_DESIGN_SIZE; }
  private machineX(): number { return (1 - this.machineScale) * SCENE_DESIGN_SIZE / 2; }
  private holeWorldX(): number { return CARD_X + (HOLE_FIRST_X + this.carriageColumn * HOLE_STEP_X) * CARD_SCALE; }

  @Builder
  private pageHeader() {
    Row({ space: 8 }) {
      Text('‹').fontSize(34).fontWeight(900).fontColor(INK)
        .width(32).height(44).enabled(!this.saving).onClick(() => router.back())
      Column({ space: 2 }) {
        Text('耳机延迟测量').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic)
        Text('整张时间卡 · 120 BPM · 4/4').fontSize(10).fontWeight(800).fontColor('#625B53')
      }.alignItems(HorizontalAlign.Start)
      Blank()
      Text(this.btAudioActive ? '蓝牙' : '未连接').fontSize(10).fontWeight(900)
        .padding({ left: 7, right: 7, top: 4, bottom: 4 })
        .backgroundColor(this.btAudioActive ? TEAL : '#E2D8C8')
        .border({ width: 1, color: INK }).borderRadius(5)
    }.width('100%').padding({ left: PAGE_SIDE_PADDING, right: PAGE_SIDE_PADDING,
      top: this.topSafeInset + 8, bottom: 10 })
  }

  @Builder
  private paperContents() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('calibration/time-card-v2/blank-time-card.png'))
        .width(SCENE_DESIGN_SIZE * this.cardScale * this.q())
        .height(SCENE_DESIGN_SIZE * this.cardScale * this.q()).objectFit(ImageFit.Contain)
      ForEach(TAP_INDICES, (index: number) => {
        if (index < this.tapCount) {
          Circle().width(HOLE_DIAMETER * this.cardScale * this.q())
            .height(HOLE_DIAMETER * this.cardScale * this.q()).fill(INK)
            .position({ x: (HOLE_FIRST_X + index % 4 * HOLE_STEP_X - HOLE_DIAMETER / 2) * this.cardScale * this.q(),
              y: (HOLE_FIRST_Y + Math.floor(index / 4) * HOLE_STEP_Y - HOLE_DIAMETER / 2) * this.cardScale * this.q() })
        }
      }, (index: number) => index.toString())
      Text('本次未完成').fontSize(52 * this.cardScale * this.q()).fontWeight(900).fontColor('#B73528')
        .width(500 * this.cardScale * this.q()).height(110 * this.cardScale * this.q())
        .textAlign(TextAlign.Center).border({ width: 2, color: '#B73528' }).borderRadius(3)
        .rotate({ angle: -8 }).opacity(this.stampOpacity)
        .position({ x: 380 * this.cardScale * this.q(), y: 390 * this.cardScale * this.q() })
      if (this.phase === 'result') {
        // Use source-paper units for both line boxes and spacing. Fixed vp gaps
        // grew relative to the scaled paper and pushed jitter into the top row
        // of holes, whose upper edge is at source y=433.
        Column({ space: RESULT_TEXT_GAP * this.cardScale * this.q() }) {
          Text('测量完成').fontSize(48 * this.cardScale * this.q()).fontWeight(900).fontColor(INK)
            .height(RESULT_TITLE_HEIGHT * this.cardScale * this.q()).maxLines(1)
          Text(`${this.resultMs} ms`).fontSize(96 * this.cardScale * this.q()).fontWeight(900).fontColor('#08827B')
            .height(RESULT_VALUE_HEIGHT * this.cardScale * this.q()).maxLines(1)
          Text(`波动 ±${this.jitterMs} ms`).fontSize(32 * this.cardScale * this.q()).fontWeight(800).fontColor('#625B53')
            .height(RESULT_JITTER_HEIGHT * this.cardScale * this.q()).maxLines(1)
        }.width(RESULT_TEXT_WIDTH * this.cardScale * this.q()).alignItems(HorizontalAlign.Center)
          .position({ x: RESULT_TEXT_X * this.cardScale * this.q(), y: RESULT_TEXT_Y * this.cardScale * this.q() })
      }
    }.width(SCENE_DESIGN_SIZE * this.cardScale * this.q())
      .height(SCENE_DESIGN_SIZE * this.cardScale * this.q()).opacity(this.paperOpacity)
      .scale(this.paperScale()).rotate(this.paperRotation())
  }

  @Builder
  private clippedPaper() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.paperContents()
      }.width(SCENE_DESIGN_SIZE * this.cardScale * this.q())
        .height(SCENE_DESIGN_SIZE * this.cardScale * this.q())
        .position({ x: this.cardX * this.q(), y: (this.cardY - this.paperClipTop) * this.q() })
    }.width(this.sceneWidth)
      .height((this.paperReleased ? SCENE_DESIGN_HEIGHT : PAPER_WINDOW_BOTTOM - this.paperClipTop) * this.q())
      .position({ x: 0, y: ((this.paperReleased ? 0 : this.frameY) + this.paperClipTop) * this.q() })
      .clip(!this.paperReleased).zIndex(this.paperReleased ? 7 : 2)
  }

  @Builder
  private machineFront() {
    Image($rawfile('calibration/time-card-v2/machine-front.png'))
      .width(SCENE_DESIGN_SIZE * FRONT_SCALE * this.machineScale * this.q())
      .height(SCENE_DESIGN_SIZE * FRONT_SCALE * this.machineScale * this.q()).objectFit(ImageFit.Contain)
      .position({ x: (this.machineX() + FRONT_X * this.machineScale) * this.q(),
        y: (this.frameY + FRONT_Y * this.machineScale) * this.q() }).opacity(this.machineOpacity).zIndex(5)
  }

  @Builder
  private leverLayer() {
    Image($rawfile('calibration/time-card-v2/lever.png'))
      .width(SCENE_DESIGN_SIZE * LEVER_SCALE * this.machineScale * this.q())
      .height(SCENE_DESIGN_SIZE * LEVER_SCALE * this.machineScale * this.q()).objectFit(ImageFit.Contain)
      .rotate({ angle: this.leverAngle,
        centerX: LEVER_PIVOT_X * LEVER_SCALE * this.machineScale * this.q(),
        centerY: LEVER_PIVOT_Y * LEVER_SCALE * this.machineScale * this.q() })
      .position({ x: (this.machineX() + (LEVER_AXIS_X - LEVER_PIVOT_X * LEVER_SCALE) * this.machineScale) * this.q(),
        y: (this.frameY + (LEVER_AXIS_Y - LEVER_PIVOT_Y * LEVER_SCALE) * this.machineScale) * this.q() })
      .opacity(this.machineOpacity).zIndex(6)
  }

  @Builder
  private timeCardScene() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('calibration/time-card-v2/machine-rear.png'))
        .width(this.sceneWidth * this.machineScale).height(this.sceneWidth * this.machineScale)
        .objectFit(ImageFit.Contain)
        .position({ x: this.machineX() * this.q(), y: this.frameY * this.q() }).opacity(this.machineOpacity).zIndex(1)
      this.clippedPaper()
      // The foreground support occludes the ram while the strike path stays
      // behind it. Its open top admits the moving ram; the support stays still.
      Image($rawfile('calibration/time-card-v2/punch-guide-topdown-60.png'))
        .width(SCENE_DESIGN_SIZE * GUIDE_SCALE * this.machineScale * this.q())
        .height(SCENE_DESIGN_SIZE * GUIDE_SCALE * this.machineScale * this.q()).objectFit(ImageFit.Contain)
        .position({ x: (this.machineX() + (this.holeWorldX() - GUIDE_CENTER_X * GUIDE_SCALE) * this.machineScale) * this.q(),
          y: (this.frameY + GUIDE_Y * this.machineScale) * this.q() }).opacity(this.machineOpacity).zIndex(4)
      Image($rawfile('calibration/time-card-v2/punch-ram-topdown-60.png'))
        .width(SCENE_DESIGN_SIZE * RAM_SCALE * this.machineScale * this.q())
        .height(SCENE_DESIGN_SIZE * RAM_SCALE * this.machineScale * this.q()).objectFit(ImageFit.Contain)
        .position({ x: (this.machineX() + (this.holeWorldX() - RAM_CENTER_X * RAM_SCALE) * this.machineScale) * this.q(),
          y: (this.frameY + (RAM_Y + this.ramDrop) * this.machineScale) * this.q() }).opacity(this.machineOpacity).zIndex(3)
      this.machineFront()
      this.leverLayer()
      this.countdownOverlay()
    }.width(this.sceneWidth).height(SCENE_DESIGN_HEIGHT * this.q()).clip(false)
  }

  @Builder
  private countdownOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.countdownNumber > 0) {
        Text(`${this.countdownNumber}`).fontSize(COUNTDOWN_FONT_SIZE).fontWeight(900)
          .fontStyle(FontStyle.Italic).fontColor(WHITE)
          .textShadow({ radius: 0, offsetX: 7, offsetY: 8, color: '#A8171B1F' })
          .rotate({ angle: -4 }).scale({ x: this.countdownScale, y: this.countdownScale })
          .translate({ y: COUNTDOWN_CENTER_Y_OFFSET }).opacity(this.countdownOpacity)
      }
    }.width(this.sceneWidth).height(SCENE_DESIGN_HEIGHT * this.q())
      .position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None).zIndex(40)
  }

  @Builder
  private introInstructions() {
    Column({ space: 7 }) {
      Text('给耳机打一张时间卡').fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic)
      Text('先完整听一小节「滴嗒嗒嗒」。从下一个「滴」开始，只跟着耳机里的声音轻敲。')
        .fontSize(13).lineHeight(21).fontColor('#625B53').textAlign(TextAlign.Center)
      Text('8 小节 · 32 次敲击').fontSize(12).fontWeight(900).fontColor('#08827B')
    }.width('100%').padding({ left: 8, right: 8, top: 5, bottom: 7 })
  }

  @Builder
  private missedExplanation() {
    Column({ space: 5 }) {
      Text(this.errorTitle()).fontSize(19).fontWeight(900).width('100%')
      Text(this.tapCount > 0 ? `保留了 ${this.tapCount} 个已打孔 · 本次未完成 32 次` : '这张时间卡还没有打孔')
        .fontSize(12).fontColor('#625B53').width('100%')
      Text(this.errorAdvice()).fontSize(13).lineHeight(20).width('100%')
      Text('本次未保存，不影响已有校准。')
        .fontSize(11).lineHeight(17).fontColor('#625B53').width('100%')
    }.width('100%').padding(13).backgroundColor('#FFF0B8')
      .border({ width: 1.5, color: INK }).borderRadius(8).shadow(CARD_SHADOW)
  }

  @Builder
  private resultDetails() {
    Column({ space: 12 }) {
      Text(this.stabilityLabel()).fontSize(13).fontWeight(900)
        .fontColor(this.jitterMs > 38 ? CORAL : '#08827B')
      Row({ space: 9 }) {
        Button('校准前试听', { type: ButtonType.Normal }).layoutWeight(1).height(44)
          .fontSize(13).fontWeight(900).fontColor(INK).backgroundColor(WHITE)
          .border({ width: 1.5, color: INK }).borderRadius(7).enabled(!this.saving && this.btAudioActive)
          .onClick(() => { void this.startResultPreview(0, '校准前'); })
        Button('校准后试听', { type: ButtonType.Normal }).layoutWeight(1).height(44)
          .fontSize(13).fontWeight(900).fontColor(INK).backgroundColor(TEAL)
          .border({ width: 1.5, color: INK }).borderRadius(7).enabled(!this.saving && this.btAudioActive)
          .onClick(() => { void this.startResultPreview(this.resultMs, '校准后'); })
      }.width('100%')
      Row({ space: 9 }) {
        Circle().width(19).height(19).fill(this.previewPulse > 0 ? CORAL : '#E5D9C7').stroke(INK).strokeWidth(1.2)
        Text(this.previewLabel.length > 0 ? `${this.previewLabel}试听中` : '试听时，对比声音与亮灯是否同步')
          .fontSize(11).fontWeight(800).fontColor('#625B53').layoutWeight(1)
      }.width('100%')
      Text('本次跟拍测得的本机补偿').fontSize(11).fontColor('#625B53')
      Button(this.measurementDetailsExpanded ? '收起测量说明 ∧' : '测量说明 ∨', { type: ButtonType.Normal })
        .fontSize(12).fontWeight(800).fontColor(INK).backgroundColor(Color.Transparent)
        .height(32).onClick(() => { this.measurementDetailsExpanded = !this.measurementDetailsExpanded; })
      if (this.measurementDetailsExpanded) {
        Text('这个数值包含耳机播放链路和你的跟拍触摸差值，保存后作为本机播放补偿。保持当前耳机连接；断开、重连或切换后推荐重测。')
          .fontSize(11).lineHeight(18).fontColor('#625B53').width('100%')
          .padding(11).backgroundColor('#FFF0B8').borderRadius(7)
      }
      if (!this.btAudioActive && this.operationError.length === 0) {
        Text('耳机已断开，请重新连接并测量。').fontSize(12).lineHeight(19).fontWeight(800)
          .fontColor(CORAL).width('100%')
      }
      if (this.operationError.length > 0) {
        Text(this.operationError).fontSize(12).lineHeight(19).fontColor(CORAL).width('100%')
      }
    }.width('100%')
  }

  @Builder
  private tapPad() {
    Column({ space: 7 }) {
      Text(this.tapCount === TOTAL_TAP_COUNT ? '正在收卡' : this.phase === 'arming' ? '准备中' : '敲一下')
        .fontSize(31).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
      Text(this.tapCount === TOTAL_TAP_COUNT ? '32 次打孔已完成' :
        this.phase === 'arming' ? '耳机声音准备好后，先听一小节' : '每听到一拍，只轻敲一次')
        .fontSize(12).fontColor('#625B53')
    }.width('100%').height(TAP_PAD_HEIGHT + this.bottomSafeInset)
      .justifyContent(FlexAlign.Center).padding({ bottom: this.bottomSafeInset })
      .backgroundColor('#FFF0B8').border({ width: 2, color: INK })
      .borderRadius({ topLeft: 16, topRight: 16 }).shadow({ radius: 1, offsetY: -3, offsetX: 0, color: INK })
      .onTouch((event: TouchEvent) => { this.onTapTouch(event); })
  }

  @Builder
  private resultActions() {
    Column({ space: 10 }) {
      Button(this.saving ? '正在保存…' : this.resultActionsReady ? '保存并生效' : '请先查看结果', { type: ButtonType.Normal })
        .width('100%').height(54).fontSize(19).fontWeight(900).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7).shadow(CONTROL_SHADOW)
        .enabled(this.resultActionsReady && !this.saving && this.btAudioActive)
        .onTouch((event: TouchEvent) => { this.onResultActionTouch(event, 'save'); })
        .onClick((event: ClickEvent) => {
          if (this.consumeResultActionClick('save', event)) { void this.finishAndSave(); }
        })
      Button('重新测量', { type: ButtonType.Normal }).width('100%').height(40)
        .fontSize(14).fontWeight(900).fontColor(INK).backgroundColor(LILAC)
        .border({ width: 1.2, color: INK }).borderRadius(7)
        .enabled(this.resultActionsReady && !this.saving && this.btAudioActive)
        .onTouch((event: TouchEvent) => { this.onResultActionTouch(event, 'retry'); })
        .onClick((event: ClickEvent) => {
          if (this.consumeResultActionClick('retry', event)) { this.retryMeasurement(); }
        })
    }.width('100%').padding({ left: PAGE_SIDE_PADDING, right: PAGE_SIDE_PADDING,
      top: CONTENT_ACTIONS_GAP, bottom: 18 + this.bottomSafeInset })
  }

  @Builder
  private startOrRetryActions() {
    Column({ space: 10 }) {
      if (this.operationError.length > 0) {
        Text(this.operationError).fontSize(12).lineHeight(19).fontColor(CORAL).width('100%')
      }
      if (this.phase === 'intro') {
        Button('开始打卡', { type: ButtonType.Normal }).width('100%').height(54)
          .fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7).shadow(CONTROL_SHADOW)
          .enabled(this.btAudioActive).onClick(() => { void this.startMeasurement(); })
        if (!this.btAudioActive && this.operationError.length === 0) {
          Text('请先连接蓝牙耳机').fontSize(11).fontColor('#625B53')
        }
      } else {
        Button(this.phase === 'changing' ? '正在换入空白卡…' : '重新听一小节，再打卡', { type: ButtonType.Normal })
          .width('100%').height(54).fontSize(18).fontWeight(900).fontColor(INK)
          .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7).shadow(CONTROL_SHADOW)
          .enabled(this.retryReady && !this.touchHeld && this.btAudioActive)
          .onClick(() => { this.retryMeasurement(); })
        if (!this.btAudioActive && this.operationError.length === 0) {
          Text('请先重新连接耳机').fontSize(11).fontColor('#625B53')
        }
      }
    }.width('100%').padding({ left: PAGE_SIDE_PADDING, right: PAGE_SIDE_PADDING,
      top: CONTENT_ACTIONS_GAP, bottom: 18 + this.bottomSafeInset })
  }

  build() {
    Column() {
      this.pageHeader()
      Scroll(this.pageScroller) {
        Column() {
          Column({ space: 8 }) {
            if (this.phase === 'intro') {
              this.introInstructions()
            } else if (this.phaseIsActive()) {
              Text(this.activeInstruction()).fontSize(12).fontWeight(800).fontColor('#625B53')
                .width('100%').textAlign(TextAlign.Center)
              Text(`${this.tapCount} / ${TOTAL_TAP_COUNT}`).fontSize(18).fontWeight(900).fontColor('#08827B')
            } else if (this.phase === 'changing') {
              Text('先换一张空白卡，再重新听节拍').fontSize(12).fontColor('#625B53')
            } else if (this.phase === 'missed') {
              Text('打卡已暂停').fontSize(12).fontColor('#625B53')
            }
            this.timeCardScene()
            if (this.phase === 'missed') {
              this.missedExplanation()
            } else if (this.phase === 'result') {
              this.resultDetails()
            }
          }.width('100%').padding({ left: PAGE_SIDE_PADDING, right: PAGE_SIDE_PADDING,
            bottom: this.phase === 'result' || this.phase === 'missed' || this.phase === 'changing' ? 0 : 10 })
          if (this.phase === 'result') {
            this.resultActions()
          } else if (this.phase === 'missed' || this.phase === 'changing') {
            this.startOrRetryActions()
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      if (this.phaseIsActive()) {
        this.tapPad()
      } else if (this.phase === 'intro') {
        this.startOrRetryActions()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_old: Area, area: Area) => {
        const width = typeof area.width === 'number' ? area.width : parseFloat(area.width.toString());
        if (width > PAGE_SIDE_PADDING * 2) {
          this.sceneWidth = Math.min(SCENE_MAX_WIDTH, width - PAGE_SIDE_PADDING * 2);
        }
      })
      .onTouch((event: TouchEvent) => { this.onPageTouch(event); })
  }
}
