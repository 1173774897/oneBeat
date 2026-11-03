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
/** A positive timeline offset delays a source; a negative offset advances it. */
inline int64_t AlignedSourceFrame(int64_t outputFrame, int64_t offsetUs)
{ return outputFrame - FramesForMicroseconds(offsetUs); }

/**
 * Capture timestamps are hardware-clock observations, not editing commands.
 * Callback PCM is already ordered; timestamp batching must neither edit samples
 * nor terminate capture. Only malformed timestamp/frame inputs are rejected.
 */
class ContiguousPcmTimeline {
public:
    bool Append(int64_t timestampNs, int64_t frameCount)
    {
        if (timestampNs < 0 || frameCount <= 0) return false;
        if (firstTimestampNs_ < 0) firstTimestampNs_ = timestampNs;
        const int64_t observedFrame = FramesForNanoseconds(timestampNs - firstTimestampNs_);
        const int64_t driftFrames = observedFrame - framesWritten_;
        // Diagnostics only: a large positive step means the source delivered no
        // PCM for a while (e.g. playback paused), which contiguous writing collapses.
        if (framesWritten_ > 0) {
            const int64_t step = driftFrames - lastDriftFrames_;
            if (step > maxDriftStepFrames_) {
                maxDriftStepFrames_ = step;
                maxDriftStepAtFrame_ = framesWritten_;
            }
            // > 10 ms: larger than callback batching jitter; a candidate missing-PCM gap.
            if (step > SAMPLE_RATE / 100) {
                if (gapCount_ == 0) firstGapAtFrame_ = framesWritten_;
                ++gapCount_;
            }
            minDriftFrames_ = std::min(minDriftFrames_, driftFrames);
            maxDriftFrames_ = std::max(maxDriftFrames_, driftFrames);
        }
        lastDriftFrames_ = driftFrames;
        framesWritten_ += frameCount;
        return true;
    }

    int64_t FirstTimestampNs() const { return firstTimestampNs_; }
    int64_t FramesWritten() const { return framesWritten_; }
    int64_t LastDriftFrames() const { return lastDriftFrames_; }
    int64_t MaxDriftStepFrames() const { return maxDriftStepFrames_; }
    int64_t MinDriftFrames() const { return minDriftFrames_; }
    int64_t MaxDriftFrames() const { return maxDriftFrames_; }
    /** Written-frame position where the largest step occurred (-1 if none). */
    int64_t MaxDriftStepAtFrame() const { return maxDriftStepAtFrame_; }
    int64_t GapCount() const { return gapCount_; }
    int64_t FirstGapAtFrame() const { return firstGapAtFrame_; }

private:
    int64_t firstTimestampNs_ = -1;
    int64_t framesWritten_ = 0;
    int64_t lastDriftFrames_ = 0;
    int64_t maxDriftStepFrames_ = 0;
    int64_t minDriftFrames_ = 0;
    int64_t maxDriftFrames_ = 0;
    int64_t maxDriftStepAtFrame_ = -1;
    int64_t gapCount_ = 0;
    int64_t firstGapAtFrame_ = -1;
};

/**
 * Offline stereo peak limiter for the final app + MIC bus, replacing a hard
 * clamp. Contract:
 * - Ceiling is -1 dBFS sample peak: device AAC exports measured +0.2 dBTP
 *   after encoding with a 0 dBFS ceiling, so 1 dB is kept for inter-sample
 *   and codec overshoot (the usual -1 dBTP delivery target).
 * - Identity whenever the bus stays at or below the ceiling: the gain is
 *   exactly 1.0, so such takes stay bit-exact.
 * - Never exceeds the ceiling: a sliding minimum over the lookahead window,
 *   then a box average of the same length, guarantees each output sample's
 *   gain is <= its own required gain (no overs, no waveshaping distortion).
 * Output is delayed by Latency() frames; callers prime and flush accordingly.
 */
class LookaheadPeakLimiter {
public:
    static constexpr int WINDOW_FRAMES = 240; // 5 ms at 48 kHz: smooth ramp, below transient-smear audibility.
    static constexpr double CEILING = 29204.0; // 32768 * 10^(-1/20), -1 dBFS.
    explicit LookaheadPeakLimiter(double releaseFrames = SAMPLE_RATE * 0.06, double ceiling = CEILING)
        : releaseCoefficient_(std::exp(-1.0 / releaseFrames)), ceiling_(ceiling)
    {
        for (int i = 0; i < WINDOW_FRAMES; ++i) { gains_[i] = 1; delayed_[i * 2] = 0; delayed_[i * 2 + 1] = 0; }
    }
    static constexpr int Latency() { return WINDOW_FRAMES - 1; }

    /** Pushes one stereo frame in PCM units and returns the frame Latency() earlier. */
    void Push(double left, double right, double &outLeft, double &outRight)
    {
        const double required = std::min(RequiredGain(left), RequiredGain(right));
        // Monotonic deque of (index, gain) gives the window minimum in O(1).
        // Expire first so the deque never holds more than WINDOW_FRAMES entries.
        while (minCount_ > 0 && minIndex_[minHead_] <= index_ - WINDOW_FRAMES) {
            minHead_ = (minHead_ + 1) % WINDOW_FRAMES; --minCount_;
        }
        while (minCount_ > 0 && minGain_[(minHead_ + minCount_ - 1) % WINDOW_FRAMES] >= required) --minCount_;
        const int tail = (minHead_ + minCount_) % WINDOW_FRAMES;
        minGain_[tail] = required; minIndex_[tail] = index_; ++minCount_;
        const double windowMinimum = minGain_[minHead_];
        // Release recovers slowly toward 1 but is capped by the window minimum,
        // which keeps the no-over guarantee.
        released_ = std::min(windowMinimum, 1 - (1 - released_) * releaseCoefficient_);
        // Snap a finished release (< 0.0001 dB) to exactly 1 so transparency resumes.
        if (released_ > 1 - RELEASE_SNAP) released_ = 1;
        const int slot = static_cast<int>(index_ % WINDOW_FRAMES);
        reducedSlots_ += (released_ < 1) - (gains_[slot] < 1);
        boxSum_ += released_ - gains_[slot];
        gains_[slot] = released_;
        // An all-ones window resets the running sum, discarding float drift.
        if (reducedSlots_ == 0) boxSum_ = WINDOW_FRAMES;
        const double gain = reducedSlots_ == 0 ? 1 : std::min(1.0, boxSum_ / WINDOW_FRAMES);
        // Frame k lives in slot k % W, so slot (n + 1) % W holds frame n - Latency():
        // exactly the oldest frame covered by every gain in the averaged window.
        const int outSlot = static_cast<int>((index_ + 1) % WINDOW_FRAMES);
        outLeft = delayed_[outSlot * 2] * gain;
        outRight = delayed_[outSlot * 2 + 1] * gain;
        delayed_[slot * 2] = left;
        delayed_[slot * 2 + 1] = right;
        minGainApplied_ = std::min(minGainApplied_, gain);
        if (gain < 1) ++limitedFrames_;
        ++index_;
    }
    /** Lowest gain applied to any output frame (1 means the limiter never engaged). */
    double MinGainApplied() const { return minGainApplied_; }
    int64_t LimitedFrames() const { return limitedFrames_; }

private:
    double RequiredGain(double sample) const
    {
        const double magnitude = std::abs(sample);
        return magnitude > ceiling_ ? ceiling_ / magnitude : 1;
    }
    static constexpr double RELEASE_SNAP = 1e-5;
    const double releaseCoefficient_;
    const double ceiling_;
    int reducedSlots_ = 0;
    double gains_[WINDOW_FRAMES];
    double delayed_[WINDOW_FRAMES * 2];
    double minGain_[WINDOW_FRAMES] = {};
    int64_t minIndex_[WINDOW_FRAMES] = {};
    int minHead_ = 0, minCount_ = 0;
    int64_t index_ = 0;
    double released_ = 1;
    double boxSum_ = WINDOW_FRAMES;
    double minGainApplied_ = 1;
    int64_t limitedFrames_ = 0;
};

/** Final S16 conversion after the limiter; the clamp only absorbs float rounding. */
inline int16_t LimitedBusSample(double sample)
{
    return static_cast<int16_t>(std::lround(std::clamp(sample, -32768.0, 32767.0)));
}

/** Maximum residual coefficient; the actual acoustic pickup is estimated per capture. */
constexpr double DEFAULT_SPEAKER_BLEED_CANCEL = 0.90;
/** Default speaker-to-mic lag when correlation cannot find a clear peak. */
constexpr int SPEAKER_BLEED_ACOUSTIC_DELAY_FRAMES = 384;
/** Search window for estimating speaker-to-mic lag on each export. */
constexpr int SPEAKER_BLEED_LAG_SEARCH_MAX_FRAMES = 2400;
/** Weak matches must not synthesize an inverted app track into the microphone. */
constexpr double SPEAKER_BLEED_MIN_CORRELATION = 0.15;

inline int32_t StereoMono(int16_t left, int16_t right)
{
    return (static_cast<int32_t>(left) + static_cast<int32_t>(right)) / 2;
}

struct SpeakerBleedEstimate {
    int delayFrames = SPEAKER_BLEED_ACOUSTIC_DELAY_FRAMES;
    double coefficient = 0;
    double correlation = 0;
};

/**
 * Estimate y[t] = coefficient * x[t-delay] from aligned stereo stems.
 * Mean-centred normalized correlation rejects DC/noise, while least squares
 * prevents the old full-scale subtraction from turning bleed into a comb filter.
 */
inline SpeakerBleedEstimate EstimateSpeakerBleed(const int16_t *inner, const int16_t *microphone,
    int frameCount, int maximumLagFrames, double maximumCoefficient)
{
    SpeakerBleedEstimate estimate;
    if (inner == nullptr || microphone == nullptr || frameCount < 480 ||
        maximumLagFrames < 0 || !(maximumCoefficient > 0)) {
        return estimate;
    }
    const int maximumLag = std::min(maximumLagFrames, frameCount - 480);
    const int comparisonFrames = frameCount - maximumLag;
    double bestCovariance = 0;
    double bestInnerVariance = 0;
    for (int lag = 0; lag <= maximumLag; lag++) {
        double innerSum = 0;
        double micSum = 0;
        double innerSquareSum = 0;
        double micSquareSum = 0;
        double productSum = 0;
        for (int frame = 0; frame < comparisonFrames; frame++) {
            const double innerMono = StereoMono(inner[frame * 2], inner[frame * 2 + 1]);
            const int micFrame = frame + lag;
            const double micMono = StereoMono(microphone[micFrame * 2], microphone[micFrame * 2 + 1]);
            innerSum += innerMono;
            micSum += micMono;
            innerSquareSum += innerMono * innerMono;
            micSquareSum += micMono * micMono;
            productSum += innerMono * micMono;
        }
        const double innerVariance = innerSquareSum - innerSum * innerSum / comparisonFrames;
        const double micVariance = micSquareSum - micSum * micSum / comparisonFrames;
        const double covariance = productSum - innerSum * micSum / comparisonFrames;
        if (!(covariance > 0) || !(innerVariance > 1) || !(micVariance > 1)) continue;
        const double correlation = covariance / std::sqrt(innerVariance * micVariance);
        if (correlation > estimate.correlation) {
            estimate.delayFrames = lag;
            estimate.correlation = correlation;
            bestCovariance = covariance;
            bestInnerVariance = innerVariance;
        }
    }
    if (estimate.correlation < SPEAKER_BLEED_MIN_CORRELATION || !(bestInnerVariance > 0)) {
        estimate.coefficient = 0;
        return estimate;
    }
    estimate.coefficient = std::clamp(bestCovariance / bestInnerVariance, 0.0,
        std::min(maximumCoefficient, 1.0));
    return estimate;
}

inline int64_t SpeakerReferenceOutputFrame(int64_t outputFrame, int delayFrames)
{
    return outputFrame - std::max(0, delayFrames);
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

/** Floating-point MIC caches preserve later gain edits; the final sum is clamped to S16. */
inline int16_t MixProcessedMicSample(int16_t app, float microphone, double microphoneGain)
{
    if (microphoneGain == 0) return app;
    const double mixed = app + microphoneGain * static_cast<double>(microphone);
    return static_cast<int16_t>(std::lround(std::clamp(mixed, -32768.0, 32767.0)));
}

inline int16_t MixSample(int16_t app, int16_t microphone, double microphoneGain, double speakerBleedCancel)
{
    return MixSample(app, MicAfterSpeakerBleedCancel(app, microphone, speakerBleedCancel), microphoneGain);
}
}
#endif
