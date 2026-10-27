import { ColorMetrics } from '@kit.ArkUI';

export const ACTION_DISABLED_OPACITY: number = 0.68;
const ACTION_PRESSED_TINT: string = '#19000000';
const ACTION_DISABLED_PAPER_FILL: string = '#ADFFF9EE';
const TRANSPARENT_FACE: ShadowOptions = { radius: 0, color: '#00000000' };

/** Numeric vp offsets for a solid backing; native ShadowOptions use px instead. */
export interface ActionButtonHardShadow {
  offsetX: number;
  offsetY: number;
  color: string;
}

interface ActionButtonAppearance {
  fill: ResourceColor;
  cornerRadius: Length | BorderRadiuses;
  lineWidth: Length | EdgeWidths;
  lineColor: ResourceColor;
  contentPadding: Padding | Length;
  autoWidth: boolean;
  controlHeight: Length;
  inkShadow: ShadowOptions | undefined;
  hitRegion: Rectangle | Rectangle[] | undefined;
}

class ActionButtonContentModifier implements ContentModifier<ButtonConfiguration> {
  appearance: ActionButtonAppearance;
  content: () => void;
  forwardClick: (config: ButtonConfiguration, event: ClickEvent) => void;

  constructor(appearance: ActionButtonAppearance, content: () => void,
    forwardClick: (config: ButtonConfiguration, event: ClickEvent) => void) {
    this.appearance = appearance;
    this.content = content;
    this.forwardClick = forwardClick;
  }

  applyContent(): WrappedBuilder<[ButtonConfiguration]> {
    return wrapBuilder(actionButtonContent);
  }
}

function resolveFaceInkShadow(config: ButtonConfiguration): ShadowOptions {
  const modifier = config.contentModifier as ActionButtonContentModifier;
  if (!config.enabled) {
    return TRANSPARENT_FACE;
  }
  const ink = modifier.appearance.inkShadow;
  return ink !== undefined ? ink : TRANSPARENT_FACE;
}

@Component
struct ActionButtonFace {
  @Prop appearance: ActionButtonAppearance;
  @Prop faceEnabled: boolean = true;
  @Prop pressed: boolean = false;
  @Prop faceInkShadow: ShadowOptions = TRANSPARENT_FACE;
  @BuilderParam content: () => void;

  private fillIsTransparent(fill: ResourceColor): boolean {
    return fill === Color.Transparent || fill === '#00000000';
  }

  private faceBackground(): ResourceColor {
    if (this.pressed) {
      return ColorMetrics.resourceColor(this.appearance.fill)
        .blendColor(ColorMetrics.resourceColor(ACTION_PRESSED_TINT)).color;
    }
    if (!this.faceEnabled && this.fillIsTransparent(this.appearance.fill)) {
      return ACTION_DISABLED_PAPER_FILL;
    }
    return this.appearance.fill;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.content()
    }
    .width(this.appearance.autoWidth ? undefined : '100%').height(this.appearance.controlHeight)
    .padding(this.appearance.contentPadding)
    .backgroundColor(this.faceBackground())
    .border({ width: this.appearance.lineWidth, color: this.appearance.lineColor })
    .borderRadius(this.appearance.cornerRadius)
    .shadow(this.faceInkShadow)
    .clip(false)
  }
}

@Builder
function actionButtonContent(config: ButtonConfiguration) {
  ActionButtonFace({
    appearance: (config.contentModifier as ActionButtonContentModifier).appearance,
    faceEnabled: config.enabled,
    pressed: config.enabled && config.pressed,
    faceInkShadow: resolveFaceInkShadow(config),
    content: (config.contentModifier as ActionButtonContentModifier).content
  })
    .responseRegion((config.contentModifier as ActionButtonContentModifier).appearance.hitRegion ??
      { x: 0, y: 0, width: '100%', height: '100%' })
    .enabled(config.enabled).focusable(false).accessibilityLevel('no-hide-descendants')
    // Native content modifiers redirect clicks to their content. Re-enter the
    // host's click path so keyboard, touch and accessibility share one action.
    .onClick((event: ClickEvent) => {
      if (config.enabled) { (config.contentModifier as ActionButtonContentModifier).forwardClick(config, event); }
    })
}

/**
 * A native button with a custom face and one disabled fade for face plus shadow.
 * Put only the button's own visual content in the optional builder. Preserve
 * business guards in the action: enabled can change after a gesture has begun.
 * Keep callback/builder identities stable while mounted and read live caller
 * state inside them; BuilderParam is not a reactive replacement for a function.
 */
@Component
export struct ActionButton {
  @Prop label: string = '';
  @Prop active: boolean = true;
  @Prop controlWidth: Length = '100%';
  @Prop controlHeight: Length = 40;
  @Prop fill: ResourceColor = '#FFF9EE';
  @Prop labelColor: ResourceColor = '#171B1F';
  @Prop labelSize: number = 16;
  @Prop labelWeight: number | FontWeight = FontWeight.Medium;
  @Prop labelStyle: FontStyle = FontStyle.Normal;
  @Prop cornerRadius: Length | BorderRadiuses = 4;
  @Prop lineWidth: Length | EdgeWidths = 0;
  @Prop lineColor: ResourceColor = '#171B1F';
  @Prop contentPadding: Padding | Length = 0;
  @Prop hardShadow: ActionButtonHardShadow | undefined = undefined;
  @Prop inkShadow: ShadowOptions | undefined = undefined;
  @Prop buttonId: string = '';
  @Prop accessibilityLabel: string = '';
  @Prop hitRegion: Rectangle | Rectangle[] | undefined = undefined;
  @BuilderParam content: () => void = this.defaultLabel;
  action: (event: ClickEvent) => void = () => {};
  touchAction: (event: TouchEvent) => void = () => {};
  private contentClickEvent: ClickEvent | undefined = undefined;
  @State private hardFaceWidth: number = 0;
  @State private hardFaceHeight: number = 0;

  private forwardContentClick(config: ButtonConfiguration, event: ClickEvent): void {
    // triggerClick synthesizes a new ClickEvent. Keep the original source and
    // timestamp while it synchronously re-enters the native callback, so touch
    // freshness guards cannot mistake a pointer action for keyboard activation.
    const previousEvent = this.contentClickEvent;
    this.contentClickEvent = event;
    try {
      config.triggerClick(event.x, event.y);
    } finally {
      this.contentClickEvent = previousEvent;
    }
  }

  @Builder
  private defaultLabel() {
    Text(this.label).fontSize(this.labelSize).fontWeight(this.labelWeight).fontStyle(this.labelStyle)
      .fontColor(this.labelColor).textAlign(TextAlign.Center).maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  private shadowNumber(value: number | Resource | undefined): number {
    if (value === undefined) { return 0; }
    if (typeof value === 'number') { return value; }
    try {
      return getContext(this).resourceManager.getNumber(value);
    } catch (_error) {
      // A missing optional decoration cannot make the action itself disappear.
      return 0;
    }
  }

  private shadowOutset(horizontal: boolean, leading: boolean): number {
    if (this.hardShadow !== undefined) {
      const offset = horizontal ? this.hardShadow.offsetX : this.hardShadow.offsetY;
      return Math.max(0, leading ? -offset : offset);
    }
    if (!this.active) { return 0; }
    if (this.inkShadow === undefined) { return 0; }
    const offset = this.shadowNumber(horizontal ? this.inkShadow.offsetX : this.inkShadow.offsetY);
    const fringe = 3 * Math.max(0, this.shadowNumber(this.inkShadow.radius)) + 1;
    return px2vp(Math.ceil(Math.max(0, fringe + (leading ? -offset : offset))));
  }

  private groupWidth(): Length {
    if (this.controlWidth === 'auto') { return 'auto'; }
    const extra = this.shadowOutset(true, true) + this.shadowOutset(true, false);
    if (typeof this.controlWidth === 'number') { return this.controlWidth + extra; }
    return `calc(${this.controlWidth} + ${extra}vp)`;
  }

  private groupHeight(): Length {
    if (this.controlHeight === 'auto') { return 'auto'; }
    const extra = this.shadowOutset(false, true) + this.shadowOutset(false, false);
    if (typeof this.controlHeight === 'number') { return this.controlHeight + extra; }
    return `calc(${this.controlHeight} + ${extra}vp)`;
  }

  private effectiveInkShadow(): ShadowOptions | undefined {
    if (this.inkShadow === undefined) { return undefined; }
    // Native blur on a semi-transparent disabled face reads as shadow bleeding through.
    if (!this.active) { return { radius: 0, color: '#00000000' }; }
    return this.inkShadow;
  }

  private appearance(): ActionButtonAppearance {
    return {
      fill: this.fill, cornerRadius: this.cornerRadius, lineWidth: this.lineWidth, lineColor: this.lineColor,
      contentPadding: this.contentPadding, autoWidth: this.controlWidth === 'auto', controlHeight: this.controlHeight,
      inkShadow: this.hardShadow === undefined ? this.effectiveInkShadow() : undefined, hitRegion: this.hitRegion
    };
  }

  private updateHardFaceSize(area: Area): void {
    // Retain the latest size even when ink is absent: callers may enable it
    // later without resizing the native host or receiving another area event.
    const width = Number(area.width);
    const height = Number(area.height);
    if (Number.isFinite(width) && width >= 0 && width !== this.hardFaceWidth) {
      this.hardFaceWidth = width;
    }
    if (Number.isFinite(height) && height >= 0 && height !== this.hardFaceHeight) {
      this.hardFaceHeight = height;
    }
  }

  @Builder
  private hardInkShadowRow() {
    if (this.hardShadow !== undefined) {
      // An empty auto-width backing has no intrinsic size. Measure only the
      // native face, and keep ink out of layout so it cannot prevent shrinking.
      Row().width(this.hardFaceWidth).height(this.hardFaceHeight)
        .backgroundColor(this.hardShadow.color).borderRadius(this.cornerRadius)
        .position({ x: this.hardShadow.offsetX, y: this.hardShadow.offsetY })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
    }
  }

  @Builder
  private actionHost() {
    Button(this.label, { type: ButtonType.Normal })
      .contentModifier(new ActionButtonContentModifier(this.appearance(), this.content.bind(this),
        this.forwardContentClick.bind(this)))
      .id(this.buttonId).width(this.controlWidth === 'auto' ? 'auto' : '100%').height(this.controlHeight)
      .padding(0).borderRadius(this.cornerRadius).clip(false)
      .enabled(this.active)
      .responseRegion(this.hitRegion ?? { x: 0, y: 0, width: '100%', height: '100%' })
      .accessibilityText(this.accessibilityLabel.length > 0 ? this.accessibilityLabel : this.label)
      .onAreaChange((_before: Area, area: Area) => this.updateHardFaceSize(area))
      .onTouch((event: TouchEvent) => this.touchAction(event))
      .onClick((event: ClickEvent) => {
        if (this.active) { this.action(this.contentClickEvent ?? event); }
      })
  }

  @Builder
  private faceWithHardInk() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.hardInkShadowRow()
      this.actionHost()
    }.width(this.controlWidth === 'auto' ? 'auto' : '100%').height(this.controlHeight).clip(false)
  }

  @Builder
  private shadowExtentWrapper(content: () => void, fadeOnExpandedBounds: boolean) {
    Stack({ alignContent: Alignment.TopStart }) {
      content()
    }
    // The cache must include overflow; clip(false) alone does not enlarge it.
    // Negative margins cancel that decoration space without enlarging layout
    // or the native button's hit target, including intrinsic-width controls.
    .width(this.groupWidth())
    .height(this.groupHeight())
    .padding({ left: this.shadowOutset(true, true), right: this.shadowOutset(true, false),
      top: this.shadowOutset(false, true), bottom: this.shadowOutset(false, false) })
    .margin({ left: -this.shadowOutset(true, true), right: -this.shadowOutset(true, false),
      top: -this.shadowOutset(false, true), bottom: -this.shadowOutset(false, false) })
    .clip(false)
    // renderGroup on native-shadow buttons clips or leaves ghost ink when faded; hard ink still needs it.
    .renderGroup(fadeOnExpandedBounds && !this.active && this.hardShadow !== undefined)
    .opacity(fadeOnExpandedBounds ? (this.active ? 1 : ACTION_DISABLED_OPACITY) : 1)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.shadowExtentWrapper(() => {
        if (this.hardShadow !== undefined) {
          this.faceWithHardInk()
        } else {
          this.actionHost()
        }
      }, true)
    }.width(this.controlWidth).height(this.controlHeight).clip(false)
  }
}
