import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, TEAL, CARD_SHADOW, CONTROL_SHADOW, INK_SHADOW_RADIUS } from '../components/ComicKit';

const PLAYER_DISPLAY_NAME_KEY: string = 'playerDisplayName';
const TEAM_HERO_HEIGHT: number = 190;
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

  private createTeam(): void {
    const displayName = this.validatedDisplayName();
    if (displayName.length === 0) {
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

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row() {
          Text('‹')
            .fontSize(32)
            .width(32)
            .onClick(() => router.back())
          Column({ space: 0 }) {
            Text('多人练习')
              .fontSize(32)
              .fontWeight(900)
              .fontStyle(FontStyle.Italic)
              .width('100%')
            Text('TEAM UP. KEEP THE BEAT.')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(1)
              .width('100%')
          }.layoutWeight(1)
          Text('组队')
            .fontSize(12)
            .fontWeight(900)
            .backgroundColor(LILAC)
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .border({ width: 1, color: INK })
            .borderRadius(4).shadow(CONTROL_SHADOW)
            .rotate({ angle: 3 })
        }.width('100%')

        Stack({ alignContent: Alignment.Bottom }) {
          Image($rawfile('comic/decor/team_beat_collage.png'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .hitTestBehavior(HitTestMode.None)
          Row({ space: -58 }) {
            ComicCharacter({ avatar: 'mismatch', pose: 'mismatch' })
              .width('52%')
              .height(TEAM_HERO_HEIGHT)
              .translate({ x: 53 })
              .rotate({ angle: -7 })
            ComicCharacter({ avatar: 'wave', pose: 'wave' })
              .width('52%')
              .height(TEAM_HERO_HEIGHT)
              .scale({ x: 0.85, y: 0.85, centerX: '50%', centerY: '100%' })
              .translate({ x: -53 })
              .rotate({ angle: 7 })
          }.width('100%').justifyContent(FlexAlign.Center)
          Text('一个节拍，一起出发！')
            .fontSize(14)
            .fontWeight(900)
            .fontStyle(FontStyle.Italic)
            .backgroundColor(PAPER)
            .border({ width: 1.5, color: INK })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .margin({ bottom: 5 })
            .rotate({ angle: -2 })
        }
        .width('100%')
        .height(TEAM_HERO_HEIGHT)
        .clip(true)

        Column({ space: 6 }) {
          Text('你的昵称')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .width('100%')
          if (this.showNicknameHint) {
            Row() {
              Blank()
              Stack({ alignContent: Alignment.TopStart }) {
                // SVG viewBox keeps the body, pointer, and hard shadow in one
                // density-independent outline on both phone and preview runtimes.
                Image($rawfile('comic/decor/nickname_hint_bubble.svg'))
                  .width(NICKNAME_HINT_WIDTH)
                  .height(NICKNAME_HINT_HEIGHT)
                  .objectFit(ImageFit.Fill)
                  .hitTestBehavior(HitTestMode.None)
                Text('先给自己起个名字！\n不想费脑筋？点这里')
                  .width(NICKNAME_HINT_WIDTH - 24)
                  .height(NICKNAME_HINT_BODY_HEIGHT - 16)
                  .fontSize(12)
                  .fontWeight(900)
                  .lineHeight(17)
                  .fontColor(INK)
                  .position({ x: 12, y: 9 })
              }
              .width(NICKNAME_HINT_WIDTH)
              .height(NICKNAME_HINT_HEIGHT)
              .rotate({ angle: -2 })
              .scale({ x: this.nicknameHintScale, y: this.nicknameHintScale })
              .opacity(this.nicknameHintOpacity)
            }.width('100%')
          }
          Row({ space: 8 }) {
            TextInput({ text: this.displayName, placeholder: '输入昵称' })
              .maxLength(16)
              .height(42)
              .layoutWeight(1)
              .backgroundColor('#F1EBDF')
              .border({ width: 1, color: INK })
              .borderRadius(5).shadow(CONTROL_SHADOW)
              .onChange((value: string) => {
                this.displayName = value;
                if (value.trim().length > 0) {
                  this.showNicknameHint = false;
                }
                AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, value.trim());
              })
            Button('叫啥都行', { type: ButtonType.Normal })
              .width(92)
              .height(42)
              .fontSize(13)
              .fontWeight(900)
              .fontColor(INK)
              .backgroundColor(TEAL)
              .border({ width: 1.5, color: INK })
              .borderRadius(5)
              .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 2, offsetY: 2, color: INK })
              .onClick(() => this.fillRandomNickname())
          }.width('100%')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 11 })
        .backgroundColor('#FFFDF7')
        .border({ width: 1.5, color: INK })
        .borderRadius(7).shadow(CARD_SHADOW)

        Row() {
          Text('选择你的身份')
            .fontSize(19)
            .fontWeight(900)
            .fontStyle(FontStyle.Italic)
          Blank()
          Text('1 / 2')
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor('#66615A')
        }.width('100%')

        Stack({ alignContent: Alignment.BottomEnd }) {
          Image($rawfile('comic/decor/lightning_accents.png'))
            .width(130)
            .height(104)
            .objectFit(ImageFit.Contain)
            .opacity(0.72)
            .margin({ right: 8, bottom: 56 })
            .rotate({ angle: -8 })
            .hitTestBehavior(HitTestMode.None)
          Column({ space: 7 }) {
            Text('我是队长')
              .fontSize(11)
              .fontWeight(900)
              .backgroundColor(PAPER)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .border({ width: 1, color: INK })
              .borderRadius(3).shadow(CONTROL_SHADOW)
              .rotate({ angle: -2 })
            Text('创建队伍')
              .fontSize(28)
              .fontWeight(900)
              .fontStyle(FontStyle.Italic)
              .width('100%')
            Text('直接进入队长创建页')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .width('100%')
            Text('设置角色、节拍、BPM 和行进场景')
              .fontSize(11)
              .fontColor('#4B302B')
              .width('100%')
            Text('开始创建  ›')
              .fontSize(14)
              .fontWeight(900)
              .width('100%')
              .margin({ top: 5 })
          }
          .width('100%')
          .padding({ left: 16, right: 106, top: 14, bottom: 14 })
          ComicCharacter({ avatar: 'lamp', pose: 'lamp' })
            .width(94)
            .height(94)
            .margin({ right: 6, bottom: 7 })
            .rotate({ angle: 4 })
        }
        .width('100%')
        .height(168)
        .backgroundColor(CORAL)
        .border({ width: 2, color: INK })
        .borderRadius(8)
        .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 4, color: INK })
        .clip(true)
        .onClick(() => this.createTeam())

        Stack({ alignContent: Alignment.BottomEnd }) {
          Image($rawfile('comic/decor/lightning_accents.png'))
            .width(138)
            .height(110)
            .objectFit(ImageFit.Contain)
            .opacity(0.68)
            .scale({ x: -1, y: 1 })
            .margin({ right: 4, bottom: 64 })
            .rotate({ angle: 8 })
            .hitTestBehavior(HitTestMode.None)
          Column({ space: 7 }) {
            Text('我是队员')
              .fontSize(11)
              .fontWeight(900)
              .backgroundColor(PAPER)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .border({ width: 1, color: INK })
              .borderRadius(3).shadow(CONTROL_SHADOW)
              .rotate({ angle: 2 })
            Text('加入队伍')
              .fontSize(28)
              .fontWeight(900)
              .fontStyle(FontStyle.Italic)
              .width('100%')
            Text('跟着队长的邀请进入')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .width('100%')
            Row({ space: 6 }) {
              Text('扫码')
                .fontSize(11)
                .fontWeight(900)
                .backgroundColor(TEAL)
                .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                .border({ width: 1, color: INK })
                .borderRadius(3).shadow(CONTROL_SHADOW)
              Text('6 位 CODE')
                .fontSize(11)
                .fontWeight(900)
                .backgroundColor(PAPER)
                .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                .border({ width: 1, color: INK })
                .borderRadius(3).shadow(CONTROL_SHADOW)
            }.width('100%')
            Text('选择加入方式  ›')
              .fontSize(14)
              .fontWeight(900)
              .width('100%')
              .margin({ top: 3 })
          }
          .width('100%')
          .padding({ left: 16, right: 106, top: 14, bottom: 14 })
          ComicCharacter({ avatar: 'cloud', pose: 'cloud-phone' })
            .width(94)
            .height(94)
            .margin({ right: 6, bottom: 7 })
            .rotate({ angle: -4 })
        }
        .width('100%')
        .height(176)
        .backgroundColor(LILAC)
        .border({ width: 2, color: INK })
        .borderRadius(8)
        .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 3, offsetY: 4, color: INK })
        .clip(true)
        .onClick(() => this.joinTeam())

        Text('请先打开系统 Wi-Fi；手输加入码还需打开蓝牙。扫码加入建议保持蓝牙开启。')
          .fontSize(11)
          .fontColor('#66615A')
          .lineHeight(17)
          .width('100%')
          .padding({ left: 4, right: 4, top: 4 })
      }
      .width('100%')
      .padding({
        left: 18,
        right: 18,
        top: 12 + this.topSafeInset,
        bottom: 28 + this.bottomSafeInset
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
