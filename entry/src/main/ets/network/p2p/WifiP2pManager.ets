import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { P2pRoomInvitation, validateP2pRoomInvitation } from './P2pInvitation';

const EMPTY_DEVICE_ADDRESS: string = '00:00:00:00:00:00';
const CONNECTION_TIMEOUT_MS: number = 25000;
const DISCOVERY_TIMEOUT_MS: number = 30000;
const DISCOVERY_REFRESH_WAIT_MS: number = 3000;
const MEMBER_GROUP_RELEASE_TIMEOUT_MS: number = 3000;
const GROUP_OWNER_CAPABILITY: number = 1;
const JOIN_REJECTED_MESSAGE: string = '队长已拒绝本次加入请求，请和队长确认后再试一次';
const JOIN_CONFIRM_TIMEOUT_MESSAGE: string =
  '系统未完成本次 P2P 确认；请确认队长已收到连接弹窗后再试一次';

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function p2pError(err: Error, fallback: string): Error {
  const message = err.message ?? '';
  if (message.indexOf('2801001') >= 0) {
    return new Error('请先打开 Wi-Fi，点此可前往系统设置');
  }
  if (message.indexOf('801') >= 0) {
    return new Error('当前设备不支持 Wi-Fi P2P，无法使用多人练习');
  }
  if (message.indexOf('201') >= 0) {
    return new Error('缺少附近设备权限，请在系统设置中允许 OneBeat 使用 Wi-Fi');
  }
  return new Error(message.length > 0 ? message : fallback);
}

export class WifiP2pManager {
  private ownsGroup: boolean = false;
  private discovering: boolean = false;
  private lastMemberAttemptGroupName: string = '';

  isWifiEnabled(): boolean {
    try {
      return wifiManager.isWifiActive();
    } catch (_e) {
      return false;
    }
  }

  async assertReadyForOneBeat(): Promise<void> {
    if (!canIUse('SystemCapability.Communication.WiFi.P2P')) {
      throw new Error('当前设备不支持 Wi-Fi P2P，无法使用多人练习');
    }
    if (!this.isWifiEnabled()) {
      throw new Error('请先打开 Wi-Fi，点此可前往系统设置');
    }
    try {
      const linked = await wifiManager.getP2pLinkedInfo();
      if (linked.connectState === wifiManager.P2pConnectState.CONNECTED && !this.ownsGroup) {
        throw new Error('设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
      }
    } catch (err) {
      const error = err as Error;
      if (error.message.indexOf('正在使用其他 P2P') >= 0) {
        throw error;
      }
      throw p2pError(error, '无法检查 Wi-Fi P2P 状态');
    }
  }

  async createLeaderGroup(invitation: P2pRoomInvitation): Promise<wifiManager.WifiP2pGroupInfo> {
    validateP2pRoomInvitation(invitation);
    // A failed or interrupted room can leave an app-owned group behind. Only
    // remove groups this manager created; foreign casting/share groups stay intact.
    await this.removeOwnedGroup();
    await this.assertReadyForOneBeat();
    const config: wifiManager.WifiP2PConfig = {
      deviceAddress: EMPTY_DEVICE_ADDRESS,
      deviceAddressType: wifiManager.DeviceAddressType.RANDOM_DEVICE_ADDRESS,
      netId: -1,
      passphrase: invitation.passphrase,
      groupName: invitation.groupName,
      goBand: wifiManager.GroupOwnerBand.GO_BAND_AUTO
    };
    try {
      const connected = this.waitForConnection(
        EMPTY_DEVICE_ADDRESS,
        wifiManager.P2pDeviceStatus.AVAILABLE,
        CONNECTION_TIMEOUT_MS
      );
      wifiManager.createGroup(config);
      await connected;
      const group = await this.waitForCurrentGroup(4000);
      if (!group.isP2pGo) {
        throw new Error('P2P 组创建后本机不是队长，请重试');
      }
      this.ownsGroup = true;
      return group;
    } catch (err) {
      throw p2pError(err as Error, '创建临时 P2P 组失败');
    }
  }

  async isLeaderGroupReady(invitation: P2pRoomInvitation): Promise<boolean> {
    if (!this.ownsGroup || !this.isWifiEnabled()) {
      return false;
    }
    try {
      const linked = await wifiManager.getP2pLinkedInfo();
      if (linked.connectState !== wifiManager.P2pConnectState.CONNECTED || !linked.isGroupOwner) {
        return false;
      }
      const group = await wifiManager.getCurrentGroup();
      return group.isP2pGo && group.groupName === invitation.groupName;
    } catch (_e) {
      return false;
    }
  }

  async prepareMemberDiscovery(): Promise<void> {
    await this.assertReadyForOneBeat();
    if (this.discovering) {
      return;
    }
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const cleanup = (): void => {
        clearTimeout(timer);
        wifiManager.off('p2pPeerDeviceChange', callback);
      };
      const callback = (_peers: wifiManager.WifiP2pDevice[]): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        resolve();
      };
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        resolve();
      }, DISCOVERY_REFRESH_WAIT_MS);
      try {
        wifiManager.on('p2pPeerDeviceChange', callback);
        wifiManager.startDiscoverDevices();
        this.discovering = true;
      } catch (err) {
        settled = true;
        cleanup();
        reject(p2pError(err as Error, '无法扫描附近 P2P 设备'));
      }
    });
  }

  async connectToLeader(invitation: P2pRoomInvitation, rejectionSignal?: Promise<Error>): Promise<string> {
    validateP2pRoomInvitation(invitation);
    await this.resetPreviousMemberAttempt(invitation);
    await this.stopDiscovery();
    await this.prepareMemberDiscovery();
    const startedAt = Date.now();
    const attempted: Set<string> = new Set();
    const leaderDeviceName = invitation.leaderDeviceName?.trim() ?? '';
    let foundPeer = false;
    let lastError = '';
    try {
      while (Date.now() - startedAt < DISCOVERY_TIMEOUT_MS) {
        let peers: wifiManager.WifiP2pDevice[] = [];
        try {
          peers = await wifiManager.getP2pPeerDevices();
        } catch (err) {
          lastError = (err as Error).message ?? '';
        }
        let hasGroupOwner = false;
        for (let i = 0; i < peers.length; i++) {
          if ((peers[i].groupCapabilities & GROUP_OWNER_CAPABILITY) !== 0) {
            hasGroupOwner = true;
            break;
          }
        }
        for (let i = 0; i < peers.length; i++) {
          const peer = peers[i];
          if (peer.deviceAddress.length === 0 || attempted.has(peer.deviceAddress)) {
            continue;
          }
          if (peer.deviceStatus !== wifiManager.P2pDeviceStatus.AVAILABLE &&
            peer.deviceStatus !== wifiManager.P2pDeviceStatus.INVITED) {
            continue;
          }
          if (leaderDeviceName.length > 0 && peer.deviceName.trim() !== leaderDeviceName) {
            continue;
          }
          if (leaderDeviceName.length === 0 && hasGroupOwner &&
            (peer.groupCapabilities & GROUP_OWNER_CAPABILITY) === 0) {
            continue;
          }
          foundPeer = true;
          attempted.add(peer.deviceAddress);
          try {
            return await this.connectCandidate(peer, invitation, rejectionSignal);
          } catch (err) {
            const connectionError = err as Error;
            lastError = connectionError.message ?? 'P2P 连接失败';
            if (lastError === JOIN_REJECTED_MESSAGE || lastError === JOIN_CONFIRM_TIMEOUT_MESSAGE) {
              throw connectionError;
            }
            await this.prepareMemberDiscovery();
          }
        }
        await sleep(900);
      }
      if (!foundPeer) {
        throw new Error('附近未找到该房间，请确认队长仍在队伍大厅且两台设备靠近');
      }
      throw new Error(lastError.length > 0 ? `发现附近设备，但连接队长失败：${lastError}` : '连接队长失败');
    } finally {
      await this.stopDiscovery();
    }
  }

  private async connectCandidate(
    peer: wifiManager.WifiP2pDevice,
    invitation: P2pRoomInvitation,
    rejectionSignal?: Promise<Error>
  ): Promise<string> {
    const config: wifiManager.WifiP2PConfig = {
      deviceAddress: peer.deviceAddress,
      deviceAddressType: peer.deviceAddressType ?? wifiManager.DeviceAddressType.RANDOM_DEVICE_ADDRESS,
      netId: -1,
      passphrase: invitation.passphrase,
      groupName: invitation.groupName,
      goBand: wifiManager.GroupOwnerBand.GO_BAND_AUTO
    };
    this.lastMemberAttemptGroupName = invitation.groupName;
    try {
      await this.waitForConnection(peer.deviceAddress, peer.deviceStatus, CONNECTION_TIMEOUT_MS, () => {
        wifiManager.p2pConnect(config);
        // Keep discovery alive until the request is submitted so the scanned
        // random address remains valid for the system confirmation flow.
        this.discovering = false;
      }, rejectionSignal);
      const group = await this.waitForCurrentGroup(4000);
      if (group.groupName !== invitation.groupName) {
        this.ownsGroup = true;
        await this.removeOwnedGroup();
        throw new Error('连接到了其他 P2P 组，已安全退出并继续查找');
      }
      if (group.goIpAddress.length === 0) {
        throw new Error('已连接 P2P，但系统未返回队长地址');
      }
      this.ownsGroup = true;
      this.lastMemberAttemptGroupName = '';
      return group.goIpAddress;
    } catch (err) {
      const connectionError = err as Error;
      await this.cancelPendingMemberConnect();
      throw connectionError;
    }
  }

  private waitForConnection(
    deviceAddress: string,
    initialDeviceStatus: wifiManager.P2pDeviceStatus,
    timeoutMs: number,
    startConnection?: () => void,
    rejectionSignal?: Promise<Error>
  ): Promise<wifiManager.WifiP2pLinkedInfo> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let requestStarted = false;
      let requestObserved = initialDeviceStatus === wifiManager.P2pDeviceStatus.INVITED;
      let lastDeviceStatus = initialDeviceStatus;
      let peerPollTimer: number = -1;
      const cleanup = (): void => {
        clearTimeout(timer);
        if (peerPollTimer >= 0) {
          clearTimeout(peerPollTimer);
        }
        wifiManager.off('p2pConnectionChange', connectionCallback);
        wifiManager.off('p2pPeerDeviceChange', peerCallback);
      };
      const rejectOnce = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };
      const connectionCallback = (info: wifiManager.WifiP2pLinkedInfo): void => {
        if (settled) {
          return;
        }
        if (info.connectState === wifiManager.P2pConnectState.CONNECTED) {
          settled = true;
          cleanup();
          resolve(info);
        } else if (requestStarted &&
          info.connectState === wifiManager.P2pConnectState.DISCONNECTED) {
          rejectOnce(new Error(JOIN_REJECTED_MESSAGE));
        }
      };
      const peerCallback = (peers: wifiManager.WifiP2pDevice[]): void => {
        for (let i = 0; i < peers.length; i++) {
          if (peers[i].deviceAddress !== deviceAddress) {
            continue;
          }
          const status = peers[i].deviceStatus;
          if (status !== lastDeviceStatus &&
            (status === wifiManager.P2pDeviceStatus.INVITED ||
              status === wifiManager.P2pDeviceStatus.UNAVAILABLE)) {
            requestObserved = true;
            lastDeviceStatus = status;
            return;
          }
          if (status === wifiManager.P2pDeviceStatus.FAILED ||
            (requestObserved && status === wifiManager.P2pDeviceStatus.AVAILABLE)) {
            rejectOnce(new Error(JOIN_REJECTED_MESSAGE));
            return;
          }
          lastDeviceStatus = status;
        }
      };
      const pollPeerStatus = async (): Promise<void> => {
        if (settled) {
          return;
        }
        try {
          peerCallback(await wifiManager.getP2pPeerDevices());
        } catch (_e) {
          // Event callbacks remain authoritative if a poll temporarily fails.
        }
        if (!settled) {
          peerPollTimer = setTimeout(() => {
            void pollPeerStatus();
          }, 350);
        }
      };
      const timer = setTimeout(() => {
        rejectOnce(new Error(JOIN_CONFIRM_TIMEOUT_MESSAGE));
      }, timeoutMs);
      wifiManager.on('p2pConnectionChange', connectionCallback);
      wifiManager.on('p2pPeerDeviceChange', peerCallback);
      if (startConnection) {
        try {
          requestStarted = true;
          startConnection();
        } catch (err) {
          rejectOnce(err as Error);
          return;
        }
      }
      if (rejectionSignal !== undefined) {
        void rejectionSignal.then((error: Error) => {
          rejectOnce(error);
        });
      }
      void pollPeerStatus();
      void (async () => {
        try {
          const current = await wifiManager.getP2pLinkedInfo();
          if (current.connectState === wifiManager.P2pConnectState.CONNECTED) {
            connectionCallback(current);
          }
        } catch (_e) {
          // The connection event remains authoritative while setup is in progress.
        }
      })();
    });
  }

  private async resetPreviousMemberAttempt(invitation: P2pRoomInvitation): Promise<void> {
    if (this.lastMemberAttemptGroupName.length === 0) {
      return;
    }
    const previousGroupName = this.lastMemberAttemptGroupName;
    try {
      wifiManager.p2pCancelConnect();
    } catch (_e) {
      // There may be no pending invitation left to cancel.
    }
    await sleep(200);
    try {
      const linked = await wifiManager.getP2pLinkedInfo();
      if (linked.connectState === wifiManager.P2pConnectState.CONNECTED) {
        const group = await wifiManager.getCurrentGroup();
        if (group.groupName !== previousGroupName && group.groupName !== invitation.groupName) {
          throw new Error('设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
        }
        wifiManager.removeGroup();
        await this.waitForDisconnected(MEMBER_GROUP_RELEASE_TIMEOUT_MS);
      }
      this.ownsGroup = false;
      this.lastMemberAttemptGroupName = '';
    } catch (err) {
      const error = err as Error;
      if (error.message.indexOf('正在使用其他 P2P') >= 0) {
        throw error;
      }
      throw p2pError(error, '上次连接尚未释放，请稍后再试');
    }
  }

  private async cancelPendingMemberConnect(): Promise<void> {
    try {
      wifiManager.p2pCancelConnect();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`WifiP2pManager p2pCancelConnect: ${e.message}`);
    }
    try {
      wifiManager.stopDiscoverDevices();
    } catch (_e) {
      // Discovery is normally stopped by negotiation; this is best-effort cleanup.
    }
    // The manager flag must be reset because P2P negotiation may stop system
    // discovery even when the request is rejected or times out.
    this.discovering = false;
  }

  private async waitForDisconnected(timeoutMs: number): Promise<void> {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      const linked = await wifiManager.getP2pLinkedInfo();
      if (linked.connectState === wifiManager.P2pConnectState.DISCONNECTED) {
        return;
      }
      await sleep(150);
    }
    throw new Error('上次 P2P 连接释放超时');
  }

  async abortMemberJoin(): Promise<void> {
    await this.stopDiscovery();
    if (this.lastMemberAttemptGroupName.length > 0) {
      await this.cancelPendingMemberConnect();
    }
    await this.removeOwnedGroup();
  }

  private async waitForCurrentGroup(timeoutMs: number): Promise<wifiManager.WifiP2pGroupInfo> {
    const startedAt = Date.now();
    let lastError = '';
    while (Date.now() - startedAt < timeoutMs) {
      try {
        const group = await wifiManager.getCurrentGroup();
        if (group.groupName.length > 0) {
          return group;
        }
      } catch (err) {
        lastError = (err as Error).message ?? '';
      }
      await sleep(250);
    }
    throw new Error(lastError.length > 0 ? lastError : '系统未返回当前 P2P 组信息');
  }

  private async stopDiscovery(): Promise<void> {
    if (!this.discovering) {
      return;
    }
    try {
      wifiManager.stopDiscoverDevices();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`WifiP2pManager stopDiscoverDevices: ${e.message}`);
    }
    this.discovering = false;
  }

  private async removeOwnedGroup(): Promise<void> {
    if (!this.ownsGroup) {
      return;
    }
    try {
      wifiManager.removeGroup();
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`WifiP2pManager removeGroup: ${e.message}`);
    }
    this.ownsGroup = false;
  }

  async teardown(): Promise<void> {
    await this.abortMemberJoin();
  }
}
