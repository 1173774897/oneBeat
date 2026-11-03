#include "../../entry/src/main/cpp/recording_residual_lag.h"
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <vector>
using namespace onebeat_recording;

namespace {
uint32_t seed = 12345;
double Noise() { seed = seed * 1664525u + 1013904223u; return (static_cast<int>(seed >> 9) % 2001 - 1000) / 1000.0; }

// Drum-like accompaniment: 8th-note hits at 120 BPM (250 ms period) with accented beats,
// bright decaying noise bursts. Its own periodicity is what makes plain correlation alias.
std::vector<int16_t> Accompaniment(int frames)
{
    std::vector<int16_t> out(frames * 2, 0);
    for (int hit = 0; hit * 12000 < frames; ++hit) {
        const double level = hit % 2 == 0 ? 20000 : 9000;
        for (int i = 0; i < 4800 && hit * 12000 + i < frames; ++i) {
            const double v = level * std::exp(-i / 700.0) * Noise();
            out[2 * (hit * 12000 + i)] = out[2 * (hit * 12000 + i) + 1] = static_cast<int16_t>(v);
        }
    }
    return out;
}

ResidualLagEstimate Run(const std::vector<int16_t> &inner, const std::vector<int16_t> &mic, int frames)
{
    ResidualLagEstimator estimator;
    for (int p = 0; p < frames; p += 4096) {
        const int n = std::min(4096, frames - p);
        estimator.Append(inner.data() + 2 * p, mic.data() + 2 * p, n);
    }
    return estimator.Estimate();
}

std::vector<int16_t> DelayedResidual(const std::vector<int16_t> &inner, int frames, int delayFrames,
    double gain, double noise)
{
    std::vector<int16_t> mic(frames * 2, 0);
    for (int f = 0; f < frames; ++f) {
        const int src = f - delayFrames;
        // Residual is a filtered, level-varying copy (nonlinear AEC leftover), plus room noise.
        const double copy = src >= 0 ? gain * (0.6 + 0.4 * std::sin(f / 9000.0)) * inner[2 * src] : 0;
        const double v = copy + noise * Noise();
        mic[2 * f] = mic[2 * f + 1] = static_cast<int16_t>(std::lround(std::max(-32768.0, std::min(32767.0, v))));
    }
    return mic;
}
}

int main()
{
    constexpr int frames = 48000 * 24;
    const auto inner = Accompaniment(frames);
    // Clear residual at the Pura 80 round trip (141 ms) despite the 250 ms pattern period.
    for (int delayMs : {109, 133, 141, 200}) {
        const auto mic = DelayedResidual(inner, frames, delayMs * 48, 0.05, 150);
        const auto estimate = Run(inner, mic, frames);
        assert(estimate.reliable);
        assert(std::llabs(estimate.lagUs - delayMs * 1000LL) <= 4000);
    }
    // Noise-only MIC (AEC removed everything): never invent a lag.
    {
        const auto mic = DelayedResidual(inner, frames, 0, 0, 400);
        const auto estimate = Run(inner, mic, frames);
        assert(!estimate.reliable);
    }
    // Residual far below the noise floor: unreliable rather than a guessed alias.
    {
        const auto mic = DelayedResidual(inner, frames, 141 * 48, 0.0005, 600);
        assert(!Run(inner, mic, frames).reliable);
    }
    // Too short to trust (< 10 s of overlap).
    {
        constexpr int shortFrames = 48000 * 6;
        const std::vector<int16_t> shortInner(inner.begin(), inner.begin() + shortFrames * 2);
        const auto mic = DelayedResidual(shortInner, shortFrames, 141 * 48, 0.05, 150);
        assert(!Run(shortInner, mic, shortFrames).reliable);
    }
    std::cout << "PASS recording residual lag: 109-200 ms round trips through periodic drums, noise/weak/short takes unreliable\n";
}
