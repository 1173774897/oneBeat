export const DOMAIN: number = 0x0001;
export const TAG: string = 'OneBeat';
export const SESSION_TCP_PORT: number = 9527;
export const PROTOCOL_VERSION: number = 4;
/** 单人和多人共用同一容量；队长也计入总人数。 */
export const SESSION_MAX_MEMBER_COUNT: number = 9;
/** 首次播放和恢复时预留给网络、音频流启动及硬件时间戳锁定的同步时间。 */
export const TRANSPORT_PREROLL_MS: number = 650;
/** 行进中改节拍在持续音频流内切换内容，仍为网络握手与已提交音频缓冲预留充足时间。 */
export const TRANSPORT_RESTART_PREROLL_MS: number = 650;
/** 暂停也发布未来共享时刻，保证所有设备在同一可闻边界切换到底噪。 */
export const TRANSPORT_PAUSE_PREROLL_MS: number = 650;
/** 正式行进前播放的准备拍小节数。 */
export const COUNT_IN_BARS: number = 1;
/** 行进期间更频繁地估算队长时钟，减小设备晶振与网络变化带来的长期漂移。 */
export const RESYNC_INTERVAL_MS: number = 5000;
/** 队员进程被终止且 TCP 未及时回报断开时，队长用于清理成员的失联阈值。 */
export const MEMBER_HEARTBEAT_TIMEOUT_MS: number = 18000;
export const MEMBER_HEARTBEAT_SWEEP_MS: number = 3000;
/** 起拍前采足够多的低延迟样本，同时把总测量时间控制在约 300ms 内。 */
export const PING_SAMPLES: number = 11;
export const TRANSPORT_PREPARE_TIMEOUT_MS: number = 900;
