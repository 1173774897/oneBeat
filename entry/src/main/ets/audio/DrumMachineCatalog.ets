import { DEFAULT_TICKS_PER_BEAT, SequencerEvent, SequencerPattern } from './RhythmTimeline';

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

export interface DrumSection {
  id: string;
  patternIndex: number;
  repeats: number;
  fillIndex: number;
  fillEvery: number;
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
  { key: 'funk', name: '放克', caption: '切分弹性', color: '#58C9C9' },
  { key: 'disco', name: '迪斯科', caption: '闪亮四拍', color: '#FF8FB7' },
  { key: 'hiphop', name: '嘻哈', caption: '松弛重拍', color: '#A6D46A' },
  { key: 'trap', name: '陷阱', caption: '半拍滚镲', color: '#8EA8FF' },
  { key: 'house', name: '浩室', caption: '稳定舞步', color: '#FF9257' },
  { key: 'techno', name: '科技舞曲', caption: '机械驱动', color: '#60C3A5' },
  { key: 'dnb', name: '鼓打贝斯', caption: '高速碎拍', color: '#D48CFF' },
  { key: 'latin', name: '拉丁', caption: '热烈打击', color: '#FFD05A' },
  { key: 'reggae', name: '雷鬼', caption: '反拍摇摆', color: '#7CCF75' }
];

export const DRUM_TRACKS: DrumTrack[] = [
  { key: 'kick', name: '底鼓' },
  { key: 'snare', name: '军鼓' },
  { key: 'hat_closed', name: '闭镲' },
  { key: 'hat_open', name: '开镲' },
  { key: 'clap', name: '拍手' },
  { key: 'tom_low', name: '低通鼓' },
  { key: 'tom_high', name: '高通鼓' },
  { key: 'perc', name: '打击乐' }
];

export const PATTERN_NAMES: string[] = ['基础律动', '推进律动', '强力律动'];
export const FILL_NAMES: string[] = ['短加花', '滚奏加花', '爆发过鼓'];

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
    return JSON.parse(raw) as DrumProgram;
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

function shouldKick(styleKey: string, beat: number, sub: number, variant: number): boolean {
  if (styleKey === 'house' || styleKey === 'techno' || styleKey === 'disco') {
    return sub === 0 || (variant > 1 && sub === 2 && beat % 2 === 1);
  }
  if (styleKey === 'jazz') {
    if (variant === 0) {
      return sub === 0 && (beat === 0 || beat === 2);
    }
    if (variant === 1) {
      return sub === 0 && (beat === 0 || beat === 1 || beat === 2);
    }
    return sub === 0;
  }
  if (styleKey === 'funk') {
    if (variant === 0) {
      return (beat === 0 && sub === 0) || (beat === 1 && sub === 2) || (beat === 2 && sub === 0);
    }
    if (variant === 1) {
      return (beat === 0 && sub === 0) || (beat === 1 && sub === 2) || (beat === 2 && sub === 0) ||
        (beat === 3 && sub === 2);
    }
    return sub === 0 && beat % 2 === 0 || (beat === 3 && sub === 2);
  }
  if (styleKey === 'latin') {
    if (variant === 0) {
      return sub === 0 && (beat === 0 || beat === 2);
    }
    return sub === 0 && (beat === 0 || beat === 2 || (variant > 1 && beat === 3));
  }
  if (styleKey === 'reggae') {
    if (variant === 0) {
      return beat === 3 && sub === 0;
    }
    return (beat === 0 && sub === 0 && variant === 1) || (beat === 3 && sub === 0);
  }
  if (styleKey === 'psychedelic') {
    if (variant === 0) {
      return beat === 0 && sub === 0;
    }
    if (variant === 1) {
      return sub === 0 && (beat === 0 || beat === 2);
    }
    return sub === 0 && (beat === 0 || beat === 1 || beat === 2);
  }
  if (styleKey === 'rock') {
    if (variant === 0) {
      return sub === 0 && (beat === 0 || beat === 2);
    }
    if (variant === 1) {
      return sub === 0 && (beat === 0 || beat === 2) || (beat === 3 && sub === 2);
    }
    return sub === 0 && (beat === 0 || beat === 2) || (beat === 1 && sub === 2) || (beat === 3 && sub === 2);
  }
  if (styleKey === 'trap' || styleKey === 'hiphop') {
    return (beat === 0 && sub === 0) || (beat === 2 && sub === (variant > 0 ? 2 : 0)) ||
      (variant > 1 && beat === 3 && sub === 3);
  }
  if (styleKey === 'dnb') {
    return (beat === 0 && sub === 0) || (beat === 2 && sub === 2) || (variant > 0 && beat === 3 && sub === 1);
  }
  return sub === 0 && (beat === 0 || beat === 2) || (variant > 0 && beat === 3 && sub === 2);
}

function shouldSnare(styleKey: string, beat: number, sub: number, variant: number): boolean {
  if (styleKey === 'trap' || styleKey === 'hiphop') {
    return beat === 2 && sub === 0 || (variant > 1 && beat === 3 && sub === 2);
  }
  if (styleKey === 'reggae') {
    return beat === 2 && sub === 0 || (variant > 1 && beat === 0 && sub === 2);
  }
  if (styleKey === 'jazz') {
    return (beat === 1 || beat === 3) && sub === 0;
  }
  if (styleKey === 'funk') {
    return (beat === 1 || beat === 3) && sub === 0;
  }
  if (styleKey === 'dnb') {
    if (variant === 0) {
      return (beat === 1 && sub === 2) || (beat === 3 && sub === 0);
    }
    return (beat === 1 && sub === 2) || (beat === 3 && sub === 0) || (variant > 1 && beat === 2 && sub === 2);
  }
  if (styleKey === 'latin') {
    return (beat === 1 && sub === 0) || (beat === 3 && sub === 0) ||
      (variant > 0 && beat === 2 && sub === 2);
  }
  if (styleKey === 'psychedelic') {
    return (beat === 1 || beat === 3) && sub === 0 || (variant > 1 && beat === 2 && sub === 2);
  }
  return (beat === 1 || beat === 3) && sub === 0;
}

function shouldGhostSnare(styleKey: string, beat: number, sub: number, variant: number,
  stepsPerBeat: number): boolean {
  if (stepsPerBeat < 4) {
    return false;
  }
  if (styleKey === 'jazz') {
    if (variant === 0) {
      return (beat === 0 || beat === 2) && sub === 2;
    }
    if (variant === 1) {
      return sub === 2 && (beat === 0 || beat === 1 || beat === 2);
    }
    return sub === 2 || (sub === 1 && beat % 2 === 1);
  }
  if (styleKey === 'funk' && variant > 0) {
    return sub === 2 && (beat === 0 || beat === 2 || (variant > 1 && beat === 1));
  }
  if (styleKey === 'hiphop' && variant > 0) {
    return sub === 2 && (beat === 1 || beat === 3);
  }
  return false;
}

/** Shuffle / straight / busy hi-hat grid per style and pattern variant. */
function shouldHat(styleKey: string, beat: number, sub: number, variant: number,
  stepsPerBeat: number): boolean {
  if (stepsPerBeat === 2) {
    if (styleKey === 'jazz' && variant === 0) {
      return sub === 0;
    }
    return variant === 0 ? sub === 0 : true;
  }
  if (styleKey === 'jazz') {
    if (variant === 0) {
      return sub === 0 || sub === 3;
    }
    if (variant === 1) {
      return sub === 0 || sub === 2 || (beat === 3 && sub === 3);
    }
    return sub === 0 || sub === 1 || sub === 3;
  }
  if (styleKey === 'reggae') {
    if (variant === 0) {
      return sub === 2;
    }
    return sub === 2 || (variant > 1 && sub === 0 && beat % 2 === 1);
  }
  if (styleKey === 'funk') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    if (variant === 1) {
      return true;
    }
    return sub !== 1 || beat % 2 === 0;
  }
  if (styleKey === 'trap') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    if (variant === 1) {
      return sub % 2 === 0;
    }
    return true;
  }
  if (styleKey === 'hiphop') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    return sub % 2 === 0 || (variant > 1 && sub === 3);
  }
  if (styleKey === 'latin') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    return sub === 0 || sub === 1 || sub === 2;
  }
  if (styleKey === 'dnb') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    return true;
  }
  if (styleKey === 'psychedelic') {
    if (variant === 0) {
      return sub === 0;
    }
    if (variant === 1) {
      return sub === 0 || sub === 2;
    }
    return sub !== 3;
  }
  if (styleKey === 'house' || styleKey === 'techno') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    if (variant === 1) {
      return sub % 2 === 0;
    }
    return true;
  }
  if (styleKey === 'disco') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    return sub % 2 === 0 || (variant > 1 && sub === 3);
  }
  if (styleKey === 'rock') {
    if (variant === 0) {
      return sub === 0 || sub === 2;
    }
    if (variant === 1) {
      return true;
    }
    return sub !== 1;
  }
  const hatStride = variant === 0 ? 2 : 1;
  return sub % hatStride === 0;
}

function shouldOpenHat(styleKey: string, beat: number, sub: number, variant: number,
  stepsPerBeat: number): boolean {
  if (stepsPerBeat < 4) {
    return variant > 0 && sub === stepsPerBeat - 1 && beat % 2 === 1;
  }
  if (styleKey === 'jazz') {
    return variant > 0 && beat === 3 && sub === 2;
  }
  if (styleKey === 'funk') {
    return variant > 1 && beat % 2 === 1 && sub === 3;
  }
  if (styleKey === 'disco') {
    return variant > 0 && sub === stepsPerBeat - 1 && beat % 2 === 0;
  }
  if (styleKey === 'rock' && variant > 1) {
    return beat === 3 && sub === 0;
  }
  return variant > 0 && sub === stepsPerBeat - 1 && beat % 2 === 1;
}

function hatVelocity(styleKey: string, beat: number, sub: number, variant: number, isOpen: boolean): number {
  if (isOpen) {
    return 0.68;
  }
  if (styleKey === 'jazz') {
    if (variant === 0) {
      return sub === 0 ? 0.62 : 0.44;
    }
    return sub === 0 ? 0.72 : 0.5;
  }
  if (styleKey === 'reggae') {
    return 0.58;
  }
  if (styleKey === 'trap' && variant > 1) {
    return sub === 0 ? 0.78 : 0.42;
  }
  return sub === 0 ? 0.72 : 0.52;
}

function shouldStylePerc(styleKey: string, beat: number, sub: number, variant: number,
  stepsPerBeat: number): boolean {
  if (styleKey === 'latin') {
    if (stepsPerBeat < 4) {
      return sub === 0 && (beat === 0 || beat === 2 || beat === 3);
    }
    if (variant === 0) {
      return (beat === 0 && sub === 3) || (beat === 2 && sub === 1) || (beat === 3 && sub === 2);
    }
    if (variant === 1) {
      return (beat === 0 && sub === 3) || (beat === 1 && sub === 2) || (beat === 2 && sub === 1) ||
        (beat === 3 && sub === 2);
    }
    return sub === 1 || sub === 3;
  }
  if (styleKey === 'funk') {
    return stepsPerBeat >= 4 && sub === stepsPerBeat - 1 &&
      (variant === 0 ? beat % 2 === 1 : true);
  }
  if (styleKey === 'reggae' && variant > 0) {
    return sub === 2 && beat !== 2;
  }
  return false;
}

function kickVelocity(styleKey: string, beat: number, sub: number, variant: number): number {
  if (styleKey === 'jazz') {
    return beat === 0 ? 0.82 : 0.58;
  }
  if (styleKey === 'reggae' && variant === 0) {
    return 0.92;
  }
  if (styleKey === 'psychedelic' && variant === 0) {
    return 0.78;
  }
  return 1;
}

function customPattern(rows: string[], beatsPerBar: number, beatUnit: number): SequencerPattern {
  const stepsPerBeat = beatUnit === 8 ? 2 : 4;
  const stepCount = beatsPerBar * stepsPerBeat;
  const events: SequencerEvent[] = [];
  for (let track = 0; track < DRUM_TRACKS.length; track++) {
    const row = track < rows.length ? rows[track] : '';
    for (let step = 0; step < stepCount && step < row.length; step++) {
      if (row.charAt(step) === '1') {
        pushEvent(events, step, stepsPerBeat, DRUM_TRACKS[track].key, step % stepsPerBeat === 0 ? 1 : 0.78);
      }
    }
  }
  events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beatsPerBar, events);
}

function fillWindowBeats(styleKey: string, fillIndex: number): number {
  if (fillIndex === 2) {
    if (styleKey === 'rock' || styleKey === 'dnb' || styleKey === 'latin' || styleKey === 'disco' ||
      styleKey === 'funk') {
      return 2;
    }
  }
  return 1;
}

function pushStyleFill(events: SequencerEvent[], styleKey: string, fillIndex: number, step: number,
  local: number, stepsPerBeat: number, fillSteps: number): void {
  const lastLocal = fillSteps - 1;
  const half = Math.floor(stepsPerBeat / 2);

  if (styleKey === 'jazz') {
    if (fillIndex === 0) {
      if (local === 0 || local === 2) {
        pushEvent(events, step, stepsPerBeat, 'snare', local === 0 ? 0.78 : 0.42);
      }
      if (stepsPerBeat >= 4 && (local === 0 || local === 3)) {
        pushEvent(events, step, stepsPerBeat, 'hat_closed', local === 0 ? 0.5 : 0.38);
      }
      if (local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'kick', 0.55);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, 'snare', local % 2 === 0 ? 0.72 : 0.48);
      if (stepsPerBeat >= 4 && (local === 0 || local === 3)) {
        pushEvent(events, step, stepsPerBeat, 'hat_closed', 0.4);
      }
      return;
    }
    pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'hat_open' : 'snare', local % 2 === 0 ? 0.55 : 0.88);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'kick', 0.7);
    }
    return;
  }

  if (styleKey === 'latin') {
    if (fillIndex === 0) {
      if (local === 0 || local === 2) {
        pushEvent(events, step, stepsPerBeat, 'perc', 0.78);
      }
      if (local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.9);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'perc' : 'snare', 0.8);
      return;
    }
    const cascade = ['tom_high', 'perc', 'tom_low', 'snare'];
    pushEvent(events, step, stepsPerBeat, cascade[local % cascade.length], local === lastLocal ? 1 : 0.82);
    if (local === 0) {
      pushEvent(events, step, stepsPerBeat, 'kick', 0.85);
    }
    return;
  }

  if (styleKey === 'funk') {
    if (fillIndex === 0) {
      if (local % 2 === 0) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.86);
      } else {
        pushEvent(events, step, stepsPerBeat, 'perc', 0.68);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, 'snare', local === 0 ? 1 : 0.58);
      if (local === 1 || local === 3) {
        pushEvent(events, step, stepsPerBeat, 'perc', 0.64);
      }
      return;
    }
    if (local === 0) {
      pushEvent(events, step, stepsPerBeat, 'kick', 1);
    }
    pushEvent(events, step, stepsPerBeat, local < half ? 'snare' : 'tom_high', local === lastLocal ? 1 : 0.76);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'perc', 0.72);
    }
    return;
  }

  if (styleKey === 'reggae') {
    if (fillIndex === 0) {
      if (local === 1 || local === 3) {
        pushEvent(events, step, stepsPerBeat, 'perc', 0.7);
      }
      return;
    }
    if (fillIndex === 1) {
      if (local < lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.45);
      }
      if (local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'kick', 0.75);
      }
      return;
    }
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'kick', 1);
      pushEvent(events, step, stepsPerBeat, 'snare', 0.95);
    }
    return;
  }

  if (styleKey === 'trap' || styleKey === 'hiphop') {
    if (fillIndex === 0) {
      if (local === 0 || local === 2) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.88);
      }
      if (stepsPerBeat >= 4) {
        pushEvent(events, step, stepsPerBeat, 'hat_closed', local % 2 === 0 ? 0.62 : 0.38);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, 'hat_closed', local % 2 === 0 ? 0.7 : 0.42);
      if (local === 0 || local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.9);
      }
      return;
    }
    pushEvent(events, step, stepsPerBeat, 'hat_closed', local === 0 ? 0.85 : 0.48);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'kick', 1);
      pushEvent(events, step, stepsPerBeat, 'snare', 1);
    }
    return;
  }

  if (styleKey === 'dnb') {
    if (fillIndex === 0) {
      if (local === 1) {
        pushEvent(events, step, stepsPerBeat, 'snare', 0.85);
      }
      if (local === 2) {
        pushEvent(events, step, stepsPerBeat, 'kick', 0.9);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'snare' : 'tom_high', 0.8);
      return;
    }
    const breakKeys = ['kick', 'snare', 'hat_closed', 'kick', 'snare', 'tom_low', 'snare', 'kick'];
    const key = breakKeys[local % breakKeys.length];
    pushEvent(events, step, stepsPerBeat, key, local === lastLocal ? 1 : 0.78);
    return;
  }

  if (styleKey === 'house' || styleKey === 'techno') {
    if (fillIndex === 0) {
      if (local % 2 === 0) {
        pushEvent(events, step, stepsPerBeat, 'clap', 0.72);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, 'hat_closed', local % 2 === 0 ? 0.68 : 0.44);
      if (local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'clap', 0.88);
      }
      return;
    }
    pushEvent(events, step, stepsPerBeat, 'kick', 0.95);
    pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'hat_open' : 'clap', 0.75);
    return;
  }

  if (styleKey === 'disco') {
    if (fillIndex === 0) {
      if (local % 2 === 0) {
        pushEvent(events, step, stepsPerBeat, 'clap', 0.8);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'clap' : 'hat_open', 0.78);
      return;
    }
    pushEvent(events, step, stepsPerBeat, 'kick', 1);
    pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'clap' : 'hat_open', local === lastLocal ? 0.95 : 0.7);
    return;
  }

  if (styleKey === 'psychedelic') {
    if (fillIndex === 0) {
      if (local === 0 || local === lastLocal) {
        pushEvent(events, step, stepsPerBeat, 'tom_low', 0.65);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, local < half ? 'tom_low' : 'tom_high', 0.58 + local * 0.08);
      pushEvent(events, step, stepsPerBeat, 'hat_open', 0.35);
      return;
    }
    pushEvent(events, step, stepsPerBeat, 'tom_high', 0.72);
    pushEvent(events, step, stepsPerBeat, 'hat_open', 0.62);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'kick', 0.68);
    }
    return;
  }

  if (styleKey === 'rock') {
    if (fillIndex === 0) {
      if (local % 2 === 0) {
        pushEvent(events, step, stepsPerBeat, local < half ? 'tom_high' : 'tom_low', 0.9);
      }
      return;
    }
    if (fillIndex === 1) {
      pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'snare' : 'tom_high', 0.84);
      return;
    }
    pushEvent(events, step, stepsPerBeat, local < half ? 'tom_high' : 'tom_low', 0.92);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'kick', 1);
      pushEvent(events, step, stepsPerBeat, 'hat_open', 0.88);
      pushEvent(events, step, stepsPerBeat, 'snare', 1);
    } else if (local === 0 && fillSteps > stepsPerBeat) {
      pushEvent(events, step, stepsPerBeat, 'snare', 0.7);
    }
    return;
  }

  // Default rock-like fills for remaining styles (e.g. psychedelic already handled — rock default)
  if (fillIndex === 0 && local % 2 === 0) {
    pushEvent(events, step, stepsPerBeat, local < half ? 'tom_high' : 'tom_low', 0.9);
  } else if (fillIndex === 1) {
    pushEvent(events, step, stepsPerBeat, local % 2 === 0 ? 'snare' : 'tom_high', 0.82);
  } else {
    pushEvent(events, step, stepsPerBeat, local < half ? 'tom_high' : 'tom_low', 1);
    if (local === lastLocal) {
      pushEvent(events, step, stepsPerBeat, 'clap', 0.85);
    }
  }
}

export function buildDrumPattern(styleKey: string, variant: number, beatsPerBar: number,
  beatUnit: number, fillIndex: number = -1, customRows?: string[]): SequencerPattern {
  const stepsPerBeat = beatUnit === 8 ? 2 : 4;
  const stepCount = beatsPerBar * stepsPerBeat;
  const hasCustomRows = customRows !== undefined && customRows.length > 0;
  const events: SequencerEvent[] = hasCustomRows ?
    customPattern(customRows, beatsPerBar, beatUnit).events.slice() : [];
  if (!hasCustomRows) {
    for (let step = 0; step < stepCount; step++) {
      const beat = Math.floor(step / stepsPerBeat);
      const sub = step % stepsPerBeat;
      if (shouldKick(styleKey, beat, sub, variant)) {
        pushEvent(events, step, stepsPerBeat, 'kick', kickVelocity(styleKey, beat, sub, variant));
      }
      if (shouldSnare(styleKey, beat, sub, variant)) {
        pushEvent(events, step, stepsPerBeat, styleKey === 'disco' ? 'clap' : 'snare', 0.96);
      }
      if (shouldGhostSnare(styleKey, beat, sub, variant, stepsPerBeat)) {
        pushEvent(events, step, stepsPerBeat, 'snare', styleKey === 'jazz' ? 0.32 : 0.4);
      }
      if (shouldHat(styleKey, beat, sub, variant, stepsPerBeat)) {
        const open = shouldOpenHat(styleKey, beat, sub, variant, stepsPerBeat);
        pushEvent(events, step, stepsPerBeat, open ? 'hat_open' : 'hat_closed',
          hatVelocity(styleKey, beat, sub, variant, open));
      }
      if (shouldStylePerc(styleKey, beat, sub, variant, stepsPerBeat)) {
        pushEvent(events, step, stepsPerBeat, 'perc', styleKey === 'latin' ? 0.72 : 0.62);
      }
    }
  }

  if (fillIndex >= 0) {
    const fillBeats = fillWindowBeats(styleKey, fillIndex);
    const fillStart = Math.max(0, stepCount - fillBeats * stepsPerBeat);
    const fillTickStart = fillStart * DEFAULT_TICKS_PER_BEAT / stepsPerBeat;
    for (let i = events.length - 1; i >= 0; i--) {
      if (events[i].tick >= fillTickStart) {
        events.splice(i, 1);
      }
    }
    const fillSteps = stepCount - fillStart;
    for (let step = fillStart; step < stepCount; step++) {
      pushStyleFill(events, styleKey, fillIndex, step, step - fillStart, stepsPerBeat, fillSteps);
    }
  }
  events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beatsPerBar, events);
}

export function buildProgramSequence(program: DrumProgram): SequencerPattern[] {
  const sequence: SequencerPattern[] = [];
  for (let sectionIndex = 0; sectionIndex < program.sections.length; sectionIndex++) {
    const section = program.sections[sectionIndex];
    for (let repeat = 0; repeat < section.repeats; repeat++) {
      const useFill = section.fillEvery > 0 && (repeat + 1) % section.fillEvery === 0;
      if (useFill && section.customFillRows !== undefined && section.customFillRows.length > 0) {
        sequence.push(customPattern(section.customFillRows, program.beatsPerBar, program.beatUnit));
      } else {
        sequence.push(buildDrumPattern(program.styleKey, section.patternIndex, program.beatsPerBar,
          program.beatUnit, useFill ? section.fillIndex : -1, section.customRows));
      }
    }
  }
  if (sequence.length === 0) {
    sequence.push(buildDrumPattern(program.styleKey, 0, program.beatsPerBar, program.beatUnit));
  }
  return sequence;
}

export function emptyCustomRows(beatsPerBar: number, beatUnit: number): string[] {
  const stepCount = beatsPerBar * (beatUnit === 8 ? 2 : 4);
  const rows: string[] = [];
  for (let i = 0; i < DRUM_TRACKS.length; i++) {
    rows.push('0'.repeat(stepCount));
  }
  return rows;
}

export function patternToRows(pattern: SequencerPattern, beatsPerBar: number, beatUnit: number): string[] {
  const stepsPerBeat = beatUnit === 8 ? 2 : 4;
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
