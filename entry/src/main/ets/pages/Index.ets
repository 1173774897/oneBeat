import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, WHITE } from '../components/ComicKit';
import { RecordingRepository } from '../recording/RecordingRepository';
import { RecordingScope } from '../recording/RecordingModels';
import { ensureStoreBootstrapReady } from '../store/StoreBootstrapSync';

type HomeEntryKind = RecordingScope | 'store';

const HOME_ENTRY_RADIUS: number = 14;
const HOME_ENTRY_BORDER: number = 2;
const HOME_ENTRY_SHADOW_X: number = 4;
const HOME_ENTRY_SHADOW_Y: number = 5;
const HOME_ENTRANCE_GAP: number = 12;
const HOME_TEAM_ENTRY_WEIGHT: number = 56;
const HOME_SOLO_ENTRY_WEIGHT: number = 44;
const HOME_PRACTICE_HEIGHT: number = 138;
const HOME_WORKS_PILL_WIDTH: number = 80;
const HOME_WORKS_PILL_HEIGHT: number = 32;
const HOME_WORKS_PILL_INSET_LEFT: number = 12;
const HOME_WORKS_PILL_INSET_BOTTOM: number = 11;
const HOME_PRACTICE_TITLE_SIZE: number = 20;
const HOME_PRACTICE_SOLO_TITLE_SIZE: number = 20;
const HOME_PRACTICE_TEXT_TOP_INSET: number = 14;
const HOME_PRACTICE_TEXT_LEFT_INSET: number = 14;
const HOME_PRACTICE_TEXT_RIGHT_INSET: number = 14;
const HOME_PRACTICE_ART_RIGHT_INSET: number = 6;
const HOME_PRACTICE_ART_BOTTOM_INSET: number = 3;
/** Extra bottom inset for the team art row so trees stay inside the 138vp card. */
const HOME_TEAM_ART_BOTTOM_INSET: number = 10;
const HOME_PRACTICE_SOLO_ART_ROW_HEIGHT: number = 46;
const HOME_STORE_HEIGHT: number = 64;
const HOME_STORE_ACTION_WIDTH: number = 96;
const HOME_TEAM_ART_WIDTH: number = 109;
const HOME_TEAM_ART_HEIGHT: number = 92;
const HOME_TEAM_TREE_HEIGHT: number = 86;
const HOME_TEAM_PLANT_06_WIDTH: number = 52;
const HOME_TEAM_PLANT_06_HEIGHT: number = 31;
const HOME_TEAM_PLANT_08_WIDTH: number = 30;
const HOME_TEAM_PLANT_08_HEIGHT: number = 34;
const HOME_TEAM_PLANT_ROW_INSET_LEFT: number = 0;
const HOME_TEAM_PLANT_ROW_INSET_RIGHT: number = 2;
const HOME_SOLO_ART_WIDTH: number = 58;
const HOME_SOLO_SIGN_HEIGHT: number = 90;

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
      Row() {
        Image($rawfile('vegetation/plant_06.png'))
          .width(HOME_TEAM_PLANT_06_WIDTH).height(HOME_TEAM_PLANT_06_HEIGHT).objectFit(ImageFit.Contain)
        Blank().layoutWeight(1)
        Image($rawfile('vegetation/plant_08.png'))
          .width(HOME_TEAM_PLANT_08_WIDTH).height(HOME_TEAM_PLANT_08_HEIGHT).objectFit(ImageFit.Contain)
      }.width('100%').alignItems(VerticalAlign.Bottom)
        .padding({
          left: HOME_TEAM_PLANT_ROW_INSET_LEFT,
          right: HOME_TEAM_PLANT_ROW_INSET_RIGHT
        })
    }.width(HOME_TEAM_ART_WIDTH).height(HOME_TEAM_ART_HEIGHT).hitTestBehavior(HitTestMode.None)
  }

  private practiceArtBottomInset(kind: RecordingScope): number {
    return kind === 'team' ? HOME_TEAM_ART_BOTTOM_INSET : HOME_PRACTICE_ART_BOTTOM_INSET;
  }

  @Builder
  private practiceEntryArtwork(kind: RecordingScope) {
    if (kind === 'team') {
      this.teamEntryArtwork()
    } else {
      this.soloEntryArtwork()
    }
  }

  @Builder
  private soloEntryArtwork() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image($rawfile('scenes/sunset/entities/sign.png'))
        .height(HOME_SOLO_SIGN_HEIGHT).objectFit(ImageFit.Contain).align(Alignment.Bottom)
    }.width(HOME_SOLO_ART_WIDTH).height(HOME_PRACTICE_SOLO_ART_ROW_HEIGHT).hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private practiceEntryPanel(kind: RecordingScope, title: string, subtitle: string, fill: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(HOME_PRACTICE_HEIGHT).backgroundColor(INK).borderRadius(HOME_ENTRY_RADIUS)
        .translate({ x: HOME_ENTRY_SHADOW_X, y: HOME_ENTRY_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      // Practice and works remain sibling controls so a works tap cannot start a session.
      Stack({ alignContent: Alignment.TopStart }) {
        Button({ type: ButtonType.Normal }) {
          // Title and scene art are separate layers; overlap matches the comic reference layout.
          Stack({ alignContent: Alignment.TopStart }) {
            Row() {
              Blank().layoutWeight(1)
              this.practiceEntryArtwork(kind)
            }.width('100%').height('100%').alignItems(VerticalAlign.Bottom)
              .padding({
                right: HOME_PRACTICE_ART_RIGHT_INSET,
                bottom: this.practiceArtBottomInset(kind)
              })
              .hitTestBehavior(HitTestMode.None)
            Column({ space: 3 }) {
              Text(title).fontSize(kind === 'solo' ? HOME_PRACTICE_SOLO_TITLE_SIZE : HOME_PRACTICE_TITLE_SIZE)
                .fontWeight(900).fontColor(INK).width('100%').maxLines(1).lineHeight(24)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(subtitle).fontSize(10).fontWeight(FontWeight.Bold).fontColor(INK)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').lineHeight(14)
            }.width('100%').alignItems(HorizontalAlign.Start).align(Alignment.TopStart).zIndex(1)
              .padding({
                left: HOME_PRACTICE_TEXT_LEFT_INSET, right: HOME_PRACTICE_TEXT_RIGHT_INSET,
                top: HOME_PRACTICE_TEXT_TOP_INSET
              })
          }.width('100%').height('100%').clip(true)
        }.width('100%').height(HOME_PRACTICE_HEIGHT).padding(0).backgroundColor(fill)
          .border({ width: HOME_ENTRY_BORDER, color: INK }).borderRadius(HOME_ENTRY_RADIUS).clip(true)
          .onClick(() => this.goPrimary(kind)).accessibilityText(this.practiceAccessibility(kind, title))
        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            Text(`作品 ${this.worksCount(kind)}`).fontSize(12).fontWeight(900).fontColor(INK)
            Blank()
            Text('›').fontSize(18).fontWeight(900).fontColor(INK)
          }.width('100%')
        }.width(HOME_WORKS_PILL_WIDTH).height(HOME_WORKS_PILL_HEIGHT)
          .padding({ left: 10, right: 8 }).backgroundColor(WHITE)
          .border({ width: HOME_ENTRY_BORDER, color: INK }).borderRadius(HOME_WORKS_PILL_HEIGHT / 2)
          .position({
            x: HOME_WORKS_PILL_INSET_LEFT,
            y: HOME_PRACTICE_HEIGHT - HOME_WORKS_PILL_HEIGHT - HOME_WORKS_PILL_INSET_BOTTOM
          })
          .zIndex(2)
          .onClick(() => this.goSecondary(kind)).accessibilityText(this.worksAccessibility(kind))
      }.width('100%').height(HOME_PRACTICE_HEIGHT).clip(false)
    }.layoutWeight(kind === 'team' ? HOME_TEAM_ENTRY_WEIGHT : HOME_SOLO_ENTRY_WEIGHT)
      .height(HOME_PRACTICE_HEIGHT).clip(false)
  }

  @Builder
  private storeEntryPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(HOME_STORE_HEIGHT).backgroundColor(INK).borderRadius(HOME_ENTRY_RADIUS)
        .translate({ x: HOME_ENTRY_SHADOW_X, y: HOME_ENTRY_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Row({ space: 8 }) {
            Text('收藏小铺').fontSize(19).fontWeight(900).fontColor(INK)
            Text('角色 / 场景 / 鼓机').fontSize(10).fontWeight(FontWeight.Bold).fontColor(INK)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.layoutWeight(1).alignItems(VerticalAlign.Center)
          Row({ space: 4 }) {
            Text('去逛逛').fontSize(13).fontWeight(900).fontColor(INK)
            Text('›').fontSize(18).fontWeight(900).fontColor(INK)
          }.width(HOME_STORE_ACTION_WIDTH).height(HOME_WORKS_PILL_HEIGHT).justifyContent(FlexAlign.Center)
            .padding({ left: 10, right: 6 }).backgroundColor(WHITE)
            .border({ width: HOME_ENTRY_BORDER, color: INK }).borderRadius(HOME_WORKS_PILL_HEIGHT / 2)
        }.width('100%').alignItems(VerticalAlign.Center)
      }.width('100%').height(HOME_STORE_HEIGHT)
        .padding({ left: 16, right: 14 }).backgroundColor(LILAC)
        .border({ width: HOME_ENTRY_BORDER, color: INK }).borderRadius(HOME_ENTRY_RADIUS)
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
        Column({ space: HOME_ENTRANCE_GAP }) {
          Row({ space: HOME_ENTRANCE_GAP }) {
            this.practiceEntryPanel('team', '多人练习', '组队同行 · 同拍出发', CORAL)
            this.practiceEntryPanel('solo', '单人练习', '跟着节奏 · 找到步调', WHITE)
          }.width('100%').height(HOME_PRACTICE_HEIGHT)
          this.storeEntryPanel()
        }.width('100%')
        Row() {
          Text('隐私声明  ALL RIGHTS RESERVED').fontSize(10).fontWeight(FontWeight.Medium).fontColor('#66615A')
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => {
              router.pushUrl({ url: 'pages/PrivacyPage' });
            })
          Blank()
          Text('SAME BEAT!').fontSize(12).fontWeight(900).fontColor(INK).letterSpacing(0.5)
        }.width('100%').alignItems(VerticalAlign.Center)
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
