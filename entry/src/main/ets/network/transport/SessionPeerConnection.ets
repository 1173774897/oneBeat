import { WireMessage } from '../../protocol/messages';

/** SessionController 使用的最小 TCP 连接接口。 */
export interface SessionPeerConnection {
  readonly id: string;
  readonly isRoomAuthenticated?: boolean;
  send(message: WireMessage): Promise<void>;
  close(): Promise<void>;
}
