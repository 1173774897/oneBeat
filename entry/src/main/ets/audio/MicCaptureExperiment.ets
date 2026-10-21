import { audio } from '@kit.AudioKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MonotonicClock } from '../common/MonotonicClock';
import { analyzeMicCaptureClock, MicCaptureClockAnchor, MicCaptureClockReport } from './MicCaptureExperimentAnalysis';

const EXPERIMENT_DIRECTORY: string = 'mic-capture-experiment';
const SAMPLE_RATE: number = 48000;
const MAX_DURATION_MS: number = 10000;
const OBSERVATION_INTERVAL_MS: number = 100;
const MAX_SNAPSHOTS: number = 140;

export type MicExperimentSource = 'mic' | 'live';

export interface MicExperimentCapability {
  apiVersion: number;
  liveAvailable: boolean;
  liveAecSupported: boolean;
  micAecSupported: boolean;
  reason: string;
}

export interface MicExperimentDevice {
  type: number;
  role: number;
}

export interface MicExperimentSnapshot {
  elapsedMs: number;
  value: string;
  stage?: string;
}

export interface MicExperimentStageTiming {
  source: MicExperimentSource;
  stage: string;
  startedAtMonoMs: number;
  durationMs: number;
  beforeSnapshotIndex: number;
  afterSnapshotIndex: number;
  error: string;
}

/** Delivery timing exposes callback batching only; it is never a microphone sample timestamp. */
export interface MicExperimentChunk {
  firstFrame: number;
  frameCount: number;
  deliveryElapsedMs: number;
  callbackGapMs: number;
}

/** Snapshot must contain only numeric engine/route diagnostics, never names or addresses; throwing aborts the run. */
export interface MicExperimentObserver {
  onProgress?: (elapsedMs: number, level: number, frames: number) => void;
  snapshot?: () => string;
  onStage?: (timing: MicExperimentStageTiming) => void;
}

/** AEC capability is advertised system support, not a claim that every acoustic echo was removed. */
export interface MicExperimentResult {
  source: MicExperimentSource;
  wavPath: string;
  reportPath: string;
  sampleRate: number;
  channels: number;
  durationMs: number;
  totalFrames: number;
  peak: number;
  clippedSamples: number;
  aecSupported: boolean;
  devices: MicExperimentDevice[];
  anchors: MicCaptureClockAnchor[];
  clockMetrics: MicCaptureClockReport;
  timestampReadFailures: number;
  overflowCount: number;
  snapshots: MicExperimentSnapshot[];
  chunks: MicExperimentChunk[];
  chunkCount: number;
  chunkObservationsDropped: number;
  stageTimings: MicExperimentStageTiming[];
}

class MicExperimentRun {
  source: MicExperimentSource = 'mic';
  cancelled: boolean = false;
  accepting: boolean = false;
  started: boolean = false;
  error: Error | undefined = undefined;
  capturer: audio.AudioCapturer | undefined = undefined;
  pcm: Uint8Array = new Uint8Array(0);
  byteLength: number = 0;
  channels: number = 1;
  sampleRate: number = SAMPLE_RATE;
  targetFrames: number = 0;
  peak: number = 0;
  lastLevel: number = 0;
  clippedSamples: number = 0;
  startedAtMs: number = 0;
  anchors: MicCaptureClockAnchor[] = [];
  snapshots: MicExperimentSnapshot[] = [];
  timestampReadFailures: number = 0;
  intervalId: number = -1;
  timeoutId: number = -1;
  complete: () => void = (): void => {};
  chunks: MicExperimentChunk[] = [];
  chunkCount: number = 0;
  lastDeliveryMs: number = -1;
  stageTimings: MicExperimentStageTiming[] = [];
}

/** Isolated short capture only: it never changes renderer, output route, audio scene, or calibration. */
export class MicCaptureExperiment {
  private static owner: MicCaptureExperiment | undefined = undefined;
  private static releaseBlocked: boolean = false;
  private current: MicExperimentRun | undefined = undefined;
  private task: Promise<MicExperimentResult> | undefined = undefined;
  private ownedDirectory: string = '';

  static capability(): MicExperimentCapability {
    const version = deviceInfo.sdkApiVersion;
    const result: MicExperimentCapability = {
      apiVersion: version, liveAvailable: false, liveAecSupported: false, micAecSupported: false,
      reason: 'LIVE 回声消除需要 API 20 及以上系统'
    };
    if (version < 20) { return result; }
    try {
      const manager = audio.getAudioManager().getStreamManager();
      result.liveAecSupported = manager.isAcousticEchoCancelerSupported(audio.SourceType.SOURCE_TYPE_LIVE);
      result.liveAvailable = result.liveAecSupported;
      result.reason = result.liveAecSupported ? '' : '本机未声明支持 LIVE 回声消除，无法进行 AEC 对比';
      try { result.micAecSupported = manager.isAcousticEchoCancelerSupported(audio.SourceType.SOURCE_TYPE_MIC); }
      catch (_micError) { /* MIC capability is optional; it must not turn a confirmed LIVE result into a false rejection. */ }
    } catch (_error) {
      result.liveAvailable = false;
      result.liveAecSupported = false;
      result.reason = '本机无法查询 LIVE 回声消除能力，已停用此实验';
    }
    return result;
  }

  run(filesDir: string, source: MicExperimentSource, observer?: MicExperimentObserver,
    durationMs: number = MAX_DURATION_MS): Promise<MicExperimentResult> {
    if (MicCaptureExperiment.owner !== undefined) { return Promise.reject(new Error('已有麦克风实验正在运行')); }
    if (MicCaptureExperiment.releaseBlocked) {
      return Promise.reject(new Error('麦克风资源未能释放，请重启应用后再试'));
    }
    if (source !== 'mic' && source !== 'live') { return Promise.reject(new Error('未知的麦克风实验类型')); }
    if (!Number.isFinite(durationMs) || durationMs < 500 || durationMs > MAX_DURATION_MS) {
      return Promise.reject(new Error('实验时长需在 0.5 至 10 秒之间'));
    }
    const capability = MicCaptureExperiment.capability();
    if (source === 'live' && !capability.liveAvailable) { return Promise.reject(new Error(capability.reason)); }
    const state = new MicExperimentRun();
    state.source = source;
    this.current = state;
    MicCaptureExperiment.owner = this;
    const task = this.perform(filesDir, source, state, durationMs, capability, observer).finally((): void => {
      if (this.current === state) { this.current = undefined; }
      if (this.task === task) { this.task = undefined; }
      if (MicCaptureExperiment.owner === this) { MicCaptureExperiment.owner = undefined; }
    });
    this.task = task;
    return task;
  }

  /** Cancellation stays attached to this run until all creation/start/write awaits have unwound. */
  cancel(): void {
    const state = this.current;
    if (state === undefined) { return; }
    state.cancelled = true;
    this.finish(state, new Error('麦克风实验已取消'));
  }

  async clear(filesDir: string): Promise<void> {
    if (MicCaptureExperiment.owner !== undefined && MicCaptureExperiment.owner !== this) {
      throw new Error('请先结束正在运行的麦克风实验');
    }
    this.cancel();
    try { await this.task; } catch (_error) {}
    if (MicCaptureExperiment.owner !== undefined) { throw new Error('请先结束正在运行的麦克风实验'); }
    MicCaptureExperiment.owner = this;
    try {
      const directory = this.directory(filesDir);
      this.ownedDirectory = directory;
      for (const source of ['mic', 'live']) {
        for (const suffix of ['wav', 'json', 'wav.tmp', 'json.tmp']) {
          await this.unlinkOwned(`${directory}/${source}.${suffix}`);
        }
      }
    } finally { MicCaptureExperiment.owner = undefined; }
  }

  async removeResult(result: MicExperimentResult): Promise<void> {
    if (MicCaptureExperiment.owner !== undefined) { throw new Error('请先结束正在运行的麦克风实验'); }
    // Results are not deletion capabilities: only the fixed experiment subdirectory and names are removable.
    if (this.ownedDirectory.length === 0 || (result.source !== 'mic' && result.source !== 'live') ||
      result.wavPath !== `${this.ownedDirectory}/${result.source}.wav` ||
      result.reportPath !== result.wavPath.slice(0, -4) + '.json') {
      throw new Error('不是本机实验文件');
    }
    MicCaptureExperiment.owner = this;
    try {
      await this.unlinkOwned(result.wavPath);
      await this.unlinkOwned(result.reportPath);
    } finally { MicCaptureExperiment.owner = undefined; }
  }

  private directory(filesDir: string): string {
    if (!filesDir.startsWith('/') || filesDir.includes('/../') || filesDir.includes('/./') || filesDir.endsWith('/..')) {
      throw new Error('实验目录无效');
    }
    return `${filesDir}/${EXPERIMENT_DIRECTORY}`;
  }

  private check(state: MicExperimentRun): void {
    if (state.error !== undefined) { throw state.error; }
    if (state.cancelled || this.current !== state) { throw new Error('麦克风实验已取消'); }
  }

  private finish(state: MicExperimentRun, error?: Error): void {
    state.accepting = false;
    if (error !== undefined && state.error === undefined) { state.error = error; }
    state.complete();
  }

  private async create(state: MicExperimentRun, source: MicExperimentSource): Promise<audio.AudioCapturer> {
    const sourceType = source === 'live' ? audio.SourceType.SOURCE_TYPE_LIVE : audio.SourceType.SOURCE_TYPE_MIC;
    for (const channel of [audio.AudioChannel.CHANNEL_1, audio.AudioChannel.CHANNEL_2]) {
      this.check(state);
      try {
        return await audio.createAudioCapturer({
          streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000, channels: channel,
            sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
          capturerInfo: { source: sourceType, capturerFlags: 0 }
        });
      } catch (error) {
        this.check(state);
        if (channel === audio.AudioChannel.CHANNEL_2) { throw error as Error; }
      }
    }
    throw new Error('无法创建 48kHz 麦克风采集');
  }

  private append(state: MicExperimentRun, buffer: ArrayBuffer): void {
    if (!state.accepting || state.cancelled || this.current !== state) { return; }
    const frameBytes = state.channels * 2;
    if (buffer.byteLength === 0) { return; }
    if (buffer.byteLength % frameBytes !== 0 || state.byteLength + buffer.byteLength > state.pcm.byteLength) {
      this.finish(state, new Error('麦克风分块格式或大小异常，实验已停止'));
      return;
    }
    // Preserve every complete callback byte verbatim. The 0.5 s headroom bounds the final whole chunk;
    // it is never padded, cropped, shifted, or resampled to make the timestamps appear aligned.
    state.pcm.set(new Uint8Array(buffer), state.byteLength);
    const nowMs = MonotonicClock.nowMs();
    if (state.chunks.length < 1400) {
      state.chunks.push({ firstFrame: state.byteLength / frameBytes, frameCount: buffer.byteLength / frameBytes,
        deliveryElapsedMs: nowMs - state.startedAtMs,
        callbackGapMs: state.lastDeliveryMs < 0 ? 0 : nowMs - state.lastDeliveryMs });
    }
    state.chunkCount += 1;
    state.lastDeliveryMs = nowMs;
    state.byteLength += buffer.byteLength;
    const view = new DataView(buffer);
    let level = 0;
    for (let offset = 0; offset < buffer.byteLength; offset += 2) {
      const sample = view.getInt16(offset, true);
      level = Math.max(level, Math.abs(sample) / 32768);
      if (sample <= -32768 || sample >= 32767) { state.clippedSamples += 1; }
    }
    state.lastLevel = level;
    state.peak = Math.max(state.peak, level);
    if (state.byteLength / frameBytes >= state.targetFrames) { this.finish(state); }
  }

  private observe(state: MicExperimentRun, observer?: MicExperimentObserver): void {
    this.check(state);
    const elapsedMs = Math.max(0, MonotonicClock.nowMs() - state.startedAtMs);
    if (state.capturer !== undefined && deviceInfo.sdkApiVersion >= 19) {
      try {
        const clock = state.capturer.getAudioTimestampInfoSync();
        if (state.anchors.length < MAX_SNAPSHOTS) {
          state.anchors.push({ framePosition: clock.framePos, timestampNs: clock.timestamp,
            receivedFrames: state.byteLength / (state.channels * 2) });
        }
      } catch (_error) { state.timestampReadFailures += 1; }
    }
    if (observer?.snapshot !== undefined && state.snapshots.length < MAX_SNAPSHOTS) {
      state.snapshots.push({ elapsedMs: elapsedMs, value: observer.snapshot().slice(0, 4096) });
    }
    observer?.onProgress?.(elapsedMs, state.lastLevel, state.byteLength / (state.channels * 2));
  }

  private stageSnapshot(state: MicExperimentRun, stage: string, observer?: MicExperimentObserver): number {
    // Cleanup may outlive page visibility or a failed playback guard. Do not call that guard again.
    if (state.cancelled || state.error !== undefined || this.current !== state || observer?.snapshot === undefined) {
      return -1;
    }
    const value = observer.snapshot().slice(0, 4096);
    this.check(state);
    if (state.snapshots.length >= MAX_SNAPSHOTS) { return -1; }
    const index = state.snapshots.length;
    state.snapshots.push({ elapsedMs: Math.max(0, MonotonicClock.nowMs() - state.startedAtMs),
      value: value, stage: stage });
    return index;
  }

  private async stage<T>(state: MicExperimentRun, name: string, observer: MicExperimentObserver | undefined,
    operation: () => Promise<T>, cleanup: boolean = false): Promise<T> {
    const timing: MicExperimentStageTiming = {
      source: state.source, stage: name, startedAtMonoMs: MonotonicClock.nowMs(), durationMs: 0,
      beforeSnapshotIndex: -1, afterSnapshotIndex: -1, error: ''
    };
    try {
      try { timing.beforeSnapshotIndex = this.stageSnapshot(state, `${name}-before`, observer); }
      catch (error) { this.finish(state, error as Error); }
      if (!cleanup) { this.check(state); }
      // Native stop/release must still execute when a stage observer reports output damage.
      const result = await operation();
      timing.afterSnapshotIndex = this.stageSnapshot(state, `${name}-after`, observer);
      this.check(state);
      return result;
    } catch (error) {
      const failure = state.error ?? error as Error;
      this.finish(state, failure);
      throw failure;
    } finally {
      timing.durationMs = Math.max(0, MonotonicClock.nowMs() - timing.startedAtMonoMs);
      timing.error = state.error?.message ?? '';
      state.stageTimings.push(timing);
      // Deliver timing even when the guard rejected the stage, so summary.json can identify
      // the first damaged boundary. Diagnostics must never replace the original failure.
      try { observer?.onStage?.(timing); }
      catch (error) {
        if (state.error === undefined) {
          const diagnosticError = error as Error;
          this.finish(state, diagnosticError);
          timing.error = diagnosticError.message;
          throw diagnosticError;
        }
      }
    }
  }

  private async perform(filesDir: string, source: MicExperimentSource, state: MicExperimentRun, durationMs: number,
    capability: MicExperimentCapability, observer?: MicExperimentObserver): Promise<MicExperimentResult> {
    const directory = this.directory(filesDir);
    this.ownedDirectory = directory;
    const wavPath = `${directory}/${source}.wav`;
    const reportPath = `${directory}/${source}.json`;
    let committed = false;
    try {
      if (!await fs.access(directory)) { await fs.mkdir(directory, true); }
      this.check(state);
      state.startedAtMs = MonotonicClock.nowMs();
      if (observer?.snapshot !== undefined) {
        state.snapshots.push({ elapsedMs: 0, value: observer.snapshot().slice(0, 4096) });
      }
      const capturer = await this.create(state, source);
      state.capturer = capturer;
      this.check(state);
      const info = await capturer.getStreamInfo();
      this.check(state);
      if (info.samplingRate !== SAMPLE_RATE || (info.channels !== 1 && info.channels !== 2) ||
        info.sampleFormat !== audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE ||
        info.encodingType !== audio.AudioEncodingType.ENCODING_TYPE_RAW) {
        throw new Error('本机未提供实验要求的 48kHz PCM16 麦克风输入');
      }
      const sourceInfo = await capturer.getCapturerInfo();
      this.check(state);
      const expectedSource = source === 'live' ? audio.SourceType.SOURCE_TYPE_LIVE : audio.SourceType.SOURCE_TYPE_MIC;
      if (sourceInfo.source !== expectedSource) { throw new Error('系统实际麦克风类型与实验不符'); }
      state.sampleRate = info.samplingRate;
      state.channels = info.channels;
      state.targetFrames = Math.ceil(durationMs * info.samplingRate / 1000);
      state.pcm = new Uint8Array(Math.ceil((durationMs + 500) * info.samplingRate / 1000) * info.channels * 2);
      const completed = new Promise<void>((resolve: () => void): void => { state.complete = resolve; });
      capturer.on('readData', (buffer: ArrayBuffer): void => { this.append(state, buffer); });
      capturer.on('inputDeviceChange', (): void => { this.finish(state, new Error('输入设备发生变化，实验已停止')); });
      capturer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
          this.finish(state, new Error('麦克风被系统中断，实验已停止'));
        }
      });
      state.accepting = true;
      state.startedAtMs = MonotonicClock.nowMs();
      await capturer.start();
      state.started = true;
      this.check(state);
      const devices = capturer.getCurrentInputDevices().map((device: audio.AudioDeviceDescriptor): MicExperimentDevice => {
        return { type: device.deviceType, role: device.deviceRole };
      });
      this.observe(state, observer);
      state.intervalId = setInterval((): void => {
        try { this.observe(state, observer); }
        catch (error) { this.finish(state, error as Error); }
      }, OBSERVATION_INTERVAL_MS);
      state.timeoutId = setTimeout((): void => {
        this.finish(state, new Error('麦克风未在预期时间内收到足够音频，请重试'));
      }, durationMs + 2500);
      await completed;
      this.check(state);
      this.observe(state, observer);
      let overflowCount = -1;
      try { overflowCount = capturer.getOverflowCountSync(); } catch (_error) {}
      await this.release(state, observer);
      this.check(state);
      // Only the observation stopwatch uses callback-independent wall time. Audio duration and WAV
      // framing use delivered PCM frames; hardware anchors remain raw diagnostics, never playback offsets.
      const totalFrames = state.byteLength / (state.channels * 2);
      const clockMetrics = await this.stage<MicCaptureClockReport>(state, 'clock-analysis', observer,
        (): Promise<MicCaptureClockReport> => Promise.resolve(analyzeMicCaptureClock(state.anchors, state.sampleRate)));
      const result: MicExperimentResult = {
        source: source, wavPath: wavPath, reportPath: reportPath, sampleRate: state.sampleRate,
        channels: state.channels, durationMs: totalFrames * 1000 / state.sampleRate, totalFrames: totalFrames,
        peak: state.peak, clippedSamples: state.clippedSamples,
        aecSupported: source === 'live' ? capability.liveAecSupported : capability.micAecSupported,
        devices: devices, anchors: state.anchors, clockMetrics: clockMetrics,
        timestampReadFailures: state.timestampReadFailures, overflowCount: overflowCount, snapshots: state.snapshots,
        chunks: state.chunks, chunkCount: state.chunkCount, chunkObservationsDropped: state.chunkCount - state.chunks.length,
        stageTimings: state.stageTimings
      };
      const wav = await this.stage<ArrayBuffer>(state, 'wav-pack', observer,
        (): Promise<ArrayBuffer> => Promise.resolve(this.wav(state)));
      await this.stage<void>(state, 'wav-write', observer, (): Promise<void> => this.writeFile(`${wavPath}.tmp`, wav));
      this.check(state);
      // A report cannot contain the completion of its own serialization/write/rename. onStage
      // streams those final timings to the page summary; the returned result retains the full array.
      const encoded = await this.stage<ArrayBuffer>(state, 'report-encode', observer,
        (): Promise<ArrayBuffer> => Promise.resolve(new util.TextEncoder().encodeInto(JSON.stringify(result)).buffer as ArrayBuffer));
      await this.stage<void>(state, 'report-write', observer,
        (): Promise<void> => this.writeFile(`${reportPath}.tmp`, encoded));
      this.check(state);
      // Fixed names keep at most the newest MIC and LIVE samples; private files never enter the album/share repository.
      await this.stage<void>(state, 'rename-wav', observer, (): Promise<void> => fs.rename(`${wavPath}.tmp`, wavPath));
      this.check(state);
      await this.stage<void>(state, 'rename-report', observer,
        (): Promise<void> => fs.rename(`${reportPath}.tmp`, reportPath));
      this.check(state);
      committed = true;
      return result;
    } catch (error) {
      this.finish(state, error as Error);
      throw state.error as Error;
    } finally {
      try { await this.release(state, observer); }
      finally {
        try {
          await this.unlinkOwned(`${wavPath}.tmp`);
          await this.unlinkOwned(`${reportPath}.tmp`);
          if (!committed) {
            // A cancelled write must not leave a new WAV paired with an older successful report.
            await this.unlinkOwned(wavPath);
            await this.unlinkOwned(reportPath);
          }
        } finally { state.pcm = new Uint8Array(0); }
      }
    }
  }

  private async release(state: MicExperimentRun, observer?: MicExperimentObserver): Promise<void> {
    state.accepting = false;
    if (state.intervalId >= 0) { clearInterval(state.intervalId); state.intervalId = -1; }
    if (state.timeoutId >= 0) { clearTimeout(state.timeoutId); state.timeoutId = -1; }
    const capturer = state.capturer;
    if (capturer === undefined) { return; }
    state.capturer = undefined;
    let failure: Error | undefined = undefined;
    // On some devices off('readData') blocks synchronously for about one second while
    // capture is running, starving the independent renderer's callbacks. Stop first;
    // accepting=false already makes any late PCM callback harmless during this await.
    if (state.started) {
      try {
        await this.stage<void>(state, 'capturer-stop', observer, (): Promise<void> => capturer.stop(), true);
      } catch (error) { failure = state.error ?? error as Error; }
    }
    state.started = false;
    try {
      await this.stage<void>(state, 'capturer-unsubscribe', observer, (): Promise<void> => {
        try { capturer.off('readData'); } catch (_error) {}
        try { capturer.off('inputDeviceChange'); } catch (_error) {}
        try { capturer.off('audioInterrupt'); } catch (_error) {}
        return Promise.resolve();
      }, true);
    } catch (error) { failure = failure ?? state.error ?? error as Error; }
    try {
      await this.stage<void>(state, 'capturer-release', observer, (): Promise<void> => this.releaseCapturer(capturer), true);
    } catch (error) { failure = failure ?? state.error ?? error as Error; }
    if (failure !== undefined) { throw failure; }
  }

  private async releaseCapturer(capturer: audio.AudioCapturer): Promise<void> {
    try { await capturer.release(); }
    catch (_error) {
      try { await capturer.release(); }
      catch (_retryError) {
        // Starting another capturer after an unconfirmed release can corrupt the A/B comparison.
        MicCaptureExperiment.releaseBlocked = true;
        throw new Error('麦克风资源未能释放，请重启应用后再试');
      }
    }
  }

  private wav(state: MicExperimentRun): ArrayBuffer {
    const buffer = new ArrayBuffer(44 + state.byteLength);
    const view = new DataView(buffer);
    const ascii = (offset: number, value: string): void => {
      for (let index = 0; index < value.length; index++) { view.setUint8(offset + index, value.charCodeAt(index)); }
    };
    ascii(0, 'RIFF'); view.setUint32(4, 36 + state.byteLength, true); ascii(8, 'WAVE'); ascii(12, 'fmt ');
    view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, state.channels, true);
    view.setUint32(24, state.sampleRate, true); view.setUint32(28, state.sampleRate * state.channels * 2, true);
    view.setUint16(32, state.channels * 2, true); view.setUint16(34, 16, true);
    ascii(36, 'data'); view.setUint32(40, state.byteLength, true);
    new Uint8Array(buffer, 44).set(state.pcm.subarray(0, state.byteLength));
    return buffer;
  }

  private async writeFile(path: string, buffer: ArrayBuffer): Promise<void> {
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      let written = 0;
      while (written < buffer.byteLength) {
        const count = await fs.write(file.fd, written === 0 ? buffer : buffer.slice(written));
        if (count <= 0 || count > buffer.byteLength - written) { throw new Error('实验音频保存未完成'); }
        written += count;
      }
      await fs.fsync(file.fd);
    } finally { await fs.close(file); }
  }

  private async unlinkOwned(path: string): Promise<void> {
    if (await fs.access(path)) { await fs.unlink(path); }
  }
}
