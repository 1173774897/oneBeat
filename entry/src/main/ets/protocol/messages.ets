import { PROTOCOL_VERSION } from '../common/Constants';

export type MessageType =
  | 'PING'
  | 'PONG'
  | 'SYNC_RESULT'
  | 'SESSION_SNAPSHOT'
  | 'TRANSPORT'
  | 'TRANSPORT_PAUSE'
  | 'TRANSPORT_RESUME'
  | 'MEMBER_UPDATE'
  | 'CLIENT_HELLO'
  | 'CLIENT_LEAVE'
  | 'LOBBY_READY';

export type TransportState = 'idle' | 'countdown' | 'playing' | 'paused';

export interface SessionMember {
  id: string;
  displayName: string;
  avatarKey: string;
  /** 回声影偶进入舞台后由队长分配；准备页不展示该颜色。 */
  colorSlot?: number;
  /** 队员在组队大厅已点「准备」 */
  lobbyReady?: boolean;
  rttMs: number;
  offsetMs: number;
}

export interface SessionSnapshotPayload {
  sessionId: string;
  bpm: number;
  beatsPerBar: number;
  beatUnit?: number;
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

export interface LobbyReadyPayload {
  ready: boolean;
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
