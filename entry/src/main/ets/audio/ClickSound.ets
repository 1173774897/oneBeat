const SAMPLE_RATE: number = 44100;

// Click envelope: a fast percussive transient plus a slower resonance tail.
// The tail keeps the signal from collapsing into pure digital silence between
// beats, which the smart PA (CustStreamCheck) can misclassify as "zero volume".
const BODY_DECAY: number = 80; // fast transient decay (1/s)
const TAIL_DECAY: number = 16; // slower resonance tail decay (1/s)
const TAIL_MIX: number = 0.35; // tail amplitude relative to the transient peak

export const ACCENT_DURATION_MS: number = 120;
export const WEAK_DURATION_MS: number = 100;

function writeSample(view: DataView, index: number, value: number): void {
  const clamped = Math.max(-1, Math.min(1, value));
  view.setInt16(index * 2, clamped * 32767, true);
}

export class ClickSound {
  static buildAccentBuffer(durationMs: number = ACCENT_DURATION_MS): ArrayBuffer {
    return ClickSound.buildTone(880, durationMs, 0.85);
  }

  static buildWeakBuffer(durationMs: number = WEAK_DURATION_MS): ArrayBuffer {
    return ClickSound.buildTone(660, durationMs, 0.55);
  }

  static buildTone(freq: number, durationMs: number, gain: number): ArrayBuffer {
    const sampleCount = Math.floor(SAMPLE_RATE * durationMs / 1000);
    const buffer = new ArrayBuffer(sampleCount * 2);
    const view = new DataView(buffer);
    for (let i = 0; i < sampleCount; i++) {
      const t = i / SAMPLE_RATE;
      const body = Math.exp(-t * BODY_DECAY);
      const tail = TAIL_MIX * Math.exp(-t * TAIL_DECAY);
      const env = (body + tail) / (1 + TAIL_MIX); // peak normalized to ~1.0
      const sample = Math.sin(2 * Math.PI * freq * t) * gain * env;
      writeSample(view, i, sample);
    }
    return buffer;
  }

  static getSampleRate(): number {
    return SAMPLE_RATE;
  }
}
