#!/usr/bin/env python3
"""Generate the original OneBeat drum one-shot library using deterministic DSP."""

import argparse
import json
import math
import random
import struct
import wave
from pathlib import Path

from drum_clap import render_clap
from drum_percussion import render_percussion
from drum_kick import render_kick
from drum_ride import render_ride
from drum_shaker import render_shaker
from drum_tom import render_tom

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
# Keep the first eight indices stable: their per-style random seeds are part
# of the existing asset library. Display order is owned by DRUM_TRACKS.
SAMPLE_NAMES = ["kick", "snare", "hat_closed", "hat_open", "clap", "tom_low", "tom_high", "perc", "ride", "shaker"]


def envelope(t: float, decay: float, attack: float = 0.001) -> float:
    return min(1.0, t / max(attack, 1e-5)) * math.exp(-t / max(decay, 1e-5))


def saturate(value: float, drive: float) -> float:
    return math.tanh(value * drive) / math.tanh(max(1.0, drive))


def render(style_index: int, name: str, pitch: float, tail: float, drive: float) -> list[float]:
    rng = random.Random(1000 + style_index * 97 + SAMPLE_NAMES.index(name) * 17)
    durations = {
        "kick": 0.52, "snare": 0.34, "hat_closed": 0.10, "hat_open": 0.52,
        "clap": 0.30, "tom_low": 0.48, "tom_high": 0.36, "perc": 0.30,
        "ride": 1.40, "shaker": 0.22,
    }
    duration_scale = tail ** 0.35 if name in ("ride", "shaker") else tail
    count = int(SAMPLE_RATE * durations[name] * duration_scale)
    # These acoustic models already shape their transients. The legacy drive
    # would flatten the contact and make them sound like electronic noise again.
    if name == "clap":
        return finish(render_clap(rng, count, SAMPLE_RATE, pitch, tail, drive))
    if name == "perc":
        return finish(render_percussion(rng, count, SAMPLE_RATE, style_index, pitch, tail, drive))
    if name == "kick":
        return finish(render_kick(rng, count, SAMPLE_RATE, pitch, tail, drive))
    if name == "ride":
        return finish(render_ride(rng, count, SAMPLE_RATE, pitch, tail, drive))
    if name == "shaker":
        return finish(render_shaker(rng, count, SAMPLE_RATE, pitch, tail, drive))
    if name in ("tom_low", "tom_high"):
        return finish(render_tom(rng, count, SAMPLE_RATE, pitch, tail, drive, high=name == "tom_high"))

    out: list[float] = []
    previous_noise = 0.0
    for i in range(count):
        t = i / SAMPLE_RATE
        noise = rng.uniform(-1.0, 1.0)
        high_noise = noise - previous_noise * 0.94
        previous_noise = noise
        value = 0.0

        if name == "snare":
            body = math.sin(2.0 * math.pi * 185.0 * pitch * t) * envelope(t, 0.10 * tail)
            wire = high_noise * envelope(t, 0.14 * tail, 0.0003)
            value = body * 0.38 + wire * 0.82
        elif name in ("hat_closed", "hat_open"):
            decay = (0.025 if name == "hat_closed" else 0.22) * tail
            metallic = sum(math.sin(2.0 * math.pi * f * pitch * t) for f in (4100, 5630, 7310, 9180)) / 4.0
            value = (high_noise * 0.72 + metallic * 0.38) * envelope(t, decay, 0.00015)
        out.append(saturate(value, drive))

    return finish(out)


def finish(out: list[float]) -> list[float]:
    fade = min(128, len(out))
    for i in range(fade):
        out[-1 - i] *= i / fade
    peak = max(0.001, max(abs(v) for v in out))
    gain = 0.92 / peak
    return [max(-1.0, min(1.0, value * gain)) for value in out]


def write_wav(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = b"".join(struct.pack("<h", int(sample * 32767.0)) for sample in samples)
    # DrumSampleBank reads PCM after a fixed 44-byte header. Keep this simple
    # mono/LE16 WAV layout; metadata chunks would be interpreted as audio.
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "generated-drums")
    output = parser.parse_args().output
    manifest = {
        "generator": "OneBeat deterministic DSP v4",
        "license": "Original project asset",
        "models": {
            "kick": "acoustic bass drum v3", "ride": "struck ride cymbal v3",
            "shaker": "granular shaker v3", "clap": "single-person palm contact v2",
            "perc": "skin-and-wood hand drum v2", "tom_low": "acoustic floor tom v4",
            "tom_high": "acoustic rack tom v4", "other": "original DSP v1",
        },
        "styles": {},
    }
    for index, (style, pitch, tail, drive) in enumerate(STYLES):
        manifest["styles"][style] = []
        for sample_name in SAMPLE_NAMES:
            relative = f"{style}/{sample_name}.wav"
            write_wav(output / relative, render(index, sample_name, pitch, tail, drive))
            manifest["styles"][style].append(relative)
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
