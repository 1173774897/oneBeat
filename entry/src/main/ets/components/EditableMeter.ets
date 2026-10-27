import { ActionButton } from './ActionButton';
import { DrumPaper } from './DrumPaper';
import { METER_DENOMINATORS } from '../common/MeterModel';
import { CORAL, INK, LILAC, PAPER, WHITE, CONTROL_SHADOW, INK_SHADOW_RADIUS } from './ComicKit';
import { COMIC_CARD_INK_OFFSET, COMIC_CONTROL_INK_OFFSET } from './ComicInkSurface';

@Component
export struct EditableMeter {
  @Prop beats: number = 4;
  @Prop unit: number = 4;
  @Prop editable: boolean = false;
  @Prop controlWidth: Length = 104;
  @Prop controlHeight: number = 40;
  @Prop valueFontSize: number = 20;
  @Prop controlCornerRadius: number = 5;
  @Prop controlShadow: ShadowOptions = CONTROL_SHADOW;
  @Prop solidInk: boolean = false;
  onEdit: () => void = (): void => {};

  build() {
    ActionButton({
      label: `${this.beats}/${this.unit}`, active: this.editable,
      controlWidth: this.controlWidth, controlHeight: this.controlHeight,
      fill: PAPER, cornerRadius: this.controlCornerRadius, lineWidth: 1.5,
      hardShadow: this.solidInk ?
        { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
      inkShadow: this.solidInk ? undefined : this.controlShadow,
      action: () => this.onEdit()
    }) {
      Row({ space: 7 }) {
        Text(`${this.beats}/${this.unit}`)
          .fontSize(this.valueFontSize)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(INK)
        Text('⌄').fontSize(13).fontWeight(900).fontColor(INK)
      }.justifyContent(FlexAlign.Center)
    }
  }
}

@Component
export struct MeterEditorOverlay {
  @Prop initialBeats: number = 4;
  @Prop initialUnit: number = 4;
  @Prop solidInk: boolean = false;
  @State draftBeats: number = 4;
  @State draftUnit: number = 4;
  onChange: (beats: number, unit: number) => void = (_beats: number, _unit: number): void => {};
  onDismiss: () => void = (): void => {};

  aboutToAppear(): void {
    this.draftBeats = this.initialBeats;
    this.draftUnit = this.initialUnit;
  }

  private choosePreset(beats: number, unit: number): void {
    if (beats === this.draftBeats && unit === this.draftUnit) {
      return;
    }
    this.draftBeats = beats;
    this.draftUnit = unit;
    this.onChange(beats, unit);
  }

  private changeBeats(delta: number): void {
    const next = Math.max(1, Math.min(16, this.draftBeats + delta));
    if (next === this.draftBeats) {
      return;
    }
    this.draftBeats = next;
    this.onChange(next, this.draftUnit);
  }

  private changeUnit(delta: number): void {
    const current = METER_DENOMINATORS.indexOf(this.draftUnit);
    const next = Math.max(0, Math.min(METER_DENOMINATORS.length - 1, current + delta));
    if (METER_DENOMINATORS[next] === this.draftUnit) {
      return;
    }
    this.draftUnit = METER_DENOMINATORS[next];
    this.onChange(this.draftBeats, this.draftUnit);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor('#72000000')
        .onClick(() => this.onDismiss())
      Column() {
        DrumPaper({ fill: PAPER, cornerRadius: 8, paperLineWidth: 0,
          offsetX: this.solidInk ? COMIC_CARD_INK_OFFSET : 0,
          offsetY: this.solidInk ? COMIC_CARD_INK_OFFSET : 0 }) {
          Column({ space: 12 }) {
            Row() {
              Column({ space: 1 }) {
                Text('编辑拍号').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
                Text('每小节拍数 / 拍点音符').fontSize(10).fontWeight(FontWeight.Bold)
                  .fontColor('#655E55').width('100%')
              }.layoutWeight(1)
              Text('×').fontSize(27).fontWeight(900).width(34).textAlign(TextAlign.End)
                .onClick(() => this.onDismiss())
            }.width('100%').alignItems(VerticalAlign.Center)

            Row({ space: 7 }) {
              Column() {
                DrumPaper({ fill: this.draftBeats === 4 && this.draftUnit === 4 ? CORAL : PAPER, cornerRadius: 4, paperLineWidth: 0,
                  offsetX: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0,
                  offsetY: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0 }) {
                  Button('4/4', { type: ButtonType.Normal }).width('100%')
                    .height(34).padding(0).fontColor(INK).fontWeight(900)
                    .backgroundColor(this.draftBeats === 4 && this.draftUnit === 4 ? CORAL : PAPER)
                    .border({ width: 1, color: INK }).borderRadius(4)
                    .onClick(() => this.choosePreset(4, 4))
                }
              }.layoutWeight(1).clip(false)
              Column() {
                DrumPaper({ fill: this.draftBeats === 3 && this.draftUnit === 4 ? CORAL : PAPER, cornerRadius: 4, paperLineWidth: 0,
                  offsetX: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0,
                  offsetY: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0 }) {
                  Button('3/4', { type: ButtonType.Normal }).width('100%')
                    .height(34).padding(0).fontColor(INK).fontWeight(900)
                    .backgroundColor(this.draftBeats === 3 && this.draftUnit === 4 ? CORAL : PAPER)
                    .border({ width: 1, color: INK }).borderRadius(4)
                    .onClick(() => this.choosePreset(3, 4))
                }
              }.layoutWeight(1).clip(false)
              Column() {
                DrumPaper({ fill: this.draftBeats === 6 && this.draftUnit === 8 ? CORAL : PAPER, cornerRadius: 4, paperLineWidth: 0,
                  offsetX: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0,
                  offsetY: this.solidInk ? COMIC_CONTROL_INK_OFFSET : 0 }) {
                  Button('6/8', { type: ButtonType.Normal }).width('100%')
                    .height(34).padding(0).fontColor(INK).fontWeight(900)
                    .backgroundColor(this.draftBeats === 6 && this.draftUnit === 8 ? CORAL : PAPER)
                    .border({ width: 1, color: INK }).borderRadius(4)
                    .onClick(() => this.choosePreset(6, 8))
                }
              }.layoutWeight(1).clip(false)
            }.width('100%')

            Row({ space: 9 }) {
              Column({ space: 6 }) {
                Text('节拍').fontSize(12).fontWeight(900).textAlign(TextAlign.Center).width('100%')
                Row({ space: 6 }) {
                  ActionButton({
                    label: '−', active: this.draftBeats > 1,
                    controlWidth: 34, controlHeight: 34, labelSize: 22, labelWeight: 900,
                    fill: WHITE, cornerRadius: 17, lineWidth: 1.5,
                    hardShadow: this.solidInk ?
                      { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
                    inkShadow: this.solidInk ? undefined : CONTROL_SHADOW,
                    action: () => this.changeBeats(-1)
                  })
                  ActionButton({
                    label: '+', active: this.draftBeats < 16,
                    controlWidth: 34, controlHeight: 34, labelSize: 21, labelWeight: 900,
                    fill: CORAL, cornerRadius: 17, lineWidth: 1.5,
                    hardShadow: this.solidInk ?
                      { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
                    inkShadow: this.solidInk ? undefined : CONTROL_SHADOW,
                    action: () => this.changeBeats(1)
                  })
                }
                Text('1–16').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#746D64')
              }.layoutWeight(1)

              Stack({ alignContent: Alignment.Center }) {
                Row().width(76).height(58).backgroundColor(INK).borderRadius(5)
                  .translate({ x: 2, y: 3 })
                Text(`${this.draftBeats}/${this.draftUnit}`)
                  .width(76).height(58).textAlign(TextAlign.Center)
                  .fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
                  .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(5)
              }.width(79).height(62)

              Column({ space: 6 }) {
                Text('音符').fontSize(12).fontWeight(900).textAlign(TextAlign.Center).width('100%')
                Row({ space: 6 }) {
                  ActionButton({
                    label: '−', active: this.draftUnit > 1,
                    controlWidth: 34, controlHeight: 34, labelSize: 22, labelWeight: 900,
                    fill: WHITE, cornerRadius: 17, lineWidth: 1.5,
                    hardShadow: this.solidInk ?
                      { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
                    inkShadow: this.solidInk ? undefined : CONTROL_SHADOW,
                    action: () => this.changeUnit(-1)
                  })
                  ActionButton({
                    label: '+', active: this.draftUnit < 16,
                    controlWidth: 34, controlHeight: 34, labelSize: 21, labelWeight: 900,
                    fill: CORAL, cornerRadius: 17, lineWidth: 1.5,
                    hardShadow: this.solidInk ?
                      { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK } : undefined,
                    inkShadow: this.solidInk ? undefined : CONTROL_SHADOW,
                    action: () => this.changeUnit(1)
                  })
                }
                Text('1 · 2 · 4 · 8 · 16').fontSize(8).fontWeight(FontWeight.Bold).fontColor('#746D64')
                  .maxLines(1)
              }.layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Center)

          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFF9EE')
          .border({ width: 2, color: INK })
          .borderRadius(8)
          .shadow(this.solidInk ? { radius: 0, color: '#00000000' } :
            { radius: INK_SHADOW_RADIUS, offsetX: 5, offsetY: 6, color: INK })
          .clip(false)
        }
      }.width('88%').clip(false)
    }
    .width('100%')
    .height('100%')
    .zIndex(160)
  }

}
