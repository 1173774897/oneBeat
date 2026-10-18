import { abilityAccessCtrl, Context, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import * as recordingNative from 'libonebeat_recording.so';
import { AudioOutputMonitor } from '../audio/AudioOutputMonitor';
import { MonotonicClock } from '../common/MonotonicClock';
import { SessionBackgroundKeeper } from '../session/SessionBackgroundKeeper';
import { RecordingClip, RecordingListener, RecordingScope, RecordingSnapshot, RecordingState } from './RecordingModels';
import { RecordingRepository, RecordingTarget } from './RecordingRepository';
import { RecordingMixer, RECORDING_MIX_VERSION } from './RecordingMixer';

const INPUT_PEAK_INTERVAL_MS: number = 80;
const CONSENT_FOREGROUND_GRACE_MS: number = 500;
const MAX_FRAME_WIDTH_PX: number = 1080;
const MICROPHONE_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const MIC_CAPTURE_INFO: audio.AudioCapturerInfo = { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 };

/** Capture observes the screen; its native workers never own playback, clocks or output calibration. */
export class RecordingCoordinator {
  private static initialized: boolean = false;
  private static context: Context | undefined = undefined;
  private static micPermissionRequested: boolean = false;
  private static initOperation: Promise<void> | undefined = undefined;
  private static startOperation: Promise<void> | undefined = undefined;
  private static stopOperation: Promise<RecordingClip | undefined> | undefined = undefined;
  private static saveOperation: Promise<RecordingClip | undefined> | undefined = undefined;
  private static nativeStopOperation: Promise<recordingNative.NativeCaptureResult> | undefined = undefined;
  private static nativeActive: boolean = false;
  private static target: RecordingTarget | undefined = undefined;
  private static state: RecordingState = 'idle';
  private static scope: RecordingScope = 'solo';
  private static elapsedMs: number = 0;
  private static amplitude: number = 0;
  private static error: string = '';
  private static saveFailureDetail: string = '';
  private static micMuted: boolean = false;
  private static builtInSpeakerCapture: boolean = false;
  private static lastClip: RecordingClip | undefined = undefined;
  private static pendingClip: RecordingClip | undefined = undefined;
  private static startedAtMonoMs: number = 0;
  private static captureStarted: boolean = false;
  private static pendingStopReason: string = '';
  private static frameWidth: number = 0;
  private static frameHeight: number = 0;
  private static routeEpoch: number = 0;
  private static generation: number = 0;
  private static peakTimer: number = -1;
  private static lastNativeState: number = -1;
  private static inputDevice: audio.AudioDeviceDescriptor | undefined = undefined;
  private static inputRouting: audio.AudioRoutingManager | undefined = undefined;
  private static listeners: RecordingListener[] = [];
  private static foreground: boolean = true;
  private static readonly inputChangeListener = (devices: audio.AudioDeviceDescriptors): void => {
    const input = RecordingCoordinator.inputDevice;
    if (input !== undefined && (devices.length !== 1 || devices[0].id !== input.id ||
      devices[0].deviceType !== audio.DeviceType.MIC)) {
      RecordingCoordinator.error = '麦克风输入已切换，录制已结束';
      void RecordingCoordinator.stop('microphone-route-change');
    }
  };

  static initialize(context: Context): Promise<void> {
    RecordingCoordinator.context = context;
    if (RecordingCoordinator.initialized) { return Promise.resolve(); }
    if (RecordingCoordinator.initOperation === undefined) {
      RecordingCoordinator.initOperation = RecordingRepository.initialize(context).then(async () => {
        const pending = await RecordingRepository.loadPendingCapture();
        if (pending !== undefined) {
          RecordingCoordinator.pendingClip = pending;
          RecordingCoordinator.target = { id: pending.id, path: pending.path, createdAt: pending.createdAt };
          RecordingCoordinator.scope = pending.scope ?? 'solo';
          RecordingCoordinator.elapsedMs = pending.durationMs;
          RecordingCoordinator.frameWidth = pending.width;
          RecordingCoordinator.frameHeight = pending.height;
          RecordingCoordinator.error = '上次录制尚未保存，原始音轨已保留';
          RecordingCoordinator.saveFailureDetail = pending.captureSyncValid === true ?
            '点击重试保存可继续处理' : '这段录制的同步校验未通过，请放弃后重新录制';
          RecordingCoordinator.setState('failed');
        }
        RecordingCoordinator.initialized = true;
      }).catch((err: Error) => { RecordingCoordinator.initOperation = undefined; throw err; });
    }
    return RecordingCoordinator.initOperation;
  }

  /** The waveform reads this snapshot only; raw PCM never crosses NAPI or enters UI timers. */
  static getSnapshot(): RecordingSnapshot {
    return {
      state: RecordingCoordinator.state, elapsedMs: RecordingCoordinator.elapsedMs,
      amplitude: RecordingCoordinator.amplitude, error: RecordingCoordinator.error,
      saveFailureDetail: RecordingCoordinator.saveFailureDetail,
      micMuted: RecordingCoordinator.micMuted, lastClip: RecordingCoordinator.lastClip,
      pendingClip: RecordingCoordinator.pendingClip
    };
  }

  static saveFailureNoticeText(snapshot?: RecordingSnapshot): string {
    const view = snapshot ?? RecordingCoordinator.getSnapshot();
    if (view.error.length === 0) {
      return view.saveFailureDetail;
    }
    if (view.saveFailureDetail.length === 0) {
      return view.error;
    }
    return `${view.error}（${view.saveFailureDetail}）`;
  }
  static subscribe(listener: RecordingListener): void {
    if (RecordingCoordinator.listeners.indexOf(listener) < 0) { RecordingCoordinator.listeners.push(listener); }
    listener(RecordingCoordinator.getSnapshot());
  }
  static unsubscribe(listener: RecordingListener): void {
    RecordingCoordinator.listeners = RecordingCoordinator.listeners.filter((item: RecordingListener) => item !== listener);
  }

  static async start(scope: RecordingScope = 'solo'): Promise<void> {
    if (RecordingCoordinator.initOperation !== undefined) { await RecordingCoordinator.initOperation; }
    if (RecordingCoordinator.pendingClip !== undefined) {
      throw new Error('上段视频的保存记录尚未完成，请先点击重试保存');
    }
    if (RecordingCoordinator.startOperation !== undefined) { return RecordingCoordinator.startOperation; }
    if (RecordingCoordinator.state === 'recording' || RecordingCoordinator.stopOperation !== undefined) { return; }
    const operation = RecordingCoordinator.startExclusive(scope);
    RecordingCoordinator.startOperation = operation;
    try { await operation; } finally {
      if (RecordingCoordinator.startOperation === operation) { RecordingCoordinator.startOperation = undefined; }
    }
    if (RecordingCoordinator.pendingStopReason.length > 0) {
      await RecordingCoordinator.stop(RecordingCoordinator.pendingStopReason);
    }
  }

  static stop(reason: string = 'user'): Promise<RecordingClip | undefined> {
    if (RecordingCoordinator.stopOperation !== undefined) { return RecordingCoordinator.stopOperation; }
    if (RecordingCoordinator.state === 'idle' || RecordingCoordinator.state === 'failed') { return Promise.resolve(undefined); }
    if (RecordingCoordinator.pendingStopReason.length === 0) { RecordingCoordinator.pendingStopReason = reason; }
    // Wake native consent waiting without doing any stop/release I/O on the UI thread.
    if (RecordingCoordinator.nativeActive) { recordingNative.cancel(); }
    const operation = RecordingCoordinator.stopExclusive();
    RecordingCoordinator.stopOperation = operation;
    return operation.finally(() => {
      if (RecordingCoordinator.stopOperation === operation) { RecordingCoordinator.stopOperation = undefined; }
    });
  }

  static handleBackground(): void {
    RecordingCoordinator.foreground = false;
    if (RecordingCoordinator.state === 'recording') { void RecordingCoordinator.stop('background'); }
  }
  static handleForeground(): void { RecordingCoordinator.foreground = true; }
  static handleRouteChange(): void {
    if ((RecordingCoordinator.state === 'preparing' || RecordingCoordinator.state === 'recording') &&
      (AppStorage.get<number>('audioOutputRouteEpoch') ?? 0) !== RecordingCoordinator.routeEpoch) {
      RecordingCoordinator.error = '声音输出已切换，录制已结束；请确认耳机后重新录制';
      void RecordingCoordinator.stop('route-change');
    }
  }
  static retrySave(): Promise<RecordingClip | undefined> {
    if (RecordingCoordinator.saveOperation !== undefined) { return RecordingCoordinator.saveOperation; }
    const clip = RecordingCoordinator.pendingClip;
    if (clip === undefined) { return Promise.resolve(undefined); }
    if (RecordingCoordinator.stopOperation !== undefined) {
      return Promise.reject(new Error('视频仍在结束处理中，请稍候再点重试保存'));
    }
    const operation = RecordingCoordinator.saveRetainedClip(clip);
    RecordingCoordinator.saveOperation = operation;
    return operation.finally(() => {
      if (RecordingCoordinator.saveOperation === operation) { RecordingCoordinator.saveOperation = undefined; }
    });
  }

  /** Only an explicit UI confirmation may discard an unindexed capture. */
  static async discardPending(): Promise<void> {
    if (RecordingCoordinator.saveOperation !== undefined || RecordingCoordinator.stopOperation !== undefined) {
      throw new Error('视频正在处理中，请稍后重试');
    }
    const clip = RecordingCoordinator.pendingClip;
    const target = RecordingCoordinator.target;
    if (clip === undefined) { return; }
    const stored = RecordingRepository.get(clip.id);
    if (stored !== undefined) {
      await RecordingRepository.clearPendingCapture(clip);
      RecordingCoordinator.pendingClip = undefined;
      RecordingCoordinator.target = undefined;
      RecordingCoordinator.lastClip = stored;
      RecordingCoordinator.error = '';
      RecordingCoordinator.saveFailureDetail = '';
      RecordingCoordinator.setState('idle');
      return;
    }
    if (target === undefined || target.id !== clip.id) { throw new Error('无法确认待清理的录制文件'); }
    RecordingCoordinator.setState('stopping');
    const processedMicPath = RecordingMixer.processedMicPath(RecordingCoordinator.micPath());
    const paths: string[] = [target.path, RecordingCoordinator.sourcePath(), RecordingCoordinator.innerPath(),
      RecordingCoordinator.micPath(), processedMicPath, `${processedMicPath}.tmp`,
      target.path.replace('.mp4', '.recovery.json')];
    try {
      for (const path of paths) { if (await fileIo.access(path)) { await fileIo.unlink(path); } }
      await RecordingRepository.clearPendingCapture(clip);
      RecordingCoordinator.pendingClip = undefined;
      RecordingCoordinator.target = undefined;
      RecordingCoordinator.error = '';
      RecordingCoordinator.saveFailureDetail = '';
      RecordingCoordinator.setState('idle');
    } catch (_) {
      RecordingCoordinator.error = '清理未完成，请稍后再试';
      RecordingCoordinator.setState('failed');
      throw new Error(RecordingCoordinator.error);
    }
  }

  private static sourcePath(): string { return RecordingCoordinator.target?.path.replace('.mp4', '-source.mp4') ?? ''; }
  private static innerPath(): string { return RecordingCoordinator.target?.path.replace('.mp4', '-inner.pcm') ?? ''; }
  private static micPath(): string { return RecordingCoordinator.target?.path.replace('.mp4', '-mic.pcm') ?? ''; }

  private static async startExclusive(scope: RecordingScope): Promise<void> {
    RecordingCoordinator.error = '';
    RecordingCoordinator.saveFailureDetail = '';
    RecordingCoordinator.lastClip = undefined;
    RecordingCoordinator.elapsedMs = 0;
    RecordingCoordinator.amplitude = 0;
    RecordingCoordinator.micMuted = false;
    RecordingCoordinator.builtInSpeakerCapture = AudioOutputMonitor.isBuiltInSpeakerActive();
    RecordingCoordinator.captureStarted = false;
    RecordingCoordinator.pendingStopReason = '';
    RecordingCoordinator.nativeStopOperation = undefined;
    RecordingCoordinator.lastNativeState = -1;
    RecordingCoordinator.scope = scope;
    RecordingCoordinator.routeEpoch = AppStorage.get<number>('audioOutputRouteEpoch') ?? 0;
    ++RecordingCoordinator.generation;
    RecordingCoordinator.setState('preparing');
    try {
      if (RecordingCoordinator.initOperation !== undefined) { await RecordingCoordinator.initOperation; }
      if (!RecordingCoordinator.initialized) { throw new Error('录制尚未准备好，请稍后重试'); }
      if (!canIUse('SystemCapability.Multimedia.Media.AVScreenCapture')) {
        throw new Error('当前设备不支持画面与麦克风同时录制');
      }
      await RecordingCoordinator.ensureMicrophonePermission();
      RecordingCoordinator.inputDevice = await RecordingCoordinator.requirePhoneMicrophone();
      RecordingCoordinator.inputRouting = audio.getAudioManager().getRoutingManager();
      RecordingCoordinator.inputRouting.on('preferredInputDeviceChangeForCapturerInfo',
        MIC_CAPTURE_INFO, RecordingCoordinator.inputChangeListener);
      const screen = display.getDefaultDisplaySync();
      const scale = Math.min(1, MAX_FRAME_WIDTH_PX / screen.width);
      RecordingCoordinator.frameWidth = Math.max(2, Math.floor(screen.width * scale / 2) * 2);
      RecordingCoordinator.frameHeight = Math.max(2, Math.floor(screen.height * scale / 2) * 2);
      RecordingCoordinator.target = await RecordingRepository.createTarget();
      await SessionBackgroundKeeper.setRecordingActive(true);
      if (RecordingCoordinator.pendingStopReason.length === 0) {
        RecordingCoordinator.nativeActive = true;
        const operation = recordingNative.start({
          videoPath: RecordingCoordinator.sourcePath(), innerPath: RecordingCoordinator.innerPath(),
          micPath: RecordingCoordinator.micPath(), width: RecordingCoordinator.frameWidth,
          height: RecordingCoordinator.frameHeight
        });
        RecordingCoordinator.schedulePeakRead();
        await operation;
        if (RecordingCoordinator.pendingStopReason.length === 0) {
          RecordingCoordinator.markStarted();
          const input = await RecordingCoordinator.requirePhoneMicrophone();
          if (input.id !== RecordingCoordinator.inputDevice.id) { throw new Error('麦克风输入已切换，请重新录制'); }
          RecordingCoordinator.handleRouteChange();
        }
      }
    } catch (err) {
      if (RecordingCoordinator.captureStarted) {
        RecordingCoordinator.error = (err as Error).message;
        RecordingCoordinator.pendingStopReason = 'capture-error';
        return;
      }
      await RecordingCoordinator.releaseCapture();
      await RecordingCoordinator.discardTarget();
      RecordingCoordinator.error = RecordingCoordinator.pendingStopReason === 'cancelled' ? '已取消录制' :
        (err as Error).message || '无法开始录制，请稍后重试';
      RecordingCoordinator.setState('failed');
      throw new Error(RecordingCoordinator.error);
    }
  }

  private static markStarted(): void {
    if (RecordingCoordinator.captureStarted || RecordingCoordinator.pendingStopReason.length > 0) { return; }
    RecordingCoordinator.captureStarted = true;
    RecordingCoordinator.startedAtMonoMs = MonotonicClock.nowMs();
    RecordingCoordinator.setState('recording');
  }

  private static async stopExclusive(): Promise<RecordingClip | undefined> {
    const starting = RecordingCoordinator.startOperation;
    if (starting !== undefined) { try { await starting; } catch (_) { return undefined; } }
    RecordingCoordinator.setState('stopping');
    const result = await RecordingCoordinator.releaseCapture();
    const innerLeadUs = result.innerOffsetUs - result.micOffsetUs;
    console.info(`[RecordingTime] mapping=${result.timestampMappingVersion ?? 0} divisor=${result.videoTimestampDivisor ?? 0}` +
      ` videoFirstUs=${result.videoFirstPtsUs ?? -1} videoLastUs=${result.videoLastPtsUs ?? -1}` +
      ` micFirstUs=${result.micFirstPtsUs ?? -1} innerFirstUs=${result.innerFirstPtsUs ?? -1}` +
      ` micOffsetUs=${result.micOffsetUs} innerOffsetUs=${result.innerOffsetUs} innerLeadUs=${innerLeadUs}` +
      ` builtInSpeaker=${RecordingCoordinator.builtInSpeakerCapture}` +
      ` durationMs=${result.durationMs} syncValid=${result.syncValid}`);
    const target = RecordingCoordinator.target;
    if (target === undefined || result.durationMs <= 0) {
      await RecordingCoordinator.discardTarget();
      if (RecordingCoordinator.error.length === 0) { RecordingCoordinator.error = '视频未生成，请重新录制'; }
      RecordingCoordinator.setState('failed');
      return undefined;
    }
    RecordingCoordinator.elapsedMs = result.durationMs;
    const reason = RecordingCoordinator.pendingStopReason || 'user';
    const clip: RecordingClip = {
      id: target.id, path: target.path, createdAt: target.createdAt, durationMs: result.durationMs,
      width: RecordingCoordinator.frameWidth, height: RecordingCoordinator.frameHeight,
      interrupted: reason !== 'user', stopReason: reason, scope: RecordingCoordinator.scope,
      sourcePath: RecordingCoordinator.sourcePath(), innerPath: RecordingCoordinator.innerPath(),
      micPath: RecordingCoordinator.micPath(), micOffsetUs: result.micOffsetUs, innerOffsetUs: result.innerOffsetUs,
      audioSampleRate: 48000, audioChannels: 2, renderedGain: 1, renderedMicShiftUs: 0,
      renderedMixVersion: 0, renderedAt: Date.now(),
      captureSyncValid: result.syncValid && result.timestampMappingVersion === 2 &&
        (result.videoTimestampDivisor === 1 || result.videoTimestampDivisor === 1000),
      captureMappingVersion: result.timestampMappingVersion ?? 0,
      videoTimestampDivisor: result.videoTimestampDivisor ?? 0,
      builtInSpeakerCapture: RecordingCoordinator.builtInSpeakerCapture
    };
    RecordingCoordinator.pendingClip = clip;
    RecordingCoordinator.saveFailureDetail = '';
    try {
      return await RecordingCoordinator.saveRetainedClip(clip);
    } catch (_error) {
      return undefined;
    }
  }

  private static async saveRetainedClip(clip: RecordingClip): Promise<RecordingClip | undefined> {
    RecordingCoordinator.setState('stopping');
    RecordingCoordinator.saveFailureDetail = '';
    try {
      await RecordingRepository.retainPendingCapture(clip);
    } catch (err) {
      RecordingCoordinator.noteSaveFailure('metadata', err);
      RecordingCoordinator.setState('failed');
      throw new Error(RecordingCoordinator.saveFailureNoticeText());
    }
    try {
      RecordingMixer.validateCaptureTiming(clip);
    } catch (err) {
      RecordingCoordinator.error = '设备录屏时间戳不兼容，原始音轨已保留';
      RecordingCoordinator.saveFailureDetail = '这段录制的同步校验未通过，请放弃后重新录制';
      RecordingCoordinator.setState('failed');
      throw new Error(RecordingCoordinator.saveFailureNoticeText());
    }
    let rendered: boolean = false;
    if (await fileIo.access(clip.path)) {
      const stat = await fileIo.stat(clip.path);
      rendered = stat.isFile() && stat.size > 0 &&
        (clip.renderedMixVersion ?? 0) >= RECORDING_MIX_VERSION &&
        clip.autoMicShiftUs !== undefined && clip.autoMicShiftConfidence !== undefined &&
        clip.autoMicShiftReliable !== undefined;
    }
    if (!rendered) {
      try {
        const mixResult = await RecordingMixer.exportMixed(clip, 1, clip.path);
        clip.autoMicShiftUs = mixResult.autoMicShiftUs;
        clip.autoMicShiftConfidence = mixResult.autoMicShiftConfidence;
        clip.autoMicShiftReliable = mixResult.autoMicShiftReliable;
        clip.renderedMixVersion = RECORDING_MIX_VERSION;
        clip.renderedAt = Date.now();
        // A crash after export must restore the same automatic baseline instead
        // of fitting again against an already-created sidecar without metadata.
        await RecordingRepository.retainPendingCapture(clip);
      } catch (err) {
        RecordingCoordinator.noteSaveFailure('encode', err);
        RecordingCoordinator.setState('failed');
        throw new Error(RecordingCoordinator.saveFailureNoticeText());
      }
    }
    try {
      await RecordingRepository.add(clip);
    } catch (err) {
      RecordingCoordinator.noteSaveFailure('library', err);
      RecordingCoordinator.setState('failed');
      throw new Error(RecordingCoordinator.saveFailureNoticeText());
    }
    try { await RecordingRepository.clearPendingCapture(clip); } catch (_error) {
      // Indexing already committed. A stale capture note is removed at next restore,
      // and must never turn a successfully saved work into a failed recording.
      console.warn('Saved recording capture metadata cleanup deferred');
    }
    RecordingCoordinator.pendingClip = undefined;
    RecordingCoordinator.lastClip = clip;
    RecordingCoordinator.target = undefined;
    RecordingCoordinator.error = '';
    RecordingCoordinator.saveFailureDetail = '';
    RecordingCoordinator.setState('idle');
    return clip;
  }

  private static noteSaveFailure(phase: 'metadata' | 'encode' | 'library', err: Object): void {
    RecordingCoordinator.saveFailureDetail = RecordingCoordinator.errorDetailFrom(err);
    RecordingCoordinator.error = phase === 'metadata' ? '原始音轨已保留，保存恢复记录失败' : phase === 'encode' ?
      '原始音轨已保留，合成成品视频失败' : '成品视频已生成，写入作品列表失败';
  }

  private static errorDetailFrom(err: Object): string {
    if (err instanceof Error) {
      const message = err.message.trim();
      if (message.length > 0) {
        return message.length > 160 ? `${message.slice(0, 160)}…` : message;
      }
    }
    return '请稍后重试；若仍失败可放弃这段后重新录制';
  }

  private static async requirePhoneMicrophone(): Promise<audio.AudioDeviceDescriptor> {
    const inputs = await audio.getAudioManager().getRoutingManager().getPreferredInputDeviceForCapturerInfo(MIC_CAPTURE_INFO);
    if (inputs.length !== 1 || inputs[0].deviceType !== audio.DeviceType.MIC) {
      throw new Error('请使用手机麦克风录制；当前麦克风路由不可用');
    }
    return inputs[0];
  }
  private static async ensureMicrophonePermission(): Promise<void> {
    const context = RecordingCoordinator.context;
    if (context === undefined) { throw new Error('录制尚未准备好，请稍后重试'); }
    const manager = abilityAccessCtrl.createAtManager();
    const granted = abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    if (await manager.checkAccessToken(context.applicationInfo.accessTokenId, MICROPHONE_PERMISSION) === granted) { return; }
    if (!RecordingCoordinator.micPermissionRequested) {
      RecordingCoordinator.micPermissionRequested = true;
      const result = await manager.requestPermissionsFromUser(context, [MICROPHONE_PERMISSION]);
      if (result.authResults.length === 1 && result.authResults[0] === granted) { return; }
    }
    throw new Error('录制需要麦克风权限，请在系统设置中为 oneBeat 开启后重试');
  }

  private static schedulePeakRead(): void {
    const generation = RecordingCoordinator.generation;
    RecordingCoordinator.peakTimer = setTimeout(() => {
      RecordingCoordinator.peakTimer = -1;
      RecordingCoordinator.readPeak(generation);
    }, INPUT_PEAK_INTERVAL_MS);
  }
  private static readPeak(generation: number): void {
    if (generation !== RecordingCoordinator.generation || !RecordingCoordinator.nativeActive) { return; }
    const snapshot = recordingNative.getStatus();
    if (snapshot.stateCode !== RecordingCoordinator.lastNativeState) {
      RecordingCoordinator.lastNativeState = snapshot.stateCode;
      if (snapshot.stateCode === 0) { RecordingCoordinator.markStarted(); }
      else if (snapshot.stateCode === 6 || snapshot.stateCode === 7) {
        RecordingCoordinator.micMuted = snapshot.stateCode === 6;
        RecordingCoordinator.notify();
      } else if (snapshot.stateCode > 0) {
        RecordingCoordinator.error = snapshot.stateCode === 1 ? '已取消录制' :
          snapshot.stateCode === 5 ? '麦克风不可用，录制已结束' : '系统已结束录制，练习仍可继续';
        void RecordingCoordinator.stop(snapshot.stateCode === 1 ? 'cancelled' : 'system-interruption');
      }
    }
    if (snapshot.error.length > 0) {
      RecordingCoordinator.error = snapshot.error;
      void RecordingCoordinator.stop('capture-error');
    }
    RecordingCoordinator.amplitude = RecordingCoordinator.micMuted ? 0 : Math.min(1, Math.max(0, snapshot.amplitude));
    if (RecordingCoordinator.captureStarted) {
      const previousSecond = Math.floor(RecordingCoordinator.elapsedMs / 1000);
      RecordingCoordinator.elapsedMs = Math.max(0, MonotonicClock.nowMs() - RecordingCoordinator.startedAtMonoMs);
      if (Math.floor(RecordingCoordinator.elapsedMs / 1000) !== previousSecond) { RecordingCoordinator.notify(); }
      if (!RecordingCoordinator.foreground && RecordingCoordinator.elapsedMs >= CONSENT_FOREGROUND_GRACE_MS) {
        void RecordingCoordinator.stop('background');
      }
    }
    RecordingCoordinator.handleRouteChange();
    if (RecordingCoordinator.pendingStopReason.length === 0 && RecordingCoordinator.nativeActive) {
      RecordingCoordinator.schedulePeakRead();
    }
  }

  private static async releaseCapture(): Promise<recordingNative.NativeCaptureResult> {
    if (RecordingCoordinator.peakTimer >= 0) { clearTimeout(RecordingCoordinator.peakTimer); RecordingCoordinator.peakTimer = -1; }
    ++RecordingCoordinator.generation;
    RecordingCoordinator.amplitude = 0;
    let result: recordingNative.NativeCaptureResult = { durationMs: 0, micOffsetUs: 0, innerOffsetUs: 0, syncValid: true };
    if (RecordingCoordinator.nativeActive) {
      if (RecordingCoordinator.nativeStopOperation === undefined) { RecordingCoordinator.nativeStopOperation = recordingNative.stop(); }
      try { result = await RecordingCoordinator.nativeStopOperation; } catch (err) {
        RecordingCoordinator.error = (err as Error).message || '系统录制结束失败';
      }
      RecordingCoordinator.nativeActive = false;
    }
    const routing = RecordingCoordinator.inputRouting;
    RecordingCoordinator.inputRouting = undefined;
    RecordingCoordinator.inputDevice = undefined;
    if (routing !== undefined) {
      try { routing.off('preferredInputDeviceChangeForCapturerInfo', RecordingCoordinator.inputChangeListener); } catch (_) {}
    }
    try { await SessionBackgroundKeeper.setRecordingActive(false); } catch (_) {
      console.warn('Recording background task release failed');
    }
    return result;
  }
  private static async discardTarget(): Promise<void> {
    const target = RecordingCoordinator.target;
    const paths: string[] = [target?.path ?? '', RecordingCoordinator.sourcePath(),
      RecordingCoordinator.innerPath(), RecordingCoordinator.micPath()];
    RecordingCoordinator.target = undefined;
    for (const path of paths) {
      if (path.length > 0) { try { await fileIo.unlink(path); } catch (_) {} }
    }
  }
  private static setState(state: RecordingState): void { RecordingCoordinator.state = state; RecordingCoordinator.notify(); }
  private static notify(): void {
    const snapshot = RecordingCoordinator.getSnapshot();
    RecordingCoordinator.listeners.forEach((listener: RecordingListener) => {
      try { listener(snapshot); } catch (_) { console.warn('Recording listener failed'); }
    });
  }
}
