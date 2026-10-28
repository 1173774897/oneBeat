import { FrameCallback } from '@kit.ArkUI';
import { showUserNotice } from '../common/UserFeedback';
import { CORAL, INK, PAPER, CONTROL_SHADOW } from './ComicKit';
import { ActionButton } from './ActionButton';
import { COMIC_CONTROL_INK_OFFSET } from './ComicInkSurface';

const BPM_MIN: number = 40;
const BPM_MAX: number = 240;
const BPM_INPUT_PADDING_X: number = 4;
const BPM_INPUT_BORDER_WIDTH: number = 1.5;
const BPM_INPUT_CARET_WIDTH: number = 2;
const BPM_INPUT_TRAILING_GUTTER: number = 2;
const BPM_INPUT_DIGIT_WIDTH_RATIO: number = 0.8;
const BPM_INPUT_LINE_HEIGHT_RATIO: number = 1.4;

class BpmInputFocusFrame extends FrameCallback {
  private readonly focus: () => void;

  constructor(focus: () => void) {
    super();
    this.focus = focus;
  }

  onIdle(_timeLeftInNano: number): void {
    this.focus();
  }
}

@Component
export struct EditableBpm {
  @Prop @Watch('onValueChanged') value: number = 120;
  @Prop @Watch('onEditabilityChanged') editable: boolean = false;
  @Prop preserveDisabledAppearance: boolean = false;
  @Prop inputId: string = 'editable-bpm';
  @Prop controlWidth: Length = 96;
  @Prop controlHeight: number = 50;
  @Prop valueFontSize: number = 40;
  @Prop italicValue: boolean = true;
  @Prop valueColor: string = INK;
  @Prop valueShadow: ShadowOptions = { radius: 0, color: '#00000000' };
  @Prop controlCornerRadius: number = 5;
  @Prop controlShadow: ShadowOptions = CONTROL_SHADOW;
  @Prop solidInk: boolean = false;
  @State editing: boolean = false;
  @State draft: string = '';
  @State inputAreaWidth: number = 0;
  @State inputAreaHeight: number = 0;
  private readonly inputController: TextInputController = new TextInputController();
  private editRevision: number = 0;
  onCommit: (value: number) => void = (_value: number): void => {};

  private onValueChanged(): void {
    if (!this.editing) {
      this.draft = `${this.value}`;
    }
  }

  private onEditabilityChanged(): void {
    if (!this.editable) {
      this.cancelEditing();
    }
  }

  private startEditing(): void {
    if (!this.editable || this.editing) {
      return;
    }
    this.draft = `${this.value}`;
    this.editRevision++;
    this.editing = true;
  }

  private requestEditingFocus(): void {
    if (!this.editing || !this.editable) {
      return;
    }
    const revision = this.editRevision;
    // The native field exists only after a deliberate tap. Wait until its
    // layout commits, and never let an old frame reactivate a dismissed edit.
    try {
      this.getUIContext().postFrameCallback(new BpmInputFocusFrame(() => {
        if (this.editing && this.editable && revision === this.editRevision) {
          try {
            this.getUIContext().getFocusController().requestFocus(this.inputId);
          } catch (_error) {
            // A hidden/unmounted page cannot take native focus; another tap
            // may retry once it is visible, without reviving this old request.
            this.cancelEditing();
          }
        }
      }));
    } catch (_error) {
      this.cancelEditing();
    }
  }

  private cancelEditing(): void {
    const wasEditing = this.editing;
    this.editing = false;
    this.editRevision++;
    this.draft = `${this.value}`;
    if (wasEditing) {
      this.inputController.stopEditing();
    }
  }

  aboutToDisappear(): void {
    this.cancelEditing();
  }

  private commitEditing(): void {
    if (!this.editing) {
      return;
    }
    const parsed = Number(this.draft);
    const raw = this.draft;
    // stopEditing can synchronously deliver blur/change callbacks. Invalidate
    // the edit first so those callbacks cannot commit twice or reopen input.
    this.editing = false;
    this.editRevision++;
    this.inputController.stopEditing();
    if (!this.editable) {
      this.draft = `${this.value}`;
      return;
    }
    if (!/^\d+$/.test(raw) || !Number.isInteger(parsed) || parsed < BPM_MIN || parsed > BPM_MAX) {
      this.draft = `${this.value}`;
      showUserNotice(`请输入 ${BPM_MIN}–${BPM_MAX} 之间的 BPM`, `bpm.validation.${this.inputId}`);
      return;
    }
    if (parsed !== this.value) {
      this.onCommit(parsed);
    }
  }

  private updateDraft(raw: string): void {
    if (!this.editable || !this.editing) {
      return;
    }
    this.draft = raw.replace(/[^\d]/g, '').slice(0, 3);
  }

  private updateInputArea(width: number, height: number): void {
    if (Number.isFinite(width) && width > 0 && width !== this.inputAreaWidth) {
      this.inputAreaWidth = width;
    }
    if (Number.isFinite(height) && height > 0 && height !== this.inputAreaHeight) {
      this.inputAreaHeight = height;
    }
  }

  private inputFontSize(): number {
    const width = this.inputAreaWidth > 0 ? this.inputAreaWidth :
      (typeof this.controlWidth === 'number' ? this.controlWidth : 96);
    const height = this.inputAreaHeight > 0 ? this.inputAreaHeight : this.controlHeight;
    const contentWidth = Math.max(1, width - 2 * (BPM_INPUT_PADDING_X + BPM_INPUT_BORDER_WIDTH) -
      BPM_INPUT_CARET_WIDTH - BPM_INPUT_TRAILING_GUTTER);
    const contentHeight = Math.max(1, height - 2 * BPM_INPUT_BORDER_WIDTH);
    let fontScale = 1;
    try {
      const context = this.getUIContext();
      fontScale = Math.max(0.1, context.px2vp(context.fp2px(1)));
    } catch (_error) {
      // The first layout can precede a usable UIContext; area measurement refits it.
    }
    // TextInput may scroll its editing text instead of fitting like Text. Budget
    // three bold italic digits, the caret and a trailing gutter in the actual box.
    const fittedVp = Math.min(contentWidth / (3 * BPM_INPUT_DIGIT_WIDTH_RATIO),
      contentHeight / BPM_INPUT_LINE_HEIGHT_RATIO);
    return Math.max(1, Math.min(this.valueFontSize, fittedVp / fontScale));
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.solidInk && this.editing) {
        Rect().width('100%').height('100%').radius(this.controlCornerRadius).fill(INK)
          .translate({ x: COMIC_CONTROL_INK_OFFSET, y: COMIC_CONTROL_INK_OFFSET })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      if (this.editing) {
        TextInput({ text: this.draft, controller: this.inputController })
          .id(this.inputId)
          .width('100%')
          .height('100%')
          .padding({ left: BPM_INPUT_PADDING_X, right: BPM_INPUT_PADDING_X, top: 0, bottom: 0 })
          .type(InputType.Number)
          .enterKeyType(EnterKeyType.Done)
          .maxLength(3)
          .fontSize(this.inputFontSize())
          .maxLines(1)
          .fontWeight(900)
          .fontStyle(this.italicValue ? FontStyle.Italic : FontStyle.Normal)
          .fontColor(INK)
          .textAlign(TextAlign.Center)
          .caretColor(CORAL)
          .caretStyle({ width: BPM_INPUT_CARET_WIDTH })
          .selectedBackgroundColor('#55FF7056')
          .backgroundColor(PAPER)
          .border({ width: BPM_INPUT_BORDER_WIDTH, color: INK })
          .borderRadius(this.controlCornerRadius)
          .shadow(this.solidInk ? { radius: 0, color: '#00000000' } : this.controlShadow)
          .clip(false)
          .enabled(this.editable)
          .opacity(1)
          .onAppear(() => this.requestEditingFocus())
          .onChange((raw: string) => this.updateDraft(raw))
          .onSubmit(() => this.commitEditing())
          .onBlur(() => this.commitEditing())
      } else {
        ActionButton({ label: `${this.value}`, active: this.editable,
          preserveDisabledAppearance: this.preserveDisabledAppearance,
          controlHeight: this.controlHeight, fill: '#00000000', cornerRadius: this.controlCornerRadius,
          accessibilityLabel: `${this.value} BPM`, action: () => this.startEditing()
        }) {
          Text(`${this.value}`)
            .width('100%')
            .height('100%')
            .fontSize(this.valueFontSize)
            .maxFontSize(this.valueFontSize)
            .minFontSize(14)
            .maxLines(1)
            .fontWeight(900)
            .fontStyle(this.italicValue ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(this.valueColor)
            .textAlign(TextAlign.Center)
            .textShadow(this.editable || this.preserveDisabledAppearance ? this.valueShadow : { radius: 0, color: '#00000000' })
        }
      }
    }.width(this.controlWidth).height(this.controlHeight).clip(false)
      .onAreaChange((_previous: Area, area: Area) => this.updateInputArea(Number(area.width), Number(area.height)))
  }

}
