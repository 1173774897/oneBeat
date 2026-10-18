import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, WHITE } from '../components/ComicKit';
import { RecordingRepository } from '../recording/RecordingRepository';
import { RecordingScope } from '../recording/RecordingModels';
import { ensureStoreBootstrapReady } from '../store/StoreBootstrapSync';

type HomeEntryKind = RecordingScope | 'store';

const HOME_ENTRY_RADIUS: number = 9;
const HOME_ENTRY_SHADOW_X: number = 3;
const HOME_ENTRY_SHADOW_Y: number = 4;
const HOME_PRACTICE_GAP: number = 12;
const HOME_PRACTICE_HEIGHT: number = 214;
const HOME_PRACTICE_FOOTER_HEIGHT: number = 46;
const HOME_PRACTICE_ART_HEIGHT: number = 88;
const HOME_STORE_HEIGHT: number = 98;
const HOME_TEAM_TREE_HEIGHT: number = 84;
const HOME_TEAM_PLANT_06_WIDTH: number = 78;
const HOME_TEAM_PLANT_08_WIDTH: number = 48;
const HOME_SOLO_SIGN_HEIGHT: number = 78;

@Entry
@Component
struct Index {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('recordingLibraryEpoch') @Watch('refreshWorks') libraryEpoch: number = 0;
  @State teamWorksCount: number = 0;
  @State soloWorksCount: number = 0;

  aboutToAppear(): void {
    void ensureStoreBootstrapReady();
    this.refreshWorks();
  }

  onPageShow(): void { this.refreshWorks(); }

  refreshWorks(): void {
    const teamClips = RecordingRepository.list('team');
    const soloClips = RecordingRepository.list('solo');
    this.teamWorksCount = teamClips.length;
    this.soloWorksCount = soloClips.length;
  }

  private goSolo(): void {
    router.pushUrl({
      url: 'pages/LeaderLobbyPage',
      params: { displayName: '我', solo: '1' }
    });
  }

  private goTeam(): void {
    router.pushUrl({ url: 'pages/TeamPage' });
  }

  private goPrimary(kind: HomeEntryKind): void {
    if (kind === 'store') { router.pushUrl({ url: 'pages/StorePage' }); }
    else if (kind === 'team') { this.goTeam(); }
    else { this.goSolo(); }
  }

  private goSecondary(kind: HomeEntryKind): void {
    if (kind === 'store') { this.goPrimary(kind); return; }
    router.pushUrl({ url: 'pages/RecordingLibraryPage', params: { scope: kind } });
  }

  private worksCount(kind: RecordingScope): number {
    return kind === 'team' ? this.teamWorksCount : this.soloWorksCount;
  }

  private practiceAccessibility(kind: RecordingScope, title: string): string {
    return `${title}，${kind === 'team' ? '组队同行，同拍出发' : '跟着节奏，找到步调'}`;
  }

  private worksAccessibility(kind: RecordingScope): string {
    return `${kind === 'team' ? '多人' : '单人'}练习作品，${this.worksCount(kind)}段，查看作品`;
  }

  @Builder
  private teamEntryArtwork() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image($rawfile('scenes/sunset/entities/tree.png'))
        .height(HOME_TEAM_TREE_HEIGHT).objectFit(ImageFit.Contain).align(Alignment.Bottom)
      Image($rawfile('vegetation/plant_06.png'))
        .width(HOME_TEAM_PLANT_06_WIDTH).height(38).objectFit(ImageFit.Contain)
        .align(Alignment.BottomStart).translate({ x: -2, y: 3 })
      Image($rawfile('vegetation/plant_08.png'))
        .width(HOME_TEAM_PLANT_08_WIDTH).height(43).objectFit(ImageFit.Contain)
        .align(Alignment.BottomEnd).translate({ x: -1, y: 3 })
    }.width('100%').height(HOME_PRACTICE_ART_HEIGHT).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private soloEntryArtwork() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image($rawfile('scenes/sunset/entities/sign.png'))
        .height(HOME_SOLO_SIGN_HEIGHT).objectFit(ImageFit.Contain).align(Alignment.Bottom)
    }.width('100%').height(HOME_PRACTICE_ART_HEIGHT).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private practiceEntryPanel(kind: RecordingScope, title: string, subtitle: string, fill: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(HOME_PRACTICE_HEIGHT).backgroundColor(INK).borderRadius(HOME_ENTRY_RADIUS)
        .translate({ x: HOME_ENTRY_SHADOW_X, y: HOME_ENTRY_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      // Practice and works remain sibling controls so a works tap cannot start a session.
      Column() {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 3 }) {
            Text(title).fontSize(21).fontWeight(900).fontColor(INK).width('100%')
            Text(subtitle).fontSize(10).fontWeight(FontWeight.Bold).fontColor(INK)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            if (kind === 'team') {
              this.teamEntryArtwork()
            } else {
              this.soloEntryArtwork()
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').height(HOME_PRACTICE_HEIGHT - HOME_PRACTICE_FOOTER_HEIGHT)
          .padding({ left: 12, right: 12, top: 13, bottom: 5 })
          .backgroundColor(Color.Transparent).borderRadius(HOME_ENTRY_RADIUS)
          .onClick(() => this.goPrimary(kind))
          .accessibilityText(this.practiceAccessibility(kind, title))
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(`作品 ${this.worksCount(kind)}`).fontSize(15).fontWeight(900).fontColor(INK)
            Blank()
            Text('›').fontSize(22).fontWeight(900).fontColor(INK)
          }.width('100%')
        }.width('100%').height(HOME_PRACTICE_FOOTER_HEIGHT)
          .padding({ left: 14, right: 14 }).backgroundColor(Color.Transparent).borderRadius(0)
          .border({ width: { top: 1.2 }, color: INK })
          .onClick(() => this.goSecondary(kind)).accessibilityText(this.worksAccessibility(kind))
      }.width('100%').height(HOME_PRACTICE_HEIGHT).backgroundColor(fill)
        .border({ width: 1.2, color: INK }).borderRadius(HOME_ENTRY_RADIUS)
    }.layoutWeight(1).height(HOME_PRACTICE_HEIGHT).clip(false)
  }

  @Builder
  private storeEntryPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(HOME_STORE_HEIGHT).backgroundColor(INK).borderRadius(HOME_ENTRY_RADIUS)
        .translate({ x: HOME_ENTRY_SHADOW_X, y: HOME_ENTRY_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Column({ space: 5 }) {
            Text('收藏小铺').fontSize(22).fontWeight(900).fontColor(INK).width('100%')
            Text('角色 · 场景 · 鼓机').fontSize(12).fontWeight(FontWeight.Bold).fontColor(INK).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('去逛逛').fontSize(15).fontWeight(900).fontColor(INK)
          Text('›').fontSize(24).fontWeight(900).fontColor(INK)
        }.width('100%')
      }.width('100%').height(HOME_STORE_HEIGHT)
        .padding({ left: 16, right: 14 }).backgroundColor(LILAC)
        .border({ width: 1.2, color: INK }).borderRadius(HOME_ENTRY_RADIUS)
        .onClick(() => this.goPrimary('store')).accessibilityText('进入收藏小铺，角色、场景、鼓机')
    }.width('100%').height(HOME_STORE_HEIGHT).clip(false)
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
          Image($rawfile('comic/decor/lightning_accents.png'))
            .width(224)
            .height(179)
            .objectFit(ImageFit.Contain)
            .opacity(0.88)
            .translate({ y: 8 })
            .rotate({ angle: -4 })
            .hitTestBehavior(HitTestMode.None)
          Row({ space: -30 }) {
            ComicCharacter({ avatar: 'teapot' }).width('53%').height(240).rotate({ angle: -8 })
            ComicCharacter({ avatar: 'cloud' }).width('53%').height(240).rotate({ angle: 8 })
          }.width('100%')
          Text('GOOD PEOPLE. SAME BEAT!').fontSize(12).fontWeight(900)
            .backgroundColor(PAPER).padding(5).align(Alignment.BottomEnd)
        }.width('100%').height(245).clip(true)
        Row({ space: HOME_PRACTICE_GAP }) {
          this.practiceEntryPanel('team', '多人练习', '组队同行 · 同拍出发', CORAL)
          this.practiceEntryPanel('solo', '单人练习', '跟着节奏 · 找到步调', WHITE)
        }.width('100%').height(HOME_PRACTICE_HEIGHT)
        this.storeEntryPanel()
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
