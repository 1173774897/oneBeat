export interface NativeCaptureOptions {
  videoPath: string;
  innerPath: string;
  micPath: string;
  width: number;
  height: number;
  /** ArkTS must verify API20 LIVE AEC support before opting in. No native source fallback. */
  systemAecMic?: boolean;
}
export interface NativeCaptureResult {
  durationMs: number;
  micOffsetUs: number;
  innerOffsetUs: number;
  syncValid: boolean;
  timestampMappingVersion?: number;
  videoTimestampDivisor?: number;
  videoFirstPtsUs?: number;
  videoLastPtsUs?: number;
  micFirstPtsUs?: number;
  innerFirstPtsUs?: number;
  micCaptureMode?: 'system-aec' | 'screen-mic';
  /** Records the verified LIVE capture selection, not measured acoustic cancellation quality. */
  micAecApplied?: boolean;
  micInputChannels?: number;
  micHardwareTimestampKnown?: boolean;
  /** Timestamp-vs-written-frame observations; diagnostics only, PCM is never edited from them. */
  innerTimeline?: NativePcmTimelineStats;
  micTimeline?: NativePcmTimelineStats;
}
export interface NativePcmTimelineStats {
  framesWritten: number;
  lastDriftFrames: number;
  minDriftFrames: number;
  maxDriftFrames: number;
  /** Largest increase between callbacks: a delivery gap that contiguous writing collapsed. */
  maxDriftStepFrames: number;
  /** Written-frame position of that largest step; near 0 means startup batching, later means mid-take. */
  maxDriftStepAtFrame: number;
  /** Steps above 10 ms (480 frames), i.e. candidate missing-PCM gaps. */
  gapCount: number;
  firstGapAtFrame: number;
}
export interface NativeCaptureStatus {
  stateCode: number;
  amplitude: number;
  error: string;
}
export interface NativeMixOptions {
  sourcePath: string;
  innerPath: string;
  micPath: string;
  outputPath: string;
  durationMs: number;
  micOffsetUs: number;
  innerOffsetUs: number;
  /** Manual post-cleaning shift relative to the automatic baseline. */
  micShiftUs: number;
  /** Previously measured automatic baseline, reused with the versioned MIC cache. */
  autoMicShiftUs: number;
  autoMicShiftKnown: number;
  autoMicShiftReliable: number;
  autoMicShiftConfidence: number;
  /** MIC-only gain, 0–4 (0–400%). */
  gain: number;
  /** Deterministic float32 residual cache reused by later gain/shift edits. */
  processedMicPath: string;
  /** 0–4: ceiling for estimated speaker-to-mic gain; zero bypasses echo fitting. */
  speakerBleedCancel: number;
  /** Quiet LIVE AEC input only: fixed MIC level compensation, never a playback gain or time edit. */
  normalizeSystemMic?: boolean;
  /** Speaker + system AEC: measure this take's lag of MIC content locked to the accompaniment and advance the MIC. */
  estimateResidualLag?: boolean;
  /** Rebase the manual edit so an upgraded, user-tuned take keeps its audible alignment. */
  preserveEffectiveMicShift?: boolean;
  previousAutoMicShiftUs?: number;
}
export interface NativeMixResult {
  autoMicShiftUs: number;
  autoMicShiftConfidence: number;
  autoMicShiftReliable: boolean;
  /** Manual edit actually applied; differs from the request only when preserveEffectiveMicShift rebased it. */
  micShiftUs: number;
  /** Level and encoder observations for device logs; never persisted or fed back into a mix. */
  diagnostics?: NativeMixDiagnostics;
}
export interface NativeMixDiagnostics {
  /** 1 when this export rebuilt the processed MIC cache (level gain/knee values are then measured). */
  cacheBuilt: number;
  micLevelGainDb: number;
  micKneeSamples: number;
  innerPeakDbfs: number;
  innerRmsDbfs: number;
  /** After the user's MIC gain. */
  micPeakDbfs: number;
  micRmsDbfs: number;
  /** app + MIC before the limiter; above 0 means the old hard clamp would have clipped. */
  busPeakDbfs: number;
  overFrames: number;
  limitedFrames: number;
  minLimiterGainDb: number;
  aacInputFrames: number;
  aacOutputPackets: number;
  aacFirstOutputPtsUs: number;
  aacLastOutputPtsUs: number;
  /** Measured residual lag (-1 when not estimated) and its response share. */
  residualLagUs: number;
  residualLagShare: number;
  /** Fraction of MIC envelope variance explained; near zero means no measurable residual. */
  residualLagExplained: number;
}
export const start: (options: NativeCaptureOptions) => Promise<void>;
export const stop: () => Promise<NativeCaptureResult>;
export const cancel: () => void;
export const getStatus: () => NativeCaptureStatus;
export const mix: (options: NativeMixOptions) => Promise<NativeMixResult>;
export const chmod: (path: string, mode: number) => boolean;
