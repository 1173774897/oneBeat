import { DEFAULT_TICKS_PER_BEAT, SequencerEvent } from './RhythmTimeline';

function styleVariant(index: number): number {
  return Math.max(0, Math.min(2, Math.floor(index)));
}

export function styleDrumPatternNames(styleKey: string): string[] {
  switch (styleKey) {
    case 'psychedelic': return ['空拍回响', '通鼓迷游', '叮镲暗涌'];
    case 'funk': return ['切分底鼓', '十六分鬼音', '叮镲切分'];
    case 'disco': return ['四拍迪斯科', '沙锤反拍', '开镲推进'];
    case 'hiphop': return ['后靠鼓点', '沙锤切分', '叮镲碎拍'];
    case 'trap': return ['半拍陷阱', '三连滚镲', '密集滚镲'];
    case 'house': return ['经典四踩', '沙锤浩室', '叮镲推进'];
    case 'techno': return ['机械四踩', '切分打击', '叮镲驱动'];
    case 'dnb': return ['双步碎拍', '鬼音切分', '叮镲疾驰'];
    case 'latin': return ['沙锤通巴', '3-3-2 律动', '通鼓嘉年华'];
    case 'reggae': return ['One Drop', '反拍沙锤', 'Steppers'];
    default: return ['八分摇滚', '反拍开镲', '叮镲推进'];
  }
}

export function styleDrumFillNames(styleKey: string): string[] {
  switch (styleKey) {
    case 'psychedelic': return ['留白回应', '通鼓回旋', '叮镲悬停'];
    case 'funk': return ['鬼音挑拍', '切分过鼓', '反拍收束'];
    case 'disco': return ['拍手切分', '军鼓上扬', '开镲收束'];
    case 'hiphop': return ['切分应答', '后靠短滚', '通鼓落拍'];
    case 'trap': return ['三连镲花', '六连滚镲', '半拍过鼓'];
    case 'house': return ['反拍短句', '沙锤上扬', '军鼓渐强'];
    case 'techno': return ['切分连击', '打击推进', '叮镲抬升'];
    case 'dnb': return ['碎拍回切', '军鼓碎滚', '通鼓冲刺'];
    case 'latin': return ['通巴回应', '沙锤切分', '通鼓花句'];
    case 'reggae': return ['空拍回应', '通鼓拖拍', '沙锤收束'];
    default: return ['军鼓短句', '重音滚奏', '通鼓下行'];
  }
}

/** A musical group can span three eighth-note transport beats; the bar clock remains unchanged. */
class StylePhrase {
  events: SequencerEvent[] = [];
  barTicks: number;
  groupTicks: number;
  groupCount: number;

  constructor(beatsPerBar: number, beatUnit: number) {
    const groupBeats = beatUnit >= 8 && beatsPerBar >= 6 && beatsPerBar % 3 === 0 ? 3 : 1;
    this.barTicks = beatsPerBar * DEFAULT_TICKS_PER_BEAT;
    this.groupTicks = groupBeats * DEFAULT_TICKS_PER_BEAT;
    this.groupCount = beatsPerBar / groupBeats;
  }

  hit(position: number, sampleKey: string, velocity: number): void {
    const tick = Math.round(position * this.groupTicks);
    if (tick < 0 || tick >= this.barTicks) {
      return;
    }
    for (let i = 0; i < this.events.length; i++) {
      const event = this.events[i];
      if (event.tick === tick && event.sampleKey === sampleKey) {
        event.velocity = Math.max(event.velocity, velocity);
        return;
      }
    }
    this.events.push({ tick: tick, sampleKey: sampleKey, velocity: velocity });
  }

  finish(): SequencerEvent[] {
    this.events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
    return this.events;
  }
}

function eighths(phrase: StylePhrase, beat: number, sampleKey: string,
  down: number = 0.58, up: number = 0.4): void {
  phrase.hit(beat, sampleKey, down);
  phrase.hit(beat + 0.5, sampleKey, up);
}

function sixteenths(phrase: StylePhrase, beat: number, sampleKey: string,
  down: number = 0.5, up: number = 0.32): void {
  const velocities: number[] = [down, up * 0.75, up, up * 0.84];
  for (let sub = 0; sub < 4; sub++) {
    phrase.hit(beat + sub / 4, sampleKey, velocities[sub]);
  }
}

function rockBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  const backbeat = phase % 2 === 1;
  if (phase === 0 || phase === 2) {
    phrase.hit(beat, 'kick', 0.92);
  }
  if (variant > 0 && phase === 3) {
    phrase.hit(beat + 0.5, 'kick', 0.76);
  }
  if (variant === 2 && phase === 1) {
    phrase.hit(beat + 0.5, 'kick', 0.72);
  }
  if (backbeat) {
    phrase.hit(beat, 'snare', variant === 2 ? 0.94 : 0.86);
  }
  if (variant === 2) {
    eighths(phrase, beat, 'ride', backbeat ? 0.59 : 0.52, 0.34);
  } else {
    phrase.hit(beat, 'hat_closed', 0.6);
    phrase.hit(beat + 0.5, variant === 1 && backbeat ? 'hat_open' : 'hat_closed',
      variant === 1 && backbeat ? 0.45 : 0.4);
  }
}

function psychedelicBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  if (phase === 0 || (variant > 0 && phase === 2)) {
    phrase.hit(beat, 'kick', phase === 0 ? 0.78 : 0.57);
  }
  if (phase === 2 || (variant === 2 && phase === 3)) {
    phrase.hit(beat + (phase === 3 ? 0.5 : 0), 'snare', phase === 2 ? 0.62 : 0.34);
  }
  if (variant === 0) {
    if (phase % 2 === 0) {
      phrase.hit(beat, 'ride', 0.42);
    }
    if (phase === 3) {
      phrase.hit(beat + 0.75, 'perc', 0.34);
    }
  } else if (variant === 1) {
    phrase.hit(beat, 'hat_closed', 0.4);
    if (phase === 1 || phase === 3) {
      phrase.hit(beat + 0.5, phase === 1 ? 'tom_high' : 'tom_low', 0.52);
      phrase.hit(beat + 0.75, 'shaker', 0.26);
    }
  } else {
    phrase.hit(beat, 'ride', phase % 2 === 0 ? 0.52 : 0.39);
    if (phase === 1 || phase === 2) {
      phrase.hit(beat + 0.5, 'ride', 0.28);
    }
    if (phase === 0 || phase === 3) {
      phrase.hit(beat + 0.75, phase === 0 ? 'tom_high' : 'tom_low', 0.48);
    }
  }
}

function funkBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  if (phase === 0 || phase === 2) {
    phrase.hit(beat, 'kick', 0.9);
  }
  if (phase === 0 || phase === 3) {
    phrase.hit(beat + 0.75, 'kick', 0.7);
  }
  if (phase === 1) {
    phrase.hit(beat + 0.5, 'kick', 0.79);
  }
  if (phase % 2 === 1) {
    phrase.hit(beat, 'snare', 0.87);
  }
  if (variant > 0) {
    phrase.hit(beat + 0.25, 'snare', phase % 2 === 0 ? 0.24 : 0.2);
    if (phase === 0 || phase === 2) {
      phrase.hit(beat + 0.75, 'snare', 0.29);
    }
  }
  if (variant === 1) {
    sixteenths(phrase, beat, 'hat_closed', 0.55, 0.35);
    phrase.hit(beat + 0.5, 'shaker', 0.24);
  } else {
    eighths(phrase, beat, variant === 2 ? 'ride' : 'hat_closed', 0.54, 0.37);
    if (variant === 2 && phase % 2 === 1) {
      phrase.hit(beat + 0.75, 'perc', 0.39);
    }
  }
}

function discoBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const backbeat = beat % 2 === 1;
  phrase.hit(beat, 'kick', 0.9);
  if (backbeat) {
    phrase.hit(beat, 'snare', 0.74);
    phrase.hit(beat, 'clap', variant === 2 ? 0.52 : 0.34);
  }
  phrase.hit(beat, 'hat_closed', 0.43);
  phrase.hit(beat + 0.5, 'hat_open', variant === 2 ? 0.56 : 0.45);
  if (variant > 0) {
    sixteenths(phrase, beat, 'shaker', 0.32, 0.4);
  }
  if (variant === 2 && beat % 4 === 3) {
    phrase.hit(beat + 0.75, 'snare', 0.32);
  }
}

function hiphopBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  const backbeat = phase % 2 === 1;
  if (phase === 0 || phase === 2) {
    phrase.hit(beat, 'kick', phase === 0 ? 0.93 : 0.82);
  }
  if (phase === 2 || (variant > 0 && phase === 3)) {
    phrase.hit(beat + (phase === 2 ? 0.75 : 0.5), 'kick', 0.66);
  }
  // Twelve transport ticks of snare layback are saved as event positions, never added to the clock.
  if (backbeat) {
    phrase.hit(beat + 12 / phrase.groupTicks, 'snare', 0.85);
  }
  phrase.hit(beat, variant === 2 ? 'ride' : 'hat_closed', variant === 2 ? 0.43 : 0.54);
  phrase.hit(beat + 0.56, variant === 2 ? 'ride' : 'hat_closed', variant === 2 ? 0.28 : 0.35);
  if (variant === 1) {
    phrase.hit(beat + 0.27, 'shaker', 0.21);
    phrase.hit(beat + 0.78, 'shaker', 0.33);
  }
  if (variant === 2 && (phase === 0 || phase === 2)) {
    phrase.hit(beat + 0.8, 'snare', 0.23);
    phrase.hit(beat + 0.5, 'perc', 0.31);
  }
}

function halfTimeBackbeat(phrase: StylePhrase, beat: number): boolean {
  return phrase.groupCount >= 4 ? beat % 4 === 2 : beat === Math.floor(phrase.groupCount / 2);
}

function trapBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  if (phase === 0 || (phase === 2 && variant > 0)) {
    phrase.hit(beat + (phase === 2 ? 0.5 : 0), 'kick', phase === 0 ? 0.94 : 0.76);
  }
  if (phase === 3) {
    phrase.hit(beat + (variant === 1 ? 5 / 6 : 0.75), 'kick', 0.72);
  }
  if (halfTimeBackbeat(phrase, beat)) {
    phrase.hit(beat, 'snare', 0.88);
    phrase.hit(beat, 'clap', 0.32);
  }
  if (variant === 1 && (phase === 1 || phase === 3)) {
    for (let sub = 0; sub < 6; sub++) {
      phrase.hit(beat + sub / 6, 'hat_closed', sub % 3 === 0 ? 0.52 : 0.28 + sub * 0.016);
    }
  } else if (variant === 2) {
    const divisions = phase === 3 ? 8 : 4;
    for (let sub = 0; sub < divisions; sub++) {
      if (phase === 0 && sub / divisions === 0.75) {
        continue;
      }
      phrase.hit(beat + sub / divisions, 'hat_closed', sub % 2 === 0 ? 0.52 : 0.25);
    }
  } else {
    eighths(phrase, beat, 'hat_closed', 0.53, 0.34);
  }
  if (variant > 0 && phase === 0) {
    phrase.hit(beat + (variant === 1 ? 5 / 6 : 0.75), 'hat_open', 0.38);
  }
}

function houseBeat(phrase: StylePhrase, beat: number, variant: number): void {
  phrase.hit(beat, 'kick', 0.9);
  if (beat % 2 === 1) {
    phrase.hit(beat, 'clap', 0.76);
    if (variant === 2) {
      phrase.hit(beat, 'snare', 0.4);
    }
  }
  phrase.hit(beat + 0.5, 'hat_open', 0.48);
  phrase.hit(beat, variant === 2 ? 'ride' : 'hat_closed', variant === 2 ? 0.42 : 0.4);
  if (variant === 1) {
    sixteenths(phrase, beat, 'shaker', 0.29, 0.36);
    if (beat % 2 === 0) {
      phrase.hit(beat + 0.75, 'perc', 0.38);
    }
  }
  if (variant === 2) {
    phrase.hit(beat + 0.5, 'ride', 0.27);
    phrase.hit(beat + 0.75, 'hat_closed', 0.24);
  }
}

function technoBeat(phrase: StylePhrase, beat: number, variant: number): void {
  phrase.hit(beat, 'kick', 0.94);
  phrase.hit(beat + 0.5, 'hat_open', variant === 0 ? 0.37 : 0.46);
  if (variant === 0) {
    phrase.hit(beat, 'hat_closed', 0.38);
    if (beat % 2 === 1) {
      phrase.hit(beat, 'clap', 0.54);
    }
  } else if (variant === 1) {
    phrase.hit(beat, 'hat_closed', 0.4);
    phrase.hit(beat + 0.25, 'hat_closed', 0.21);
    phrase.hit(beat + 0.75, 'hat_closed', 0.24);
    if (beat % 4 === 0 || beat % 4 === 3) {
      phrase.hit(beat + 0.75, 'perc', 0.54);
    }
    if (beat % 4 === 1) {
      phrase.hit(beat + 0.25, 'tom_low', 0.45);
    }
  } else {
    eighths(phrase, beat, 'ride', 0.42, 0.29);
    phrase.hit(beat + 0.25, 'hat_closed', 0.25);
    phrase.hit(beat + 0.75, 'hat_closed', 0.25);
    if (beat % 2 === 1) {
      phrase.hit(beat, 'snare', 0.6);
    }
  }
}

function dnbBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  if (phase === 0 || phase === 2) {
    phrase.hit(beat + (phase === 2 ? 0.5 : 0), 'kick', 0.92);
  }
  if (phase % 2 === 1) {
    phrase.hit(beat, 'snare', 0.91);
  }
  if (variant > 0) {
    if (phase === 0 || phase === 2) {
      phrase.hit(beat + 0.75, 'snare', 0.26);
    }
    if (phase === 3) {
      phrase.hit(beat + 0.25, 'kick', 0.67);
      phrase.hit(beat + 0.5, 'snare', 0.31);
    }
  }
  if (variant === 2) {
    eighths(phrase, beat, 'ride', 0.46, 0.3);
    phrase.hit(beat + 0.25, 'hat_closed', 0.24);
    phrase.hit(beat + 0.75, 'hat_closed', 0.22);
  } else {
    eighths(phrase, beat, 'hat_closed', 0.54, 0.34);
    if (variant === 1) {
      phrase.hit(beat + 0.25, 'hat_closed', 0.22);
      phrase.hit(beat + 0.75, 'hat_closed', 0.27);
    }
  }
}

function latinBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  eighths(phrase, beat, 'shaker', 0.34, 0.48);
  if (phase === 0 || phase === 2) {
    phrase.hit(beat, 'kick', 0.64);
  }
  if (variant === 1) {
    // One-bar 3+3+2 eighth-note accents; this is intentionally not labelled a two-bar son clave.
    if (phase === 0 || phase === 3) {
      phrase.hit(beat, 'perc', 0.76);
    }
    if (phase === 1) {
      phrase.hit(beat + 0.5, 'perc', 0.78);
    }
    if (phase === 2 || phase === 3) {
      phrase.hit(beat + 0.5, 'kick', 0.55);
    }
    if (phase % 2 === 1) {
      phrase.hit(beat, 'snare', 0.42);
    }
  } else {
    if (phase === 1 || phase === 3) {
      phrase.hit(beat, 'perc', 0.69);
    }
    if (phase === 0 || phase === 2 || phase === 3) {
      phrase.hit(beat + 0.5, 'perc', phase === 3 ? 0.82 : 0.47);
    }
    if (variant === 2) {
      phrase.hit(beat + 0.75, phase % 2 === 0 ? 'tom_high' : 'tom_low', 0.43);
      phrase.hit(beat, 'ride', phase % 2 === 0 ? 0.36 : 0.29);
    }
  }
}

function reggaeBeat(phrase: StylePhrase, beat: number, variant: number): void {
  const phase = beat % 4;
  const drop = halfTimeBackbeat(phrase, beat);
  // In four-group bars, One Drop leaves beat one empty on kick; Steppers restores all four kicks.
  if (drop || variant === 2 || (variant === 1 && phase === 0)) {
    phrase.hit(beat, 'kick', drop ? 0.82 : 0.66);
  }
  if (drop) {
    phrase.hit(beat, 'snare', 0.58);
  }
  phrase.hit(beat + 0.5, variant === 2 && phase === 3 ? 'hat_open' : 'hat_closed',
    variant === 2 && phase === 3 ? 0.32 : 0.54);
  phrase.hit(beat, 'shaker', 0.24);
  phrase.hit(beat + 0.5, 'shaker', 0.43);
  if (variant > 0) {
    phrase.hit(beat + 0.25, 'shaker', 0.18);
    phrase.hit(beat + 0.75, 'shaker', 0.25);
    if (phase === 1 || phase === 3) {
      phrase.hit(beat + 0.75, 'perc', 0.35);
    }
  }
}

/** Built-ins use musical event positions; they do not inherit the user's selected editing grid. */
export function buildStyleDrumPattern(styleKey: string, variant: number,
  beatsPerBar: number, beatUnit: number): SequencerEvent[] {
  const phrase = new StylePhrase(beatsPerBar, beatUnit);
  const mode = styleVariant(variant);
  for (let beat = 0; beat < phrase.groupCount; beat++) {
    switch (styleKey) {
      case 'psychedelic': psychedelicBeat(phrase, beat, mode); break;
      case 'funk': funkBeat(phrase, beat, mode); break;
      case 'disco': discoBeat(phrase, beat, mode); break;
      case 'hiphop': hiphopBeat(phrase, beat, mode); break;
      case 'trap': trapBeat(phrase, beat, mode); break;
      case 'house': houseBeat(phrase, beat, mode); break;
      case 'techno': technoBeat(phrase, beat, mode); break;
      case 'dnb': dnbBeat(phrase, beat, mode); break;
      case 'latin': latinBeat(phrase, beat, mode); break;
      case 'reggae': reggaeBeat(phrase, beat, mode); break;
      default: rockBeat(phrase, beat, mode); break;
    }
  }
  return phrase.finish();
}

export function styleFillWindowBeats(styleKey: string, fillIndex: number): number {
  const mode = styleVariant(fillIndex);
  if (mode === 0 || (styleKey === 'trap' && mode === 1)) {
    return 1;
  }
  return 2;
}

function rockFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  if (mode === 0) {
    phrase.hit(start, 'snare', 0.76);
    phrase.hit(start + 0.5, 'snare', 0.4);
    phrase.hit(start + 0.75, 'tom_high', 0.72);
  } else if (mode === 1) {
    const keys: string[] = ['snare', 'snare', 'snare', 'snare', 'snare', 'snare', 'tom_high', 'tom_low'];
    const velocities: number[] = [0.67, 0.31, 0.43, 0.54, 0.79, 0.48, 0.76, 0.94];
    const count = Math.round(length * 4);
    // The hands stay on the roll: no artificial hi-hat or clap layer over every stroke.
    for (let sub = 0; sub < count; sub++) {
      const index = keys.length - count + sub;
      phrase.hit(start + sub / 4, keys[index], velocities[index]);
    }
    phrase.hit(start, 'kick', 0.64);
  } else {
    for (let sub = 0; sub < length * 4; sub++) {
      const progress = sub / (length * 4);
      const key = progress < 0.25 ? 'snare' : (progress < 0.625 ? 'tom_high' : 'tom_low');
      phrase.hit(start + sub / 4, key, sub % 2 === 0 ? 0.85 : 0.56);
    }
    phrase.hit(start + length - 0.25, 'kick', 0.76);
  }
}

function psychedelicFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  if (mode === 0) {
    phrase.hit(start + 0.5, 'tom_high', 0.52);
    phrase.hit(start + 0.875, 'perc', 0.3);
  } else if (mode === 1) {
    for (let beat = 0; beat < length; beat++) {
      phrase.hit(start + beat, 'tom_high', beat === 0 ? 0.55 : 0.45);
      phrase.hit(start + beat + 2 / 3, 'tom_low', 0.62);
    }
  } else {
    phrase.hit(start, 'ride', 0.46);
    phrase.hit(start + length * 0.375, 'tom_low', 0.55);
    phrase.hit(start + length * 0.75, 'tom_high', 0.37);
    phrase.hit(start + length - 0.25, 'ride', 0.29);
  }
}

function funkFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    if (mode === 0) {
      phrase.hit(down, 'snare', 0.22);
      phrase.hit(down + 0.25, 'snare', 0.36);
      phrase.hit(down + 0.5, 'kick', 0.8);
      phrase.hit(down + 0.75, 'snare', 0.85);
    } else if (mode === 1) {
      phrase.hit(down, 'snare', 0.78);
      phrase.hit(down + 0.25, 'snare', 0.24);
      phrase.hit(down + 0.5, beat === length - 1 ? 'tom_low' : 'tom_high', 0.69);
      phrase.hit(down + 0.75, 'perc', 0.48);
    } else {
      phrase.hit(down, 'kick', 0.74);
      phrase.hit(down + 0.25, 'snare', 0.24);
      phrase.hit(down + 0.5, 'snare', 0.83);
      phrase.hit(down + 0.5, 'ride', 0.4);
      phrase.hit(down + 0.75, 'shaker', 0.27);
    }
  }
}

function discoFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    phrase.hit(down, 'kick', 0.88);
    if (mode === 0) {
      phrase.hit(down, 'clap', 0.71);
      phrase.hit(down + 0.75, 'clap', 0.46);
      phrase.hit(down + 0.5, 'hat_open', 0.4);
    } else if (mode === 1) {
      for (let sub = 0; sub < 4; sub++) {
        phrase.hit(down + sub / 4, 'snare', 0.32 + (beat * 4 + sub) * 0.065);
      }
      eighths(phrase, down, 'shaker', 0.24, 0.32);
    } else {
      phrase.hit(down, 'snare', 0.76);
      phrase.hit(down + 0.5, 'hat_open', beat === length - 1 ? 0.62 : 0.43);
      phrase.hit(down + 0.75, beat === length - 1 ? 'tom_low' : 'snare', 0.57);
      sixteenths(phrase, down, 'shaker', 0.26, 0.34);
    }
  }
}

function hiphopFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    phrase.hit(down, 'hat_closed', 0.43);
    if (mode === 0) {
      phrase.hit(down + 12 / phrase.groupTicks, 'snare', 0.78);
      phrase.hit(down + 0.56, 'kick', 0.68);
      phrase.hit(down + 0.8, 'snare', 0.28);
    } else if (mode === 1) {
      phrase.hit(down + 12 / phrase.groupTicks, 'snare', 0.68);
      phrase.hit(down + 0.3, 'snare', 0.31);
      phrase.hit(down + 0.56, 'snare', 0.48);
      phrase.hit(down + 0.82, 'snare', beat === length - 1 ? 0.82 : 0.37);
      phrase.hit(down + 0.75, 'shaker', 0.26);
    } else {
      phrase.hit(down, 'kick', 0.8);
      phrase.hit(down + 0.56, beat === 0 ? 'tom_high' : 'tom_low', 0.68);
      phrase.hit(down + 0.82, 'snare', 0.34);
      if (beat === length - 1) {
        phrase.hit(down, 'ride', 0.33);
      }
    }
  }
}

function trapFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    const divisions = mode === 0 ? 3 : 6;
    for (let sub = 0; sub < divisions; sub++) {
      phrase.hit(down + sub / divisions, 'hat_closed', sub === 0 ? 0.57 : 0.25 + sub * 0.04);
    }
    if (mode < 2) {
      phrase.hit(down, 'snare', 0.78);
      if (mode === 1) {
        phrase.hit(down + 5 / 6, 'snare', 0.42);
      }
    } else {
      phrase.hit(down, beat === 0 ? 'snare' : 'kick', beat === 0 ? 0.83 : 0.9);
      phrase.hit(down + 2 / 3, beat === 0 ? 'tom_high' : 'tom_low', 0.65);
      if (beat === length - 1) {
        phrase.hit(down + 0.75, 'hat_open', 0.4);
      }
    }
  }
}

function houseFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    phrase.hit(down, 'kick', 0.86);
    if (mode === 0) {
      phrase.hit(down + 0.5, 'clap', 0.72);
      phrase.hit(down + 0.5, 'hat_open', 0.43);
      phrase.hit(down + 0.75, 'perc', 0.4);
    } else if (mode === 1) {
      sixteenths(phrase, down, 'shaker', 0.28 + beat * 0.08, 0.35 + beat * 0.08);
      phrase.hit(down + 0.5, 'hat_open', 0.42);
      phrase.hit(down + 0.75, beat === length - 1 ? 'clap' : 'perc', 0.61);
    } else {
      for (let sub = 0; sub < 4; sub++) {
        phrase.hit(down + sub / 4, 'snare', 0.27 + (beat * 4 + sub) * 0.075);
      }
      phrase.hit(down + 0.5, 'ride', 0.29 + beat * 0.08);
    }
  }
}

function technoFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    phrase.hit(down, 'kick', 0.88);
    if (mode === 0) {
      phrase.hit(down + 0.25, 'perc', 0.55);
      phrase.hit(down + 0.75, 'perc', 0.69);
      phrase.hit(down + 0.5, 'hat_open', 0.35);
    } else if (mode === 1) {
      phrase.hit(down, 'tom_low', 0.45);
      phrase.hit(down + 0.375, 'perc', 0.58);
      phrase.hit(down + 0.75, 'perc', 0.71);
      phrase.hit(down + 0.5, 'hat_closed', 0.35);
    } else {
      eighths(phrase, down, 'ride', 0.35 + beat * 0.1, 0.28 + beat * 0.09);
      phrase.hit(down + 0.25, 'snare', 0.28 + beat * 0.1);
      phrase.hit(down + 0.75, 'snare', 0.4 + beat * 0.13);
    }
  }
}

function dnbFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    if (mode === 0) {
      phrase.hit(down, 'snare', 0.84);
      phrase.hit(down + 0.25, 'snare', 0.27);
      phrase.hit(down + 0.5, 'kick', 0.82);
      phrase.hit(down + 0.75, 'snare', 0.45);
    } else if (mode === 1) {
      const offsets: number[] = [0, 0.25, 0.5, 0.625, 0.75, 0.875];
      const velocities: number[] = [0.82, 0.26, 0.6, 0.29, 0.43, 0.58];
      for (let sub = 0; sub < offsets.length; sub++) {
        phrase.hit(down + offsets[sub], 'snare', velocities[sub]);
      }
      phrase.hit(down + 0.5, 'kick', 0.74);
    } else {
      phrase.hit(down, 'snare', 0.88);
      phrase.hit(down + 0.25, 'tom_high', 0.49);
      phrase.hit(down + 0.5, beat === length - 1 ? 'tom_low' : 'kick', 0.76);
      phrase.hit(down + 0.75, 'snare', 0.55);
      phrase.hit(down, 'ride', 0.38);
    }
  }
}

function latinFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    if (mode === 0) {
      phrase.hit(down, 'perc', 0.62);
      phrase.hit(down + 0.5, 'perc', 0.79);
      phrase.hit(down + 0.75, 'perc', 0.41);
      eighths(phrase, down, 'shaker', 0.26, 0.36);
    } else if (mode === 1) {
      sixteenths(phrase, down, 'shaker', 0.3, 0.43);
      phrase.hit(down + 0.25, 'perc', 0.52);
      phrase.hit(down + 0.75, 'perc', 0.78);
      if (beat === 0) {
        phrase.hit(down, 'kick', 0.62);
      }
    } else {
      phrase.hit(down, beat === 0 ? 'tom_high' : 'tom_low', 0.73);
      phrase.hit(down + 0.25, 'perc', 0.43);
      phrase.hit(down + 0.5, 'perc', 0.72);
      phrase.hit(down + 0.75, beat === 0 ? 'tom_high' : 'tom_low', 0.84);
      eighths(phrase, down, 'shaker', 0.27, 0.37);
    }
  }
}

function reggaeFill(phrase: StylePhrase, start: number, length: number, mode: number): void {
  for (let beat = 0; beat < length; beat++) {
    const down = start + beat;
    if (mode === 0) {
      phrase.hit(down + 0.5, 'perc', 0.45);
      phrase.hit(down + 0.75, 'snare', 0.55);
      eighths(phrase, down, 'shaker', 0.22, 0.4);
    } else if (mode === 1) {
      phrase.hit(down + 1 / 3, beat === 0 ? 'tom_high' : 'tom_low', 0.6);
      phrase.hit(down + 2 / 3, beat === 0 ? 'tom_low' : 'snare', 0.69);
      phrase.hit(down + 0.5, 'shaker', 0.35);
    } else {
      sixteenths(phrase, down, 'shaker', 0.24, 0.42);
      phrase.hit(down + 0.5, 'hat_closed', 0.43);
      if (beat === length - 1) {
        phrase.hit(down + 0.75, 'kick', 0.74);
        phrase.hit(down + 0.75, 'snare', 0.63);
      } else {
        phrase.hit(down + 0.75, 'perc', 0.44);
      }
    }
  }
}

/** Absolute ticks in the final window let the catalog replace only that window, including custom prefixes. */
export function buildStyleDrumFill(styleKey: string, fillIndex: number,
  beatsPerBar: number, beatUnit: number): SequencerEvent[] {
  const mode = styleVariant(fillIndex);
  // Fill lengths are denominator beats, matching the existing catalog's replacement boundary in every meter.
  const phrase = new StylePhrase(beatsPerBar, 4);
  const length = Math.min(beatsPerBar, styleFillWindowBeats(styleKey, mode));
  const start = beatsPerBar - length;
  switch (styleKey) {
    case 'psychedelic': psychedelicFill(phrase, start, length, mode); break;
    case 'funk': funkFill(phrase, start, length, mode); break;
    case 'disco': discoFill(phrase, start, length, mode); break;
    case 'hiphop': hiphopFill(phrase, start, length, mode); break;
    case 'trap': trapFill(phrase, start, length, mode); break;
    case 'house': houseFill(phrase, start, length, mode); break;
    case 'techno': technoFill(phrase, start, length, mode); break;
    case 'dnb': dnbFill(phrase, start, length, mode); break;
    case 'latin': latinFill(phrase, start, length, mode); break;
    case 'reggae': reggaeFill(phrase, start, length, mode); break;
    default: rockFill(phrase, start, length, mode); break;
  }
  return phrase.finish();
}
