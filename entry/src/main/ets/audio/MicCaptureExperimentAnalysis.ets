const NS_PER_SECOND: number = 1000000000;
const NS_PER_MS: number = 1000000;
const MIN_FIT_ANCHORS: number = 6;
const MIN_FIT_DURATION_MS: number = 1000;
const MIN_SLOPE_PAIR_DURATION_MS: number = 100;
const MAX_STEP_ERROR_MS: number = 12;
const MAX_RESIDUAL_P95_MS: number = 1;
const MAX_RESIDUAL_MS: number = 3;
const MAX_CLOCK_RATE_ERROR_PPM: number = 2000;
const CALLBACK_CURSOR_VARIATION_MS: number = 20;

/**
 * One hardware timestamp query in capture order. The caller must normalize the
 * native timestamp to nanoseconds in one unchanged clock domain. Frame positions
 * count PCM frames, not individual channel samples or bytes. receivedFrames is
 * the cumulative number of frames delivered when the hardware query was taken.
 */
export interface MicCaptureClockAnchor {
  framePosition: number;
  timestampNs: number;
  receivedFrames: number;
}

export type MicCaptureClockQuality = 'insufficient' | 'stable' | 'unstable';

/** Observation only: none of these values is an acoustic or playback calibration. */
export interface MicCaptureClockReport {
  sampleRate: number;
  anchorCount: number;
  warmupAnchorCount: number;
  usableAnchorCount: number;
  duplicateAnchorCount: number;
  invalidAnchorCount: number;
  discontinuityCount: number;
  observedDurationMs: number;
  estimatedSampleRate: number;
  // Positive ppm means that the hardware frame clock advances faster than nominal.
  clockRateErrorPpm: number;
  fitStartFrame: number;
  fitStartTimestampNs: number;
  timestampFitResidualP95Ms: number;
  timestampFitResidualMaxMs: number;
  // The received/hardware cursor difference includes callback batching and query
  // scheduling. It must never be presented or saved as microphone input latency.
  frameCursorOffsetMedianFrames: number;
  frameCursorOffsetRangeFrames: number;
  frameCursorVariationMs: number;
  callbackBatchingSuspected: boolean;
  quality: MicCaptureClockQuality;
  reason: string;
}

function median(values: number[]): number {
  if (values.length === 0) {
    return 0;
  }
  const sorted = values.slice().sort((left: number, right: number) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function validAnchor(anchor: MicCaptureClockAnchor): boolean {
  return Number.isSafeInteger(anchor.framePosition) && anchor.framePosition >= 0 &&
    Number.isFinite(anchor.timestampNs) && anchor.timestampNs > 0 &&
    Number.isSafeInteger(anchor.receivedFrames) && anchor.receivedFrames >= 0;
}

function emptyReport(anchorCount: number, sampleRate: number): MicCaptureClockReport {
  return {
    sampleRate: sampleRate,
    anchorCount: anchorCount,
    warmupAnchorCount: 0,
    usableAnchorCount: 0,
    duplicateAnchorCount: 0,
    invalidAnchorCount: 0,
    discontinuityCount: 0,
    observedDurationMs: 0,
    estimatedSampleRate: 0,
    clockRateErrorPpm: 0,
    fitStartFrame: 0,
    fitStartTimestampNs: 0,
    timestampFitResidualP95Ms: 0,
    timestampFitResidualMaxMs: 0,
    frameCursorOffsetMedianFrames: 0,
    frameCursorOffsetRangeFrames: 0,
    frameCursorVariationMs: 0,
    callbackBatchingSuspected: false,
    quality: 'insufficient',
    reason: '有效硬件时间戳不足，不能判断采集时钟是否稳定'
  };
}

/**
 * Fits hardware timestamp against hardware frame position, never callback arrival
 * time. Robust slopes tolerate isolated query noise; rejected/repeated anchors
 * remain visible in the report. A stable 10-second fit proves only this capture
 * clock's short-term consistency, not microphone AEC quality or A/V alignment.
 */
export function analyzeMicCaptureClock(anchors: MicCaptureClockAnchor[],
  sampleRate: number): MicCaptureClockReport {
  const report = emptyReport(anchors.length, sampleRate);
  if (!Number.isFinite(sampleRate) || sampleRate <= 0) {
    report.reason = '采样率无效，不能分析采集时钟';
    return report;
  }

  const nominalNsPerFrame = NS_PER_SECOND / sampleRate;
  const usable: MicCaptureClockAnchor[] = [];
  const cursorOffsets: number[] = [];
  let previous: MicCaptureClockAnchor | undefined = undefined;
  let warmup = true;
  for (let index = 0; index < anchors.length; index++) {
    const anchor = anchors[index];
    const zeroCursors = anchor.framePosition === 0 && anchor.receivedFrames === 0;
    // Some devices expose a pre-start timestamp placeholder in another epoch.
    // Only the continuous zero/zero prefix is excluded; returning to zero after
    // capture progresses is a reset, never another opportunity to hide a jump.
    if (warmup && zeroCursors) {
      report.warmupAnchorCount++;
      continue;
    }
    warmup = false;
    if (zeroCursors) {
      report.discontinuityCount++;
      if (!validAnchor(anchor)) { report.invalidAnchorCount++; }
      continue;
    }
    if (!validAnchor(anchor)) {
      report.invalidAnchorCount++;
      continue;
    }
    cursorOffsets.push(anchor.receivedFrames - anchor.framePosition);
    if (previous !== undefined) {
      const frameDelta = anchor.framePosition - previous.framePosition;
      const timeDeltaNs = anchor.timestampNs - previous.timestampNs;
      if (frameDelta === 0 && timeDeltaNs === 0) {
        report.duplicateAnchorCount++;
        continue;
      }
      if (frameDelta <= 0 || timeDeltaNs <= 0 || anchor.receivedFrames < previous.receivedFrames) {
        report.discontinuityCount++;
        continue;
      }
      const stepErrorMs = Math.abs(timeDeltaNs - frameDelta * nominalNsPerFrame) / NS_PER_MS;
      // A reset/large step makes the entire run unsuitable for timing comparison,
      // even if a robust fit can still recover the dominant clock rate afterward.
      if (stepErrorMs > MAX_STEP_ERROR_MS) {
        report.discontinuityCount++;
      }
    }
    usable.push(anchor);
    previous = anchor;
  }

  report.usableAnchorCount = usable.length;
  if (cursorOffsets.length > 0) {
    const offsets = cursorOffsets.slice().sort((left: number, right: number) => left - right);
    report.frameCursorOffsetMedianFrames = median(offsets);
    report.frameCursorOffsetRangeFrames = offsets[offsets.length - 1] - offsets[0];
    report.frameCursorVariationMs = report.frameCursorOffsetRangeFrames * 1000 / sampleRate;
    // This is a scheduling/batching hint only. Hardware fitting below remains
    // independent so delayed delivery cannot be mistaken for clock-rate drift.
    report.callbackBatchingSuspected = report.frameCursorVariationMs > CALLBACK_CURSOR_VARIATION_MS;
  }
  if (usable.length < 2) {
    return report;
  }

  const origin = usable[0];
  report.fitStartFrame = origin.framePosition;
  report.fitStartTimestampNs = origin.timestampNs;
  report.observedDurationMs = (usable[usable.length - 1].timestampNs - origin.timestampNs) / NS_PER_MS;
  const slopes: number[] = [];
  for (let left = 0; left < usable.length - 1; left++) {
    for (let right = left + 1; right < usable.length; right++) {
      const timeDeltaNs = usable[right].timestampNs - usable[left].timestampNs;
      // Wider pairs make ppm less sensitive to sub-millisecond hardware query
      // quantization. Relative arithmetic also avoids subtracting large epochs.
      const frameDelta = usable[right].framePosition - usable[left].framePosition;
      if (frameDelta * nominalNsPerFrame >= MIN_SLOPE_PAIR_DURATION_MS * NS_PER_MS) {
        slopes.push(timeDeltaNs / frameDelta);
      }
    }
  }
  if (slopes.length === 0) {
    return report;
  }
  const nsPerFrame = median(slopes);
  if (!Number.isFinite(nsPerFrame) || nsPerFrame <= 0) {
    return report;
  }
  const relativeIntercepts: number[] = [];
  for (let index = 0; index < usable.length; index++) {
    relativeIntercepts.push((usable[index].timestampNs - origin.timestampNs) -
      (usable[index].framePosition - origin.framePosition) * nsPerFrame);
  }
  const relativeInterceptNs = median(relativeIntercepts);
  report.fitStartTimestampNs = origin.timestampNs + relativeInterceptNs;
  report.estimatedSampleRate = NS_PER_SECOND / nsPerFrame;
  report.clockRateErrorPpm = (report.estimatedSampleRate / sampleRate - 1) * 1000000;

  const residualsMs: number[] = [];
  for (let index = 0; index < usable.length; index++) {
    const predictedRelativeNs = relativeInterceptNs +
      (usable[index].framePosition - origin.framePosition) * nsPerFrame;
    residualsMs.push(Math.abs((usable[index].timestampNs - origin.timestampNs) - predictedRelativeNs) / NS_PER_MS);
  }
  residualsMs.sort((left: number, right: number) => left - right);
  report.timestampFitResidualP95Ms = residualsMs[Math.max(0, Math.ceil(residualsMs.length * 0.95) - 1)];
  report.timestampFitResidualMaxMs = residualsMs[residualsMs.length - 1];

  const nominalSpanMs = (usable[usable.length - 1].framePosition - origin.framePosition) * 1000 / sampleRate;
  if (usable.length < MIN_FIT_ANCHORS || nominalSpanMs < MIN_FIT_DURATION_MS) {
    return report;
  }
  const unstable = report.discontinuityCount > 0 ||
    report.timestampFitResidualP95Ms > MAX_RESIDUAL_P95_MS ||
    report.timestampFitResidualMaxMs > MAX_RESIDUAL_MS ||
    Math.abs(report.clockRateErrorPpm) > MAX_CLOCK_RATE_ERROR_PPM;
  if (!unstable && report.observedDurationMs < MIN_FIT_DURATION_MS) {
    return report;
  }
  report.quality = unstable ? 'unstable' : 'stable';
  report.reason = unstable ? '硬件时间戳存在跳变、较大残差或异常速率，本次不能作为可靠时钟比较' :
    '硬件时间戳短时拟合稳定；这不代表声学对齐或回声消除效果';
  return report;
}
