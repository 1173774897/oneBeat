import { common } from '@kit.AbilityKit';
import { router, RectShape } from '@kit.ArkUI';
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
import { ComicCharacter, PAPER, INK, CORAL, LILAC, WHITE, CONTROL_SHADOW } from '../components/ComicKit';
import { TeamTicketBackdrop, TeamWifiFooter } from '../components/TeamEntryVisuals';
import { ActionButton } from '../components/ActionButton';

const PLAYER_DISPLAY_NAME_KEY: string = 'playerDisplayName';
const JOIN_PAGE_SIDE_INSET: number = 18;
const JOIN_HEADER_HEIGHT: number = 36;
const JOIN_HERO_HEIGHT: number = 180;
const JOIN_HERO_TEXT_WIDTH_RATIO: number = 0.46;
const JOIN_HERO_ILLUSTRATION_WIDTH: number = 246;
const JOIN_HERO_ILLUSTRATION_X_OFFSET: number = 0;
const JOIN_HERO_ART_WIDTH: number = 230;
const JOIN_HERO_ART_HEIGHT: number = 276;
const JOIN_HERO_ART_Y: number = -12;
const JOIN_TICKET_HEIGHT: number = 360;
const JOIN_SCAN_HEIGHT: number = 156;
const JOIN_DIVIDER_HEIGHT: number = 24;
const JOIN_CODE_HEIGHT: number = 180;
const JOIN_CONTENT_INSET: number = 20;
const JOIN_ACTION_HEIGHT: number = 46;

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
  @State private contentWidth: number = 360;
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
      Column() {
        Row({ space: 2 }) {
          Text('‹').fontSize(32).fontColor(INK).width(32).height(JOIN_HEADER_HEIGHT)
            .accessibilityText('返回多人练习').onClick(() => router.back())
          Text('加入队伍').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).layoutWeight(1)
          Text('队员').fontSize(13).fontWeight(900).fontColor(INK)
            .padding({ left: 12, right: 12, top: 3, bottom: 3 }).backgroundColor(LILAC)
            .border({ width: 1.4, color: INK }).borderRadius(4)
            .rotate({ angle: 2 })
            .shadow(CONTROL_SHADOW)
        }.width('100%').height(JOIN_HEADER_HEIGHT)
        this.invitationHero()
        this.joinTicket()
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor('#333333').fontWeight(FontWeight.Bold)
            .width('100%').lineHeight(18).margin({ top: 14 })
            .onClick(() => {
              if (this.wirelessSettingsAvailable) {
                const ctx = getContext(this) as common.UIAbilityContext;
                void openWirelessSettings(ctx);
              }
            })
        }
        TeamWifiFooter().margin({ top: 16 })
      }.width('100%').padding({ left: JOIN_PAGE_SIDE_INSET, right: JOIN_PAGE_SIDE_INSET,
        top: 8 + this.topSafeInset, bottom: 12 + this.bottomSafeInset })
    }.width('100%').height('100%').backgroundColor(PAPER)
      .onAreaChange((_old: Area, area: Area) => {
        const width = Number(area.width) - JOIN_PAGE_SIDE_INSET * 2;
        if (width > 0 && Math.abs(width - this.contentWidth) > 0.1) { this.contentWidth = width; }
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private invitationArtworkX(): number {
    const textWidth = this.contentWidth * JOIN_HERO_TEXT_WIDTH_RATIO;
    const remainingWidth = this.contentWidth - textWidth;
    // The fixed-size scene includes the flower overhang beyond the character's
    // 230vp box. Center its complete 246vp footprint in the remaining column.
    return textWidth + (remainingWidth - JOIN_HERO_ILLUSTRATION_WIDTH) / 2 +
      JOIN_HERO_ILLUSTRATION_X_OFFSET;
  }

  @Builder
  private invitationHero() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Image($rawfile('comic/decor/ticket-halftone-coral.svg')).width(142).height(227.2)
          .position({ x: 8, y: -28 }).hitTestBehavior(HitTestMode.None)
        Image($rawfile('comic/decor/ticket-halftone-ink-cloud.svg')).width(104).height(94.5)
          .position({ x: 10, y: 5 }).hitTestBehavior(HitTestMode.None)
        Image($rawfile('comic/decor/ticket-halftone-lilac-cloud.svg')).width(120).height(200)
          .position({ x: 94, y: -8 }).hitTestBehavior(HitTestMode.None)
        ComicCharacter({ avatar: 'cloud', pose: 'cloud-phone' }).width(JOIN_HERO_ART_WIDTH).height(JOIN_HERO_ART_HEIGHT)
          .position({ x: 0, y: JOIN_HERO_ART_Y })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Image($rawfile('vegetation/plant_06.png')).width(92).height(92).objectFit(ImageFit.Contain)
          .position({ x: -20, y: JOIN_HERO_HEIGHT - 92 + 14 }).hitTestBehavior(HitTestMode.None)
        Image($rawfile('vegetation/plant_11.png')).width(84).height(84).objectFit(ImageFit.Contain)
          .position({ x: 145, y: JOIN_HERO_HEIGHT - 84 + 14 }).hitTestBehavior(HitTestMode.None)
      }.width(JOIN_HERO_ILLUSTRATION_WIDTH).height(JOIN_HERO_HEIGHT)
        .position({ x: this.invitationArtworkX(), y: 0 }).clip(false)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Text('拿到队长的\n邀请了吗？').fontSize(27).minFontSize(24).maxFontSize(27)
        .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).lineHeight(34).maxLines(2)
        .width(this.contentWidth * JOIN_HERO_TEXT_WIDTH_RATIO).height(76)
        .position({ x: 0, y: 14 })
      Text('扫码，或输入 6 位加入码\n和大家一起出发。').fontSize(12).fontWeight(FontWeight.Bold)
        .fontColor(INK).lineHeight(20).width(this.contentWidth * JOIN_HERO_TEXT_WIDTH_RATIO)
        .height(50).position({ x: 0, y: 102 })
    }.width('100%').height(JOIN_HERO_HEIGHT)
      // Keep the original vertical crop, but allow the fixed-size centered art
      // into the right page inset rather than cutting through the phone.
      .clipShape(new RectShape({ width: this.contentWidth + JOIN_PAGE_SIDE_INSET, height: JOIN_HERO_HEIGHT }))
  }

  @Builder
  private joinAction(scan: boolean) {
    // Read state here: primitive builder arguments can retain their initial
    // value and leave the six-digit action disabled after code entry.
    ActionButton({
      label: scan ? (this.scanning ? '正在扫码…' : '打开相机扫码  ›') :
        (this.joining ? '正在连接…' : '用加入码进入  ›'),
      active: !this.joining && !this.scanning && (scan || this.joinCode.length === 6),
      controlHeight: JOIN_ACTION_HEIGHT,
      contentPadding: { left: 16, right: 16 },
      labelSize: 18,
      labelWeight: 900,
      fill: scan ? CORAL : LILAC,
      lineWidth: 1.5,
      cornerRadius: 6,
      hardShadow: { offsetX: 2, offsetY: 2, color: INK },
      action: () => {
        if (this.joining || this.scanning || (!scan && this.joinCode.length !== 6)) {
          return;
        }
        if (scan) { void this.scanJoin(); } else { void this.joinWithCode(this.joinCode); }
      }
    })
  }

  @Builder
  private scanMethod() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text('扫描队长二维码').fontSize(19).minFontSize(15).maxFontSize(19)
              .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).maxLines(1)
            Text('推荐').fontSize(10).fontWeight(900).fontColor(WHITE).backgroundColor(CORAL)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 }).borderRadius(8)
          }.width('100%')
          Text('对准队长展示的二维码').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#84868D')
            .width('100%').maxLines(1)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Stack({ alignContent: Alignment.TopEnd }) {
          Image($rawfile('comic/icons/ticket-scan.svg')).width(44).height(44).objectFit(ImageFit.Contain)
          Image($rawfile('comic/icons/ticket-beat-marks.svg')).width(20).height(18).rotate({ angle: 40 })
            .translate({ x: 11, y: -8 })
        }.width(48).height(44).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }.width('100%').height(44)
      Column() {
        this.joinAction(true)
      }.width('100%').margin({ top: 12 })
      Text('扫码需要相机和 Wi-Fi').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#84868D')
        .width('100%').height(16).textAlign(TextAlign.Center).margin({ top: 8 })
    }.width('100%').height(JOIN_SCAN_HEIGHT)
      .padding({ left: JOIN_CONTENT_INSET, right: JOIN_CONTENT_INSET, top: 18, bottom: 12 })
  }

  @Builder
  private codeMethod() {
    Column() {
      Text('输入 6 位加入码').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
        .fontColor(INK).width('100%').height(24)
      Stack() {
        // Keep a single native numeric editor for paste, selection, deletion and
        // accessibility; the six empty marks are decoration, never six focus targets.
        TextInput({ text: this.joinCode, placeholder: '' }).height(46).width('100%').fontSize(24)
          .fontWeight(900).fontColor(INK).letterSpacing(12).textAlign(TextAlign.Center)
          .backgroundColor(PAPER).border({ width: 1.4, color: INK }).borderRadius(6)
          .type(InputType.Number).maxLength(6).accessibilityText('输入六位数字加入码')
          .onChange((value: string) => { this.joinCode = value.replace(/[^\d]/g, '').slice(0, 6); })
        if (this.joinCode.length === 0) {
          Row() {
            ForEach([0, 1, 2, 3, 4, 5], (slot: number) => {
              Text('—').fontSize(23).fontWeight(900).fontColor('#B2B3B8')
                // None on the Row only excludes the Row itself, not its children.
                .hitTestBehavior(HitTestMode.None)
            }, (slot: number): string => slot.toString())
          }.width('100%').height(46).padding({ left: 16, right: 16 })
            .justifyContent(FlexAlign.SpaceEvenly).hitTestBehavior(HitTestMode.None)
            .accessibilityLevel('no-hide-descendants')
        }
      }.width('100%').height(46).margin({ top: 8 })
      Column() {
        this.joinAction(false)
      }.width('100%').margin({ top: 10 })
      Text('加入码需要蓝牙发现').fontSize(11).fontWeight(FontWeight.Bold).fontColor('#84868D')
        .width('100%').height(16).textAlign(TextAlign.Center).margin({ top: 8 })
    }.width('100%').height(JOIN_CODE_HEIGHT)
      .padding({ left: JOIN_CONTENT_INSET, right: JOIN_CONTENT_INSET, top: 8, bottom: 8 })
  }

  @Builder
  private joinTicket() {
    Stack({ alignContent: Alignment.TopStart }) {
      TeamTicketBackdrop({ ticketHeight: JOIN_TICKET_HEIGHT, firstNotchY: 96,
        tearY: JOIN_SCAN_HEIGHT + JOIN_DIVIDER_HEIGHT / 2, fill: '#FFFFFF', halftone: 'join' })
      Column() {
        this.scanMethod()
        Row() {
          Text('或者').fontSize(12).fontWeight(900).fontColor(INK).width(52).height(22)
            .textAlign(TextAlign.Center).backgroundColor('#FFFFFF').border({ width: 1.1, color: INK }).borderRadius(4)
        }.width('100%').height(JOIN_DIVIDER_HEIGHT).justifyContent(FlexAlign.Center).hitTestBehavior(HitTestMode.None)
        this.codeMethod()
      }.width('100%').height(JOIN_TICKET_HEIGHT)
    }.width('100%').height(JOIN_TICKET_HEIGHT).clip(false)
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
