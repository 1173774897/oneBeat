import * as recordingNative from 'libonebeat_recording.so';
import { RecordingClip, RecordingMicCaptureMode } from './RecordingModels';

// Retained stems let same-gain legacy exports adopt the current DSP once.
export const RECORDING_MIX_VERSION: number = 6;
// 9: speaker AEC takes measure the accompaniment residual's round trip and advance the MIC.
// 10: explained-variance gate rejects near-empty fits; upgrades keep user-tuned alignment.
const SYSTEM_AEC_MIX_VERSION: number = 10;
/** Mirrors native MAX_AUTO_MIC_SHIFT_US: the automatic baseline never exceeds 250 ms. */
const MAX_AUTO_MIC_SHIFT_US: number = 250000;
export const MAX_MIC_SHIFT_US: number = 300000;
/**
 * MIC edit ceiling (400%, +12 dB). Drum styles sit ~12 dB above a typical
 * instrument MIC at 100%; the bus limiter absorbs the resulting peaks.
 * Native MixFile enforces the same bound.
 */
export const MAX_MIC_GAIN: number = 4;
const PROCESSED_MIC_VERSION: number = 3;
const BUILT_IN_SPEAKER_BLEED_LIMIT: number = 4;

export interface RecordingMixResult {
  autoMicShiftUs: number;
  autoMicShiftConfidence: number;
  autoMicShiftReliable: boolean;
  /** Manual edit to persist; rebased only when an upgrade preserved a tuned take's alignment. */
  micShiftUs: number;
}

/**
 * Source tracks are immutable; app audio stays at unity and gain applies only to cleaned MIC.
 * The native bus uses a lookahead peak limiter instead of a hard clamp: it is bit-exact while
 * app + MIC stays in S16 range, so only takes that would have clipped change.
 */
export class RecordingMixer {
  /** Upgrade quiet AEC takes without re-rendering unchanged legacy FIR exports. */
  static mixVersion(clip: RecordingClip): number {
    return clip.micCaptureMode === 'system-aec' ? SYSTEM_AEC_MIX_VERSION : RECORDING_MIX_VERSION;
  }

  /** A DSP-versioned sidecar is reusable only with its immutable raw MIC stem. */
  static processedMicPath(micPath: string, mode?: RecordingMicCaptureMode): string {
    if (micPath.length === 0) { throw new Error('麦克风原轨路径无效'); }
    // A system-processed stem must never reuse a legacy FIR residual cache.
    // v5 re-measures the speaker AEC round trip with the explained-variance gate
    // (v3 carried a fixed zero baseline; v4 could accept near-empty fits).
    if (mode === 'system-aec') { return `${micPath}.system-aec-v5.f32`; }
    return `${micPath}.clean-v${PROCESSED_MIC_VERSION}.f32`;
  }

  /**
   * A baseline copied from the removed per-device memory (reliable with confidence 0).
   * Device takes measured 134 ms (accompaniment residual) and 62 ms (the performance
   * itself) on one phone, so the lag belongs to each take's content, not the device.
   * Such a take is re-measured from its own stems.
   */
  static hasDeviceMemoryBaseline(clip: RecordingClip): boolean {
    return clip.micCaptureMode === 'system-aec' && clip.autoMicShiftReliable === true &&
      clip.autoMicShiftConfidence === 0 && (clip.autoMicShiftUs ?? 0) !== 0;
  }

  /** The stored export matches the current DSP version and the take's own baseline. */
  static isRenderCurrent(clip: RecordingClip): boolean {
    return (clip.renderedMixVersion ?? 0) >= RecordingMixer.mixVersion(clip) &&
      !RecordingMixer.hasDeviceMemoryBaseline(clip);
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
    if (!Number.isFinite(gain) || gain < 0 || gain > MAX_MIC_GAIN) {
      throw new Error(`麦克风音量需在 0% 到 ${MAX_MIC_GAIN * 100}% 之间`);
    }
    if (!Number.isFinite(micShiftUs) || Math.abs(micShiftUs) > MAX_MIC_SHIFT_US) {
      throw new Error('时间偏移需在提前或延后 300 毫秒以内');
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
    // A DSP-version upgrade or a device-memory baseline re-measures from the stems; a tuned
    // take keeps its audible alignment (the manual edit is rebased natively), an untouched
    // one adopts the result.
    const remeasure = (clip.renderedMixVersion ?? 0) < RecordingMixer.mixVersion(clip) ||
      RecordingMixer.hasDeviceMemoryBaseline(clip);
    const autoKnown = !remeasure && clip.autoMicShiftUs !== undefined &&
      clip.autoMicShiftConfidence !== undefined && clip.autoMicShiftReliable !== undefined;
    const preserveEffective = remeasure && micShiftUs !== 0 && clip.autoMicShiftUs !== undefined;
    // LIVE already applies AEC: no second echo fit. On the speaker the native cache build
    // measures how late the MIC content locked to the accompaniment arrives (the residual
    // when audible, otherwise the performance) and advances the MIC by that lag. A take
    // too weak to measure keeps a zero baseline: there is no device-wide value to reuse.
    const speakerAec = systemAec && clip.builtInSpeakerCapture === true;
    // Level-wise LIVE MIC only gets compensation when abnormally quiet; a second echo fit
    // would damage the near-end performance.
    const result = await recordingNative.mix({
      sourcePath: clip.sourcePath, innerPath: clip.innerPath, micPath: clip.micPath, outputPath: outputPath,
      durationMs: clip.durationMs, innerOffsetUs: clip.innerOffsetUs ?? 0, micOffsetUs: clip.micOffsetUs ?? 0,
      micShiftUs: micShiftUs, gain: gain, speakerBleedCancel: speakerBleedCancel,
      normalizeSystemMic: systemAec, estimateResidualLag: speakerAec,
      autoMicShiftUs: clip.autoMicShiftUs ?? 0, autoMicShiftKnown: autoKnown ? 1 : 0,
      autoMicShiftReliable: clip.autoMicShiftReliable === true ? 1 : 0,
      autoMicShiftConfidence: clip.autoMicShiftConfidence ?? 0,
      preserveEffectiveMicShift: preserveEffective, previousAutoMicShiftUs: preserveEffective ? clip.autoMicShiftUs ?? 0 : 0,
      processedMicPath: RecordingMixer.processedMicPath(clip.micPath, clip.micCaptureMode)
    });
    const d = result.diagnostics;
    if (d !== undefined) {
      // Device evidence for bus headroom, AEC level boost and AAC priming; contains levels only.
      console.info(`[RecordingMixDiag] mode=${clip.micCaptureMode ?? 'screen-mic'} gain=${gain}` +
        ` cacheBuilt=${d.cacheBuilt} micLevelGainDb=${d.micLevelGainDb.toFixed(2)} micKneeSamples=${d.micKneeSamples}` +
        ` innerPeak=${d.innerPeakDbfs.toFixed(2)} innerRms=${d.innerRmsDbfs.toFixed(2)}` +
        ` micPeak=${d.micPeakDbfs.toFixed(2)} micRms=${d.micRmsDbfs.toFixed(2)} busPeak=${d.busPeakDbfs.toFixed(2)}` +
        ` overFrames=${d.overFrames} limitedFrames=${d.limitedFrames} minLimiterGainDb=${d.minLimiterGainDb.toFixed(2)}` +
        ` aacInputFrames=${d.aacInputFrames} aacPackets=${d.aacOutputPackets}` +
        ` aacFirstPtsUs=${d.aacFirstOutputPtsUs} aacLastPtsUs=${d.aacLastOutputPtsUs} durationMs=${clip.durationMs}` +
        ` residualLagUs=${d.residualLagUs} residualShare=${d.residualLagShare.toFixed(2)}` +
        ` residualExplained=${d.residualLagExplained.toFixed(4)} remeasure=${remeasure}` +
        ` manualIn=${micShiftUs} manualOut=${result.micShiftUs}` +
        ` autoShiftUs=${result.autoMicShiftUs} autoReliable=${result.autoMicShiftReliable}`);
    }
    if (!Number.isFinite(result.autoMicShiftUs) || Math.abs(result.autoMicShiftUs) > MAX_AUTO_MIC_SHIFT_US ||
      !Number.isFinite(result.autoMicShiftConfidence) ||
      result.autoMicShiftConfidence < 0 || result.autoMicShiftConfidence > 1 ||
      !Number.isFinite(result.micShiftUs) || Math.abs(result.micShiftUs) > MAX_MIC_SHIFT_US) {
      throw new Error('自动对齐结果无效');
    }
    return result;
  }
}
