import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { scanCore, scanBarcode } from '@kit.ScanKit';
import { AppSession, MemberJoinStage } from '../app/AppSession';
import { isUserCancelled, logUserFailure, userErrorMessage } from '../common/UserFeedback';
import { joinCodeFromPayload, parseJoinQrPayload } from '../network/join/JoinQrPayload';
import { P2pRoomInvitation } from '../network/p2p/P2pInvitation';
import {
  bluetoothPermissionDeniedHint,
  cameraPermissionDeniedHint,
  ensureBluetoothDiscoveryPermission,
  ensureCameraPermission,
  ensureTeamNetworkPermissions,
  hasTeamNetworkPermissions,
  isBluetoothDiscoveryAvailable,
  openWirelessSettings,
  teamNetworkAccessUnavailableHint,
  teamNetworkPermissionDeniedHint,
  verifyTeamNetworkAccess
} from '../network/join/TeamNetworkPermissions';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, TEAL, CARD_SHADOW, CONTROL_SHADOW } from '../components/ComicKit';

const PLAYER_DISPLAY_NAME_KEY: string = 'playerDisplayName';
const JOIN_HERO_HEIGHT: number = 162;

@Entry
@Component
struct MemberJoinPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @State displayName: string = 'Member';
  @State joinCode: string = '';
  @State status: string = '';
  @State joining: boolean = false;
  @State scanning: boolean = false;
  @State wirelessSettingsAvailable: boolean = false;
  private initializationToken: number = 0;
  private joinRequestToken: number = 0;
  private pageActive: boolean = true;

  aboutToAppear(): void {
    this.pageActive = true;
    const params = router.getParams() as Record<string, string>;
    if (params !== undefined && params['displayName'] !== undefined && params['displayName'].length > 0) {
      this.displayName = params['displayName'];
    } else {
      const saved = AppStorage.get<string>(PLAYER_DISPLAY_NAME_KEY) ?? '';
      if (saved.length > 0) {
        this.displayName = saved;
      }
    }
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.initializationToken++;
    this.joinRequestToken++;
  }

  private persistDisplayName(): void {
    const trimmed = this.displayName.trim();
    if (trimmed.length > 0) {
      AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, trimmed);
    }
  }

  private async initialize(): Promise<void> {
    const initializationToken = ++this.initializationToken;
    this.status = '';
    try {
      await AppSession.reset();
      if (!this.pageActive || initializationToken !== this.initializationToken) {
        return;
      }
      const session = await AppSession.prepareMember(this.displayName);
      if (!this.canWarmUpDiscovery(session, initializationToken)) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const granted = await hasTeamNetworkPermissions(ctx);
      if (!this.canWarmUpDiscovery(session, initializationToken)) {
        return;
      }
      const accessible = granted && await verifyTeamNetworkAccess();
      if (!this.canWarmUpDiscovery(session, initializationToken)) {
        return;
      }
      if (accessible) {
        await session.p2p.prepareMemberDiscovery();
      } else if (granted) {
        this.wirelessSettingsAvailable = true;
        this.status = teamNetworkAccessUnavailableHint();
      }
    } catch (err) {
      logUserFailure('join-prepare', err);
      if (this.pageActive && initializationToken === this.initializationToken && !this.joining) {
        this.status = userErrorMessage(err, '暂时无法准备加入，请重试');
      }
    }
  }

  private canWarmUpDiscovery(session: AppSession, initializationToken: number): boolean {
    // A join only needs the old session's teardown barrier. Its permission and
    // discovery work must not wait for, or be overwritten by, background warmup.
    return this.pageActive && initializationToken === this.initializationToken &&
      !this.joining && AppSession.get() === session;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('‹').fontSize(32).width(32).onClick(() => router.back())
          Column({ space: 0 }) {
            Text('加入队伍').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
            Text('SCAN OR ENTER THE CODE').fontSize(10).fontWeight(FontWeight.Bold).letterSpacing(1).width('100%')
          }.layoutWeight(1)
          Text('队员')
            .fontSize(12)
            .fontWeight(900)
            .backgroundColor(LILAC)
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .border({ width: 1, color: INK })
            .borderRadius(4)
            .shadow(CONTROL_SHADOW)
        }.width('100%')

        Column() {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Image($rawfile('comic/decor/join_invitation_paper.png'))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .hitTestBehavior(HitTestMode.None)
            ComicCharacter({ pose: 'lilroll' })
              .width(JOIN_HERO_HEIGHT)
              .height(JOIN_HERO_HEIGHT)
              .margin({ right: 3, bottom: -8 })
              .rotate({ angle: 5 })
            Column({ space: 5 }) {
              Text('拿到队长的邀请了吗？')
                .fontSize(19)
                .fontWeight(900)
                .fontStyle(FontStyle.Italic)
                .width('100%')
              Text('扫二维码最快，\n也可以输入 6 位加入码。')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .lineHeight(18)
                .width('100%')
            }
            .width('100%')
            .padding({ left: 14, right: 140, top: 6, bottom: 48 })
          }
          .width('100%')
          .height(JOIN_HERO_HEIGHT)
          .clip(true)
        }
        .width('100%')
        .backgroundColor(TEAL)
        .border({ width: 2, color: INK })
        .borderRadius(8)
        .shadow(CARD_SHADOW)

        Column({ space: 10 }) {
          Row() {
            Column({ space: 2 }) {
              Text('方式 A').fontSize(10).fontWeight(900).fontColor('#66615A').width('100%')
              Text('扫描队长二维码').fontSize(19).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
            }.layoutWeight(1)
            Text('推荐')
              .fontSize(10)
              .fontWeight(900)
              .backgroundColor(CORAL)
              .padding({ left: 7, right: 7, top: 4, bottom: 4 })
              .border({ width: 1, color: INK })
              .borderRadius(3)
              .shadow(CONTROL_SHADOW)
              .rotate({ angle: 3 })
          }.width('100%')
          Text('扫码需要相机和 Wi-Fi')
            .fontSize(12)
            .fontColor('#66615A')
            .width('100%')
          Button(this.scanning ? '正在扫码…' : '打开相机扫码  ›')
            .backgroundColor(CORAL)
            .fontColor(INK)
            .fontSize(18)
            .fontWeight(900)
            .border({ width: 1.5, color: INK })
            .borderRadius(6)
            .shadow(CONTROL_SHADOW)
            .height(52)
            .width('100%')
            .enabled(!this.joining && !this.scanning)
            .onClick(() => {
              void this.scanJoin();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#FFFDF7')
        .border({ width: 1.5, color: INK })
        .borderRadius(7)
        .shadow(CARD_SHADOW)

        Row({ space: 10 }) {
          Divider().color(INK).strokeWidth(1).layoutWeight(1)
          Text('或者').fontSize(11).fontWeight(900)
          Divider().color(INK).strokeWidth(1).layoutWeight(1)
        }.width('100%')

        Column({ space: 10 }) {
          Text('方式 B').fontSize(10).fontWeight(900).fontColor('#66615A').width('100%')
          Text('输入 6 位加入码').fontSize(19).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
          Text('加入码需要蓝牙发现')
            .fontSize(12)
            .fontColor('#66615A')
            .width('100%')
          TextInput({ text: this.joinCode, placeholder: '例如 482913' })
            .height(50)
            .fontSize(24)
            .fontWeight(900)
            .letterSpacing(5)
            .backgroundColor('#F1EBDF')
            .border({ width: 1.5, color: INK })
            .borderRadius(6)
            .type(InputType.Number)
            .maxLength(6)
            .onChange((v: string) => {
              this.joinCode = v.replace(/[^\d]/g, '').slice(0, 6);
            })
          Button(this.joining ? '正在连接…' : '用加入码进入  ›')
            .backgroundColor(LILAC)
            .fontColor(INK)
            .fontSize(18)
            .fontWeight(900)
            .border({ width: 1.5, color: INK })
            .borderRadius(6)
            .shadow(CONTROL_SHADOW)
            .height(52)
            .width('100%')
            .enabled(!this.joining && !this.scanning && this.joinCode.length === 6)
            .onClick(() => {
              void this.joinWithCode(this.joinCode);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#FFFDF7')
        .border({ width: 1.5, color: INK })
        .borderRadius(7)
        .shadow(CARD_SHADOW)

        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(12)
            .fontColor('#333333')
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .padding({ left: 2, right: 2, top: 2 })
            .onClick(() => {
              if (this.wirelessSettingsAvailable) {
                const ctx = getContext(this) as common.UIAbilityContext;
                void openWirelessSettings(ctx);
              }
            })
        }
      }
      .padding({
        left: 20,
        right: 20,
        top: 12 + this.topSafeInset,
        bottom: 28 + this.bottomSafeInset
      })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private async ensureP2pReady(): Promise<boolean> {
    const requestToken = this.joinRequestToken;
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted = await ensureTeamNetworkPermissions(ctx);
    if (!this.isCurrentJoin(requestToken)) {
      return false;
    }
    if (!granted) {
      this.status = teamNetworkPermissionDeniedHint();
      return false;
    }
    const accessible = await verifyTeamNetworkAccess();
    if (!this.isCurrentJoin(requestToken)) {
      return false;
    }
    if (!accessible) {
      this.wirelessSettingsAvailable = true;
      this.status = teamNetworkAccessUnavailableHint();
      return false;
    }
    this.wirelessSettingsAvailable = false;
    return true;
  }

  private isCurrentJoin(requestToken: number, session?: AppSession): boolean {
    // A response from a retired room cannot replace the current room's status.
    return this.pageActive && requestToken === this.joinRequestToken &&
      (session === undefined || AppSession.get() === session);
  }

  private showJoinFailure(error: Object, fallback: string): void {
    const message = userErrorMessage(error, fallback);
    this.status = message;
    this.wirelessSettingsAvailable = message.indexOf('Wi-Fi') >= 0;
  }

  private updateJoinProgress(stage: MemberJoinStage): void {
    if (stage === 'connecting') {
      this.status = '正在连接队长，请在队长手机上确认…';
    } else if (stage === 'joining') {
      this.status = '已建立局域连接，正在同步队伍…';
    } else {
      this.status = '队伍已连接，正在准备进入大厅…';
    }
  }

  private async joinInvitation(invitation: P2pRoomInvitation): Promise<void> {
    if (this.joining || this.scanning) {
      return;
    }
    this.initializationToken++;
    const requestToken = ++this.joinRequestToken;
    this.joining = true;
    let joiningSession: AppSession | undefined = undefined;
    try {
      if (!(await this.ensureP2pReady())) {
        return;
      }
      const session = await AppSession.prepareMember(this.displayName);
      joiningSession = session;
      if (!this.isCurrentJoin(requestToken, session)) {
        return;
      }
      this.status = '正在扫描附近 P2P 设备并连接队长…';
      await session.memberJoinWithInvitation(invitation, (stage) => {
        if (this.isCurrentJoin(requestToken, session)) {
          this.updateJoinProgress(stage);
        }
      });
      if (!this.isCurrentJoin(requestToken, session)) {
        return;
      }
      this.persistDisplayName();
      this.status = '已同步时钟，正在进入…';
      await router.replaceUrl({ url: 'pages/LeaderLobbyPage', params: { reuse: '1' } });
    } catch (err) {
      logUserFailure('join-invitation', err);
      if (this.isCurrentJoin(requestToken, joiningSession)) {
        this.showJoinFailure(err, '加入失败，请重试或重新扫码');
      }
    } finally {
      if (this.isCurrentJoin(requestToken)) {
        this.joining = false;
      }
    }
  }

  private async joinWithCode(code: string): Promise<void> {
    if (this.joining || this.scanning) {
      return;
    }
    this.initializationToken++;
    const requestToken = ++this.joinRequestToken;
    this.joining = true;
    let joiningSession: AppSession | undefined = undefined;
    try {
      if (!(await this.ensureP2pReady())) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const bluetoothGranted = await ensureBluetoothDiscoveryPermission(ctx);
      if (!this.isCurrentJoin(requestToken)) {
        return;
      }
      if (!bluetoothGranted) {
        this.status = bluetoothPermissionDeniedHint();
        return;
      }
      if (!isBluetoothDiscoveryAvailable()) {
        this.status = '手输加入码需要打开蓝牙；也可以改用扫码加入';
        return;
      }
      const session = await AppSession.prepareMember(this.displayName);
      joiningSession = session;
      if (!this.isCurrentJoin(requestToken, session)) {
        return;
      }
      this.status = '正在通过蓝牙查找附近房间…';
      await session.memberJoinByCode(code, () => {
        if (this.isCurrentJoin(requestToken, session)) {
          this.status = '已找到队伍，正在请求连接队长…';
        }
      }, (stage) => {
        if (this.isCurrentJoin(requestToken, session)) {
          this.updateJoinProgress(stage);
        }
      });
      if (!this.isCurrentJoin(requestToken, session)) {
        return;
      }
      this.persistDisplayName();
      this.status = '已同步时钟，正在进入…';
      await router.replaceUrl({ url: 'pages/LeaderLobbyPage', params: { reuse: '1' } });
    } catch (err) {
      logUserFailure('join-code', err);
      if (this.isCurrentJoin(requestToken, joiningSession)) {
        this.showJoinFailure(err, '加入失败，请重试或改用扫码');
      }
    } finally {
      if (this.isCurrentJoin(requestToken)) {
        this.joining = false;
      }
    }
  }

  private async scanJoin(): Promise<void> {
    if (this.joining || this.scanning) {
      return;
    }
    this.initializationToken++;
    const requestToken = ++this.joinRequestToken;
    this.scanning = true;
    this.status = '';
    this.wirelessSettingsAvailable = false;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const cameraOk = await ensureCameraPermission(ctx);
      if (!this.isCurrentJoin(requestToken)) {
        return;
      }
      if (!cameraOk) {
        this.status = cameraPermissionDeniedHint();
        return;
      }
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE]
      };
      const result = await scanBarcode.startScanForResult(ctx, options);
      if (!this.isCurrentJoin(requestToken)) {
        return;
      }
      const payload = parseJoinQrPayload(result.originalValue);
      const code = joinCodeFromPayload(payload);
      this.joinCode = code;
      this.status = `已识别加入码 ${code}，正在扫描附近 P2P 设备…`;
      this.scanning = false;
      await this.joinInvitation(payload);
    } catch (err) {
      if (!isUserCancelled(err)) {
        logUserFailure('join-scan', err);
        if (this.isCurrentJoin(requestToken)) {
          this.showJoinFailure(err, '扫码失败，请重试或输入加入码');
        }
      }
    } finally {
      if (this.isCurrentJoin(requestToken)) {
        this.scanning = false;
      }
    }
  }
}
