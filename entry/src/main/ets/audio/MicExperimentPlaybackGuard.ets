import { MicExperimentPlaybackSnapshot } from './MetronomeEngine';

/** Fail closed on an observable output change; this is not an acoustic sync certificate. */
export function micExperimentPlaybackProblem(before: MicExperimentPlaybackSnapshot,
  current: MicExperimentPlaybackSnapshot): string {
  if (!current.running || !current.started || current.state !== before.state) {
    return '实验播放被暂停或中断，本轮已停止';
  }
  if (current.rendererEpoch !== before.rendererEpoch || current.streamId !== before.streamId ||
    current.physicalStartCount !== before.physicalStartCount) {
    return '播放实例或物理起点发生变化，本轮已停止';
  }
  if (current.interruptCount !== before.interruptCount) {
    return '检测到音频焦点变化，本轮已停止';
  }
  if (before.underflowCount >= 0 && current.underflowCount >= 0 &&
    current.underflowCount !== before.underflowCount) {
    return '检测到播放缓冲不足或计数重置，本轮已停止';
  }
  if (current.sampledAtMonoMs - current.lastWriteProgressMs > 800) {
    return '播放数据超过 800ms 未推进，本轮已停止';
  }
  if (before.rawFrame >= 0 && current.rawFrame >= 0 &&
    before.timestampMonoMs > 0 && current.timestampMonoMs > 0) {
    const elapsed = current.timestampMonoMs - before.timestampMonoMs;
    // This renderer is fixed at 44.1kHz. Allow its documented ~20ms frame
    // quantization; a coarse jump is evidence of a changed clock, not an offset
    // to repair. Missing anchors remain explicitly unknown in the report.
    const frameElapsed = (current.rawFrame - before.rawFrame) * 1000 / 44100;
    if (current.rawFrame < before.rawFrame || elapsed < -3 || Math.abs(frameElapsed - elapsed) > 40) {
      return '输出帧与硬件时间戳出现跳变，本轮已停止';
    }
  }
  if (current.outputDevices.length > 0 && current.outputDevices !== before.outputDevices) {
    return '声音输出设备发生变化，本轮已停止';
  }
  if (before.audioScene >= 0 && current.audioScene >= 0 && current.audioScene !== before.audioScene) {
    return '系统音频场景发生变化，本轮已停止';
  }
  return '';
}
