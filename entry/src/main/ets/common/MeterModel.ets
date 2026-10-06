export type BeatPointState = 'normal' | 'accent' | 'silent';

export const METER_NUMERATORS: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
export const METER_DENOMINATORS: number[] = [1, 2, 4, 8, 16];

export function isValidMeter(beats: number, unit: number): boolean {
  return Number.isInteger(beats) && beats >= 1 && beats <= 16 && METER_DENOMINATORS.indexOf(unit) >= 0;
}

export function defaultBeatPointStates(beats: number): BeatPointState[] {
  const states: BeatPointState[] = [];
  for (let i = 0; i < beats; i++) {
    states.push(i === 0 ? 'accent' : 'normal');
  }
  return states;
}

export function beatPointStatesForRhythm(rhythm: number, beats: number): BeatPointState[] {
  const states = defaultBeatPointStates(beats);
  if (rhythm === 2) {
    for (let i = 1; i < states.length; i++) {
      states[i] = 'silent';
    }
  }
  return states;
}

export function normalizeBeatPointStates(states: BeatPointState[] | undefined, beats: number): BeatPointState[] {
  const fallback = defaultBeatPointStates(beats);
  if (states === undefined) {
    return fallback;
  }
  for (let i = 0; i < beats && i < states.length; i++) {
    const state = states[i];
    if (state === 'normal' || state === 'accent' || state === 'silent') {
      fallback[i] = state;
    }
  }
  return fallback;
}

export function nextBeatPointState(state: BeatPointState): BeatPointState {
  if (state === 'normal') {
    return 'accent';
  }
  if (state === 'accent') {
    return 'silent';
  }
  return 'normal';
}

/** Drum-machine rows use a sixteenth-note grid regardless of the selected beat unit. */
export function stepsPerBeatForUnit(unit: number): number {
  return Math.max(1, Math.round(16 / unit));
}

export function beatUnitLabel(unit: number): string {
  if (unit === 1) { return '全'; }
  if (unit === 2) { return '二分'; }
  if (unit === 4) { return '四分'; }
  if (unit === 8) { return '八分'; }
  return '十六分';
}
