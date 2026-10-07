import { MonotonicClock } from '../common/MonotonicClock';
import { PING_SAMPLES } from '../common/Constants';
import { PingResponse } from '../protocol/messages';

export interface SyncSample {
  offsetMs: number;
  rttMs: number;
}

interface TimedOffsetSample {
  atMs: number;
  offsetMs: number;
  rttMs: number;
}

export class ClockSyncEstimator {
  private offsetMs: number = 0;
  private rttMs: number = 999;
  // skew 线性拟合状态：offset(t) ≈ skewRefOffsetMs + skewPpm * (t - skewRefAtMs) / 1e6
  private samples: TimedOffsetSample[] = [];
  private skewPpm: number = 0;
  private skewRefAtMs: number = 0;
  private skewRefOffsetMs: number = 0;
  private hasSkewFit: boolean = false;

  getOffsetMs(): number {
    return this.getOffsetAt(MonotonicClock.nowMs());
  }

  /** skew 线性投影后的时钟偏移（leader ≈ client + offset），不含声学延迟补偿。 */
  getOffsetAt(atMs: number): number {
    if (!this.hasSkewFit) {
      return this.offsetMs;
    }
    return this.skewRefOffsetMs + this.skewPpm * (atMs - this.skewRefAtMs) / 1e6;
  }

  getRttMs(): number {
    return this.rttMs;
  }

  getQualityLabel(): string {
    if (this.rttMs < 50) {
      return 'good';
    }
    if (this.rttMs < 150) {
      return 'fair';
    }
    return 'poor';
  }

  /** NTP-style offset: leaderMono ≈ clientMono + offsetMs */
  recordRoundTrip(clientSendMs: number, serverRecvMs: number, serverSendMs: number, clientRecvMs: number): void {
    const offset = ((serverRecvMs - clientSendMs) + (serverSendMs - clientRecvMs)) / 2;
    const rtt = (clientRecvMs - clientSendMs) - (serverSendMs - serverRecvMs);
    this.applySample({ offsetMs: offset, rttMs: rtt });
  }

  applySample(sample: SyncSample): void {
    this.offsetMs = sample.offsetMs;
    this.rttMs = sample.rttMs;
    this.recordSample(sample.offsetMs, sample.rttMs);
  }

  smoothAdjust(nextOffsetMs: number, alpha: number = 0.25): void {
    this.offsetMs = this.offsetMs * (1 - alpha) + nextOffsetMs * alpha;
    this.recordSample(nextOffsetMs, this.rttMs);
  }

  /** 记录带时间戳的样本，用于 skew 线性拟合。 */
  recordSample(offsetMs: number, rttMs: number): void {
    const now = MonotonicClock.nowMs();
    this.samples.push({ atMs: now, offsetMs: offsetMs, rttMs: rttMs });
    // 只保留最近 60s 内的样本，避免陈旧样本污染拟合。
    const horizon = now - 60000;
    while (this.samples.length > 1 && this.samples[0].atMs < horizon) {
      this.samples.shift();
    }
    this.fitSkew();
  }

  /** 最小二乘线性回归拟合 offset(t) = a + b*(t - tRef)，b 即两端晶振的相对漂移率。 */
  private fitSkew(): void {
    const n = this.samples.length;
    if (n < 2) {
      this.hasSkewFit = false;
      return;
    }
    const refAtMs = this.samples[n - 1].atMs;
    let sumX = 0;
    let sumY = 0;
    let sumXX = 0;
    let sumXY = 0;
    for (const s of this.samples) {
      const x = s.atMs - refAtMs;
      const y = s.offsetMs;
      sumX += x;
      sumY += y;
      sumXX += x * x;
      sumXY += x * y;
    }
    const denom = n * sumXX - sumX * sumX;
    if (Math.abs(denom) < 1e-9) {
      this.hasSkewFit = false;
      return;
    }
    const driftRate = (n * sumXY - sumX * sumY) / denom; // ms per ms
    const intercept = (sumY - driftRate * sumX) / n;
    this.skewRefAtMs = refAtMs;
    this.skewRefOffsetMs = intercept;
    this.skewPpm = driftRate * 1e6;
    this.hasSkewFit = true;
  }

  static medianFromSamples(samples: SyncSample[]): SyncSample {
    if (samples.length === 0) {
      return { offsetMs: 0, rttMs: 999 };
    }
    // 采样过滤：丢弃无效样本（负 RTT 表示两端单调时钟跳变，不可信）。
    const valid = samples.filter((s) => Number.isFinite(s.rttMs) && s.rttMs >= 0 &&
      Number.isFinite(s.offsetMs));
    if (valid.length === 0) {
      return { offsetMs: 0, rttMs: 999 };
    }
    // 队列延迟是 Wi-Fi P2P 时钟误差的主要来源：按 RTT 升序，优先使用最快样本。
    const sorted = [...valid].sort((a, b) => a.rttMs - b.rttMs);
    // 取最快的至多一半（至少 1 个、至多 3 个）样本做中位数，抑制异常包。
    const take = Math.max(1, Math.min(3, Math.ceil(sorted.length / 2)));
    const candidates = sorted.slice(0, take);
    const offsets = candidates.map((s) => s.offsetMs).sort((a, b) => a - b);
    const mid = Math.floor(offsets.length / 2);
    return {
      offsetMs: offsets.length % 2 === 0 ? (offsets[mid - 1] + offsets[mid]) / 2 : offsets[mid],
      rttMs: candidates[0].rttMs
    };
  }

  static async measureWithSender(
    sendPing: (id: string, clientMono: number) => Promise<PingResponse>,
    sampleCount: number = PING_SAMPLES,
    onSample?: (offsetMs: number, rttMs: number) => void
  ): Promise<SyncSample> {
    const samples: SyncSample[] = [];
    for (let i = 0; i < sampleCount; i++) {
      const t0 = MonotonicClock.nowMs();
      const id = `ping-${i}-${t0}`;
      const response = await sendPing(id, t0);
      const t3 = MonotonicClock.nowMs();
      const t1 = response.serverMono;
      const t2 = response.leaderMono;
      const offset = ((t1 - t0) + (t2 - t3)) / 2;
      const rtt = (t3 - t0) - (t2 - t1);
      samples.push({ offsetMs: offset, rttMs: rtt });
      if (onSample !== undefined) {
        onSample(offset, rtt);
      }
      if (i + 1 < sampleCount) {
        await ClockSyncEstimator.delay(20);
      }
    }
    return ClockSyncEstimator.medianFromSamples(samples);
  }

  private static delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
