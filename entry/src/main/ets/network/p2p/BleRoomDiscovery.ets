import { access, ble, constant } from '@kit.ConnectivityKit';
import { sameTag, serviceDataFromAdvertising } from './BleAdvertisingTag';
import { util } from '@kit.ArkTS';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import {
  parseP2pRoomInvitation,
  P2pRoomInvitation,
  randomAuthNonce,
  validateP2pRoomInvitation
} from './P2pInvitation';

const ROOM_SERVICE_UUID: string = '4f6e6542-6561-7452-6f6f-6d0000000001';
const INVITATION_CHARACTERISTIC_UUID: string = '4f6e6542-6561-7449-6e76-697465000001';
const JOIN_FEEDBACK_CHARACTERISTIC_UUID: string = '4f6e6542-6561-744a-6f69-6e0000000001';
const WIFI_DIALOG_ACCEPT_EVENT: string = 'ohos.event.wifi.DIALOG_ACCEPT';
const WIFI_DIALOG_REJECT_EVENT: string = 'ohos.event.wifi.DIALOG_REJECT';
const WIFI_CONFIG_PERMISSION: string = 'ohos.permission.SET_WIFI_CONFIG';
const P2P_CONFIRM_DIALOG_TYPE: number = 4;
const BLE_LOOKUP_TIMEOUT_MS: number = 15000;
const GATT_CONNECT_TIMEOUT_MS: number = 8000;
// Device 2026-10-29: a GATT connection takes 3–5s here, so a 3s bound made
// every fresh feedback connection time out and rejections waited ~25s.
const GATT_FEEDBACK_CONNECT_TIMEOUT_MS: number = 6000;
// The lookup's GATT link is kept for the feedback channel this long; a join
// normally consumes it within milliseconds of the lookup resolving.
const RETAINED_LOOKUP_LINK_MS: number = 15000;
// While the member types the code, nearby rooms' invitations are read ahead:
// the GATT connection is 3–5s of every lookup (device 2026-10-29), and the
// invitation is readable by anyone nearby anyway. Bounded in rooms and time.
const PREFETCH_MAX_ROOMS: number = 3;
const PREFETCH_MAX_MS: number = 20000;
const PREFETCH_CACHE_MAX_AGE_MS: number = 30000;
const GATT_FEEDBACK_OPERATION_TIMEOUT_MS: number = 3000;
const GATT_FEEDBACK_CLOSE_TIMEOUT_MS: number = 250;
const MAX_GATT_READ_ATTEMPTS: number = 2;
const JOIN_FEEDBACK_POLL_MS: number = 250;
const JOIN_ATTEMPT_TTL_MS: number = 45000;
const LEADER_REJECTED_MESSAGE: string = '队长已拒绝本次加入请求，请和队长确认后再试一次';

const encoder = new util.TextEncoder();
const decoder = util.TextDecoder.create('utf-8');

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function encodeText(value: string): ArrayBuffer {
  return toArrayBuffer(encoder.encodeInto(value));
}

function serviceTag(code: string, protocolVersion: number): Uint8Array {
  const bytes = new Uint8Array(7);
  bytes[0] = protocolVersion & 0xff;
  for (let i = 0; i < 6; i++) {
    bytes[i + 1] = code.charCodeAt(i);
  }
  return bytes;
}

function sameUuid(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

type JoinDecision = 'pending' | 'accepted' | 'rejected';

interface LeaderJoinAttempt {
  deviceId: string;
  attemptId: string;
  decision: JoinDecision;
  createdAt: number;
  displayName: string;
}

/** Player nicknames are at most 16 characters (TeamPage input limit). */
const JOIN_REQUEST_NAME_MAX_CHARS: number = 16;
// Room for `P:<16 hex>:<16 CJK chars>` (67 bytes) in a single write.
const JOIN_REGISTRATION_MTU: number = 128;

/**
 * P:<attemptId>[:<nickname>]. The leader's system P2P dialog shows the peer's
 * cached Wi-Fi record, which after a quick rejoin is an address string instead
 * of the model (device 2026-10-29 17:40:13); the nickname lets the leader app
 * say who is asking. Colons in a nickname are harmless: only the first one
 * after the id separates it.
 */
function joinRegistrationCommand(attemptId: string, displayName: string): string {
  const name = Array.from(displayName.trim()).slice(0, JOIN_REQUEST_NAME_MAX_CHARS).join('');
  return name.length > 0 ? `P:${attemptId}:${name}` : `P:${attemptId}`;
}

/** Owns one optional BLE feedback attempt; cancelling must never await the BLE stack. */
export class BleMemberJoinFeedbackAttempt {
  private cancelled: boolean = false;
  private readonly cancelListeners: Set<() => void> = new Set();

  isCancelled(): boolean {
    return this.cancelled;
  }

  /** Registers synchronous cleanup, or runs it now if cancelled; returns an unsubscribe callback. */
  onCancel(listener: () => void): () => void {
    if (this.cancelled) {
      listener();
      return (): void => {};
    }
    this.cancelListeners.add(listener);
    return (): void => { this.cancelListeners.delete(listener); };
  }

  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    const listeners = Array.from(this.cancelListeners);
    this.cancelListeners.clear();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (_e) {
        // One unavailable GATT cleanup must not prevent the other waiters from cancelling.
      }
    }
  }
}

const REGISTRATION_MTU_WAIT_MS: number = 600;

/**
 * Raises the MTU after service discovery, just before the registration write.
 * Requesting it right after connect collided with discovery on device
 * (2026-10-29 18:24, 18:32: "already has a pending command", then getServices
 * timed out after 10s with an empty list and the room was "not found").
 */
function negotiateRegistrationMtu(client: ble.GattClientDevice): Promise<void> {
  return new Promise<void>((resolve) => {
    let settled = false;
    const finish = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      try {
        client.off('BLEMtuChange', onMtu);
      } catch (_e) {
      }
      resolve();
    };
    const onMtu = (_mtu: number): void => finish();
    const timer = setTimeout(finish, REGISTRATION_MTU_WAIT_MS);
    try {
      client.on('BLEMtuChange', onMtu);
      client.setBLEMtuSize(JOIN_REGISTRATION_MTU);
    } catch (_e) {
      // The nameless registration still fits the default MTU.
      finish();
    }
  });
}

/** An empty list after a stalled discovery is retried once before giving up. */
async function discoverServices(client: ble.GattClientDevice): Promise<ble.GattService[]> {
  const services = await client.getServices();
  if (services.length > 0) {
    return services;
  }
  console.warn('[JoinDiag] stage=ble-services-empty retry=1');
  return await client.getServices();
}

function closeFeedbackClient(client: ble.GattClientDevice): void {
  try {
    client.disconnect();
  } catch (_e) {
  }
  try {
    client.close();
  } catch (_e) {
  }
}

function feedbackStep<T>(work: Promise<T>, timeoutMs: number,
  attempt?: BleMemberJoinFeedbackAttempt): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    let removeCancel: () => void = (): void => {};
    const timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      removeCancel();
      reject(new Error('BLE join feedback operation timeout'));
    }, timeoutMs);
    const fail = (error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      removeCancel();
      reject(error);
    };
    // Always consume late completion/rejection from a timed-out system promise.
    work.then((value: T) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      removeCancel();
      resolve(value);
    }, (error: Error) => fail(error));
    if (attempt !== undefined) {
      removeCancel = attempt.onCancel(() => fail(new Error('BLE join feedback cancelled')));
    }
  });
}

function feedbackRetryDelay(attempt: BleMemberJoinFeedbackAttempt): Promise<void> {
  return new Promise<void>((resolve) => {
    let removeCancel: () => void = (): void => {};
    const timer = setTimeout(() => {
      removeCancel();
      resolve();
    }, JOIN_FEEDBACK_POLL_MS);
    removeCancel = attempt.onCancel(() => {
      clearTimeout(timer);
      resolve();
    });
  });
}

interface PrefetchedInvitation {
  invitation: P2pRoomInvitation;
  readAt: number;
}

interface PrefetchLink {
  deviceId: string;
  client: ble.GattClientDevice;
  characteristic: ble.BLECharacteristic;
}

interface PreRegisteredJoin {
  deviceId: string;
  client: ble.GattClientDevice;
  characteristic: ble.BLECharacteristic;
  attemptId: string;
}

export class BleJoinFeedbackChannel {
  readonly rejection: Promise<Error>;
  private readonly client: ble.GattClientDevice;
  private readonly characteristic: ble.BLECharacteristic;
  private readonly attemptId: string;
  private resolveRejection: (error: Error) => void = (_error: Error): void => {};
  private closed: boolean = false;
  private rejectionDelivered: boolean = false;
  private pollTimer: number = -1;
  private removeCancel: () => void = (): void => {};

  constructor(
    client: ble.GattClientDevice,
    characteristic: ble.BLECharacteristic,
    attemptId: string,
    attempt?: BleMemberJoinFeedbackAttempt,
    startPolling: boolean = true
  ) {
    this.client = client;
    this.characteristic = characteristic;
    this.attemptId = attemptId;
    this.rejection = new Promise<Error>((resolve) => {
      this.resolveRejection = resolve;
    });
    if (attempt !== undefined) {
      this.removeCancel = attempt.onCancel(() => { void this.close(); });
    }
    if (startPolling) {
      this.schedulePoll(0);
    }
  }

  private schedulePoll(delayMs: number): void {
    if (this.closed || this.rejectionDelivered) {
      return;
    }
    this.pollTimer = setTimeout(() => {
      void this.poll();
    }, delayMs);
  }

  private async poll(): Promise<void> {
    if (this.closed || this.rejectionDelivered) {
      return;
    }
    try {
      const result = await this.client.readCharacteristicValue(this.characteristic);
      if (this.closed) {
        return;
      }
      const status = decoder.decodeToString(new Uint8Array(result.characteristicValue));
      if (status === `R:${this.attemptId}`) {
        this.rejectionDelivered = true;
        console.info(`BLE join feedback rejected: ${this.attemptId}`);
        this.resolveRejection(new Error(LEADER_REJECTED_MESSAGE));
        return;
      }
    } catch (_e) {
      // A short BLE read interruption must not abort an otherwise valid P2P join.
    }
    this.schedulePoll(JOIN_FEEDBACK_POLL_MS);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.removeCancel();
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
    }
    try {
      const cancelCharacteristic: ble.BLECharacteristic = {
        serviceUuid: this.characteristic.serviceUuid,
        characteristicUuid: this.characteristic.characteristicUuid,
        characteristicValue: encodeText(`C:${this.attemptId}`),
        descriptors: this.characteristic.descriptors
      };
      // C only removes this attemptId on the leader; late cleanup cannot erase
      // a newer join. P2P may interrupt BLE, so cancellation cannot hold a GATT
      // handle or the joining page indefinitely.
      await feedbackStep(this.client.writeCharacteristicValue(cancelCharacteristic, ble.GattWriteType.WRITE),
        GATT_FEEDBACK_CLOSE_TIMEOUT_MS);
    } catch (_e) {
      // The P2P transition can briefly interrupt BLE. Server entries also expire.
    } finally {
      closeFeedbackClient(this.client);
    }
  }
}

export class BleRoomDiscovery {
  private gattServer: ble.GattServer | undefined = undefined;
  private advertisingId: number | undefined = undefined;
  private dialogSubscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  // Leader: told the requesting member's nickname on registration, '' when
  // the request is decided, withdrawn or expired.
  private joinRequestListener: ((displayName: string) => void) | undefined = undefined;
  // Member: nickname sent with the join registration.
  private memberDisplayName: string = '';
  private leaderJoinAttempts: Map<string, LeaderJoinAttempt> = new Map();
  private lastResolvedDeviceId: string = '';
  private lastResolvedRoomId: string = '';
  // Join attempt registered on the lookup's own GATT link before P2P starts.
  // Device 2026-10-29: a second connection costs 3–5s, and any BLE operation
  // issued while P2P negotiates stalled past its 3s bound, so the leader's
  // rejection had no attempt to report to and the member waited ~25s.
  private preRegistered: PreRegisteredJoin | undefined = undefined;
  private preRegisteredTimer: number = -1;
  private prefetched: Map<string, PrefetchedInvitation> = new Map();
  private prefetchLink: PrefetchLink | undefined = undefined;
  private prefetchStop: (() => Promise<void>) | undefined = undefined;

  isBluetoothEnabled(): boolean {
    try {
      return access.getState() === access.BluetoothState.STATE_ON;
    } catch (_e) {
      return false;
    }
  }

  async startLeaderAdvertising(invitation: P2pRoomInvitation): Promise<void> {
    validateP2pRoomInvitation(invitation);
    if (!canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      throw new Error('当前设备不支持蓝牙附近发现');
    }
    if (!this.isBluetoothEnabled()) {
      throw new Error('蓝牙未开启，队员仍可扫码加入；手输加入码暂不可用');
    }
    await this.stopLeaderAdvertising();
    const invitationBytes = encodeText(JSON.stringify(invitation));
    const server = ble.createGattServer();
    const invitationCharacteristic: ble.BLECharacteristic = {
      serviceUuid: ROOM_SERVICE_UUID,
      characteristicUuid: INVITATION_CHARACTERISTIC_UUID,
      characteristicValue: invitationBytes,
      descriptors: [],
      properties: { read: true },
      permissions: { read: true }
    };
    const joinFeedbackCharacteristic: ble.BLECharacteristic = {
      serviceUuid: ROOM_SERVICE_UUID,
      characteristicUuid: JOIN_FEEDBACK_CHARACTERISTIC_UUID,
      characteristicValue: encodeText('N'),
      descriptors: [],
      properties: { read: true, write: true },
      permissions: { read: true, write: true }
    };
    const service: ble.GattService = {
      serviceUuid: ROOM_SERVICE_UUID,
      isPrimary: true,
      characteristics: [invitationCharacteristic, joinFeedbackCharacteristic]
    };
    server.on('characteristicRead', (request: ble.CharacteristicReadRequest) => {
      if (!sameUuid(request.serviceUuid, ROOM_SERVICE_UUID)) {
        return;
      }
      let responseValue: ArrayBuffer;
      if (sameUuid(request.characteristicUuid, INVITATION_CHARACTERISTIC_UUID)) {
        responseValue = invitationBytes;
      } else if (sameUuid(request.characteristicUuid, JOIN_FEEDBACK_CHARACTERISTIC_UUID)) {
        const attempt = this.leaderJoinAttempts.get(request.deviceId);
        if (attempt === undefined) {
          responseValue = encodeText('N');
        } else {
          const decisionCode = attempt.decision === 'rejected' ? 'R' :
            (attempt.decision === 'accepted' ? 'A' : 'P');
          responseValue = encodeText(`${decisionCode}:${attempt.attemptId}`);
        }
      } else {
        return;
      }
      const full = new Uint8Array(responseValue);
      const offset = Math.max(0, Math.min(request.offset, full.length));
      server.sendResponse({
        deviceId: request.deviceId,
        transId: request.transId,
        status: 0,
        offset,
        value: toArrayBuffer(full.slice(offset))
      });
    });
    server.on('characteristicWrite', (request: ble.CharacteristicWriteRequest) => {
      if (!sameUuid(request.serviceUuid, ROOM_SERVICE_UUID) ||
        !sameUuid(request.characteristicUuid, JOIN_FEEDBACK_CHARACTERISTIC_UUID)) {
        return;
      }
      this.pruneLeaderJoinAttempts();
      const command = decoder.decodeToString(new Uint8Array(request.value));
      const attemptId = command.substring(2, 18);
      const displayName = command.length > 19 && command.charAt(18) === ':' ?
        Array.from(command.substring(19)).slice(0, JOIN_REQUEST_NAME_MAX_CHARS).join('') : '';
      let status = 0;
      if (command.startsWith('P:') && /^[0-9a-f]{16}$/.test(attemptId) &&
        (command.length === 18 || command.charAt(18) === ':')) {
        this.leaderJoinAttempts.set(request.deviceId, {
          deviceId: request.deviceId,
          attemptId,
          decision: 'pending',
          createdAt: Date.now(),
          displayName
        });
        console.info(`BLE join attempt registered: ${attemptId} named=${displayName.length > 0}`);
        this.joinRequestListener?.(displayName);
      } else if (command.startsWith('C:')) {
        const current = this.leaderJoinAttempts.get(request.deviceId);
        if (current !== undefined && current.attemptId === attemptId) {
          this.leaderJoinAttempts.delete(request.deviceId);
          this.joinRequestListener?.('');
        }
      } else {
        status = 1;
      }
      if (request.needRsp) {
        server.sendResponse({
          deviceId: request.deviceId,
          transId: request.transId,
          status,
          offset: request.offset,
          value: request.value
        });
      }
    });
    server.addService(service);
    const tag = serviceTag(invitation.code, invitation.protocolVersion);
    const advertisingData: ble.AdvertiseData = {
      serviceUuids: [ROOM_SERVICE_UUID],
      manufactureData: [],
      serviceData: []
    };
    const advertisingResponse: ble.AdvertiseData = {
      serviceUuids: [],
      manufactureData: [],
      serviceData: [{ serviceUuid: ROOM_SERVICE_UUID, serviceValue: toArrayBuffer(tag) }]
    };
    try {
      const advertisingId = await ble.startAdvertising({
        advertisingSettings: { interval: 160, txPower: 0, connectable: true },
        advertisingData: advertisingData,
        advertisingResponse: advertisingResponse,
        duration: 0
      });
      this.gattServer = server;
      this.advertisingId = advertisingId;
      await this.startDialogDecisionListener();
    } catch (err) {
      await this.stopDialogDecisionListener();
      server.close();
      throw new Error((err as Error).message ?? 'BLE 房间广播启动失败');
    }
  }

  /** Leader: receives the requesting member's nickname ('' clears the notice). */
  setJoinRequestListener(listener: ((displayName: string) => void) | undefined): void {
    this.joinRequestListener = listener;
  }

  /** Member: nickname sent with the join registration. */
  setMemberDisplayName(displayName: string): void {
    this.memberDisplayName = displayName;
  }

  /** Reads nearby rooms' invitations ahead of the code; safe to call repeatedly. */
  startInvitationPrefetch(protocolVersion: number): void {
    if (this.prefetchStop !== undefined || !canIUse('SystemCapability.Communication.Bluetooth.Core') ||
      !this.isBluetoothEnabled()) {
      return;
    }
    const startedAt = Date.now();
    let stopped = false;
    let scanning = false;
    let reading: Promise<void> | undefined = undefined;
    const queued: string[] = [];
    const seen: Set<string> = new Set();
    const stopScan = (): void => {
      if (scanning) {
        scanning = false;
        try {
          ble.stopBLEScan();
        } catch (_e) {
        }
      }
    };
    const startScan = (): void => {
      if (stopped || scanning || seen.size >= PREFETCH_MAX_ROOMS) {
        return;
      }
      try {
        ble.startBLEScan([{ serviceUuid: ROOM_SERVICE_UUID }],
          { dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY, matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE });
        scanning = true;
      } catch (err) {
        console.warn(`[JoinDiag] stage=prefetch-scan-failed reason=${(err as Error).message}`);
      }
    };
    const drain = async (): Promise<void> => {
      stopScan();
      while (!stopped && queued.length > 0) {
        const deviceId = queued.shift() as string;
        const readStartedAt = Date.now();
        try {
          const invitation = await this.readInvitationForPrefetch(deviceId, protocolVersion);
          this.prefetched.set(deviceId, { invitation, readAt: Date.now() });
          console.info(`[JoinDiag] stage=prefetch-read result=ok readMs=${Date.now() - readStartedAt} ` +
            `elapsedMs=${Date.now() - startedAt}`);
        } catch (err) {
          console.warn(`[JoinDiag] stage=prefetch-read result=failed readMs=${Date.now() - readStartedAt} ` +
            `reason=${(err as Error).message}`);
        }
      }
      reading = undefined;
      startScan();
    };
    const callback = (results: ble.ScanResult[]): void => {
      if (stopped) {
        return;
      }
      results.sort((left: ble.ScanResult, right: ble.ScanResult) => right.rssi - left.rssi);
      for (let i = 0; i < results.length && seen.size < PREFETCH_MAX_ROOMS; i++) {
        if (!seen.has(results[i].deviceId)) {
          seen.add(results[i].deviceId);
          queued.push(results[i].deviceId);
        }
      }
      if (reading === undefined && queued.length > 0) {
        reading = drain();
      }
    };
    const timer = setTimeout(() => { void stop(); }, PREFETCH_MAX_MS);
    const stop = async (): Promise<void> => {
      if (!stopped) {
        stopped = true;
        clearTimeout(timer);
        ble.off('BLEDeviceFind', callback);
        stopScan();
      }
      // A read in flight is usually the leader's: finishing it beats a new lookup.
      const pending: Promise<void> | undefined = reading;
      if (pending !== undefined) {
        await pending;
      }
      if (this.prefetchStop === stop) {
        this.prefetchStop = undefined;
      }
    };
    this.prefetchStop = stop;
    ble.on('BLEDeviceFind', callback);
    startScan();
    console.info('[JoinDiag] stage=prefetch-start');
  }

  /** Stops prefetching; an in-flight read is allowed to finish. */
  async stopInvitationPrefetch(): Promise<void> {
    const stop = this.prefetchStop;
    if (stop !== undefined) {
      await stop();
    }
  }

  /** Drops prefetched invitations and the kept link (page left without joining). */
  async discardInvitationPrefetch(): Promise<void> {
    await this.stopInvitationPrefetch();
    this.prefetched.clear();
    this.releasePrefetchLink();
  }

  private async readInvitationForPrefetch(deviceId: string, protocolVersion: number): Promise<P2pRoomInvitation> {
    const client = ble.createGattClientDevice(deviceId);
    let kept = false;
    try {
      await this.connectGattClient(client, deviceId);
      const services = await discoverServices(client);
      const target = this.findCharacteristic(services, INVITATION_CHARACTERISTIC_UUID);
      if (target === undefined) {
        throw new Error('队长未提供 OneBeat 房间邀请');
      }
      const result = await client.readCharacteristicValue(target);
      const invitation = parseP2pRoomInvitation(decoder.decodeToString(new Uint8Array(result.characteristicValue)));
      validateP2pRoomInvitation(invitation);
      const feedback = this.findCharacteristic(services, JOIN_FEEDBACK_CHARACTERISTIC_UUID);
      // Keep only the first (strongest) room's link: usually the one being joined.
      if (feedback !== undefined && invitation.protocolVersion === protocolVersion &&
        this.prefetchLink === undefined) {
        this.prefetchLink = { deviceId, client, characteristic: feedback };
        kept = true;
      }
      return invitation;
    } finally {
      if (!kept) {
        closeFeedbackClient(client);
      }
    }
  }

  private releasePrefetchLink(): void {
    const link = this.prefetchLink;
    this.prefetchLink = undefined;
    if (link !== undefined) {
      closeFeedbackClient(link.client);
    }
  }

  /** A prefetched invitation for this code, registered on its kept link when possible. */
  private async takePrefetchedInvitation(code: string, protocolVersion: number):
    Promise<P2pRoomInvitation | undefined> {
    await this.stopInvitationPrefetch();
    const hits: PrefetchedInvitation[] = [];
    const hitIds: string[] = [];
    const now = Date.now();
    this.prefetched.forEach((entry: PrefetchedInvitation, deviceId: string) => {
      if (hits.length === 0 && now - entry.readAt <= PREFETCH_CACHE_MAX_AGE_MS &&
        entry.invitation.code === code && entry.invitation.protocolVersion === protocolVersion) {
        hits.push(entry);
        hitIds.push(deviceId);
      }
    });
    this.prefetched.clear();
    const link = this.prefetchLink;
    this.prefetchLink = undefined;
    if (hits.length === 0) {
      if (link !== undefined) {
        closeFeedbackClient(link.client);
      }
      return undefined;
    }
    const found = hits[0].invitation;
    const hitDeviceId = hitIds[0];
    try {
      validateP2pRoomInvitation(found);
    } catch (_e) {
      if (link !== undefined) {
        closeFeedbackClient(link.client);
      }
      return undefined;
    }
    if (link !== undefined && link.deviceId === hitDeviceId) {
      if (!await this.preRegisterJoin(link.client, link.deviceId, link.characteristic)) {
        closeFeedbackClient(link.client);
      }
    } else if (link !== undefined) {
      closeFeedbackClient(link.client);
    }
    this.lastResolvedDeviceId = hitDeviceId;
    this.lastResolvedRoomId = found.roomId;
    console.info(`[JoinDiag] stage=prefetch-hit preRegistered=${this.preRegistered !== undefined}`);
    return found;
  }

  async resolveInvitationByCode(code: string, protocolVersion: number): Promise<P2pRoomInvitation> {
    if (!/^\d{6}$/.test(code)) {
      throw new Error('请输入 6 位加入码');
    }
    if (!canIUse('SystemCapability.Communication.Bluetooth.Core')) {
      throw new Error('当前设备不支持蓝牙附近发现，请改用扫码加入');
    }
    if (!this.isBluetoothEnabled()) {
      throw new Error('手输加入码需要打开蓝牙；也可以改用扫码加入');
    }
    const prefetched = await this.takePrefetchedInvitation(code, protocolVersion);
    if (prefetched !== undefined) {
      return prefetched;
    }
    return await this.findRoomInvitation(code, protocolVersion);
  }

  /** The room tag a scan report carries, or undefined when the report has none. */
  private roomTagOf(result: ble.ScanResult): Uint8Array | undefined {
    const parsed: Uint8Array[] = [];
    result.serviceDataMap?.forEach((value: Uint8Array, key: string) => {
      if (sameUuid(key, ROOM_SERVICE_UUID)) {
        parsed.push(value);
      }
    });
    if (parsed.length > 0) {
      return parsed[0];
    }
    return result.data === undefined ? undefined : serviceDataFromAdvertising(result.data, ROOM_SERVICE_UUID);
  }

  private findRoomInvitation(code: string, protocolVersion: number): Promise<P2pRoomInvitation> {
    this.releasePreRegistered();
    const expectedTag = serviceTag(code, protocolVersion);
    const startedAt = Date.now();
    let candidates = 0;
    const seen: Set<string> = new Set();
    return new Promise((resolve, reject) => {
      let settled = false;
      let reading = false;
      const queuedIds: string[] = [];
      const queuedOrReading: Set<string> = new Set();
      const attempts: Map<string, number> = new Map();

      let scanning = false;
      const startScan = (): void => {
        ble.startBLEScan([{
          serviceUuid: ROOM_SERVICE_UUID
        }], { dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY, matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE });
        scanning = true;
      };
      const stopScan = (): void => {
        if (!scanning) {
          return;
        }
        scanning = false;
        try {
          ble.stopBLEScan();
        } catch (_e) {
        }
      };
      const cleanup = (): void => {
        clearTimeout(timer);
        ble.off('BLEDeviceFind', callback);
        stopScan();
      };

      const drainQueue = async (): Promise<void> => {
        if (reading || settled) {
          return;
        }
        reading = true;
        // Trial: scanning while a GATT connection is being set up shares the
        // radio and can slow the connection (device: 4–6s per invitation read).
        // Pause it for the read; the lookup resumes scanning if no room matched.
        stopScan();
        while (!settled && queuedIds.length > 0) {
          const deviceId = queuedIds.shift();
          if (deviceId === undefined) {
            continue;
          }
          attempts.set(deviceId, (attempts.get(deviceId) ?? 0) + 1);
          const readStartedAt = Date.now();
          try {
            const invitation = await this.readInvitation(deviceId, (candidate: P2pRoomInvitation) =>
              candidate.code === code && candidate.protocolVersion === protocolVersion);
            validateP2pRoomInvitation(invitation);
            const matched = invitation.code === code && invitation.protocolVersion === protocolVersion;
            console.info(`[JoinDiag] stage=ble-read result=${matched ? 'match' : 'other-room'} ` +
              `readMs=${Date.now() - readStartedAt} elapsedMs=${Date.now() - startedAt}`);
            if (matched) {
              this.lastResolvedDeviceId = deviceId;
              this.lastResolvedRoomId = invitation.roomId;
              settled = true;
              cleanup();
              resolve(invitation);
              return;
            }
          } catch (err) {
            // A scan can arrive before the peer's GATT service is ready. A later
            // scan result may queue one more read before the lookup times out.
            console.warn(`[JoinDiag] stage=ble-read result=failed readMs=${Date.now() - readStartedAt} ` +
              `elapsedMs=${Date.now() - startedAt} reason=${(err as Error).message}`);
          } finally {
            queuedOrReading.delete(deviceId);
          }
        }
        reading = false;
        if (!settled) {
          try {
            startScan();
          } catch (err) {
            console.warn(`[JoinDiag] stage=ble-scan-resume-failed reason=${(err as Error).message}`);
          }
        }
      };

      const callback = (results: ble.ScanResult[]): void => {
        if (settled || results.length === 0) {
          return;
        }
        results.sort((left: ble.ScanResult, right: ble.ScanResult) => right.rssi - left.rssi);
        for (let i = 0; i < results.length; i++) {
          const deviceId = results[i].deviceId;
          if (queuedOrReading.has(deviceId) ||
            (attempts.get(deviceId) ?? 0) >= MAX_GATT_READ_ATTEMPTS) {
            continue;
          }
          // The scan response already names the room's code. A different code
          // never needs a GATT connection; each one can cost seconds and keep
          // the queue from reaching the right leader before the lookup timeout.
          const tag = this.roomTagOf(results[i]);
          const tagState = tag === undefined ? 'none' : (sameTag(tag, expectedTag) ? 'match' : 'other');
          if (!seen.has(deviceId)) {
            seen.add(deviceId);
            candidates++;
            console.info(`[JoinDiag] stage=ble-candidate index=${candidates} tag=${tagState} ` +
              `rssi=${results[i].rssi} elapsedMs=${Date.now() - startedAt}`);
          }
          if (tagState === 'other') {
            attempts.set(deviceId, MAX_GATT_READ_ATTEMPTS);
            continue;
          }
          queuedOrReading.add(deviceId);
          queuedIds.push(deviceId);
        }
        void drainQueue();
      };
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        console.warn(`[JoinDiag] stage=ble-lookup-timeout candidates=${candidates}`);
        reject(new Error('附近未找到该房间，请确认队长仍在队伍大厅且蓝牙已开启'));
      }, BLE_LOOKUP_TIMEOUT_MS);
      try {
        ble.on('BLEDeviceFind', callback);
        startScan();
      } catch (err) {
        settled = true;
        cleanup();
        reject(new Error((err as Error).message ?? '蓝牙附近发现启动失败'));
      }
    });
  }

  async startMemberJoinFeedback(invitation: P2pRoomInvitation,
    feedbackAttempt: BleMemberJoinFeedbackAttempt = new BleMemberJoinFeedbackAttempt()):
    Promise<BleJoinFeedbackChannel | undefined> {
    if (feedbackAttempt.isCancelled() || this.lastResolvedDeviceId.length === 0 ||
      this.lastResolvedRoomId !== invitation.roomId) {
      return undefined;
    }
    const deviceId = this.lastResolvedDeviceId;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (feedbackAttempt.isCancelled()) {
        return undefined;
      }
      const channel = await this.openMemberJoinFeedback(deviceId, feedbackAttempt);
      if (feedbackAttempt.isCancelled()) {
        if (channel !== undefined) {
          void channel.close();
        }
        return undefined;
      }
      if (channel !== undefined) {
        return channel;
      }
      if (attempt + 1 < 2) {
        await feedbackRetryDelay(feedbackAttempt);
      }
    }
    console.warn('BLE join feedback unavailable after retry');
    return undefined;
  }

  private async openMemberJoinFeedback(deviceId: string, feedbackAttempt: BleMemberJoinFeedbackAttempt):
    Promise<BleJoinFeedbackChannel | undefined> {
    if (feedbackAttempt.isCancelled()) {
      return undefined;
    }
    const registered = this.takePreRegistered(deviceId);
    if (registered !== undefined) {
      if (feedbackAttempt.isCancelled()) {
        void new BleJoinFeedbackChannel(registered.client, registered.characteristic, registered.attemptId,
          undefined, false).close();
        return undefined;
      }
      // No BLE operation here: P2P negotiation starts concurrently and stalls them.
      console.info(`BLE join feedback opened: ${registered.attemptId} link=lookup`);
      return new BleJoinFeedbackChannel(registered.client, registered.characteristic,
        registered.attemptId, feedbackAttempt);
    }
    const client = ble.createGattClientDevice(deviceId);
    let handedOff = false;
    let clientClosed = false;
    const releaseClient = (): void => {
      if (!clientClosed) {
        clientClosed = true;
        closeFeedbackClient(client);
      }
    };
    // Cancelling during an unresolved system operation releases the local GATT
    // handle synchronously. Continuations check cancellation before submitting
    // a new P:; packets already submitted remain subject to native delivery.
    const removeCancel = feedbackAttempt.onCancel(releaseClient);
    try {
      await this.connectGattClient(client, deviceId, GATT_FEEDBACK_CONNECT_TIMEOUT_MS, feedbackAttempt);
      if (feedbackAttempt.isCancelled()) {
        return undefined;
      }
      const services = await feedbackStep(client.getServices(), GATT_FEEDBACK_OPERATION_TIMEOUT_MS, feedbackAttempt);
      if (feedbackAttempt.isCancelled()) {
        return undefined;
      }
      const target = this.findCharacteristic(services, JOIN_FEEDBACK_CHARACTERISTIC_UUID);
      if (target === undefined) {
        throw new Error('队长版本不支持即时连接结果回执');
      }
      const attemptId = randomAuthNonce().substring(0, 16);
      if (!await this.writeJoinRegistration(client, target, attemptId, feedbackAttempt)) {
        throw new Error('BLE join feedback registration failed');
      }
      if (feedbackAttempt.isCancelled()) {
        return undefined;
      }
      console.info(`BLE join feedback opened: ${attemptId} link=new`);
      const channel = new BleJoinFeedbackChannel(client, target, attemptId, feedbackAttempt);
      handedOff = true;
      return channel;
    } catch (err) {
      if (!feedbackAttempt.isCancelled()) {
        console.warn(`BLE join feedback retry: ${(err as Error).message}`);
      }
      return undefined;
    } finally {
      removeCancel();
      if (!handedOff) {
        releaseClient();
      }
    }
  }

  private connectGattClient(
    client: ble.GattClientDevice,
    deviceId: string,
    timeoutMs: number = GATT_CONNECT_TIMEOUT_MS,
    feedbackAttempt?: BleMemberJoinFeedbackAttempt
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let removeCancel: () => void = (): void => {};
      const finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        try {
          client.off('BLEConnectionStateChange', callback);
        } catch (_e) {
        }
        removeCancel();
        if (error !== undefined) {
          reject(error);
        } else {
          resolve();
        }
      };
      const callback = (state: ble.BLEConnectionChangeState): void => {
        if (settled || state.deviceId !== deviceId) {
          return;
        }
        if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          finish();
        } else if (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
          finish(new Error('蓝牙连接已断开'));
        }
      };
      const timer = setTimeout(() => {
        finish(new Error('蓝牙连接超时'));
      }, timeoutMs);
      client.on('BLEConnectionStateChange', callback);
      if (feedbackAttempt !== undefined) {
        removeCancel = feedbackAttempt.onCancel(() => finish(new Error('BLE join feedback cancelled')));
      }
      if (!settled) {
        try {
          client.connect();
        } catch (err) {
          finish(err as Error);
        }
      }
    });
  }

  private findCharacteristic(
    services: ble.GattService[],
    characteristicUuid: string
  ): ble.BLECharacteristic | undefined {
    for (let i = 0; i < services.length; i++) {
      if (!sameUuid(services[i].serviceUuid, ROOM_SERVICE_UUID)) {
        continue;
      }
      for (let j = 0; j < services[i].characteristics.length; j++) {
        if (sameUuid(services[i].characteristics[j].characteristicUuid, characteristicUuid)) {
          return services[i].characteristics[j];
        }
      }
    }
    return undefined;
  }

  private async readInvitation(deviceId: string,
    retainIf: (invitation: P2pRoomInvitation) => boolean): Promise<P2pRoomInvitation> {
    const client = ble.createGattClientDevice(deviceId);
    let retained = false;
    try {
      await this.connectGattClient(client, deviceId);
      const services = await discoverServices(client);
      const target = this.findCharacteristic(services, INVITATION_CHARACTERISTIC_UUID);
      if (target === undefined) {
        throw new Error('队长未提供 OneBeat 房间邀请');
      }
      const result = await client.readCharacteristicValue(target);
      const json = decoder.decodeToString(new Uint8Array(result.characteristicValue));
      const invitation = parseP2pRoomInvitation(json);
      const feedback = this.findCharacteristic(services, JOIN_FEEDBACK_CHARACTERISTIC_UUID);
      if (retainIf(invitation) && feedback !== undefined) {
        retained = await this.preRegisterJoin(client, deviceId, feedback);
      }
      return invitation;
    } finally {
      if (!retained) {
        closeFeedbackClient(client);
      }
    }
  }

  /** Writes P:attemptId on the lookup link; returns true when the link is kept. */
  private async preRegisterJoin(client: ble.GattClientDevice, deviceId: string,
    feedback: ble.BLECharacteristic): Promise<boolean> {
    this.releasePreRegistered();
    const attemptId = randomAuthNonce().substring(0, 16);
    if (!await this.writeJoinRegistration(client, feedback, attemptId)) {
      return false;
    }
    this.preRegistered = { deviceId, client, characteristic: feedback, attemptId };
    this.preRegisteredTimer = setTimeout(() => {
      this.preRegisteredTimer = -1;
      this.releasePreRegistered();
    }, RETAINED_LOOKUP_LINK_MS);
    return true;
  }

  /**
   * Writes the registration, falling back to the nameless form if the longer
   * write is refused (MTU not raised): rejection feedback matters more.
   */
  private async writeJoinRegistration(client: ble.GattClientDevice, feedback: ble.BLECharacteristic,
    attemptId: string, attempt?: BleMemberJoinFeedbackAttempt): Promise<boolean> {
    await negotiateRegistrationMtu(client);
    const named = joinRegistrationCommand(attemptId, this.memberDisplayName);
    const commands = named === `P:${attemptId}` ? [named] : [named, `P:${attemptId}`];
    for (let i = 0; i < commands.length; i++) {
      try {
        await feedbackStep(client.writeCharacteristicValue({
          serviceUuid: feedback.serviceUuid,
          characteristicUuid: feedback.characteristicUuid,
          characteristicValue: encodeText(commands[i]),
          descriptors: feedback.descriptors
        }, ble.GattWriteType.WRITE), GATT_FEEDBACK_OPERATION_TIMEOUT_MS, attempt);
        if (i > 0) {
          console.warn('BLE join registration sent without nickname');
        }
        return true;
      } catch (err) {
        console.warn(`BLE join registration write failed: ${(err as Error).message}`);
        if (attempt?.isCancelled() === true) {
          return false;
        }
      }
    }
    return false;
  }

  /** Hands the pre-registered attempt to one caller, which then owns its link. */
  private takePreRegistered(deviceId: string): PreRegisteredJoin | undefined {
    const registered = this.preRegistered;
    if (registered === undefined || registered.deviceId !== deviceId) {
      return undefined;
    }
    this.preRegistered = undefined;
    if (this.preRegisteredTimer >= 0) {
      clearTimeout(this.preRegisteredTimer);
      this.preRegisteredTimer = -1;
    }
    return registered;
  }

  private releasePreRegistered(): void {
    const registered = this.preRegistered;
    this.preRegistered = undefined;
    if (this.preRegisteredTimer >= 0) {
      clearTimeout(this.preRegisteredTimer);
      this.preRegisteredTimer = -1;
    }
    if (registered !== undefined) {
      // An unused attempt would otherwise stay pending on the leader and absorb
      // the next dialog decision; C: removes exactly this attempt.
      void new BleJoinFeedbackChannel(registered.client, registered.characteristic, registered.attemptId,
        undefined, false).close();
    }
  }

  private pruneLeaderJoinAttempts(): void {
    const now = Date.now();
    this.leaderJoinAttempts.forEach((attempt, deviceId) => {
      if (now - attempt.createdAt > JOIN_ATTEMPT_TTL_MS) {
        this.leaderJoinAttempts.delete(deviceId);
      }
    });
  }

  private applyDialogDecision(decision: JoinDecision): void {
    this.pruneLeaderJoinAttempts();
    let oldestDeviceId = '';
    let oldestCreatedAt = Number.MAX_SAFE_INTEGER;
    this.leaderJoinAttempts.forEach((attempt, deviceId) => {
      if (attempt.decision === 'pending' && attempt.createdAt < oldestCreatedAt) {
        oldestDeviceId = deviceId;
        oldestCreatedAt = attempt.createdAt;
      }
    });
    const oldest = this.leaderJoinAttempts.get(oldestDeviceId);
    // The dialog is answered either way; any request notice is now stale.
    this.joinRequestListener?.('');
    if (oldest !== undefined) {
      oldest.decision = decision;
      console.info(`BLE join dialog decision ${decision}: ${oldest.attemptId}`);
    } else {
      console.warn(`BLE join dialog decision ${decision}: no pending attempt`);
    }
  }

  private async startDialogDecisionListener(): Promise<void> {
    await this.stopDialogDecisionListener();
    try {
      const subscriber = await commonEventManager.createSubscriber({
        events: [WIFI_DIALOG_ACCEPT_EVENT, WIFI_DIALOG_REJECT_EVENT],
        publisherPermission: WIFI_CONFIG_PERMISSION
      });
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err) {
          console.warn(`BLE join dialog event: ${err.message}`);
          return;
        }
        // The dialog result is an ordered event; without finishing it the system
        // waited 5–20s (Ordered: Timeout) for this receiver on every decision.
        try {
          if (subscriber.isOrderedCommonEventSync()) {
            void subscriber.finishCommonEvent().catch((): void => {});
          }
        } catch (_e) {
        }
        const parameters = JSON.stringify(data.parameters ?? {});
        if (parameters.indexOf(`\"dialogType\":${P2P_CONFIRM_DIALOG_TYPE}`) < 0) {
          return;
        }
        if (data.event === WIFI_DIALOG_REJECT_EVENT) {
          console.info('BLE join received system P2P dialog rejection');
          this.applyDialogDecision('rejected');
        } else if (data.event === WIFI_DIALOG_ACCEPT_EVENT) {
          console.info('BLE join received system P2P dialog acceptance');
          this.applyDialogDecision('accepted');
        }
      });
      this.dialogSubscriber = subscriber;
    } catch (err) {
      console.warn(`BLE join dialog listener unavailable: ${(err as Error).message}`);
    }
  }

  private async stopDialogDecisionListener(): Promise<void> {
    if (this.dialogSubscriber === undefined) {
      return;
    }
    try {
      commonEventManager.unsubscribe(this.dialogSubscriber);
    } catch (_e) {
    }
    this.dialogSubscriber = undefined;
  }

  async stopLeaderAdvertising(): Promise<void> {
    await this.stopDialogDecisionListener();
    this.leaderJoinAttempts.clear();
    if (this.advertisingId !== undefined) {
      try {
        await ble.stopAdvertising(this.advertisingId);
      } catch (err) {
        const error = err as BusinessError;
        console.warn(`BleRoomDiscovery stopAdvertising: ${error.message}`);
      }
      this.advertisingId = undefined;
    }
    if (this.gattServer !== undefined) {
      try {
        this.gattServer.off('characteristicRead');
        this.gattServer.off('characteristicWrite');
        this.gattServer.removeService(ROOM_SERVICE_UUID);
      } catch (_e) {
      }
      this.gattServer.close();
      this.gattServer = undefined;
    }
  }
}
