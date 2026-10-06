import { common } from '@kit.AbilityKit';
import { access } from '@kit.ConnectivityKit';
import { router, promptAction } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { SessionController } from '../session/SessionController';
import { SessionMember } from '../protocol/messages';
import { RandomCharacterFilm, RANDOM_FILM_HEIGHT } from '../components/RandomCharacterFilm';
import { EditableBpm } from '../components/EditableBpm';
import { EditableMeter, MeterEditorOverlay } from '../components/EditableMeter';
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
  BLUE,
  CARD_SHADOW,
  CONTROL_SHADOW,
  INK_SHADOW_RADIUS
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
import { DrumProgram, parseDrumProgram, styleByKey } from '../audio/DrumMachineCatalog';
import {
  isProDrumMachineAccessible,
  isSceneAccessible,
  limitedFreeCharacterKeys
} from '../store/EntitlementStore';
import { refreshStoreEntitlementsNow } from '../store/StoreBootstrapSync';
import { SESSION_MAX_MEMBER_COUNT } from '../common/Constants';

interface LobbySceneOption {
  key: string;
  name: string;
  caption: string;
}

const LOBBY_SCENES: LobbySceneOption[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海浪、云层与土路' },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜街区与霓虹灯' }
];

const PRO_DRUM_BUTTON_HEIGHT: number = 56;
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
const ROSTER_READY_BADGE_WIDTH: number = 50;
const ROSTER_READY_BADGE_HEIGHT: number = 16;
const ROSTER_READY_BADGE_POINTER_SIZE: number = 6;
/** 给头像上方的准备气泡预留空间；增大则整排头像下移。 */
const ROSTER_ROW_TOP_PADDING: number = 15;
/** 相对头像顶边的位置；减小会把准备气泡继续上移。 */
const ROSTER_READY_BADGE_TOP: number = -13;

@Entry
@Component
struct LeaderLobbyPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'sunset_coast';
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
  private rhythms: string[] = ['均匀节拍', '双分节拍', '仅小节重音'];
  private enteringStage: boolean = false;
  private refreshingConnectivity: boolean = false;
  private readonly rosterScroller: Scroller = new Scroller();
  private randomSelectionToken: number = 0;
  private randomPreviewPreviousDrawId: number = 0;
  // Retain dismissal even if the authoritative result arrives after active changes.
  private readonly interruptedRandomPreviews: Map<string, number> = new Map();
  private readonly bluetoothStateListener = (_state: access.BluetoothState): void => {
    void this.refreshLeaderConnectivity();
  };

  aboutToAppear(): void {
    try {
      access.on('stateChange', this.bluetoothStateListener);
    } catch (_e) {
    }
    void this.initialize();
  }
  aboutToDisappear(): void {
    this.randomSelectionToken += 1;
    this.randomPreviewPageVisible = false;
    this.randomPreviewPendingMemberId = '';
    this.interruptedRandomPreviews.clear();
    try {
      access.off('stateChange', this.bluetoothStateListener);
    } catch (_e) {
    }
  }
  onBackPress(): boolean {
    if (this.meterEditorVisible) {
      this.meterEditorVisible = false;
      return true;
    }
    void this.leaveLobby();
    return true;
  }
  onPageShow(): void {
    this.randomPreviewPageVisible = true;
    this.enteringStage = false;
    void this.refreshLeaderConnectivity();
  }
  onPageHide(): void {
    this.randomSelectionToken += 1;
    this.randomPreviewPageVisible = false;
    this.randomPreviewPendingMemberId = '';
  }

  private async refreshLeaderConnectivity(): Promise<void> {
    if (this.refreshingConnectivity) {
      return;
    }
    this.refreshingConnectivity = true;
    try {
      await AppSession.get()?.refreshLeaderP2pGroup();
      this.refresh();
      this.updateRoomStatus();
    } catch (err) {
      this.refresh();
      this.status = (err as Error).message;
    } finally {
      this.refreshingConnectivity = false;
    }
  }

  private onStoreEntitlementsChanged(): void {
    this.refresh();
  }

  private async initialize(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
      await refreshStoreEntitlementsNow();
      const params = router.getParams() as Record<string, string>;
      if (params?.['reuse'] !== '1') {
        await AppSession.reset();
        const name = params?.['displayName'] || 'Player';
        const session = AppSession.createLeader(name);
        if (params?.['solo'] === '1') {
          await session.leaderBootstrapSolo(name);
        } else {
          const ctx = getContext(this) as common.UIAbilityContext;
          const granted = await ensureTeamNetworkPermissions(ctx);
          if (!granted) {
            throw new Error(teamNetworkPermissionDeniedHint());
          }
          if (!(await verifyTeamNetworkAccess())) {
            throw new Error(teamNetworkAccessUnavailableHint());
          }
          await ensureBluetoothDiscoveryPermission(ctx);
          await session.leaderBootstrap(name);
        }
      }
      this.refresh();
      this.soloTeam = AppSession.get()?.controller.soloTeam ?? false;
      this.updateRoomStatus();
      if (!this.failed && !this.soloTeam && this.leader && this.qr.length > 0) {
        this.invite = true;
      }
    } catch (e) {
      this.failed = true;
      this.status = (e as Error).message;
    } finally { this.loading = false; }
  }

  private updateRoomStatus(): void {
    const controller = AppSession.get()?.controller;
    if (controller === undefined) {
      return;
    }
    this.status = controller.soloTeam
      ? '单人练习 · 可增减人机队友'
      : (controller.bleInviteAvailable
        ? 'P2P 队伍已创建 · 可扫码或输入加入码'
        : 'P2P 队伍已创建 · 可扫码加入；打开蓝牙并返回即可恢复当前加入码');
  }

  private async leaveLobby(): Promise<void> {
    if (this.leavingLobby || this.enteringStage) {
      return;
    }
    this.leavingLobby = true;
    this.status = '正在退出队伍…';
    try {
      await AppSession.reset();
      router.back();
    } catch (_e) {
      this.leavingLobby = false;
      promptAction.showToast({ message: '退出队伍失败，请重试' });
    }
  }

  refresh(): void {
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
    try {
      await AppSession.get()?.controller.updateMeter(beats, unit);
      this.refresh();
    } catch (_e) {
      promptAction.showToast({ message: '拍号修改失败，请重试' });
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
    } catch (_e) {
      if (this.randomPreviewPageVisible && this.members.some((member: SessionMember) =>
        member.id === memberId && member.randomDrawId === drawId)) {
        promptAction.showToast({ message: '随机头像同步失败，请重试' });
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

  private pickOpacity(state: CharacterPickState): number {
    if (state === 'selectable') {
      return 1;
    }
    if (state === 'taken' || state === 'lockedByReady') {
      return 0.42;
    }
    return 0.28;
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
    } catch (_e) {
      if (token === this.randomSelectionToken && this.randomPreviewPageVisible) {
        this.randomPreviewPendingMemberId = '';
        promptAction.showToast({ message: '角色同步失败，请重试' });
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
    if (this.loading) {
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
    if (this.loading) {
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
    if (c.isLocalLobbyReady()) {
      await c.setLobbyReady(false);
    } else {
      await c.setLobbyReady(true);
    }
    this.refresh();
  }

  private async leaderDepartToWalk(): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined || !c.canLeaderStartWalk()) {
      return;
    }
    try {
      await c.departLobbyToWalk();
      await this.enterStage();
    } catch (_e) {
      promptAction.showToast({ message: '出发同步失败，请重试' });
    }
  }

  private async chooseScene(key: string): Promise<void> {
    if (!this.leader || this.loading || key === this.selectedSceneKey) { return; }
    if (!isSceneAccessible(key)) {
      promptAction.showToast({ message: '请先在收藏小铺解锁这个场景' });
      return;
    }
    try {
      await AppSession.get()?.controller.updateSceneKey(key);
      this.refresh();
    } catch (_e) {
      promptAction.showToast({ message: '场景同步失败，请重试' });
    }
  }

  private activeDrumProgram(): DrumProgram {
    return parseDrumProgram(this.drumProgram);
  }

  private activeDrumStyleName(): string {
    return styleByKey(this.activeDrumProgram().styleKey).name;
  }

  private activeDrumStyleCaption(): string {
    return styleByKey(this.activeDrumProgram().styleKey).caption;
  }

  private activeDrumStyleColor(): string {
    return styleByKey(this.activeDrumProgram().styleKey).color;
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
      promptAction.showToast({ message: 'PRO 定制鼓机包含在畅游月卡中' });
      return;
    }
    router.pushUrl({ url: 'pages/DrumMachinePage' });
  }

  private async switchToBasicBeat(): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader) {
      return;
    }
    const stored = AppStorage.get<number>('lastBasicRhythm') ?? 0;
    const next = stored >= 0 && stored <= 2 ? stored : 0;
    await controller.updateRhythm(next);
    this.refresh();
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
    await AppSession.get()?.controller.updateRhythm(index);
    this.refresh();
  }

  private async enterStage(): Promise<void> {
    if (this.enteringStage) {
      return;
    }
    this.enteringStage = true;
    try {
      await router.pushUrl({ url: 'pages/MainPage' });
    } catch (_e) {
      this.enteringStage = false;
      promptAction.showToast({ message: '进入行进页失败，请重试' });
    }
  }

  private canAddSoloBotSlot(): boolean {
    return this.members.length < SESSION_MAX_MEMBER_COUNT &&
      (AppSession.get()?.controller.canAddSoloBot() ?? false);
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
    try {
      const newBotId = await c.addSoloBotWithNextAvatar();
      this.refresh();
      if (newBotId !== undefined && newBotId.length > 0) {
        this.selectEditingMember(newBotId);
      }
    } catch (_e) {
      promptAction.showToast({ message: '添加人机失败' });
    }
  }

  private async removeSoloBotSlot(id: string): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined) {
      return;
    }
    try {
      await c.removeSoloBotById(id);
      this.refresh();
    } catch (_e) {
      promptAction.showToast({ message: '移除人机失败' });
    }
  }

  @Builder
  private rosterReadyBadge() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Text('✓ 已准备')
          .fontSize(9)
          .fontWeight(900)
          .fontColor(INK)
      }
      .width(ROSTER_READY_BADGE_WIDTH)
      .height(ROSTER_READY_BADGE_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(TEAL)
      .border({ width: 1, color: INK })
      .borderRadius(8)
      .shadow({ radius: 1, offsetX: 1, offsetY: 1, color: INK })
      .zIndex(2)
      Row()
        .width(ROSTER_READY_BADGE_POINTER_SIZE)
        .height(ROSTER_READY_BADGE_POINTER_SIZE)
        .backgroundColor(TEAL)
        .border({ width: 1, color: INK })
        .rotate({ angle: 45 })
        .position({
          x: (ROSTER_READY_BADGE_WIDTH - ROSTER_READY_BADGE_POINTER_SIZE) / 2,
          y: ROSTER_READY_BADGE_HEIGHT - ROSTER_READY_BADGE_POINTER_SIZE / 2
        })
        .zIndex(1)
    }
    .width(ROSTER_READY_BADGE_WIDTH)
    .height(ROSTER_READY_BADGE_HEIGHT + ROSTER_READY_BADGE_POINTER_SIZE)
    .position({
      x: (ROSTER_AVATAR_SIZE - ROSTER_READY_BADGE_WIDTH) / 2,
      y: ROSTER_READY_BADGE_TOP
    })
    .clip(false)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private rosterMemberSlot(member: SessionMember) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        ComicCharacter({
          avatar: member.avatarKey,
          portrait: true,
          mysteryAvatar: this.revealedMemberMysteryAvatar(member)
        }).width(ROSTER_AVATAR_SIZE).height(ROSTER_AVATAR_SIZE)
          .border({
            width: this.editingMemberId === member.id ? 2 : 0,
            color: INK
          })
          .borderRadius(4)
          .clip(true)
          .opacity(this.canEditMember(member.id) ? 1 : 0.88)
          .onClick(() => { this.selectEditingMember(member.id); })
        if (member.lobbyReady === true) {
          this.rosterReadyBadge()
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
      Text(member.displayName).fontSize(10).maxLines(1).width(58).textAlign(TextAlign.Center)
    }
    .width(58)
    .alignItems(HorizontalAlign.Center)
    .clip(false)
  }

  @Builder
  private rosterAddSlot() {
    Column({ space: 2 }) {
      Stack() {
        Text('+').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.canAddSoloBotSlot() ? INK : '#9A948C')
      }
      .width(43)
      .height(43)
      .border({ width: 1.5, color: INK })
      .borderRadius(4)
      .backgroundColor(PAPER)
      .shadow(CONTROL_SHADOW)
      .opacity(this.canAddSoloBotSlot() ? 1 : 0.42)
      .enabled(this.canAddSoloBotSlot())
      .hitTestBehavior(this.canAddSoloBotSlot() ? HitTestMode.Default : HitTestMode.None)
      .onClick(() => { void this.addSoloBotSlot(); })
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
      // An opaque offset layer gives the frame a hard ink shadow even when the
      // portrait is transparent or dimmed. Only the artwork follows pick opacity.
      Row().width(CHARACTER_PICK_AVATAR_SIZE).height(CHARACTER_PICK_AVATAR_SIZE)
        .backgroundColor(INK).borderRadius(CHARACTER_PICK_CORNER_RADIUS)
        .position({ x: CHARACTER_PICK_SHADOW_OFFSET, y: CHARACTER_PICK_AVATAR_TOP + CHARACTER_PICK_SHADOW_OFFSET })
      Stack() {
        ComicCharacter({ avatar: key, portrait: true })
          .width('100%').height('100%')
          .opacity(this.pickOpacity(this.pickStateForKey(key)))
      }
        .width(CHARACTER_PICK_AVATAR_SIZE)
        .height(CHARACTER_PICK_AVATAR_SIZE)
        .backgroundColor((this.showingRandomMystery() ? 'random' : this.editingAvatarKey()) === key ? LILAC : PAPER)
        .border({ width: 1.5, color: INK })
        // Clip the portrait itself to the frame corners; badges and the ink
        // shadow remain sibling layers so their overhang is never cropped.
        .borderRadius(CHARACTER_PICK_CORNER_RADIUS).clip(true)
        .position({ x: 0, y: CHARACTER_PICK_AVATAR_TOP })
      this.characterBadges(key)
    }
    .width(59)
    .height(54)
    .clip(false)
    .onClick(() => { void this.pickCharacter(key); })
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
      Row()
        .width('100%').height(PRO_DRUM_BUTTON_HEIGHT).backgroundColor(LILAC)
        .border({ width: 1.5, color: INK }).borderRadius(7)
        .shadow(CARD_SHADOW).opacity(locked ? 0.68 : 1)
        .align(Alignment.Top).translate({ y: PRO_DRUM_ENTRY_PADDING })
      this.proChain(asset)
      // Keep the title above the decorative chain so narrow-screen labels stay readable.
      Row() {
        Text('PRO 定制鼓机').fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Blank()
        Text('›').fontSize(30).fontColor(INK)
      }
      .width('100%').height(PRO_DRUM_BUTTON_HEIGHT).padding({ left: 16, right: 14 })
      .opacity(locked ? 0.68 : 1)
      .align(Alignment.Top).translate({ y: PRO_DRUM_ENTRY_PADDING })
      .onClick(() => this.editDrumMachine())
    }
    // Intentionally paint the hanging tail above later controls without adding
    // layout space; the decorative image must still let their taps through.
    .width('100%').height(PRO_DRUM_BUTTON_HEIGHT + PRO_DRUM_ENTRY_PADDING * 2).clip(false).zIndex(1)
  }

  @Builder
  private proDrumMachineEntry() {
    if (isProDrumMachineAccessible()) {
      this.proDrumMachineEntryWithChain('comic/decor/pro-chain-anchored.png', false)
    } else {
      this.proDrumMachineEntryWithChain('comic/decor/pro-chain-locked.png', true)
    }
  }

  @Builder
  private scenePreview(key: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (key === 'sunset_coast') {
        Image($rawfile('background/sunset_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
        Image($rawfile('background/sunset_sun.png')).width(54).height(54).objectFit(ImageFit.Contain)
          .position({ x: '60%', y: 4 })
        Image($rawfile('background/sunset_clouds.png')).width('150%').height(48).objectFit(ImageFit.Fill)
          .position({ x: -18, y: 4 })
        Image($rawfile('background/ocean.png')).width('100%').height(36).objectFit(ImageFit.Fill)
          .position({ x: 0, y: 46 })
        Image($rawfile('background/midground_dirt.png')).width('100%').height(34).objectFit(ImageFit.Fill)
          .position({ x: 0, y: 70 })
      } else {
        Image($rawfile('scenes/neon/neon_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
        Image($rawfile('scenes/neon/neon_far_skyline.png')).width('118%').height(68).objectFit(ImageFit.Fill)
          .position({ x: -12, y: 8 })
        Image($rawfile('scenes/neon/neon_street_blocks.png')).width('130%').height(72).objectFit(ImageFit.Fill)
          .position({ x: -18, y: 31 })
      }
    }.width('100%').height(96).clip(true)
  }

  @Builder
  private sceneCard(item: LobbySceneOption) {
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
          Text('✓ 已选择').fontSize(10).fontWeight(900).fontColor(PAPER)
            .backgroundColor(CORAL).padding({ left: 7, right: 7, top: 4, bottom: 4 }).borderRadius(4).shadow(CONTROL_SHADOW)
        }.width('100%').padding({ top: 6, right: 6 }).hitTestBehavior(HitTestMode.None)
      }
    }
    .width(154).height(148)
    .backgroundColor('#FFFDF7')
    .border({ width: this.selectedSceneKey === item.key ? 3 : 1, color: INK })
    .borderRadius(7).shadow(CARD_SHADOW)
    .opacity(this.leader && isSceneAccessible(item.key) ? 1 : 0.55)
    .onClick(() => { void this.chooseScene(item.key); })
  }

  @Builder
  private rhythmDropdownPanel() {
    Column({ space: 3 }) {
      ForEach(this.rhythms, (name: string, index: number) => {
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
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
        .onClick(() => { void this.chooseBasicRhythm(index); })
      })
    }
    .width(this.rhythmDropdownWidth)
    .padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER)
    .border({ width: 1.5, color: INK })
    .borderRadius(6)
    .shadow(CARD_SHADOW)
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

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
        Row() {
          Text('‹').fontSize(32).width(32).onClick(() => { void this.leaveLobby(); })
          Text('队伍大厅').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
          Blank()
          Text(this.leader ? '队长' : '队员').fontSize(12).backgroundColor(LILAC).padding(7).borderRadius(4).shadow(CONTROL_SHADOW)
        }.width('100%')
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
          Scroll(this.rosterScroller) {
            Row({ space: 10 }) {
              ForEach(this.members, (m: SessionMember) => {
                this.rosterMemberSlot(m)
              }, (m: SessionMember) => `${m.id}-${m.avatarKey}-${m.randomDrawId ?? 0}-` +
                `${this.revealedMemberMysteryAvatar(m)}-${m.lobbyReady === true ? 1 : 0}`)
              if (this.soloTeam && this.leader) {
                this.rosterAddSlot()
              }
            }
            .padding({ top: ROSTER_ROW_TOP_PADDING, bottom: 2 })
            .onAreaChange(() => { this.keepRosterAddSlotVisible(); })
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .clip(false)
          .onAreaChange(() => { this.keepRosterAddSlotVisible(); })
          if (this.invite && this.qr.length > 0) {
            QRCode(this.qr).width(150).height(150).backgroundColor(Color.White)
            Text(`加入码  ${AppSession.get()?.controller.joinCode ?? '------'}`)
              .fontSize(28)
              .fontWeight(900)
              .fontStyle(FontStyle.Italic)
              .letterSpacing(4)
            Text(AppSession.get()?.controller.bleInviteAvailable === true
              ? '队员可扫码，或打开蓝牙后输入 6 位加入码'
              : '队员仍可扫码；打开队长蓝牙并返回本页后，当前加入码会自动恢复')
              .fontSize(12)
              .fontColor('#66615A')
            Row() {
              Blank()
              Text('收起邀请信息 ›')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .onClick(() => { this.invite = false; })
            }.width('100%')
          }
        }.padding(12).width('100%').backgroundColor(WHITE)
          .border({ width: 1, color: INK }).borderRadius(7).shadow(CARD_SHADOW).clip(false)
        Text('角色选择').width('100%').fontWeight(FontWeight.Bold).fontSize(17)
        Text(this.soloTeam && this.leader ? '点队伍槽位切换编辑对象' : '仅可更换自己的角色')
          .fontSize(11).fontColor('#66615A').width('100%')
        if (this.showingRandomMystery()) {
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
        .clip(false)
        if (this.leader) {
          Column({ space: 9 }) {
            Row() {
              Text('行进场景').fontSize(18).fontWeight(900)
              Blank()
              Text('点击选择 · 可左右滑动')
                .fontSize(10).fontWeight(FontWeight.Bold).fontColor('#66615A')
            }.width('100%')
            Scroll() {
              Row({ space: 10 }) {
                ForEach(LOBBY_SCENES, (item: LobbySceneOption) => {
                  this.sceneCard(item)
                }, (item: LobbySceneOption) => item.key)
              }.padding({ bottom: 2 })
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').height(151)
            Text('出发后全队进入同一场景')
              .fontSize(11).fontColor('#66615A').width('100%')
          }.width('100%').padding(12).backgroundColor(WHITE)
            .border({ width: 1, color: INK }).borderRadius(7).shadow(CARD_SHADOW)
        }
        if (this.leader && this.rhythm !== 3) {
          Column({ space: 13 }) {
            Text('队长设置').fontSize(18).fontWeight(900).width('100%')
            Row() {
              Text('节奏型').fontSize(14).width(68)
              Button({ type: ButtonType.Normal }) {
                Row() {
                  Text(this.rhythms[this.rhythm]).fontSize(13).fontWeight(FontWeight.Bold)
                  Blank()
                  Text(this.rhythmDropdownOpen ? '⌃' : '⌄').fontSize(15)
                }.width('100%')
              }
              .id('lobby-rhythm-select')
              .layoutWeight(1)
              .height(34)
              .padding({ left: 8, right: 7 })
              .fontColor(INK)
              .backgroundColor(PAPER)
              .border({ width: 1, color: INK })
              .borderRadius(5).shadow(CONTROL_SHADOW)
              .enabled(this.leader && !this.loading)
              .onClick(() => this.openRhythmDropdown())
            }.width('100%')
            Row({ space: 8 }) {
              Text('拍号').fontSize(14).width(60)
              EditableMeter({
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
              Button('−').backgroundColor(PAPER).fontColor(INK).border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
                .enabled(this.leader && this.bpm > 40).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm - 1); })
              EditableBpm({
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
              Button('+').backgroundColor(PAPER).fontColor(INK).border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
                .enabled(this.leader && this.bpm < 240).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm + 1); })
            }.width('100%')
            Text(`每分钟 ${this.bpm} 个${beatUnitLabel(this.unit)}音符拍点`).fontSize(11).fontColor('#66615A').width('100%')
          }.width('100%').padding(12).backgroundColor(WHITE)
            .border({ width: 1, color: INK }).borderRadius(7).shadow(CARD_SHADOW)
        }
        if (this.rhythm === 3 && this.drumProgram.length > 0) {
          Column({ space: 12 }) {
            Row() {
              Text('PRO 定制鼓机').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
              Blank()
              Text('已应用')
                .fontSize(10).fontWeight(900).fontColor(INK).backgroundColor(BLUE)
                .shadow(CONTROL_SHADOW)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .border({ width: 1, color: INK }).borderRadius(3).rotate({ angle: 2 })
            }.width('100%')
            Row({ space: 12 }) {
              Stack() {
                Circle().width(68).height(68).fill(this.activeDrumStyleColor()).stroke(INK).strokeWidth(2)
                Text('♪').fontSize(34).fontWeight(900).fontColor(INK)
              }.width(72).height(72)
              Column({ space: 3 }) {
                Text(this.activeDrumStyleName()).fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
                Text(this.activeDrumStyleCaption()).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#5D574F').width('100%')
                Row({ space: 4 }) {
                  EditableMeter({
                    beats: this.beats,
                    unit: this.unit,
                    editable: this.leader && !this.loading,
                    controlWidth: 66,
                    controlHeight: 28,
                    valueFontSize: 14,
                    onEdit: (): void => { this.meterEditorVisible = true; }
                  })
                  EditableBpm({
                    value: this.bpm,
                    editable: this.leader && !this.loading,
                    inputId: 'lobby-drum-bpm-input',
                    controlWidth: 55,
                    controlHeight: 26,
                    valueFontSize: 18,
                    onCommit: (value: number): void => {
                      void AppSession.get()?.controller.updateBpm(value);
                    }
                  })
                  Text('BPM').fontSize(13).fontWeight(900)
                }.width('100%').alignItems(VerticalAlign.Center)
              }.layoutWeight(1)
            }.width('100%')
            Row({ space: 8 }) {
              Text(`${this.activeDrumSectionCount()} 个段落`)
                .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
              Text(`${this.activeDrumBarCount()} 小节循环`)
                .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
            }.width('100%')
            if (this.leader) {
              Row({ space: 9 }) {
                Button('编辑鼓机', { type: ButtonType.Normal })
                  .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
                  .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
                  .onClick(() => this.editDrumMachine())
                Button('切回节拍打点', { type: ButtonType.Normal })
                  .layoutWeight(1.35).height(46).fontSize(15).fontWeight(900).fontColor(INK)
                  .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
                  .onClick(() => { void this.switchToBasicBeat(); })
              }.width('100%')
            } else {
              Text('队长已启用定制鼓机，出发时会自动同步。').fontSize(11).fontColor('#5D574F').width('100%')
            }
          }
          .width('100%').padding(14).backgroundColor('#EDE6FF')
          .border({ width: 2, color: INK }).borderRadius(8)
          .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 4, color: INK })
        } else if (this.leader) {
          this.proDrumMachineEntry()
        }
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
        ComicButton({
          label: this.primaryLobbyLabel(),
          fill: this.primaryLobbyFill(),
          active: this.primaryLobbyActive(),
          action: () => { void this.handlePrimaryLobbyAction(); }
        })
        }.padding({
          left: 18,
          right: 18,
          top: 12 + this.topSafeInset,
          bottom: 28 + this.bottomSafeInset
        }).width('100%')
      }.height('100%').width('100%').backgroundColor(PAPER)
      if (this.rhythmDropdownOpen) {
        this.rhythmDropdownOverlay()
      }
      if (this.meterEditorVisible) {
        MeterEditorOverlay({
          initialBeats: this.beats,
          initialUnit: this.unit,
          onChange: (beats: number, unit: number): void => { void this.applyMeter(beats, unit); },
          onDismiss: (): void => { this.meterEditorVisible = false; }
        })
      }
    }.height('100%').width('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
