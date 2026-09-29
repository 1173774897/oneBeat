import { promptAction, router } from '@kit.ArkUI';
import { ComicCharacter, CORAL, INK, LILAC, PAPER } from '../components/ComicKit';

interface StoreCharacter {
  key: string;
  name: string;
  caption: string;
  asset: string;
  color: string;
  price: string;
  defaultOwned: boolean;
}

interface StoreScene {
  key: string;
  name: string;
  caption: string;
  price: string;
  defaultOwned: boolean;
}

const STORE_CHARACTERS: StoreCharacter[] = [
  { key: 'matchman', name: '火柴人', caption: '默认可重复 · 免费', asset: 'matchman', color: '#FFB347', price: '免费', defaultOwned: true },
  { key: 'cloud', name: '云行者', caption: '轻盈天空拍', asset: 'cloud', color: '#6BD4D1', price: '¥8', defaultOwned: true },
  { key: 'teapot', name: '茶壶太太', caption: '慢火稳拍', asset: 'teapot', color: '#FFD06A', price: '¥8', defaultOwned: true },
  { key: 'wave', name: 'Wave', caption: '浪线步态', asset: 'wave', color: '#7EC8FF', price: '¥8', defaultOwned: true },
  { key: 'mismatch', name: '条纹步客', caption: '酷脸推进', asset: 'mismatch', color: '#79D7D4', price: '¥8', defaultOwned: true },
  { key: 'scooter', name: '滑板车', caption: '双拍十六帧', asset: 'scooter', color: '#FF9E7A', price: '¥8', defaultOwned: true },
  { key: 'lilroll', name: '轮滑小子', caption: '贴地飞行', asset: 'lilroll', color: '#C7B8EC', price: '¥8', defaultOwned: false }
];

const STORE_SCENES: StoreScene[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海水、云层与土路循环行进', price: '¥12', defaultOwned: true },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜楼群与湿润街道多层视差', price: '¥12', defaultOwned: true }
];

@Entry
@Component
struct StorePage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'neon_street';
  @State selectedTab: number = 0;
  @State ownedCharacters: string[] = [];
  @State ownedScenes: string[] = [];
  @State passActive: boolean = false;
  @State purchaseVisible: boolean = false;
  @State pendingType: string = '';
  @State pendingKey: string = '';
  @State pendingName: string = '';
  @State pendingPrice: string = '';

  aboutToAppear(): void {
    this.loadPurchases();
  }

  private defaultCharacterKeys(): string[] {
    const keys: string[] = [];
    for (let i = 0; i < STORE_CHARACTERS.length; i++) {
      if (STORE_CHARACTERS[i].defaultOwned) {
        keys.push(STORE_CHARACTERS[i].key);
      }
    }
    return keys;
  }

  private defaultSceneKeys(): string[] {
    const keys: string[] = [];
    for (let i = 0; i < STORE_SCENES.length; i++) {
      if (STORE_SCENES[i].defaultOwned) {
        keys.push(STORE_SCENES[i].key);
      }
    }
    return keys;
  }

  private parseKeys(raw: string, fallback: string[]): string[] {
    if (raw.length === 0) {
      return fallback;
    }
    try {
      return JSON.parse(raw) as string[];
    } catch (_e) {
      return fallback;
    }
  }

  private loadPurchases(): void {
    this.ownedCharacters = this.parseKeys(
      AppStorage.get<string>('storeOwnedCharacters') ?? '', this.defaultCharacterKeys());
    this.ownedScenes = this.parseKeys(
      AppStorage.get<string>('storeOwnedScenes') ?? '', this.defaultSceneKeys());
    this.passActive = AppStorage.get<boolean>('storePassActive') ?? false;
  }

  private hasCharacter(key: string): boolean {
    return this.passActive || this.ownedCharacters.indexOf(key) >= 0;
  }

  private hasScene(key: string): boolean {
    for (let i = 0; i < STORE_SCENES.length; i++) {
      if (STORE_SCENES[i].key === key && STORE_SCENES[i].defaultOwned) {
        return true;
      }
    }
    return this.passActive || this.ownedScenes.indexOf(key) >= 0;
  }

  private selectScene(item: StoreScene): void {
    if (!this.hasScene(item.key)) {
      return;
    }
    this.selectedSceneKey = item.key;
    promptAction.showToast({ message: `已切换到 ${item.name}` });
  }

  private ownedCharacterCount(): number {
    if (this.passActive) {
      return STORE_CHARACTERS.length;
    }
    let count = 0;
    for (let i = 0; i < STORE_CHARACTERS.length; i++) {
      if (this.ownedCharacters.indexOf(STORE_CHARACTERS[i].key) >= 0) {
        count++;
      }
    }
    return count;
  }

  private visibleCharacterCount(onlyAccessible: boolean): number {
    if (!onlyAccessible) {
      return STORE_CHARACTERS.length;
    }
    return this.ownedCharacterCount();
  }

  private openCharacterPurchase(item: StoreCharacter): void {
    if (this.hasCharacter(item.key)) {
      return;
    }
    this.pendingType = 'character';
    this.pendingKey = item.key;
    this.pendingName = item.name;
    this.pendingPrice = item.price;
    this.purchaseVisible = true;
  }

  private openPassPurchase(): void {
    if (this.passActive) {
      promptAction.showToast({ message: '畅游月卡已生效' });
      return;
    }
    this.pendingType = 'pass';
    this.pendingKey = 'monthly_pass';
    this.pendingName = '畅游月卡';
    this.pendingPrice = '¥18 / 月';
    this.purchaseVisible = true;
  }

  private confirmPurchase(): void {
    if (this.pendingType === 'pass') {
      this.passActive = true;
      AppStorage.setOrCreate('storePassActive', true);
      promptAction.showToast({ message: '畅游月卡已开通' });
    } else if (this.pendingType === 'character' && this.ownedCharacters.indexOf(this.pendingKey) < 0) {
      const next = this.ownedCharacters.slice();
      next.push(this.pendingKey);
      this.ownedCharacters = next;
      AppStorage.setOrCreate('storeOwnedCharacters', JSON.stringify(next));
      promptAction.showToast({ message: `已解锁 ${this.pendingName}` });
    }
    this.purchaseVisible = false;
  }

  private restorePurchases(): void {
    this.loadPurchases();
    promptAction.showToast({ message: '已恢复本机购买记录' });
  }

  private characterStatus(item: StoreCharacter): string {
    if (this.passActive && this.ownedCharacters.indexOf(item.key) < 0) {
      return '月卡可用';
    }
    return this.hasCharacter(item.key) ? '已拥有' : `购买 ${item.price}`;
  }

  @Builder
  private passBanner() {
    Stack() {
      Image($rawfile('comic/decor/subscription_ticket.png'))
        .width('100%').height('100%').objectFit(ImageFit.Fill)
      Row() {
        Column({ space: 4 }) {
          Text(this.passActive ? '月卡正在生效' : '畅游月卡')
            .fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
          Text('全部角色与场景').fontSize(15).fontWeight(900).width('100%')
          Button(this.passActive ? '已开通' : '查看方案  ›', { type: ButtonType.Normal })
            .height(34).padding({ left: 13, right: 13 }).fontSize(12).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.2, color: INK }).borderRadius(17)
            .enabled(!this.passActive).onClick(() => this.openPassPurchase())
        }.width('58%').padding({ left: 20 }).alignItems(HorizontalAlign.Start)
        Row({ space: -26 }) {
          ComicCharacter({ avatar: 'cloud' }).width(92).height(132)
          ComicCharacter({ avatar: 'mismatch' }).width(108).height(140)
        }.width('42%').justifyContent(FlexAlign.Center)
      }.width('100%').height('100%').padding({ left: 18, right: 6, top: 14, bottom: 12 })
    }.width('100%').height(184)
  }

  @Builder
  private tabBar() {
    Row() {
      ForEach(['角色', '场景', '我的'], (label: string, index: number) => {
        Button(label, { type: ButtonType.Normal }).layoutWeight(1).height(42).padding(0)
          .fontSize(15).fontWeight(900).fontColor(INK)
          .backgroundColor(this.selectedTab === index ? CORAL : PAPER)
          .border({ width: { right: index < 2 ? 1 : 0 }, color: '#C9C0B4' })
          .onClick(() => this.selectedTab = index)
      })
    }.width('100%').border({ width: 1.5, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private characterCard(item: StoreCharacter) {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height('100%').backgroundColor(item.color)
        Text('.....').fontSize(20).letterSpacing(5).fontColor('#332D2960')
          .position({ x: 10, y: 7 }).rotate({ angle: -8 })
        ComicCharacter({ avatar: item.asset }).width('96%').height('96%')
      }.width('100%').height(150).clip(true)
      Column({ space: 4 }) {
        Text(item.name).fontSize(15).fontWeight(900).maxLines(1)
        Text(item.caption).fontSize(9).fontColor('#645E55').maxLines(1)
        Button(this.characterStatus(item), { type: ButtonType.Normal })
          .width('88%').height(31).padding(0).fontSize(12).fontWeight(900).fontColor(INK)
          .backgroundColor(this.hasCharacter(item.key) ? PAPER : CORAL)
          .border({ width: 1, color: INK }).borderRadius(16)
          .enabled(!this.hasCharacter(item.key)).onClick(() => this.openCharacterPurchase(item))
      }.width('100%').height(78).padding({ top: 5, bottom: 6 })
    }.width('100%').height(228).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private characterGrid(onlyAccessible: boolean) {
    Grid() {
      ForEach(STORE_CHARACTERS, (item: StoreCharacter) => {
        if (!onlyAccessible || this.hasCharacter(item.key)) {
          GridItem() {
            this.characterCard(item)
          }
        }
      }, (item: StoreCharacter) => item.key)
    }.columnsTemplate('1fr 1fr').columnsGap(10).rowsGap(10).width('100%')
    .height(Math.ceil(this.visibleCharacterCount(onlyAccessible) / 2) * 238)
  }

  @Builder
  private sunsetPreview() {
    Stack() {
      Image($rawfile('background/sunset_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
      Image($rawfile('background/sunset_sun.png')).width(90).height(90).objectFit(ImageFit.Contain)
        .position({ x: '64%', y: 4 })
      Image($rawfile('background/sunset_clouds.png')).width('150%').height(92).objectFit(ImageFit.Fill)
        .position({ x: -30, y: 5 })
      Image($rawfile('background/ocean.png')).width('100%').height(72).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 72 })
      Image($rawfile('background/midground_dirt.png')).width('100%').height(62).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 116 })
      Text('夕阳海边').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic)
        .fontColor(PAPER).textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
        .position({ x: 14, y: 116 })
    }.width('100%').height(178).clip(true)
  }

  @Builder
  private neonPreview() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('scenes/neon/neon_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
      Image($rawfile('scenes/neon/neon_far_skyline.png')).width('115%').height(104).objectFit(ImageFit.Fill)
        .position({ x: -12, y: 20 })
      Image($rawfile('scenes/neon/neon_street_blocks.png')).width('130%').height(112).objectFit(ImageFit.Fill)
        .position({ x: -36, y: 36 })
      Image($rawfile('scenes/neon/neon_road.png')).width('125%').height(72).objectFit(ImageFit.Fill)
        .position({ x: -20, y: 106 })
      Text('霓虹街口').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic)
        .fontColor(PAPER).textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
        .position({ x: 14, y: 116 })
    }.width('100%').height(178).clip(true)
  }

  @Builder
  private scenePreview(item: StoreScene) {
    if (item.key === 'neon_street') {
      this.neonPreview()
    } else {
      this.sunsetPreview()
    }
  }

  @Builder
  private sceneCard(item: StoreScene) {
    Column({ space: 0 }) {
      this.scenePreview(item)
      Row() {
        Column({ space: 2 }) {
          Text(item.name).fontSize(16).fontWeight(900)
          Text(item.caption).fontSize(9).fontColor('#645E55')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.selectedSceneKey === item.key ? '使用中' : this.hasScene(item.key) ? '使用' : `购买 ${item.price}`,
          { type: ButtonType.Normal }).height(32).padding({ left: 13, right: 13 })
          .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1, color: INK }).borderRadius(16)
          .enabled(this.hasScene(item.key) && this.selectedSceneKey !== item.key)
          .onClick(() => this.selectScene(item))
      }.width('100%').height(62).padding({ left: 12, right: 10 })
    }.width('100%').height(240).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private purchaseDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text(this.pendingType === 'pass' ? 'MORE BEATS!' : 'NEW FRIEND!')
          .fontSize(11).fontWeight(900).fontColor(PAPER).backgroundColor(INK)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -3 })
        Text(this.pendingName).fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
        Text(this.pendingType === 'pass' ? '开通后可使用当前及后续上架的所有角色和场景。' :
          '购买后会加入“我的”，可在角色选择页使用。')
          .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
        Text(this.pendingPrice).fontSize(22).fontWeight(900).fontColor(CORAL)
        Row({ space: 9 }) {
          Button('再想想', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.purchaseVisible = false)
          Button('确认购买', { type: ButtonType.Normal }).layoutWeight(1.3).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.confirmPurchase())
        }.width('100%')
        Text('当前为本地交互版，后续接入 HarmonyOS 正式支付。')
          .fontSize(9).fontColor('#6B655D').width('100%')
      }.width('88%').padding(17).backgroundColor('#FFF1D7')
      .border({ width: 2.5, color: INK }).borderRadius(8)
      .shadow({ radius: 0, offsetX: 7, offsetY: 8, color: INK })
    }.width('100%').height('100%').backgroundColor('#77000000').zIndex(100)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('‹').fontSize(32).width(32).onClick(() => router.back())
            Text('收藏小铺').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            Stack({ alignContent: Alignment.TopEnd }) {
              Text('▣').fontSize(31).fontWeight(900)
              Text(`${this.ownedCharacterCount()}`).fontSize(9).fontWeight(900).fontColor(PAPER)
                .width(17).height(17).textAlign(TextAlign.Center).backgroundColor(CORAL).borderRadius(9)
            }.width(42).height(40)
          }.width('100%')
          this.passBanner()
          this.tabBar()
          if (this.selectedTab === 0) {
            this.characterGrid(false)
          } else if (this.selectedTab === 1) {
            ForEach(STORE_SCENES, (item: StoreScene) => {
              this.sceneCard(item)
            }, (item: StoreScene) => item.key)
            Column({ space: 4 }) {
              Text('MORE WORLDS INCOMING').fontSize(11).fontWeight(900).letterSpacing(1)
              Text('新场景将会在这里持续上架').fontSize(12).fontColor('#655F57')
            }.width('100%').padding(16).backgroundColor(LILAC)
            .border({ width: 1.2, color: INK }).borderRadius(7)
          } else {
            Row() {
              Text('我的角色').fontSize(17).fontWeight(900)
              Blank()
              Text(`${this.ownedCharacterCount()} 个`).fontSize(11).fontColor('#655F57')
            }.width('100%')
            this.characterGrid(true)
            Text('我的场景').fontSize(17).fontWeight(900).width('100%')
            ForEach(STORE_SCENES, (item: StoreScene) => {
              if (this.hasScene(item.key)) {
                this.sceneCard(item)
              }
            }, (item: StoreScene) => item.key)
          }
          Button('恢复购买', { type: ButtonType.Normal }).width('100%').height(48)
            .fontSize(15).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
            .border({ width: 1.5, color: INK }).borderRadius(7).onClick(() => this.restorePurchases())
          Row() {
            Text('COLLECT MORE WEIRDOS\nFOR A BRIGHTER RHYTHM.')
              .fontSize(9).fontWeight(900).lineHeight(11)
            Blank()
            Image($rawfile('comic/brand/onebeat_wordmark.png')).width(112).height(50).objectFit(ImageFit.Contain)
          }.width('100%')
          Text('隐私声明')
            .fontSize(12)
            .fontColor('#66615A')
            .decoration({ type: TextDecorationType.Underline })
            .width('100%')
            .textAlign(TextAlign.End)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PrivacyPage' });
            })
        }.width('100%').padding({
          left: 16,
          right: 16,
          top: 10 + this.topSafeInset,
          bottom: 24 + this.bottomSafeInset
        })
      }.width('100%').height('100%').backgroundColor(PAPER)
      if (this.purchaseVisible) {
        this.purchaseDialog()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
