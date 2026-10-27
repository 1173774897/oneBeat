import { router } from '@kit.ArkUI';
import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { RecordingCoordinator } from '../recording/RecordingCoordinator';
import { MetronomeEngine, MicExperimentPlaybackSnapshot } from '../audio/MetronomeEngine';
import { micExperimentPlaybackProblem } from '../audio/MicExperimentPlaybackGuard';
import { MicCaptureExperiment, MicExperimentCapability, MicExperimentResult,
  MicExperimentStageTiming } from '../audio/MicCaptureExperiment';
import { MicExperimentPlayer } from '../audio/MicExperimentPlayer';
import { MonotonicClock } from '../common/MonotonicClock';
import { writeAtomic } from '../common/AtomicTextFile';
import { showUserNotice } from '../common/UserFeedback';
import { ensureMicrophonePermission, microphonePermissionDeniedHint } from '../network/join/TeamNetworkPermissions';
import { PAPER, INK, LILAC, CORAL, WHITE, TEAL } from '../components/ComicKit';
import { ActionButton } from '../components/ActionButton';

const LAB_PAGE_INSET: number = 20;
const LAB_CARD_GAP: number = 16;
const LAB_CARD_INSET: number = 16;
const LAB_BUTTON_HEIGHT: number = 46;
const LAB_LEVEL_HEIGHT: number = 12;
const LAB_BPM: number = 120;
const LAB_CAPTURE_MS: number = 10000;
const LAB_RECOVERY_MS: number = 2000;

interface MicLabBoundary {
  phase: string;
  playback: MicExperimentPlaybackSnapshot;
}

interface MicLabReport {
  version: number;
  recordedAt: number;
  mode: string;
  outcome: string;
  capability: MicExperimentCapability;
  boundaries: MicLabBoundary[];
  stages: MicExperimentStageTiming[];
  mic: MicExperimentResult | undefined;
  live: MicExperimentResult | undefined;
}

@Entry
@Component
struct MicCaptureExperimentPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @State capability: MicExperimentCapability = MicCaptureExperiment.capability();
  @State busy: boolean = false;
  @State phase: string = '独立 MIC 实验';
  @State instruction: string = '同一段节奏，比较两种采集';
  @State elapsed: number = 0;
  @State level: number = 0;
  @State outcome: string = '';
  @State micResult: MicExperimentResult | undefined = undefined;
  @State liveResult: MicExperimentResult | undefined = undefined;
  @State previewSource: string = '';
  private experiment: MicCaptureExperiment = new MicCaptureExperiment();
  private player: MicExperimentPlayer = new MicExperimentPlayer();
  private engine: MetronomeEngine | undefined = undefined;
  private baseline: MicExperimentPlaybackSnapshot | undefined = undefined;
  private boundaries: MicLabBoundary[] = [];
  private stages: MicExperimentStageTiming[] = [];
  private task: Promise<void> | undefined = undefined;
  private runToken: number = 0;
  private previewToken: number = 0;
  private leaving: boolean = false;
  private pageActive: boolean = false;
  private foreground: boolean = true;
  private application: common.ApplicationContext | undefined = undefined;
  private routing: audio.AudioRoutingManager | undefined = undefined;
  private routeSubscribed: boolean = false;
  private cancelReason: string = '';
  private applicationCallback: ApplicationStateChangeCallback = {
    onApplicationForeground: (): void => { this.foreground = true; },
    onApplicationBackground: (): void => {
      this.foreground = false;
      this.cancelExperiment('应用进入后台，本轮已停止');
    }
  };
  private routeCallback = (devices: audio.AudioDeviceDescriptors): void => {
    if (!this.busy || this.baseline === undefined) { return; }
    const signature = devices.map((device: audio.AudioDeviceDescriptor): string =>
      `${device.deviceType}:${device.id}`).join(',');
    if (signature !== this.baseline.outputDevices) {
      this.cancelExperiment('声音输出设备发生变化，本轮已停止');
    }
  };

  aboutToAppear(): void {
    this.pageActive = true;
    this.application = (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext();
    this.application.on('applicationStateChange', this.applicationCallback);
  }

  onPageShow(): void { this.pageActive = true; }

  onPageHide(): void {
    this.pageActive = false;
    this.cancelExperiment('离开实验页，本轮已停止');
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.cancelExperiment('离开实验页，本轮已停止');
    this.application?.off('applicationStateChange', this.applicationCallback);
    this.application = undefined;
  }

  onBackPress(): boolean { void this.leavePage(); return true; }

  private checkIsolation(): void {
    // A lobby owns a global route observer even while idle. Never borrow its engine
    // or start LIVE while that observer could alter production calibration state.
    if (AppSession.hasLiveOrRetiringSession()) { throw new Error('请先退出练习与队伍，并等待退出完成后再实验'); }
    const state = RecordingCoordinator.getSnapshot().state;
    if (state !== 'idle' && state !== 'failed') { throw new Error('请先结束正式录制与保存'); }
  }

  private checkRun(token: number): void {
    if (token !== this.runToken || !this.pageActive || !this.foreground) {
      throw new Error(this.cancelReason || '麦克风实验已取消');
    }
    this.checkIsolation();
  }

  private sample(phase: string, details: boolean = false): string {
    this.checkIsolation();
    if (this.engine === undefined || this.baseline === undefined) { throw new Error('实验播放基准不可用'); }
    const snapshot = this.engine.readMicExperimentPlaybackSnapshot(details);
    const problem = micExperimentPlaybackProblem(this.baseline, snapshot);
    if (details) { this.boundaries.push({ phase: phase, playback: snapshot }); }
    if (problem.length > 0) { throw new Error(problem); }
    return JSON.stringify(snapshot);
  }

  private async waitObserved(durationMs: number, token: number): Promise<void> {
    const until = MonotonicClock.nowMs() + durationMs;
    while (MonotonicClock.nowMs() < until) {
      this.checkRun(token);
      if (this.baseline !== undefined) { this.sample('interval'); }
      await new Promise<void>((resolve): void => { setTimeout(resolve, 100); });
    }
    this.checkRun(token);
  }

  private subscribeRoute(): void {
    this.routing = audio.getAudioManager().getRoutingManager();
    this.routing.on('preferOutputDeviceChangeForRendererInfo',
      { usage: audio.StreamUsage.STREAM_USAGE_GAME, rendererFlags: 0 }, this.routeCallback);
    this.routeSubscribed = true;
  }

  private unsubscribeRoute(): void {
    if (this.routeSubscribed) {
      try { this.routing?.off('preferOutputDeviceChangeForRendererInfo', this.routeCallback); }
      catch (_error) {}
    }
    this.routeSubscribed = false;
    this.routing = undefined;
  }

  private startExperiment(compare: boolean): Promise<void> {
    if (this.task !== undefined || this.busy || this.leaving || !this.pageActive || !this.foreground) {
      return Promise.resolve();
    }
    this.busy = true;
    const token = ++this.runToken;
    const task = this.performExperiment(compare, token).finally((): void => {
      if (this.task === task) { this.task = undefined; }
      this.busy = false;
    });
    this.task = task;
    return task;
  }

  private async performExperiment(compare: boolean, token: number): Promise<void> {
    let permissionReady = false;
    let fileRunStarted = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.cancelReason = '';
    this.outcome = '';
    this.boundaries = [];
    this.stages = [];
    try {
      this.checkRun(token);
      this.previewToken++;
      this.previewSource = '';
      await this.player.stop();
      this.checkRun(token);
      this.phase = '准备麦克风权限';
      if (!await ensureMicrophonePermission(context)) { throw new Error(microphonePermissionDeniedHint()); }
      // A permission prompt can outlive navigation. Recheck before creating any audio resource.
      this.checkRun(token);
      permissionReady = true;
      this.capability = MicCaptureExperiment.capability();
      if (compare && !this.capability.liveAvailable) { throw new Error(this.capability.reason); }
      this.micResult = undefined;
      this.liveResult = undefined;
      await this.experiment.clear(context.filesDir);
      await this.deleteSummary(context.filesDir);
      fileRunStarted = true;
      this.checkRun(token);
      this.subscribeRoute();
      const engine = new MetronomeEngine();
      this.engine = engine;
      engine.configure(0, 0);
      engine.setBpm(LAB_BPM, 4);
      engine.setOffsetMs(0);
      this.phase = '建立播放基准';
      this.instruction = '120 BPM · 整个对比只启动一次节奏';
      await engine.ensureRenderer();
      this.checkRun(token);
      // Local experiment has no shared transport and must not apply or persist earphone compensation.
      await engine.scheduleFromLeaderStart(MonotonicClock.nowMs() + 800, 0, 0, 0);
      await this.waitObserved(2200, token);
      const baseline = engine.readMicExperimentPlaybackSnapshot(true);
      if (!baseline.running || !baseline.started || baseline.writeCallbackCount < 2 || baseline.streamId < 0 ||
        baseline.outputDevices === 'none' || baseline.outputDevices === 'unavailable' || baseline.audioScene < 0) {
        throw new Error('无法建立可观测的播放基准，本轮未开始采集');
      }
      this.baseline = baseline;
      this.boundaries.push({ phase: 'baseline', playback: baseline });
      this.micResult = await this.capturePhase('mic', token, context.filesDir);
      this.phase = '普通 MIC 释放后观察';
      await this.waitObserved(LAB_RECOVERY_MS, token);
      this.sample('mic-restored', true);
      if (compare) {
        this.liveResult = await this.capturePhase('live', token, context.filesDir);
        this.phase = 'LIVE 释放后观察';
        await this.waitObserved(LAB_RECOVERY_MS, token);
        this.sample('live-restored', true);
        const micDevices = JSON.stringify(this.micResult.devices);
        if (micDevices !== JSON.stringify(this.liveResult.devices)) {
          throw new Error('两段实际输入设备不同，无法作为同条件 AEC 对比');
        }
      }
      this.checkRun(token);
      this.outcome = '未发现可观测输出变化；仍需双机/耳机实测。请试听比较漏入的节拍与人声。';
      this.phase = '本轮采集完成';
    } catch (error) {
      this.outcome = this.cancelReason || (error as Error).message;
      this.phase = permissionReady ? '本轮已停止' : '实验未开始';
    } finally {
      this.experiment.cancel();
      await this.stopOutput();
      this.baseline = undefined;
      this.level = 0;
      this.instruction = '试听的是原始麦克风，不另混入节奏、不自动归一音量';
      if (fileRunStarted) {
        const report: MicLabReport = {
          version: 1, recordedAt: Date.now(), mode: compare ? 'mic-vs-live' : 'mic-only',
          outcome: this.outcome, capability: this.capability, boundaries: this.boundaries, stages: this.stages,
          mic: this.micResult, live: this.liveResult
        };
        try { await writeAtomic(`${context.filesDir}/mic-capture-experiment/summary.json`, JSON.stringify(report)); }
        catch (_error) { this.outcome += ' 综合报告未能写入，本机录音仍可试听。'; }
      }
    }
  }

  private async capturePhase(source: 'mic' | 'live', token: number, filesDir: string): Promise<MicExperimentResult> {
    this.checkRun(token);
    this.sample(`${source}-before`, true);
    this.phase = source === 'mic' ? '01 / 普通 MIC' : '02 / LIVE + 系统 AEC';
    this.elapsed = 0;
    this.instruction = '前 5 秒保持安静，后 5 秒说话或拍手';
    let observations = 0;
    const result = await this.experiment.run(filesDir, source, {
      onProgress: (elapsedMs: number, level: number, _frames: number): void => {
        if (token !== this.runToken) { return; }
        this.elapsed = elapsedMs;
        this.level = Math.min(1, Math.max(0, level));
        this.instruction = elapsedMs < 5000 ? '保持安静 · 只听节拍' : '现在说话或拍手 · 保持设备位置';
      },
      onStage: (timing: MicExperimentStageTiming): void => { this.stages.push(timing); },
      snapshot: (): string => {
        this.checkRun(token);
        // The first observation precedes capturer creation; the second follows
        // native start. Record route/scene/latency while capture is actually active,
        // since a temporary scene change may disappear before release completes.
        observations++;
        return this.sample(`${source}-active`, observations === 2);
      }
    }, LAB_CAPTURE_MS);
    // Keep a completed raw take available for diagnosis even if the following
    // output-boundary check rejects this run as unsuitable for comparison.
    if (source === 'mic') { this.micResult = result; }
    else { this.liveResult = result; }
    this.checkRun(token);
    this.sample(`${source}-released`, true);
    return result;
  }

  private async stopOutput(): Promise<void> {
    this.unsubscribeRoute();
    const engine = this.engine;
    // Invalidate pending startup synchronously; don't leave a scheduled beat behind navigation.
    engine?.pause();
    if (engine !== undefined) { await engine.stopEngine(); }
    if (this.engine === engine) { this.engine = undefined; }
  }

  private cancelExperiment(reason: string): void {
    if (this.busy) { this.cancelReason = reason; this.runToken++; }
    this.experiment.cancel();
    this.engine?.pause();
    this.previewToken++;
    this.player.cancel();
    this.previewSource = '';
  }

  private async leavePage(): Promise<void> {
    if (this.leaving) { return; }
    this.leaving = true;
    this.cancelExperiment('已结束本轮实验');
    await this.task;
    await this.player.stop();
    await this.stopOutput();
    router.back();
  }

  private async preview(result: MicExperimentResult): Promise<void> {
    if (this.busy || this.engine !== undefined || this.leaving || !this.pageActive || !this.foreground) { return; }
    const token = ++this.previewToken;
    try {
      this.checkIsolation();
      if (this.previewSource === result.source) {
        this.previewSource = '';
        await this.player.stop();
        return;
      }
      this.previewSource = result.source;
      await this.player.play(result.wavPath, (): void => {
        if (token === this.previewToken) { this.previewSource = ''; }
      });
    } catch (error) {
      if (token !== this.previewToken) { return; }
      this.previewSource = '';
      showUserNotice((error as Error).message, 'mic-experiment');
    }
  }

  private async deleteSummary(filesDir: string): Promise<void> {
    const path = `${filesDir}/mic-capture-experiment/summary.json`;
    if (await fs.access(path)) { await fs.unlink(path); }
  }

  private async clearFiles(): Promise<void> {
    if (this.busy || this.leaving) { return; }
    this.busy = true;
    try {
      this.previewToken++;
      await this.player.stop();
      this.previewSource = '';
      const filesDir = (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
      await this.experiment.clear(filesDir);
      await this.deleteSummary(filesDir);
      this.micResult = undefined;
      this.liveResult = undefined;
      this.outcome = '本机实验录音与报告已清除';
    } catch (error) { showUserNotice((error as Error).message, 'mic-experiment'); }
    finally { this.busy = false; }
  }

  private resultDetails(result: MicExperimentResult): string {
    const clock = result.clockMetrics;
    const status = clock.quality === 'stable' ? '短时采集时钟稳定' : clock.reason;
    const inputs = result.devices.map((device): string => `${device.type}/${device.role}`).join(' · ');
    const fit = clock.quality === 'insufficient' ? '硬件锚点不足，暂不报告漂移' :
      `漂移 ${clock.clockRateErrorPpm.toFixed(1)} ppm · P95 ${clock.timestampFitResidualP95Ms.toFixed(2)} ms`;
    return `${result.sampleRate / 1000} kHz · ${result.channels} 声道 · ${(result.durationMs / 1000).toFixed(1)} 秒\n` +
      `输入类型/角色 ${inputs || '未知'} · AEC 声明 ${result.aecSupported ? '支持' : '未声明'}\n` +
      `${status}\n${fit}\n` +
      `削波 ${result.clippedSamples} · 溢出 ${result.overflowCount < 0 ? '不可查询' : result.overflowCount}`;
  }

  @Builder
  private resultCard(title: string, result: MicExperimentResult) {
    Column({ space: 10 }) {
      Row() {
        Text(title).fontSize(18).fontWeight(900).fontColor(INK)
        Blank()
        ActionButton({
          label: this.previewSource === result.source ? '停止试听' : '试听原音', active: !this.busy,
          controlWidth: 'auto', controlHeight: 36, labelSize: 13, labelColor: INK, fill: LILAC,
          cornerRadius: 18, contentPadding: { left: 16, right: 16 },
          action: (): void => { void this.preview(result); }
        })
      }.width('100%')
      Text(this.resultDetails(result)).fontSize(12).lineHeight(21).fontColor(INK).width('100%')
    }.padding(LAB_CARD_INSET).width('100%').backgroundColor(WHITE)
      .border({ width: 2, color: INK, radius: 14 })
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').backgroundColor(Color.Transparent).fontColor(INK).fontSize(16)
          .onClick((): void => { void this.leavePage(); })
        Blank()
        Text('SOUND LAB / 01').fontSize(12).fontWeight(900).fontColor(INK)
      }.width('100%').padding({ left: 8, right: LAB_PAGE_INSET, top: this.topSafeInset + 8, bottom: 8 })
      Scroll() {
        Column({ space: LAB_CARD_GAP }) {
          Column({ space: 8 }) {
            Text('听清这一拍').fontSize(30).fontWeight(900).fontColor(INK).width('100%')
            Text('普通 MIC × LIVE 回声消除').fontSize(16).fontWeight(700).fontColor(INK).width('100%')
            Text('仅比较独立 AudioCapturer 的两种模式，并非现有录屏 MIC。不会替换正式录制或写入耳机校准。')
              .fontSize(13).lineHeight(21).fontColor(INK)
          }.width('100%')
          Column({ space: 8 }) {
            Text(`API ${this.capability.apiVersion} · ${this.capability.liveAvailable ? '可进行 LIVE 对比' : '仅可采集普通 MIC'}`)
              .fontSize(16).fontWeight(900).fontColor(INK).width('100%')
            Text(this.capability.liveAvailable ?
              '系统声明支持 LIVE AEC；实际去回声效果需要试听。普通 MIC 也可能已带系统处理。' : this.capability.reason)
              .fontSize(12).lineHeight(20).fontColor(INK).width('100%')
          }.padding(LAB_CARD_INSET).width('100%').backgroundColor(LILAC).border({ width: 2, color: INK, radius: 14 })
          Column({ space: 12 }) {
            Text(this.phase).fontSize(20).fontWeight(900).fontColor(INK).width('100%')
            Text(this.instruction).fontSize(13).fontColor(INK).width('100%')
            Progress({ value: Math.min(100, this.elapsed / LAB_CAPTURE_MS * 100), total: 100, type: ProgressType.Linear })
              .width('100%').color(CORAL).backgroundColor('#E4DFD7')
            Row() {
              Text('MIC').fontSize(11).fontWeight(900).fontColor(INK).width(36)
              Progress({ value: this.level * 100, total: 100, type: ProgressType.Linear })
                .layoutWeight(1).height(LAB_LEVEL_HEIGHT).color(TEAL).backgroundColor('#E4DFD7')
            }.width('100%')
            if (this.busy) {
              Button('停止本轮').height(LAB_BUTTON_HEIGHT).width('100%').fontColor(WHITE).backgroundColor(INK)
                .onClick((): void => { this.cancelExperiment('已手动停止本轮实验'); })
            } else {
              ActionButton({
                label: '开始 MIC / LIVE 对比 · 约 28 秒', active: this.capability.liveAvailable,
                controlHeight: LAB_BUTTON_HEIGHT, labelColor: INK, fill: CORAL,
                labelSize: 14, labelWeight: 900, cornerRadius: LAB_BUTTON_HEIGHT / 2,
                contentPadding: { left: 16, right: 16 },
                action: (): void => { void this.startExperiment(true); }
              })
              Button('只采集普通 MIC · 约 14 秒').height(LAB_BUTTON_HEIGHT).width('100%')
                .fontColor(INK).backgroundColor(PAPER).fontSize(14)
                .onClick((): void => { void this.startExperiment(false); })
            }
          }.padding(LAB_CARD_INSET).width('100%').backgroundColor(WHITE).border({ width: 2, color: INK, radius: 14 })
          if (this.outcome.length > 0) {
            Text(this.outcome).fontSize(13).lineHeight(22).fontWeight(700).fontColor(INK)
              .padding(LAB_CARD_INSET).width('100%').backgroundColor(LILAC).borderRadius(12)
          }
          if (this.micResult !== undefined) { this.resultCard('01 / 普通 MIC', this.micResult); }
          if (this.liveResult !== undefined) { this.resultCard('02 / LIVE', this.liveResult); }
          Text('每段前 5 秒安静，后 5 秒说话或拍手。保持手机、耳机和系统音量一致。先用扬声器，再分别连接常用耳机复测。\n\n录音只留本机私有目录，重测会覆盖上一轮，不上传、不存图库。硬件时间戳稳定不等于声音已对齐；双机同步和耳机实际延迟仍需另测。')
            .fontSize(12).lineHeight(21).fontColor('#625C55').width('100%')
          ActionButton({
            label: '清除本机实验文件', active: !this.busy, controlWidth: 'auto',
            labelColor: INK, fill: Color.Transparent, cornerRadius: 20,
            contentPadding: { left: 16, right: 16 }, action: (): void => { void this.clearFiles(); }
          })
        }.width('100%').padding({ left: LAB_PAGE_INSET, right: LAB_PAGE_INSET,
          top: 8, bottom: this.bottomSafeInset + 24 })
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(PAPER)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
