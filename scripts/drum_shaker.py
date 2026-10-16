"""Original granular hand-shaker synthesis; no recorded or pitched source is used."""

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


def render_shaker(
    rng: random.Random,
    count: int,
    sample_rate: int,
    pitch: float,
    tail: float,
    drive: float,
) -> list[float]:
    """Return one dry, repeatable shaker stroke with no end fade or normalization.

    Grain collisions and friction share one short stroke envelope. There is no
    delayed accent or leading silence, so a sequencer event stays on its tick.
    The caller retains control of the exact number of mono PCM frames.
    """
    if count <= 0:
        return []

    color = max(0.89, min(1.12, max(0.1, pitch) ** 0.25))
    damping = max(0.81, min(1.12, max(0.1, tail) ** 0.25))
    pressure = max(0.90, min(1.12, 1.0 + (drive - 1.0) * 0.15))
    grain_retain = math.exp(-1.0 / (sample_rate * 0.00064))
    stroke_decay = 0.027 * damping
    collision_energy = 0.45
    noise: list[float] = []
    shell_noise: list[float] = []

    # The contents hit the shell irregularly and settle quickly after the
    # stroke. A shot-noise energy process preserves that grainy motion; merely
    # filtering one decaying white-noise burst would resemble a closed hi-hat.
    for index in range(count):
        t = index / sample_rate
        stroke = math.exp(-t / stroke_decay)
        collision_rate = (750.0 + 6800.0 * math.exp(-t / (0.009 * damping))) * stroke
        collision_energy *= grain_retain
        if rng.random() < collision_rate / sample_rate:
            collision_energy += rng.uniform(0.12, 0.85) * stroke
        grain = rng.uniform(-1.0, 1.0) * math.sqrt(max(0.0, collision_energy))
        friction = rng.uniform(-1.0, 1.0) * 0.15 * stroke
        noise.append(grain + friction)
        shell_noise.append(grain * 0.45 + rng.uniform(-1.0, 1.0) * 0.10 * stroke)

    grit = _bandpass(noise, sample_rate, 5200.0 * color, 0.56)
    sand = _bandpass(noise, sample_rate, 9300.0 * color, 0.70)
    body = _bandpass(shell_noise, sample_rate, 1700.0 * color, 0.62)
    shell = _bandpass(shell_noise, sample_rate, 2900.0 * color, 0.60)
    result: list[float] = []
    for index in range(count):
        t = index / sample_rate
        attack = 1.0 - math.exp(-t / 0.00010)
        # Broad, low-Q shell bands add wood/paper body without an audible pitch
        # or metal oscillator, keeping this a dry shaker distinct from the hats.
        value = grit[index] * 0.67 + sand[index] * 0.19
        value += body[index] * 0.24 + shell[index] * 0.19
        result.append(value * attack * pressure)
    return result
