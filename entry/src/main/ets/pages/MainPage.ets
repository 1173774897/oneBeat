import { router, promptAction } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { SessionController } from '../session/SessionController';
import { SessionMember } from '../protocol/messages';
import { ComicCharacter, PAPER, INK, CORAL, LILAC } from '../components/ComicKit';
import { WalkScene } from '../scene/WalkScene';

const COUNTDOWN_FONT_SIZE: number = 138;
const COUNTDOWN_START_SCALE: number = 0.52;
const COUNTDOWN_SCALE_RANGE: number = 1.1;
const COUNTDOWN_MAX_OPACITY: number = 0.76;
const COUNTDOWN_CENTER_Y_OFFSET: number = 0;

@Entry
@Component
struct MainPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @State members: SessionMember[] = [];
  @State bpm: number = 120;
  @State beats: number = 4;
  @State unit: number = 4;
  @State beat: number = -1;
  @State leader: boolean = false;
  @State state: string = 'idle';
  @State sync: string = '';
  @State sound: number = 0;
  @State showMembers: boolean = false;
  @State busy: boolean = false;
  @State exiting: boolean = false;
  @State showExitConfirm: boolean = false;
  @State returningToLobby: boolean = false;
  @State chromeVisible: boolean = true;
  @State visualCountIn: boolean = false;
  @State visualPlaying: boolean = false;
  @State countdownNumber: number = 0;
  @State countdownScale: number = COUNTDOWN_START_SCALE;
  @State countdownOpacity: number = 0;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') sceneKey: string = 'neon_street';
  @State soloTeam: boolean = false;
  private sounds: string[] = ['电子', '清脆', '低音'];
  private visualTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.startVisualLoop();
  }
  aboutToDisappear(): void { this.stopVisualLoop(); }
  onPageShow(): void {
    this.refresh();
    this.startVisualLoop();
  }
  onBackPress(): boolean {
    if (this.showExitConfirm) {
      this.showExitConfirm = false;
      return true;
    }
    void this.requestExit();
    return true;
  }
  refresh(): void {
    const c = AppSession.get()?.controller;
    if (c === undefined) { return; }
    this.members = c.getMembers(); this.bpm = c.bpm; this.beats = c.beatsPerBar; this.unit = c.beatUnit;
    this.leader = c.isLeader; this.state = c.state; this.sound = c.soundId;
    const storedBeatInBar = AppStorage.get<number>('currentBeatInBar') ?? 0;
    this.beat = storedBeatInBar > 0 ? storedBeatInBar - 1 : -1;
    this.sync = c.soloTeam ? '本机练习' : c.isLeader ? '队长时钟' : `同步 ${c.getSyncQuality()}`;
    this.soloTeam = c.soloTeam;
    if (c.soloTeam && c.isLeader) {
      c.reconcileSoloLegacyBots();
      this.members = c.getMembers();
    }
    this.refreshVisualTransport();
    if (!c.soloTeam && !c.isLeader && !c.lobbyDeparted) {
      this.returnToLobby();
    }
  }

  private canAddSoloBotSlot(): boolean {
    return AppSession.get()?.controller.canAddSoloBot() ?? false;
  }

  private async addSoloBotSlot(): Promise<void> {
    if (!this.canAddSoloBotSlot()) {
      return;
    }
    await AppSession.get()?.controller.addSoloBotWithNextAvatar();
    this.refresh();
  }

  private async removeSoloBotSlot(id: string): Promise<void> {
    await AppSession.get()?.controller.removeSoloBotById(id);
    this.refresh();
  }

  private startVisualLoop(): void {
    if (this.visualTimer >= 0) { return; }
    this.visualTimer = setInterval(() => this.refreshVisualTransport(), 32);
  }

  private stopVisualLoop(): void {
    if (this.visualTimer >= 0) {
      clearInterval(this.visualTimer);
      this.visualTimer = -1;
    }
  }

  private refreshVisualTransport(): void {
    const snapshot = AppSession.get()?.metronome.getVisualSnapshot();
    if (snapshot === undefined || !snapshot.running) {
      if (this.visualCountIn) { this.visualCountIn = false; }
      if (this.visualPlaying) { this.visualPlaying = false; }
      if (this.countdownNumber !== 0) { this.countdownNumber = 0; }
      if (this.countdownOpacity !== 0) { this.countdownOpacity = 0; }
      return;
    }
    const nextBeat = snapshot.beatInBar > 0 ? snapshot.beatInBar - 1 : -1;
    const nextPlaying = snapshot.mainPlayheadMs >= 0;
    if (this.beat !== nextBeat) { this.beat = nextBeat; }
    if (this.visualCountIn !== snapshot.countIn) { this.visualCountIn = snapshot.countIn; }
    if (this.visualPlaying !== nextPlaying) { this.visualPlaying = nextPlaying; }
    if (snapshot.countIn && snapshot.beatInBar > 0) {
      const phase = Math.max(0, Math.min(1, snapshot.beatPhase));
      const nextCountdownNumber = Math.max(1, this.beats - snapshot.beatInBar + 1);
      const nextScale = COUNTDOWN_START_SCALE + phase * COUNTDOWN_SCALE_RANGE;
      const nextOpacity = COUNTDOWN_MAX_OPACITY * (1 - phase * phase);
      if (this.countdownNumber !== nextCountdownNumber) { this.countdownNumber = nextCountdownNumber; }
      if (Math.abs(this.countdownScale - nextScale) > 0.01) { this.countdownScale = nextScale; }
      if (Math.abs(this.countdownOpacity - nextOpacity) > 0.01) { this.countdownOpacity = nextOpacity; }
    } else {
      if (this.countdownNumber !== 0) { this.countdownNumber = 0; }
      if (this.countdownOpacity !== 0) { this.countdownOpacity = 0; }
    }
  }

  private async toggle(): Promise<void> {
    if (!this.leader || this.busy || this.exiting) { return; }
    this.busy = true;
    try {
      const s = AppSession.get();
      if (this.state === 'playing' || this.state === 'countdown') { await s?.leaderPause(); }
      else if (this.state === 'paused') { await s?.leaderResume(); }
      else { await s?.leaderStart(); }
    } catch (_e) { promptAction.showToast({ message: '播放操作失败，请重试' }); }
    finally { this.busy = false; this.refresh(); }
  }

  private async requestExit(): Promise<void> {
    if (this.exiting || this.returningToLobby) { return; }
    const controller = AppSession.get()?.controller;
    if (controller === undefined) {
      await this.exitSessionToHome();
      return;
    }
    if (!controller.isLeader) {
      this.showExitConfirm = true;
      return;
    }
    this.returningToLobby = true;
    try {
      await AppSession.get()?.leaderReturnToLobby();
      router.back();
    } catch (_e) {
      promptAction.showToast({ message: '返回队伍大厅失败，请重试' });
      this.returningToLobby = false;
    }
  }

  private returnToLobby(): void {
    if (this.returningToLobby || this.exiting) { return; }
    this.returningToLobby = true;
    this.showExitConfirm = false;
    router.back();
  }

  private async exitSessionToHome(): Promise<void> {
    if (this.exiting) { return; }
    this.showExitConfirm = false;
    this.exiting = true;
    try {
      await AppSession.reset();
    } catch (_e) {
      promptAction.showToast({ message: '会话已退出，部分网络资源稍后释放' });
    }
    router.clear();
    try {
      await router.replaceUrl({ url: 'pages/Index' });
    } catch (_e) {
      promptAction.showToast({ message: '返回首页失败，请重试' });
      this.exiting = false;
    }
  }

  private toggleChrome(): void {
    animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.chromeVisible = !this.chromeVisible;
    });
  }

  @Builder
  private countdownOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.countdownNumber > 0) {
        Text(`${this.countdownNumber}`)
          .fontSize(COUNTDOWN_FONT_SIZE)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(Color.White)
          .textShadow({ radius: 0, offsetX: 7, offsetY: 8, color: '#A8171B1F' })
          .rotate({ angle: -4 })
          .scale({ x: this.countdownScale, y: this.countdownScale })
          .translate({ y: COUNTDOWN_CENTER_Y_OFFSET })
          .opacity(this.countdownOpacity)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .zIndex(40)
  }

  @Builder
  private exitConfirmOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 13 }) {
        Row() {
          Text('先等等！').fontSize(13).fontWeight(900).fontColor(PAPER)
            .backgroundColor(INK).padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .rotate({ angle: -2 })
          Blank()
          Text('×').fontSize(22).fontWeight(900).width(32).height(32).textAlign(TextAlign.Center)
            .onClick(() => this.showExitConfirm = false)
        }.width('100%')
        Text('要退出这支队伍吗？').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text('退出后会回到首页，本轮队伍进度不会保留。')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#625C54').width('100%')
        Row({ space: 10 }) {
          Button('继续行进', { type: ButtonType.Normal })
            .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6)
            .onClick(() => this.showExitConfirm = false)
          Button('退出队伍', { type: ButtonType.Normal })
            .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6)
            .onClick(() => { void this.exitSessionToHome(); })
        }.width('100%')
      }
      .width('86%')
      .padding(17)
      .backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK })
      .borderRadius(8)
      .shadow({ radius: 0, offsetX: 4, offsetY: 5, color: INK })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#72000000')
    .zIndex(100)
  }

  @Builder
  private topPanel() {
    Column({ space: 5 }) {
      Row() {
        Text('‹').fontSize(30).width(30).onClick(() => { void this.requestExit(); })
        Text('一起行进').fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic)
        Text(' LIVE ').fontSize(10).fontWeight(FontWeight.Bold).fontColor(PAPER)
          .backgroundColor(CORAL).padding({ left: 4, right: 4, top: 2, bottom: 2 }).rotate({ angle: -4 })
        Blank()
        Circle().width(8).height(8).fill('#38B68D')
        Text(this.sync).fontSize(10).fontWeight(FontWeight.Bold).maxLines(1)
        Text('⚙').fontSize(21).padding({ left: 7, right: 2 }).onClick(() => { void this.requestExit(); })
      }.width('100%')
      Row({ space: 5 }) {
        Text(`${this.bpm}`).fontSize(58).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(CORAL)
          .textShadow({ radius: 0, offsetX: 3, offsetY: 3, color: INK })
        Text('BPM').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
        Blank()
        Row({ space: 7 }) {
          ForEach(Array.from({ length: this.beats }, (_v: number, i: number) => i), (i: number) => {
            if (this.visualCountIn && this.beat === i) {
              Circle().width(19).height(19).fill('#00FFFFFF')
                .stroke('#35D6E4').strokeWidth(3)
                .shadow({ radius: 8, color: '#9935D6E4', offsetX: 0, offsetY: 0 })
            } else {
              Circle().width(19).height(19)
                .fill(this.visualPlaying && this.beat === i ? CORAL : '#E5DFD1')
                .stroke(INK).strokeWidth(1)
            }
          })
        }
        Text(`${this.beats}/${this.unit}`).fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
      }.height(65).width('100%')
      Row() {
        Text(this.visualCountIn ? '准备拍 · 下一小节出发' :
          this.visualPlaying ? 'STEP BY STEP · SAME BEAT' : 'READY TO WALK?')
          .fontSize(9).fontWeight(FontWeight.Bold).letterSpacing(1)
        Blank()
        Text('轻点舞台隐藏面板').fontSize(9).fontColor('#67615A')
      }.width('100%')
    }
    .width('100%').padding({ left: 14, right: 14, top: 8 + this.topSafeInset, bottom: 8 })
    .backgroundColor('#F5EBD6F5')
    .border({ width: { bottom: 3 }, color: INK })
    .shadow({ radius: 0, offsetY: 5, color: '#66171B1F' })
    .translate({ y: this.chromeVisible ? 0 : -155 - this.topSafeInset })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  @Builder
  private bottomPanel() {
    Column({ space: 7 }) {
      if (this.showMembers) {
        Column({ space: 6 }) {
          Scroll() {
            Row({ space: 12 }) {
              ForEach(this.members, (m: SessionMember) => {
                Column({ space: 2 }) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    ComicCharacter({ avatar: m.avatarKey, portrait: true }).width(34).height(34)
                    if (this.soloTeam && this.leader && SessionController.isSoloBotMemberId(m.id)) {
                      Text('×')
                        .fontSize(11)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(PAPER)
                        .width(16)
                        .height(16)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(INK)
                        .borderRadius(8)
                        .margin({ top: 1, right: 1 })
                        .onClick(() => { void this.removeSoloBotSlot(m.id); })
                    }
                  }
                  .width(34)
                  .height(34)
                  .clip(false)
                  Text(m.displayName).fontSize(9).fontWeight(FontWeight.Bold).maxLines(1).width(58)
                    .textAlign(TextAlign.Center)
                }
                .width(58)
                .alignItems(HorizontalAlign.Center)
                .clip(false)
              }, (m: SessionMember) => m.id)
              if (this.soloTeam && this.leader) {
                Column() {
                  Stack() {
                    Text('+').fontSize(20).fontWeight(FontWeight.Bold)
                      .fontColor(this.canAddSoloBotSlot() ? INK : '#9A948C')
                  }
                  .width(34)
                  .height(34)
                  .border({ width: 1.5, color: INK })
                  .borderRadius(4)
                  .backgroundColor(PAPER)
                  .opacity(this.canAddSoloBotSlot() ? 1 : 0.42)
                  .hitTestBehavior(this.canAddSoloBotSlot() ? HitTestMode.Default : HitTestMode.None)
                  .onClick(() => { void this.addSoloBotSlot(); })
                  Text(' ').fontSize(9).opacity(0)
                }.width(58)
              }
            }.padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%')
          .height(56)
          .clip(false)
        }.width('100%')
          .backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).clip(false)
      }
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Button('♪').width(38).height(38).backgroundColor(PAPER).fontColor(INK).border({ width: 1.5, color: INK }).borderRadius(5)
            .enabled(this.leader).onClick(() => { void AppSession.get()?.controller.updateSoundId(this.sound + 1); })
          Text(this.sounds[this.sound]).fontSize(9).fontWeight(FontWeight.Bold)
        }
        Button('−').width(38).height(38).backgroundColor(PAPER).fontColor(INK).fontSize(22)
          .border({ width: 1.5, color: INK }).borderRadius(5)
          .enabled(this.leader && this.bpm > 40).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm - 1); })
        Button(this.state === 'playing' || this.state === 'countdown' ? 'Ⅱ' : '▶')
          .width(68).height(68).backgroundColor(CORAL).fontColor(INK).fontSize(27)
          .border({ width: 2, color: INK }).borderRadius(34).shadow({ radius: 0, offsetX: 3, offsetY: 3, color: INK })
          .enabled(this.leader && !this.busy).onClick(() => { void this.toggle(); })
        Button('+').width(38).height(38).backgroundColor(PAPER).fontColor(INK).fontSize(22)
          .border({ width: 1.5, color: INK }).borderRadius(5)
          .enabled(this.leader && this.bpm < 240).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm + 1); })
        Column({ space: 2 }) {
          Button('人').width(38).height(38).backgroundColor(this.showMembers ? LILAC : PAPER).fontColor(INK)
            .border({ width: 1.5, color: INK }).borderRadius(5).onClick(() => this.showMembers = !this.showMembers)
          Text(`${this.members.length} 队员`).fontSize(9).fontWeight(FontWeight.Bold)
        }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).alignItems(VerticalAlign.Center)
      Text(this.leader ? (this.state === 'idle' ? '点击播放 · 全队一起出发' :
        this.state === 'paused' ? '已暂停 · 点击继续' :
          this.visualCountIn ? '准备拍 · 舞台保持静止' : 'ONEBEAT / 同拍进行中') : '节奏由队长控制')
        .fontSize(10).fontWeight(FontWeight.Bold).fontStyle(FontStyle.Italic).letterSpacing(0.5)
    }
    .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 12 + this.bottomSafeInset })
    .backgroundColor('#F5EBD6F5')
    .border({ width: { top: 3 }, color: INK })
    .shadow({ radius: 0, offsetY: -5, color: '#66171B1F' })
    .translate({ y: this.chromeVisible ? 0 : 190 + this.bottomSafeInset })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      WalkScene({
        members: this.members,
        bpm: this.bpm,
        isPlaying: this.state === 'playing' || this.state === 'countdown',
        scrollSpeed: this.state === 'playing' || this.state === 'countdown' ? this.bpm * 1.2 : 0,
        sceneKey: this.sceneKey
      })
        .width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onClick(() => this.toggleChrome())
      this.countdownOverlay()
      Column() {
        this.topPanel()
        Blank().hitTestBehavior(HitTestMode.None)
        this.bottomPanel()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(50)
      if (this.showExitConfirm) {
        this.exitConfirmOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
