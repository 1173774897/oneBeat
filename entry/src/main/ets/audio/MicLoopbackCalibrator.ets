import { audio } from '@kit.AudioKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { MonotonicClock } from '../common/MonotonicClock';
import { CalibrationPlaybackReference, CalibrationSignalTiming } from './MetronomeEngine';

const SAMPLE_RATE_HZ: number = 44100;
const CHIRP_DURATION_MS: number = 500;
const CHIRP_F0_HZ: number = 800;
const CHIRP_F1_HZ: number = 4000;
const CHIRP_AMPLITUDE: number = 1.0;
const PERSISTENT_RENDERER_SIGNAL_LEAD_MS: number = 600;
const MAX_EXPECTED_ROUND_TRIP_MS: number = 1200;
const CORRELATION_TAIL_MARGIN_MS: number = 150;
// A current acoustic chirp cannot precede its renderer reference. Keep a
// conservative allowance for callback-anchor jitter, but exclude old chirps
// sitting hundreds of milliseconds earlier in a queued readData backlog.
const CORRELATION_CAUSAL_SLACK_MS: number = 100;
const POSITIONING_MAX_PROBES: number = 3;
const POSITION_READY_CORR_SNR_DB: number = 24;
// 正式测量单次探头的可接受 SNR 下限：低于此值视为检出不可靠，丢弃重测。
const MIN_ACCEPTABLE_SNR_DB: number = 18;
const HEADPHONE_MEASUREMENT_RUNS: number = 4;
const MIN_VALID_HEADPHONE_RUNS: number = 3;
// 四次中若有一次明显偏离，使用最紧的三次作为稳健簇；30ms 覆盖 A2DP 常见短时缓冲抖动。
const OUTLIER_CLUSTER_MAX_SPREAD_MS: number = 30;
const OUTLIER_MIN_SEPARATION_MS: number = 15;
// 输入侧校准连测次数：取中位数抵消 hardware latency 查询与回调调度的随机抖动。
const INPUT_CALIBRATION_RUNS: number = 3;
const MIN_VALID_INPUT_RUNS: number = 2;
const INPUT_CLUSTER_MAX_SPREAD_MS: number = 30;
const MIN_INPUT_LATENCY_MS: number = 1;
const MAX_INPUT_LATENCY_MS: number = 1000;
// Speaker loopback must exceed renderer HARDWARE leg plus mic/air path; smaller
// values usually mean correlation locked onto an old chirp at the causal edge.
const MIN_INPUT_ROUND_TRIP_MS: number = 60;

export interface MicLoopbackResult {
  latencyMs: number;
  snrDb: number;
  detected: boolean;
  capturedPeak: number;
  validRuns: number;
  detectedRuns: number;
  spreadMs: number;
  hardwareLatencyMs: number;
  // Raw round trips can be pooled across probes, but playback retains only
  // the last probe's renderer epoch. Its mapping must never be median-pooled.
  playbackReference?: CalibrationPlaybackReference;
}

export interface MicInputLatencyResult {
  inputLatencyMs: number;
  roundTripMs: number;
  hardwareLatencyMs: number;
  snrDb: number;
  detected: boolean;
  capturedPeak: number;
}

export type CalibrationSignalPlayer =
  // Resolves to the chirp first frame's renderer-presentation target, not the
  // earlier writeData/submit callback time.
  (signal: Int16Array, targetAtLocalMonoMs: number) => Promise<CalibrationSignalTiming>;

/** Realigns renderer frame epoch between mic calibration probes on the same route. */
export type MicCalibrationProbeBoundaryHook = () => Promise<void>;

/**
 * 生成线性扫频 chirp（800→4000Hz）。起始相位用 cos 保证首采样即满幅（尖锐起跳沿），
 * 便于在采集流中做能量起跳检测；尾部加 20ms 淡出避免收尾咔哒声。
 */
function buildChirp(durationMs: number): Int16Array {
  const n = Math.floor(SAMPLE_RATE_HZ * durationMs / 1000);
  const out = new Int16Array(n);
  const T = durationMs / 1000;
  const fadeSamples = Math.floor(SAMPLE_RATE_HZ * 0.02);
  for (let i = 0; i < n; i++) {
    const t = i / SAMPLE_RATE_HZ;
    const phase = 2 * Math.PI *
      (CHIRP_F0_HZ * t + (CHIRP_F1_HZ - CHIRP_F0_HZ) * t * t / (2 * T));
    let env = 1;
    if (i > n - fadeSamples) {
      env = (n - i) / fadeSamples;
    }
    out[i] = Math.round(Math.cos(phase) * CHIRP_AMPLITUDE * env * 32767);
  }
  return out;
}

/** 数值中位数；样本数 >= 1。用于把多次测量的随机抖动取稳。 */
function medianOf(values: number[]): number {
  const sorted = values.slice().sort((a: number, b: number) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

interface CorrOnset {
  onset: number;
  corrSnrDb: number;
}

// 相关峰需高出相关底噪该值（dB）才判定为可靠检出。纯噪声的相关峰期望约 12.7dB 以上，
// 取 16dB 留出余量，避免在「耳机未靠近麦克风、几乎没采到信号」时误报一个假时延。
const CORR_SNR_THRESHOLD_DB: number = 16;
// 4 倍降采样到 11025Hz：chirp 800~4000Hz 远低于其奈奎斯特 5512Hz，相关计算量降约 16 倍。
const DOWNSAMPLE_FACTOR: number = 4;
// 粗搜索每隔 4 个降采样点计算一次，再在峰值附近逐点细搜。保持约 0.09ms 精度，
// 同时让“预检测 + 4 次正式测量”不会长时间占用 UI 线程。
const CORR_COARSE_STRIDE: number = 4;
// Diagnostic peaks closer than this are the same chirp main lobe in practice.
// Keeping them out of top-K exposes a possible later acoustic peak instead of
// printing three adjacent samples from an earlier AEC/electrical-reference peak.
const CORR_DIAG_PEAK_GUARD_MS: number = 50;

interface CaptureClockAnchor {
  framePos: number;
  timestampMonoMs: number;
  queryMonoMs: number;
}

/**
 * 互相关（matched filter）定位 chirp 到达时刻。
 *
 * 能量门限法要求信号在几毫秒窗口内压过底噪，而入耳式耳机漏音极弱、时间域 SNR 常 ≤0dB，
 * 必然漏检。这里拿已知 chirp 与整段采集做滑动点积（匹配滤波），把 chirp 能量在整段时长内
 * 积分，降采样域约 5512 点带来约 37dB 处理增益，即使信号被底噪淹没也能稳定定位峰值。
 * 峰值下标即 chirp 在采集流中的起点（原始采样域）。
 */
async function findOnsetByCrossCorrelation(captured: number[], chirp: Int16Array,
  minOnsetSamples: number): Promise<CorrOnset> {
  const ds = DOWNSAMPLE_FACTOR;
  const chirpLen = Math.floor(chirp.length / ds);
  const capLen = Math.floor(captured.length / ds);
  if (chirpLen < 16 || capLen < chirpLen) {
    return { onset: -1, corrSnrDb: -999 };
  }

  // 4 点均值降采样（抗混叠）；chirp 转 float 并去直流，避免麦克风直流偏移抬升相关底噪。
  const dsChirp = new Float64Array(chirpLen);
  let chirpMean = 0;
  for (let i = 0; i < chirpLen; i++) {
    let s = 0;
    for (let j = 0; j < ds; j++) {
      s += chirp[i * ds + j] / 32768;
    }
    dsChirp[i] = s / ds;
    chirpMean += dsChirp[i];
  }
  chirpMean /= chirpLen;
  for (let i = 0; i < chirpLen; i++) {
    dsChirp[i] -= chirpMean;
  }

  const dsCap = new Float64Array(capLen);
  for (let i = 0; i < capLen; i++) {
    let s = 0;
    for (let j = 0; j < ds; j++) {
      s += captured[i * ds + j];
    }
    dsCap[i] = s / ds;
  }

  // 粗粒度滑动点积相关。绝对值兼容少数设备录音链路发生极性翻转的情况。
  // 分块计算并在块间让出事件循环，避免长时间阻塞 readData 回调导致采集锚点漂移。
  const maxLag = capLen - chirpLen;
  const minLag = Math.max(0, Math.ceil(minOnsetSamples / ds));
  if (minLag > maxLag) {
    return { onset: -1, corrSnrDb: -999 };
  }
  const firstCorrIndex = Math.ceil(minLag / CORR_COARSE_STRIDE);
  const lastCorrIndex = Math.floor(maxLag / CORR_COARSE_STRIDE);
  if (firstCorrIndex > lastCorrIndex) {
    return { onset: -1, corrSnrDb: -999 };
  }
  const corrCount = lastCorrIndex - firstCorrIndex + 1;
  const corr = new Float64Array(corrCount);
  let bestLag = minLag;
  let bestVal = 0;
  const CORR_CHUNK_LAGS = 512;
  for (let chunkStart = 0; chunkStart < corrCount; chunkStart += CORR_CHUNK_LAGS) {
    const chunkEnd = Math.min(chunkStart + CORR_CHUNK_LAGS, corrCount);
    for (let corrIndex = chunkStart; corrIndex < chunkEnd; corrIndex++) {
      const lag = (firstCorrIndex + corrIndex) * CORR_COARSE_STRIDE;
      let sum = 0;
      for (let i = 0; i < chirpLen; i++) {
        sum += dsCap[lag + i] * dsChirp[i];
      }
      const magnitude = Math.abs(sum);
      corr[corrIndex] = magnitude;
      if (magnitude > bestVal) {
        bestVal = magnitude;
        bestLag = lag;
      }
    }
    await yieldToEventLoop();
  }

  // 诊断：打印相关序列前 3 强峰（粗域 lag）。用于判断真峰前 ~232ms 处是否存在
  // 稳定副峰（电串扰/早反射被锁定），从而解释「蓝牙回环缺 mic 时延」的 onset 偏早。
  {
    const TOPK = 3;
    const guardIndexes = Math.max(8, Math.round(
      CORR_DIAG_PEAK_GUARD_MS * SAMPLE_RATE_HZ /
      (1000 * CORR_COARSE_STRIDE * ds)));
    const corrCopy = Array.from(corr);
    const peaks: string[] = [];
    const bestLagMs = bestLag * ds / SAMPLE_RATE_HZ * 1000;
    for (let k = 0; k < TOPK; k++) {
      let maxIdx = -1;
      let maxVal = -1;
      for (let i = 0; i < corrCopy.length; i++) {
        if (corrCopy[i] > maxVal) {
          maxVal = corrCopy[i];
          maxIdx = i;
        }
      }
      if (maxIdx < 0) {
        break;
      }
      const lagMs = (firstCorrIndex + maxIdx) * CORR_COARSE_STRIDE * ds /
        SAMPLE_RATE_HZ * 1000;
      const relativeMs = Math.round(lagMs - bestLagMs);
      const relativeDb = 20 * Math.log10(Math.max(maxVal, 1e-12) / Math.max(bestVal, 1e-12));
      peaks.push(`#${k + 1} lag=${Math.round(lagMs)}ms rel=${relativeMs >= 0 ? '+' : ''}${relativeMs}ms ` +
        `level=${relativeDb.toFixed(1)}dB`);
      for (let i = Math.max(0, maxIdx - guardIndexes);
        i <= Math.min(corrCopy.length - 1, maxIdx + guardIndexes); i++) {
        corrCopy[i] = -1;
      }
    }
    console.info(`[CorrPeaksDiag] ${peaks.join('  ')}`);
  }

  // 在粗峰附近逐采样细搜，最终定位精度仍是 DOWNSAMPLE_FACTOR 个原始采样点。
  const refineStart = Math.max(minLag, bestLag - CORR_COARSE_STRIDE + 1);
  const refineEnd = Math.min(maxLag, bestLag + CORR_COARSE_STRIDE - 1);
  for (let lag = refineStart; lag <= refineEnd; lag++) {
    let sum = 0;
    for (let i = 0; i < chirpLen; i++) {
      sum += dsCap[lag + i] * dsChirp[i];
    }
    const magnitude = Math.abs(sum);
    if (magnitude > bestVal) {
      bestVal = magnitude;
      bestLag = lag;
    }
  }

  // 相关底噪 = 去掉峰值主瓣邻域后的 RMS
  const exclude = Math.max(Math.floor(chirpLen / 4), 8);
  let bgSum = 0;
  let bgCount = 0;
  for (let corrIndex = 0; corrIndex < corr.length; corrIndex++) {
    const lag = (firstCorrIndex + corrIndex) * CORR_COARSE_STRIDE;
    if (Math.abs(lag - bestLag) > exclude) {
      bgSum += corr[corrIndex] * corr[corrIndex];
      bgCount++;
    }
  }
  const bgRms = bgCount > 0 ? Math.sqrt(bgSum / bgCount) : 1e-6;
  const corrSnrDb = 20 * Math.log10(bestVal / Math.max(bgRms, 1e-12));

  if (corrSnrDb < CORR_SNR_THRESHOLD_DB) {
    return { onset: -1, corrSnrDb };
  }
  return { onset: bestLag * ds, corrSnrDb };
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

/** 让出当前事件循环一个宏任务，使排队的 readData 回调有机会执行。 */
function yieldToEventLoop(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 0);
  });
}

/**
 * 麦克风回环自动测时延：渲染一个已知 chirp 到耳机，同时用麦克风采集，互相关（匹配滤波）定位
 * chirp 在采集流中的到达帧。耳机测量从 chirp 目标帧的 renderer-presentation 时刻起算，
 * 先保留物理往返；正式播放的 legacy 帧坐标另按最终 renderer epoch 转换。
 * writeData 只是提前填充队列，不能直接算进物理输出时延。
 */
export class MicLoopbackCalibrator {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private captured: number[] = [];
  private chirp: Int16Array = buildChirp(CHIRP_DURATION_MS);
  private captureStartMonoMs: number = -1;
  private captureDeliveredFrames: number = 0;
  private captureStage: string = 'unknown';
  private lastPlaybackReference: CalibrationPlaybackReference | undefined = undefined;
  // A boolean cancel flag can be cleared by a quick retry while the previous
  // async run is still unwinding. A monotonically increasing generation makes
  // cancellation permanent for that run and keeps old capturer callbacks from
  // writing into the next probe's shared sample buffer.
  private measurementGeneration: number = 0;

  private isMeasurementActive(generation: number): boolean {
    return generation === this.measurementGeneration;
  }

  private readCaptureClockAnchor(capturer: audio.AudioCapturer): CaptureClockAnchor | undefined {
    try {
      const startupBeforeMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const activeBeforeMs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const info = capturer.getAudioTimestampInfoSync();
      const activeAfterMs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const startupAfterMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      if (info.framePos < 0 || info.timestamp <= 0) {
        return undefined;
      }
      const queryMonoMs = (startupBeforeMs + startupAfterMs) / 2;
      const activeAtQueryMs = (activeBeforeMs + activeAfterMs) / 2;
      const timestampMonoMs = info.timestamp / 1000000 + queryMonoMs - activeAtQueryMs;
      if (!Number.isFinite(timestampMonoMs)) {
        return undefined;
      }
      return { framePos: info.framePos, timestampMonoMs, queryMonoMs };
    } catch (_e) {
      return undefined;
    }
  }

  private describeInputDevices(capturer: audio.AudioCapturer): string {
    try {
      const devices = capturer.getCurrentInputDevices();
      const parts: string[] = [];
      for (let i = 0; i < devices.length; i++) {
        parts.push(`${devices[i].deviceType}:${devices[i].id}`);
      }
      return parts.length > 0 ? parts.join(',') : 'none';
    } catch (_e) {
      return 'unavailable';
    }
  }

  private readAudioScene(): number {
    try {
      return audio.getAudioManager().getAudioSceneSync();
    } catch (_e) {
      return -1;
    }
  }

  private appendCapturedBuffer(buffer: ArrayBuffer, generation: number,
    capturer: audio.AudioCapturer): void {
    if (!this.isMeasurementActive(generation)) {
      return;
    }
    const n = Math.floor(buffer.byteLength / 2);
    const bufferStartFrame = this.captureDeliveredFrames;
    this.captureDeliveredFrames += n;
    if (this.captureStartMonoMs < 0) {
      // 回调时刻减一个缓冲时长只是交付时间估计；输入处理和积压仍计入两阶段的输入项。
      const bufferMs = n / SAMPLE_RATE_HZ * 1000;
      const nowMs = MonotonicClock.nowMs();
      this.captureStartMonoMs = nowMs - bufferMs;
      const clock = this.readCaptureClockAnchor(capturer);
      let clockFields = 'clock=unavailable';
      if (clock !== undefined) {
        // bufferStartFrame is the first delivered sample in the current probe,
        // while framePos is the newest hardware-captured frame. Their difference
        // reveals delivery backlog that the callback-time heuristic cannot see.
        const clockStartMonoMs = clock.timestampMonoMs -
          (clock.framePos - bufferStartFrame) * 1000 / SAMPLE_RATE_HZ;
        clockFields = `clockFrame=${clock.framePos} bufferStartFrame=${bufferStartFrame} ` +
          `clockAgeMs=${(clock.queryMonoMs - clock.timestampMonoMs).toFixed(1)} ` +
          `clockStart=${clockStartMonoMs.toFixed(1)} ` +
          `clockMinusHeuristicMs=${(clockStartMonoMs - this.captureStartMonoMs).toFixed(1)}`;
      }
      console.info(`[CaptureAnchorDiag] stage=${this.captureStage} firstReadData=${nowMs.toFixed(1)} ` +
        `bufferMs=${bufferMs.toFixed(1)} n=${n} heuristicStart=${this.captureStartMonoMs.toFixed(1)} ` +
        `${clockFields} inputDevices=[${this.describeInputDevices(capturer)}] ` +
        `audioScene=${this.readAudioScene()}`);
    }
    const view = new DataView(buffer);
    for (let i = 0; i < n; i++) {
      this.captured.push(view.getInt16(i * 2, true) / 32768);
    }
  }

  /** Wait in short slices so route changes and page exit stop a long capture promptly. */
  private async waitWhileActive(generation: number, durationMs: number): Promise<boolean> {
    const deadline = MonotonicClock.nowMs() + Math.max(0, durationMs);
    while (this.isMeasurementActive(generation)) {
      const remainingMs = deadline - MonotonicClock.nowMs();
      if (remainingMs <= 0) {
        return true;
      }
      await sleep(Math.min(50, remainingMs));
    }
    return false;
  }

  /** Both calibration stages must use the same MIC processing chain so their subtraction remains valid. */
  private async createStartedCapturer(streamInfo: audio.AudioStreamInfo,
    generation: number): Promise<audio.AudioCapturer> {
    this.captureDeliveredFrames = 0;
    const capturer = await audio.createAudioCapturer({
      streamInfo: streamInfo,
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      }
    });
    capturer.on('readData', (buffer: ArrayBuffer): void => {
      this.appendCapturedBuffer(buffer, generation, capturer);
    });
    await capturer.start();
    console.info(`[MicRouteDiag] phase=capturer-start stage=${this.captureStage} ` +
      `inputDevices=[${this.describeInputDevices(capturer)}] audioScene=${this.readAudioScene()}`);
    return capturer;
  }

  private emptyResult(capturedPeak: number = 0, snrDb: number = -999,
    validRuns: number = 0): MicLoopbackResult {
    return {
      latencyMs: -1,
      snrDb,
      detected: false,
      capturedPeak,
      validRuns,
      detectedRuns: validRuns,
      spreadMs: -1,
      hardwareLatencyMs: -1
    };
  }

  /** Measure one chirp without restarting either side of the audio route. */
  private async runPersistentProbe(playSignal: CalibrationSignalPlayer,
    generation: number): Promise<MicLoopbackResult> {
    if (!this.isMeasurementActive(generation)) {
      return this.emptyResult();
    }
    // 每个探针从首个新鲜采集缓冲重新计数，避免把上一次相关运算期间的回调间隙累计进 onset。
    // now-bufferMs 仍包含 readData 的输入流水线/调度项；两阶段使用同一 MIC 配置并各自取中位数，
    // 只依赖共同项在 I_BT-I_SPK 中相消，不能假定单次回调抖动会在 gap+onset 内自动抵消。
    this.captured = [];
    this.captureStartMonoMs = -1;
    const captureReadyDeadline = MonotonicClock.nowMs() + 500;
    while (this.isMeasurementActive(generation) && this.captureStartMonoMs < 0 &&
      MonotonicClock.nowMs() < captureReadyDeadline) {
      await sleep(10);
    }
    if (!this.isMeasurementActive(generation) || this.captureStartMonoMs < 0) {
      return this.emptyResult();
    }
    const probeCaptureStartMonoMs = this.captureStartMonoMs;
    const targetAtLocalMonoMs = MonotonicClock.nowMs() + PERSISTENT_RENDERER_SIGNAL_LEAD_MS;
    // Keep the physical round trip and causal search on the raw presentation
    // clock. The page later converts the result to production's legacy frame
    // mapping; using that mapping here would also move the correlation window.
    const timing = await playSignal(this.chirp, targetAtLocalMonoMs);
    if (!this.isMeasurementActive(generation)) {
      return this.emptyResult();
    }
    // A later probe replaces the output renderer even if its correlation is
    // rejected. The retained epoch, rather than the accepted acoustic cluster,
    // determines which mapping is usable after the capturer is released.
    this.lastPlaybackReference = timing.playbackReference;
    // A fixed 1300ms window can end before a queued 500ms chirp is complete.
    // Anchor the deadline to the verified presentation time so correlation
    // always receives the whole current chirp, even with a deep real queue.
    const captureUntilMonoMs = timing.presentationMonoMs + MAX_EXPECTED_ROUND_TRIP_MS +
      CHIRP_DURATION_MS + CORRELATION_TAIL_MARGIN_MS;
    const captureCompleted = await this.waitWhileActive(generation,
      captureUntilMonoMs - MonotonicClock.nowMs());
    if (!captureCompleted || !this.isMeasurementActive(generation)) {
      return this.emptyResult();
    }
    const analyzed = await this.analyzeCaptured(
      this.captured.slice(),
      probeCaptureStartMonoMs,
      timing.presentationMonoMs
    );
    if (!this.isMeasurementActive(generation)) {
      return this.emptyResult();
    }
    analyzed.hardwareLatencyMs = timing.hardwareLatencyMs;
    analyzed.playbackReference = timing.playbackReference;
    return analyzed;
  }

  /**
   * Capture chirps emitted by the session's persistent renderer. Positioning probes give the
   * user actionable feedback at normal listening volume. Formal probes reuse the input stream
   * and take a robust median of raw round trips; their boundary hook may replace the output
   * renderer, so the result separately retains the actual final renderer's mapping.
   */
  async measureWithPersistentRenderer(
    playSignal: CalibrationSignalPlayer,
    onStatus?: (msg: string) => void,
    probeBoundary?: MicCalibrationProbeBoundaryHook
  ): Promise<MicLoopbackResult> {
    const generation = ++this.measurementGeneration;
    this.captureStage = 'headphone';
    this.lastPlaybackReference = undefined;
    this.captured = [];
    this.captureStartMonoMs = -1;

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    let capturer: audio.AudioCapturer | undefined = undefined;
    try {
      capturer = await this.createStartedCapturer(streamInfo, generation);
      if (!this.isMeasurementActive(generation)) {
        return this.emptyResult();
      }
      this.capturer = capturer;

      const realignRendererEpoch = async (): Promise<void> => {
        if (probeBoundary !== undefined) {
          await probeBoundary();
        }
      };

      let positioningBest = this.emptyResult();
      await realignRendererEpoch();
      for (let i = 0; i < POSITIONING_MAX_PROBES; i++) {
        onStatus?.(i === 0
          ? '正在听耳机声音，请把出声孔对准手机底部麦克风…'
          : `继续找位置 ${i + 1}/${POSITIONING_MAX_PROBES}，可以用手掌轻罩住耳机和麦克风…`);
        const probe = await this.runPersistentProbe(playSignal, generation);
        if (!this.isMeasurementActive(generation)) {
          return this.emptyResult();
        }
        if (probe.snrDb > positioningBest.snrDb) {
          positioningBest = probe;
        }
        if (probe.detected && probe.snrDb >= POSITION_READY_CORR_SNR_DB) {
          onStatus?.('位置很好，请保持不动，即将开始 4 次正式测量');
          if (!await this.waitWhileActive(generation, 350)) {
            return this.emptyResult();
          }
          break;
        }
        if (probe.detected) {
          onStatus?.('已经听到测试音，再靠近一点会更稳…');
        } else {
          onStatus?.('还没听清，请让耳机出声孔更贴近手机底部麦克风…');
        }
        if (!await this.waitWhileActive(generation, 650)) {
          return this.emptyResult();
        }
        if (i + 1 < POSITIONING_MAX_PROBES) {
          await realignRendererEpoch();
        }
      }

      if (!positioningBest.detected) {
        return positioningBest;
      }

      await realignRendererEpoch();

      const valid: MicLoopbackResult[] = [];
      let capturedPeak = positioningBest.capturedPeak;
      let runs = 0;
      let attempts = 0;
      const maxAttempts = HEADPHONE_MEASUREMENT_RUNS * 2;
      while (runs < HEADPHONE_MEASUREMENT_RUNS && attempts < maxAttempts) {
        attempts++;
        onStatus?.(`位置已锁定 · 正式测量 ${runs + 1}/${HEADPHONE_MEASUREMENT_RUNS}` +
          (attempts > runs + 1 ? '（上一轮 SNR 偏低，重测中…）' : ''));
        const probe = await this.runPersistentProbe(playSignal, generation);
        if (!this.isMeasurementActive(generation)) {
          return this.emptyResult();
        }
        capturedPeak = Math.max(capturedPeak, probe.capturedPeak);
        // 低 SNR 视为检出不可靠，丢弃并重测；仅达到可接受 SNR 才计入有效样本。
        if (probe.detected && probe.snrDb >= MIN_ACCEPTABLE_SNR_DB) {
          valid.push(probe);
          runs++;
        }
        if (runs < HEADPHONE_MEASUREMENT_RUNS && attempts < maxAttempts) {
          if (!await this.waitWhileActive(generation, 250)) {
            return this.emptyResult();
          }
          await realignRendererEpoch();
        }
      }
      await capturer.stop();

      if (valid.length < MIN_VALID_HEADPHONE_RUNS) {
        const confidence = valid.length > 0
          ? medianOf(valid.map((probe: MicLoopbackResult) => probe.snrDb))
          : positioningBest.snrDb;
        return this.emptyResult(capturedPeak, Math.round(confidence * 10) / 10, valid.length);
      }

      const sorted = valid.slice().sort((a: MicLoopbackResult, b: MicLoopbackResult) =>
        a.latencyMs - b.latencyMs);
      let selected = sorted;
      const fullSpread = sorted[sorted.length - 1].latencyMs - sorted[0].latencyMs;
      if (sorted.length === HEADPHONE_MEASUREMENT_RUNS) {
        const lowerSpread = sorted[2].latencyMs - sorted[0].latencyMs;
        const upperSpread = sorted[3].latencyMs - sorted[1].latencyMs;
        const tightSpread = Math.min(lowerSpread, upperSpread);
        // Only discard a sample when the remaining three form a clearly tighter cluster.
        // Uniformly distributed Bluetooth jitter has no defensible “bad” sample, so retain all four.
        if (tightSpread <= OUTLIER_CLUSTER_MAX_SPREAD_MS &&
          fullSpread - tightSpread >= OUTLIER_MIN_SEPARATION_MS) {
          selected = lowerSpread <= upperSpread ? sorted.slice(0, 3) : sorted.slice(1, 4);
        }
      }
      const latencies = selected.map((probe: MicLoopbackResult) => probe.latencyMs);
      const confidences = selected.map((probe: MicLoopbackResult) => probe.snrDb);
      const minLatency = Math.min(...latencies);
      const maxLatency = Math.max(...latencies);
      console.info(`[MicLoopback] detected=${sorted.map((probe: MicLoopbackResult) => probe.latencyMs).join(',')}ms ` +
        `selected=${latencies.join(',')}ms spread=${(maxLatency - minLatency).toFixed(1)}ms`);
      if (maxLatency - minLatency > OUTLIER_CLUSTER_MAX_SPREAD_MS) {
        // A high correlation SNR identifies a chirp, not a stable latency.
        // Saving a broad cluster would conceal route/input scheduling changes.
        const rejected = this.emptyResult(capturedPeak,
          Math.round(medianOf(confidences) * 10) / 10, selected.length);
        rejected.detectedRuns = valid.length;
        rejected.spreadMs = Math.round((maxLatency - minLatency) * 10) / 10;
        rejected.playbackReference = this.lastPlaybackReference;
        return rejected;
      }
      return {
        latencyMs: Math.round(medianOf(latencies) * 10) / 10,
        snrDb: Math.round(medianOf(confidences) * 10) / 10,
        detected: true,
        capturedPeak,
        validRuns: selected.length,
        detectedRuns: valid.length,
        spreadMs: Math.round((maxLatency - minLatency) * 10) / 10,
        hardwareLatencyMs: medianOf(selected.map((probe: MicLoopbackResult) => probe.hardwareLatencyMs)),
        playbackReference: this.lastPlaybackReference
      };
    } catch (err) {
      throw new Error((err as Error).message ?? '麦克风回环测量失败');
    } finally {
      try {
        await capturer?.stop();
      } catch (_e) {
        // Stop can race page exit; release still has to run.
      }
      let releaseFailed = false;
      try {
        await capturer?.release();
      } catch (_e) {
        // A result is only usable with the recording route gone. A cancelled
        // generation may finish best-effort cleanup without affecting its retry.
        releaseFailed = this.isMeasurementActive(generation);
      }
      if (this.capturer === capturer) {
        this.capturer = undefined;
      }
      if (releaseFailed) {
        throw new Error('麦克风录音流未能关闭，请退出校准后重试');
      }
    }
  }

  /**
   * 测「输入侧时延」：用外放播放同一个 chirp，麦克风收回后得到往返，
   * 再扣掉 getLatency(HARDWARE) 报出的帧时钟下游输出侧，剩下的就是
   * 麦克风→ADC→输入缓冲→AEC→readData 的输入侧。
   * 两步都以 renderer-presentation 时刻为起点，避免把可变的提交队列
   * 混入输入侧。外放与蓝牙下系统的 AEC/降噪仍可能不同，所以这个差分
   * 仍是对“两种路由共享同一 MIC 处理链”的有意识假设。
   *
   * 连测 INPUT_CALIBRATION_RUNS 次取中位数，抵消单次启动/调度抖动。
   */
  async measureInputLatency(playSignal: CalibrationSignalPlayer,
    onStatus?: (msg: string) => void,
    afterEachProbe?: MicCalibrationProbeBoundaryHook): Promise<MicInputLatencyResult> {
    const generation = ++this.measurementGeneration;
    this.captureStage = 'input';
    this.lastPlaybackReference = undefined;
    const samples: number[] = [];
    const validProbes: MicLoopbackResult[] = [];
    let detectedProbeCount = 0;
    let last = this.emptyResult();
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    let capturer: audio.AudioCapturer | undefined = undefined;
    try {
      capturer = await this.createStartedCapturer(streamInfo, generation);
      if (!this.isMeasurementActive(generation)) {
        return {
          inputLatencyMs: -1,
          roundTripMs: -1,
          hardwareLatencyMs: -1,
          snrDb: -999,
          detected: false,
          capturedPeak: 0
        };
      }
      this.capturer = capturer;
      if (afterEachProbe !== undefined) {
        await afterEachProbe();
      }
      for (let i = 0; i < INPUT_CALIBRATION_RUNS; i++) {
        if (!this.isMeasurementActive(generation)) {
          break;
        }
        onStatus?.(`输入侧测量 ${i + 1}/${INPUT_CALIBRATION_RUNS}…`);
        last = await this.runPersistentProbe(playSignal, generation);
        if (!this.isMeasurementActive(generation)) {
          break;
        }
        if (last.detected) {
          detectedProbeCount++;
        }
        if (last.detected && last.hardwareLatencyMs >= 0) {
          if (last.latencyMs < MIN_INPUT_ROUND_TRIP_MS) {
            console.warn(`[MicInputCalibration] reject roundTripMs=${last.latencyMs.toFixed(1)} ` +
              `< ${MIN_INPUT_ROUND_TRIP_MS} (likely wrong chirp in correlation)`);
          } else {
            const inputLatencyMs = last.latencyMs - last.hardwareLatencyMs;
            if (Number.isFinite(inputLatencyMs) && inputLatencyMs >= MIN_INPUT_LATENCY_MS &&
              inputLatencyMs <= MAX_INPUT_LATENCY_MS) {
              samples.push(inputLatencyMs);
              validProbes.push(last);
            } else {
              // A non-positive input pipeline is physically invalid. Persisting a
              // clamped zero would fold the entire mic leg into output compensation.
              console.warn(`[MicInputCalibration] reject inputLatencyMs=${inputLatencyMs.toFixed(1)} ` +
                `roundTripMs=${last.latencyMs} hardwareLatencyMs=${last.hardwareLatencyMs}`);
            }
          }
        }
        if (i + 1 < INPUT_CALIBRATION_RUNS) {
          if (afterEachProbe !== undefined) {
            await afterEachProbe();
          }
          if (!await this.waitWhileActive(generation, 350)) {
            break;
          }
        }
      }
      await capturer.stop();
    } finally {
      try {
        await capturer?.stop();
      } catch (_e) {
        // Stop may race page exit; release must still run.
      }
      let releaseFailed = false;
      try {
        await capturer?.release();
      } catch (_e) {
        releaseFailed = this.isMeasurementActive(generation);
      }
      if (this.capturer === capturer) {
        this.capturer = undefined;
      }
      if (releaseFailed) {
        throw new Error('麦克风录音流未能关闭，请退出校准后重试');
      }
    }
    const sortedSamples = samples.slice().sort((a: number, b: number) => a - b);
    let stableSamples = sortedSamples;
    if (sortedSamples.length >= 3 &&
      sortedSamples[sortedSamples.length - 1] - sortedSamples[0] > INPUT_CLUSTER_MAX_SPREAD_MS) {
      const lowerSpread = sortedSamples[1] - sortedSamples[0];
      const upperSpread = sortedSamples[2] - sortedSamples[1];
      const tightSpread = Math.min(lowerSpread, upperSpread);
      stableSamples = tightSpread <= INPUT_CLUSTER_MAX_SPREAD_MS
        ? (lowerSpread <= upperSpread ? sortedSamples.slice(0, 2) : sortedSamples.slice(1, 3))
        : [];
    } else if (sortedSamples.length === 2 &&
      sortedSamples[1] - sortedSamples[0] > INPUT_CLUSTER_MAX_SPREAD_MS) {
      stableSamples = [];
    }
    console.info(`[MicInputCalibration] samples=${sortedSamples.join(',')}ms ` +
      `selected=${stableSamples.join(',')}ms`);
    if (stableSamples.length < MIN_VALID_INPUT_RUNS) {
      console.warn(`[MicInputCalibration] failed: need ${MIN_VALID_INPUT_RUNS} stable samples, ` +
        `got ${stableSamples.length} accepted=${samples.length} ` +
        `correlationDetected=${detectedProbeCount}/${INPUT_CALIBRATION_RUNS} ` +
        `lastRoundTripMs=${last.latencyMs} lastHardwareMs=${last.hardwareLatencyMs} ` +
        `lastSnrDb=${last.snrDb} lastPeak=${last.capturedPeak}`);
      return {
        inputLatencyMs: -1,
        roundTripMs: last.latencyMs,
        hardwareLatencyMs: last.hardwareLatencyMs,
        snrDb: last.snrDb,
        detected: false,
        capturedPeak: last.capturedPeak
      };
    }
    const median = medianOf(stableSamples);
    return {
      inputLatencyMs: Math.round(median * 10) / 10,
      roundTripMs: Math.round(medianOf(validProbes.map((probe: MicLoopbackResult) =>
        probe.latencyMs)) * 10) / 10,
      hardwareLatencyMs: Math.round(medianOf(validProbes.map((probe: MicLoopbackResult) =>
        probe.hardwareLatencyMs)) * 10) / 10,
      snrDb: Math.round(medianOf(validProbes.map((probe: MicLoopbackResult) => probe.snrDb)) * 10) / 10,
      detected: true,
      capturedPeak: Math.max(...validProbes.map((probe: MicLoopbackResult) => probe.capturedPeak))
    };
  }

  cancel(): void {
    this.measurementGeneration++;
  }

  private async analyzeCaptured(captured: number[], captureStartMonoMs: number,
    chirpReferenceMonoMs: number): Promise<MicLoopbackResult> {
    let capturedPeak = 0;
    for (let i = 0; i < captured.length; i++) {
      const a = Math.abs(captured[i]);
      if (a > capturedPeak) {
        capturedPeak = a;
      }
    }
    const causalSearchStartMs = captureStartMonoMs >= 0 && chirpReferenceMonoMs >= 0
      ? Math.max(0, chirpReferenceMonoMs - captureStartMonoMs - CORRELATION_CAUSAL_SLACK_MS)
      : 0;
    const correlation = await findOnsetByCrossCorrelation(captured, this.chirp,
      Math.ceil(causalSearchStartMs * SAMPLE_RATE_HZ / 1000));
    const roundedConfidence = Math.round(correlation.corrSnrDb * 10) / 10;
    if (correlation.onset < 0 || captureStartMonoMs < 0 || chirpReferenceMonoMs < 0) {
      return this.emptyResult(capturedPeak, roundedConfidence);
    }

    const fs = SAMPLE_RATE_HZ;
    // Both headset and input-side probes use the renderer-presentation target;
    // input calibration later subtracts the HARDWARE latency returned with it.
    const chirpCapturedMs = captureStartMonoMs + correlation.onset / fs * 1000;
    const latencyMs = chirpCapturedMs - chirpReferenceMonoMs;

    // latencyMs = gapMs + onsetMs。gapMs（参考时刻→采集首帧）漂移说明渲染/采集锚点抖动；
    // onsetMs（chirp 在采集缓冲里的到达偏移）漂移说明声学路径或起始检测抖动。
    const gapMs = captureStartMonoMs - chirpReferenceMonoMs;
    const onsetMs = correlation.onset / fs * 1000;
    const tailSamples = captured.length - correlation.onset;
    const tailMs = tailSamples / fs * 1000;
    console.info(`[LatencyProbe] latencyMs=${Math.round(latencyMs * 10) / 10} ` +
      `= gapMs(${Math.round(gapMs * 10) / 10}) + onsetMs(${Math.round(onsetMs * 10) / 10}) ` +
      `onsetSamples=${correlation.onset} lenSamples=${captured.length} tailMs=${tailMs.toFixed(1)} ` +
      `capStart=${captureStartMonoMs.toFixed(1)} chirpReference=${chirpReferenceMonoMs.toFixed(1)} ` +
      `searchFromMs=${causalSearchStartMs.toFixed(1)} snrDb=${roundedConfidence} peak=${capturedPeak}`);

    return {
      latencyMs: Math.round(latencyMs * 10) / 10,
      // UI 质量必须使用真正决定“是否检出”的相关峰置信度，不能再用普通录音能量比。
      snrDb: roundedConfidence,
      detected: true,
      capturedPeak,
      validRuns: 1,
      detectedRuns: 1,
      spreadMs: 0,
      hardwareLatencyMs: -1
    };
  }
}
