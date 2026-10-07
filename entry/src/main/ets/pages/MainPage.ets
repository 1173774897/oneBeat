import { router, promptAction } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { SessionController } from '../session/SessionController';
import { SessionMember } from '../protocol/messages';
import {
  ComicCharacter,
  revealedAvatarAsset,
  PAPER,
  INK,
  CORAL,
  LILAC,
  WHITE,
  CARD_SHADOW,
  CONTROL_SHADOW,
  INK_SHADOW_RADIUS
} from '../components/ComicKit';
import { WalkScene } from '../scene/WalkScene';
import { EditableBpm } from '../components/EditableBpm';
import { MeterEditorOverlay } from '../components/EditableMeter';
import { BeatPointState, defaultBeatPointStates } from '../common/MeterModel';
import {
  defaultDrumProgram,
  DrumStyle,
  DRUM_STYLES,
  parseDrumProgram,
  serializeDrumProgram
} from '../audio/DrumMachineCatalog';

const COUNTDOWN_FONT_SIZE: number = 138;
const COUNTDOWN_START_SCALE: number = 0.52;
const COUNTDOWN_SCALE_RANGE: number = 1.1;
const COUNTDOWN_MAX_OPACITY: number = 0.76;
const COUNTDOWN_CENTER_Y_OFFSET: number = 0;
const BEAT_POINT_FOUR_BEAT_GAP: number = 18;
const BEAT_POINT_MIN_GAP: number = 3;
const BEAT_POINT_ROW_HEIGHT: number = 16;
const BEAT_POINT_FALLBACK_AREA_WIDTH: number = 332;
const TOP_PANEL_HIDDEN_OFFSET: number = 204;

@Entry
@Component
struct MainPage {
  @StorageLink('sessionEpoch') @Watch('refresh') epoch: number = 0;
  @State members: SessionMember[] = [];
  @State bpm: number = 120;
  @State beats: number = 4;
  @State unit: number = 4;
  @State beatPointStates: BeatPointState[] = defaultBeatPointStates(4);
  @State beat: number = -1;
  @State leader: boolean = false;
  @State state: string = 'idle';
  @State sync: string = '';
  @State sound: number = 0;
  @State showMembers: boolean = false;
  @State showStyles: boolean = false;
  @State rhythm: number = 0;
  @State drumStyleKey: string = 'rock';
  @State busy: boolean = false;
  @State exiting: boolean = false;
  @State showExitConfirm: boolean = false;
  @State meterEditorVisible: boolean = false;
  @State returningToLobby: boolean = false;
  @State chromeVisible: boolean = true;
  @State visualCountIn: boolean = false;
  @State visualPlaying: boolean = false;
  @State countdownNumber: number = 0;
  @State countdownScale: number = COUNTDOWN_START_SCALE;
  @State countdownOpacity: number = 0;
  @State beatPointAreaWidth: number = BEAT_POINT_FALLBACK_AREA_WIDTH;
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') sceneKey: string = 'sunset_coast';
  @StorageLink('btAudioActive') @Watch('onBtAudioActiveChanged') btAudioActive: boolean = false;
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
    if (this.meterEditorVisible) {
      this.meterEditorVisible = false;
      return true;
    }
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
    this.beatPointStates = c.beatPointStates.slice();
    this.leader = c.isLeader; this.state = c.state; this.sound = c.soundId; this.rhythm = c.rhythm;
    this.drumStyleKey = c.drumProgram.length > 0 ? parseDrumProgram(c.drumProgram).styleKey : 'rock';
    if (this.rhythm !== 3 && this.showStyles) { this.showStyles = false; }
    const storedBeatInBar = AppStorage.get<number>('currentBeatInBar') ?? 0;
    this.beat = storedBeatInBar > 0 ? storedBeatInBar - 1 : -1;
    this.sync = c.soloTeam ? '本机练习' : c.isLeader ? '队长时钟' : `同步 ${c.getSyncQuality()}`;
    this.soloTeam = c.soloTeam;
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

  private toggleStyleDrawer(): void {
    if (!this.leader || this.rhythm !== 3) {
      return;
    }
    this.showStyles = !this.showStyles;
    if (this.showStyles) {
      this.showMembers = false;
    }
  }

  private toggleMemberDrawer(): void {
    this.showMembers = !this.showMembers;
    if (this.showMembers) {
      this.showStyles = false;
    }
  }

  private async chooseDrumStyle(styleKey: string): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader || controller.rhythm !== 3) {
      return;
    }
    const program = controller.drumProgram.length > 0 ?
      parseDrumProgram(controller.drumProgram) : defaultDrumProgram();
    if (program.styleKey === styleKey) {
      return;
    }
    program.styleKey = styleKey;
    await controller.updateDrumProgram(serializeDrumProgram(program));
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

  private async applyMeter(beats: number, unit: number): Promise<void> {
    if (!this.leader || this.exiting) {
      return;
    }
    this.beats = beats;
    this.unit = unit;
    try {
      await AppSession.get()?.controller.updateMeter(beats, unit);
    } catch (_e) {
      promptAction.showToast({ message: '拍号修改失败，请重试' });
    } finally {
      this.refresh();
    }
  }

  private async cycleBeatPoint(index: number): Promise<void> {
    if (!this.leader || this.busy || this.exiting) {
      return;
    }
    this.busy = true;
    try {
      await AppSession.get()?.controller.cycleBeatPointState(index);
    } catch (_e) {
      promptAction.showToast({ message: '拍点修改失败，请重试' });
    } finally {
      this.busy = false;
      this.refresh();
    }
  }

  private beatPointFill(index: number): string {
    const state = this.beatPointStates[index] ?? (index === 0 ? 'accent' : 'normal');
    if (state === 'accent') { return LILAC; }
    if (state === 'silent') { return WHITE; }
    return CORAL;
  }

  private beatPointGap(): number {
    if (this.beats <= 4) {
      return BEAT_POINT_FOUR_BEAT_GAP;
    }
    const progress = (this.beats - 4) / 12;
    return BEAT_POINT_FOUR_BEAT_GAP -
      (BEAT_POINT_FOUR_BEAT_GAP - BEAT_POINT_MIN_GAP) * progress;
  }

  private beatPointSize(): number {
    // One to four beats intentionally reserve a four-slot grid so every common meter keeps the same visual weight.
    const slotCount = Math.max(4, this.beats);
    const gap = this.beatPointGap();
    return Math.max(12, (this.beatPointAreaWidth - gap * (slotCount - 1)) / slotCount);
  }

  private beatPointHeight(): number {
    // Height is the width of a sixteen-beat point; only sixteen beats render as squares.
    return Math.max(12,
      (this.beatPointAreaWidth - BEAT_POINT_MIN_GAP * 15) / 16);
  }

  private beatPointGroupWidth(): number {
    return this.beatPointSize() * this.beats + this.beatPointGap() * Math.max(0, this.beats - 1);
  }

  @Builder
  private beatPoint(index: number) {
    Stack()
      .width(this.beatPointSize())
      .height(this.beatPointHeight())
      .backgroundColor(this.beatPointFill(index))
      .border({
        width: this.beat === index && (this.visualPlaying || this.visualCountIn) ? 3 : 1.5,
        color: this.beat === index && (this.visualPlaying || this.visualCountIn) ? '#35D6E4' : INK
      })
      .borderRadius(5)
      .shadow(this.beat === index && (this.visualPlaying || this.visualCountIn) ?
        { radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 } :
        { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
      .opacity(this.leader && !this.busy ? 1 : 0.82)
      .onClick(() => { void this.cycleBeatPoint(index); })
  }

  private beatUnitIconPath(): string {
    if (this.unit === 1) { return 'comic/icons/note-whole.svg'; }
    if (this.unit === 2) { return 'comic/icons/note-half.svg'; }
    if (this.unit === 4) { return 'comic/icons/note-quarter.svg'; }
    if (this.unit === 8) { return 'comic/icons/note-eighth.svg'; }
    return 'comic/icons/note-sixteenth.svg';
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
            .shadow(CONTROL_SHADOW)
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
            .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
            .onClick(() => this.showExitConfirm = false)
          Button('退出队伍', { type: ButtonType.Normal })
            .layoutWeight(1).height(46).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
            .onClick(() => { void this.exitSessionToHome(); })
        }.width('100%')
      }
      .width('86%')
      .padding(17)
      .backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK })
      .borderRadius(8)
      .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 4, offsetY: 5, color: INK })
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
          .shadow(CONTROL_SHADOW)
        Blank()
        Circle().width(8).height(8).fill('#38B68D')
        Text(this.sync).fontSize(10).fontWeight(FontWeight.Bold).maxLines(1)
        Text('⚙').fontSize(21).padding({ left: 7, right: 2 }).onClick(() => { void this.requestExit(); })
      }.width('100%')
      Row({ space: 5 }) {
        EditableBpm({
          value: this.bpm,
          editable: this.leader,
          inputId: 'walk-bpm-input',
          controlWidth: 105,
          controlHeight: 62,
          valueFontSize: 58,
          valueColor: CORAL,
          valueShadow: { radius: 0, offsetX: 3, offsetY: 3, color: INK },
          onCommit: (value: number): void => {
            void AppSession.get()?.controller.updateBpm(value);
          }
        })
        Text('BPM').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
        Blank()
        Text(`${this.beats}/${this.unit}`)
          .width(76)
          .height(46)
          .fontSize(27)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(CORAL)
          .textAlign(TextAlign.Center)
          .textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
          .opacity(this.leader && !this.busy ? 1 : 0.6)
          .onClick(() => {
            if (this.leader && !this.busy) {
              this.meterEditorVisible = true;
            }
          })
        Image($rawfile(this.beatUnitIconPath()))
          .width(38)
          .height(46)
          .objectFit(ImageFit.Contain)
      }.height(65).width('100%')
      Row() {
        Row({ space: this.beatPointGap() }) {
          ForEach(Array.from({ length: this.beats }, (_v: number, i: number) => i), (i: number) => {
            this.beatPoint(i)
          }, (i: number) => `${i}`)
        }
        .width(this.beatPointGroupWidth())
        .height(BEAT_POINT_ROW_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(BEAT_POINT_ROW_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .onAreaChange((_oldArea, area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.beatPointAreaWidth) > 0.5) {
          this.beatPointAreaWidth = width;
        }
      })
      Text(this.visualCountIn ? '准备拍 · 下一小节出发' :
        this.visualPlaying ? 'STEP BY STEP · SAME BEAT' : 'READY TO WALK?')
        .fontSize(9).fontWeight(FontWeight.Bold).letterSpacing(1).width('100%')
    }
    .width('100%').padding({ left: 14, right: 14, top: 8 + this.topSafeInset, bottom: 8 })
    .backgroundColor(WHITE)
    .border({ width: { bottom: 3 }, color: INK })
    .translate({ y: this.chromeVisible ? 0 : -TOP_PANEL_HIDDEN_OFFSET - this.topSafeInset })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  @Builder
  private bottomPanel() {
    Column({ space: 7 }) {
      if (this.showStyles && this.rhythm === 3) {
        Column() {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(DRUM_STYLES, (style: DrumStyle) => {
                Column({ space: 2 }) {
                  Text(style.name).fontSize(13).fontWeight(900)
                  Text(style.caption).fontSize(9).fontWeight(FontWeight.Bold)
                }
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.drumStyleKey === style.key ? style.color : PAPER)
                .border({ width: 1, color: INK })
                .borderRadius(5)
                .shadow(CONTROL_SHADOW)
                .onClick(() => { void this.chooseDrumStyle(style.key); })
              }, (style: DrumStyle) => style.key)
            }.padding({ left: 8, right: 8, top: 4, bottom: 5 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .height(58)
        }
        .width('100%')
        .backgroundColor(LILAC)
        .border({ width: 1, color: INK })
        .borderRadius(5)
        .shadow(CARD_SHADOW)
      } else if (this.showMembers) {
        Column({ space: 6 }) {
          Scroll() {
            Row({ space: 12 }) {
              ForEach(this.members, (m: SessionMember) => {
                Column({ space: 2 }) {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    ComicCharacter({
                      avatar: revealedAvatarAsset(m.avatarKey, m.resolvedAvatarKey ?? '', m.colorSlot ?? 0),
                      portrait: true
                    }).width(34).height(34)
                    if (this.soloTeam && this.leader && SessionController.isSoloBotMemberId(m.id)) {
                      Text('×')
                        .fontSize(11)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(PAPER)
                        .width(16)
                        .height(16)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(INK)
                        .borderRadius(8).shadow(CARD_SHADOW)
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
                  .borderRadius(4).shadow(CONTROL_SHADOW)
                  .backgroundColor(PAPER)
                  .opacity(this.canAddSoloBotSlot() ? 1 : 0.42)
                  .enabled(this.canAddSoloBotSlot())
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
          .backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CARD_SHADOW).clip(false)
      }
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          if (this.rhythm === 3) {
            Button({ type: ButtonType.Normal }) {
              Text('风').fontSize(17).fontWeight(900).fontColor(INK).lineHeight(22)
            }.width(38).height(38).padding(0).backgroundColor(this.showStyles ? LILAC : PAPER)
              .fontColor(INK).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
              .enabled(this.leader).onClick(() => this.toggleStyleDrawer())
            Text('风格').fontSize(9).fontWeight(FontWeight.Bold)
          } else {
            Button({ type: ButtonType.Normal }) {
              Text('♪').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
            }.width(38).height(38).padding(0).backgroundColor(PAPER).fontColor(INK)
              .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
              .enabled(this.leader).onClick(() => { void AppSession.get()?.controller.updateSoundId(this.sound + 1); })
            Text(this.sounds[this.sound]).fontSize(9).fontWeight(FontWeight.Bold)
          }
        }
        Button({ type: ButtonType.Normal }) {
          Text('−').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
        }.width(38).height(38).padding(0).backgroundColor(PAPER).fontColor(INK)
          .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .enabled(this.leader && this.bpm > 40).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm - 1); })
        Button({ type: ButtonType.Normal }) {
          Image($rawfile(this.state === 'playing' || this.state === 'countdown' ?
            'comic/icons/stop.svg' : 'comic/icons/play.svg'))
            .width(32).height(32).objectFit(ImageFit.Contain)
        }
          .width(68).height(68).padding(0).backgroundColor(CORAL).fontColor(INK)
          .border({ width: 2, color: INK }).borderRadius(34).shadow({ radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 3, color: INK })
          .enabled(this.leader && !this.busy).onClick(() => { void this.toggle(); })
        Button({ type: ButtonType.Normal }) {
          Text('+').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
        }.width(38).height(38).padding(0).backgroundColor(PAPER).fontColor(INK)
          .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .enabled(this.leader && this.bpm < 240).onClick(() => { void AppSession.get()?.controller.updateBpm(this.bpm + 1); })
        Column({ space: 2 }) {
          Button({ type: ButtonType.Normal }) {
            Text('人').fontSize(17).fontWeight(900).fontColor(INK).lineHeight(22)
          }.width(38).height(38).padding(0).backgroundColor(this.showMembers ? LILAC : PAPER).fontColor(INK)
            .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.toggleMemberDrawer())
          Text(`${this.members.length} 队员`).fontSize(9).fontWeight(FontWeight.Bold)
        }
      }.width('100%').justifyContent(FlexAlign.SpaceBetween).alignItems(VerticalAlign.Center)
      Text(this.leader ? (this.state === 'idle' ? '点击播放 · 全队一起出发' :
        this.state === 'paused' ? '已暂停 · 点击继续' :
          this.visualCountIn ? '准备拍 · 舞台保持静止' : 'ONEBEAT / 同拍进行中') : '节奏由队长控制')
        .fontSize(10).fontWeight(FontWeight.Bold).fontStyle(FontStyle.Italic).letterSpacing(0.5)
    }
    .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 12 + this.bottomSafeInset })
    .backgroundColor(WHITE)
    .border({ width: { top: 3 }, color: INK })
    .translate({ y: this.chromeVisible ? 0 : 190 + this.bottomSafeInset })
    .opacity(this.chromeVisible ? 1 : 0)
  }

  onBtAudioActiveChanged(): void {
    if (this.btAudioActive) {
      promptAction.showToast({ message: '检测到蓝牙耳机输出，节拍可能延迟，建议外放或有线耳机' });
    }
  }

  @Builder
  bluetoothBanner() {
    Column() {
      Row() {
        Text('蓝牙耳机输出 · 节拍可能延迟')
          .fontSize(13)
          .fontColor(INK)
        Blank()
        Text('建议外放 / 有线')
          .fontSize(12)
          .fontColor(CORAL)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 9, bottom: 9 })
      .backgroundColor(PAPER)
      .borderRadius(12)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: this.topSafeInset + 10 })
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
      if (this.btAudioActive) {
        this.bluetoothBanner()
      }
      if (this.showExitConfirm) {
        this.exitConfirmOverlay()
      }
      if (this.meterEditorVisible) {
        MeterEditorOverlay({
          initialBeats: this.beats,
          initialUnit: this.unit,
          onChange: (beats: number, unit: number): void => { void this.applyMeter(beats, unit); },
          onDismiss: (): void => { this.meterEditorVisible = false; }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
