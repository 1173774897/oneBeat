export interface NativeCaptureOptions {
  videoPath: string;
  innerPath: string;
  micPath: string;
  width: number;
  height: number;
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
  /** Manual post-cleaning shift; positive values delay MIC against the video. */
  micShiftUs: number;
  gain: number;
  /** Deterministic float32 residual cache reused by later gain/shift edits. */
  processedMicPath: string;
  /** 0–4: ceiling for estimated speaker-to-mic gain; zero bypasses echo fitting. */
  speakerBleedCancel: number;
}
export const start: (options: NativeCaptureOptions) => Promise<void>;
export const stop: () => Promise<NativeCaptureResult>;
export const cancel: () => void;
export const getStatus: () => NativeCaptureStatus;
export const mix: (options: NativeMixOptions) => Promise<void>;
