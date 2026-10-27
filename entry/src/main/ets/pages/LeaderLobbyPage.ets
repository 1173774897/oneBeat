import { COMIC_CARD_INK_OFFSET, COMIC_CONTROL_INK_OFFSET } from '../components/ComicInkSurface';
import { common } from '@kit.AbilityKit';
import { access } from '@kit.ConnectivityKit';
import { router } from '@kit.ArkUI';
import { navigateToHome } from '../app/HomeNavigation';
import { AppSession } from '../app/AppSession';
import { SessionController } from '../session/SessionController';
import { SessionMember } from '../protocol/messages';
import { RandomCharacterFilm, RANDOM_FILM_HEIGHT } from '../components/RandomCharacterFilm';
import { EditableBpm } from '../components/EditableBpm';
import { EditableMeter, MeterEditorOverlay } from '../components/EditableMeter';
import { DrumPaper } from '../components/DrumPaper';
import { ActionButton, ACTION_DISABLED_OPACITY } from '../components/ActionButton';
import { beatUnitLabel } from '../common/MeterModel';
import {
  avatarDisplayName,
  ComicButton,
  ComicCharacter,
  PAPER,
  INK,
  CORAL,
  LILAC,
  TEAL,
  WHITE,
  BLUE
} from '../components/ComicKit';
import {
  CharacterPickState,
  characterPickState,
  isCharacterOwned,
  isDuplicatableAvatar,
  isExclusiveTakenByOther,
  isRandomAvatar,
  isRandomPoolCharacter,
  rosterKeysForLobby,
  sortRosterKeysForPicker
} from '../assets/CharacterCatalog';
import {
  ensureBluetoothDiscoveryPermission,
  ensureTeamNetworkPermissions,
  openWirelessSettings,
  teamNetworkAccessUnavailableHint,
  teamNetworkPermissionDeniedHint,
  verifyTeamNetworkAccess
} from '../network/join/TeamNetworkPermissions';
import { DrumProgram, drumProgramStyleKeys, parseDrumProgram, styleByKey } from '../audio/DrumMachineCatalog';
import { loadSavedDrumPrograms, resolveSavedDrumProgram } from '../audio/DrumProgramLibrary';
import {
  isProDrumMachineAccessible,
  isSceneAccessible,
  hasUsableEntitlementCache,
  limitedFreeCharacterKeys,
  resolveDrumAccess,
  formatTrialExpiry
} from '../store/EntitlementStore';
import { refreshStoreEntitlementsNow } from '../store/StoreBootstrapSync';
import { SESSION_MAX_MEMBER_COUNT } from '../common/Constants';
import { getCalibrationMs } from '../store/AudioLatencyPersistence';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';

interface LobbySceneOption {
  key: string;
  name: string;
  caption: string;
}

type LobbyInviteBluetoothState = 'off' | 'turningOn' | 'turningOff' | 'on' | 'unavailable';

const LOBBY_SCENES: LobbySceneOption[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海浪、云层与土路' },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜街区与霓虹灯' }
];

const PRO_DRUM_BUTTON_HEIGHT: number = 56;
// Regional faces use DrumPaper sibling backings; their shadows must stay outside face clipping.
const LOBBY_AREA_SHADOW_OFFSET: number = 4;
const LOBBY_SCENE_CARD_WIDTH: number = 154;
const LOBBY_SCENE_CARD_HEIGHT: number = 148;
const LOBBY_SCENE_CORNER_RADIUS: number = 7;
const LOBBY_SCENE_BORDER_WIDTH: number = 1;
const LOBBY_SCENE_SELECTED_BORDER_WIDTH: number = 3;
const PRO_DRUM_ENTRY_PADDING: number = 4;
const PRO_CHAIN_SOURCE_WIDTH: number = 400;
const PRO_CHAIN_SOURCE_HEIGHT: number = 600;
const PRO_CHAIN_BUTTON_TOP_PX: number = 45;
const PRO_CHAIN_BUTTON_BOTTOM_PX: number = 235;
// The source's two button-edge anchors, not viewport width, determine the uniform
// scale. Independent width caps or vertical offsets would break this alignment.
const PRO_CHAIN_SCALE: number = PRO_DRUM_BUTTON_HEIGHT /
  (PRO_CHAIN_BUTTON_BOTTOM_PX - PRO_CHAIN_BUTTON_TOP_PX);
const PRO_CHAIN_WIDTH: number = PRO_CHAIN_SOURCE_WIDTH * PRO_CHAIN_SCALE;
const PRO_CHAIN_HEIGHT: number = PRO_CHAIN_SOURCE_HEIGHT * PRO_CHAIN_SCALE;
const PRO_CHAIN_TOP_OFFSET: number = PRO_DRUM_ENTRY_PADDING - PRO_CHAIN_BUTTON_TOP_PX * PRO_CHAIN_SCALE;
const PRO_CHAIN_OFFSET_X: number = -20;
const PRO_DRUM_TRIAL_LABEL_SIZE: number = 10;
const DRUM_CARD_PADDING: number = 14;
const DRUM_CARD_CONTENT_GAP: number = 12;
const DRUM_CARD_RADIUS: number = 8;
const DRUM_CONTROL_RADIUS: number = 6;
const DRUM_ARRANGEMENT_ICON_SIZE: number = 68;
const DRUM_STYLE_CHIP_GAP: number = 6;
const DRUM_STYLE_CHIP_HEIGHT: number = 28;

const CHARACTER_PICK_AVATAR_SIZE: number = 48;
const CHARACTER_PICK_AVATAR_TOP: number = 6;
const CHARACTER_PICK_CORNER_RADIUS: number = 6;
const CHARACTER_PICK_SHADOW_OFFSET: number = 2;
const CHARACTER_BADGE_INSET: number = 2;
const CHARACTER_BADGE_GAP: number = 2;
const CHARACTER_BADGE_ICON_SIZE: number = 16;
// Cutout SVGs include a 3 vp transparent gutter for their white outline and ink
// shadow. Keep the original 16 vp glyph anchored, not the padded image bounds.
const CHARACTER_BADGE_ICON_PADDING: number = 3;
const CHARACTER_FREE_BADGE_WIDTH: number = 28;
const CHARACTER_FREE_BADGE_HEIGHT: number = 17;
const ROSTER_AVATAR_SIZE: number = 43;
const ROSTER_SLOT_NAME_GAP: number = 2;
const ROSTER_SLOT_NAME_HEIGHT: number = 12;
const ROSTER_SLOT_TOTAL_HEIGHT: number = ROSTER_AVATAR_SIZE + ROSTER_SLOT_NAME_GAP + ROSTER_SLOT_NAME_HEIGHT;
const ROSTER_STATUS_RAIL_HEIGHT: number = 13;
const ROSTER_STATUS_ICON_SIZE: number = 9;
const ROSTER_STATUS_DOT_SIZE: number = 2;
const ROSTER_STATUS_ANIMATION_INTERVAL_MS: number = 220;
/** 头像顶部已无浮层，只留漫画阴影和选中描边需要的呼吸空间。 */
const ROSTER_ROW_TOP_PADDING: number = 2;
const ROSTER_SLOT_COLUMN_WIDTH: number = 58;
const ROSTER_SLOT_ROW_GAP: number = 10;
const ROSTER_SLOT_STEP: number = ROSTER_SLOT_COLUMN_WIDTH + ROSTER_SLOT_ROW_GAP;
const ROSTER_DRAG_LONG_PRESS_MS: number = 450;
const ROSTER_DRAG_CLICK_GUARD_MS: number = 150;
const ROSTER_REORDER_SHIFT_MS: number = 160;
const ROSTER_DRAG_HELD_SCALE: number = 1.29;
const ROSTER_DRAG_HELD_OPACITY: number = 0.72;
const ROSTER_SCROLL_BOTTOM_INSET: number = COMIC_CONTROL_INK_OFFSET + 2;
/** 名单行固定高度：拖拽放大只改 transform，不撑开「人在队伍中」白卡片。 */
const ROSTER_SCROLL_VIEWPORT_HEIGHT: number =
  ROSTER_ROW_TOP_PADDING + ROSTER_SLOT_TOTAL_HEIGHT + ROSTER_SCROLL_BOTTOM_INSET;
/** 拖拽时名单层叠在标题/邀请区之上，放大部分可画出固定视口外。 */
const ROSTER_DRAG_OVERFLOW_Z_INDEX: number = 6;
const CALIBRATION_DOT_INDICES: number[] = [0, 1, 2];
const CALIBRATION_CARD_HEIGHT: number = 58;
const CALIBRATION_CARD_ICON_SIZE: number = 36;
const CALIBRATION_CARD_HEADPHONE_SIZE: number = 32;
const CALIBRATION_ENTRY_VERTICAL_MARGIN: number = 10;
const SOLO_CALIBRATION_FONT_SIZE: number = 12;
const SOLO_CALIBRATION_VERTICAL_PADDING: number = 6;
const BLUETOOTH_ROUTE_CONFIRM_WIDTH: number = 318;
const BLUETOOTH_ROUTE_PROBE_BUTTON_HEIGHT: number = 48;
const INVITE_NOTICE_GAP: number = 8;
const INVITE_NOTICE_HORIZONTAL_PADDING: number = 10;
const INVITE_NOTICE_VERTICAL_PADDING: number = 8;
const INVITE_NOTICE_ICON_SIZE: number = 16;
const INVITE_NOTICE_ACTION_WIDTH: number = 76;
const INVITE_NOTICE_ACTION_HEIGHT: number = 44;
const INVITE_NOTICE_FILL: string = '#FFF1CC';
const INVITE_NOTICE_INK: string = '#77602A';

@Entry
@Component
struct LeaderLobbyPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'sunset_coast';
  @StorageLink('btAudioActive') @Watch('onBluetoothAudioRouteChanged') btAudioActive: boolean = false;
  @StorageLink('btCalibrationTracksConnection') btCalibrationTracksConnection: boolean = false;
  @StorageLink('btCalibrationNeedsRemeasure') btCalibrationNeedsRemeasure: boolean = false;
  @StorageLink('storeEntitlementEpoch') @Watch('onStoreEntitlementsChanged') storeEntitlementEpoch: number = 0;
  @State members: SessionMember[] = [];
  @State editingMemberId: string = 'leader';
  @State leader: boolean = true;
  @State bpm: number = 120;
  @State beats: number = 4;
  @State unit: number = 4;
  @State rhythm: number = 0;
  @State drumProgram: string = '';
  @State loading: boolean = true;
  @State status: string = '正在准备队伍…';
  @State soloTeam: boolean = false;
  @State failed: boolean = false;
  @State invite: boolean = false;
  @State qr: string = '';
  @State inviteBluetoothState: LobbyInviteBluetoothState = 'unavailable';
  @State inviteBluetoothSupported: boolean = false;
  @State inviteCodeAvailable: boolean = false;
  @State inviteJoinCode: string = '';
  @State inviteActionBusy: boolean = false;
  @State inviteActionError: string = '';
  @State localReady: boolean = false;
  @State leaderCanDepart: boolean = false;
  @State rhythmDropdownOpen: boolean = false;
  @State meterEditorVisible: boolean = false;
  @State rhythmDropdownX: number = 0;
  @State rhythmDropdownY: number = 0;
  @State rhythmDropdownWidth: number = 200;
  @State leavingLobby: boolean = false;
  @State randomPreviewRequest: number = 0;
  @State randomPreviewCancelRequest: number = 0;
  @State randomPreviewPendingMemberId: string = '';
  @State randomPreviewPageVisible: boolean = true;
  @State latencyCalibrationMs: number = -1;
  @State calibrationDotPhase: number = 0;
  @State bluetoothRouteConfirmVisible: boolean = false;
  @State bluetoothRouteProbePlaying: boolean = false;
  @State bluetoothRouteProbePlayed: boolean = false;
  @State bluetoothRouteStatus: string = '';
  @State drumAccessAllowed: boolean = false;
  @State drumAccessSource: string = 'locked';
  @State drumAccessExpiresAt: number = 0;
  @State proDrumEntryScale: number = 1;
  // Closing and reopening the dialog can overlap two asynchronous probes. A
  // completion belongs only to the request that still owns the visible dialog.
  private bluetoothRouteProbeRequestToken: number = 0;
  private rhythms: string[] = ['均匀节拍', '双分节拍', '仅小节重音'];
  private enteringStage: boolean = false;
  private refreshingConnectivity: boolean = false;
  private connectivityRefreshQueued: boolean = false;
  private connectivityRefreshOwner: number = 0;
  private connectivityRefreshSession: AppSession | undefined = undefined;
  private inviteActionOwner: number = 0;
  private inviteFeedbackSession: AppSession | undefined = undefined;
  private readonly rosterScroller: Scroller = new Scroller();
  private randomSelectionToken: number = 0;
  private randomPreviewPreviousDrawId: number = 0;
  private rosterStatusAnimationTimer: number = -1;
  @State rosterDragMemberId: string = '';
  @State rosterDragOffsetX: number = 0;
  private rosterDragFromIndex: number = -1;
  private rosterDragSession: AppSession | undefined = undefined;
  private rosterDragSuppressSelectUntil: number = 0;
  private drumAccessRefreshTimer: number = -1;
  private actionSequence: number = 0;
  // Late results from an earlier action or room cannot overwrite visible feedback.
  private readonly pendingActions: Map<string, number> = new Map();
  private readonly actionSessions: Map<string, AppSession> = new Map();
  // Retain dismissal even if the authoritative result arrives after active changes.
  private readonly interruptedRandomPreviews: Map<string, number> = new Map();
  private readonly bluetoothStateListener = (_state: access.BluetoothState): void => {
    // Hide stale digits before native P2P/BLE work can suspend this callback.
    this.updateInviteBluetoothState();
    void this.refreshLeaderConnectivity();
  };

  private clearInviteAction(): void {
    this.inviteActionOwner = 0;
    this.inviteActionBusy = false;
    this.inviteActionError = '';
  }

  private updateInviteBluetoothState(): void {
    const session = AppSession.get();
    if (session !== this.inviteFeedbackSession) {
      this.clearInviteAction();
      this.inviteFeedbackSession = session;
    }
    const previousState = this.inviteBluetoothState;
    this.inviteBluetoothSupported = false;
    this.inviteBluetoothState = 'unavailable';
    try {
      this.inviteBluetoothSupported = canIUse('SystemCapability.Communication.Bluetooth.Core');
      if (this.inviteBluetoothSupported) {
        const state = access.getState();
        if (state === access.BluetoothState.STATE_ON) {
          this.inviteBluetoothState = 'on';
        } else if (state === access.BluetoothState.STATE_OFF) {
          this.inviteBluetoothState = 'off';
        } else if (state === access.BluetoothState.STATE_TURNING_ON) {
          this.inviteBluetoothState = 'turningOn';
        } else if (state === access.BluetoothState.STATE_TURNING_OFF) {
          this.inviteBluetoothState = 'turningOff';
        }
      }
    } catch (_error) {
      // Permission/capability failures are unknown availability, not proof that Bluetooth is off.
    }
    this.inviteJoinCode = session?.controller.joinCode ?? '';
    this.inviteCodeAvailable = this.inviteBluetoothState === 'on' &&
      session?.controller.bleInviteAvailable === true;
    if (previousState !== this.inviteBluetoothState || this.canShowJoinCode()) {
      this.inviteActionError = '';
    }
  }

  private canShowJoinCode(): boolean {
    // The radio being on is insufficient: nearby discovery must actually be advertising this invitation.
    return this.inviteBluetoothState === 'on' && this.inviteCodeAvailable &&
      /^\d{6}$/.test(this.inviteJoinCode);
  }

  private inviteUnavailableTitle(): string {
    if (this.inviteBluetoothState === 'turningOn') {
      return '正在启用加入码';
    }
    return this.inviteBluetoothState === 'off' || this.inviteBluetoothState === 'turningOff'
      ? '加入码待启用' : '加入码暂不可用';
  }

  private inviteUnavailableDetail(): string {
    if (this.inviteActionError.length > 0) {
      return this.inviteActionError;
    }
    if (this.inviteBluetoothState === 'off') {
      return '开启蓝牙后，可用 6 位码加入';
    }
    if (this.inviteBluetoothState === 'turningOn') {
      return '蓝牙正在开启，队员仍可扫码加入';
    }
    if (this.inviteBluetoothState === 'turningOff') {
      return '蓝牙正在关闭，队员仍可扫码加入';
    }
    return '附近发现暂不可用，队员可扫码加入';
  }

  private inviteActionLabel(): string {
    if (this.inviteActionBusy) {
      return '处理中…';
    }
    if (this.inviteBluetoothState === 'turningOn') {
      return '开启中…';
    }
    return this.inviteBluetoothState === 'off' || this.inviteBluetoothState === 'turningOff'
      ? '去开启 ›' : '重试 ›';
  }

  private inviteActionEnabled(): boolean {
    return this.leader && !this.soloTeam && !this.loading && !this.failed && !this.leavingLobby &&
      this.randomPreviewPageVisible && this.qr.length > 0 && this.inviteBluetoothSupported &&
      !this.inviteActionBusy && this.inviteBluetoothState !== 'turningOn';
  }

  private async activateJoinCode(): Promise<void> {
    this.updateInviteBluetoothState();
    if (!this.inviteActionEnabled() || this.canShowJoinCode()) {
      return;
    }
    const session = AppSession.get();
    if (session === undefined || !session.controller.isLeader || session.controller.soloTeam) {
      return;
    }
    const request = this.beginAction('lobby-invite');
    this.inviteActionOwner = request;
    this.inviteActionBusy = true;
    this.inviteActionError = '';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      if (this.inviteBluetoothState === 'off' || this.inviteBluetoothState === 'turningOff') {
        // Opening settings does not claim success. State events/page return own radio and advertisement revalidation.
        await openWirelessSettings(ctx);
        return;
      }
      const granted = await ensureBluetoothDiscoveryPermission(ctx);
      if (!this.isCurrentAction('lobby-invite', request)) {
        return;
      }
      if (!granted) {
        this.inviteActionError = '未获得蓝牙权限，仍可扫码加入';
        return;
      }
      await this.refreshLeaderConnectivity();
      if (this.isCurrentAction('lobby-invite', request)) {
        this.updateInviteBluetoothState();
      }
    } catch (error) {
      logUserFailure('lobby-invite', error);
      if (this.isCurrentAction('lobby-invite', request)) {
        this.inviteActionError = '未能更新加入码，请从系统设置检查蓝牙';
      }
    } finally {
      if (this.inviteActionOwner === request) {
        this.inviteActionOwner = 0;
        this.inviteActionBusy = false;
      }
    }
  }

  private onBluetoothAudioRouteChanged(): void {
    if (!this.btAudioActive && this.bluetoothRouteConfirmVisible) {
      this.bluetoothRouteProbeRequestToken++;
      this.bluetoothRouteProbePlaying = false;
      this.bluetoothRouteProbePlayed = false;
      this.bluetoothRouteStatus = '耳机已断开，请连接后重新试音';
      void AppSession.get()?.stopLatencyCalibration();
    }
  }

  private requestBluetoothCalibration(): void {
    this.bluetoothRouteProbeRequestToken++;
    this.bluetoothRouteProbePlayed = false;
    this.bluetoothRouteProbePlaying = false;
    this.bluetoothRouteStatus = this.btAudioActive ? '' : '未检测到耳机输出，请连接后重新试音';
    this.bluetoothRouteConfirmVisible = true;
  }

  private async playBluetoothRouteProbe(): Promise<void> {
    if (!this.bluetoothRouteConfirmVisible || this.bluetoothRouteProbePlaying) {
      return;
    }
    if (!this.btAudioActive) {
      this.bluetoothRouteStatus = '未检测到耳机输出，请连接后重新试音';
      return;
    }
    const requestToken = ++this.bluetoothRouteProbeRequestToken;
    this.bluetoothRouteProbePlaying = true;
    this.bluetoothRouteProbePlayed = false;
    this.bluetoothRouteStatus = '';
    try {
      const played = await AppSession.get()?.playBluetoothRouteProbe() ?? false;
      if (requestToken === this.bluetoothRouteProbeRequestToken && played &&
        this.bluetoothRouteConfirmVisible && this.btAudioActive) {
        this.bluetoothRouteProbePlayed = true;
      } else if (requestToken === this.bluetoothRouteProbeRequestToken && this.bluetoothRouteConfirmVisible) {
        this.bluetoothRouteStatus = '试音未完成，请重试';
      }
    } catch (err) {
      logUserFailure('lobby-route-probe', err);
      if (requestToken === this.bluetoothRouteProbeRequestToken &&
        this.bluetoothRouteConfirmVisible && this.btAudioActive) {
        this.bluetoothRouteStatus = '试音失败，请确认耳机连接后重试';
      }
    } finally {
      if (requestToken === this.bluetoothRouteProbeRequestToken && this.bluetoothRouteConfirmVisible) {
        this.bluetoothRouteProbePlaying = false;
      }
    }
  }

  private async confirmBluetoothCalibration(): Promise<void> {
    if (!this.bluetoothRouteConfirmVisible || this.bluetoothRouteProbePlaying ||
      !this.bluetoothRouteProbePlayed || !this.btAudioActive) {
      return;
    }
    this.bluetoothRouteProbeRequestToken++;
    this.bluetoothRouteConfirmVisible = false;
    this.bluetoothRouteProbePlayed = false;
    // The tap game intentionally inherits the renderer warmed by the route probe.
    void router.pushUrl({ url: 'pages/TimeCardCalibrationPage' });
  }

  private dismissBluetoothRouteConfirmation(): void {
    this.bluetoothRouteProbeRequestToken++;
    this.bluetoothRouteConfirmVisible = false;
    this.bluetoothRouteProbePlayed = false;
    this.bluetoothRouteProbePlaying = false;
    this.bluetoothRouteStatus = '';
    void AppSession.get()?.stopLatencyCalibration();
  }

  private rejectBluetoothRouteConfirmation(): void {
    this.bluetoothRouteProbePlayed = false;
    this.bluetoothRouteStatus = '请先把媒体输出切到耳机，再播放试音';
  }

  private hasBluetoothCalibration(): boolean {
    return this.latencyCalibrationMs >= 0 && this.btCalibrationTracksConnection;
  }

  private calibrationCardTitle(): string {
    if (this.btCalibrationNeedsRemeasure && this.hasBluetoothCalibration()) {
      return '耳机已重新连接';
    }
    return this.hasBluetoothCalibration() ? '耳机已校准' : '蓝牙耳机延迟';
  }

  private calibrationCardSubtitle(): string {
    if (!this.hasBluetoothCalibration()) {
      return '声音不同步时，可校准耳机';
    }
    if (this.btCalibrationNeedsRemeasure) {
      return `原补偿 ${this.latencyCalibrationMs} ms · 建议适配新连接`;
    }
    return `补偿 ${this.latencyCalibrationMs} ms · 保持当前耳机连接`;
  }

  private calibrationCardActionLabel(): string {
    if (!this.hasBluetoothCalibration()) {
      return '开始校准 ›';
    }
    return this.btCalibrationNeedsRemeasure ? '推荐重测 ›' : '重测 ›';
  }

  private calibrationCardFill(): string {
    if (!this.hasBluetoothCalibration()) {
      return '#FFF0B8';
    }
    return this.btCalibrationNeedsRemeasure ? '#FFE4DE' : '#E4F7F2';
  }

  private calibrationCardIconFill(): string {
    if (!this.hasBluetoothCalibration()) {
      return BLUE;
    }
    return this.btCalibrationNeedsRemeasure ? CORAL : TEAL;
  }

  private soloCalibrationEntryLabel(): string {
    if (this.hasBluetoothCalibration()) {
      return this.btCalibrationNeedsRemeasure ? '耳机已重连 · 校准 ›' : '耳机已校准';
    }
    return '耳机设置 ›';
  }

  @Builder
  private soloLatencyCalibrationEntry() {
    Text(this.soloCalibrationEntryLabel())
      .fontSize(SOLO_CALIBRATION_FONT_SIZE).fontWeight(500).fontColor('#625B53')
      .width('100%').textAlign(TextAlign.Center)
      .padding({ top: SOLO_CALIBRATION_VERTICAL_PADDING, bottom: SOLO_CALIBRATION_VERTICAL_PADDING })
      .onClick(() => this.requestBluetoothCalibration())
  }

  @Builder
  private latencyCalibrationEntry() {
    Column() {
      DrumPaper({ fill: this.calibrationCardFill(), cornerRadius: 8, paperLineWidth: 0,
        offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
        Row({ space: 10 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(CALIBRATION_CARD_ICON_SIZE).height(CALIBRATION_CARD_ICON_SIZE)
              .fill(this.calibrationCardIconFill()).stroke(INK).strokeWidth(1.5)
            if (!this.hasBluetoothCalibration()) {
              Image($rawfile('calibration/lobby/bluetooth-calibration-default.png'))
                .width(CALIBRATION_CARD_HEADPHONE_SIZE).height(CALIBRATION_CARD_HEADPHONE_SIZE)
                .objectFit(ImageFit.Contain)
            } else if (this.btCalibrationNeedsRemeasure) {
              Image($rawfile('calibration/lobby/bluetooth-calibration-reconnected.png'))
                .width(CALIBRATION_CARD_HEADPHONE_SIZE).height(CALIBRATION_CARD_HEADPHONE_SIZE)
                .objectFit(ImageFit.Contain)
            } else {
              Image($rawfile('calibration/lobby/bluetooth-calibration-calibrated.png'))
                .width(CALIBRATION_CARD_HEADPHONE_SIZE).height(CALIBRATION_CARD_HEADPHONE_SIZE)
                .objectFit(ImageFit.Contain)
            }
          }.width(CALIBRATION_CARD_ICON_SIZE).height(CALIBRATION_CARD_ICON_SIZE)

          Column({ space: 2 }) {
            Text(this.calibrationCardTitle())
              .fontSize(15).fontWeight(900).fontColor(INK).width('100%').maxLines(1)
            Text(this.calibrationCardSubtitle())
              .fontSize(10).fontWeight(700).fontColor('#625B53').width('100%').maxLines(1)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(this.calibrationCardActionLabel())
            .fontSize(13).fontWeight(900).fontColor(CORAL)
        }
        .width('100%')
        .height(CALIBRATION_CARD_HEIGHT)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.calibrationCardFill())
        .border({ width: 1.5, color: INK })
        .borderRadius(8)
        .onClick(() => this.requestBluetoothCalibration())
      }
    }.width('100%').clip(false)
      .margin({ top: CALIBRATION_ENTRY_VERTICAL_MARGIN, bottom: CALIBRATION_ENTRY_VERTICAL_MARGIN })
  }

  @Builder
  private bluetoothRouteConfirmationOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99171B1F')
        .onClick(() => this.dismissBluetoothRouteConfirmation())

      Column() {
        DrumPaper({ fill: PAPER, cornerRadius: 10, paperLineWidth: 0,
          offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
          Column({ space: 14 }) {
            Row({ space: 11 }) {
              Stack() {
                Image($rawfile('calibration/lobby/bluetooth-calibration-default.png'))
                  .width(56).height(56).objectFit(ImageFit.Contain)
              }.width(58).height(58)
              Column({ space: 2 }) {
                Text('确认蓝牙声音出口').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
                Text('确认后再开始延迟测量').fontSize(10).fontWeight(800).fontColor('#625B53')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text('×').fontSize(26).fontWeight(900).fontColor(INK).width(28).textAlign(TextAlign.Center)
                .onClick(() => this.dismissBluetoothRouteConfirmation())
            }.width('100%').alignItems(VerticalAlign.Center)

            Text(this.bluetoothRouteStatus.length > 0 ? this.bluetoothRouteStatus :
              '系统检测到了蓝牙音频。播放“嘀嗒”两声试音，确认声音确实从蓝牙耳机里传出。')
              .width('100%').fontSize(13).lineHeight(20).fontWeight(700).fontColor('#4F4943')

            ActionButton({
              label: this.bluetoothRouteProbePlaying ? '正在播放…' :
                this.bluetoothRouteProbePlayed ? '再播放一次试音 ♪' : '播放试音 ♪',
              active: !this.bluetoothRouteProbePlaying,
              controlHeight: BLUETOOTH_ROUTE_PROBE_BUTTON_HEIGHT,
              contentPadding: { left: 16, right: 16 },
              labelSize: 15, labelWeight: 900, fill: LILAC, lineWidth: 1.5, cornerRadius: 7,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => { void this.playBluetoothRouteProbe(); }
            })

            if (this.bluetoothRouteProbePlayed) {
              Row({ space: 6 }) {
                Text('✓').fontSize(13).fontWeight(900).fontColor(TEAL)
                Text('试音已播放，现在请选择实际听到的位置')
                  .fontSize(10).fontWeight(800).fontColor('#625B53')
              }.width('100%')

              ActionButton({
                label: '声音在蓝牙耳机里', active: this.btAudioActive && !this.bluetoothRouteProbePlaying,
                controlHeight: 50, labelSize: 16, labelWeight: 900,
                contentPadding: { left: 16, right: 16 },
                fill: TEAL, lineWidth: 1.5, cornerRadius: 7,
                hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                action: () => { void this.confirmBluetoothCalibration(); }
              })

              DrumPaper({ fill: WHITE, paperWidth: '100%', cornerRadius: 7, paperLineWidth: 0,
                offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                Button('声音在手机 / 其他设备', { type: ButtonType.Normal })
                  .width('100%').height(44).fontSize(13).fontWeight(900).fontColor(CORAL)
                  .backgroundColor(WHITE).border({ width: 1.5, color: INK }).borderRadius(7)
                  .onClick(() => this.rejectBluetoothRouteConfirmation())
              }
            }
          }
          .width('100%')
          .padding(18)
          .backgroundColor(PAPER)
          .border({ width: 2, color: INK })
          .borderRadius(10)
          .clip(false)
        }
      }.width(BLUETOOTH_ROUTE_CONFIRM_WIDTH).clip(false)
    }
    .width('100%')
    .height('100%')
    .zIndex(120)
  }

  aboutToAppear(): void {
    this.latencyCalibrationMs = getCalibrationMs();
    this.startRosterStatusAnimation();
    this.startDrumAccessRefresh();
    try {
      access.on('stateChange', this.bluetoothStateListener);
    } catch (_e) {
    }
    void this.initialize();
  }
  aboutToDisappear(): void {
    this.clearInviteAction();
    this.connectivityRefreshQueued = false;
    this.cancelRosterDrag();
    this.stopDrumAccessRefresh();
    this.pendingActions.clear();
    this.actionSessions.clear();
    this.bluetoothRouteProbeRequestToken++;
    this.randomSelectionToken += 1;
    this.randomPreviewPageVisible = false;
    this.randomPreviewPendingMemberId = '';
    this.interruptedRandomPreviews.clear();
    this.stopRosterStatusAnimation();
    if (this.bluetoothRouteConfirmVisible) {
      this.dismissBluetoothRouteConfirmation();
    }
    try {
      access.off('stateChange', this.bluetoothStateListener);
    } catch (_e) {
    }
  }
  onBackPress(): boolean {
    if (this.bluetoothRouteConfirmVisible) {
      this.dismissBluetoothRouteConfirmation();
      return true;
    }
    if (this.meterEditorVisible) {
      this.meterEditorVisible = false;
      return true;
    }
    void this.leaveLobby();
    return true;
  }
  onPageShow(): void {
    this.randomPreviewPageVisible = true;
    this.startRosterStatusAnimation();
    this.startDrumAccessRefresh();
    this.enteringStage = false;
    this.refresh();
    this.latencyCalibrationMs = getCalibrationMs();
    void this.refreshLeaderConnectivity();
  }
  onPageHide(): void {
    this.clearInviteAction();
    this.connectivityRefreshQueued = false;
    this.cancelRosterDrag();
    this.stopDrumAccessRefresh();
    this.pendingActions.clear();
    this.actionSessions.clear();
    this.bluetoothRouteProbeRequestToken++;
    if (this.bluetoothRouteConfirmVisible) {
      this.dismissBluetoothRouteConfirmation();
    }
    this.randomSelectionToken += 1;
    this.randomPreviewPageVisible = false;
    this.randomPreviewPendingMemberId = '';
    this.stopRosterStatusAnimation();
  }

  private beginAction(scope: string, trackSession: boolean = true): number {
    const request = ++this.actionSequence;
    this.pendingActions.set(scope, request);
    const session = AppSession.get();
    if (trackSession && session !== undefined) {
      this.actionSessions.set(scope, session);
    } else {
      this.actionSessions.delete(scope);
    }
    return request;
  }

  private isCurrentAction(scope: string, request: number): boolean {
    return this.randomPreviewPageVisible && this.pendingActions.get(scope) === request &&
      (!this.actionSessions.has(scope) || this.actionSessions.get(scope) === AppSession.get());
  }

  private reportActionFailure(scope: string, request: number, error: Object, fallback: string): void {
    logUserFailure(scope, error);
    if (this.isCurrentAction(scope, request)) {
      showUserNotice(userErrorMessage(error, fallback), scope);
    }
  }

  private startRosterStatusAnimation(): void {
    if (this.rosterStatusAnimationTimer >= 0) {
      return;
    }
    this.rosterStatusAnimationTimer = setInterval(() => {
      this.calibrationDotPhase = (this.calibrationDotPhase + 1) % CALIBRATION_DOT_INDICES.length;
    }, ROSTER_STATUS_ANIMATION_INTERVAL_MS);
  }

  private stopRosterStatusAnimation(): void {
    if (this.rosterStatusAnimationTimer >= 0) {
      clearInterval(this.rosterStatusAnimationTimer);
      this.rosterStatusAnimationTimer = -1;
    }
  }

  private async refreshLeaderConnectivity(): Promise<void> {
    this.updateInviteBluetoothState();
    const session = AppSession.get();
    if (!this.randomPreviewPageVisible || this.leavingLobby || session === undefined ||
      !session.controller.isLeader || session.controller.soloTeam) {
      return;
    }
    if (this.refreshingConnectivity && this.connectivityRefreshSession === session) {
      // TURNING_ON and ON can arrive during one native refresh. Re-read the final state instead of dropping it.
      this.connectivityRefreshQueued = true;
      return;
    }
    this.refreshingConnectivity = true;
    const request = this.beginAction('lobby-connectivity');
    this.connectivityRefreshOwner = request;
    this.connectivityRefreshSession = session;
    try {
      do {
        this.connectivityRefreshQueued = false;
        try {
          const refreshing = session.refreshLeaderP2pGroup();
          // The session invalidates advertisement readiness before its first await.
          // Publish that invalidation now, rather than keeping old digits throughout native work.
          this.updateInviteBluetoothState();
          await refreshing;
        } catch (err) {
          logUserFailure('lobby-connectivity', err);
          if (this.isCurrentAction('lobby-connectivity', request)) {
            this.refresh();
            this.status = userErrorMessage(err, '邀请信息更新失败，请稍后重试');
          }
          continue;
        }
        if (!this.isCurrentAction('lobby-connectivity', request)) {
          return;
        }
        this.refresh();
        this.updateRoomStatus();
      } while (this.connectivityRefreshQueued && this.isCurrentAction('lobby-connectivity', request));
    } finally {
      if (this.connectivityRefreshOwner === request) {
        const retry = this.connectivityRefreshQueued && this.randomPreviewPageVisible &&
          !this.leavingLobby && session === AppSession.get();
        this.refreshingConnectivity = false;
        this.connectivityRefreshQueued = false;
        this.connectivityRefreshOwner = 0;
        this.connectivityRefreshSession = undefined;
        if (retry) {
          void this.refreshLeaderConnectivity();
        }
      }
    }
  }

  private onStoreEntitlementsChanged(): void {
    this.refreshDrumAccess();
    const session = AppSession.get();
    if (session !== undefined) {
      void this.reconcileLobbySceneAccess(session).catch((error: Error) => {
        logUserFailure('lobby-scene-access', error);
      });
    }
    this.refresh();
  }

  private async reconcileLobbySceneAccess(session: AppSession): Promise<void> {
    if (session !== AppSession.get() || !this.randomPreviewPageVisible || this.leavingLobby ||
      !session.controller.isLeader || isSceneAccessible(session.controller.sceneKey)) {
      return;
    }
    // The room owns the scene. Updating only cached UI storage would be undone
    // by its next snapshot; only the visible leader lobby reconciles revocation.
    await session.controller.updateSceneKey('sunset_coast');
  }

  private refreshDrumAccess(): void {
    const access = resolveDrumAccess();
    this.drumAccessAllowed = access.allowed;
    this.drumAccessSource = access.source;
    this.drumAccessExpiresAt = access.expiresAt;
  }

  private startDrumAccessRefresh(): void {
    this.refreshDrumAccess();
    if (this.drumAccessRefreshTimer < 0) {
      this.drumAccessRefreshTimer = setInterval(() => this.refreshDrumAccess(), 1000);
    }
  }

  private stopDrumAccessRefresh(): void {
    if (this.drumAccessRefreshTimer >= 0) {
      clearInterval(this.drumAccessRefreshTimer);
      this.drumAccessRefreshTimer = -1;
    }
  }

  private drumAccessLabel(): string {
    if (this.drumAccessSource === 'trial') {
      return `试用中 · 截止 ${formatTrialExpiry(this.drumAccessExpiresAt)}`;
    }
    if (this.drumAccessSource === 'monthly') {
      return '月卡已解锁';
    }
    return this.drumAccessAllowed ? '已解锁' : '使用前需解锁';
  }

  private async initialize(): Promise<void> {
    const request = this.beginAction('lobby-initialize', false);
    this.loading = true;
    this.failed = false;
    // Cached entitlements already back the controls. Refresh them independently:
    // store/network latency must not hold an unrelated local roster off screen.
    const entitlements = refreshStoreEntitlementsNow().catch((error: Error) => {
      logUserFailure('lobby-store-refresh', error);
    });
    try {
      const params = router.getParams() as Record<string, string>;
      if (params?.['reuse'] !== '1') {
        await AppSession.reset();
        if (!this.isCurrentAction('lobby-initialize', request)) {
          return;
        }
        const name = params?.['displayName'] || 'Player';
        const session = AppSession.createLeader(name);
        this.actionSessions.set('lobby-initialize', session);
        if (params?.['solo'] === '1') {
          const preparing = session.leaderBootstrapSolo(name);
          this.refresh();
          await preparing;
        } else {
          // The leader exists before Wi-Fi/BLE/background setup. Show that real
          // roster now, while loading still prevents an unprepared departure.
          this.refresh();
          const ctx = getContext(this) as common.UIAbilityContext;
          const granted = await ensureTeamNetworkPermissions(ctx);
          if (!this.isCurrentAction('lobby-initialize', request)) {
            return;
          }
          if (!granted) {
            throw new Error(teamNetworkPermissionDeniedHint());
          }
          const accessible = await verifyTeamNetworkAccess();
          if (!this.isCurrentAction('lobby-initialize', request)) {
            return;
          }
          if (!accessible) {
            throw new Error(teamNetworkAccessUnavailableHint());
          }
          await ensureBluetoothDiscoveryPermission(ctx);
          if (!this.isCurrentAction('lobby-initialize', request)) {
            return;
          }
          await session.leaderBootstrap(name);
        }
      } else {
        const session = AppSession.get();
        if (session !== undefined) {
          this.actionSessions.set('lobby-initialize', session);
        }
        this.refresh();
      }
      if (!this.isCurrentAction('lobby-initialize', request)) {
        return;
      }
      // A valid local snapshot can make the lobby usable while revalidating.
      // Missing/expired snapshots retain the first-run entitlement readiness gate.
      if (!hasUsableEntitlementCache()) {
        await entitlements;
      }
      if (!this.isCurrentAction('lobby-initialize', request)) {
        return;
      }
      const session = AppSession.get();
      if (session !== undefined) {
        await this.reconcileLobbySceneAccess(session);
        if (!this.isCurrentAction('lobby-initialize', request)) {
          return;
        }
      }
      this.refresh();
      this.soloTeam = AppSession.get()?.controller.soloTeam ?? false;
      this.updateRoomStatus();
      if (!this.failed && !this.soloTeam && this.leader && this.qr.length > 0) {
        this.invite = true;
      }
    } catch (e) {
      logUserFailure('lobby-initialize', e);
      if (this.isCurrentAction('lobby-initialize', request)) {
        this.failed = true;
        this.status = userErrorMessage(e, '队伍创建失败，请重试');
      }
    } finally {
      if (this.isCurrentAction('lobby-initialize', request)) {
        this.loading = false;
      }
    }
  }

  private updateRoomStatus(): void {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || this.failed) {
      return;
    }
    this.status = '';
  }

  private async leaveLobby(): Promise<void> {
    if (this.leavingLobby || this.enteringStage) {
      return;
    }
    this.bluetoothRouteProbeRequestToken++;
    if (this.bluetoothRouteConfirmVisible) {
      this.dismissBluetoothRouteConfirmation();
    }
    this.leavingLobby = true;
    const request = this.beginAction('lobby-exit', false);
    this.status = '正在退出队伍…';
    try {
      await AppSession.reset();
      if (!this.isCurrentAction('lobby-exit', request)) {
        this.leavingLobby = false;
        return;
      }
      await navigateToHome();
    } catch (error) {
      this.reportActionFailure('lobby-exit', request, error, '退出队伍失败，请重试');
      this.leavingLobby = false;
      if (this.isCurrentAction('lobby-exit', request)) {
        this.status = '';
      }
    }
  }

  refresh(): void {
    this.updateInviteBluetoothState();
    const c = AppSession.get()?.controller;
    if (c === undefined) { return; }
    this.members = c.getMembers(); this.leader = c.isLeader;
    this.bpm = c.bpm; this.beats = c.beatsPerBar; this.unit = c.beatUnit; this.rhythm = c.rhythm;
    this.drumProgram = c.drumProgram;
    if (this.rhythm === 3) {
      this.rhythmDropdownOpen = false;
    }
    this.selectedSceneKey = c.sceneKey;
    this.soloTeam = c.soloTeam;
    if (this.rosterDragMemberId.length > 0 &&
      (this.rosterDragSession !== AppSession.get() || !this.soloRosterReorderEnabled() ||
      this.members.findIndex((member: SessionMember) => member.id === this.rosterDragMemberId) !==
        this.rosterDragFromIndex)) {
      this.cancelRosterDrag();
    }
    this.qr = c.buildJoinQrPayload();
    this.localReady = c.isLocalLobbyReady();
    this.leaderCanDepart = c.canLeaderStartWalk();
    this.ensureEditingMember();
    if (this.randomPreviewPendingMemberId === this.editingMemberId &&
      this.members.some((member: SessionMember) => member.id === this.randomPreviewPendingMemberId &&
        isRandomAvatar(member.avatarKey) && (member.randomDrawId ?? 0) > this.randomPreviewPreviousDrawId)) {
      this.randomPreviewPendingMemberId = '';
    }
    this.completeInterruptedRandomPreviews();
    if (!this.soloTeam && !this.leader && c.lobbyDeparted) {
      void this.enterStage();
    }
  }

  private async applyMeter(beats: number, unit: number): Promise<void> {
    if (!this.leader || this.loading) {
      return;
    }
    this.beats = beats;
    this.unit = unit;
    const request = this.beginAction('lobby-meter');
    try {
      await AppSession.get()?.controller.updateMeter(beats, unit);
      if (this.isCurrentAction('lobby-meter', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-meter', request, error, '拍号同步失败，请重试');
    }
  }

  private ensureEditingMember(): void {
    const c = AppSession.get()?.controller;
    if (c === undefined) {
      this.editingMemberId = 'leader';
      return;
    }
    if (!c.isLeader) {
      const localId = c.getLocalMemberId();
      if (localId.length > 0) {
        this.editingMemberId = localId;
        return;
      }
    }
    let found = false;
    for (let i = 0; i < this.members.length; i++) {
      if (this.members[i].id === this.editingMemberId) {
        found = true;
        break;
      }
    }
    if (found) {
      return;
    }
    if (c.soloTeam && c.isLeader) {
      this.editingMemberId = 'leader';
      return;
    }
    const localId = c.getLocalMemberId();
    this.editingMemberId = localId.length > 0 ? localId : 'leader';
  }

  private canEditMember(memberId: string): boolean {
    const c = AppSession.get()?.controller;
    if (c === undefined) {
      return false;
    }
    if (c.soloTeam && c.isLeader) {
      return true;
    }
    return memberId === c.getLocalMemberId();
  }

  private editingAvatarKey(): string {
    for (let i = 0; i < this.members.length; i++) {
      if (this.members[i].id === this.editingMemberId) {
        return this.members[i].avatarKey;
      }
    }
    return 'random';
  }

  private editingResolvedAvatarKey(): string {
    for (let i = 0; i < this.members.length; i++) {
      if (this.members[i].id === this.editingMemberId) {
        return this.members[i].resolvedAvatarKey ?? '';
      }
    }
    return '';
  }

  private showingRandomMystery(): boolean {
    return isRandomAvatar(this.editingAvatarKey()) ||
      this.randomPreviewPendingMemberId === this.editingMemberId ||
      this.interruptedRandomPreviews.has(this.editingMemberId);
  }

  private randomPreviewReady(): boolean {
    return !this.loading && !this.failed && this.randomPreviewPageVisible &&
      this.members.some((member: SessionMember) => member.id === this.editingMemberId);
  }

  private editingRandomDrawId(): number {
    const member = this.members.find((value: SessionMember) => value.id === this.editingMemberId);
    return member?.randomDrawId ?? 0;
  }

  private shouldSkipEditingRandomPlayback(): boolean {
    const member = this.members.find((value: SessionMember) => value.id === this.editingMemberId);
    const revealAt = member?.randomAvatarRevealAtLeaderMs;
    return this.interruptedRandomPreviews.has(this.editingMemberId) ||
      (revealAt !== undefined && Number.isFinite(revealAt) && revealAt >= 0);
  }

  private finishRandomPreviewBeforeSwitch(): void {
    if (!this.randomPreviewReady() || !this.showingRandomMystery()) {
      return;
    }
    const minimumDrawId = this.randomPreviewPendingMemberId === this.editingMemberId
      ? this.randomPreviewPreviousDrawId + 1 : Math.max(1, this.editingRandomDrawId());
    this.interruptedRandomPreviews.set(this.editingMemberId,
      Math.max(minimumDrawId, this.interruptedRandomPreviews.get(this.editingMemberId) ?? 0));
    this.completeInterruptedRandomPreviews();
  }

  private completeInterruptedRandomPreviews(): void {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !this.randomPreviewPageVisible || this.loading || this.failed) {
      return;
    }
    const members = controller.getMembers();
    this.interruptedRandomPreviews.forEach((minimumDrawId: number, memberId: string) => {
      const member = members.find((value: SessionMember) => value.id === memberId);
      if (member === undefined) {
        this.interruptedRandomPreviews.delete(memberId);
        return;
      }
      const drawId = member.randomDrawId ?? 0;
      if (!isRandomAvatar(member.avatarKey) || !Number.isSafeInteger(drawId) || drawId < minimumDrawId ||
        !isRandomPoolCharacter(member.resolvedAvatarKey ?? '')) {
        return;
      }
      // Remove before publication, which can synchronously trigger refresh.
      // Only the confirmed new draw may satisfy an interrupted pending reroll.
      this.interruptedRandomPreviews.delete(memberId);
      void this.publishRandomFilmResult(memberId, drawId);
    });
  }

  private revealedMemberMysteryAvatar(member: SessionMember): string {
    return AppSession.get()?.controller.isMemberRandomAvatarRevealed(member.id) === true
      ? member.resolvedAvatarKey ?? '' : '';
  }

  private async onRandomFilmSettled(memberId: string, drawId: number): Promise<void> {
    if (memberId !== this.editingMemberId || !this.randomPreviewReady() ||
      this.randomPreviewPendingMemberId === memberId || !isRandomAvatar(this.editingAvatarKey()) ||
      drawId !== this.editingRandomDrawId()) {
      return;
    }
    await this.publishRandomFilmResult(memberId, drawId);
  }

  private async publishRandomFilmResult(memberId: string, drawId: number): Promise<void> {
    try {
      await AppSession.get()?.controller.completeRandomAvatarPreview(memberId, drawId);
    } catch (error) {
      logUserFailure('lobby-random-character', error);
      if (this.randomPreviewPageVisible && this.members.some((member: SessionMember) =>
        member.id === memberId && member.randomDrawId === drawId)) {
        showUserNotice(userErrorMessage(error, '角色同步失败，请重试'), 'lobby-character');
      }
    }
  }

  private pickStateForKey(key: string): CharacterPickState {
    return characterPickState(key, this.members, this.editingMemberId, this.soloTeam);
  }

  private isLimitedFreeCharacter(key: string): boolean {
    return limitedFreeCharacterKeys().indexOf(key) >= 0;
  }

  private isCharacterOccupied(key: string): boolean {
    // Pick state prioritizes readiness and entitlement. Occupancy must still
    // describe another member's exclusive selection, never our own selection.
    return isExclusiveTakenByOther(this.members, key, this.editingMemberId);
  }

  private characterBadgeWidth(key: string): number {
    if (!isCharacterOwned(key) || !this.isLimitedFreeCharacter(key)) {
      return CHARACTER_BADGE_ICON_SIZE;
    }
    return CHARACTER_FREE_BADGE_WIDTH + (isDuplicatableAvatar(key) || this.isCharacterOccupied(key)
      ? CHARACTER_BADGE_GAP + CHARACTER_BADGE_ICON_SIZE : 0);
  }

  private characterBadgeHeight(key: string): number {
    return isCharacterOwned(key) && this.isLimitedFreeCharacter(key)
      ? CHARACTER_FREE_BADGE_HEIGHT : CHARACTER_BADGE_ICON_SIZE;
  }

  private async pickCharacter(key: string): Promise<void> {
    if (this.pickStateForKey(key) !== 'selectable') {
      return;
    }
    const memberId = this.editingMemberId;
    const token = ++this.randomSelectionToken;
    this.interruptedRandomPreviews.delete(memberId);
    if (isRandomAvatar(key)) {
      this.randomPreviewPreviousDrawId = this.editingRandomDrawId();
      this.randomPreviewPendingMemberId = memberId;
      this.randomPreviewRequest += 1;
    } else {
      this.randomPreviewPendingMemberId = '';
      this.randomPreviewCancelRequest += 1;
    }
    try {
      await AppSession.get()?.controller.updateMemberAvatar(memberId, key);
      this.refresh();
    } catch (error) {
      logUserFailure('lobby-character', error);
      if (token === this.randomSelectionToken && this.randomPreviewPageVisible) {
        this.randomPreviewPendingMemberId = '';
        showUserNotice(userErrorMessage(error, '角色同步失败，请重试'), 'lobby-character');
      }
    } finally {
      // A follower's send may finish before the leader's snapshot. Retain the
      // film until random is confirmed, without remounting/replaying it twice.
      // An older completion must also never dismiss a newer member's film.
      if (token === this.randomSelectionToken && !isRandomAvatar(key)) {
        this.randomPreviewPendingMemberId = '';
      }
    }
  }

  private selectEditingMember(memberId: string): void {
    if (!this.canEditMember(memberId) || memberId === this.editingMemberId) {
      return;
    }
    this.finishRandomPreviewBeforeSwitch();
    this.randomSelectionToken += 1;
    this.randomPreviewPendingMemberId = '';
    this.editingMemberId = memberId;
  }

  private localLobbyReady(): boolean {
    return this.localReady;
  }

  private canLeaderDepart(): boolean {
    return this.leaderCanDepart;
  }

  private primaryLobbyLabel(): string {
    if (this.leavingLobby) {
      return '正在退出…';
    }
    if (this.failed) {
      return '重试创建';
    }
    if (this.loading) {
      return '正在连接…';
    }
    if (this.leader) {
      return '出发';
    }
    if (this.localLobbyReady()) {
      return '取消准备';
    }
    return '准备';
  }

  private primaryLobbyFill(): string {
    if (!this.leader && this.localLobbyReady()) {
      return '#D8D3C8';
    }
    return CORAL;
  }

  private primaryLobbyActive(): boolean {
    if (this.loading || this.leavingLobby) {
      return false;
    }
    if (this.failed) {
      return true;
    }
    if (!this.leader || this.soloTeam) {
      return true;
    }
    return this.canLeaderDepart();
  }

  private async handlePrimaryLobbyAction(): Promise<void> {
    if (this.failed) {
      void this.initialize();
      return;
    }
    if (this.loading || this.leavingLobby) {
      return;
    }
    const c = AppSession.get()?.controller;
    if (c === undefined) {
      return;
    }
    if (c.soloTeam) {
      void this.enterStage();
      return;
    }
    if (c.isLeader) {
      await this.leaderDepartToWalk();
      return;
    }
    const request = this.beginAction('lobby-ready');
    try {
      await c.setLobbyReady(!c.isLocalLobbyReady());
      if (this.isCurrentAction('lobby-ready', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-ready', request, error, '准备状态同步失败，请重试');
    }
  }

  private async leaderDepartToWalk(): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined || !c.canLeaderStartWalk()) {
      return;
    }
    const request = this.beginAction('lobby-depart');
    try {
      await c.departLobbyToWalk();
      if (!this.isCurrentAction('lobby-depart', request)) {
        return;
      }
      await this.enterStage();
    } catch (error) {
      this.reportActionFailure('lobby-depart', request, error, '出发同步失败，请重试');
    }
  }

  private async chooseScene(key: string): Promise<void> {
    if (!this.leader || this.loading || key === this.selectedSceneKey) { return; }
    if (!isSceneAccessible(key)) {
      showUserNotice('请先在收藏小铺解锁这个场景', 'lobby-scene');
      return;
    }
    const request = this.beginAction('lobby-scene');
    try {
      await AppSession.get()?.controller.updateSceneKey(key);
      if (this.isCurrentAction('lobby-scene', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-scene', request, error, '场景同步失败，请重试');
    }
  }

  private activeDrumProgram(): DrumProgram {
    return parseDrumProgram(this.drumProgram);
  }

  private activeDrumProgramName(): string {
    return resolveSavedDrumProgram(this.drumProgram, AppSession.get()?.controller.drumProgramLibraryId,
      loadSavedDrumPrograms())?.name ?? '未命名编排';
  }

  private activeDrumStyleKeys(): string[] {
    return drumProgramStyleKeys(this.activeDrumProgram());
  }

  private activeDrumVisibleStyleKeys(): string[] {
    return this.activeDrumStyleKeys().slice(0, 2);
  }

  private activeDrumSectionCount(): number {
    return this.activeDrumProgram().sections.length;
  }

  private activeDrumBarCount(): number {
    const sections = this.activeDrumProgram().sections;
    let total = 0;
    for (let i = 0; i < sections.length; i++) {
      total += sections[i].repeats;
    }
    return total;
  }

  private editDrumMachine(): void {
    if (!isProDrumMachineAccessible()) {
      this.showProDrumAccessToast();
      this.proDrumEntryScale = 0.96;
      animateTo({ duration: 240, curve: Curve.EaseOut }, () => { this.proDrumEntryScale = 1; });
      return;
    }
    router.pushUrl({ url: 'pages/DrumMachinePage' });
  }

  private showProDrumAccessToast(): void {
    this.refreshDrumAccess();
    showUserNotice(this.drumAccessAllowed ? this.drumAccessLabel() :
      '定制鼓机包含在畅游月卡中', 'lobby-drum-access');
  }

  private async switchToBasicBeat(): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader) {
      return;
    }
    const stored = AppStorage.get<number>('lastBasicRhythm') ?? 0;
    const next = stored >= 0 && stored <= 2 ? stored : 0;
    const request = this.beginAction('lobby-rhythm');
    try {
      await controller.updateRhythm(next);
      if (this.isCurrentAction('lobby-rhythm', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-rhythm', request, error, '节奏同步失败，请重试');
    }
  }

  private openRhythmDropdown(): void {
    if (!this.leader || this.loading) {
      return;
    }
    if (this.rhythmDropdownOpen) {
      this.rhythmDropdownOpen = false;
      return;
    }
    try {
      const uiContext = this.getUIContext();
      const rect = uiContext.getComponentUtils().getRectangleById('lobby-rhythm-select');
      this.rhythmDropdownX = uiContext.px2vp(rect.windowOffset.x);
      this.rhythmDropdownY = uiContext.px2vp(rect.windowOffset.y + rect.size.height);
      this.rhythmDropdownWidth = uiContext.px2vp(rect.size.width);
    } catch (_e) {
      this.rhythmDropdownX = 86;
      this.rhythmDropdownY = 120;
      this.rhythmDropdownWidth = 220;
    }
    this.rhythmDropdownOpen = true;
  }

  private async chooseBasicRhythm(index: number): Promise<void> {
    if (!this.leader || index < 0 || index >= this.rhythms.length) {
      return;
    }
    this.rhythmDropdownOpen = false;
    const request = this.beginAction('lobby-rhythm');
    try {
      await AppSession.get()?.controller.updateRhythm(index);
      if (this.isCurrentAction('lobby-rhythm', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-rhythm', request, error, '节奏同步失败，请重试');
    }
  }

  private async enterStage(): Promise<void> {
    if (this.enteringStage) {
      return;
    }
    this.enteringStage = true;
    const request = this.beginAction('lobby-enter-stage');
    try {
      await router.pushUrl({ url: 'pages/MainPage' });
    } catch (error) {
      this.reportActionFailure('lobby-enter-stage', request, error, '进入行进页失败，请重试');
      if (this.isCurrentAction('lobby-enter-stage', request)) {
        this.enteringStage = false;
      }
    }
  }

  private canAddSoloBotSlot(): boolean {
    return this.members.length < SESSION_MAX_MEMBER_COUNT &&
      (AppSession.get()?.controller.canAddSoloBot() ?? false);
  }

  private soloRosterReorderEnabled(): boolean {
    return this.soloTeam && this.leader && !this.loading && this.randomPreviewPageVisible &&
      !this.leavingLobby && !this.enteringStage;
  }

  private rosterDragOverflowPaint(): boolean {
    return this.rosterDragMemberId.length > 0;
  }

  private beginRosterDrag(memberId: string): void {
    if (!this.soloRosterReorderEnabled()) {
      return;
    }
    const fromIndex = this.members.findIndex((member: SessionMember) => member.id === memberId);
    if (fromIndex < 0) {
      return;
    }
    const session = AppSession.get();
    if (session === undefined) {
      return;
    }
    this.rosterDragMemberId = memberId;
    this.rosterDragFromIndex = fromIndex;
    this.rosterDragSession = session;
    this.rosterDragOffsetX = 0;
    this.rosterDragSuppressSelectUntil = 0;
  }

  private updateRosterDrag(offsetX: number): void {
    if (this.rosterDragMemberId.length === 0) {
      return;
    }
    if (this.rosterDragSession !== AppSession.get() || !this.soloRosterReorderEnabled()) {
      this.cancelRosterDrag();
      return;
    }
    this.rosterDragOffsetX = offsetX;
  }

  private rosterDragTargetIndex(): number {
    if (this.rosterDragMemberId.length === 0 || this.rosterDragFromIndex < 0 ||
      this.rosterDragFromIndex >= this.members.length ||
      this.members[this.rosterDragFromIndex].id !== this.rosterDragMemberId) {
      return -1;
    }
    return Math.max(0, Math.min(this.members.length - 1,
      this.rosterDragFromIndex + Math.round(this.rosterDragOffsetX / ROSTER_SLOT_STEP)));
  }

  private rosterMemberDragOffsetX(memberId: string): number {
    const targetIndex = this.rosterDragTargetIndex();
    if (targetIndex < 0) {
      return 0;
    }
    if (memberId === this.rosterDragMemberId) {
      return this.rosterDragOffsetX;
    }
    const index = this.members.findIndex((member: SessionMember) => member.id === memberId);
    // Preview an insertion gap without changing the authoritative roster or
    // rebuilding its gesture owner. Only the drop commits the new walk order.
    if (index > this.rosterDragFromIndex && index <= targetIndex) {
      return -ROSTER_SLOT_STEP;
    }
    if (index >= targetIndex && index < this.rosterDragFromIndex) {
      return ROSTER_SLOT_STEP;
    }
    return 0;
  }

  private cancelRosterDrag(): void {
    // A long-press can end before Pan recognizes. Guard its trailing click, but
    // expire by time so cancellation cannot permanently disable avatar selection.
    if (this.rosterDragMemberId.length > 0) {
      this.rosterDragSuppressSelectUntil = Date.now() + ROSTER_DRAG_CLICK_GUARD_MS;
    }
    this.rosterDragMemberId = '';
    this.rosterDragFromIndex = -1;
    this.rosterDragSession = undefined;
    this.rosterDragOffsetX = 0;
  }

  private async finishRosterDrag(): Promise<void> {
    if (this.rosterDragMemberId.length === 0 || this.rosterDragFromIndex < 0) {
      this.cancelRosterDrag();
      return;
    }
    const session = this.rosterDragSession;
    const fromIndex = this.members.findIndex((member: SessionMember) => member.id === this.rosterDragMemberId);
    // A delayed gesture from an earlier room or a changed roster must never
    // reorder a different member that now happens to occupy the old index.
    if (session === undefined || session !== AppSession.get() || !this.soloRosterReorderEnabled() ||
      fromIndex !== this.rosterDragFromIndex) {
      this.cancelRosterDrag();
      return;
    }
    const toIndex = this.rosterDragTargetIndex();
    this.cancelRosterDrag();
    if (fromIndex === toIndex) {
      return;
    }
    const request = this.beginAction('lobby-reorder-roster');
    try {
      await session.controller.reorderSoloMembers(fromIndex, toIndex);
      if (this.isCurrentAction('lobby-reorder-roster', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-reorder-roster', request, error, '调整顺序失败，请重试');
    }
  }

  private selectRosterMember(memberId: string): void {
    if (this.rosterDragMemberId.length > 0 || Date.now() < this.rosterDragSuppressSelectUntil) {
      return;
    }
    this.selectEditingMember(memberId);
  }

  private keepRosterAddSlotVisible(): void {
    if (!this.soloTeam || !this.leader) {
      return;
    }
    // The add slot is the final item, so the smallest shift that keeps it visible
    // is the horizontal scroll container's current end position.
    this.rosterScroller.scrollEdge(Edge.End);
  }

  private async addSoloBotSlot(): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined || !this.canAddSoloBotSlot()) {
      return;
    }
    const request = this.beginAction('lobby-add-bot');
    try {
      const newBotId = await c.addSoloBotWithNextAvatar();
      if (!this.isCurrentAction('lobby-add-bot', request)) {
        return;
      }
      this.refresh();
      if (newBotId !== undefined && newBotId.length > 0) {
        this.selectEditingMember(newBotId);
      }
      this.keepRosterAddSlotVisible();
    } catch (error) {
      this.reportActionFailure('lobby-add-bot', request, error, '添加人机失败，请重试');
    }
  }

  private async removeSoloBotSlot(id: string): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined) {
      return;
    }
    const request = this.beginAction('lobby-remove-bot');
    try {
      await c.removeSoloBotById(id);
      if (this.isCurrentAction('lobby-remove-bot', request)) {
        this.refresh();
      }
    } catch (error) {
      this.reportActionFailure('lobby-remove-bot', request, error, '移除人机失败，请重试');
    }
  }

  @Builder
  private rosterReadyStatusSegment(member: SessionMember) {
    Row() {
      Text('✓')
        .fontSize(10)
        .fontWeight(900)
        .fontColor(WHITE)
    }
    .width(member.bluetoothCalibrating === true ? ROSTER_AVATAR_SIZE / 2 : ROSTER_AVATAR_SIZE)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(TEAL)
  }

  @Builder
  private rosterCalibrationStatusSegment(member: SessionMember) {
    Row({ space: 1 }) {
      Image($rawfile('comic/icons/headphones-status.svg'))
        .width(ROSTER_STATUS_ICON_SIZE)
        .height(ROSTER_STATUS_ICON_SIZE)
        .objectFit(ImageFit.Contain)
      Row({ space: 1 }) {
        ForEach(CALIBRATION_DOT_INDICES, (dotIndex: number) => {
          Circle()
            .width(ROSTER_STATUS_DOT_SIZE)
            .height(ROSTER_STATUS_DOT_SIZE)
            .fill(WHITE)
            .opacity(dotIndex === this.calibrationDotPhase ? 1 : 0.38)
            .translate({ y: dotIndex === this.calibrationDotPhase ? -1 : 0 })
        })
      }
    }
    .width(member.lobbyReady === true ? ROSTER_AVATAR_SIZE / 2 : ROSTER_AVATAR_SIZE)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(CORAL)
    .border({ width: { left: member.lobbyReady === true ? 1 : 0 }, color: INK })
  }

  @Builder
  private rosterStatusRail(member: SessionMember) {
    Row({ space: 0 }) {
      if (member.lobbyReady === true) {
        this.rosterReadyStatusSegment(member)
      }
      if (member.bluetoothCalibrating === true) {
        this.rosterCalibrationStatusSegment(member)
      }
    }
    .width(ROSTER_AVATAR_SIZE)
    .height(ROSTER_STATUS_RAIL_HEIGHT)
    .border({ width: 1, color: INK })
    .borderRadius({ bottomLeft: 4, bottomRight: 4 })
    .position({ x: 0, y: ROSTER_AVATAR_SIZE - ROSTER_STATUS_RAIL_HEIGHT })
    .clip(true)
    .zIndex(3)
    .hitTestBehavior(HitTestMode.None)
  }

  private characterPickSelected(key: string): boolean {
    return (this.showingRandomMystery() ? 'random' : this.editingAvatarKey()) === key;
  }

  @Builder
  private rosterMemberPortrait(member: SessionMember) {
    ActionButton({
      active: this.canEditMember(member.id),
      controlWidth: ROSTER_AVATAR_SIZE, controlHeight: ROSTER_AVATAR_SIZE,
      fill: PAPER, cornerRadius: 4,
      hardShadow: this.editingMemberId === member.id ?
        { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
      accessibilityLabel: `${member.displayName}，选择队员`,
      action: () => { this.selectRosterMember(member.id); }
    }) {
      Stack() {
        ComicCharacter({
          avatar: member.avatarKey,
          portrait: true,
          allowNativeDrag: false,
          mysteryAvatar: this.revealedMemberMysteryAvatar(member)
        }).width(ROSTER_AVATAR_SIZE).height(ROSTER_AVATAR_SIZE)
      }
      .width(ROSTER_AVATAR_SIZE).height(ROSTER_AVATAR_SIZE)
      .backgroundColor(PAPER)
      .border({ width: this.editingMemberId === member.id ? 2 : 0, color: INK })
      .borderRadius(4).clip(true)
    }
  }

  @Builder
  private rosterMemberSlotBody(member: SessionMember) {
    Column({ space: ROSTER_SLOT_NAME_GAP }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.rosterMemberPortrait(member)
        if (member.lobbyReady === true || member.bluetoothCalibrating === true) {
          this.rosterStatusRail(member)
        }
        if (this.soloTeam && this.leader && SessionController.isSoloBotMemberId(member.id)) {
          Text('×')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(PAPER)
            .width(17)
            .height(17)
            .textAlign(TextAlign.Center)
            .backgroundColor(INK)
            .borderRadius(9)
            .margin({ top: 1, right: 1 })
            .onClick(() => { void this.removeSoloBotSlot(member.id); })
        }
      }
      .width(ROSTER_AVATAR_SIZE)
      .height(ROSTER_AVATAR_SIZE)
      .clip(false)
      Text(member.displayName).fontSize(10).maxLines(1).width(ROSTER_SLOT_COLUMN_WIDTH)
        .height(ROSTER_SLOT_NAME_HEIGHT).textAlign(TextAlign.Center)
    }
    .width(ROSTER_SLOT_COLUMN_WIDTH)
    .alignItems(HorizontalAlign.Center)
    .clip(false)
  }

  @Builder
  private rosterMemberSlot(member: SessionMember) {
    // Keep the same avatar subtree when initialization finishes. Gesture actions
    // still check readiness, so loading no longer forces a second image mount.
    if (this.soloTeam && this.leader) {
      Column() {
        this.rosterMemberSlotBody(member)
      }
      .width(ROSTER_SLOT_COLUMN_WIDTH)
      .translate({ x: this.rosterMemberDragOffsetX(member.id) })
      // The held avatar tracks the finger immediately; only its neighbours ease
      // into the gap. Disable the preview animation when layout commits on drop.
      .animation({
        duration: this.rosterDragMemberId.length > 0 && this.rosterDragMemberId !== member.id
          ? ROSTER_REORDER_SHIFT_MS : 0,
        curve: Curve.EaseOut
      })
      .zIndex(this.rosterDragMemberId === member.id ? 10 : 0)
      .opacity(this.rosterDragMemberId === member.id ? ROSTER_DRAG_HELD_OPACITY : 1)
      .scale({
        x: this.rosterDragMemberId === member.id ? ROSTER_DRAG_HELD_SCALE : 1,
        y: this.rosterDragMemberId === member.id ? ROSTER_DRAG_HELD_SCALE : 1,
        centerX: ROSTER_SLOT_COLUMN_WIDTH / 2,
        centerY: ROSTER_SLOT_TOTAL_HEIGHT / 2
      })
      .priorityGesture(GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false, duration: ROSTER_DRAG_LONG_PRESS_MS })
          .onAction(() => { this.beginRosterDrag(member.id); }),
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 1 })
          .onActionStart((event: GestureEvent) => { this.updateRosterDrag(event.offsetX); })
          .onActionUpdate((event: GestureEvent) => { this.updateRosterDrag(event.offsetX); })
          .onActionEnd((event: GestureEvent) => {
            this.updateRosterDrag(event.offsetX);
            void this.finishRosterDrag();
          })
          .onActionCancel(() => { this.cancelRosterDrag(); })
      ).onCancel(() => { this.cancelRosterDrag(); }))
    } else {
      this.rosterMemberSlotBody(member)
    }
  }

  @Builder
  private rosterAddSlot() {
    Column({ space: 2 }) {
      Column() {
        ActionButton({
          label: '+', active: this.canAddSoloBotSlot(),
          controlWidth: 43, controlHeight: 43, labelSize: 24, labelWeight: FontWeight.Bold,
          fill: PAPER, lineWidth: 1.5, cornerRadius: 4,
          hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
          accessibilityLabel: '添加队员',
          action: () => { void this.addSoloBotSlot(); }
        })
      }.width(43).clip(false)
      Text(' ').fontSize(10).opacity(0)
    }.width(58)
  }

  @Builder
  private unownedLockBadge() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('comic/icons/lock-cutout.svg'))
        .width(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .height(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .objectFit(ImageFit.Contain)
        .position({ x: -CHARACTER_BADGE_ICON_PADDING, y: -CHARACTER_BADGE_ICON_PADDING })
    }.width(CHARACTER_BADGE_ICON_SIZE).height(CHARACTER_BADGE_ICON_SIZE).clip(false)
  }

  @Builder
  private limitedFreeBadge() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('comic/icons/limited-free-ticket.svg'))
        .width(CHARACTER_FREE_BADGE_WIDTH + 1).height(CHARACTER_FREE_BADGE_HEIGHT + 1)
        .objectFit(ImageFit.Fill)
      Text('限免')
        .width(CHARACTER_FREE_BADGE_WIDTH).height(CHARACTER_FREE_BADGE_HEIGHT)
        .fontSize(10).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        .textAlign(TextAlign.Center)
    }.width(CHARACTER_FREE_BADGE_WIDTH).height(CHARACTER_FREE_BADGE_HEIGHT)
      .rotate({ angle: -4 }).clip(false)
  }

  @Builder
  private duplicateAvatarBadge() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('comic/icons/multi-person-cutout.svg'))
        .width(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .height(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .objectFit(ImageFit.Contain)
        .position({ x: -CHARACTER_BADGE_ICON_PADDING, y: -CHARACTER_BADGE_ICON_PADDING })
    }.width(CHARACTER_BADGE_ICON_SIZE).height(CHARACTER_BADGE_ICON_SIZE).clip(false)
  }

  @Builder
  private occupiedAvatarBadge() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('comic/icons/occupied-person-cutout.svg'))
        .width(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .height(CHARACTER_BADGE_ICON_SIZE + CHARACTER_BADGE_ICON_PADDING * 2)
        .objectFit(ImageFit.Contain)
        .position({ x: -CHARACTER_BADGE_ICON_PADDING, y: -CHARACTER_BADGE_ICON_PADDING })
    }.width(CHARACTER_BADGE_ICON_SIZE).height(CHARACTER_BADGE_ICON_SIZE).clip(false)
  }

  @Builder
  private characterBadges(key: string) {
    // Keep entitlement labels when readiness disables selection. Unowned roles
    // retain the lock priority; accessible exclusive roles can show occupancy.
    // Free access sits left of occupancy, which keeps the right edge anchored.
    // These labels remain opaque sibling layers and are not tap targets.
    Row({ space: CHARACTER_BADGE_GAP }) {
      if (!isCharacterOwned(key)) {
        this.unownedLockBadge()
      } else {
        if (isDuplicatableAvatar(key)) {
          this.duplicateAvatarBadge()
        }
        if (this.isLimitedFreeCharacter(key)) {
          this.limitedFreeBadge()
        }
        if (this.isCharacterOccupied(key)) {
          this.occupiedAvatarBadge()
        }
      }
    }
    .width(this.characterBadgeWidth(key)).height(this.characterBadgeHeight(key))
    .alignItems(VerticalAlign.Bottom)
    .position({
      x: CHARACTER_PICK_AVATAR_SIZE - CHARACTER_BADGE_INSET - this.characterBadgeWidth(key),
      y: CHARACTER_PICK_AVATAR_TOP + CHARACTER_PICK_AVATAR_SIZE - CHARACTER_BADGE_INSET -
        this.characterBadgeHeight(key)
    })
    .clip(false).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private characterPickCell(key: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
      ActionButton({
        active: this.pickStateForKey(key) === 'selectable',
        controlWidth: CHARACTER_PICK_AVATAR_SIZE, controlHeight: CHARACTER_PICK_AVATAR_SIZE,
        hitRegion: { x: 0, y: -CHARACTER_PICK_AVATAR_TOP, width: 59, height: 54 },
        fill: this.characterPickSelected(key) ? LILAC : PAPER,
        cornerRadius: CHARACTER_PICK_CORNER_RADIUS,
        hardShadow: { offsetX: CHARACTER_PICK_SHADOW_OFFSET, offsetY: CHARACTER_PICK_SHADOW_OFFSET, color: INK },
        accessibilityLabel: `${avatarDisplayName(key)}，选择角色`,
        action: () => { void this.pickCharacter(key); }
      }) {
        Stack() {
          ComicCharacter({ avatar: key, portrait: true })
            .width('100%').height('100%')
        }
          .width(CHARACTER_PICK_AVATAR_SIZE).height(CHARACTER_PICK_AVATAR_SIZE)
          .backgroundColor(this.characterPickSelected(key) ? LILAC : PAPER)
          .border({ width: 1.5, color: INK })
          .borderRadius(CHARACTER_PICK_CORNER_RADIUS).clip(true)
      }
      }.width(CHARACTER_PICK_AVATAR_SIZE).height(CHARACTER_PICK_AVATAR_SIZE)
        .position({ x: 0, y: CHARACTER_PICK_AVATAR_TOP })
      this.characterBadges(key)
    }
    .width(59)
    .height(54)
    .clip(false)
  }

  @Builder
  private proChain(asset: string) {
    // The image box matches the source aspect ratio, so Contain cannot introduce
    // letterboxing between the 45/235 px anchors and the button's outer edges.
    Image($rawfile(asset))
      .width(PRO_CHAIN_WIDTH).height(PRO_CHAIN_HEIGHT)
      .objectFit(ImageFit.Contain).align(Alignment.TopEnd)
      .translate({ x: PRO_CHAIN_OFFSET_X, y: PRO_CHAIN_TOP_OFFSET })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private proDrumMachineEntryWithChain(asset: string, locked: boolean) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        DrumPaper({ fill: LILAC, cornerRadius: 7, paperLineWidth: 0,
          offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
          Row()
            .width('100%').height(PRO_DRUM_BUTTON_HEIGHT).backgroundColor(LILAC)
            .border({ width: 1.5, color: INK }).borderRadius(7)
            .hitTestBehavior(HitTestMode.None)
        }
      }.width('100%').height(PRO_DRUM_BUTTON_HEIGHT).clip(false)
        .opacity(locked ? 0.68 : 1)
        .align(Alignment.Top).translate({ y: PRO_DRUM_ENTRY_PADDING })
        .hitTestBehavior(HitTestMode.None)
      this.proChain(asset)
      // Keep the title above the decorative chain so narrow-screen labels stay readable.
      Row() {
        Column({ space: 2 }) {
          Text('PRO 定制鼓机').fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
          if (!locked) {
            Text(this.drumAccessLabel()).fontSize(PRO_DRUM_TRIAL_LABEL_SIZE)
              .fontWeight(FontWeight.Bold).fontColor('#5D574F')
          }
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text('›').fontSize(30).fontColor(INK)
      }
      .width('100%').height(PRO_DRUM_BUTTON_HEIGHT).padding({ left: 16, right: 14 })
      .opacity(locked ? 0.68 : 1)
      .align(Alignment.Top).translate({ y: PRO_DRUM_ENTRY_PADDING })
      .hitTestBehavior(HitTestMode.None)
    }
    // Intentionally paint the hanging tail above later controls without adding
    // layout space; taps anywhere on the entry box share one target.
    .width('100%').height(PRO_DRUM_BUTTON_HEIGHT + PRO_DRUM_ENTRY_PADDING * 2).clip(false).zIndex(1)
    .scale({ x: this.proDrumEntryScale, y: this.proDrumEntryScale })
    .onClick(() => { this.editDrumMachine(); })
    .accessibilityText(locked ? 'PRO 定制鼓机，查看开通方案' : 'PRO 定制鼓机，编辑鼓机')
  }

  @Builder
  private proDrumMachineEntry() {
    if (this.drumAccessAllowed) {
      this.proDrumMachineEntryWithChain('comic/decor/pro-chain-anchored.png', false)
    } else {
      this.proDrumMachineEntryWithChain('comic/decor/pro-chain-locked.png', true)
    }
  }

  @Builder
  private scenePreview(key: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (key === 'sunset_coast') {
        Image($rawfile('scenes/sunset/sunset_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
        Image($rawfile('scenes/sunset/sunset_sun.png')).width(54).height(54).objectFit(ImageFit.Contain)
          .position({ x: '60%', y: 4 })
        Image($rawfile('scenes/sunset/sunset_clouds.png')).width('150%').height(48).objectFit(ImageFit.Fill)
          .position({ x: -18, y: 4 })
        Image($rawfile('scenes/sunset/sunset_ocean.png')).width('100%').height(46).objectFit(ImageFit.Fill)
          .position({ x: 0, y: 46 })
        Image($rawfile('scenes/sunset/sunset_midground_dirt.png')).width('100%').height(34).objectFit(ImageFit.Fill)
          .position({ x: 0, y: 55 })
        Image($rawfile('scenes/sunset/sunset_road.png')).width('125%').height(40).objectFit(ImageFit.Fill)
          .position({ x: -14, y: 70 })
      } else {
        Image($rawfile('scenes/neon/neon_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width('118%').height(68).objectFit(ImageFit.Fill)
          .position({ x: -12, y: 8 })
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width('130%').height(72).objectFit(ImageFit.Fill)
          .position({ x: -18, y: 31 })
        Image($rawfile('scenes/neon/neon_road.png')).width('125%').height(40).objectFit(ImageFit.Fill)
          .position({ x: -14, y: 73 })
      }
    }.width('100%').height(96).clip(true)
  }

  @Builder
  private sceneCard(item: LobbySceneOption) {
    Column() {
      DrumPaper({ fill: '#FFFDF7', cornerRadius: LOBBY_SCENE_CORNER_RADIUS, paperLineWidth: 0,
        clipContent: true,
        offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column({ space: 0 }) {
            this.scenePreview(item.key)
            Column({ space: 2 }) {
              Text(item.name).fontSize(15).fontWeight(900).width('100%')
              Text(item.caption).fontSize(10).fontColor('#66615A').width('100%').maxLines(1)
            }.width('100%').padding({ left: 8, right: 8, top: 6, bottom: 7 })
          }.width('100%')
          if (this.selectedSceneKey === item.key) {
            Row() {
              Blank()
              DrumPaper({ fill: CORAL, paperWidth: 'auto', cornerRadius: 4, paperLineWidth: 0,
                offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                Text('✓ 已选择').fontSize(10).fontWeight(900).fontColor(PAPER)
                  .backgroundColor(CORAL).padding({ left: 7, right: 7, top: 4, bottom: 4 }).borderRadius(4)
              }
            }.width('100%').padding({ top: 6, right: 6 }).hitTestBehavior(HitTestMode.None)
            // Add the remaining ink inside the fixed border, without changing
            // the content inset when selection moves between cards.
            Row().width('100%').height('100%')
              .border({ width: LOBBY_SCENE_SELECTED_BORDER_WIDTH - LOBBY_SCENE_BORDER_WIDTH, color: INK })
              .borderRadius(LOBBY_SCENE_CORNER_RADIUS - LOBBY_SCENE_BORDER_WIDTH)
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          }
        }
        .width('100%').height(LOBBY_SCENE_CARD_HEIGHT)
        .backgroundColor('#FFFDF7')
        .border({ width: LOBBY_SCENE_BORDER_WIDTH, color: INK })
        .borderRadius(LOBBY_SCENE_CORNER_RADIUS)
        .onClick(() => { void this.chooseScene(item.key); })
      }
    // Fade the opaque face and ink together. The cache needs the full shadow
    // extent; negative margins preserve card spacing and the Scroll's bounds.
    }.width(LOBBY_SCENE_CARD_WIDTH + LOBBY_AREA_SHADOW_OFFSET)
      .height(LOBBY_SCENE_CARD_HEIGHT + LOBBY_AREA_SHADOW_OFFSET)
      .padding({ right: LOBBY_AREA_SHADOW_OFFSET, bottom: LOBBY_AREA_SHADOW_OFFSET })
      .margin({ right: -LOBBY_AREA_SHADOW_OFFSET, bottom: -LOBBY_AREA_SHADOW_OFFSET })
      .clip(false)
      .renderGroup(!this.leader || !isSceneAccessible(item.key))
      .opacity(this.leader && isSceneAccessible(item.key) ? 1 : ACTION_DISABLED_OPACITY)
  }

  @Builder
  private rhythmDropdownPanel() {
    Column() {
      DrumPaper({ fill: PAPER, cornerRadius: 6, paperLineWidth: 0,
        offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
        Column({ space: 3 }) {
          ForEach(this.rhythms, (name: string, index: number) => {
            DrumPaper({ fill: this.rhythm === index ? CORAL : PAPER, paperWidth: '100%', cornerRadius: 4, paperLineWidth: 0,
              offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
              Button({ type: ButtonType.Normal }) {
                Row() {
                  Text(name).fontSize(13).fontWeight(FontWeight.Bold)
                  Blank()
                  if (this.rhythm === index) {
                    Text('✓').fontSize(13).fontWeight(900)
                  }
                }.width('100%')
              }
              .width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
              .backgroundColor(this.rhythm === index ? CORAL : PAPER)
              .border({ width: 1, color: INK }).borderRadius(4)
              .onClick(() => { void this.chooseBasicRhythm(index); })
            }
          })
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 5, bottom: 5 })
        .backgroundColor(PAPER)
        .border({ width: 1.5, color: INK })
        .borderRadius(6)
        .clip(false)
      }
    }.width(this.rhythmDropdownWidth).clip(false)
  }

  @Builder
  private rhythmDropdownOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .onClick(() => this.rhythmDropdownOpen = false)
      Column() {
        this.rhythmDropdownPanel()
      }
      .position({ x: this.rhythmDropdownX, y: this.rhythmDropdownY })
    }
    .width('100%')
    .height('100%')
    .zIndex(85)
  }

  @Builder
  private inviteUnavailableCard() {
    Row({ space: INVITE_NOTICE_GAP }) {
      Image($rawfile(this.inviteBluetoothState === 'off' || this.inviteBluetoothState === 'turningOff'
        ? 'comic/icons/bluetooth-off.svg' : 'comic/icons/bluetooth.svg'))
        .width(INVITE_NOTICE_ICON_SIZE).height(INVITE_NOTICE_ICON_SIZE)
        .objectFit(ImageFit.Contain).accessibilityLevel('no')
      Column({ space: 3 }) {
        Text(this.inviteUnavailableTitle()).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor(INVITE_NOTICE_INK).width('100%')
        Text(this.inviteUnavailableDetail()).fontSize(11).fontColor(INVITE_NOTICE_INK).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        .accessibilityGroup(true)
      if (this.inviteBluetoothSupported) {
        ActionButton({
          label: this.inviteActionLabel(), active: this.inviteActionEnabled(),
          controlWidth: INVITE_NOTICE_ACTION_WIDTH, controlHeight: INVITE_NOTICE_ACTION_HEIGHT,
          fill: INVITE_NOTICE_FILL, labelColor: INVITE_NOTICE_INK, labelSize: 12,
          labelWeight: FontWeight.Bold, lineWidth: 0, cornerRadius: 4,
          buttonId: 'lobby-enable-join-code',
          accessibilityLabel: this.inviteBluetoothState === 'off' || this.inviteBluetoothState === 'turningOff'
            ? '前往系统设置开启蓝牙，扫码仍可使用' : '重新启用加入码，扫码仍可使用',
          action: () => { void this.activateJoinCode(); }
        })
      }
    }.width('100%')
      .padding({ left: INVITE_NOTICE_HORIZONTAL_PADDING, right: INVITE_NOTICE_HORIZONTAL_PADDING,
        top: INVITE_NOTICE_VERTICAL_PADDING, bottom: INVITE_NOTICE_VERTICAL_PADDING })
      .backgroundColor(INVITE_NOTICE_FILL).borderRadius(5)
      .id('lobby-join-code-notice')
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
        Row() {
          Text('‹').fontSize(32).width(32).onClick(() => { void this.leaveLobby(); })
          Text('队伍大厅').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
          Blank()
          DrumPaper({ fill: LILAC, paperWidth: 'auto', cornerRadius: 4, paperLineWidth: 0,
            offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
            Text(this.leader ? '队长' : '队员').fontSize(12).backgroundColor(LILAC).padding(7).borderRadius(4)
          }
        }.width('100%')
        DrumPaper({ fill: WHITE, cornerRadius: 7, paperLineWidth: 0,
          offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
          Column({ space: 9 }) {
            Row() {
              Text(`${this.members.length} 人在队伍中`).fontWeight(FontWeight.Bold)
              Blank()
              if (this.qr.length > 0 && !this.invite) {
                Text('展开邀请信息 ›')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .onClick(() => { this.invite = true; })
              } else if (this.qr.length === 0) {
                Text('本机练习').fontSize(12).fontColor('#66615A')
              }
            }.width('100%')
            Column() {
              Scroll(this.rosterScroller) {
                Row({ space: ROSTER_SLOT_ROW_GAP }) {
                  ForEach(this.members, (m: SessionMember) => {
                    this.rosterMemberSlot(m)
                  }, (m: SessionMember) => `${m.id}-${m.avatarKey}-${m.randomDrawId ?? 0}-` +
                    `${this.revealedMemberMysteryAvatar(m)}-${m.lobbyReady === true ? 1 : 0}-` +
                    `${m.bluetoothCalibrating === true ? 1 : 0}`)
                  if (this.soloTeam && this.leader) {
                    this.rosterAddSlot()
                  }
                }
                .padding({
                  left: 2,
                  right: COMIC_CONTROL_INK_OFFSET + 2,
                  top: ROSTER_ROW_TOP_PADDING,
                  bottom: ROSTER_SCROLL_BOTTOM_INSET
                })
              }
              .scrollable(ScrollDirection.Horizontal)
              .enableScrollInteraction(this.rosterDragMemberId.length === 0)
              .scrollBar(BarState.Off)
              .width('100%')
              .height(ROSTER_SCROLL_VIEWPORT_HEIGHT)
              .clip(!this.rosterDragOverflowPaint())
            }
            .width('100%')
            .height(ROSTER_SCROLL_VIEWPORT_HEIGHT)
            .clip(!this.rosterDragOverflowPaint())
            .zIndex(this.rosterDragOverflowPaint() ? ROSTER_DRAG_OVERFLOW_Z_INDEX : 0)
            if (this.invite && this.qr.length > 0) {
              QRCode(this.qr).width(150).height(150).backgroundColor(Color.White)
              if (this.leader && !this.canShowJoinCode()) {
                Text('队员可直接扫码').fontSize(12).fontColor('#66615A')
                this.inviteUnavailableCard()
              } else {
                Text(`加入码  ${this.inviteJoinCode}`)
                  .fontSize(28)
                  .fontWeight(900)
                  .fontStyle(FontStyle.Italic)
                  .letterSpacing(4)
                  .id('lobby-join-code')
                Text('扫码或输入 6 位加入码').fontSize(12).fontColor('#66615A')
              }
              Row() {
                Blank()
                Text('收起邀请信息 ›')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .onClick(() => { this.invite = false; })
              }.width('100%')
            }
          }.padding(12).width('100%').backgroundColor(WHITE)
            .border({ width: 1, color: INK }).borderRadius(7)
            .clip(!this.rosterDragOverflowPaint())
        }
        Text('角色选择').width('100%').fontWeight(FontWeight.Bold).fontSize(17)
        Text(this.soloTeam && this.leader ? '点槽位切换编辑 · 长按拖动调整顺序' : '仅可更换自己的角色')
          .fontSize(11).fontColor('#66615A').width('100%')
        if (this.showingRandomMystery()) {
          DrumPaper({ fill: PAPER, cornerRadius: 6, paperLineWidth: 0,
            offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
            RandomCharacterFilm({
              request: this.randomPreviewRequest,
              cancelRequest: this.randomPreviewCancelRequest,
              memberId: this.editingMemberId,
              resolvedAvatarKey: this.editingResolvedAvatarKey(),
              drawId: this.editingRandomDrawId(),
              skipPlayback: this.shouldSkipEditingRandomPlayback(),
              revealReady: AppSession.get()?.controller.isMemberRandomAvatarRevealed(this.editingMemberId) === true,
              onSettled: (memberId: string, drawId: number) => { void this.onRandomFilmSettled(memberId, drawId); },
              selectionPending: this.randomPreviewPendingMemberId === this.editingMemberId,
              ready: this.randomPreviewReady()
            }).width('100%').height(RANDOM_FILM_HEIGHT)
          }
        } else {
          Stack() {
            Image($rawfile('comic/decor/character_panel.png')).width('100%').height('100%').objectFit(ImageFit.Fill)
            ComicCharacter({ avatar: this.editingAvatarKey() }).width('82%').height(248)
            Text('JUST KEEP\nTHE BEAT.').fontWeight(900).fontStyle(FontStyle.Italic).fontSize(14)
              .position({ x: '72%', y: 12 })
          }.height(RANDOM_FILM_HEIGHT).width('100%').clip(true)
        }
        Row({ space: 8 }) {
          Text(avatarDisplayName(this.showingRandomMystery() ? 'random' : this.editingAvatarKey()))
            .fontSize(15).fontWeight(FontWeight.Bold)
          if (this.pickStateForKey(this.editingAvatarKey()) === 'selfReadyLocked') {
            Text('已准备 · 不可换角').fontSize(11).fontColor('#66615A')
          }
        }.width('100%')
        Column() {
          Scroll() {
            Row({ space: 10 }) {
              ForEach(sortRosterKeysForPicker(rosterKeysForLobby(this.soloTeam)), (key: string) => {
                this.characterPickCell(key)
              }, (key: string) => `${key}@${this.storeEntitlementEpoch}`)
            }
            .padding({ left: 2, right: 2, top: 2, bottom: 2 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .clip(true)
        }.width('100%').clip(true)
        if (this.leader) {
          DrumPaper({ fill: WHITE, cornerRadius: 7, paperLineWidth: 0, clipContent: true,
            offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
            Column({ space: 9 }) {
              Row() {
                Text('行进场景').fontSize(18).fontWeight(900)
                Blank()
                Text('点击选择 · 可左右滑动')
                  .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#66615A')
              }.width('100%')
              // Keep card backings inside the viewport while clipping horizontal overflow.
              Scroll() {
                Row({ space: 10 }) {
                  ForEach(LOBBY_SCENES, (item: LobbySceneOption) => {
                    this.sceneCard(item)
                  }, (item: LobbySceneOption) => item.key)
                }.padding({ right: LOBBY_AREA_SHADOW_OFFSET, bottom: LOBBY_AREA_SHADOW_OFFSET })
              }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
                .height(LOBBY_SCENE_CARD_HEIGHT + LOBBY_AREA_SHADOW_OFFSET).clip(true)
            }.width('100%').padding(12).backgroundColor(WHITE)
              .border({ width: 1, color: INK }).borderRadius(7)
              .clip(false)
          }
        }
        if (this.leader && this.rhythm !== 3) {
          DrumPaper({ fill: WHITE, cornerRadius: 7, paperLineWidth: 0,
            offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
            Column({ space: 13 }) {
              Text('队长设置').fontSize(18).fontWeight(900).width('100%')
              Row() {
                Text('节奏型').fontSize(14).width(68)
                Column() {
                  ActionButton({
                    active: this.leader && !this.loading,
                    controlHeight: 34, contentPadding: { left: 8, right: 7 },
                    fill: PAPER, lineWidth: 1, cornerRadius: 5,
                    hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                    buttonId: 'lobby-rhythm-select', accessibilityLabel: this.rhythms[this.rhythm],
                    action: () => this.openRhythmDropdown()
                  }) {
                    Row() {
                      Text(this.rhythms[this.rhythm]).fontSize(13).fontWeight(FontWeight.Bold).fontColor(INK)
                      Blank()
                      Text(this.rhythmDropdownOpen ? '⌃' : '⌄').fontSize(15).fontColor(INK)
                    }.width('100%')
                  }
                }.layoutWeight(1).clip(false)
              }.width('100%')
              Row({ space: 8 }) {
                Text('拍号').fontSize(14).width(60)
                EditableMeter({
                  solidInk: true,
                  beats: this.beats,
                  unit: this.unit,
                  editable: this.leader && !this.loading,
                  controlWidth: '100%',
                  controlHeight: 38,
                  valueFontSize: 20,
                  onEdit: (): void => { this.meterEditorVisible = true; }
                })
                .layoutWeight(1)
              }.width('100%')
              Row({ space: 12 }) {
                Text('BPM').width(56).fontWeight(FontWeight.Bold)
                ActionButton({
                  label: '−', active: this.leader && this.bpm > 40,
                  controlWidth: 'auto', controlHeight: 40, contentPadding: { left: 16, right: 16 },
                  labelSize: 16, labelWeight: FontWeight.Medium, fill: PAPER, lineWidth: 1, cornerRadius: 4,
                  hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                  accessibilityLabel: '降低 BPM',
                  action: () => { void AppSession.get()?.controller.updateBpm(this.bpm - 1); }
                })
                EditableBpm({
                  solidInk: true,
                  value: this.bpm,
                  editable: this.leader && !this.loading,
                  inputId: 'lobby-bpm-input',
                  controlWidth: '100%',
                  controlHeight: 48,
                  valueFontSize: 40,
                  onCommit: (value: number): void => {
                    void AppSession.get()?.controller.updateBpm(value);
                  }
                }).layoutWeight(1)
                ActionButton({
                  label: '+', active: this.leader && this.bpm < 240,
                  controlWidth: 'auto', controlHeight: 40, contentPadding: { left: 16, right: 16 },
                  labelSize: 16, labelWeight: FontWeight.Medium, fill: PAPER, lineWidth: 1, cornerRadius: 4,
                  hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                  accessibilityLabel: '提高 BPM',
                  action: () => { void AppSession.get()?.controller.updateBpm(this.bpm + 1); }
                })
              }.width('100%')
              Text(`每分钟 ${this.bpm} 个${beatUnitLabel(this.unit)}音符拍点`).fontSize(11).fontColor('#66615A').width('100%')
            }.width('100%').padding(12).backgroundColor(WHITE)
              .border({ width: 1, color: INK }).borderRadius(7)
              .clip(false)
          }
        }
        if (this.rhythm === 3 && this.drumProgram.length > 0) {
          DrumPaper({ fill: '#EDE6FF', cornerRadius: DRUM_CARD_RADIUS, paperLineWidth: 0,
            offsetX: LOBBY_AREA_SHADOW_OFFSET, offsetY: LOBBY_AREA_SHADOW_OFFSET }) {
            Column({ space: DRUM_CARD_CONTENT_GAP }) {
              Row() {
                Text('PRO 定制鼓机').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
                Blank()
                Column() {
                  DrumPaper({ fill: BLUE, paperWidth: 'auto', cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                    offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                    Text('已应用')
                      .fontSize(10).fontWeight(900).fontColor(INK).backgroundColor(BLUE)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .border({ width: 1, color: INK }).borderRadius(DRUM_CONTROL_RADIUS)
                  }
                }.rotate({ angle: 2 }).clip(false)
              }.width('100%')
              if (this.leader) {
                Text(this.drumAccessLabel()).fontSize(11).fontWeight(FontWeight.Bold)
                  .fontColor('#61566F').width('100%')
                  .onClick(() => this.showProDrumAccessToast())
              }
              Row({ space: DRUM_CARD_CONTENT_GAP }) {
                DrumPaper({ fill: WHITE, paperWidth: DRUM_ARRANGEMENT_ICON_SIZE, cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                  offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                  Stack() {
                    Column({ space: 5 }) {
                      Rect().width(29).height(5).radius(2.5).fill(INK)
                      Rect().width(21).height(5).radius(2.5).fill(INK)
                      Rect().width(29).height(5).radius(2.5).fill(INK)
                    }
                  }
                  .width(DRUM_ARRANGEMENT_ICON_SIZE).height(DRUM_ARRANGEMENT_ICON_SIZE)
                  .backgroundColor(WHITE).border({ width: 1.5, color: INK })
                  .borderRadius(DRUM_CONTROL_RADIUS)
                  .id('lobby-drum-arrangement-icon')
                  .accessibilityText('本编排')
                }
                Column({ space: 6 }) {
                  Text(this.activeDrumProgramName()).fontSize(12).fontWeight(900).fontColor('#61566F').width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: DRUM_STYLE_CHIP_GAP }) {
                    ForEach(this.activeDrumVisibleStyleKeys(), (key: string) => {
                      DrumPaper({ fill: styleByKey(key).color, paperWidth: 'auto', cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                        offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                        Text(styleByKey(key).name)
                          .fontSize(14).fontWeight(900).fontColor(INK)
                          .height(DRUM_STYLE_CHIP_HEIGHT)
                          .padding({ left: 8, right: 8 })
                          .backgroundColor(styleByKey(key).color)
                          .border({ width: 1, color: INK }).borderRadius(DRUM_CONTROL_RADIUS)
                          .maxLines(1)
                      }
                    }, (key: string) => key)
                    if (this.activeDrumStyleKeys().length > 2) {
                      Text('…').fontSize(20).fontWeight(900).fontColor(INK)
                        .accessibilityText('更多风格')
                    }
                  }.width('100%').alignItems(VerticalAlign.Center).id('lobby-drum-style-summary')
                  Row({ space: 6 }) {
                    EditableMeter({
                      solidInk: true,
                      beats: this.beats,
                      unit: this.unit,
                      editable: this.leader && !this.loading,
                      controlWidth: 66,
                      controlHeight: 28,
                      valueFontSize: 14,
                      controlCornerRadius: DRUM_CONTROL_RADIUS,
                      onEdit: (): void => { this.meterEditorVisible = true; }
                    })
                    DrumPaper({ fill: WHITE, paperWidth: 'auto', cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                      offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                      Row({ space: 4 }) {
                        Text('BPM').fontSize(11).fontWeight(900).fontColor('#61566F')
                        EditableBpm({
                          solidInk: true,
                          value: this.bpm,
                          editable: this.leader && !this.loading,
                          inputId: 'lobby-drum-bpm-input',
                          controlWidth: 42,
                          controlHeight: 26,
                          valueFontSize: 18,
                          controlCornerRadius: DRUM_CONTROL_RADIUS,
                          onCommit: (value: number): void => {
                            void AppSession.get()?.controller.updateBpm(value);
                          }
                        })
                      }.height(28).padding({ left: 7, right: 5 }).backgroundColor(WHITE)
                        .border({ width: 1, color: INK }).borderRadius(DRUM_CONTROL_RADIUS)
                    }
                  }.width('100%').alignItems(VerticalAlign.Center)
                }.layoutWeight(1)
              }.width('100%')
              Row({ space: 8 }) {
                DrumPaper({ fill: PAPER, paperWidth: 'auto', cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                  offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                  Text(`${this.activeDrumSectionCount()} 个段落`)
                    .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK })
                    .borderRadius(DRUM_CONTROL_RADIUS)
                }
                DrumPaper({ fill: PAPER, paperWidth: 'auto', cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                  offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                  Text(`${this.activeDrumBarCount()} 小节循环`)
                    .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                    .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK })
                    .borderRadius(DRUM_CONTROL_RADIUS)
                }
              }.width('100%')
              if (this.leader) {
                Row({ space: 9 }) {
                  Column() {
                    DrumPaper({ fill: LILAC, cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                      offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                      Button('编辑鼓机', { type: ButtonType.Normal })
                        .width('100%').height(46).fontSize(15).fontWeight(900).fontColor(INK)
                        .backgroundColor(LILAC).border({ width: 1.5, color: INK })
                        .borderRadius(DRUM_CONTROL_RADIUS)
                        .onClick(() => this.editDrumMachine())
                    }
                  }.layoutWeight(1).clip(false)
                  Column() {
                    DrumPaper({ fill: PAPER, cornerRadius: DRUM_CONTROL_RADIUS, paperLineWidth: 0,
                      offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET }) {
                      Button('切回节拍打点', { type: ButtonType.Normal })
                        .width('100%').height(46).fontSize(15).fontWeight(900).fontColor(INK)
                        .backgroundColor(PAPER).border({ width: 1.5, color: INK })
                        .borderRadius(DRUM_CONTROL_RADIUS)
                        .onClick(() => { void this.switchToBasicBeat(); })
                    }
                  }.layoutWeight(1.35).clip(false)
                }.width('100%')
              } else {
                Text('队长已启用定制鼓机，出发时会自动同步。').fontSize(11).fontColor('#5D574F').width('100%')
              }
            }
            .width('100%').padding(DRUM_CARD_PADDING).backgroundColor('#EDE6FF')
            .border({ width: 2, color: INK }).borderRadius(DRUM_CARD_RADIUS)
            .clip(false)
            .id('lobby-applied-drum-card')
          }
        } else if (this.leader) {
          this.proDrumMachineEntry()
        }
        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(12)
            .fontColor('#66615A')
            .width('100%')
            .onClick(() => {
              if (this.status.indexOf('Wi-Fi') >= 0) {
                const ctx = getContext(this) as common.UIAbilityContext;
                void openWirelessSettings(ctx);
              }
            })
        }
        if (this.btAudioActive) {
          if (this.soloTeam) {
            this.soloLatencyCalibrationEntry()
          } else {
            this.latencyCalibrationEntry()
          }
        }
        ComicButton({
          label: this.primaryLobbyLabel(),
          fill: this.primaryLobbyFill(),
          active: this.primaryLobbyActive(),
          hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
          action: () => { void this.handlePrimaryLobbyAction(); }
        })
        }.padding({
          left: 18,
          right: 18,
          top: 12 + this.topSafeInset,
          bottom: 28 + this.bottomSafeInset
        }).width('100%')
      }.height('100%').width('100%').backgroundColor(PAPER)
        // Before long-press, swipes still scroll normally. Once sorting owns
        // the touch, neither Scroll may compete with the avatar's Pan gesture.
        .enableScrollInteraction(this.rosterDragMemberId.length === 0)
      if (this.rhythmDropdownOpen) {
        this.rhythmDropdownOverlay()
      }
      if (this.meterEditorVisible) {
        MeterEditorOverlay({
          solidInk: true,
          initialBeats: this.beats,
          initialUnit: this.unit,
          onChange: (beats: number, unit: number): void => { void this.applyMeter(beats, unit); },
          onDismiss: (): void => { this.meterEditorVisible = false; }
        })
      }
      if (this.bluetoothRouteConfirmVisible) {
        this.bluetoothRouteConfirmationOverlay()
      }
    }.height('100%').width('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
