import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, TEAL } from '../components/ComicKit';

const PLAYER_DISPLAY_NAME_KEY: string = 'playerDisplayName';

@Entry
@Component
struct TeamPage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @State displayName: string = '';
  @State showNicknameHint: boolean = false;
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
      return '';
    }
    this.showNicknameHint = false;
    AppStorage.setOrCreate(PLAYER_DISPLAY_NAME_KEY, trimmed);
    return trimmed;
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
            .borderRadius(4)
            .rotate({ angle: 3 })
        }.width('100%')

        Stack({ alignContent: Alignment.Bottom }) {
          Image($rawfile('comic/decor/entry_burst.png'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
          Row({ space: -28 }) {
            ComicCharacter({ avatar: 'mismatch' })
              .width('52%')
              .height(190)
              .rotate({ angle: -7 })
            ComicCharacter({ avatar: 'wave' })
              .width('52%')
              .height(190)
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
        .height(190)
        .clip(true)

        Column({ space: 6 }) {
          Text('你的昵称')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .width('100%')
          if (this.showNicknameHint) {
            Row() {
              Blank()
              Column({ space: -7 }) {
                Text('先给自己起个名字！\n不想费脑筋？点这里')
                  .width(178)
                  .fontSize(12)
                  .fontWeight(900)
                  .lineHeight(17)
                  .fontColor(INK)
                  .backgroundColor(CORAL)
                  .padding({ left: 11, right: 11, top: 8, bottom: 8 })
                  .border({ width: 1.5, color: INK })
                  .borderRadius(7)
                  .shadow({ radius: 0, offsetX: 2, offsetY: 3, color: INK })
                  .rotate({ angle: -2 })
                Stack() {
                  Text('▼').fontSize(25).fontColor(INK)
                  Text('▼').fontSize(19).fontColor(CORAL).margin({ top: -1 })
                }
                .width(28)
                .height(22)
                .margin({ right: 29 })
                .alignSelf(ItemAlign.End)
              }
            }.width('100%')
          }
          Row({ space: 8 }) {
            TextInput({ text: this.displayName, placeholder: '输入昵称' })
              .maxLength(16)
              .height(42)
              .layoutWeight(1)
              .backgroundColor('#F1EBDF')
              .border({ width: 1, color: INK })
              .borderRadius(5)
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
              .shadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
              .onClick(() => this.fillRandomNickname())
          }.width('100%')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 11 })
        .backgroundColor('#FFFDF7')
        .border({ width: 1.5, color: INK })
        .borderRadius(7)

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
          Column({ space: 7 }) {
            Text('我是队长')
              .fontSize(11)
              .fontWeight(900)
              .backgroundColor(PAPER)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .border({ width: 1, color: INK })
              .borderRadius(3)
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
          ComicCharacter({ avatar: 'teapot', portrait: true })
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
        .shadow({ radius: 0, offsetX: 3, offsetY: 4, color: INK })
        .clip(true)
        .onClick(() => this.createTeam())

        Stack({ alignContent: Alignment.BottomEnd }) {
          Column({ space: 7 }) {
            Text('我是队员')
              .fontSize(11)
              .fontWeight(900)
              .backgroundColor(PAPER)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .border({ width: 1, color: INK })
              .borderRadius(3)
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
                .borderRadius(3)
              Text('6 位 CODE')
                .fontSize(11)
                .fontWeight(900)
                .backgroundColor(PAPER)
                .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                .border({ width: 1, color: INK })
                .borderRadius(3)
            }.width('100%')
            Text('选择加入方式  ›')
              .fontSize(14)
              .fontWeight(900)
              .width('100%')
              .margin({ top: 3 })
          }
          .width('100%')
          .padding({ left: 16, right: 106, top: 14, bottom: 14 })
          ComicCharacter({ avatar: 'cloud', portrait: true })
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
        .shadow({ radius: 0, offsetX: 3, offsetY: 4, color: INK })
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
