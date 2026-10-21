import { common } from '@kit.AbilityKit';
import { router, promptAction } from '@kit.ArkUI';
import { navigateToHome } from '../app/HomeNavigation';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, TEAL, WHITE, CONTROL_SHADOW } from '../components/ComicKit';
import { TeamTicketBackdrop, TeamWifiFooter } from '../components/TeamEntryVisuals';
import { isTeamWifiActive, openWirelessSettings } from '../network/join/TeamNetworkPermissions';

const PLAYER_DISPLAY_NAME_KEY: string = 'playerDisplayName';
const TEAM_PAGE_SIDE_INSET: number = 18;
const TEAM_PAGE_TOP_INSET: number = 8;
const TEAM_PAGE_BOTTOM_INSET: number = 24;
const TEAM_HEADER_HEIGHT: number = 36;
const TEAM_HERO_HEIGHT: number = 70;
const TEAM_BRAND_WIDTH: number = 110;
const TEAM_BRAND_HEIGHT: number = 82;
const TEAM_BRAND_X_OFFSET: number = 3;
const TEAM_BRAND_Y: number = -23;
const TEAM_NICKNAME_HEIGHT: number = 58;
const TEAM_NICKNAME_BOTTOM_GAP: number = 14;
const TEAM_TICKET_GAP: number = 12;
const TEAM_TICKET_MIN_HEIGHT: number = 336;
const TEAM_TICKET_MAX_HEIGHT: number = 448;
const TEAM_ROLE_TEXT_HEIGHT: number = 99;
const TEAM_ROLE_ACTION_HEIGHT: number = 62;
const TEAM_ROLE_CHARACTER_Y: number = 0;
/** Mismatch (队长) uses the full computed slot; wave scales down from the bottom edge. */
const TEAM_WAVE_CHARACTER_SCALE: number = 0.88;
/** Mismatch ticket foot plant (plant_01); larger bottom inset moves the sprite up. */
const TEAM_CAPTAIN_PLANT_SIZE: number = 92;
const TEAM_CAPTAIN_PLANT_X: number = 5;
const TEAM_CAPTAIN_PLANT_BOTTOM_INSET: number = 23;
const TEAM_CAPTAIN_PLANT_11_SIZE: number = 62;
const TEAM_CAPTAIN_PLANT_11_RIGHT_INSET: number = 8;
const TEAM_CAPTAIN_PLANT_11_BOTTOM_INSET: number = 22;
const TEAM_CAPTAIN_PLANT_09_SIZE: number = 58;
const TEAM_CAPTAIN_PLANT_09_X: number = 72;
const TEAM_CAPTAIN_PLANT_09_BOTTOM_INSET: number = 29;
/** Wave ticket main foot plant (plant_03). */
const TEAM_MEMBER_PLANT_RIGHT_INSET: number = 47;
const TEAM_MEMBER_PLANT_BOTTOM_INSET: number = 10;
/** Smaller accent plants on the wave ticket; one mirrored horizontally. */
const TEAM_MEMBER_EXTRA_PLANT_SIZE: number = 74;
const TEAM_MEMBER_EXTRA_PLANT_LEFT_X: number = 6;
const TEAM_MEMBER_EXTRA_PLANT_RIGHT_INSET: number = 40;
const TEAM_MEMBER_EXTRA_PLANT_BOTTOM_INSET: number = 44;
const TEAM_FOOTER_TOP_GAP: number = 16;
const TEAM_FOOTER_HEIGHT: number = 28;
const NICKNAME_HINT_WIDTH: number = 182;
const NICKNAME_HINT_BODY_HEIGHT: number = 50;
const NICKNAME_HINT_HEIGHT: number = 67;

@Entry
@Component
struct TeamPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @State displayName: string = '';
  @State showNicknameHint: boolean = false;
  @State nicknameHintScale: number = 1;
  @State nicknameHintOpacity: number = 1;
  @State private viewportHeight: number = 720;
  @State private contentWidth: number = 360;
  private nicknameHintPulseRevision: number = 0;
  private nicknamePool: string[] = [
    '云朵侠', '节拍猫', '慢半拍', '闪电腿', '小旋风', '踩点王',
    '奶油飞侠', '月球散步', '乱拍天才', '霓虹旅人', '云端舞者', '走路带风',
    '今天不掉拍', '海边追风者', '宇宙节拍员', '云端漫步者', '随风踩鼓点',
    '左脚追上右脚', '带着节拍出发', '正在月球散步', '跟着鼓点旅行'
  ];

  aboutToAppear(): void {
    const savedName = (AppStorage.get<string>(PLAYER_DISPLAY_NAME_KEY) ?? '').trim();
    this.displayName = savedName === 'Player' || savedName === 'Member' || savedName === '我' ? '' : savedName;
  }

  onBackPress(): boolean {
    void navigateToHome();
    return true;
  }

  private randomNicknameValue(): string {
    const index = Math.floor(Math.random() * this.nicknamePool.length);
    return this.nicknamePool[index];
  }

  private fillRandomNickname(): void {
    this.displayName = this.randomNicknameValue();
    this.showNicknameHint = false;
    AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, this.displayName);
  }

  private validatedDisplayName(): string {
    const trimmed = this.displayName.trim();
    if (trimmed.length === 0) {
      this.showNicknameHint = true;
      this.pulseNicknameHint();
      return '';
    }
    this.showNicknameHint = false;
    AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, trimmed);
    return trimmed;
  }

  private pulseNicknameHint(): void {
    const revision = ++this.nicknameHintPulseRevision;
    this.nicknameHintScale = 1;
    this.nicknameHintOpacity = 1;
    // The hint may be entering the conditional tree on this same tap; defer the
    // first frame so both a newly shown and an existing bubble animate reliably.
    setTimeout(() => {
      if (revision !== this.nicknameHintPulseRevision) {
        return;
      }
      animateTo({ duration: 90, curve: Curve.EaseOut }, () => {
        this.nicknameHintScale = 1.045;
        this.nicknameHintOpacity = 0.48;
      });
      setTimeout(() => {
        if (revision !== this.nicknameHintPulseRevision) {
          return;
        }
        animateTo({ duration: 150, curve: Curve.EaseInOut }, () => {
          this.nicknameHintScale = 1;
          this.nicknameHintOpacity = 1;
        });
      }, 95);
    }, 0);
  }

  private async createTeam(): Promise<void> {
    const displayName = this.validatedDisplayName();
    if (displayName.length === 0) {
      return;
    }
    if (!isTeamWifiActive()) {
      try {
        const result = await promptAction.showDialog({
          title: '建队前先打开 Wi-Fi',
          message: '同拍使用 Wi-Fi 直连组队，不需要连接同一个路由器。打开后再回来创建队伍。',
          buttons: [
            { text: '暂不创建', color: '#625B53' },
            { text: '去打开 Wi-Fi', color: CORAL, primary: true }
          ]
        });
        if (result.index === 1) {
          const ctx = getContext(this) as common.UIAbilityContext;
          await openWirelessSettings(ctx);
        }
      } catch (_e) {
      }
      return;
    }
    router.pushUrl({
      url: 'pages/LeaderLobbyPage',
      params: { displayName: displayName, solo: '0' }
    });
  }

  private joinTeam(): void {
    const displayName = this.validatedDisplayName();
    if (displayName.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/MemberJoinPage',
      params: { displayName: displayName }
    });
  }

  private ticketHeight(): number {
    const fixed = this.topSafeInset + this.bottomSafeInset + TEAM_PAGE_TOP_INSET + TEAM_PAGE_BOTTOM_INSET +
      TEAM_HEADER_HEIGHT + TEAM_HERO_HEIGHT + TEAM_NICKNAME_HEIGHT + TEAM_NICKNAME_BOTTOM_GAP +
      TEAM_FOOTER_TOP_GAP + TEAM_FOOTER_HEIGHT;
    // Short screens scroll rather than compressing the character or either action below a usable size.
    return Math.max(TEAM_TICKET_MIN_HEIGHT, Math.min(TEAM_TICKET_MAX_HEIGHT, this.viewportHeight - fixed));
  }

  private ticketWidth(): number {
    return (this.contentWidth - TEAM_TICKET_GAP) / 2;
  }

  private artworkHeight(): number {
    return this.ticketHeight() - TEAM_ROLE_TEXT_HEIGHT - TEAM_ROLE_ACTION_HEIGHT;
  }

  private characterHeight(): number {
    return Math.min(this.artworkHeight(), this.ticketWidth() * 1.5);
  }

  private roleCharacterWidth(captain: boolean): number {
    const base = this.ticketWidth();
    return captain ? base : base * TEAM_WAVE_CHARACTER_SCALE;
  }

  private roleCharacterHeight(captain: boolean): number {
    const base = this.characterHeight();
    return captain ? base : base * TEAM_WAVE_CHARACTER_SCALE;
  }

  private roleCharacterX(captain: boolean): number {
    if (captain) {
      return 0;
    }
    return (this.ticketWidth() - this.roleCharacterWidth(false)) / 2;
  }

  private roleCharacterY(captain: boolean): number {
    return this.artworkHeight() - this.roleCharacterHeight(captain) + TEAM_ROLE_CHARACTER_Y;
  }

  private captainPlantY(): number {
    return this.artworkHeight() - TEAM_CAPTAIN_PLANT_SIZE - TEAM_CAPTAIN_PLANT_BOTTOM_INSET;
  }

  private captainAccentPlantY(plantSize: number, bottomInset: number): number {
    return this.artworkHeight() - plantSize - bottomInset;
  }

  private memberPlantY(): number {
    return this.artworkHeight() - TEAM_CAPTAIN_PLANT_SIZE - TEAM_MEMBER_PLANT_BOTTOM_INSET;
  }

  private memberExtraPlantY(): number {
    return this.artworkHeight() - TEAM_MEMBER_EXTRA_PLANT_SIZE - TEAM_MEMBER_EXTRA_PLANT_BOTTOM_INSET;
  }

  @Builder
  private slogan() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('comic/decor/ticket-halftone-coral.svg')).width(78).height(124.8)
        .position({ x: this.contentWidth - 82, y: -42 }).hitTestBehavior(HitTestMode.None)
      Image($rawfile('comic/brand/onebeat_wordmark.png')).width(TEAM_BRAND_WIDTH).height(TEAM_BRAND_HEIGHT)
        .objectFit(ImageFit.Contain)
        .position({ x: this.contentWidth - TEAM_BRAND_WIDTH + TEAM_BRAND_X_OFFSET, y: TEAM_BRAND_Y })
        .hitTestBehavior(HitTestMode.None)
      Text('一个节拍，一起出发。').fontSize(25).minFontSize(17).maxFontSize(25)
        .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).maxLines(1).width('100%').height(34)
        .padding({ right: 106 }).position({ x: 0, y: 16 })
      Image($rawfile('comic/icons/ticket-underline.svg')).width(104).height(9)
        .position({ x: 64, y: 47 }).hitTestBehavior(HitTestMode.None)
    }.width('100%').height(TEAM_HERO_HEIGHT).clip(false)
  }

  @Builder
  private nicknameCard() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(TEAM_NICKNAME_HEIGHT).backgroundColor(INK).borderRadius(6)
        .translate({ x: 4, y: 5 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Row({ space: 8 }) {
        Text('你的昵称').fontSize(16).fontWeight(900).fontColor(INK).width(64).maxLines(1)
        TextInput({ text: this.displayName, placeholder: '输入昵称' }).maxLength(16).height(38)
          .fontSize(14).placeholderFont({ size: 14 }).layoutWeight(1).padding({ left: 10, right: 8 })
          .backgroundColor('#F1EBDF').border({ width: 1, color: INK }).borderRadius(6)
          .accessibilityText('你的昵称')
          .onChange((value: string) => {
            this.displayName = value;
            if (value.trim().length > 0) { this.showNicknameHint = false; }
            AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, value.trim());
          })
        Button('叫啥都行', { type: ButtonType.Normal }).width(88).height(38).padding(0)
          .fontSize(14).fontWeight(900).fontColor(INK).backgroundColor(TEAL)
          .border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
          .accessibilityText('随机起一个昵称').onClick(() => this.fillRandomNickname())
      }.width('100%').height(TEAM_NICKNAME_HEIGHT).padding({ left: 10, right: 10 })
        .backgroundColor(WHITE).border({ width: 1.6, color: INK }).borderRadius(6)
      if (this.showNicknameHint) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image($rawfile('comic/decor/nickname_hint_bubble.svg')).width(NICKNAME_HINT_WIDTH)
            .height(NICKNAME_HINT_HEIGHT).objectFit(ImageFit.Fill)
          Text('先给自己起个名字！\n不想费脑筋？点这里').width(NICKNAME_HINT_WIDTH - 24)
            .height(NICKNAME_HINT_BODY_HEIGHT - 16).fontSize(12).fontWeight(900).lineHeight(17)
            .fontColor(INK).position({ x: 12, y: 9 })
        }.width(NICKNAME_HINT_WIDTH).height(NICKNAME_HINT_HEIGHT)
          .position({ x: Math.max(0, this.contentWidth - NICKNAME_HINT_WIDTH - 4), y: -NICKNAME_HINT_HEIGHT + 6 })
          .scale({ x: this.nicknameHintScale, y: this.nicknameHintScale }).opacity(this.nicknameHintOpacity)
          .rotate({ angle: -2 }).zIndex(20).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height(TEAM_NICKNAME_HEIGHT).clip(false).zIndex(5)
  }

  @Builder
  private roleArtwork(captain: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (captain) {
        Image($rawfile('vegetation/plant_05.png')).width(TEAM_CAPTAIN_PLANT_09_SIZE).height(TEAM_CAPTAIN_PLANT_09_SIZE)
          .objectFit(ImageFit.Contain)
          .position({
            x: TEAM_CAPTAIN_PLANT_09_X,
            y: this.captainAccentPlantY(TEAM_CAPTAIN_PLANT_09_SIZE, TEAM_CAPTAIN_PLANT_09_BOTTOM_INSET)
          })
          .hitTestBehavior(HitTestMode.None)
        Image($rawfile('vegetation/plant_03.png')).width(TEAM_CAPTAIN_PLANT_11_SIZE).height(TEAM_CAPTAIN_PLANT_11_SIZE)
          .objectFit(ImageFit.Contain)
          .position({
            x: this.ticketWidth() - TEAM_CAPTAIN_PLANT_11_SIZE - TEAM_CAPTAIN_PLANT_11_RIGHT_INSET,
            y: this.captainAccentPlantY(TEAM_CAPTAIN_PLANT_11_SIZE, TEAM_CAPTAIN_PLANT_11_BOTTOM_INSET)
          })
          .hitTestBehavior(HitTestMode.None)
        Image($rawfile('vegetation/plant_01.png')).width(TEAM_CAPTAIN_PLANT_SIZE).height(TEAM_CAPTAIN_PLANT_SIZE)
          .objectFit(ImageFit.Contain)
          .position({ x: TEAM_CAPTAIN_PLANT_X, y: this.captainPlantY() })
          .hitTestBehavior(HitTestMode.None)
      } else {
        Image($rawfile('vegetation/plant_06.png')).width(TEAM_MEMBER_EXTRA_PLANT_SIZE)
          .height(TEAM_MEMBER_EXTRA_PLANT_SIZE).objectFit(ImageFit.Contain)
          .scale({ x: -1, y: 1 })
          .position({ x: TEAM_MEMBER_EXTRA_PLANT_LEFT_X, y: this.memberExtraPlantY() })
          .hitTestBehavior(HitTestMode.None)
        Image($rawfile('vegetation/plant_03.png')).width(TEAM_MEMBER_EXTRA_PLANT_SIZE)
          .height(TEAM_MEMBER_EXTRA_PLANT_SIZE).objectFit(ImageFit.Contain)
          .position({
            x: this.ticketWidth() - TEAM_MEMBER_EXTRA_PLANT_SIZE - TEAM_MEMBER_EXTRA_PLANT_RIGHT_INSET,
            y: this.memberExtraPlantY()
          })
          .hitTestBehavior(HitTestMode.None)
        Image($rawfile('vegetation/plant_03.png')).width(TEAM_CAPTAIN_PLANT_SIZE).height(TEAM_CAPTAIN_PLANT_SIZE)
          .objectFit(ImageFit.Contain)
          .position({ x: this.ticketWidth() - TEAM_MEMBER_PLANT_RIGHT_INSET, y: this.memberPlantY() })
          .hitTestBehavior(HitTestMode.None)
      }
      ComicCharacter({ avatar: captain ? 'mismatch' : 'wave', pose: captain ? 'mismatch' : 'wave' })
        .width(this.roleCharacterWidth(captain)).height(this.roleCharacterHeight(captain))
        .position({ x: this.roleCharacterX(captain), y: this.roleCharacterY(captain) })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }.width('100%').height(this.artworkHeight())
      .clip(true).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private roleTicket(captain: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      TeamTicketBackdrop({ ticketHeight: this.ticketHeight(), tearY: this.ticketHeight() - TEAM_ROLE_ACTION_HEIGHT,
        fill: captain ? CORAL : '#FFFFFF', halftone: captain ? 'captain' : 'member' })
      Column() {
        Column({ space: 5 }) {
          Text(captain ? '我是队长' : '我是队员').fontSize(13).fontWeight(900).fontColor(INK)
            .padding({ left: 12, right: 12, top: 3, bottom: 3 }).height(25)
            .backgroundColor(captain ? PAPER : LILAC)
            .border({ width: 1.4, color: INK })
            .borderRadius(4)
            .rotate({ angle: captain ? -2 : 2 })
            .shadow(CONTROL_SHADOW)
          Text(captain ? '创建队伍' : '加入队伍').fontSize(29).minFontSize(21).maxFontSize(29)
            .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).maxLines(1).width('100%').height(36)
            .textAlign(TextAlign.Center)
          Text(captain ? '选角色 · 定节拍' : '扫码或输入加入码').fontSize(11).minFontSize(9).maxFontSize(11)
            .fontWeight(FontWeight.Bold).fontColor(INK).width('100%').maxLines(1).textAlign(TextAlign.Center)
        }.width('100%').height(TEAM_ROLE_TEXT_HEIGHT).padding({ left: 8, right: 8, top: 11 })
        this.roleArtwork(captain)
        Column() {
          Row({ space: 9 }) {
            Text(captain ? '开始创建' : '选择加入').fontSize(19).minFontSize(16).maxFontSize(19)
              .fontWeight(900).fontColor(INK).maxLines(1)
            Text('›').fontSize(27).fontWeight(900).fontColor(INK)
          }.width('100%').height(40).justifyContent(FlexAlign.Center).backgroundColor(captain ? PAPER : LILAC)
            .border({ width: 1.5, color: INK }).borderRadius(8).shadow(CONTROL_SHADOW)
        }.width('100%').height(TEAM_ROLE_ACTION_HEIGHT).padding({ left: 10, right: 10, top: 10, bottom: 12 })
      }.width('100%').height(this.ticketHeight()).hitTestBehavior(HitTestMode.None)
    }.height(this.ticketHeight()).layoutWeight(1).clip(false).focusable(true)
      .accessibilityGroup(true).accessibilityText(captain ? '我是队长，创建队伍' : '我是队员，加入队伍')
      // One target per ticket prevents the lower CTA and card from dispatching the same route twice.
      .onClick(() => { if (captain) { void this.createTeam(); } else { this.joinTeam(); } })
  }

  build() {
    Scroll() {
      Column() {
        Row({ space: 2 }) {
          Text('‹').fontSize(32).fontColor(INK).width(32).height(TEAM_HEADER_HEIGHT)
            .accessibilityText('返回首页').onClick(() => { void navigateToHome(); })
          Text('多人练习').fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        }.width('100%').height(TEAM_HEADER_HEIGHT)
        this.slogan()
        this.nicknameCard()
        Row({ space: TEAM_TICKET_GAP }) {
          this.roleTicket(true)
          this.roleTicket(false)
        }.width('100%').height(this.ticketHeight()).margin({ top: TEAM_NICKNAME_BOTTOM_GAP })
        TeamWifiFooter().margin({ top: TEAM_FOOTER_TOP_GAP })
      }.width('100%').padding({ left: TEAM_PAGE_SIDE_INSET, right: TEAM_PAGE_SIDE_INSET,
        top: TEAM_PAGE_TOP_INSET + this.topSafeInset, bottom: TEAM_PAGE_BOTTOM_INSET + this.bottomSafeInset })
    }.width('100%').height('100%').backgroundColor(PAPER)
      .onAreaChange((_old: Area, area: Area) => {
        const height = Number(area.height);
        const width = Number(area.width) - TEAM_PAGE_SIDE_INSET * 2;
        if (height > 0 && Math.abs(height - this.viewportHeight) > 0.1) { this.viewportHeight = height; }
        if (width > 0 && Math.abs(width - this.contentWidth) > 0.1) { this.contentWidth = width; }
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
