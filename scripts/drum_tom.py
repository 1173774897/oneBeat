"""Original struck-head tom synthesis for OneBeat's floor and rack toms."""

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


def render_tom(
    rng: random.Random,
    count: int,
    sample_rate: int,
    pitch: float,
    tail: float,
    drive: float,
    high: bool,
) -> list[float]:
    """Return exactly ``count`` raw mono frames; the caller fades and normalizes.

    Both voices start at the same sample boundary as the other kit sounds.
    The supplied RNG makes each style repeatable, while bounded tuning and
    damping preserve a recognizable acoustic floor/rack pair in every style.
    ``drive`` changes stick pressure slightly and never adds distortion.
    """
    if count <= 0:
        return []

    tuning = max(0.91, min(1.10, max(0.1, pitch) ** 0.32))
    decay_scale = max(0.83, min(1.12, max(0.1, tail) ** 0.34))
    pressure = max(0.92, min(1.08, 1.0 + (drive - 1.0) * 0.12))
    base = (170.0 if high else 108.0) * tuning
    body_decay = (0.064 if high else 0.086) * decay_scale
    duration = count / sample_rate
    noise = [rng.uniform(-1.0, 1.0) for _ in range(count)]

    # A stick transfers force over a finite contact, exciting the head modes
    # together. An unexcited sine plus a long pitch sweep exposes an oscillator
    # instead of the impact and coupled resonances of a real two-headed drum.
    force: list[float] = []
    for index in range(count):
        t = index / sample_rate
        rise = 1.0 - math.exp(-t / 0.000045)
        contact = math.exp(-t / 0.00024) + 0.11 * math.exp(-t / 0.00085)
        force.append(rise * contact * (1.0 + 0.17 * noise[index]))
    force_sum = max(1e-12, sum(force))
    force = [value / force_sum for value in force]

    # Coupling shifts the circular-head ratios away from exact harmonics.
    # Upper modes lose energy faster, leaving a pitched head/body decay rather
    # than the metallic, equally sustained partials of a synthetic tom.
    modes = (
        (1.000, 0.88, 1.000),
        (1.472, 0.43, 0.640),
        (1.986, 0.30, 0.430),
        (2.337, 0.22, 0.330),
        (2.781, 0.16, 0.260),
        (3.184, 0.11, 0.210),
        (3.672, 0.075, 0.165),
        (4.213, 0.055, 0.130),
        (4.861, 0.038, 0.105),
        (5.492, 0.025, 0.085),
        (6.407, 0.016, 0.070),
    )
    # Impact briefly raises head tension. This modest, fast fall retains the
    # acoustic tom's pitch contour without the old conspicuous electronic bend.
    settle_amount = 0.040 if high else 0.050
    settle_time = 0.012 if high else 0.016
    settle = [1.0 + settle_amount * math.exp(-index / (sample_rate * settle_time)) for index in range(count)]
    out = [0.0] * count
    for ratio, amplitude, decay_ratio in modes:
        frequency = base * ratio * rng.uniform(0.996, 1.004)
        radius = math.exp(-1.0 / (sample_rate * body_decay * decay_ratio))
        radius_squared = radius * radius
        phase_step = 2.0 * math.pi * frequency / sample_rate
        y1 = y2 = 0.0
        for index in range(count):
            step = phase_step * settle[index]
            value = 2.0 * radius * math.cos(step) * y1 - radius_squared * y2 + math.sin(step) * force[index]
            y2, y1 = y1, value
            out[index] += amplitude * value

    # The resonant head carries the note; broadband stick, skin and shell
    # contact supply its identity without a sustained noise/snare-wire layer.
    stick = _bandpass(noise, sample_rate, (3550.0 if high else 2750.0) * tuning, 0.65)
    skin = _bandpass(noise, sample_rate, (1650.0 if high else 1250.0) * tuning, 0.80)
    shell = _bandpass(noise, sample_rate, (830.0 if high else 540.0) * tuning, 1.25)
    for index in range(count):
        t = index / sample_rate
        attack = 1.0 - math.exp(-t / 0.000085)
        contact = 0.15 * stick[index] * math.exp(-t / 0.0025)
        contact += 0.18 * skin[index] * math.exp(-t / 0.0060)
        cavity = 0.22 * shell[index] * math.exp(-t / (0.018 * decay_scale))
        out[index] += attack * (contact * pressure + cavity)

    # The existing files have fixed style-specific lengths, including very
    # short funk hits. Preserve their body, then increase damping smoothly late
    # in the window: the caller's 128-frame edge fade must not hide a loud cut.
    # Removing pressure offset first keeps that damping from leaving a DC tail.
    dc_retain = math.exp(-2.0 * math.pi * 22.0 / sample_rate)
    previous_input = previous_output = 0.0
    for index, value in enumerate(out):
        filtered = dc_retain * (previous_output + value - previous_input)
        previous_input, previous_output = value, filtered
        progress = (index / sample_rate) / duration
        out[index] = filtered * math.exp(-8.0 * progress ** 8)
    return out
