import { MicExperimentPlaybackSnapshot } from './MetronomeEngine';

const RECORDING_PLAYBACK_POLL_MS: number = 250;
const RECORDING_HARDWARE_LATENCY_CHANGE_MS: number = 10;
const RECORDING_WRITE_STALL_MS: number = 1500;

export type RecordingPlaybackSnapshotReader =
  (includeOutputDetails: boolean) => MicExperimentPlaybackSnapshot | undefined;

function isActiveTransport(state: string): boolean {
  return state === 'countdown' || state === 'playing';
}

function samePhysicalStream(before: MicExperimentPlaybackSnapshot,
  current: MicExperimentPlaybackSnapshot): boolean {
  return before.rendererEpoch === current.rendererEpoch && before.streamId === current.streamId &&
    before.physicalStartCount === current.physicalStartCount;
}

/**
 * Read-only protection around capture startup/shutdown. The caller owns the
 * session identity and must return undefined if that original session ends.
 * An unsafe observation stops recording through onUnsafe, never the renderer.
 * This detects observable output changes, not an acoustic synchronization proof.
 */
export class RecordingPlaybackObserver {
  private timer: number = -1;
  private started: boolean = false;
  private reason: string = '';
  private observedSession: boolean = false;
  private lastTransport: string = '';
  private lastSnapshot: MicExperimentPlaybackSnapshot | undefined = undefined;
  private activeBaseline: MicExperimentPlaybackSnapshot | undefined = undefined;
  private activeUnderflowBaseline: number = -1;
  private outputDevices: string = '';
  private audioScene: number = -1;
  private hardwareLatencyMs: number = -1;
  private readonly readSnapshot: RecordingPlaybackSnapshotReader;
  private readonly readTransportState: () => string;
  private readonly onUnsafe: (reason: string) => void;

  constructor(readSnapshot: RecordingPlaybackSnapshotReader,
    readTransportState: () => string, onUnsafe: (reason: string) => void) {
    this.readSnapshot = readSnapshot;
    this.readTransportState = readTransportState;
    this.onUnsafe = onUnsafe;
  }

  /** Establish before native capture starts; a missing session is explicitly unobserved. */
  start(): string {
    this.dispose();
    this.started = true;
    this.reason = '';
    this.observedSession = false;
    this.lastTransport = '';
    this.lastSnapshot = undefined;
    this.activeBaseline = undefined;
    this.activeUnderflowBaseline = -1;
    this.outputDevices = '';
    this.audioScene = -1;
    this.hardwareLatencyMs = -1;
    const problem = this.checkpoint('before-native-start');
    if (problem.length === 0) {
      this.timer = setInterval(() => { this.observe('poll', false); }, RECORDING_PLAYBACK_POLL_MS);
    }
    return problem;
  }

  /** Slow route/scene/latency queries belong only at capture lifecycle boundaries. */
  checkpoint(phase: string): string {
    if (!this.started) { return this.reason; }
    return this.observe(phase, true);
  }

  dispose(): void {
    this.started = false;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private observe(phase: string, includeOutputDetails: boolean): string {
    if (!this.started || this.reason.length > 0) { return this.reason; }
    let current: MicExperimentPlaybackSnapshot | undefined;
    let transport: string;
    try {
      current = this.readSnapshot(includeOutputDetails);
      transport = this.readTransportState();
    } catch (_error) {
      return this.fail('无法确认伴奏播放状态，录制已结束');
    }
    if (current === undefined) {
      if (this.observedSession) { return this.fail('练习会话已结束，录制已结束'); }
      if (includeOutputDetails) { console.info(`[RecordingOutputDiag] phase=${phase} session=none`); }
      return '';
    }
    this.observedSession = true;
    const previous = this.lastSnapshot;
    if (includeOutputDetails) {
      // Report platform hardware and queue latency separately. Queue depth can
      // vary naturally; it must never become a saved headphone calibration.
      console.info(`[RecordingOutputDiag] phase=${phase} transport=${transport} ` +
        `rendererEpoch=${current.rendererEpoch} streamId=${current.streamId} ` +
        `physicalStarts=${current.physicalStartCount} running=${current.running} started=${current.started} ` +
        `state=${current.state} output=${current.outputDevices || 'unknown'} scene=${current.audioScene} ` +
        `hardwareMs=${current.latencyHardwareMs} softwareMs=${current.latencySoftwareMs} ` +
        `allMs=${current.latencyAllMs} interrupts=${current.interruptCount} ` +
        `underflows=${current.underflowCount} rawFrame=${current.rawFrame} ` +
        `timestampMs=${current.timestampMonoMs} productionFrame=${current.productionFrame} ` +
        `productionQueryMs=${current.productionClockQueryMonoMs} ` +
        `transportStartMs=${current.transportStartLocalMs} beatOrigin=${current.transportStartBeatIndex} ` +
        `bpm=${current.transportBpm} compensationMs=${current.transportOutputCompensationMs} ` +
        `sharedOffsetMs=${current.sharedClockOffsetMs}`);
    }
    if (previous !== undefined && current.interruptCount !== previous.interruptCount) {
      return this.fail('检测到伴奏音频焦点变化，录制已结束');
    }
    if (current.outputDevices.length > 0 && current.outputDevices !== 'unavailable') {
      const outputDevices = current.outputDevices.split(',').sort().join(',');
      if (this.outputDevices.length > 0 && outputDevices !== this.outputDevices) {
        return this.fail('伴奏输出设备已切换，录制已结束');
      }
      this.outputDevices = outputDevices;
    }
    if (current.audioScene >= 0) {
      if (this.audioScene >= 0 && current.audioScene !== this.audioScene) {
        return this.fail('系统音频场景已变化，录制已结束');
      }
      this.audioScene = current.audioScene;
    }
    if (Number.isFinite(current.latencyHardwareMs) && current.latencyHardwareMs >= 0) {
      if (this.hardwareLatencyMs >= 0 &&
        Math.abs(current.latencyHardwareMs - this.hardwareLatencyMs) >= RECORDING_HARDWARE_LATENCY_CHANGE_MS) {
        return this.fail('伴奏硬件输出延迟已变化，录制已结束');
      }
      // Compare every boundary to the first known value, so several smaller
      // changes cannot conceal a total 10ms displacement during one recording.
      if (this.hardwareLatencyMs < 0) { this.hardwareLatencyMs = current.latencyHardwareMs; }
    }

    const active = isActiveTransport(transport);
    const wasActive = isActiveTransport(this.lastTransport);
    if (!active || !wasActive) {
      // Leader/member pause, resume and the initial countdown are legitimate
      // transport actions. Acquire their next running stream, without asking
      // the session to pause, reschedule, recover or refresh calibration.
      this.activeBaseline = undefined;
      this.activeUnderflowBaseline = -1;
    }
    const baseline = this.activeBaseline;
    if (active && baseline !== undefined) {
      if (!samePhysicalStream(baseline, current)) {
        return this.fail('伴奏播放实例或物理起点已变化，录制已结束');
      }
      if (!current.running || !current.started || current.state !== baseline.state) {
        return this.fail('伴奏播放发生中断，录制已结束');
      }
      if (this.activeUnderflowBaseline >= 0 && current.underflowCount >= 0 &&
        current.underflowCount !== this.activeUnderflowBaseline) {
        return this.fail('检测到伴奏播放缓冲不足，录制已结束');
      }
      if (this.activeUnderflowBaseline < 0 && current.underflowCount >= 0) {
        this.activeUnderflowBaseline = current.underflowCount;
      }
      if (current.sampledAtMonoMs - current.lastWriteProgressMs > RECORDING_WRITE_STALL_MS) {
        return this.fail('伴奏播放数据未持续推进，录制已结束');
      }
      if (previous !== undefined && samePhysicalStream(previous, current) &&
        previous.rawFrame >= 0 && current.rawFrame >= 0 &&
        previous.timestampMonoMs > 0 && current.timestampMonoMs > 0) {
        const timeMs = current.timestampMonoMs - previous.timestampMonoMs;
        const frameMs = (current.rawFrame - previous.rawFrame) * 1000 / 44100;
        // The existing production renderer is fixed at 44.1kHz and hardware
        // timestamps can quantize by ~20ms. Detect coarse jumps, not jitter.
        if (current.rawFrame < previous.rawFrame || timeMs < -3 || Math.abs(frameMs - timeMs) > 40) {
          return this.fail('伴奏输出时钟出现跳变，录制已结束');
        }
      }
    }
    if (active && this.activeBaseline === undefined && current.running && current.started) {
      this.activeBaseline = current;
      this.activeUnderflowBaseline = current.underflowCount;
    }
    this.lastSnapshot = current;
    this.lastTransport = transport;
    return '';
  }

  private fail(reason: string): string {
    if (this.reason.length > 0) { return this.reason; }
    this.reason = reason;
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    console.warn(`[RecordingOutputDiag] unsafe=${reason}`);
    this.onUnsafe(reason);
    return reason;
  }
}
