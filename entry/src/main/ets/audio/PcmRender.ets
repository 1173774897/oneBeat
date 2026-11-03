import { DEFAULT_TICKS_PER_BEAT, SequencerEvent, SequencerPattern } from './RhythmTimeline';
import { DrumProgram, drumSectionStyleKey } from './DrumMachineCatalog';
import {
  DRUM_BUS_LOOKAHEAD_FRAMES,
  DrumBusLimiterState,
  DrumBusLimitStats,
  DrumBusMix,
  freshDrumBusLimiterState,
  limitDrumBus,
  limitDrumBusChunk
} from './DrumBusLimiter';

/**
 * Pure PCM generation shared by the engine's synchronous path and the TaskPool
 * worker. Everything a render reads arrives as an argument: these functions run
 * on another thread, where engine state, closures and class prototypes do not
 * exist (patterns and programs arrive as plain copies). Both paths must stay
 * bit-identical apart from dither, so keep the arithmetic here only.
 */

export const PCM_SAMPLE_RATE: number = 44100;
const BYTES_PER_SAMPLE: number = 2;
// Sub-audible dither floor laid under the click samples so the stream is never
// pure digital zero. Pure zero runs are what the smart PA silence detector
// (CustStreamCheck -> SmartpaPowerOff) keys on to power off the amplifier.
// ~ -80dBFS peak; raise only if device logs still show zero_volume=true.
export const DITHER_FLOOR_GAIN: number = 0.0001;

export interface RenderedBar {
  samples: Int16Array;
  frameCount: number;
  samplesPerBeat: number;
  beatsPerBar: number;
}

/** A bar before the drum bus limiter: voices are summed without clamping. */
export interface MixedBar extends DrumBusMix {
  frameCount: number;
  samplesPerBeat: number;
  beatsPerBar: number;
}

/** Engine settings a render depends on, captured when the job is created. */
export interface PcmVoiceContext {
  bpm: number;
  beatPointStates: string[];
  drumKitGain: number;
  accentBuffer: ArrayBuffer;
  weakBuffer: ArrayBuffer;
}

export interface PcmRenderJob {
  context: PcmVoiceContext;
  patterns: SequencerPattern[];
  looping: boolean;
  bank: Map<string, ArrayBuffer>;
  program: DrumProgram | undefined;
  /** Count-in bar length rendered alongside; 0 skips it. */
  countInBeats: number;
  /**
   * Render only bars [startBar, endBar). Chunks run in order: each continues
   * the previous chunk's limiter state, so the bars equal one whole render.
   * The first chunk (startBar 0, the head: a start always begins at bar 0)
   * also returns the count-in and placeholder shapes for the other bars.
   */
  chunk?: PcmRenderChunk;
}

export interface PcmRenderChunk {
  startBar: number;
  endBar: number;
  /** Omitted for the head. */
  limiterState?: DrumBusLimiterState;
}

/** Shape of a bar not rendered yet; its samples are a view of the shared silence. */
export interface PcmBarShape {
  frameCount: number;
  samplesPerBeat: number;
  beatsPerBar: number;
}

export interface PcmRenderResult {
  sequence: RenderedBar[];
  countIn: RenderedBar | undefined;
  renderMs: number;
  /** Head jobs only: bars after the head, in order, and dither long enough for any of them. */
  placeholders?: PcmBarShape[];
  silence?: Int16Array;
  /** Chunk jobs: state for the chunk that follows. */
  limiterState?: DrumBusLimiterState;
}

/**
 * Every ArrayBuffer a job carries. TaskPool TRANSFERS ArrayBuffer arguments by
 * default, detaching them on the sender (device 2026-11-03: the click tones
 * were detached after the first job, every later job failed to serialize and
 * the route probe could not render its clicks). The engine keeps using these
 * buffers, so the task must clone exactly this list. Add any new buffer field here.
 */
export function pcmJobArrayBuffers(job: PcmRenderJob): ArrayBuffer[] {
  const buffers: ArrayBuffer[] = [job.context.accentBuffer, job.context.weakBuffer];
  job.bank.forEach((sample: ArrayBuffer) => {
    if (buffers.indexOf(sample) < 0) {
      buffers.push(sample);
    }
  });
  return buffers;
}

export function applyDitherFloorToRange(samples: Int16Array, start: number, end: number): void {
  for (let i = start; i < end; i++) {
    const tpdf = (Math.random() + Math.random() - 1.0) * DITHER_FLOOR_GAIN;
    samples[i] = Math.round(tpdf * 32767);
  }
}

export function applyDitherFloor(data: ArrayBuffer): void {
  const samples = new Int16Array(data);
  applyDitherFloorToRange(samples, 0, samples.length);
}

function drumSample(bank: Map<string, ArrayBuffer>, sampleKey: string,
  styleKey?: string): ArrayBuffer | undefined {
  const styled = styleKey === undefined ? undefined : bank.get(`${styleKey}/${sampleKey}`);
  return styled ?? bank.get(sampleKey);
}

export function programBarStyleKeys(program: DrumProgram | undefined): string[] {
  const styles: string[] = [];
  if (program !== undefined) {
    for (let section = 0; section < program.sections.length; section++) {
      const current = program.sections[section];
      const style = drumSectionStyleKey(program, current);
      for (let repeat = 0; repeat < current.repeats; repeat++) {
        styles.push(style);
      }
    }
  }
  return styles;
}

export function pcmBarShape(context: PcmVoiceContext, pattern: SequencerPattern): PcmBarShape {
  const samplesPerBeat = PCM_SAMPLE_RATE * 60 / Math.max(1, context.bpm);
  return {
    frameCount: Math.max(1, Math.round(samplesPerBeat * pattern.beatsPerBar)),
    samplesPerBeat, beatsPerBar: pattern.beatsPerBar
  };
}

/**
 * mixFrames < frameCount mixes only the bar's opening frames (the limiter's
 * lookahead into the bar after a head); frameCount metadata stays the real length.
 */
export function mixPcmBar(context: PcmVoiceContext, pattern: SequencerPattern, applyBeatPointPattern: boolean,
  bank: Map<string, ArrayBuffer>, program: DrumProgram | undefined, styleKey?: string,
  mixFrames: number = Number.MAX_SAFE_INTEGER): MixedBar {
  const shape = pcmBarShape(context, pattern);
  const samplesPerBeat = shape.samplesPerBeat;
  const frameCount = shape.frameCount;
  const mixLength = Math.max(0, Math.min(frameCount, mixFrames));
  const data = new ArrayBuffer(mixLength * BYTES_PER_SAMPLE);
  applyDitherFloor(data);
  const dither = new Int16Array(data);
  const output = new Float32Array(mixLength);
  for (let i = 0; i < mixLength; i++) {
    output[i] = dither[i];
  }

  for (let eventIndex = 0; eventIndex < pattern.events.length; eventIndex++) {
    const event = pattern.events[eventIndex];
    const eventBeat = Math.floor(event.tick / pattern.ticksPerBeat) % Math.max(1, pattern.beatsPerBar);
    const pointState = context.beatPointStates[eventBeat] ?? 'normal';
    if (applyBeatPointPattern && pointState === 'silent') {
      continue;
    }
    const bankSample = drumSample(bank, event.sampleKey, styleKey);
    const sourceData = bankSample !== undefined ? bankSample :
      event.sampleKey === 'accent' ? context.accentBuffer : context.weakBuffer;
    const source = new DataView(sourceData);
    const sourceFrames = Math.floor(sourceData.byteLength / BYTES_PER_SAMPLE);
    const startFrame = Math.round(event.tick * samplesPerBeat / pattern.ticksPerBeat);
    const availableFrames = Math.min(sourceFrames, mixLength - startFrame);
    // Click tones ('accent'/'weak', bundled or from a sound bank) keep unity; only kit voices get headroom.
    const kitVoice = bankSample !== undefined && event.sampleKey !== 'accent' && event.sampleKey !== 'weak';
    const voiceGain = kitVoice ? context.drumKitGain : 1;
    for (let frame = 0; frame < availableFrames; frame++) {
      const target = startFrame + frame;
      const pointGain = applyBeatPointPattern && program !== undefined && pointState === 'accent' ? 1.15 : 1;
      const mixed = output[target] +
        source.getInt16(frame * BYTES_PER_SAMPLE, true) * event.velocity * pointGain * voiceGain;
      // Per-voice rounding is unchanged; range is enforced once by the drum bus limiter.
      output[target] = Math.round(mixed);
    }
  }

  return {
    mix: output,
    frameCount: frameCount,
    samplesPerBeat: samplesPerBeat,
    beatsPerBar: pattern.beatsPerBar
  };
}

export function mixPcmRideTails(context: PcmVoiceContext, patterns: SequencerPattern[], sequence: MixedBar[],
  looping: boolean, bank: Map<string, ArrayBuffer>, program: DrumProgram | undefined): void {
  if (sequence.length === 0) {
    return;
  }
  const styles = programBarStyleKeys(program);
  // Only the sustained ride voice needs this continuation. Mix it while
  // preparing PCM, never in writeData, and keep every bar's frame count and
  // transport boundary unchanged. Looping PCM includes the previous cycle's
  // steady-state ring so its seam cannot chop the cymbal tail.
  for (let barIndex = 0; barIndex < patterns.length; barIndex++) {
    const pattern = patterns[barIndex];
    const bar = sequence[barIndex];
    const ride = drumSample(bank, 'ride', styles[barIndex]);
    if (ride === undefined) {
      continue;
    }
    // A ringing cymbal retains its source kit across the next section's style boundary.
    const source = new DataView(ride);
    const sourceFrames = Math.floor(ride.byteLength / BYTES_PER_SAMPLE);
    for (let eventIndex = 0; eventIndex < pattern.events.length; eventIndex++) {
      const event = pattern.events[eventIndex];
      if (event.sampleKey !== 'ride') {
        continue;
      }
      const eventBeat = Math.floor(event.tick / pattern.ticksPerBeat) % Math.max(1, pattern.beatsPerBar);
      const pointState = context.beatPointStates[eventBeat] ?? 'normal';
      if (pointState === 'silent') {
        continue;
      }
      const startFrame = Math.round(event.tick * bar.samplesPerBeat / pattern.ticksPerBeat);
      if (startFrame < 0 || startFrame >= bar.frameCount) {
        continue;
      }
      const pointGain = program !== undefined && pointState === 'accent' ? 1.15 : 1;
      let sourceFrame = bar.frameCount - startFrame;
      let targetBarIndex = barIndex + 1;
      while (sourceFrame < sourceFrames) {
        if (!looping && targetBarIndex >= sequence.length) {
          break;
        }
        const target = sequence[targetBarIndex % sequence.length];
        const count = Math.min(sourceFrames - sourceFrame, target.frameCount);
        // Unrendered (placeholder or partial) bars keep their timing but take no samples.
        const writable = Math.min(count, target.mix.length);
        for (let frame = 0; frame < writable; frame++) {
          const mixed = target.mix[frame] + source.getInt16((sourceFrame + frame) * BYTES_PER_SAMPLE, true) *
            event.velocity * pointGain * context.drumKitGain;
          // Per-voice rounding is unchanged; range is enforced once by the drum bus limiter.
          target.mix[frame] = Math.round(mixed);
        }
        sourceFrame += count;
        targetBarIndex++;
      }
    }
  }
}

export function finishPcmBars(mixes: MixedBar[], looping: boolean): RenderedBar[] {
  const stats: DrumBusLimitStats = { overSamples: 0, limitedSamples: 0, peak: 0, minGain: 1 };
  const samples = limitDrumBus(mixes, looping, stats);
  if (stats.overSamples > 0) {
    console.info(`[DrumBusDiag] bars=${mixes.length} overSamples=${stats.overSamples}` +
      ` limitedSamples=${stats.limitedSamples} peakDbfs=${(20 * Math.log10(stats.peak / 32768)).toFixed(2)}` +
      ` minGainDb=${(20 * Math.log10(stats.minGain)).toFixed(2)}`);
  }
  const bars: RenderedBar[] = [];
  for (let i = 0; i < mixes.length; i++) {
    bars.push({
      samples: samples[i],
      frameCount: mixes[i].frameCount,
      samplesPerBeat: mixes[i].samplesPerBeat,
      beatsPerBar: mixes[i].beatsPerBar
    });
  }
  return bars;
}

export function countInPattern(beats: number): SequencerPattern {
  const events: SequencerEvent[] = [];
  for (let beat = 0; beat < beats; beat++) {
    events.push({
      tick: beat * DEFAULT_TICKS_PER_BEAT,
      sampleKey: beat === 0 ? 'accent' : 'weak',
      velocity: 1
    });
  }
  return new SequencerPattern(DEFAULT_TICKS_PER_BEAT, beats, events);
}

/** Head bars for a split render; 0 renders the whole sequence at once. */
export function pcmHeadBarCount(totalBars: number): number {
  // Measured 2026-11-03: rendering runs ~16x faster than playback on the
  // slower phone, so a chunk of C bars renders while ~C/16 bars play. The head
  // and each later chunk use N/8 bars, so the chain stays well ahead of
  // playback; short programs gain nothing from splitting.
  if (totalBars <= 3) {
    return 0;
  }
  const head = Math.max(2, Math.ceil(totalBars / 8));
  return head < totalBars - 1 ? head : 0;
}

/** Bars per later chunk; equal to the head so every chunk costs about the same. */
export function pcmTailChunkBars(totalBars: number): number {
  return Math.max(1, pcmHeadBarCount(totalBars));
}

function renderPcmChunk(job: PcmRenderJob, chunk: PcmRenderChunk, startedAt: number): PcmRenderResult {
  const count = job.patterns.length;
  const startBar = Math.max(0, Math.min(chunk.startBar, count));
  const endBar = Math.max(startBar, Math.min(chunk.endBar, count));
  // The limiter looks 219 frames past the chunk: into the next bar, or the
  // loop's first bar after the last chunk; a non-looping end looks at nothing.
  const lookaheadBar = endBar < count ? endBar : job.looping ? 0 : -1;
  const styles = programBarStyleKeys(job.program);
  const mixes: MixedBar[] = [];
  const head = startBar === 0;
  const placeholders: PcmBarShape[] = [];
  let longest = 1;
  for (let i = 0; i < count; i++) {
    const inChunk = i >= startBar && i < endBar;
    const mixFrames = inChunk ? Number.MAX_SAFE_INTEGER : i === lookaheadBar ? DRUM_BUS_LOOKAHEAD_FRAMES : 0;
    const mix = mixPcmBar(job.context, job.patterns[i], true, job.bank, job.program, styles[i], mixFrames);
    mixes.push(mix);
    if (head && !inChunk) {
      placeholders.push({ frameCount: mix.frameCount, samplesPerBeat: mix.samplesPerBeat, beatsPerBar: mix.beatsPerBar });
      longest = Math.max(longest, mix.frameCount);
    }
  }
  // Tails from every bar, including the loop wrap from the last bars, land in
  // this chunk exactly as in the whole render; other bars take no samples.
  mixPcmRideTails(job.context, job.patterns, mixes, job.looping, job.bank, job.program);
  const lookahead = lookaheadBar < 0 ? new Float32Array(0) :
    mixes[lookaheadBar].mix.subarray(0, DRUM_BUS_LOOKAHEAD_FRAMES);
  const stats: DrumBusLimitStats = { overSamples: 0, limitedSamples: 0, peak: 0, minGain: 1 };
  const limited = limitDrumBusChunk(mixes.slice(startBar, endBar), lookahead,
    chunk.limiterState ?? freshDrumBusLimiterState(), stats);
  if (stats.overSamples > 0) {
    console.info(`[DrumBusDiag] bars=${startBar}-${endBar}/${count} overSamples=${stats.overSamples}` +
      ` limitedSamples=${stats.limitedSamples} minGainDb=${(20 * Math.log10(stats.minGain)).toFixed(2)}`);
  }
  const sequence: RenderedBar[] = [];
  for (let i = startBar; i < endBar; i++) {
    sequence.push({
      samples: limited.outputs[i - startBar], frameCount: mixes[i].frameCount,
      samplesPerBeat: mixes[i].samplesPerBeat, beatsPerBar: mixes[i].beatsPerBar
    });
  }
  const result: PcmRenderResult = {
    sequence, countIn: undefined, renderMs: 0, limiterState: limited.state
  };
  if (head) {
    const silenceData = new ArrayBuffer(longest * BYTES_PER_SAMPLE);
    applyDitherFloor(silenceData);
    result.placeholders = placeholders;
    result.silence = new Int16Array(silenceData);
    result.countIn = job.countInBeats > 0 ? finishPcmBars([mixPcmBar(job.context,
      countInPattern(job.countInBeats), false, job.bank, job.program)], false)[0] : undefined;
  }
  result.renderMs = Date.now() - startedAt;
  return result;
}

/** Whole job, as run on the worker thread. */
export function renderPcmJob(job: PcmRenderJob): PcmRenderResult {
  const startedAt = Date.now();
  if (job.chunk !== undefined) {
    return renderPcmChunk(job, job.chunk, startedAt);
  }
  const styles = programBarStyleKeys(job.program);
  const mixes: MixedBar[] = [];
  for (let i = 0; i < job.patterns.length; i++) {
    mixes.push(mixPcmBar(job.context, job.patterns[i], true, job.bank, job.program, styles[i]));
  }
  mixPcmRideTails(job.context, job.patterns, mixes, job.looping, job.bank, job.program);
  // Ride tails cross bar boundaries, so the whole sequence is limited at once.
  const sequence = finishPcmBars(mixes, job.looping);
  const countIn = job.countInBeats > 0 ? finishPcmBars([mixPcmBar(job.context,
    countInPattern(job.countInBeats), false, job.bank, job.program)],
    false)[0] : undefined;
  return { sequence, countIn, renderMs: Date.now() - startedAt };
}
