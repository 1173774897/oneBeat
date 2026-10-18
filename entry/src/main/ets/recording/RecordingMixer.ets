import * as recordingNative from 'libonebeat_recording.so';
import { RecordingClip } from './RecordingModels';

// Retained stems let same-gain legacy exports adopt the current DSP once.
export const RECORDING_MIX_VERSION: number = 6;
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
  /** A DSP-versioned sidecar is reusable only with its immutable raw MIC stem. */
  static processedMicPath(micPath: string): string {
    if (micPath.length === 0) { throw new Error('麦克风原轨路径无效'); }
    return `${micPath}.clean-v${PROCESSED_MIC_VERSION}.f32`;
  }

  static validateCaptureTiming(clip: RecordingClip): void {
    if (clip.captureSyncValid === false || (clip.captureSyncValid === true &&
      (clip.captureMappingVersion !== 2 ||
        (clip.videoTimestampDivisor !== 1 && clip.videoTimestampDivisor !== 1000)))) {
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
    const speakerLikeCapture = clip.builtInSpeakerCapture === true ||
      (clip.builtInSpeakerCapture === undefined && innerLeadUs > 80000);
    // Native fits each microphone channel's room response in local windows.
    // This is a fit ceiling, never a fixed subtraction from both channels.
    const speakerBleedCancel = speakerLikeCapture ? BUILT_IN_SPEAKER_BLEED_LIMIT : 0;
    if (speakerLikeCapture) {
      console.info(`[RecordingMix] speaker residual innerLeadUs=${innerLeadUs} maxEchoGain=${speakerBleedCancel}`);
    }
    const autoKnown = clip.autoMicShiftUs !== undefined &&
      clip.autoMicShiftConfidence !== undefined && clip.autoMicShiftReliable !== undefined;
    const result = await recordingNative.mix({
      sourcePath: clip.sourcePath, innerPath: clip.innerPath, micPath: clip.micPath, outputPath: outputPath,
      durationMs: clip.durationMs, innerOffsetUs: clip.innerOffsetUs ?? 0, micOffsetUs: clip.micOffsetUs ?? 0,
      micShiftUs: micShiftUs, gain: gain, speakerBleedCancel: speakerBleedCancel,
      autoMicShiftUs: clip.autoMicShiftUs ?? 0, autoMicShiftKnown: autoKnown ? 1 : 0,
      autoMicShiftReliable: clip.autoMicShiftReliable === true ? 1 : 0,
      autoMicShiftConfidence: clip.autoMicShiftConfidence ?? 0,
      processedMicPath: RecordingMixer.processedMicPath(clip.micPath)
    });
    if (!Number.isFinite(result.autoMicShiftUs) || Math.abs(result.autoMicShiftUs) > 30000 ||
      !Number.isFinite(result.autoMicShiftConfidence) ||
      result.autoMicShiftConfidence < 0 || result.autoMicShiftConfidence > 1) {
      throw new Error('自动人声对齐结果无效');
    }
    return result;
  }
}
