import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { MicLoopbackCalibrator } from '../audio/MicLoopbackCalibrator';
import { AudioOutputMonitor } from '../audio/AudioOutputMonitor';
import { AppSession } from '../app/AppSession';
import { ensureMicrophonePermission, microphonePermissionDeniedHint } from '../network/join/TeamNetworkPermissions';
import {
  clearCalibrationMs,
  getCalibrationMs,
  getInputLatencyMs,
  saveCalibrationMs,
  saveInputLatencyMs
} from '../store/AudioLatencyPersistence';
import {
  CARD_SHADOW,
  CONTROL_SHADOW,
  CORAL,
  INK,
  LILAC,
  PAPER,
  TEAL,
  WHITE
} from '../components/ComicKit';

@Entry
@Component
struct MicLoopbackCalibrationPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('btAudioActive') @Watch('onBluetoothAudioRouteChanged') btAudioActive: boolean = false;
  @StorageLink('audioOutputRouteEpoch') @Watch('onAudioOutputRouteChanged') audioOutputRouteEpoch: number = 0;
  @State measuring: boolean = false;
  @State hasResult: boolean = false;
  @State resultMs: number = -1;
  @State snrDb: number = 0;
  @State validRuns: number = 0;
  @State detectedRuns: number = 0;
  @State spreadMs: number = -1;
  @State status: string = '点击开始，自动播放测试音并用麦克风测回环时延';
  @State saving: boolean = false;
  @State inputLatencyMs: number = -1;
  @State inputCalibrating: boolean = false;
  @State inputStatus: string = '';
  private calibrator: MicLoopbackCalibrator = new MicLoopbackCalibrator();
  private pageActive: boolean = false;
  private measurementToken: number = 0;

  aboutToAppear(): void {
    this.pageActive = true;
    this.inputLatencyMs = getInputLatencyMs();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.measurementToken++;
    this.calibrator.cancel();
    this.publishCalibrationActivity(false);
    void AppSession.get()?.stopLatencyCalibration();
  }

  private publishCalibrationActivity(active: boolean): void {
    const controller = AppSession.get()?.controller;
    if (controller !== undefined) {
      void controller.setBluetoothCalibrationActive(active);
    }
  }

  private onBluetoothAudioRouteChanged(): void {
    if (this.btAudioActive) {
      if (this.inputCalibrating) {
        this.calibrator.cancel();
        this.inputCalibrating = false;
        this.inputStatus = '输入侧校准期间检测到蓝牙耳机，本次结果已丢弃';
        AppSession.get()?.pauseLatencyCalibration();
      }
      return;
    }
    // A loopback result belongs to the physical route that produced it. Once
    // that route disappears, never allow a later reconnect to save the stale value.
    this.measurementToken++;
    const hadResult = this.hasResult;
    this.hasResult = false;
    this.resultMs = -1;
    this.validRuns = 0;
    this.detectedRuns = 0;
    this.spreadMs = -1;
    this.saving = false;
    if (this.measuring) {
      this.calibrator.cancel();
      this.measuring = false;
      this.status = '蓝牙耳机已断开，请重新连接后再测';
      this.publishCalibrationActivity(false);
    } else if (hadResult) {
      this.status = '测量所用的蓝牙耳机已断开，结果已作废；重连后请重新测量';
    }
    void AppSession.get()?.stopLatencyCalibration();
  }

  private onAudioOutputRouteChanged(): void {
    this.measurementToken++;
    if (this.measuring || this.inputCalibrating) {
      this.calibrator.cancel();
    }
    if (this.measuring) {
      this.measuring = false;
      this.publishCalibrationActivity(false);
    }
    if (this.inputCalibrating) {
      this.inputCalibrating = false;
      this.inputStatus = '输出设备发生变化，本次输入侧结果已丢弃';
    }
    if (this.hasResult) {
      this.hasResult = false;
      this.resultMs = -1;
      this.validRuns = 0;
      this.detectedRuns = 0;
      this.spreadMs = -1;
      this.saving = false;
      this.status = '输出设备发生变化，耳机回环结果已作废，请重新测量';
    }
    AppSession.get()?.pauseLatencyCalibration();
  }

  private async startMeasure(): Promise<void> {
    if (!this.btAudioActive) {
      promptAction.showToast({ message: '当前没有检测到蓝牙耳机输出，请返回大厅重新确认' });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted = await ensureMicrophonePermission(ctx);
    if (!granted) {
      promptAction.showToast({ message: microphonePermissionDeniedHint() });
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      promptAction.showToast({ message: '当前没有可用会话，请从队伍大厅进入' });
      return;
    }
    this.measuring = true;
    this.saving = false;
    this.hasResult = false;
    this.resultMs = -1;
    this.validRuns = 0;
    this.detectedRuns = 0;
    this.spreadMs = -1;
    this.status = '正在寻找合适的摆放位置…';
    this.publishCalibrationActivity(true);
    const measurementToken = ++this.measurementToken;
    try {
      const result = await this.calibrator.measureWithPersistentRenderer(
        (signal: Int16Array, targetAtLocalMonoMs: number) =>
          session.scheduleMicLoopbackSignal(signal, targetAtLocalMonoMs),
        (msg: string) => {
          if (measurementToken === this.measurementToken) {
            this.status = msg;
          }
        });
      if (!this.pageActive || measurementToken !== this.measurementToken || !this.btAudioActive) {
        return;
      }
      this.measuring = false;
      this.publishCalibrationActivity(false);
      session.pauseLatencyCalibration();
      if (!result.detected) {
        if (result.validRuns > 0) {
          this.status = `4 次中定位成功 ${result.validRuns} 次，请保持耳机不动后重试`;
          return;
        }
        const levelPct = Math.round(result.capturedPeak * 100);
        if (levelPct < 5) {
          this.status = '还没有稳定听到测试音，请把耳机出声孔贴近手机底部麦克风后重试';
        } else {
          this.status = '听到了环境声音，但没有锁定测试音；请对准麦克风并用手掌轻罩住后重试';
        }
        return;
      }
      this.resultMs = result.latencyMs;
      this.snrDb = result.snrDb;
      this.validRuns = result.validRuns;
      this.detectedRuns = result.detectedRuns;
      this.spreadMs = result.spreadMs;
      this.hasResult = true;
      if (this.resultMs < 0) {
        this.status = '测量已完成，但时间轴结果异常，请再测一次';
      } else if (this.outputCompensationMs() < 0) {
        this.status = '测量已完成，但两次测量基准不一致，请重新校准输入侧后再测耳机';
      } else {
        this.status = this.resultConsistent()
          ? '测量完成'
          : '测量完成；检测到蓝牙链路波动，已取稳健中位数';
      }
    } catch (err) {
      if (!this.pageActive || measurementToken !== this.measurementToken) {
        return;
      }
      this.measuring = false;
      this.status = `测量失败：${(err as Error).message}`;
      this.publishCalibrationActivity(false);
      session.pauseLatencyCalibration();
    }
  }

  private async startInputCalibration(): Promise<void> {
    if (this.inputCalibrating || this.measuring) {
      return;
    }
    if (!AudioOutputMonitor.isBuiltInSpeakerActive()) {
      promptAction.showToast({ message: '请把媒体输出切到手机扬声器后再测输入侧时延（只需测一次）' });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted = await ensureMicrophonePermission(ctx);
    if (!granted) {
      promptAction.showToast({ message: microphonePermissionDeniedHint() });
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      promptAction.showToast({ message: '当前没有可用会话，请从队伍大厅进入' });
      return;
    }
    this.inputCalibrating = true;
    this.inputStatus = '外放播放测试音，测输入侧时延…';
    const inputMeasurementToken = ++this.measurementToken;
    try {
      const result = await this.calibrator.measureInputLatency(
        (signal: Int16Array, targetAtLocalMonoMs: number) =>
          session.scheduleMicInputReferenceSignal(signal, targetAtLocalMonoMs),
        (msg: string) => {
          if (inputMeasurementToken === this.measurementToken) {
            this.inputStatus = msg;
          }
        });
      session.pauseLatencyCalibration();
      if (!this.pageActive || inputMeasurementToken !== this.measurementToken) {
        return;
      }
      this.inputCalibrating = false;
      if (!AudioOutputMonitor.isBuiltInSpeakerActive()) {
        this.inputStatus = '输入侧校准期间媒体输出已离开手机扬声器，本次结果已丢弃';
        return;
      }
      if (!result.detected) {
        this.inputStatus = '未定位到输入侧时延，请把手机麦克风对准外放出声点后重试';
        return;
      }
      const measuredInputLatencyMs = Math.round(result.inputLatencyMs);
      await saveInputLatencyMs(measuredInputLatencyMs);
      this.inputLatencyMs = measuredInputLatencyMs;
      this.inputStatus = `输入侧时延已保存：${this.inputLatencyMs} ms`;
      promptAction.showToast({ message: `输入侧时延 ${this.inputLatencyMs} ms 已保存` });
    } catch (err) {
      if (!this.pageActive || inputMeasurementToken !== this.measurementToken) {
        return;
      }
      this.inputCalibrating = false;
      session.pauseLatencyCalibration();
      this.inputStatus = `输入侧校准失败：${(err as Error).message}`;
    }
  }

  private async finishAndSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (!this.resultSaveable()) {
      if (this.inputLatencyMs >= 0 && this.resultMs - this.inputLatencyMs < 0) {
        promptAction.showToast({ message: '回环值小于输入侧值，本次差分结果无效，请重测两步' });
      } else {
        promptAction.showToast({ message: '还没有足够的有效测量结果' });
      }
      return;
    }
    if (!this.btAudioActive) {
      promptAction.showToast({ message: '蓝牙耳机已断开，本次结果没有保存' });
      return;
    }
    if (this.inputLatencyMs < 0) {
      promptAction.showToast({ message: '请先完成输入侧校准，再保存耳机输出补偿' });
      return;
    }
    const outputMs = this.outputCompensationMs();
    const previousOutputMs = getCalibrationMs();
    const saveToken = this.measurementToken;
    console.info(`[LatencyDiag] save outputMs=${outputMs} = resultMs=${this.resultMs} - ` +
      `inputLatencyMs=${this.inputLatencyMs}`);
    this.saving = true;
    try {
      await saveCalibrationMs(outputMs);
      if (!this.pageActive || !this.btAudioActive || saveToken !== this.measurementToken) {
        // Persistence is asynchronous. If the measured route vanished during
        // flush, restore the prior shared value instead of activating stale mic data.
        if (previousOutputMs >= 0) {
          await saveCalibrationMs(previousOutputMs);
        } else {
          await clearCalibrationMs();
        }
        this.saving = false;
        if (this.pageActive) {
          promptAction.showToast({ message: '保存期间蓝牙路由发生变化，本次结果已丢弃' });
        }
        return;
      }
      const session = AppSession.get();
      session?.metronome.refreshOutputCalibration();
      session?.keepLatencyCalibrationRendererAlive();
      session?.markLatencyCalibrationRoute(true);
      promptAction.showToast({ message: `已保存 ${outputMs} ms（回环 ${this.resultMs} ms − 输入侧 ${this.inputLatencyMs} ms），蓝牙重连后推荐重测` });
      router.back({ url: 'pages/LeaderLobbyPage' });
    } catch (err) {
      promptAction.showToast({ message: `保存失败：${(err as Error).message}` });
      this.saving = false;
    }
  }

  private qualityLabel(): string {
    if (this.resultMs < 0 || this.outputCompensationMs() < 0) {
      return '本次结果无效';
    }
    if (this.validRuns === 4 && this.spreadMs >= 0 && this.spreadMs <= 10 && this.snrDb >= 20) {
      return '结果稳定';
    }
    if (this.validRuns >= 3 && this.spreadMs >= 0 && this.spreadMs <= 30) {
      return '结果可用';
    }
    return '链路有波动，已取中位数';
  }

  private resultConsistent(): boolean {
    return this.resultMs >= 0 && this.outputCompensationMs() >= 0 &&
      this.validRuns >= 3 && this.spreadMs >= 0 && this.spreadMs <= 30;
  }

  private resultSaveable(): boolean {
    return this.hasResult && this.resultMs >= 0 && this.inputLatencyMs >= 0 &&
      this.outputCompensationMs() >= 0 && this.validRuns >= 3;
  }

  private outputCompensationMs(): number {
    if (this.inputLatencyMs < 0) {
      return this.resultMs;
    }
    return Math.round((this.resultMs - this.inputLatencyMs) * 10) / 10;
  }

  private runSummary(): string {
    if (this.detectedRuns > this.validRuns) {
      return `${this.detectedRuns}/4 次定位 · ${this.validRuns} 次一致（已排除离群值）`;
    }
    return `${this.detectedRuns}/4 次定位`;
  }

  @Builder
  private resultCard() {
    Column({ space: 8 }) {
      Text(this.qualityLabel()).fontSize(11).fontWeight(900)
        .fontColor(this.resultConsistent() ? TEAL : CORAL)
      Row({ space: 6 }) {
        Text(`${this.resultMs}`).fontSize(48).fontWeight(900).fontColor(INK)
        Text('ms').fontSize(16).fontWeight(900).fontColor('#625B53').margin({ top: 16 })
      }
      Text(`${this.runSummary()} · 相关置信度 ${this.snrDb} dB · 稳健波动 ${this.spreadMs} ms`)
        .fontSize(12).fontWeight(700).fontColor('#5C554D')
      Text(this.resultMs < 0
        ? '该值来自异常的采集时间轴，本次不会保存，请重新测量。'
        : this.inputLatencyMs >= 0 && this.outputCompensationMs() < 0
          ? `回环 ${this.resultMs} ms − 输入侧 ${this.inputLatencyMs} ms = ${this.outputCompensationMs()} ms。这表示两次测量基准不一致，不会保存。`
        : this.inputLatencyMs >= 0
          ? `保存值 = 回环 ${this.resultMs} ms − 输入侧 ${this.inputLatencyMs} ms = ${this.outputCompensationMs()} ms`
          : '这是回环往返值，保存前会先扣掉输入侧时延。')
        .fontSize(12).lineHeight(18).fontColor('#5C554D').width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor(WHITE)
    .border({ width: 1.5, color: INK })
    .borderRadius(9)
    .shadow(CARD_SHADOW)
  }

  build() {
    Column() {
      Row({ space: 9 }) {
        Text('‹').fontSize(32).width(32).onClick(() => router.back())
        Column({ space: 1 }) {
          Text('麦克风回环').fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
          Text('耳机延迟校准 · 自动实测').fontSize(11).fontWeight(800).fontColor('#5C554D')
        }.alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 8 + this.topSafeInset, bottom: 8 })

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 4 }) {
            Text('第 1 步 · 输入侧校准（只需一次）').fontSize(16).fontWeight(900).width('100%')
            Text(this.inputLatencyMs >= 0
              ? `已保存输入侧时延 ${this.inputLatencyMs} ms`
              : '断开蓝牙后用手机外放测一次麦克风输入侧时延，回环结果会先扣掉它，语义才和打卡机一致。')
              .fontSize(13).lineHeight(20).fontColor('#5C554D').width('100%')
          }.width('100%')

          Button(this.inputCalibrating ? '校准中…' : (this.inputLatencyMs >= 0 ? '重新校准输入侧' : '校准输入侧时延'), { type: ButtonType.Normal })
            .width('100%').height(42).fontSize(13).fontWeight(900).fontColor(INK)
            .backgroundColor(TEAL).border({ width: 1.5, color: INK }).borderRadius(7)
            .enabled(!this.inputCalibrating && !this.measuring)
            .onClick(() => { void this.startInputCalibration(); })

          if (this.inputStatus.length > 0) {
            Text(this.inputStatus).fontSize(11).fontWeight(700).fontColor('#5C554D').width('100%')
          }

          Column({ space: 4 }) {
            Text('第 2 步 · 耳机回环测量').fontSize(16).fontWeight(900).width('100%')
            Text('保持平常听歌音量，不需要调大。把一只耳机出声孔对准手机底部麦克风，可以用手掌轻罩住二者；页面会先自动找位置，再连续测量 4 次。')
              .fontSize(13).lineHeight(20).fontColor('#5C554D').width('100%')
          }.width('100%')

          Row({ space: 8 }) {
            Text(this.measuring ? '◌' : this.hasResult ? '●' : '·').fontSize(12).fontColor(this.measuring ? CORAL : TEAL)
            Text(this.status).fontSize(12).fontWeight(700).fontColor('#5C554D').layoutWeight(1)
          }.width('100%').padding({ left: 4, right: 4 })

          if (this.hasResult) {
            this.resultCard()
          }

          Button(this.measuring ? '测量中…' : (this.hasResult ? '重新测量' : '开始测量'), { type: ButtonType.Normal })
            .width('100%').height(44).fontSize(14).fontWeight(900).fontColor(INK)
            .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(7)
            .enabled(!this.measuring)
            .onClick(() => { void this.startMeasure(); })

          if (this.hasResult) {
            Button('保存并生效', { type: ButtonType.Normal })
              .width('100%').height(56).fontSize(19).fontWeight(900).fontColor(INK)
              .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7)
              .shadow(CONTROL_SHADOW).enabled(!this.saving && this.resultSaveable())
              .opacity(this.saving || !this.resultSaveable() ? 0.55 : 1)
              .onClick(() => { void this.finishAndSave(); })
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 28 + this.bottomSafeInset })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
