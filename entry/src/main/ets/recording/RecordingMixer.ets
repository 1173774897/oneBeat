import * as recordingNative from 'libonebeat_recording.so';
import { RecordingClip, RecordingMicCaptureMode } from './RecordingModels';

// Retained stems let same-gain legacy exports adopt the current DSP once.
export const RECORDING_MIX_VERSION: number = 6;
const SYSTEM_AEC_MIX_VERSION: number = 7;
export const MAX_MIC_SHIFT_US: number = 300000;
const PROCESSED_MIC_VERSION: number = 3;
const BUILT_IN_SPEAKER_BLEED_LIMIT: number = 4;

export interface RecordingMixResult {
  autoMicShiftUs: number;
  autoMicShiftConfidence: number;
  autoMicShiftReliable: boolean;
}

/** Source tracks are immutable; app audio stays at unity and gain applies only to cleaned MIC. */
export class RecordingMixer {
  /** Upgrade quiet AEC takes without re-rendering unchanged legacy FIR exports. */
  static mixVersion(clip: RecordingClip): number {
    return clip.micCaptureMode === 'system-aec' ? SYSTEM_AEC_MIX_VERSION : RECORDING_MIX_VERSION;
  }

  /** A DSP-versioned sidecar is reusable only with its immutable raw MIC stem. */
  static processedMicPath(micPath: string, mode?: RecordingMicCaptureMode): string {
    if (micPath.length === 0) { throw new Error('麦克风原轨路径无效'); }
    // A system-processed stem must never reuse a legacy FIR residual cache.
    if (mode === 'system-aec') { return `${micPath}.system-aec-v2.f32`; }
    return `${micPath}.clean-v${PROCESSED_MIC_VERSION}.f32`;
  }

  static validateCaptureTiming(clip: RecordingClip): void {
    const systemAec = clip.micCaptureMode === 'system-aec';
    const validMapping = systemAec ? clip.captureMappingVersion === 3 : clip.captureMappingVersion === 2;
    if (clip.captureSyncValid === false || (clip.captureSyncValid === true &&
      (!validMapping || (clip.videoTimestampDivisor !== 1 && clip.videoTimestampDivisor !== 1000))) ||
      (systemAec && clip.captureSyncValid !== true)) {
      throw new Error('设备录屏时间戳不兼容，无法保证三路同步');
    }
    // Existing saved works predate the explicit mapping marker. Their measured
    // offsets remain usable; a newly finished capture must carry the marker.
    if (!Number.isFinite(clip.micOffsetUs ?? 0) || !Number.isFinite(clip.innerOffsetUs ?? 0) ||
      Math.abs(clip.micOffsetUs ?? 0) > 10000000 || Math.abs(clip.innerOffsetUs ?? 0) > 10000000) {
      throw new Error('设备录屏时间戳不兼容，无法保证三路同步');
    }
  }

  static async exportMixed(clip: RecordingClip, gain: number, outputPath: string,
    micShiftUs: number = clip.renderedMicShiftUs ?? 0): Promise<RecordingMixResult> {
    if (!Number.isFinite(gain) || gain < 0 || gain > 2) {
      throw new Error('麦克风音量需在 0% 到 200% 之间');
    }
    if (!Number.isFinite(micShiftUs) || Math.abs(micShiftUs) > MAX_MIC_SHIFT_US) {
      throw new Error('人声对齐需在提前或延后 300 毫秒以内');
    }
    if (clip.sourcePath === undefined || clip.innerPath === undefined || clip.micPath === undefined) {
      throw new Error('这段旧视频没有独立麦克风音轨，无法单独调整');
    }
    if ((clip.audioSampleRate ?? 48000) !== 48000 || (clip.audioChannels ?? 2) !== 2) {
      throw new Error('原始音轨格式不兼容');
    }
    RecordingMixer.validateCaptureTiming(clip);
    const innerLeadUs = (clip.innerOffsetUs ?? 0) - (clip.micOffsetUs ?? 0);
    // Built-in speaker captures beat bleed on mic before OH_APP_PLAYBACK inner starts.
    const systemAec = clip.micCaptureMode === 'system-aec';
    const speakerLikeCapture = !systemAec && (clip.builtInSpeakerCapture === true ||
      (clip.builtInSpeakerCapture === undefined && innerLeadUs > 80000));
    // Native fits each microphone channel's room response in local windows.
    // This is a fit ceiling, never a fixed subtraction from both channels.
    const speakerBleedCancel = speakerLikeCapture ? BUILT_IN_SPEAKER_BLEED_LIMIT : 0;
    if (speakerLikeCapture) {
      console.info(`[RecordingMix] speaker residual innerLeadUs=${innerLeadUs} maxEchoGain=${speakerBleedCancel}`);
    }
    const autoKnown = systemAec || (clip.autoMicShiftUs !== undefined &&
      clip.autoMicShiftConfidence !== undefined && clip.autoMicShiftReliable !== undefined);
    // LIVE already applies AEC. Only compensate abnormally quiet MIC level;
    // a second echo fit or automatic time shift can damage speech/synchrony.
    const result = await recordingNative.mix({
      sourcePath: clip.sourcePath, innerPath: clip.innerPath, micPath: clip.micPath, outputPath: outputPath,
      durationMs: clip.durationMs, innerOffsetUs: clip.innerOffsetUs ?? 0, micOffsetUs: clip.micOffsetUs ?? 0,
      micShiftUs: micShiftUs, gain: gain, speakerBleedCancel: speakerBleedCancel,
      normalizeSystemMic: systemAec,
      autoMicShiftUs: systemAec ? 0 : clip.autoMicShiftUs ?? 0, autoMicShiftKnown: autoKnown ? 1 : 0,
      autoMicShiftReliable: !systemAec && clip.autoMicShiftReliable === true ? 1 : 0,
      autoMicShiftConfidence: systemAec ? 0 : clip.autoMicShiftConfidence ?? 0,
      processedMicPath: RecordingMixer.processedMicPath(clip.micPath, clip.micCaptureMode)
    });
    if (!Number.isFinite(result.autoMicShiftUs) || Math.abs(result.autoMicShiftUs) > 30000 ||
      !Number.isFinite(result.autoMicShiftConfidence) ||
      result.autoMicShiftConfidence < 0 || result.autoMicShiftConfidence > 1) {
      throw new Error('自动人声对齐结果无效');
    }
    return result;
  }
}
