import { router } from '@kit.ArkUI';
import { ComicCharacter, PAPER, INK, WHITE } from '../components/ComicKit';
import { RecordingRepository } from '../recording/RecordingRepository';
import { RecordingClip, RecordingScope } from '../recording/RecordingModels';
import { ensureStoreBootstrapReady } from '../store/StoreBootstrapSync';

type HomeEntryKind = RecordingScope | 'store';

const HOME_CARD_HEIGHT: number = 128;
const HOME_CARD_HEADER_HEIGHT: number = 76;
const HOME_CARD_RADIUS: number = 10;
const HOME_CARD_INSET: number = 16;
const HOME_CARD_ICON_SIZE: number = 34;
const HOME_CARD_PILL_HEIGHT: number = 30;
const HOME_CARD_PILL_WIDTH: number = 124;
const HOME_CARD_SHADOW_X: number = 3;
const HOME_CARD_SHADOW_Y: number = 4;

@Entry
@Component
struct Index {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('recordingLibraryEpoch') @Watch('refreshWorks') libraryEpoch: number = 0;
  @State teamWorksCount: number = 0;
  @State soloWorksCount: number = 0;
  @State teamRecordedMs: number = 0;
  @State soloRecordedMs: number = 0;

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
    this.teamRecordedMs = teamClips.reduce((total: number, clip: RecordingClip) => total + clip.durationMs, 0);
    this.soloRecordedMs = soloClips.reduce((total: number, clip: RecordingClip) => total + clip.durationMs, 0);
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

  private recordedDuration(kind: HomeEntryKind): string {
    const totalSeconds = Math.floor((kind === 'team' ? this.teamRecordedMs : this.soloRecordedMs) / 1000);
    if (totalSeconds >= 3600) { return `${Math.floor(totalSeconds / 3600)}小时${Math.floor(totalSeconds % 3600 / 60)}分`; }
    return `${Math.floor(totalSeconds / 60)}:${(totalSeconds % 60).toString().padStart(2, '0')}`;
  }

  private entryMetric(kind: HomeEntryKind): string {
    return kind === 'store' ? '角色 · 场景 · 鼓机' : `累计录制 ${this.recordedDuration(kind)}`;
  }

  private secondaryLabel(kind: HomeEntryKind): string {
    return kind === 'store' ? '逛逛小铺' : `作品 ${kind === 'team' ? this.teamWorksCount : this.soloWorksCount}`;
  }

  private secondaryAccessibility(kind: HomeEntryKind): string {
    if (kind === 'store') { return '进入收藏小铺'; }
    return `${kind === 'team' ? '多人' : '单人'}练习作品，${kind === 'team' ? this.teamWorksCount : this.soloWorksCount}段，查看作品`;
  }

  @Builder
  private entryCard(kind: HomeEntryKind, title: string, subtitle: string, icon: string, tint: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row().width('100%').height(HOME_CARD_HEIGHT).backgroundColor(INK).borderRadius(HOME_CARD_RADIUS)
        .translate({ x: HOME_CARD_SHADOW_X, y: HOME_CARD_SHADOW_Y })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      // The card face has no click handler: its practice areas and works pill are
      // sibling buttons, so a works tap can never bubble into practice navigation.
      Column() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Stack() {
              Image($rawfile(icon)).width(HOME_CARD_ICON_SIZE).height(HOME_CARD_ICON_SIZE)
                .objectFit(ImageFit.Contain)
            }.width(42).height(42).backgroundColor(tint).borderRadius(12)
            Column({ space: 4 }) {
              Text(title).fontSize(21).fontWeight(900).fontColor(INK)
              Text(subtitle).fontSize(11).fontColor('#817B76').maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text('›').fontSize(24).fontColor(INK).width(28).height(28).textAlign(TextAlign.Center)
              .border({ width: 1.2, color: '#817B76' }).borderRadius(14)
          }.width('100%')
        }.width('100%').height(HOME_CARD_HEADER_HEIGHT)
          .padding({ left: HOME_CARD_INSET, right: HOME_CARD_INSET, top: 12, bottom: 4 })
          .backgroundColor(Color.Transparent).borderRadius(HOME_CARD_RADIUS)
          .onClick(() => this.goPrimary(kind)).accessibilityText(`${title}，${subtitle}`)
        Row({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              Image($rawfile('comic/icons/note-quarter.svg')).width(12).height(14).objectFit(ImageFit.Contain)
                .opacity(0.55)
              Text(this.entryMetric(kind)).fontSize(11).fontColor('#817B76').maxLines(1).layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }.width('100%')
          }.layoutWeight(1).height(HOME_CARD_PILL_HEIGHT).padding(0)
            .backgroundColor(Color.Transparent).borderRadius(0).onClick(() => this.goPrimary(kind))
            .accessibilityText(`${title}，${this.entryMetric(kind)}`)
          Button({ type: ButtonType.Normal }) {
            Row({ space: 4 }) {
              Text(this.secondaryLabel(kind)).fontSize(12).fontWeight(FontWeight.Bold).fontColor(INK)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text('›').fontSize(18).fontColor(INK)
            }.width('100%')
          }.width(HOME_CARD_PILL_WIDTH).height(HOME_CARD_PILL_HEIGHT).padding({ left: 12, right: 10 })
            .backgroundColor(tint).borderRadius(15).onClick(() => this.goSecondary(kind))
            .accessibilityText(this.secondaryAccessibility(kind))
        }.width('100%').height(HOME_CARD_HEIGHT - HOME_CARD_HEADER_HEIGHT)
          .padding({ left: HOME_CARD_INSET, right: HOME_CARD_INSET, top: 4, bottom: 14 })
      }.width('100%').height(HOME_CARD_HEIGHT).backgroundColor(WHITE)
        .border({ width: 1.2, color: '#655F59' }).borderRadius(HOME_CARD_RADIUS)
    }.width('100%').height(HOME_CARD_HEIGHT).clip(false)
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
        this.entryCard('team', '多人练习', '组队同行，踩准同一个节拍', 'comic/icons/multi-person.svg', '#E5DCF6')
        this.entryCard('solo', '单人练习', '跟着节奏，找到自己的步调', 'comic/icons/solo-person.svg', '#FFE0D4')
        this.entryCard('store', '收藏小铺', '为每一次同行添点新花样', 'comic/icons/limited-free-ticket.svg', '#D5EDE7')
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
