import { DEFAULT_TICKS_PER_BEAT, SequencerEvent } from './RhythmTimeline';

export const JAZZ_PATTERN_NAMES: string[] = ['经典 Swing', 'Jazz Shuffle', '推进 Swing'];
export const JAZZ_FILL_NAMES: string[] = ['三连应答', '六连滚奏', 'Swing 过鼓'];

function jazzVariant(index: number): number {
  return Math.max(0, Math.min(2, Math.floor(index)));
}

function addJazzEvent(events: SequencerEvent[], tick: number, sampleKey: string,
  velocity: number, barTicks: number): void {
  const roundedTick = Math.round(tick);
  if (roundedTick >= 0 && roundedTick < barTicks) {
    for (let i = 0; i < events.length; i++) {
      if (events[i].tick === roundedTick && events[i].sampleKey === sampleKey) {
        events[i].velocity = Math.max(events[i].velocity, velocity);
        return;
      }
    }
    events.push({ tick: roundedTick, sampleKey: sampleKey, velocity: velocity });
  }
}

/** Events use the transport's denominator-beat clock; the phrasing never changes bar duration. */
export function buildJazzPattern(variant: number, beatsPerBar: number, beatUnit: number): SequencerEvent[] {
  const events: SequencerEvent[] = [];
  const mode = jazzVariant(variant);
  const barTicks = beatsPerBar * DEFAULT_TICKS_PER_BEAT;
  // Compound meters phrase across three denominator beats, rather than adding a new triplet to every eighth.
  const groupBeats = beatUnit >= 8 && beatsPerBar >= 6 && beatsPerBar % 3 === 0 ? 3 : 1;
  const groupTicks = groupBeats * DEFAULT_TICKS_PER_BEAT;
  const groupCount = Math.ceil(beatsPerBar / groupBeats);
  for (let group = 0; group < groupCount; group++) {
    const down = group * groupTicks;
    const skip = down + groupTicks * 2 / 3;
    const backbeat = group % 2 === 1;
    const last = group === groupCount - 1;

    if (backbeat) {
      addJazzEvent(events, down, 'hat_closed', 0.31, barTicks);
    }

    if (mode === 0) {
      addJazzEvent(events, down, 'ride', backbeat ? 0.6 : 0.52, barTicks);
      if (backbeat) {
        addJazzEvent(events, skip, 'ride', 0.36, barTicks);
      }
      addJazzEvent(events, down, 'kick', group === 0 ? 0.44 : 0.28, barTicks);
      if (group % 4 === 1) {
        addJazzEvent(events, skip, 'snare', 0.3, barTicks);
      } else if (group % 4 === 2) {
        addJazzEvent(events, skip, 'snare', 0.43, barTicks);
      } else if (group % 4 === 3) {
        addJazzEvent(events, down, 'snare', 0.48, barTicks);
      }
    } else if (mode === 1) {
      // Shuffle keeps the first and third triplet on the ride, leaving the middle triplet silent.
      addJazzEvent(events, down, 'ride', backbeat ? 0.62 : 0.54, barTicks);
      addJazzEvent(events, skip, 'ride', backbeat ? 0.43 : 0.36, barTicks);
      addJazzEvent(events, down, 'kick', backbeat ? 0.32 : 0.72, barTicks);
      if (backbeat) {
        addJazzEvent(events, down, 'snare', 0.75, barTicks);
      } else {
        addJazzEvent(events, skip, 'snare', 0.27, barTicks);
      }
      if (last) {
        addJazzEvent(events, skip, 'kick', 0.42, barTicks);
      }
    } else {
      addJazzEvent(events, down, 'ride', backbeat ? 0.65 : 0.56, barTicks);
      if (backbeat || group % 4 === 2 || last) {
        addJazzEvent(events, skip, 'ride', last ? 0.45 : 0.41, barTicks);
      }
      if (!backbeat) {
        addJazzEvent(events, down, 'kick', group === 0 ? 0.64 : 0.5, barTicks);
      } else {
        addJazzEvent(events, skip, 'kick', 0.44, barTicks);
        addJazzEvent(events, down, 'snare', 0.54, barTicks);
      }
      if (group % 4 === 0 || group % 4 === 2) {
        addJazzEvent(events, skip, 'snare', group % 4 === 0 ? 0.3 : 0.6, barTicks);
      }
      if (last) {
        addJazzEvent(events, down + groupTicks / 3, 'snare', 0.24, barTicks);
      }
    }
  }
  events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  return events;
}

export function jazzFillWindowBeats(fillIndex: number): number {
  return jazzVariant(fillIndex) === 2 ? 2 : 1;
}

/** Fill ticks are absolute within the bar, matching the catalog's replacement window. */
export function buildJazzFill(fillIndex: number, beatsPerBar: number, beatUnit: number): SequencerEvent[] {
  const events: SequencerEvent[] = [];
  const mode = jazzVariant(fillIndex);
  const barTicks = beatsPerBar * DEFAULT_TICKS_PER_BEAT;
  const fillBeats = Math.min(beatsPerBar, jazzFillWindowBeats(mode));
  const start = barTicks - fillBeats * DEFAULT_TICKS_PER_BEAT;
  addJazzEvent(events, start, 'ride', 0.4, barTicks);

  if (mode === 0) {
    addJazzEvent(events, start, 'snare', 0.62, barTicks);
    addJazzEvent(events, start + DEFAULT_TICKS_PER_BEAT / 3, 'snare', 0.28, barTicks);
    addJazzEvent(events, start + DEFAULT_TICKS_PER_BEAT * 2 / 3, 'tom_high', 0.6, barTicks);
    addJazzEvent(events, start, 'kick', 0.34, barTicks);
  } else if (mode === 1) {
    const velocities: number[] = [0.66, 0.3, 0.42, 0.72, 0.34, 0.52];
    for (let sub = 0; sub < velocities.length; sub++) {
      addJazzEvent(events, start + sub * DEFAULT_TICKS_PER_BEAT / 6, 'snare', velocities[sub], barTicks);
    }
  } else {
    for (let beat = 0; beat < fillBeats; beat++) {
      const down = start + beat * DEFAULT_TICKS_PER_BEAT;
      const last = beat === fillBeats - 1;
      addJazzEvent(events, down, beat === 0 ? 'snare' : 'tom_high', beat === 0 ? 0.66 : 0.6, barTicks);
      if (beat === 0 && fillBeats > 1) {
        addJazzEvent(events, down + DEFAULT_TICKS_PER_BEAT / 3, 'snare', 0.27, barTicks);
      }
      addJazzEvent(events, down + DEFAULT_TICKS_PER_BEAT * 2 / 3,
        last ? 'tom_low' : 'tom_high', last ? 0.82 : 0.7, barTicks);
      if (last) {
        addJazzEvent(events, down + DEFAULT_TICKS_PER_BEAT * 2 / 3, 'kick', 0.54, barTicks);
        addJazzEvent(events, down + DEFAULT_TICKS_PER_BEAT * 2 / 3, 'ride', 0.34, barTicks);
      }
    }
  }
  events.sort((a: SequencerEvent, b: SequencerEvent) => a.tick - b.tick);
  return events;
}
