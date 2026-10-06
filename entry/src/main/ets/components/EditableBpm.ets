import { promptAction } from '@kit.ArkUI';
import { CORAL, INK, PAPER, CONTROL_SHADOW } from './ComicKit';

const BPM_MIN: number = 40;
const BPM_MAX: number = 240;

@Component
export struct EditableBpm {
  @Prop value: number = 120;
  @Prop editable: boolean = false;
  @Prop inputId: string = 'editable-bpm';
  @Prop controlWidth: Length = 96;
  @Prop controlHeight: number = 50;
  @Prop valueFontSize: number = 40;
  @Prop valueColor: string = INK;
  @Prop valueShadow: ShadowOptions = { radius: 0, color: '#00000000' };
  @State editing: boolean = false;
  @State draft: string = '';
  onCommit: (value: number) => void = (_value: number): void => {};

  private startEditing(): void {
    if (!this.editable || this.editing) {
      return;
    }
    this.draft = `${this.value}`;
    this.editing = true;
  }

  private commitEditing(): void {
    if (!this.editing) {
      return;
    }
    const parsed = Number.parseInt(this.draft, 10);
    this.editing = false;
    if (this.draft.length === 0 || !Number.isFinite(parsed) || parsed < BPM_MIN || parsed > BPM_MAX) {
      promptAction.showToast({ message: `请输入 ${BPM_MIN}–${BPM_MAX} 之间的 BPM` });
      this.draft = `${this.value}`;
      return;
    }
    this.onCommit(parsed);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      TextInput({ text: this.editing ? this.draft : `${this.value}` })
        .id(this.inputId)
        .width('100%')
        .height('100%')
        .padding({ left: 6, right: 6 })
        .type(InputType.Number)
        .enterKeyType(EnterKeyType.Done)
        .maxLength(3)
        .fontSize(this.valueFontSize)
        .maxFontSize(this.valueFontSize)
        .minFontSize(14)
        .maxLines(1)
        .fontWeight(900)
        .fontStyle(FontStyle.Italic)
        .fontColor(this.editing ? INK : '#00000000')
        .textAlign(TextAlign.Center)
        .caretColor(CORAL)
        .selectedBackgroundColor('#55FF7056')
        .backgroundColor(this.editing ? PAPER : '#00000000')
        .border({ width: this.editing ? 1.5 : 0, color: INK })
        .borderRadius(5)
        .shadow(this.editing ? CONTROL_SHADOW : { radius: 0, color: '#00000000' })
        .enabled(this.editable)
        .opacity(1)
        .onFocus(() => this.startEditing())
        .onChange((raw: string) => {
          if (this.editing) {
            this.draft = raw.replace(/[^\d]/g, '').slice(0, 3);
          }
        })
        .onSubmit(() => this.commitEditing())
        .onBlur(() => this.commitEditing())
      if (!this.editing) {
        Text(`${this.value}`)
          .width('100%')
          .height('100%')
          .fontSize(this.valueFontSize)
          .maxFontSize(this.valueFontSize)
          .minFontSize(14)
          .maxLines(1)
          .fontWeight(900)
          .fontStyle(FontStyle.Italic)
          .fontColor(this.valueColor)
          .textAlign(TextAlign.Center)
          .textShadow(this.valueShadow)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.controlWidth)
    .height(this.controlHeight)
  }
}
