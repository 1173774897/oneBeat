import { PROTOCOL_VERSION } from '../common/Constants';
import { BeatPointState } from '../common/MeterModel';

export type MessageType =
  | 'PING'
  | 'PONG'
  | 'SYNC_RESULT'
  | 'SESSION_SNAPSHOT'
  | 'TRANSPORT'
  | 'TRANSPORT_PREPARE'
  | 'TRANSPORT_READY'
  | 'TRANSPORT_PAUSE'
  | 'TRANSPORT_RESUME'
  | 'MEMBER_UPDATE'
  | 'CLIENT_HELLO'
  | 'CLIENT_LEAVE'
  | 'SESSION_DISBANDED'
  | 'SESSION_DISBANDED_ACK'
  | 'RANDOM_PREVIEW_COMPLETE'
  | 'LOBBY_READY'
  | 'BLUETOOTH_CALIBRATION_STATE';

export type TransportState = 'idle' | 'countdown' | 'playing' | 'paused';

export interface SessionMember {
  id: string;
  displayName: string;
  avatarKey: string;
  /** 随机角色由队长在大厅确定；大厅只显示剪影，行进页才读取真身。 */
  resolvedAvatarKey?: string;
  /** 每次随机抽取的队长版本；同一人物再次抽中也必须使用新版本。 */
  randomDrawId?: number;
  /** 胶片完成后统一显示剪影的队长单调时刻，不提前揭晓配色。 */
  randomAvatarRevealAtLeaderMs?: number;
  /** 随机角色的配色下标由队长在大厅分配，同角色优先不重复。 */
  colorSlot?: number;
  /** 队员在组队大厅已点「准备」 */
  lobbyReady?: boolean;
  /** 当前设备正在进行耳机延迟打卡；仅用于大厅的临时状态提示。 */
  bluetoothCalibrating?: boolean;
  rttMs: number;
  offsetMs: number;
}

export interface SessionSnapshotPayload {
  sessionId: string;
  bpm: number;
  beatsPerBar: number;
  beatUnit?: number;
  beatPointStates?: BeatPointState[];
  rhythm?: number;
  drumProgram?: string;
  sceneKey?: string;
  soundId: number;
  state: TransportState;
  leaderMonoMs: number;
  members: SessionMember[];
  beatIndex: number;
  /** 队长已带队离开大厅 */
  lobbyDeparted?: boolean;
}

export interface TransportPayload {
  startAtLeaderMonoMs: number;
  countdownMs: number;
  beatIndex: number;
  countInBeats?: number;
}

export interface TransportPreparePayload {
  id: string;
  /** 新起拍要求明确成功，缺省保留旧队长有界等待后继续的协议行为。 */
  requireClockReady?: boolean;
  /** 严格请求的 ACK 必须明确报告测量成功，失败不能冒充准备完成。 */
  clockReady?: boolean;
}

export interface TransportPausePayload {
  pauseAtLeaderMonoMs: number;
  beatIndex: number;
}

export interface TransportResumePayload {
  resumeAtLeaderMonoMs: number;
  beatIndex: number;
  countInBeats?: number;
}

export interface PingPayload {
  id: string;
  clientMono: number;
  serverMono?: number;
}

export interface PongPayload {
  id: string;
  clientMono: number;
  serverMono: number;
  leaderMono: number;
}

export interface PingResponse {
  serverMono: number;
  leaderMono: number;
}

export interface ClientHelloPayload {
  displayName: string;
  avatarKey: string;
  /** 6 位码只用于附近房间定位，TCP 准入还必须校验下面的高熵令牌。 */
  joinCode?: string;
  roomId?: string;
  authToken?: string;
  protocolVersion?: number;
  nonce?: string;
}

export interface ClientLeavePayload {
  reason: string;
}

export interface SessionDisbandedPayload {
  reason: 'leader_exit';
}

export interface SessionDisbandedAckPayload {
  received: boolean;
}

export interface LobbyReadyPayload {
  ready: boolean;
}

export interface BluetoothCalibrationStatePayload {
  active: boolean;
}

/** 完成通知只携带抽取版本；队长从已认证连接推断队员与人物。 */
export interface RandomPreviewCompletePayload {
  drawId: number;
}

export interface MemberAvatarPayload {
  memberId: string;
  avatarKey: string;
}

export interface SyncResultPayload {
  offsetMs: number;
  rttMs: number;
  quality: string;
}

export interface WireMessage {
  v: number;
  type: MessageType;
  payload: object;
}

export function createMessage(type: MessageType, payload: object): WireMessage {
  return {
    v: PROTOCOL_VERSION,
    type: type,
    payload: payload
  };
}
