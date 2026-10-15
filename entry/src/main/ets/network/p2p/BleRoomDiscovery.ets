import { access, ble, constant } from '@kit.ConnectivityKit';
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
const GATT_FEEDBACK_CONNECT_TIMEOUT_MS: number = 3000;
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
    attempt?: BleMemberJoinFeedbackAttempt
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
    this.schedulePoll(0);
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
  private leaderJoinAttempts: Map<string, LeaderJoinAttempt> = new Map();
  private lastResolvedDeviceId: string = '';
  private lastResolvedRoomId: string = '';

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
      const attemptId = command.substring(2);
      let status = 0;
      if (command.startsWith('P:') && /^[0-9a-f]{16}$/.test(attemptId)) {
        this.leaderJoinAttempts.set(request.deviceId, {
          deviceId: request.deviceId,
          attemptId,
          decision: 'pending',
          createdAt: Date.now()
        });
        console.info(`BLE join attempt registered: ${attemptId}`);
      } else if (command.startsWith('C:')) {
        const current = this.leaderJoinAttempts.get(request.deviceId);
        if (current !== undefined && current.attemptId === attemptId) {
          this.leaderJoinAttempts.delete(request.deviceId);
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
    return await this.findRoomInvitation(code, protocolVersion);
  }

  private findRoomInvitation(code: string, protocolVersion: number): Promise<P2pRoomInvitation> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let reading = false;
      const queuedIds: string[] = [];
      const queuedOrReading: Set<string> = new Set();
      const attempts: Map<string, number> = new Map();

      const cleanup = (): void => {
        clearTimeout(timer);
        ble.off('BLEDeviceFind', callback);
        try {
          ble.stopBLEScan();
        } catch (_e) {
        }
      };

      const drainQueue = async (): Promise<void> => {
        if (reading || settled) {
          return;
        }
        reading = true;
        while (!settled && queuedIds.length > 0) {
          const deviceId = queuedIds.shift();
          if (deviceId === undefined) {
            continue;
          }
          attempts.set(deviceId, (attempts.get(deviceId) ?? 0) + 1);
          try {
            const invitation = await this.readInvitation(deviceId);
            validateP2pRoomInvitation(invitation);
            if (invitation.code === code && invitation.protocolVersion === protocolVersion) {
              this.lastResolvedDeviceId = deviceId;
              this.lastResolvedRoomId = invitation.roomId;
              settled = true;
              cleanup();
              resolve(invitation);
              return;
            }
          } catch (_e) {
            // A scan can arrive before the peer's GATT service is ready. A later
            // scan result may queue one more read before the lookup times out.
          } finally {
            queuedOrReading.delete(deviceId);
          }
        }
        reading = false;
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
        reject(new Error('附近未找到该房间，请确认队长仍在队伍大厅且蓝牙已开启'));
      }, BLE_LOOKUP_TIMEOUT_MS);
      try {
        ble.on('BLEDeviceFind', callback);
        ble.startBLEScan([{
          serviceUuid: ROOM_SERVICE_UUID
        }], { dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY, matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE });
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
      try {
        client.setBLEMtuSize(128);
      } catch (_e) {
        // The compact request also fits devices that retain their default MTU.
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
      const requestCharacteristic: ble.BLECharacteristic = {
        serviceUuid: target.serviceUuid,
        characteristicUuid: target.characteristicUuid,
        characteristicValue: encodeText(`P:${attemptId}`),
        descriptors: target.descriptors
      };
      await feedbackStep(client.writeCharacteristicValue(requestCharacteristic, ble.GattWriteType.WRITE),
        GATT_FEEDBACK_OPERATION_TIMEOUT_MS, feedbackAttempt);
      if (feedbackAttempt.isCancelled()) {
        return undefined;
      }
      console.info(`BLE join feedback opened: ${attemptId}`);
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

  private async readInvitation(deviceId: string): Promise<P2pRoomInvitation> {
    const client = ble.createGattClientDevice(deviceId);
    try {
      await this.connectGattClient(client, deviceId);
      const services = await client.getServices();
      const target = this.findCharacteristic(services, INVITATION_CHARACTERISTIC_UUID);
      if (target === undefined) {
        throw new Error('队长未提供 OneBeat 房间邀请');
      }
      const result = await client.readCharacteristicValue(target);
      const json = decoder.decodeToString(new Uint8Array(result.characteristicValue));
      return parseP2pRoomInvitation(json);
    } finally {
      try {
        client.disconnect();
      } catch (_e) {
      }
      client.close();
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
