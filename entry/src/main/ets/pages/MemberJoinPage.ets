import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { scanCore, scanBarcode } from '@kit.ScanKit';
import { AppSession } from '../app/AppSession';
import { joinCodeFromPayload, parseJoinQrPayload } from '../network/join/JoinQrPayload';
import { P2pRoomInvitation } from '../network/p2p/P2pInvitation';
import {
  bluetoothPermissionDeniedHint,
  cameraPermissionDeniedHint,
  ensureBluetoothDiscoveryPermission,
  ensureCameraPermission,
  ensureTeamNetworkPermissions,
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
  @State bluetoothAck: boolean = false;
  @State joining: boolean = false;
  @State wirelessSettingsAvailable: boolean = false;

  aboutToAppear(): void {
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

  private persistDisplayName(): void {
    const trimmed = this.displayName.trim();
    if (trimmed.length > 0) {
      AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, trimmed);
    }
  }

  private async initialize(): Promise<void> {
    await AppSession.reset();
    const session = AppSession.createMember(this.displayName);
    this.status = '请先打开系统 Wi-Fi；手输加入码时还需要打开蓝牙';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const granted = await ensureTeamNetworkPermissions(ctx);
      if (granted && await verifyTeamNetworkAccess()) {
        await session.p2p.prepareMemberDiscovery();
      } else if (granted) {
        this.wirelessSettingsAvailable = true;
        this.status = teamNetworkAccessUnavailableHint();
      }
    } catch (_e) {
      // 进入页时预申请；用户点加入时会再次校验并提示
    }
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
          Text('请先打开 Wi-Fi。扫码无需蓝牙发现权限，对准队长邀请二维码即可。')
            .fontSize(12)
            .fontColor('#66615A')
            .width('100%')
          Button('打开相机扫码  ›')
            .backgroundColor(CORAL)
            .fontColor(INK)
            .fontSize(18)
            .fontWeight(900)
            .border({ width: 1.5, color: INK })
            .borderRadius(6)
            .shadow(CONTROL_SHADOW)
            .height(52)
            .width('100%')
            .enabled(this.bluetoothAck && !this.joining)
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
          Text('需要打开蓝牙，用于查找附近广播该加入码的队长。')
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
            .enabled(this.bluetoothAck && !this.joining && this.joinCode.length === 6)
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

        Column({ space: 7 }) {
          Text('蓝牙耳机同步提醒').fontSize(12).fontWeight(900).fontColor('#884400').width('100%')
          Text('外放或有线耳机同步效果最佳。这里说明的是蓝牙耳机延迟，与上方“蓝牙用于找房间”不是同一用途。')
            .fontSize(11)
            .fontColor('#70420F')
            .lineHeight(17)
            .width('100%')
          Row({ space: 8 }) {
            Checkbox({ name: 'bt_ack', group: 'disclaimer' })
              .select(this.bluetoothAck)
              .onChange((value: boolean) => {
                this.bluetoothAck = value;
              })
            Text('我已知晓，继续加入')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
          }.width('100%')
        }
        .width('100%')
        .padding(11)
        .backgroundColor('#FFF0D8')
        .border({ width: 1, color: '#B66B18' })
        .borderRadius(6)
        .shadow(CONTROL_SHADOW)

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
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted = await ensureTeamNetworkPermissions(ctx);
    if (!granted) {
      this.status = teamNetworkPermissionDeniedHint();
      return false;
    }
    if (!(await verifyTeamNetworkAccess())) {
      this.wirelessSettingsAvailable = true;
      this.status = teamNetworkAccessUnavailableHint();
      return false;
    }
    this.wirelessSettingsAvailable = false;
    return true;
  }

  private async joinInvitation(invitation: P2pRoomInvitation): Promise<void> {
    this.joining = true;
    try {
      if (!(await this.ensureP2pReady())) {
        return;
      }
      const session = AppSession.get() ?? AppSession.createMember(this.displayName);
      session.controller.bluetoothAcknowledged = this.bluetoothAck;
      this.status = '正在扫描附近 P2P 设备并连接队长…';
      await session.memberJoinWithInvitation(invitation);
      this.persistDisplayName();
      this.status = '已同步时钟，正在进入…';
      router.replaceUrl({ url: 'pages/LeaderLobbyPage', params: { reuse: '1' } });
    } catch (err) {
      this.status = `加入失败：${(err as Error).message}`;
    } finally {
      this.joining = false;
    }
  }

  private async joinWithCode(code: string): Promise<void> {
    this.joining = true;
    try {
      if (!(await this.ensureP2pReady())) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const bluetoothGranted = await ensureBluetoothDiscoveryPermission(ctx);
      if (!bluetoothGranted) {
        this.status = bluetoothPermissionDeniedHint();
        return;
      }
      if (!isBluetoothDiscoveryAvailable()) {
        this.status = '手输加入码需要打开蓝牙；也可以改用扫码加入';
        return;
      }
      const session = AppSession.get() ?? AppSession.createMember(this.displayName);
      session.controller.bluetoothAcknowledged = this.bluetoothAck;
      this.status = '正在通过蓝牙查找附近房间…';
      await session.memberJoinByCode(code, () => {
        this.status = '已找到队伍，正在请求连接队长…';
      });
      this.persistDisplayName();
      this.status = '已同步时钟，正在进入…';
      router.replaceUrl({ url: 'pages/LeaderLobbyPage', params: { reuse: '1' } });
    } catch (err) {
      this.status = `加入失败：${(err as Error).message}`;
    } finally {
      this.joining = false;
    }
  }

  private async scanJoin(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const cameraOk = await ensureCameraPermission(ctx);
      if (!cameraOk) {
        this.status = cameraPermissionDeniedHint();
        return;
      }
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE]
      };
      const result = await scanBarcode.startScanForResult(ctx, options);
      const payload = parseJoinQrPayload(result.originalValue);
      const code = joinCodeFromPayload(payload);
      this.joinCode = code;
      this.status = `已识别加入码 ${code}，正在扫描附近 P2P 设备…`;
      await this.joinInvitation(payload);
    } catch (err) {
      this.status = `扫码失败：${(err as Error).message}`;
    }
  }
}
