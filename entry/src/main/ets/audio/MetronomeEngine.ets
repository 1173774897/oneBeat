import { audio } from '@kit.AudioKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { ClickSound, ACCENT_DURATION_MS, WEAK_DURATION_MS } from './ClickSound';
import { AudioOutputMonitor } from './AudioOutputMonitor';
import { getEffectiveCalibrationMs, getCalibrationMs, getInputLatencyMs } from '../store/AudioLatencyPersistence';
import { MonotonicClock } from '../common/MonotonicClock';
import {
  BuiltInRhythmFactory,
  DEFAULT_TICKS_PER_BEAT,
  SequencerEvent,
  SequencerPattern
} from './RhythmTimeline';
import {
  buildProgramSequence,
  DrumProgram,
  parseDrumProgram
} from './DrumMachineCatalog';
import { DrumSampleBank } from './DrumSampleBank';
import { BeatPointState, defaultBeatPointStates, normalizeBeatPointStates } from '../common/MeterModel';
import { DEBUG } from 'BuildProfile';

const SAMPLE_RATE: number = 44100;
const BYTES_PER_SAMPLE: number = 2;
const AUDIO_PREROLL_MS: number = 650;
const AUDIO_CLOCK_LOCK_RETRY_MS: number = 8;
const AUDIO_CLOCK_LOCK_TIMEOUT_MS: number = 300;
const AUDIO_CLOCK_LOCK_MIN_REMAINING_MS: number = 80;
const AUDIO_CALLBACK_STALL_MS: number = 1500;
// Sub-audible dither floor laid under the click samples so the stream is never
// pure digital zero. Pure zero runs are what the smart PA silence detector
// (CustStreamCheck -> SmartpaPowerOff) keys on to power off the amplifier.
// ~ -80dBFS peak; raise only if device logs still show zero_volume=true.
const DITHER_FLOOR_GAIN: number = 0.0001;
// 播放中持续相位锁定的校正参数。
// 相位误差（音频播放头相对墙钟时间轴）超过该阈值时启动插帧/丢帧校正。
const AUDIO_PHASE_LOCK_THRESHOLD_FRAMES: number = 44; // 约 1ms
// 每次校正的最大步长，保证插帧/丢帧足够渐进、听感不可察觉。
const AUDIO_PHASE_LOCK_MAX_STEP_FRAMES: number = 16; // 约 0.36ms
// 拍点内“安全区”起点：越过强拍 click 衰减尾后（约 1.25 倍 click 时长）才允许校正，
// 避免在 click 瞬态上插帧/丢帧造成可闻毛刺。
const AUDIO_PHASE_LOCK_SAFE_FRAMES: number =
  Math.ceil(Math.max(ACCENT_DURATION_MS, WEAK_DURATION_MS) * 1.25 * SAMPLE_RATE / 1000);

function applyDitherFloorToRange(samples: Int16Array, start: number, end: number): void {
  for (let i = start; i < end; i++) {
    const tpdf = (Math.random() + Math.random() - 1.0) * DITHER_FLOOR_GAIN;
    samples[i] = Math.round(tpdf * 32767);
  }
}

function applyDitherFloor(data: ArrayBuffer): void {
  const samples = new Int16Array(data);
  applyDitherFloorToRange(samples, 0, samples.length);
}

export type BeatCallback = (beatIndex: number, beatInBar: number, scheduledAtMonoMs: number) => void;

export interface TransportVisualSnapshot {
  revision: number;
  running: boolean;
  playheadMs: number;
  mainPlayheadMs: number;
  mainBeatIndex: number;
  beatIndex: number;
  beatInBar: number;
  beatPhase: number;
  countIn: boolean;
}

/** Timing metadata for a chirp placed on the renderer's presentation timeline. */
export interface CalibrationSignalTiming {
  presentationMonoMs: number;
  hardwareLatencyMs: number;
}

interface CalibrationClockSample {
  framePos: number;
  timestampMonoMs: number;
  queryMonoMs: number;
}

interface PendingCalibrationSignal {
  samples: Int16Array;
  startFrame: number;
  submitMonoMs: number;
  fullySubmitted: boolean;
}

interface RenderedBar {
  samples: Int16Array;
  frameCount: number;
  samplesPerBeat: number;
  beatsPerBar: number;
}

type AudioTransitionKind = 'play' | 'pause';

interface PendingAudioTransition {
  kind: AudioTransitionKind;
  token: number;
  targetFrame: number;
  beatIndex: number;
  countInBeats: number;
  outputLatencyMs: number;
}

export class MetronomeEngine {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private rendererWriteDataCallback: audio.AudioRendererWriteDataCallback | undefined = undefined;
  private rendererEpoch: number = 0;
  private rendererStreamId: number = -1;
  private rendererStarted: boolean = false;
  private rendererOperation: Promise<void> = Promise.resolve();
  // A calibration transaction stays exclusive until its target frame has
  // actually crossed the hardware playhead. Otherwise a retry can overwrite
  // the single mixed signal while the previous caller is still awaiting it.
  private calibrationOperation: Promise<void> = Promise.resolve();
  private outputLatencyMs: number = 0;
  private recoveringAudio: boolean = false;
  private writeCallbackCount: number = 0;
  private observedWriteCallbackCount: number = 0;
  private lastWriteProgressMs: number = 0;
  // A2DP 冷启动诊断：renderer.start() 之后、首个 writeData 回调之前的等待时间。
  private diagFirstWriteAfterStartPending: boolean = false;
  private accentBuffer: ArrayBuffer = ClickSound.buildAccentBuffer();
  private weakBuffer: ArrayBuffer = ClickSound.buildWeakBuffer();
  private beatCallback: BeatCallback = () => {
  };
  private timerId: number = -1;
  private audioStartTimerId: number = -1;
  private pauseTimerId: number = -1;
  private running: boolean = false;
  private bpm: number = 120;
  private beatsPerBar: number = 4;
  private beatPointStates: BeatPointState[] = defaultBeatPointStates(4);
  private beatIndex: number = 0;
  private offsetMs: number = 0;
  private nextBeatAtMs: number = 0;
  private rhythm: number = 0;
  private soundId: number = -1;
  private runToken: number = 0;
  private transportBpm: number = 120;
  private transportBeatsPerBar: number = 4;

  private pattern: SequencerPattern = BuiltInRhythmFactory.create(0, 4, this.beatPointStates);
  private customProgramRaw: string = '';
  private customProgram: DrumProgram | undefined = undefined;
  private customProgramLooping: boolean = true;
  private configurationToken: number = 0;
  private sampleBank: Map<string, ArrayBuffer> = new Map();
  private pendingSequence: RenderedBar[] = [];
  private pendingSequenceLooping: boolean = true;
  private pendingRevision: number = 0;
  private deferPendingSequenceActivation: boolean = false;
  private activeSequence: RenderedBar[] = [];
  private activeSequenceLooping: boolean = true;
  private activeSequenceFinished: boolean = false;
  private activeRevision: number = -1;
  private activeSequenceIndex: number = 0;
  private activeLoopStartIndex: number = 0;
  private activeBar: RenderedBar | undefined = undefined;
  private mainStartBeatIndex: number = 0;
  private applyMainStartOffset: boolean = false;
  private audioStreaming: boolean = false;
  private pendingAudioTransition: PendingAudioTransition | undefined = undefined;
  private audioSubmittedFrames: number = 0;
  /** 已提交但尚未被 DAC 播出的帧数（提交坐标 - 硬件播放坐标的偏移量）。 */
  private queueDepthFrames: number = 0;
  /** 播放中待执行的相位校正帧数（正值=插帧延迟，负值=丢帧追赶）。 */
  private phaseCorrectionFrames: number = 0;
  private audioFrameCursor: number = 0;
  private lastUnderflowCount: number = 0;
  private transportRevision: number = 0;
  private transportStartLocalMs: number = 0;
  private transportStartBeatIndex: number = 0;
  private transportCountInBeats: number = 0;
  private transportCountInDurationMs: number = 0;
  /**
   * Calibration supplies zero here because the user is measuring the complete
   * route delay themselves. Mixing the platform estimate into that trial would
   * make the displayed value describe only the estimate's residual error.
   */
  private transportOutputCompensationOverrideMs: number | undefined = undefined;
  /** Only the transport that established the current audio origin may read the hardware playhead. */
  private audioTimelineToken: number = -1;
  private audioTimelineLeadFrames: number = 0;
  private audioTimestampBaseFrame: number = 0;
  private audioTimestampBaseReady: boolean = false;
  private audioTimestampClockOffsetMs: number | undefined = undefined;
  private rendererStartedAtLocalMs: number = 0;
  private lastRenderedStreamFrame: number = 0;
  private audioClockLocked: boolean = false;
  private lastAudioRawFrame: number = -1;
  private lastAudioTimestampAgeMs: number = Number.POSITIVE_INFINITY;
  private lastAudioPlayheadMs: number = 0;
  private lastAudioSampleMonoMs: number = 0;
  private lastTimestampQueryMonoMs: number = -1;
  // Mic loopback is mixed into this renderer so the measured Bluetooth queue is
  // the same physical queue retained for the lobby and walking transport.
  private calibrationSignal: PendingCalibrationSignal | undefined = undefined;
  // Input calibration deliberately switches SPK -> BT before the headset probe.
  // The first probe on the new route must not reuse the old route's timestamp epoch.
  private calibrationRouteResetPending: boolean = false;
  // Playback warm-up may consume calibrationRouteResetPending before the mic
  // page starts. Keep this separate bit until the mic-only path has rebuilt a
  // renderer whose frame origin belongs to the new physical route.
  private micCalibrationRendererRebuildPending: boolean = false;
  // Only a flushed or newly-created stream has the same zero point for
  // AudioTimestampInfo.framePos and audioSubmittedFrames. Mic calibration is
  // not allowed to use the elapsed-wall-clock base heuristic used by playback.
  private calibrationFrameOriginExact: boolean = false;

  private handleWriteData(data: ArrayBuffer): audio.AudioDataCallbackResult {
    this.writeCallbackCount++;
    this.lastWriteProgressMs = MonotonicClock.nowMs();
    if (this.diagFirstWriteAfterStartPending) {
      this.diagFirstWriteAfterStartPending = false;
      const elapsed = MonotonicClock.nowMs() - this.rendererStartedAtLocalMs;
      console.info(`[A2DP-DIAG] first writeData after start: +${elapsed}ms (A2DP/media-link establishment)`);
    }
    this.fillAudioData(data);
    return audio.AudioDataCallbackResult.VALID;
  }

  configure(rhythm: number, soundId: number): void {
    this.configurationToken++;
    const leavingProgram = this.customProgram !== undefined;
    const rhythmChanged = this.rhythm !== rhythm;
    const soundChanged = this.soundId !== soundId;
    this.rhythm = rhythm;
    this.soundId = soundId;
    this.customProgramRaw = '';
    this.customProgram = undefined;
    this.customProgramLooping = true;
    this.sampleBank = new Map();
    if (soundChanged) {
      this.accentBuffer = ClickSound.buildTone(soundId === 1 ? 1200 : soundId === 2 ? 440 : 880, ACCENT_DURATION_MS, 0.85);
      this.weakBuffer = ClickSound.buildTone(soundId === 1 ? 900 : soundId === 2 ? 330 : 660, WEAK_DURATION_MS, 0.55);
    }
    if (rhythmChanged) {
      this.pattern = BuiltInRhythmFactory.create(this.rhythm, this.beatsPerBar, this.beatPointStates);
    }
    if (leavingProgram || rhythmChanged || soundChanged || this.pendingSequence.length === 0) {
      this.rebuildPendingSequence([this.pattern], true);
    }
  }

  /**
   * Route confirmation must contain exactly one accent and one weak click.
   * A finite rendered sequence avoids racing a timer against frames that the
   * Bluetooth renderer has already queued, which previously produced one or
   * two audible clicks depending on queue depth.
   */
  configureRouteProbeClickPair(): void {
    this.configurationToken++;
    this.bpm = 120;
    this.beatsPerBar = 2;
    this.rhythm = 0;
    this.customProgramRaw = '';
    this.customProgram = undefined;
    this.customProgramLooping = false;
    this.sampleBank = new Map();
    if (this.soundId !== 0) {
      this.soundId = 0;
      this.accentBuffer = ClickSound.buildTone(880, ACCENT_DURATION_MS, 0.85);
      this.weakBuffer = ClickSound.buildTone(660, WEAK_DURATION_MS, 0.55);
    }
    this.beatPointStates = defaultBeatPointStates(2);
    this.pattern = BuiltInRhythmFactory.create(0, 2, this.beatPointStates);
    this.rebuildPendingSequence([this.pattern], false);
  }

  async configureProgram(raw: string, looping: boolean = true): Promise<void> {
    // Even an already-applied request must invalidate older sample loads: a
    // late one-shot preview must never replace the walking transport's loop.
    const token = ++this.configurationToken;
    if (raw.length === 0 || (raw === this.customProgramRaw && looping === this.customProgramLooping)) {
      return;
    }
    const program = parseDrumProgram(raw);
    const bank = await DrumSampleBank.loadStyle(program.styleKey);
    if (token !== this.configurationToken) {
      return;
    }
    this.customProgramRaw = raw;
    this.customProgram = program;
    this.customProgramLooping = looping;
    this.sampleBank = bank;
    this.rebuildPendingSequence(buildProgramSequence(program), looping);
  }

  setBeatCallback(callback: BeatCallback): void {
    this.beatCallback = callback;
  }

  setOffsetMs(offsetMs: number): void {
    this.offsetMs = offsetMs;
  }

  setBpm(bpm: number, beatsPerBar: number): void {
    const bpmChanged = this.bpm !== bpm;
    const meterChanged = this.beatsPerBar !== beatsPerBar;
    this.bpm = bpm;
    this.beatsPerBar = beatsPerBar;
    if (meterChanged) {
      this.beatPointStates = normalizeBeatPointStates(this.beatPointStates, this.beatsPerBar);
      this.pattern = BuiltInRhythmFactory.create(this.rhythm, this.beatsPerBar, this.beatPointStates);
    }
    if (bpmChanged || meterChanged || this.pendingSequence.length === 0) {
      if (this.customProgram !== undefined) {
        this.customProgram.beatsPerBar = beatsPerBar;
        this.rebuildPendingSequence(buildProgramSequence(this.customProgram), this.customProgramLooping);
      } else {
        this.rebuildPendingSequence([this.pattern], true);
      }
    }
  }

  setBeatPointStates(states: BeatPointState[]): void {
    const normalized = normalizeBeatPointStates(states, this.beatsPerBar);
    if (normalized.join(',') === this.beatPointStates.join(',')) {
      return;
    }
    this.beatPointStates = normalized;
    this.pattern = BuiltInRhythmFactory.create(this.rhythm, this.beatsPerBar, this.beatPointStates);
    if (this.customProgram !== undefined) {
      this.rebuildPendingSequence(buildProgramSequence(this.customProgram), this.customProgramLooping);
    } else {
      this.rebuildPendingSequence([this.pattern], true);
    }
  }

  getBeatIndex(): number {
    return this.beatIndex;
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 视觉「跑道」由共享的单调墙钟时间轴驱动（已通过 ClockSync 对齐），而不是本地音频
   * presentation 时钟。音频 presentation 时钟依赖每台手机各自不同的 outputLatencyMs，
   * 该值在无线路由（尤其蓝牙 A2DP）上不可靠且设备间差异大，若用它驱动画面会导致多机画面互偏。
   */
  getVisualSnapshot(): TransportVisualSnapshot {
    if (!this.running || this.transportStartLocalMs <= 0) {
      return {
        revision: this.transportRevision,
        running: false,
        playheadMs: 0,
        mainPlayheadMs: 0,
        mainBeatIndex: 0,
        beatIndex: this.beatIndex,
        beatInBar: 0,
        beatPhase: 0,
        countIn: false
      };
    }

    const now = MonotonicClock.nowMs();
    // 视觉时间轴与音频硬件播放头解耦：统一走 ClockSync 对齐后的墙钟逻辑时间轴，
    // 保证各机画面一致。音频侧的对齐（相位校正）仍使用 readAudioPlayheadMs，不受影响。
    const playheadMs = now - this.transportStartLocalMs;
    const beatMs = 60000 / Math.max(1, this.transportBpm);
    const started = playheadMs >= 0;
    const presentedAtLocalMs = this.transportStartLocalMs + playheadMs;
    const beatOffsetFromNext = started ? Math.floor((presentedAtLocalMs - this.nextBeatAtMs) / beatMs) : 0;
    const beatIndex = started ? this.beatIndex + beatOffsetFromNext : this.transportStartBeatIndex;
    const beatStartAtMs = this.nextBeatAtMs + beatOffsetFromNext * beatMs;
    const beatPhase = started ? (presentedAtLocalMs - beatStartAtMs) / beatMs : 0;
    const countIn = this.transportCountInBeats > 0 && (!started ||
      beatIndex < this.transportStartBeatIndex + this.transportCountInBeats);
    const countInBeat = beatIndex - this.transportStartBeatIndex;
    return {
      revision: this.transportRevision,
      running: true,
      playheadMs: playheadMs,
      mainPlayheadMs: playheadMs - this.transportCountInDurationMs,
      mainBeatIndex: Math.max(0,
        beatIndex - this.transportStartBeatIndex - this.transportCountInBeats),
      beatIndex: beatIndex,
      beatInBar: started ? (countIn ? (countInBeat % this.transportBeatsPerBar) + 1 :
        (beatIndex % this.transportBeatsPerBar) + 1) : 0,
      beatPhase: started ? Math.max(0, Math.min(0.999999, beatPhase)) : 0,
      countIn: countIn
    };
  }

  async ensureRenderer(): Promise<void> {
    if (this.renderer !== undefined) {
      return;
    }
    await this.createRenderer();
  }

  private async createRenderer(): Promise<audio.AudioRenderer> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const rendererInfo: audio.AudioRendererInfo = {
      // STREAM_USAGE_MUSIC 默认走低功耗渲染器（内部缓冲最大 1000ms），
      // 该缓冲不被 getAudioTimestampInfo / getLatency 上报，会导致设备间数百 ms 的可闻偏差。
      // 改用 STREAM_USAGE_GAME 走普通/低时延通路，规避低功耗大缓冲。
      usage: audio.StreamUsage.STREAM_USAGE_GAME,
      rendererFlags: 0
    };
    const created = await audio.createAudioRenderer({
      streamInfo: streamInfo,
      rendererInfo: rendererInfo
    });
    const rendererEpoch = ++this.rendererEpoch;
    const writeDataCallback: audio.AudioRendererWriteDataCallback = (data: ArrayBuffer) => {
      // release()/recreate can leave an already-queued callback from the old
      // stream. It must not advance the new stream's submitted-frame counter.
      if (this.renderer !== created || this.rendererEpoch !== rendererEpoch) {
        return audio.AudioDataCallbackResult.INVALID;
      }
      return this.handleWriteData(data);
    };
    this.renderer = created;
    this.rendererWriteDataCallback = writeDataCallback;
    created.on('writeData', writeDataCallback);
    created.on('stateChange', (state: audio.AudioState) => {
      if (this.renderer !== created) { return; }
      console.info(`MetronomeEngine renderer state=${state}, running=${this.running}, token=${this.runToken}`);
      this.rendererStarted = state === audio.AudioState.STATE_RUNNING;
    });
    created.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (this.renderer !== created) { return; }
      console.warn(`MetronomeEngine audio interrupt: hint=${event.hintType}, force=${event.forceType}, token=${this.runToken}`);
      // A forced pause must remain paused until the system grants focus back.
      // Restarting immediately would compete with calls or other audio owners.
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME && this.running) {
        void this.recoverAudio('focus resumed');
      }
    });
    // 只读诊断：读取框架分配的流 ID（不改 stream usage / 状态 / 缓冲），失败静默。
    try {
      this.rendererStreamId = created.getAudioStreamIdSync();
      console.info(`MetronomeEngine streamId=${this.rendererStreamId}`);
    } catch (e) {
      this.rendererStreamId = -1;
    }
    return created;
  }

  /**
   * Schedule a one-shot calibration signal on this renderer's stream timeline.
   * The returned local monotonic time is the renderer-presentation target of
   * the first signal frame. Production playback schedules against this same
   * frame clock, so the calibration must not count submit-to-presentation queue
   * depth as output latency and then compensate that queue a second time.
   */
  async scheduleCalibrationSignal(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    const task: Promise<CalibrationSignalTiming> = this.calibrationOperation.then(
      (): Promise<CalibrationSignalTiming> =>
        this.scheduleCalibrationSignalExclusive(signal, targetAtLocalMonoMs)
    );
    this.calibrationOperation = task.then(
      (): void => {},
      (): void => {}
    );
    return task;
  }

  private async scheduleCalibrationSignalExclusive(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    await this.ensureRenderer();
    this.pause();
    await this.ensureSilentRendererRunning(true);
    // Warm the physical route before choosing a frame target so its timestamp
    // and A2DP link match the stream that production will keep using. Queue
    // depth itself is deliberately excluded by the presentation-time anchor.
    await this.warmUpRenderQueueForCalibration();
    let presentationMonoMs = targetAtLocalMonoMs;
    let hardwareLatencyMs = -1;
    await this.queueRendererOperation(async () => {
      const renderer = this.renderer;
      if (renderer === undefined || !this.rendererStarted ||
        renderer.state !== audio.AudioState.STATE_RUNNING) {
        throw new Error('校准音频渲染器未运行');
      }

      const clock = await this.readStableCalibrationClock(renderer);
      if (clock === undefined) {
        // A wall-clock/queue-depth fallback is acceptable for live playback,
        // but not for calibration: an unknown queue would be folded back into
        // the saved compensation and recreate the submit-anchor bug.
        this.calibrationRouteResetPending = true;
        this.micCalibrationRendererRebuildPending = true;
        throw new Error('未取得稳定的音频硬件时间戳，请保持当前输出设备后重试');
      }
      const targetFrame = Math.max(this.audioSubmittedFrames,
        Math.round(clock.framePos +
          (targetAtLocalMonoMs - clock.timestampMonoMs) * SAMPLE_RATE / 1000));
      // This forward estimate is only used to diagnose the scheduled queue.
      // The returned anchor is measured after framePos actually crosses the
      // target, so a future A2DP stall cannot turn into saved compensation.
      const scheduledPresentationMonoMs = clock.timestampMonoMs +
        (targetFrame - clock.framePos) * 1000 / SAMPLE_RATE;
      const pendingSignal: PendingCalibrationSignal = {
        samples: signal,
        startFrame: targetFrame,
        submitMonoMs: -1,
        fullySubmitted: false
      };
      this.calibrationSignal = pendingSignal;
      // getAudioTimestampInfoSync() places the anchor at the frame written to
      // hardware. Only the downstream HAL/driver/device leg remains; SOFTWARE
      // has already elapsed and must not be subtracted again during input calibration.
      hardwareLatencyMs = MetronomeEngine.readHardwareLatencyMs(renderer);
      const scheduledLeadMs = scheduledPresentationMonoMs - clock.queryMonoMs;
      console.info(`[CalibDiag] schedule targetFrame=${targetFrame} playedFrames=${clock.framePos} ` +
        `submittedFrames=${this.audioSubmittedFrames} leadMs=${scheduledLeadMs.toFixed(1)} ` +
        `scheduledPresentationMonoMs=${scheduledPresentationMonoMs.toFixed(1)}`);

      // Keep the renderer operation locked through submit and hardware crossing.
      // A second probe therefore cannot replace calibrationSignal and mistake
      // this probe's callback/crossing for its own.
      const submitDeadline = MonotonicClock.nowMs() + 3000;
      while (this.calibrationSignal === pendingSignal &&
        pendingSignal.submitMonoMs < 0 && MonotonicClock.nowMs() < submitDeadline) {
        await MetronomeEngine.delay(4);
      }
      if (pendingSignal.submitMonoMs < 0) {
        if (this.calibrationSignal === pendingSignal) {
          this.calibrationSignal = undefined;
        }
        throw new Error('校准音未能及时写入音频流，请重试');
      }
      const crossedPresentationMonoMs = await this.waitForCalibrationFrameCrossing(
        renderer, targetFrame, clock, pendingSignal);
      if (crossedPresentationMonoMs === undefined) {
        if (this.calibrationSignal === pendingSignal) {
          this.calibrationSignal = undefined;
        }
        this.calibrationRouteResetPending = true;
        this.micCalibrationRendererRebuildPending = true;
        throw new Error('未确认校准音越过硬件播放头，请重试');
      }
      // Do not let the next probe clear/replace this signal while its 500ms
      // tail is still waiting for writeData buffers.
      const completeDeadline = MonotonicClock.nowMs() + signal.length * 1000 / SAMPLE_RATE + 1000;
      while (this.calibrationSignal === pendingSignal && !pendingSignal.fullySubmitted &&
        MonotonicClock.nowMs() < completeDeadline) {
        await MetronomeEngine.delay(4);
      }
      if (!pendingSignal.fullySubmitted) {
        if (this.calibrationSignal === pendingSignal) {
          this.calibrationSignal = undefined;
        }
        throw new Error('校准音未完整写入音频流，请重试');
      }
      presentationMonoMs = crossedPresentationMonoMs;
      console.info(`[CalibAnchor] submitMonoMs=${pendingSignal.submitMonoMs.toFixed(1)} ` +
        `scheduledMonoMs=${scheduledPresentationMonoMs.toFixed(1)} ` +
        `presentationMonoMs=${presentationMonoMs.toFixed(1)} ` +
        `scheduleCorrectionMs=${(presentationMonoMs - scheduledPresentationMonoMs).toFixed(1)} ` +
        `submitToPresentationMs=${(presentationMonoMs - pendingSignal.submitMonoMs).toFixed(1)}`);
    });
    return {
      presentationMonoMs,
      hardwareLatencyMs
    };
  }

  /** Start the persistent renderer with dither only; do not start a UI transport. */
  private async ensureSilentRendererRunning(requireExactCalibrationClock: boolean = false): Promise<void> {
    await this.queueRendererOperation(async () => {
      let renderer = this.renderer;
      if (renderer === undefined) {
        throw new Error('校准音频渲染器不可用');
      }
      const now = MonotonicClock.nowMs();
      const routeReset = this.calibrationRouteResetPending;
      const rebuildForMic = requireExactCalibrationClock &&
        this.micCalibrationRendererRebuildPending;
      const healthy = this.rendererStarted && renderer.state === audio.AudioState.STATE_RUNNING &&
        now - this.lastWriteProgressMs < AUDIO_CALLBACK_STALL_MS && !routeReset && !rebuildForMic &&
        (!requireExactCalibrationClock || this.calibrationFrameOriginExact);
      if (healthy) {
        console.info(`[CalibDiag] renderer healthy, keep buffer, queueDepthFrames=${this.queueDepthFrames} submittedFrames=${this.audioSubmittedFrames}`);
        return;
      }
      console.info(`[CalibDiag] renderer NOT healthy, flush+restart, routeReset=${routeReset} ` +
        `micRebuild=${rebuildForMic} exactClock=${this.calibrationFrameOriginExact} state=${renderer.state} ` +
        `lastWriteAge=${now - this.lastWriteProgressMs}ms`);
      if (rebuildForMic) {
        try {
          if (renderer.state === audio.AudioState.STATE_RUNNING ||
            renderer.state === audio.AudioState.STATE_PAUSED) {
            this.rendererStarted = false;
            await renderer.stop();
          }
          // Route changes can leave the old stream exposing a frozen timestamp.
          // A new renderer gives framePos and audioSubmittedFrames one provable
          // origin; merely rebasing the old counter from elapsed wall time does not.
          const oldWriteDataCallback = this.rendererWriteDataCallback;
          this.renderer = undefined;
          this.rendererWriteDataCallback = undefined;
          this.rendererEpoch++;
          if (oldWriteDataCallback !== undefined) {
            renderer.off('writeData', oldWriteDataCallback);
          }
          renderer.off('stateChange');
          renderer.off('audioInterrupt');
          await renderer.release();
          renderer = await this.createRenderer();
        } catch (err) {
          // Continuing after a failed rebuild would forget the old queue only
          // in local bookkeeping and could save that queue as physical latency.
          throw new Error(`切换输出设备后重建音频时钟失败：${(err as Error).message}`);
        }
      } else {
        if (renderer.state === audio.AudioState.STATE_RUNNING ||
          renderer.state === audio.AudioState.STATE_PAUSED) {
          await this.haltRendererNow();
        }
        if (routeReset || requireExactCalibrationClock) {
          try {
            // Mic timing resets audioSubmittedFrames, so its physical stream
            // must be flushed as well. Flush resets framePos to the same zero.
            await renderer.flush();
          } catch (err) {
            throw new Error(`重置麦克回环音频时钟失败：${(err as Error).message}`);
          }
        }
      }
      this.resetAudioTimestampState();
      this.audioSubmittedFrames = 0;
      this.audioStreaming = false;
      this.pendingAudioTransition = undefined;
      this.calibrationSignal = undefined;
      this.calibrationFrameOriginExact = rebuildForMic || routeReset || requireExactCalibrationClock;
      this.rendererStartedAtLocalMs = MonotonicClock.nowMs();
      this.diagFirstWriteAfterStartPending = true;
      await renderer.start();
      this.rendererStarted = true;
      this.observedWriteCallbackCount = this.writeCallbackCount;
      this.lastWriteProgressMs = MonotonicClock.nowMs();
      this.calibrationRouteResetPending = false;
      if (requireExactCalibrationClock) {
        this.micCalibrationRendererRebuildPending = false;
      }
    });
  }

  /**
   * 播放前提前暖机：启动持久 renderer 并让 writeData 用 dither 填满队列到稳态。
   * 在「进入队伍 + 蓝牙已连」时调用，让第一拍/校准直接复用已到稳态的 renderer，
   * 跳过 A2DP 建链 + 队列从空重建的冷启动。
   */
  async warmUpRendererForPlayback(): Promise<void> {
    await this.ensureRenderer();
    await this.ensureSilentRendererRunning();
    console.info(`[WarmUp] playback renderer warm, queueDepthFrames=${this.queueDepthFrames} submittedFrames=${this.audioSubmittedFrames}`);
  }

  /**
   * 校准前暖机：flush 冷重启后，先让物理路由和硬件帧时间戳稳定，再选择 chirp 的
   * presentation target。固定等待也让正式播放复用的 A2DP 链路处于同一运行状态；
   * 软件队列深度不会进入校准值。
   */
  private async warmUpRenderQueueForCalibration(): Promise<void> {
    const CALIBRATION_WARMUP_MS = 1200;
    const renderer = this.renderer;
    // renderer 已运行超过一个暖机周期且 writeData 在流动 → 队列早已到稳态，跳过固定等待。
    const alreadyWarm = renderer !== undefined && this.rendererStarted &&
      renderer.state === audio.AudioState.STATE_RUNNING &&
      MonotonicClock.nowMs() - this.rendererStartedAtLocalMs >= CALIBRATION_WARMUP_MS &&
      MonotonicClock.nowMs() - this.lastWriteProgressMs < AUDIO_CALLBACK_STALL_MS;
    if (!alreadyWarm) {
      await MetronomeEngine.delay(CALIBRATION_WARMUP_MS);
    }
    if (renderer !== undefined && this.rendererStarted &&
      renderer.state === audio.AudioState.STATE_RUNNING) {
      this.readRenderedStreamFrames(renderer, MonotonicClock.nowMs());
    }
    console.info(`[CalibDiag] warm-up ${alreadyWarm ? 'skipped (already warm)' : 'done'} queueDepthFrames=${this.queueDepthFrames} submittedFrames=${this.audioSubmittedFrames}`);
  }

  async stopEngine(): Promise<void> {
    this.cancelTransport();
    await this.haltRenderer();
    const renderer = this.renderer;
    this.renderer = undefined;
    const writeDataCallback = this.rendererWriteDataCallback;
    this.rendererWriteDataCallback = undefined;
    this.rendererEpoch++;
    if (renderer !== undefined) {
      try {
        if (writeDataCallback !== undefined) {
          renderer.off('writeData', writeDataCallback);
        }
        renderer.off('stateChange');
        renderer.off('audioInterrupt');
        await renderer.release();
      } catch (err) {
        const e = err as BusinessError;
        console.warn(`MetronomeEngine release: ${e.message}`);
      }
    }
  }

  async scheduleFromLeaderStart(startAtLeaderMonoMs: number, beatIndex: number,
    countInBeats: number = 0, outputCompensationOverrideMs?: number): Promise<void> {
    const token = this.beginTransport();
    try {
      await this.ensureRenderer();
    } catch (err) {
      console.warn(`MetronomeEngine audio init failed, beats continue without sound: ${(err as Error).message}`);
    }
    if (token !== this.runToken) {
      return;
    }

    this.transportBpm = this.bpm;
    this.transportBeatsPerBar = this.beatsPerBar;
    const interval = 60000 / this.transportBpm;
    // ClockSync offset is leader - client, so convert leader time back to the local clock.
    let localStart = startAtLeaderMonoMs - this.offsetMs;
    let firstBeatIndex = beatIndex;
    let remainingCountInBeats = Math.max(0, countInBeats);
    const now = MonotonicClock.nowMs();
    if (localStart < now) {
      const missedBeats = Math.ceil((now - localStart) / interval);
      localStart += missedBeats * interval;
      firstBeatIndex += missedBeats;
      remainingCountInBeats = Math.max(0, remainingCountInBeats - missedBeats);
    }

    this.beatIndex = firstBeatIndex;
    this.nextBeatAtMs = localStart;
    this.transportStartLocalMs = localStart;
    this.transportStartBeatIndex = firstBeatIndex;
    this.transportCountInBeats = remainingCountInBeats;
    this.transportCountInDurationMs = remainingCountInBeats * interval;
    this.transportOutputCompensationOverrideMs = outputCompensationOverrideMs;
    this.transportRevision++;
    const rendererAlreadyRunning = this.rendererStarted &&
      this.renderer?.state === audio.AudioState.STATE_RUNNING;
    const audioDelay = rendererAlreadyRunning ? 0 :
      Math.max(0, localStart - MonotonicClock.nowMs() - AUDIO_PREROLL_MS);
    if (DEBUG) {
      console.info(`OneBeatSync schedule offsetMs=${this.offsetMs.toFixed(2)} ` +
        `startAtLeader=${startAtLeaderMonoMs.toFixed(2)}ms localStart=${localStart.toFixed(2)}ms ` +
        `now=${now.toFixed(2)}ms audioDelay=${audioDelay.toFixed(2)}ms ` +
        `countIn=${countInBeats} beat=${firstBeatIndex} bpm=${this.transportBpm.toFixed(1)}`);
    }
    this.audioStartTimerId = setTimeout(() => {
      void this.startAudioStream(localStart, firstBeatIndex, remainingCountInBeats, token,
        outputCompensationOverrideMs);
    }, audioDelay);
    const uiDelay = Math.max(0, localStart - MonotonicClock.nowMs());
    this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token), uiDelay);
  }

  pause(): void {
    this.cancelTransport();
  }

  /**
   * Schedule a logical pause on the shared clock while keeping the physical
   * renderer alive. Already queued audio therefore drains to the same audible
   * boundary on every device, then the callback supplies only the dither floor.
   */
  schedulePauseFromLeader(pauseAtLeaderMonoMs: number): void {
    const token = this.runToken;
    const localPauseAt = pauseAtLeaderMonoMs - this.offsetMs;
    this.refreshOutputLatency();
    const hardwarePauseAt = localPauseAt - this.outputLatencyMs;
    this.scheduleRunningTransition({
      kind: 'pause',
      token: token,
      targetFrame: this.estimateTargetStreamFrame(hardwarePauseAt),
      beatIndex: this.beatIndex,
      countInBeats: 0,
      outputLatencyMs: this.outputLatencyMs
    });
    if (this.pauseTimerId >= 0) {
      clearTimeout(this.pauseTimerId);
    }
    const delay = Math.max(0, localPauseAt - MonotonicClock.nowMs());
    this.pauseTimerId = setTimeout(() => {
      if (token !== this.runToken) {
        return;
      }
      this.running = false;
      if (this.timerId >= 0) {
        clearTimeout(this.timerId);
        this.timerId = -1;
      }
      this.transportRevision++;
    }, delay);
  }

  /** Leaving the walk/session may release the keep-alive stream completely. */
  async suspendRenderer(): Promise<void> {
    this.cancelTransport();
    await this.haltRenderer();
  }

  private beginTransport(): number {
    this.cancelTimers();
    this.runToken++;
    this.running = true;
    this.pendingAudioTransition = undefined;
    return this.runToken;
  }

  private cancelTransport(): void {
    this.running = false;
    this.audioStreaming = false;
    this.pendingAudioTransition = undefined;
    this.calibrationSignal = undefined;
    this.runToken++;
    this.cancelTimers();
  }

  private cancelTimers(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (this.audioStartTimerId >= 0) {
      clearTimeout(this.audioStartTimerId);
      this.audioStartTimerId = -1;
    }
    if (this.pauseTimerId >= 0) {
      clearTimeout(this.pauseTimerId);
      this.pauseTimerId = -1;
    }
  }

  private async startAudioStream(localAudibleStart: number, beatIndex: number,
    countInBeats: number, token: number, outputCompensationOverrideMs?: number): Promise<void> {
    await this.queueRendererOperation(async () => {
      const renderer = this.renderer;
      if (renderer === undefined || token !== this.runToken || !this.running) {
        return;
      }
      const now = MonotonicClock.nowMs();
      const rendererHealthy = this.rendererStarted &&
        renderer.state === audio.AudioState.STATE_RUNNING &&
        now - this.lastWriteProgressMs < AUDIO_CALLBACK_STALL_MS;
      if (rendererHealthy) {
        if (outputCompensationOverrideMs === undefined) {
          this.refreshOutputLatency();
        }
        const outputCompensationMs = outputCompensationOverrideMs ?? this.outputLatencyMs;
        const hardwareStartAt = localAudibleStart - outputCompensationMs;
        const btActive = AudioOutputMonitor.isBluetoothA2dpActive();
        const platformLatency = MetronomeEngine.readOutputLatencyMs(renderer);
        const targetFrame = this.estimateTargetStreamFrame(hardwareStartAt);
        const renderedFrames = this.readRenderedStreamFrames(renderer, now);
        // 帧映射诊断：targetFrame 应落在「now + (audible−compensation−now)」处；
        // 若 rendered 与 queueDepth 异常大（未上报的硬件缓冲），会直接暴露早出声量级。
        const frameLeadMs = renderedFrames === undefined ? Number.NaN :
          (targetFrame - renderedFrames) / SAMPLE_RATE * 1000;
        const actualOutputMs = this.queueDepthFrames * 1000 / SAMPLE_RATE;
        console.info(`[SyncDiag] route=${btActive ? 'BT' : 'SPK'} beat=${beatIndex} ` +
          `leaderAudible=${(localAudibleStart + this.offsetMs).toFixed(2)}ms offsetMs=${this.offsetMs.toFixed(1)} ` +
          `audible=${localAudibleStart.toFixed(2)}ms compensation=${outputCompensationMs}ms ` +
          `hardware=${hardwareStartAt.toFixed(2)}ms platform=${platformLatency}ms ` +
          `calibrated=${getCalibrationMs()}ms inputLatency=${getInputLatencyMs()}ms ` +
          `delta=${(outputCompensationMs - platformLatency).toFixed(1)}ms ` +
          `actualOutput=${actualOutputMs.toFixed(1)}ms actualDiff=${(actualOutputMs - platformLatency).toFixed(1)}ms ` +
          `targetFrame=${targetFrame} rendered=${renderedFrames ?? -1} ` +
          `queueDepth=${this.queueDepthFrames} frameLeadMs=${frameLeadMs.toFixed(1)}`);
        const transition: PendingAudioTransition = {
          kind: 'play',
          token: token,
          targetFrame: targetFrame,
          beatIndex: beatIndex,
          countInBeats: countInBeats,
          outputLatencyMs: outputCompensationMs
        };
        this.scheduleRunningTransition(transition);
        if (DEBUG) {
          console.info(`OneBeatSync transition[continuous] audible=${localAudibleStart.toFixed(2)}ms ` +
            `hardware=${hardwareStartAt.toFixed(2)}ms targetFrame=${transition.targetFrame} ` +
            `submitted=${this.audioSubmittedFrames} latency=${outputCompensationMs}`);
        }
        return;
      }
      if (renderer.state === audio.AudioState.STATE_RUNNING ||
        renderer.state === audio.AudioState.STATE_PAUSED) {
        // A RUNNING state without write callbacks is not a usable keep-alive
        // stream. Rebuilding it here is recovery, rather than a normal transport switch.
        await this.haltRendererNow();
      }
      await this.startAudioStreamNow(localAudibleStart, beatIndex, countInBeats, token,
        outputCompensationOverrideMs);
    });
  }

  private async startAudioStreamNow(localAudibleStart: number, beatIndex: number,
    countInBeats: number, token: number, outputCompensationOverrideMs?: number): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined || token !== this.runToken || !this.running) {
      return;
    }
    // A physical restart resets only the stream clock. Normal play/pause/BPM
    // transitions never enter this path once the renderer is running.
    this.resetAudioTimestampState();
    const rendererStartRequestedAtMs = MonotonicClock.nowMs();
    this.rendererStartedAtLocalMs = rendererStartRequestedAtMs;
    this.audioSubmittedFrames = 0;
    this.audioStreaming = false;
    const outputCompensationMs = outputCompensationOverrideMs ?? this.outputLatencyMs;
    const provisionalHardwareStart = localAudibleStart - outputCompensationMs;
    const provisionalTransition: PendingAudioTransition = {
      kind: 'play',
      token: token,
      targetFrame: Math.max(0,
        Math.round((provisionalHardwareStart - rendererStartRequestedAtMs) * SAMPLE_RATE / 1000)),
      beatIndex: beatIndex,
      countInBeats: countInBeats,
      outputLatencyMs: outputCompensationMs
    };
    this.scheduleRunningTransition(provisionalTransition);
    try {
      await renderer.start();
      if (token !== this.runToken || !this.running) {
        return;
      }
      this.rendererStarted = true;
      this.observedWriteCallbackCount = this.writeCallbackCount;
      this.lastWriteProgressMs = MonotonicClock.nowMs();
      this.diagFirstWriteAfterStartPending = true;
      try {
        const coldLatency = renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_ALL);
        const calMs = getCalibrationMs();
        console.info(`[A2DP-DIAG] start() returned, getLatency(ALL)=${coldLatency}ms, ` +
          `outputCompensationMs=${outputCompensationOverrideMs ?? this.outputLatencyMs}, ` +
          `calibrationMs=${calMs}, ` +
          `override=${outputCompensationOverrideMs === undefined ? 'none' : outputCompensationOverrideMs}`);
      } catch (_e) {
        console.info(`[A2DP-DIAG] start() returned, getLatency unavailable`);
      }
      try {
        const activeDevices = await renderer.getCurrentOutputDevices();
        const activeTypes: number[] = [];
        for (let i = 0; i < activeDevices.length; i++) {
          activeTypes.push(activeDevices[i].deviceType);
        }
        console.info(`[A2DP-DIAG] renderer active output deviceTypes=[${activeTypes.join(',')}]`);
      } catch (_e) {
        console.info(`[A2DP-DIAG] renderer.getCurrentOutputDevices() unavailable`);
      }
      await this.lockAudioStartToPresentationClock(renderer, localAudibleStart,
        rendererStartRequestedAtMs, token, outputCompensationOverrideMs);
      if (token !== this.runToken || !this.running) {
        return;
      }
      await this.settleOutputLatency(renderer, localAudibleStart, beatIndex, countInBeats, token,
        outputCompensationOverrideMs);
      this.primeAudioTimestamp(renderer);
      try {
        this.lastUnderflowCount = renderer.getUnderflowCountSync();
      } catch (_e) {
        this.lastUnderflowCount = 0;
      }
    } catch (err) {
      this.audioStreaming = false;
      this.pendingAudioTransition = undefined;
      const e = err as BusinessError;
      console.warn(`MetronomeEngine start: ${e.message}`);
    }
  }

  private async haltRenderer(): Promise<void> {
    await this.queueRendererOperation(() => this.haltRendererNow());
  }

  private queueRendererOperation(operation: () => Promise<void>): Promise<void> {
    // A delayed recovery/suspend must finish before the next start, otherwise
    // it can stop the new stream after the UI has already resumed walking.
    const queued = this.rendererOperation.then(operation, operation);
    this.rendererOperation = queued.catch(() => {});
    return queued;
  }

  private async haltRendererNow(): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined || (renderer.state !== audio.AudioState.STATE_RUNNING &&
      renderer.state !== audio.AudioState.STATE_PAUSED)) {
      return;
    }
    this.rendererStarted = false;
    try {
      await renderer.stop();
    } catch (_e) {
      // A concurrent stop or release may already have changed the renderer state.
    }
  }

  private emitBeatAndScheduleNext(token: number): void {
    if (!this.running || token !== this.runToken) {
      return;
    }
    let interval = 60000 / this.transportBpm;
    const now = MonotonicClock.nowMs();
    if (this.nextBeatAtMs < now) {
      const skipped = Math.floor((now - this.nextBeatAtMs) / interval);
      if (skipped > 0) {
        this.nextBeatAtMs += skipped * interval;
        this.beatIndex += skipped;
      }
    }
    const beatInBar = (this.beatIndex % this.transportBeatsPerBar) + 1;
    this.beatCallback(this.beatIndex, beatInBar, this.nextBeatAtMs);
    this.beatIndex++;

    if (beatInBar === 1) {
      this.reportUnderflowIfNeeded();
    }
    interval = 60000 / this.transportBpm;
    this.nextBeatAtMs += interval;
    this.checkAudioProgress(now);
    const wait = Math.max(0, this.nextBeatAtMs - MonotonicClock.nowMs());
    this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token), wait);
  }

  private rebuildPendingSequence(patterns: SequencerPattern[], looping: boolean): void {
    const sequence: RenderedBar[] = [];
    for (let i = 0; i < patterns.length; i++) {
      sequence.push(this.renderBar(patterns[i]));
    }
    this.pendingSequence = sequence;
    this.pendingSequenceLooping = looping;
    this.pendingRevision++;
    // Configuration packets arrive before their shared transport boundary. The
    // old sequence must keep looping until that boundary instead of switching
    // on whichever device happens to finish its current bar first.
    this.deferPendingSequenceActivation = this.audioStreaming;
  }

  private renderBar(pattern: SequencerPattern, applyBeatPointPattern: boolean = true): RenderedBar {
    const samplesPerBeat = SAMPLE_RATE * 60 / Math.max(1, this.bpm);
    const frameCount = Math.max(1, Math.round(samplesPerBeat * pattern.beatsPerBar));
    const data = new ArrayBuffer(frameCount * BYTES_PER_SAMPLE);
    const output = new DataView(data);
    applyDitherFloor(data);

    for (let eventIndex = 0; eventIndex < pattern.events.length; eventIndex++) {
      const event = pattern.events[eventIndex];
      const eventBeat = Math.floor(event.tick / pattern.ticksPerBeat) % Math.max(1, pattern.beatsPerBar);
      const pointState = this.beatPointStates[eventBeat] ?? 'normal';
      if (applyBeatPointPattern && pointState === 'silent') {
        continue;
      }
      const bankSample = this.sampleBank.get(event.sampleKey);
      const sourceData = bankSample !== undefined ? bankSample :
        event.sampleKey === 'accent' ? this.accentBuffer : this.weakBuffer;
      const source = new DataView(sourceData);
      const sourceFrames = Math.floor(sourceData.byteLength / BYTES_PER_SAMPLE);
      const startFrame = Math.round(event.tick * samplesPerBeat / pattern.ticksPerBeat);
      const availableFrames = Math.min(sourceFrames, frameCount - startFrame);
      for (let frame = 0; frame < availableFrames; frame++) {
        const targetOffset = (startFrame + frame) * BYTES_PER_SAMPLE;
        const pointGain = applyBeatPointPattern && this.customProgram !== undefined && pointState === 'accent' ? 1.15 : 1;
        const mixed = output.getInt16(targetOffset, true) +
          source.getInt16(frame * BYTES_PER_SAMPLE, true) * event.velocity * pointGain;
        output.setInt16(targetOffset, Math.max(-32768, Math.min(32767, Math.round(mixed))), true);
      }
    }

    return {
      samples: new Int16Array(data),
      frameCount: frameCount,
      samplesPerBeat: samplesPerBeat,
      beatsPerBar: pattern.beatsPerBar
    };
  }

  private renderCountInBar(beats: number): RenderedBar {
    const events: SequencerEvent[] = [];
    for (let beat = 0; beat < beats; beat++) {
      events.push({
        tick: beat * DEFAULT_TICKS_PER_BEAT,
        sampleKey: beat === 0 ? 'accent' : 'weak',
        velocity: 1
      });
    }
    return this.renderBar(new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beats, events), false);
  }

  private prepareAudioCursor(beatIndex: number, countInBeats: number = 0): void {
    if (this.pendingSequence.length === 0) {
      this.rebuildPendingSequence([this.pattern], true);
    }
    const countInBar = countInBeats > 0 ? this.renderCountInBar(countInBeats) : undefined;
    this.activeSequence = countInBar === undefined ? this.pendingSequence : [countInBar, ...this.pendingSequence];
    this.activeSequenceLooping = this.pendingSequenceLooping;
    this.activeSequenceFinished = false;
    this.activeRevision = this.pendingRevision;
    this.deferPendingSequenceActivation = false;
    this.activeSequenceIndex = 0;
    this.activeLoopStartIndex = countInBar === undefined ? 0 : 1;
    this.activeBar = this.activeSequence[0];
    const bar = this.activeBar;
    if (bar === undefined) {
      this.audioFrameCursor = 0;
      return;
    }
    this.mainStartBeatIndex = beatIndex + countInBeats;
    this.applyMainStartOffset = countInBar !== undefined;
    const beatInBar = ((beatIndex % bar.beatsPerBar) + bar.beatsPerBar) % bar.beatsPerBar;
    this.audioFrameCursor = countInBar === undefined ? Math.round(beatInBar * bar.samplesPerBeat) : 0;
    if (this.audioFrameCursor >= bar.frameCount) {
      this.audioFrameCursor = 0;
    }
  }

  private fillAudioData(data: ArrayBuffer): void {
    const output = new Int16Array(data);
    const bufferStartFrame = this.audioSubmittedFrames;
    let outputCursor = 0;
    while (outputCursor < output.length) {
      const transition = this.pendingAudioTransition;
      if (transition !== undefined && transition.targetFrame <= this.audioSubmittedFrames) {
        this.applyAudioTransition(transition);
        continue;
      }
      const framesBeforeTransition = transition === undefined ? output.length - outputCursor :
        Math.max(0, transition.targetFrame - this.audioSubmittedFrames);
      const outputLimit = Math.min(output.length, outputCursor + framesBeforeTransition);
      if (outputLimit <= outputCursor) {
        continue;
      }
      if (!this.audioStreaming) {
        applyDitherFloorToRange(output, outputCursor, outputLimit);
        this.audioSubmittedFrames += outputLimit - outputCursor;
        outputCursor = outputLimit;
        continue;
      }

      let bar = this.activeBar;
      if (bar === undefined && !this.activeSequenceFinished) {
        bar = this.pendingSequence.length > 0 ? this.pendingSequence[0] : undefined;
        this.activeBar = bar;
      }
      if (bar === undefined) {
        applyDitherFloorToRange(output, outputCursor, outputLimit);
        this.audioSubmittedFrames += outputLimit - outputCursor;
        outputCursor = outputLimit;
        continue;
      }

      // 播放中持续相位锁定：在拍点 dither floor（静音区）插帧/丢帧，逐步校正相位误差，
      // 避免在 click 瞬态上操作产生可闻毛刺。
      if (this.phaseCorrectionFrames !== 0) {
        const samplesPerBeat = Math.max(1, Math.round(bar.samplesPerBeat));
        const posInBeat = this.audioFrameCursor % samplesPerBeat;
        if (posInBeat >= AUDIO_PHASE_LOCK_SAFE_FRAMES) {
          if (this.phaseCorrectionFrames > 0) {
            const insertFrames = Math.min(this.phaseCorrectionFrames, outputLimit - outputCursor);
            applyDitherFloorToRange(output, outputCursor, outputCursor + insertFrames);
            outputCursor += insertFrames;
            this.audioSubmittedFrames += insertFrames;
            this.phaseCorrectionFrames -= insertFrames;
            continue;
          }
          const dropFrames = Math.min(-this.phaseCorrectionFrames,
            bar.frameCount - this.audioFrameCursor, outputLimit - outputCursor);
          this.audioFrameCursor += dropFrames;
          this.phaseCorrectionFrames += dropFrames;
          if (this.audioFrameCursor >= bar.frameCount) {
            this.advanceAudioBar();
          }
          continue;
        }
      }

      const copyFrames = Math.min(bar.frameCount - this.audioFrameCursor, outputLimit - outputCursor);
      output.set(bar.samples.subarray(this.audioFrameCursor, this.audioFrameCursor + copyFrames), outputCursor);
      outputCursor += copyFrames;
      this.audioFrameCursor += copyFrames;
      this.audioSubmittedFrames += copyFrames;
      if (this.audioFrameCursor >= bar.frameCount) {
        this.advanceAudioBar();
      }
    }
    this.mixCalibrationSignal(output, bufferStartFrame);
  }

  private mixCalibrationSignal(output: Int16Array, bufferStartFrame: number): void {
    const pendingSignal = this.calibrationSignal;
    if (pendingSignal === undefined) {
      return;
    }
    const signal = pendingSignal.samples;
    const signalStart = pendingSignal.startFrame;
    const signalEnd = signalStart + signal.length;
    const bufferEnd = bufferStartFrame + output.length;
    const mixStart = Math.max(bufferStartFrame, signalStart);
    const mixEnd = Math.min(bufferEnd, signalEnd);
    if (mixStart < mixEnd && pendingSignal.submitMonoMs < 0) {
      // Keep the actual buffer-submission time only to quantify queue lead in
      // [CalibAnchor]. Calibration itself is anchored to presentation time.
      pendingSignal.submitMonoMs = MonotonicClock.nowMs() +
        (signalStart - bufferStartFrame) * 1000 / SAMPLE_RATE;
    }
    for (let streamFrame = mixStart; streamFrame < mixEnd; streamFrame++) {
      const outputIndex = streamFrame - bufferStartFrame;
      const signalIndex = streamFrame - signalStart;
      const mixed = output[outputIndex] + signal[signalIndex];
      output[outputIndex] = Math.max(-32768, Math.min(32767, mixed));
    }
    if (mixStart < mixEnd && bufferEnd >= signalEnd) {
      pendingSignal.fullySubmitted = true;
      if (this.calibrationSignal === pendingSignal) {
        this.calibrationSignal = undefined;
      }
    }
  }

  private applyAudioTransition(transition: PendingAudioTransition): void {
    if (this.pendingAudioTransition !== transition) {
      return;
    }
    this.pendingAudioTransition = undefined;
    if (transition.token !== this.runToken) {
      return;
    }
    this.phaseCorrectionFrames = 0;
    if (transition.kind === 'pause') {
      this.audioStreaming = false;
      if (DEBUG) {
        console.info(`OneBeatSync transition[pause] frame=${transition.targetFrame} ` +
          `submitted=${this.audioSubmittedFrames}`);
      }
      return;
    }
    this.prepareAudioCursor(transition.beatIndex, transition.countInBeats);
    this.audioStreaming = true;
    // The click reaches the acoustic output outputLatencyMs after its hardware
    // presentation frame, so the visual/audio playhead origin includes both.
    this.audioTimelineLeadFrames = transition.targetFrame +
      Math.round(transition.outputLatencyMs * SAMPLE_RATE / 1000);
    this.audioTimelineToken = transition.token;
    this.lastAudioPlayheadMs = 0;
    this.lastAudioSampleMonoMs = this.transportStartLocalMs;
    if (DEBUG) {
      console.info(`OneBeatSync transition[play] frame=${transition.targetFrame} ` +
        `submitted=${this.audioSubmittedFrames} latency=${transition.outputLatencyMs}`);
    }
  }

  private async lockAudioStartToPresentationClock(
    renderer: audio.AudioRenderer,
    localAudibleStart: number,
    rendererStartRequestedAtMs: number,
    token: number,
    outputCompensationOverrideMs?: number
  ): Promise<void> {
    const lockDeadline = Math.min(
      rendererStartRequestedAtMs + AUDIO_CLOCK_LOCK_TIMEOUT_MS,
      localAudibleStart - AUDIO_CLOCK_LOCK_MIN_REMAINING_MS);
    let tsProbed = false;
    while (token === this.runToken && this.running && MonotonicClock.nowMs() <= lockDeadline) {
      const now = MonotonicClock.nowMs();
      const playedFramesNow = this.readRenderedStreamFrames(renderer, now);
      if (playedFramesNow !== undefined) {
        tsProbed = true;
        if (outputCompensationOverrideMs === undefined) {
          this.refreshOutputLatency();
        }
        const outputCompensationMs = outputCompensationOverrideMs ?? this.outputLatencyMs;
        const hardwareStartAt = localAudibleStart - outputCompensationMs;
        const btActive = AudioOutputMonitor.isBluetoothA2dpActive();
        const platformLatency = MetronomeEngine.readOutputLatencyMs(renderer);
        console.info(`[SyncDiag] route=${btActive ? 'BT' : 'SPK'} ` +
          `leaderAudible=${(localAudibleStart + this.offsetMs).toFixed(2)}ms offsetMs=${this.offsetMs.toFixed(1)} ` +
          `audible=${localAudibleStart.toFixed(2)}ms compensation=${outputCompensationMs}ms ` +
          `hardware=${hardwareStartAt.toFixed(2)}ms platform=${platformLatency}ms ` +
          `calibrated=${getCalibrationMs()}ms inputLatency=${getInputLatencyMs()}ms ` +
          `delta=${(outputCompensationMs - platformLatency).toFixed(1)}ms`);
        const targetFrame = Math.max(this.audioSubmittedFrames,
          Math.round(playedFramesNow + (hardwareStartAt - now) * SAMPLE_RATE / 1000));
        this.updatePendingPlayTransition(targetFrame, outputCompensationMs, token);
        const actualAudibleMs = now + (targetFrame - playedFramesNow) * 1000 / SAMPLE_RATE +
          outputCompensationMs;
        if (DEBUG) {
          console.info(`OneBeatSync lockClock[hw] expected=${localAudibleStart.toFixed(2)}ms ` +
            `actual=${actualAudibleMs.toFixed(2)}ms dev=${(actualAudibleMs - localAudibleStart).toFixed(2)}ms ` +
            `played=${playedFramesNow.toFixed(1)} submitted=${this.audioSubmittedFrames} ` +
            `queue=${this.queueDepthFrames.toFixed(1)} target=${targetFrame} latency=${outputCompensationMs}`);
        }
        return;
      }
      tsProbed = true;
      await MetronomeEngine.delay(AUDIO_CLOCK_LOCK_RETRY_MS);
    }
    if (DEBUG) {
      const transition = this.pendingAudioTransition;
      console.info(`OneBeatSync lockClock[fallback] expected=${localAudibleStart.toFixed(2)}ms ` +
        `rendererStart=${rendererStartRequestedAtMs.toFixed(2)} submitted=${this.audioSubmittedFrames} ` +
        `target=${transition?.targetFrame ?? -1} latency=${this.outputLatencyMs} probed=${tsProbed}`);
    }
  }

  private async settleOutputLatency(renderer: audio.AudioRenderer, localAudibleStart: number,
    beatIndex: number, countInBeats: number, token: number,
    outputCompensationOverrideMs?: number): Promise<void> {
    const samples: number[] = [];
    for (let i = 0; outputCompensationOverrideMs === undefined && i < 3; i++) {
      if (i > 0) {
        await MetronomeEngine.delay(80);
      }
      if (token !== this.runToken || !this.running ||
        MonotonicClock.nowMs() >= localAudibleStart - AUDIO_CLOCK_LOCK_MIN_REMAINING_MS) {
        break;
      }
      const latency = MetronomeEngine.readOutputLatencyOffsetMs(renderer);
      if (latency > 0) {
        samples.push(latency);
      }
    }
    if (samples.length > 0) {
      samples.sort((a, b) => a - b);
      this.outputLatencyMs = samples[Math.floor(samples.length / 2)];
    }
    if (token !== this.runToken || !this.running) {
      return;
    }
    const outputCompensationMs = outputCompensationOverrideMs ?? this.outputLatencyMs;
    const hardwareStartAt = localAudibleStart - outputCompensationMs;
    const btActive = AudioOutputMonitor.isBluetoothA2dpActive();
    const platformLatency = MetronomeEngine.readOutputLatencyMs(renderer);
    console.info(`[SyncDiag] route=${btActive ? 'BT' : 'SPK'} beat=${beatIndex} ` +
      `leaderAudible=${(localAudibleStart + this.offsetMs).toFixed(2)}ms offsetMs=${this.offsetMs.toFixed(1)} ` +
      `audible=${localAudibleStart.toFixed(2)}ms compensation=${outputCompensationMs}ms ` +
      `hardware=${hardwareStartAt.toFixed(2)}ms platform=${platformLatency}ms ` +
      `calibrated=${getCalibrationMs()}ms inputLatency=${getInputLatencyMs()}ms ` +
      `delta=${(outputCompensationMs - platformLatency).toFixed(1)}ms`);
    this.scheduleRunningTransition({
      kind: 'play',
      token: token,
      targetFrame: this.estimateTargetStreamFrame(hardwareStartAt),
      beatIndex: beatIndex,
      countInBeats: countInBeats,
      outputLatencyMs: outputCompensationMs
    });
  }

  private scheduleRunningTransition(transition: PendingAudioTransition): void {
    if (transition.token !== this.runToken) {
      return;
    }
    transition.targetFrame = Math.max(this.audioSubmittedFrames, transition.targetFrame);
    this.pendingAudioTransition = transition;
  }

  private updatePendingPlayTransition(targetFrame: number, outputLatencyMs: number, token: number): void {
    const transition = this.pendingAudioTransition;
    if (transition === undefined || transition.kind !== 'play' || transition.token !== token) {
      return;
    }
    transition.targetFrame = Math.max(this.audioSubmittedFrames, targetFrame);
    transition.outputLatencyMs = outputLatencyMs;
  }

  private estimateTargetStreamFrame(targetHardwareAtMs: number): number {
    const renderer = this.renderer;
    const now = MonotonicClock.nowMs();
    if (renderer !== undefined && this.rendererStarted) {
      const played = this.readRenderedStreamFrames(renderer, now);
      if (played !== undefined) {
        return Math.max(this.audioSubmittedFrames,
          Math.round(played + (targetHardwareAtMs - now) * SAMPLE_RATE / 1000));
      }
    }
    return Math.max(this.audioSubmittedFrames,
      Math.round(this.audioSubmittedFrames + (targetHardwareAtMs - now) * SAMPLE_RATE / 1000 -
        this.queueDepthFrames));
  }

  private static delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /** 读取当前音频路由的估算输出时延（DAC/设备/无线），毫秒。失败返回 -1。 */
  private static readOutputLatencyMs(renderer: audio.AudioRenderer): number {
    try {
      return renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_ALL);
    } catch (e) {
      return -1;
    }
  }

  /** Latency after a renderer timestamped frame has crossed into the hardware path. */
  private static readHardwareLatencyMs(renderer: audio.AudioRenderer): number {
    try {
      return renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_HARDWARE);
    } catch (e) {
      return -1;
    }
  }

  /**
   * 蓝牙 A2DP 才使用用户实测的「应用时间轴 → 耳朵」绝对补偿；外放和有线路由只采用
   * getLatency。这个边界必须保留，否则一次耳机校准会污染之后的手机外放时序。
   */
  private static readOutputLatencyOffsetMs(renderer: audio.AudioRenderer): number {
    const btActive = AudioOutputMonitor.isBluetoothA2dpActive();
    if (btActive) {
      const calibrated = getEffectiveCalibrationMs();
      if (calibrated >= 0) {
        // 校准补偿 vs 平台 getLatency(ALL) 的差值即「相对外放超前/滞后的量级」：
        // delta > 0 → 耳机比平台估算更早出声；delta ≈ 40ms 时正是早出声偏差的来源。
        // 同时打印 inputLatency 与 platform，便于反推 resultMs = calibrated + inputLatency。
        const platform = MetronomeEngine.readOutputLatencyMs(renderer);
        console.info(`[LatencyDiag] route=BT calibrated=${calibrated} platform=${platform} ` +
          `inputLatency=${getInputLatencyMs()} resultMs=${calibrated + getInputLatencyMs()} ` +
          `delta=${calibrated - platform}ms`);
        // 反推蓝牙路由下的输入侧时延，与外放路由测得的 inputLatency 对比，验证「输入时延路由无关」假设。
        const inputSPK = getInputLatencyMs();
        const resultMs = calibrated + inputSPK;
        const inputBT = resultMs - platform;
        console.info(`[LatencyDiag-InputRoute] inputSPK=${inputSPK} inputBT=${Math.round(inputBT * 10) / 10} ` +
          `diff=${Math.round((inputSPK - inputBT) * 10) / 10} resultMs=${resultMs} platform=${platform}`);
        return calibrated;
      }
    }
    const phoneLatency = MetronomeEngine.readOutputLatencyMs(renderer);
    if (phoneLatency <= 0) {
      return -1;
    }
    if (!btActive) {
      console.info(`[LatencyDiag] route=SPK phoneLatency=${phoneLatency} ` +
        `calibrated=${getEffectiveCalibrationMs()} inputLatency=${getInputLatencyMs()}`);
      return phoneLatency;
    }
    const btLink = btActive ? AudioOutputMonitor.estimateBluetoothLinkLatencyMs() : 0;
    const offset = phoneLatency + btLink;
    if (DEBUG) {
      console.info(`OneBeatSync outputLatency phone=${phoneLatency} btActive=${btActive} ` +
        `btLink=${btLink} offset=${offset}`);
    }
    return offset;
  }

  /** 刷新当前路由时延；无线查询失败时保留旧值，非无线查询失败时清除旧耳机补偿。 */
  private refreshOutputLatency(): void {
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    const latency = MetronomeEngine.readOutputLatencyOffsetMs(renderer);
    if (latency >= 0) {
      this.outputLatencyMs = latency;
    } else if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      // Do not carry a previously cached Bluetooth manual value into a route
      // whose platform latency is still settling.
      this.outputLatencyMs = 0;
    }
  }

  /**
   * Refresh route compensation. A real SPK/BT transition additionally marks
   * the calibration frame epoch dirty; the next mic probe rebuilds and warms it.
   */
  refreshOutputCalibration(routeChanged: boolean = false): void {
    if (routeChanged) {
      this.calibrationRouteResetPending = true;
      this.micCalibrationRendererRebuildPending = true;
    }
    this.refreshOutputLatency();
  }

  private advanceAudioBar(): void {
    if (this.activeRevision !== this.pendingRevision && !this.deferPendingSequenceActivation) {
      this.activeSequence = this.pendingSequence;
      this.activeSequenceLooping = this.pendingSequenceLooping;
      this.activeSequenceFinished = false;
      this.activeRevision = this.pendingRevision;
      this.activeSequenceIndex = 0;
      this.activeLoopStartIndex = 0;
    } else if (this.activeSequenceIndex + 1 < this.activeSequence.length) {
      this.activeSequenceIndex++;
    } else if (this.activeSequenceLooping && this.activeSequence.length > 0) {
      this.activeSequenceIndex = this.activeLoopStartIndex;
    } else {
      this.activeSequenceFinished = true;
    }
    this.activeBar = !this.activeSequenceFinished && this.activeSequence.length > 0 ?
      this.activeSequence[this.activeSequenceIndex] : undefined;
    this.audioFrameCursor = 0;
    if (this.applyMainStartOffset && this.activeBar !== undefined &&
      this.activeSequenceIndex === this.activeLoopStartIndex) {
      const mainBeatInBar = ((this.mainStartBeatIndex % this.activeBar.beatsPerBar) +
        this.activeBar.beatsPerBar) % this.activeBar.beatsPerBar;
      this.audioFrameCursor = Math.round(mainBeatInBar * this.activeBar.samplesPerBeat);
      this.applyMainStartOffset = false;
    }
  }

  private resetAudioTimestampState(): void {
    this.audioTimelineToken = -1;
    this.audioTimelineLeadFrames = 0;
    this.audioTimestampBaseFrame = 0;
    this.audioTimestampBaseReady = false;
    this.audioTimestampClockOffsetMs = undefined;
    this.rendererStartedAtLocalMs = 0;
    this.lastRenderedStreamFrame = 0;
    this.audioClockLocked = false;
    this.lastAudioRawFrame = -1;
    this.lastAudioTimestampAgeMs = Number.POSITIVE_INFINITY;
    this.lastAudioPlayheadMs = 0;
    this.lastAudioSampleMonoMs = 0;
    this.lastTimestampQueryMonoMs = -1;
    this.queueDepthFrames = 0;
    this.phaseCorrectionFrames = 0;
    this.calibrationFrameOriginExact = false;
  }

  /**
   * Read the hardware frame clock for mic calibration without the playback
   * path's elapsed-time base heuristic. Audio timestamps use the active
   * monotonic clock, while app scheduling uses startup uptime; sample both
   * clocks together so the timestamp's real age is preserved.
   */
  private readCalibrationClockSample(renderer: audio.AudioRenderer): CalibrationClockSample | undefined {
    if (!this.calibrationFrameOriginExact) {
      return undefined;
    }
    try {
      // Millisecond uptime is too coarse for a 100ms / +/-2% rate check. Read
      // both clock domains in nanoseconds and convert only after sampling.
      const startupBeforeMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const activeBeforeMs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const info = renderer.getAudioTimestampInfoSync();
      const activeAfterMs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const startupAfterMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      if (info.framePos < 0 || info.timestamp <= 0) {
        return undefined;
      }
      const queryMonoMs = (startupBeforeMs + startupAfterMs) / 2;
      const activeAtQueryMs = (activeBeforeMs + activeAfterMs) / 2;
      const activeToStartupMs = queryMonoMs - activeAtQueryMs;
      const timestampMonoMs = info.timestamp / 1000000 + activeToStartupMs;
      const timestampAgeMs = queryMonoMs - timestampMonoMs;
      if (!Number.isFinite(timestampMonoMs) || timestampAgeMs < -50 || timestampAgeMs > 2000) {
        return undefined;
      }
      return {
        framePos: info.framePos,
        timestampMonoMs,
        queryMonoMs
      };
    } catch (_e) {
      return undefined;
    }
  }

  /** Require monotonic frame progress at the configured 44.1 kHz before trusting calibration. */
  private async readStableCalibrationClock(
    renderer: audio.AudioRenderer
  ): Promise<CalibrationClockSample | undefined> {
    const MIN_RATE_WINDOW_MS = 100;
    const MAX_RATE_ERROR_RATIO = 0.02;
    const MAX_QUEUE_MS = 2500;
    let first: CalibrationClockSample | undefined = undefined;
    for (let retry = 0; retry < 20; retry++) {
      const current = this.readCalibrationClockSample(renderer);
      if (current !== undefined) {
        if (first === undefined) {
          first = current;
        } else if (current.framePos < first.framePos ||
          current.timestampMonoMs < first.timestampMonoMs) {
          return undefined;
        } else {
          const timestampDeltaMs = current.timestampMonoMs - first.timestampMonoMs;
          const frameDelta = current.framePos - first.framePos;
          if (timestampDeltaMs >= MIN_RATE_WINDOW_MS && frameDelta > 0) {
            const observedRateHz = frameDelta * 1000 / timestampDeltaMs;
            const rateErrorRatio = Math.abs(observedRateHz - SAMPLE_RATE) / SAMPLE_RATE;
            const timestampAgeMs = current.queryMonoMs - current.timestampMonoMs;
            const playedAtQuery = current.framePos +
              Math.max(0, timestampAgeMs) * SAMPLE_RATE / 1000;
            const queueFrames = this.audioSubmittedFrames - playedAtQuery;
            const queueMs = queueFrames * 1000 / SAMPLE_RATE;
            console.info(`[CalibClock] framePos=${current.framePos} submittedFrames=${this.audioSubmittedFrames} ` +
              `rateHz=${observedRateHz.toFixed(1)} ageMs=${timestampAgeMs.toFixed(1)} ` +
              `queueMs=${queueMs.toFixed(1)}`);
            if (rateErrorRatio > MAX_RATE_ERROR_RATIO || queueMs < -50 || queueMs > MAX_QUEUE_MS) {
              return undefined;
            }
            this.queueDepthFrames = Math.max(0, queueFrames);
            return current;
          }
        }
      }
      await MetronomeEngine.delay(20);
    }
    return undefined;
  }

  /**
   * Confirm the target with a timestamp sampled after the hardware playhead has
   * crossed it. A pre-target extrapolation cannot observe a later A2DP stall,
   * so it is diagnostic only and must never become the saved mic anchor.
   */
  private async waitForCalibrationFrameCrossing(renderer: audio.AudioRenderer,
    targetFrame: number, anchor: CalibrationClockSample,
    pendingSignal: PendingCalibrationSignal): Promise<number | undefined> {
    const MAX_RATE_ERROR_RATIO = 0.02;
    const rendererEpoch = this.rendererEpoch;
    const deadline = MonotonicClock.nowMs() + 4000;
    let previous = anchor;
    while (MonotonicClock.nowMs() < deadline) {
      if (this.renderer !== renderer || this.rendererEpoch !== rendererEpoch ||
        !this.rendererStarted || !this.calibrationFrameOriginExact ||
        this.calibrationRouteResetPending || this.micCalibrationRendererRebuildPending ||
        (this.calibrationSignal !== pendingSignal && !pendingSignal.fullySubmitted)) {
        return undefined;
      }
      const current = this.readCalibrationClockSample(renderer);
      if (current !== undefined) {
        if (current.framePos < previous.framePos ||
          current.timestampMonoMs < previous.timestampMonoMs) {
          return undefined;
        }
        const timestampDeltaMs = current.timestampMonoMs - anchor.timestampMonoMs;
        const frameDelta = current.framePos - anchor.framePos;
        if (timestampDeltaMs > 0 && frameDelta > 0) {
          const observedRateHz = frameDelta * 1000 / timestampDeltaMs;
          const rateErrorRatio = Math.abs(observedRateHz - SAMPLE_RATE) / SAMPLE_RATE;
          if (rateErrorRatio > MAX_RATE_ERROR_RATIO) {
            console.warn(`[CalibClock] crossing rate rejected rateHz=${observedRateHz.toFixed(1)} ` +
              `targetFrame=${targetFrame} framePos=${current.framePos}`);
            return undefined;
          }
          if (current.framePos >= targetFrame) {
            // Use the raw timestamped playhead, never query-time extrapolation.
            const presentationMonoMs = current.timestampMonoMs -
              (current.framePos - targetFrame) * 1000 / SAMPLE_RATE;
            console.info(`[CalibClock] crossed targetFrame=${targetFrame} framePos=${current.framePos} ` +
              `rateHz=${observedRateHz.toFixed(1)} overshootFrames=${current.framePos - targetFrame} ` +
              `presentationMonoMs=${presentationMonoMs.toFixed(1)}`);
            return presentationMonoMs;
          }
        }
        previous = current;
      }
      await MetronomeEngine.delay(8);
    }
    return undefined;
  }

  private primeAudioTimestamp(renderer: audio.AudioRenderer): void {
    this.readRenderedStreamFrames(renderer, MonotonicClock.nowMs());
  }

  private readAudioPlayheadMs(nowMs: number): number | undefined {
    const renderer = this.renderer;
    if (renderer === undefined || !this.rendererStarted) {
      return undefined;
    }
    if (this.audioClockLocked && this.lastTimestampQueryMonoMs >= 0 &&
      nowMs - this.lastTimestampQueryMonoMs < 8) {
      return this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs);
    }
    this.lastTimestampQueryMonoMs = nowMs;
    const renderedFrames = this.readRenderedStreamFrames(renderer, nowMs);
    if (renderedFrames === undefined) {
      return this.audioClockLocked ?
        this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs) : undefined;
    }
    const playheadMs = (renderedFrames - this.audioTimelineLeadFrames) * 1000 / SAMPLE_RATE;
    if (!Number.isFinite(playheadMs)) {
      return undefined;
    }
    this.audioClockLocked = true;
    this.lastAudioPlayheadMs = playheadMs;
    this.lastAudioSampleMonoMs = nowMs;
    return playheadMs;
  }

  /** Map the renderer's persistent frame counter into this stream's submitted-frame coordinate. */
  private readRenderedStreamFrames(renderer: audio.AudioRenderer, nowMs: number): number | undefined {
    try {
      const info = renderer.getAudioTimestampInfoSync();
      if (info.timestamp <= 0) {
        return undefined;
      }
      const rawTimestampMs = info.timestamp / 1000000;
      if (this.audioTimestampClockOffsetMs === undefined) {
        this.audioTimestampClockOffsetMs = rawTimestampMs - nowMs;
      }
      const timestampInLocalClock = rawTimestampMs - this.audioTimestampClockOffsetMs;
      const timestampAgeMs = nowMs - timestampInLocalClock;
      this.lastAudioTimestampAgeMs = timestampAgeMs;
      if (timestampAgeMs < -50 || timestampAgeMs > 2000) {
        return undefined;
      }
      if (!this.audioTimestampBaseReady) {
        // framePos can survive stop/flush on some devices. Anchor it to the
        // amount that could actually have played since this physical start.
        const elapsedFrames = Math.max(0,
          (nowMs - this.rendererStartedAtLocalMs) * SAMPLE_RATE / 1000);
        const playedEstimate = Math.min(this.audioSubmittedFrames, elapsedFrames);
        this.audioTimestampBaseFrame = info.framePos - playedEstimate;
        this.audioTimestampBaseReady = true;
        const clockOffset = this.audioTimestampClockOffsetMs === undefined ? 'NA' :
          this.audioTimestampClockOffsetMs.toFixed(1);
        console.info(`[ClockDiag] rawTs=${rawTimestampMs.toFixed(1)}ms now=${nowMs.toFixed(1)}ms ` +
          `clockOffset=${clockOffset}ms framePos=${info.framePos} ` +
          `elapsedFrames=${elapsedFrames.toFixed(0)} playedEstimate=${playedEstimate.toFixed(0)} ` +
          `baseFrame=${this.audioTimestampBaseFrame.toFixed(0)}`);
      } else if (this.lastAudioRawFrame >= 0 && info.framePos < this.lastAudioRawFrame) {
        this.audioTimestampBaseFrame = info.framePos - this.lastRenderedStreamFrame;
      }
      this.lastAudioRawFrame = info.framePos;
      // Presentation cannot advance beyond data already accepted by the
      // renderer. This clamp also contains stale first timestamps on routes
      // whose hardware clock becomes available late.
      const renderedFrames = Math.min(this.audioSubmittedFrames, Math.max(0,
        info.framePos - this.audioTimestampBaseFrame +
        Math.max(0, Math.min(250, timestampAgeMs)) * SAMPLE_RATE / 1000));
      this.lastRenderedStreamFrame = renderedFrames;
      this.queueDepthFrames = Math.max(0, this.audioSubmittedFrames - renderedFrames);
      return renderedFrames;
    } catch (_e) {
      // API 19+ exposes hardware timestamps; older devices retain the monotonic fallback.
      this.lastAudioTimestampAgeMs = Number.POSITIVE_INFINITY;
      return undefined;
    }
  }

  /** 当前音频播放头相对墙钟时间轴的相位误差（帧）。正值=音频偏快，需插帧延迟；负值=音频偏慢，需丢帧追赶。 */
  private measurePhaseErrorFrames(): number {
    if (!this.audioClockLocked || !this.audioStreaming || this.activeSequenceFinished) {
      return 0;
    }
    const nowMs = MonotonicClock.nowMs();
    const playhead = this.readAudioPlayheadMs(nowMs);
    if (playhead === undefined) {
      return 0;
    }
    const expected = nowMs - this.transportStartLocalMs;
    return Math.round((playhead - expected) * SAMPLE_RATE / 1000);
  }

  private reportUnderflowIfNeeded(): void {
    const renderer = this.renderer;
    if (renderer === undefined || !this.rendererStarted) {
      return;
    }
    try {
      const count = renderer.getUnderflowCountSync();
      if (count > this.lastUnderflowCount) {
        console.warn(`MetronomeEngine audio underflow: ${count - this.lastUnderflowCount}`);
        this.lastUnderflowCount = count;
      }
    } catch (_e) {
      // Diagnostics must never disturb the transport.
    }
  }

  private checkAudioProgress(nowMs: number): void {
    const renderer = this.renderer;
    if (!this.audioStreaming || renderer === undefined || this.recoveringAudio ||
      renderer.state !== audio.AudioState.STATE_RUNNING || this.activeSequenceFinished) {
      return;
    }
    // 播放中持续相位锁定：每拍评估一次相位误差，超出阈值就调度一小步插帧/丢帧，
    // 实际校正会在 fillAudioData 的 dither floor（静音区）中渐进完成。
    const phaseError = this.measurePhaseErrorFrames();
    if (Math.abs(phaseError) >= AUDIO_PHASE_LOCK_THRESHOLD_FRAMES) {
      const step = Math.max(-AUDIO_PHASE_LOCK_MAX_STEP_FRAMES,
        Math.min(AUDIO_PHASE_LOCK_MAX_STEP_FRAMES, phaseError));
      this.phaseCorrectionFrames += step;
    }
    if (this.observedWriteCallbackCount !== this.writeCallbackCount) {
      this.observedWriteCallbackCount = this.writeCallbackCount;
      this.lastWriteProgressMs = nowMs;
      return;
    }
    if (nowMs - this.lastWriteProgressMs >= AUDIO_CALLBACK_STALL_MS) {
      void this.recoverAudio(`writeData stalled for ${Math.round(nowMs - this.lastWriteProgressMs)}ms`);
    }
  }

  private async recoverAudio(reason: string): Promise<void> {
    if (!this.running || this.recoveringAudio || this.activeSequenceFinished) { return; }
    this.recoveringAudio = true;
    const token = this.runToken;
    const now = MonotonicClock.nowMs();
    const interval = 60000 / this.transportBpm;
    const skipped = Math.max(0, Math.ceil((now - this.nextBeatAtMs) / interval));
    const beatIndex = this.beatIndex + skipped;
    const localStart = this.nextBeatAtMs + skipped * interval;
    const countInBeats = Math.max(0,
      this.transportStartBeatIndex + this.transportCountInBeats - beatIndex);
    console.warn(`MetronomeEngine audio recovery: ${reason}, beat=${beatIndex}, token=${token}`);
    try {
      // Recovery is the exceptional path where rebuilding the physical stream
      // is intentional; normal pause/resume/configuration changes keep it alive.
      await this.haltRenderer();
      await this.startAudioStream(localStart, beatIndex, countInBeats, token,
        this.transportOutputCompensationOverrideMs);
    } catch (err) {
      console.warn(`MetronomeEngine audio recovery failed: ${(err as Error).message}`);
    } finally {
      this.recoveringAudio = false;
    }
  }
}
