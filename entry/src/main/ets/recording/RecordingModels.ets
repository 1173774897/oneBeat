export type RecordingState = 'idle' | 'preparing' | 'recording' | 'stopping' | 'failed';
export type RecordingScope = 'solo' | 'team';

/** A completed, app-private MP4; deleting the app also deletes its local work and check-ins. */
export interface RecordingClip {
  id: string;
  path: string;
  createdAt: number;
  durationMs: number;
  width: number;
  height: number;
  interrupted: boolean;
  stopReason: string;
  scope?: RecordingScope;
  sourcePath?: string;
  innerPath?: string;
  micPath?: string;
  innerOffsetUs?: number;
  micOffsetUs?: number;
  audioSampleRate?: number;
  audioChannels?: number;
  renderedGain?: number;
  renderedAt?: number;
  /** Explicit capture validation survives save retries; absent only for already saved legacy works. */
  captureSyncValid?: boolean;
  captureMappingVersion?: number;
  videoTimestampDivisor?: number;
  /** True when capture started on built-in speaker; mix applies echo bleed cancel. */
  builtInSpeakerCapture?: boolean;
}

/** A finished capture awaiting export/indexing; never an already playable library entry. */
export interface PendingRecordingCapture {
  version: number;
  finished: boolean;
  clip: RecordingClip;
}

/** Amplitude is a measured input peak in [0, 1], never a beat-driven or synthetic waveform. */
export interface RecordingSnapshot {
  state: RecordingState;
  elapsedMs: number;
  amplitude: number;
  error: string;
  /** Actionable detail for a pending save; cleared when save succeeds or pending clip is discarded. */
  saveFailureDetail: string;
  micMuted: boolean;
  lastClip?: RecordingClip;
  pendingClip?: RecordingClip;
}

export type RecordingListener = (snapshot: RecordingSnapshot) => void;
