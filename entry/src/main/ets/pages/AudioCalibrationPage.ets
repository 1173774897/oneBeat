import { router, promptAction } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { MonotonicClock } from '../common/MonotonicClock';
import { saveCalibrationMs } from '../store/AudioLatencyPersistence';
import {
  BLUE,
  CARD_SHADOW,
  CONTROL_SHADOW,
  CORAL,
  INK,
  LILAC,
  PAPER,
  TEAL,
  WHITE
} from '../components/ComicKit';

type CalibrationPhase = 'intro' | 'arming' | 'listening' | 'measuring' | 'missed' | 'result';

const CALIBRATION_BPM: number = 120;
const BEAT_INTERVAL_MS: number = 60000 / CALIBRATION_BPM;
const COUNT_IN_BEATS: number = 4;
const MEASURE_BAR_COUNT: number = 8;
const BEATS_PER_BAR: number = 4;
const TOTAL_TAP_COUNT: number = MEASURE_BAR_COUNT * BEATS_PER_BAR;
const AUDIO_START_LEAD_MS: number = 1300;
const FIRST_TAP_EARLY_MS: number = 80;
// Bluetooth output can arrive more than one beat late. A wider window prevents
// the measured delay from being folded into the 500 ms click period.
const MAX_EXPECTED_OUTPUT_DELAY_MS: number = 2000;
const FIRST_TAP_LATE_MS: number = MAX_EXPECTED_OUTPUT_DELAY_MS;
const TAP_INTERVAL_TOLERANCE_MS: number = 150;
const MIN_MEASURED_OFFSET_MS: number = -120;
const MAX_MEASURED_OFFSET_MS: number = MAX_EXPECTED_OUTPUT_DELAY_MS;
const PUNCH_MACHINE_HEIGHT: number = 274;
const PUNCH_MACHINE_IMAGE_SIZE: number = 278;
const PUNCH_TICKET_WIDTH: number = 210;
const PUNCH_TICKET_HEIGHT: number = 105;
const PUNCH_TICKET_TOP: number = 84;
const COLLECTED_TICKET_SLIDE_X: number = 106;
const MISS_BURST_SIZE: number = 218;
const RESULT_RECEIPT_WIDTH: number = 286;
const RESULT_RECEIPT_HEIGHT: number = 429;
const RESULT_CONNECTION_NOTICE_HEIGHT: number = 66;
const TAP_PAD_HEIGHT: number = 184;
const PREVIEW_BEAT_COUNT: number = 8;
const BAR_INDICES: number[] = [0, 1, 2, 3, 4, 5, 6, 7];
const BEAT_INDICES: number[] = [0, 1, 2, 3];
const TAP_INDICES: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
];

@Entry
@Component
struct AudioCalibrationPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('btAudioActive') @Watch('onBluetoothAudioRouteChanged') btAudioActive: boolean = false;
  @State phase: CalibrationPhase = 'intro';
  @State tapCount: number = 0;
  @State resultMs: number = 0;
  @State jitterMs: number = 0;
  @State missReason: string = '';
  @State punchImpact: number = 0;
  @State collectedTicketVisible: boolean = false;
  @State collectedTicketX: number = 0;
  @State collectedTicketOpacity: number = 0;
  @State previewPulse: number = 0;
  @State previewLabel: string = '';
  @State saving: boolean = false;
  private audioStartAtMs: number = 0;
  private measurementStartAtMs: number = 0;
  private lastTapAtMs: number = 0;
  private tapOffsetsMs: number[] = [];
  private missTimer: number = -1;
  private punchTimer: number = -1;
  private ticketTimer: number = -1;
  private ticketResetTimer: number = -1;
  private finishTimer: number = -1;
  private previewTimer: number = -1;
  private previewStopTimer: number = -1;
  private runToken: number = 0;
  private pageActive: boolean = false;

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
    router.back();
    return true;
  }

  private clearTimers(): void {
    if (this.missTimer >= 0) {
      clearTimeout(this.missTimer);
      this.missTimer = -1;
    }
    if (this.punchTimer >= 0) {
      clearTimeout(this.punchTimer);
      this.punchTimer = -1;
    }
    if (this.ticketTimer >= 0) {
      clearTimeout(this.ticketTimer);
      this.ticketTimer = -1;
    }
    if (this.ticketResetTimer >= 0) {
      clearTimeout(this.ticketResetTimer);
      this.ticketResetTimer = -1;
    }
    if (this.finishTimer >= 0) {
      clearTimeout(this.finishTimer);
      this.finishTimer = -1;
    }
    if (this.previewTimer >= 0) {
      clearInterval(this.previewTimer);
      this.previewTimer = -1;
    }
    if (this.previewStopTimer >= 0) {
      clearTimeout(this.previewStopTimer);
      this.previewStopTimer = -1;
    }
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
    if (this.phaseIsActive()) {
      this.failMeasurement('蓝牙耳机已断开，请重新连接后再测');
      return;
    }
    this.clearTimers();
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
    this.previewPulse = 0;
    this.previewLabel = '';
  }

  private async startMeasurement(): Promise<void> {
    if (!this.btAudioActive) {
      promptAction.showToast({ message: '当前没有检测到蓝牙耳机输出，请返回大厅重新确认' });
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      promptAction.showToast({ message: '当前没有可用会话，请从队伍大厅进入' });
      return;
    }
    const token = ++this.runToken;
    this.clearTimers();
    this.publishCalibrationActivity(true);
    this.phase = 'arming';
    this.tapCount = 0;
    this.resultMs = 0;
    this.jitterMs = 0;
    this.missReason = '';
    this.punchImpact = 0;
    this.collectedTicketVisible = false;
    this.collectedTicketX = 0;
    this.collectedTicketOpacity = 0;
    this.previewPulse = 0;
    this.previewLabel = '';
    this.tapOffsetsMs = [];
    this.lastTapAtMs = 0;
    this.audioStartAtMs = MonotonicClock.nowMs() + AUDIO_START_LEAD_MS;
    this.measurementStartAtMs = this.audioStartAtMs + COUNT_IN_BEATS * BEAT_INTERVAL_MS;
    try {
      await session.scheduleLatencyTapMeasurement(this.audioStartAtMs, COUNT_IN_BEATS);
      if (!this.pageActive || token !== this.runToken) {
        return;
      }
      this.phase = 'listening';
      this.armMissTimer(this.measurementStartAtMs + FIRST_TAP_LATE_MS, token);
    } catch (err) {
      if (token !== this.runToken) {
        return;
      }
      this.failMeasurement(`音频启动失败：${(err as Error).message}`);
    }
  }

  private armMissTimer(deadlineMs: number, token: number): void {
    if (this.missTimer >= 0) {
      clearTimeout(this.missTimer);
    }
    const delay = Math.max(0, deadlineMs - MonotonicClock.nowMs());
    this.missTimer = setTimeout(() => {
      if (token === this.runToken && this.phaseIsActive() && this.tapCount < TOTAL_TAP_COUNT) {
        this.failMeasurement(`第 ${this.tapCount + 1} 拍没有接到敲击`);
      }
    }, delay);
  }

  private phaseIsActive(): boolean {
    return this.phase === 'arming' || this.phase === 'listening' || this.phase === 'measuring';
  }

  /** ArkUI touch timestamps use the boot-time clock in nanoseconds. */
  private touchMonoMs(event: TouchEvent): number {
    const eventMs = event.timestamp / 1000000;
    const now = MonotonicClock.nowMs();
    // Keep a callback-time fallback for older runtimes that expose a different
    // timestamp epoch; it is less precise but never corrupts the whole run.
    return Math.abs(eventMs - now) <= 2000 ? eventMs : now;
  }

  private onTapTouch(event: TouchEvent): void {
    if (event.type !== TouchType.Down || !this.phaseIsActive() || this.tapCount >= TOTAL_TAP_COUNT) {
      return;
    }
    const tapAtMs = this.touchMonoMs(event);
    if (tapAtMs < this.measurementStartAtMs - FIRST_TAP_EARLY_MS) {
      return;
    }
    if (this.phase === 'arming') {
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

    this.phase = 'measuring';
    this.tapOffsetsMs.push(offsetMs);
    this.lastTapAtMs = tapAtMs;
    this.tapCount++;
    const completedBar = this.tapCount % BEATS_PER_BAR === 0;
    this.playPunchFeedback(completedBar);

    if (this.tapCount >= TOTAL_TAP_COUNT) {
      if (this.missTimer >= 0) {
        clearTimeout(this.missTimer);
        this.missTimer = -1;
      }
      AppSession.get()?.pauseLatencyCalibration();
      const token = this.runToken;
      this.finishTimer = setTimeout(() => {
        if (token === this.runToken && this.pageActive) {
          this.finishMeasurement();
        }
      }, 390);
      return;
    }
    const token = this.runToken;
    this.armMissTimer(tapAtMs + BEAT_INTERVAL_MS + TAP_INTERVAL_TOLERANCE_MS, token);
  }

  private playPunchFeedback(completedBar: boolean): void {
    // This animation is touch-triggered only. It must never predict an audio
    // beat, otherwise the visual cue would contaminate the headphone result.
    this.punchImpact = 1;
    if (this.punchTimer >= 0) {
      clearTimeout(this.punchTimer);
    }
    this.punchTimer = setTimeout(() => {
      this.punchImpact = 0;
      this.punchTimer = -1;
    }, 110);
    if (completedBar) {
      this.playTicketCollection();
    }
  }

  private playTicketCollection(): void {
    this.collectedTicketVisible = true;
    this.collectedTicketX = 0;
    this.collectedTicketOpacity = 1;
    this.ticketTimer = setTimeout(() => {
      animateTo({ duration: 270, curve: Curve.EaseInOut }, () => {
        this.collectedTicketX = COLLECTED_TICKET_SLIDE_X;
        this.collectedTicketOpacity = 0;
      });
      this.ticketTimer = -1;
    }, 70);
    this.ticketResetTimer = setTimeout(() => {
      this.collectedTicketVisible = false;
      this.collectedTicketX = 0;
      this.ticketResetTimer = -1;
    }, 360);
  }

  private finishMeasurement(): void {
    this.finishTimer = -1;
    let sum = 0;
    for (let i = 0; i < this.tapOffsetsMs.length; i++) {
      sum += this.tapOffsetsMs[i];
    }
    const mean = sum / Math.max(1, this.tapOffsetsMs.length);
    let variance = 0;
    for (let i = 0; i < this.tapOffsetsMs.length; i++) {
      const deviation = this.tapOffsetsMs[i] - mean;
      variance += deviation * deviation;
    }
    this.resultMs = Math.max(0, Math.round(mean));
    this.jitterMs = Math.round(Math.sqrt(variance / Math.max(1, this.tapOffsetsMs.length)));
    this.phase = 'result';
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
  }

  private failMeasurement(reason: string): void {
    this.clearTimers();
    this.missReason = reason;
    this.phase = 'missed';
    this.publishCalibrationActivity(false);
    AppSession.get()?.pauseLatencyCalibration();
  }

  private async finishAndSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (!this.btAudioActive) {
      promptAction.showToast({ message: '蓝牙耳机已断开，本次结果没有保存' });
      return;
    }
    this.saving = true;
    try {
      await saveCalibrationMs(this.resultMs);
      const session = AppSession.get();
      session?.metronome.refreshOutputCalibration();
      session?.keepLatencyCalibrationRendererAlive();
      session?.markLatencyCalibrationRoute(true);
      promptAction.showToast({
        message: `已保存 ${this.resultMs} ms，请保持耳机连接；蓝牙重连后推荐重测`
      });
      router.back();
    } catch (err) {
      promptAction.showToast({ message: `保存失败：${(err as Error).message}` });
      this.saving = false;
    }
  }

  private async startResultPreview(compensationMs: number, label: string): Promise<void> {
    if (!this.btAudioActive) {
      promptAction.showToast({ message: '当前没有检测到蓝牙耳机输出' });
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      return;
    }
    if (this.previewTimer >= 0) {
      clearInterval(this.previewTimer);
    }
    if (this.previewStopTimer >= 0) {
      clearTimeout(this.previewStopTimer);
    }
    session.pauseLatencyCalibration();
    this.previewPulse = 0;
    this.previewLabel = label;
    const visualStartAtMs = MonotonicClock.nowMs() + AUDIO_START_LEAD_MS;
    this.previewTimer = setInterval(() => {
      const elapsed = MonotonicClock.nowMs() - visualStartAtMs;
      if (elapsed < 0) {
        this.previewPulse = 0;
        return;
      }
      const phase = elapsed % BEAT_INTERVAL_MS;
      this.previewPulse = phase < 110 ? 1 : 0;
    }, 16);
    this.previewStopTimer = setTimeout(() => {
      if (this.previewTimer >= 0) {
        clearInterval(this.previewTimer);
        this.previewTimer = -1;
      }
      this.previewStopTimer = -1;
      this.previewPulse = 0;
      session.pauseLatencyCalibration();
    }, AUDIO_START_LEAD_MS + PREVIEW_BEAT_COUNT * BEAT_INTERVAL_MS);
    try {
      await session.scheduleLatencyPreview(visualStartAtMs, compensationMs);
    } catch (err) {
      this.previewLabel = '';
      promptAction.showToast({ message: `试听启动失败：${(err as Error).message}` });
    }
  }

  private currentBarNumber(): number {
    return Math.min(MEASURE_BAR_COUNT, Math.floor(this.tapCount / BEATS_PER_BAR) + 1);
  }

  private currentBeatCount(): number {
    return this.tapCount % BEATS_PER_BAR;
  }

  private barState(barIndex: number): number {
    const firstTap = barIndex * BEATS_PER_BAR;
    if (this.tapCount >= firstTap + BEATS_PER_BAR) {
      return 2;
    }
    if (this.tapCount >= firstTap) {
      return 1;
    }
    return 0;
  }

  private barPunchFilled(barIndex: number, beatIndex: number): boolean {
    return this.tapCount > barIndex * BEATS_PER_BAR + beatIndex;
  }

  private currentTicketPunchFilled(beatIndex: number): boolean {
    return beatIndex < this.currentBeatCount();
  }

  private stabilityLabel(): string {
    if (this.jitterMs <= 20) {
      return '节拍很稳';
    }
    if (this.jitterMs <= 38) {
      return '稳定度良好';
    }
    return '波动较大，建议再测一次';
  }

  private activeInstruction(): string {
    if (this.phase === 'arming') {
      return '正在唤醒耳机音频通道…';
    }
    if (this.phase === 'listening') {
      return '先听完整的一小节，从第二个「滴」开始敲';
    }
    return `只听耳机继续敲 · ${this.tapCount} / ${TOTAL_TAP_COUNT}`;
  }

  @Builder
  private pageHeader() {
    Row({ space: 8 }) {
      Row() {
        Text('‹').fontSize(34).fontWeight(900).fontColor(INK)
      }
      .width(32).height(44)
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .onClick(() => router.back())

      Column({ space: 1 }) {
        Text('耳机延迟测量').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic)
        Row({ space: 6 }) {
          Text('节拍打卡机 · 120 BPM · 4/4').fontSize(10).fontWeight(800).fontColor('#5C554D')
          Row({ space: 4 }) {
            Circle().width(6).height(6).fill(this.btAudioActive ? TEAL : '#A59D92')
            Text(this.btAudioActive ? '蓝牙' : '外放').fontSize(9).fontWeight(900).fontColor(INK)
          }
        }.alignItems(VerticalAlign.Center)
      }.alignItems(HorizontalAlign.Start)
      Blank()
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 8 + this.topSafeInset, bottom: 8 })
  }

  @Builder
  private progressTicket(barIndex: number) {
    Column({ space: 5 }) {
      Row({ space: 3 }) {
        ForEach(BEAT_INDICES, (beatIndex: number) => {
          Circle()
            .width(9).height(9)
            .fill(this.barPunchFilled(barIndex, beatIndex) ? INK : '#D9D1C4')
        })
      }
      Text(`${barIndex + 1}`).fontSize(10).fontWeight(900).fontColor(INK)
    }
    .height(43)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.barState(barIndex) === 2 ? TEAL :
      this.barState(barIndex) === 1 ? '#FFF0B8' : WHITE)
    .border({ width: this.barState(barIndex) === 1 ? 2 : 1, color: INK })
    .borderRadius(5)
  }

  @Builder
  private progressBoard() {
    Column({ space: 7 }) {
      Row() {
        Text('8 张节拍卡').fontSize(13).fontWeight(900).fontColor(INK)
        Blank()
        Text(`${this.tapCount} / ${TOTAL_TAP_COUNT}`).fontSize(13).fontWeight(900).fontColor(CORAL)
      }.width('100%')
      Grid() {
        ForEach(BAR_INDICES, (barIndex: number) => {
          GridItem() {
            this.progressTicket(barIndex)
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(7)
      .rowsGap(7)
      .height(93)
    }
    .width('100%')
  }

  @Builder
  private tapDotBoard() {
    Grid() {
      ForEach(TAP_INDICES, (tapIndex: number) => {
        GridItem() {
          Circle()
            .width(8).height(8)
            .fill(tapIndex < this.tapCount ? INK : '#D6CCBC')
            .scale({ x: tapIndex === this.tapCount - 1 ? 1.35 : 1,
              y: tapIndex === this.tapCount - 1 ? 1.35 : 1 })
        }
      })
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
    .columnsGap(4)
    .rowsGap(7)
    .width('92%')
    .height(25)
  }

  @Builder
  private punchMachine() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('calibration/punch_machine.png'))
        .width(PUNCH_MACHINE_IMAGE_SIZE).height(PUNCH_MACHINE_IMAGE_SIZE)
        .objectFit(ImageFit.Contain)
        .position({ x: '50%', y: 0 })
        .translate({ x: -PUNCH_MACHINE_IMAGE_SIZE / 2 })

      Stack({ alignContent: Alignment.Center }) {
        Image($rawfile('calibration/time_card.png'))
          .width('100%').height('100%').objectFit(ImageFit.Contain)
        Column({ space: 7 }) {
          Row() {
            Text(`第 ${this.currentBarNumber()} / ${MEASURE_BAR_COUNT} 小节`)
              .fontSize(12).fontWeight(900).fontColor(INK)
            Blank()
            Text(`${this.currentBeatCount()} / 4`).fontSize(10).fontWeight(900).fontColor(CORAL)
          }.width('100%')
          Row({ space: 17 }) {
            ForEach(BEAT_INDICES, (beatIndex: number) => {
              Stack() {
                Circle()
                  .width(25).height(25)
                  .fill(this.currentTicketPunchFilled(beatIndex) ? INK : '#E8E0D4')
                  .stroke(INK).strokeWidth(1.2)
                if (this.currentTicketPunchFilled(beatIndex)) {
                  Text('✓').fontSize(12).fontWeight(900).fontColor(WHITE)
                }
              }.width(27).height(27)
            })
          }.width('100%').justifyContent(FlexAlign.Center)
        }
        .width('82%').padding({ top: 13 })
      }
      .width(PUNCH_TICKET_WIDTH)
      .height(PUNCH_TICKET_HEIGHT)
      .position({ x: '50%', y: PUNCH_TICKET_TOP })
      .translate({ x: -PUNCH_TICKET_WIDTH / 2, y: this.punchImpact * 4 })

      if (this.collectedTicketVisible) {
        Stack({ alignContent: Alignment.Center }) {
          Image($rawfile('calibration/time_card.png'))
            .width('100%').height('100%').objectFit(ImageFit.Contain)
          Row({ space: 12 }) {
            ForEach(BEAT_INDICES, (_beatIndex: number) => {
              Circle().width(18).height(18).fill(INK)
            })
          }.padding({ top: 17 })
        }
        .width(PUNCH_TICKET_WIDTH)
        .height(PUNCH_TICKET_HEIGHT)
        .position({ x: '50%', y: PUNCH_TICKET_TOP })
        .translate({ x: -PUNCH_TICKET_WIDTH / 2 + this.collectedTicketX })
        .opacity(this.collectedTicketOpacity)
        .rotate({ angle: this.collectedTicketX * 0.035 })
      }

      Text('咔!')
        .fontSize(31).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(WHITE)
        .textShadow({ radius: 0, offsetX: 3, offsetY: 3, color: INK })
        .opacity(this.punchImpact)
        .scale({ x: 0.8 + this.punchImpact * 0.35, y: 0.8 + this.punchImpact * 0.35 })
        .position({ x: '73%', y: 52 })
    }
    .width('100%')
    .height(PUNCH_MACHINE_HEIGHT)
  }

  @Builder
  private tapPad() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 8 }) {
        Text(this.phase === 'arming' ? '准备中' : '敲这里')
          .fontSize(31).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Text(this.activeInstruction())
          .fontSize(12).fontWeight(800).fontColor('#5C554D').textAlign(TextAlign.Center)
        this.tapDotBoard()
      }
    }
    .width('100%')
    .height(TAP_PAD_HEIGHT)
    .backgroundColor(this.punchImpact > 0 ? '#FFD95E' : '#FFF0B8')
    .border({ width: 2, color: INK })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .shadow({ radius: 1, offsetX: 0, offsetY: -4, color: INK })
    .enabled(this.phase !== 'arming')
    .opacity(this.phase === 'arming' ? 0.65 : 1)
    .onTouch((event: TouchEvent): void => this.onTapTouch(event))
  }

  @Builder
  private introContent() {
    Column({ space: 14 }) {
      if (!this.btAudioActive) {
        Text('当前未检测到蓝牙输出，也可以用外放体验测量流程')
          .fontSize(12).fontWeight(800).fontColor(INK).width('100%')
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .backgroundColor('#FFF0B8').border({ width: 1.2, color: INK }).borderRadius(6)
      }
      Column({ space: 9 }) {
        Text('听节拍，给耳机打张时间卡').fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic)
          .width('100%')
        Text('先完整听一小节“滴嗒嗒嗒”。从下一个“滴”开始，只跟着耳机里的声音敲屏幕。')
          .fontSize(14).lineHeight(22).fontColor('#4F4942').width('100%')
        Row({ space: 8 }) {
          Text('120').fontSize(22).fontWeight(900).fontColor(CORAL)
          Text('BPM').fontSize(11).fontWeight(900)
          Divider().vertical(true).height(25).color('#CFC5B7')
          Text('8').fontSize(22).fontWeight(900).fontColor(TEAL)
          Text('小节').fontSize(11).fontWeight(900)
          Divider().vertical(true).height(25).color('#CFC5B7')
          Text('32').fontSize(22).fontWeight(900).fontColor(BLUE)
          Text('次敲击').fontSize(11).fontWeight(900)
        }.width('100%').justifyContent(FlexAlign.Center)
      }
      .width('100%').padding(15).backgroundColor(WHITE)
      .border({ width: 1.5, color: INK }).borderRadius(9).shadow(CARD_SHADOW)

      this.punchMachine()

      Column({ space: 7 }) {
        Text('测量时请注意').fontSize(15).fontWeight(900).width('100%')
        Text('• 不看其他节拍画面，只听耳机').fontSize(12).fontColor('#5C554D').lineHeight(19)
        Text('• 用同一根手指，在任意位置轻敲').fontSize(12).fontColor('#5C554D').lineHeight(19)
        Text('• 中途漏拍或多敲会立即停下，可以重新开始')
          .fontSize(12).fontColor('#5C554D').lineHeight(19)
      }
      .width('100%').alignItems(HorizontalAlign.Start)

      Button('开始打卡', { type: ButtonType.Normal })
        .width('100%').height(56).fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7)
        .shadow(CONTROL_SHADOW).onClick(() => { void this.startMeasurement(); })
    }.width('100%')
  }

  @Builder
  private missedContent() {
    Column({ space: 15 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($rawfile('calibration/miss_burst.png'))
          .width(MISS_BURST_SIZE).height(MISS_BURST_SIZE).objectFit(ImageFit.Contain)
        Text('刚才断拍了\n再来一次')
          .fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          .textAlign(TextAlign.Center)
          .translate({ y: 70 })
      }
      .width('100%').height(238).backgroundColor('#FFF0B8')
      .border({ width: 2, color: INK }).borderRadius(10).shadow(CARD_SHADOW)

      Column({ space: 7 }) {
        Text(this.missReason).fontSize(16).fontWeight(900).fontColor(INK)
        Text(`已经完成 ${this.tapCount} / ${TOTAL_TAP_COUNT} 次敲击`)
          .fontSize(13).fontColor('#5C554D')
        Text('这次记录不会参与计算。准备好后重新听一小节即可。')
          .fontSize(12).lineHeight(19).fontColor('#5C554D').textAlign(TextAlign.Center)
      }
      .width('100%').padding(15).backgroundColor(WHITE)
      .border({ width: 1.5, color: INK }).borderRadius(9)

      Button('重新开始', { type: ButtonType.Normal })
        .width('100%').height(56).fontSize(20).fontWeight(900).fontColor(INK)
        .backgroundColor(TEAL).border({ width: 1.5, color: INK }).borderRadius(7)
        .shadow(CONTROL_SHADOW).onClick(() => { void this.startMeasurement(); })
    }.width('100%')
  }

  @Builder
  private resultContent() {
    Column({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($rawfile('calibration/result_receipt.png'))
          .width(RESULT_RECEIPT_WIDTH).height(RESULT_RECEIPT_HEIGHT).objectFit(ImageFit.Contain)
        Column({ space: 9 }) {
          Text('节拍打卡回执').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(CORAL)
          Text('NO. 08 / 08').fontSize(10).fontWeight(900).fontColor('#5C554D')
          Divider().width(196).color(INK).strokeWidth(1)
          Text(`${this.resultMs} ms`).fontSize(43).fontWeight(900).fontColor(INK)
          Text('建议耳机补偿').fontSize(12).fontWeight(900).fontColor('#5C554D')
          Row({ space: 8 }) {
            Text('32 / 32 有效').fontSize(11).fontWeight(900)
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(TEAL).border({ width: 1, color: INK }).borderRadius(13)
            Text(`波动 ±${this.jitterMs} ms`).fontSize(11).fontWeight(900)
              .padding({ left: 8, right: 8, top: 5, bottom: 5 })
              .backgroundColor(BLUE).border({ width: 1, color: INK }).borderRadius(13)
          }
          Text(this.stabilityLabel()).fontSize(12).fontWeight(900)
            .fontColor(this.jitterMs > 38 ? CORAL : TEAL)
          Divider().width(196).color(INK).strokeWidth(1)
          Row({ space: 10 }) {
            Circle().width(22).height(22).fill(this.previewPulse > 0 ? CORAL : '#E5D9C7')
              .border({ width: 1.5, color: INK })
              .scale({ x: 1 + this.previewPulse * 0.28, y: 1 + this.previewPulse * 0.28 })
            Text(this.previewLabel.length > 0 ? `${this.previewLabel}试听中` : '试听验票灯')
              .fontSize(12).fontWeight(900).fontColor(INK)
          }
        }
        .width(230)
        .padding({ top: 22 })
      }
      .width('100%').height(RESULT_RECEIPT_HEIGHT)

      Row({ space: 10 }) {
        Button('校准前试听', { type: ButtonType.Normal })
          .layoutWeight(1).height(44).fontSize(14).fontWeight(900).fontColor(INK)
          .backgroundColor(WHITE).border({ width: 1.5, color: INK }).borderRadius(7)
          .onClick(() => { void this.startResultPreview(0, '校准前'); })
        Button('校准后试听', { type: ButtonType.Normal })
          .layoutWeight(1).height(44).fontSize(14).fontWeight(900).fontColor(INK)
          .backgroundColor(TEAL).border({ width: 1.5, color: INK }).borderRadius(7)
          .onClick(() => { void this.startResultPreview(this.resultMs, '校准后'); })
      }.width('100%')

      Text('试听时看收据上的验票灯：声音越贴近亮灯瞬间，补偿越合适。')
        .fontSize(11).lineHeight(17).fontColor('#5C554D').textAlign(TextAlign.Center)

      this.progressBoard()

      Text('这个数值包含当前耳机播放链路和你的跟拍触摸差值，保存后会作为本机播放补偿。')
        .fontSize(12).lineHeight(19).fontColor('#5C554D').textAlign(TextAlign.Center)

      Row({ space: 10 }) {
        Stack() {
          Circle().width(28).height(28).fill(this.btAudioActive ? '#FFF0B8' : '#FFD7CF')
            .stroke(INK).strokeWidth(1.2)
          Text('!').fontSize(17).fontWeight(900).fontColor(CORAL)
        }.width(30).height(30)
        Column({ space: 2 }) {
          Text(this.btAudioActive ? '保存后请保持当前耳机连接' : '当前没有连接蓝牙耳机')
            .fontSize(13).fontWeight(900).fontColor(INK).width('100%')
          Text(this.btAudioActive
            ? '耳机断开、重新连接或切换后，需要重新测量。'
            : '连接蓝牙耳机后，请重新完成一次延迟测量。')
            .fontSize(10).fontWeight(700).fontColor('#625B53').width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%').height(RESULT_CONNECTION_NOTICE_HEIGHT)
      .padding({ left: 11, right: 11 })
      .backgroundColor(this.btAudioActive ? '#FFF6D8' : '#FFE4DE')
      .border({ width: 1.5, color: INK }).borderRadius(7)

      Button('保存并生效', { type: ButtonType.Normal })
        .width('100%').height(56).fontSize(19).fontWeight(900).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7)
        .shadow(CONTROL_SHADOW).enabled(!this.saving).opacity(this.saving ? 0.55 : 1)
        .onClick(() => { void this.finishAndSave(); })
      Button('重新测量', { type: ButtonType.Normal })
        .width('100%').height(46).fontSize(15).fontWeight(900).fontColor(INK)
        .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(7)
        .onClick(() => { void this.startMeasurement(); })
    }.width('100%')
  }

  build() {
    Column() {
      this.pageHeader()
      if (this.phaseIsActive()) {
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 8 }) {
              Text(this.phase === 'measuring' ? '●' : '◌')
                .fontSize(12).fontColor(this.phase === 'measuring' ? TEAL : CORAL)
              Text(this.activeInstruction()).fontSize(13).fontWeight(800).fontColor('#5C554D')
                .layoutWeight(1)
            }.width('100%')
            this.progressBoard()
            this.punchMachine()
          }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 14 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        this.tapPad()
      } else {
        Scroll() {
          if (this.phase === 'intro') {
            this.introContent()
          } else if (this.phase === 'missed') {
            this.missedContent()
          } else {
            this.resultContent()
          }
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 18, right: 18, bottom: 28 + this.bottomSafeInset })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
