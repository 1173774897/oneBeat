#include "../../entry/src/main/cpp/recording_system_mic.h"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
using namespace onebeat_recording;
int main()
{
    SystemMicTimeline timeline;
    constexpr int64_t nowNs = 123456000000000LL;
    assert(!timeline.Anchor(0, 0, nowNs));
    assert(!timeline.Anchor(-1, nowNs, nowNs));
    assert(!timeline.Anchor(0, nowNs / 1000, nowNs)); // us must not be accepted as ns.
    assert(!timeline.Anchor(480001, nowNs, nowNs));
    assert(!timeline.Anchor(0, nowNs + 2000000000LL, nowNs));
    assert(!timeline.Known());
    assert(timeline.TimestampForFrame(0) == -1);
    assert(timeline.Anchor(4800, nowNs - 1000000LL, nowNs));
    assert(timeline.TimestampForFrame(0) == nowNs - 101000000LL);
    assert(timeline.TimestampForFrame(960) - timeline.TimestampForFrame(0) == 20000000);
    // Later noisy hardware observations never edit the already locked origin.
    assert(timeline.Anchor(9600, nowNs + 55000000LL, nowNs + 60000000LL));
    assert(timeline.TimestampForFrame(4800) == nowNs - 1000000LL);
    assert(timeline.TimestampForFrame(-1) == -1);
    std::vector<uint8_t> converted;
    const int16_t mono[] = {-32768, -1, 0, 1, 32767};
    assert(CopySystemMicStereo(mono, sizeof(mono), 1, converted));
    assert(converted.size() == sizeof(mono) * 2);
    for (int index = 0; index < 5; index++) {
        int16_t left, right;
        std::memcpy(&left, converted.data() + index * 4, 2);
        std::memcpy(&right, converted.data() + index * 4 + 2, 2);
        assert(left == mono[index] && right == mono[index]);
    }
    const uint8_t stereo[] = {0, 128, 255, 127, 1, 0, 255, 255};
    assert(CopySystemMicStereo(stereo, sizeof(stereo), 2, converted));
    assert(converted == std::vector<uint8_t>(stereo, stereo + sizeof(stereo)));
    assert(!CopySystemMicStereo(stereo, 3, 2, converted));
    assert(!CopySystemMicStereo(stereo, 8, 3, converted));
    assert(!CopySystemMicStereo(nullptr, 4, 2, converted));
    std::cout << "recording system MIC timeline/conversion passed\n";
}
