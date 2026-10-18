#include "../../entry/src/main/cpp/recording_audio_math.h"
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
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
    assert(FramesForNanoseconds(20000000) == 960);
    assert(FramesForNanoseconds(3600000000000LL) == 172800000);

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

    std::cout << "PASS recording audio math: independent MIC gain, Surface ns/us normalization, preserved offsets, clock guards and long uptime\n";
}
