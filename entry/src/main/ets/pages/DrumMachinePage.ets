import { router } from '@kit.ArkUI';
import { ActionButton } from '../components/ActionButton';
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
import { DrumPaper } from '../components/DrumPaper';
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
  drumSectionStyleKey,
  drumProgramStyleKeys,
  drumProgramStyleSummary,
  drumFillDescription,
  drumFillNames,
  drumPatternDescription,
  drumPatternNames,
  parseDrumProgram,
  serializeDrumProgram,
  styleByKey
} from '../audio/DrumMachineCatalog';

import {
  SavedDrumProgram, loadSavedDrumPrograms, writeSavedDrumPrograms,
  loadRecentDrumProgram, rememberRecentDrumProgram, resolveSavedDrumProgram
} from '../audio/DrumProgramLibrary';

const FILL_FREQUENCIES: number[] = [1, 2, 4, 8, 16];
const EDITED_LABEL: string = '已编辑';

interface DrumSectionSelectionState {
  playbackKey: string;
  styleKey: string;
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
const DRUM_EDITOR_PANEL_RADIUS: number = 8;
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
const DRUM_EDITOR_CONTROL_SHADOW_OFFSET: number = 2;
const DRUM_EDITOR_ACTION_SHADOW_OFFSET: number = 4;
const DRUM_EDITOR_CELL_SHADOW_OFFSET: number = 1;
const DRUM_EDITOR_OFF_GRID_SIZE: number = 10;
const DRUM_EDITOR_OFF_GRID_HIT_SIZE: number = 18;
const DRUM_EDITOR_FILL_FOCUS_DELAY_MS: number = 1000;
const DRUM_SECTION_PLAYING_COLOR: string = '#EDE4FA';
const DRUM_SECTION_TITLE_GAP: number = 4;
const DRUM_SECTION_TOGGLE_WIDTH: number = 22;
const DRUM_SONG_PREVIEW_PROGRESS_MS: number = 16;
const DRUM_SONG_PREVIEW_UPDATE_DELAY_MS: number = 150;

const DRUM_OUTER_RADIUS: number = 8;
const DRUM_INNER_RADIUS: number = 6;
const DRUM_PAGE_SIDE_INSET: number = 16;
const DRUM_SAVED_CARD_SIZE: number = 112;
const DRUM_POPOVER_MIN_WIDTH: number = 180;
const DRUM_STYLE_POPOVER_WIDTH: number = 320;
const DRUM_STYLE_POPOVER_THREE_COLUMN_MIN: number = 300;
const DRUM_POPOVER_GAP: number = 2;
const DRUM_POPOVER_TAIL: number = 6;
const DRUM_POPOVER_PADDING: number = 8;
const DRUM_POPOVER_HEADER_HEIGHT: number = 20;
const DRUM_POPOVER_HEADER_GAP: number = 8;
const DRUM_POPOVER_OPTION_GAP: number = 4;
const DRUM_POPOVER_ROW_HEIGHT: number = 30;
const DRUM_POPOVER_SHADOW_OFFSET: number = 3;
const DRUM_CARD_HARD_SHADOW: ShadowOptions = { radius: 0, offsetX: 4, offsetY: 4, color: INK };
const DRUM_HEADER_HEIGHT: number = 48;
const DRUM_SETTINGS_HEIGHT: number = 42;
const DRUM_BODY_INSET: number = 0;
const DRUM_CONTENT_TOP_INSET: number = 12;
const DRUM_CONTENT_BOTTOM_INSET: number = 20;
const DRUM_FOOTER_INSET: number = 12;
const DRUM_ACTION_HEIGHT: number = 44;
const DRUM_ADD_SECTION_HEIGHT: number = 36;
const DRUM_BLOCK_GAP: number = 12;
const DRUM_ARRANGEMENT_TITLE_HEIGHT: number = 32;
const DRUM_ARRANGEMENT_META_HEIGHT: number = 18;
const DRUM_ARRANGEMENT_HEADING_GAP: number = 4;
const DRUM_ARRANGEMENT_ACTION_WIDTH: number = 74;
const DRUM_ARRANGEMENT_ACTION_HEIGHT: number = 28;
const DRUM_ARRANGEMENT_ACTION_GAP: number = 8;
const DRUM_NEW_PROGRAM_DIALOG_MAX_WIDTH: number = 360;
const DRUM_NEW_PROGRAM_DIALOG_PADDING: number = 18;
const DRUM_NEW_PROGRAM_DIALOG_BUTTON_HEIGHT: number = 42;
const DRUM_SECTION_TAB_WIDTH: number = 96;
const DRUM_SECTION_HEADER_HEIGHT: number = 34;
const DRUM_SECTION_STYLE_WIDTH: number = 84;
const DRUM_FORM_ROW_HEIGHT: number = 40;
const DRUM_FIELD_HEIGHT: number = 30;
const DRUM_FIELD_LABEL_WIDTH: number = 42;
const DRUM_PHRASE_ICON_SIZE: number = 18;
const DRUM_PHRASE_ACTION_WIDTH: number = 32;
const DRUM_CONTROL_HARD_SHADOW: ShadowOptions = { radius: 0, offsetX: 2, offsetY: 2, color: INK };

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
  @State dropdownAbove: boolean = false;
  @State dropdownTailX: number = 24;
  @State pendingStyleKey: string = '';
  @State pendingStyleSection: number = -1;
  @State dropdownSectionIndex: number = 0;
  @State saveDialogVisible: boolean = false;
  @State overwriteDialogVisible: boolean = false;
  @State meterEditorVisible: boolean = false;
  @State saveName: string = '';
  @State saveNameError: string = '';
  @State songPreviewMessage: string = '';
  @State savedPrograms: SavedDrumProgram[] = [];
  @State savedProgramsRevision: number = 0;
  @State loadedProgramId: string = '';
  @State newProgramDialogVisible: boolean = false;
  @State newProgramAfterSave: boolean = false;
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
  private dropdownAnchorId: string = '';
  private dropdownTouchX: number = 0;
  private dropdownTouchY: number = 0;
  private dropdownTouchMoved: boolean = false;
  private readonly pageScroller: Scroller = new Scroller();
  private readonly editorScroller: Scroller = new Scroller();
  private editorViewportWidth: number = 0;
  private editorPreviewTimerId: number = -1;
  private editorPreviewRevision: number = 0;
  private editorPreviewCycle: number = -1;
  private editorFillFocusTimerId: number = -1;
  private bpmUpdateRevision: number = 0;
  private pageLifetimeRevision: number = 0;
  private cleanProgramRaw: string = '';

  aboutToAppear(): void {
    this.pageLifetimeRevision++;
    this.saving = false;
    if (!isProDrumMachineAccessible()) {
      showUserNotice('请先在大厅解锁鼓机月卡或分享试用', 'drum.entitlement');
      router.back();
      return;
    }
    this.loadSavedPrograms();
    this.loadedProgramId = '';
    this.newProgramDialogVisible = false;
    this.newProgramAfterSave = false;
    this.saveDialogVisible = false;
    this.overwriteDialogVisible = false;
    const controller = AppSession.get()?.controller;
    let program = defaultDrumProgram();
    let sourceId: string | undefined = '';
    let restoringRecent: boolean = false;
    if (controller !== undefined && controller.drumProgram.length > 0) {
      program = parseDrumProgram(controller.drumProgram);
      sourceId = controller.drumProgramLibraryId;
    } else {
      const recent = loadRecentDrumProgram();
      if (recent !== undefined) {
        program = parseDrumProgram(recent.program);
        sourceId = recent.libraryId;
        restoringRecent = true;
      }
    }
    const owned = resolveSavedDrumProgram(serializeDrumProgram(program), sourceId, this.savedPrograms);
    this.loadedProgramId = owned?.id ?? '';
    this.styleKey = program.styleKey;
    this.sections = program.sections;
    this.resetSectionPlaybackKeys();
    this.expandedSections = this.sections.map((_section: DrumSection, index: number) => index === 0);
    const editorSettings = controller?.getProDrumEditorSettings();
    if (restoringRecent) {
      // A recent arrangement includes its own meter. The room still owns live BPM;
      // restoring the local draft must not publish a meter change before Apply.
      this.beatsPerBar = program.beatsPerBar;
      this.beatUnit = program.beatUnit;
      this.bpm = controller?.bpm ?? this.bpm;
    } else if (editorSettings !== undefined) {
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
    this.cleanProgramRaw = owned?.program ?? serializeDrumProgram(this.currentProgram());
  }

  private rememberEditedTempoAndMeter(): void {
    AppSession.get()?.controller.rememberProDrumEditorSettings(
      this.beatsPerBar, this.beatUnit, this.bpm);
  }

  onBackPress(): boolean {
    if (this.overwriteDialogVisible) {
      this.returnToRename();
      return true;
    }
    if (this.saveDialogVisible) {
      this.cancelSaveFlow();
      return true;
    }
    if (this.newProgramDialogVisible) {
      this.cancelNewProgram();
      return true;
    }
    if (this.pendingStyleKey.length > 0) {
      this.pendingStyleKey = '';
      return true;
    }
    if (this.dropdownTarget.length > 0) {
      this.closeDropdown();
      return true;
    }
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
    this.savedPrograms = loadSavedDrumPrograms();
    this.savedProgramsRevision++;
  }

  private hasUnsavedProgramChanges(): boolean {
    // Tempo is preserved by New and is not part of a library arrangement.
    return serializeDrumProgram(this.currentProgram()) !== this.cleanProgramRaw;
  }

  private requestNewProgram(): void {
    if (this.saving || this.newProgramDialogVisible || this.saveDialogVisible || this.overwriteDialogVisible) {
      return;
    }
    this.closeDropdown();
    if (this.hasUnsavedProgramChanges()) {
      this.newProgramDialogVisible = true;
    } else {
      this.beginNewProgram();
    }
  }

  private cancelNewProgram(): void {
    this.newProgramDialogVisible = false;
    this.newProgramAfterSave = false;
  }

  private saveBeforeNewProgram(): void {
    this.newProgramDialogVisible = false;
    this.newProgramAfterSave = true;
    this.openSaveDialog();
  }

  private cancelSaveFlow(): void {
    this.saveDialogVisible = false;
    this.overwriteDialogVisible = false;
    this.newProgramAfterSave = false;
  }

  private beginNewProgram(): void {
    this.stopActivePreview();
    this.bpmUpdateRevision++;
    this.clearEditorFillFocusTimer();
    this.closeDropdown();
    this.pendingStyleKey = '';
    this.editorVisible = false;
    this.meterEditorVisible = false;
    this.cancelSaveFlow();
    this.newProgramDialogVisible = false;
    this.loadedProgramId = '';

    const fresh = defaultDrumProgram();
    this.styleKey = fresh.styleKey;
    this.selectedSection = 0;
    this.expandedSections = [true];
    this.sections = fresh.sections;
    this.resetSectionPlaybackKeys();
    this.contextStates = [];
    this.storeCurrentContext();
    this.cleanProgramRaw = serializeDrumProgram(this.currentProgram());
    // New only replaces the local draft. Meter/tempo and the applied team program stay owned by the session.
    this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }

  private openSaveDialog(): void {
    this.closeDropdown();
    const loaded = this.loadedProgram();
    if (loaded !== undefined) {
      this.saveName = loaded.name;
      this.persistNamedSave(true, loaded.id);
      return;
    }
    this.saveName = '';
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

  private loadedProgram(): SavedDrumProgram | undefined {
    return this.savedPrograms.find((saved: SavedDrumProgram) => saved.id === this.loadedProgramId);
  }

  private loadedProgramName(): string {
    return this.loadedProgram()?.name ?? '';
  }

  private arrangementTitleName(): string {
    return this.loadedProgramName() || '未命名';
  }

  private persistNamedSave(overwrite: boolean, targetId: string = ''): void {
    const name = this.saveName.trim();
    const program = serializeDrumProgram(this.currentProgram());
    const next: SavedDrumProgram[] = [];
    let replaced = false;
    let savedId = '';
    for (let i = 0; i < this.savedPrograms.length; i++) {
      const saved = this.savedPrograms[i];
      if (overwrite && (targetId.length > 0 ? saved.id === targetId : saved.name === name)) {
        next.push({ id: saved.id, name: name, program: program });
        replaced = true;
        savedId = saved.id;
      } else {
        next.push(saved);
      }
    }
    if (!replaced) {
      savedId = `rhythm-${Date.now()}`;
      next.unshift({ id: savedId, name: name, program: program });
    }
    try {
      writeSavedDrumPrograms(next);
    } catch (error) {
      // A save continuation may discard the old draft only after persistence completes.
      this.saveNameError = '保存失败，请重试';
      logUserFailure('drum.save', error);
      showUserNotice('保存失败，当前编排仍然保留', 'drum.save');
      if (this.newProgramAfterSave && !this.saveDialogVisible && !this.overwriteDialogVisible) {
        this.newProgramAfterSave = false;
        this.newProgramDialogVisible = true;
      }
      return;
    }
    this.savedPrograms = next;
    // ForEach reuses closures by key. A stable record ID alone keeps old meter/style/callback data after overwrite.
    this.savedProgramsRevision++;
    // An explicitly loaded/saved record owns later saves by ID, even after its draft changes.
    this.loadedProgramId = savedId;
    this.cleanProgramRaw = program;
    AppSession.get()?.controller.rememberDrumProgramLibraryId(program, savedId);
    this.rememberRecentProgram(program, savedId);
    this.saveDialogVisible = false;
    this.overwriteDialogVisible = false;
    showUserNotice(replaced ? '已更新我的编排' : '已保存到我的编排', 'drum.save');
    if (this.newProgramAfterSave) {
      this.beginNewProgram();
    }
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
    try {
      writeSavedDrumPrograms(next);
    } catch (error) {
      logUserFailure('drum.delete', error);
      showUserNotice('删除失败，原编排仍然保留，请重试', 'drum.delete');
      return;
    }
    this.savedPrograms = next;
    this.savedProgramsRevision++;
    if (this.loadedProgramId === id) {
      this.loadedProgramId = '';
      this.cleanProgramRaw = '';
    }
  }

  private rememberRecentProgram(raw: string, libraryId: string): void {
    try {
      rememberRecentDrumProgram(raw, libraryId);
    } catch (error) {
      // The saved library / applied room state already committed; a cache failure must not undo either one.
      logUserFailure('drum.recent', error);
    }
  }

  private loadSavedProgram(saved: SavedDrumProgram): void {
    const wasPreviewing = this.previewTarget.length > 0;
    const program = parseDrumProgram(saved.program);
    this.loadedProgramId = saved.id;
    this.newProgramAfterSave = false;
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
    this.cleanProgramRaw = serializeDrumProgram(this.currentProgram());
    if (wasPreviewing) {
      void this.refreshActivePreview();
    }
  }

  private savedProgramMeter(saved: SavedDrumProgram): string {
    const program = parseDrumProgram(saved.program);
    return `${program.beatsPerBar}/${program.beatUnit}`;
  }

  private savedProgramStyle(saved: SavedDrumProgram): string {
    return drumProgramStyleSummary(parseDrumProgram(saved.program));
  }

  aboutToDisappear(): void {
    this.cancelSaveFlow();
    this.newProgramDialogVisible = false;
    this.closeDropdown();
    this.pendingStyleKey = '';
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
      sections: this.sections.map((section: DrumSection) => this.copySection(section))
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
      styleKey: section.styleKey ?? this.styleKey,
      patternIndex: section.patternIndex,
      repeats: section.repeats,
      fillIndex: section.fillIndex,
      fillEvery: section.fillEvery,
      customPattern: cloneDrumCustomPattern(section.customPattern),
      customFill: cloneDrumCustomPattern(section.customFill),
      customRows: this.copyOptionalRows(section.customRows),
      customFillRows: this.copyOptionalRows(section.customFillRows)
    };
  }

  private contextKey(styleKey: string, beats: number, unit: number): string {
    return `${beats}-${unit}`;
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
        playbackKey: this.playbackSectionKeys()[i],
        styleKey: this.sectionStyleKey(i),
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
      // Letters and indices can move after deletion; drafts belong to the stable section identity.
      const selection = saved?.selections.find((value: DrumSectionSelectionState) =>
        value.playbackKey === this.playbackSectionKeys()[i]);
      if (selection !== undefined) {
        section.styleKey = selection.styleKey;
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

  private sectionStyleKey(index: number): string {
    const section = this.sections[index];
    return section === undefined ? this.styleKey : drumSectionStyleKey(this.currentProgramBase(), section);
  }

  private currentProgramBase(): DrumProgram {
    return { styleKey: this.styleKey, beatsPerBar: this.beatsPerBar, beatUnit: this.beatUnit,
      sections: this.sections };
  }

  private chooseSectionStyle(index: number, key: string): void {
    this.closeDropdown();
    if (index < 0 || index >= this.sections.length || this.sectionStyleKey(index) === key) {
      return;
    }
    if (this.hasCustomPattern(this.sections[index]) || this.hasCustomFill(this.sections[index])) {
      this.pendingStyleSection = index;
      this.pendingStyleKey = key;
      return;
    }
    this.applySectionStyle(index, key, false);
  }

  private applySectionStyle(index: number, key: string, keepCustom: boolean): void {
    if (index < 0 || index >= this.sections.length) {
      this.pendingStyleKey = '';
      return;
    }
    const section = this.copySection(this.sections[index]);
    section.styleKey = styleByKey(key).key;
    section.patternIndex = 0;
    section.fillIndex = 0;
    // A new preset must not silently overwrite a hand-edited phrase.
    if (!keepCustom) {
      section.customPattern = undefined;
      section.customFill = undefined;
      section.customRows = undefined;
      section.customFillRows = undefined;
    }
    this.pendingStyleKey = '';
    this.replaceSection(index, section);
    this.storeCurrentContext();
    this.notifySectionEdited(index);
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

  private styleDropdownColumns(): number {
    return this.dropdownMenuWidth >= DRUM_STYLE_POPOVER_THREE_COLUMN_MIN ? 3 : 2;
  }

  private styleDropdownRows(): number[] {
    const rows: number[] = [];
    for (let row = 0; row < Math.ceil(DRUM_STYLES.length / this.styleDropdownColumns()); row++) {
      rows.push(row);
    }
    return rows;
  }

  private dropdownHeight(): number {
    const count = this.dropdownKind === 'style' ? this.styleDropdownRows().length :
      this.dropdownKind === 'frequency' ? FILL_FREQUENCIES.length : 3;
    const headerHeight = this.dropdownKind === 'style' ? DRUM_POPOVER_HEADER_HEIGHT + DRUM_POPOVER_HEADER_GAP : 0;
    return DRUM_POPOVER_PADDING * 2 + headerHeight +
      DRUM_POPOVER_TAIL + count * DRUM_POPOVER_ROW_HEIGHT + Math.max(0, count - 1) * DRUM_POPOVER_OPTION_GAP;
  }

  private openDropdownFromAnchor(target: string, anchorId: string): void {
    if (this.dropdownTarget === target) {
      this.closeDropdown();
      return;
    }
    const parts = target.split('-');
    this.dropdownKind = parts[1];
    this.dropdownSectionIndex = Number.parseInt(parts[parts.length - 1], 10);
    this.dropdownAnchorId = anchorId;
    try {
      const ui = this.getUIContext();
      const anchor = ui.getComponentUtils().getRectangleById(anchorId);
      const content = ui.getComponentUtils().getRectangleById('dm-scroll-content');
      const viewport = ui.getComponentUtils().getRectangleById('dm-page-scroll');
      const contentX = ui.px2vp(content.windowOffset.x);
      const contentY = ui.px2vp(content.windowOffset.y);
      const width = ui.px2vp(content.size.width);
      const anchorLeft = ui.px2vp(anchor.windowOffset.x);
      const anchorWidth = ui.px2vp(anchor.size.width);
      const anchorTop = ui.px2vp(anchor.windowOffset.y);
      const anchorBottom = anchorTop + ui.px2vp(anchor.size.height);
      const menuWidth = this.dropdownKind === 'style' ? DRUM_STYLE_POPOVER_WIDTH :
        Math.max(DRUM_POPOVER_MIN_WIDTH, anchorWidth);
      this.dropdownMenuWidth = Math.min(menuWidth, width - DRUM_PAGE_SIDE_INSET * 2 - DRUM_POPOVER_SHADOW_OFFSET);
      // Lists extend their field edges; the wider palette grows left from its compact style trigger.
      const menuLeft = this.dropdownKind === 'style' ? anchorLeft + anchorWidth - this.dropdownMenuWidth : anchorLeft;
      this.dropdownAnchorX = Math.max(DRUM_PAGE_SIDE_INSET, Math.min(width -
        DRUM_PAGE_SIDE_INSET - this.dropdownMenuWidth - DRUM_POPOVER_SHADOW_OFFSET, menuLeft - contentX));
      const tailInset = DRUM_OUTER_RADIUS + DRUM_POPOVER_TAIL + 2;
      this.dropdownTailX = Math.max(tailInset, Math.min(this.dropdownMenuWidth - tailInset,
        anchorLeft + anchorWidth / 2 - contentX - this.dropdownAnchorX));
      const viewportTop = ui.px2vp(viewport.windowOffset.y);
      // The fixed footer already reserves the bottom safe area outside this viewport.
      const viewportBottom = ui.px2vp(viewport.windowOffset.y + viewport.size.height);
      const height = this.dropdownHeight();
      this.dropdownAbove = anchorBottom + DRUM_POPOVER_GAP + height > viewportBottom &&
        anchorTop - height - DRUM_POPOVER_GAP > viewportTop;
      this.dropdownAnchorY = this.dropdownAbove ? anchorTop - contentY - height - DRUM_POPOVER_GAP :
        anchorBottom - contentY + DRUM_POPOVER_GAP;
      this.dropdownTarget = target;
    } catch (_e) {
      // A missing anchor must never open an unrelated, fixed-position menu.
      this.closeDropdown();
    }
  }

  private pointInsideComponent(id: string, x: number, y: number): boolean {
    try {
      const ui = this.getUIContext();
      const rect = ui.getComponentUtils().getRectangleById(id);
      const left = ui.px2vp(rect.windowOffset.x);
      const top = ui.px2vp(rect.windowOffset.y);
      return x >= left && x <= left + ui.px2vp(rect.size.width) &&
        y >= top && y <= top + ui.px2vp(rect.size.height);
    } catch (_e) {
      return false;
    }
  }

  private observePageTouch(event: TouchEvent): void {
    const touch = event.changedTouches[0];
    if (touch === undefined || this.dropdownTarget.length === 0) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.dropdownTouchX = touch.windowX;
      this.dropdownTouchY = touch.windowY;
      this.dropdownTouchMoved = false;
    } else if (event.type === TouchType.Move) {
      if (Math.abs(touch.windowX - this.dropdownTouchX) > 8 ||
        Math.abs(touch.windowY - this.dropdownTouchY) > 8) {
        this.dropdownTouchMoved = true;
      }
    } else if (event.type === TouchType.Up && !this.dropdownTouchMoved &&
      !this.pointInsideComponent('dm-open-dropdown', touch.windowX, touch.windowY) &&
      !this.pointInsideComponent(this.dropdownAnchorId, touch.windowX, touch.windowY)) {
      this.closeDropdown();
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
    if (index < 0 || index >= this.sections.length) { return; }
    const section = this.copySection(this.sections[index]);
    section.patternIndex = patternIndex;
    section.customRows = undefined;
    section.customPattern = undefined;
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private hasCustomPattern(section: DrumSection | undefined): boolean {
    return section !== undefined && (section.customPattern !== undefined || section.customRows !== undefined);
  }

  private hasCustomFill(section: DrumSection | undefined): boolean {
    return section !== undefined && (section.customFill !== undefined || section.customFillRows !== undefined);
  }

  private sectionRepeats(index: number): number {
    return this.sections[index]?.repeats ?? 1;
  }

  private sectionDisplayId(index: number): string {
    return this.sections[index]?.id ?? '';
  }

  private sectionRenderKey(index: number): string {
    return `${this.sectionPlaybackKeys[index] ?? 'section'}-${index}`;
  }

  private editorPatternLabel(): string {
    const section = this.sections[this.selectedSection];
    const presetLabel = this.editorMode === 0 ?
      drumPatternNames(this.sectionStyleKey(this.selectedSection))[section.patternIndex] : drumFillNames(this.sectionStyleKey(this.selectedSection))[section.fillIndex];
    const custom = this.editorMode === 0 ? this.hasCustomPattern(section) : this.hasCustomFill(section);
    const label = custom ? EDITED_LABEL : presetLabel;
    const description = custom ? '自定义鼓点，保留原始位置和力度' :
      (this.editorMode === 0 ? drumPatternDescription(this.sectionStyleKey(this.selectedSection), section.patternIndex) :
        drumFillDescription(this.sectionStyleKey(this.selectedSection), section.fillIndex));
    return `${styleByKey(this.sectionStyleKey(this.selectedSection)).name} · ${label} · ${description}`;
  }

  private updateRepeats(index: number, delta: number): void {
    if (index < 0 || index >= this.sections.length) { return; }
    const section = this.copySection(this.sections[index]);
    section.repeats = Math.max(1, Math.min(16, section.repeats + delta));
    this.replaceSection(index, section);
    this.notifySectionEdited(index);
  }

  private updateFill(index: number, fillIndex: number): void {
    if (index < 0 || index >= this.sections.length) { return; }
    const section = this.copySection(this.sections[index]);
    section.fillIndex = fillIndex;
    section.customFillRows = undefined;
    section.customFill = undefined;
    this.replaceSection(index, section);
    this.dropdownTarget = '';
    this.notifySectionEdited(index);
  }

  private updateFillEvery(index: number, delta: number): void {
    if (index < 0 || index >= this.sections.length) { return; }
    const section = this.copySection(this.sections[index]);
    section.fillEvery = Math.max(1, Math.min(16, section.fillEvery + delta));
    this.replaceSection(index, section);
    this.notifySectionEdited(index);
  }

  private selectFillEvery(index: number, optionIndex: number): void {
    if (index < 0 || index >= this.sections.length || optionIndex < 0 || optionIndex >= FILL_FREQUENCIES.length) {
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

  /** Cycle preset indices so a newly appended section differs from its predecessor when options exist. */
  private nextSectionPresetIndex(current: number, optionCount: number): number {
    if (optionCount <= 1) {
      return 0;
    }
    return (current + 1) % optionCount;
  }

  private addSection(): void {
    if (this.sections.length >= 8) {
      return;
    }
    const previousIndex = this.sections.length - 1;
    const previous = this.sections[previousIndex];
    const styleKey = this.sectionStyleKey(previousIndex);
    const patternCount = drumPatternNames(styleKey).length;
    const fillCount = drumFillNames(styleKey).length;
    const id = String.fromCharCode(65 + this.sections.length);
    const expanded = this.sections.map((_section: DrumSection, index: number) => this.isSectionExpanded(index));
    this.playbackSectionKeys();
    const next = this.sections.slice();
    next.push({
      id: id,
      styleKey: styleKey,
      patternIndex: this.nextSectionPresetIndex(previous.patternIndex, patternCount),
      repeats: 4,
      fillIndex: this.nextSectionPresetIndex(previous.fillIndex, fillCount),
      fillEvery: 4
    });
    this.sections = next;
    this.playbackSectionKeys();
    this.expandedSections = [...expanded, true];
    this.selectedSection = next.length - 1;
    this.afterSectionsStructureChanged();
  }

  private deleteSection(index: number): void {
    if (this.sections.length <= 1 || index < 0 || index >= this.sections.length) {
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
    this.closeDropdown();
    this.pendingStyleKey = '';
    this.sectionPlaybackKeys = nextPlaybackKeys;
    // Letters are renumbered after deletion; carry fold state with each
    // surviving card instead of accidentally transferring it to the next ID.
    this.expandedSections = expanded;
    if (this.selectedSection > index) {
      this.selectedSection--;
    } else if (this.selectedSection === index) {
      this.selectedSection = Math.min(index, next.length - 1);
    }
    // Retiring card observers may run before ForEach unmounts them. Render reads
    // tolerate missing indices, and moved cards get a new key to drop old closures.
    this.sections = next;
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
  // ArkUI drops custom accessors declared on @Component structs during lowering.
  // Use methods so the emitted UI keeps this projection and its @State dependency.
  private editorPlayheadStep(): number {
    return this.editorPlayheadBeats < 0 ? -1 : this.editorPlayheadBeats * this.editorSubdivision;
  }

  private setEditorPlayheadStep(step: number): void {
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
    const style = section.styleKey ?? this.styleKey;
    if (style === 'jazz') {
      preferred = mode === 1 && section.fillIndex === 1 ? 6 : 3;
    } else if (style === 'trap' &&
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
    if (index < 0 || index >= this.sections.length) { return; }
    // The overlay only owns its own audition. Keep the song's transport and
    // pending preparation alive until the user explicitly auditions this draft.
    this.clearEditorFillFocusTimer();
    if (this.previewTarget === 'song') {
      this.stopEditorPreviewProgress();
    } else {
      this.stopActivePreview();
    }
    this.closeDropdown();
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
    this.setEditorPlayheadStep(step);
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
        styleKey: this.sectionStyleKey(this.selectedSection),
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
      this.setEditorPlayheadStep(-1);
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
      this.setEditorPlayheadStep(startStep);
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
      this.editorPlayheadStep() * DRUM_EDITOR_CELL_WIDTH));
  }

  private updateEditorViewport(width: number): void {
    this.editorViewportWidth = Math.max(0, width);
    this.keepEditorPlayheadVisible();
  }

  private keepEditorPlayheadVisible(forceReveal: boolean = false): void {
    if ((!forceReveal && this.previewTarget !== 'editor') || this.editorPlayheadStep() < 0 || this.editorViewportWidth <= 0) {
      return;
    }
    const left = Math.floor(this.editorPlayheadStep()) * DRUM_EDITOR_CELL_WIDTH;
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
    } else {
      // A one-shot fill audition must reach its first fill even when the saved section is shorter.
      section.repeats = Math.max(section.repeats, section.fillEvery);
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
    if (index < 0 || index >= this.sections.length) { return; }
    const section = this.copySection(this.sections[index]);
    const target = `${withFill ? 'fill' : 'pattern'}-${index}`;
    const started = await this.previewProgram(
      this.buildSectionPreviewProgram(section, withFill), target, false);
    if (started && this.previewTarget === target) {
      this.armSectionPreviewStop(target, this.sectionPreviewBarCount(section, withFill));
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
    await this.setBpm(this.bpm + delta);
  }

  private async setBpm(value: number): Promise<void> {
    if (!Number.isFinite(value)) {
      return;
    }
    const controller = AppSession.get()?.controller;
    this.bpm = Math.max(40, Math.min(240, Math.round(value)));
    this.rememberEditedTempoAndMeter();
    const revision = ++this.bpmUpdateRevision;
    // Everyone may edit a local draft; only the leader may publish live team tempo.
    if (controller === undefined || !controller.isLeader) {
      void this.refreshActivePreview();
      return;
    }
    try {
      await controller.updateBpm(this.bpm);
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
      if (controller.rhythm >= 0 && controller.rhythm <= 2) {
        AppStorage.setOrCreate('lastBasicRhythm', controller.rhythm);
      }
      session.stopDrumPreview();
      const libraryId = this.loadedProgram()?.id ?? '';
      const applied = await controller.updateDrumArrangement(raw, libraryId);
      if (!applied) { return; }
      if (lifetime !== this.pageLifetimeRevision || AppSession.get() !== session || session.controller !== controller) {
        return;
      }
      if (!isProDrumMachineAccessible()) {
        showUserNotice('鼓机权益已到期，编排已保留，请解锁后再应用', 'drum.apply.entitlement');
        return;
      }
      // Applying spans network awaits; only the page and session that started
      // it may publish its result or navigate away from the current screen.
      if (lifetime !== this.pageLifetimeRevision || AppSession.get() !== session || session.controller !== controller) {
        return;
      }
      this.rememberRecentProgram(raw, libraryId);
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

  private popoverOutline(): string {
    const w = vp2px(this.dropdownMenuWidth);
    const h = vp2px(this.dropdownHeight());
    const r = vp2px(DRUM_OUTER_RADIUS);
    const t = vp2px(DRUM_POPOVER_TAIL);
    const x = vp2px(this.dropdownTailX);
    const top = this.dropdownAbove ? 0 : t;
    const bottom = this.dropdownAbove ? h - t : h;
    const upper = this.dropdownAbove ? '' : ` H ${x - t} L ${x} 0 L ${x + t} ${top}`;
    const lower = this.dropdownAbove ? ` H ${x + t} L ${x} ${h} L ${x - t} ${bottom}` : '';
    return `M ${r} ${top}${upper} H ${w - r} Q ${w} ${top} ${w} ${top + r}` +
      ` V ${bottom - r} Q ${w} ${bottom} ${w - r} ${bottom}${lower}` +
      ` H ${r} Q 0 ${bottom} 0 ${bottom - r} V ${top + r} Q 0 ${top} ${r} ${top} Z`;
  }

  private dropdownTitle(): string {
    const label = this.dropdownKind === 'style' ? '选择风格' : this.dropdownKind === 'pattern' ?
      '选择节奏型' : this.dropdownKind === 'fill' ? '选择加花' : '加花频率';
    return `段落 ${this.sections[this.dropdownSectionIndex]?.id ?? ''} · ${label}`;
  }

  private dropdownSelectionColor(): string {
    return styleByKey(this.sectionStyleKey(this.dropdownSectionIndex)).color;
  }

  private sectionTabOutline(): string {
    const w = vp2px(DRUM_SECTION_TAB_WIDTH);
    const h = vp2px(DRUM_SECTION_HEADER_HEIGHT);
    const r = vp2px(DRUM_OUTER_RADIUS);
    return `M ${r} 0 H ${w - vp2px(15)} Q ${w - vp2px(11)} 0 ${w - vp2px(9)} ${vp2px(5)}` +
      ` L ${w - vp2px(1)} ${h - vp2px(6)} Q ${w + vp2px(1)} ${h} ${w - vp2px(5)} ${h}` +
      ` H 0 V ${r} Q 0 0 ${r} 0 Z`;
  }

  @Builder
  private chevron(open: boolean) {
    Path().commands(`M ${vp2px(2)} ${vp2px(3)} L ${vp2px(6)} ${vp2px(7)} L ${vp2px(10)} ${vp2px(3)}`)
      .width(12).height(10).fill('#00000000').stroke(INK).strokeWidth(2)
      .strokeLineCap(LineCapStyle.Round).rotate({ angle: open ? 180 : 0 })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private stepButton(index: number, delta: number) {
    Column() {
      ActionButton({ label: delta < 0 ? '−' : '+',
        active: delta < 0 ? this.sectionRepeats(index) > 1 : this.sectionRepeats(index) < 16,
        controlHeight: 28, fill: WHITE, labelSize: 21, labelWeight: 900,
        cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1,
        hardShadow: { offsetX: 1, offsetY: 1, color: INK },
        accessibilityLabel: `${delta < 0 ? '减少' : '增加'}段落 ${this.sectionDisplayId(index)} 的重复小节数`,
        action: () => this.updateRepeats(index, delta)
      })
    }.width(30)
  }

  @Builder
  private smallStepper(index: number) {
    Row({ space: 3 }) {
      this.stepButton(index, -1)
      Column() {
        DrumPaper({ fill: WHITE, cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1,
        offsetX: 1, offsetY: 1 }) {
        Text(`${this.sectionRepeats(index)}`).width('100%').height(28).textAlign(TextAlign.Center)
          .fontSize(17).fontWeight(900).fontColor(INK)
      }
      }.width(30)
      this.stepButton(index, 1)
    }
  }

  @Builder
  private dropdownOption(label: string, selected: boolean, fill: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 3 }) {
        Text(label).fontSize(13).fontWeight(900)
          .fontColor(selected ? '#FFFFFF' : INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        if (selected) { Text('✓').fontSize(17).fontWeight(900).fontColor('#FFFFFF') }
      }.width('100%')
    }.width('100%').height(DRUM_POPOVER_ROW_HEIGHT).padding({ left: 8, right: 8 })
      .fontColor(selected ? '#FFFFFF' : INK)
      .backgroundColor(selected && this.dropdownKind !== 'style' ? this.dropdownSelectionColor() : fill)
      .border({ width: 0 }).borderRadius(DRUM_INNER_RADIUS).onClick(action)
  }

  @Builder
  private styleDropdownPanel(sectionIndex: number) {
    Column({ space: DRUM_POPOVER_OPTION_GAP }) {
      ForEach(this.styleDropdownRows(), (row: number) => {
        Row({ space: DRUM_POPOVER_OPTION_GAP }) {
          ForEach(DRUM_STYLES.slice(row * this.styleDropdownColumns(), (row + 1) * this.styleDropdownColumns()), (style: DrumStyle) => {
            Column() {
              this.dropdownOption(style.name, this.sectionStyleKey(sectionIndex) === style.key,
                style.color, () => this.chooseSectionStyle(sectionIndex, style.key))
            }.layoutWeight(1)
          }, (style: DrumStyle) => style.key)
        }.width('100%')
      }, (row: number) => `${row}`)
    }.width('100%')
  }

  @Builder
  private patternDropdownPanel(sectionIndex: number) {
    Column({ space: DRUM_POPOVER_OPTION_GAP }) {
      ForEach(drumPatternNames(this.sectionStyleKey(sectionIndex)), (name: string, index: number) => {
        this.dropdownOption(name, !this.hasCustomPattern(this.sections[sectionIndex]) &&
          this.sections[sectionIndex]?.patternIndex === index, '#FFFFFF', () => this.updatePattern(sectionIndex, index))
      })
    }.width('100%')
  }

  @Builder
  private fillDropdownPanel(sectionIndex: number) {
    Column({ space: DRUM_POPOVER_OPTION_GAP }) {
      ForEach(drumFillNames(this.sectionStyleKey(sectionIndex)), (name: string, index: number) => {
        this.dropdownOption(name, !this.hasCustomFill(this.sections[sectionIndex]) &&
          this.sections[sectionIndex]?.fillIndex === index, '#FFFFFF', () => this.updateFill(sectionIndex, index))
      })
    }.width('100%')
  }

  @Builder
  private frequencyDropdownPanel(sectionIndex: number) {
    Column({ space: DRUM_POPOVER_OPTION_GAP }) {
      ForEach(FILL_FREQUENCIES, (frequency: number, index: number) => {
        this.dropdownOption(`每 ${frequency} 小节`, this.sections[sectionIndex]?.fillEvery === frequency,
          '#FFFFFF', () => this.selectFillEvery(sectionIndex, index))
      })
    }.width('100%')
  }

  @Builder
  private sectionDropdownOverlay() {
    Stack({ alignContent: Alignment.TopStart }) {
      Path().commands(this.popoverOutline()).width(this.dropdownMenuWidth).height(this.dropdownHeight())
        .fill(INK).translate({ x: DRUM_POPOVER_SHADOW_OFFSET, y: DRUM_POPOVER_SHADOW_OFFSET })
        .hitTestBehavior(HitTestMode.None)
      Path().commands(this.popoverOutline()).width(this.dropdownMenuWidth).height(this.dropdownHeight())
        .fill('#FFFDF7').stroke(INK).strokeWidth(1.5).hitTestBehavior(HitTestMode.None)
      Column({ space: DRUM_POPOVER_HEADER_GAP }) {
        if (this.dropdownKind === 'style') {
          Text(this.dropdownTitle()).fontSize(13).fontWeight(900).fontColor(INK).width('100%')
            .height(DRUM_POPOVER_HEADER_HEIGHT).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.dropdownKind === 'style') {
          this.styleDropdownPanel(this.dropdownSectionIndex)
        } else if (this.dropdownKind === 'pattern') {
          this.patternDropdownPanel(this.dropdownSectionIndex)
        } else if (this.dropdownKind === 'fill') {
          this.fillDropdownPanel(this.dropdownSectionIndex)
        } else {
          this.frequencyDropdownPanel(this.dropdownSectionIndex)
        }
      }.width('100%').padding(DRUM_POPOVER_PADDING)
        .position({ x: 0, y: this.dropdownAbove ? 0 : DRUM_POPOVER_TAIL })
    }.id('dm-open-dropdown').width(this.dropdownMenuWidth).height(this.dropdownHeight())
      .position({ x: this.dropdownAnchorX, y: this.dropdownAnchorY }).zIndex(85)
  }

  @Builder
  private phraseAction(index: number, fill: boolean, edit: boolean) {
    ActionButton({
      active: edit || this.previewTarget.length === 0 || this.previewTarget === `${fill ? 'fill' : 'pattern'}-${index}`,
      controlWidth: DRUM_PHRASE_ACTION_WIDTH, controlHeight: DRUM_FORM_ROW_HEIGHT,
      fill: '#00000000', cornerRadius: DRUM_INNER_RADIUS,
      accessibilityLabel: `${edit ? '编辑' : '试听'}${fill ? '加花' : '主节奏'}，段落 ${this.sectionDisplayId(index)}`,
      action: () => {
        if (edit) { this.openEditor(index, fill ? 1 : 0); }
        else { void this.previewSection(index, fill); }
      }
    }) {
      if (edit) {
        Stack() {
          Path().commands(`M ${vp2px(2)} ${vp2px(12)} L ${vp2px(1)} ${vp2px(17)} ` +
            `L ${vp2px(6)} ${vp2px(16)} L ${vp2px(17)} ${vp2px(5)} ` +
            `L ${vp2px(13)} ${vp2px(1)} Z`).width(DRUM_PHRASE_ICON_SIZE).height(DRUM_PHRASE_ICON_SIZE).fill(INK)
          Path().commands(`M ${vp2px(11)} ${vp2px(3)} L ${vp2px(15)} ${vp2px(7)}`)
            .width(DRUM_PHRASE_ICON_SIZE).height(DRUM_PHRASE_ICON_SIZE).stroke(WHITE).strokeWidth(1)
        }.width(DRUM_PHRASE_ICON_SIZE).height(DRUM_PHRASE_ICON_SIZE)
      } else if (this.previewTarget === `${fill ? 'fill' : 'pattern'}-${index}`) {
        Rect().width(13).height(13).fill(INK).radius(1)
      } else {
        Path().commands(`M ${vp2px(4)} ${vp2px(2)} L ${vp2px(16)} ${vp2px(9)} ` +
          `L ${vp2px(4)} ${vp2px(16)} Z`).width(DRUM_PHRASE_ICON_SIZE).height(DRUM_PHRASE_ICON_SIZE).fill(INK)
      }
    }
  }

  @Builder
  private phraseField(index: number, fill: boolean) {
    Column() {
      DrumPaper({ fill: this.isSongPhrasePlaying(index, fill) ? styleByKey(this.sectionStyleKey(index)).color : PAPER,
      cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1, offsetX: 1, offsetY: 1 }) {
      Button({ type: ButtonType.Normal }) {
        Row() {
          Text(fill ? (this.hasCustomFill(this.sections[index]) ? EDITED_LABEL :
            drumFillNames(this.sectionStyleKey(index))[this.sections[index]?.fillIndex ?? 0]) :
            (this.hasCustomPattern(this.sections[index]) ? EDITED_LABEL :
            drumPatternNames(this.sectionStyleKey(index))[this.sections[index]?.patternIndex ?? 0]))
            .fontSize(13).fontWeight(FontWeight.Bold).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
          this.chevron(this.dropdownTarget === `menu-${fill ? 'fill' : 'pattern'}-${index}`)
        }.width('100%')
      }.id(`dm-${fill ? 'fill' : 'pattern'}-${index}`).width('100%').height(DRUM_FIELD_HEIGHT)
        .padding({ left: 8, right: 7 }).fontColor(INK).backgroundColor('#00000000')
        .borderRadius(DRUM_INNER_RADIUS)
        .onClick(() => this.openDropdownFromAnchor(`menu-${fill ? 'fill' : 'pattern'}-${index}`,
          `dm-${fill ? 'fill' : 'pattern'}-${index}`))
    }
    }.layoutWeight(1)
  }

  @Builder
  private formRule() {
    Divider().strokeWidth(0.6).color('#D6D0C7').width('100%')
  }

  @Builder
  private sectionCard(index: number) {
    Column() {
      DrumPaper({ fill: this.playingSongSection === index ? DRUM_SECTION_PLAYING_COLOR : '#FFFDF7',
      cornerRadius: DRUM_OUTER_RADIUS, clipContent: true }) {
      Column() {
        Row({ space: 6 }) {
          Row() {
            Stack({ alignContent: Alignment.Center }) {
              Path().commands(this.sectionTabOutline()).width(DRUM_SECTION_TAB_WIDTH).height(DRUM_SECTION_HEADER_HEIGHT)
                .fill(styleByKey(this.sectionStyleKey(index)).color).stroke(INK).strokeWidth(1)
                .hitTestBehavior(HitTestMode.None)
              Row({ space: DRUM_SECTION_TITLE_GAP }) {
                Text(`段落 ${this.sectionDisplayId(index)}`).fontSize(20).fontWeight(900).fontStyle(FontStyle.Italic)
                this.chevron(this.isSectionExpanded(index))
              }.padding({ right: 5 })
            }.width(DRUM_SECTION_TAB_WIDTH).height(DRUM_SECTION_HEADER_HEIGHT)
            Blank()
          }.layoutWeight(1).height(DRUM_SECTION_HEADER_HEIGHT)
            .accessibilityText(`${this.isSectionExpanded(index) ? '收起' : '展开'}段落 ${this.sectionDisplayId(index)}`)
            .onClick(() => this.toggleSectionExpanded(index))
          if (!this.isSectionExpanded(index)) {
            Text(`${this.sectionRepeats(index)}小节`).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#6D7073')
          }
          Column() {
            DrumPaper({ fill: styleByKey(this.sectionStyleKey(index)).color,
            cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1, offsetX: 1, offsetY: 1 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 7 }) {
                Text(styleByKey(this.sectionStyleKey(index)).name).fontSize(13).fontWeight(900)
                this.chevron(this.dropdownTarget === `menu-style-${index}`)
              }
            }.id(`dm-style-${index}`).width('100%').height(22).padding(0).fontColor(INK)
              .backgroundColor('#00000000').borderRadius(DRUM_INNER_RADIUS)
              .accessibilityText(`段落 ${this.sectionDisplayId(index)}，风格 ${styleByKey(this.sectionStyleKey(index)).name}`)
              .onClick(() => this.openDropdownFromAnchor(`menu-style-${index}`, `dm-style-${index}`))
          }
          }.width(DRUM_SECTION_STYLE_WIDTH)
          Divider().vertical(true).height(17).strokeWidth(0.6).color('#BFC0BB')
          ActionButton({ label: '×', active: this.sections.length > 1,
            controlWidth: 24, controlHeight: 28, fill: '#00000000', labelSize: 23, labelWeight: 900,
            cornerRadius: DRUM_INNER_RADIUS, accessibilityLabel: `删除段落 ${this.sectionDisplayId(index)}`,
            action: () => this.requestDeleteSection(index)
          })
        }.width('100%').height(DRUM_SECTION_HEADER_HEIGHT).padding({ right: 5 })
        if (this.isSectionExpanded(index)) {
          this.formRule()
          Column() {
            Row({ space: 8 }) {
              Text('节奏型').fontSize(13).fontWeight(900).width(DRUM_FIELD_LABEL_WIDTH)
              this.phraseField(index, false)
              this.phraseAction(index, false, false)
              this.phraseAction(index, false, true)
            }.width('100%').height(DRUM_FORM_ROW_HEIGHT)
            this.formRule()
            Row({ space: 8 }) {
              Text('重复').fontSize(13).fontWeight(900).width(DRUM_FIELD_LABEL_WIDTH)
              this.smallStepper(index)
              Text('小节').fontSize(13)
              Blank()
            }.width('100%').height(DRUM_FORM_ROW_HEIGHT)
            this.formRule()
            Row({ space: 8 }) {
              Text('加花').fontSize(13).fontWeight(900).width(DRUM_FIELD_LABEL_WIDTH)
              this.phraseField(index, true)
              this.phraseAction(index, true, false)
              this.phraseAction(index, true, true)
            }.width('100%').height(DRUM_FORM_ROW_HEIGHT)
            this.formRule()
            Row({ space: 8 }) {
              Text('频率').fontSize(13).fontWeight(900).width(DRUM_FIELD_LABEL_WIDTH)
              Column() {
                DrumPaper({ fill: PAPER, cornerRadius: DRUM_INNER_RADIUS,
                paperLineWidth: 1, offsetX: 1, offsetY: 1 }) {
                Button({ type: ButtonType.Normal }) {
                  Row() {
                    Text(`每 ${this.sections[index]?.fillEvery ?? 4} 小节`).fontSize(13).fontWeight(FontWeight.Bold)
                    Blank()
                    this.chevron(this.dropdownTarget === `menu-frequency-${index}`)
                  }.width('100%')
                }.id(`dm-frequency-${index}`).width('100%').height(DRUM_FIELD_HEIGHT)
                  .padding({ left: 8, right: 7 }).fontColor(INK).backgroundColor('#00000000')
                  .borderRadius(DRUM_INNER_RADIUS)
                  .onClick(() => this.openDropdownFromAnchor(`menu-frequency-${index}`, `dm-frequency-${index}`))
              }
              }.layoutWeight(1)
              Blank().width(DRUM_PHRASE_ACTION_WIDTH * 2 + 8)
            }.width('100%').height(DRUM_FORM_ROW_HEIGHT)
          }.width('100%').padding({ left: 8, right: 8, top: 2, bottom: 5 })
        }
      }.width('100%')
    }
    }.id(`dm-section-${index}`).width('100%')
  }

  @Builder
  private savedStyleChips(saved: SavedDrumProgram) {
    Row({ space: 3 }) {
      ForEach(drumProgramStyleKeys(parseDrumProgram(saved.program)).slice(0, 2), (key: string) => {
        Text(styleByKey(key).name).fontSize(9).fontWeight(900).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center).layoutWeight(1)
          .padding({ left: 3, right: 3, top: 3, bottom: 3 })
          .backgroundColor(styleByKey(key).color).borderRadius(DRUM_INNER_RADIUS)
      }, (key: string) => key)
      if (drumProgramStyleKeys(parseDrumProgram(saved.program)).length > 2) {
        Text('…').fontSize(12).fontWeight(900).width(10)
      }
    }.width('100%')
  }

  @Builder
  private savedProgramCard(saved: SavedDrumProgram) {
    Column() {
      DrumPaper({ fill: '#FFFDF7', cornerRadius: DRUM_OUTER_RADIUS }) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 7 }) {
        Text(saved.name).fontSize(13).fontWeight(900).maxLines(1).width('100%').padding({ right: 19 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.savedProgramMeter(saved)).fontSize(11).fontColor('#615B53').width('100%')
        this.savedStyleChips(saved)
        Blank()
        Button('载入', { type: ButtonType.Normal }).width('100%').height(24).padding(0).fontSize(11)
          .fontWeight(FontWeight.Bold).fontColor(INK).backgroundColor(WHITE)
          .border({ width: 1, color: INK }).borderRadius(DRUM_INNER_RADIUS)
          .onClick(() => this.loadSavedProgram(saved))
      }.width('100%').height('100%').padding(9)
      Button('×', { type: ButtonType.Normal }).width(24).height(24).padding(0).fontSize(20).fontWeight(900)
        .fontColor(INK).backgroundColor('#00000000').margin({ top: 3, right: 3 })
        .accessibilityText(`删除我的编排 ${saved.name}`).onClick(() => this.deleteSavedProgram(saved.id))
    }.width('100%').height(DRUM_SAVED_CARD_SIZE)
    }
    }.width(DRUM_SAVED_CARD_SIZE)
  }

  @Builder
  private styleChangeOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text('保留写好的鼓点？').fontSize(23).fontWeight(900).width('100%')
        Text(`切换为${styleByKey(this.pendingStyleKey).name}，只影响段落 ${this.sections[this.pendingStyleSection]?.id ?? ''}。`)
          .fontSize(14).width('100%')
        Button('保留已编辑鼓点', { type: ButtonType.Normal }).width('100%').height(44)
          .fontColor(INK).fontWeight(900).backgroundColor(LILAC).border({ width: 1, color: INK })
          .borderRadius(DRUM_INNER_RADIUS).shadow(DRUM_CONTROL_HARD_SHADOW)
          .onClick(() => this.applySectionStyle(this.pendingStyleSection, this.pendingStyleKey, true))
        Button('使用新风格预设', { type: ButtonType.Normal }).width('100%').height(44)
          .fontColor(INK).fontWeight(900).backgroundColor(CORAL).border({ width: 1, color: INK })
          .borderRadius(DRUM_INNER_RADIUS).shadow(DRUM_CONTROL_HARD_SHADOW)
          .onClick(() => this.applySectionStyle(this.pendingStyleSection, this.pendingStyleKey, false))
        Text('取消').fontSize(14).fontWeight(FontWeight.Bold).padding(8).onClick(() => this.pendingStyleKey = '')
      }.width('86%').padding(18).backgroundColor(PAPER).border({ width: 2, color: INK })
        .borderRadius(DRUM_OUTER_RADIUS).shadow(DRUM_CARD_HARD_SHADOW)
    }.width('100%').height('100%').backgroundColor('#66000000').zIndex(110)
  }

  @Builder
  private newProgramDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        DrumPaper({ fill: PAPER, cornerRadius: DRUM_OUTER_RADIUS }) {
          Column({ space: 14 }) {
            Row({ space: 8 }) {
              Text('先保存当前编排吗？').fontSize(22).fontWeight(900).fontColor(INK).layoutWeight(1)
                .maxLines(2)
              Button('×', { type: ButtonType.Normal }).id('dm-new-close').width(28).height(28).padding(0)
                .fontSize(25).fontWeight(900).fontColor(INK).backgroundColor('#00000000')
                .accessibilityText('取消新建编排').onClick(() => this.cancelNewProgram())
            }.width('100%')
            Text(this.loadedProgramName().length > 0 ?
              `保存会更新「${this.loadedProgramName()}」，然后开始新编排。` : '保存到“我的编排”，再开始新编排。')
              .width('100%').fontSize(13).lineHeight(20).fontColor('#625D55')
            Column() {
              DrumPaper({ fill: CORAL, cornerRadius: DRUM_INNER_RADIUS, offsetX: 2, offsetY: 2 }) {
                Button('保存并新建', { type: ButtonType.Normal }).id('dm-new-save').width('100%')
                  .height(DRUM_NEW_PROGRAM_DIALOG_BUTTON_HEIGHT).padding(0).fontSize(14).fontWeight(900)
                  .fontColor(INK).backgroundColor('#00000000').borderRadius(DRUM_INNER_RADIUS)
                  .onClick(() => this.saveBeforeNewProgram())
              }
            }.width('100%')
            Column() {
              DrumPaper({ fill: WHITE, cornerRadius: DRUM_INNER_RADIUS, offsetX: 2, offsetY: 2 }) {
                Button('不保存，直接新建', { type: ButtonType.Normal }).id('dm-new-discard').width('100%')
                  .height(DRUM_NEW_PROGRAM_DIALOG_BUTTON_HEIGHT).padding(0).fontSize(14).fontWeight(900)
                  .fontColor(INK).backgroundColor('#00000000').borderRadius(DRUM_INNER_RADIUS)
                  .onClick(() => this.beginNewProgram())
              }
            }.width('100%')
          }.width('100%').padding(DRUM_NEW_PROGRAM_DIALOG_PADDING)
        }
      }.width('88%').constraintSize({ maxWidth: DRUM_NEW_PROGRAM_DIALOG_MAX_WIDTH })
    }.width('100%').height('100%').backgroundColor('#66000000').zIndex(110)
  }

  @Builder
  private saveDialogOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Row() {
          Text('保存到我的编排').fontSize(23).fontWeight(900).fontStyle(FontStyle.Italic)
          Blank()
          Text('×').fontSize(27).fontWeight(900).onClick(() => this.cancelSaveFlow())
        }.width('100%')
        Divider().strokeWidth(1).color('#CEC4B6')
        Column({ space: 4 }) {
          DrumPaper({ fill: PAPER, cornerRadius: DRUM_INNER_RADIUS,
            paperLineColor: this.saveNameError.length > 0 ? '#B32E23' : INK, offsetX: 2, offsetY: 2 }) {
            TextInput({ text: this.saveName, placeholder: '节奏名称，例如：夜跑推进' })
              .width('100%').height(44).fontSize(15).fontColor(INK).backgroundColor('#00000000')
              .padding({ left: 10, right: 10 }).border({ width: 0 }).borderRadius(DRUM_INNER_RADIUS).maxLength(16)
              .onChange((value: string) => {
                this.saveName = value;
                this.saveNameError = '';
              })
          }
          if (this.saveNameError.length > 0) {
            Text(this.saveNameError).width('100%').fontSize(12).lineHeight(16).fontColor('#B32E23')
          }
        }.width('100%')
        Row({ space: 9 }) {
          Column() {
            DrumPaper({ fill: PAPER, cornerRadius: DRUM_INNER_RADIUS, offsetX: 2, offsetY: 2 }) {
              Button('取消', { type: ButtonType.Normal }).width('100%').height(42).padding(0).fontSize(13).fontWeight(900)
                .fontColor(INK).backgroundColor('#00000000').borderRadius(DRUM_INNER_RADIUS)
                .onClick(() => this.cancelSaveFlow())
            }
          }.layoutWeight(1)
          Column() {
            DrumPaper({ fill: CORAL, cornerRadius: DRUM_INNER_RADIUS, offsetX: 2, offsetY: 2 }) {
              Button(this.newProgramAfterSave ? '保存并新建' : '保存', { type: ButtonType.Normal })
                .width('100%').height(42).padding(0).fontSize(13).fontWeight(900)
                .fontColor(INK).backgroundColor('#00000000').borderRadius(DRUM_INNER_RADIUS)
                .onClick(() => this.confirmNamedSave())
            }
          }.layoutWeight(1.4)
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
        Text('覆盖已有节奏？').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%')
        Text(`继续保存会覆盖「${this.saveName.trim()}」的原有编排。`)
          .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
        Divider().strokeWidth(1).color('#C8BFB1')
        Row({ space: 9 }) {
          Button('返回改名', { type: ButtonType.Normal }).layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(LILAC).border({ width: 1.5, color: INK }).borderRadius(DRUM_INNER_RADIUS).shadow(DRUM_CONTROL_HARD_SHADOW)
            .onClick(() => this.returnToRename())
          Button(this.newProgramAfterSave ? '覆盖并新建' : '覆盖保存', { type: ButtonType.Normal })
            .layoutWeight(1).height(44).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(DRUM_INNER_RADIUS).shadow(DRUM_CONTROL_HARD_SHADOW)
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
              Text(`段落 ${this.sectionDisplayId(this.selectedSection)}`)
                .fontSize(14).fontWeight(900).fontColor(CORAL)
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .border({ width: 1.5, color: CORAL }).borderRadius(DRUM_OUTER_RADIUS)
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
                    Column() {
                      DrumPaper({ fill: this.editorSubdivision === subdivision ? CORAL : WHITE,
                        cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1.2,
                        offsetX: DRUM_EDITOR_CONTROL_SHADOW_OFFSET, offsetY: DRUM_EDITOR_CONTROL_SHADOW_OFFSET }) {
                        Button(subdivision === 4 ? '4 等分' : `${subdivision} 连音`, { type: ButtonType.Normal })
                          .width('100%').height(DRUM_EDITOR_SUBDIVISION_HEIGHT).padding(0)
                          .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor('#00000000')
                          .borderRadius(DRUM_INNER_RADIUS)
                          .accessibilityText(`每拍${subdivision}等分${this.editorSubdivision === subdivision ? '，已选择' : ''}`)
                          .onClick(() => this.chooseEditorSubdivision(subdivision))
                      }
                    }.layoutWeight(1)
                  }, (subdivision: number) => `${subdivision}`)
                }.layoutWeight(1)
              }.width('100%')
              Row() {
                Text(`${this.editorStepCount()} 格 / 小节`).fontSize(11).fontColor('#625D55')
                Blank()
                Text('点格子编辑 · 点数字定位').fontSize(11).fontColor('#625D55')
              }.width('100%')
              if (this.editorOffGridCount() > 0) {
                Column() {
                  DrumPaper({ fill: '#E8DFF2', cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1,
                    offsetX: DRUM_EDITOR_CONTROL_SHADOW_OFFSET, offsetY: DRUM_EDITOR_CONTROL_SHADOW_OFFSET }) {
                    Button({ type: ButtonType.Normal }) {
                      Row({ space: 6 }) {
                        Rect().width(6).height(6).fill(INK).rotate({ angle: 45 })
                        Text(`就近保留 ${this.editorOffGridCount()} 个细分鼓点`)
                          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(INK)
                      }.width('100%').justifyContent(FlexAlign.Start)
                    }.width('100%').height(30).padding({ left: 8, right: 8 }).backgroundColor('#00000000')
                      .borderRadius(DRUM_INNER_RADIUS)
                      .accessibilityText(`就近保留 ${this.editorOffGridCount()} 个细分鼓点，将全部菱形吸附到当前网格`)
                      .onClick(() => this.snapAllEditorOffGridEvents())
                  }
                }.width('100%')
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
                                // Fixed cell geometry keeps shadow rendering free of per-cell area observers.
                                ActionButton({ active: this.editorStepEditable(step),
                                  controlWidth: DRUM_EDITOR_BUTTON_WIDTH, controlHeight: this.editorTrackRowHeight - 8,
                                  fill: this.editorCellColor(trackIndex, step), cornerRadius: DRUM_EDITOR_CELL_RADIUS,
                                  lineWidth: 0.8, lineColor: '#776F65',
                                  hardShadow: { offsetX: DRUM_EDITOR_CELL_SHADOW_OFFSET,
                                    offsetY: DRUM_EDITOR_CELL_SHADOW_OFFSET, color: INK },
                                  accessibilityLabel: this.editorStepEditable(step) ?
                                    `${_track.name}，第 ${Math.floor(step / this.editorSubdivision) + 1} 拍第 ${step % this.editorSubdivision + 1} 格，${this.editorCellEnabled(trackIndex, step) ? '关闭' : '添加'}鼓点` :
                                    `${_track.name}，第 ${Math.floor(step / this.editorSubdivision) + 1} 拍第 ${step % this.editorSubdivision + 1} 格，主节奏，不可编辑`,
                                  action: () => this.toggleStep(trackIndex, step)
                                })
                              }.width(DRUM_EDITOR_CELL_WIDTH).height(this.editorTrackRowHeight)
                                .justifyContent(FlexAlign.Center)
                                .border({ width: { left: step % this.editorSubdivision === 0 ? 1 :
                                  (this.editorSubdivision === 6 && step % 6 === 3 ? 0.7 : 0) }, color: '#A59B8D' })
                                .borderStyle(this.editorSubdivision === 6 && step % 6 === 3 ? BorderStyle.Dashed : BorderStyle.Solid)
                            }, (step: number) => `${step}`)
                          }.height(this.editorTrackRowHeight).width(this.editorGridWidth())
                          ForEach(this.editorOffGridEvents(trackIndex), (event: SequencerEvent) => {
                            Stack() {
                            ActionButton({ active: this.editorEventTickEditable(event.tick),
                              controlWidth: DRUM_EDITOR_OFF_GRID_HIT_SIZE, controlHeight: this.editorTrackRowHeight,
                              fill: '#00000000', cornerRadius: 0,
                              accessibilityLabel: this.editorEventTickEditable(event.tick) ?
                                `${_track.name}，第 ${(event.tick / DEFAULT_TICKS_PER_BEAT + 1).toFixed(2)} 拍，点按就近保留到当前格子` :
                                `${_track.name}，第 ${(event.tick / DEFAULT_TICKS_PER_BEAT + 1).toFixed(2)} 拍，主节奏，不可编辑`,
                              action: () => this.snapEditorEventToGrid(trackIndex, event.tick)
                            }) {
                              Rect().width(DRUM_EDITOR_OFF_GRID_SIZE).height(DRUM_EDITOR_OFF_GRID_SIZE)
                                .fill(INK).stroke(PAPER).strokeWidth(1).rotate({ angle: 45 })
                            }
                            }.width(DRUM_EDITOR_OFF_GRID_HIT_SIZE).height(this.editorTrackRowHeight)
                              .position({ x: this.editorOffGridX(event), y: 0 })
                          }, (event: SequencerEvent) => `${event.sampleKey}-${event.tick}`)
                        }.height(this.editorTrackRowHeight).width(this.editorGridWidth())
                          .border({ width: { bottom: 0.7 }, color: '#B9B0A2' })
                      }, (track: DrumTrack) => track.key)
                      Blank().height(DRUM_EDITOR_SCROLLBAR_SPACE)
                    }.width(this.editorGridWidth())
                    Rect().width(DRUM_EDITOR_PLAYHEAD_WIDTH).height(this.editorTracksHeight())
                      .fill(CORAL).position({ x: this.editorPlayheadX(), y: DRUM_EDITOR_HEADER_HEIGHT })
                      .visibility(this.editorPlayheadStep() >= 0 ? Visibility.Visible : Visibility.Hidden)
                      .zIndex(10).hitTestBehavior(HitTestMode.None)
                    Polygon().width(DRUM_EDITOR_PLAYHEAD_CAP_WIDTH).height(7)
                      .points([[0, 0], [DRUM_EDITOR_PLAYHEAD_CAP_WIDTH, 0], [DRUM_EDITOR_PLAYHEAD_CAP_WIDTH / 2, 7]])
                      .fill(CORAL).position({ x: this.editorPlayheadCapX(), y: DRUM_EDITOR_BEAT_HEIGHT - 7 })
                      .visibility(this.editorPlayheadStep() >= 0 ? Visibility.Visible : Visibility.Hidden)
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
            Column() {
              DrumPaper({ fill: LILAC, cornerRadius: DRUM_OUTER_RADIUS,
                offsetX: DRUM_EDITOR_ACTION_SHADOW_OFFSET, offsetY: DRUM_EDITOR_ACTION_SHADOW_OFFSET }) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 6 }) {
                    Image($rawfile(this.previewTarget === 'editor' ? 'comic/icons/stop.svg' : 'comic/icons/play.svg'))
                      .width(17).height(17).objectFit(ImageFit.Contain)
                    Text(this.previewTarget === 'editor' ? '停止' : '试听').fontSize(14).fontWeight(900).fontColor(INK)
                  }.justifyContent(FlexAlign.Center)
                }.width('100%').height(DRUM_EDITOR_ACTION_HEIGHT).padding(0)
                  .backgroundColor('#00000000').borderRadius(DRUM_OUTER_RADIUS)
                  .onClick(() => { void this.toggleEditorPreview(); })
              }
            }.layoutWeight(1.2)
            Column() {
              DrumPaper({ fill: CORAL, cornerRadius: DRUM_OUTER_RADIUS,
                offsetX: DRUM_EDITOR_ACTION_SHADOW_OFFSET, offsetY: DRUM_EDITOR_ACTION_SHADOW_OFFSET }) {
                Button(this.editorMode === 0 ? '应用到节奏型' : '应用到加花', { type: ButtonType.Normal })
                  .width('100%').height(DRUM_EDITOR_ACTION_HEIGHT).padding(0).fontSize(14).fontWeight(900).fontColor(INK)
                  .backgroundColor('#00000000').borderRadius(DRUM_OUTER_RADIUS)
                  .onClick(() => this.saveEditor())
              }
            }.layoutWeight(2)
          }.width('100%').padding({ left: 12, right: 14, top: 14, bottom: 16 })
            .backgroundColor(PAPER).border({ width: { top: 2 }, color: INK })
        }.width('100%').height('100%').backgroundColor(PAPER)
          .borderRadius(DRUM_EDITOR_PANEL_RADIUS).clip(true)
      }.width('100%').height('100%')
        .constraintSize({ maxWidth: DRUM_EDITOR_PANEL_MAX_WIDTH, maxHeight: DRUM_EDITOR_PANEL_MAX_HEIGHT })
        .backgroundColor(PAPER).border({ width: 2, color: INK, radius: DRUM_EDITOR_PANEL_RADIUS })
        .borderRadius(DRUM_EDITOR_PANEL_RADIUS)
        .shadow({ radius: 0, offsetX: 4, offsetY: 6, color: INK })
    }.width('100%').height('100%')
      .padding({ left: DRUM_EDITOR_OVERLAY_SIDE_INSET, right: DRUM_EDITOR_OVERLAY_SIDE_INSET,
        top: this.topSafeInset + DRUM_EDITOR_OVERLAY_VERTICAL_INSET,
        bottom: this.bottomSafeInset + DRUM_EDITOR_OVERLAY_VERTICAL_INSET })
      .backgroundColor('#66000000').zIndex(100)
  }

  @Builder
  private pageHeader() {
    Row({ space: 5 }) {
      Button({ type: ButtonType.Normal }) {
        Path().commands(`M ${vp2px(13)} ${vp2px(3)} L ${vp2px(5)} ${vp2px(11)} L ${vp2px(13)} ${vp2px(19)}`)
          .width(18).height(22).fill('#00000000').stroke(INK).strokeWidth(3)
      }.width(25).height(32).padding(0).backgroundColor('#00000000').onClick(() => router.back())
      Text('定制鼓机').fontSize(26).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
      Text('PRO').fontSize(10).fontWeight(900).fontColor(INK).backgroundColor('#FFD05A')
        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(3)
      Blank()
    }.width('100%').height(DRUM_HEADER_HEIGHT)
  }

  @Builder
  private settingsHeader() {
    Row({ space: 8 }) {
      Text('拍号').fontSize(13).fontWeight(900).fontColor(INK)
      Column() {
        DrumPaper({ fill: WHITE, cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1,
          offsetX: 1, offsetY: 1 }) {
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(`${this.beatsPerBar}/${this.beatUnit}`).fontSize(17).fontWeight(900)
              Blank()
              this.chevron(false)
            }.width('100%')
          }.width('100%').height(26).padding({ left: 9, right: 6 }).fontColor(INK).backgroundColor('#00000000')
            .borderRadius(DRUM_INNER_RADIUS)
            .accessibilityText('编辑拍号')
            .onClick(() => { this.closeDropdown(); this.meterEditorVisible = true; })
        }
      }.layoutWeight(1.1)
      Divider().vertical(true).height(22).strokeWidth(0.6).color('#BFC0BB')
      Text('BPM').fontSize(13).fontWeight(900).fontColor(INK)
      this.tempoStepButton('−', -1)
      Column() {
        DrumPaper({ fill: WHITE, cornerRadius: DRUM_INNER_RADIUS, paperLineWidth: 1,
          offsetX: 1, offsetY: 1 }) {
          EditableBpm({
            value: this.bpm, editable: true, inputId: 'drum-machine-bpm-input',
            controlWidth: '100%', controlHeight: 26, valueFontSize: 18, italicValue: false,
            controlCornerRadius: DRUM_INNER_RADIUS, controlShadow: { radius: 0, color: '#00000000' },
            onCommit: (value: number): void => { void this.setBpm(value); }
          })
        }
      }.layoutWeight(0.8)
      this.tempoStepButton('+', 1)
    }.width('100%').height(DRUM_SETTINGS_HEIGHT).padding({ bottom: 6 })
      .border({ width: { bottom: 0.7 }, color: '#CBC5BB' })
  }

  @Builder
  private tempoStepButton(label: string, delta: number) {
    Column() {
      ActionButton({ label: label, active: delta < 0 ? this.bpm > 40 : this.bpm < 240,
        controlHeight: 26, fill: WHITE, labelSize: 20, labelWeight: 900,
        cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1,
        hardShadow: { offsetX: 1, offsetY: 1, color: INK },
        action: () => { void this.changeBpm(delta); }
      })
    }.width(27)
  }

  @Builder
  private addSectionAction() {
    ActionButton({ label: '+ 新增段落', active: this.sections.length < 8,
      controlHeight: DRUM_ADD_SECTION_HEIGHT, fill: LILAC, labelSize: 17, labelWeight: 900,
      cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1.5,
      hardShadow: { offsetX: 4, offsetY: 4, color: INK },
      accessibilityLabel: this.sections.length < 8 ? '新增段落' : '最多编排 8 个段落',
      action: () => this.addSection()
    })
  }

  @Builder
  private programActions() {
    Row({ space: 8 }) {
      Column() {
        ActionButton({ label: this.previewTarget === 'song' ? '停止整曲' : '试听整曲',
          active: this.previewTarget.length === 0 || this.previewTarget === 'song',
          controlHeight: DRUM_ACTION_HEIGHT, fill: WHITE, cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1.5,
          hardShadow: { offsetX: 4, offsetY: 4, color: INK },
          action: () => { void this.togglePreview(); }
        }) {
          Row({ space: 6 }) {
            Image($rawfile(this.previewTarget === 'song' ? 'comic/icons/stop.svg' : 'comic/icons/play.svg'))
              .width(14).height(14).objectFit(ImageFit.Contain)
            Text(this.previewTarget === 'song' ? '停止整曲' : '试听整曲').fontSize(14).fontWeight(900).fontColor(INK)
          }
        }
      }.layoutWeight(1)
      Column() {
        ActionButton({ label: this.saving ? '应用中…' : '应用到队伍 ›', active: this.isLeader() && !this.saving,
          controlHeight: DRUM_ACTION_HEIGHT, fill: CORAL, labelSize: 14, labelWeight: 900,
          cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1.5,
          hardShadow: { offsetX: 4, offsetY: 4, color: INK },
          action: () => { void this.applyToTeam(); }
        })
      }.layoutWeight(1)
    }.width('100%')
  }

  @Builder
  private arrangementHeaderAction(save: boolean) {
    Column() {
      ActionButton({ label: save ? '保存' : '＋ 新建', active: !this.saving,
        buttonId: save ? 'dm-save-program' : 'dm-new-program',
        controlHeight: DRUM_ARRANGEMENT_ACTION_HEIGHT, fill: LILAC, labelSize: 13, labelWeight: 900,
        cornerRadius: DRUM_INNER_RADIUS, lineWidth: 1,
        hardShadow: { offsetX: 2, offsetY: 2, color: INK },
        accessibilityLabel: save ? '保存编排' : '新建编排',
        action: () => {
            if (save) { this.openSaveDialog(); }
            else { this.requestNewProgram(); }
        }
      })
    }.width(DRUM_ARRANGEMENT_ACTION_WIDTH)
  }

  @Builder
  private arrangementHeader() {
    Column({ space: DRUM_ARRANGEMENT_HEADING_GAP }) {
      Row({ space: 5 }) {
        Text('编排').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
        if (this.arrangementTitleName().length > 0) {
          Text('·').fontSize(14).fontWeight(900).fontColor(INK)
        }
        Text(this.arrangementTitleName()).fontSize(14).fontWeight(FontWeight.Bold).fontColor(INK)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: DRUM_ARRANGEMENT_ACTION_GAP }) {
          this.arrangementHeaderAction(false)
          this.arrangementHeaderAction(true)
        }.width(DRUM_ARRANGEMENT_ACTION_WIDTH * 2 + DRUM_ARRANGEMENT_ACTION_GAP)
      }.width('100%').height(DRUM_ARRANGEMENT_TITLE_HEIGHT)
      Row() {
        Row({ space: 4 }) {
          Text('风格跟着段落走').fontSize(10).fontWeight(FontWeight.Bold).fontColor('#656B70')
          Image($rawfile('comic/icons/info.svg')).width(11).height(11).objectFit(ImageFit.Contain)
        }.height(DRUM_ARRANGEMENT_META_HEIGHT)
          .onClick(() => showUserNotice('每个段落可以单独选择风格，拍号和 BPM 由整曲共用。', 'drum.section-style-help'))
        Blank()
        Text(`${drumProgramStyleKeys(this.currentProgram()).length}种风格 · ${this.sections.length}/8段`)
          .fontSize(11).fontWeight(900).fontColor(INK)
      }.width('100%').height(DRUM_ARRANGEMENT_META_HEIGHT)
    }.width('100%')
  }

  @Builder
  private myPrograms() {
    Column({ space: 8 }) {
      Row() {
        Text('我的编排').fontSize(18).fontWeight(900).fontColor(INK)
        Blank()
        Text(`${this.savedPrograms.length}个编排`).fontSize(11).fontWeight(900).fontColor('#555B60')
      }.width('100%')
      if (this.savedPrograms.length === 0) {
        Text('点击“保存”，命名后会出现在这里。').fontSize(11).fontColor('#716A61')
          .width('100%').height(42)
      } else {
        Scroll() {
          Row({ space: 9 }) {
            ForEach(this.savedPrograms, (saved: SavedDrumProgram) => {
              this.savedProgramCard(saved)
            }, (saved: SavedDrumProgram) => `${saved.id}:${this.savedProgramsRevision}`)
          }.padding({ left: 1, right: 5, bottom: 5 }).justifyContent(FlexAlign.Start)
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).width('100%').align(Alignment.TopStart)
      }
    }.width('100%').padding({ top: 12, bottom: 4 })
      .border({ width: { top: 0.7 }, color: '#CBC5BB' })
  }

  build() {
    Stack() {
      Column() {
        Column() {
          this.pageHeader()
          this.settingsHeader()
        }.width('100%').padding({ left: DRUM_PAGE_SIDE_INSET, right: DRUM_PAGE_SIDE_INSET,
          top: this.topSafeInset + 8, bottom: 4 })
        Scroll(this.pageScroller) {
          // The menu shares the content coordinate system so page pans also move its pointer.
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
              Column({ space: DRUM_BLOCK_GAP }) {
                this.arrangementHeader()
                ForEach(this.sections, (_section: DrumSection, index: number) => {
                  this.sectionCard(index)
                }, (_section: DrumSection, index: number) => this.sectionRenderKey(index))
                this.addSectionAction()
                if (this.previewTarget === 'song' && this.songPreviewMessage.length > 0) {
                  Text(this.songPreviewMessage).width('100%').fontSize(12).lineHeight(18).fontColor('#B32E23')
                }
                this.myPrograms()
              }.width('100%').padding({ left: DRUM_BODY_INSET, right: DRUM_BODY_INSET,
                top: DRUM_CONTENT_TOP_INSET })
            }.padding({ left: DRUM_PAGE_SIDE_INSET, right: DRUM_PAGE_SIDE_INSET,
              bottom: DRUM_CONTENT_BOTTOM_INSET }).width('100%')
            if (this.dropdownTarget.length > 0 && this.dropdownSectionIndex < this.sections.length) {
              this.sectionDropdownOverlay()
            }
          }.id('dm-scroll-content').width('100%').clip(false)
        }.id('dm-page-scroll').width('100%').layoutWeight(1).backgroundColor(PAPER)
          // A short arrangement must start under the parameters rather than center in the spare viewport.
          .align(Alignment.TopStart)
          .onTouch((event: TouchEvent) => this.observePageTouch(event))
        Column() {
          this.programActions()
        }.width('100%').padding({ left: DRUM_PAGE_SIDE_INSET, right: DRUM_PAGE_SIDE_INSET,
          top: DRUM_FOOTER_INSET, bottom: this.bottomSafeInset + DRUM_FOOTER_INSET })
          .backgroundColor(PAPER).border({ width: { top: 0.7 }, color: '#CBC5BB' })
      }.width('100%').height('100%')
      if (this.editorVisible) {
        this.editorOverlay()
      }
      if (this.saveDialogVisible) {
        this.saveDialogOverlay()
      }
      if (this.overwriteDialogVisible) {
        this.overwriteDialogOverlay()
      }
      if (this.newProgramDialogVisible) {
        this.newProgramDialogOverlay()
      }
      if (this.pendingStyleKey.length > 0) {
        this.styleChangeOverlay()
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
