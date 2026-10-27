#ifndef ONEBEAT_RECORDING_MIC_LEVEL_H
#define ONEBEAT_RECORDING_MIC_LEVEL_H
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace onebeat_recording {
/**
 * Some LIVE AEC implementations deliver a much quieter near-end signal than
 * others. Measure immutable PCM off the capture thread and choose ONE gain for
 * the whole take: no AGC pumping, time edits, or changes to the accompaniment.
 * This is an energy/activity guard, not a speech detector. Silence, stationary
 * noise and very faint residual echo must not be raised to normal voice level.
 */
class SystemMicLevelMeter {
public:
    void Append(const int16_t *stereo, size_t frames)
    {
        for (size_t frame = 0; frame < frames; ++frame) {
            int magnitude = 0;
            for (size_t channel = 0; channel < 2; ++channel) {
                const int pcm = stereo[frame * 2 + channel];
                const double sample = pcm / 32768.0;
                energy_ += sample * sample;
                magnitude = std::max(magnitude, std::abs(pcm));
            }
            ++peakMagnitudes_[magnitude];
            ++measuredFrames_;
            if (++windowFrames_ == WINDOW_FRAMES) {
                windows_.push_back(std::sqrt(energy_ / (2 * WINDOW_FRAMES)));
                energy_ = 0;
                windowFrames_ = 0;
            }
        }
    }

    double Gain() const
    {
        if (windows_.size() < 25) return 1;
        auto sorted = windows_;
        std::sort(sorted.begin(), sorted.end());
        const double floor = sorted[(sorted.size() - 1) / 10];
        const double active = sorted[(sorted.size() - 1) * 9 / 10];
        if (active < Db(-58) || active >= Db(-36) || active < floor * Db(10)) return 1;
        const double activityThreshold = std::max(Db(-58), floor * Db(10));
        const auto activity = std::count_if(windows_.begin(), windows_.end(),
            [activityThreshold](double rms) { return rms >= activityThreshold; });
        if (activity < 10) return 1;
        const double robustPeak = RobustPeak();
        if (robustPeak == 0) return 1;
        // Quiet takes approach -28 dBFS in active 20 ms windows. A 30 dB cap
        // limits noise lift; repeated peaks still reserve the user's 200% edit.
        return std::max(1.0, std::min({Db(-28) / active, Db(30), 0.35 / robustPeak}));
    }

private:
    static double Db(double db) { return std::pow(10.0, db / 20.0); }
    double RobustPeak() const
    {
        // One startup click must not set the loudness of the entire take. A
        // bounded PCM-magnitude histogram finds the 99.95th percentile of the
        // louder stereo channel; rare peaks are handled by a static soft knee.
        // This is one whole-take estimate, never a time-varying gain or a trim.
        const uint64_t rank = measuredFrames_ - measuredFrames_ / 2000;
        uint64_t count = 0;
        for (size_t magnitude = 0; magnitude < peakMagnitudes_.size(); ++magnitude) {
            count += peakMagnitudes_[magnitude];
            if (count >= rank) return static_cast<double>(magnitude) / 32768.0;
        }
        return 0;
    }
    static constexpr int WINDOW_FRAMES = 960; // 20 ms at the fixed 48 kHz stem rate.
    std::array<uint64_t, 32769> peakMagnitudes_{};
    uint64_t measuredFrames_ = 0;
    std::vector<double> windows_;
    double energy_ = 0;
    int windowFrames_ = 0;
};

/**
 * PCM-unit, MIC-only level correction. Normal takes remain exact; boosted takes
 * retain linear quiet samples and soften exceptional peaks below .35 FS. This
 * memoryless curve adds no latency, envelope pumping or stereo interaction.
 */
inline double ApplySystemMicLevel(double sample, double gain)
{
    if (!(gain > 1)) return sample;
    const double scaled = sample * gain;
    const double magnitude = std::abs(scaled) / 32768.0;
    if (magnitude <= 0.25) return scaled;
    const double limited = 0.25 + 0.10 * std::tanh((magnitude - 0.25) / 0.10);
    return std::copysign(limited * 32768.0, scaled);
}
}
#endif
