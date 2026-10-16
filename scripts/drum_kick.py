"""Original felt-beater bass drum synthesis for OneBeat's acoustic kick voice."""

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


def render_kick(
    rng: random.Random,
    count: int,
    sample_rate: int,
    pitch: float,
    tail: float,
    drive: float,
) -> list[float]:
    """Return a raw mono bass drum; the caller owns gain and the final fade.

    The exact requested frame count and immediate onset preserve sequencer
    timing. Style controls vary tuning, damping and beater pressure gently so
    even the electronic styles retain this voice's acoustic drum identity.
    """
    if count <= 0:
        return []

    tuning = max(0.91, min(1.09, max(0.1, pitch) ** 0.22))
    decay_scale = max(0.82, min(1.12, max(0.1, tail) ** 0.30))
    pressure = max(0.92, min(1.08, 1.0 + (drive - 1.0) * 0.10))
    base = 59.0 * tuning
    duration = count / sample_rate
    noise = [rng.uniform(-1.0, 1.0) for _ in range(count)]

    # A felt beater transfers momentum over a short finite contact. Its force
    # pulse excites the head modes together, rather than starting an exposed
    # sine wave with the old multi-octave electronic pitch sweep.
    force: list[float] = []
    for index in range(count):
        t = index / sample_rate
        rise = 1.0 - math.exp(-t / 0.00016)
        force.append(rise * math.exp(-t / 0.00060) * (1.0 + 0.10 * noise[index]))
    force_sum = max(1e-12, sum(force))
    force = [value / force_sum for value in force]

    # The coupled heads and shell have several damped, inharmonic modes. A very
    # small tension change settles within a few milliseconds; sustained glides
    # would turn the low head back into an 808-like bass oscillator.
    modes = (
        (1.000, 0.95, 0.085),
        (1.481, 0.42, 0.050),
        (2.107, 0.28, 0.033),
        (2.437, 0.19, 0.023),
        (2.813, 0.11, 0.017),
        (3.617, 0.075, 0.012),
        (4.320, 0.045, 0.008),
    )
    settle = [1.0 + 0.035 * math.exp(-index / (sample_rate * 0.006)) for index in range(count)]
    out = [0.0] * count
    for ratio, amplitude, decay in modes:
        frequency = base * ratio * rng.uniform(0.997, 1.003)
        # The shortest legacy one-shots must still end quietly before the
        # caller's tiny edge fade; otherwise the low head can click at the cut.
        effective_decay = min(decay * decay_scale, duration / 7.5)
        radius = math.exp(-1.0 / (sample_rate * max(effective_decay, 1e-6)))
        radius_squared = radius * radius
        phase_step = 2.0 * math.pi * frequency / sample_rate
        y1 = y2 = 0.0
        for index in range(count):
            step = phase_step * settle[index]
            value = 2.0 * radius * math.cos(step) * y1 - radius_squared * y2 + math.sin(step) * force[index]
            y2, y1 = y1, value
            out[index] += amplitude * value

    felt = _bandpass(noise, sample_rate, 720.0 * tuning, 0.60)
    skin = _bandpass(noise, sample_rate, 1550.0 * tuning, 0.65)
    shell = _bandpass(noise, sample_rate, 285.0 * tuning, 1.10)
    for index in range(count):
        t = index / sample_rate
        attack = 1.0 - math.exp(-t / 0.00024)
        contact = felt[index] * 0.65 * math.exp(-t / 0.0050)
        contact += skin[index] * 0.12 * math.exp(-t / 0.0024)
        cavity = shell[index] * 0.22 * math.exp(-t / (0.013 * decay_scale))
        out[index] += attack * (contact * pressure + cavity)

    # A finite modal response can retain a tiny pressure offset. Remove it
    # below the audible head tuning without subtracting a constant that would
    # introduce a discontinuity at the beginning or end of the one-shot.
    dc_retain = math.exp(-2.0 * math.pi * 20.0 / sample_rate)
    previous_input = previous_output = 0.0
    for index, value in enumerate(out):
        filtered = dc_retain * (previous_output + value - previous_input)
        previous_input, previous_output = value, filtered
        out[index] = filtered
    return out
