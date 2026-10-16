"""Original struck-ride synthesis with a dry tip attack and restrained metal wash."""

import math
import random


def _bandpass(samples: list[float], sample_rate: int, frequency: float, q: float) -> list[float]:
    omega = 2.0 * math.pi * min(frequency, sample_rate * 0.43) / sample_rate
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


def _add_mode(
    result: list[float], sample_rate: int, frequency: float, decay: float, amplitude: float, phase: float
) -> None:
    frequency = min(frequency, sample_rate * 0.44)
    step = 2.0 * math.pi * frequency / sample_rate
    radius = math.exp(-1.0 / (sample_rate * decay))
    coefficient = 2.0 * radius * math.cos(step)
    radius_squared = radius * radius
    current = amplitude * math.sin(phase)
    previous = amplitude * math.sin(phase - step) / radius
    for index in range(len(result)):
        result[index] += current
        following = coefficient * current - radius_squared * previous
        previous, current = current, following


def render_ride(
    rng: random.Random,
    count: int,
    sample_rate: int,
    pitch: float,
    tail: float,
    drive: float,
) -> list[float]:
    """Return a deterministic mono ride; the caller owns duration, fade and gain.

    Style parameters vary stick brightness and damping within a small range. A
    ride remains the same acoustic instrument across styles, rather than being
    transposed into a bell or turned into the open-hi-hat voice.
    """
    if count <= 0:
        return []

    color = max(0.92, min(1.08, max(0.1, pitch) ** 0.15))
    damping = max(0.84, min(1.12, max(0.1, tail) ** 0.20))
    pressure = max(0.90, min(1.10, 1.0 + (drive - 1.0) * 0.12))
    result = [0.0] * count

    # Dense, irregular partials give the bow a metallic continuum. No isolated
    # low mode is allowed to dominate as it would in a bell patch; the quieter
    # low partials last longer while bright partials damp sooner.
    mode_count = 72
    for mode in range(mode_count):
        position = mode / (mode_count - 1)
        frequency = 1080.0 * (13.4 ** position) * rng.uniform(0.978, 1.022) * color
        center_weight = math.exp(-0.5 * ((math.log(frequency / (4100.0 * color))) / 0.77) ** 2)
        amplitude = (0.0065 + 0.0125 * center_weight) * rng.uniform(0.66, 1.20)
        decay = (0.375 - 0.175 * position) * damping * rng.uniform(0.87, 1.13)
        _add_mode(result, sample_rate, frequency, decay, amplitude, rng.uniform(-math.pi, math.pi))

    # A tip strike contains many short-lived high partials. Spreading the ping
    # over this cluster keeps the rhythmic attack clear without a synthetic
    # single-frequency "ding" or the broad sustained roar of a crash cymbal.
    for mode in range(22):
        position = mode / 21.0
        frequency = (2050.0 + 5900.0 * position) * rng.uniform(0.975, 1.025) * color
        amplitude = (0.046 + 0.030 * math.sin(math.pi * position)) * pressure
        decay = (0.028 - 0.014 * position) * damping
        _add_mode(result, sample_rate, frequency, decay, amplitude, rng.uniform(-math.pi, math.pi))

    noise = [rng.uniform(-1.0, 1.0) for _ in range(count)]
    tip = _bandpass(noise, sample_rate, 4400.0 * color, 0.75)
    wash_mid = _bandpass(noise, sample_rate, 5900.0 * color, 0.58)
    wash_high = _bandpass(noise, sample_rate, 10500.0 * color, 0.70)
    for index in range(count):
        t = index / sample_rate
        attack = 1.0 - math.exp(-t / 0.00007)
        stick = tip[index] * 0.34 * pressure * math.exp(-t / 0.0027)
        wash = (wash_mid[index] * 0.046 + wash_high[index] * 0.028) * math.exp(-t / (0.185 * damping))
        result[index] = attack * (result[index] + stick + wash)
    return result
