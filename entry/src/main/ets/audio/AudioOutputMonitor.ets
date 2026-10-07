import { audio } from '@kit.AudioKit';

/**
 * 监听当前音频输出设备，识别是否走蓝牙 A2DP（普通蓝牙媒体）。
 *
 * 背景：普通蓝牙 A2DP（SBC/AAC）可闻时延约 150~250ms，且
 * AudioRenderer.getLatency() 通常不完整上报这段链路时延，导致蓝牙端与外放端
 * 之间存在锁钟/相位锁定无法消除的系统性偏差。检测到后应提示用户改用外放、
 * 有线耳机，或低时延（aptX LL / LC3 / LHDC-LL）耳机。
 */
export class AudioOutputMonitor {
  private static routing: audio.AudioRoutingManager | undefined = undefined;
  private static listener: ((bluetoothActive: boolean) => void) | undefined = undefined;
  private static started: boolean = false;

  private static ensureRouting(): audio.AudioRoutingManager | undefined {
    if (AudioOutputMonitor.routing !== undefined) {
      return AudioOutputMonitor.routing;
    }
    try {
      AudioOutputMonitor.routing = audio.getAudioManager().getRoutingManager();
    } catch (e) {
      console.warn(`AudioOutputMonitor getRoutingManager failed: ${e}`);
    }
    return AudioOutputMonitor.routing;
  }

  /** 同步查询当前输出设备是否包含蓝牙 A2DP。 */
  static isBluetoothA2dpActive(): boolean {
    const routing = AudioOutputMonitor.ensureRouting();
    if (routing === undefined) {
      return false;
    }
    try {
      const devices = routing.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
      for (const device of devices) {
        if (device.deviceType === audio.DeviceType.BLUETOOTH_A2DP) {
          return true;
        }
      }
      return false;
    } catch (e) {
      console.warn(`AudioOutputMonitor getDevicesSync failed: ${e}`);
      return false;
    }
  }

  /** 开始监听输出设备切换；首次及每次切换都会回调当前是否为蓝牙 A2DP。 */
  static start(listener: (bluetoothActive: boolean) => void): void {
    AudioOutputMonitor.listener = listener;
    const routing = AudioOutputMonitor.ensureRouting();
    if (routing === undefined) {
      return;
    }
    if (!AudioOutputMonitor.started) {
      try {
        routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG,
          (_action: audio.DeviceChangeAction) => {
            AudioOutputMonitor.notify();
          });
        AudioOutputMonitor.started = true;
      } catch (e) {
        console.warn(`AudioOutputMonitor on deviceChange failed: ${e}`);
      }
    }
    AudioOutputMonitor.notify();
  }

  static stop(): void {
    const routing = AudioOutputMonitor.routing;
    if (routing !== undefined && AudioOutputMonitor.started) {
      try {
        routing.off('deviceChange');
      } catch (e) {
        console.warn(`AudioOutputMonitor off deviceChange failed: ${e}`);
      }
    }
    AudioOutputMonitor.started = false;
    AudioOutputMonitor.listener = undefined;
  }

  private static notify(): void {
    const active = AudioOutputMonitor.isBluetoothA2dpActive();
    if (AudioOutputMonitor.listener !== undefined) {
      AudioOutputMonitor.listener(active);
    }
  }
}
