import { RecordingCoordinator } from '../recording/RecordingCoordinator';
import { CORAL, PAPER } from './ComicKit';

export const WAVEFORM_TOP: string = '27%';
export const WAVEFORM_HEIGHT: number = 70;
export const WAVEFORM_SIDE_INSET: number = 20;
export const WAVEFORM_DOCK_TOP_GAP: number = 0;
export const WAVEFORM_BRAND_WIDTH: number = 64;
export const WAVEFORM_BRAND_HEIGHT: number = 46;
const WAVEFORM_BRAND_GAP: number = 10;
const WAVEFORM_MOVE_MS: number = 220;
export const RECORD_STOP_BOTTOM: number = 24;
export const RECORD_PILL_HEIGHT: number = 46;
const WAVEFORM_BAR_COUNT: number = 42;
const WAVEFORM_POLL_MS: number = 50;
export const WAVEFORM_MAX_DISPLAY_GAIN: number = 32;
const WAVEFORM_DISPLAY_TARGET_PEAK: number = 0.5;
const WAVEFORM_DISPLAY_NOISE_FLOOR: number = 0.0002;

/** This is ordinary scene UI so system screen capture keeps the wave and stop button in the finished video. */
@Component
export struct RecordingOverlay {
  @Prop elapsedMs: number = 0;
  @Prop stopping: boolean = false;
  @Prop chromeVisible: boolean = true;
  @Prop topSafeInset: number = 0;
  @Prop bottomSafeInset: number = 0;
  @State micMuted: boolean = false;
  @State private movementReady: boolean = false;
  onStop: () => void = () => {};
  private amplitudeTimer: number = -1;
  private samples: number[] = Array.from({ length: WAVEFORM_BAR_COUNT }, (_value: number) => 0);
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasReady: boolean = false;
  private canvasWidth: number = 280;
  private canvasHeight: number = 33;
  private displayGain: number = WAVEFORM_MAX_DISPLAY_GAIN;

  aboutToAppear(): void {
    // Only this small component observes microphone energy. The beat renderer and
    // transport clock never depend on microphone sampling or waveform repainting.
    this.amplitudeTimer = setInterval(() => {
      const snapshot = RecordingCoordinator.getSnapshot();
      const amplitude = snapshot.micMuted ? 0 : Math.max(0, Math.min(1, snapshot.amplitude));
      this.samples = this.samples.slice(1).concat(amplitude);
      if (this.micMuted !== snapshot.micMuted) { this.micMuted = snapshot.micMuted; }
      this.drawWaveform();
    }, WAVEFORM_POLL_MS);
  }

  private drawWaveform(): void {
    if (!this.canvasReady) { return; }
    const width = this.canvasWidth;
    const middle = this.canvasHeight / 2;
    this.canvas.clearRect(0, 0, width, this.canvasHeight);
    const stride = width / WAVEFORM_BAR_COUNT;
    // Quiet AEC input needs visual sensitivity too. This gain never leaves the
    // overlay: PCM, saved MIC gain, and all transport/audio clocks stay raw.
    let recentPeak: number = WAVEFORM_DISPLAY_NOISE_FLOOR;
    for (const sample of this.samples) { recentPeak = Math.max(recentPeak, sample); }
    const targetGain = Math.max(1, Math.min(WAVEFORM_MAX_DISPLAY_GAIN,
      WAVEFORM_DISPLAY_TARGET_PEAK / recentPeak));
    // Respond immediately to a loud input, and recover sensitivity gradually
    // after it leaves the visible history, avoiding repeated full-height bars.
    this.displayGain = targetGain < this.displayGain ? targetGain :
      this.displayGain + (targetGain - this.displayGain) * 0.2;
    this.canvas.lineWidth = Math.max(2, stride * 0.48);
    this.canvas.lineCap = 'round';
    for (let index = 0; index < WAVEFORM_BAR_COUNT; index++) {
      // Compress only the measured peak's display range; silence stays flat.
      // Canvas explicitly redraws both halves, avoiding keyed child reuse that
      // can leave bars at their initial size on older ArkUI runtimes.
      const visiblePeak = Math.min(1, Math.max(0,
        this.samples[index] - WAVEFORM_DISPLAY_NOISE_FLOOR) * this.displayGain);
      const halfHeight = Math.max(0.65, Math.pow(visiblePeak, 0.48) * (middle - 2));
      const x = (index + 0.5) * stride;
      this.canvas.strokeStyle = index >= WAVEFORM_BAR_COUNT - 7 ? '#66E5D9' : '#E8FFF9';
      this.canvas.beginPath();
      this.canvas.moveTo(x, middle - halfHeight);
      this.canvas.lineTo(x, middle + halfHeight);
      this.canvas.stroke();
    }
  }

  aboutToDisappear(): void {
    if (this.amplitudeTimer >= 0) {
      clearInterval(this.amplitudeTimer);
      this.amplitudeTimer = -1;
    }
  }

  private durationLabel(): string {
    const seconds = Math.max(0, Math.floor(this.elapsedMs / 1000));
    const minutes = Math.floor(seconds / 60);
    return `${minutes.toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: WAVEFORM_BRAND_GAP }) {
          Image($rawfile('comic/brand/onebeat_wordmark.png'))
            .width(WAVEFORM_BRAND_WIDTH).height(WAVEFORM_BRAND_HEIGHT).objectFit(ImageFit.Contain)
            .draggable(false).accessibilityText('同拍 ONEBEAT')
          Divider().vertical(true).height(42).strokeWidth(1).color('#A6FFF9EE')
          Column({ space: 6 }) {
            Row({ space: 5 }) {
              Circle().width(5).height(5).fill(CORAL)
              Text(this.micMuted ? 'MIC 已静音' : 'MIC · 周围的声音')
                .fontSize(9).fontWeight(FontWeight.Bold).fontColor(PAPER).letterSpacing(0.8)
            }.width('100%')
            Canvas(this.canvas).width('100%').height(33).hitTestBehavior(HitTestMode.None)
              .onReady(() => { this.canvasReady = true; this.drawWaveform(); })
              .onAreaChange((_oldArea, area) => {
                this.canvasWidth = Number(area.width);
                this.canvasHeight = Number(area.height);
                this.drawWaveform();
              })
          }.layoutWeight(1)
        }
        .width('100%').height(WAVEFORM_HEIGHT).padding({ left: 13, right: 13, top: 10, bottom: 9 })
        .backgroundColor('#95171B1F').border({ width: 1, color: '#60FFF9EE' }).borderRadius(10)
      }
      .width('100%').padding({ left: WAVEFORM_SIDE_INSET, right: WAVEFORM_SIDE_INSET })
      .position({ x: 0, y: this.chromeVisible ? WAVEFORM_TOP : this.topSafeInset + WAVEFORM_DOCK_TOP_GAP })
      .animation({ duration: this.movementReady ? WAVEFORM_MOVE_MS : 0, curve: Curve.EaseInOut })
      // The overlay mounts after recording hides the panels. Its first frame is
      // already docked; only later user panel toggles should animate the position.
      .onAppear(() => { this.movementReady = true; })
      .id('recording-waveform').hitTestBehavior(HitTestMode.None)
      Column() {
        Blank().hitTestBehavior(HitTestMode.None)
        Row() {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 9 }) {
              Rect().width(11).height(11).radius(2).fill(CORAL)
              Text(this.stopping ? '正在结束…' : '停止录制')
                .fontSize(13).fontWeight(900).fontColor(PAPER)
              Text(this.durationLabel()).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#BDEAE3')
            }.padding({ left: 18, right: 18 })
          }
          .height(RECORD_PILL_HEIGHT).backgroundColor('#E6171B1F').border({ width: 1, color: '#9CFFF9EE' }).borderRadius(23)
          .id('recording-stop-pill')
          .enabled(!this.stopping).hitTestBehavior(HitTestMode.Default).onClick(this.onStop)
          .accessibilityText('停止本机视频录制，练习继续')
        }.width('100%').justifyContent(FlexAlign.Center)
          .padding({ bottom: RECORD_STOP_BOTTOM + this.bottomSafeInset })
          .hitTestBehavior(HitTestMode.Transparent)
      }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
        // The panel already provides Stop; keep the stage pill anchored below it rather than lifting a duplicate control.
        .visibility(this.chromeVisible ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent).zIndex(60)
  }
}
