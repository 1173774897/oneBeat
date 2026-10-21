#ifndef ONEBEAT_RECORDING_SYSTEM_MIC_H
#define ONEBEAT_RECORDING_SYSTEM_MIC_H
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace onebeat_recording {
/**
 * OHAudio's CLOCK_MONOTONIC timestamp identifies a hardware frame, not the
 * callback payload's first sample. Lock one stream origin and retain every
 * delivered sample thereafter; batching/jitter must never insert/drop PCM.
 */
class SystemMicTimeline {
public:
    bool Anchor(int64_t framePosition, int64_t hardwareNs, int64_t observedMonoNs)
    {
        if (Known()) return true;
        if (framePosition < 0 || hardwareNs <= 0 || observedMonoNs <= 0) return false;
        constexpr int64_t SECOND = 1000000000LL;
        if (hardwareNs > observedMonoNs + SECOND || hardwareNs < observedMonoNs - 2 * SECOND) return false;
        // A newly created stream starts at frame zero. Reject another clock's
        // absolute frame counter instead of fabricating a timestamp origin.
        if (framePosition > 48000 * 10) return false;
        const int64_t origin = hardwareNs - FrameNs(framePosition);
        if (origin <= 0 || origin < observedMonoNs - 3 * SECOND || origin > observedMonoNs + SECOND) return false;
        originNs_ = origin;
        return true;
    }

    bool Known() const { return originNs_ >= 0; }
    int64_t TimestampForFrame(int64_t firstFrame) const
    {
        if (!Known() || firstFrame < 0 || firstFrame > std::numeric_limits<int64_t>::max() / 1000000000LL)
            return -1;
        return originNs_ + FrameNs(firstFrame);
    }

private:
    static int64_t FrameNs(int64_t frame) { return frame * 1000000000LL / 48000; }
    int64_t originNs_ = -1;
};

/** No resampling/gain: stereo stays byte-exact; mono is copied to both channels. */
inline bool CopySystemMicStereo(const void *input, int32_t length, int channels, std::vector<uint8_t> &out)
{
    if (input == nullptr || length <= 0 || (channels != 1 && channels != 2) ||
        length % (channels * static_cast<int>(sizeof(int16_t))) != 0) return false;
    if (channels == 2) {
        const auto *bytes = static_cast<const uint8_t *>(input);
        out.assign(bytes, bytes + length);
    } else {
        const int count = length / sizeof(int16_t);
        out.resize(static_cast<size_t>(count) * 2 * sizeof(int16_t));
        const auto *bytes = static_cast<const uint8_t *>(input);
        // memcpy keeps callbacks safe even when a platform buffer is unaligned.
        for (int index = 0; index < count; index++) {
            std::memcpy(out.data() + index * 4, bytes + index * 2, 2);
            std::memcpy(out.data() + index * 4 + 2, bytes + index * 2, 2);
        }
    }
    return true;
}
}
#endif
