#include "../../entry/src/main/cpp/recording_audio_math.h"
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <vector>
using namespace onebeat_recording;
int main()
{
    // With MIC at zero the application's full signed 16-bit range is bit exact.
    for (int sample = -32768; sample <= 32767; sample++)
        assert(MixSample(static_cast<int16_t>(sample), 21000, 0) == sample);
    assert(MixSample(6000, 4000, 1) == 10000);
    assert(MixSample(6000, 4000, 2) == 14000);
    assert(MixSample(-30000, -5000, 2) == -32768);
    assert(MixSample(30000, 5000, 2) == 32767);
    assert(MixProcessedMicSample(6000, 4000.5f, 1) == 10001);
    assert(MixProcessedMicSample(32760, -4.5f, 0) == 32760);
    assert(MixProcessedMicSample(30000, 5000.25f, 2) == 32767);
    assert(MicAfterSpeakerBleedCancel(1000, 1800, 0.72) == 1080);
    assert(MixSample(1000, 1800, 1, 0.72) == 2080);
    assert(MixSample(1000, 1800, 1, 0) == MixSample(1000, 1800, 1));
    double toneEnergy[3] = {0, 0, 0};
    for (int frame = 0; frame < SAMPLE_RATE; frame++) {
        int16_t application = static_cast<int16_t>(6000 * std::sin(2 * M_PI * 440 * frame / SAMPLE_RATE));
        int16_t microphone = static_cast<int16_t>(4000 * std::sin(2 * M_PI * 997 * frame / SAMPLE_RATE));
        for (int gain = 0; gain <= 2; gain++) {
            int16_t result = MixSample(application, microphone, gain);
            assert(std::abs(result - application - microphone * gain) <= 1);
            double micOnly = result - application;
            toneEnergy[gain] += micOnly * micOnly;
        }
    }
    assert(toneEnergy[0] == 0);
    assert(std::abs(toneEnergy[2] / toneEnergy[1] - 4.0) < 0.001);
    // A 17ms late MIC starts after 816 frames; an 11ms pre-roll is trimmed by 528.
    assert(FramesForMicroseconds(17000) == 816);
    assert(FramesForMicroseconds(-11000) == -528);
    assert(AlignedSourceFrame(2880, 60000) == 0); // +60ms delays MIC.
    assert(AlignedSourceFrame(0, -60000) == 2880); // -60ms advances MIC.
    assert(FramesForNanoseconds(20000000) == 960);
    assert(FramesForNanoseconds(3600000000000LL) == 172800000);

    // Callback timestamps may jitter, but every delivered PCM frame remains
    // contiguous. The timeline validates clocks without authoring zero/skip seams.
    ContiguousPcmTimeline pcm;
    constexpr int64_t pcmStartNs = 10000000000LL;
    assert(pcm.Append(pcmStartNs, 960));
    assert(pcm.Append(pcmStartNs + 20500000, 960));
    assert(pcm.Append(pcmStartNs + 39800000, 960));
    assert(pcm.FirstTimestampNs() == pcmStartNs);
    assert(pcm.FramesWritten() == 2880);
    assert(pcm.LastDriftFrames() == -10);
    ContiguousPcmTimeline batchedHardwareClock;
    assert(batchedHardwareClock.Append(pcmStartNs, 960));
    assert(batchedHardwareClock.Append(pcmStartNs + 120000000, 960));
    assert(batchedHardwareClock.Append(pcmStartNs + 140000000, 960));
    assert(batchedHardwareClock.FramesWritten() == 2880);
    ContiguousPcmTimeline discontinuous;
    assert(discontinuous.Append(pcmStartNs, 960));
    assert(discontinuous.Append(pcmStartNs + 800000000, 960));
    assert(discontinuous.FramesWritten() == 1920);
    ContiguousPcmTimeline gradualClockSlope;
    for (int chunk = 0; chunk < 10000; chunk++) {
        assert(gradualClockSlope.Append(pcmStartNs + chunk * 20001000LL, 960));
    }
    assert(std::abs(gradualClockSlope.LastDriftFrames()) > SAMPLE_RATE * 5 / 1000);

    // Estimate both acoustic delay and level. A fixed full-scale subtraction
    // would inject an inverted app track; a per-encoder-block delay would reset at 1024.
    constexpr int estimateFrames = 12000;
    constexpr int actualDelay = 347;
    constexpr double actualCoefficient = 0.34;
    std::vector<int16_t> inner(estimateFrames * 2);
    std::vector<int16_t> microphone(estimateFrames * 2);
    uint32_t random = 0x13579bdu;
    for (int frame = 0; frame < estimateFrames; frame++) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        const int16_t app = static_cast<int16_t>(static_cast<int>(random % 12001) - 6000);
        const int16_t voice = static_cast<int16_t>(800 * std::sin(2 * M_PI * 997 * frame / SAMPLE_RATE));
        const int16_t bleed = frame >= actualDelay ?
            static_cast<int16_t>(std::lround(inner[(frame - actualDelay) * 2] * actualCoefficient)) : 0;
        inner[frame * 2] = app;
        inner[frame * 2 + 1] = app;
        microphone[frame * 2] = static_cast<int16_t>(bleed + voice);
        microphone[frame * 2 + 1] = static_cast<int16_t>(bleed + voice);
    }
    const SpeakerBleedEstimate bleed = EstimateSpeakerBleed(inner.data(), microphone.data(),
        estimateFrames, SPEAKER_BLEED_LAG_SEARCH_MAX_FRAMES, DEFAULT_SPEAKER_BLEED_CANCEL);
    assert(bleed.delayFrames == actualDelay);
    assert(std::abs(bleed.coefficient - actualCoefficient) < 0.01);
    assert(bleed.correlation > 0.8);
    const int checkFrame = 4097;
    const int16_t expectedVoice =
        static_cast<int16_t>(800 * std::sin(2 * M_PI * 997 * checkFrame / SAMPLE_RATE));
    const int16_t cleaned = MicAfterSpeakerBleedCancelMono(
        StereoMono(inner[(checkFrame - bleed.delayFrames) * 2],
            inner[(checkFrame - bleed.delayFrames) * 2 + 1]),
        microphone[checkFrame * 2], bleed.coefficient);
    assert(std::abs(cleaned - expectedVoice) <= 2);
    assert(SpeakerReferenceOutputFrame(1023, 384) == 639);
    assert(SpeakerReferenceOutputFrame(1024, 384) == 640);

    // Rendering must be byte-identical regardless of AAC input chunking. The
    // 1536-frame case proves that a delay longer than one 1024-frame block is
    // still read from the preceding absolute output position.
    for (const int delay : {384, 1536}) {
        std::vector<int16_t> delayedMic(estimateFrames * 2);
        for (int frame = 0; frame < estimateFrames; frame++) {
            const int16_t voice =
                static_cast<int16_t>(800 * std::sin(2 * M_PI * 997 * frame / SAMPLE_RATE));
            const int16_t delayedBleed = frame >= delay ?
                static_cast<int16_t>(std::lround(inner[(frame - delay) * 2] * actualCoefficient)) : 0;
            delayedMic[frame * 2] = static_cast<int16_t>(delayedBleed + voice);
            delayedMic[frame * 2 + 1] = static_cast<int16_t>(delayedBleed + voice);
        }
        auto render = [&](int chunkFrames) {
            std::vector<int16_t> output(estimateFrames * 2);
            for (int base = 0; base < estimateFrames; base += chunkFrames) {
                const int count = std::min(chunkFrames, estimateFrames - base);
                for (int local = 0; local < count; local++) {
                    const int frame = base + local;
                    const int64_t referenceFrame = SpeakerReferenceOutputFrame(frame, delay);
                    const int32_t reference = referenceFrame >= 0 ?
                        StereoMono(inner[referenceFrame * 2], inner[referenceFrame * 2 + 1]) : 0;
                    for (int channel = 0; channel < 2; channel++) {
                        const int index = frame * 2 + channel;
                        const int16_t micSample = MicAfterSpeakerBleedCancelMono(
                            reference, delayedMic[index], actualCoefficient);
                        output[index] = MixSample(inner[index], micSample, 1);
                    }
                }
            }
            return output;
        };
        const std::vector<int16_t> chunks257 = render(257);
        const std::vector<int16_t> chunks1024 = render(1024);
        const std::vector<int16_t> chunks4096 = render(4096);
        assert(chunks257 == chunks1024);
        assert(chunks1024 == chunks4096);
        for (int frame = 0; frame < estimateFrames; frame++) {
            const int16_t voice =
                static_cast<int16_t>(800 * std::sin(2 * M_PI * 997 * frame / SAMPLE_RATE));
            for (int channel = 0; channel < 2; channel++) {
                const int index = frame * 2 + channel;
                assert(chunks1024[index] == MixSample(inner[index], voice, 1));
            }
        }
    }

    std::vector<int16_t> uncorrelated(estimateFrames * 2);
    for (int frame = 0; frame < estimateFrames; frame++) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        const int16_t sample = static_cast<int16_t>(static_cast<int>(random % 12001) - 6000);
        uncorrelated[frame * 2] = sample;
        uncorrelated[frame * 2 + 1] = sample;
    }
    assert(EstimateSpeakerBleed(inner.data(), uncorrelated.data(),
        estimateFrames, SPEAKER_BLEED_LAG_SEARCH_MAX_FRAMES,
        DEFAULT_SPEAKER_BLEED_CANCEL).coefficient == 0);

    constexpr int64_t startUs = 9123450000LL;
    constexpr int64_t firstUs = 9123456789LL;
    constexpr int64_t firstNs = firstUs * 1000;
    SurfacePtsNormalizer nanoseconds;
    nanoseconds.Reset(startUs);
    int64_t normalized = -1;
    assert(nanoseconds.Normalize(firstNs, firstUs + 50000, normalized));
    assert(nanoseconds.Divisor() == 1000 && normalized == firstUs);
    const int64_t normalizedFirst = normalized;
    // A real failure had 176 frames over about 3s, written as 3075s because
    // each Surface ns timestamp had been passed to the us muxer unchanged.
    assert(nanoseconds.Normalize(firstNs + 14997189, firstUs + 60000, normalized));
    assert(normalized - normalizedFirst == 14997);
    assert(nanoseconds.Normalize(firstNs + 3075787500LL, firstUs + 3100000, normalized));
    assert((normalized - normalizedFirst + 33333) / 1000 == 3109);
    assert((firstNs + 17000000) / 1000 - normalizedFirst == 17000);
    assert((firstNs - 11000000) / 1000 - normalizedFirst == -11000);

    SurfacePtsNormalizer microseconds;
    microseconds.Reset(startUs);
    assert(microseconds.Normalize(firstUs, firstUs + 900000, normalized));
    assert(microseconds.Divisor() == 1 && normalized == firstUs);
    assert(microseconds.Normalize(firstUs + 14997, firstUs + 950000, normalized));
    assert(normalized - firstUs == 14997); // Callback delay never becomes a media offset.
    assert(!microseconds.Normalize(firstNs + 32000000, firstUs + 1000000, normalized));
    assert(!microseconds.Normalize(firstUs + 10000, firstUs + 1000000, normalized));

    SurfacePtsNormalizer unknownOrigin;
    unknownOrigin.Reset(startUs);
    assert(!unknownOrigin.Normalize(0, firstUs + 50000, normalized));
    SurfacePtsNormalizer ambiguousUnit;
    ambiguousUnit.Reset(0);
    assert(!ambiguousUnit.Normalize(5000, 6000, normalized));
    SurfacePtsNormalizer staleVideo;
    staleVideo.Reset(startUs);
    assert(!staleVideo.Normalize(firstNs, firstUs + 11000000, normalized));
    SurfacePtsNormalizer longUptime;
    constexpr int64_t longUs = 31104000000123LL;
    longUptime.Reset(longUs - 1000);
    assert(longUptime.Normalize(longUs * 1000 + 987, longUs + 10000, normalized));
    assert(normalized == longUs && longUptime.Divisor() == 1000);

    std::cout << "PASS recording audio math: contiguous PCM, estimated cross-block speaker bleed, "
        "independent MIC gain, timestamp normalization and clock guards\n";
}
