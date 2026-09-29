import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PROTOCOL_VERSION, SESSION_TCP_PORT } from '../../common/Constants';

export const P2P_INVITATION_FORMAT_VERSION: number = 3;
const INVITATION_LIFETIME_MS: number = 6 * 60 * 60 * 1000;
const PASSPHRASE_ALPHABET: string = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

export interface P2pRoomInvitation {
  v: number;
  role: string;
  roomId: string;
  code: string;
  groupName: string;
  passphrase: string;
  authToken: string;
  protocolVersion: number;
  expiresAt: number;
  port: number;
  leaderDeviceName?: string;
}

function randomBytes(length: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(length).data;
}

function bytesToHex(bytes: Uint8Array): string {
  let value = '';
  for (let i = 0; i < bytes.length; i++) {
    value += bytes[i].toString(16).padStart(2, '0');
  }
  return value;
}

function randomAlphabetText(length: number): string {
  const bytes = randomBytes(length);
  let value = '';
  for (let i = 0; i < length; i++) {
    value += PASSPHRASE_ALPHABET.charAt(bytes[i] % PASSPHRASE_ALPHABET.length);
  }
  return value;
}

function randomJoinCode(): string {
  const bytes = randomBytes(4);
  const value = (((bytes[0] << 24) >>> 0) + (bytes[1] << 16) + (bytes[2] << 8) + bytes[3]) >>> 0;
  return `${100000 + value % 900000}`;
}

export function createP2pRoomInvitation(): P2pRoomInvitation {
  return {
    v: P2P_INVITATION_FORMAT_VERSION,
    role: 'join',
    roomId: bytesToHex(randomBytes(16)),
    code: randomJoinCode(),
    groupName: `DIRECT-OB-${randomAlphabetText(8)}`,
    passphrase: randomAlphabetText(16),
    authToken: bytesToHex(randomBytes(32)),
    protocolVersion: PROTOCOL_VERSION,
    expiresAt: Date.now() + INVITATION_LIFETIME_MS,
    port: SESSION_TCP_PORT
  };
}

export function randomAuthNonce(): string {
  return bytesToHex(randomBytes(16));
}

export function invitationWithGroupCredentials(
  invitation: P2pRoomInvitation,
  groupName: string,
  passphrase: string,
  leaderDeviceName: string
): P2pRoomInvitation {
  return {
    v: invitation.v,
    role: invitation.role,
    roomId: invitation.roomId,
    code: invitation.code,
    groupName,
    passphrase,
    authToken: invitation.authToken,
    protocolVersion: invitation.protocolVersion,
    expiresAt: invitation.expiresAt,
    port: invitation.port,
    leaderDeviceName
  };
}

export function parseP2pRoomInvitation(raw: string): P2pRoomInvitation {
  const invitation = JSON.parse(raw) as P2pRoomInvitation;
  validateP2pRoomInvitation(invitation);
  return invitation;
}

export function validateP2pRoomInvitation(invitation: P2pRoomInvitation): void {
  if (invitation.role !== 'join' || invitation.v !== P2P_INVITATION_FORMAT_VERSION) {
    throw new Error('不是当前版本的 OneBeat 邀请');
  }
  if (invitation.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error('双方版本不一致，请更新 OneBeat 后重试');
  }
  if (!/^\d{6}$/.test(invitation.code)) {
    throw new Error('邀请缺少 6 位加入码');
  }
  if (invitation.roomId.length < 16 || invitation.authToken.length < 32) {
    throw new Error('邀请认证信息不完整');
  }
  if (invitation.groupName.length === 0 || invitation.passphrase.length < 8) {
    throw new Error('邀请缺少 P2P 组信息');
  }
  if (invitation.expiresAt <= Date.now()) {
    throw new Error('邀请已过期，请让队长重新创建队伍');
  }
  if (invitation.port <= 0 || invitation.port > 65535) {
    throw new Error('邀请端口无效');
  }
}
