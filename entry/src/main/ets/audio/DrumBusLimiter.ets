/**
 * Drum voices are normalized near full scale (about -0.7 dBFS), so overlapping
 * kick/snare/hat hits in most built-in styles sum to +2..+8 dBFS. Clamping each
 * voice as it was added hard-clipped those peaks in live playback and in every
 * recording. Bars are therefore summed unclamped and limited here, offline,
 * while PCM is prepared (never in writeData).
 *
 * Contract:
 * - Ceiling -1 dBFS: the renderer's 44.1 -> 48 kHz system resampling and AAC
 *   recordings overshoot between samples, so 1 dB is kept for that.
 * - Zero latency: every output sample stays at its own frame index, so bar
 *   lengths, beat onsets and the shared transport timeline are unchanged.
 * - Exact identity when no sample exceeds the ceiling (the common metronome case).
 * - Never exceeds the ceiling and never waveshapes: a sliding minimum of the required
 *   gain followed by a box average of the same width guarantees each sample's
 *   gain is <= its own required gain, ramping over WINDOW frames before a peak.
 */
const WINDOW_FRAMES: number = 220; // 5 ms at the 44.1 kHz drum renderer.
const RELEASE_FRAMES: number = 44100 * 0.06;
const RELEASE_SNAP: number = 1e-5;
/** 32768 * 10^(-1/20): -1 dBFS sample peak. */
export const DRUM_BUS_CEILING: number = 29204;

/** Unclamped bar mix; values are per-voice-rounded integers that may exceed S16. */
export interface DrumBusMix {
  mix: Float32Array;
}

/** Diagnostics for the most recent limited sequence. */
export interface DrumBusLimitStats {
  overSamples: number;
  limitedSamples: number;
  peak: number;
  minGain: number;
}

function requiredGain(sample: number): number {
  const magnitude = Math.abs(sample);
  return magnitude > DRUM_BUS_CEILING ? DRUM_BUS_CEILING / magnitude : 1;
}

/**
 * Converts consecutive bars to S16. A looping sequence wraps its lookahead into
 * the first bar so the last bar can ramp down before the loop restart's peak;
 * either way the no-over guarantee holds per sample.
 */
export function limitDrumBus(bars: DrumBusMix[], looping: boolean, stats?: DrumBusLimitStats): Int16Array[] {
  const outputs: Int16Array[] = [];
  const offsets: number[] = [];
  let total = 0;
  let overSamples = 0;
  let peak = 0;
  for (let i = 0; i < bars.length; i++) {
    const mix = bars[i].mix;
    offsets.push(total);
    total += mix.length;
    const output = new Int16Array(mix.length);
    for (let s = 0; s < mix.length; s++) {
      const value = mix[s];
      const magnitude = Math.abs(value);
      if (magnitude > peak) {
        peak = magnitude;
      }
      if (magnitude > DRUM_BUS_CEILING) {
        overSamples++;
      }
      // Over-ceiling samples are always rewritten below (their gain is < 1); the
      // clamp only keeps Int16Array from wrapping if that invariant ever breaks.
      output[s] = Math.max(-32768, Math.min(32767, value));
    }
    outputs.push(output);
  }
  let limitedSamples = 0;
  let minGain = 1;
  if (overSamples > 0 && total > 0) {
    let bar = 0;
    const sampleAt = (index: number): number => {
      // Index is monotonic within each pass, so a moving bar cursor avoids a search.
      while (bar + 1 < bars.length && index >= offsets[bar + 1]) {
        bar++;
      }
      return bars[bar].mix[index - offsets[bar]];
    };
    const minGains = new Float64Array(WINDOW_FRAMES);
    const minIndices = new Float64Array(WINDOW_FRAMES);
    const released = new Float64Array(WINDOW_FRAMES).fill(1);
    let minHead = 0;
    let minCount = 0;
    let release = 1;
    let boxSum = WINDOW_FRAMES;
    let reducedSlots = 0;
    const coefficient = Math.exp(-1 / RELEASE_FRAMES);
    let outBar = 0;
    for (let j = 0; j < total + WINDOW_FRAMES - 1; j++) {
      let required = 1;
      if (j < total) {
        required = requiredGain(sampleAt(j));
      } else if (looping) {
        // Lookahead past the end reads the loop restart (first bar) without moving the main cursor.
        const wrapped = j - total;
        let wrapBar = 0;
        while (wrapBar + 1 < bars.length && wrapped >= offsets[wrapBar + 1]) {
          wrapBar++;
        }
        if (wrapped - offsets[wrapBar] < bars[wrapBar].mix.length) {
          required = requiredGain(bars[wrapBar].mix[wrapped - offsets[wrapBar]]);
        }
      }
      while (minCount > 0 && minIndices[minHead] <= j - WINDOW_FRAMES) {
        minHead = (minHead + 1) % WINDOW_FRAMES;
        minCount--;
      }
      while (minCount > 0 && minGains[(minHead + minCount - 1) % WINDOW_FRAMES] >= required) {
        minCount--;
      }
      const tail = (minHead + minCount) % WINDOW_FRAMES;
      minGains[tail] = required;
      minIndices[tail] = j;
      minCount++;
      release = Math.min(minGains[minHead], 1 - (1 - release) * coefficient);
      if (release > 1 - RELEASE_SNAP) {
        release = 1;
      }
      const slot = j % WINDOW_FRAMES;
      reducedSlots += (release < 1 ? 1 : 0) - (released[slot] < 1 ? 1 : 0);
      boxSum += release - released[slot];
      released[slot] = release;
      if (reducedSlots === 0) {
        boxSum = WINDOW_FRAMES;
      }
      const p = j - WINDOW_FRAMES + 1;
      if (p < 0) {
        continue;
      }
      const gain = reducedSlots === 0 ? 1 : Math.min(1, boxSum / WINDOW_FRAMES);
      if (gain < 1) {
        while (outBar + 1 < bars.length && p >= offsets[outBar + 1]) {
          outBar++;
        }
        const local = p - offsets[outBar];
        const limited = Math.round(bars[outBar].mix[local] * gain);
        outputs[outBar][local] = Math.max(-32768, Math.min(32767, limited));
        limitedSamples++;
        if (gain < minGain) {
          minGain = gain;
        }
      }
    }
  }
  if (stats !== undefined) {
    stats.overSamples = overSamples;
    stats.limitedSamples = limitedSamples;
    stats.peak = peak;
    stats.minGain = minGain;
  }
  return outputs;
}
