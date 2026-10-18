import { router } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import {
  CORAL,
  INK,
  LILAC,
  PAPER,
  WHITE,
  CARD_SHADOW,
  CONTROL_SHADOW,
  INK_SHADOW_RADIUS
} from '../components/ComicKit';
import { isProDrumMachineAccessible } from '../store/EntitlementStore';
import { EditableBpm } from '../components/EditableBpm';
import { EditableMeter, MeterEditorOverlay } from '../components/EditableMeter';
import { beatUnitLabel } from '../common/MeterModel';
import { logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import { DEFAULT_TICKS_PER_BEAT, SequencerEvent } from '../audio/RhythmTimeline';
import {
  buildSectionPattern,
  cloneDrumCustomPattern,
  sectionFillStartBeat,
  defaultDrumProgram,
  DrumCustomPattern,
  DrumProgram,
  DrumSection,
  DrumStyle,
  DrumTrack,
  DRUM_STYLES,
  DRUM_TRACKS,
  drumFillDescription,
  drumFillNames,
  drumPatternDescription,
  drumPatternNames,
  parseDrumProgram,
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
  customPattern?: DrumCustomPattern;
  customFill?: DrumCustomPattern;
}

interface DrumContextState {
  key: string;
  selections: DrumSectionSelectionState[];
}

const DRUM_EDITOR_CELL_WIDTH: number = 22;
const DRUM_EDITOR_CELL_GAP: number = 4;
// Keep the button inside its timeline column when the grid width is adjusted.
const DRUM_EDITOR_BUTTON_WIDTH: number = Math.max(1, DRUM_EDITOR_CELL_WIDTH - DRUM_EDITOR_CELL_GAP);
const DRUM_EDITOR_CELL_RADIUS: number = 4;
const DRUM_EDITOR_PANEL_MAX_WIDTH: number = 560;
const DRUM_EDITOR_PANEL_MAX_HEIGHT: number = 720;
const DRUM_EDITOR_PANEL_RADIUS: number = 16;
const DRUM_EDITOR_OVERLAY_SIDE_INSET: number = 16;
const DRUM_EDITOR_OVERLAY_VERTICAL_INSET: number = 24;
const DRUM_EDITOR_LABEL_WIDTH: number = 56;
const DRUM_EDITOR_HEADER_HEIGHT: number = 56;
const DRUM_EDITOR_BEAT_HEIGHT: number = 24;
const DRUM_EDITOR_SCROLLBAR_SPACE: number = 14;
const DRUM_EDITOR_ROW_HEIGHT: number = 40;
const DRUM_EDITOR_MIN_ROW_HEIGHT: number = 36;
const DRUM_EDITOR_MAX_ROW_HEIGHT: number = 56;
const DRUM_EDITOR_PLAYHEAD_WIDTH: number = 2;
const DRUM_EDITOR_PLAYHEAD_CAP_WIDTH: number = 10;
const DRUM_EDITOR_ACTION_HEIGHT: number = 48;
const DRUM_EDITOR_PREVIEW_FRAME_MS: number = 32;
const DRUM_EDITOR_SUBDIVISIONS: number[] = [4, 3, 6];
const DRUM_EDITOR_SUBDIVISION_HEIGHT: number = 34;
const DRUM_EDITOR_SUBDIVISION_GAP: number = 6;
const DRUM_EDITOR_OFF_GRID_SIZE: number = 10;
const DRUM_EDITOR_OFF_GRID_HIT_SIZE: number = 18;
const DRUM_EDITOR_FILL_FOCUS_DELAY_MS: number = 1000;
const DRUM_EDITOR_LOCKED_CELL_OPACITY: number = 0.52;
const DRUM_SECTION_PLAYING_COLOR: string = '#EDE4FA';
const DRUM_PHRASE_PLAYING_COLOR: string = '#FFF0B8';
const DRUM_SONG_PREVIEW_PROGRESS_MS: number = 16;
const DRUM_SONG_PREVIEW_UPDATE_DELAY_MS: number = 150;

@Entry
@Component
struct DrumMachinePage {
  @State styleKey: string = 'rock';
  @State beatsPerBar: number = 4;
  @State beatUnit: number = 4;
  @State bpm: number = 120;
  @State sections: DrumSection[] = [];
  @State selectedSection: number = 0;
  @State expandedSections: boolean[] = [true];
  @State editorVisible: boolean = false;
  @State editorMode: number = 0;
  @State editorEvents: SequencerEvent[] = [];
  @State editorSubdivision: number = 4;
  @State editorStepVelocities: number[][] = [];
  @State previewTarget: string = '';
  @State playingSongSection: number = -1;
  @State playingSongIsFill: boolean = false;
  @State editorPlayheadBeats: number = -1;
  @State editorTrackRowHeight: number = DRUM_EDITOR_ROW_HEIGHT;
  @State saving: boolean = false;
  @State dropdownTarget: string = '';
  @State dropdownAnchorX: number = 0;
  @State dropdownAnchorY: number = 0;
  @State dropdownMenuWidth: number = 126;
  @State dropdownKind: string = '';
  @State dropdownSectionIndex: number = 0;
  @State saveDialogVisible: boolean = false;
  @State overwriteDialogVisible: boolean = false;
  @State meterEditorVisible: boolean = false;
  @State saveName: string = '';
  @State saveNameError: string = '';
  @State songPreviewMessage: string = '';
  @State savedPrograms: SavedDrumProgram[] = [];
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  private sectionPreviewStopTimerId: number = -1;
  private sectionPreviewRevision: number = 0;
  private songPreviewProgressTimerId: number = -1;
  private songPreviewProgressRevision: number = 0;
  private songPreviewTransportRevision: number | undefined = undefined;
  private songPreviewHasPlayed: boolean = false;
  private songPreviewUpdateTimerId: number = -1;
  private songPreviewUpdateRevision: number = 0;
  private songPreviewDeferredStart: boolean = false;
  private sectionPlaybackKeys: string[] = [];
  private nextSectionPlaybackKey: number = 0;
  private contextStates: DrumContextState[] = [];
  private readonly editorScroller: Scroller = new Scroller();
  private editorViewportWidth: number = 0;
  private editorPreviewTimerId: number = -1;
  private editorPreviewRevision: number = 0;
  private editorPreviewCycle: number = -1;
  private editorFillFocusTimerId: number = -1;
  private bpmUpdateRevision: number = 0;
  private pageLifetimeRevision: number = 0;

  aboutToAppear(): void {
    this.pageLifetimeRevision++;
    this.saving = false;
    if (!isProDrumMachineAccessible()) {
      showUserNotice('请先在大厅解锁鼓机月卡或分享试用', 'drum.entitlement');
      router.back();
      return;
    }
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
    this.sections = program.sections;
    this.resetSectionPlaybackKeys();
    this.expandedSections = this.sections.map((_section: DrumSection, index: number) => index === 0);
    const editorSettings = controller?.getProDrumEditorSettings();
    if (editorSettings !== undefined) {
      this.beatsPerBar = editorSettings.beatsPerBar;
      this.beatUnit = editorSettings.beatUnit;
      this.bpm = editorSettings.bpm;
    } else if (controller !== undefined) {
      // The lobby's live leader settings are the source of truth when opening PRO;
      // a previously saved arrangement may carry an older meter.
      this.beatsPerBar = controller.beatsPerBar;
      this.beatUnit = controller.beatUnit;
      this.bpm = controller.bpm;
    } else {
      this.beatsPerBar = program.beatsPerBar;
      this.beatUnit = program.beatUnit;
    }
    this.contextStates = [];
    this.storeCurrentContext();
  }

  private rememberEditedTempoAndMeter(): void {
    AppSession.get()?.controller.rememberProDrumEditorSettings(
      this.beatsPerBar, this.beatUnit, this.bpm);
  }

  onBackPress(): boolean {
    if (this.meterEditorVisible) {
      this.meterEditorVisible = false;
      return true;
    }
    if (this.editorVisible) {
      this.closeEditor();
      return true;
    }
    return false;
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
    this.saveNameError = '';
    this.saveDialogVisible = true;
  }

  private confirmNamedSave(): void {
    const name = this.saveName.trim();
    if (name.length === 0) {
      this.saveNameError = '请输入名称';
      return;
    }
    this.saveNameError = '';
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
    showUserNotice(replaced ? '已更新我的节奏' : '已保存到我的节奏', 'drum.save');
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
  }

  private loadSavedProgram(saved: SavedDrumProgram): void {
    const wasPreviewing = this.previewTarget.length > 0;
    const program = parseDrumProgram(saved.program);
    this.styleKey = program.styleKey;
    this.beatsPerBar = program.beatsPerBar;
    this.beatUnit = program.beatUnit;
    this.sections = program.sections;
    this.resetSectionPlaybackKeys();
    this.selectedSection = 0;
    this.expandedSections = this.sections.map((_section: DrumSection, index: number) => index === 0);
    this.dropdownTarget = '';
    this.contextStates = [];
    this.storeCurrentContext();
    this.rememberEditedTempoAndMeter();
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
    this.pageLifetimeRevision++;
    this.bpmUpdateRevision++;
    this.clearEditorFillFocusTimer();
    this.stopActivePreview();
  }

  private currentProgram(): DrumProgram {
    return {
      styleKey: this.styleKey,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
      sections: this.sections
    };
  }

  private resetSectionPlaybackKeys(): void {
    this.sectionPlaybackKeys = [];
    this.playbackSectionKeys();
  }

  private playbackSectionKeys(): string[] {
    // Display letters are renumbered after deletion. Playback identity must
    // survive that renumbering so an audible B cannot silently become A.
    while (this.sectionPlaybackKeys.length < this.sections.length) {
      this.sectionPlaybackKeys.push(`section-${++this.nextSectionPlaybackKey}`);
    }
    this.sectionPlaybackKeys = this.sectionPlaybackKeys.slice(0, this.sections.length);
    return this.sectionPlaybackKeys.slice();
  }

  private copySection(section: DrumSection): DrumSection {
    return {
      id: section.id,
      patternIndex: section.patternIndex,
      repeats: section.repeats,
      fillIndex: section.fillIndex,
      fillEvery: section.fillEvery,
      customRows: this.copyOptionalRows(section.customRows),
      customFillRows: this.copyOptionalRows(section.customFillRows),
      customPattern: cloneDrumCustomPattern(section.customPattern),
      customFill: cloneDrumCustomPattern(section.customFill)
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
        customFillRows: this.copyOptionalRows(this.sections[i].customFillRows),
        customPattern: cloneDrumCustomPattern(this.sections[i].customPattern),
        customFill: cloneDrumCustomPattern(this.sections[i].customFill)
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
        section.customPattern = cloneDrumCustomPattern(selection.customPattern);
        section.customFill = cloneDrumCustomPattern(selection.customFill);
      } else {
        section.patternIndex = 0;
        section.fillIndex = 0;
        section.customRows = undefined;
        section.customFillRows = undefined;
        section.customPattern = undefined;
        section.customFill = undefined;
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
    if (this.previewTarget === 'song') {
      this.queueSongPreviewUpdate();
    } else {
      void this.refreshActivePreview();
    }
  }

  private replaceSection(index: number, section: DrumSection): void {
    const next: DrumSection[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      next.push(i === index ? section : this.sections[i]);
    }
    this.sections = next;
  }

  private isSectionExpanded(index: number): boolean {
    return this.expandedSections[index] === true;
  }

  private toggleSectionExpanded(index: number): void {
    if (index < 0 || index >= this.sections.length) {
      return;
    }
    // The editor target and audition target never own card visibility. Keep
    // each fold state separate so editing B cannot implicitly collapse A.
    const next = this.sections.map((_section: DrumSection, sectionIndex: number) =>
      sectionIndex === index ? !this.isSectionExpanded(sectionIndex) : this.isSectionExpanded(sectionIndex));
    this.expandedSections = next;
    if (!next[index] && this.dropdownSectionIndex === index) {
      this.closeDropdown();
    }
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
      this.queueSongPreviewUpdate();
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

  /** 整曲在小节边界接入增删；独立段落试听仍按原来的有限播放流程处理。 */
  private afterSectionsStructureChanged(removedIndex: number = -1): void {
    const target = this.previewTarget;
    if (target.length === 0) {
      return;
    }
    if (target === 'song') {
      this.queueSongPreviewUpdate();
      if (this.songPreviewProgressTimerId >= 0) {
        this.updateSongPreviewProgress();
      }
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
    section.customPattern = undefined;
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private hasCustomPattern(section: DrumSection): boolean {
    return section.customPattern !== undefined || section.customRows !== undefined;
  }

  private hasCustomFill(section: DrumSection): boolean {
    return section.customFill !== undefined || section.customFillRows !== undefined;
  }

  private editorPatternLabel(): string {
    const section = this.sections[this.selectedSection];
    const label = this.editorMode === 0 ?
      drumPatternNames(this.styleKey)[section.patternIndex] : drumFillNames(this.styleKey)[section.fillIndex];
    const custom = this.editorMode === 0 ? this.hasCustomPattern(section) : this.hasCustomFill(section);
    const description = custom ? '自定义鼓点，保留原始位置和力度' :
      (this.editorMode === 0 ? drumPatternDescription(this.styleKey, section.patternIndex) :
        drumFillDescription(this.styleKey, section.fillIndex));
    return `${styleByKey(this.styleKey).name} · ${label} · ${description}`;
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
    section.customFill = undefined;
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
      return;
    }
    const id = String.fromCharCode(65 + this.sections.length);
    const expanded = this.sections.map((_section: DrumSection, index: number) => this.isSectionExpanded(index));
    this.playbackSectionKeys();
    const next = this.sections.slice();
    next.push({ id: id, patternIndex: 0, repeats: 4, fillIndex: 0, fillEvery: 4 });
    this.sections = next;
    this.playbackSectionKeys();
    this.expandedSections = [...expanded, true];
    this.selectedSection = next.length - 1;
    this.afterSectionsStructureChanged();
  }

  private deleteSection(index: number): void {
    if (this.sections.length <= 1) {
      return;
    }
    const next: DrumSection[] = [];
    const expanded: boolean[] = [];
    const playbackKeys = this.playbackSectionKeys();
    const nextPlaybackKeys: string[] = [];
    for (let i = 0; i < this.sections.length; i++) {
      if (i !== index) {
        const section = this.copySection(this.sections[i]);
        section.id = String.fromCharCode(65 + next.length);
        next.push(section);
        expanded.push(this.isSectionExpanded(i));
        nextPlaybackKeys.push(playbackKeys[i]);
      }
    }
    this.sections = next;
    this.sectionPlaybackKeys = nextPlaybackKeys;
    // Letters are renumbered after deletion; carry fold state with each
    // surviving card instead of accidentally transferring it to the next ID.
    this.expandedSections = expanded;
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
    this.rememberEditedTempoAndMeter();
    void this.refreshActivePreview();
  }

  private editorStepCount(): number {
    return this.beatsPerBar * this.editorSubdivision;
  }

  // The grid is a projection of musical time. Keeping the cursor in beats
  // prevents a 4/3/6 view switch from moving a held or running audition.
  private get editorPlayheadStep(): number {
    return this.editorPlayheadBeats < 0 ? -1 : this.editorPlayheadBeats * this.editorSubdivision;
  }

  private set editorPlayheadStep(step: number) {
    this.editorPlayheadBeats = step < 0 ? -1 : step / this.editorSubdivision;
  }

  private editorFillStartBeat(): number {
    if (this.editorMode !== 1 || this.selectedSection < 0 || this.selectedSection >= this.sections.length) {
      return 0;
    }
    return sectionFillStartBeat(this.currentProgram(), this.sections[this.selectedSection]);
  }

  private editorFillStartTick(): number {
    return this.editorFillStartBeat() * DEFAULT_TICKS_PER_BEAT;
  }

  private editorStepEditable(step: number): boolean {
    return this.editorMode === 0 || step >= this.editorFillStartBeat() * this.editorSubdivision;
  }

  private editorEventTickEditable(tick: number): boolean {
    return this.editorMode === 0 || tick + 0.000001 >= this.editorFillStartTick();
  }

  private clearEditorFillFocusTimer(): void {
    if (this.editorFillFocusTimerId >= 0) {
      clearTimeout(this.editorFillFocusTimerId);
      this.editorFillFocusTimerId = -1;
    }
  }

  private scheduleEditorFillFocusScroll(): void {
    this.clearEditorFillFocusTimer();
    if (this.editorMode !== 1) {
      return;
    }
    const fillStartBeat = this.editorFillStartBeat();
    if (fillStartBeat <= 0) {
      return;
    }
    this.editorFillFocusTimerId = setTimeout(() => {
      this.editorFillFocusTimerId = -1;
      if (!this.editorVisible || this.editorMode !== 1) {
        return;
      }
      const xOffset = fillStartBeat * this.editorSubdivision * DRUM_EDITOR_CELL_WIDTH;
      const maxOffset = Math.max(0, this.editorGridWidth() - this.editorViewportWidth);
      this.editorScroller.scrollTo({ xOffset: Math.min(xOffset, maxOffset), yOffset: 0, animation: true });
    }, DRUM_EDITOR_FILL_FOCUS_DELAY_MS);
  }

  private cloneSequencerEvent(event: SequencerEvent): SequencerEvent {
    return { tick: event.tick, sampleKey: event.sampleKey, velocity: event.velocity };
  }

  private buildFillEditorEvents(section: DrumSection): SequencerEvent[] {
    const program = this.currentProgram();
    const fillStartTick = sectionFillStartBeat(program, section) * DEFAULT_TICKS_PER_BEAT;
    const mainEvents = buildSectionPattern(program, section, false).events.filter((event: SequencerEvent) => {
      return event.tick < fillStartTick;
    }).map((event: SequencerEvent): SequencerEvent => this.cloneSequencerEvent(event));
    const fillEvents = buildSectionPattern(program, section, true).events.filter((event: SequencerEvent) => {
      return event.tick >= fillStartTick;
    }).map((event: SequencerEvent): SequencerEvent => this.cloneSequencerEvent(event));
    const events = mainEvents.concat(fillEvents);
    events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
    return events;
  }

  private copyEditorEvents(): SequencerEvent[] {
    return this.editorEvents.map((event: SequencerEvent): SequencerEvent => {
      return { tick: event.tick, sampleKey: event.sampleKey, velocity: event.velocity };
    });
  }

  private isEditorEventOnGrid(event: SequencerEvent, subdivision: number = this.editorSubdivision): boolean {
    const step = event.tick * subdivision / DEFAULT_TICKS_PER_BEAT;
    return Math.abs(step - Math.round(step)) < 0.000001;
  }

  private isEditorEventAtStep(event: SequencerEvent, sampleKey: string, step: number): boolean {
    return event.sampleKey === sampleKey && this.isEditorEventOnGrid(event) &&
      Math.round(event.tick * this.editorSubdivision / DEFAULT_TICKS_PER_BEAT) === step;
  }

  private refreshEditorGridProjection(): void {
    const velocities: number[][] = DRUM_TRACKS.map((_track: DrumTrack): number[] => {
      const row: number[] = [];
      for (let step = 0; step < this.editorStepCount(); step++) {
        row.push(0);
      }
      return row;
    });
    for (let i = 0; i < this.editorEvents.length; i++) {
      const event = this.editorEvents[i];
      if (!this.isEditorEventOnGrid(event)) {
        continue;
      }
      const track = DRUM_TRACKS.findIndex((item: DrumTrack) => item.key === event.sampleKey);
      const step = Math.round(event.tick * this.editorSubdivision / DEFAULT_TICKS_PER_BEAT);
      if (track >= 0 && step >= 0 && step < this.editorStepCount()) {
        velocities[track][step] = Math.max(velocities[track][step], event.velocity);
      }
    }
    // Compute cell lookup only when notes or the grid change; the transport's
    // 32 ms paints must not scan every event for every visible button.
    this.editorStepVelocities = velocities;
  }

  private editorCellEnabled(track: number, step: number): boolean {
    return (this.editorStepVelocities[track]?.[step] ?? 0) > 0;
  }

  private editorCellColor(track: number, step: number): string {
    const velocity = this.editorStepVelocities[track]?.[step] ?? 0;
    if (velocity <= 0) {
      return '#E9E2D5';
    }
    if (velocity < 0.4) {
      return '#D9CCE9';
    }
    return step % this.editorSubdivision === 0 ? CORAL : LILAC;
  }

  private editorOffGridEvents(trackIndex?: number): SequencerEvent[] {
    return this.editorEvents.filter((event: SequencerEvent) => {
      return !this.isEditorEventOnGrid(event) &&
        (trackIndex === undefined || event.sampleKey === DRUM_TRACKS[trackIndex]?.key);
    });
  }

  private editorOffGridCount(): number {
    return this.editorOffGridEvents().length;
  }

  private editorOffGridX(event: SequencerEvent): number {
    return Math.max(0, Math.min(this.editorGridWidth() - DRUM_EDITOR_OFF_GRID_HIT_SIZE,
      event.tick / DEFAULT_TICKS_PER_BEAT * this.editorSubdivision * DRUM_EDITOR_CELL_WIDTH -
        DRUM_EDITOR_OFF_GRID_HIT_SIZE / 2));
  }

  private chooseEditorSubdivision(subdivision: number): void {
    if (!this.editorVisible || DRUM_EDITOR_SUBDIVISIONS.indexOf(subdivision) < 0 ||
      subdivision === this.editorSubdivision) {
      return;
    }
    this.clearEditorFillFocusTimer();
    if (this.previewTarget === 'editor') {
      this.updateEditorPreviewProgress(false);
    }
    const offsetBeats = this.editorScroller.currentOffset().xOffset /
      (this.editorSubdivision * DRUM_EDITOR_CELL_WIDTH);
    this.editorSubdivision = subdivision;
    this.refreshEditorGridProjection();
    this.editorScroller.scrollTo({
      xOffset: Math.min(Math.max(0, this.editorGridWidth() - this.editorViewportWidth),
        Math.max(0, offsetBeats * subdivision * DRUM_EDITOR_CELL_WIDTH)),
      yOffset: 0, animation: false
    });
    this.keepEditorPlayheadVisible(true);
    // View changes never commit a section or reconfigure its sounding events.
    // Only Apply copies the draft's subdivision and events into the arrangement.
  }

  private snappedEditorEvents(trackIndex: number = -1, eventTick: number = -1): SequencerEvent[] {
    const events: SequencerEvent[] = [];
    const moved: SequencerEvent[] = [];
    for (let i = 0; i < this.editorEvents.length; i++) {
      const source = this.editorEvents[i];
      const selected = trackIndex < 0 ||
        (source.sampleKey === DRUM_TRACKS[trackIndex]?.key && source.tick === eventTick);
      if (selected && !this.isEditorEventOnGrid(source)) {
        const position = source.tick * this.editorSubdivision / DEFAULT_TICKS_PER_BEAT;
        // Exact midpoint ties go earlier; the last cell is the final valid
        // target, so snapping can never spill a hit into the next bar.
        const step = Math.max(0, Math.min(this.editorStepCount() - 1, Math.floor(position + 0.5 - 0.000000001)));
        moved.push({ tick: step * DEFAULT_TICKS_PER_BEAT / this.editorSubdivision,
          sampleKey: source.sampleKey, velocity: source.velocity });
      } else {
        events.push({ tick: source.tick, sampleKey: source.sampleKey, velocity: source.velocity });
      }
    }
    for (let i = 0; i < moved.length; i++) {
      const note = moved[i];
      const step = Math.round(note.tick * this.editorSubdivision / DEFAULT_TICKS_PER_BEAT);
      const existing = events.findIndex((event: SequencerEvent) => {
        return this.isEditorEventAtStep(event, note.sampleKey, step);
      });
      if (existing < 0) {
        events.push(note);
      } else {
        // Merge only collisions at an explicitly snapped destination. Other
        // events keep their original ordering, timing and velocities.
        events[existing].tick = note.tick;
        events[existing].velocity = Math.max(events[existing].velocity, note.velocity);
        for (let j = events.length - 1; j > existing; j--) {
          if (this.isEditorEventAtStep(events[j], note.sampleKey, step)) {
            events[existing].velocity = Math.max(events[existing].velocity, events[j].velocity);
            events.splice(j, 1);
          }
        }
      }
    }
    return events;
  }

  private snapEditorEventToGrid(trackIndex: number, eventTick: number): void {
    if (!this.editorVisible || trackIndex < 0 || trackIndex >= DRUM_TRACKS.length ||
      !this.editorEventTickEditable(eventTick) ||
      !this.editorOffGridEvents(trackIndex).some((event: SequencerEvent) => event.tick === eventTick)) {
      return;
    }
    this.editorEvents = this.snappedEditorEvents(trackIndex, eventTick);
    this.refreshEditorGridProjection();
    if (this.previewTarget === 'editor') {
      void this.restartEditorPreview();
    }
  }

  private snapAllEditorOffGridEvents(): void {
    if (!this.editorVisible || this.editorOffGridCount() === 0) {
      return;
    }
    const fillStartTick = this.editorFillStartTick();
    const locked = this.editorEvents.filter((event: SequencerEvent) => {
      return !this.isEditorEventOnGrid(event) && event.tick < fillStartTick;
    }).map((event: SequencerEvent): SequencerEvent => this.cloneSequencerEvent(event));
    const editable = this.editorEvents.filter((event: SequencerEvent) => {
      return this.isEditorEventOnGrid(event) || event.tick >= fillStartTick;
    });
    this.editorEvents = editable;
    this.editorEvents = this.snappedEditorEvents().concat(locked);
    this.editorEvents.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
    this.refreshEditorGridProjection();
    if (this.previewTarget === 'editor') {
      void this.restartEditorPreview();
    }
  }

  private editorGridWidth(): number {
    return this.editorStepCount() * DRUM_EDITOR_CELL_WIDTH;
  }

  private editorTracksHeight(): number {
    return DRUM_TRACKS.length * this.editorTrackRowHeight;
  }

  private editorGridHeight(): number {
    return DRUM_EDITOR_HEADER_HEIGHT + this.editorTracksHeight() + DRUM_EDITOR_SCROLLBAR_SPACE;
  }

  private updateEditorGridViewport(height: number): void {
    if (height <= 0) {
      return;
    }
    // Grow rows into the available workspace; short windows scroll the grid
    // vertically instead of shrinking tap targets or pushing actions offscreen.
    const rowHeight = Math.max(DRUM_EDITOR_MIN_ROW_HEIGHT, Math.min(DRUM_EDITOR_MAX_ROW_HEIGHT,
      Math.floor((height - DRUM_EDITOR_HEADER_HEIGHT - DRUM_EDITOR_SCROLLBAR_SPACE) / DRUM_TRACKS.length)));
    if (this.editorTrackRowHeight !== rowHeight) {
      this.editorTrackRowHeight = rowHeight;
    }
  }

  private editorPlayheadCapX(): number {
    return Math.max(0, Math.min(this.editorGridWidth() - DRUM_EDITOR_PLAYHEAD_CAP_WIDTH,
      this.editorPlayheadX() + DRUM_EDITOR_PLAYHEAD_WIDTH / 2 - DRUM_EDITOR_PLAYHEAD_CAP_WIDTH / 2));
  }

  private editorStepIndexes(): number[] {
    return Array.from({ length: this.editorStepCount() }, (_value: number, step: number) => step);
  }

  private editorBeatIndexes(): number[] {
    return Array.from({ length: this.beatsPerBar }, (_value: number, beat: number) => beat);
  }

  private initialEditorSubdivision(section: DrumSection, mode: number): number {
    const custom = mode === 0 ? section.customPattern : section.customFill;
    if (custom !== undefined) {
      return custom.subdivision;
    }
    const legacyRows = mode === 0 ? section.customRows : section.customFillRows;
    if (legacyRows !== undefined && legacyRows.length > 0) {
      return 4;
    }
    let preferred = 4;
    if (this.styleKey === 'jazz') {
      preferred = mode === 1 && section.fillIndex === 1 ? 6 : 3;
    } else if (this.styleKey === 'trap' &&
      (mode === 0 ? section.patternIndex === 1 : section.fillIndex === 1)) {
      preferred = 6;
    }
    // Pick a view for the actual opened phrase, including its fill prefix. A tie
    // retains its musical preference; stored grids and event positions never change.
    let selected = preferred;
    let remaining = this.editorEvents.filter((event: SequencerEvent) =>
      !this.isEditorEventOnGrid(event, preferred)).length;
    for (let i = 0; i < DRUM_EDITOR_SUBDIVISIONS.length; i++) {
      const subdivision = DRUM_EDITOR_SUBDIVISIONS[i];
      const offGrid = this.editorEvents.filter((event: SequencerEvent) =>
        !this.isEditorEventOnGrid(event, subdivision)).length;
      if (offGrid < remaining) {
        selected = subdivision;
        remaining = offGrid;
      }
    }
    return selected;
  }

  private openEditor(index: number, mode: number): void {
    // The overlay only owns its own audition. Keep the song's transport and
    // pending preparation alive until the user explicitly auditions this draft.
    this.clearEditorFillFocusTimer();
    if (this.previewTarget === 'song') {
      this.stopEditorPreviewProgress();
    } else {
      this.stopActivePreview();
    }
    this.selectedSection = index;
    this.editorMode = mode;
    const section = this.sections[index];
    this.editorEvents = mode === 1 ? this.buildFillEditorEvents(section) :
      buildSectionPattern(this.currentProgram(), section, false).events.map(
        (event: SequencerEvent): SequencerEvent => this.cloneSequencerEvent(event));
    this.editorSubdivision = this.initialEditorSubdivision(section, mode);
    this.refreshEditorGridProjection();
    this.editorVisible = true;
    this.scheduleEditorFillFocusScroll();
  }

  private toggleStep(track: number, step: number): void {
    if (!this.editorVisible || track < 0 || track >= DRUM_TRACKS.length || !Number.isInteger(step) ||
      step < 0 || step >= this.editorStepCount() || !this.editorStepEditable(step)) {
      return;
    }
    const sampleKey = DRUM_TRACKS[track].key;
    const tick = step * DEFAULT_TICKS_PER_BEAT / this.editorSubdivision;
    const enabled = this.editorEvents.some((event: SequencerEvent) => {
      return this.isEditorEventAtStep(event, sampleKey, step) && event.velocity > 0;
    });
    const events = this.copyEditorEvents().filter((event: SequencerEvent) => {
      return !this.isEditorEventAtStep(event, sampleKey, step);
    });
    if (!enabled) {
      events.push({ tick: tick, sampleKey: sampleKey, velocity: step % this.editorSubdivision === 0 ? 1 : 0.78 });
    }
    this.editorEvents = events;
    this.refreshEditorGridProjection();
    if (this.previewTarget === 'editor') {
      void this.restartEditorPreview();
    }
  }

  private closeEditor(): void {
    this.clearEditorFillFocusTimer();
    if (this.previewTarget === 'editor') {
      this.stopActivePreview();
    } else {
      this.stopEditorPreviewProgress();
    }
    this.editorVisible = false;
  }

  private seekEditorStep(step: number): void {
    if (!this.editorVisible || !Number.isInteger(step) || step < 0 || step >= this.editorStepCount()) {
      return;
    }
    if (this.previewTarget === 'editor') {
      void this.restartEditorPreview(step);
      return;
    }
    this.editorPlayheadStep = step;
    this.editorPreviewCycle = 0;
    this.keepEditorPlayheadVisible(true);
  }

  private buildEditorPreviewProgram(): DrumProgram {
    // Both editor modes audition the visible draft directly, without waiting
    // for a section's fill frequency or committing the draft to the arrangement.
    return {
      styleKey: this.styleKey,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
      sections: [{
        id: this.sections[this.selectedSection].id,
        patternIndex: 0,
        repeats: 1,
        fillIndex: 0,
        fillEvery: 0,
        customPattern: { subdivision: this.editorSubdivision, events: this.copyEditorEvents() }
      }]
    };
  }

  private stopEditorPreviewProgress(keepPlayhead: boolean = false): void {
    this.editorPreviewRevision++;
    if (this.editorPreviewTimerId >= 0) {
      clearInterval(this.editorPreviewTimerId);
      this.editorPreviewTimerId = -1;
    }
    if (!keepPlayhead) {
      this.editorPlayheadStep = -1;
      this.editorPreviewCycle = -1;
    }
  }

  private async toggleEditorPreview(): Promise<void> {
    if (this.previewTarget === 'editor') {
      this.stopActivePreview(true);
      return;
    }
    await this.restartEditorPreview();
  }

  private async restartEditorPreview(startStep?: number): Promise<void> {
    // An explicit seek replaces the old transport position; ordinary draft
    // refreshes instead sample it so editing does not jump back in the bar.
    this.stopActivePreview(startStep === undefined);
    if (startStep !== undefined) {
      this.editorPlayheadStep = startStep;
      this.keepEditorPlayheadVisible(true);
    }
    if (!this.editorVisible || AppSession.get() === undefined) {
      return;
    }
    if (!isProDrumMachineAccessible()) {
      showUserNotice('鼓机权益已到期，编排已保留，请解锁后再试听', 'drum.preview.entitlement');
      return;
    }
    const revision = this.editorPreviewRevision;
    const startPositionBeats = Math.max(0, this.editorPlayheadBeats);
    this.editorPreviewCycle = startPositionBeats > 0 || this.editorPlayheadBeats >= 0 ? 0 : -1;
    this.previewTarget = 'editor';
    try {
      await this.startPreviewPlayback(this.buildEditorPreviewProgram(), true, startPositionBeats);
      // Sample preparation can finish after a new draft, cancellation or page exit.
      // That completion must not restore its cursor or clear the new audition.
      if (revision !== this.editorPreviewRevision || !this.editorVisible || this.previewTarget !== 'editor') {
        return;
      }
      if (this.editorPlayheadBeats < 0) {
        this.editorPlayheadBeats = 0;
      }
      this.editorPreviewCycle = 0;
      this.updateEditorPreviewProgress();
      this.editorPreviewTimerId = setInterval(() => {
        if (revision === this.editorPreviewRevision) {
          this.updateEditorPreviewProgress();
        }
      }, DRUM_EDITOR_PREVIEW_FRAME_MS);
    } catch (error) {
      if (revision === this.editorPreviewRevision && this.previewTarget === 'editor') {
        this.stopActivePreview(true);
        logUserFailure('drum.preview.editor', error);
        showUserNotice('试听启动失败', 'drum.preview.editor');
      }
    }
  }

  private editorPlayheadX(): number {
    return Math.max(0, Math.min(this.editorGridWidth() - DRUM_EDITOR_PLAYHEAD_WIDTH,
      this.editorPlayheadStep * DRUM_EDITOR_CELL_WIDTH));
  }

  private updateEditorViewport(width: number): void {
    this.editorViewportWidth = Math.max(0, width);
    this.keepEditorPlayheadVisible();
  }

  private keepEditorPlayheadVisible(forceReveal: boolean = false): void {
    if ((!forceReveal && this.previewTarget !== 'editor') || this.editorPlayheadStep < 0 || this.editorViewportWidth <= 0) {
      return;
    }
    const left = Math.floor(this.editorPlayheadStep) * DRUM_EDITOR_CELL_WIDTH;
    const right = Math.min(this.editorGridWidth(), left + DRUM_EDITOR_CELL_WIDTH + DRUM_EDITOR_PLAYHEAD_WIDTH);
    const offset = this.editorScroller.currentOffset().xOffset;
    const maxOffset = Math.max(0, this.editorGridWidth() - this.editorViewportWidth);
    if (offset >= 0 && offset <= maxOffset && left >= offset && right <= offset + this.editorViewportWidth) {
      return;
    }
    // Turn pages on full cell boundaries so the playing step stays wholly visible.
    const pageSteps = Math.max(1,
      Math.floor((this.editorViewportWidth - DRUM_EDITOR_PLAYHEAD_WIDTH) / DRUM_EDITOR_CELL_WIDTH));
    const pageWidth = pageSteps * DRUM_EDITOR_CELL_WIDTH;
    const pageLeft = Math.floor(left / pageWidth) * pageWidth;
    this.editorScroller.scrollTo({ xOffset: Math.min(pageLeft, maxOffset), yOffset: 0, animation: false });
  }

  private updateEditorPreviewProgress(followPlayhead: boolean = true): void {
    if (!this.editorVisible || this.previewTarget !== 'editor') {
      return;
    }
    const snapshot = AppSession.get()?.metronome.getVisualSnapshot();
    if (snapshot === undefined || !snapshot.running || snapshot.countIn || snapshot.mainPlayheadMs < 0) {
      // A resumed audition keeps its chosen start line throughout sample
      // preparation and preroll; only a valid transport frame may advance it.
      return;
    }
    // Derive the cursor from the same transport clock as playback; timer jitter
    // may skip a paint but must never accumulate drift against the drum audio.
    const beatMs = 60000 / Math.max(1, this.bpm);
    const absoluteBeats = snapshot.mainPlayheadMs / beatMs;
    const cycle = Math.floor(absoluteBeats / this.beatsPerBar);
    this.editorPlayheadBeats = absoluteBeats % this.beatsPerBar;
    if (followPlayhead) {
      if (cycle !== this.editorPreviewCycle) {
        this.editorPreviewCycle = cycle;
        this.editorScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      }
      this.keepEditorPlayheadVisible();
    }
  }

  private saveEditor(): void {
    const section = this.copySection(this.sections[this.selectedSection]);
    const fillStartTick = this.editorFillStartTick();
    const events = this.copyEditorEvents().filter((event: SequencerEvent) => {
      return this.editorMode === 0 || event.tick + 0.000001 >= fillStartTick;
    });
    const pattern: DrumCustomPattern = { subdivision: this.editorSubdivision, events: events };
    if (this.editorMode === 0) {
      section.customPattern = pattern;
      section.customRows = undefined;
    } else {
      section.customFill = pattern;
      section.customFillRows = undefined;
    }
    this.replaceSection(this.selectedSection, section);
    this.closeEditor();
    this.notifySectionEdited(this.selectedSection);
  }

  private cancelSectionPreviewStop(): void {
    this.cancelSongPreviewUpdate();
    this.stopSongPreviewProgress();
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

  private stopSongPreviewProgress(): void {
    this.songPreviewProgressRevision++;
    if (this.songPreviewProgressTimerId >= 0) {
      clearTimeout(this.songPreviewProgressTimerId);
      this.songPreviewProgressTimerId = -1;
    }
    this.playingSongSection = -1;
    this.playingSongIsFill = false;
    this.songPreviewTransportRevision = undefined;
    this.songPreviewHasPlayed = false;
  }

  private startSongPreviewProgress(): void {
    this.stopSongPreviewProgress();
    if (AppSession.get()?.isDrumPreviewActive() !== true) {
      return;
    }
    this.songPreviewTransportRevision = AppSession.get()?.metronome.getVisualSnapshot().revision;
    const revision = this.songPreviewProgressRevision;
    this.scheduleSongPreviewProgress(revision);
  }

  private scheduleSongPreviewProgress(revision: number): void {
    const delayMs = this.updateSongPreviewProgress();
    if (revision !== this.songPreviewProgressRevision || this.previewTarget !== 'song') {
      return;
    }
    // An unrelated polling interval can paint after the downbeat. Recheck on
    // the local PCM boundary, with a frame-sized cap while a new plan queues.
    this.songPreviewProgressTimerId = setTimeout(() => {
      if (revision === this.songPreviewProgressRevision) {
        this.songPreviewProgressTimerId = -1;
        this.scheduleSongPreviewProgress(revision);
      }
    }, delayMs);
  }

  private updateSongPreviewProgress(): number {
    if (this.previewTarget !== 'song') {
      this.stopSongPreviewProgress();
      return DRUM_SONG_PREVIEW_PROGRESS_MS;
    }
    const session = AppSession.get();
    const snapshot = session?.metronome.getVisualSnapshot();
    if (session?.isDrumPreviewActive() !== true ||
      (snapshot !== undefined && snapshot.revision !== this.songPreviewTransportRevision)) {
      this.cancelSongPreviewUpdate();
      this.stopSongPreviewProgress();
      this.previewTarget = '';
      this.songPreviewMessage = '';
      return DRUM_SONG_PREVIEW_PROGRESS_MS;
    }
    if (snapshot === undefined || !snapshot.running) {
      this.playingSongSection = -1;
      this.playingSongIsFill = false;
      return DRUM_SONG_PREVIEW_PROGRESS_MS;
    }
    // Queued PCM may still belong to an older plan. The engine reports its
    // audible stable key, rather than projecting the latest edited lengths.
    const position = session.metronome.getDrumPreviewPosition();
    if (position !== undefined) {
      this.songPreviewHasPlayed = true;
    }
    this.playingSongSection = position === undefined ? -1 :
      this.sectionPlaybackKeys.indexOf(position.sectionKey);
    this.playingSongIsFill = position?.isFill === true;
    const boundaryDelayMs = position?.nextBoundaryDelayMs;
    return boundaryDelayMs !== undefined && Number.isFinite(boundaryDelayMs) ?
      Math.max(1, Math.min(DRUM_SONG_PREVIEW_PROGRESS_MS, boundaryDelayMs)) : DRUM_SONG_PREVIEW_PROGRESS_MS;
  }

  private cancelSongPreviewUpdate(): void {
    this.songPreviewUpdateRevision++;
    this.songPreviewDeferredStart = false;
    if (this.songPreviewUpdateTimerId >= 0) {
      clearTimeout(this.songPreviewUpdateTimerId);
      this.songPreviewUpdateTimerId = -1;
    }
    AppSession.get()?.invalidateDrumPreviewUpdate();
  }

  private isSongPhrasePlaying(sectionIndex: number, isFill: boolean): boolean {
    return this.previewTarget === 'song' && this.playingSongSection === sectionIndex &&
      this.playingSongIsFill === isFill;
  }

  private queueSongPreviewUpdate(): void {
    if (this.previewTarget !== 'song') {
      return;
    }
    const session = AppSession.get();
    if (session?.isDrumPreviewActive() !== true && !this.songPreviewDeferredStart) {
      this.stopActivePreview();
      return;
    }
    // A recovering renderer can temporarily have no audible frame anchor.
    // Once this owner has played, that gap must not turn an edit into a new start.
    const audible = session?.isDrumPreviewReady() === true &&
      (this.songPreviewHasPlayed || session.metronome.getDrumPreviewPosition() !== undefined);
    if (audible) {
      this.songPreviewHasPlayed = true;
    }
    this.cancelSongPreviewUpdate();
    if (!audible) {
      // A cold load or scheduled preroll is still replaceable. Withdraw it now,
      // before the debounce, so the superseded arrangement cannot start first.
      this.cancelSectionPreviewStop();
      session?.stopDrumPreview();
      this.songPreviewDeferredStart = true;
    }
    const revision = this.songPreviewUpdateRevision;
    const ownerRevision = session?.getDrumPreviewRequestRevision();
    this.songPreviewUpdateTimerId = setTimeout(() => {
      this.songPreviewUpdateTimerId = -1;
      if (revision !== this.songPreviewUpdateRevision || this.previewTarget !== 'song') {
        return;
      }
      if (this.songPreviewDeferredStart) {
        this.songPreviewDeferredStart = false;
        if (session?.getDrumPreviewRequestRevision() !== ownerRevision) {
          this.stopSongPreviewProgress();
          this.previewTarget = '';
          return;
        }
        void this.restartSongPreview();
      } else {
        void this.applySongPreviewUpdate(revision);
      }
    }, DRUM_SONG_PREVIEW_UPDATE_DELAY_MS);
  }

  private async applySongPreviewUpdate(revision: number): Promise<void> {
    const session = AppSession.get();
    if (session?.isDrumPreviewReady() !== true) {
      return;
    }
    const ownerRevision = session.getDrumPreviewRequestRevision();
    try {
      const applied = await session.updateDrumPreviewProgram(
        serializeDrumProgram(this.currentProgram()), this.playbackSectionKeys());
      if (applied && revision === this.songPreviewUpdateRevision && this.previewTarget === 'song' &&
        AppSession.get() === session && ownerRevision === session.getDrumPreviewRequestRevision() &&
        session.isDrumPreviewReady()) {
        this.songPreviewMessage = '';
      }
    } catch (error) {
      if (revision === this.songPreviewUpdateRevision && this.previewTarget === 'song' &&
        AppSession.get() === session && ownerRevision === session.getDrumPreviewRequestRevision() &&
        session.isDrumPreviewReady()) {
        logUserFailure('drum.preview.update', error);
        // Keep this beside playback until a newer edit really reaches the same
        // audition owner; the visible arrangement may differ from its audio.
        this.songPreviewMessage = '修改未进入试听，正在播放上一版';
      }
    }
  }

  private async previewProgram(program: DrumProgram, target: string, looping: boolean = true): Promise<boolean> {
    if (this.previewTarget === target) {
      this.cancelSectionPreviewStop();
      AppSession.get()?.stopDrumPreview();
      this.previewTarget = '';
      this.songPreviewMessage = '';
      return false;
    }
    if (!isProDrumMachineAccessible()) {
      showUserNotice('鼓机权益已到期，编排已保留，请解锁后再试听', 'drum.preview.entitlement');
      return false;
    }
    if (this.previewTarget.length > 0) {
      return false;
    }
    this.cancelSectionPreviewStop();
    const revision = this.sectionPreviewRevision;
    const sectionKeys = target === 'song' ? this.playbackSectionKeys() : undefined;
    try {
      this.previewTarget = target;
      this.songPreviewMessage = '';
      await this.startPreviewPlayback(program, looping, 0, sectionKeys);
      const current = revision === this.sectionPreviewRevision && this.previewTarget === target &&
        AppSession.get()?.isDrumPreviewActive() === true;
      if (!current && revision === this.sectionPreviewRevision && this.previewTarget === target) {
        this.previewTarget = '';
      }
      if (current && target === 'song') {
        this.startSongPreviewProgress();
      }
      return current;
    } catch (error) {
      if (revision === this.sectionPreviewRevision && this.previewTarget === target) {
        this.previewTarget = '';
        logUserFailure('drum.preview.start', error);
        showUserNotice('试听启动失败', 'drum.preview.start');
      }
      return false;
    }
  }

  private async startPreviewPlayback(
    program: DrumProgram,
    looping: boolean,
    startPositionBeats: number = 0,
    sectionKeys?: string[]
  ): Promise<void> {
    await AppSession.get()?.previewDrumProgram(
      serializeDrumProgram(program), looping, this.bpm, this.beatsPerBar, startPositionBeats, sectionKeys);
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

  private stopActivePreview(keepEditorPlayhead: boolean = false): void {
    // Stop clears the engine snapshot. Capture first, revealing the final line
    // once if it crossed a viewport edge since the last paint; pending sample
    // preparation has no newer played position to capture.
    if (keepEditorPlayhead && this.previewTarget === 'editor' && this.editorPreviewTimerId >= 0) {
      this.updateEditorPreviewProgress(false);
      this.keepEditorPlayheadVisible();
    }
    this.stopEditorPreviewProgress(keepEditorPlayhead);
    this.cancelSectionPreviewStop();
    AppSession.get()?.stopDrumPreview();
    this.previewTarget = '';
    this.songPreviewMessage = '';
  }

  private async restartSongPreview(): Promise<void> {
    if (this.previewTarget !== 'song') {
      return;
    }
    this.cancelSectionPreviewStop();
    const revision = this.sectionPreviewRevision;
    const program = this.currentProgram();
    const sectionKeys = this.playbackSectionKeys();
    try {
      await this.startPreviewPlayback(program, true, 0, sectionKeys);
      if (revision === this.sectionPreviewRevision && this.previewTarget === 'song') {
        if (AppSession.get()?.isDrumPreviewActive() === true) {
          this.songPreviewMessage = '';
          this.startSongPreviewProgress();
        } else {
          this.previewTarget = '';
        }
      }
    } catch (error) {
      if (revision === this.sectionPreviewRevision && this.previewTarget === 'song') {
        this.previewTarget = '';
        this.songPreviewMessage = '';
        logUserFailure('drum.preview.switch', error);
        showUserNotice('切换试听失败', 'drum.preview.switch');
      }
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
    } catch (error) {
      if (revision === this.sectionPreviewRevision && this.previewTarget === target) {
        this.previewTarget = '';
        logUserFailure('drum.preview.switch', error);
        showUserNotice('切换试听失败', 'drum.preview.switch');
      }
    }
  }

  private isLeader(): boolean {
    return AppSession.get()?.controller.isLeader === true;
  }

  private async changeBpm(delta: number): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader) {
      return;
    }
    await this.setBpm(controller.bpm + delta);
  }

  private async setBpm(value: number): Promise<void> {
    const controller = AppSession.get()?.controller;
    if (controller === undefined || !controller.isLeader) {
      return;
    }
    const revision = ++this.bpmUpdateRevision;
    try {
      await controller.updateBpm(value);
      if (revision !== this.bpmUpdateRevision || AppSession.get()?.controller !== controller) {
        return;
      }
      this.bpm = controller.bpm;
      this.rememberEditedTempoAndMeter();
      void this.refreshActivePreview();
    } catch (error) {
      if (revision === this.bpmUpdateRevision && AppSession.get()?.controller === controller) {
        logUserFailure('drum.bpm', error);
        showUserNotice(userErrorMessage(error, '速度调整失败，请重试'), 'drum.bpm');
      }
    }
  }

  private async applyToTeam(): Promise<void> {
    const session = AppSession.get();
    if (session === undefined || !session.controller.isLeader || this.saving) {
      return;
    }
    if (!isProDrumMachineAccessible()) {
      showUserNotice('鼓机权益已到期，编排已保留，请解锁后再应用', 'drum.apply.entitlement');
      return;
    }
    const controller = session.controller;
    const lifetime = this.pageLifetimeRevision;
    this.saving = true;
    try {
      const raw = serializeDrumProgram(this.currentProgram());
      AppStorage.setOrCreate('myDrumProgram', raw);
      if (controller.rhythm >= 0 && controller.rhythm <= 2) {
        AppStorage.setOrCreate('lastBasicRhythm', controller.rhythm);
      }
      session.stopDrumPreview();
      await controller.updateMeter(this.beatsPerBar, this.beatUnit);
      if (lifetime !== this.pageLifetimeRevision || AppSession.get() !== session || session.controller !== controller) {
        return;
      }
      if (!isProDrumMachineAccessible()) {
        showUserNotice('鼓机权益已到期，编排已保留，请解锁后再应用', 'drum.apply.entitlement');
        return;
      }
      await controller.updateDrumProgram(raw);
      // Applying spans network awaits; only the page and session that started
      // it may publish its result or navigate away from the current screen.
      if (lifetime !== this.pageLifetimeRevision || AppSession.get() !== session || session.controller !== controller) {
        return;
      }
      showUserNotice('鼓机编排已应用到队伍', 'drum.apply');
      router.back();
    } catch (error) {
      if (lifetime === this.pageLifetimeRevision && AppSession.get() === session && session.controller === controller) {
        logUserFailure('drum.apply', error);
        showUserNotice(userErrorMessage(error, '应用失败，请重试'), 'drum.apply');
      }
    } finally {
      if (lifetime === this.pageLifetimeRevision) {
        this.saving = false;
      }
    }
  }

  @Builder
  private smallStepper(value: number, minus: () => void, plus: () => void) {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Normal }) {
        Text('-').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
      }.width(34).height(32).padding(0).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW).onClick(minus)
      Text(`${value}`).width(30).textAlign(TextAlign.Center).fontSize(19).fontWeight(900)
      Button({ type: ButtonType.Normal }) {
        Text('+').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
      }.width(34).height(32).padding(0).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW).onClick(plus)
    }
  }

  @Builder
  private patternDropdownPanel(sectionIndex: number) {
    Column({ space: 3 }) {
      ForEach(drumPatternNames(this.styleKey), (name: string, patternIndex: number) => {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(name).fontSize(13).fontWeight(FontWeight.Bold)
            Blank()
            if (!this.hasCustomPattern(this.sections[sectionIndex]) &&
              this.sections[sectionIndex].patternIndex === patternIndex) {
              Text('✓').fontSize(13).fontWeight(900)
            }
          }.width('100%')
        }.width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
        .backgroundColor(!this.hasCustomPattern(this.sections[sectionIndex]) &&
          this.sections[sectionIndex].patternIndex === patternIndex ? CORAL : PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
        .onClick(() => this.updatePattern(sectionIndex, patternIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CARD_SHADOW)
  }

  @Builder
  private fillDropdownPanel(sectionIndex: number) {
    Column({ space: 3 }) {
      ForEach(drumFillNames(this.styleKey), (name: string, fillIndex: number) => {
        Button({ type: ButtonType.Normal }) {
          Row() {
            Text(name).fontSize(13).fontWeight(FontWeight.Bold)
            Blank()
            if (!this.hasCustomFill(this.sections[sectionIndex]) &&
              this.sections[sectionIndex].fillIndex === fillIndex) {
              Text('✓').fontSize(13).fontWeight(900)
            }
          }.width('100%')
        }.width('100%').height(32).padding({ left: 10, right: 8 }).fontColor(INK)
        .backgroundColor(!this.hasCustomFill(this.sections[sectionIndex]) &&
          this.sections[sectionIndex].fillIndex === fillIndex ? '#FFD36A' : PAPER)
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
        .onClick(() => this.updateFill(sectionIndex, fillIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CARD_SHADOW)
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
        .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
        .onClick(() => this.selectFillEvery(sectionIndex, optionIndex))
      })
    }.width(this.dropdownMenuWidth).padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CARD_SHADOW)
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
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('×').fontSize(20).fontWeight(900).fontColor('#D83A2E').lineHeight(22)
        }.width(28).height(28).padding(0).backgroundColor('#FFF1E8')
          .border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .enabled(this.sections.length > 1)
          .opacity(this.sections.length > 1 ? 1 : 0.4)
          .accessibilityText(this.sections.length > 1 ? `删除段落 ${this.sections[index].id}` : '至少保留一个段落')
          .onClick(() => this.requestDeleteSection(index))
        Text(this.isSectionExpanded(index) ? '⌃' : '⌄').fontSize(22).width(30).textAlign(TextAlign.Center)
          .accessibilityText(`${this.isSectionExpanded(index) ? '收起' : '展开'}段落 ${this.sections[index].id}`)
          .onClick(() => this.toggleSectionExpanded(index))
      }.width('100%')
      if (this.isSectionExpanded(index)) {
        Row({ space: 7 }) {
          Text('节奏型').fontSize(13).fontWeight(FontWeight.Bold).width(52)
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(this.hasCustomPattern(this.sections[index]) ? EDITED_LABEL :
                drumPatternNames(this.styleKey)[this.sections[index].patternIndex]).fontSize(13).fontWeight(FontWeight.Bold)
              Blank()
              Text(this.dropdownTarget === `menu-pattern-${index}` ? '⌃' : '⌄').fontSize(15)
            }.width('100%')
          }.id(`dm-pattern-${index}`).layoutWeight(1).height(34).padding({ left: 8, right: 7 })
          .fontColor(INK).backgroundColor(this.isSongPhrasePlaying(index, false) ? DRUM_PHRASE_PLAYING_COLOR : PAPER)
          .border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .onClick(() => this.openDropdownFromAnchor(`menu-pattern-${index}`, `dm-pattern-${index}`, 126))
          Button(this.previewTarget === `pattern-${index}` ? '停止' : '试听', { type: ButtonType.Normal })
            .width(54).height(34).padding(0).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .enabled(this.previewTarget.length === 0 || this.previewTarget === `pattern-${index}`)
            .onClick(() => { void this.previewSection(index, false); })
          Button('编辑', { type: ButtonType.Normal }).width(54).height(34).padding(0)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
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
              Text(this.hasCustomFill(this.sections[index]) ? EDITED_LABEL :
                drumFillNames(this.styleKey)[this.sections[index].fillIndex]).fontSize(13).fontWeight(FontWeight.Bold)
              Blank()
              Text(this.dropdownTarget === `menu-fill-${index}` ? '⌃' : '⌄').fontSize(15)
            }.width('100%')
          }.id(`dm-fill-${index}`).layoutWeight(1).height(34).padding({ left: 8, right: 7 })
          .fontColor(INK).backgroundColor(this.isSongPhrasePlaying(index, true) ? DRUM_PHRASE_PLAYING_COLOR : PAPER)
          .border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .onClick(() => this.openDropdownFromAnchor(`menu-fill-${index}`, `dm-fill-${index}`, 126))
          Button(this.previewTarget === `fill-${index}` ? '停止' : '试听', { type: ButtonType.Normal })
            .width(54).height(34).padding(0).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .enabled(this.previewTarget.length === 0 || this.previewTarget === `fill-${index}`)
            .onClick(() => { void this.previewSection(index, true); })
          Button('编辑', { type: ButtonType.Normal }).width(54).height(34).padding(0)
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
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
          .border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
          .onClick(() => this.openDropdownFromAnchor(`menu-frequency-${index}`, `dm-frequency-${index}`, 122))
          Blank()
        }.width('100%')
      }
    }
    .width('100%').padding(12)
    .backgroundColor(this.playingSongSection === index ? DRUM_SECTION_PLAYING_COLOR : '#FFFDF7')
    .border({ width: 1.5, color: INK }).borderRadius(7)
    .shadow(CARD_SHADOW)
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
          .fontWeight(FontWeight.Bold).fontColor(INK).backgroundColor(WHITE)
          .border({ width: 1, color: INK }).borderRadius(10).shadow(CONTROL_SHADOW)
          .onClick(() => this.loadSavedProgram(saved))
      }.width('100%').height('100%').padding(9)
      Button('×', { type: ButtonType.Normal }).width(23).height(23).padding(0).fontSize(18).fontWeight(900)
        .fontColor(INK).backgroundColor(CORAL).border({ width: 1.2, color: INK }).borderRadius(12)
        .position({ x: 89, y: 4 }).zIndex(2)
        .onClick(() => this.deleteSavedProgram(saved.id))
    }
    .width(116).height(82).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(6)
    .shadow(CARD_SHADOW)
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
        Column({ space: 4 }) {
          TextInput({ text: this.saveName, placeholder: '节奏名称，例如：夜跑推进' })
            .height(44).fontSize(15).fontColor(INK).backgroundColor(PAPER)
            .border({ width: 1.5, color: this.saveNameError.length > 0 ? '#B32E23' : INK })
            .borderRadius(5).shadow(CONTROL_SHADOW).maxLength(16)
            .onChange((value: string) => {
              this.saveName = value;
              this.saveNameError = '';
            })
          if (this.saveNameError.length > 0) {
            Text(this.saveNameError).width('100%').fontSize(12).lineHeight(16).fontColor('#B32E23')
          }
        }.width('100%')
        Row({ space: 9 }) {
          Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.saveDialogVisible = false)
          Button('保存', { type: ButtonType.Normal }).layoutWeight(1.4).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.confirmNamedSave())
        }.width('100%')
      }
      .width('88%').padding(16).backgroundColor('#FFF9EE')
      .border({ width: 2, color: INK }).borderRadius(8)
      .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 6, offsetY: 7, color: INK })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(110)
  }

  @Builder
  private overwriteDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text('覆盖已有节奏？').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text(`继续保存会覆盖「${this.saveName.trim()}」的原有编排。`)
          .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
        Divider().strokeWidth(1).color('#C8BFB1')
        Row({ space: 9 }) {
          Button('返回改名', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.returnToRename())
          Button('覆盖保存', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.persistNamedSave(true))
        }.width('100%')
      }
      .width('88%').padding(17).backgroundColor('#FFF1D7')
      .border({ width: 2.5, color: INK }).borderRadius(8)
      .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 7, offsetY: 8, color: INK })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(120)
  }

  @Builder
  private editorOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Stack() {
        Column() {
          Column({ space: 10 }) {
            Row({ space: 12 }) {
              Text(this.editorMode === 0 ? '编辑主节奏' : '编辑加花')
                .fontSize(30).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(PAPER)
                .maxLines(1).layoutWeight(1)
              Button('×', { type: ButtonType.Normal }).width(40).height(40).padding(0)
                .fontSize(32).fontColor(PAPER).backgroundColor('#00000000').borderRadius(20)
                .onClick(() => this.closeEditor())
            }.width('100%')
            Row({ space: 16 }) {
              Text(`段落 ${this.sections[this.selectedSection].id}`)
                .fontSize(14).fontWeight(900).fontColor(CORAL)
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .border({ width: 1.5, color: CORAL }).borderRadius(7)
              Text(`${this.beatsPerBar}/${this.beatUnit}`).fontSize(21).fontWeight(900).fontColor(PAPER)
            }.width('100%')
          }.width('100%').padding({ left: 20, right: 16, top: 14, bottom: 18 }).backgroundColor(INK)
          Column({ space: 12 }) {
            Row() {
              Column({ space: 4 }) {
                Text('第 1 小节').fontSize(20).fontWeight(900).fontColor(INK).width('100%')
                Text(this.editorPatternLabel()).fontSize(12).fontColor('#625D55').width('100%')
                  .lineHeight(18).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1)
              Text('⟶').fontSize(30).fontColor(INK).width(38).textAlign(TextAlign.End)
                .hitTestBehavior(HitTestMode.None)
            }.width('100%').padding({ left: 16, right: 16, top: 14 })
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text('每拍细分').fontSize(12).fontWeight(FontWeight.Bold).fontColor(INK)
                Row({ space: DRUM_EDITOR_SUBDIVISION_GAP }) {
                  ForEach(DRUM_EDITOR_SUBDIVISIONS, (subdivision: number) => {
                    Button(subdivision === 4 ? '4 等分' : `${subdivision} 连音`, { type: ButtonType.Normal })
                      .layoutWeight(1).height(DRUM_EDITOR_SUBDIVISION_HEIGHT).padding(0)
                      .fontSize(12).fontWeight(900).fontColor(INK)
                      .backgroundColor(this.editorSubdivision === subdivision ? CORAL : PAPER)
                      .border({ width: 1.2, color: INK }).borderRadius(6)
                      .accessibilityText(`每拍${subdivision}等分${this.editorSubdivision === subdivision ? '，已选择' : ''}`)
                      .onClick(() => this.chooseEditorSubdivision(subdivision))
                  }, (subdivision: number) => `${subdivision}`)
                }.layoutWeight(1)
              }.width('100%')
              Row() {
                Text(`${this.editorStepCount()} 格 / 小节`).fontSize(11).fontColor('#625D55')
                Blank()
                Text('点格子编辑 · 点数字定位').fontSize(11).fontColor('#625D55')
              }.width('100%')
              if (this.editorOffGridCount() > 0) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 6 }) {
                    Rect().width(6).height(6).fill(INK).rotate({ angle: 45 })
                    Text(`就近保留 ${this.editorOffGridCount()} 个细分鼓点`)
                      .fontSize(12).fontWeight(FontWeight.Bold).fontColor(INK)
                  }.width('100%').justifyContent(FlexAlign.Start)
                }.width('100%').height(30).padding({ left: 8, right: 8 }).backgroundColor('#E8DFF2')
                  .border({ width: 0.8, color: '#A89BB6' }).borderRadius(5)
                  .accessibilityText(`就近保留 ${this.editorOffGridCount()} 个细分鼓点，将全部菱形吸附到当前网格`)
                  .onClick(() => this.snapAllEditorOffGridEvents())
              }
            }.width('100%').padding({ left: 16, right: 16 })
            Scroll() {
              Row() {
                Column() {
                  Blank().height(DRUM_EDITOR_HEADER_HEIGHT)
                  ForEach(DRUM_TRACKS, (track: DrumTrack) => {
                    Text(track.name).width('100%').height(this.editorTrackRowHeight)
                      .fontSize(13).fontWeight(FontWeight.Bold).fontColor(INK).maxLines(1)
                      .padding({ left: 8, right: 5 })
                      .border({ width: { bottom: 0.7 }, color: '#B9B0A2' })
                  }, (track: DrumTrack) => track.key)
                  Blank().height(DRUM_EDITOR_SCROLLBAR_SPACE)
                }.width(DRUM_EDITOR_LABEL_WIDTH).height(this.editorGridHeight())
                  .border({ width: { right: 1 }, color: '#8C8376' })
                Scroll(this.editorScroller) {
                  Stack({ alignContent: Alignment.TopStart }) {
                    Column() {
                      Row() {
                        ForEach(this.editorBeatIndexes(), (beat: number) => {
                          Text(`${beat + 1} 拍`)
                            .width(this.editorSubdivision * DRUM_EDITOR_CELL_WIDTH)
                            .height(DRUM_EDITOR_BEAT_HEIGHT)
                            .textAlign(TextAlign.Center).fontSize(11).fontWeight(FontWeight.Bold).fontColor(INK)
                            .border({ width: { bottom: 1, left: 0.7 }, color: '#8C8376' })
                        }, (beat: number) => `${beat}`)
                      }.width(this.editorGridWidth())
                      Row() {
                        ForEach(this.editorStepIndexes(), (step: number) => {
                          Text(`${step % this.editorSubdivision + 1}`).width(DRUM_EDITOR_CELL_WIDTH)
                            .height(DRUM_EDITOR_HEADER_HEIGHT - DRUM_EDITOR_BEAT_HEIGHT).textAlign(TextAlign.Center)
                            .fontSize(12).fontWeight(900).fontColor(INK)
                            .border({ width: { left: step % this.editorSubdivision === 0 ? 1 :
                              (this.editorSubdivision === 6 && step % 6 === 3 ? 0.7 : 0) }, color: '#C2B8AA' })
                            .borderStyle(this.editorSubdivision === 6 && step % 6 === 3 ? BorderStyle.Dashed : BorderStyle.Solid)
                            .accessibilityText(`第 ${Math.floor(step / this.editorSubdivision) + 1} 拍第 ${step % this.editorSubdivision + 1} 格，从此处试听`)
                            .onClick(() => this.seekEditorStep(step))
                        }, (step: number) => `${step}`)
                      }.width(this.editorGridWidth())
                      ForEach(DRUM_TRACKS, (_track: DrumTrack, trackIndex: number) => {
                        Stack({ alignContent: Alignment.TopStart }) {
                          Row() {
                            ForEach(this.editorStepIndexes(), (step: number) => {
                              Row() {
                                Button('', { type: ButtonType.Normal }).width(DRUM_EDITOR_BUTTON_WIDTH)
                                  .height(this.editorTrackRowHeight - 8).padding(0)
                                  .backgroundColor(this.editorCellColor(trackIndex, step))
                                  .border({ width: 0.8, color: '#776F65', radius: DRUM_EDITOR_CELL_RADIUS })
                                  .borderRadius(DRUM_EDITOR_CELL_RADIUS).clip(true)
                                  .enabled(this.editorStepEditable(step))
                                  .opacity(this.editorStepEditable(step) ? 1 : DRUM_EDITOR_LOCKED_CELL_OPACITY)
                                  .accessibilityText(this.editorStepEditable(step) ?
                                    `${_track.name}，第 ${Math.floor(step / this.editorSubdivision) + 1} 拍第 ${step % this.editorSubdivision + 1} 格，${this.editorCellEnabled(trackIndex, step) ? '关闭' : '添加'}鼓点` :
                                    `${_track.name}，第 ${Math.floor(step / this.editorSubdivision) + 1} 拍第 ${step % this.editorSubdivision + 1} 格，主节奏，不可编辑`)
                                  .onClick(() => this.toggleStep(trackIndex, step))
                              }.width(DRUM_EDITOR_CELL_WIDTH).height(this.editorTrackRowHeight)
                                .justifyContent(FlexAlign.Center)
                                .border({ width: { left: step % this.editorSubdivision === 0 ? 1 :
                                  (this.editorSubdivision === 6 && step % 6 === 3 ? 0.7 : 0) }, color: '#A59B8D' })
                                .borderStyle(this.editorSubdivision === 6 && step % 6 === 3 ? BorderStyle.Dashed : BorderStyle.Solid)
                            }, (step: number) => `${step}`)
                          }.height(this.editorTrackRowHeight).width(this.editorGridWidth())
                          ForEach(this.editorOffGridEvents(trackIndex), (event: SequencerEvent) => {
                            Button({ type: ButtonType.Normal }) {
                              Rect().width(DRUM_EDITOR_OFF_GRID_SIZE).height(DRUM_EDITOR_OFF_GRID_SIZE)
                                .fill(INK).stroke(PAPER).strokeWidth(1).rotate({ angle: 45 })
                            }.width(DRUM_EDITOR_OFF_GRID_HIT_SIZE).height(this.editorTrackRowHeight).padding(0)
                              .backgroundColor('#00000000').borderRadius(0)
                              .enabled(this.editorEventTickEditable(event.tick))
                              .opacity(this.editorEventTickEditable(event.tick) ? 1 : DRUM_EDITOR_LOCKED_CELL_OPACITY)
                              .position({ x: this.editorOffGridX(event), y: 0 })
                              .accessibilityText(this.editorEventTickEditable(event.tick) ?
                                `${_track.name}，第 ${(event.tick / DEFAULT_TICKS_PER_BEAT + 1).toFixed(2)} 拍，点按就近保留到当前格子` :
                                `${_track.name}，第 ${(event.tick / DEFAULT_TICKS_PER_BEAT + 1).toFixed(2)} 拍，主节奏，不可编辑`)
                              .onClick(() => this.snapEditorEventToGrid(trackIndex, event.tick))
                          }, (event: SequencerEvent) => `${event.sampleKey}-${event.tick}`)
                        }.height(this.editorTrackRowHeight).width(this.editorGridWidth())
                          .border({ width: { bottom: 0.7 }, color: '#B9B0A2' })
                      }, (track: DrumTrack) => track.key)
                      Blank().height(DRUM_EDITOR_SCROLLBAR_SPACE)
                    }.width(this.editorGridWidth())
                    Rect().width(DRUM_EDITOR_PLAYHEAD_WIDTH).height(this.editorTracksHeight())
                      .fill(CORAL).position({ x: this.editorPlayheadX(), y: DRUM_EDITOR_HEADER_HEIGHT })
                      .visibility(this.editorPlayheadStep >= 0 ? Visibility.Visible : Visibility.Hidden)
                      .zIndex(10).hitTestBehavior(HitTestMode.None)
                    Polygon().width(DRUM_EDITOR_PLAYHEAD_CAP_WIDTH).height(7)
                      .points([[0, 0], [DRUM_EDITOR_PLAYHEAD_CAP_WIDTH, 0], [DRUM_EDITOR_PLAYHEAD_CAP_WIDTH / 2, 7]])
                      .fill(CORAL).position({ x: this.editorPlayheadCapX(), y: DRUM_EDITOR_BEAT_HEIGHT - 7 })
                      .visibility(this.editorPlayheadStep >= 0 ? Visibility.Visible : Visibility.Hidden)
                      .zIndex(10).hitTestBehavior(HitTestMode.None)
                  }.width(this.editorGridWidth()).height(this.editorGridHeight())
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.On)
                .scrollBarColor('#5C5952')
                .scrollBarWidth(5)
                .clip(true)
                .layoutWeight(1)
                .height(this.editorGridHeight())
                .onAreaChange((_old: Area, area: Area) => this.updateEditorViewport(Number(area.width)))
                .onAppear(() => this.editorScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false }))
              }.width('100%').height(this.editorGridHeight())
            }.width('100%').layoutWeight(1).align(Alignment.TopStart)
              .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off).clip(true)
              .onAreaChange((_old: Area, area: Area) => this.updateEditorGridViewport(Number(area.height)))
          }.width('100%').layoutWeight(1).backgroundColor(PAPER)
          Row({ space: 8 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                Image($rawfile(this.previewTarget === 'editor' ? 'comic/icons/stop.svg' : 'comic/icons/play.svg'))
                  .width(17).height(17).objectFit(ImageFit.Contain)
                Text(this.previewTarget === 'editor' ? '停止' : '试听').fontSize(14).fontWeight(900).fontColor(INK)
              }.justifyContent(FlexAlign.Center)
            }.layoutWeight(1.2).height(DRUM_EDITOR_ACTION_HEIGHT).padding(0)
              .backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(7).shadow(CONTROL_SHADOW)
              .onClick(() => { void this.toggleEditorPreview(); })
            Button(this.editorMode === 0 ? '应用到节奏型' : '应用到加花', { type: ButtonType.Normal })
              .layoutWeight(2).height(DRUM_EDITOR_ACTION_HEIGHT).padding(0).fontSize(14).fontWeight(900).fontColor(INK)
              .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(7).shadow(CONTROL_SHADOW)
              .onClick(() => this.saveEditor())
          }.width('100%').padding({ left: 12, right: 14, top: 14, bottom: 16 })
            .backgroundColor(PAPER).border({ width: { top: 2 }, color: INK })
        }.width('100%').height('100%').backgroundColor(PAPER)
          .borderRadius(DRUM_EDITOR_PANEL_RADIUS).clip(true)
      }.width('100%').height('100%')
        .constraintSize({ maxWidth: DRUM_EDITOR_PANEL_MAX_WIDTH, maxHeight: DRUM_EDITOR_PANEL_MAX_HEIGHT })
        .backgroundColor(PAPER).border({ width: 2, color: INK, radius: DRUM_EDITOR_PANEL_RADIUS })
        .borderRadius(DRUM_EDITOR_PANEL_RADIUS)
        .shadow({ radius: INK_SHADOW_RADIUS, offsetX: 4, offsetY: 6, color: INK })
    }.width('100%').height('100%')
      .padding({ left: DRUM_EDITOR_OVERLAY_SIDE_INSET, right: DRUM_EDITOR_OVERLAY_SIDE_INSET,
        top: this.topSafeInset + DRUM_EDITOR_OVERLAY_VERTICAL_INSET,
        bottom: this.bottomSafeInset + DRUM_EDITOR_OVERLAY_VERTICAL_INSET })
      .backgroundColor('#66000000').zIndex(100)
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
              .shadow(CONTROL_SHADOW)
            Blank()
            Button('保存', { type: ButtonType.Normal }).height(36).fontColor(INK).backgroundColor(CORAL)
              .border({ width: 1.5, color: INK }).borderRadius(18).shadow(CONTROL_SHADOW).onClick(() => this.openSaveDialog())
          }.width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('选择风格').fontSize(16).fontWeight(900)
            Blank()
            Row({ space: 3 }) {
              Text('横滑查看更多').fontSize(10).fontColor('#655E55')
              Text('→').fontSize(16).fontWeight(900).fontColor('#655E55')
            }
          }.width('100%')
          Scroll() {
            Row({ space: 8 }) {
              ForEach(DRUM_STYLES, (style: DrumStyle) => {
                Column({ space: 2 }) {
                  Text(style.name).fontSize(13).fontWeight(900)
                  Text(style.caption).fontSize(9)
                }.padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .backgroundColor(this.styleKey === style.key ? style.color : PAPER)
                .border({ width: 1, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
                .onClick(() => this.chooseStyle(style.key))
              }, (style: DrumStyle) => style.key)
            }.padding({ bottom: 4 })
          }.scrollable(ScrollDirection.Horizontal).width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row() {
            Text('拍号').fontSize(16).fontWeight(900).width(58)
            EditableMeter({
              beats: this.beatsPerBar,
              unit: this.beatUnit,
              editable: this.isLeader(),
              controlWidth: '100%',
              controlHeight: 38,
              valueFontSize: 20,
              onEdit: (): void => { this.meterEditorVisible = true; }
            })
            .layoutWeight(1)
          }.width('100%')
          Divider().strokeWidth(1).color('#D4CBBE')
          Row({ space: 8 }) {
            Text('BPM').fontSize(16).fontWeight(900).width(58)
            Button({ type: ButtonType.Normal }) {
              Text('−').fontSize(22).fontWeight(900).fontColor(INK).lineHeight(24)
            }.width(38).height(38).padding(0).backgroundColor(PAPER)
              .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
              .enabled(this.isLeader() && this.bpm > 40)
              .onClick(() => { void this.changeBpm(-1); })
            EditableBpm({
              value: this.bpm,
              editable: this.isLeader(),
              inputId: 'drum-machine-bpm-input',
              controlWidth: '100%',
              controlHeight: 38,
              valueFontSize: 32,
              onCommit: (value: number): void => { void this.setBpm(value); }
            }).layoutWeight(1)
            Button({ type: ButtonType.Normal }) {
              Text('+').fontSize(21).fontWeight(900).fontColor(INK).lineHeight(24)
            }.width(38).height(38).padding(0).backgroundColor(PAPER)
              .border({ width: 1, color: INK }).borderRadius(4).shadow(CONTROL_SHADOW)
              .enabled(this.isLeader() && this.bpm < 240)
              .onClick(() => { void this.changeBpm(1); })
          }.width('100%')
          Text(`每分钟 ${this.bpm} 个${beatUnitLabel(this.beatUnit)}音符拍点`)
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
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
            .enabled(this.sections.length < 8)
            .opacity(this.sections.length < 8 ? 1 : 0.4)
            .accessibilityText(this.sections.length < 8 ? '新增段落' : '最多编排 8 个段落')
            .onClick(() => this.addSection())
          Row({ space: 8 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                Image($rawfile(this.previewTarget === 'song' ?
                  'comic/icons/stop.svg' : 'comic/icons/play.svg'))
                  .width(19).height(19).objectFit(ImageFit.Contain)
                Text(this.previewTarget === 'song' ? '停止整曲' : '试听整曲')
                  .fontSize(14).fontWeight(900).fontColor(INK)
              }.justifyContent(FlexAlign.Center)
            }.layoutWeight(1).height(48).padding(0)
              .fontColor(INK).backgroundColor(WHITE).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
              .enabled(this.previewTarget.length === 0 || this.previewTarget === 'song')
              .onClick(() => { void this.togglePreview(); })
            Button(this.saving ? '应用中…' : '应用到队伍 ›', { type: ButtonType.Normal }).layoutWeight(1.4).height(48)
              .fontColor(INK).fontWeight(900).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(6).shadow(CONTROL_SHADOW)
              .enabled(!this.saving).onClick(() => { void this.applyToTeam(); })
          }.width('100%')
          if (this.previewTarget === 'song' && this.songPreviewMessage.length > 0) {
            Text(this.songPreviewMessage).width('100%').fontSize(12).lineHeight(18).fontColor('#B32E23')
          }
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
            .backgroundColor('#FFFDF7').border({ width: 1, color: '#C8BFB1' }).borderRadius(6).shadow(CONTROL_SHADOW)
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
      if (this.meterEditorVisible) {
        MeterEditorOverlay({
          initialBeats: this.beatsPerBar,
          initialUnit: this.beatUnit,
          onChange: (beats: number, unit: number): void => { this.chooseMeter(beats, unit); },
          onDismiss: (): void => { this.meterEditorVisible = false; }
        })
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
