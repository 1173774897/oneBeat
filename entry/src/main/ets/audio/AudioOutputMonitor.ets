import { audio } from '@kit.AudioKit';

// §5.6 绝对延迟补偿（自动估算）：蓝牙 A2DP 空中链路 + 耳机 DAC 的典型可闻时延（编解码查表）。
// SBC ~180ms | AAC ~150ms | LDAC ~120~180ms | aptX LL ~40ms | L2HC ~40ms | LC3(LE Audio) ~30ms。
// 关键：getLatency(LATENCY_TYPE_ALL) 对无线路由已返回「含蓝牙链路」的估算时延（官方文档注明
// 无线设备估算可能存在误差）。实测在蓝牙耳机上再加 180ms 会导致声音明显超前画面，故默认额外补偿
// 置 0（宁可略微滞后、不要超前）。若某设备 getLatency 明显低估蓝牙链路，再按需调大该值。
const BLUETOOTH_LINK_LATENCY_DEFAULT_MS: number = 0;
const METRONOME_RENDERER_INFO: audio.AudioRendererInfo = {
  usage: audio.StreamUsage.STREAM_USAGE_GAME,
  rendererFlags: 0
};

interface OutputRouteSnapshot {
  wireless: boolean;
  builtInSpeaker: boolean;
  signature: string;
}

/**
 * 监听节拍 renderer 的首选输出，识别是否走蓝牙或星闪无线耳机。
 * 无线路由才允许使用手工校准；外放与有线路由始终回到平台 getLatency。
 */
export class AudioOutputMonitor {
  private static routing: audio.AudioRoutingManager | undefined = undefined;
  private static listener: ((bluetoothActive: boolean, routeSignature: string) => void) | undefined = undefined;
  private static started: boolean = false;
  private static deviceChangeSubscribed: boolean = false;
  private static preferredRouteSubscribed: boolean = false;
  private static readonly deviceChangeListener = (_action: audio.DeviceChangeAction): void => {
    AudioOutputMonitor.notify();
  };
  private static readonly preferredRouteListener = (_devices: audio.AudioDeviceDescriptors): void => {
    AudioOutputMonitor.notify();
  };

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

  /**
   * 同步查询当前输出设备是否为蓝牙/星闪无线输出。
   * 覆盖三类 deviceType：经典蓝牙媒体 BLUETOOTH_A2DP(8)、蓝牙通话 BLUETOOTH_SCO(7)、
   * 星闪 NEARLINK(31)。星闪(NearLink) 设备在未做 declareDeviceTypesCompatibility 声明时
   * （API < 26）会以 BLUETOOTH_SCO(7) 作为匿名类型返回；华为 L2HC 编码常走星闪链路，
   * 因此仅判断 BLUETOOTH_A2DP 会把 L2HC/星闪耳机误判为外放。
   */
  private static readPreferredOutputRoute(): OutputRouteSnapshot {
    const routing = AudioOutputMonitor.ensureRouting();
    if (routing === undefined) {
      return { wireless: false, builtInSpeaker: false, signature: 'unavailable' };
    }
    try {
      // Query the preferred route for the same GAME usage as MetronomeEngine.
      // A connected headset may coexist with speaker output, so the general
      // connected-device list cannot decide whether manual calibration applies.
      const devices = routing.getPreferredOutputDeviceForRendererInfoSync(METRONOME_RENDERER_INFO);
      const types: number[] = [];
      const identities: string[] = [];
      let wireless = false;
      let builtInSpeaker = devices.length > 0;
      for (let i = 0; i < devices.length; i++) {
        const type = devices[i].deviceType;
        types.push(type);
        identities.push(`${type}:${devices[i].id}`);
        if (type === audio.DeviceType.BLUETOOTH_A2DP ||
          type === audio.DeviceType.BLUETOOTH_SCO ||
          type === audio.DeviceType.NEARLINK) {
          wireless = true;
        }
        if (type !== audio.DeviceType.SPEAKER) {
          builtInSpeaker = false;
        }
      }
      console.info(`[A2DP-DIAG] current output deviceTypes=[${types.join(',')}]`);
      identities.sort();
      return {
        wireless,
        builtInSpeaker,
        signature: identities.length > 0 ? identities.join('|') : 'none'
      };
    } catch (e) {
      console.warn(`AudioOutputMonitor preferred output query failed: ${e}`);
      return { wireless: false, builtInSpeaker: false, signature: 'unavailable' };
    }
  }

  static isBluetoothA2dpActive(): boolean {
    return AudioOutputMonitor.readPreferredOutputRoute().wireless;
  }

  /** Input-side mic calibration is valid only against the phone's built-in loudspeaker. */
  static isBuiltInSpeakerActive(): boolean {
    return AudioOutputMonitor.readPreferredOutputRoute().builtInSpeaker;
  }

  /** 开始监听输出设备切换；首次及每次切换都会回调当前是否为无线耳机。 */
  static start(listener: (bluetoothActive: boolean, routeSignature: string) => void): void {
    AudioOutputMonitor.listener = listener;
    const routing = AudioOutputMonitor.ensureRouting();
    if (routing === undefined) {
      return;
    }
    if (!AudioOutputMonitor.started) {
      try {
        routing.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG,
          AudioOutputMonitor.deviceChangeListener);
        AudioOutputMonitor.deviceChangeSubscribed = true;
      } catch (e) {
        console.warn(`AudioOutputMonitor on deviceChange failed: ${e}`);
      }
      try {
        routing.on('preferOutputDeviceChangeForRendererInfo', METRONOME_RENDERER_INFO,
          AudioOutputMonitor.preferredRouteListener);
        AudioOutputMonitor.preferredRouteSubscribed = true;
      } catch (e) {
        console.warn(`AudioOutputMonitor on preferred route change failed: ${e}`);
      }
      AudioOutputMonitor.started = AudioOutputMonitor.deviceChangeSubscribed ||
        AudioOutputMonitor.preferredRouteSubscribed;
    }
    AudioOutputMonitor.notify();
  }

  static stop(): void {
    const routing = AudioOutputMonitor.routing;
    if (routing !== undefined && AudioOutputMonitor.deviceChangeSubscribed) {
      try {
        routing.off('deviceChange', AudioOutputMonitor.deviceChangeListener);
      } catch (e) {
        console.warn(`AudioOutputMonitor off deviceChange failed: ${e}`);
      }
    }
    if (routing !== undefined && AudioOutputMonitor.preferredRouteSubscribed) {
      try {
        routing.off('preferOutputDeviceChangeForRendererInfo', AudioOutputMonitor.preferredRouteListener);
      } catch (e) {
        console.warn(`AudioOutputMonitor off preferred route change failed: ${e}`);
      }
    }
    AudioOutputMonitor.started = false;
    AudioOutputMonitor.deviceChangeSubscribed = false;
    AudioOutputMonitor.preferredRouteSubscribed = false;
    AudioOutputMonitor.listener = undefined;
  }

  private static notify(): void {
    const route = AudioOutputMonitor.readPreferredOutputRoute();
    if (AudioOutputMonitor.listener !== undefined) {
      AudioOutputMonitor.listener(route.wireless, route.signature);
    }
  }

  /**
   * 未做手工校准时的无线链路兜底增量。默认返回 0：getLatency(LATENCY_TYPE_ALL)
   * 已包含蓝牙链路估算；仅当某设备明显低估时再调大该常量。
   */
  static estimateBluetoothLinkLatencyMs(): number {
    return BLUETOOTH_LINK_LATENCY_DEFAULT_MS;
  }
}
