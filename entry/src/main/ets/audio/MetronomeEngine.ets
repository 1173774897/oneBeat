import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClickSound, ACCENT_DURATION_MS, WEAK_DURATION_MS } from './ClickSound';
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

interface RenderedBar {
  samples: Int16Array;
  frameCount: number;
  samplesPerBeat: number;
  beatsPerBar: number;
}

export class MetronomeEngine {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private rendererStreamId: number = -1;
  private rendererStarted: boolean = false;
  private rendererOperation: Promise<void> = Promise.resolve();
  private outputLatencyMs: number = 0;
  private recoveringAudio: boolean = false;
  private writeCallbackCount: number = 0;
  private observedWriteCallbackCount: number = 0;
  private lastWriteProgressMs: number = 0;
  private accentBuffer: ArrayBuffer = ClickSound.buildAccentBuffer();
  private weakBuffer: ArrayBuffer = ClickSound.buildWeakBuffer();
  private beatCallback: BeatCallback = () => {
  };
  private timerId: number = -1;
  private audioStartTimerId: number = -1;
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

  private pattern: SequencerPattern = BuiltInRhythmFactory.create(0, 4, this.beatPointStates);
  private customProgramRaw: string = '';
  private customProgram: DrumProgram | undefined = undefined;
  private customProgramLooping: boolean = true;
  private configurationToken: number = 0;
  private sampleBank: Map<string, ArrayBuffer> = new Map();
  private pendingSequence: RenderedBar[] = [];
  private pendingSequenceLooping: boolean = true;
  private pendingRevision: number = 0;
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
  private audioLeadSamples: number = 0;
  private audioStartAnchorPending: boolean = false;
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
  private audioTimelineLeadFrames: number = 0;
  private audioTimestampBaseFrame: number = 0;
  private audioTimestampBaseReady: boolean = false;
  private audioClockLocked: boolean = false;
  private lastAudioRawFrame: number = -1;
  private lastAudioPlayheadMs: number = 0;
  private lastAudioSampleMonoMs: number = 0;
  private lastTimestampQueryMonoMs: number = -1;

  private readonly writeDataCallback: audio.AudioRendererWriteDataCallback = (data: ArrayBuffer) => {
    this.writeCallbackCount++;
    this.fillAudioData(data);
    return audio.AudioDataCallbackResult.VALID;
  };

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
   * Audio presentation is the master clock. Before the renderer exposes a stable
   * hardware timestamp, monotonic transport time is used as a short fallback.
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
    const audioPlayhead = this.readAudioPlayheadMs(now);
    const playheadMs = audioPlayhead !== undefined ? audioPlayhead : now - this.transportStartLocalMs;
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
      beatInBar: started ? (countIn ? (countInBeat % this.beatsPerBar) + 1 :
        (beatIndex % this.beatsPerBar) + 1) : 0,
      beatPhase: started ? Math.max(0, Math.min(0.999999, beatPhase)) : 0,
      countIn: countIn
    };
  }

  async ensureRenderer(): Promise<void> {
    if (this.renderer !== undefined) {
      return;
    }
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
    created.on('writeData', this.writeDataCallback);
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
    this.renderer = created;
    // 只读诊断：读取框架分配的流 ID（不改 stream usage / 状态 / 缓冲），失败静默。
    try {
      this.rendererStreamId = created.getAudioStreamIdSync();
      console.info(`MetronomeEngine streamId=${this.rendererStreamId}`);
    } catch (e) {
      this.rendererStreamId = -1;
    }
  }

  async stopEngine(): Promise<void> {
    this.cancelTransport();
    await this.haltRenderer();
    const renderer = this.renderer;
    this.renderer = undefined;
    if (renderer !== undefined) {
      try {
        renderer.off('writeData', this.writeDataCallback);
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
    countInBeats: number = 0): Promise<void> {
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
    this.transportRevision++;
    this.resetAudioTimestampState();
    const audioDelay = Math.max(0, localStart - MonotonicClock.nowMs() - AUDIO_PREROLL_MS);
    if (DEBUG) {
      console.info(`OneBeatSync schedule offsetMs=${this.offsetMs.toFixed(2)} ` +
        `startAtLeader=${startAtLeaderMonoMs.toFixed(2)}ms localStart=${localStart.toFixed(2)}ms ` +
        `now=${now.toFixed(2)}ms audioDelay=${audioDelay.toFixed(2)}ms ` +
        `countIn=${countInBeats} beat=${firstBeatIndex} bpm=${this.transportBpm.toFixed(1)}`);
    }
    this.audioStartTimerId = setTimeout(() => {
      void this.startAudioStream(localStart, firstBeatIndex, remainingCountInBeats, token);
    }, audioDelay);
    const uiDelay = Math.max(0, localStart - MonotonicClock.nowMs());
    this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token), uiDelay);
  }

  pause(): void {
    this.cancelTransport();
    void this.haltRenderer();
  }

  private beginTransport(): number {
    this.cancelTimers();
    this.runToken++;
    this.running = true;
    this.audioStreaming = false;
    return this.runToken;
  }

  private cancelTransport(): void {
    this.running = false;
    this.audioStreaming = false;
    this.audioStartAnchorPending = false;
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
  }

  private async startAudioStream(localStart: number, beatIndex: number,
    countInBeats: number, token: number): Promise<void> {
    // 声学输出延迟校准：提前提交音频，使可闻节拍对齐到 localStart。
    // UI 节拍仍以 localStart 为准，仅音频时间轴前移。
    // 符号修正：audibleStart = localStart - latency（正值=提前），运行时 getLatency 取代固定 -20。
    this.refreshOutputLatency();
    const acousticDelayMs = this.outputLatencyMs;
    const audibleStart = localStart - acousticDelayMs;
    if (DEBUG) {
      console.info(`OneBeatSync audio offsetMs=${this.offsetMs.toFixed(2)} ` +
        `localStart=${localStart.toFixed(2)}ms audibleStart=${audibleStart.toFixed(2)}ms ` +
        `acousticDelay=${acousticDelayMs} countIn=${countInBeats} beat=${beatIndex}`);
    }
    await this.queueRendererOperation(() => this.startAudioStreamNow(audibleStart, beatIndex, countInBeats, token));
  }

  private async startAudioStreamNow(localStart: number, beatIndex: number,
    countInBeats: number, token: number): Promise<void> {
    const renderer = this.renderer;
    if (renderer === undefined || token !== this.runToken || !this.running) {
      return;
    }
    await this.haltRendererNow();
    if (token !== this.runToken || !this.running) {
      return;
    }
    let rendererPositionReset = false;
    try {
      await renderer.flush();
      rendererPositionReset = true;
    } catch (_e) {
      // Some older renderers do not expose flush in the stopped state.
    }
    if (token !== this.runToken || !this.running) { return; }

    this.resetAudioTimestampState();
    this.prepareAudioCursor(beatIndex, countInBeats);
    const rendererStartRequestedAtMs = MonotonicClock.nowMs();
    const fallbackFirstBeatFrame = Math.max(0,
      Math.round((localStart - rendererStartRequestedAtMs) * SAMPLE_RATE / 1000));
    this.audioSubmittedFrames = 0;
    // 先用墙钟估算的 lead 占位：renderer.start() 会立即触发写回调，若这里保持 0，
    // 写回调会在 lock 完成前把整个大缓冲区灌满静音（overshoot），首拍被逼到 ~210ms 之后。
    this.audioLeadSamples = fallbackFirstBeatFrame;
    this.audioStartAnchorPending = true;
    // Recovery rejoins the current beat while the original visual/session
    // timeline keeps advancing; flushed hardware frames start from zero again.
    this.audioTimelineLeadFrames = fallbackFirstBeatFrame -
      Math.round((localStart - this.transportStartLocalMs) * SAMPLE_RATE / 1000);
    if (rendererPositionReset) {
      // flush() 不会把硬件帧计数器归零（日志 framePos 跨拍持续累加），
      // 所以不能用 0 当基准；保持 baseReady=false，交给 lock 在首个有效样本里用真实 framePos 建立基准。
      this.audioTimestampBaseFrame = 0;
      this.audioTimestampBaseReady = false;
    }
    this.audioStreaming = true;
    try {
      await renderer.start();
      if (token !== this.runToken || !this.running) {
        try { await renderer.stop(); } catch (_e) { }
        return;
      }
      this.rendererStarted = true;
      this.observedWriteCallbackCount = this.writeCallbackCount;
      this.lastWriteProgressMs = MonotonicClock.nowMs();
      await this.lockAudioStartToPresentationClock(renderer, localStart,
        rendererStartRequestedAtMs, fallbackFirstBeatFrame, token);
      if (token !== this.runToken || !this.running) {
        return;
      }
      this.primeAudioTimestamp(renderer);
      try {
        this.lastUnderflowCount = renderer.getUnderflowCountSync();
      } catch (_e) {
        this.lastUnderflowCount = 0;
      }
    } catch (err) {
      this.audioStreaming = false;
      this.audioStartAnchorPending = false;
      const e = err as BusinessError;
      console.warn(`MetronomeEngine start: ${e.message}`);
    }
  }

  private async haltRenderer(): Promise<void> {
    await this.queueRendererOperation(() => this.haltRendererNow());
  }

  private queueRendererOperation(operation: () => Promise<void>): Promise<void> {
    // A delayed pause/stop must finish before the next start, otherwise it can
    // stop the new stream after the UI has already resumed walking.
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
    const beatInBar = (this.beatIndex % this.beatsPerBar) + 1;
    this.beatCallback(this.beatIndex, beatInBar, this.nextBeatAtMs);
    this.beatIndex++;

    if (beatInBar === 1) {
      this.transportBpm = this.bpm;
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
    let outputCursor = 0;
    while (outputCursor < output.length) {
      if (!this.audioStreaming) {
        output.fill(0, outputCursor);
        return;
      }
      if (this.audioStartAnchorPending) {
        // 封顶 preroll 静音到已知的墙钟 lead，填满即切内容，避免大缓冲区 overshoot 首拍。
        const silenceFrames = Math.min(this.audioLeadSamples, output.length - outputCursor);
        if (silenceFrames > 0) {
          applyDitherFloorToRange(output, outputCursor, outputCursor + silenceFrames);
          outputCursor += silenceFrames;
          this.audioLeadSamples -= silenceFrames;
          this.audioSubmittedFrames += silenceFrames;
          continue;
        }
        this.audioStartAnchorPending = false;
        continue;
      }
      if (this.audioLeadSamples > 0) {
        const silenceFrames = Math.min(this.audioLeadSamples, output.length - outputCursor);
        applyDitherFloorToRange(output, outputCursor, outputCursor + silenceFrames);
        outputCursor += silenceFrames;
        this.audioLeadSamples -= silenceFrames;
        this.audioSubmittedFrames += silenceFrames;
        continue;
      }

      let bar = this.activeBar;
      if (bar === undefined && !this.activeSequenceFinished) {
        bar = this.pendingSequence.length > 0 ? this.pendingSequence[0] : undefined;
        this.activeBar = bar;
      }
      if (bar === undefined) {
        output.fill(0, outputCursor);
        return;
      }

      // 播放中持续相位锁定：在拍点 dither floor（静音区）插帧/丢帧，逐步校正相位误差，
      // 避免在 click 瞬态上操作产生可闻毛刺。
      if (this.phaseCorrectionFrames !== 0) {
        const samplesPerBeat = Math.max(1, Math.round(bar.samplesPerBeat));
        const posInBeat = this.audioFrameCursor % samplesPerBeat;
        if (posInBeat >= AUDIO_PHASE_LOCK_SAFE_FRAMES) {
          if (this.phaseCorrectionFrames > 0) {
            const insertFrames = Math.min(this.phaseCorrectionFrames, output.length - outputCursor);
            applyDitherFloorToRange(output, outputCursor, outputCursor + insertFrames);
            outputCursor += insertFrames;
            this.audioSubmittedFrames += insertFrames;
            this.phaseCorrectionFrames -= insertFrames;
            continue;
          }
          const dropFrames = Math.min(-this.phaseCorrectionFrames,
            bar.frameCount - this.audioFrameCursor, output.length - outputCursor);
          this.audioFrameCursor += dropFrames;
          this.phaseCorrectionFrames += dropFrames;
          if (this.audioFrameCursor >= bar.frameCount) {
            this.advanceAudioBar();
          }
          continue;
        }
      }

      const copyFrames = Math.min(bar.frameCount - this.audioFrameCursor, output.length - outputCursor);
      output.set(bar.samples.subarray(this.audioFrameCursor, this.audioFrameCursor + copyFrames), outputCursor);
      outputCursor += copyFrames;
      this.audioFrameCursor += copyFrames;
      this.audioSubmittedFrames += copyFrames;
      if (this.audioFrameCursor >= bar.frameCount) {
        this.advanceAudioBar();
      }
    }
  }

  private async lockAudioStartToPresentationClock(
    renderer: audio.AudioRenderer,
    localStart: number,
    rendererStartRequestedAtMs: number,
    fallbackFirstBeatFrame: number,
    token: number
  ): Promise<void> {
    const lockDeadline = Math.min(
      rendererStartRequestedAtMs + AUDIO_CLOCK_LOCK_TIMEOUT_MS,
      localStart - AUDIO_CLOCK_LOCK_MIN_REMAINING_MS);
    let tsProbed = false;
    let clockOffsetMs: number | undefined = undefined;
    while (token === this.runToken && this.running && MonotonicClock.nowMs() <= lockDeadline) {
      try {
        const info = renderer.getAudioTimestampInfoSync();
        const timestampMs = info.timestamp / 1000000;
        const now = MonotonicClock.nowMs();
        if (!tsProbed) {
          tsProbed = true;
          if (DEBUG) {
            console.info(`MetronomeEngine lockClock[tsProbe] rawNs=${info.timestamp} ` +
              `tsMs=${timestampMs.toFixed(2)} nowMs=${now.toFixed(2)} ` +
              `deltaMs=${(timestampMs - now).toFixed(2)} framePos=${info.framePos} ` +
              `reqStart=${rendererStartRequestedAtMs.toFixed(2)}`);
          }
        }
        if (info.timestamp > 0) {
          if (clockOffsetMs === undefined) {
            // info.timestamp 与 MonotonicClock 时基不同（日志 deltaMs 为固定偏移），
            // 首次有效样本算出两者偏移，后续把硬件时间戳折算到应用单调时钟时基再比较。
            clockOffsetMs = timestampMs - now;
          }
          const timestampInNowBase = timestampMs - clockOffsetMs;
          if (timestampInNowBase >= rendererStartRequestedAtMs - 10 &&
            timestampInNowBase <= now + 10) {
            if (!this.audioTimestampBaseReady) {
              this.audioTimestampBaseFrame = info.framePos;
              this.audioTimestampBaseReady = true;
            }
            // 首样本时 base 刚重置为当前 framePos、now≈timestampInNowBase，playedFramesNow 会被算成 0，
            // 漏掉 renderer.start() 以来已实际播放的帧数。补上这段墙钟已播帧，避免写回调 bursts
            // 把首拍 lead 顶到下溢（表现为 dev 数十 ms 的迟到）。
            // 但墙钟估计不能超过已提交帧数（写回调尚未触发时 submitted=0，否则 played>submitted 会令首拍提前）。
            const playedFramesNow = Math.min(this.audioSubmittedFrames, Math.max(0,
              info.framePos - this.audioTimestampBaseFrame +
              Math.max(0, Math.min(250, now - timestampInNowBase)) * SAMPLE_RATE / 1000 +
              Math.max(0, now - rendererStartRequestedAtMs) * SAMPLE_RATE / 1000));
          // 统一帧坐标系（以“流启动以来”的帧序号为基准）：
          // queueDepthFrames = 已提交帧 - 已播放帧，即仍在音频管线中排队待播出的帧数。
          this.queueDepthFrames = Math.max(0, this.audioSubmittedFrames - playedFramesNow);
          // 目标首拍内容帧在统一坐标下的位置 S_content = (localStart - now)*SR/1000 + playedFramesNow。
          // 剩余 lead = S_content - audioSubmittedFrames = (localStart - now)*SR/1000 - queueDepthFrames，
          // 从而避免把硬件 framePos 与应用提交计数直接相减（仅当 framePos 启动时归零才成立，跨设备不可靠）。
          this.audioLeadSamples = Math.max(0,
            Math.round((localStart - now) * SAMPLE_RATE / 1000 - this.queueDepthFrames));
          this.audioTimelineLeadFrames = playedFramesNow +
            (this.transportStartLocalMs - now) * SAMPLE_RATE / 1000;
          this.audioStartAnchorPending = false;
          const actualFirstBeatMs = now +
            (this.audioSubmittedFrames + this.audioLeadSamples - playedFramesNow) * 1000 / SAMPLE_RATE;
          if (DEBUG) {
            console.info(`OneBeatSync lockClock[hw] offsetMs=${this.offsetMs.toFixed(2)} expected=${localStart.toFixed(2)}ms ` +
              `actual=${actualFirstBeatMs.toFixed(2)}ms dev=${(actualFirstBeatMs - localStart).toFixed(2)}ms ` +
              `now=${now.toFixed(2)} hwTs=${timestampInNowBase.toFixed(2)} framePos=${info.framePos} ` +
              `played=${playedFramesNow.toFixed(1)} submitted=${this.audioSubmittedFrames} ` +
              `queue=${this.queueDepthFrames.toFixed(1)} lead=${this.audioLeadSamples} ` +
              `latency=${MetronomeEngine.readOutputLatencyMs(renderer)}`);
          }
          return;
        }
        }
      } catch (e) {
        if (!tsProbed) {
          tsProbed = true;
          if (DEBUG) {
            console.warn(`MetronomeEngine lockClock[tsProbe] getAudioTimestampInfoSync threw: ${e}`);
          }
        }
      }
      await MetronomeEngine.delay(AUDIO_CLOCK_LOCK_RETRY_MS);
    }
    // The fallback preserves the original monotonic scheduling model while
    // accounting for silence already submitted during timestamp probing.
    const fallbackTargetFrame = Math.max(fallbackFirstBeatFrame, this.audioSubmittedFrames);
    this.audioLeadSamples = fallbackTargetFrame - this.audioSubmittedFrames;
    this.audioTimelineLeadFrames = fallbackTargetFrame -
      Math.round((localStart - this.transportStartLocalMs) * SAMPLE_RATE / 1000);
    const actualFirstBeatMs = rendererStartRequestedAtMs + fallbackTargetFrame * 1000 / SAMPLE_RATE;
    if (DEBUG) {
      console.info(`OneBeatSync lockClock[fallback] offsetMs=${this.offsetMs.toFixed(2)} expected=${localStart.toFixed(2)}ms ` +
        `actual=${actualFirstBeatMs.toFixed(2)}ms dev=${(actualFirstBeatMs - localStart).toFixed(2)}ms ` +
        `rendererStart=${rendererStartRequestedAtMs.toFixed(2)} ` +
        `fallbackFrame=${fallbackFirstBeatFrame} targetFrame=${fallbackTargetFrame} ` +
        `submitted=${this.audioSubmittedFrames} lead=${this.audioLeadSamples} ` +
        `latency=${MetronomeEngine.readOutputLatencyMs(renderer)}`);
    }
    this.audioStartAnchorPending = false;
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

  /** 刷新并缓存当前音频路由的输出时延；getLatency 在流尚未路由时可能返回 0，此时保留旧值。 */
  private refreshOutputLatency(): void {
    const renderer = this.renderer;
    if (renderer === undefined) {
      return;
    }
    const latency = MetronomeEngine.readOutputLatencyMs(renderer);
    if (latency > 0) {
      this.outputLatencyMs = latency;
    }
  }

  private advanceAudioBar(): void {
    if (this.activeRevision !== this.pendingRevision) {
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
    this.audioTimelineLeadFrames = 0;
    this.audioTimestampBaseFrame = 0;
    this.audioTimestampBaseReady = false;
    this.audioClockLocked = false;
    this.lastAudioRawFrame = -1;
    this.lastAudioPlayheadMs = 0;
    this.lastAudioSampleMonoMs = 0;
    this.lastTimestampQueryMonoMs = -1;
    this.queueDepthFrames = 0;
    this.phaseCorrectionFrames = 0;
  }

  private primeAudioTimestamp(renderer: audio.AudioRenderer): void {
    try {
      const info = renderer.getAudioTimestampInfoSync();
      if (!this.audioTimestampBaseReady) {
        this.audioTimestampBaseFrame = info.framePos;
        this.audioTimestampBaseReady = true;
      }
      this.lastAudioRawFrame = info.framePos;
    } catch (_e) {
      // API 19+ exposes hardware timestamps; older devices use monotonic fallback.
    }
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
    try {
      const info = renderer.getAudioTimestampInfoSync();
      if (!this.audioTimestampBaseReady) {
        this.audioTimestampBaseFrame = info.framePos;
        this.audioTimestampBaseReady = true;
      }
      if (this.lastAudioRawFrame >= 0 && info.framePos < this.lastAudioRawFrame) {
        const expectedPlayhead = this.audioClockLocked ?
          this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs) :
          nowMs - this.transportStartLocalMs;
        this.audioTimestampBaseFrame = info.framePos - this.audioTimelineLeadFrames -
          expectedPlayhead * SAMPLE_RATE / 1000;
      }
      this.lastAudioRawFrame = info.framePos;
      const timestampMs = info.timestamp / 1000000;
      const timestampAgeMs = nowMs - timestampMs;
      if (info.timestamp <= 0 || timestampAgeMs < -50 || timestampAgeMs > 2000) {
        return this.audioClockLocked ?
          this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs) : undefined;
      }
      const extrapolatedFrames = info.framePos + Math.max(0, Math.min(250, timestampAgeMs)) * SAMPLE_RATE / 1000;
      const playheadMs = (extrapolatedFrames - this.audioTimestampBaseFrame -
        this.audioTimelineLeadFrames) * 1000 / SAMPLE_RATE;
      if (!Number.isFinite(playheadMs)) {
        return undefined;
      }
      this.audioClockLocked = true;
      this.lastAudioPlayheadMs = playheadMs;
      this.lastAudioSampleMonoMs = nowMs;
      return playheadMs;
    } catch (_e) {
      return this.audioClockLocked ?
        this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs) : undefined;
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
      await this.startAudioStream(localStart, beatIndex, countInBeats, token);
    } catch (err) {
      console.warn(`MetronomeEngine audio recovery failed: ${(err as Error).message}`);
    } finally {
      this.recoveringAudio = false;
    }
  }
}
