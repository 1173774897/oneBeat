#include "../../entry/src/main/cpp/recording_mic_level.h"
#include "../../entry/src/main/cpp/recording_audio_math.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <vector>
using namespace onebeat_recording;

static std::vector<int16_t> Signal(double amplitude, bool pauses = true)
{
    std::vector<int16_t> pcm(48000 * 3 * 2);
    for (size_t frame = 0; frame < pcm.size() / 2; ++frame) {
        const bool active = !pauses || (frame / 9600) % 3 != 0;
        const auto sample = static_cast<int16_t>(std::lround(32768 *
            (active ? amplitude : amplitude / 100) * std::sin(frame * 2 * 3.141592653589793 * 307 / 48000)));
        pcm[frame * 2] = sample;
        pcm[frame * 2 + 1] = sample;
    }
    return pcm;
}
static double Measure(const std::vector<int16_t> &pcm, size_t batch = 4096)
{
    SystemMicLevelMeter meter;
    for (size_t frame = 0; frame < pcm.size() / 2; frame += batch)
        meter.Append(pcm.data() + frame * 2, std::min(batch, pcm.size() / 2 - frame));
    return meter.Gain();
}
static void CheckBoostedSamples(const std::vector<int16_t> &pcm, double gain)
{
    assert(gain > 1);
    for (const auto sample : pcm) {
        const double output = ApplySystemMicLevel(sample, gain);
        assert(std::isfinite(output));
        assert(std::abs(output) <= .35 * 32768 + 1e-9);
        if (std::abs(sample * gain) <= .25 * 32768) assert(output == sample * gain);
    }
}
int main(int argc, char **argv)
{
    if (argc > 1) {
        for (int index = 1; index < argc; ++index) {
            std::ifstream input(argv[index], std::ios::binary);
            assert(input.good());
            std::vector<int16_t> pcm;
            int16_t sample;
            while (input.read(reinterpret_cast<char *>(&sample), sizeof(sample))) pcm.push_back(sample);
            assert(pcm.size() % 2 == 0);
            const auto gain = Measure(pcm);
            double energy = 0;
            size_t limitedSamples = 0;
            for (const auto sample : pcm) {
                const auto output = ApplySystemMicLevel(sample, gain);
                energy += output * output;
                limitedSamples += std::abs(output - sample * gain) > 1e-6;
            }
            std::cout << argv[index] << " gain=" << gain << " dB=" << 20 * std::log10(gain)
                << " outputRmsDbFS=" << 20 * std::log10(std::sqrt(energy / pcm.size()) / 32768)
                << " softKneeSamples=" << limitedSamples << '/' << pcm.size() << '\n';
        }
        return 0;
    }
    const auto quiet = Signal(.004);
    const auto original = quiet;
    const double gain = Measure(quiet);
    assert(gain > 10 && gain < 20); // Quiet near-end reaches an audible level.
    assert(std::abs(gain - Measure(quiet, 37)) < 1e-10); // Callback/block boundaries are irrelevant.
    assert(quiet == original); // Meter never rewrites or time-stretches the raw stem.
    assert(Measure(Signal(.08)) == 1); // Normal Pura 80 Pro-like level is untouched.
    assert(Measure(Signal(0)) == 1);
    assert(Measure(Signal(.0003)) == 1); // Very faint residual echo is not normalized.
    assert(Measure(Signal(.004, false)) == 1); // Stationary noise has no credible activity contrast.
    auto transient = quiet;
    transient[2752 * 2] = 30000;
    transient[2752 * 2 + 1] = -32768;
    const auto transientOriginal = transient;
    const double transientGain = Measure(transient);
    // A short startup click, including one in only one stereo channel, cannot
    // choose the level for seconds of quiet activity. Raw PCM stays untouched.
    assert(std::abs(transientGain / gain - 1) < .01);
    assert(std::abs(transientGain - Measure(transient, 37)) < 1e-10);
    CheckBoostedSamples(transient, transientGain);
    assert(transient == transientOriginal);
    auto repeatedPeaks = quiet;
    for (size_t start : {32000, 64000, 96000}) {
        for (size_t frame = start; frame < start + 1000; ++frame) {
            repeatedPeaks[frame * 2] = 6000;
            repeatedPeaks[frame * 2 + 1] = -6000;
        }
    }
    const auto repeatedOriginal = repeatedPeaks;
    const double repeatedGain = Measure(repeatedPeaks);
    assert(repeatedGain > 1 && repeatedGain < 2);
    assert(repeatedGain < transientGain / 5); // Sustained/repeated peaks retain headroom.
    CheckBoostedSamples(repeatedPeaks, repeatedGain);
    assert(repeatedPeaks == repeatedOriginal);
    assert(Measure(std::vector<int16_t>(960 * 2, 10)) == 1); // Insufficient evidence stays at unity.

    const auto normal = Signal(.08);
    const double normalGain = Measure(normal);
    for (const auto sample : normal) assert(ApplySystemMicLevel(sample, normalGain) == sample);
    for (const auto sample : {-32768., -100., 0., 100., 32767.}) {
        assert(ApplySystemMicLevel(sample, 1) == sample);
        assert(ApplySystemMicLevel(sample, .5) == sample);
        assert(ApplySystemMicLevel(sample, 0) == sample);
    }
    double previous = 0;
    for (double sample = 0; sample <= 32768; sample += 17) {
        const double output = ApplySystemMicLevel(sample, 20);
        assert(std::isfinite(output) && output >= previous && output <= .35 * 32768);
        assert(output == -ApplySystemMicLevel(-sample, 20));
        if (sample * 20 <= .25 * 32768) assert(output == sample * 20);
        previous = output;
    }
    const double kneeInput = .25 * 32768 / 20;
    assert(ApplySystemMicLevel(kneeInput, 20) == .25 * 32768);
    assert(std::abs(ApplySystemMicLevel(kneeInput + 1e-5, 20) -
        ApplySystemMicLevel(kneeInput - 1e-5, 20) - 4e-4) < 1e-8);
    assert(std::isfinite(ApplySystemMicLevel(std::numeric_limits<double>::max(), 20)));
    assert(std::isfinite(ApplySystemMicLevel(-std::numeric_limits<double>::max(), 20)));
    for (double edit : {0., .5, 1., 2.}) {
        const float normalized = static_cast<float>(ApplySystemMicLevel(100, gain));
        const int16_t app = 12000;
        assert(MixProcessedMicSample(app, normalized, edit) == std::lround(app + normalized * edit));
        assert(MixProcessedMicSample(app, normalized, 0) == app);
    }
    std::cout << "PASS fixed AEC MIC level: quiet activity, unchanged normal/silence/noise, robust peak headroom, static soft knee, block/stereo/raw and MIC-only edit invariants\n";
}
