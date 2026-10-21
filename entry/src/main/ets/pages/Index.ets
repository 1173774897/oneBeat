import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, CORAL, LILAC, WHITE, CONTROL_SHADOW } from '../components/ComicKit';
import { RecordingRepository } from '../recording/RecordingRepository';
import { RecordingScope } from '../recording/RecordingModels';
import { ensureStoreBootstrapReady } from '../store/StoreBootstrapSync';
import { AppSession } from '../app/AppSession';
import { RecordingCoordinator } from '../recording/RecordingCoordinator';
import { showUserNotice } from '../common/UserFeedback';

type HomeEntryKind = RecordingScope | 'store';

const HOME_ENTRY_RADIUS: number = 8;
const HOME_ENTRY_BORDER: number = 2;
const HOME_ENTRY_SHADOW_X: number = 4;
const HOME_ENTRY_SHADOW_Y: number = 5;
const HOME_ENTRANCE_GAP: number = 10;
const HOME_PRACTICE_PAIR_GAP: number = 8;
const HOME_TEAM_ENTRY_WEIGHT: number = 56;
const HOME_SOLO_ENTRY_WEIGHT: number = 44;
const HOME_PRACTICE_HEIGHT: number = 138;
const HOME_WORKS_PILL_WIDTH: number = 80;
const HOME_WORKS_PILL_HEIGHT: number = 32;
const HOME_WORKS_PILL_INSET_LEFT: number = 12;
const HOME_WORKS_PILL_INSET_BOTTOM: number = 11;
const HOME_WORKS_PILL_BORDER_WIDTH: number = 1.4;
const HOME_PRACTICE_TITLE_SIZE: number = 20;
const HOME_PRACTICE_SOLO_TITLE_SIZE: number = 20;
const HOME_PRACTICE_TEXT_TOP_INSET: number = 14;
const HOME_PRACTICE_TEXT_LEFT_INSET: number = 14;
const HOME_PRACTICE_TEXT_RIGHT_INSET: number = 14;
const HOME_PRACTICE_ART_RIGHT_INSET: number = 6;
const HOME_PRACTICE_ART_BOTTOM_INSET: number = 10;
/** Extra bottom inset for the team art row so trees stay inside the 138vp card. */
const HOME_TEAM_ART_BOTTOM_INSET: number = 10;
const HOME_STORE_HEIGHT: number = 64;
const HOME_TEAM_ART_WIDTH: number = 121;
const HOME_TEAM_ART_HEIGHT: number = 92;
const HOME_TEAM_PLANT_09_WIDTH: number = 42;
const HOME_TEAM_PLANT_09_HEIGHT: number = 34;
const HOME_TEAM_TREE_HEIGHT: number = 92;
const HOME_TEAM_TREE_DISPLAY_WIDTH: number = 68;
const HOME_TEAM_PLANT_06_WIDTH: number = 52;
const HOME_TEAM_PLANT_06_HEIGHT: number = 31;
const HOME_TEAM_PLANT_08_WIDTH: number = 30;
const HOME_TEAM_PLANT_08_HEIGHT: number = 34;
/** Row padding around the whole team illustration; does not add space between images. */
const HOME_TEAM_PLANT_ROW_INSET_LEFT: number = 0;
const HOME_TEAM_PLANT_ROW_INSET_RIGHT: number = 0;
/** Negative margin pulls the next sprite over the previous PNG's transparent padding. */
const HOME_TEAM_ART_TILE_OVERLAP: number = 26;
const HOME_SOLO_ART_TILE_OVERLAP: number = 32;
const HOME_SOLO_ROCKS_WIDTH: number = 66;
const HOME_SOLO_ROCKS_HEIGHT: number = 56;
const HOME_SOLO_ART_WIDTH: number = 94;
const HOME_SOLO_ART_HEIGHT: number = 90;
const HOME_SOLO_SIGN_HEIGHT: number = 90;
const HOME_HERO_STACK_HEIGHT: number = 245;
/** Fixed hero height so editorial characters match across narrow and wide screens. */
const HOME_HERO_CHARACTER_HEIGHT: number = 230;
/** Square character art needs width >= height or Contain scales down by the narrow side. */
const HOME_HERO_CHARACTER_SLOT: number = 230;
/** Teapot PNG includes right-side steam beyond the body square. */
const HOME_HERO_TEAPOT_WIDTH: number = 236;
/** Tightest overlap on narrow screens (cloud margin-left is the negated value). */
const HOME_HERO_CHARACTER_OVERLAP_MAX: number = 96;
/** Extra gap between teapot and cloud when the hero row has horizontal slack. */
const HOME_HERO_CHARACTER_GAP_MAX: number = 48;
const HOME_WORDMARK_IMAGE_WIDTH: number = 190;
const HOME_WORDMARK_IMAGE_HEIGHT: number = 100;
/** Pulls the PNG toward the screen edge; does not change the layout box width. */
const HOME_WORDMARK_LEFT_BLEED: number = 30;
/** Slogan may overlap transparent padding in the PNG; reserve only the visible mark width. */
const HOME_WORDMARK_VISIBLE_WIDTH: number = 108;
const HOME_WORDMARK_SLOGAN_LEFT_PAD: number =
  Math.max(0, HOME_WORDMARK_VISIBLE_WIDTH - HOME_WORDMARK_LEFT_BLEED);
const HOME_WORDMARK_SLOGAN_BOTTOM_INSET: number = 10;

@Entry
@Component
struct Index {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('recordingLibraryEpoch') @Watch('refreshWorks') libraryEpoch: number = 0;
  @State teamWorksCount: number = 0;
  @State soloWorksCount: number = 0;
  @State heroAreaWidth: number = 0;

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

  private openMicExperiment(): void {
    const state = RecordingCoordinator.getSnapshot().state;
    if (AppSession.hasLiveOrRetiringSession() || (state !== 'idle' && state !== 'failed')) {
      showUserNotice('请先退出练习并结束录制，再进入 MIC 实验', 'mic-experiment');
      return;
    }
    router.pushUrl({ url: 'pages/MicCaptureExperimentPage' });
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

  private heroCloudMarginLeft(): number {
    const tightSpan = HOME_HERO_TEAPOT_WIDTH + HOME_HERO_CHARACTER_SLOT - HOME_HERO_CHARACTER_OVERLAP_MAX;
    const slack = Math.max(0, this.heroAreaWidth - tightSpan);
    const spread = Math.min(slack, HOME_HERO_CHARACTER_OVERLAP_MAX + HOME_HERO_CHARACTER_GAP_MAX);
    return spread - HOME_HERO_CHARACTER_OVERLAP_MAX;
  }

  @Builder
  private teamEntryArtwork() {
    Row({ space: 0 }) {
      Image($rawfile('vegetation/plant_09.png'))
        .width(HOME_TEAM_PLANT_09_WIDTH).height(HOME_TEAM_PLANT_09_HEIGHT).objectFit(ImageFit.Contain)
        .zIndex(1)
      Image($rawfile('vegetation/plant_06.png'))
        .width(HOME_TEAM_PLANT_06_WIDTH).height(HOME_TEAM_PLANT_06_HEIGHT).objectFit(ImageFit.Contain)
        .margin({ left: -HOME_TEAM_ART_TILE_OVERLAP }).zIndex(2)
      Image($rawfile('scenes/sunset/entities/tree.png'))
        .width(HOME_TEAM_TREE_DISPLAY_WIDTH).height(HOME_TEAM_TREE_HEIGHT).objectFit(ImageFit.Contain)
        .margin({ left: -HOME_TEAM_ART_TILE_OVERLAP }).zIndex(3)
      Image($rawfile('vegetation/plant_08.png'))
        .width(HOME_TEAM_PLANT_08_WIDTH).height(HOME_TEAM_PLANT_08_HEIGHT).objectFit(ImageFit.Contain)
        .margin({ left: -HOME_TEAM_ART_TILE_OVERLAP+8  }).zIndex(4)
    }.width(HOME_TEAM_ART_WIDTH).height(HOME_TEAM_ART_HEIGHT).alignItems(VerticalAlign.Bottom)
      .justifyContent(FlexAlign.Start).clip(true)
      .padding({
        left: HOME_TEAM_PLANT_ROW_INSET_LEFT,
        right: HOME_TEAM_PLANT_ROW_INSET_RIGHT
      })
      .hitTestBehavior(HitTestMode.None)
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
    Row({ space: 0 }) {
      Image($rawfile('scenes/sunset/entities/rocks.png'))
        .width(HOME_SOLO_ROCKS_WIDTH).height(HOME_SOLO_ROCKS_HEIGHT).objectFit(ImageFit.Contain)
        .zIndex(1)
      Image($rawfile('scenes/sunset/entities/sign.png'))
        .height(HOME_SOLO_SIGN_HEIGHT).objectFit(ImageFit.Contain)
        .margin({ left: -HOME_SOLO_ART_TILE_OVERLAP }).zIndex(2)
    }.width(HOME_SOLO_ART_WIDTH).height(HOME_SOLO_ART_HEIGHT).alignItems(VerticalAlign.Bottom)
      .justifyContent(FlexAlign.Start).clip(true)
      .hitTestBehavior(HitTestMode.None)
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
                .fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK).width('100%').maxLines(1).lineHeight(24)
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
        if (this.worksCount(kind) > 0) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 3 }) {
              Text(`作品 ${this.worksCount(kind)}`).fontSize(12).fontWeight(900).fontColor(INK)
              Blank()
              Text('›').fontSize(18).fontWeight(900).fontColor(INK)
            }.width('100%')
          }.width(HOME_WORKS_PILL_WIDTH).height(HOME_WORKS_PILL_HEIGHT)
            .padding({ left: 10, right: 8 }).backgroundColor(PAPER)
            .border({ width: HOME_WORKS_PILL_BORDER_WIDTH, color: INK })
            .borderRadius(4)
            .shadow(CONTROL_SHADOW)
            .position({
              x: HOME_WORKS_PILL_INSET_LEFT,
              y: HOME_PRACTICE_HEIGHT - HOME_WORKS_PILL_HEIGHT - HOME_WORKS_PILL_INSET_BOTTOM
            })
            .zIndex(2)
            .onClick(() => this.goSecondary(kind)).accessibilityText(this.worksAccessibility(kind))
        }
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
            Text('收藏小铺').fontSize(19).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
            Text('角色 / 场景 / 鼓机').fontSize(10).fontWeight(FontWeight.Bold).fontColor(INK)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.layoutWeight(1).alignItems(VerticalAlign.Center)
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
        Stack({ alignContent: Alignment.BottomStart }) {
          Image($rawfile('comic/brand/onebeat_wordmark.png'))
            .width(HOME_WORDMARK_IMAGE_WIDTH).height(HOME_WORDMARK_IMAGE_HEIGHT).objectFit(ImageFit.Contain)
            .margin({ left: -HOME_WORDMARK_LEFT_BLEED })
            .hitTestBehavior(HitTestMode.None)
          Text('不同的人/相同的节拍/更有趣的世界').width('100%').zIndex(1)
            .fontSize(12).minFontSize(10).maxFontSize(12).fontWeight(FontWeight.Bold)
            .lineHeight(18).textAlign(TextAlign.End).maxLines(3)
            .padding({ left: HOME_WORDMARK_SLOGAN_LEFT_PAD, bottom: HOME_WORDMARK_SLOGAN_BOTTOM_INSET })
        }.width('100%').height(HOME_WORDMARK_IMAGE_HEIGHT).clip(false)
        Stack() {
          Image($rawfile('comic/decor/entry_burst.png')).width('115%').height(HOME_HERO_CHARACTER_HEIGHT)
            .objectFit(ImageFit.Fill)
          Stack({ alignContent: Alignment.Bottom }) {
            Row({ space: 0 }) {
              ComicCharacter({ avatar: 'teapot', objectFit: ImageFit.Contain })
                .width(HOME_HERO_TEAPOT_WIDTH).height(HOME_HERO_CHARACTER_HEIGHT).rotate({ angle: -8 })
              ComicCharacter({ avatar: 'cloud', objectFit: ImageFit.Contain })
                .width(HOME_HERO_CHARACTER_SLOT).height(HOME_HERO_CHARACTER_HEIGHT).rotate({ angle: 8 })
                .margin({ left: this.heroCloudMarginLeft() })
            }.justifyContent(FlexAlign.Center).clip(false)
          }.width('100%').height(HOME_HERO_CHARACTER_HEIGHT).clip(false)
            .onAreaChange((_previous: Area, area: Area) => {
              const width = Number(area.width);
              if (width > 0 && Math.abs(width - this.heroAreaWidth) > 0.1) {
                this.heroAreaWidth = width;
              }
            })
          Text('GOOD PEOPLE. SAME BEAT!').fontSize(12).fontWeight(900)
            .backgroundColor(PAPER).padding(5).align(Alignment.BottomEnd)
        }.width('100%').height(HOME_HERO_STACK_HEIGHT).clip(false)
        Column({ space: HOME_ENTRANCE_GAP }) {
          Row({ space: HOME_PRACTICE_PAIR_GAP }) {
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
            .accessibilityText('SAME BEAT，长按进入独立 MIC 实验')
            .gesture(LongPressGesture({ repeat: false, duration: 800 })
              .onAction((): void => { this.openMicExperiment(); }))
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
