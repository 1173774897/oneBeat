"""Original, deterministic modal synthesis for OneBeat's hand-percussion voice."""

import math
import random


def _bandpass(samples: list[float], sample_rate: int, frequency: float, q: float) -> list[float]:
    omega = 2.0 * math.pi * min(frequency, sample_rate * 0.45) / sample_rate
    alpha = math.sin(omega) / (2.0 * q)
    inverse_a0 = 1.0 / (1.0 + alpha)
    b0 = alpha * inverse_a0
    b2 = -b0
    a1 = -2.0 * math.cos(omega) * inverse_a0
    a2 = (1.0 - alpha) * inverse_a0
    x1 = x2 = y1 = y2 = 0.0
    result: list[float] = []
    for value in samples:
        output = b0 * value + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, value
        y2, y1 = y1, output
        result.append(output)
    return result


def render_percussion(
    rng: random.Random,
    count: int,
    sample_rate: int,
    style_index: int,
    pitch: float,
    tail: float,
    drive: float,
) -> list[float]:
    """Render a small skin-and-wood hand drum; the caller fades and normalizes it.

    ``rng`` belongs to the offline asset generator, so rerendering a style is
    repeatable. The supplied count remains the exact voice duration; there is no
    leading silence or delayed onset that would shift the sequencer's timing.
    """
    if count <= 0:
        return []

    style = style_index % 12
    tuning = (1.00, 0.98, 1.02, 1.015, 1.01, 0.98, 0.97, 1.015, 0.99, 1.025, 1.035, 0.99)[style]
    damping = (1.00, 1.08, 0.92, 0.88, 0.95, 1.04, 1.06, 0.96, 0.96, 0.88, 0.94, 1.02)[style]
    base = 295.0 * max(0.1, pitch) ** 0.35 * tuning
    decay_scale = max(0.1, tail) ** 0.35 * damping
    noise = [rng.uniform(-1.0, 1.0) for _ in range(count)]
    contact_low = _bandpass(noise, sample_rate, 1450.0 * tuning, 0.60)
    contact_high = _bandpass(noise, sample_rate, 3650.0 * tuning, 0.65)
    force: list[float] = []
    for index in range(count):
        t = index / sample_rate
        rise = 1.0 - math.exp(-t / 0.000035)
        force.append(rise * (math.exp(-t / 0.00032) + 0.12 * math.exp(-t / 0.0013)) * (1.0 + 0.22 * noise[index]))
    force_sum = max(1e-12, sum(force))
    force = [value / force_sum for value in force]

    # A struck circular skin has inharmonic modes, unlike the old two-sine
    # electronic ping. Higher modes must die sooner or the slap sounds metallic.
    modes = (
        (1.000, 0.28, 0.061),
        (1.594, 0.38, 0.039),
        (2.136, 0.33, 0.027),
        (2.296, 0.21, 0.022),
        (2.654, 0.17, 0.018),
        (2.918, 0.12, 0.015),
        (3.156, 0.10, 0.012),
        (3.500, 0.08, 0.010),
        (4.180, 0.06, 0.008),
        (5.060, 0.04, 0.006),
    )
    out = [0.0] * count
    for ratio, amplitude, decay in modes:
        frequency = base * ratio * rng.uniform(0.994, 1.006)
        radius = math.exp(-1.0 / (sample_rate * decay * decay_scale))
        radius_squared = radius * radius
        phase_step = 2.0 * math.pi * frequency / sample_rate
        y1 = y2 = 0.0
        for index in range(count):
            # The skin briefly tightens at impact; keeping the settle short
            # avoids turning this hand strike into a sustained synthetic glide.
            t = index / sample_rate
            step = phase_step * (1.0 + 0.055 * math.exp(-t / 0.0045))
            value = 2.0 * radius * math.cos(step) * y1 - radius_squared * y2 + math.sin(step) * force[index]
            y2, y1 = y1, value
            out[index] += value * amplitude

    # The wooden shell adds a brief, broad knock. Filtering noise rather than
    # adding another sustained oscillator keeps the cavity underneath the skin.
    cavity = _bandpass(noise, sample_rate, 780.0 * tuning, 1.7)
    presence = 1.0 + 0.10 * (drive - 1.0)
    for index in range(count):
        t = index / sample_rate
        contact_attack = 1.0 - math.exp(-t / 0.00013)
        palm = contact_low[index] * math.exp(-t / (0.0065 * decay_scale))
        fingers = contact_high[index] * math.exp(-t / 0.0028)
        shell = cavity[index] * math.exp(-t / (0.013 * decay_scale))
        out[index] += contact_attack * (0.33 * palm + 0.16 * fingers + 0.20 * shell) * presence
    return out
