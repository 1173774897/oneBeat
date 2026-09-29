import { MonotonicClock } from '../common/MonotonicClock';
import { PING_SAMPLES } from '../common/Constants';
import { PingResponse } from '../protocol/messages';

export interface SyncSample {
  offsetMs: number;
  rttMs: number;
}

export class ClockSyncEstimator {
  private offsetMs: number = 0;
  private rttMs: number = 999;

  getOffsetMs(): number {
    return this.offsetMs;
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
  }

  smoothAdjust(nextOffsetMs: number, alpha: number = 0.25): void {
    this.offsetMs = this.offsetMs * (1 - alpha) + nextOffsetMs * alpha;
  }

  static medianFromSamples(samples: SyncSample[]): SyncSample {
    if (samples.length === 0) {
      return { offsetMs: 0, rttMs: 999 };
    }
    const sorted = [...samples].sort((a, b) => a.rttMs - b.rttMs);
    const trimmed = sorted.length > 4 ? sorted.slice(0, sorted.length - 2) : sorted;
    const offsets = trimmed.map((s) => s.offsetMs).sort((a, b) => a - b);
    const rtts = trimmed.map((s) => s.rttMs).sort((a, b) => a - b);
    const mid = Math.floor(offsets.length / 2);
    return {
      offsetMs: offsets.length % 2 === 0 ? (offsets[mid - 1] + offsets[mid]) / 2 : offsets[mid],
      rttMs: rtts.length % 2 === 0 ? (rtts[mid - 1] + rtts[mid]) / 2 : rtts[mid]
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
      await ClockSyncEstimator.delay(40);
    }
    return ClockSyncEstimator.medianFromSamples(samples);
  }

  private static delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
