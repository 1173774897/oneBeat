#include "../../entry/src/main/cpp/recording_echo_filter.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <vector>

using namespace onebeat_recording;

namespace {
int16_t Limit(double value)
{
    return static_cast<int16_t>(std::clamp(std::lround(value), -32768L, 32767L));
}

double Rms(const std::vector<double> &samples)
{
    double sum = 0;
    for (double value : samples) sum += value * value;
    return std::sqrt(sum / samples.size());
}

void SignedStereoAndExternalSound()
{
    constexpr int frames = 48000 * 2;
    constexpr int leftDelay = -7341;
    constexpr int rightDelay = 3167;
    std::mt19937 generator(132714);
    std::uniform_int_distribution<int> appNoise(-4000, 4000), outsideNoise(-1800, 1800);
    std::vector<int16_t> app(frames * 2), mic(frames * 2), external(frames * 2);
    for (int frame = 0; frame < frames; ++frame) {
        app[frame * 2] = static_cast<int16_t>(appNoise(generator));
        app[frame * 2 + 1] = static_cast<int16_t>(appNoise(generator));
        external[frame * 2] = static_cast<int16_t>(outsideNoise(generator));
        external[frame * 2 + 1] = static_cast<int16_t>(outsideNoise(generator));
    }
    for (int frame = 0; frame < frames; ++frame) {
        for (int channel = 0; channel < 2; ++channel) {
            const int delay = channel == 0 ? leftDelay : rightDelay;
            const int source = frame - delay;
            const int16_t reference = source >= 0 && source < frames ? app[source * 2 + channel] : 0;
            mic[frame * 2 + channel] = Limit(external[frame * 2 + channel] + reference *
                (channel == 0 ? 1.45 : 0.65));
        }
    }
    const auto fit = EstimateStereoEcho(app.data(), mic.data(), frames);
    assert(fit.channels[0].enabled && fit.channels[1].enabled);
    assert(fit.channels[0].delayFrames == leftDelay);
    assert(fit.channels[1].delayFrames == rightDelay);
    assert(std::abs(fit.channels[0].coefficient - 1.45) < 0.02);
    assert(std::abs(fit.channels[1].coefficient - 0.65) < 0.02);
    for (int channel = 0; channel < 2; ++channel) {
        std::vector<double> before, after;
        for (int frame = 14400; frame < frames - 14400; ++frame) {
            const auto source = EchoReferenceFrame(frame, fit.channels[channel].delayFrames);
            const int16_t reference = app[source * 2 + channel];
            const double cleaned = SuppressEchoSample(mic[frame * 2 + channel], reference,
                fit.channels[channel]);
            before.push_back(mic[frame * 2 + channel] - external[frame * 2 + channel]);
            after.push_back(cleaned - external[frame * 2 + channel]);
        }
        // Independent external audio survives, rather than being gated with
        // the entire microphone during each internal metronome hit.
        assert(Rms(after) < Rms(before) * 0.04);
    }
}

void UnrelatedMicAndQuietRightChannel()
{
    constexpr int frames = 48000 * 2;
    std::mt19937 generator(668772);
    std::uniform_int_distribution<int> noise(-4000, 4000);
    std::vector<int16_t> app(frames * 2), mic(frames * 2);
    for (int frame = 0; frame < frames; ++frame) {
        app[frame * 2] = app[frame * 2 + 1] = static_cast<int16_t>(noise(generator));
        mic[frame * 2] = static_cast<int16_t>(noise(generator));
        mic[frame * 2 + 1] = static_cast<int16_t>(noise(generator) / 50);
    }
    const auto fit = EstimateStereoEcho(app.data(), mic.data(), frames);
    for (int channel = 0; channel < 2; ++channel) {
        assert(!fit.channels[channel].enabled);
        for (int frame = 0; frame < frames; ++frame)
            assert(SuppressEchoSample(mic[frame * 2 + channel], app[frame * 2 + channel],
                fit.channels[channel]) == mic[frame * 2 + channel]);
    }
    // A repeatable echo in one physical channel cannot authorize subtraction
    // in the other channel, which may contain only quiet environmental sound.
    for (int frame = 0; frame < frames; ++frame) mic[frame * 2] = app[frame * 2];
    const auto onlyLeft = EstimateStereoEcho(app.data(), mic.data(), frames);
    assert(onlyLeft.channels[0].enabled);
    assert(!onlyLeft.channels[1].enabled);
}

void DoubleTalkAndLimits()
{
    constexpr int frames = 48000 * 2;
    std::mt19937 generator(412321);
    std::uniform_int_distribution<int> appNoise(-500, 500), outsideNoise(-7000, 7000);
    std::vector<int16_t> app(frames * 2), mic(frames * 2);
    for (int index = 0; index < frames * 2; ++index) {
        app[index] = static_cast<int16_t>(appNoise(generator));
        mic[index] = static_cast<int16_t>(outsideNoise(generator) + app[index]);
    }
    const auto fit = EstimateStereoEcho(app.data(), mic.data(), frames);
    assert(!fit.channels[0].enabled && !fit.channels[1].enabled);
    assert(!EstimateStereoEcho(nullptr, mic.data(), frames).channels[0].enabled);
    assert(!EstimateStereoEcho(app.data(), mic.data(), 2399).channels[0].enabled);
    assert(!EstimateStereoEcho(app.data(), mic.data(), frames, -1).channels[0].enabled);
    assert(!EstimateStereoEcho(app.data(), mic.data(), frames, 14400, 5).channels[0].enabled);
    assert(EchoReferenceFrame(0, -7341) == 7341);
    assert(EchoReferenceFrame(0, 7341) == -7341);
    assert(EchoReferenceFrame(INT64_MAX, -1) == INT64_MAX);
    EchoChannelEstimate wide;
    wide.enabled = true;
    wide.coefficient = 2;
    assert(SuppressEchoSample(30000, -30000, wide) == 90000);
    const int appSample = 12345;
    const double gain = 0;
    assert(Limit(appSample + gain * SuppressEchoSample(30000, -30000, wide)) == appSample);
}

void FrequencyResponseAndExternalSound()
{
    constexpr int frames = 76800;
    constexpr int delay = -7341;
    std::mt19937 generator(421055);
    std::uniform_int_distribution<int> appNoise(-5000, 5000), outsideNoise(-1200, 1200);
    std::vector<int16_t> app(frames * 2), mic(frames * 2), external(frames * 2);
    for (int index = 0; index < frames * 2; ++index) {
        app[index] = static_cast<int16_t>(appNoise(generator));
        external[index] = static_cast<int16_t>(outsideNoise(generator));
    }
    for (int frame = 0; frame < frames; ++frame) {
        auto reference = [&](int extraDelay) {
            const int source = frame - delay - extraDelay;
            return source >= 0 && source < frames ? app[source * 2] : 0;
        };
        mic[frame * 2] = Limit(external[frame * 2] + 1.3 * reference(0) +
            0.4 * reference(17) - 0.2 * reference(47));
        mic[frame * 2 + 1] = external[frame * 2 + 1];
    }
    const auto fit = EstimateStereoEchoFir(app.data(), mic.data(), frames);
    assert(fit.channels[0].enabled);
    assert(fit.channels[0].validationReduction > 0.7);
    assert(!fit.channels[1].enabled);
    std::vector<double> before, after;
    for (int frame = 15000; frame < frames - 15000; ++frame) {
        const auto first = EchoFirReferenceFirstFrame(frame, fit.channels[0].delayFrames);
        assert(first >= 0 && first + ECHO_FIR_TAPS <= frames);
        const double prediction = PredictEchoFirSample(app.data() + first * 2, 0, fit.channels[0]);
        before.push_back(mic[frame * 2] - external[frame * 2]);
        after.push_back(mic[frame * 2] - prediction - external[frame * 2]);
        assert(PredictEchoFirSample(app.data() + first * 2, 1, fit.channels[1]) == 0);
    }
    assert(Rms(after) < Rms(before) * 0.15);
    const auto invalid = EstimateStereoEchoFir(app.data(), mic.data(), 96001);
    assert(!invalid.channels[0].enabled && !invalid.channels[1].enabled);

    // Replacing the near-end signal with unrelated, dominant sound must not
    // authorize a filter simply because the reference contains loud beats.
    std::uniform_int_distribution<int> loudOutside(-16000, 16000);
    for (int index = 0; index < frames * 2; ++index) mic[index] = static_cast<int16_t>(loudOutside(generator));
    const auto unrelated = EstimateStereoEchoFir(app.data(), mic.data(), frames);
    assert(!unrelated.channels[0].enabled && !unrelated.channels[1].enabled);
    EchoFirChannelEstimate wide;
    wide.enabled = true;
    wide.taps[0] = -2;
    std::array<int16_t, ECHO_FIR_TAPS * 2> references{};
    references[references.size() - 2] = 30000;
    assert(PredictEchoFirSample(references.data(), 0, wide) == -60000);
    assert(MixEchoFirSample(12345, 30000, 0, PredictEchoFirSample(references.data(), 0, wide)) == 12345);
    assert(MixEchoFirSample(-30000, -30000, 0, std::numeric_limits<double>::quiet_NaN()) == -30000);
    assert(MixEchoFirSample(20000, 30000, 1, -30000) == 32767);
    assert(MixEchoFirSample(-20000, -30000, 1, 30000) == -32768);
    assert(MixEchoFirSample(10000, 30000, .5, 20000) == 15000);
}

void HeldOutGainCannotOverCancel()
{
    constexpr int frames = 76800;
    constexpr int delay = 1200;
    std::mt19937 generator(507211);
    std::uniform_int_distribution<int> referenceNoise(-5000, 5000), outsideNoise(-120, 120);
    std::vector<int16_t> app(frames * 2), mic(frames * 2);
    for (auto &sample : app) sample = static_cast<int16_t>(referenceNoise(generator));
    for (int frame = 0; frame < frames; ++frame) {
        const int source = frame - delay;
        const double pathGain = ((frame / 480) & 1) == 0 ? 1.0 : 0.65;
        for (int channel = 0; channel < 2; ++channel) {
            const double echo = source >= 0 ? app[source * 2 + channel] * pathGain : 0;
            mic[frame * 2 + channel] = Limit(echo + outsideNoise(generator));
        }
    }
    const auto fit = EstimateStereoEchoFir(app.data(), mic.data(), frames);
    for (int channel = 0; channel < 2; ++channel) {
        const auto &model = fit.channels[channel];
        assert(model.enabled);
        assert(std::abs(model.delayFrames - delay) <= 48);
        assert(model.appliedScale > 0.55 && model.appliedScale < 0.70);
        double predictionEnergy = 0, residualProduct = 0;
        for (int frame = 15000; frame < frames - 15000; ++frame) {
            if (((frame / 480) & 1) == 0) continue;
            const auto first = EchoFirReferenceFirstFrame(frame, model.delayFrames);
            const double prediction = PredictEchoFirSample(app.data() + first * 2, channel, model);
            const double residual = mic[frame * 2 + channel] - prediction;
            predictionEnergy += prediction * prediction;
            residualProduct += residual * prediction;
        }
        // A non-negative projection means validation retains a small real echo;
        // it never crosses through zero into the audible inverse tail.
        assert(predictionEnergy > 0 && residualProduct / predictionEnergy >= -0.01);
    }
    for (int frame = 0; frame < frames; ++frame) {
        const int source = frame - delay;
        const double pathGain = ((frame / 480) & 1) == 0 ? 1.0 : 0.01;
        for (int channel = 0; channel < 2; ++channel) {
            const double echo = source >= 0 ? app[source * 2 + channel] * pathGain : 0;
            mic[frame * 2 + channel] = Limit(echo);
        }
    }
    const auto unsafeMinimum = EstimateStereoEchoFir(app.data(), mic.data(), frames);
    assert(!unsafeMinimum.channels[0].enabled && !unsafeMinimum.channels[1].enabled);
}

void TonalEnvelopeDelayIsStable()
{
    constexpr int frames = 76800;
    constexpr int delay = 2400;
    std::array<int, 2> delays{};
    for (int tone = 0; tone < 2; ++tone) {
        const double frequency = tone == 0 ? 660.0 : 880.0;
        std::vector<int16_t> app(frames * 2), mic(frames * 2);
        for (int onset = 4800; onset < frames - 6000; onset += 24000) {
            for (int sample = 0; sample < 5760; ++sample) {
                const double time = sample / 48000.0;
                const double envelope = (std::exp(-80 * time) + .35 * std::exp(-16 * time)) / 1.35;
                const int16_t value = Limit(std::sin(2 * M_PI * frequency * time) * 12000 * envelope);
                app[(onset + sample) * 2] = value;
                app[(onset + sample) * 2 + 1] = value;
            }
        }
        for (int frame = delay; frame < frames; ++frame) {
            mic[frame * 2] = Limit(app[(frame - delay) * 2] * .45);
            mic[frame * 2 + 1] = Limit(app[(frame - delay) * 2 + 1] * .30);
        }
        const auto fit = EstimateStereoEchoFir(app.data(), mic.data(), frames);
        assert(fit.channels[0].enabled && fit.channels[1].enabled);
        delays[tone] = fit.channels[0].delayFrames;
        assert(std::abs(delays[tone] - delay) <= 48);
    }
    assert(std::abs(delays[0] - delays[1]) <= 48);
}

void InvertedBroadbandAndOppositePolarities()
{
    constexpr int frames = 76800;
    constexpr int delays[2] = {-7341, 5307};
    constexpr double gains[2] = {-1.35, 0.7};
    std::mt19937 generator(812334);
    std::uniform_int_distribution<int> appNoise(-6000, 6000), externalNoise(-900, 900);
    std::vector<int16_t> app(frames * 2), mic(frames * 2), external(frames * 2);
    for (int index = 0; index < frames * 2; ++index) {
        app[index] = static_cast<int16_t>(appNoise(generator));
        external[index] = static_cast<int16_t>(externalNoise(generator));
    }
    for (int frame = 0; frame < frames; ++frame) {
        for (int channel = 0; channel < 2; ++channel) {
            const int source = frame - delays[channel];
            const double echo = source >= 0 && source < frames ? app[source * 2 + channel] * gains[channel] : 0;
            mic[frame * 2 + channel] = Limit(external[frame * 2 + channel] + echo);
        }
    }
    // This is broadband, so a half-period shift cannot disguise inversion as
    // a nearby positive peak, as it can for a single metronome tone.
    const auto scalar = EstimateStereoEcho(app.data(), mic.data(), frames);
    assert(!scalar.channels[0].enabled);
    for (int polarity : {1, -1}) {
        std::vector<int16_t> observed = mic;
        if (polarity < 0) for (auto &sample : observed) sample = static_cast<int16_t>(-sample);
        const auto fit = EstimateStereoEchoFir(app.data(), observed.data(), frames);
        for (int channel = 0; channel < 2; ++channel) {
            const auto &model = fit.channels[channel];
            assert(model.enabled && model.validationReduction > 0.8);
            assert(std::abs(model.delayFrames - delays[channel]) < ECHO_FIR_TAPS / 2);
            std::vector<double> before, after;
            for (int frame = 15000; frame < frames - 15000; ++frame) {
                const auto first = EchoFirReferenceFirstFrame(frame, model.delayFrames);
                const double outside = external[frame * 2 + channel] * polarity;
                const double input = observed[frame * 2 + channel];
                const double prediction = PredictEchoFirSample(app.data() + first * 2, channel, model);
                before.push_back(input - outside);
                after.push_back(input - prediction - outside);
            }
            assert(Rms(after) < Rms(before) * 0.15);
        }
    }
}

void ProvenFilterDuringDoubleTalk()
{
    constexpr int frames = 76800;
    constexpr int delays[2] = {-7341, 3167};
    constexpr double gains[2] = {1.2, -0.9};
    std::mt19937 generator(198207);
    std::uniform_int_distribution<int> appNoise(-4000, 4000), quietOutside(-150, 150),
        loudOutside(-18000, 18000);
    std::vector<int16_t> app(frames * 2), reliableMic(frames * 2), observed(frames * 2), external(frames * 2);
    for (auto &sample : app) sample = static_cast<int16_t>(appNoise(generator));
    auto echo = [&](int frame, int channel, int extraDelay = 0) {
        const int source = frame - delays[channel] - extraDelay;
        return source >= 0 && source < frames ? app[source * 2 + channel] * gains[channel] : 0.0;
    };
    for (int frame = 0; frame < frames; ++frame) {
        for (int channel = 0; channel < 2; ++channel) {
            reliableMic[frame * 2 + channel] = Limit(echo(frame, channel) + quietOutside(generator));
            external[frame * 2 + channel] = static_cast<int16_t>(loudOutside(generator));
            observed[frame * 2 + channel] = Limit(.7 * echo(frame, channel) + external[frame * 2 + channel]);
        }
    }
    const auto reliable = EstimateStereoEchoFir(app.data(), reliableMic.data(), frames);
    const auto fresh = EstimateStereoEchoFir(app.data(), observed.data(), frames);
    for (int channel = 0; channel < 2; ++channel) {
        assert(reliable.channels[channel].enabled);
        assert(!reliable.channels[channel].revalidated);
        const auto strongFallback = RevalidateEchoFir(reliable.channels[channel], app.data(),
            reliableMic.data(), frames, channel);
        assert(strongFallback.enabled && strongFallback.revalidated);
        assert(strongFallback.trainingReduction > .12 && strongFallback.validationReduction > .12 &&
            strongFallback.validationCorrelation > .45);
        assert(!RevalidateEchoFir(strongFallback, app.data(), reliableMic.data(), frames, channel).enabled);
        assert(!fresh.channels[channel].enabled);
        const auto fallback = RevalidateEchoFir(reliable.channels[channel], app.data(), observed.data(), frames, channel);
        assert(fallback.enabled && fallback.revalidated && fallback.validationReduction < .12);
        assert(!RevalidateEchoFir(fallback, app.data(), observed.data(), frames, channel).enabled);
        std::vector<double> before, after, preservedExternal, cleaned;
        for (int frame = 15000; frame < frames - 15000; ++frame) {
            const auto first = EchoFirReferenceFirstFrame(frame, fallback.delayFrames);
            const int index = frame * 2 + channel;
            const double prediction = PredictEchoFirSample(app.data() + first * 2, channel, fallback);
            const double residual = observed[index] - prediction;
            before.push_back(observed[index] - external[index]);
            after.push_back(residual - external[index]);
            preservedExternal.push_back(external[index]);
            cleaned.push_back(residual);
        }
        assert(Rms(after) < Rms(before) * .15);
        assert(Rms(cleaned) > Rms(preservedExternal) * .95);
        assert(Rms(cleaned) < Rms(preservedExternal) * 1.05);
        assert(!RevalidateEchoFir(reliable.channels[channel], app.data(), observed.data(), 16000, channel).enabled);
    }
    for (int scenario = 0; scenario < 4; ++scenario) {
        for (int frame = 0; frame < frames; ++frame) {
            for (int channel = 0; channel < 2; ++channel) {
                double changedEcho = 0;
                if (scenario == 1) changedEcho = -.7 * echo(frame, channel);
                if (scenario == 2) changedEcho = .7 * echo(frame, channel, 2048);
                if (scenario == 3) changedEcho = (((frame / 480) & 1) == 0 ? .7 : -.7) * echo(frame, channel);
                observed[frame * 2 + channel] = Limit(changedEcho + loudOutside(generator));
            }
        }
        for (int channel = 0; channel < 2; ++channel)
            assert(!RevalidateEchoFir(reliable.channels[channel], app.data(), observed.data(), frames, channel).enabled);
    }
}

std::vector<int16_t> RenderClampedPlan(const std::vector<int16_t> &app,
    const std::vector<int16_t> &mic, const std::vector<StereoEchoFirEstimate> &models, int blockFrames)
{
    const int totalFrames = static_cast<int>(app.size() / 2);
    std::vector<int16_t> output(app.size());
    for (int position = 0; position < totalFrames; position += blockFrames) {
        const int frames = std::min(blockFrames, totalFrames - position);
        int processed = 0;
        while (processed < frames) {
            const int absolute = position + processed;
            const int anchor = absolute / 48000;
            const int count = std::min(frames - processed, 48000 - absolute % 48000);
            std::array<std::array<std::vector<int16_t>, 2>, 2> references;
            for (int side = 0; side < 2; ++side) {
                for (int channel = 0; channel < 2; ++channel) {
                    const auto &model = models[anchor + side].channels[channel];
                    if (!model.enabled) continue;
                    auto &reference = references[side][channel];
                    reference.resize((count + ECHO_FIR_TAPS - 1) * 2, 0);
                    const auto first = EchoFirReferenceFirstFrame(absolute, model.delayFrames);
                    for (int frame = 0; frame < count + ECHO_FIR_TAPS - 1; ++frame) {
                        const auto source = first + frame;
                        if (source >= 0 && source < totalFrames) {
                            reference[frame * 2] = app[source * 2];
                            reference[frame * 2 + 1] = app[source * 2 + 1];
                        }
                    }
                }
            }
            for (int frame = 0; frame < count; ++frame) {
                const double blend = (absolute + frame - anchor * 48000) / 48000.0;
                for (int channel = 0; channel < 2; ++channel) {
                    double echo[2]{};
                    for (int side = 0; side < 2; ++side) {
                        const auto &model = models[anchor + side].channels[channel];
                        if (model.enabled) echo[side] = PredictEchoFirSample(
                            references[side][channel].data() + frame * 2, channel, model);
                    }
                    const int index = (absolute + frame) * 2 + channel;
                    output[index] = MixEchoFirSample(app[index], mic[index], .75,
                        echo[0] * (1 - blend) + echo[1] * blend);
                }
            }
            processed += count;
        }
    }
    return output;
}

void BoundariesAndChunkInvariance()
{
    constexpr int frames = 48000 * 2 + 257;
    constexpr int probeFrames = 76800;
    std::mt19937 generator(611045);
    std::uniform_int_distribution<int> noise(-5000, 5000);
    std::vector<int16_t> app(frames * 2), mic(frames * 2);
    for (int index = 0; index < frames * 2; ++index) app[index] = static_cast<int16_t>(noise(generator));
    for (int frame = 0; frame < frames; ++frame) {
        const int source = frame + 7341;
        mic[frame * 2] = source < frames ? Limit(app[source * 2] * 1.4) : 0;
        mic[frame * 2 + 1] = static_cast<int16_t>(noise(generator) / 10);
    }
    std::vector<StereoEchoFirEstimate> models;
    for (int anchor = 0; anchor <= 3; ++anchor) {
        const int start = std::clamp(anchor * 48000 - probeFrames / 2, 0, frames - probeFrames);
        assert(start >= 0 && start + probeFrames <= frames);
        models.push_back(EstimateStereoEchoFir(app.data() + start * 2, mic.data() + start * 2, probeFrames));
    }
    assert(models.front().channels[0].enabled && models.back().channels[0].enabled);
    const auto expected = RenderClampedPlan(app, mic, models, 257);
    assert(RenderClampedPlan(app, mic, models, 1024) == expected);
    assert(RenderClampedPlan(app, mic, models, 4096) == expected);
    // A sub-probe recording uses its true length; no fabricated trailing
    // silence participates in fitting or changes the capture timeline.
    const int shortFrames = 16000;
    const int count = std::min(probeFrames, shortFrames);
    const int start = std::clamp(48000 - probeFrames / 2, 0, std::max(0, shortFrames - probeFrames));
    assert(start == 0 && count == shortFrames);
    const auto shortFit = EstimateStereoEchoFir(app.data(), mic.data(), count);
    for (const auto &channel : shortFit.channels) assert(std::isfinite(channel.validationReduction));
}

std::vector<int16_t> Read(const char *path)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    assert(file.good());
    const auto bytes = file.tellg();
    assert(bytes > 0 && static_cast<int64_t>(bytes) % 4 == 0);
    std::vector<int16_t> samples(static_cast<size_t>(bytes) / 2);
    file.seekg(0);
    file.read(reinterpret_cast<char *>(samples.data()), bytes);
    assert(file.good());
    return samples;
}

void InspectDeviceFixture(const char *innerPath, const char *micPath)
{
    const auto inner = Read(innerPath), mic = Read(micPath);
    constexpr int frames = 445824; // 9.288 s fixture, not an application constant.
    constexpr int innerStart = 11208, micStart = 724;
    std::vector<int16_t> alignedInner(frames * 2), alignedMic(frames * 2);
    std::copy_n(inner.begin(), std::min(inner.size(), alignedInner.size() - innerStart * 2),
        alignedInner.begin() + innerStart * 2);
    std::copy_n(mic.begin(), std::min(mic.size(), alignedMic.size() - micStart * 2),
        alignedMic.begin() + micStart * 2);
    const auto fit = EstimateStereoEcho(alignedInner.data(), alignedMic.data(), frames);
    for (int channel = 0; channel < 2; ++channel) {
        const auto &estimate = fit.channels[channel];
        std::vector<double> before, after;
        double referenceSquare = 0, beforeProduct = 0, afterProduct = 0;
        for (int frame = 14400; frame < frames - 14400; ++frame) {
            const auto source = EchoReferenceFrame(frame, estimate.delayFrames);
            const int16_t reference = alignedInner[source * 2 + channel];
            const int16_t sample = alignedMic[frame * 2 + channel];
            const double cleaned = SuppressEchoSample(sample, reference, estimate);
            before.push_back(sample);
            after.push_back(cleaned);
            referenceSquare += static_cast<double>(reference) * reference;
            beforeProduct += static_cast<double>(sample) * reference;
            afterProduct += cleaned * reference;
        }
        std::cout << "DEVICE channel=" << channel << " enabled=" << estimate.enabled <<
            " lagMs=" << estimate.delayFrames / 48.0 << " gain=" << estimate.coefficient <<
            " correlation=" << estimate.correlation << " validation=" << estimate.validationCorrelation <<
            " rmsBefore=" << Rms(before) << " rmsAfter=" << Rms(after) << " reductionDb=" <<
            20 * std::log10(Rms(before) / Rms(after)) << " coherentBefore=" << beforeProduct / referenceSquare <<
            " coherentAfter=" << afterProduct / referenceSquare << '\n';
    }
    constexpr int probeFrames = 76800;
    std::vector<StereoEchoEstimate> local;
    for (int center = 0; center <= 10; ++center) {
        const int first = center * 48000 - probeFrames / 2;
        std::vector<int16_t> probeInner(probeFrames * 2), probeMic(probeFrames * 2);
        for (int frame = 0; frame < probeFrames; ++frame) {
            const int source = first + frame;
            if (source < 0 || source >= frames) continue;
            for (int channel = 0; channel < 2; ++channel) {
                probeInner[frame * 2 + channel] = alignedInner[source * 2 + channel];
                probeMic[frame * 2 + channel] = alignedMic[source * 2 + channel];
            }
        }
        local.push_back(EstimateStereoEcho(probeInner.data(), probeMic.data(), probeFrames));
        const auto &left = local.back().channels[0];
        const auto &right = local.back().channels[1];
        std::cout << "WINDOW second=" << center << " left=" << left.enabled << " lagMs=" <<
            left.delayFrames / 48.0 << " gain=" << left.coefficient << " corr=" << left.correlation <<
            " validation=" << left.validationCorrelation << " right=" << right.enabled << '\n';
    }
    for (int channel = 0; channel < 2; ++channel) {
        std::vector<double> before, after;
        double referenceSquare = 0, beforeProduct = 0, afterProduct = 0;
        for (int frame = 0; frame < frames; ++frame) {
            const int second = frame / 48000;
            const double blend = (frame % 48000) / 48000.0;
            auto contribution = [&](int window) {
                const auto &estimate = local[window].channels[channel];
                const auto source = EchoReferenceFrame(frame, estimate.delayFrames);
                if (!estimate.enabled || source < 0 || source >= frames) return 0.0;
                return alignedInner[source * 2 + channel] * estimate.coefficient;
            };
            const double sample = alignedMic[frame * 2 + channel];
            const double cleaned = sample - contribution(second) * (1 - blend) -
                contribution(second + 1) * blend;
            before.push_back(sample);
            after.push_back(cleaned);
            const auto referenceFrame = EchoReferenceFrame(frame, -7325);
            if (referenceFrame >= 0 && referenceFrame < frames) {
                const double reference = alignedInner[referenceFrame * 2 + channel];
                referenceSquare += reference * reference;
                beforeProduct += sample * reference;
                afterProduct += cleaned * reference;
            }
        }
        std::cout << "WINDOWED channel=" << channel << " rmsBefore=" << Rms(before) <<
            " rmsAfter=" << Rms(after) << " reductionDb=" << 20 * std::log10(Rms(before) / Rms(after)) <<
            " coherentBefore=" << beforeProduct / referenceSquare << " coherentAfter=" <<
            afterProduct / referenceSquare << '\n';
    }
    const auto fitStarted = std::chrono::steady_clock::now();
    std::vector<StereoEchoFirEstimate> firLocal;
    for (int center = 0; center <= 10; ++center) {
        const int first = std::clamp(center * 48000 - probeFrames / 2, 0, frames - probeFrames);
        std::vector<int16_t> probeInner(probeFrames * 2), probeMic(probeFrames * 2);
        for (int frame = 0; frame < probeFrames; ++frame) {
            const int source = first + frame;
            if (source < 0 || source >= frames) continue;
            for (int channel = 0; channel < 2; ++channel) {
                probeInner[frame * 2 + channel] = alignedInner[source * 2 + channel];
                probeMic[frame * 2 + channel] = alignedMic[source * 2 + channel];
            }
        }
        firLocal.push_back(EstimateStereoEchoFir(probeInner.data(), probeMic.data(), probeFrames));
        const auto &left = firLocal.back().channels[0];
        const auto &right = firLocal.back().channels[1];
        std::cout << "FIR_WINDOW second=" << center << " left=" << left.enabled << " lagMs=" <<
            left.delayFrames / 48.0 << " reduction=" << left.validationReduction << " corr=" <<
            left.validationCorrelation << " right=" << right.enabled << '\n';
    }
    std::cout << "FIR_FIT_HOST_MS=" << std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - fitStarted).count() << '\n';
    for (int channel = 0; channel < 2; ++channel) {
        std::vector<double> before, after;
        double referenceSquare = 0, beforeProduct = 0, afterProduct = 0;
        for (int frame = 0; frame < frames; ++frame) {
            const int second = frame / 48000;
            const double blend = (frame % 48000) / 48000.0;
            auto contribution = [&](int window) {
                const auto &estimate = firLocal[window].channels[channel];
                const auto first = EchoFirReferenceFirstFrame(frame, estimate.delayFrames);
                if (!estimate.enabled || first < 0 || first + ECHO_FIR_TAPS > frames) return 0.0;
                return PredictEchoFirSample(alignedInner.data() + first * 2, channel, estimate);
            };
            const double sample = alignedMic[frame * 2 + channel];
            const double cleaned = sample - contribution(second) * (1 - blend) -
                contribution(second + 1) * blend;
            before.push_back(sample);
            after.push_back(cleaned);
            const auto referenceFrame = EchoReferenceFrame(frame, -7325);
            if (referenceFrame >= 0 && referenceFrame < frames) {
                const double reference = alignedInner[referenceFrame * 2 + channel];
                referenceSquare += reference * reference;
                beforeProduct += sample * reference;
                afterProduct += cleaned * reference;
            }
        }
        std::cout << "FIR_SUMMARY channel=" << channel << " rmsBefore=" << Rms(before) <<
            " rmsAfter=" << Rms(after) << " reductionDb=" << 20 * std::log10(Rms(before) / Rms(after)) <<
            " coherentBefore=" << beforeProduct / referenceSquare << " coherentAfter=" <<
            afterProduct / referenceSquare << " coherentReductionDb=" <<
            20 * std::log10(std::abs(beforeProduct) / std::abs(afterProduct)) << '\n';
    }
}
}

int main(int argc, char **argv)
{
    SignedStereoAndExternalSound();
    UnrelatedMicAndQuietRightChannel();
    DoubleTalkAndLimits();
    FrequencyResponseAndExternalSound();
    HeldOutGainCannotOverCancel();
    TonalEnvelopeDelayIsStable();
    InvertedBroadbandAndOppositePolarities();
    ProvenFilterDuringDoubleTalk();
    BoundariesAndChunkInvariance();
    if (argc == 3) InspectDeviceFixture(argv[1], argv[2]);
    std::cout << "PASS signed per-channel echo estimation, external sound and single final limiter\n";
}
