import { common } from '@kit.AbilityKit';
import { access } from '@kit.ConnectivityKit';
import { router, promptAction } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { SessionController } from '../session/SessionController';
import { SessionMember } from '../protocol/messages';
import {
  avatarDisplayName,
  ComicButton,
  ComicCharacter,
  PAPER,
  INK,
  CORAL,
  LILAC,
  TEAL
} from '../components/ComicKit';
import {
  CharacterPickState,
  characterPickState,
  isCharacterOwned,
  isDuplicatableAvatar,
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

interface LobbySceneOption {
  key: string;
  name: string;
  caption: string;
}

const LOBBY_SCENES: LobbySceneOption[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海浪、云层与土路' },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜街区与霓虹灯' }
];

@Entry
@Component
struct LeaderLobbyPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'neon_street';
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
  @State rhythmDropdownX: number = 0;
  @State rhythmDropdownY: number = 0;
  @State rhythmDropdownWidth: number = 200;
  @State leavingLobby: boolean = false;
  private rhythms: string[] = ['均匀节拍', '双分节拍', '仅小节重音'];
  private enteringStage: boolean = false;
  private refreshingConnectivity: boolean = false;
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
    try {
      access.off('stateChange', this.bluetoothStateListener);
    } catch (_e) {
    }
  }
  onBackPress(): boolean {
    void this.leaveLobby();
    return true;
  }
  onPageShow(): void {
    this.enteringStage = false;
    void this.refreshLeaderConnectivity();
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

  private async initialize(): Promise<void> {
    this.loading = true;
    this.failed = false;
    try {
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
    if (c.soloTeam && c.isLeader) {
      c.reconcileSoloLegacyBots();
      this.members = c.getMembers();
    }
    this.localReady = c.isLocalLobbyReady();
    this.leaderCanDepart = c.canLeaderStartWalk();
    this.ensureEditingMember();
    if (!this.soloTeam && !this.leader && c.lobbyDeparted) {
      void this.enterStage();
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
    return 'matchman';
  }

  private pickStateForKey(key: string): CharacterPickState {
    return characterPickState(key, this.members, this.editingMemberId, this.soloTeam);
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
    try {
      await AppSession.get()?.controller.updateMemberAvatar(this.editingMemberId, key);
      this.refresh();
    } catch (_e) {
      promptAction.showToast({ message: '角色同步失败，请重试' });
    }
  }

  private selectEditingMember(memberId: string): void {
    if (!this.canEditMember(memberId)) {
      return;
    }
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
    return AppSession.get()?.controller.canAddSoloBot() ?? false;
  }

  private async addSoloBotSlot(): Promise<void> {
    const c = AppSession.get()?.controller;
    if (c === undefined || !this.canAddSoloBotSlot()) {
      return;
    }
    try {
      await c.addSoloBotWithNextAvatar();
      this.refresh();
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
  private rosterMemberSlot(member: SessionMember) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        ComicCharacter({ avatar: member.avatarKey, portrait: true }).width(43).height(43)
          .border({
            width: this.editingMemberId === member.id ? 2 : 0,
            color: INK
          })
          .borderRadius(4)
          .opacity(this.canEditMember(member.id) ? 1 : 0.88)
          .onClick(() => { this.selectEditingMember(member.id); })
        if (member.lobbyReady === true) {
          Text('备')
            .fontSize(9)
            .fontWeight(FontWeight.Bold)
            .fontColor(PAPER)
            .backgroundColor(TEAL)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .borderRadius(3)
            .margin({ top: 1, left: 1 })
            .hitTestBehavior(HitTestMode.None)
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
      .width(43)
      .height(43)
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
      .opacity(this.canAddSoloBotSlot() ? 1 : 0.42)
      .hitTestBehavior(this.canAddSoloBotSlot() ? HitTestMode.Default : HitTestMode.None)
      .onClick(() => { void this.addSoloBotSlot(); })
      Text(' ').fontSize(10).opacity(0)
    }.width(58)
  }

  @Builder
  private unownedLockGlyph() {
    Column({ space: 0 }) {
      Row()
        .width(6)
        .height(3)
        .border({ width: 1, color: INK })
        .borderRadius(3)
        .backgroundColor(PAPER)
      Row()
        .width(7)
        .height(5)
        .backgroundColor(INK)
        .borderRadius(1)
        .margin({ top: -1 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private duplicatePersonGlyph() {
    Column({ space: 1 }) {
      Circle().width(4).height(4).fill(INK)
      Row()
        .width(5)
        .height(6)
        .backgroundColor(INK)
        .borderRadius(2)
    }
    .width(8)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private characterPickCell(key: string) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      ComicCharacter({ avatar: key, portrait: true })
        .width(46)
        .height(46)
        .backgroundColor(this.editingAvatarKey() === key ? LILAC : PAPER)
        .border({ width: 1, color: INK })
        .borderRadius(6)
        .opacity(this.pickOpacity(this.pickStateForKey(key)))
        .onClick(() => { void this.pickCharacter(key); })
      if (!isCharacterOwned(key)) {
        Column() {
          this.unownedLockGlyph()
        }
        .padding({ left: 4, right: 4, top: 3, bottom: 3 })
        .backgroundColor(PAPER)
        .border({ width: 1, color: INK })
        .borderRadius(8)
        .margin({ right: 2, bottom: 2 })
        .hitTestBehavior(HitTestMode.None)
      } else if (isDuplicatableAvatar(key)) {
        Row({ space: -3 }) {
          this.duplicatePersonGlyph()
          this.duplicatePersonGlyph()
        }
        .padding({ left: 3, right: 3, top: 2, bottom: 2 })
        .backgroundColor(PAPER)
        .border({ width: 1, color: INK })
        .borderRadius(8)
        .margin({ right: 2, bottom: 2 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(52)
    .height(46)
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
            .backgroundColor(CORAL).padding({ left: 7, right: 7, top: 4, bottom: 4 }).borderRadius(4)
        }.width('100%').padding({ top: 6, right: 6 }).hitTestBehavior(HitTestMode.None)
      }
    }
    .width(154).height(148)
    .backgroundColor('#FFFDF7')
    .border({ width: this.selectedSceneKey === item.key ? 3 : 1, color: INK })
    .borderRadius(7).clip(true)
    .opacity(this.leader ? 1 : 0.9)
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
        .border({ width: 1, color: INK }).borderRadius(4)
        .onClick(() => { void this.chooseBasicRhythm(index); })
      })
    }
    .width(this.rhythmDropdownWidth)
    .padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER)
    .border({ width: 1.5, color: INK })
    .borderRadius(6)
    .clip(true)
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
          Text(this.leader ? '队长' : '队员').fontSize(12).backgroundColor(LILAC).padding(7).borderRadius(4)
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
          Scroll() {
            Row({ space: 10 }) {
              ForEach(this.members, (m: SessionMember) => {
                this.rosterMemberSlot(m)
              }, (m: SessionMember) => `${m.id}-${m.avatarKey}`)
              if (this.soloTeam && this.leader) {
                this.rosterAddSlot()
              }
            }
            .padding({ top: 2, bottom: 2 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .clip(false)
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
        }.padding(12).width('100%').border({ width: 1, color: INK }).borderRadius(7).clip(false)
        Text('角色选择').width('100%').fontWeight(FontWeight.Bold).fontSize(17)
        Text(this.soloTeam && this.leader ? '点队伍槽位切换编辑对象' : '仅可更换自己的角色')
          .fontSize(11).fontColor('#66615A').width('100%')
        Stack() {
          Image($rawfile('comic/decor/character_panel.png')).width('100%').height('100%').objectFit(ImageFit.Fill)
          ComicCharacter({ avatar: this.editingAvatarKey() }).width('82%').height(248)
          Text('JUST KEEP\nTHE BEAT.').fontWeight(900).fontStyle(FontStyle.Italic).fontSize(14)
            .position({ x: '72%', y: 12 })
        }.height(250).width('100%').clip(true)
        Row({ space: 8 }) {
          Text(avatarDisplayName(this.editingAvatarKey())).fontSize(15).fontWeight(FontWeight.Bold)
          if (this.pickStateForKey(this.editingAvatarKey()) === 'selfReadyLocked') {
            Text('已准备 · 不可换角').fontSize(11).fontColor('#66615A')
          }
        }.width('100%')
        Scroll() {
          Row({ space: 10 }) {
            ForEach(sortRosterKeysForPicker(rosterKeysForLobby(this.soloTeam)), (key: string) => {
              this.characterPickCell(key)
            }, (key: string) => key)
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
          }.width('100%').padding(12).border({ width: 1, color: INK }).borderRadius(7)
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
              .borderRadius(5)
              .enabled(this.leader && !this.loading)
              .onClick(() => this.openRhythmDropdown())
            }.width('100%')
            Row({ space: 8 }) {
              Text('拍号').fontSize(14).width(60)
              ForEach([4, 3, 6], (n: number) => {
                Button(`${n}/${n === 6 ? 8 : 4}`, { type: ButtonType.Normal }).layoutWeight(1).height(35)
                  .fontColor(INK).backgroundColor(this.beats === n ? CORAL : PAPER).borderRadius(4).border({ width: 1, color: INK })
                  .enabled(this.leader && !this.loading).onClick(() => { void AppSession.get()?.controller.updateMeter(n, n === 6 ? 8 : 4); })
              })
            }.width('100%')
            Row({ space: 12 }) {
              Text('BPM').width(56).fontWeight(FontWeight.Bold)
              Button('−').backgroundColor(PAPER).fontColor(INK).border({ width: 1, color: INK }).borderRadius(4)
                .enabled(this.leader && this.bpm > 40).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm - 1); })
              Text(`${this.bpm}`).fontSize(40).fontWeight(900).fontStyle(FontStyle.Italic).layoutWeight(1).textAlign(TextAlign.Center)
              Button('+').backgroundColor(PAPER).fontColor(INK).border({ width: 1, color: INK }).borderRadius(4)
                .enabled(this.leader && this.bpm < 240).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm + 1); })
            }.width('100%')
            Text(`每分钟 ${this.bpm} 个${this.unit === 8 ? '八分' : '四分'}音符拍点`).fontSize(11).fontColor('#66615A').width('100%')
          }.width('100%').padding(12).border({ width: 1, color: INK }).borderRadius(7)
        }
        if (this.rhythm === 3 && this.drumProgram.length > 0) {
          Column({ space: 12 }) {
            Row() {
              Text('PRO 定制鼓机').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
              Blank()
              Text('已应用')
                .fontSize(10).fontWeight(900).fontColor(PAPER).backgroundColor(TEAL)
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
                Text(`${this.beats}/${this.unit} · ${this.bpm} BPM`).fontSize(13).fontWeight(900).width('100%')
              }.layoutWeight(1)
            }.width('100%')
            Row({ space: 8 }) {
              Text(`${this.activeDrumSectionCount()} 个段落`)
                .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK }).borderRadius(4)
              Text(`${this.activeDrumBarCount()} 小节循环`)
                .fontSize(12).fontWeight(900).backgroundColor(PAPER)
                .padding({ left: 9, right: 9, top: 5, bottom: 5 }).border({ width: 1, color: INK }).borderRadius(4)
            }.width('100%')
            if (this.leader) {
              Row({ space: 9 }) {
                Button('编辑鼓机', { type: ButtonType.Normal })
                  .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
                  .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(6)
                  .onClick(() => this.editDrumMachine())
                Button('切回节拍打点', { type: ButtonType.Normal })
                  .layoutWeight(1.35).height(46).fontSize(15).fontWeight(900).fontColor(INK)
                  .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6)
                  .onClick(() => { void this.switchToBasicBeat(); })
              }.width('100%')
            } else {
              Text('队长已启用定制鼓机，出发时会自动同步。').fontSize(11).fontColor('#5D574F').width('100%')
            }
          }
          .width('100%').padding(14).backgroundColor('#EDE6FF')
          .border({ width: 2, color: INK }).borderRadius(8)
          .shadow({ radius: 0, offsetX: 3, offsetY: 4, color: INK })
        } else if (this.leader) {
          ComicButton({ label: 'PRO 定制鼓机', fill: LILAC, action: () => {
            this.editDrumMachine();
          } })
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
    }.height('100%').width('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
