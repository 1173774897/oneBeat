#include "../../entry/src/main/cpp/recording_mic_level.h"
#include "../../entry/src/main/cpp/recording_audio_math.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
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
            std::cout << argv[index] << " gain=" << gain << " dB=" << 20 * std::log10(gain) << '\n';
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
    transient[12000] = 30000;
    const double capped = Measure(transient);
    assert(capped == 1); // A pre-existing loud transient prevents boosting; it is never attenuated.
    transient[12000] = 6000;
    assert(Measure(transient) * 6000 / 32768 <= .350001);
    assert(Measure(std::vector<int16_t>(960 * 2, 10)) == 1); // Insufficient evidence stays at unity.
    for (double edit : {0., .5, 1., 2.}) {
        const float normalized = static_cast<float>(100 * gain);
        const int16_t app = 12000;
        assert(MixProcessedMicSample(app, normalized, edit) == std::lround(app + normalized * edit));
        assert(MixProcessedMicSample(app, normalized, 0) == app);
    }
    std::cout << "PASS fixed AEC MIC level: quiet activity, unchanged normal/silence/noise, peak headroom, block and MIC-only edit invariants\n";
}
