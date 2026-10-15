import { MonotonicClock } from '../common/MonotonicClock';
import { PING_SAMPLES } from '../common/Constants';
import { PingResponse } from '../protocol/messages';

export interface SyncSample {
  offsetMs: number;
  rttMs: number;
}

// 拟合投影与新测量的 NTP 区间之间允许的额外余量（覆盖两端调度抖动与 ms 取整）。
const CLOCK_FIT_CONSISTENCY_MARGIN_MS: number = 5;
// 权重下限，避免 rtt≈0 的单个结果独占整个拟合。
const CLOCK_FIT_MIN_WEIGHT_RTT_MS: number = 4;

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

  smoothAdjust(next: SyncSample, alpha: number = 0.25): void {
    this.offsetMs = this.offsetMs * (1 - alpha) + next.offsetMs * alpha;
    this.rttMs = next.rttMs;
    this.recordSample(next.offsetMs, next.rttMs);
  }

  /**
   * 记录一次「已按 RTT 过滤」的测量结果，用于 skew 线性拟合。
   * 只能传 medianFromSamples 的输出，不能传单个原始 ping：链路唤醒或排队时的
   * 原始 ping 偏差可达上百毫秒，一旦进入 60s 窗口，getOffsetMs 会在整个窗口期内被拖偏。
   */
  private recordSample(offsetMs: number, rttMs: number): void {
    if (!Number.isFinite(offsetMs) || !Number.isFinite(rttMs) || rttMs < 0) {
      return;
    }
    const now = MonotonicClock.nowMs();
    // NTP 约束：真实 offset 必在 [offset - rtt/2, offset + rtt/2] 内。新测量与拟合投影
    // 超出该范围时，历史窗口已被证伪，继续线性回归只会让新值被旧值稀释。
    if (this.hasSkewFit) {
      const projected = this.getOffsetAt(now);
      const boundMs = rttMs / 2 + CLOCK_FIT_CONSISTENCY_MARGIN_MS;
      if (Math.abs(projected - offsetMs) > boundMs) {
        console.info(`[ClockFitDiag] action=reset projectedOffsetMs=${projected.toFixed(2)} ` +
          `sampleOffsetMs=${offsetMs.toFixed(2)} rttMs=${rttMs.toFixed(2)} boundMs=${boundMs.toFixed(2)} ` +
          `droppedSamples=${this.samples.length}`);
        this.samples = [];
      }
    }
    this.samples.push({ atMs: now, offsetMs: offsetMs, rttMs: rttMs });
    // 只保留最近 60s 内的样本，避免陈旧样本污染拟合。
    const horizon = now - 60000;
    while (this.samples.length > 1 && this.samples[0].atMs < horizon) {
      this.samples.shift();
    }
    this.fitSkew();
  }

  /**
   * 加权最小二乘拟合 offset(t) = a + b*(t - tRef)，b 即两端晶振的相对漂移率。
   * 权重 1/rtt²：单次测量误差上界与 rtt/2 成正比，慢链路结果不能与快链路结果等权。
   */
  private fitSkew(): void {
    const n = this.samples.length;
    if (n < 2) {
      this.hasSkewFit = false;
      return;
    }
    const refAtMs = this.samples[n - 1].atMs;
    let sumW = 0;
    let sumX = 0;
    let sumY = 0;
    let sumXX = 0;
    let sumXY = 0;
    for (const s of this.samples) {
      const rtt = Math.max(CLOCK_FIT_MIN_WEIGHT_RTT_MS, s.rttMs);
      const w = 1 / (rtt * rtt);
      const x = s.atMs - refAtMs;
      const y = s.offsetMs;
      sumW += w;
      sumX += w * x;
      sumY += w * y;
      sumXX += w * x * x;
      sumXY += w * x * y;
    }
    const denom = sumW * sumXX - sumX * sumX;
    if (Math.abs(denom) < 1e-9 * sumW * sumW) {
      this.hasSkewFit = false;
      return;
    }
    const driftRate = (sumW * sumXY - sumX * sumY) / denom; // ms per ms
    const intercept = (sumY - driftRate * sumX) / sumW;
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
    sampleCount: number = PING_SAMPLES
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
