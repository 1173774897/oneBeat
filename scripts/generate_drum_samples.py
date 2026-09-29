#!/usr/bin/env python3
"""Generate the original OneBeat drum one-shot library using deterministic DSP."""

import json
import math
import random
import struct
import wave
from pathlib import Path

SAMPLE_RATE = 44100
STYLES = [
    ("rock", 1.00, 0.85, 1.20),
    ("psychedelic", 0.82, 1.25, 1.45),
    ("jazz", 1.18, 0.72, 0.72),
    ("funk", 1.10, 0.58, 1.05),
    ("disco", 1.28, 0.78, 1.18),
    ("hiphop", 0.78, 1.10, 1.32),
    ("trap", 0.68, 1.35, 1.45),
    ("house", 1.22, 0.92, 1.28),
    ("techno", 0.92, 1.08, 1.55),
    ("dnb", 1.36, 0.62, 1.38),
    ("latin", 1.42, 0.66, 0.90),
    ("reggae", 0.88, 0.90, 0.78),
]
SAMPLE_NAMES = ["kick", "snare", "hat_closed", "hat_open", "clap", "tom_low", "tom_high", "perc"]


def envelope(t: float, decay: float, attack: float = 0.001) -> float:
    return min(1.0, t / max(attack, 1e-5)) * math.exp(-t / max(decay, 1e-5))


def saturate(value: float, drive: float) -> float:
    return math.tanh(value * drive) / math.tanh(max(1.0, drive))


def render(style_index: int, name: str, pitch: float, tail: float, drive: float) -> list[float]:
    rng = random.Random(1000 + style_index * 97 + SAMPLE_NAMES.index(name) * 17)
    durations = {
        "kick": 0.52, "snare": 0.34, "hat_closed": 0.10, "hat_open": 0.52,
        "clap": 0.30, "tom_low": 0.48, "tom_high": 0.36, "perc": 0.30,
    }
    count = int(SAMPLE_RATE * durations[name] * tail)
    out: list[float] = []
    previous_noise = 0.0
    phase = 0.0
    for i in range(count):
        t = i / SAMPLE_RATE
        noise = rng.uniform(-1.0, 1.0)
        high_noise = noise - previous_noise * 0.94
        previous_noise = noise
        value = 0.0

        if name == "kick":
            freq = (150.0 * pitch) * math.exp(-t * 25.0) + 42.0 * pitch
            phase += 2.0 * math.pi * freq / SAMPLE_RATE
            body = math.sin(phase) * envelope(t, 0.16 * tail, 0.0005)
            click = high_noise * math.exp(-t * 150.0) * 0.22
            value = body * 1.15 + click
        elif name == "snare":
            body = math.sin(2.0 * math.pi * 185.0 * pitch * t) * envelope(t, 0.10 * tail)
            wire = high_noise * envelope(t, 0.14 * tail, 0.0003)
            value = body * 0.38 + wire * 0.82
        elif name in ("hat_closed", "hat_open"):
            decay = (0.025 if name == "hat_closed" else 0.22) * tail
            metallic = sum(math.sin(2.0 * math.pi * f * pitch * t) for f in (4100, 5630, 7310, 9180)) / 4.0
            value = (high_noise * 0.72 + metallic * 0.38) * envelope(t, decay, 0.00015)
        elif name == "clap":
            burst = 0.0
            for offset in (0.0, 0.018, 0.037):
                dt = t - offset
                if dt >= 0:
                    burst += math.exp(-dt * 85.0)
            value = high_noise * min(1.0, burst) * math.exp(-t * 5.5 / tail)
        elif name in ("tom_low", "tom_high"):
            base = (108.0 if name == "tom_low" else 176.0) * pitch
            freq = base * (1.0 + 0.55 * math.exp(-t * 20.0))
            phase += 2.0 * math.pi * freq / SAMPLE_RATE
            value = math.sin(phase) * envelope(t, (0.22 if name == "tom_low" else 0.15) * tail)
            value += math.sin(phase * 1.98) * envelope(t, 0.08 * tail) * 0.18
        else:
            if style_index in (6, 8, 9):
                freqs = (720.0, 1130.0, 1670.0)
                metallic = sum(math.sin(2.0 * math.pi * f * pitch * t) for f in freqs) / len(freqs)
                value = metallic * envelope(t, 0.11 * tail)
            else:
                block = math.sin(2.0 * math.pi * 860.0 * pitch * t)
                block += 0.55 * math.sin(2.0 * math.pi * 1290.0 * pitch * t)
                value = block * envelope(t, 0.055 * tail)

        out.append(saturate(value, drive))

    fade = min(128, len(out))
    for i in range(fade):
        out[-1 - i] *= i / fade
    peak = max(0.001, max(abs(v) for v in out))
    gain = 0.92 / peak
    return [max(-1.0, min(1.0, value * gain)) for value in out]


def write_wav(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = b"".join(struct.pack("<h", int(sample * 32767.0)) for sample in samples)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)


def main() -> None:
    output = Path(__file__).resolve().parent / "generated-drums"
    manifest = {"generator": "OneBeat deterministic DSP v1", "license": "Original project asset", "styles": {}}
    for index, (style, pitch, tail, drive) in enumerate(STYLES):
        manifest["styles"][style] = []
        for sample_name in SAMPLE_NAMES:
            relative = f"{style}/{sample_name}.wav"
            write_wav(output / relative, render(index, sample_name, pitch, tail, drive))
            manifest["styles"][style].append(relative)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
