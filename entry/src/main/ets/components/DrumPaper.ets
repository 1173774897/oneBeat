import { INK, PAPER } from './ComicKit';

/** A solid offset backing: radius-zero native shadows are omitted on some devices. */
@Component
export struct DrumPaper {
  @Prop fill: string = PAPER;
  // Intrinsic-width badges share the same backing without stretching to fill their row.
  @Prop paperWidth: Length = '100%';
  @Prop cornerRadius: number = 8;
  @Prop paperLineWidth: number = 1.5;
  @Prop paperLineColor: string = INK;
  @Prop offsetX: number = 4;
  @Prop offsetY: number = 4;
  @Prop clipContent: boolean = false;
  @State private surfaceWidth: number = 0;
  @State private surfaceHeight: number = 0;
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  private emptyContent() {}

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Rect().width(this.surfaceWidth).height(this.surfaceHeight).radius(this.cornerRadius).fill(INK)
        .position({ x: this.offsetX, y: this.offsetY }).hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
      Column() {
        this.content()
      }.width(this.paperWidth).backgroundColor(this.fill)
        .border({ width: this.paperLineWidth, color: this.paperLineColor }).borderRadius(this.cornerRadius)
        // Clip the face, while keeping its separate ink backing free to extend outside.
        .clip(this.clipContent)
        .onAreaChange((_before: Area, area: Area) => {
          const width = Number(area.width);
          const height = Number(area.height);
          if (width > 0 && width !== this.surfaceWidth) { this.surfaceWidth = width; }
          if (height > 0 && height !== this.surfaceHeight) { this.surfaceHeight = height; }
        })
    // Column supports intrinsic "auto" sizing; leave the Stack width unset in
    // that case so its measured face determines the backing's exact bounds.
    }.width(this.paperWidth === 'auto' ? undefined : this.paperWidth).clip(false)
  }
}
