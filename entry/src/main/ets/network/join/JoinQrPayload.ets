import {
  parseP2pRoomInvitation,
  P2pRoomInvitation,
  validateP2pRoomInvitation
} from '../p2p/P2pInvitation';

export type JoinQrPayload = P2pRoomInvitation;

export function parseJoinQrPayload(raw: string): JoinQrPayload {
  return parseP2pRoomInvitation(raw);
}

export function joinCodeFromPayload(payload: JoinQrPayload): string {
  validateP2pRoomInvitation(payload);
  return payload.code;
}
