const SAMPLE_RATE: number = 44100;

function writeSample(view: DataView, index: number, value: number): void {
  const clamped = Math.max(-1, Math.min(1, value));
  view.setInt16(index * 2, clamped * 32767, true);
}

export class ClickSound {
  static buildAccentBuffer(durationMs: number = 18): ArrayBuffer {
    return ClickSound.buildTone(880, durationMs, 0.85);
  }

  static buildWeakBuffer(durationMs: number = 14): ArrayBuffer {
    return ClickSound.buildTone(660, durationMs, 0.55);
  }

  static buildTone(freq: number, durationMs: number, gain: number): ArrayBuffer {
    const sampleCount = Math.floor(SAMPLE_RATE * durationMs / 1000);
    const buffer = new ArrayBuffer(sampleCount * 2);
    const view = new DataView(buffer);
    for (let i = 0; i < sampleCount; i++) {
      const t = i / SAMPLE_RATE;
      const env = Math.exp(-t * 90);
      const sample = Math.sin(2 * Math.PI * freq * t) * gain * env;
      writeSample(view, i, sample);
    }
    return buffer;
  }

  static getSampleRate(): number {
    return SAMPLE_RATE;
  }
}
