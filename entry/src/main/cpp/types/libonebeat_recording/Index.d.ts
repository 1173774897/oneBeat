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
  gain: number;
  /** 0–1: subtract scaled app playback from mic before mix (built-in speaker echo). */
  speakerBleedCancel: number;
}
export const start: (options: NativeCaptureOptions) => Promise<void>;
export const stop: () => Promise<NativeCaptureResult>;
export const cancel: () => void;
export const getStatus: () => NativeCaptureStatus;
export const mix: (options: NativeMixOptions) => Promise<void>;
