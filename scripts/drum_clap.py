"""A dry, single-person handclap synthesized without recorded source material."""

import math
import random


def _bandpass(samples: list[float], sample_rate: int, frequency: float, q: float) -> list[float]:
    omega = 2.0 * math.pi * min(frequency, sample_rate * 0.45) / sample_rate
    alpha = math.sin(omega) / (2.0 * q)
    inverse_a0 = 1.0 / (1.0 + alpha)
    b0 = alpha * inverse_a0
    a1 = -2.0 * math.cos(omega) * inverse_a0
    a2 = (1.0 - alpha) * inverse_a0
    x1 = x2 = y1 = y2 = 0.0
    result: list[float] = []
    for value in samples:
        filtered = b0 * (value - x2) - a1 * y1 - a2 * y2
        result.append(filtered)
        x2, x1 = x1, value
        y2, y1 = y1, filtered
    return result


def _lowpass(samples: list[float], sample_rate: int, frequency: float) -> list[float]:
    retain = math.exp(-2.0 * math.pi * frequency / sample_rate)
    previous = 0.0
    result: list[float] = []
    for value in samples:
        previous = retain * previous + (1.0 - retain) * value
        result.append(previous)
    return result


def render_clap(
    rng: random.Random,
    count: int,
    sample_rate: int,
    pitch: float,
    tail: float,
    drive: float,
) -> list[float]:
    """Return an unnormalized mono clap, with no clipping or end fade applied.

    The caller owns the one-shot frame count, final fade and output gain. Style
    parameters alter hand size, damping and impact pressure within a narrow range
    so every style still reads as hands meeting rather than an electronic snare.
    """
    if count <= 0:
        return []

    color = max(0.82, min(1.18, pitch ** 0.34))
    decay_scale = max(0.75, min(1.20, tail ** 0.48))
    pressure = max(0.85, min(1.15, 1.0 + (drive - 1.0) * 0.18))
    noise = [rng.uniform(-1.0, 1.0) for _ in range(count)]
    palm = _bandpass(noise, sample_rate, 1050.0 * color, 0.70)
    snap = _bandpass(noise, sample_rate, 2450.0 * color, 0.68)
    air_band = _bandpass(noise, sample_rate, 5600.0 * color, 0.65)
    air = _lowpass(air_band, sample_rate, min(9000.0, sample_rate * 0.40))

    # The fingers and palm do not meet at exactly the same instant. Keeping the
    # contacts within 3 ms makes one organic impact, not the spaced claps of a
    # drum-machine ensemble patch.
    contacts = (
        (0.0, 0.58),
        (rng.uniform(0.00045, 0.00085), 0.84),
        (rng.uniform(0.00135, 0.00185), 0.51),
        (rng.uniform(0.00240, 0.00290), 0.20),
    )
    direct: list[float] = []
    for index in range(count):
        t = index / sample_rate
        contact = 0.0
        for offset, strength in contacts:
            dt = t - offset
            if dt >= 0.0:
                attack = min(1.0, dt / 0.00012)
                contact += strength * attack * math.exp(-dt / (0.0062 * decay_scale))

        attack = min(1.0, t / 0.00018)
        palm_envelope = attack * math.exp(-t / (0.0115 * decay_scale))
        diffuse_envelope = attack * math.exp(-t / (0.024 * decay_scale))
        air_envelope = attack * math.exp(-t / (0.0052 * decay_scale))
        value = palm[index] * (contact * 0.87 + palm_envelope * 0.57)
        value += snap[index] * (contact * 0.94 + diffuse_envelope * 0.20)
        value += air[index] * (contact * 0.29 + air_envelope * 0.28) * pressure

        # Palm cavities add a little body, but these heavily damped modes must
        # disappear before they can become a pitched woodblock or tom sound.
        value += math.sin(2.0 * math.pi * 735.0 * color * t) * palm_envelope * math.exp(-t / 0.0028) * 0.15
        value += math.sin(2.0 * math.pi * 1240.0 * color * t) * palm_envelope * math.exp(-t / 0.0018) * 0.07
        direct.append(value * 0.60)

    # Quiet, filtered early reflections give the impact air without adding an
    # audible second hit or a room-sized reverb tail. Always read the dry source
    # so the delays cannot feed back and ring beyond the intended clap decay.
    reflection_source = _lowpass(direct, sample_rate, 3500.0 * color)
    reflections = (
        (int(sample_rate * 0.0087), 0.11),
        (int(sample_rate * 0.0143), 0.075),
        (int(sample_rate * 0.0221), 0.035),
    )
    result = direct.copy()
    for delay, gain in reflections:
        for index in range(delay, count):
            result[index] += reflection_source[index - delay] * gain
    return result
