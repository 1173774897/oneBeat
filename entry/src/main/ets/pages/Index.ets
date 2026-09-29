import { router } from '@kit.ArkUI';
import { ComicButton, ComicCharacter, PAPER, LILAC, TEAL } from '../components/ComicKit';

@Entry
@Component
struct Index {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;

  private goSolo(): void {
    router.pushUrl({
      url: 'pages/LeaderLobbyPage',
      params: { displayName: '我', solo: '1' }
    });
  }

  private goTeam(): void {
    router.pushUrl({ url: 'pages/TeamPage' });
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Image($rawfile('comic/brand/onebeat_wordmark.png')).width(190).height(100).objectFit(ImageFit.Contain)
          Blank()
          Text('不同的人\n相同的节拍\n更有趣的世界').fontSize(12).fontWeight(FontWeight.Bold).lineHeight(18)
        }.width('100%')
        Stack() {
          Image($rawfile('comic/decor/entry_burst.png')).width('100%').height('100%').objectFit(ImageFit.Fill)
          Row({ space: -30 }) {
            ComicCharacter({ avatar: 'teapot' }).width('53%').height(240).rotate({ angle: -8 })
            ComicCharacter({ avatar: 'cloud' }).width('53%').height(240).rotate({ angle: 8 })
          }.width('100%')
          Text('GOOD PEOPLE. SAME BEAT!').fontSize(12).fontWeight(900)
            .backgroundColor(PAPER).padding(5).align(Alignment.BottomEnd)
        }.width('100%').height(245).clip(true)
        ComicButton({ label: '多人练习', action: () => this.goTeam() })
        ComicButton({ label: '单人练习', fill: TEAL, action: () => this.goSolo() })
        ComicButton({ label: '收藏小铺', fill: LILAC, action: () => {
          router.pushUrl({ url: 'pages/StorePage' });
        } })
        Row() {
          Blank()
          Text('隐私声明').fontSize(12).fontColor('#66615A').decoration({ type: TextDecorationType.Underline })
            .onClick(() => {
              router.pushUrl({ url: 'pages/PrivacyPage' });
            })
        }.width('100%')
        Text('RHYTHM CONNECTS DIFFERENT PEOPLE.').fontSize(10).fontWeight(FontWeight.Bold).letterSpacing(1)
      }.width('100%').padding({
        left: 20,
        right: 20,
        top: 12 + this.topSafeInset,
        bottom: 30 + this.bottomSafeInset
      })
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
