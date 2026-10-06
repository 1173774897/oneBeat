import { METER_DENOMINATORS } from '../common/MeterModel';
import { CORAL, INK, LILAC, PAPER, WHITE, CONTROL_SHADOW, INK_SHADOW_RADIUS } from './ComicKit';

@Component
export struct EditableMeter {
  @Prop beats: number = 4;
  @Prop unit: number = 4;
  @Prop editable: boolean = false;
  @Prop controlWidth: Length = 104;
  @Prop controlHeight: number = 40;
  @Prop valueFontSize: number = 20;
  onEdit: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 7 }) {
        Text(`${this.beats}/${this.unit}`)
          .fontSize(this.valueFontSize)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(INK)
        Text('⌄').fontSize(13).fontWeight(900).fontColor(INK)
      }.justifyContent(FlexAlign.Center)
    }
    .width(this.controlWidth)
    .height(this.controlHeight)
    .padding(0)
    .backgroundColor(PAPER)
    .border({ width: 1.5, color: INK })
    .borderRadius(5)
    .shadow(CONTROL_SHADOW)
    .enabled(this.editable)
    .opacity(this.editable ? 1 : 0.6)
    .onClick(() => this.onEdit())
  }
}

@Component
export struct MeterEditorOverlay {
  @Prop initialBeats: number = 4;
  @Prop initialUnit: number = 4;
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
          Button('4/4', { type: ButtonType.Normal }).layoutWeight(1)
            .height(34).padding(0).fontColor(INK).fontWeight(900)
            .backgroundColor(this.draftBeats === 4 && this.draftUnit === 4 ? CORAL : PAPER)
            .border({ width: 1, color: INK }).borderRadius(4)
            .onClick(() => this.choosePreset(4, 4))
          Button('3/4', { type: ButtonType.Normal }).layoutWeight(1)
            .height(34).padding(0).fontColor(INK).fontWeight(900)
            .backgroundColor(this.draftBeats === 3 && this.draftUnit === 4 ? CORAL : PAPER)
            .border({ width: 1, color: INK }).borderRadius(4)
            .onClick(() => this.choosePreset(3, 4))
          Button('6/8', { type: ButtonType.Normal }).layoutWeight(1)
            .height(34).padding(0).fontColor(INK).fontWeight(900)
            .backgroundColor(this.draftBeats === 6 && this.draftUnit === 8 ? CORAL : PAPER)
            .border({ width: 1, color: INK }).borderRadius(4)
            .onClick(() => this.choosePreset(6, 8))
        }.width('100%')

        Row({ space: 9 }) {
          Column({ space: 6 }) {
            Text('节拍').fontSize(12).fontWeight(900).textAlign(TextAlign.Center).width('100%')
            Row({ space: 6 }) {
              Button('−', { type: ButtonType.Normal }).width(34).height(34).padding(0)
                .fontSize(22).fontWeight(900).fontColor(INK).backgroundColor(WHITE)
                .border({ width: 1.5, color: INK }).borderRadius(17).shadow(CONTROL_SHADOW)
                .enabled(this.draftBeats > 1).opacity(this.draftBeats > 1 ? 1 : 0.4)
                .onClick(() => this.changeBeats(-1))
              Button('+', { type: ButtonType.Normal }).width(34).height(34).padding(0)
                .fontSize(21).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
                .border({ width: 1.5, color: INK }).borderRadius(17).shadow(CONTROL_SHADOW)
                .enabled(this.draftBeats < 16).opacity(this.draftBeats < 16 ? 1 : 0.4)
                .onClick(() => this.changeBeats(1))
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
              Button('−', { type: ButtonType.Normal }).width(34).height(34).padding(0)
                .fontSize(22).fontWeight(900).fontColor(INK).backgroundColor(WHITE)
                .border({ width: 1.5, color: INK }).borderRadius(17).shadow(CONTROL_SHADOW)
                .enabled(this.draftUnit > 1).opacity(this.draftUnit > 1 ? 1 : 0.4)
                .onClick(() => this.changeUnit(-1))
              Button('+', { type: ButtonType.Normal }).width(34).height(34).padding(0)
                .fontSize(21).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
                .border({ width: 1.5, color: INK }).borderRadius(17).shadow(CONTROL_SHADOW)
                .enabled(this.draftUnit < 16).opacity(this.draftUnit < 16 ? 1 : 0.4)
                .onClick(() => this.changeUnit(1))
            }
            Text('1 · 2 · 4 · 8 · 16').fontSize(8).fontWeight(FontWeight.Bold).fontColor('#746D64')
              .maxLines(1)
          }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)

      }
      .width('88%')
      .padding(16)
      .backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK })
      .borderRadius(8)
      .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 5, offsetY: 6, color: INK })
    }
    .width('100%')
    .height('100%')
    .zIndex(160)
  }
}
