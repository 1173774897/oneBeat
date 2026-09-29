import { promptAction, router } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { CORAL, INK, LILAC, PAPER, TEAL } from '../components/ComicKit';
import {
  buildDrumPattern,
  defaultDrumProgram,
  DrumProgram,
  DrumSection,
  DrumStyle,
  DrumTrack,
  DRUM_STYLES,
  DRUM_TRACKS,
  FILL_NAMES,
  parseDrumProgram,
  PATTERN_NAMES,
  patternToRows,
  serializeDrumProgram,
  styleByKey
} from '../audio/DrumMachineCatalog';

const FILL_FREQUENCIES: number[] = [1, 2, 4, 8, 16];
const EDITED_LABEL: string = '已编辑';

interface SavedDrumProgram {
  id: string;
  name: string;
  program: string;
}

interface DrumSectionSelectionState {
  patternIndex: number;
  fillIndex: number;
  customRows?: string[];
  customFillRows?: string[];
}

interface DrumContextState {
  key: string;
  selections: DrumSectionSelectionState[];
}

@Entry
@Component
struct DrumMachinePage {
  @State styleKey: string = 'rock';
  @State beatsPerBar: number = 4;
  @State beatUnit: number = 4;
  @State bpm: number = 120;
  @State sections: DrumSection[] = [];
  @State selectedSection: number = 0;
  @State editorVisible: boolean = false;
  @State editorMode: number = 0;
  @State editorRows: string[] = [];
  @State previewTarget: string = '';
  @State saving: boolean = false;
  @State dropdownTarget: string = '';
  @State dropdownAnchorX: number = 0;
  @State dropdownAnchorY: number = 0;
  @State dropdownMenuWidth: number = 126;
  @State dropdownKind: string = '';
  @State dropdownSectionIndex: number = 0;
  @State saveDialogVisible: boolean = false;
  @State overwriteDialogVisible: boolean = false;
  @State saveName: string = '';
  @State savedPrograms: SavedDrumProgram[] = [];
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  private sectionPreviewStopTimerId: number = -1;
  private sectionPreviewRevision: number = 0;
  private contextStates: DrumContextState[] = [];

  aboutToAppear(): void {
    this.loadSavedPrograms();
    const controller = AppSession.get()?.controller;
    let program = defaultDrumProgram();
    if (controller !== undefined && controller.drumProgram.length > 0) {
      program = parseDrumProgram(controller.drumProgram);
    } else {
      const saved = AppStorage.get<string>('myDrumProgram') ?? '';
      if (saved.length > 0) {
        program = parseDrumProgram(saved);
      }
    }
    this.styleKey = program.styleKey;
    this.beatsPerBar = program.beatsPerBar;
    this.beatUnit = program.beatUnit;
    if (controller !== undefined) {
      this.bpm = controller.bpm;
    }
    this.sections = program.sections;
    this.contextStates = [];
    this.storeCurrentContext();
  }

  private loadSavedPrograms(): void {
    const raw = AppStorage.get<string>('savedDrumPrograms') ?? '';
    if (raw.length === 0) {
      this.savedPrograms = [];
      return;
    }
    try {
      this.savedPrograms = JSON.parse(raw) as SavedDrumProgram[];
    } catch (_e) {
      this.savedPrograms = [];
    }
  }

  private openSaveDialog(): void {
    this.dropdownTarget = '';
    this.saveName = `我的节奏 ${this.savedPrograms.length + 1}`;
    this.saveDialogVisible = true;
  }

  private confirmNamedSave(): void {
    const name = this.saveName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '请填写节奏名称' });
      return;
    }
    for (let i = 0; i < this.savedPrograms.length; i++) {
      if (this.savedPrograms[i].name === name) {
        this.saveDialogVisible = false;
        this.overwriteDialogVisible = true;
        return;
      }
    }
    this.persistNamedSave(false);
  }

  private persistNamedSave(overwrite: boolean): void {
    const name = this.saveName.trim();
    const program = serializeDrumProgram(this.currentProgram());
    const next: SavedDrumProgram[] = [];
    let replaced = false;
    for (let i = 0; i < this.savedPrograms.length; i++) {
      const saved = this.savedPrograms[i];
      if (overwrite && saved.name === name) {
        next.push({ id: saved.id, name: name, program: program });
        replaced = true;
      } else {
        next.push(saved);
      }
    }
    if (!replaced) {
      next.unshift({ id: `rhythm-${Date.now()}`, name: name, program: program });
    }
    this.savedPrograms = next;
    AppStorage.setOrCreate('savedDrumPrograms', JSON.stringify(next));
    AppStorage.setOrCreate('myDrumProgram', program);
    this.saveDialogVisible = false;
    this.overwriteDialogVisible = false;
    promptAction.showToast({ message: replaced ? '已更新我的节奏' : '已保存到我的节奏' });
  }

  private returnToRename(): void {
    this.overwriteDialogVisible = false;
    this.saveDialogVisible = true;
  }

  private deleteSavedProgram(id: string): void {
    const next: SavedDrumProgram[] = [];
    for (let i = 0; i < this.savedPrograms.length; i++) {
      if (this.savedPrograms[i].id !== id) {
        next.push(this.savedPrograms[i]);
      }
    }
    this.savedPrograms = next;
    AppStorage.setOrCreate('savedDrumPrograms', JSON.stringify(next));
    promptAction.showToast({ message: '已删除这个节奏' });
  }

  private loadSavedProgram(saved: SavedDrumProgram): void {
    const wasPreviewing = this.previewTarget.length > 0;
    const program = parseDrumProgram(saved.program);
    this.styleKey = program.styleKey;
    this.beatsPerBar = program.beatsPerBar;
    this.beatUnit = program.beatUnit;
    this.sections = program.sections;
    this.selectedSection = 0;
    this.dropdownTarget = '';
    this.contextStates = [];
    this.storeCurrentContext();
    promptAction.showToast({ message: `已载入 ${saved.name}` });
    if (wasPreviewing) {
      void this.refreshActivePreview();
    }
  }

  private savedProgramMeter(saved: SavedDrumProgram): string {
    const program = parseDrumProgram(saved.program);
    return `${program.beatsPerBar}/${program.beatUnit}`;
  }

  private savedProgramStyle(saved: SavedDrumProgram): string {
    return styleByKey(parseDrumProgram(saved.program).styleKey).name;
  }

  aboutToDisappear(): void {
    this.cancelSectionPreviewStop();
    AppSession.get()?.stopDrumPreview();
  }

  private currentProgram(): DrumProgram {
    return {
      styleKey: this.styleKey,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
      sections: this.sections
    };
  }

  private copySection(section: DrumSection): DrumSection {
    return {
      id: section.id,
      patternIndex: section.patternIndex,
      repeats: section.repeats,
      fillIndex: section.fillIndex,
      fillEvery: section.fillEvery,
      customRows: section.customRows,
      customFillRows: section.customFillRows
    };
  }

  private contextKey(styleKey: string, beats: number, unit: number): string {
    return `${styleKey}-${beats}-${unit}`;
  }

  private copyOptionalRows(rows?: string[]): string[] | undefined {
    return rows === undefined ? undefined : rows.slice();
  }

  private storeCurrentContext(): void {
    if (this.sections.length === 0) {
      return;
    }
    const selections: DrumSectionSelectionState[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      selections.push({
        patternIndex: this.sections[i].patternIndex,
        fillIndex: this.sections[i].fillIndex,
        customRows: this.copyOptionalRows(this.sections[i].customRows),
        customFillRows: this.copyOptionalRows(this.sections[i].customFillRows)
      });
    }
    const key = this.contextKey(this.styleKey, this.beatsPerBar, this.beatUnit);
    const next: DrumContextState[] = [];
    let replaced = false;
    for (let i = 0; i < this.contextStates.length; i++) {
      if (this.contextStates[i].key === key) {
        next.push({ key: key, selections: selections });
        replaced = true;
      } else {
        next.push(this.contextStates[i]);
      }
    }
    if (!replaced) {
      next.push({ key: key, selections: selections });
    }
    this.contextStates = next;
  }

  private restoreContext(styleKey: string, beats: number, unit: number): void {
    const key = this.contextKey(styleKey, beats, unit);
    let saved: DrumContextState | undefined = undefined;
    for (let i = 0; i < this.contextStates.length; i++) {
      if (this.contextStates[i].key === key) {
        saved = this.contextStates[i];
        break;
      }
    }
    const next: DrumSection[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      const section = this.copySection(this.sections[i]);
      if (saved !== undefined && i < saved.selections.length) {
        const selection = saved.selections[i];
        section.patternIndex = selection.patternIndex;
        section.fillIndex = selection.fillIndex;
        section.customRows = this.copyOptionalRows(selection.customRows);
        section.customFillRows = this.copyOptionalRows(selection.customFillRows);
      } else {
        section.patternIndex = 0;
        section.fillIndex = 0;
        section.customRows = undefined;
        section.customFillRows = undefined;
      }
      next.push(section);
    }
    this.sections = next;
  }

  private chooseStyle(styleKey: string): void {
    if (this.styleKey === styleKey) {
      return;
    }
    this.storeCurrentContext();
    this.styleKey = styleKey;
    this.restoreContext(styleKey, this.beatsPerBar, this.beatUnit);
    this.dropdownTarget = '';
    void this.refreshActivePreview();
  }

  private replaceSection(index: number, section: DrumSection): void {
    const next: DrumSection[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      next.push(i === index ? section : this.sections[i]);
    }
    this.sections = next;
  }

  private openDropdownFromAnchor(target: string, anchorId: string, menuWidth: number): void {
    if (this.dropdownTarget === target) {
      this.closeDropdown();
      return;
    }
    const parts = target.split('-');
    const sectionIndex = Number.parseInt(parts[parts.length - 1], 10);
    this.dropdownKind = parts.slice(1, parts.length - 1).join('-');
    this.dropdownSectionIndex = sectionIndex;
    this.dropdownMenuWidth = menuWidth;
    try {
      const uiContext = this.getUIContext();
      const rect = uiContext.getComponentUtils().getRectangleById(anchorId);
      this.dropdownAnchorX = uiContext.px2vp(rect.windowOffset.x);
      this.dropdownAnchorY = uiContext.px2vp(rect.windowOffset.y + rect.size.height);
      this.dropdownTarget = target;
    } catch (_e) {
      this.dropdownAnchorX = 59;
      this.dropdownAnchorY = 120;
      this.dropdownTarget = target;
    }
  }

  private closeDropdown(): void {
    this.dropdownTarget = '';
    this.dropdownKind = '';
  }

  private notifySectionEdited(index: number): void {
    const target = this.previewTarget;
    if (target.length === 0) {
      return;
    }
    if (target === 'song') {
      void this.refreshActivePreview();
      return;
    }
    if (target === `pattern-${index}`) {
      void this.restartSectionPreview(index, false, this.sections[index]);
      return;
    }
    if (target === `fill-${index}`) {
      void this.restartSectionPreview(index, true, this.sections[index]);
    }
  }

  /** 段落增删后：整曲试听重播；段落试听按新下标续播或停止 */
  private afterSectionsStructureChanged(removedIndex: number = -1): void {
    const target = this.previewTarget;
    if (target.length === 0) {
      return;
    }
    if (target === 'song') {
      void this.refreshActivePreview();
      return;
    }
    if (removedIndex < 0) {
      return;
    }
    let sectionIndex = -1;
    let withFill = false;
    if (target.startsWith('pattern-')) {
      sectionIndex = parseInt(target.substring('pattern-'.length), 10);
      withFill = false;
    } else if (target.startsWith('fill-')) {
      sectionIndex = parseInt(target.substring('fill-'.length), 10);
      withFill = true;
    } else {
      return;
    }
    if (sectionIndex === removedIndex) {
      sectionIndex = Math.min(removedIndex, this.sections.length - 1);
    } else if (sectionIndex > removedIndex) {
      sectionIndex--;
    }
    if (sectionIndex < 0 || sectionIndex >= this.sections.length) {
      this.cancelSectionPreviewStop();
      AppSession.get()?.stopDrumPreview();
      this.previewTarget = '';
      return;
    }
    this.previewTarget = `${withFill ? 'fill' : 'pattern'}-${sectionIndex}`;
    void this.restartSectionPreview(sectionIndex, withFill, this.sections[sectionIndex]);
  }

  private updatePattern(index: number, patternIndex: number): void {
    const section = this.copySection(this.sections[index]);
    section.patternIndex = patternIndex;
    section.customRows = undefined;
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private updateRepeats(index: number, delta: number): void {
    const section = this.copySection(this.sections[index]);
    section.repeats = Math.max(1, Math.min(16, section.repeats + delta));
    this.replaceSection(index, section);
    this.notifySectionEdited(index);
  }

  private updateFill(index: number, fillIndex: number): void {
    const section = this.copySection(this.sections[index]);
    section.fillIndex = fillIndex;
    section.customFillRows = undefined;
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private updateFillEvery(index: number, delta: number): void {
    const section = this.copySection(this.sections[index]);
    section.fillEvery = Math.max(1, Math.min(16, section.fillEvery + delta));
    this.replaceSection(index, section);
    this.notifySectionEdited(index);
  }

  private selectFillEvery(index: number, optionIndex: number): void {
    if (optionIndex < 0 || optionIndex >= FILL_FREQUENCIES.length) {
      return;
    }
    const section = this.copySection(this.sections[index]);
    section.fillEvery = FILL_FREQUENCIES[optionIndex];
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private fillEveryOptionIndex(value: number): number {
    for (let i = 0; i < FILL_FREQUENCIES.length; i++) {
      if (FILL_FREQUENCIES[i] === value) {
        return i;
      }
    }
    return 0;
  }

  private addSection(): void {
    if (this.sections.length >= 8) {
      promptAction.showToast({ message: '最多编排 8 个段落' });
      return;
    }
    const id = String.fromCharCode(65 + this.sections.length);
    const next = this.sections.slice();
    next.push({ id: id, patternIndex: 0, repeats: 4, fillIndex: 0, fillEvery: 4 });
    this.sections = next;
    this.selectedSection = next.length - 1;
    this.afterSectionsStructureChanged();
  }

  private deleteSection(index: number): void {
    if (this.sections.length <= 1) {
      promptAction.showToast({ message: '至少保留一个段落' });
      return;
    }
    const next: DrumSection[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      if (i !== index) {
        const section = this.copySection(this.sections[i]);
        section.id = String.fromCharCode(65 + next.length);
        next.push(section);
      }
    }
    this.sections = next;
    if (this.selectedSection > index) {
      this.selectedSection--;
    } else if (this.selectedSection === index) {
      this.selectedSection = Math.min(index, next.length - 1);
    }
    this.afterSectionsStructureChanged(index);
  }

  private requestDeleteSection(index: number): void {
    this.deleteSection(index);
  }

  private chooseMeter(beats: number, unit: number): void {
    if (this.beatsPerBar === beats && this.beatUnit === unit) {
      return;
    }
    this.storeCurrentContext();
    this.beatsPerBar = beats;
    this.beatUnit = unit;
    this.restoreContext(this.styleKey, beats, unit);
    this.dropdownTarget = '';
    void this.refreshActivePreview();
  }

  private editorStepCount(): number {
    return this.beatsPerBar * (this.beatUnit === 8 ? 2 : 4);
  }

  private editorStepIndexes(): number[] {
    return Array.from({ length: this.editorStepCount() }, (_value: number, step: number) => step);
  }

  private editorStepGroups(): string[] {
    return this.editorStepCount() === 16 ? ['1–4', '5–8', '9–12', '13–16'] :
      ['1–4', '5–8', '9–12'];
  }

  private openEditor(index: number, mode: number): void {
    this.selectedSection = index;
    this.editorMode = mode;
    const section = this.sections[index];
    if (mode === 0) {
      this.editorRows = section.customRows !== undefined ? section.customRows : patternToRows(
        buildDrumPattern(this.styleKey, section.patternIndex, this.beatsPerBar, this.beatUnit),
        this.beatsPerBar, this.beatUnit);
    } else {
      this.editorRows = section.customFillRows !== undefined ? section.customFillRows : patternToRows(
        buildDrumPattern(this.styleKey, section.patternIndex, this.beatsPerBar, this.beatUnit,
          section.fillIndex, section.customRows), this.beatsPerBar, this.beatUnit);
    }
    this.editorVisible = true;
  }

  private toggleStep(track: number, step: number): void {
    const rows = this.editorRows.slice();
    const row = rows[track];
    const nextValue = row.charAt(step) === '1' ? '0' : '1';
    rows[track] = row.substring(0, step) + nextValue + row.substring(step + 1);
    this.editorRows = rows;
  }

  private saveEditor(): void {
    const section = this.copySection(this.sections[this.selectedSection]);
    if (this.editorMode === 0) {
      section.customRows = this.editorRows.slice();
    } else {
      section.customFillRows = this.editorRows.slice();
    }
    this.replaceSection(this.selectedSection, section);
    this.editorVisible = false;
    this.notifySectionEdited(this.selectedSection);
    promptAction.showToast({ message: this.editorMode === 0 ? '节奏型已编辑' : '加花已编辑' });
  }

  private cancelSectionPreviewStop(): void {
    this.sectionPreviewRevision++;
    if (this.sectionPreviewStopTimerId >= 0) {
      clearTimeout(this.sectionPreviewStopTimerId);
      this.sectionPreviewStopTimerId = -1;
    }
  }

  private armSectionPreviewStop(target: string, barCount: number = 1): void {
    this.cancelSectionPreviewStop();
    const revision = this.sectionPreviewRevision;
    const bars = Math.max(1, barCount);
    const durationMs = 350 + Math.ceil(this.beatsPerBar * bars * 60000 / Math.max(1, this.bpm)) + 80;
    this.sectionPreviewStopTimerId = setTimeout(() => {
      if (revision !== this.sectionPreviewRevision || this.previewTarget !== target) {
        return;
      }
      this.sectionPreviewStopTimerId = -1;
      AppSession.get()?.stopDrumPreview();
      this.previewTarget = '';
    }, durationMs);
  }

  private async previewProgram(program: DrumProgram, target: string, looping: boolean = true): Promise<boolean> {
    if (this.previewTarget === target) {
      this.cancelSectionPreviewStop();
      AppSession.get()?.stopDrumPreview();
      this.previewTarget = '';
      return false;
    }
    if (this.previewTarget.length > 0) {
      return false;
    }
    try {
      this.cancelSectionPreviewStop();
      this.previewTarget = target;
      await this.startPreviewPlayback(program, looping);
      return this.previewTarget === target;
    } catch (_e) {
      this.previewTarget = '';
      promptAction.showToast({ message: '试听启动失败' });
      return false;
    }
  }

  private async startPreviewPlayback(program: DrumProgram, looping: boolean): Promise<void> {
    await AppSession.get()?.previewDrumProgram(
      serializeDrumProgram(program), looping, this.bpm, this.beatsPerBar);
  }

  private async refreshActivePreview(): Promise<void> {
    const target = this.previewTarget;
    if (target.length === 0) {
      return;
    }
    if (target === 'song') {
      await this.restartSongPreview();
      return;
    }
    if (target.startsWith('pattern-')) {
      const index = parseInt(target.substring('pattern-'.length), 10);
      if (index >= 0 && index < this.sections.length) {
        await this.restartSectionPreview(index, false, this.sections[index]);
      } else {
        this.stopActivePreview();
      }
      return;
    }
    if (target.startsWith('fill-')) {
      const index = parseInt(target.substring('fill-'.length), 10);
      if (index >= 0 && index < this.sections.length) {
        await this.restartSectionPreview(index, true, this.sections[index]);
      } else {
        this.stopActivePreview();
      }
    }
  }

  private stopActivePreview(): void {
    this.cancelSectionPreviewStop();
    AppSession.get()?.stopDrumPreview();
    this.previewTarget = '';
  }

  private async restartSongPreview(): Promise<void> {
    if (this.previewTarget !== 'song') {
      return;
    }
    this.cancelSectionPreviewStop();
    try {
      await this.startPreviewPlayback(this.currentProgram(), true);
    } catch (_e) {
      this.previewTarget = '';
      promptAction.showToast({ message: '切换试听失败' });
    }
  }

  private async togglePreview(): Promise<void> {
    await this.previewProgram(this.currentProgram(), 'song');
  }

  private buildSectionPreviewProgram(sectionSource: DrumSection, withFill: boolean): DrumProgram {
    const section = this.copySection(sectionSource);
    if (!withFill) {
      section.fillEvery = 0;
    }
    return {
      styleKey: this.styleKey,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
      sections: [section]
    };
  }

  private sectionPreviewBarCount(section: DrumSection, withFill: boolean): number {
    if (!withFill) {
      return section.repeats;
    }
    return Math.max(section.repeats, section.fillEvery);
  }

  private async previewSection(index: number, withFill: boolean): Promise<void> {
    const target = `${withFill ? 'fill' : 'pattern'}-${index}`;
    const started = await this.previewProgram(
      this.buildSectionPreviewProgram(this.sections[index], withFill), target, false);
    if (started && this.previewTarget === target) {
      this.armSectionPreviewStop(target, this.sectionPreviewBarCount(this.sections[index], withFill));
    }
  }

  private async restartSectionPreview(index: number, withFill: boolean, section: DrumSection): Promise<void> {
    const target = `${withFill ? 'fill' : 'pattern'}-${index}`;
    if (this.previewTarget !== target) {
      return;
    }
    this.cancelSectionPreviewStop();
    const revision = this.sectionPreviewRevision;
    try {
      await this.startPreviewPlayback(this.buildSectionPreviewProgram(section, withFill), false);
      if (revision === this.sectionPreviewRevision && this.previewTarget === target) {
        this.armSectionPreviewStop(target, this.sectionPreviewBarCount(section, withFill));
      }
    } catch (_e) {
      if (this.previewTarget === target) {
        this.previewTarget = '';
      }
      promptAction.showToast({ message: '切换试听失败' });
    }
  }

  private saveLocal(): void {
    AppStorage.setOrCreate('myDrumProgram', serializeDrumProgram(this.currentProgram()));
    promptAction.showToast({ message: '已保存编排' });
  }

  private isLeader(): boolean {
    return AppSession.get()?.controller.isLeader === true;
  }

  private async changeBpm(delta: number): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader) {
      return;
    }
    await controller.updateBpm(controller.bpm + delta);
    this.bpm = controller.bpm;
    void this.refreshActivePreview();
  }

  private async applyToTeam(): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader || this.saving) {
      return;
    }
    this.saving = true;
    try {
      const raw = serializeDrumProgram(this.currentProgram());
      AppStorage.setOrCreate('myDrumProgram', raw);
      if (controller.rhythm >= 0 && controller.rhythm <= 2) {
        AppStorage.setOrCreate('lastBasicRhythm', controller.rhythm);
      }
      AppSession.get()?.stopDrumPreview();
      await controller.updateMeter(this.beatsPerBar, this.beatUnit);
      await controller.updateDrumProgram(raw);
      promptAction.showToast({ message: '鼓机编排已应用到队伍' });
      router.back();
    } catch (_e) {
      promptAction.showToast({ message: '应用失败，请重试' });
    } finally {
      this.saving = false;
    }
  }

  @Builder
  private smallStepper(value: number, minus: () => void, plus: () => void) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Text('-').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
      }.width(34).height(32).padding(0).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).onClick(minus)
      Text(`${value}`).width(30).textAlign(TextAlign.Center).fontSize(19).fontWeight(900)
      Button({ type: ButtonType.Normal }) {
        Text('+').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
      }.width(34).height(32).padding(0).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).onClick(plus)
    }
  }

  @Builder
  private patternDropdownPanel(sectionIndex: number) {
    Column({ space: 3 }) {
      ForEach(PATTERN_NAMES, (name: string, patternIndex: number) => {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(name).fontSize(13).fontWeight(FontWeight.Bold)
            Blank()
            if (this.sections[sectionIndex].customRows === undefined &&
              this.sections[sectionIndex].patternIndex === patternIndex) {
              Text('✓').fontSize(13).fontWeight(900)
            }
          }.width('100%')
        }.width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
        .backgroundColor(this.sections[sectionIndex].customRows === undefined &&
          this.sections[sectionIndex].patternIndex === patternIndex ? CORAL : PAPER)
        .border({ width: 1, color: INK }).borderRadius(4)
        .onClick(() => this.updatePattern(sectionIndex, patternIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).clip(true)
  }

  @Builder
  private fillDropdownPanel(sectionIndex: number) {
    Column({ space: 3 }) {
      ForEach(FILL_NAMES, (name: string, fillIndex: number) => {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(name).fontSize(13).fontWeight(FontWeight.Bold)
            Blank()
            if (this.sections[sectionIndex].customFillRows === undefined &&
              this.sections[sectionIndex].fillIndex === fillIndex) {
              Text('✓').fontSize(13).fontWeight(900)
            }
          }.width('100%')
        }.width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
        .backgroundColor(this.sections[sectionIndex].customFillRows === undefined &&
          this.sections[sectionIndex].fillIndex === fillIndex ? '#FFD36A' : PAPER)
        .border({ width: 1, color: INK }).borderRadius(4)
        .onClick(() => this.updateFill(sectionIndex, fillIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).clip(true)
  }

  @Builder
  private frequencyDropdownPanel(sectionIndex: number) {
    Column({ space: 3 }) {
      ForEach(FILL_FREQUENCIES, (frequency: number, optionIndex: number) => {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(`每${frequency}小节`).fontSize(13).fontWeight(FontWeight.Bold)
            Blank()
            if (this.sections[sectionIndex].fillEvery === frequency) {
              Text('✓').fontSize(13).fontWeight(900)
            }
          }.width('100%')
        }.width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
        .backgroundColor(this.sections[sectionIndex].fillEvery === frequency ? LILAC : PAPER)
        .border({ width: 1, color: INK }).borderRadius(4)
        .onClick(() => this.selectFillEvery(sectionIndex, optionIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).clip(true)
  }

  @Builder
  private sectionDropdownOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .onClick(() => this.closeDropdown())
      Column() {
        if (this.dropdownKind === 'pattern') {
          this.patternDropdownPanel(this.dropdownSectionIndex);
        } else if (this.dropdownKind === 'fill') {
          this.fillDropdownPanel(this.dropdownSectionIndex);
        } else if (this.dropdownKind === 'frequency') {
          this.frequencyDropdownPanel(this.dropdownSectionIndex);
        }
      }
      .position({ x: this.dropdownAnchorX, y: this.dropdownAnchorY })
    }
    .width('100%')
    .height('100%')
    .zIndex(85)
  }

  @Builder
  private sectionCard(index: number) {
    Column({ space: 11 }) {
      Row() {
        Text(`段落 ${this.sections[index].id}`).fontSize(19).fontWeight(900).fontStyle(FontStyle.Italic)
          .onClick(() => this.selectedSection = index)
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('×').fontSize(20).fontWeight(900).fontColor('#D83A2E').lineHeight(22)
        }.width(28).height(28).padding(0).backgroundColor('#FFF1E8')
          .border({ width: 1, color: INK }).borderRadius(5)
          .onClick(() => this.requestDeleteSection(index))
        Text(this.selectedSection === index ? '⌃' : '⌄').fontSize(22).width(30).textAlign(TextAlign.Center)
          .onClick(() => this.selectedSection = index)
      }.width('100%')
      if (this.selectedSection === index) {
        Row({ space: 7 }) {
          Text('节奏型').fontSize(13).fontWeight(FontWeight.Bold).width(52)
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(this.sections[index].customRows !== undefined ? EDITED_LABEL :
                PATTERN_NAMES[this.sections[index].patternIndex]).fontSize(13).fontWeight(FontWeight.Bold)
              Blank()
              Text(this.dropdownTarget === `menu-pattern-${index}` ? '⌃' : '⌄').fontSize(15)
            }.width('100%')
          }.id(`dm-pattern-${index}`).layoutWeight(1).height(34).padding({ left: 8, right: 7 })
          .fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1, color: INK }).borderRadius(5)
          .onClick(() => this.openDropdownFromAnchor(`menu-pattern-${index}`, `dm-pattern-${index}`, 126))
          Button(this.previewTarget === `pattern-${index}` ? '停止' : '试听', { type: ButtonType.Normal })
            .width(54).height(34).padding(0).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5)
            .enabled(this.previewTarget.length === 0 || this.previewTarget === `pattern-${index}`)
            .onClick(() => { void this.previewSection(index, false); })
          Button('编辑', { type: ButtonType.Normal }).width(54).height(34).padding(0)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5)
            .onClick(() => this.openEditor(index, 0))
        }.width('100%')
        Row({ space: 8 }) {
          Text('重复').fontSize(13).fontWeight(FontWeight.Bold).width(52)
          this.smallStepper(this.sections[index].repeats,
            () => this.updateRepeats(index, -1), () => this.updateRepeats(index, 1))
          Text('小节').fontSize(13)
          Blank()
        }.width('100%')
        Row({ space: 7 }) {
          Text('加花').fontSize(13).fontWeight(FontWeight.Bold).width(52)
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(this.sections[index].customFillRows !== undefined ? EDITED_LABEL :
                FILL_NAMES[this.sections[index].fillIndex]).fontSize(13).fontWeight(FontWeight.Bold)
              Blank()
              Text(this.dropdownTarget === `menu-fill-${index}` ? '⌃' : '⌄').fontSize(15)
            }.width('100%')
          }.id(`dm-fill-${index}`).layoutWeight(1).height(34).padding({ left: 8, right: 7 })
          .fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1, color: INK }).borderRadius(5)
          .onClick(() => this.openDropdownFromAnchor(`menu-fill-${index}`, `dm-fill-${index}`, 126))
          Button(this.previewTarget === `fill-${index}` ? '停止' : '试听', { type: ButtonType.Normal })
            .width(54).height(34).padding(0).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5)
            .enabled(this.previewTarget.length === 0 || this.previewTarget === `fill-${index}`)
            .onClick(() => { void this.previewSection(index, true); })
          Button('编辑', { type: ButtonType.Normal }).width(54).height(34).padding(0)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5)
            .onClick(() => this.openEditor(index, 1))
        }.width('100%')
        Row({ space: 7 }) {
          Text('频率').fontSize(13).fontWeight(FontWeight.Bold).width(52)
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(`每${this.sections[index].fillEvery}小节`).fontSize(13).fontWeight(FontWeight.Bold)
              Blank()
              Text(this.dropdownTarget === `menu-frequency-${index}` ? '⌃' : '⌄').fontSize(15)
            }.width('100%')
          }.id(`dm-frequency-${index}`).width(122).height(34).padding({ left: 8, right: 7 })
          .fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1, color: INK }).borderRadius(5)
          .onClick(() => this.openDropdownFromAnchor(`menu-frequency-${index}`, `dm-frequency-${index}`, 122))
          Blank()
        }.width('100%')
      }
    }
    .width('100%').padding(12).backgroundColor('#FFFDF7')
    .border({ width: 1.5, color: INK }).borderRadius(7)
    .shadow({ radius: 0, offsetX: 2, offsetY: 3, color: this.selectedSection === index ? CORAL : '#D8D0C1' })
  }

  @Builder
  private savedProgramCard(saved: SavedDrumProgram) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 5 }) {
        Text(saved.name).fontSize(13).fontWeight(900).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width(76)
        Row() {
          Text('♪').fontSize(16).fontWeight(900)
          Text(this.savedProgramMeter(saved)).fontSize(12).fontWeight(FontWeight.Bold).margin({ left: 4 })
          Blank()
          Text(this.savedProgramStyle(saved)).fontSize(10).fontColor('#615B53')
        }.width('100%')
        Button('载入', { type: ButtonType.Normal }).width(48).height(20).padding(0).fontSize(9)
          .fontWeight(FontWeight.Bold).fontColor(INK).backgroundColor('#BDE9E3')
          .border({ width: 1, color: INK }).borderRadius(10)
          .onClick(() => this.loadSavedProgram(saved))
      }.width('100%').height('100%').padding(9)
      Button('×', { type: ButtonType.Normal }).width(23).height(23).padding(0).fontSize(18).fontWeight(900)
        .fontColor(INK).backgroundColor(CORAL).border({ width: 1.2, color: INK }).borderRadius(12)
        .position({ x: 89, y: 4 }).zIndex(2)
        .onClick(() => this.deleteSavedProgram(saved.id))
    }
    .width(116).height(82).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(6)
    .shadow({ radius: 0, offsetX: 2, offsetY: 2, color: '#D4CBBE' })
  }

  @Builder
  private saveDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row() {
          Text('保存到我的节奏').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic)
          Blank()
          Text('×').fontSize(27).fontWeight(900).onClick(() => this.saveDialogVisible = false)
        }.width('100%')
        Divider().strokeWidth(1).color('#CEC4B6')
        Text('给这套鼓机编排起一个名字').fontSize(13).fontWeight(FontWeight.Bold).width('100%')
        TextInput({ text: this.saveName, placeholder: '例如：夜跑推进' })
          .height(44).fontSize(15).fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1.5, color: INK }).borderRadius(5).maxLength(16)
          .onChange((value: string) => this.saveName = value)
        Row({ space: 9 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.saveDialogVisible = false)
          Button('保存', { type: ButtonType.Normal }).layoutWeight(1.4).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.confirmNamedSave())
        }.width('100%')
      }
      .width('88%').padding(16).backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK }).borderRadius(8)
      .shadow({ radius: 0, offsetX: 6, offsetY: 7, color: INK })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(110)
  }

  @Builder
  private overwriteDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text('同名警告').fontSize(12).fontWeight(900).fontColor(PAPER).backgroundColor(INK)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -3 })
        Text('这个名字已经存在').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text(`继续保存会覆盖「${this.saveName.trim()}」的原有编排。`)
          .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
        Divider().strokeWidth(1).color('#C8BFB1')
        Row({ space: 9 }) {
          Button('返回改名', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.returnToRename())
          Button('覆盖保存', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5)
            .onClick(() => this.persistNamedSave(true))
        }.width('100%')
      }
      .width('88%').padding(17).backgroundColor('#FFF1D7')
      .border({ width: 2.5, color: INK }).borderRadius(8)
      .shadow({ radius: 0, offsetX: 7, offsetY: 8, color: INK })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(120)
  }

  @Builder
  private editorOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 10 }) {
        Row() {
          Text(`${this.editorMode === 0 ? '编辑主节奏' : '编辑加花'} · 段落 ${this.sections[this.selectedSection].id}`)
            .fontSize(21).fontWeight(900).fontStyle(FontStyle.Italic)
          Blank()
          Text('×').fontSize(28).onClick(() => this.editorVisible = false)
        }.width('100%')
        Text(`${this.beatsPerBar}/${this.beatUnit} · 第 1 小节 · 点击格子开关鼓点`)
          .fontSize(11).fontColor('#625D55').width('100%')
        Column({ space: 6 }) {
          Row({ space: 5 }) {
            Text('').width(44)
            Row({ space: 4 }) {
              ForEach(this.editorStepGroups(), (group: string) => {
                Text(group).layoutWeight(1).height(18).textAlign(TextAlign.Center)
                  .fontSize(9).fontWeight(FontWeight.Bold).fontColor('#625D55')
                  .border({ width: { top: 1, left: 1, right: 1 }, color: '#9A9287' })
              })
            }.layoutWeight(1)
          }.width('100%')
          Row({ space: 5 }) {
            Text('').width(44)
            Row({ space: 1 }) {
              ForEach(this.editorStepIndexes(), (step: number) => {
                Text(`${step + 1}`).layoutWeight(1).height(16).textAlign(TextAlign.Center)
                  .fontSize(8).fontWeight(FontWeight.Bold).fontColor(INK)
              })
            }.layoutWeight(1)
          }.width('100%')
          ForEach(DRUM_TRACKS, (track: DrumTrack, trackIndex: number) => {
            Row({ space: 5 }) {
              Text(track.name).width(44).fontSize(10).fontWeight(FontWeight.Bold).maxLines(1)
              Row({ space: 1 }) {
                ForEach(this.editorStepIndexes(), (step: number) => {
                  Button('', { type: ButtonType.Normal }).layoutWeight(1).height(25).padding(0).borderRadius(3)
                    .backgroundColor(this.editorRows[trackIndex].charAt(step) === '1' ?
                      (step % (this.beatUnit === 8 ? 2 : 4) === 0 ? CORAL : TEAL) : '#E9E2D5')
                    .border({ width: 1, color: INK }).onClick(() => this.toggleStep(trackIndex, step))
                })
              }.layoutWeight(1)
            }.height(28).width('100%')
          })
        }.width('100%').padding({ left: 8, right: 8, top: 9, bottom: 10 })
        .backgroundColor(PAPER).border({ width: 1, color: INK }).borderRadius(5)
        Row({ space: 8 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontColor(INK)
            .backgroundColor(PAPER).border({ width: 1, color: INK }).borderRadius(5)
            .onClick(() => this.editorVisible = false)
          Button(this.editorMode === 0 ? '应用到节奏型' : '应用到加花', { type: ButtonType.Normal })
            .layoutWeight(2).height(42).fontColor(INK)
            .backgroundColor(CORAL).border({ width: 1, color: INK }).borderRadius(5)
            .onClick(() => this.saveEditor())
        }.width('100%')
      }
      .width('96%').padding(12).backgroundColor('#FFF9EEF8').border({ width: 2, color: INK }).borderRadius(8)
      .shadow({ radius: 0, offsetX: 5, offsetY: 6, color: INK })
    }
    .width('100%').height('100%').backgroundColor('#66000000').zIndex(100)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('‹').fontSize(32).width(32).onClick(() => router.back())
            Text('定制鼓机').fontSize(30).fontWeight(900).fontStyle(FontStyle.Italic)
            Text(' PRO ').fontSize(10).fontWeight(FontWeight.Bold).fontColor(PAPER).backgroundColor(INK)
              .padding({ left: 5, right: 5, top: 3, bottom: 3 }).rotate({ angle: -4 })
            Blank()
            Button('保存', { type: ButtonType.Normal }).height(36).fontColor(INK).backgroundColor(CORAL)
              .border({ width: 1.5, color: INK }).borderRadius(18).onClick(() => this.openSaveDialog())
          }.width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('选择风格').fontSize(16).fontWeight(900)
            Blank()
            Row({ space: 3 }) {
              Text('横滑查看更多').fontSize(10).fontWeight(FontWeight.Bold)
              Text('→').fontSize(16).fontWeight(900)
            }.height(26).padding({ left: 9, right: 8 }).backgroundColor(LILAC)
            .border({ width: 1, color: INK }).borderRadius(13)
          }.width('100%')
          Scroll() {
            Row({ space: 8 }) {
              ForEach(DRUM_STYLES, (style: DrumStyle) => {
                Column({ space: 2 }) {
                  Text(style.name).fontSize(13).fontWeight(900)
                  Text(style.caption).fontSize(9)
                }.padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.styleKey === style.key ? style.color : PAPER)
                .border({ width: 1, color: INK }).borderRadius(5)
                .onClick(() => this.chooseStyle(style.key))
              }, (style: DrumStyle) => style.key)
            }.padding({ bottom: 4 })
          }.scrollable(ScrollDirection.Horizontal).width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('拍号').fontSize(16).fontWeight(900).width(58)
            ForEach([4, 3, 6], (beats: number) => {
              Button(`${beats}/${beats === 6 ? 8 : 4}`, { type: ButtonType.Normal }).layoutWeight(1).height(38)
                .fontColor(INK).backgroundColor(this.beatsPerBar === beats ? CORAL : PAPER)
                .border({ width: 1, color: INK }).borderRadius(4)
              .onClick(() => this.chooseMeter(beats, beats === 6 ? 8 : 4))
            })
          }.width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row({ space: 8 }) {
            Text('BPM').fontSize(16).fontWeight(900).width(58)
            Button({ type: ButtonType.Normal }) {
              Text('−').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
            }.width(38).height(38).padding(0).backgroundColor(PAPER)
              .border({ width: 1, color: INK }).borderRadius(4)
              .enabled(this.isLeader() && this.bpm > 40)
              .onClick(() => { void this.changeBpm(-1); })
            Text(`${this.bpm}`).layoutWeight(1).textAlign(TextAlign.Center)
              .fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
            Button({ type: ButtonType.Normal }) {
              Text('+').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
            }.width(38).height(38).padding(0).backgroundColor(PAPER)
              .border({ width: 1, color: INK }).borderRadius(4)
              .enabled(this.isLeader() && this.bpm < 240)
              .onClick(() => { void this.changeBpm(1); })
          }.width('100%')
          Text(`每分钟 ${this.bpm} 个${this.beatUnit === 8 ? '八分' : '四分'}音符拍点`)
            .fontSize(11).fontColor('#66615A').width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('编排').fontSize(16).fontWeight(900)
            Blank()
            Text(`${styleByKey(this.styleKey).name} · ${this.sections.length} 段`).fontSize(11).fontColor('#655E55')
          }.width('100%')
          ForEach(this.sections, (_section: DrumSection, index: number) => {
            this.sectionCard(index)
          }, (section: DrumSection) => `${section.id}-${section.patternIndex}-${section.repeats}-${section.fillEvery}`)
          Button('+ 新增段落', { type: ButtonType.Normal }).width('100%').height(46).fontSize(17).fontWeight(900)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(6)
            .onClick(() => this.addSection())
          Row({ space: 8 }) {
            Button(this.previewTarget === 'song' ? '■ 停止整曲' : '▶ 试听整曲',
              { type: ButtonType.Normal }).layoutWeight(1).height(48)
              .fontColor(INK).backgroundColor('#BDE9E3').border({ width: 1.5, color: INK }).borderRadius(6)
              .enabled(this.previewTarget.length === 0 || this.previewTarget === 'song')
              .onClick(() => { void this.togglePreview(); })
            Button(this.saving ? '应用中…' : '应用到队伍 ›', { type: ButtonType.Normal }).layoutWeight(1.4).height(48)
              .fontColor(INK).fontWeight(900).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6)
              .enabled(!this.saving).onClick(() => { void this.applyToTeam(); })
          }.width('100%')
          Text('节奏、加花与段落会作为轻量事件同步；每台设备使用本地鼓组采样播放。')
            .fontSize(10).fontColor('#686158').width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('我的节奏').fontSize(16).fontWeight(900)
            Blank()
            Text(`${this.savedPrograms.length} 个编排`).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#655E55')
          }.width('100%')
          if (this.savedPrograms.length === 0) {
            Row() {
              Text('点击右上角“保存”，命名后会出现在这里。').fontSize(12).fontColor('#716A61')
            }.width('100%').height(58).padding({ left: 12, right: 12 })
            .backgroundColor('#FFFDF7').border({ width: 1, color: '#C8BFB1' }).borderRadius(6)
          } else {
            Scroll() {
              Row({ space: 9 }) {
                ForEach(this.savedPrograms, (saved: SavedDrumProgram) => {
                  this.savedProgramCard(saved)
                }, (saved: SavedDrumProgram) => saved.id)
              }.padding({ bottom: 4 })
            }.scrollable(ScrollDirection.Horizontal).width('100%')
          }
        }.padding({ left: 16, right: 16, top: this.topSafeInset + 12,
          bottom: this.bottomSafeInset + 28 }).width('100%')
      }.width('100%').height('100%').backgroundColor(PAPER)
      if (this.dropdownTarget.length > 0) {
        this.sectionDropdownOverlay()
      }
      if (this.editorVisible) {
        this.editorOverlay()
      }
      if (this.saveDialogVisible) {
        this.saveDialogOverlay()
      }
      if (this.overwriteDialogVisible) {
        this.overwriteDialogOverlay()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
