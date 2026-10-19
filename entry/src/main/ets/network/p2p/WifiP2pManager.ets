import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { P2pRoomInvitation, validateP2pRoomInvitation } from './P2pInvitation';

const EMPTY_DEVICE_ADDRESS: string = '00:00:00:00:00:00';
const CONNECTION_TIMEOUT_MS: number = 25000;
const DISCOVERY_TIMEOUT_MS: number = 30000;
const DISCOVERY_REFRESH_WAIT_MS: number = 3000;
const MEMBER_GROUP_RELEASE_TIMEOUT_MS: number = 3000;
const CONNECTION_STATE_POLL_MS: number = 350;
const GROUP_OWNER_CAPABILITY: number = 1;
const FOREIGN_P2P_MESSAGE: string = '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试';
const JOIN_REJECTED_MESSAGE: string = '队长已拒绝本次加入请求，请和队长确认后再试一次';
const JOIN_CANCELLED_MESSAGE: string = '本次加入已取消';
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
    return new Error('缺少附近设备权限，请在系统设置中允许同拍使用 Wi-Fi');
  }
  return new Error(message.length > 0 ? message : fallback);
}

export class WifiP2pManager {
  private static groupReleaseOperation: Promise<void> | undefined = undefined;
  private ownsGroup: boolean = false;
  private ownedGroupName: string = '';
  private groupRemovalOperation: Promise<void> | undefined = undefined;
  private discovering: boolean = false;
  private lastMemberAttemptGroupName: string = '';
  private cancelMemberGroupWait: (() => void) | undefined = undefined;
  private memberAttemptGeneration: number = 0;

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
    // removeGroup() only submits the system request. A new manager must wait
    // for the old owner's confirmed release before classifying a live group.
    let releasing = WifiP2pManager.groupReleaseOperation;
    while (releasing !== undefined) {
      await releasing;
      releasing = WifiP2pManager.groupReleaseOperation;
    }
    try {
      let linked = await wifiManager.getP2pLinkedInfo();
      // Exit may register its release while this SDK query is in flight (for
      // example after stopping discovery). Do not classify that stale snapshot.
      releasing = WifiP2pManager.groupReleaseOperation;
      while (releasing !== undefined) {
        await releasing;
        linked = await wifiManager.getP2pLinkedInfo();
        releasing = WifiP2pManager.groupReleaseOperation;
      }
      if (linked.connectState === wifiManager.P2pConnectState.CONNECTED && !this.ownsGroup) {
        throw new Error(FOREIGN_P2P_MESSAGE);
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
      this.ownedGroupName = group.groupName;
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

  async prepareMemberDiscovery(targetDeviceName?: string): Promise<void> {
    await this.assertReadyForOneBeat();
    if (this.discovering) {
      return;
    }
    // 预热命中时缓存里可能已有队长设备，直接启动一轮并返回，省去死等首个事件。
    if (targetDeviceName !== undefined && targetDeviceName.length > 0) {
      try {
        const cached = await wifiManager.getP2pPeerDevices();
        for (let i = 0; i < cached.length; i++) {
          if (cached[i].deviceName.trim() === targetDeviceName) {
            wifiManager.startDiscoverDevices();
            this.discovering = true;
            return;
          }
        }
      } catch (_e) {
        // 读取缓存失败则退回等待首个设备事件的流程
      }
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
    const leaderDeviceName = invitation.leaderDeviceName?.trim() ?? '';
    await this.resetPreviousMemberAttempt();
    // 不在此处 stopDiscovery：若已预热（discovering 为 true），prepareMemberDiscovery
    // 会直接复用现有发现结果，从而省去一次冷启动等待。
    await this.prepareMemberDiscovery(leaderDeviceName);
    const startedAt = Date.now();
    const attempted: Set<string> = new Set();
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
            if (lastError === JOIN_REJECTED_MESSAGE || lastError === JOIN_CONFIRM_TIMEOUT_MESSAGE ||
              lastError === FOREIGN_P2P_MESSAGE || lastError === JOIN_CANCELLED_MESSAGE ||
              (this.ownsGroup && this.ownedGroupName === invitation.groupName)) {
              // Once this attempt has joined the expected group, discovery is
              // no longer a useful retry. Preserve its readiness error; the
              // caller's abort releases the verified group before another join.
              throw connectionError;
            }
            await this.resetPreviousMemberAttempt();
            await this.prepareMemberDiscovery(leaderDeviceName);
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
    this.cancelMemberGroupWait?.();
    const generation = ++this.memberAttemptGeneration;
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
      // Abort may run after CONNECTED resolves but before the group waiter is
      // installed. The generation also closes that asynchronous handoff gap.
      if (generation !== this.memberAttemptGeneration) {
        throw new Error(JOIN_CANCELLED_MESSAGE);
      }
      const group = await this.waitForMemberGroup(invitation.groupName, 4000, generation);
      if (generation !== this.memberAttemptGeneration) {
        throw new Error(JOIN_CANCELLED_MESSAGE);
      }
      this.lastMemberAttemptGroupName = '';
      return group.goIpAddress;
    } catch (err) {
      const connectionError = err as Error;
      if (generation === this.memberAttemptGeneration) {
        await this.cancelPendingMemberConnect();
      }
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
      const startedAt = Date.now();
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
      const connectionCallback = (info: wifiManager.WifiP2pLinkedInfo, source: string = 'event'): void => {
        if (settled) {
          return;
        }
        if (info.connectState === wifiManager.P2pConnectState.CONNECTED) {
          settled = true;
          cleanup();
          console.info(`[JoinDiag] stage=p2p-connected source=${source} elapsedMs=${Date.now() - startedAt}`);
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
      const pollConnectionStatus = async (): Promise<void> => {
        if (settled) {
          return;
        }
        try {
          const current = await wifiManager.getP2pLinkedInfo();
          if (settled) {
            return;
          }
          // Some builds delay or omit CONNECTED events. Querying the current
          // state lets a ready link proceed; initial DISCONNECTED is normal
          // during negotiation and must not be treated as a rejected request.
          if (current.connectState === wifiManager.P2pConnectState.CONNECTED) {
            connectionCallback(current, 'poll');
            return;
          }
        } catch (_e) {
          // Temporary query failure does not invalidate the event-driven path.
        }
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
            void pollConnectionStatus();
          }, CONNECTION_STATE_POLL_MS);
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
      void pollConnectionStatus();
    });
  }

  private async resetPreviousMemberAttempt(): Promise<void> {
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
        const group = await this.waitForCurrentGroup(MEMBER_GROUP_RELEASE_TIMEOUT_MS);
        // A new invitation cannot grant ownership of an existing system group.
        // Only the group requested by the previous attempt may be released.
        if (group.groupName !== previousGroupName) {
          throw new Error(FOREIGN_P2P_MESSAGE);
        }
        this.ownsGroup = true;
        this.ownedGroupName = group.groupName;
        await this.removeOwnedGroup();
      } else if (linked.connectState !== wifiManager.P2pConnectState.DISCONNECTED) {
        await this.waitForDisconnected(MEMBER_GROUP_RELEASE_TIMEOUT_MS);
      }
      this.ownsGroup = false;
      this.ownedGroupName = '';
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
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let pollTimer: number = -1;
      const timer = setTimeout(() => {
        settled = true;
        if (pollTimer >= 0) {
          clearTimeout(pollTimer);
        }
        reject(new Error('上次 P2P 连接释放超时，请稍后重试退出队伍'));
      }, timeoutMs);
      const poll = async (): Promise<void> => {
        try {
          const linked = await wifiManager.getP2pLinkedInfo();
          if (settled) {
            return;
          }
          if (linked.connectState === wifiManager.P2pConnectState.DISCONNECTED) {
            settled = true;
            clearTimeout(timer);
            resolve();
            return;
          }
        } catch (_e) {
          // A transient SDK query is not proof of release. The deadline also
          // bounds a query whose native Promise never returns.
        }
        if (!settled) {
          pollTimer = setTimeout(() => { void poll(); }, 150);
        }
      };
      void poll();
    });
  }

  async abortMemberJoin(): Promise<void> {
    this.memberAttemptGeneration++;
    this.cancelMemberGroupWait?.();
    await this.stopDiscovery();
    if (this.lastMemberAttemptGroupName.length > 0) {
      await this.cancelPendingMemberConnect();
    }
    await this.removeOwnedGroup();
  }

  private waitForMemberGroup(expectedGroupName: string,
    timeoutMs: number, generation: number): Promise<wifiManager.WifiP2pGroupInfo> {
    return new Promise((resolve, reject) => {
      const startedAt = Date.now();
      let settled = false;
      let matchedGroup = false;
      let lastError = '';
      let pollTimer: number = -1;
      const cleanup = (): void => {
        clearTimeout(timer);
        if (pollTimer >= 0) {
          clearTimeout(pollTimer);
        }
        if (this.cancelMemberGroupWait === cancel) {
          this.cancelMemberGroupWait = undefined;
        }
      };
      const rejectOnce = (error: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };
      const cancel = (): void => { rejectOnce(new Error(JOIN_CANCELLED_MESSAGE)); };
      const timer = setTimeout(() => {
        console.info(`[JoinDiag] stage=p2p-group state=timeout elapsedMs=${Date.now() - startedAt}`);
        rejectOnce(new Error(matchedGroup ? '已连接 P2P，但系统未返回队长地址' :
          (lastError.length > 0 ? lastError : '系统未返回当前 P2P 组信息')));
      }, timeoutMs);
      const poll = async (): Promise<void> => {
        try {
          const group = await wifiManager.getCurrentGroup();
          if (settled) {
            return;
          }
          if (generation !== this.memberAttemptGeneration) {
            cancel();
            return;
          }
          if (group.groupName.length > 0) {
            if (group.groupName !== expectedGroupName) {
              rejectOnce(new Error(FOREIGN_P2P_MESSAGE));
              return;
            }
            // CONNECTED can precede the GO address. Record the verified group
            // before waiting for it, so abort/timeout can release our own link.
            this.ownsGroup = true;
            this.ownedGroupName = group.groupName;
            if (group.goIpAddress.length > 0) {
              settled = true;
              cleanup();
              console.info(`[JoinDiag] stage=p2p-group state=ready elapsedMs=${Date.now() - startedAt}`);
              resolve(group);
              return;
            }
            if (!matchedGroup) {
              console.info(`[JoinDiag] stage=p2p-group state=waiting-address elapsedMs=${Date.now() - startedAt}`);
            }
            matchedGroup = true;
          }
        } catch (err) {
          if (settled) {
            return;
          }
          lastError = (err as Error).message ?? '';
        }
        if (!settled) {
          pollTimer = setTimeout(() => { void poll(); }, 250);
        }
      };
      this.cancelMemberGroupWait = cancel;
      void poll();
    });
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
    if (this.groupRemovalOperation !== undefined) {
      await this.groupRemovalOperation;
      return;
    }
    if (!this.ownsGroup) {
      return;
    }
    const preceding = WifiP2pManager.groupReleaseOperation;
    const removal = this.removeOwnedGroupExclusive(preceding);
    this.groupRemovalOperation = removal;
    WifiP2pManager.groupReleaseOperation = removal;
    try {
      await removal;
    } finally {
      if (this.groupRemovalOperation === removal) {
        this.groupRemovalOperation = undefined;
      }
      if (WifiP2pManager.groupReleaseOperation === removal) {
        WifiP2pManager.groupReleaseOperation = undefined;
      }
    }
  }

  private async removeOwnedGroupExclusive(preceding?: Promise<void>): Promise<void> {
    if (preceding !== undefined) {
      await preceding;
    }
    const startedAt = Date.now();
    try {
      const linked = await wifiManager.getP2pLinkedInfo();
      if (linked.connectState === wifiManager.P2pConnectState.CONNECTED) {
        const group = await wifiManager.getCurrentGroup();
        if (group.groupName.length === 0) {
          throw new Error('系统尚未返回上次 P2P 组信息，请稍后重试');
        }
        // Ownership comes from the group this instance actually created/joined,
        // never from a prefix or a newly supplied invitation. A replaced group
        // may belong to casting/sharing, and must survive our old session exit.
        if (group.groupName !== this.ownedGroupName) {
          this.ownsGroup = false;
          this.ownedGroupName = '';
          console.info('[JoinDiag] stage=p2p-release state=ownership-changed');
          return;
        }
        wifiManager.removeGroup();
        await this.waitForDisconnected(MEMBER_GROUP_RELEASE_TIMEOUT_MS);
      } else if (linked.connectState !== wifiManager.P2pConnectState.DISCONNECTED) {
        await this.waitForDisconnected(MEMBER_GROUP_RELEASE_TIMEOUT_MS);
      }
      this.ownsGroup = false;
      this.ownedGroupName = '';
      console.info(`[JoinDiag] stage=p2p-release state=disconnected elapsedMs=${Date.now() - startedAt}`);
    } catch (err) {
      // Keep the owner available for retry: forgetting it here would make the
      // still-live app connection indistinguishable from a foreign connection.
      console.warn(`[JoinDiag] stage=p2p-release state=failed elapsedMs=${Date.now() - startedAt}`);
      throw p2pError(err as Error, '上次 P2P 连接尚未释放，请稍后重试');
    }
  }

  async teardown(): Promise<void> {
    await this.abortMemberJoin();
  }
}
