import { MonotonicClock } from '../common/MonotonicClock';
import { PING_SAMPLES } from '../common/Constants';
import { PingResponse } from '../protocol/messages';

export interface SyncSample {
  offsetMs: number;
  rttMs: number;
  // Network measurements retain their own midpoint; batch completion is not a measurement time.
  localMidpointMs?: number;
  validSampleCount?: number;
}

export interface ClockSyncReadiness {
  ready: boolean;
  reason: string;
  mode: string;
  sampleAgeMs: number;
  errorEstimateMs: number;
  validSampleCount: number;
  skewPpm: number;
}

/** A received batch was unusable, unlike a timeout indicating an unreachable peer. */
export class ClockSyncMeasurementError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ClockSyncMeasurementError';
  }
}

const CLOCK_FIT_CONSISTENCY_MARGIN_MS: number = 5;
const CLOCK_FIT_MIN_WEIGHT_RTT_MS: number = 4;
const CLOCK_FIT_MIN_SAMPLES: number = 3;
const CLOCK_FIT_MIN_SPAN_MS: number = 10000;
const CLOCK_FIT_WINDOW_MS: number = 60000;
const CLOCK_FIT_MAX_RESIDUAL_MS: number = 3;
// An admission guard against fitting network noise as drift, not a measured hardware bound.
// Reject out-of-range fits: clipping their slope would invent an unsupported time mapping.
const CLOCK_FIT_MAX_ABS_SKEW_PPM: number = 1000;
// Five-second resyncs can survive two missed intervals; never extrapolate indefinitely.
const CLOCK_MAPPING_HOLDOVER_MS: number = 15000;
const CLOCK_READY_MAX_AGE_MS: number = 3000;
const CLOCK_READY_MIN_SAMPLES: number = 3;
// This is a network-clock admission budget, not a guarantee of audible alignment.
// RTT cannot distinguish a fixed asymmetric path from a true clock offset.
const CLOCK_READY_MAX_ERROR_MS: number = 10;
const CLOCK_TIMESTAMP_MARGIN_MS: number = 1;

interface TimedOffsetSample {
  atMs: number;
  offsetMs: number;
  rttMs: number;
  validSampleCount: number;
}

export class ClockSyncEstimator {
  private offsetMs: number = 0;
  private rttMs: number = 999;
  private samples: TimedOffsetSample[] = [];
  private lastSample: TimedOffsetSample | undefined = undefined;
  private skewPpm: number = 0;
  private skewRefAtMs: number = 0;
  private skewRefOffsetMs: number = 0;
  private fitResidualMs: number = 0;
  private hasSkewFit: boolean = false;

  getOffsetMs(): number {
    return this.getOffsetAt(MonotonicClock.nowMs());
  }

  /** leader ≈ client + offset. Expired projections freeze; they must not admit a new start. */
  getOffsetAt(atMs: number): number {
    if (!this.hasSkewFit || !Number.isFinite(atMs)) {
      return this.offsetMs;
    }
    const projectionAtMs = Math.min(this.getMappingValidUntilMs(),
      Math.max(this.samples[0].atMs, atMs));
    return this.skewRefOffsetMs + this.skewPpm * (projectionAtMs - this.skewRefAtMs) / 1e6;
  }

  /** Derivative of the current mapping; consumers must also retain its expiry. */
  getSkewPpm(atMs: number = MonotonicClock.nowMs()): number {
    return this.hasSkewFit && Number.isFinite(atMs) && atMs >= this.samples[0].atMs &&
      atMs < this.getMappingValidUntilMs() ? this.skewPpm : 0;
  }

  getMappingValidUntilMs(): number {
    return this.lastSample === undefined ? 0 : this.lastSample.atMs + CLOCK_MAPPING_HOLDOVER_MS;
  }

  getRttMs(): number {
    return this.rttMs;
  }

  /** Network responsiveness only. Strict playback admission uses getReadiness(), not this label. */
  getQualityLabel(): string {
    if (this.rttMs < 50) {
      return 'good';
    }
    if (this.rttMs < 150) {
      return 'fair';
    }
    return 'poor';
  }

  /**
   * Conservative operational estimate including path ambiguity, fit residual and sample age.
   * The drift allowance is a policy assumption; hardware output latency is outside this model.
   */
  getReadiness(atMs: number = MonotonicClock.nowMs()): ClockSyncReadiness {
    const sample = this.lastSample;
    if (sample === undefined || !Number.isFinite(atMs)) {
      return ClockSyncEstimator.unavailableReadiness('uninitialized');
    }
    const estimateAtSample = this.getOffsetAt(sample.atMs);
    return ClockSyncEstimator.assessSample({ offsetMs: sample.offsetMs, rttMs: sample.rttMs,
      localMidpointMs: sample.atMs, validSampleCount: sample.validSampleCount }, atMs,
      Math.abs(estimateAtSample - sample.offsetMs) + this.fitResidualMs,
      this.getSkewPpm(atMs), this.hasSkewFit);
  }

  /** Check admission before mutating a live mapping with a slow or stale batch. */
  static getSampleReadiness(sample: SyncSample,
    atMs: number = MonotonicClock.nowMs()): ClockSyncReadiness {
    if (!ClockSyncEstimator.isValidSample(sample) || !Number.isFinite(atMs)) {
      return ClockSyncEstimator.unavailableReadiness('invalid_sample');
    }
    return ClockSyncEstimator.assessSample(sample, atMs, 0, 0, false);
  }

  private static assessSample(sample: SyncSample, atMs: number, additionalErrorMs: number,
    skewPpm: number, hasFit: boolean): ClockSyncReadiness {
    const measuredAtMs = sample.localMidpointMs === undefined ? atMs : sample.localMidpointMs;
    const validCount = sample.validSampleCount === undefined ? 1 : sample.validSampleCount;
    const ageMs = atMs - measuredAtMs;
    const errorEstimateMs = sample.rttMs / 2 + CLOCK_TIMESTAMP_MARGIN_MS + additionalErrorMs +
      Math.abs(ageMs) * CLOCK_FIT_MAX_ABS_SKEW_PPM / 1e6;
    let reason = 'ready';
    if (validCount < CLOCK_READY_MIN_SAMPLES) {
      reason = 'insufficient_samples';
    } else if (ageMs < 0 || ageMs > CLOCK_READY_MAX_AGE_MS) {
      reason = 'stale_sample';
    } else if (errorEstimateMs > CLOCK_READY_MAX_ERROR_MS) {
      reason = 'uncertain_offset';
    }
    const mode = ageMs > CLOCK_MAPPING_HOLDOVER_MS ? 'stale' :
      ageMs > CLOCK_READY_MAX_AGE_MS ? 'holdover' : hasFit ? 'skew' : 'offset';
    return { ready: reason === 'ready', reason: reason, mode: mode,
      sampleAgeMs: ageMs, errorEstimateMs: errorEstimateMs,
      validSampleCount: validCount, skewPpm: skewPpm };
  }

  private static unavailableReadiness(reason: string): ClockSyncReadiness {
    return { ready: false, reason: reason, mode: 'uninitialized',
      sampleAgeMs: Number.POSITIVE_INFINITY, errorEstimateMs: Number.POSITIVE_INFINITY,
      validSampleCount: 0, skewPpm: 0 };
  }

  /** NTP-style offset: leaderMono ≈ clientMono + offsetMs. A single ping cannot make READY. */
  recordRoundTrip(clientSendMs: number, serverRecvMs: number, serverSendMs: number,
    clientRecvMs: number): boolean {
    const sample = ClockSyncEstimator.fromRoundTrip(clientSendMs, serverRecvMs, serverSendMs, clientRecvMs);
    return sample !== undefined && this.applySample(sample);
  }

  /** Invalid or out-of-order samples leave the complete previous mapping unchanged. */
  applySample(sample: SyncSample): boolean {
    return this.acceptSample(sample, 1);
  }

  smoothAdjust(next: SyncSample, alpha: number = 0.25): boolean {
    if (!Number.isFinite(alpha) || alpha < 0 || alpha > 1) {
      return false;
    }
    return this.acceptSample(next, alpha);
  }

  private acceptSample(sample: SyncSample, alpha: number): boolean {
    if (!ClockSyncEstimator.isValidSample(sample)) {
      return false;
    }
    // Missing timestamps are supported for direct callers; production batches always supply one.
    const now = MonotonicClock.nowMs();
    const atMs = sample.localMidpointMs === undefined ? now : sample.localMidpointMs;
    if (!Number.isFinite(now) || atMs > now ||
      (this.lastSample !== undefined && atMs < this.lastSample.atMs)) {
      return false;
    }
    if (this.lastSample !== undefined && atMs === this.lastSample.atMs) {
      // Preparation may reuse an in-flight resync. Accept that result idempotently,
      // rather than letting the same physical measurement gain extra regression weight.
      return sample.offsetMs === this.lastSample.offsetMs && sample.rttMs === this.lastSample.rttMs;
    }
    const timed: TimedOffsetSample = { atMs: atMs, offsetMs: sample.offsetMs, rttMs: sample.rttMs,
      validSampleCount: sample.validSampleCount === undefined ? 1 : sample.validSampleCount };
    const previousOffsetMs = this.getOffsetAt(atMs);
    const reset = this.recordSample(timed);
    this.offsetMs = this.lastSample === undefined || reset ? sample.offsetMs :
      previousOffsetMs * (1 - alpha) + sample.offsetMs * alpha;
    this.rttMs = sample.rttMs;
    this.lastSample = timed;
    return true;
  }

  /** Only filtered batches should enter the history during network measurement. */
  private recordSample(sample: TimedOffsetSample): boolean {
    let reset = false;
    if (this.lastSample !== undefined && sample.atMs - this.lastSample.atMs > CLOCK_MAPPING_HOLDOVER_MS) {
      // Once holdover expires, a new batch starts a new training window instead of reviving stale drift.
      this.samples = [];
      reset = true;
    } else if (this.hasSkewFit) {
      const projected = this.getOffsetAt(sample.atMs);
      const boundMs = sample.rttMs / 2 + CLOCK_FIT_CONSISTENCY_MARGIN_MS;
      if (Math.abs(projected - sample.offsetMs) > boundMs) {
        console.info(`[ClockFitDiag] action=reset projectedOffsetMs=${projected.toFixed(2)} ` +
          `sampleOffsetMs=${sample.offsetMs.toFixed(2)} rttMs=${sample.rttMs.toFixed(2)} ` +
          `boundMs=${boundMs.toFixed(2)} droppedSamples=${this.samples.length}`);
        this.samples = [];
        reset = true;
      }
    }
    this.samples.push(sample);
    const horizon = sample.atMs - CLOCK_FIT_WINDOW_MS;
    while (this.samples.length > 1 && this.samples[0].atMs < horizon) {
      this.samples.shift();
    }
    this.fitSkew();
    return reset;
  }

  /** RTT-weighted fit with explicit training, rate and residual gates. */
  private fitSkew(): void {
    this.hasSkewFit = false;
    this.skewPpm = 0;
    this.fitResidualMs = 0;
    const n = this.samples.length;
    if (n < CLOCK_FIT_MIN_SAMPLES) {
      return;
    }
    const ref = this.samples[n - 1];
    if (ref.atMs - this.samples[0].atMs < CLOCK_FIT_MIN_SPAN_MS) {
      return;
    }
    let sumW = 0;
    let sumX = 0;
    let sumY = 0;
    let sumXX = 0;
    let sumXY = 0;
    for (const s of this.samples) {
      const rtt = Math.max(CLOCK_FIT_MIN_WEIGHT_RTT_MS, s.rttMs);
      const w = 1 / (rtt * rtt);
      const x = s.atMs - ref.atMs;
      // Center both axes: uptime offsets can be many hours larger than their millisecond variations.
      const y = s.offsetMs - ref.offsetMs;
      sumW += w;
      sumX += w * x;
      sumY += w * y;
      sumXX += w * x * x;
      sumXY += w * x * y;
    }
    const denom = sumW * sumXX - sumX * sumX;
    if (Math.abs(denom) < 1e-9 * sumW * sumW) {
      return;
    }
    const driftRate = (sumW * sumXY - sumX * sumY) / denom;
    const intercept = ref.offsetMs + (sumY - driftRate * sumX) / sumW;
    if (!Number.isFinite(driftRate) || !Number.isFinite(intercept) ||
      Math.abs(driftRate * 1e6) > CLOCK_FIT_MAX_ABS_SKEW_PPM) {
      return;
    }
    let sumSquaredError = 0;
    for (const s of this.samples) {
      const rtt = Math.max(CLOCK_FIT_MIN_WEIGHT_RTT_MS, s.rttMs);
      const error = s.offsetMs - (intercept + driftRate * (s.atMs - ref.atMs));
      sumSquaredError += error * error / (rtt * rtt);
    }
    const residual = Math.sqrt(sumSquaredError / sumW);
    if (!Number.isFinite(residual) || residual > CLOCK_FIT_MAX_RESIDUAL_MS) {
      return;
    }
    this.skewRefAtMs = ref.atMs;
    this.skewRefOffsetMs = intercept;
    this.skewPpm = driftRate * 1e6;
    this.fitResidualMs = residual;
    this.hasSkewFit = true;
  }

  static medianFromSamples(samples: SyncSample[]): SyncSample {
    const valid = samples.filter((sample) => ClockSyncEstimator.isValidSample(sample));
    if (valid.length === 0) {
      throw new ClockSyncMeasurementError('clock batch has no valid measurements');
    }
    const sorted = [...valid].sort((a, b) => a.rttMs - b.rttMs);
    const take = Math.max(1, Math.min(3, Math.ceil(sorted.length / 2)));
    const candidates = sorted.slice(0, take).sort((a, b) => a.offsetMs - b.offsetMs);
    // Use a real lower-median measurement (including its RTT and time). Averaging offsets
    // then attaching the fastest RTT fabricates a confidence interval that can exclude truth.
    let selected = candidates[Math.floor((candidates.length - 1) / 2)];
    for (const candidate of candidates) {
      if (candidate.offsetMs === selected.offsetMs && candidate.rttMs < selected.rttMs) {
        selected = candidate;
      }
    }
    return { offsetMs: selected.offsetMs, rttMs: selected.rttMs,
      localMidpointMs: selected.localMidpointMs, validSampleCount: valid.length };
  }

  static async measureWithSender(
    sendPing: (id: string, clientMono: number) => Promise<PingResponse>,
    sampleCount: number = PING_SAMPLES
  ): Promise<SyncSample> {
    const samples: SyncSample[] = [];
    for (let i = 0; i < sampleCount; i++) {
      const t0 = MonotonicClock.nowMs();
      const id = `ping-${i}-${t0}`;
      const response = await sendPing(id, t0);
      const t3 = MonotonicClock.nowMs();
      const sample = ClockSyncEstimator.fromRoundTrip(t0, response.serverMono, response.leaderMono, t3);
      if (sample !== undefined) {
        samples.push(sample);
      }
      if (i + 1 < sampleCount) {
        await ClockSyncEstimator.delay(20);
      }
    }
    return ClockSyncEstimator.medianFromSamples(samples);
  }

  private static fromRoundTrip(t0: number, t1: number, t2: number, t3: number): SyncSample | undefined {
    if (!Number.isFinite(t0) || !Number.isFinite(t1) || !Number.isFinite(t2) || !Number.isFinite(t3) ||
      t3 < t0 || t2 < t1) {
      return undefined;
    }
    const sample: SyncSample = { offsetMs: ((t1 - t0) + (t2 - t3)) / 2,
      rttMs: (t3 - t0) - (t2 - t1), localMidpointMs: t0 + (t3 - t0) / 2, validSampleCount: 1 };
    return ClockSyncEstimator.isValidSample(sample) ? sample : undefined;
  }

  private static isValidSample(sample: SyncSample): boolean {
    return Number.isFinite(sample.offsetMs) && Number.isFinite(sample.rttMs) && sample.rttMs >= 0 &&
      (sample.localMidpointMs === undefined || Number.isFinite(sample.localMidpointMs)) &&
      (sample.validSampleCount === undefined || (Number.isInteger(sample.validSampleCount) &&
        sample.validSampleCount > 0));
  }

  private static delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
