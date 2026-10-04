export const DOMAIN: number = 0x0001;
export const TAG: string = 'OneBeat';
export const SESSION_TCP_PORT: number = 9527;
export const PROTOCOL_VERSION: number = 2;
/** 给音频渲染器和队员设备预留的同步准备时间，之后立即播放准备拍。 */
export const TRANSPORT_PREROLL_MS: number = 350;
/** 正式行进前播放的准备拍小节数。 */
export const COUNT_IN_BARS: number = 1;
/** 行进期间更频繁地估算队长时钟，减小设备晶振与网络变化带来的长期漂移。 */
export const RESYNC_INTERVAL_MS: number = 5000;
/** 队员进程被终止且 TCP 未及时回报断开时，队长用于清理成员的失联阈值。 */
export const MEMBER_HEARTBEAT_TIMEOUT_MS: number = 18000;
export const MEMBER_HEARTBEAT_SWEEP_MS: number = 3000;
export const PING_SAMPLES: number = 7;
