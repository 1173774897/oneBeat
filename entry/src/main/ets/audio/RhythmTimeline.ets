import { BeatPointState, normalizeBeatPointStates } from '../common/MeterModel';

export const DEFAULT_TICKS_PER_BEAT: number = 480;

export interface SequencerEvent {
  tick: number;
  sampleKey: string;
  velocity: number;
}

export class SequencerPattern {
  ticksPerBeat: number;
  beatsPerBar: number;
  events: SequencerEvent[];

  constructor(ticksPerBeat: number, beatsPerBar: number, events: SequencerEvent[]) {
    this.ticksPerBeat = ticksPerBeat;
    this.beatsPerBar = beatsPerBar;
    this.events = events;
  }
}

/**
 * Metronome presets use the same tick grid as the future drum-machine editor.
 * Additional drum tracks only need new sample keys and events.
 */
export class BuiltInRhythmFactory {
  static create(rhythm: number, beatsPerBar: number, beatPointStates?: BeatPointState[]): SequencerPattern {
    const events: SequencerEvent[] = [];
    const states = normalizeBeatPointStates(beatPointStates, beatsPerBar);
    for (let beat = 0; beat < beatsPerBar; beat++) {
      const state = states[beat];
      const audible = state !== 'silent';
      if (audible) {
        events.push({
          tick: beat * DEFAULT_TICKS_PER_BEAT,
          sampleKey: state === 'accent' ? 'accent' : 'weak',
          velocity: 1
        });
      }
      if (rhythm === 1 && state !== 'silent') {
        events.push({
          tick: beat * DEFAULT_TICKS_PER_BEAT + DEFAULT_TICKS_PER_BEAT / 2,
          sampleKey: 'weak',
          velocity: 0.72
        });
      }
    }
    return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beatsPerBar, events);
  }
}
