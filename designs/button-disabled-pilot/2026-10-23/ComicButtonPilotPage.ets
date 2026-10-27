import { ComicButton, ComicHardShadowOptions, PAPER, INK, CORAL, TEAL, LILAC,
  CARD_SHADOW } from '../components/ComicKit';

const COMIC_BUTTON_HEIGHT: number = 56;
const COMIC_BUTTON_RADIUS: number = 7;

// Temporary device-only harness: reproduces the pre-pilot visual/interaction code.
@Component
struct LegacyComicButton {
  @Prop label: string = '';
  @Prop fill: string = CORAL;
  @Prop active: boolean = true;
  @Prop badgeLabel: string = '';
  @Prop badgeIcon: string = '';
  @Prop badgeFill: string = PAPER;
  // Existing pages retain native shadow rendering unless a solid backing is supplied.
  @Prop inkShadow: ShadowOptions = CARD_SHADOW;
  @Prop hardShadow: ComicHardShadowOptions | undefined = undefined;
  action: () => void = () => {};

  @Builder
  private buttonFace() {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(this.label).fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        Blank()
        if (this.badgeLabel.length > 0 && this.badgeIcon.length > 0) {
          Row({ space: 5 }) {
            Image($rawfile(this.badgeIcon))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
            Text(this.badgeLabel)
              .fontSize(9)
              .fontWeight(900)
              .fontColor(INK)
              .letterSpacing(0.7)
          }
          .width(92)
          .height(30)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.badgeFill)
          .border({ width: 1.2, color: INK })
          .borderRadius(4)
          .rotate({ angle: -2 })
          .margin({ right: 9 })
        }
        Text('›').fontSize(30).fontColor(INK)
      }.width('100%').padding({ left: 16, right: 14 })
    }.width('100%').height(COMIC_BUTTON_HEIGHT).backgroundColor(this.fill)
      .border({ width: 1.5, color: INK }).borderRadius(COMIC_BUTTON_RADIUS)
      .shadow(this.hardShadow !== undefined ? { radius: 0, color: '#00000000' } : this.inkShadow)
      .enabled(this.active).opacity(this.active ? 1 : 0.5).onClick(this.action)
      .id('pilot_legacy_button')
  }

  build() {
    if (this.hardShadow !== undefined) {
      // Older supported runtimes suppress zero-radius shadows. Use a solid backing
      // instead; translation must not enlarge layout or intercept button taps.
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width('100%').height(COMIC_BUTTON_HEIGHT)
          .backgroundColor(this.hardShadow?.color ?? INK).borderRadius(COMIC_BUTTON_RADIUS)
          .translate({ x: this.hardShadow?.offsetX ?? 0, y: this.hardShadow?.offsetY ?? 0 })
          .opacity(this.active ? 1 : 0.5)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        this.buttonFace()
      }.width('100%').height(COMIC_BUTTON_HEIGHT).clip(false)
    } else {
      this.buttonFace()
    }
  }
}


@Entry
@Component
struct ComicButtonPilotPage {
  @State active: boolean = false;
  @State variant: boolean = false;
  @State legacyClicks: number = 0;
  @State hardClicks: number = 0;
  @State nativeClicks: number = 0;
  @State disablePending: boolean = false;
  private disableTimer: number = -1;

  aboutToDisappear(): void {
    this.clearDisableTimer();
  }

  private clearDisableTimer(): void {
    if (this.disableTimer >= 0) {
      clearTimeout(this.disableTimer);
      this.disableTimer = -1;
    }
    this.disablePending = false;
  }

  private buttonLabel(): string {
    return this.variant ? '重新出发' : '一起出发';
  }

  private buttonFill(): string {
    return this.variant ? TEAL : CORAL;
  }

  private scheduleDisable(): void {
    this.clearDisableTimer();
    this.active = true;
    this.disablePending = true;
    // The timer can disable a held target without requiring a second touch.
    this.disableTimer = setTimeout(() => {
      this.active = false;
      this.disablePending = false;
      this.disableTimer = -1;
    }, 2000);
  }

  build() {
    Column({ space: 10 }) {
      Text('ComicButton 真机试点').fontSize(22).fontWeight(FontWeight.Bold)
        .fontColor(INK).id('pilot_title')
      Text(`active=${this.active}; variant=${this.variant}; pending=${this.disablePending}`)
        .fontSize(12).fontColor(INK).id('pilot_state')
      Text('旧实现 · 硬阴影 4/4').fontSize(14).fontColor(INK).width('100%')
      LegacyComicButton({
        label: this.buttonLabel(), fill: this.buttonFill(), active: this.active,
        badgeLabel: this.variant ? 'PRO' : '',
        badgeIcon: this.variant ? 'comic/icons/lock.svg' : '', badgeFill: LILAC,
        hardShadow: { offsetX: 4, offsetY: 4, color: INK },
        action: () => { this.legacyClicks += 1; }
      }).id('pilot_legacy_hard')
      Text(`legacy clicks=${this.legacyClicks}`).fontSize(12).fontColor(INK)
        .width('100%').id('pilot_legacy_count')
      Text('新实现 · 硬阴影 4/4').fontSize(14).fontColor(INK).width('100%')
      ComicButton({
        label: this.buttonLabel(), fill: this.buttonFill(), active: this.active,
        badgeLabel: this.variant ? 'PRO' : '',
        badgeIcon: this.variant ? 'comic/icons/lock.svg' : '', badgeFill: LILAC,
        hardShadow: { offsetX: 4, offsetY: 4, color: INK },
        action: () => { this.hardClicks += 1; }
      }).id('pilot_new_hard')
      Text(`hard clicks=${this.hardClicks}`).fontSize(12).fontColor(INK)
        .width('100%').id('pilot_hard_count')
      Text('新实现 · 原生阴影回退').fontSize(14).fontColor(INK).width('100%')
      ComicButton({
        label: this.buttonLabel(), fill: this.buttonFill(), active: this.active,
        badgeLabel: this.variant ? 'PRO' : '',
        badgeIcon: this.variant ? 'comic/icons/lock.svg' : '', badgeFill: LILAC,
        action: () => { this.nativeClicks += 1; }
      }).id('pilot_new_native')
      Text(`native clicks=${this.nativeClicks}`).fontSize(12).fontColor(INK)
        .width('100%').id('pilot_native_count')
      Row({ space: 8 }) {
        Button(this.active ? '切换为禁用' : '切换为可用', { type: ButtonType.Normal })
          .layoutWeight(1).height(40).fontSize(14).id('pilot_toggle_active')
          .onClick(() => {
            this.clearDisableTimer();
            this.active = !this.active;
          })
        Button('切换文字/颜色/徽标', { type: ButtonType.Normal })
          .layoutWeight(1).height(40).fontSize(13).id('pilot_toggle_variant')
          .onClick(() => { this.variant = !this.variant; })
      }.width('100%').margin({ top: 4 })
      Row({ space: 8 }) {
        Button(this.disablePending ? '等待 2 秒后禁用' : '启用，2 秒后禁用', { type: ButtonType.Normal })
          .layoutWeight(1).height(40).fontSize(13).id('pilot_async_disable')
          .enabled(!this.disablePending)
          .onClick(() => { this.scheduleDisable(); })
        Button('重置计数', { type: ButtonType.Normal })
          .layoutWeight(1).height(40).fontSize(14).id('pilot_reset_counts')
          .onClick(() => {
            this.legacyClicks = 0;
            this.hardClicks = 0;
            this.nativeClicks = 0;
          })
      }.width('100%')
      Text('所有点击仅累加本页计数，不连接业务。').fontSize(11).fontColor(INK)
        .width('100%').id('pilot_boundary')
    }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 24, right: 24, top: 80, bottom: 24 }).backgroundColor(PAPER)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
