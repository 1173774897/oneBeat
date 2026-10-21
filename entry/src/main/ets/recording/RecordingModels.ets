export type RecordingState = 'idle' | 'preparing' | 'recording' | 'stopping' | 'failed';
export type RecordingScope = 'solo' | 'team';
/** The immutable MIC stem's processing contract; absent means legacy screen MIC. */
export type RecordingMicCaptureMode = 'system-aec' | 'screen-mic';
/** Coarse, completed I/O boundaries; these stages are not a time-based percentage. */
export type RecordingSavePhase = 'finishing' | 'mixing' | 'indexing';

/** A completed, app-private MP4; deleting the app also deletes its local work and check-ins. */
export interface RecordingClip {
  id: string;
  path: string;
  /** App-private JPEG extracted from the first video key frame. */
  coverPath?: string;
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
  /** User edit relative to the automatic post-cleaning baseline; positive delays MIC. */
  renderedMicShiftUs?: number;
  /** High-confidence post-cleaning baseline inferred from aligned inner/MIC stems. */
  autoMicShiftUs?: number;
  autoMicShiftConfidence?: number;
  autoMicShiftReliable?: boolean;
  /** Export DSP revision; older renders with retained stems are rebuilt without changing the gain. */
  renderedMixVersion?: number;
  renderedAt?: number;
  /** Explicit capture validation survives save retries; absent only for already saved legacy works. */
  captureSyncValid?: boolean;
  captureMappingVersion?: number;
  videoTimestampDivisor?: number;
  /** True on built-in speaker; only legacy screen MIC uses offline echo cancellation. */
  builtInSpeakerCapture?: boolean;
  /** System AEC stems bypass the legacy offline echo fit and automatic MIC shift. */
  micCaptureMode?: RecordingMicCaptureMode;
  /** Media-library URI produced by "save to album"; reused for sharing so the album copy is made only once. */
  albumUri?: string;
  /** renderedAt (or createdAt) of the content stored at albumUri; used to invalidate the URI after a re-render. */
  albumContentAt?: number;
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
  /** True until native screen capture has finished releasing; save/result UI must stay out of the video. */
  captureActive: boolean;
  elapsedMs: number;
  amplitude: number;
  error: string;
  /** Actionable detail for a pending save; cleared when save succeeds or pending clip is discarded. */
  saveFailureDetail: string;
  /** Meaningful during stopping; the UI reports real stages without guessing elapsed progress. */
  savePhase?: RecordingSavePhase;
  micMuted: boolean;
  lastClip?: RecordingClip;
  pendingClip?: RecordingClip;
}

export type RecordingListener = (snapshot: RecordingSnapshot) => void;
