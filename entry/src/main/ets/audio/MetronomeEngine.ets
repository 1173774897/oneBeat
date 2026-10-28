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
  drumProgramStyleKeys,
  drumSectionStyleKey,
  parseDrumProgram,
  sectionFillStartBeat
} from './DrumMachineCatalog';
import { DrumSampleBank } from './DrumSampleBank';
import { BeatPointState, defaultBeatPointStates, normalizeBeatPointStates } from '../common/MeterModel';
import { DEBUG } from 'BuildProfile';

const SAMPLE_RATE: number = 44100;
const BYTES_PER_SAMPLE: number = 2;
// getAudioTimestampInfoSync() on current Huawei devices advances framePos in
// ~882-frame (20ms) quanta. A 100ms / ±2% gate then reports 37–54 kHz from a
// single extra or missing quantum and rejects a healthy speaker clock.
const CALIB_CLOCK_MIN_RATE_WINDOW_MS: number = 400;
const CALIB_CLOCK_MIN_FRAME_DELTA: number = Math.round(SAMPLE_RATE * 0.3);
const CALIB_CLOCK_MAX_RATE_ERROR_RATIO: number = 0.08;
const CALIB_CLOCK_RECOVERY_TIMEOUT_MS: number = 4000;
const CALIB_CLOCK_MAX_SAMPLE_AGE_MS: number = 250;
// Huawei framePos often updates in 20ms steps; one stale read can look like −882 frames.
const CALIB_CLOCK_FRAME_POS_QUANTUM: number = Math.round(SAMPLE_RATE * 20 / 1000);
// Keep the validated production mapping independent of prior mic calibration.
// Enable this only for a controlled playback A/B; mic probes keep their raw clock.
const EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP: boolean = false;
const AUDIO_PREROLL_MS: number = 650;
const AUDIO_CLOCK_LOCK_RETRY_MS: number = 8;
const AUDIO_CLOCK_LOCK_TIMEOUT_MS: number = 300;
const AUDIO_CLOCK_LOCK_MIN_REMAINING_MS: number = 80;
const AUDIO_CALLBACK_STALL_MS: number = 1500;
// Two same-direction observations above 50 ms exceed the hardware's ~20 ms
// timestamp quantum. Smaller drift stays with the normal inaudible slew.
const AUDIO_FOREGROUND_REPHASE_MS: number = 50;
const AUDIO_FOREGROUND_RECHECK_MS: number = 80;
const AUDIO_FOREGROUND_RECHECK_TIMEOUT_MS: number = 2000;
const ROUTE_PROBE_POLL_MS: number = 20;
const ROUTE_PROBE_WARMUP_MS: number = 300;
const ROUTE_PROBE_WARMUP_TIMEOUT_MS: number = 4000;
const ROUTE_PROBE_LEAD_MS: number = 200;
const ROUTE_PROBE_SUBMISSION_TIMEOUT_MS: number = 6000;
const ROUTE_PROBE_MAX_DRAIN_MS: number = 3000;
const ROUTE_REPHASE_SETTLE_MS: number = 160;
const ROUTE_REPHASE_READY_TIMEOUT_MS: number = 4000;
const ROUTE_REPHASE_GUARD_MS: number = 80;
const DRUM_PREVIEW_BOUNDARY_CAPACITY: number = 256;
const DRUM_PREVIEW_CLOCK_MAX_AGE_MS: number = 2000;
const DRUM_PREVIEW_CLOCK_REPEAT_GRACE_MS: number = 40;
const DRUM_PREVIEW_CLOCK_CONFIRM_WINDOW_MS: number = 400;
// Sub-audible dither floor laid under the click samples so the stream is never
// pure digital zero. Pure zero runs are what the smart PA silence detector
// (CustStreamCheck -> SmartpaPowerOff) keys on to power off the amplifier.
// ~ -80dBFS peak; raise only if device logs still show zero_volume=true.
const DITHER_FLOOR_GAIN: number = 0.0001;
// 播放中持续相位锁定的校正参数。
// 相位误差（音频播放头相对墙钟时间轴）超过该阈值时启动插帧/丢帧校正。
const AUDIO_PHASE_LOCK_THRESHOLD_FRAMES: number = 44; // 约 1ms
// Bound each quiet splice to limit local changes to the PCM waveform.
const AUDIO_PHASE_LOCK_MAX_STEP_FRAMES: number = 16; // 约 0.36ms
// A time-based budget must exceed the musical-clock slew even at low BPM.
// This is a control limit, not a measured audio-crystal bound.
const AUDIO_PHASE_CORRECTION_RATE_PPM: number = 2000;
const AUDIO_PHASE_CORRECTION_MAX_INTERVAL_MS: number = 2000;
const AUDIO_PHASE_CLOCK_MAX_AGE_MS: number = 250;
const AUDIO_PHASE_CORRECTION_CAPACITY: number = 128;
// The rendered dither is at most four PCM units. Beat position alone cannot
// identify silence: subdivisions and sustained cymbal tails can occur anywhere.
const AUDIO_PHASE_QUIET_SAMPLE_LIMIT: number = 4;
const AUDIO_PHASE_QUIET_GUARD_FRAMES: number = 16;

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

/**
 * Difference between raw hardware and production frame coordinates in one
 * physical renderer epoch. A positive offset increases app-to-ear compensation;
 * it becomes invalid as soon as the renderer or its output route changes.
 * framePos belongs to timestampMonoMs, not the later query time; submittedFrames
 * lets post-capture verification also confirm that writeData resumed.
 */
export interface CalibrationPlaybackReference {
  rendererEpoch: number;
  streamId: number;
  frameMappingOffsetMs: number;
  sampledAtMonoMs: number;
  framePos: number;
  timestampMonoMs: number;
  submittedFrames: number;
}

/** Read-only experiment evidence; none of these observations is a calibration value. */
export interface MicExperimentPlaybackSnapshot {
  sampledAtMonoMs: number;
  rendererEpoch: number;
  streamId: number;
  physicalStartCount: number;
  running: boolean;
  started: boolean;
  state: number;
  writeCallbackCount: number;
  submittedFrames: number;
  lastWriteProgressMs: number;
  interruptCount: number;
  lastInterruptHint: number;
  lastInterruptForce: number;
  underflowCount: number;
  outputDevices: string;
  audioScene: number;
  latencyAllMs: number;
  latencyHardwareMs: number;
  latencySoftwareMs: number;
  rawFrame: number;
  timestampMonoMs: number;
  productionClockQueryMonoMs: number;
  productionFrame: number;
  transportStartLocalMs: number;
  transportStartBeatIndex: number;
  transportBpm: number;
  transportOutputCompensationMs: number;
  sharedClockOffsetMs: number;
}

/** A fresh sample may recover in the same epoch; callers must still verify stream identity. */
export class MicPlaybackClockPendingError extends Error {
  readonly reason: string;

  constructor(reason: string) {
    super('麦克回环播放时钟暂未就绪，请稍候');
    this.name = 'MicPlaybackClockPendingError';
    this.reason = reason;
  }
}

/** Timing metadata for a chirp placed on the renderer's presentation timeline. */
export interface CalibrationSignalTiming {
  presentationMonoMs: number;
  hardwareLatencyMs: number;
  playbackReference?: CalibrationPlaybackReference;
}

interface OutputLatencySnapshot {
  allMs: number;
  softwareMs: number;
  hardwareMs: number;
}

interface CalibrationClockSample {
  framePos: number;
  rawTimestampMs: number;
  timestampMonoMs: number;
  queryMonoMs: number;
}

/** Diagnostic copy of an existing playback read; never query or rebase audio to populate it. */
interface ProductionClockSample {
  rendererEpoch: number;
  streamId: number;
  physicalStartCount: number;
  queryMonoMs: number;
  rawFrame: number;
  rawTimestampMs: number;
  renderedFrame: number;
  submittedFrames: number;
  baseFrame: number;
  clockOffsetMs: number;
  legacyAgeMs: number;
  baseUpdateReason: string;
  previousRawFrame: number;
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

interface DrumProgramPreparation {
  raw: string;
  looping: boolean;
  token: number;
  work: Promise<boolean>;
}

interface DrumPreviewBarPosition {
  sectionKey: string;
  repeatIndex: number;
}

/** Stable local editor identity and the phrase currently presented by the local renderer. */
export interface DrumPreviewPosition extends DrumPreviewBarPosition {
  isFill: boolean;
  nextBoundaryDelayMs?: number;
}

interface DrumPreviewPlan {
  raw: string;
  program: DrumProgram;
  bank: Map<string, ArrayBuffer>;
  sequence: RenderedBar[];
  sectionKeys: string[];
  sectionStarts: number[];
  positions: DrumPreviewBarPosition[];
  fillStartFrames: number[];
}

interface DrumPreviewActivation {
  plan: DrumPreviewPlan;
  startBar: number;
  startIndex: number;
  previous?: DrumPreviewActivation;
}

interface DrumPreviewPlanContext {
  bpm: number;
  beatsPerBar: number;
  beatUnit: number;
  armed: boolean;
  started: boolean;
  initialBeatOffset: number;
  newest: DrumPreviewActivation;
  rendered: DrumPreviewActivation;
  renderedBar: number;
  renderedFill: boolean;
  boundaryFrames: Float64Array;
  boundaryBars: Float64Array;
  boundaryFills: Float64Array;
  boundaryRendererEpochs: Float64Array;
  boundaryPhysicalStarts: Float64Array;
  boundaryHead: number;
  boundaryCount: number;
}

interface DrumPreviewNativeClock {
  rendererEpoch: number;
  physicalStartCount: number;
  rawFrame: number;
  timestampMonoMs: number;
  streamFrameAtTimestamp: number;
  originTimestampMonoMs: number;
  originStreamFrame: number;
  rawToStreamOffset: number;
  candidateRawFrame: number;
  candidateTimestampMonoMs: number;
  lastSeenRawFrame: number;
  lastSeenTimestampMonoMs: number;
  repeatedPairSinceMonoMs: number;
  lastOutputFrame: number;
}

interface StagedDrumPreviewUpdate {
  revision: number;
  base: DrumPreviewPlan;
  activation: DrumPreviewActivation;
  nextIndices: number[];
}

type AudioTransitionKind = 'play' | 'pause';

interface PendingAudioTransition {
  kind: AudioTransitionKind;
  token: number;
  targetFrame: number;
  beatIndex: number;
  countInBeats: number;
  outputLatencyMs: number;
  routeRephase?: boolean;
  preserveActiveSequence?: boolean;
  // A resumed write callback must skip a route beat whose presentation time
  // passed while callbacks were frozen, even if its submitted frame is pending.
  hardwareAtLocalMs?: number;
  // Rephasing seeks forward on the original transport, rather than making the
  // chosen beat a new playhead zero that phase-lock would treat as clock drift.
  timelineElapsedFrames?: number;
}

type StartTargetMode = 'timestamp' | 'fallback' | 'cold-wall';

interface StartFrameMappingEstimate {
  rawFrame: number;
  rawTimestampMs: number;
  baseFrame: number;
  uncappedMappedFrame: number;
  submittedCapFrames: number;
  legacyAgeMs: number;
}

/** Read-only evidence from the same calculation that selects a playback target. */
interface StartTargetEstimate {
  token: number;
  mode: StartTargetMode;
  queryMonoMs: number;
  targetHardwareMs: number;
  requestedFrame: number;
  submittedAtEstimate: number;
  selectedFrame: number;
  playedFrame: number;
  frameMapping?: StartFrameMappingEstimate;
}

interface StartTimingRequest {
  token: number;
  sequence: number;
  requestedAtMs: number;
  timerDueAtMs: number;
  timerFiredAtMs: number;
  operationStartedAtMs: number;
}

interface StartTimingTransition {
  transition: PendingAudioTransition;
  estimate: StartTargetEstimate;
  audibleMs: number;
  sequence: number;
}

interface StartWriteBufferContext {
  startTiming: StartTimingTransition;
  callbackEntryMonoMs: number;
  bufferStartFrame: number;
  bufferFrames: number;
  previousCallbackGapMs?: number;
  rendererEpoch: number;
  physicalStartCount: number;
  applied: boolean;
}

interface RouteProbePreparation {
  completion: Promise<void>;
  started: boolean;
  abandoned: boolean;
}

interface RouteRendererPreparation {
  settled: boolean;
  error?: Error;
}

interface RouteRephaseSelection {
  transition?: PendingAudioTransition;
}

export class MetronomeEngine {
  private startTimingSequence: number = 0;
  private startTimingRequest: StartTimingRequest | undefined = undefined;
  private startTargetEstimate: StartTargetEstimate | undefined = undefined;
  private startTimingTransition: StartTimingTransition | undefined = undefined;
  private startWriteBufferContext: StartWriteBufferContext | undefined = undefined;
  private previousWriteCallbackEntryMonoMs: number | undefined = undefined;
  private previousWriteCallbackRendererEpoch: number = -1;
  private previousWriteCallbackPhysicalStartCount: number = -1;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private rendererInitialization: Promise<audio.AudioRenderer> | undefined = undefined;
  private rendererWriteDataCallback: audio.AudioRendererWriteDataCallback | undefined = undefined;
  private rendererEpoch: number = 0;
  private rendererStreamId: number = -1;
  // Only the first start of a newly-created renderer has a proven raw/submitted
  // zero for diagnostics. A normal stop/restart may retain the hardware counter.
  private rendererPhysicalStartCount: number = 0;
  private diagnosticRawOriginLost: boolean = false;
  private productionClockSample: ProductionClockSample | undefined = undefined;
  private rendererStarted: boolean = false;
  private rendererOperation: Promise<void> = Promise.resolve();
  private routeProbeOperation: Promise<void> = Promise.resolve();
  private routeProbeGeneration: number = 0;
  private outputRouteRephaseGeneration: number = 0;
  private outputRouteRephasePreparing: boolean = false;
  private expiredRouteToken: number = -1;
  // A calibration transaction stays exclusive until its target frame has
  // actually crossed the hardware playhead. Otherwise a retry can overwrite
  // the single mixed signal while the previous caller is still awaiting it.
  private calibrationOperation: Promise<void> = Promise.resolve();
  private outputLatencyMs: number = 0;
  private recoveringAudio: boolean = false;
  private writeCallbackCount: number = 0;
  private experimentInterruptCount: number = 0;
  private experimentLastInterruptHint: number = -1;
  private experimentLastInterruptForce: number = -1;
  private observedWriteCallbackCount: number = 0;
  private lastWriteProgressMs: number = 0;
  private audioWriteDiscontinuity: boolean = false;
  private audioClockContinuityLost: boolean = false;
  private backgroundPlaybackInterrupted: boolean = false;
  private audioFocusInterrupted: boolean = false;
  private foregroundContinuityRequest: number = 0;
  // A2DP 冷启动诊断：renderer.start() 之后、首个 writeData 回调之前的等待时间。
  private diagFirstWriteAfterStartPending: boolean = false;
  private accentBuffer: ArrayBuffer = ClickSound.buildAccentBuffer();
  private weakBuffer: ArrayBuffer = ClickSound.buildWeakBuffer();
  private beatCallback: BeatCallback = () => {
  };
  private timerId: number = -1;
  private audioStartTimerId: number = -1;
  private pauseTimerId: number = -1;
  private scheduledPauseAtLocalMs: number | undefined = undefined;
  private running: boolean = false;
  private bpm: number = 120;
  private beatsPerBar: number = 4;
  private beatPointStates: BeatPointState[] = defaultBeatPointStates(4);
  private beatIndex: number = 0;
  private offsetMs: number = 0;
  private clockMappingAtMs: number = 0;
  private clockMappingSkewPpm: number = 0;
  private clockMappingValidUntilMs: number = Number.POSITIVE_INFINITY;
  private transportOffsetAtStartMs: number = 0;
  private disciplinedOffsetMs: number = 0;
  private disciplinedOffsetAtMs: number = 0;
  private transportUsesSharedClock: boolean = false;
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
  private drumProgramPreparation: DrumProgramPreparation | undefined = undefined;
  private sampleBank: Map<string, ArrayBuffer> = new Map();
  private drumPreviewPlan: DrumPreviewPlanContext | undefined = undefined;
  private stagedDrumPreviewUpdate: StagedDrumPreviewUpdate | undefined = undefined;
  private drumPreviewUpdateRevision: number = 0;
  // Local presentation continuity belongs to the physical stream, so a warm
  // stop/new preview must not reseed it from an unrelated legacy phase estimate.
  private drumPreviewNativeClock: DrumPreviewNativeClock | undefined = undefined;
  private pendingSequence: RenderedBar[] = [];
  private pendingSequenceLooping: boolean = true;
  private pendingRevision: number = 0;
  private preparedCountInBars: Map<number, RenderedBar> = new Map();
  private preparedCountInRevision: number = -1;
  private preparedCountInCapacity: number = 0;
  private deferPendingSequenceActivation: boolean = false;
  private activeSequence: RenderedBar[] = [];
  private activeSequenceLooping: boolean = true;
  private activeSequenceFinished: boolean = false;
  private activeRevision: number = -1;
  // Local route retokens leave this ownership intact; shared starts revise it.
  private audioSequenceTransportRevision: number = -1;
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
  private phaseCorrectionEnabled: boolean = true;
  // Corrections belong to submitted stream coordinates. Their acoustic effect
  // starts only after the hardware head and output latency cross that point.
  private phaseCorrectionStarts: Float64Array = new Float64Array(AUDIO_PHASE_CORRECTION_CAPACITY);
  private phaseCorrectionDeltas: Float64Array = new Float64Array(AUDIO_PHASE_CORRECTION_CAPACITY);
  private phaseCorrectionHead: number = 0;
  private phaseCorrectionCount: number = 0;
  private phaseCorrectionCompletedFrames: number = 0;
  private phaseCorrectionSubmittedFrames: number = 0;
  private phaseCorrectionAudibleFrames: number = 0;
  private phaseFeedbackStartFrame: number = -1;
  private phaseFeedbackSampleFresh: boolean = false;
  private phaseCorrectionCheckAtMs: number = -1;
  private audioFrameCursor: number = 0;
  private lastUnderflowCount: number = 0;
  private transportRevision: number = 0;
  private transportStartLocalMs: number = 0;
  private transportStartBeatIndex: number = 0;
  private transportCountInBeats: number = 0;
  private transportCountInDurationMs: number = 0;
  // A local drum seek changes source PCM, never the elapsed audio-clock origin.
  // Keeping those coordinates separate prevents phase-lock from undoing a seek.
  private transportPreviewStartPositionBeats: number | undefined = undefined;
  /**
   * Calibration supplies zero here because the user is measuring the complete
   * route delay themselves. Mixing the platform estimate into that trial would
   * make the displayed value describe only the estimate's residual error.
   */
  private transportOutputCompensationOverrideMs: number | undefined = undefined;
  /** Only the transport that established the current audio origin may read the hardware playhead. */
  private audioTimelineToken: number = -1;
  private audioTimelineLeadFrames: number = 0;
  private audioTimelineOutputLatencyMs: number = 0;
  private audioTimestampBaseFrame: number = 0;
  private audioTimestampBaseReady: boolean = false;
  private audioTimestampClockOffsetMs: number | undefined = undefined;
  private rendererStartedAtLocalMs: number = 0;
  private lastRenderedStreamFrame: number = 0;
  private audioClockLocked: boolean = false;
  private lastAudioRawFrame: number = -1;
  private lastAudioTimestampAgeMs: number = Number.POSITIVE_INFINITY;
  private lastAudioFrameMapExact: boolean = false;
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
    const callbackEntryMonoMs = MonotonicClock.nowMs();
    if (this.audioStreaming && this.lastWriteProgressMs > 0 &&
      callbackEntryMonoMs - this.lastWriteProgressMs > AUDIO_CALLBACK_STALL_MS) {
      this.audioWriteDiscontinuity = true;
    }
    this.lastWriteProgressMs = callbackEntryMonoMs;
    const previousEntry = this.previousWriteCallbackEntryMonoMs;
    const previousCallbackGapMs = previousEntry !== undefined && callbackEntryMonoMs >= previousEntry &&
      this.previousWriteCallbackRendererEpoch === this.rendererEpoch &&
      this.previousWriteCallbackPhysicalStartCount === this.rendererPhysicalStartCount
      ? callbackEntryMonoMs - previousEntry : undefined;
    this.previousWriteCallbackEntryMonoMs = callbackEntryMonoMs;
    this.previousWriteCallbackRendererEpoch = this.rendererEpoch;
    this.previousWriteCallbackPhysicalStartCount = this.rendererPhysicalStartCount;
    if (this.diagFirstWriteAfterStartPending) {
      this.diagFirstWriteAfterStartPending = false;
      const elapsed = MonotonicClock.nowMs() - this.rendererStartedAtLocalMs;
      console.info(`[A2DP-DIAG] first writeData after start: +${elapsed}ms (A2DP/media-link establishment)`);
    }
    const startTiming = this.startTimingTransition;
    const bufferContext: StartWriteBufferContext | undefined = startTiming !== undefined &&
      startTiming.transition.token === this.runToken && startTiming.estimate.token === this.runToken &&
      this.pendingAudioTransition === startTiming.transition ? {
        startTiming, callbackEntryMonoMs, bufferStartFrame: this.audioSubmittedFrames,
        bufferFrames: data.byteLength / BYTES_PER_SAMPLE, previousCallbackGapMs,
        rendererEpoch: this.rendererEpoch, physicalStartCount: this.rendererPhysicalStartCount, applied: false
      } : undefined;
    this.startWriteBufferContext = bufferContext;
    try {
      this.fillAudioData(data);
    } finally {
      this.startWriteBufferContext = undefined;
    }
    if (bufferContext?.applied) {
      this.logStartWriteCompletion(bufferContext, MonotonicClock.nowMs());
    }
    return audio.AudioDataCallbackResult.VALID;
  }

  configure(rhythm: number, soundId: number): void {
    this.clearDrumPreviewPlan();
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
    this.clearDrumPreviewPlan();
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

  /**
   * Confirm the physical route with one complete accent/weak PCM pair. This
   * preview has no shared-clock deadline: skipping a late first beat would
   * invalidate what the user is being asked to listen for. Keep the ordinary
   * renderer and its production frame mapping, rather than entering mic timing.
   * Cancellation relinquishes ownership without stopping a newer transport.
   */
  async playRouteProbeClickPair(isCancelled: () => boolean = () => false): Promise<boolean> {
    const generation = ++this.routeProbeGeneration;
    const queuedAt = MonotonicClock.nowMs();
    const preparation: RouteProbePreparation = {
      completion: Promise.resolve(), started: false, abandoned: false
    };
    // Serialize cold preparation too: a superseded create/start must finish
    // before another probe can establish the renderer it will retain.
    const task = this.routeProbeOperation.then(() => {
      preparation.started = true;
      return this.playRouteProbeClickPairExclusive(generation, isCancelled, preparation);
    });
    this.routeProbeOperation = task.then(() => preparation.completion, () => preparation.completion);
    let settled = false;
    let result = false;
    let failure: Error | undefined = undefined;
    void task.then((completed: boolean) => {
      result = completed;
      settled = true;
    }, (error: Error) => {
      failure = error;
      settled = true;
    });
    while (!settled) {
      if (generation !== this.routeProbeGeneration || isCancelled()) {
        preparation.abandoned = true;
        return false;
      }
      if (!preparation.started && MonotonicClock.nowMs() - queuedAt >= ROUTE_PROBE_WARMUP_TIMEOUT_MS) {
        preparation.abandoned = true;
        throw new Error('蓝牙试音启动超时，请保持当前输出设备后重试');
      }
      await MetronomeEngine.delay(ROUTE_PROBE_POLL_MS);
    }
    if (preparation.abandoned || generation !== this.routeProbeGeneration || isCancelled()) {
      return false;
    }
    if (failure !== undefined) {
      throw new Error((failure as Error).message);
    }
    return result;
  }

  private async playRouteProbeClickPairExclusive(generation: number,
    isCancelled: () => boolean, preparation: RouteProbePreparation): Promise<boolean> {
    const requestCurrent = (): boolean => !preparation.abandoned &&
      generation === this.routeProbeGeneration && !isCancelled();
    if (!requestCurrent()) {
      return false;
    }
    this.pause();
    const preparationToken = this.runToken;
    const preparationCurrent = (): boolean => requestCurrent() && this.runToken === preparationToken;
    const warmupStartedAt = MonotonicClock.nowMs();
    const writesBeforeWarmup = this.writeCallbackCount;
    let warmupSettled = false;
    let warmupError: Error | undefined = undefined;
    const warming = this.warmUpRendererForPlayback(() => !preparationCurrent());
    // A timeout stops this logical request, but cannot cancel a native create /
    // start Promise. Its completion still owns preparation order, so a late
    // response cannot replace the renderer established by the next probe.
    preparation.completion = warming.then(() => {}, () => {});
    void warming.then(() => {
      warmupSettled = true;
    }, (error: Error) => {
      warmupError = error;
      warmupSettled = true;
    });
    while (!warmupSettled) {
      if (!preparationCurrent()) {
        return false;
      }
      if (MonotonicClock.nowMs() - warmupStartedAt >= ROUTE_PROBE_WARMUP_TIMEOUT_MS) {
        throw new Error('蓝牙试音启动超时，请保持当前输出设备后重试');
      }
      await MetronomeEngine.delay(ROUTE_PROBE_POLL_MS);
    }
    if (!preparationCurrent()) {
      return false;
    }
    if (warmupError !== undefined) {
      throw new Error((warmupError as Error).message);
    }
    const renderer = this.renderer;
    if (renderer === undefined) {
      throw new Error('蓝牙试音渲染器不可用');
    }
    const rendererEpoch = this.rendererEpoch;
    const physicalStartCount = this.rendererPhysicalStartCount;
    const physicalCurrent = (): boolean => this.renderer === renderer &&
      this.rendererEpoch === rendererEpoch && this.rendererPhysicalStartCount === physicalStartCount &&
      this.rendererStarted && renderer.state === audio.AudioState.STATE_RUNNING;
    const warmedAt = MonotonicClock.nowMs();
    // start() resolving is not evidence that A2DP accepts audio. Observe real
    // writeData progress and let the silent stream open the physical link first.
    while (this.writeCallbackCount <= writesBeforeWarmup ||
      MonotonicClock.nowMs() - warmedAt < ROUTE_PROBE_WARMUP_MS) {
      if (!preparationCurrent() || !physicalCurrent()) {
        return false;
      }
      if (MonotonicClock.nowMs() - warmupStartedAt >= ROUTE_PROBE_WARMUP_TIMEOUT_MS) {
        throw new Error('蓝牙试音未收到音频写入回调，请重试');
      }
      await MetronomeEngine.delay(ROUTE_PROBE_POLL_MS);
    }

    let probeToken = -1;
    let firstFrame = -1;
    let endFrame = -1;
    await this.queueRendererOperation(async () => {
      if (!preparationCurrent() || !physicalCurrent()) {
        return;
      }
      this.configureRouteProbeClickPair();
      probeToken = this.beginTransport();
      this.transportBpm = this.bpm;
      this.transportBeatsPerBar = this.beatsPerBar;
      this.beatIndex = 0;
      this.transportStartBeatIndex = 0;
      this.transportCountInBeats = 0;
      this.transportCountInDurationMs = 0;
      this.transportStartLocalMs = MonotonicClock.nowMs();
      this.transportOutputCompensationOverrideMs = 0;
      this.transportRevision++;
      firstFrame = this.audioSubmittedFrames + Math.round(ROUTE_PROBE_LEAD_MS * SAMPLE_RATE / 1000);
      endFrame = firstFrame + this.pendingSequence[0].frameCount;
      this.scheduleRunningTransition({
        kind: 'play', token: probeToken, targetFrame: firstFrame,
        beatIndex: 0, countInBeats: 0, outputLatencyMs: 0
      });
      console.info(`[RouteProbeDiag] stage=scheduled rendererEpoch=${rendererEpoch} ` +
        `streamId=${this.rendererStreamId} token=${probeToken} firstFrame=${firstFrame} ` +
        `endFrame=${endFrame} submittedFrames=${this.audioSubmittedFrames}`);
    });
    const probeCurrent = (): boolean => requestCurrent() && this.runToken === probeToken && physicalCurrent();
    if (probeToken < 0 || !probeCurrent()) {
      return false;
    }
    const submissionStartedAt = MonotonicClock.nowMs();
    while (this.audioTimelineToken !== probeToken || !this.activeSequenceFinished ||
      this.audioSubmittedFrames < endFrame) {
      if (!probeCurrent()) {
        return false;
      }
      const now = MonotonicClock.nowMs();
      if (now - submissionStartedAt >= ROUTE_PROBE_SUBMISSION_TIMEOUT_MS ||
        now - this.lastWriteProgressMs >= AUDIO_CALLBACK_STALL_MS) {
        console.warn(`[RouteProbeDiag] stage=submission-timeout token=${probeToken} ` +
          `submittedFrames=${this.audioSubmittedFrames} endFrame=${endFrame}`);
        throw new Error('蓝牙试音未完整播放，请保持当前输出设备后重试');
      }
      await MetronomeEngine.delay(ROUTE_PROBE_POLL_MS);
    }
    if (!probeCurrent()) {
      return false;
    }
    const now = MonotonicClock.nowMs();
    const playedFrames = this.readRenderedStreamFrames(renderer, now);
    const queueMs = playedFrames === undefined ? 1000 :
      Math.max(0, (endFrame - playedFrames) * 1000 / SAMPLE_RATE);
    const platformLatencyMs = Math.max(0, MetronomeEngine.readOutputLatencyMs(renderer));
    // Both clicks are now irrevocably queued. Give that queue and the wireless
    // tail time to drain before enabling the route-confirmation choices; pause
    // must never cut a still-unsubmitted second click at a wall-clock deadline.
    const drainMs = Math.min(ROUTE_PROBE_MAX_DRAIN_MS, Math.max(700, queueMs + platformLatencyMs + 200));
    const drainUntil = now + drainMs;
    console.info(`[RouteProbeDiag] stage=submitted token=${probeToken} ` +
      `elapsedMs=${(now - submissionStartedAt).toFixed(1)} queueMs=${queueMs.toFixed(1)} ` +
      `platformLatencyMs=${platformLatencyMs} drainMs=${drainMs.toFixed(1)}`);
    while (MonotonicClock.nowMs() < drainUntil) {
      if (!probeCurrent()) {
        return false;
      }
      if (MonotonicClock.nowMs() - this.lastWriteProgressMs >= AUDIO_CALLBACK_STALL_MS) {
        throw new Error('蓝牙试音音频输出已停滞，请保持当前输出设备后重试');
      }
      await MetronomeEngine.delay(ROUTE_PROBE_POLL_MS);
    }
    return probeCurrent();
  }

  /** True only when this request's drum sequence is ready; superseded loads cannot authorize playback. */
  async configureProgram(raw: string, looping: boolean = true): Promise<boolean> {
    this.clearDrumPreviewPlan();
    const pending = this.drumProgramPreparation;
    if (pending !== undefined && pending.raw === raw && pending.looping === looping &&
      pending.token === this.configurationToken) {
      // Snapshot/clock notifications can repeat while native resources load.
      // Reuse the same preparation so a strict transport ACK can await it.
      return await pending.work;
    }
    // Even an already-applied request must invalidate older sample loads: a
    // late one-shot preview must never replace the walking transport's loop.
    const token = ++this.configurationToken;
    if (raw.length === 0) {
      return false;
    }
    if (raw === this.customProgramRaw && looping === this.customProgramLooping) {
      return true;
    }
    const work = this.prepareDrumProgram(raw, looping, token);
    const preparation: DrumProgramPreparation = { raw, looping, token, work };
    this.drumProgramPreparation = preparation;
    try {
      return await work;
    } finally {
      if (this.drumProgramPreparation === preparation) {
        this.drumProgramPreparation = undefined;
      }
    }
  }

  private async prepareDrumProgram(raw: string, looping: boolean, token: number): Promise<boolean> {
    const program = parseDrumProgram(raw);
    const bank = await this.loadProgramBank(program);
    if (token !== this.configurationToken) {
      return false;
    }
    this.customProgramRaw = raw;
    this.customProgram = program;
    this.customProgramLooping = looping;
    this.sampleBank = bank;
    this.rebuildPendingSequence(buildProgramSequence(program), looping);
    return true;
  }

  private async loadProgramBank(program: DrumProgram): Promise<Map<string, ArrayBuffer>> {
    const styles = drumProgramStyleKeys(program);
    const kits = await Promise.all(styles.map((style: string) => DrumSampleBank.loadStyle(style)));
    if (kits.length === 1) {
      return kits[0];
    }
    const bank: Map<string, ArrayBuffer> = new Map();
    for (let i = 0; i < kits.length; i++) {
      kits[i].forEach((sample: ArrayBuffer, key: string) => {
        bank.set(`${styles[i]}/${key}`, sample);
      });
    }
    // Namespace kits in this request's immutable prepared bank. A late load or
    // a staged preview must never change the kit used by already-rendered PCM.
    return bank;
  }

  /** Releasing a local audition must also invalidate a sample load that has not completed yet. */
  cancelProgramPreparation(): void {
    this.clearDrumPreviewPlan();
    this.configurationToken++;
  }

  /** Arm only the immediately following count-in-free, looping whole-song audition. */
  attachDrumPreviewPlan(sectionKeys: string[]): void {
    this.clearDrumPreviewPlan();
    const program = this.customProgram;
    if (program === undefined || !this.customProgramLooping) {
      throw new Error('整曲试听尚未准备完成');
    }
    const plan = this.createDrumPreviewPlan(this.customProgramRaw, program, this.sampleBank,
      this.pendingSequence, sectionKeys);
    const activation: DrumPreviewActivation = { plan, startBar: 0, startIndex: 0 };
    this.drumPreviewPlan = {
      bpm: this.bpm, beatsPerBar: program.beatsPerBar, beatUnit: program.beatUnit,
      armed: true, started: false, initialBeatOffset: 0, newest: activation, rendered: activation, renderedBar: 0,
      renderedFill: false,
      boundaryFrames: new Float64Array(DRUM_PREVIEW_BOUNDARY_CAPACITY),
      boundaryBars: new Float64Array(DRUM_PREVIEW_BOUNDARY_CAPACITY),
      boundaryFills: new Float64Array(DRUM_PREVIEW_BOUNDARY_CAPACITY),
      boundaryRendererEpochs: new Float64Array(DRUM_PREVIEW_BOUNDARY_CAPACITY),
      boundaryPhysicalStarts: new Float64Array(DRUM_PREVIEW_BOUNDARY_CAPACITY),
      boundaryHead: 0, boundaryCount: 0
    };
  }

  /** Withdraw unsubmitted edits immediately, keeping the active transport and submitted PCM intact. */
  invalidateDrumPreviewUpdate(): void {
    this.drumPreviewUpdateRevision++;
    this.stagedDrumPreviewUpdate = undefined;
  }

  /** Prepare a whole-song revision without changing its clock, current bar or renderer lifecycle. */
  async updateDrumPreviewProgram(raw: string, sectionKeys: string[]): Promise<boolean> {
    this.invalidateDrumPreviewUpdate();
    const context = this.drumPreviewPlan;
    const revision = this.drumPreviewUpdateRevision;
    const configuration = this.configurationToken;
    if (context === undefined || context.armed || !this.running || raw.length === 0 ||
      this.bpm !== context.bpm || this.beatsPerBar !== context.beatsPerBar) {
      return false;
    }
    const program = parseDrumProgram(raw);
    if (program.beatsPerBar !== context.beatsPerBar || program.beatUnit !== context.beatUnit) {
      return false;
    }
    let bank: Map<string, ArrayBuffer>;
    try {
      bank = await this.loadProgramBank(program);
    } catch (err) {
      if (context !== this.drumPreviewPlan || revision !== this.drumPreviewUpdateRevision ||
        configuration !== this.configurationToken || !this.running) {
        return false;
      }
      throw new Error((err as Error).message);
    }
    if (context !== this.drumPreviewPlan || revision !== this.drumPreviewUpdateRevision ||
      configuration !== this.configurationToken || !this.running) {
      return false;
    }
    // Explicit render inputs keep a prepared style/bank out of the active engine
    // until its boundary. No PCM generation or resource access occurs in writeData.
    const sequence = this.renderSequence(buildProgramSequence(program), true, bank, program);
    const plan = this.createDrumPreviewPlan(raw, program, bank, sequence, sectionKeys);
    if (context !== this.drumPreviewPlan || revision !== this.drumPreviewUpdateRevision ||
      configuration !== this.configurationToken || !this.running) {
      return false;
    }
    this.pruneDrumPreviewHistory(context);
    const base = context.newest.plan;
    this.stagedDrumPreviewUpdate = {
      revision, base, activation: { plan, startBar: 0, startIndex: 0 },
      nextIndices: this.drumPreviewNextIndices(base, plan)
    };
    return true;
  }

  /** Local audition follows emitted PCM at presentation; walking visuals keep their shared clock. */
  getDrumPreviewPosition(): DrumPreviewPosition | undefined {
    const context = this.drumPreviewPlan;
    if (context === undefined || context.armed || !this.running) {
      return undefined;
    }
    const logicalBeat = this.drumPreviewLogicalBeat(context);
    let bar = logicalBeat < 0 ? -1 : Math.floor(logicalBeat / context.beatsPerBar);
    let isFill = false;
    let nextBoundaryDelayMs: number | undefined = undefined;
    const presentedFrame = this.drumPreviewPresentedFrame();
    if (presentedFrame !== undefined) {
      const boundary = this.drumPreviewBoundaryAt(context, presentedFrame);
      // A valid hardware clock can precede the clamped first PCM submission.
      // Do not paint A just because the requested wall-clock start has passed.
      if (boundary < 0) {
        return undefined;
      }
      bar = context.boundaryBars[boundary];
      isFill = context.boundaryFills[boundary] === 1;
      nextBoundaryDelayMs = this.drumPreviewNextBoundaryDelay(context, presentedFrame);
    }
    if (bar < 0) {
      return undefined;
    }
    const activation = this.drumPreviewActivationAt(context, bar);
    const index = this.drumPreviewIndexAt(activation, bar);
    const position = activation.plan.positions[index];
    this.pruneDrumPreviewHistory(context, bar);
    if (position === undefined) {
      return undefined;
    }
    if (presentedFrame === undefined) {
      const fillStart = activation.plan.fillStartFrames[index];
      const sourceFrame = (logicalBeat % context.beatsPerBar) * activation.plan.sequence[index].samplesPerBeat;
      isFill = fillStart >= 0 && sourceFrame >= fillStart;
    }
    const result: DrumPreviewPosition = {
      sectionKey: position.sectionKey, repeatIndex: position.repeatIndex, isFill: isFill
    };
    if (nextBoundaryDelayMs !== undefined) {
      result.nextBoundaryDelayMs = nextBoundaryDelayMs;
    }
    return result;
  }

  private clearDrumPreviewPlan(): void {
    this.invalidateDrumPreviewUpdate();
    this.drumPreviewPlan = undefined;
  }

  private createDrumPreviewPlan(raw: string, program: DrumProgram,
    bank: Map<string, ArrayBuffer>, sequence: RenderedBar[], sectionKeys: string[]): DrumPreviewPlan {
    if (sectionKeys.length !== program.sections.length || sectionKeys.length === 0) {
      throw new Error('整曲试听段落标识不完整');
    }
    const keys: string[] = [];
    const starts: number[] = [];
    const positions: DrumPreviewBarPosition[] = [];
    const fillStartBeats: number[] = [];
    for (let section = 0; section < program.sections.length; section++) {
      const key = sectionKeys[section];
      if (key.length === 0 || keys.indexOf(key) >= 0) {
        throw new Error('整曲试听段落标识重复');
      }
      keys.push(key);
      starts.push(positions.length);
      for (let repeat = 0; repeat < program.sections[section].repeats; repeat++) {
        positions.push({ sectionKey: key, repeatIndex: repeat });
        const definition = program.sections[section];
        const withFill = definition.fillEvery > 0 && (repeat + 1) % definition.fillEvery === 0;
        fillStartBeats.push(withFill ? sectionFillStartBeat(program, definition) : -1);
      }
    }
    if (positions.length !== sequence.length) {
      throw new Error('整曲试听小节计划不完整');
    }
    const fillStartFrames: number[] = [];
    for (let index = 0; index < sequence.length; index++) {
      fillStartFrames.push(fillStartBeats[index] < 0 ? -1 :
        Math.round(fillStartBeats[index] * sequence[index].samplesPerBeat));
    }
    return { raw, program, bank, sequence, sectionKeys: keys, sectionStarts: starts, positions, fillStartFrames };
  }

  private drumPreviewNextIndices(before: DrumPreviewPlan, after: DrumPreviewPlan): number[] {
    const indices: number[] = [];
    for (let bar = 0; bar < before.positions.length; bar++) {
      const position = before.positions[bar];
      const section = after.sectionKeys.indexOf(position.sectionKey);
      if (section >= 0) {
        const nextRepeat = position.repeatIndex + 1;
        indices.push(nextRepeat < after.program.sections[section].repeats ?
          after.sectionStarts[section] + nextRepeat :
          after.sectionStarts[(section + 1) % after.sectionKeys.length]);
        continue;
      }
      const oldSection = before.sectionKeys.indexOf(position.sectionKey);
      let successor = -1;
      for (let step = 1; step <= before.sectionKeys.length; step++) {
        const candidate = before.sectionKeys[(oldSection + step) % before.sectionKeys.length];
        successor = after.sectionKeys.indexOf(candidate);
        if (successor >= 0) {
          break;
        }
      }
      indices.push(successor < 0 ? 0 : after.sectionStarts[successor]);
    }
    return indices;
  }

  private drumPreviewLogicalBeat(context: DrumPreviewPlanContext): number {
    const snapshot = this.getVisualSnapshot();
    if (!snapshot.running || snapshot.countIn || snapshot.mainPlayheadMs < 0) {
      return -1;
    }
    const beatMs = 60000 / Math.max(1, context.bpm);
    return snapshot.mainPlayheadMs / beatMs + context.initialBeatOffset;
  }

  private drumPreviewLogicalBar(context: DrumPreviewPlanContext): number {
    const beat = this.drumPreviewLogicalBeat(context);
    return beat < 0 ? -1 : Math.floor(beat / context.beatsPerBar);
  }

  private drumPreviewActivationAt(context: DrumPreviewPlanContext, bar: number): DrumPreviewActivation {
    let activation = context.newest;
    while (activation.previous !== undefined && activation.startBar > bar) {
      activation = activation.previous;
    }
    return activation;
  }

  private drumPreviewIndexAt(activation: DrumPreviewActivation, bar: number): number {
    const count = activation.plan.sequence.length;
    const index = activation.startIndex + bar - activation.startBar;
    return ((index % count) + count) % count;
  }

  private pruneDrumPreviewHistory(context: DrumPreviewPlanContext, audibleBar?: number): void {
    const logicalBar = this.drumPreviewLogicalBar(context);
    if (logicalBar < 0) {
      return;
    }
    let presentedBar = audibleBar ?? logicalBar;
    if (audibleBar === undefined) {
      const frame = this.drumPreviewPresentedFrame();
      if (frame !== undefined) {
        const boundary = this.drumPreviewBoundaryAt(context, frame);
        if (boundary < 0) {
          return;
        }
        presentedBar = context.boundaryBars[boundary];
      }
    }
    // Keep the audible plan and any already-submitted future revisions. A route
    // repair can revisit those revisions before catching the submission head.
    const oldest = this.drumPreviewActivationAt(context,
      Math.min(presentedBar, logicalBar, context.renderedBar));
    oldest.previous = undefined;
  }

  private drumPreviewPresentedFrame(): number | undefined {
    const renderer = this.renderer;
    if (renderer === undefined || !this.rendererStarted) {
      return undefined;
    }
    const frame = this.readDrumPreviewStreamFrame(renderer);
    return frame === undefined || !Number.isFinite(frame) ? undefined :
      frame - this.audioTimelineOutputLatencyMs * SAMPLE_RATE / 1000;
  }

  private readDrumPreviewNativeSample(renderer: audio.AudioRenderer): CalibrationClockSample | undefined {
    try {
      const startupBefore = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const activeBefore = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const info = renderer.getAudioTimestampInfoSync();
      const activeAfter = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const startupAfter = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const queryMonoMs = (startupBefore + startupAfter) / 2;
      const timestampMonoMs = info.timestamp / 1000000 + queryMonoMs - (activeBefore + activeAfter) / 2;
      if (!Number.isFinite(info.framePos) || info.framePos < 0 || info.timestamp <= 0 ||
        !Number.isFinite(timestampMonoMs)) {
        return undefined;
      }
      return { framePos: info.framePos, rawTimestampMs: info.timestamp / 1000000,
        timestampMonoMs, queryMonoMs };
    } catch (_e) {
      return undefined;
    }
  }

  private readDrumPreviewStreamFrame(renderer: audio.AudioRenderer): number | undefined {
    const sample = this.readDrumPreviewNativeSample(renderer);
    if (sample === undefined) {
      return undefined;
    }
    const ageMs = sample.queryMonoMs - sample.timestampMonoMs;
    let clock = this.drumPreviewNativeClock;
    if (clock !== undefined && (clock.rendererEpoch !== this.rendererEpoch ||
      clock.physicalStartCount !== this.rendererPhysicalStartCount)) {
      clock = undefined;
      this.drumPreviewNativeClock = undefined;
    }
    if (ageMs < -50 || ageMs > DRUM_PREVIEW_CLOCK_MAX_AGE_MS) {
      // A repeatedly frozen pair is evidence of a stopped native clock. Keep
      // its last presentation instead of extrapolating through queued audio.
      return clock !== undefined && sample.framePos === clock.lastSeenRawFrame &&
        sample.timestampMonoMs === clock.lastSeenTimestampMonoMs ? clock.lastOutputFrame : undefined;
    }
    const rate = SAMPLE_RATE / 1000;
    if (clock === undefined) {
      // A renderer's first physical start proves raw/submitted zero. A retained
      // counter after stop is instead anchored at the sample's actual time,
      // never at its delayed query time or the shared playback phase cache.
      const zeroProven = this.rendererPhysicalStartCount === 1 && !this.diagnosticRawOriginLost;
      const streamFrame = zeroProven ? sample.framePos : Math.min(this.audioSubmittedFrames,
        Math.max(0, (sample.timestampMonoMs - this.rendererStartedAtLocalMs) * rate));
      clock = {
        rendererEpoch: this.rendererEpoch, physicalStartCount: this.rendererPhysicalStartCount,
        rawFrame: sample.framePos, timestampMonoMs: sample.timestampMonoMs,
        streamFrameAtTimestamp: streamFrame,
        originTimestampMonoMs: sample.timestampMonoMs, originStreamFrame: streamFrame,
        rawToStreamOffset: streamFrame - sample.framePos,
        candidateRawFrame: -1, candidateTimestampMonoMs: -1,
        lastSeenRawFrame: sample.framePos, lastSeenTimestampMonoMs: sample.timestampMonoMs,
        repeatedPairSinceMonoMs: sample.queryMonoMs, lastOutputFrame: 0
      };
      this.drumPreviewNativeClock = clock;
    }
    const repeated = sample.framePos === clock.lastSeenRawFrame &&
      sample.timestampMonoMs === clock.lastSeenTimestampMonoMs;
    if (!repeated) {
      clock.lastSeenRawFrame = sample.framePos;
      clock.lastSeenTimestampMonoMs = sample.timestampMonoMs;
      clock.repeatedPairSinceMonoMs = sample.queryMonoMs;
    } else if (sample.queryMonoMs - clock.repeatedPairSinceMonoMs > DRUM_PREVIEW_CLOCK_REPEAT_GRACE_MS) {
      return clock.lastOutputFrame;
    }

    const elapsedMs = sample.timestampMonoMs - clock.timestampMonoMs;
    const rawDelta = sample.framePos - clock.rawFrame;
    const tolerance = CALIB_CLOCK_FRAME_POS_QUANTUM * 2;
    const expectedStreamFrame = clock.originStreamFrame +
      (sample.timestampMonoMs - clock.originTimestampMonoMs) * rate;
    // Quantization has one bounded error budget for the origin, rather than a
    // fresh budget on every read. Otherwise small counter-origin losses can be
    // accepted repeatedly and leave the highlight permanently behind the PCM.
    const sameOrigin = elapsedMs >= 0 && rawDelta >= 0 &&
      Math.abs(sample.framePos + clock.rawToStreamOffset - expectedStreamFrame) <= tolerance;
    let projectedAtSample = clock.streamFrameAtTimestamp;
    let projectedTimestamp = clock.timestampMonoMs;
    if (sameOrigin) {
      clock.rawFrame = sample.framePos;
      clock.timestampMonoMs = sample.timestampMonoMs;
      clock.streamFrameAtTimestamp = sample.framePos + clock.rawToStreamOffset;
      clock.candidateRawFrame = -1;
      projectedAtSample = clock.streamFrameAtTimestamp;
      projectedTimestamp = sample.timestampMonoMs;
    } else if (elapsedMs > 0) {
      const candidateElapsed = sample.timestampMonoMs - clock.candidateTimestampMonoMs;
      const candidateDelta = sample.framePos - clock.candidateRawFrame;
      const candidateConsistent = clock.candidateRawFrame >= 0 &&
        candidateElapsed >= DRUM_PREVIEW_CLOCK_CONFIRM_WINDOW_MS &&
        candidateDelta > 0 && Math.abs(candidateDelta - candidateElapsed * rate) <= tolerance;
      if (candidateConsistent) {
        // A sustained advancing pair confirms a new counter origin. Derive its
        // offset at the confirming timestamp from the fixed trusted reference,
        // so earlier tolerated losses cannot leak into the replacement origin.
        clock.rawToStreamOffset = expectedStreamFrame - sample.framePos;
        clock.rawFrame = sample.framePos;
        clock.timestampMonoMs = sample.timestampMonoMs;
        clock.streamFrameAtTimestamp = expectedStreamFrame;
        clock.originTimestampMonoMs = sample.timestampMonoMs;
        clock.originStreamFrame = expectedStreamFrame;
        clock.candidateRawFrame = -1;
      } else if (clock.candidateRawFrame < 0 || candidateElapsed < 0 || candidateDelta < 0 ||
        Math.abs(candidateDelta - candidateElapsed * rate) > tolerance) {
        clock.candidateRawFrame = sample.framePos;
        clock.candidateTimestampMonoMs = sample.timestampMonoMs;
      }
      projectedAtSample = expectedStreamFrame;
      projectedTimestamp = sample.timestampMonoMs;
    }
    // A lone low/out-of-order pair cannot rewrite the origin. Its brief trusted
    // projection also covers quantized/aged samples; the entire validated age
    // is used, rather than dropping all but 250 ms of a valid native timestamp.
    const projected = projectedAtSample + Math.max(0, sample.queryMonoMs - projectedTimestamp) * rate;
    const frame = Math.min(this.audioSubmittedFrames, Math.max(0, clock.lastOutputFrame, projected));
    clock.lastOutputFrame = frame;
    return frame;
  }

  private drumPreviewBoundaryAt(context: DrumPreviewPlanContext, frame: number): number {
    for (let offset = 1; offset <= context.boundaryCount; offset++) {
      const index = (context.boundaryHead - offset + DRUM_PREVIEW_BOUNDARY_CAPACITY) %
        DRUM_PREVIEW_BOUNDARY_CAPACITY;
      if (context.boundaryRendererEpochs[index] === this.rendererEpoch &&
        context.boundaryPhysicalStarts[index] === this.rendererPhysicalStartCount &&
        context.boundaryFrames[index] <= frame) {
        return index;
      }
    }
    return -1;
  }

  private drumPreviewNextBoundaryDelay(context: DrumPreviewPlanContext, frame: number): number | undefined {
    let next = Number.POSITIVE_INFINITY;
    for (let offset = 1; offset <= context.boundaryCount; offset++) {
      const index = (context.boundaryHead - offset + DRUM_PREVIEW_BOUNDARY_CAPACITY) %
        DRUM_PREVIEW_BOUNDARY_CAPACITY;
      if (context.boundaryRendererEpochs[index] === this.rendererEpoch &&
        context.boundaryPhysicalStarts[index] === this.rendererPhysicalStartCount &&
        context.boundaryFrames[index] > frame) {
        next = Math.min(next, context.boundaryFrames[index]);
      }
    }
    return Number.isFinite(next) ? (next - frame) * 1000 / SAMPLE_RATE : undefined;
  }

  private recordDrumPreviewBoundary(context: DrumPreviewPlanContext, fill?: boolean, frame?: number): void {
    // Preallocated numeric anchors record actual submitted frames, including
    // source-frame insertion/drop. They retain no PCM and allocate nothing in writeData.
    const index = context.boundaryHead;
    const fillStart = context.rendered.plan.fillStartFrames[this.activeSequenceIndex];
    const isFill = fill ?? (fillStart >= 0 && this.audioFrameCursor >= fillStart);
    context.renderedFill = isFill;
    context.boundaryFrames[index] = frame ?? this.audioSubmittedFrames;
    context.boundaryBars[index] = context.renderedBar;
    context.boundaryFills[index] = isFill ? 1 : 0;
    context.boundaryRendererEpochs[index] = this.rendererEpoch;
    context.boundaryPhysicalStarts[index] = this.rendererPhysicalStartCount;
    context.boundaryHead = (index + 1) % DRUM_PREVIEW_BOUNDARY_CAPACITY;
    context.boundaryCount = Math.min(DRUM_PREVIEW_BOUNDARY_CAPACITY, context.boundaryCount + 1);
  }

  setBeatCallback(callback: BeatCallback): void {
    this.beatCallback = callback;
  }

  /** Mapping is leader minus local; its expiry bounds extrapolation during a lost resync. */
  setOffsetMs(offsetMs: number, skewPpm: number = 0,
    validUntilMs: number = Number.POSITIVE_INFINITY): void {
    if (!Number.isFinite(offsetMs) || !Number.isFinite(skewPpm) || Number.isNaN(validUntilMs)) {
      return;
    }
    const now = MonotonicClock.nowMs();
    this.transportClockAdjustmentAt(now);
    this.offsetMs = offsetMs;
    this.clockMappingAtMs = now;
    this.clockMappingSkewPpm = skewPpm;
    this.clockMappingValidUntilMs = validUntilMs;
    if (!this.running) {
      this.resetTransportClockDiscipline(now);
    }
  }

  private mappedOffsetAt(localMs: number): number {
    const elapsed = Math.max(0, Math.min(localMs, this.clockMappingValidUntilMs) - this.clockMappingAtMs);
    return this.offsetMs + this.clockMappingSkewPpm * elapsed / 1e6;
  }

  private resetTransportClockDiscipline(nowMs: number): void {
    this.disciplinedOffsetMs = this.mappedOffsetAt(nowMs);
    this.disciplinedOffsetAtMs = nowMs;
  }

  /** Keep the musical clock monotonic while a new network estimate is absorbed.
   *  The 1 ms/s slew is a control limit for shared playback, not
   *  an assumption about device crystals or a promise of acoustic accuracy.
   */
  private transportClockAdjustmentAt(nowMs: number): number {
    if (!this.phaseCorrectionEnabled || !this.transportUsesSharedClock) {
      return 0;
    }
    const elapsed = Math.max(0, nowMs - this.disciplinedOffsetAtMs);
    const limit = elapsed / 1000;
    const difference = this.mappedOffsetAt(nowMs) - this.disciplinedOffsetMs;
    this.disciplinedOffsetMs += Math.max(-limit, Math.min(limit, difference));
    this.disciplinedOffsetAtMs = Math.max(nowMs, this.disciplinedOffsetAtMs);
    return this.disciplinedOffsetMs - this.transportOffsetAtStartMs;
  }

  private transportElapsedAt(nowMs: number): number {
    return nowMs - this.transportStartLocalMs + this.transportClockAdjustmentAt(nowMs);
  }

  /** nextBeatAtMs stays on the original musical grid; timers need current local time. */
  private localTimeForTransportGrid(gridAtMs: number, nowMs: number): number {
    return gridAtMs - this.transportClockAdjustmentAt(nowMs);
  }

  setBpm(bpm: number, beatsPerBar: number): void {
    const bpmChanged = this.bpm !== bpm;
    const meterChanged = this.beatsPerBar !== beatsPerBar;
    if (bpmChanged || meterChanged) {
      this.clearDrumPreviewPlan();
    }
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
    this.clearDrumPreviewPlan();
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
    const playheadMs = this.transportElapsedAt(now);
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
    const previewPositionBeats = this.transportPreviewStartPositionBeats;
    // Keep pre-roll negative so a held editor cursor stays put until playback.
    const mainPlayheadMs = playheadMs - this.transportCountInDurationMs +
      (started ? (previewPositionBeats ?? 0) * beatMs : 0);
    const previewBeatPosition = Math.max(0, mainPlayheadMs / beatMs);
    return {
      revision: this.transportRevision,
      running: true,
      playheadMs: playheadMs,
      mainPlayheadMs: mainPlayheadMs,
      mainBeatIndex: previewPositionBeats === undefined ? Math.max(0,
        beatIndex - this.transportStartBeatIndex - this.transportCountInBeats) : Math.floor(previewBeatPosition),
      beatIndex: previewPositionBeats === undefined ? beatIndex : Math.floor(previewBeatPosition),
      beatInBar: started ? (previewPositionBeats !== undefined ?
        (Math.floor(previewBeatPosition) % this.transportBeatsPerBar) + 1 :
        (countIn ? (countInBeat % this.transportBeatsPerBar) + 1 :
        (beatIndex % this.transportBeatsPerBar) + 1)) : 0,
      beatPhase: started ? (previewPositionBeats !== undefined ? previewBeatPosition % 1 :
        Math.max(0, Math.min(0.999999, beatPhase))) : 0,
      countIn: countIn
    };
  }

  async ensureRenderer(): Promise<void> {
    if (this.renderer !== undefined) {
      return;
    }
    // Route-preview preparation can overlap a user starting the real transport.
    // Share native creation so its late response cannot replace a newer stream.
    if (this.rendererInitialization === undefined) {
      this.rendererInitialization = this.createRenderer();
    }
    const initialization = this.rendererInitialization;
    try {
      await initialization;
    } finally {
      if (this.rendererInitialization === initialization) {
        this.rendererInitialization = undefined;
      }
    }
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
    this.rendererPhysicalStartCount = 0;
    this.diagnosticRawOriginLost = false;
    this.productionClockSample = undefined;
    this.rendererWriteDataCallback = writeDataCallback;
    created.on('writeData', writeDataCallback);
    created.on('stateChange', (state: audio.AudioState) => {
      if (this.renderer !== created) { return; }
      console.info(`MetronomeEngine renderer state=${state}, running=${this.running}, token=${this.runToken}`);
      this.rendererStarted = state === audio.AudioState.STATE_RUNNING;
    });
    created.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (this.renderer !== created) { return; }
      // A short interruption can resume before a polling observer sees it.
      // Retain evidence without changing the existing focus/recovery policy.
      this.experimentInterruptCount++;
      this.experimentLastInterruptHint = event.hintType;
      this.experimentLastInterruptForce = event.forceType;
      console.warn(`MetronomeEngine audio interrupt: hint=${event.hintType}, force=${event.forceType}, token=${this.runToken}`);
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.audioFocusInterrupted = true;
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        this.audioFocusInterrupted = false;
      }
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
   * the first signal frame on the raw hardware clock. Bluetooth results also
   * carry the bridge to production's legacy frame mapping. The physical round
   * trip excludes the submit queue, which must not become saved compensation.
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
    const calibrationToken = this.runToken;
    await this.ensureSilentRendererRunning(true);
    // Warm the physical route before choosing a frame target so its timestamp
    // and A2DP link match the stream that production will keep using. Queue
    // depth itself is deliberately excluded by the presentation-time anchor.
    await this.warmUpRenderQueueForCalibration();
    let presentationMonoMs = targetAtLocalMonoMs;
    let hardwareLatencyMs = -1;
    let playbackReference: CalibrationPlaybackReference | undefined = undefined;
    await this.queueRendererOperation(async () => {
      const renderer = this.renderer;
      if (renderer === undefined || !this.rendererStarted ||
        renderer.state !== audio.AudioState.STATE_RUNNING) {
        throw new Error('校准音频渲染器未运行');
      }

      const clock = await this.readStableCalibrationClock(renderer, calibrationToken);
      if (clock === undefined) {
        // A wall-clock/queue-depth fallback is acceptable for live playback,
        // but not for calibration: an unknown queue would be folded back into
        // the saved compensation and recreate the submit-anchor bug.
        // Recovery keeps this renderer and origin. Only the explicit probe
        // boundary or an output-route reset may rebuild the physical stream.
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
      const outputLatency = this.logMicCalibrationAudioStateForRenderer(
        'probe-capturer-active', renderer);
      hardwareLatencyMs = outputLatency.hardwareMs;
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
      if (AudioOutputMonitor.isBluetoothA2dpActive()) {
        // Bind the raw chirp to its own epoch before the renderer transaction
        // unlocks; a queued route boundary must not attach a replacement stream.
        playbackReference = this.readMicCalibrationPlaybackReference();
      }
    });
    return {
      presentationMonoMs,
      hardwareLatencyMs,
      playbackReference
    };
  }

  /** Start the persistent renderer with dither only; do not start a UI transport. */
  private async ensureSilentRendererRunning(requireExactCalibrationClock: boolean = false,
    isCancelled: () => boolean = () => false,
    keepRunningOnRouteChange: boolean = false): Promise<void> {
    await this.queueRendererOperation(async () => {
      if (isCancelled()) {
        return;
      }
      let renderer = this.renderer;
      if (renderer === undefined) {
        throw new Error(requireExactCalibrationClock ? '校准音频渲染器不可用' : '播放音频渲染器不可用');
      }
      const now = MonotonicClock.nowMs();
      const routeReset = this.calibrationRouteResetPending;
      // Mic calibration must release on route epoch dirtiness. flush() alone does
      // not realign framePos with audioSubmittedFrames on current Huawei builds.
      const rebuildForMic = requireExactCalibrationClock &&
        (this.micCalibrationRendererRebuildPending || routeReset);
      const healthy = this.rendererStarted && renderer.state === audio.AudioState.STATE_RUNNING &&
        now - this.lastWriteProgressMs < AUDIO_CALLBACK_STALL_MS &&
        (!routeReset || keepRunningOnRouteChange) && !rebuildForMic &&
        (!requireExactCalibrationClock || this.calibrationFrameOriginExact);
      if (healthy) {
        console.info(`[CalibDiag] renderer healthy, keep buffer, queueDepthFrames=${this.queueDepthFrames} submittedFrames=${this.audioSubmittedFrames}`);
        return;
      }
      console.info(`[CalibDiag] renderer NOT healthy, prepare+restart, routeReset=${routeReset} ` +
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
        if (isCancelled()) {
          return;
        }
        if (requireExactCalibrationClock) {
          try {
            // Mic timing resets audioSubmittedFrames, so its physical stream
            // must be flushed as well. Flush resets framePos to the same zero.
            // Ordinary playback uses its rebased clock and must not flush a
            // newly prepared stream just because the output route changed.
            await renderer.flush();
          } catch (err) {
            throw new Error(`重置麦克回环音频时钟失败：${(err as Error).message}`);
          }
        }
      }
      if (isCancelled()) {
        return;
      }
      this.resetAudioTimestampState();
      this.audioSubmittedFrames = 0;
      this.audioStreaming = false;
      this.pendingAudioTransition = undefined;
      this.calibrationSignal = undefined;
      this.calibrationFrameOriginExact = rebuildForMic || requireExactCalibrationClock;
      this.rendererStartedAtLocalMs = MonotonicClock.nowMs();
      this.diagFirstWriteAfterStartPending = true;
      this.rendererPhysicalStartCount++;
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
   * 一次性试音的取消谓词阻止晚到的 create / queued warm-up 抢回新 transport。
   */
  async warmUpRendererForPlayback(isCancelled: () => boolean = () => false): Promise<void> {
    await this.ensureRenderer();
    if (isCancelled()) {
      return;
    }
    // A route notification invalidates mic timing, not a healthy playback
    // queue. Let the running stream follow the system route without a restart.
    await this.ensureSilentRendererRunning(false, isCancelled, true);
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

  /**
   * Reset the persistent renderer queue between input-side probes on the same
   * route. flush() alone does not realign getAudioTimestampInfo().framePos with
   * audioSubmittedFrames on current Huawei builds, which yields multi-second
   * negative queueMs and breaks readStableCalibrationClock().
   */
  async flushCalibrationStreamBetweenProbes(): Promise<void> {
    await this.calibrationOperation.catch((): void => {});
    await this.queueRendererOperation(async () => {
      let renderer = this.renderer;
      if (renderer === undefined) {
        return;
      }
      try {
        if (renderer.state === audio.AudioState.STATE_RUNNING ||
          renderer.state === audio.AudioState.STATE_PAUSED) {
          this.rendererStarted = false;
          await renderer.stop();
        }
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
        throw new Error(`输入侧探针间重建音频时钟失败：${(err as Error).message}`);
      }
      this.resetAudioTimestampState();
      this.audioSubmittedFrames = 0;
      this.audioStreaming = false;
      this.pendingAudioTransition = undefined;
      this.calibrationSignal = undefined;
      this.calibrationFrameOriginExact = true;
      this.rendererStartedAtLocalMs = MonotonicClock.nowMs();
      this.diagFirstWriteAfterStartPending = true;
      this.rendererPhysicalStartCount++;
      await renderer.start();
      this.rendererStarted = true;
      this.observedWriteCallbackCount = this.writeCallbackCount;
      this.lastWriteProgressMs = MonotonicClock.nowMs();
      this.calibrationRouteResetPending = false;
      this.micCalibrationRendererRebuildPending = false;
      console.info('[CalibDiag] input probe boundary rebuild, frame epoch realigned');
    });
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

  /** The final source-position argument is reserved for local, count-in-free drum audition. */
  async scheduleFromLeaderStart(startAtLeaderMonoMs: number, beatIndex: number,
    countInBeats: number = 0, outputCompensationOverrideMs?: number,
    previewStartPositionBeats?: number): Promise<void> {
    const requestedAtMs = MonotonicClock.nowMs();
    const preview = this.drumPreviewPlan;
    const preservePreview = preview !== undefined && preview.armed && countInBeats === 0;
    const token = this.beginTransport(preservePreview);
    if (preservePreview && preview !== undefined) {
      preview.armed = false;
    }
    const timing: StartTimingRequest = {
      token, sequence: ++this.startTimingSequence, requestedAtMs,
      timerDueAtMs: -1, timerFiredAtMs: -1, operationStartedAtMs: -1
    };
    this.startTimingRequest = timing;
    this.preparePlaybackBuffers(countInBeats);
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
    // Only local drum audition opts into a fractional source position. Shared
    // starts/count-ins retain their existing integer-beat transport contract.
    this.transportPreviewStartPositionBeats = previewStartPositionBeats === undefined ? undefined :
      Math.max(0, Number.isFinite(previewStartPositionBeats) ? previewStartPositionBeats : 0) %
      Math.max(1, this.transportBeatsPerBar);
    const interval = 60000 / this.transportBpm;
    // ClockSync offset is leader - client, so convert leader time back to the local clock.
    let localStart = startAtLeaderMonoMs - this.offsetMs;
    const useSharedClock = previewStartPositionBeats === undefined && outputCompensationOverrideMs === undefined;
    if (this.phaseCorrectionEnabled && useSharedClock) {
      // Evaluate the mapping at the deadline, not just at receipt. The second
      // projection solves the small affine skew without introducing a new epoch.
      localStart = startAtLeaderMonoMs - this.mappedOffsetAt(localStart);
      localStart = startAtLeaderMonoMs - this.mappedOffsetAt(localStart);
    }
    let firstBeatIndex = beatIndex;
    let remainingCountInBeats = Math.max(0, countInBeats);
    const now = MonotonicClock.nowMs();
    if (localStart < now) {
      const missedBeats = Math.ceil((now - localStart) / interval);
      localStart += missedBeats * interval;
      if (this.transportPreviewStartPositionBeats === undefined) {
        firstBeatIndex += missedBeats;
      }
      remainingCountInBeats = Math.max(0, remainingCountInBeats - missedBeats);
    }

    this.beatIndex = firstBeatIndex;
    this.nextBeatAtMs = localStart;
    this.transportStartLocalMs = localStart;
    this.transportUsesSharedClock = useSharedClock;
    this.resetTransportClockDiscipline(now);
    this.transportOffsetAtStartMs = this.phaseCorrectionEnabled && useSharedClock ?
      this.mappedOffsetAt(localStart) : this.disciplinedOffsetMs;
    this.transportStartBeatIndex = firstBeatIndex;
    this.transportCountInBeats = remainingCountInBeats;
    this.transportCountInDurationMs = remainingCountInBeats * interval;
    this.transportOutputCompensationOverrideMs = outputCompensationOverrideMs;
    this.transportRevision++;
    const rendererAlreadyRunning = this.rendererStarted &&
      this.renderer?.state === audio.AudioState.STATE_RUNNING;
    const audioDelay = rendererAlreadyRunning ? 0 :
      Math.max(0, localStart - MonotonicClock.nowMs() - AUDIO_PREROLL_MS);
    console.info(`[StartTimingDiag] stage=schedule seq=${timing.sequence} token=${token} ` +
      `requestedAtMs=${requestedAtMs.toFixed(1)} nowMonoMs=${now.toFixed(1)} ` +
      `leaderAudibleMs=${startAtLeaderMonoMs.toFixed(1)} audibleMs=${localStart.toFixed(1)} ` +
      `offsetMs=${this.offsetMs.toFixed(1)} remainingAudibleMs=${(localStart - now).toFixed(1)} ` +
      `requestWaitMs=${(now - requestedAtMs).toFixed(1)} rendererRunning=${rendererAlreadyRunning} ` +
      `physicalStartCount=${this.rendererPhysicalStartCount} ` +
      `compensationOverrideMs=${outputCompensationOverrideMs ?? 'saved-or-platform'}`);
    if (DEBUG) {
      console.info(`OneBeatSync schedule offsetMs=${this.offsetMs.toFixed(2)} ` +
        `startAtLeader=${startAtLeaderMonoMs.toFixed(2)}ms localStart=${localStart.toFixed(2)}ms ` +
        `now=${now.toFixed(2)}ms audioDelay=${audioDelay.toFixed(2)}ms ` +
        `countIn=${countInBeats} beat=${firstBeatIndex} bpm=${this.transportBpm.toFixed(1)}`);
    }
    timing.timerDueAtMs = MonotonicClock.nowMs() + audioDelay;
    this.audioStartTimerId = setTimeout(() => {
      timing.timerFiredAtMs = MonotonicClock.nowMs();
      console.info(`[StartTimingDiag] stage=timer seq=${timing.sequence} token=${token} ` +
        `timerLateMs=${(timing.timerFiredAtMs - timing.timerDueAtMs).toFixed(1)}`);
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
    this.scheduledPauseAtLocalMs = localPauseAt;
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
      this.scheduledPauseAtLocalMs = undefined;
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

  private beginTransport(preserveDrumPreview: boolean = false): number {
    if (!preserveDrumPreview) {
      this.clearDrumPreviewPlan();
    }
    this.cancelTimers();
    this.startTimingRequest = undefined;
    this.startTargetEstimate = undefined;
    this.startTimingTransition = undefined;
    this.startWriteBufferContext = undefined;
    this.runToken++;
    this.phaseCorrectionFrames = 0;
    this.audioWriteDiscontinuity = false;
    this.audioClockContinuityLost = false;
    this.backgroundPlaybackInterrupted = false;
    this.audioFocusInterrupted = false;
    this.running = true;
    this.transportPreviewStartPositionBeats = undefined;
    this.pendingAudioTransition = undefined;
    return this.runToken;
  }

  private cancelTransport(): void {
    this.clearDrumPreviewPlan();
    this.running = false;
    this.audioStreaming = false;
    this.pendingAudioTransition = undefined;
    this.calibrationSignal = undefined;
    this.startTimingRequest = undefined;
    this.startTargetEstimate = undefined;
    this.startTimingTransition = undefined;
    this.startWriteBufferContext = undefined;
    this.runToken++;
    this.resetPhaseCorrectionState();
    this.cancelTimers();
  }

  /** Controlled A/B only: change this while stopped, then start a new transport. */
  setPhaseCorrectionEnabled(enabled: boolean): boolean {
    if (this.running || this.audioStreaming) {
      return false;
    }
    if (this.phaseCorrectionEnabled === enabled) { return true; }
    this.phaseCorrectionEnabled = enabled;
    this.resetPhaseCorrectionState();
    this.resetTransportClockDiscipline(MonotonicClock.nowMs());
    return true;
  }

  private cancelTimers(): void {
    this.scheduledPauseAtLocalMs = undefined;
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
      this.preparePlaybackBuffers(countInBeats);
      const now = MonotonicClock.nowMs();
      if (this.startTimingRequest?.token === token) {
        this.startTimingRequest.operationStartedAtMs = now;
      }
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
        this.logProductionClockDiagnostic('continuous-play', localAudibleStart);
        this.logStartTimingTarget('continuous', transition, localAudibleStart, outputCompensationMs);
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
    this.preparePlaybackBuffers(countInBeats);
    // A physical restart resets only the stream clock. Normal play/pause/BPM
    // transitions never enter this path once the renderer is running.
    this.resetAudioTimestampState();
    const rendererStartRequestedAtMs = MonotonicClock.nowMs();
    this.rendererStartedAtLocalMs = rendererStartRequestedAtMs;
    this.audioSubmittedFrames = 0;
    this.audioStreaming = false;
    const outputCompensationMs = outputCompensationOverrideMs ?? this.outputLatencyMs;
    const provisionalHardwareStart = localAudibleStart - outputCompensationMs;
    const requestedFrame = Math.round((provisionalHardwareStart - rendererStartRequestedAtMs) *
      SAMPLE_RATE / 1000);
    const provisionalTransition: PendingAudioTransition = {
      kind: 'play',
      token: token,
      targetFrame: Math.max(0, requestedFrame),
      beatIndex: beatIndex,
      countInBeats: countInBeats,
      outputLatencyMs: outputCompensationMs
    };
    this.cacheStartTargetEstimate('cold-wall', rendererStartRequestedAtMs, provisionalHardwareStart,
      0, requestedFrame, provisionalTransition.targetFrame);
    this.scheduleRunningTransition(provisionalTransition);
    this.logStartTimingTarget('cold-provisional', provisionalTransition, localAudibleStart, outputCompensationMs);
    try {
      this.rendererPhysicalStartCount++;
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
    const musicalNow = this.transportStartLocalMs + this.transportElapsedAt(now);
    // A resync can move the local deadline later. Do not emit an early beat
    // merely because a timer was armed before that estimate arrived.
    if (musicalNow < this.nextBeatAtMs) {
      this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token), this.nextBeatAtMs - musicalNow);
      return;
    }
    if (this.nextBeatAtMs < musicalNow) {
      const skipped = Math.floor((musicalNow - this.nextBeatAtMs) / interval);
      if (skipped > 0) {
        this.nextBeatAtMs += skipped * interval;
        this.beatIndex += skipped;
      }
    }
    const beatInBar = (this.beatIndex % this.transportBeatsPerBar) + 1;
    this.beatCallback(this.beatIndex, beatInBar, this.localTimeForTransportGrid(this.nextBeatAtMs, now));
    this.beatIndex++;

    if (beatInBar === 1) {
      this.reportUnderflowIfNeeded();
    }
    interval = 60000 / this.transportBpm;
    this.nextBeatAtMs += interval;
    this.checkAudioProgress(now);
    const afterCallback = MonotonicClock.nowMs();
    const wait = Math.max(0, this.localTimeForTransportGrid(this.nextBeatAtMs, afterCallback) - afterCallback);
    this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token), wait);
  }

  private rebuildPendingSequence(patterns: SequencerPattern[], looping: boolean): void {
    const sequence = this.renderSequence(patterns, looping, this.sampleBank, this.customProgram);
    this.pendingSequence = sequence;
    this.pendingSequenceLooping = looping;
    this.pendingRevision++;
    this.prepareCountInBuffers();
    // Configuration packets arrive before their shared transport boundary. The
    // old sequence must keep looping until that boundary instead of switching
    // on whichever device happens to finish its current bar first.
    this.deferPendingSequenceActivation = this.audioStreaming;
  }

  private renderSequence(patterns: SequencerPattern[], looping: boolean,
    bank: Map<string, ArrayBuffer>, program: DrumProgram | undefined): RenderedBar[] {
    const sequence: RenderedBar[] = [];
    const styles = this.programBarStyleKeys(program);
    for (let i = 0; i < patterns.length; i++) {
      sequence.push(this.renderBar(patterns[i], true, bank, program, styles[i]));
    }
    this.mixRideTails(patterns, sequence, looping, bank, program);
    return sequence;
  }

  private programBarStyleKeys(program: DrumProgram | undefined): string[] {
    const styles: string[] = [];
    if (program !== undefined) {
      for (let section = 0; section < program.sections.length; section++) {
        const current = program.sections[section];
        const style = drumSectionStyleKey(program, current);
        for (let repeat = 0; repeat < current.repeats; repeat++) {
          styles.push(style);
        }
      }
    }
    return styles;
  }

  private drumSample(bank: Map<string, ArrayBuffer>, sampleKey: string,
    styleKey?: string): ArrayBuffer | undefined {
    const styled = styleKey === undefined ? undefined : bank.get(`${styleKey}/${sampleKey}`);
    return styled ?? bank.get(sampleKey);
  }

  private mixRideTails(patterns: SequencerPattern[], sequence: RenderedBar[], looping: boolean,
    bank: Map<string, ArrayBuffer> = this.sampleBank,
    program: DrumProgram | undefined = this.customProgram): void {
    if (sequence.length === 0) {
      return;
    }
    const styles = this.programBarStyleKeys(program);
    // Only the new, sustained ride voice needs this continuation. Mix it while
    // preparing PCM, never in writeData, and keep every bar's frame count and
    // transport boundary unchanged. Looping PCM includes the previous cycle's
    // steady-state ring so its seam cannot chop the cymbal tail.
    for (let barIndex = 0; barIndex < patterns.length; barIndex++) {
      const pattern = patterns[barIndex];
      const bar = sequence[barIndex];
      const ride = this.drumSample(bank, 'ride', styles[barIndex]);
      if (ride === undefined) {
        continue;
      }
      // A ringing cymbal retains its source kit across the next section's style boundary.
      const source = new DataView(ride);
      const sourceFrames = Math.floor(ride.byteLength / BYTES_PER_SAMPLE);
      for (let eventIndex = 0; eventIndex < pattern.events.length; eventIndex++) {
        const event = pattern.events[eventIndex];
        if (event.sampleKey !== 'ride') {
          continue;
        }
        const eventBeat = Math.floor(event.tick / pattern.ticksPerBeat) % Math.max(1, pattern.beatsPerBar);
        const pointState = this.beatPointStates[eventBeat] ?? 'normal';
        if (pointState === 'silent') {
          continue;
        }
        const startFrame = Math.round(event.tick * bar.samplesPerBeat / pattern.ticksPerBeat);
        if (startFrame < 0 || startFrame >= bar.frameCount) {
          continue;
        }
        const pointGain = program !== undefined && pointState === 'accent' ? 1.15 : 1;
        let sourceFrame = bar.frameCount - startFrame;
        let targetBarIndex = barIndex + 1;
        while (sourceFrame < sourceFrames) {
          if (!looping && targetBarIndex >= sequence.length) {
            break;
          }
          const target = sequence[targetBarIndex % sequence.length];
          const count = Math.min(sourceFrames - sourceFrame, target.frameCount);
          for (let frame = 0; frame < count; frame++) {
            const mixed = target.samples[frame] +
              source.getInt16((sourceFrame + frame) * BYTES_PER_SAMPLE, true) * event.velocity * pointGain;
            target.samples[frame] = Math.max(-32768, Math.min(32767, Math.round(mixed)));
          }
          sourceFrame += count;
          targetBarIndex++;
        }
      }
    }
  }

  private renderBar(pattern: SequencerPattern, applyBeatPointPattern: boolean = true,
    bank: Map<string, ArrayBuffer> = this.sampleBank,
    program: DrumProgram | undefined = this.customProgram, styleKey?: string): RenderedBar {
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
      const bankSample = this.drumSample(bank, event.sampleKey, styleKey);
      const sourceData = bankSample !== undefined ? bankSample :
        event.sampleKey === 'accent' ? this.accentBuffer : this.weakBuffer;
      const source = new DataView(sourceData);
      const sourceFrames = Math.floor(sourceData.byteLength / BYTES_PER_SAMPLE);
      const startFrame = Math.round(event.tick * samplesPerBeat / pattern.ticksPerBeat);
      const availableFrames = Math.min(sourceFrames, frameCount - startFrame);
      for (let frame = 0; frame < availableFrames; frame++) {
        const targetOffset = (startFrame + frame) * BYTES_PER_SAMPLE;
        const pointGain = applyBeatPointPattern && program !== undefined && pointState === 'accent' ? 1.15 : 1;
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

  private preparePlaybackBuffers(countInBeats: number): void {
    if (this.pendingSequence.length === 0) {
      this.rebuildPendingSequence([this.pattern], true);
    }
    if (countInBeats > 0 && (this.preparedCountInRevision !== this.pendingRevision ||
      countInBeats > this.preparedCountInCapacity || !this.preparedCountInBars.has(countInBeats))) {
      this.prepareCountInBuffers(countInBeats);
    }
  }

  private prepareCountInBuffers(requiredBeats: number = 0): void {
    const pendingBeats = this.pendingAudioTransition?.kind === 'play'
      ? this.pendingAudioTransition.countInBeats : 0;
    const capacity = Math.ceil(Math.max(1, this.beatsPerBar, requiredBeats,
      this.transportCountInBeats, pendingBeats));
    const full = this.renderCountInBar(capacity);
    const prepared = new Map<number, RenderedBar>();
    // Every remaining count-in restarts with an accent. Prefixes of the same
    // rendered bar preserve its rounding and sounds without repeating the PCM
    // allocation/dither loop in writeData. A revision also covers sample-bank
    // changes; configurationToken alone changes even when PCM is unchanged.
    const addPrefix = (beats: number): void => {
      if (beats <= 0 || prepared.has(beats)) {
        return;
      }
      const frameCount = Math.max(1, Math.round(full.samplesPerBeat * beats));
      prepared.set(beats, {
        samples: new Int16Array(full.samples.buffer, full.samples.byteOffset, frameCount),
        frameCount, samplesPerBeat: full.samplesPerBeat, beatsPerBar: beats
      });
    };
    for (let beats = 1; beats <= capacity; beats++) {
      addPrefix(beats);
    }
    addPrefix(requiredBeats);
    addPrefix(this.transportCountInBeats);
    addPrefix(pendingBeats);
    this.preparedCountInBars = prepared;
    this.preparedCountInCapacity = capacity;
    this.preparedCountInRevision = this.pendingRevision;
  }

  private hasPreparedPlaybackBuffers(countInBeats: number): boolean {
    return this.pendingSequence.length > 0 && (countInBeats <= 0 ||
      (this.preparedCountInRevision === this.pendingRevision && this.preparedCountInBars.has(countInBeats)));
  }

  private prepareAudioCursor(beatIndex: number, countInBeats: number = 0): void {
    const preview = this.drumPreviewPlan;
    if (preview !== undefined && !preview.armed && preview.started && countInBeats === 0) {
      this.prepareDrumPreviewCursorAtBeat(preview, beatIndex);
      return;
    }
    const countInBar = countInBeats > 0 ? this.preparedCountInBars.get(countInBeats) : undefined;
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
    const sourceBeat = beatIndex + (this.transportPreviewStartPositionBeats ?? 0);
    const beatInBar = ((sourceBeat % bar.beatsPerBar) + bar.beatsPerBar) % bar.beatsPerBar;
    this.audioFrameCursor = countInBar === undefined ? Math.round(beatInBar * bar.samplesPerBeat) : 0;
    if (this.audioFrameCursor >= bar.frameCount) {
      this.audioFrameCursor = 0;
    }
    if (preview !== undefined && !preview.armed && countInBeats === 0) {
      preview.started = true;
      preview.initialBeatOffset = beatInBar;
      preview.renderedBar = 0;
      preview.rendered = preview.newest;
    }
  }

  private prepareRouteAudioCursor(beatIndex: number, preserveActiveSequence: boolean): void {
    const preview = this.drumPreviewPlan;
    if (preview !== undefined && !preview.armed) {
      this.prepareDrumPreviewCursorAtBeat(preview, beatIndex);
      return;
    }
    if (!preserveActiveSequence) {
      this.prepareAudioCursor(this.transportStartBeatIndex, this.transportCountInBeats);
    }
    let countInBeats = 0;
    for (let i = 0; i < this.activeLoopStartIndex; i++) {
      countInBeats += this.activeSequence[i].beatsPerBar;
    }
    let index = 0;
    let beatOffset = beatIndex - (this.mainStartBeatIndex - countInBeats);
    if (beatIndex < this.mainStartBeatIndex && countInBeats > 0) {
      beatOffset = Math.max(0, beatOffset);
      while (index < this.activeLoopStartIndex - 1 &&
        beatOffset >= this.activeSequence[index].beatsPerBar) {
        beatOffset -= this.activeSequence[index].beatsPerBar;
        index++;
      }
      this.applyMainStartOffset = true;
    } else {
      index = this.activeLoopStartIndex;
      const firstMainBar = this.activeSequence[index];
      if (firstMainBar === undefined) {
        this.activeBar = undefined;
        this.activeSequenceFinished = true;
        return;
      }
      // Seek the original program, including its initial partial bar. Rebuilding
      // only the remaining count-in would add a new accent; restarting the main
      // sequence would replay its first drum section on every output switch.
      beatOffset = Math.max(0, beatIndex - this.mainStartBeatIndex) +
        ((this.mainStartBeatIndex % firstMainBar.beatsPerBar) + firstMainBar.beatsPerBar) %
          firstMainBar.beatsPerBar + (this.transportPreviewStartPositionBeats ?? 0);
      let mainBeats = 0;
      for (let i = index; i < this.activeSequence.length; i++) {
        mainBeats += this.activeSequence[i].beatsPerBar;
      }
      if (mainBeats <= 0 || (!this.activeSequenceLooping && beatOffset >= mainBeats)) {
        this.activeBar = undefined;
        this.activeSequenceFinished = true;
        return;
      }
      if (this.activeSequenceLooping) {
        beatOffset %= mainBeats;
      }
      while (index < this.activeSequence.length - 1 &&
        beatOffset >= this.activeSequence[index].beatsPerBar) {
        beatOffset -= this.activeSequence[index].beatsPerBar;
        index++;
      }
      this.applyMainStartOffset = false;
    }
    this.activeSequenceIndex = index;
    this.activeBar = this.activeSequence[index];
    this.activeSequenceFinished = this.activeBar === undefined;
    this.audioFrameCursor = this.activeBar === undefined ? 0 :
      Math.round(beatOffset * this.activeBar.samplesPerBeat);
  }

  private fillAudioData(data: ArrayBuffer): void {
    const output = new Int16Array(data);
    const bufferStartFrame = this.audioSubmittedFrames;
    let outputCursor = 0;
    while (outputCursor < output.length) {
      const transition = this.pendingAudioTransition;
      if (transition?.routeRephase && transition.hardwareAtLocalMs !== undefined &&
        MonotonicClock.nowMs() >= transition.hardwareAtLocalMs) {
        // The callback can resume before the asynchronous route watcher. Do
        // not submit a late click; the same owner will select a future beat.
        if (transition.token === this.runToken) {
          this.expiredRouteToken = transition.token;
          this.audioStreaming = false;
          this.phaseCorrectionFrames = 0;
        }
        if (this.pendingAudioTransition === transition) {
          this.pendingAudioTransition = undefined;
        }
        continue;
      }
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

      let phaseCopyLimit = outputLimit - outputCursor;
      if (this.phaseCorrectionFrames !== 0 && this.canCorrectAudioPhase() &&
        this.phaseCorrectionCount < AUDIO_PHASE_CORRECTION_CAPACITY) {
        const stepFrames = Math.min(Math.abs(this.phaseCorrectionFrames),
          AUDIO_PHASE_LOCK_MAX_STEP_FRAMES);
        const dropFrames = this.phaseCorrectionFrames < 0 ? stepFrames : 0;
        const quietCursor = this.findQuietPhaseCorrectionCursor(bar, this.audioFrameCursor,
          phaseCopyLimit, dropFrames);
        if (quietCursor === this.audioFrameCursor) {
          if (this.phaseCorrectionFrames > 0) {
            const insertFrames = Math.min(stepFrames, outputLimit - outputCursor);
            this.recordPhaseCorrection(this.audioSubmittedFrames, insertFrames);
            applyDitherFloorToRange(output, outputCursor, outputCursor + insertFrames);
            outputCursor += insertFrames;
            this.audioSubmittedFrames += insertFrames;
            this.phaseCorrectionFrames -= insertFrames;
            continue;
          }
          this.recordPhaseCorrection(this.audioSubmittedFrames, -dropFrames);
          this.audioFrameCursor += dropFrames;
          this.phaseCorrectionFrames += dropFrames;
          continue;
        } else if (quietCursor > this.audioFrameCursor) {
          phaseCopyLimit = quietCursor - this.audioFrameCursor;
        }
      }

      const copyFrames = Math.min(bar.frameCount - this.audioFrameCursor,
        outputLimit - outputCursor, phaseCopyLimit);
      const preview = this.drumPreviewPlan;
      if (preview !== undefined && !preview.armed && !preview.renderedFill &&
        this.activeSequence === preview.rendered.plan.sequence) {
        const fillStart = preview.rendered.plan.fillStartFrames[this.activeSequenceIndex];
        if (fillStart >= 0 && fillStart < this.audioFrameCursor + copyFrames) {
          // Anchor the first submitted fill frame after any source-frame correction.
          // A threshold skipped by a drop begins at the next surviving source sample.
          this.recordDrumPreviewBoundary(preview, true,
            this.audioSubmittedFrames + Math.max(0, fillStart - this.audioFrameCursor));
        }
      }
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
    this.resetPhaseCorrectionState();
    this.audioWriteDiscontinuity = false;
    this.audioClockContinuityLost = false;
    this.backgroundPlaybackInterrupted = false;
    if (transition.kind === 'pause') {
      this.audioStreaming = false;
      if (DEBUG) {
        console.info(`OneBeatSync transition[pause] frame=${transition.targetFrame} ` +
          `submitted=${this.audioSubmittedFrames}`);
      }
      return;
    }
    const requiredCountIn = transition.routeRephase ? this.transportCountInBeats : transition.countInBeats;
    if ((!transition.routeRephase || !transition.preserveActiveSequence) &&
      !this.hasPreparedPlaybackBuffers(requiredCountIn)) {
      // A missing plan must remain silent, rather than build a multi-second PCM
      // bar in this callback or silently drop the count-in and play the main bar.
      this.audioStreaming = false;
      console.warn(`MetronomeEngine start buffers unavailable: token=${transition.token} ` +
        `countIn=${requiredCountIn} revision=${this.pendingRevision}`);
      return;
    }
    if (transition.routeRephase) {
      this.prepareRouteAudioCursor(transition.beatIndex, transition.preserveActiveSequence ?? false);
    } else {
      this.prepareAudioCursor(transition.beatIndex, transition.countInBeats);
    }
    this.audioStreaming = true;
    // The click reaches the acoustic output outputLatencyMs after its hardware
    // presentation frame, so the visual/audio playhead origin includes both.
    this.audioTimelineLeadFrames = transition.targetFrame +
      Math.round(transition.outputLatencyMs * SAMPLE_RATE / 1000) -
      (transition.timelineElapsedFrames ?? 0);
    this.audioTimelineOutputLatencyMs = transition.outputLatencyMs;
    this.audioTimelineToken = transition.token;
    this.phaseFeedbackStartFrame = transition.targetFrame;
    this.audioSequenceTransportRevision = this.transportRevision;
    const preview = this.drumPreviewPlan;
    if (preview !== undefined && !preview.armed && preview.started &&
      this.activeSequence === preview.rendered.plan.sequence) {
      this.recordDrumPreviewBoundary(preview);
    }
    this.lastAudioPlayheadMs = 0;
    this.lastAudioSampleMonoMs = this.transportStartLocalMs;
    const startTiming = this.startTimingTransition;
    if (startTiming?.transition === transition && startTiming.estimate.token === this.runToken) {
      this.startTimingTransition = undefined;
      const appliedMonoMs = MonotonicClock.nowMs();
      const context = this.startWriteBufferContext;
      const targetOffsetFrames = context !== undefined ? transition.targetFrame - context.bufferStartFrame : -1;
      const bufferKnown = context !== undefined && context.startTiming === startTiming &&
        context.rendererEpoch === this.rendererEpoch &&
        context.physicalStartCount === this.rendererPhysicalStartCount &&
        targetOffsetFrames >= 0 && targetOffsetFrames < context.bufferFrames;
      if (bufferKnown && context !== undefined) {
        context.applied = true;
      }
      console.info(`[StartTimingDiag] stage=applied seq=${startTiming.sequence} token=${transition.token} ` +
        `beat=${transition.beatIndex} targetFrame=${transition.targetFrame} submittedFrame=${this.audioSubmittedFrames} ` +
        `appliedMonoMs=${appliedMonoMs.toFixed(1)} audibleLeadMs=${(startTiming.audibleMs - appliedMonoMs).toFixed(1)} ` +
        `estimatedFrameDeadlineDeltaMs=${(appliedMonoMs - startTiming.estimate.targetHardwareMs).toFixed(1)} ` +
        `clampMs=${(Math.max(0, transition.targetFrame - startTiming.estimate.requestedFrame) * 1000 / SAMPLE_RATE).toFixed(2)} ` +
        `bufferContextKnown=${bufferKnown} ` +
        `callbackEntryMonoMs=${bufferKnown && context !== undefined ? context.callbackEntryMonoMs.toFixed(1) : 'unknown'} ` +
        `bufferStartFrame=${bufferKnown && context !== undefined ? context.bufferStartFrame : 'unknown'} ` +
        `bufferFrames=${bufferKnown && context !== undefined ? context.bufferFrames : 'unknown'} ` +
        `targetOffsetFrames=${bufferKnown ? targetOffsetFrames : 'unknown'} ` +
        `targetOffsetMs=${bufferKnown ? (targetOffsetFrames * 1000 / SAMPLE_RATE).toFixed(2) : 'unknown'} ` +
        `previousCallbackGapMs=${bufferKnown && context?.previousCallbackGapMs !== undefined ? context.previousCallbackGapMs.toFixed(1) : 'unknown'} ` +
        `cachedUnderflowCount=${this.lastUnderflowCount} ` +
        `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
        `physicalStartCount=${this.rendererPhysicalStartCount} audioClockLocked=${this.audioClockLocked}`);
    }
    if (transition.routeRephase) {
      const now = MonotonicClock.nowMs();
      this.lastAudioPlayheadMs = now - this.transportStartLocalMs;
      this.lastAudioSampleMonoMs = now;
      this.lastTimestampQueryMonoMs = -1;
      console.info(`[RouteRephaseDiag] stage=applied token=${transition.token} ` +
        `beat=${transition.beatIndex} compensationMs=${transition.outputLatencyMs} ` +
        `timelineElapsedFrames=${transition.timelineElapsedFrames ?? 0}`);
    }
    if (DEBUG) {
      console.info(`OneBeatSync transition[play] frame=${transition.targetFrame} ` +
        `submitted=${this.audioSubmittedFrames} latency=${transition.outputLatencyMs}`);
    }
  }

  private logStartWriteCompletion(context: StartWriteBufferContext, fillCompletedMonoMs: number): void {
    const startTiming = context.startTiming;
    if (startTiming.transition.token !== this.runToken || startTiming.estimate.token !== this.runToken ||
      context.rendererEpoch !== this.rendererEpoch ||
      context.physicalStartCount !== this.rendererPhysicalStartCount) {
      return;
    }
    const targetOffsetFrames = startTiming.transition.targetFrame - context.bufferStartFrame;
    // This is sampled after filling PCM but before VALID is returned. It does
    // not prove native acceptance or presentation; the duration excludes this log.
    const callbackDurationMs = fillCompletedMonoMs >= context.callbackEntryMonoMs
      ? (fillCompletedMonoMs - context.callbackEntryMonoMs).toFixed(1) : 'unknown';
    console.info(`[StartTimingDiag] stage=write-complete seq=${startTiming.sequence} ` +
      `token=${startTiming.transition.token} targetFrame=${startTiming.transition.targetFrame} ` +
      `callbackEntryMonoMs=${context.callbackEntryMonoMs.toFixed(1)} ` +
      `fillCompletedMonoMs=${fillCompletedMonoMs.toFixed(1)} fillCompletedBeforeReturn=true ` +
      `callbackDurationMs=${callbackDurationMs} bufferStartFrame=${context.bufferStartFrame} ` +
      `bufferFrames=${context.bufferFrames} targetOffsetFrames=${targetOffsetFrames} ` +
      `targetOffsetMs=${(targetOffsetFrames * 1000 / SAMPLE_RATE).toFixed(2)} ` +
      `previousCallbackGapMs=${context.previousCallbackGapMs?.toFixed(1) ?? 'unknown'} ` +
      `cachedUnderflowCount=${this.lastUnderflowCount} ` +
      `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
      `physicalStartCount=${this.rendererPhysicalStartCount}`);
  }

  private async lockAudioStartToPresentationClock(
    renderer: audio.AudioRenderer,
    localAudibleStart: number,
    rendererStartRequestedAtMs: number,
    token: number,
    outputCompensationOverrideMs?: number
  ): Promise<void> {
    this.preparePlaybackBuffers(this.pendingAudioTransition?.countInBeats ?? 0);
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
        const requestedFrame = Math.round(playedFramesNow + (hardwareStartAt - now) * SAMPLE_RATE / 1000);
        const targetFrame = Math.max(this.audioSubmittedFrames, requestedFrame);
        this.cacheStartTargetEstimate('timestamp', now, hardwareStartAt, playedFramesNow, requestedFrame, targetFrame);
        this.updatePendingPlayTransition(targetFrame, outputCompensationMs, token);
        this.logProductionClockDiagnostic('cold-lock', localAudibleStart);
        this.logStartTimingTarget('cold-lock', this.pendingAudioTransition, localAudibleStart, outputCompensationMs);
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
    this.preparePlaybackBuffers(countInBeats);
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
    const transition: PendingAudioTransition = {
      kind: 'play',
      token: token,
      targetFrame: this.estimateTargetStreamFrame(hardwareStartAt),
      beatIndex: beatIndex,
      countInBeats: countInBeats,
      outputLatencyMs: outputCompensationMs
    };
    this.scheduleRunningTransition(transition);
    this.logProductionClockDiagnostic('cold-settle', localAudibleStart);
    this.logStartTimingTarget('cold-settle', transition, localAudibleStart, outputCompensationMs);
  }

  private scheduleRunningTransition(transition: PendingAudioTransition): void {
    if (transition.token !== this.runToken) {
      return;
    }
    if (transition.kind === 'play' && !transition.routeRephase &&
      (this.transportPreviewStartPositionBeats !== undefined ||
      (this.phaseCorrectionEnabled && this.transportUsesSharedClock))) {
      // Recovery resumes a later beat of the same transport, not elapsed zero.
      // Otherwise feedback would mistake the entire pre-recovery duration for
      // drift. Preview seeks include a source offset but share this elapsed origin.
      transition.timelineElapsedFrames = Math.round(Math.max(0,
        transition.beatIndex - this.transportStartBeatIndex) * 60 * SAMPLE_RATE / this.transportBpm);
    }
    transition.targetFrame = Math.max(this.audioSubmittedFrames, transition.targetFrame);
    this.pendingAudioTransition = transition;
    this.startTimingTransition = undefined;
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
        const requestedFrame = Math.round(played + (targetHardwareAtMs - now) * SAMPLE_RATE / 1000);
        const selectedFrame = Math.max(this.audioSubmittedFrames, requestedFrame);
        this.cacheStartTargetEstimate('timestamp', now, targetHardwareAtMs, played, requestedFrame, selectedFrame);
        return selectedFrame;
      }
    }
    const requestedFrame = Math.round(this.audioSubmittedFrames +
      (targetHardwareAtMs - now) * SAMPLE_RATE / 1000 - this.queueDepthFrames);
    const selectedFrame = Math.max(this.audioSubmittedFrames, requestedFrame);
    this.cacheStartTargetEstimate('fallback', now, targetHardwareAtMs,
      this.audioSubmittedFrames - this.queueDepthFrames, requestedFrame, selectedFrame);
    return selectedFrame;
  }

  private cacheStartTargetEstimate(mode: StartTargetMode, queryMonoMs: number,
    targetHardwareMs: number, playedFrame: number, requestedFrame: number, selectedFrame: number): void {
    const estimate: StartTargetEstimate = { token: this.runToken, mode, queryMonoMs, targetHardwareMs,
      playedFrame, requestedFrame, selectedFrame, submittedAtEstimate: this.audioSubmittedFrames };
    const sample = this.productionClockSample;
    // The next diagnostic read can replace productionClockSample. Bind this
    // copy to the target's first legacy query; exact/fallback reads have no copy.
    if (mode === 'timestamp' && this.startTimingRequest?.token === this.runToken &&
      !this.lastAudioFrameMapExact && sample !== undefined && sample.queryMonoMs === queryMonoMs &&
      sample.rendererEpoch === this.rendererEpoch && sample.streamId === this.rendererStreamId &&
      sample.physicalStartCount === this.rendererPhysicalStartCount &&
      sample.submittedFrames === this.audioSubmittedFrames && sample.renderedFrame === playedFrame) {
      const uncappedMappedFrame = sample.rawFrame - sample.baseFrame +
        Math.max(0, Math.min(250, sample.legacyAgeMs)) * SAMPLE_RATE / 1000;
      estimate.frameMapping = {
        rawFrame: sample.rawFrame, rawTimestampMs: sample.rawTimestampMs,
        baseFrame: sample.baseFrame, uncappedMappedFrame,
        submittedCapFrames: Math.max(0, uncappedMappedFrame - sample.submittedFrames),
        legacyAgeMs: sample.legacyAgeMs
      };
    }
    this.startTargetEstimate = estimate;
  }

  private logStartTimingTarget(path: string, transition: PendingAudioTransition | undefined,
    audibleMs: number, compensationMs: number): void {
    // Reuse the exact target-selection sample. Another timestamp/latency query
    // here would perturb the short first-start margin we are investigating.
    const estimate = this.startTargetEstimate;
    if (estimate === undefined || estimate.token !== this.runToken) {
      return;
    }
    const request = this.startTimingRequest?.token === this.runToken ? this.startTimingRequest : undefined;
    const targetPending = transition !== undefined && transition.kind === 'play' &&
      transition.token === this.runToken && this.pendingAudioTransition === transition;
    const committedFrame = targetPending && transition !== undefined ? transition.targetFrame : estimate.selectedFrame;
    if (targetPending && transition !== undefined) {
      this.startTimingTransition = { transition, estimate, audibleMs, sequence: request?.sequence ?? 0 };
    }
    const timerLateMs = request !== undefined && request.timerFiredAtMs >= 0 ?
      request.timerFiredAtMs - request.timerDueAtMs : -1;
    const operationWaitMs = request !== undefined && request.timerFiredAtMs >= 0 ?
      request.operationStartedAtMs - request.timerFiredAtMs : -1;
    const mapping = estimate.frameMapping;
    console.info(`[StartTimingDiag] stage=target path=${path} seq=${request?.sequence ?? 0} token=${this.runToken} ` +
      `mode=${estimate.mode} queryMonoMs=${estimate.queryMonoMs.toFixed(1)} ` +
      `targetHardwareMs=${estimate.targetHardwareMs.toFixed(1)} audibleMs=${audibleMs.toFixed(1)} compensationMs=${compensationMs} ` +
      `requestedFrame=${estimate.requestedFrame} submittedAtEstimate=${estimate.submittedAtEstimate} ` +
      `selectedFrame=${estimate.selectedFrame} committedFrame=${committedFrame} targetPending=${targetPending} ` +
      `headroomMs=${((estimate.requestedFrame - estimate.submittedAtEstimate) * 1000 / SAMPLE_RATE).toFixed(2)} ` +
      `clampMs=${(Math.max(0, committedFrame - estimate.requestedFrame) * 1000 / SAMPLE_RATE).toFixed(2)} ` +
      `queueEstimateMs=${((estimate.submittedAtEstimate - estimate.playedFrame) * 1000 / SAMPLE_RATE).toFixed(1)} ` +
      `estimateFrameMapKnown=${mapping !== undefined} estimateRawFrame=${mapping?.rawFrame ?? 'unknown'} ` +
      `estimateRawTimestampMs=${mapping?.rawTimestampMs.toFixed(3) ?? 'unknown'} ` +
      `estimateBaseFrame=${mapping?.baseFrame ?? 'unknown'} ` +
      `uncappedMappedFrame=${mapping?.uncappedMappedFrame.toFixed(1) ?? 'unknown'} ` +
      `submittedCapFrames=${mapping?.submittedCapFrames.toFixed(1) ?? 'unknown'} ` +
      `submittedCapMs=${mapping !== undefined ? (mapping.submittedCapFrames * 1000 / SAMPLE_RATE).toFixed(2) : 'unknown'} ` +
      `estimateLegacyAgeMs=${mapping?.legacyAgeMs.toFixed(1) ?? 'unknown'} ` +
      `remainingAudibleMs=${(audibleMs - estimate.queryMonoMs).toFixed(1)} ` +
      `timerLateMs=${timerLateMs.toFixed(1)} operationWaitMs=${operationWaitMs.toFixed(1)} ` +
      `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
      `physicalStartCount=${this.rendererPhysicalStartCount} audioClockLocked=${this.audioClockLocked}`);
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

  private static readSoftwareLatencyMs(renderer: audio.AudioRenderer): number {
    try {
      return renderer.getLatency(audio.AudioLatencyType.LATENCY_TYPE_SOFTWARE);
    } catch (_e) {
      return -1;
    }
  }

  private static readOutputLatencySnapshot(renderer: audio.AudioRenderer): OutputLatencySnapshot {
    return {
      allMs: MetronomeEngine.readOutputLatencyMs(renderer),
      softwareMs: MetronomeEngine.readSoftwareLatencyMs(renderer),
      hardwareMs: MetronomeEngine.readHardwareLatencyMs(renderer)
    };
  }

  private static describeOutputDevices(renderer: audio.AudioRenderer): string {
    try {
      const devices = renderer.getCurrentOutputDevicesSync();
      const parts: string[] = [];
      for (let i = 0; i < devices.length; i++) {
        parts.push(`${devices[i].deviceType}:${devices[i].id}`);
      }
      return parts.length > 0 ? parts.join(',') : 'none';
    } catch (_e) {
      return 'unavailable';
    }
  }

  private static readAudioScene(): number {
    try {
      return audio.getAudioManager().getAudioSceneSync();
    } catch (_e) {
      return -1;
    }
  }

  private logMicCalibrationAudioStateForRenderer(phase: string,
    renderer: audio.AudioRenderer): OutputLatencySnapshot {
    const latency = MetronomeEngine.readOutputLatencySnapshot(renderer);
    let rawFrame = -1;
    try {
      rawFrame = renderer.getAudioTimestampInfoSync().framePos;
    } catch (_e) {
      // Timestamp availability is already enforced separately by the mic clock gate.
    }
    console.info(`[OutputPathDiag] phase=${phase} rendererEpoch=${this.rendererEpoch} ` +
      `streamId=${this.rendererStreamId} state=${renderer.state} started=${this.rendererStarted} ` +
      `outputDevices=[${MetronomeEngine.describeOutputDevices(renderer)}] ` +
      `latencyAll=${latency.allMs} latencySoftware=${latency.softwareMs} ` +
      `latencyHardware=${latency.hardwareMs} audioScene=${MetronomeEngine.readAudioScene()} ` +
      `rawFrame=${rawFrame} submitted=${this.audioSubmittedFrames} ` +
      `queueDepth=${this.queueDepthFrames.toFixed(1)} exact=${this.calibrationFrameOriginExact}`);
    return latency;
  }

  /** Read-only snapshot used to compare the capturer-active and production output paths. */
  logMicCalibrationAudioState(phase: string): void {
    const renderer = this.renderer;
    if (renderer === undefined) {
      console.info(`[OutputPathDiag] phase=${phase} renderer=none rendererEpoch=${this.rendererEpoch}`);
      return;
    }
    this.logMicCalibrationAudioStateForRenderer(phase, renderer);
  }

  /**
   * The experiment reads existing production state; it must never prime/rebase
   * that state to obtain a prettier result. Slow latency/route queries belong
   * at phase boundaries, not in the audio callback or the 100ms observer.
   */
  readMicExperimentPlaybackSnapshot(includeOutputDetails: boolean = false): MicExperimentPlaybackSnapshot {
    const renderer = this.renderer;
    // Raw hardware coordinates remain observable even if the production frame
    // origin is approximate. Reading them must not make that origin exact.
    const clock = renderer === undefined ? undefined : this.readCalibrationClockSample(renderer, true, false);
    let underflows = -1;
    if (renderer !== undefined) {
      try { underflows = renderer.getUnderflowCountSync(); } catch (_error) {}
    }
    const latency = renderer !== undefined && includeOutputDetails ?
      MetronomeEngine.readOutputLatencySnapshot(renderer) : undefined;
    return {
      sampledAtMonoMs: MonotonicClock.nowMs(), rendererEpoch: this.rendererEpoch,
      streamId: this.rendererStreamId, physicalStartCount: this.rendererPhysicalStartCount,
      running: this.running, started: this.rendererStarted, state: renderer?.state ?? -1,
      writeCallbackCount: this.writeCallbackCount, submittedFrames: this.audioSubmittedFrames,
      lastWriteProgressMs: this.lastWriteProgressMs,
      interruptCount: this.experimentInterruptCount, lastInterruptHint: this.experimentLastInterruptHint,
      lastInterruptForce: this.experimentLastInterruptForce, underflowCount: underflows,
      outputDevices: renderer !== undefined && includeOutputDetails ?
        MetronomeEngine.describeOutputDevices(renderer) : '',
      audioScene: includeOutputDetails ? MetronomeEngine.readAudioScene() : -1,
      latencyAllMs: latency?.allMs ?? -1, latencyHardwareMs: latency?.hardwareMs ?? -1,
      latencySoftwareMs: latency?.softwareMs ?? -1,
      rawFrame: clock?.framePos ?? -1, timestampMonoMs: clock?.timestampMonoMs ?? -1,
      productionClockQueryMonoMs: this.productionClockSample?.queryMonoMs ?? -1,
      productionFrame: this.productionClockSample?.renderedFrame ?? -1,
      transportStartLocalMs: this.transportStartLocalMs,
      transportStartBeatIndex: this.transportStartBeatIndex, transportBpm: this.transportBpm,
      transportOutputCompensationMs: this.audioTimelineOutputLatencyMs, sharedClockOffsetMs: this.offsetMs
    };
  }

  /**
   * Bridge a mic result to the already-established production frame coordinate.
   * Do not prime or rebase that coordinate here: doing so would change the very
   * playback mapping being measured. Raw and legacy frames use one timestamp
   * sample so hardware timestamp quantization cannot enter their difference.
   */
  readMicCalibrationPlaybackReference(expected?: CalibrationPlaybackReference): CalibrationPlaybackReference {
    const renderer = this.renderer;
    const clockOffsetMs = this.audioTimestampClockOffsetMs;
    if (expected !== undefined &&
      (this.rendererEpoch !== expected.rendererEpoch || this.rendererStreamId !== expected.streamId)) {
      throw new Error('测量后的正式播放基准发生变化，请重新测量');
    }
    if (renderer === undefined || !this.rendererStarted ||
      renderer.state !== audio.AudioState.STATE_RUNNING || !this.calibrationFrameOriginExact ||
      this.calibrationRouteResetPending || this.micCalibrationRendererRebuildPending ||
      !this.audioTimestampBaseReady || clockOffsetMs === undefined ||
      !Number.isFinite(clockOffsetMs) || !Number.isFinite(this.audioTimestampBaseFrame) ||
      !Number.isFinite(this.audioSubmittedFrames) || this.audioSubmittedFrames <= 0 ||
      EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP) {
      throw new Error('麦克回环尚未取得可复用的正式播放时间基准，请重新测量');
    }
    const sample = this.readCalibrationClockSample(renderer, true);
    if (sample === undefined || !Number.isFinite(sample.framePos) ||
      !Number.isFinite(sample.rawTimestampMs) || !Number.isFinite(sample.queryMonoMs)) {
      console.info(`[MicPlaybackBridge] state=pending reason=timestamp-unavailable ` +
        `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId}`);
      throw new MicPlaybackClockPendingError('timestamp-unavailable');
    }
    const rawAgeMs = sample.queryMonoMs - sample.timestampMonoMs;
    const legacyAgeMs = sample.queryMonoMs - (sample.rawTimestampMs - clockOffsetMs);
    // Production contains stale timestamps with a 250ms interpolation clamp.
    // A calibration bridge must reject that stale state rather than turn the
    // clamp into an apparently stable, but time-dependent, coordinate offset.
    if (!Number.isFinite(rawAgeMs) || !Number.isFinite(legacyAgeMs) ||
      rawAgeMs < -50 || legacyAgeMs < -50 ||
      (this.lastAudioRawFrame >= 0 &&
        this.calibrationFramePosRegressedBeyondQuantum(this.lastAudioRawFrame, sample.framePos)) ||
      (expected !== undefined &&
        (this.calibrationFramePosRegressedBeyondQuantum(expected.framePos, sample.framePos) ||
          sample.timestampMonoMs < expected.timestampMonoMs - 1))) {
      console.warn(`[MicPlaybackBridge] state=invalid reason=clock-regression-or-future-timestamp ` +
        `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
        `rawAgeMs=${rawAgeMs.toFixed(1)} legacyAgeMs=${legacyAgeMs.toFixed(1)} ` +
        `framePos=${sample.framePos} lastRawFrame=${this.lastAudioRawFrame}`);
      throw new Error('麦克回环播放时钟已失效，请保持当前输出设备后重新测量');
    }
    if (rawAgeMs > 250 || legacyAgeMs > 250) {
      // Keep the strict freshness gate. Capture teardown and callback backlog
      // may briefly freeze a live stream; verification can wait for new samples.
      console.info(`[MicPlaybackBridge] state=pending reason=timestamp-stale ` +
        `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
        `rawAgeMs=${rawAgeMs.toFixed(1)} legacyAgeMs=${legacyAgeMs.toFixed(1)} ` +
        `framePos=${sample.framePos} submittedFrames=${this.audioSubmittedFrames}`);
      throw new MicPlaybackClockPendingError('timestamp-stale');
    }
    const rawFrameAtQuery = sample.framePos + rawAgeMs * SAMPLE_RATE / 1000;
    const legacyFrameAtQuery = sample.framePos - this.audioTimestampBaseFrame +
      Math.max(0, Math.min(250, legacyAgeMs)) * SAMPLE_RATE / 1000;
    if (!Number.isFinite(rawFrameAtQuery) || !Number.isFinite(legacyFrameAtQuery) ||
      rawFrameAtQuery < -CALIB_CLOCK_FRAME_POS_QUANTUM ||
      legacyFrameAtQuery < -CALIB_CLOCK_FRAME_POS_QUANTUM ||
      rawFrameAtQuery > this.audioSubmittedFrames + CALIB_CLOCK_FRAME_POS_QUANTUM ||
      legacyFrameAtQuery > this.audioSubmittedFrames + CALIB_CLOCK_FRAME_POS_QUANTUM) {
      throw new Error('麦克回环播放帧超出当前音频流范围，请重新测量');
    }
    const rawFrame = Math.min(this.audioSubmittedFrames, Math.max(0, rawFrameAtQuery));
    const legacyFrame = Math.min(this.audioSubmittedFrames, Math.max(0, legacyFrameAtQuery));
    const frameMappingOffsetMs = (legacyFrame - rawFrame) * 1000 / SAMPLE_RATE;
    console.info(`[MicPlaybackBridge] rendererEpoch=${this.rendererEpoch} ` +
      `streamId=${this.rendererStreamId} rawFrame=${rawFrame.toFixed(1)} ` +
      `legacyFrame=${legacyFrame.toFixed(1)} m=${frameMappingOffsetMs.toFixed(1)}ms ` +
      `rawAgeMs=${rawAgeMs.toFixed(1)} legacyAgeMs=${legacyAgeMs.toFixed(1)} ` +
      `sampledAtMonoMs=${sample.queryMonoMs.toFixed(1)}`);
    return {
      rendererEpoch: this.rendererEpoch,
      streamId: this.rendererStreamId,
      frameMappingOffsetMs,
      sampledAtMonoMs: sample.queryMonoMs,
      framePos: sample.framePos,
      timestampMonoMs: sample.timestampMonoMs,
      submittedFrames: this.audioSubmittedFrames
    };
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
        // Saved compensation belongs to the production frame mapping. Its
        // difference from a platform estimate is not an independent acoustic
        // measurement; keep these legacy logs out of mic input calibration.
        const platform = MetronomeEngine.readOutputLatencyMs(renderer);
        console.info(`[LatencyDiag] route=BT calibrated=${calibrated} platform=${platform} ` +
          `inputLatency=${getInputLatencyMs()} resultMs=${calibrated + getInputLatencyMs()} ` +
          `delta=${calibrated - platform}ms`);
        // resultMs/inputBT are legacy inferred diagnostics, not captured timings.
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

  /**
   * Move only this device's output onto a future beat of the existing shared
   * transport. Queued PCM cannot be recalled; missed beats are skipped rather
   * than replayed. The local token cancels old native starts, not the team clock.
   * Success requires writeData to apply the target, not merely queue it locally.
   */
  async rescheduleForOutputRouteChange(): Promise<boolean> {
    const generation = ++this.outputRouteRephaseGeneration;
    this.outputRouteRephasePreparing = true;
    try {
      return await this.rescheduleOutputRouteInternal();
    } finally {
      if (generation === this.outputRouteRephaseGeneration) {
        this.outputRouteRephasePreparing = false;
      }
    }
  }

  private async rescheduleOutputRouteInternal(): Promise<boolean> {
    if (!this.running || this.transportOutputCompensationOverrideMs !== undefined ||
      (this.audioSequenceTransportRevision === this.transportRevision && this.activeSequenceFinished)) {
      return false;
    }
    const previous = this.pendingAudioTransition;
    const oldCompensationMs = Math.max(this.audioTimelineOutputLatencyMs,
      previous?.kind === 'play' ? previous.outputLatencyMs : 0);
    // Route retokens are local cancellation boundaries, not a new transport.
    // Keep the original sequence across several switches before any new target
    // has reached writeData; only a real shared start changes this revision.
    const preserveActiveSequence = this.audioSequenceTransportRevision === this.transportRevision &&
      this.activeSequence.length > 0;
    const pendingPauseAt = this.scheduledPauseAtLocalMs;
    const token = this.beginTransport(true);
    this.audioStreaming = false;
    this.phaseCorrectionFrames = 0;
    // UI callbacks stay on the same nextBeatAt/beatIndex grid. Reusing a new
    // local token prevents an old cold lock/settle from overwriting this route.
    if (pendingPauseAt !== undefined) {
      // A route update must never replace a shared pause with a play transition.
      this.schedulePauseFromLeader(pendingPauseAt + this.offsetMs);
      if (pendingPauseAt > MonotonicClock.nowMs()) {
        this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token),
          Math.max(0, this.localTimeForTransportGrid(this.nextBeatAtMs, MonotonicClock.nowMs()) - MonotonicClock.nowMs()));
      }
      return false;
    }
    this.timerId = setTimeout(() => this.emitBeatAndScheduleNext(token),
      Math.max(0, this.localTimeForTransportGrid(this.nextBeatAtMs, MonotonicClock.nowMs()) - MonotonicClock.nowMs()));
    let abandoned = false;
    const current = (): boolean => !abandoned && token === this.runToken && this.running &&
      this.scheduledPauseAtLocalMs === undefined;
    let selected: PendingAudioTransition | undefined = undefined;
    let applyDeadline = Number.POSITIVE_INFINITY;
    this.expiredRouteToken = -1;
    try {
      while (current()) {
        if (!await this.prepareOutputRouteRenderer(current, applyDeadline)) {
          return false;
        }
        selected = await this.installOutputRouteTransition(token, oldCompensationMs,
          preserveActiveSequence, current);
        if (selected === undefined) {
          return false;
        }
        if (!Number.isFinite(applyDeadline)) {
          // Retrying a frozen target must not extend this request forever.
          // Native preparation remains separately bounded before this deadline.
          applyDeadline = (selected.hardwareAtLocalMs ?? MonotonicClock.nowMs()) +
            ROUTE_REPHASE_READY_TIMEOUT_MS;
        }
        while (current()) {
          if (this.audioTimelineToken === token) {
            return true;
          }
          const now = MonotonicClock.nowMs();
          if (now >= applyDeadline) {
            throw new Error('声音出口切换后的节拍未能及时写入，请暂停后重新开始');
          }
          if (this.expiredRouteToken === token ||
            (selected.hardwareAtLocalMs !== undefined && now >= selected.hardwareAtLocalMs) ||
            now - this.lastWriteProgressMs >= AUDIO_CALLBACK_STALL_MS) {
            if (this.pendingAudioTransition === selected) {
              this.pendingAudioTransition = undefined;
            }
            this.expiredRouteToken = -1;
            console.info(`[RouteRephaseDiag] stage=retry token=${token} beat=${selected.beatIndex}`);
            break;
          }
          await MetronomeEngine.delay(20);
        }
      }
      return false;
    } catch (err) {
      const stillOwned = current();
      abandoned = true;
      if (this.pendingAudioTransition === selected && selected !== undefined) {
        this.pendingAudioTransition = undefined;
      }
      if (!stillOwned) {
        return false;
      }
      throw new Error((err as Error).message);
    }
  }

  private async prepareOutputRouteRenderer(current: () => boolean,
    applyDeadline: number): Promise<boolean> {
    const writesBefore = this.writeCallbackCount;
    const preparation: RouteRendererPreparation = { settled: false };
    const preparationStartedAt = MonotonicClock.nowMs();
    const prepareRenderer = async (): Promise<void> => {
      await this.ensureRenderer();
      if (!current()) {
        return;
      }
      // A healthy renderer already follows the system route; restarting it would
      // discard its queue and frame mapping. Only a stopped/stalled stream recovers.
      await this.ensureSilentRendererRunning(false, () => !current(), true);
    };
    void prepareRenderer().then(() => {
      preparation.settled = true;
    }, (err: Error) => {
      preparation.error = err;
      preparation.settled = true;
    });
    while (!preparation.settled) {
      if (!current()) {
        return false;
      }
      if (MonotonicClock.nowMs() >= Math.min(applyDeadline,
        preparationStartedAt + ROUTE_REPHASE_READY_TIMEOUT_MS)) {
        // Native stop/start cannot be revoked. Its serialized operation remains
        // queued, but late completion may no longer install this logical route.
        throw new Error('声音出口切换准备超时，请暂停后重新开始');
      }
      await MetronomeEngine.delay(20);
    }
    if (!current()) {
      return false;
    }
    if (preparation.error !== undefined) {
      throw new Error((preparation.error as Error).message);
    }
    const readyAt = MonotonicClock.nowMs();
    while (this.writeCallbackCount <= writesBefore ||
      MonotonicClock.nowMs() - readyAt < ROUTE_REPHASE_SETTLE_MS) {
      if (!current()) {
        return false;
      }
      if (MonotonicClock.nowMs() >= Math.min(applyDeadline,
        readyAt + ROUTE_REPHASE_READY_TIMEOUT_MS)) {
        throw new Error('声音出口切换后未收到音频写入，请暂停后重新开始');
      }
      await MetronomeEngine.delay(20);
    }
    return current();
  }

  private async installOutputRouteTransition(token: number, oldCompensationMs: number,
    preserveActiveSequence: boolean, current: () => boolean): Promise<PendingAudioTransition | undefined> {
    const selection: RouteRephaseSelection = {};
    await this.queueRendererOperation(async () => {
      const renderer = this.renderer;
      if (!current() || renderer === undefined) {
        return;
      }
      if (!this.rendererStarted || renderer.state !== audio.AudioState.STATE_RUNNING) {
        throw new Error('声音出口切换后音频输出尚未恢复，请暂停后重新开始');
      }
      if (!preserveActiveSequence) {
        this.preparePlaybackBuffers(this.transportCountInBeats);
      }
      this.refreshOutputLatency();
      const compensationMs = this.outputLatencyMs;
      const now = MonotonicClock.nowMs();
      const rendered = this.readRenderedStreamFrames(renderer, now);
      const queueMs = rendered === undefined ? Math.max(1000, this.queueDepthFrames * 1000 / SAMPLE_RATE) :
        Math.max(0, (this.audioSubmittedFrames - rendered) * 1000 / SAMPLE_RATE);
      // Include both routes: old queued clicks must precede the new beat even
      // when the new device has much less delay than the previous headphones.
      const earliestAudible = now + queueMs + Math.max(oldCompensationMs, compensationMs) +
        ROUTE_REPHASE_GUARD_MS;
      const beatMs = 60000 / Math.max(1, this.transportBpm);
      const adjustment = this.transportClockAdjustmentAt(now);
      let steps = Math.max(0, Math.ceil((earliestAudible + adjustment - this.transportStartLocalMs) / beatMs));
      let audibleAt = this.localTimeForTransportGrid(this.transportStartLocalMs + steps * beatMs, now);
      let targetFrame = this.estimateTargetStreamFrame(audibleAt - compensationMs);
      // A slow timestamp query can consume the guard. Choose a later real beat,
      // never clamp an already-late beat into the queue at a non-beat time.
      for (let i = 0; i < 8 && targetFrame < this.audioSubmittedFrames +
        Math.round(ROUTE_REPHASE_GUARD_MS * SAMPLE_RATE / 1000); i++) {
        steps++;
        audibleAt = this.localTimeForTransportGrid(this.transportStartLocalMs + steps * beatMs, now);
        targetFrame = this.estimateTargetStreamFrame(audibleAt - compensationMs);
      }
      if (targetFrame < this.audioSubmittedFrames +
        Math.round(ROUTE_REPHASE_GUARD_MS * SAMPLE_RATE / 1000)) {
        throw new Error('声音出口切换后的音频队列尚未稳定，请暂停后重新开始');
      }
      const beatIndex = this.transportStartBeatIndex + steps;
      const transition: PendingAudioTransition = {
        kind: 'play', token, targetFrame, beatIndex, countInBeats: 0,
        outputLatencyMs: compensationMs, routeRephase: true, preserveActiveSequence,
        hardwareAtLocalMs: audibleAt - compensationMs,
        timelineElapsedFrames: Math.round(steps * beatMs * SAMPLE_RATE / 1000)
      };
      this.scheduleRunningTransition(transition);
      selection.transition = transition;
      console.info(`[RouteRephaseDiag] stage=scheduled token=${token} beat=${beatIndex} ` +
        `audible=${audibleAt.toFixed(1)} oldCompensationMs=${oldCompensationMs} ` +
        `compensationMs=${compensationMs} queueMs=${queueMs.toFixed(1)} targetFrame=${targetFrame}`);
      this.logProductionClockDiagnostic('route-rephase', audibleAt);
    });
    return selection.transition;
  }

  private advanceAudioBar(): void {
    const preview = this.drumPreviewPlan;
    if (preview !== undefined && !preview.armed &&
      this.activeSequence === preview.rendered.plan.sequence) {
      const nextBar = preview.renderedBar + 1;
      const activation = this.drumPreviewActivationAt(preview, nextBar);
      const staged = this.stagedDrumPreviewUpdate;
      if (activation === preview.rendered && preview.rendered === preview.newest &&
        staged !== undefined && staged.revision === this.drumPreviewUpdateRevision &&
        staged.base === preview.rendered.plan) {
        const prepared = staged.activation;
        prepared.startBar = nextBar;
        prepared.startIndex = staged.nextIndices[this.activeSequenceIndex];
        prepared.previous = preview.newest;
        preview.newest = prepared;
        this.customProgramRaw = prepared.plan.raw;
        this.customProgram = prepared.plan.program;
        this.customProgramLooping = true;
        this.sampleBank = prepared.plan.bank;
        this.pendingSequence = prepared.plan.sequence;
        this.pendingSequenceLooping = true;
        this.pendingRevision++;
        this.stagedDrumPreviewUpdate = undefined;
        this.setDrumPreviewCursor(preview, prepared, nextBar);
      } else {
        // Route recovery may revisit an older audible revision. Replay already-
        // submitted changes at their original bars before adopting a newer edit;
        // the native queue may still contain that future revision's PCM.
        this.setDrumPreviewCursor(preview, activation, nextBar);
      }
      this.recordDrumPreviewBoundary(preview);
      return;
    }
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

  private setDrumPreviewCursor(context: DrumPreviewPlanContext, activation: DrumPreviewActivation,
    bar: number, beatInBar: number = 0): void {
    context.rendered = activation;
    context.renderedBar = bar;
    this.activeSequence = activation.plan.sequence;
    this.activeSequenceLooping = true;
    this.activeSequenceFinished = false;
    this.activeRevision = this.pendingRevision;
    this.deferPendingSequenceActivation = false;
    this.activeSequenceIndex = this.drumPreviewIndexAt(activation, bar);
    this.activeLoopStartIndex = 0;
    this.activeBar = this.activeSequence[this.activeSequenceIndex];
    this.audioFrameCursor = Math.min(this.activeBar.frameCount - 1,
      Math.max(0, Math.round(beatInBar * this.activeBar.samplesPerBeat)));
  }

  private prepareDrumPreviewCursorAtBeat(context: DrumPreviewPlanContext, beatIndex: number): void {
    if (!context.started) {
      context.initialBeatOffset = ((this.transportStartBeatIndex % context.beatsPerBar) +
        context.beatsPerBar) % context.beatsPerBar;
      context.started = true;
    }
    const sourceBeat = Math.max(0, beatIndex - this.transportStartBeatIndex) + context.initialBeatOffset;
    const bar = Math.floor(sourceBeat / context.beatsPerBar);
    const activation = this.drumPreviewActivationAt(context, bar);
    this.setDrumPreviewCursor(context, activation, bar, sourceBeat % context.beatsPerBar);
    this.applyMainStartOffset = false;
  }

  private resetAudioTimestampState(): void {
    this.productionClockSample = undefined;
    this.audioClockContinuityLost = false;
    this.audioTimelineToken = -1;
    this.audioTimelineLeadFrames = 0;
    this.audioTimelineOutputLatencyMs = 0;
    this.audioTimestampBaseFrame = 0;
    this.audioTimestampBaseReady = false;
    this.audioTimestampClockOffsetMs = undefined;
    this.rendererStartedAtLocalMs = 0;
    this.lastRenderedStreamFrame = 0;
    this.audioClockLocked = false;
    this.lastAudioRawFrame = -1;
    this.lastAudioTimestampAgeMs = Number.POSITIVE_INFINITY;
    this.lastAudioFrameMapExact = false;
    this.lastAudioPlayheadMs = 0;
    this.lastAudioSampleMonoMs = 0;
    this.lastTimestampQueryMonoMs = -1;
    this.queueDepthFrames = 0;
    this.resetPhaseCorrectionState();
    this.calibrationFrameOriginExact = false;
  }

  /**
   * Read the hardware frame clock for mic calibration without the playback
   * path's elapsed-time base heuristic. Audio timestamps use the active
   * monotonic clock, while app scheduling uses startup uptime; sample both
   * clocks together so the timestamp's real age is preserved.
   */
  private readCalibrationClockSample(renderer: audio.AudioRenderer,
    includeOutOfRangeAge: boolean = false, requireExactOrigin: boolean = true): CalibrationClockSample | undefined {
    if (requireExactOrigin && !this.calibrationFrameOriginExact) {
      return undefined;
    }
    try {
      // Nanosecond uptime keeps STARTUP−ACTIVE conversion from dominating the
      // rate window; framePos itself is still quantized to ~20ms.
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
      if (!Number.isFinite(timestampMonoMs) ||
        (!includeOutOfRangeAge && (timestampAgeMs < -50 || timestampAgeMs > 2000))) {
        return undefined;
      }
      return {
        framePos: info.framePos,
        rawTimestampMs: info.timestamp / 1000000,
        timestampMonoMs,
        queryMonoMs
      };
    } catch (_e) {
      return undefined;
    }
  }

  /**
   * Observed 44.1k rate only after the window is long enough to outrun the
   * 20ms framePos quantum. A shorter pair is noise, not a clock verdict.
   */
  private calibrationObservedRateHz(from: CalibrationClockSample, to: CalibrationClockSample): number | undefined {
    const timestampDeltaMs = to.timestampMonoMs - from.timestampMonoMs;
    const frameDelta = to.framePos - from.framePos;
    if (timestampDeltaMs < CALIB_CLOCK_MIN_RATE_WINDOW_MS || frameDelta < CALIB_CLOCK_MIN_FRAME_DELTA) {
      return undefined;
    }
    return frameDelta * 1000 / timestampDeltaMs;
  }

  private calibrationRatePlausible(observedRateHz: number): boolean {
    const rateErrorRatio = Math.abs(observedRateHz - SAMPLE_RATE) / SAMPLE_RATE;
    return rateErrorRatio <= CALIB_CLOCK_MAX_RATE_ERROR_RATIO;
  }

  /** True only when framePos moved backward by more than one hardware quantum. */
  private calibrationFramePosRegressedBeyondQuantum(previousFramePos: number,
    currentFramePos: number): boolean {
    return currentFramePos < previousFramePos - CALIB_CLOCK_FRAME_POS_QUANTUM;
  }

  /** Wait for a fresh rate window in the same stream; a stalled window is never a chirp anchor. */
  private async readStableCalibrationClock(
    renderer: audio.AudioRenderer,
    expectedRunToken: number = this.runToken
  ): Promise<CalibrationClockSample | undefined> {
    const MAX_QUEUE_MS = 2500;
    const startedAtMonoMs = MonotonicClock.nowMs();
    const deadline = startedAtMonoMs + CALIB_CLOCK_RECOVERY_TIMEOUT_MS;
    const rendererEpoch = this.rendererEpoch;
    const streamId = this.rendererStreamId;
    let first: CalibrationClockSample | undefined = undefined;
    let firstSubmittedFrames = 0;
    let previous: CalibrationClockSample | undefined = undefined;
    let maxFramePos = -1;
    let lastReason = 'timestamp-unavailable';
    let loggedReason = '';
    let lastRateHz = 0;
    let lastAgeMs = Number.POSITIVE_INFINITY;
    let lastQueueMs = Number.POSITIVE_INFINITY;
    while (MonotonicClock.nowMs() <= deadline) {
      if (this.renderer !== renderer || this.rendererEpoch !== rendererEpoch ||
        this.rendererStreamId !== streamId || this.runToken !== expectedRunToken ||
        !this.rendererStarted || renderer.state !== audio.AudioState.STATE_RUNNING ||
        !this.calibrationFrameOriginExact || this.calibrationRouteResetPending ||
        this.micCalibrationRendererRebuildPending) {
        console.warn(`[CalibClock] stage=pre-chirp state=rejected reason=stream-invalidated ` +
          `rendererEpoch=${rendererEpoch}->${this.rendererEpoch} streamId=${streamId}->${this.rendererStreamId} ` +
          `cancelled=${this.runToken !== expectedRunToken} started=${this.rendererStarted} ` +
          `routeReset=${this.calibrationRouteResetPending} micRebuild=${this.micCalibrationRendererRebuildPending}`);
        return undefined;
      }
      const current = this.readCalibrationClockSample(renderer, true);
      if (current === undefined) {
        first = undefined;
        lastReason = 'timestamp-unavailable';
      } else {
        lastAgeMs = current.queryMonoMs - current.timestampMonoMs;
        if (!Number.isFinite(current.framePos) || !Number.isFinite(lastAgeMs) ||
          !Number.isFinite(this.audioSubmittedFrames) || lastAgeMs < -50 ||
          this.calibrationFramePosRegressedBeyondQuantum(maxFramePos, current.framePos) ||
          (previous !== undefined && current.timestampMonoMs < previous.timestampMonoMs - 1)) {
          console.warn(`[CalibClock] stage=pre-chirp state=rejected reason=clock-invalid ` +
            `rendererEpoch=${rendererEpoch} streamId=${streamId} ageMs=${lastAgeMs.toFixed(1)} ` +
            `framePos=${current.framePos} previousFrame=${previous?.framePos ?? -1} ` +
            `maxFrame=${maxFramePos} submittedFrames=${this.audioSubmittedFrames}`);
          return undefined;
        }
        const frameRegressed = current.framePos < maxFramePos;
        maxFramePos = Math.max(maxFramePos, current.framePos);
        previous = current;
        if (lastAgeMs > CALIB_CLOCK_MAX_SAMPLE_AGE_MS) {
          first = undefined;
          lastReason = 'timestamp-stale';
        } else {
          const playedAtQuery = current.framePos + Math.max(0, lastAgeMs) * SAMPLE_RATE / 1000;
          const queueFrames = this.audioSubmittedFrames - playedAtQuery;
          lastQueueMs = queueFrames * 1000 / SAMPLE_RATE;
          if (lastQueueMs < -50 || lastQueueMs > MAX_QUEUE_MS) {
            console.warn(`[CalibClock] stage=pre-chirp state=rejected reason=queue-out-of-range ` +
              `rendererEpoch=${rendererEpoch} streamId=${streamId} queueMs=${lastQueueMs.toFixed(1)} ` +
              `ageMs=${lastAgeMs.toFixed(1)} framePos=${current.framePos} ` +
              `submittedFrames=${this.audioSubmittedFrames}`);
            return undefined;
          }
          // A transient old read may be one hardware quantum behind. Discard
          // its rate window, but never rebase frames or loosen the final rate gate.
          if (frameRegressed) {
            first = undefined;
            lastReason = 'frame-quantum-regression';
          } else if (first === undefined) {
            first = current;
            firstSubmittedFrames = this.audioSubmittedFrames;
            lastReason = 'collecting-rate-window';
          } else if (current.timestampMonoMs - first.timestampMonoMs >= CALIB_CLOCK_MIN_RATE_WINDOW_MS) {
            const observedRateHz = this.calibrationObservedRateHz(first, current);
            lastRateHz = observedRateHz ?? 0;
            if (observedRateHz !== undefined && this.calibrationRatePlausible(observedRateHz) &&
              this.audioSubmittedFrames > firstSubmittedFrames) {
              this.queueDepthFrames = Math.max(0, queueFrames);
              console.info(`[CalibClock] stage=pre-chirp state=stable rendererEpoch=${rendererEpoch} ` +
                `streamId=${streamId} framePos=${current.framePos} submittedFrames=${this.audioSubmittedFrames} ` +
                `rateHz=${observedRateHz.toFixed(1)} ageMs=${lastAgeMs.toFixed(1)} ` +
                `queueMs=${lastQueueMs.toFixed(1)} elapsedMs=${(MonotonicClock.nowMs() - startedAtMonoMs).toFixed(1)}`);
              return current;
            }
            lastReason = this.audioSubmittedFrames <= firstSubmittedFrames
              ? 'write-not-advancing' : 'rate-not-stable';
            // Callback backlog or stream startup can spoil the first rate pair.
            // Recovery requires an entirely new 400ms window within one deadline.
            first = current;
            firstSubmittedFrames = this.audioSubmittedFrames;
          }
        }
      }
      if (lastReason !== loggedReason) {
        console.info(`[CalibClock] stage=pre-chirp state=waiting reason=${lastReason} ` +
          `rendererEpoch=${rendererEpoch} streamId=${streamId} framePos=${previous?.framePos ?? -1} ` +
          `submittedFrames=${this.audioSubmittedFrames} ageMs=${lastAgeMs.toFixed(1)} ` +
          `rateHz=${lastRateHz.toFixed(1)} queueMs=${lastQueueMs.toFixed(1)}`);
        loggedReason = lastReason;
      }
      const remainingMs = deadline - MonotonicClock.nowMs();
      if (remainingMs <= 0) {
        break;
      }
      await MetronomeEngine.delay(Math.min(20, remainingMs));
    }
    console.warn(`[CalibClock] stage=pre-chirp state=timeout reason=${lastReason} ` +
      `rendererEpoch=${rendererEpoch} streamId=${streamId} framePos=${previous?.framePos ?? -1} ` +
      `submittedFrames=${this.audioSubmittedFrames} ageMs=${lastAgeMs.toFixed(1)} ` +
      `rateHz=${lastRateHz.toFixed(1)} queueMs=${lastQueueMs.toFixed(1)} ` +
      `elapsedMs=${(MonotonicClock.nowMs() - startedAtMonoMs).toFixed(1)}`);
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
    const rendererEpoch = this.rendererEpoch;
    const deadline = MonotonicClock.nowMs() + 4000;
    let previous = anchor;
    let playheadMax = anchor.framePos;
    let waitingForRateAfterCross = false;
    let firstCrossSample: CalibrationClockSample | undefined = undefined;
    let lastFramePos = anchor.framePos;
    while (MonotonicClock.nowMs() < deadline) {
      if (this.renderer !== renderer || this.rendererEpoch !== rendererEpoch) {
        console.warn(`[CalibClock] crossing failed: renderer replaced epoch=${rendererEpoch}->` +
          `${this.rendererEpoch}`);
        return undefined;
      }
      if (!this.rendererStarted || !this.calibrationFrameOriginExact) {
        console.warn(`[CalibClock] crossing failed: renderer not running or clock epoch not exact ` +
          `started=${this.rendererStarted} exact=${this.calibrationFrameOriginExact}`);
        return undefined;
      }
      if (this.calibrationRouteResetPending || this.micCalibrationRendererRebuildPending) {
        console.warn(`[CalibClock] crossing failed: route reset pending ` +
          `routeReset=${this.calibrationRouteResetPending} micRebuild=${this.micCalibrationRendererRebuildPending}`);
        return undefined;
      }
      if (this.calibrationSignal !== pendingSignal && !pendingSignal.fullySubmitted) {
        console.warn(`[CalibClock] crossing failed: calibration signal replaced before submit complete`);
        return undefined;
      }
      const current = this.readCalibrationClockSample(renderer);
      if (current !== undefined) {
        lastFramePos = current.framePos;
        if (current.timestampMonoMs < previous.timestampMonoMs - 1) {
          console.warn(`[CalibClock] crossing failed: timestamp regressed ` +
            `prev=${previous.timestampMonoMs.toFixed(1)} cur=${current.timestampMonoMs.toFixed(1)} ` +
            `targetFrame=${targetFrame} framePos=${current.framePos}`);
          return undefined;
        }
        if (this.calibrationFramePosRegressedBeyondQuantum(previous.framePos, current.framePos)) {
          console.warn(`[CalibClock] crossing failed: framePos regressed beyond quantum ` +
            `prev=${previous.framePos} cur=${current.framePos} targetFrame=${targetFrame}`);
          return undefined;
        }
        playheadMax = Math.max(playheadMax, current.framePos);
        const observedRateHz = this.calibrationObservedRateHz(anchor, current);
        if (current.framePos >= targetFrame) {
          if (firstCrossSample === undefined) {
            firstCrossSample = current;
          }
          if (observedRateHz === undefined) {
            if (!waitingForRateAfterCross) {
              waitingForRateAfterCross = true;
              console.info(`[CalibClock] crossed targetFrame=${targetFrame} framePos=${current.framePos} ` +
                `waiting for ${CALIB_CLOCK_MIN_RATE_WINDOW_MS}ms rate window`);
            }
          } else if (!this.calibrationRatePlausible(observedRateHz)) {
            console.warn(`[CalibClock] crossing failed: rate out of range after target ` +
              `rateHz=${observedRateHz.toFixed(1)} targetFrame=${targetFrame} framePos=${current.framePos}`);
            return undefined;
          } else {
            // Anchor presentation to the first post-target timestamp read. Later
            // reads can jump several 20ms quanta ahead and would back-interpolate
            // presentation too early, collapsing round-trip into invalid input latency.
            const crossSample = firstCrossSample ?? current;
            const presentationMonoMs = crossSample.timestampMonoMs -
              (crossSample.framePos - targetFrame) * 1000 / SAMPLE_RATE;
            console.info(`[CalibClock] crossed targetFrame=${targetFrame} anchorFramePos=${crossSample.framePos} ` +
              `readFramePos=${current.framePos} rateHz=${observedRateHz.toFixed(1)} ` +
              `overshootFrames=${crossSample.framePos - targetFrame} ` +
              `presentationMonoMs=${presentationMonoMs.toFixed(1)}`);
            return presentationMonoMs;
          }
        } else if (observedRateHz !== undefined && !this.calibrationRatePlausible(observedRateHz)) {
          // Before the playhead reaches target, a long-window rate sample can still
          // wobble from 20ms framePos quanta; keep waiting instead of aborting.
          console.info(`[CalibClock] crossing pre-target rate ignored rateHz=${observedRateHz.toFixed(1)} ` +
            `targetFrame=${targetFrame} framePos=${current.framePos} playheadMax=${playheadMax}`);
        }
        previous = current;
      }
      await MetronomeEngine.delay(8);
    }
    console.warn(`[CalibClock] crossing failed: timeout targetFrame=${targetFrame} ` +
      `playheadMax=${playheadMax} lastFramePos=${lastFramePos} ` +
      `waitingForRate=${waitingForRateAfterCross} remainingMs=${Math.max(0, deadline - MonotonicClock.nowMs())}`);
    return undefined;
  }

  private primeAudioTimestamp(renderer: audio.AudioRenderer): void {
    this.readRenderedStreamFrames(renderer, MonotonicClock.nowMs());
  }

  private resetPhaseCorrectionState(): void {
    this.phaseCorrectionFrames = 0;
    this.phaseCorrectionHead = 0;
    this.phaseCorrectionCount = 0;
    this.phaseCorrectionCompletedFrames = 0;
    this.phaseCorrectionSubmittedFrames = 0;
    this.phaseCorrectionAudibleFrames = 0;
    this.phaseFeedbackStartFrame = -1;
    this.phaseFeedbackSampleFresh = false;
    this.phaseCorrectionCheckAtMs = -1;
    this.audioClockLocked = false;
    this.lastTimestampQueryMonoMs = -1;
  }

  private recordPhaseCorrection(streamFrame: number, deltaFrames: number): void {
    const index = (this.phaseCorrectionHead + this.phaseCorrectionCount) % AUDIO_PHASE_CORRECTION_CAPACITY;
    this.phaseCorrectionStarts[index] = streamFrame;
    this.phaseCorrectionDeltas[index] = deltaFrames;
    this.phaseCorrectionCount++;
    this.phaseCorrectionSubmittedFrames += deltaFrames;
  }

  private audiblePhaseCorrectionAt(streamFrame: number): number {
    while (this.phaseCorrectionCount > 0) {
      const start = this.phaseCorrectionStarts[this.phaseCorrectionHead];
      const delta = this.phaseCorrectionDeltas[this.phaseCorrectionHead];
      if (streamFrame < start + Math.max(0, delta)) {
        // During inserted silence source time is held; a dropped source span
        // advances it only when its first surviving output sample is audible.
        return this.phaseCorrectionCompletedFrames +
          (delta > 0 ? Math.max(0, Math.min(delta, streamFrame - start)) : 0);
      }
      this.phaseCorrectionCompletedFrames += delta;
      this.phaseCorrectionHead = (this.phaseCorrectionHead + 1) % AUDIO_PHASE_CORRECTION_CAPACITY;
      this.phaseCorrectionCount--;
    }
    return this.phaseCorrectionCompletedFrames;
  }

  private findQuietPhaseCorrectionCursor(bar: RenderedBar, start: number,
    availableFrames: number, dropFrames: number): number {
    const guard = AUDIO_PHASE_QUIET_GUARD_FRAMES;
    const end = Math.min(bar.frameCount - dropFrames - guard, start + availableFrames);
    for (let cursor = Math.max(guard, start); cursor < end; cursor++) {
      let quiet = true;
      // A zero crossing is not silence. Require quiet PCM on both sides of
      // the splice as well as every dropped sample, including cymbal tails.
      for (let sample = cursor - guard; sample <= cursor + dropFrames + guard; sample++) {
        if (Math.abs(bar.samples[sample]) > AUDIO_PHASE_QUIET_SAMPLE_LIMIT) {
          quiet = false;
          break;
        }
      }
      if (quiet) {
        return cursor;
      }
    }
    // A continuous tone has no safe gap. Leave the request pending instead of
    // cutting its tail; rate correction for sustained PCM needs a resampler.
    return -1;
  }

  private readAudioPlayheadMs(nowMs: number): number | undefined {
    this.phaseFeedbackSampleFresh = false;
    const renderer = this.renderer;
    if (renderer === undefined || !this.rendererStarted ||
      this.audioTimelineToken !== this.runToken || this.phaseFeedbackStartFrame < 0) {
      return undefined;
    }
    this.lastTimestampQueryMonoMs = nowMs;
    const previousRawFrame = this.lastAudioRawFrame;
    const renderedFrames = this.readRenderedStreamFrames(renderer, nowMs);
    if (renderedFrames === undefined) {
      return this.audioClockLocked ?
        this.lastAudioPlayheadMs + Math.max(0, nowMs - this.lastAudioSampleMonoMs) : undefined;
    }
    if (!Number.isFinite(this.lastAudioTimestampAgeMs) || this.lastAudioTimestampAgeMs < -1 ||
      this.lastAudioTimestampAgeMs > AUDIO_PHASE_CLOCK_MAX_AGE_MS) {
      return undefined;
    }
    if (previousRawFrame >= 0 && this.lastAudioRawFrame < previousRawFrame) {
      // A changed frame coordinate cannot consume the correction ledger. Wait
      // for a newly anchored transport/route before using feedback again.
      this.audioClockContinuityLost = true;
      this.resetPhaseCorrectionState();
      return undefined;
    }
    const audibleStreamFrame = renderedFrames - this.audioTimelineOutputLatencyMs * SAMPLE_RATE / 1000;
    if (audibleStreamFrame < this.phaseFeedbackStartFrame) {
      return undefined;
    }
    this.phaseCorrectionAudibleFrames = this.audiblePhaseCorrectionAt(audibleStreamFrame);
    const playheadMs = (renderedFrames - this.audioTimelineLeadFrames -
      this.phaseCorrectionAudibleFrames) * 1000 / SAMPLE_RATE;
    if (!Number.isFinite(playheadMs)) {
      return undefined;
    }
    this.audioClockLocked = true;
    this.phaseFeedbackSampleFresh = true;
    this.lastAudioPlayheadMs = playheadMs;
    this.lastAudioSampleMonoMs = nowMs;
    return playheadMs;
  }

  /** Map the renderer's persistent frame counter into this stream's submitted-frame coordinate. */
  private readRenderedStreamFrames(renderer: audio.AudioRenderer, nowMs: number): number | undefined {
    this.productionClockSample = undefined;
    if (EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP && this.calibrationFrameOriginExact &&
      !this.calibrationRouteResetPending && !this.micCalibrationRendererRebuildPending) {
      const sample = this.readCalibrationClockSample(renderer);
      if (sample === undefined) {
        return undefined;
      }
      const timestampAgeMs = nowMs - sample.timestampMonoMs;
      this.lastAudioTimestampAgeMs = timestampAgeMs;
      if (timestampAgeMs < -50 || timestampAgeMs > 2000) {
        return undefined;
      }
      if (this.lastAudioRawFrame >= 0 &&
        this.calibrationFramePosRegressedBeyondQuantum(this.lastAudioRawFrame, sample.framePos)) {
        // A large regression means the renderer changed epochs behind our back.
        // Never rebase an allegedly exact mic-calibration stream from elapsed wall time.
        console.warn(`[ClockDiag] exact frame epoch lost previous=${this.lastAudioRawFrame} ` +
          `current=${sample.framePos}`);
        this.calibrationFrameOriginExact = false;
        this.audioClockContinuityLost = true;
        this.audioTimestampBaseReady = false;
        this.audioTimestampClockOffsetMs = undefined;
        this.lastAudioRawFrame = -1;
        this.lastAudioFrameMapExact = false;
        return undefined;
      }
      const firstExactRead = !this.lastAudioFrameMapExact;
      const timestampedFrame = sample.framePos +
        Math.max(0, Math.min(250, timestampAgeMs)) * SAMPLE_RATE / 1000;
      // A mic boundary rebuild proves framePos and audioSubmittedFrames share
      // zero. Preserve that coordinate during playback; elapsed-time rebasing
      // would add a headset-dependent 200–300ms offset a second time.
      const renderedFrames = Math.min(this.audioSubmittedFrames, Math.max(
        this.lastRenderedStreamFrame, Math.max(0, timestampedFrame)));
      this.lastAudioRawFrame = sample.framePos;
      this.lastRenderedStreamFrame = renderedFrames;
      this.queueDepthFrames = Math.max(0, this.audioSubmittedFrames - renderedFrames);
      this.lastAudioFrameMapExact = true;
      if (firstExactRead) {
        console.info(`[ClockDiag] frameMap=exact rawFrame=${sample.framePos} ` +
          `ageMs=${timestampAgeMs.toFixed(1)} rendered=${renderedFrames.toFixed(1)} ` +
          `submitted=${this.audioSubmittedFrames} queueDepth=${this.queueDepthFrames.toFixed(1)}`);
      }
      return renderedFrames;
    }
    this.lastAudioFrameMapExact = false;
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
      const previousRawFrame = this.lastAudioRawFrame;
      let baseUpdateReason = 'retained';
      if (!this.audioTimestampBaseReady) {
        // framePos can survive stop/flush on some devices. Anchor it to the
        // amount that could actually have played since this physical start.
        const elapsedFrames = Math.max(0,
          (nowMs - this.rendererStartedAtLocalMs) * SAMPLE_RATE / 1000);
        const playedEstimate = Math.min(this.audioSubmittedFrames, elapsedFrames);
        this.audioTimestampBaseFrame = info.framePos - playedEstimate;
        this.audioTimestampBaseReady = true;
        baseUpdateReason = 'elapsed-time-initialization';
        const clockOffset = this.audioTimestampClockOffsetMs === undefined ? 'NA' :
          this.audioTimestampClockOffsetMs.toFixed(1);
        console.info(`[ClockDiag] rawTs=${rawTimestampMs.toFixed(1)}ms now=${nowMs.toFixed(1)}ms ` +
          `clockOffset=${clockOffset}ms framePos=${info.framePos} ` +
          `elapsedFrames=${elapsedFrames.toFixed(0)} playedEstimate=${playedEstimate.toFixed(0)} ` +
          `baseFrame=${this.audioTimestampBaseFrame.toFixed(0)}`);
      } else if (this.lastAudioRawFrame >= 0 && info.framePos < this.lastAudioRawFrame) {
        // Other observers can see the regression before phase feedback does.
        // Retain that evidence until a new transition proves the content origin.
        this.audioClockContinuityLost = this.audioStreaming || this.audioClockContinuityLost;
        const previousBaseFrame = this.audioTimestampBaseFrame;
        if (this.calibrationFramePosRegressedBeyondQuantum(this.lastAudioRawFrame, info.framePos)) {
          // The legacy recovery remains unchanged, but its diagnostic cannot
          // assume raw zero survived an unexplained hardware-counter reset.
          this.diagnosticRawOriginLost = true;
        }
        this.audioTimestampBaseFrame = info.framePos - this.lastRenderedStreamFrame;
        baseUpdateReason = 'raw-frame-regression';
        console.info(`[ProductionClockDiag] stage=frame-map state=base-update reason=raw-frame-regression ` +
          `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
          `physicalStartCount=${this.rendererPhysicalStartCount} previousRawFrame=${previousRawFrame} ` +
          `rawFrame=${info.framePos} previousBaseFrame=${previousBaseFrame.toFixed(1)} ` +
          `baseFrame=${this.audioTimestampBaseFrame.toFixed(1)} queryMonoMs=${nowMs.toFixed(1)}`);
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
      this.productionClockSample = {
        rendererEpoch: this.rendererEpoch,
        streamId: this.rendererStreamId,
        physicalStartCount: this.rendererPhysicalStartCount,
        queryMonoMs: nowMs,
        rawFrame: info.framePos,
        rawTimestampMs,
        renderedFrame: renderedFrames,
        submittedFrames: this.audioSubmittedFrames,
        baseFrame: this.audioTimestampBaseFrame,
        clockOffsetMs: this.audioTimestampClockOffsetMs,
        legacyAgeMs: timestampAgeMs,
        baseUpdateReason,
        previousRawFrame
      };
      return renderedFrames;
    } catch (_e) {
      // API 19+ exposes hardware timestamps; older devices retain the monotonic fallback.
      this.lastAudioTimestampAgeMs = Number.POSITIVE_INFINITY;
      return undefined;
    }
  }

  /**
   * Compare production coordinates after its target is committed. Reuse the
   * playback sample, so diagnostics add no audio API queries or scheduling changes.
   * An old hardware counter after stop/flush must never be presented as an
   * acoustic offset; only a new renderer's first physical start proves its zero.
   */
  private logProductionClockDiagnostic(stage: string, localAudibleStart: number): void {
    const sample = this.productionClockSample;
    const transition = this.pendingAudioTransition;
    if (sample === undefined || sample.rendererEpoch !== this.rendererEpoch ||
      sample.streamId !== this.rendererStreamId ||
      sample.physicalStartCount !== this.rendererPhysicalStartCount || !this.rendererStarted ||
      this.renderer === undefined || this.renderer.state !== audio.AudioState.STATE_RUNNING) {
      console.info(`[ProductionClockDiag] stage=${stage} state=sample-unavailable ` +
        `rendererEpoch=${this.rendererEpoch} streamId=${this.rendererStreamId} ` +
        `physicalStartCount=${this.rendererPhysicalStartCount}`);
      return;
    }
    try {
      const startupBeforeMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const activeMs = systemDateTime.getUptime(systemDateTime.TimeType.ACTIVE, true) / 1000000;
      const startupAfterMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, true) / 1000000;
      const activeToStartupMs = (startupBeforeMs + startupAfterMs) / 2 - activeMs;
      const rawTimestampMonoMs = sample.rawTimestampMs + activeToStartupMs;
      const rawAgeMs = sample.queryMonoMs - rawTimestampMonoMs;
      const rawFrameAtQuery = sample.rawFrame + rawAgeMs * SAMPLE_RATE / 1000;
      const coordinateDeltaMs = (sample.renderedFrame - rawFrameAtQuery) * 1000 / SAMPLE_RATE;
      const sampleFresh = Number.isFinite(rawAgeMs) && rawAgeMs >= -50 && rawAgeMs <= 250 &&
        Number.isFinite(sample.legacyAgeMs) && sample.legacyAgeMs >= -50 && sample.legacyAgeMs <= 250 &&
        startupAfterMs - sample.queryMonoMs >= 0 && startupAfterMs - sample.queryMonoMs <= 250 &&
        Number.isFinite(sample.rawFrame) && sample.rawFrame >= 0 && Number.isFinite(coordinateDeltaMs);
      const originProven = sample.physicalStartCount === 1 && !this.diagnosticRawOriginLost &&
        !this.calibrationRouteResetPending && !this.micCalibrationRendererRebuildPending;
      const usable = originProven && sampleFresh;
      const targetPending = transition !== undefined && transition.token === this.runToken;
      const rawTargetMonoMs = usable && targetPending && transition !== undefined &&
        Number.isFinite(transition.targetFrame) && Number.isFinite(localAudibleStart)
        ? rawTimestampMonoMs + (transition.targetFrame - sample.rawFrame) * 1000 / SAMPLE_RATE : undefined;
      const m = usable ? coordinateDeltaMs.toFixed(1) : 'unproven';
      const rawTarget = rawTargetMonoMs === undefined ? 'unproven' : rawTargetMonoMs.toFixed(1);
      const targetError = rawTargetMonoMs === undefined ? 'unproven'
        : (rawTargetMonoMs - localAudibleStart).toFixed(1);
      console.info(`[ProductionClockDiag] stage=${stage} state=sample ` +
        `rendererEpoch=${sample.rendererEpoch} streamId=${sample.streamId} ` +
        `physicalStartCount=${sample.physicalStartCount} originProven=${originProven} ` +
        `rawOriginLost=${this.diagnosticRawOriginLost} ` +
        `exactCalibrationOrigin=${this.calibrationFrameOriginExact} sampleFresh=${sampleFresh} ` +
        `baseUpdate=${sample.baseUpdateReason} baseFrame=${sample.baseFrame.toFixed(1)} ` +
        `clockOffsetMs=${sample.clockOffsetMs.toFixed(1)} rawFrame=${sample.rawFrame} ` +
        `previousRawFrame=${sample.previousRawFrame} rendered=${sample.renderedFrame.toFixed(1)} ` +
        `submittedFrames=${sample.submittedFrames} rawAgeMs=${rawAgeMs.toFixed(1)} ` +
        `legacyAgeMs=${sample.legacyAgeMs.toFixed(1)} coordinateDeltaMs=${coordinateDeltaMs.toFixed(1)} ` +
        `m=${m}ms targetPending=${targetPending} targetFrame=${transition?.targetFrame ?? -1} ` +
        `compensation=${transition?.outputLatencyMs ?? -1}ms audible=${localAudibleStart.toFixed(1)} ` +
        `targetEstimate=true rawTargetMonoMs=${rawTarget} rawTargetMinusAudibleMs=${targetError}`);
    } catch (_e) {
      console.info(`[ProductionClockDiag] stage=${stage} state=clock-domain-unavailable ` +
        `rendererEpoch=${sample.rendererEpoch} streamId=${sample.streamId}`);
    }
  }

  private canCorrectAudioPhase(): boolean {
    return this.phaseCorrectionEnabled && this.running && this.audioStreaming && !this.audioClockContinuityLost &&
      this.audioTimelineToken === this.runToken &&
      this.audioSequenceTransportRevision === this.transportRevision &&
      !this.activeSequenceFinished && !this.recoveringAudio && !this.outputRouteRephasePreparing &&
      this.pendingAudioTransition === undefined && this.calibrationSignal === undefined &&
      this.transportOutputCompensationOverrideMs === undefined &&
      this.transportPreviewStartPositionBeats === undefined && this.drumPreviewPlan === undefined;
  }

  /** Residual after all queued corrections; positive means the audible source is early. */
  private measurePhaseErrorFrames(): number {
    return this.readPhaseErrorFrames() ?? 0;
  }

  /** Unavailable feedback cannot prove continuity after a background suspension. */
  private readPhaseErrorFrames(): number | undefined {
    if (!this.canCorrectAudioPhase()) {
      return undefined;
    }
    const nowMs = MonotonicClock.nowMs();
    const playhead = this.readAudioPlayheadMs(nowMs);
    if (playhead === undefined || !this.phaseFeedbackSampleFresh) {
      return undefined;
    }
    const expected = this.transportElapsedAt(nowMs);
    // Submitted corrections can be hundreds of milliseconds ahead of the ear.
    // Count those and pending work once, while keeping readAudioPlayheadMs an
    // observation of the content that has actually reached acoustic output.
    const inFlightFrames = this.phaseCorrectionSubmittedFrames - this.phaseCorrectionAudibleFrames;
    return Math.round((playhead - expected) * SAMPLE_RATE / 1000) -
      inFlightFrames - this.phaseCorrectionFrames;
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
    // This runs once per beat. Phase feedback uses only fresh hardware
    // observations; unavailable timestamps retain stall detection, not steering.
    const firstCheck = this.phaseCorrectionCheckAtMs < 0;
    const elapsedMs = firstCheck ? 0 : Math.max(0,
      Math.min(AUDIO_PHASE_CORRECTION_MAX_INTERVAL_MS, nowMs - this.phaseCorrectionCheckAtMs));
    this.phaseCorrectionCheckAtMs = nowMs;
    const budgetFrames = firstCheck ? AUDIO_PHASE_LOCK_MAX_STEP_FRAMES :
      Math.floor(elapsedMs * SAMPLE_RATE * AUDIO_PHASE_CORRECTION_RATE_PPM / 1e9);
    const phaseError = this.measurePhaseErrorFrames();
    if (budgetFrames > 0 && Math.abs(phaseError) >= AUDIO_PHASE_LOCK_THRESHOLD_FRAMES) {
      const requested = Math.max(-budgetFrames, Math.min(budgetFrames, phaseError));
      // No quiet window must not accumulate seconds of future insert/drop work.
      // Keep at most one interval's budget pending; residual remains observable.
      const pending = Math.max(-budgetFrames, Math.min(budgetFrames, this.phaseCorrectionFrames + requested));
      const step = pending - this.phaseCorrectionFrames;
      this.phaseCorrectionFrames = pending;
      console.info(`[PhaseLockDiag] residualFrames=${phaseError} stepFrames=${step} ` +
        `pendingFrames=${this.phaseCorrectionFrames} ` +
        `queuedFrames=${this.phaseCorrectionSubmittedFrames - this.phaseCorrectionAudibleFrames} ` +
        `clockAdjustmentMs=${this.transportClockAdjustmentAt(nowMs).toFixed(3)}`);
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

  /** Background policy mute need not send audioInterrupt; inspect continuity on return. */
  async restoreAfterForeground(continuityLost: boolean = false): Promise<void> {
    // Native policy can mute playback while PCM callbacks keep flowing. Carry
    // task-loss evidence across a concurrent foreground check or route wait.
    this.backgroundPlaybackInterrupted = this.backgroundPlaybackInterrupted || continuityLost;
    const request = ++this.foregroundContinuityRequest;
    const token = this.runToken;
    const revision = this.transportRevision;
    const deadline = MonotonicClock.nowMs() + AUDIO_FOREGROUND_RECHECK_TIMEOUT_MS;
    let previousPhaseMs = 0;
    let consecutiveErrors = 0;
    for (;;) {
      // Every wait can hand ownership to a new transport, an incoming call or
      // calibration. A stale foreground check must never restart that owner.
      const excluded = request !== this.foregroundContinuityRequest || token !== this.runToken ||
        revision !== this.transportRevision || !this.running || this.audioFocusInterrupted ||
        this.activeSequenceFinished || this.transportOutputCompensationOverrideMs !== undefined ||
        this.transportPreviewStartPositionBeats !== undefined || this.drumPreviewPlan !== undefined ||
        this.calibrationSignal !== undefined;
      if (excluded) {
        console.info(`[ForegroundPlaybackDiag] stage=skipped token=${token} currentToken=${this.runToken} ` +
          `running=${this.running} focusInterrupted=${this.audioFocusInterrupted}`);
        return;
      }
      const now = MonotonicClock.nowMs();
      const busy = this.recoveringAudio || this.pendingAudioTransition !== undefined ||
        this.outputRouteRephasePreparing;
      const renderer = this.renderer;
      if (renderer === undefined) {
        console.info(`[ForegroundPlaybackDiag] stage=skipped reason=no-renderer token=${token}`);
        return;
      }
      if (!busy) {
        const stalled = now - this.lastWriteProgressMs >= AUDIO_CALLBACK_STALL_MS;
        const phaseFrames = this.readPhaseErrorFrames();
        const phaseMs = phaseFrames === undefined ? undefined : phaseFrames * 1000 / SAMPLE_RATE;
        console.info(`[ForegroundPlaybackDiag] stage=check writeGap=${this.audioWriteDiscontinuity} ` +
          `backgroundInterrupted=${this.backgroundPlaybackInterrupted} ` +
          `clockLost=${this.audioClockContinuityLost} stalled=${stalled} state=${renderer.state} ` +
          `phaseMs=${phaseMs === undefined ? 'unavailable' : phaseMs.toFixed(1)}`);
        if (this.backgroundPlaybackInterrupted || this.audioWriteDiscontinuity || this.audioClockContinuityLost || stalled ||
          renderer.state !== audio.AudioState.STATE_RUNNING) {
          await this.recoverAudio('foreground continuity lost');
          return;
        }
        if (phaseMs !== undefined) {
          if (Math.abs(phaseMs) < AUDIO_FOREGROUND_REPHASE_MS) { return; }
          consecutiveErrors = phaseMs * previousPhaseMs > 0 ? consecutiveErrors + 1 : 1;
          previousPhaseMs = phaseMs;
          if (consecutiveErrors >= 2) {
            await this.recoverAudio('foreground phase mismatch confirmed');
            return;
          }
        } else {
          consecutiveErrors = 0;
          // The explicit A/B switch disables phase feedback; unavailable API
          // samples in that mode must not silently enable a different correction.
          if (!this.phaseCorrectionEnabled || !this.transportUsesSharedClock) { return; }
          if (now >= deadline && this.audioStreaming && this.audioTimelineToken === token &&
            this.audioSequenceTransportRevision === revision) {
            await this.recoverAudio('foreground phase clock remained unavailable');
            return;
          }
        }
      } else {
        consecutiveErrors = 0;
      }
      if (now >= deadline) {
        console.info(`[ForegroundPlaybackDiag] stage=deferred token=${token} ` +
          `recovering=${this.recoveringAudio} transition=${this.pendingAudioTransition !== undefined} ` +
          `routePreparing=${this.outputRouteRephasePreparing}`);
        return;
      }
      await MetronomeEngine.delay(Math.min(AUDIO_FOREGROUND_RECHECK_MS, deadline - now));
    }
  }

  private async recoverAudio(reason: string): Promise<void> {
    if (!this.running || this.audioFocusInterrupted || this.recoveringAudio || this.activeSequenceFinished) { return; }
    // Switching endpoints can emit a focus-resume event while route preparation
    // already owns the renderer. A second recovery would overwrite its target.
    if (this.outputRouteRephasePreparing) { return; }
    if (this.pendingAudioTransition?.routeRephase) {
      try {
        await this.rescheduleForOutputRouteChange();
      } catch (err) {
        console.warn(`MetronomeEngine route recovery failed: ${(err as Error).message}`);
      }
      return;
    }
    this.recoveringAudio = true;
    const token = this.runToken;
    try {
      // Recovery is the exceptional path where rebuilding the physical stream
      // is intentional; normal pause/resume/configuration changes keep it alive.
      await this.haltRenderer();
      if (token !== this.runToken || !this.running || this.audioFocusInterrupted) { return; }
      const now = MonotonicClock.nowMs();
      const interval = 60000 / this.transportBpm;
      const compensation = this.transportOutputCompensationOverrideMs ?? this.outputLatencyMs;
      // Select after stop completes, with enough hardware lead for a cold start.
      // Clamping an already-late target would resume the right beat at the wrong time.
      const earliestAudible = now + AUDIO_PREROLL_MS + Math.max(0, compensation);
      const adjustment = this.transportClockAdjustmentAt(now);
      const elapsedBeats = Math.max(0,
        Math.ceil((earliestAudible - this.transportStartLocalMs + adjustment) / interval));
      const beatIndex = this.transportStartBeatIndex + elapsedBeats;
      const localStart = this.localTimeForTransportGrid(this.transportStartLocalMs + elapsedBeats * interval, now);
      const countInBeats = Math.max(0,
        this.transportStartBeatIndex + this.transportCountInBeats - beatIndex);
      console.warn(`MetronomeEngine audio recovery: ${reason}, beat=${beatIndex}, token=${token} ` +
        `headroomMs=${(localStart - now).toFixed(1)}`);
      await this.startAudioStream(localStart, beatIndex, countInBeats, token,
        this.transportOutputCompensationOverrideMs);
    } catch (err) {
      console.warn(`MetronomeEngine audio recovery failed: ${(err as Error).message}`);
    } finally {
      this.recoveringAudio = false;
    }
  }
}
