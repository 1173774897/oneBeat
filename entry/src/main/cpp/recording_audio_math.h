#ifndef ONEBEAT_RECORDING_AUDIO_MATH_H
#define ONEBEAT_RECORDING_AUDIO_MATH_H
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
namespace onebeat_recording {
constexpr int SAMPLE_RATE = 48000;

/** Surface encoders may preserve ns instead of the generic AVCodec us contract. */
class SurfacePtsNormalizer {
public:
    void Reset(int64_t captureStartMonoUs)
    {
        startUs_ = captureStartMonoUs;
        divisor_ = 0;
        previousUs_ = -1;
    }

    bool Normalize(int64_t rawPts, int64_t observedMonoUs, int64_t &ptsUs)
    {
        if (rawPts < 0 || startUs_ < 0 || observedMonoUs < startUs_) return false;
        if (divisor_ == 0) {
            const bool isUs = InCaptureWindow(rawPts, observedMonoUs);
            const bool isNs = InCaptureWindow(rawPts / 1000, observedMonoUs);
            // Arrival time only distinguishes units. It never replaces a
            // media timestamp or independently zeroes an audio/video track.
            if (isUs == isNs) return false;
            divisor_ = isNs ? 1000 : 1;
        }
        const int64_t normalized = rawPts / divisor_;
        if (!InCaptureWindow(normalized, observedMonoUs) || normalized < previousUs_) return false;
        previousUs_ = normalized;
        ptsUs = normalized;
        return true;
    }

    int Divisor() const { return divisor_; }

private:
    bool InCaptureWindow(int64_t ptsUs, int64_t observedMonoUs) const
    {
        constexpr int64_t PRE_ROLL_US = 10000000;
        constexpr int64_t FUTURE_TOLERANCE_US = 1000000;
        const int64_t lower = std::max<int64_t>(0, std::max(startUs_, observedMonoUs) - PRE_ROLL_US);
        const int64_t upper = observedMonoUs > std::numeric_limits<int64_t>::max() - FUTURE_TOLERANCE_US ?
            std::numeric_limits<int64_t>::max() : observedMonoUs + FUTURE_TOLERANCE_US;
        return ptsUs >= lower && ptsUs <= upper;
    }
    int64_t startUs_ = -1;
    int64_t previousUs_ = -1;
    int divisor_ = 0;
};

inline int64_t FramesForNanoseconds(int64_t ns)
{ return std::llround(static_cast<double>(ns) * SAMPLE_RATE / 1000000000.0); }
inline int64_t FramesForMicroseconds(int64_t us)
{ return std::llround(static_cast<double>(us) * SAMPLE_RATE / 1000000.0); }
/** Typical pickup of app playback into the phone mic when using the built-in speaker. */
constexpr double DEFAULT_SPEAKER_BLEED_CANCEL = 0.88;
/** Default speaker-to-mic lag when correlation cannot find a clear peak. */
constexpr int SPEAKER_BLEED_ACOUSTIC_DELAY_FRAMES = 384;
/** Search window for estimating speaker-to-mic lag on each export. */
constexpr int SPEAKER_BLEED_LAG_SEARCH_MAX_FRAMES = 2400;
/** Fade mic in after inner capture starts so the two metronome sources do not stack. */
constexpr int SPEAKER_MIC_FADE_IN_FRAMES = 480;

inline int32_t StereoMono(int16_t left, int16_t right)
{
    return (static_cast<int32_t>(left) + static_cast<int32_t>(right)) / 2;
}

inline int16_t MicAfterSpeakerBleedCancelMono(int32_t innerMono, int16_t microphone, double bleedCancel)
{
    if (!(bleedCancel > 0)) {
        return microphone;
    }
    const double bleed = std::min(bleedCancel, 1.0);
    int cleaned = static_cast<int>(microphone) - static_cast<int>(std::lround(innerMono * bleed));
    return static_cast<int16_t>(std::clamp(cleaned, -32768, 32767));
}

inline int16_t MicAfterSpeakerBleedCancel(int16_t app, int16_t microphone, double bleedCancel)
{
    return MicAfterSpeakerBleedCancelMono(static_cast<int32_t>(app), microphone, bleedCancel);
}

inline int16_t MixSample(int16_t app, int16_t microphone, double microphoneGain)
{
    // Clipping is applied only to the final sample. The app coefficient is
    // always exactly one, including when the microphone is muted at gain zero.
    int mixed = static_cast<int>(std::lround(app + microphone * microphoneGain));
    return static_cast<int16_t>(std::clamp(mixed, -32768, 32767));
}

inline int16_t MixSample(int16_t app, int16_t microphone, double microphoneGain, double speakerBleedCancel)
{
    return MixSample(app, MicAfterSpeakerBleedCancel(app, microphone, speakerBleedCancel), microphoneGain);
}
}
#endif
