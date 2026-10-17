import { DEFAULT_TICKS_PER_BEAT, SequencerEvent, SequencerPattern } from './RhythmTimeline';
import { isValidMeter, stepsPerBeatForUnit } from '../common/MeterModel';
import {
  buildJazzFill,
  buildJazzPattern,
  jazzFillWindowBeats,
  JAZZ_FILL_NAMES,
  JAZZ_PATTERN_NAMES
} from './JazzDrumPatterns';
import {
  buildStyleDrumFill,
  buildStyleDrumPattern,
  styleFillWindowBeats,
  styleDrumFillNames,
  styleDrumPatternNames
} from './StyleDrumPatterns';

export interface DrumStyle {
  key: string;
  name: string;
  caption: string;
  color: string;
}

export interface DrumTrack {
  key: string;
  name: string;
}

/** The grid is an editing preference; event ticks and velocities are the saved musical data. */
export interface DrumCustomPattern {
  subdivision: number;
  events: SequencerEvent[];
}

export interface DrumSection {
  id: string;
  patternIndex: number;
  repeats: number;
  fillIndex: number;
  fillEvery: number;
  customPattern?: DrumCustomPattern;
  customFill?: DrumCustomPattern;
  // Legacy rows retain their original beat-unit-dependent sixteenth grid until explicitly applied.
  customRows?: string[];
  customFillRows?: string[];
}

export interface DrumProgram {
  styleKey: string;
  beatsPerBar: number;
  beatUnit: number;
  sections: DrumSection[];
}

export const DRUM_STYLES: DrumStyle[] = [
  { key: 'rock', name: '摇滚', caption: '硬朗推进', color: '#FF674F' },
  { key: 'psychedelic', name: '迷幻', caption: '漂浮脉冲', color: '#BBA6FF' },
  { key: 'jazz', name: '爵士', caption: '轻摆律动', color: '#F2C65D' },
  { key: 'funk', name: '放克', caption: '切分弹性', color: '#A9C9F2' },
  { key: 'disco', name: '迪斯科', caption: '闪亮四拍', color: '#FF8FB7' },
  { key: 'hiphop', name: '嘻哈', caption: '松弛重拍', color: '#EBC8B0' },
  { key: 'trap', name: '陷阱', caption: '半拍滚镲', color: '#8EA8FF' },
  { key: 'house', name: '浩室', caption: '稳定舞步', color: '#FF9257' },
  { key: 'techno', name: '科技舞曲', caption: '机械驱动', color: '#BED0EC' },
  { key: 'dnb', name: '鼓打贝斯', caption: '高速碎拍', color: '#D48CFF' },
  { key: 'latin', name: '拉丁', caption: '热烈打击', color: '#FFD05A' },
  { key: 'reggae', name: '雷鬼', caption: '反拍摇摆', color: '#F3D993' }
];

export const DRUM_TRACKS: DrumTrack[] = [
  { key: 'kick', name: '底鼓' },
  { key: 'snare', name: '军鼓' },
  { key: 'hat_closed', name: '闭镲' },
  { key: 'hat_open', name: '开镲' },
  { key: 'ride', name: '叮叮镲' },
  { key: 'clap', name: '拍手' },
  { key: 'tom_low', name: '低通鼓' },
  { key: 'tom_high', name: '高通鼓' },
  { key: 'perc', name: '打击乐' },
  { key: 'shaker', name: '沙锤' }
];

// Old binary rows have no instrument keys. UI insertions must never reinterpret
// their fifth row (clap) as ride or shift either tom and the percussion voice.
const LEGACY_DRUM_TRACK_KEYS: string[] = [
  'kick', 'snare', 'hat_closed', 'hat_open', 'clap', 'tom_low', 'tom_high', 'perc'
];

export const PATTERN_NAMES: string[] = ['基础律动', '推进律动', '强力律动'];
export const FILL_NAMES: string[] = ['短加花', '滚奏加花', '爆发过鼓'];

export function drumPatternNames(styleKey: string): string[] {
  return styleKey === 'jazz' ? JAZZ_PATTERN_NAMES : styleDrumPatternNames(styleKey);
}

export function drumFillNames(styleKey: string): string[] {
  return styleKey === 'jazz' ? JAZZ_FILL_NAMES : styleDrumFillNames(styleKey);
}

/** Musical descriptions explain the built-in phrase, including intentional off-grid notes. */
export function drumPatternDescription(styleKey: string, index: number): string {
  const selected = savedPatternIndex(index);
  switch (styleKey) {
    case 'psychedelic': return ['疏落叮镲与留白打击', '通鼓应答与沙锤点缀', '叮镲铺底与通鼓回应'][selected];
    case 'jazz': return ['叮镲 Swing 乐句与轻底鼓', '三连音一、三位的 Shuffle 律动', '切分军鼓与叮镲推动 Swing'][selected];
    case 'funk': return ['切分底鼓与反拍军鼓', '十六分镲与轻军鼓鬼音', '叮镲与打击乐的切分应答'][selected];
    case 'disco': return ['四拍底鼓与反拍开镲', '四拍底鼓与十六分沙锤', '开镲与拍手推动四拍律动'][selected];
    case 'hiphop': return ['刻意后靠的微时值鼓点', '刻意后靠的微时值鼓点与沙锤切分', '刻意后靠的微时值鼓点与叮镲碎拍'][selected];
    case 'trap': return ['半拍军鼓与切分底鼓', '每拍六格的十六分三连音滚镲', '含八等分落点的密集滚镲'][selected];
    case 'house': return ['四拍底鼓与反拍开镲', '沙锤与打击乐推动四拍律动', '叮镲与开镲交织的四拍律动'][selected];
    case 'techno': return ['四拍底鼓与机械镲点', '闭镲与打击乐的十六分切分', '叮镲与军鼓推动机械律动'][selected];
    case 'dnb': return ['双步底鼓与反拍军鼓', '军鼓鬼音与密集切分', '叮镲与碎拍鼓点交织'][selected];
    case 'latin': return ['沙锤与通巴打击的交织', '八分音符 3＋3＋2 切分重音', '沙锤、叮镲与通鼓的应答'][selected];
    case 'reggae': return ['One Drop 底鼓与军鼓重拍', '反拍沙锤与打击乐点缀', '四拍底鼓与反拍沙锤推进'][selected];
    default: return ['八分镲与二、四拍军鼓', '反拍开镲与底鼓引入', '叮镲推进与强反拍军鼓'][selected];
  }
}

export function drumFillDescription(styleKey: string, index: number): string {
  const selected = savedPatternIndex(index);
  switch (styleKey) {
    case 'psychedelic': return ['含八等分落点的留白应答', '三连音通鼓，可与主节奏形成混合细分', '疏落叮镲与高低通鼓回应'][selected];
    case 'jazz': return ['三连音军鼓与高通鼓应答', '每拍六格的轻重军鼓滚奏', '三连音高低通鼓衔接 Swing'][selected];
    case 'funk': return ['轻军鼓与切分重音', '军鼓与通鼓的切分接力', '底鼓与反拍军鼓收束'][selected];
    case 'disco': return ['拍手切分与开镲应答', '十六分军鼓渐强与沙锤铺底', '开镲与通鼓的十六分收束'][selected];
    case 'hiphop': return ['刻意后靠的微时值切分应答', '刻意后靠的微时值军鼓短滚', '刻意后靠的微时值通鼓与军鼓'][selected];
    case 'trap': return ['三连音镲花，可与主节奏形成混合细分', '六连音滚镲，可与主节奏形成混合细分', '六连音与四等分混合的半拍过鼓'][selected];
    case 'house': return ['拍手与开镲的反拍短句', '十六分沙锤与反拍应答', '军鼓渐强与叮镲抬升'][selected];
    case 'techno': return ['十六分打击乐切分', '含八等分落点的切分打击', '叮镲与军鼓的切分抬升'][selected];
    case 'dnb': return ['底鼓与军鼓的碎拍回切', '十六分军鼓穿插八等分碎滚', '军鼓与高低通鼓冲刺'][selected];
    case 'latin': return ['鼓皮打击与沙锤应答', '十六分沙锤与打击乐切分', '高低通鼓与沙锤花句'][selected];
    case 'reggae': return ['反拍打击与留白应答', '三连通鼓与半拍沙锤，可与主节奏形成混合细分', '十六分沙锤与反拍重音收束'][selected];
    default: return ['轻重军鼓接高通鼓', '两拍军鼓重音滚奏接高低通鼓', '十六分军鼓转高低通鼓下行'][selected];
  }
}

function validDrumSampleKey(key: string): boolean {
  for (let i = 0; i < DRUM_TRACKS.length; i++) {
    if (DRUM_TRACKS[i].key === key) {
      return true;
    }
  }
  return false;
}

function copyDrumEvents(events: SequencerEvent[], barTicks?: number): SequencerEvent[] {
  const copied: SequencerEvent[] = [];
  if (!Array.isArray(events)) {
    return copied;
  }
  for (let i = 0; i < events.length; i++) {
    const event = events[i];
    if (event === null || event === undefined || typeof event.tick !== 'number' ||
      !Number.isFinite(event.tick) || event.tick < 0 ||
      (barTicks !== undefined && event.tick >= barTicks) || !validDrumSampleKey(event.sampleKey)) {
      continue;
    }
    const velocity = typeof event.velocity === 'number' && Number.isFinite(event.velocity) ?
      Math.max(0, Math.min(1, event.velocity)) : 1;
    // Preserve fractional positions and event order: changing the visible grid must not quantize audio.
    copied.push({ tick: event.tick, sampleKey: event.sampleKey, velocity: velocity });
  }
  return copied;
}

export function cloneDrumCustomPattern(pattern?: DrumCustomPattern): DrumCustomPattern | undefined {
  if (pattern === undefined || pattern === null || !Array.isArray(pattern.events)) {
    return undefined;
  }
  const subdivision = pattern.subdivision === 3 || pattern.subdivision === 6 ? pattern.subdivision : 4;
  return { subdivision: subdivision, events: copyDrumEvents(pattern.events) };
}

function copyLegacyRows(rows?: string[]): string[] | undefined {
  if (!Array.isArray(rows)) {
    return undefined;
  }
  const copied: string[] = [];
  for (let i = 0; i < rows.length; i++) {
    copied.push(typeof rows[i] === 'string' ? rows[i] : '');
  }
  return copied;
}

function savedPatternIndex(value: number): number {
  return Number.isInteger(value) && value >= 0 && value < PATTERN_NAMES.length ? value : 0;
}

export function defaultDrumProgram(): DrumProgram {
  return {
    styleKey: 'rock',
    beatsPerBar: 4,
    beatUnit: 4,
    sections: [{ id: 'A', patternIndex: 0, repeats: 4, fillIndex: 0, fillEvery: 4 }]
  };
}

export function parseDrumProgram(raw: string): DrumProgram {
  if (raw.length === 0) {
    return defaultDrumProgram();
  }
  try {
    const parsed = JSON.parse(raw) as DrumProgram;
    if (parsed === null || !isValidMeter(parsed.beatsPerBar, parsed.beatUnit) ||
      !Array.isArray(parsed.sections)) {
      return defaultDrumProgram();
    }
    const sections: DrumSection[] = [];
    for (let i = 0; i < parsed.sections.length; i++) {
      const section = parsed.sections[i];
      if (section === null || section === undefined) {
        continue;
      }
      sections.push({
        id: typeof section.id === 'string' ? section.id : String.fromCharCode(65 + i),
        patternIndex: savedPatternIndex(section.patternIndex),
        repeats: Number.isInteger(section.repeats) && section.repeats > 0 ? section.repeats : 1,
        fillIndex: savedPatternIndex(section.fillIndex),
        fillEvery: Number.isInteger(section.fillEvery) && section.fillEvery >= 0 ? section.fillEvery : 0,
        customPattern: cloneDrumCustomPattern(section.customPattern),
        customFill: cloneDrumCustomPattern(section.customFill),
        customRows: copyLegacyRows(section.customRows),
        customFillRows: copyLegacyRows(section.customFillRows)
      });
    }
    return {
      styleKey: styleByKey(parsed.styleKey).key,
      beatsPerBar: parsed.beatsPerBar,
      beatUnit: parsed.beatUnit,
      sections: sections
    };
  } catch (_e) {
    return defaultDrumProgram();
  }
}

export function serializeDrumProgram(program: DrumProgram): string {
  return JSON.stringify(program);
}

export function styleByKey(key: string): DrumStyle {
  for (let i = 0; i < DRUM_STYLES.length; i++) {
    if (DRUM_STYLES[i].key === key) {
      return DRUM_STYLES[i];
    }
  }
  return DRUM_STYLES[0];
}

function pushEvent(events: SequencerEvent[], step: number, stepsPerBeat: number,
  sampleKey: string, velocity: number = 1): void {
  events.push({
    tick: Math.round(step * DEFAULT_TICKS_PER_BEAT / stepsPerBeat),
    sampleKey: sampleKey,
    velocity: velocity
  });
}

function customPattern(rows: string[], beatsPerBar: number, beatUnit: number): SequencerPattern {
  const stepsPerBeat = stepsPerBeatForUnit(beatUnit);
  const stepCount = beatsPerBar * stepsPerBeat;
  const events: SequencerEvent[] = [];
  const rowKeys: string[] = rows.length <= LEGACY_DRUM_TRACK_KEYS.length ? LEGACY_DRUM_TRACK_KEYS :
    DRUM_TRACKS.map((track: DrumTrack) => track.key);
  for (let track = 0; track < rowKeys.length; track++) {
    const row = track < rows.length ? rows[track] : '';
    for (let step = 0; step < stepCount && step < row.length; step++) {
      if (row.charAt(step) === '1') {
        pushEvent(events, step, stepsPerBeat, rowKeys[track], step % stepsPerBeat === 0 ? 1 : 0.78);
      }
    }
  }
  events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beatsPerBar, events);
}

export function buildDrumPattern(styleKey: string, variant: number, beatsPerBar: number,
  beatUnit: number, fillIndex: number = -1, customRows?: string[], customEvents?: SequencerEvent[]): SequencerPattern {
  const barTicks = beatsPerBar * DEFAULT_TICKS_PER_BEAT;
  const hasCustomEvents = customEvents !== undefined;
  const hasCustomRows = customRows !== undefined && customRows.length > 0;
  const events: SequencerEvent[] = hasCustomEvents ? copyDrumEvents(customEvents, barTicks) :
    (hasCustomRows ? customPattern(customRows, beatsPerBar, beatUnit).events.slice() :
      (styleKey === 'jazz' ? buildJazzPattern(variant, beatsPerBar, beatUnit) :
        buildStyleDrumPattern(styleKey, variant, beatsPerBar, beatUnit)));

  if (fillIndex >= 0) {
    const fillTickStart = presetFillStartBeat(styleKey, fillIndex, beatsPerBar) * DEFAULT_TICKS_PER_BEAT;
    for (let i = events.length - 1; i >= 0; i--) {
      if (events[i].tick >= fillTickStart) {
        events.splice(i, 1);
      }
    }
    const fill = styleKey === 'jazz' ? buildJazzFill(fillIndex, beatsPerBar, beatUnit) :
      buildStyleDrumFill(styleKey, fillIndex, beatsPerBar, beatUnit);
    for (let i = 0; i < fill.length; i++) {
      events.push(fill[i]);
    }
  }
  if (!hasCustomEvents) {
    events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  }
  return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beatsPerBar, events);
}

export function presetFillStartBeat(styleKey: string, fillIndex: number, beatsPerBar: number): number {
  const fillBeats = styleKey === 'jazz' ? jazzFillWindowBeats(fillIndex) :
    styleFillWindowBeats(styleKey, fillIndex);
  return Math.max(0, beatsPerBar - fillBeats);
}

/** First beat of the audible fill window for phrase UI, preview boundaries and the fill grid editor. */
export function sectionFillStartBeat(program: DrumProgram, section: DrumSection): number {
  return section.fillIndex < 0 ? program.beatsPerBar :
    presetFillStartBeat(program.styleKey, section.fillIndex, program.beatsPerBar);
}

/** Resolve a full audible bar without converting its events through the editor's visible grid. */
export function buildSectionPattern(program: DrumProgram, section: DrumSection,
  withFill: boolean): SequencerPattern {
  if (withFill && section.customFill !== undefined) {
    const fill = cloneDrumCustomPattern(section.customFill);
    if (fill !== undefined) {
      return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, program.beatsPerBar,
        copyDrumEvents(fill.events, program.beatsPerBar * DEFAULT_TICKS_PER_BEAT));
    }
  }
  if (withFill && section.customFillRows !== undefined && section.customFillRows.length > 0) {
    return customPattern(section.customFillRows, program.beatsPerBar, program.beatUnit);
  }
  const main = cloneDrumCustomPattern(section.customPattern);
  return buildDrumPattern(program.styleKey, section.patternIndex, program.beatsPerBar,
    program.beatUnit, withFill ? section.fillIndex : -1, section.customRows,
    main === undefined ? undefined : main.events);
}

export function buildProgramSequence(program: DrumProgram): SequencerPattern[] {
  const sequence: SequencerPattern[] = [];
  for (let sectionIndex = 0; sectionIndex < program.sections.length; sectionIndex++) {
    const section = program.sections[sectionIndex];
    for (let repeat = 0; repeat < section.repeats; repeat++) {
      const useFill = section.fillEvery > 0 && (repeat + 1) % section.fillEvery === 0;
      sequence.push(buildSectionPattern(program, section, useFill));
    }
  }
  if (sequence.length === 0) {
    sequence.push(buildDrumPattern(program.styleKey, 0, program.beatsPerBar, program.beatUnit));
  }
  return sequence;
}

export function emptyCustomRows(beatsPerBar: number, beatUnit: number): string[] {
  const stepCount = beatsPerBar * stepsPerBeatForUnit(beatUnit);
  const rows: string[] = [];
  for (let i = 0; i < DRUM_TRACKS.length; i++) {
    rows.push('0'.repeat(stepCount));
  }
  return rows;
}

export function patternToRows(pattern: SequencerPattern, beatsPerBar: number, beatUnit: number): string[] {
  const stepsPerBeat = stepsPerBeatForUnit(beatUnit);
  const stepCount = beatsPerBar * stepsPerBeat;
  const chars: string[][] = [];
  for (let track = 0; track < DRUM_TRACKS.length; track++) {
    const row: string[] = [];
    for (let step = 0; step < stepCount; step++) {
      row.push('0');
    }
    chars.push(row);
  }
  for (let i = 0; i < pattern.events.length; i++) {
    const event = pattern.events[i];
    let trackIndex = -1;
    for (let track = 0; track < DRUM_TRACKS.length; track++) {
      if (DRUM_TRACKS[track].key === event.sampleKey) {
        trackIndex = track;
        break;
      }
    }
    if (trackIndex >= 0) {
      const step = Math.round(event.tick * stepsPerBeat / DEFAULT_TICKS_PER_BEAT);
      if (step >= 0 && step < stepCount) {
        chars[trackIndex][step] = '1';
      }
    }
  }
  const rows: string[] = [];
  for (let track = 0; track < chars.length; track++) {
    rows.push(chars[track].join(''));
  }
  return rows;
}
