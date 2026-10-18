#ifndef ONEBEAT_RECORDING_ECHO_FILTER_H
#define ONEBEAT_RECORDING_ECHO_FILTER_H

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace onebeat_recording {

struct EchoChannelEstimate {
    bool enabled = false;
    int delayFrames = 0;
    double coefficient = 0;
    double correlation = 0;
    double validationCorrelation = 0;
};

struct StereoEchoEstimate {
    std::array<EchoChannelEstimate, 2> channels{};
};

namespace echo_detail {
constexpr int CHANNELS = 2;
constexpr int MINIMUM_COMPARISON_FRAMES = 2400;
constexpr double MINIMUM_CORRELATION = 0.50;
constexpr double MINIMUM_REFERENCE_RMS = 16.0;

struct Fit {
    double correlation = 0;
    double coefficient = 0;
    double referenceRms = 0;
};

struct EnvelopeDelay {
    bool valid = false;
    int frames = 0;
    double correlation = 0;
};

/**
 * Tonal clicks have many sample-level phase peaks. A 1 ms RMS envelope keeps
 * delay discovery tied to the physical onset; the FIR handles sub-ms phase.
 */
inline EnvelopeDelay EstimateEnvelopeDelay(const int16_t *reference, const int16_t *microphone,
    int frameCount, int maximumLagFrames, int channel)
{
    constexpr int ENVELOPE_FRAMES = 48;
    EnvelopeDelay result;
    if (reference == nullptr || microphone == nullptr || frameCount < 4800 ||
        maximumLagFrames < 0 || channel < 0 || channel >= CHANNELS) return result;
    const int bins = frameCount / ENVELOPE_FRAMES;
    const int maximumLagBins = std::min(maximumLagFrames / ENVELOPE_FRAMES,
        std::max(0, (bins - 50) / 2));
    if (maximumLagBins <= 0) return result;
    std::vector<double> referenceEnvelope(bins), microphoneEnvelope(bins);
    for (int bin = 0; bin < bins; ++bin) {
        double referenceEnergy = 0, microphoneEnergy = 0;
        for (int frame = 0; frame < ENVELOPE_FRAMES; ++frame) {
            const int index = (bin * ENVELOPE_FRAMES + frame) * CHANNELS + channel;
            const double x = reference[index];
            const double y = microphone[index];
            referenceEnergy += x * x;
            microphoneEnergy += y * y;
        }
        referenceEnvelope[bin] = std::sqrt(referenceEnergy / ENVELOPE_FRAMES);
        microphoneEnvelope[bin] = std::sqrt(microphoneEnergy / ENVELOPE_FRAMES);
    }
    const int first = maximumLagBins;
    const int end = bins - maximumLagBins;
    for (int delay = -maximumLagBins; delay <= maximumLagBins; ++delay) {
        double referenceSum = 0, microphoneSum = 0, referenceSquare = 0;
        double microphoneSquare = 0, product = 0;
        int count = 0;
        for (int bin = first; bin < end; ++bin) {
            const double x = referenceEnvelope[bin - delay];
            const double y = microphoneEnvelope[bin];
            referenceSum += x;
            microphoneSum += y;
            referenceSquare += x * x;
            microphoneSquare += y * y;
            product += x * y;
            ++count;
        }
        const double referenceVariance = referenceSquare - referenceSum * referenceSum / count;
        const double microphoneVariance = microphoneSquare - microphoneSum * microphoneSum / count;
        const double covariance = product - referenceSum * microphoneSum / count;
        if (!(referenceVariance > 1) || !(microphoneVariance > 1) || !(covariance > 0)) continue;
        const double correlation = covariance / std::sqrt(referenceVariance * microphoneVariance);
        if (correlation > result.correlation) {
            result.correlation = correlation;
            result.frames = delay * ENVELOPE_FRAMES;
        }
    }
    result.valid = result.correlation >= 0.20;
    return result;
}

inline Fit Measure(const int16_t *reference, const int16_t *microphone, int firstFrame,
    int endFrame, int delay, int channel, int stride, int validationPart = -1,
    bool allowNegativeCovariance = false)
{
    double referenceSum = 0, microphoneSum = 0, referenceSquare = 0;
    double microphoneSquare = 0, product = 0;
    int count = 0;
    for (int frame = firstFrame; frame < endFrame; frame += stride) {
        // Interleaved 10 ms windows expose both onset and decay to held-out
        // validation. Larger, beat-length partitions can put the entire loud
        // onset in training and a different tone/quiet tail in validation.
        if (validationPart >= 0 && ((frame / 480) & 1) != validationPart) continue;
        const double x = reference[(frame - delay) * CHANNELS + channel];
        const double y = microphone[frame * CHANNELS + channel];
        referenceSum += x;
        microphoneSum += y;
        referenceSquare += x * x;
        microphoneSquare += y * y;
        product += x * y;
        ++count;
    }
    Fit fit;
    if (count < 32) return fit;
    const double referenceVariance = referenceSquare - referenceSum * referenceSum / count;
    const double microphoneVariance = microphoneSquare - microphoneSum * microphoneSum / count;
    const double covariance = product - referenceSum * microphoneSum / count;
    if (!(referenceVariance > 1) || !(microphoneVariance > 1) ||
        (allowNegativeCovariance ? covariance == 0 : !(covariance > 0))) return fit;
    fit.referenceRms = std::sqrt(referenceVariance / count);
    fit.correlation = covariance / std::sqrt(referenceVariance * microphoneVariance);
    fit.coefficient = covariance / referenceVariance;
    return fit;
}

inline bool IsUsable(const Fit &fit)
{
    return std::isfinite(fit.coefficient) && std::isfinite(fit.correlation) &&
        fit.referenceRms >= MINIMUM_REFERENCE_RMS && fit.correlation >= MINIMUM_CORRELATION;
}
}

/**
 * Offline speaker pickup estimate, using already aligned 48 kHz stereo stems.
 * A signed delay belongs to the echo reference only: no capture timestamps or
 * application samples are moved. Each physical mic channel needs its own fit.
 * A scalar fit reduces a coherent echo component; it is not a general AEC or
 * denoiser, and cannot remove arbitrary room noise or a changing room response.
 */
namespace echo_detail {
inline StereoEchoEstimate EstimateStereoEchoImpl(const int16_t *alignedInner, const int16_t *alignedMic,
    int frameCount, int maximumLagFrames, double maximumCoefficient, bool polarityInsensitiveDelay)
{
    StereoEchoEstimate result;
    if (alignedInner == nullptr || alignedMic == nullptr || frameCount <
        echo_detail::MINIMUM_COMPARISON_FRAMES || maximumLagFrames < 0 ||
        !std::isfinite(maximumCoefficient) || maximumCoefficient <= 0 || maximumCoefficient > 4.0) return result;
    const int maxLag = std::min(maximumLagFrames,
        (frameCount - echo_detail::MINIMUM_COMPARISON_FRAMES) / 2);
    const int first = maxLag;
    const int end = frameCount - maxLag;
    constexpr int COARSE_LAG_STEP = 16;
    const int coarseFrames = frameCount / COARSE_LAG_STEP;
    std::vector<int16_t> coarseInner(coarseFrames * 2), coarseMic(coarseFrames * 2);
    for (int frame = 0; frame < coarseFrames; ++frame) {
        for (int channel = 0; channel < 2; ++channel) {
            int x = 0, y = 0;
            for (int sample = 0; sample < COARSE_LAG_STEP; ++sample) {
                const int position = (frame * COARSE_LAG_STEP + sample) * 2 + channel;
                x += alignedInner[position];
                y += alignedMic[position];
            }
            coarseInner[frame * 2 + channel] = static_cast<int16_t>(x / COARSE_LAG_STEP);
            coarseMic[frame * 2 + channel] = static_cast<int16_t>(y / COARSE_LAG_STEP);
        }
    }
    // Averaging before the coarse search preserves a peak for broadband
    // signals whose exact delay falls between two coarse lag positions.
    // Final acceptance always uses the original, full-rate PCM.
    const int coarseLag = maxLag / COARSE_LAG_STEP;
    const int coarseFirst = (first + COARSE_LAG_STEP - 1) / COARSE_LAG_STEP;
    const int coarseEnd = end / COARSE_LAG_STEP;
    for (int channel = 0; channel < echo_detail::CHANNELS; ++channel) {
        int bestDelay = 0;
        double bestScore = 0;
        for (int delay = -coarseLag; delay <= coarseLag; ++delay) {
            const auto fit = echo_detail::Measure(coarseInner.data(), coarseMic.data(), coarseFirst,
                coarseEnd, delay, channel, 1, -1, polarityInsensitiveDelay);
            const double score = polarityInsensitiveDelay ? std::abs(fit.correlation) : fit.correlation;
            if (score > bestScore) {
                bestScore = score;
                bestDelay = delay * COARSE_LAG_STEP;
            }
        }
        const int refineFirst = std::max(-maxLag, bestDelay - COARSE_LAG_STEP);
        const int refineEnd = std::min(maxLag, bestDelay + COARSE_LAG_STEP);
        bestScore = 0;
        for (int delay = refineFirst; delay <= refineEnd; ++delay) {
            const auto fit = echo_detail::Measure(alignedInner, alignedMic, first, end,
                delay, channel, 2, 0, polarityInsensitiveDelay);
            const double score = polarityInsensitiveDelay ? std::abs(fit.correlation) : fit.correlation;
            if (score > bestScore) {
                bestScore = score;
                bestDelay = delay;
            }
        }
        const auto training = echo_detail::Measure(alignedInner, alignedMic, first, end,
            bestDelay, channel, 1, 0);
        const auto validation = echo_detail::Measure(alignedInner, alignedMic, first, end,
            bestDelay, channel, 1, 1);
        auto &estimate = result.channels[channel];
        estimate.delayFrames = bestDelay;
        estimate.correlation = training.correlation;
        estimate.validationCorrelation = validation.correlation;
        if (!echo_detail::IsUsable(training) || !echo_detail::IsUsable(validation)) continue;
        // Double talk and transient coincidences tend not to reproduce the
        // same transfer gain in held-out windows. Do not inject inverse app
        // audio into a channel unless that relationship is repeatable.
        const double ratio = validation.coefficient / training.coefficient;
        if (!std::isfinite(ratio) || ratio < 0.5 || ratio > 2.0) continue;
        const auto full = echo_detail::Measure(alignedInner, alignedMic, first, end,
            bestDelay, channel, 1);
        if (!echo_detail::IsUsable(full)) continue;
        estimate.coefficient = std::min(full.coefficient, maximumCoefficient);
        estimate.enabled = estimate.coefficient > 0;
    }
    return result;
}
}

inline StereoEchoEstimate EstimateStereoEcho(const int16_t *alignedInner, const int16_t *alignedMic,
    int frameCount, int maximumLagFrames = 14400, double maximumCoefficient = 4.0)
{
    // Keep the scalar API's positive-gain contract. FIR delay discovery alone
    // accepts either polarity, because its signed taps model phase inversion.
    return echo_detail::EstimateStereoEchoImpl(alignedInner, alignedMic, frameCount,
        maximumLagFrames, maximumCoefficient, false);
}

inline int64_t EchoReferenceFrame(int64_t outputFrame, int signedDelayFrames)
{
    const int64_t delay = signedDelayFrames;
    if (delay < 0 && outputFrame > std::numeric_limits<int64_t>::max() + delay)
        return std::numeric_limits<int64_t>::max();
    if (delay > 0 && outputFrame < std::numeric_limits<int64_t>::min() + delay)
        return std::numeric_limits<int64_t>::min();
    return outputFrame - delay;
}

/** Keep the residual in floating point; only the final app + gain * mic is limited. */
inline double SuppressEchoSample(int16_t microphone, int16_t matchingReference,
    const EchoChannelEstimate &estimate)
{
    if (!estimate.enabled || !(estimate.coefficient > 0)) return microphone;
    return static_cast<double>(microphone) - matchingReference * estimate.coefficient;
}

constexpr int ECHO_FIR_TAPS = 256;

struct EchoFirChannelEstimate {
    bool enabled = false;
    int delayFrames = 0;
    std::array<double, ECHO_FIR_TAPS> taps{};
    double trainingReduction = 0;
    double validationReduction = 0;
    double validationCorrelation = 0;
    double appliedScale = 1;
    bool revalidated = false;
};

struct StereoEchoFirEstimate {
    std::array<EchoFirChannelEstimate, 2> channels{};
};

namespace echo_detail {
inline bool SolveRegularizedCovariance(std::vector<double> &covariance,
    std::array<double, ECHO_FIR_TAPS> &target)
{
    constexpr int n = ECHO_FIR_TAPS;
    double trace = 0;
    for (int i = 0; i < n; ++i) trace += covariance[i * n + i];
    if (!(trace > 1e-8) || !std::isfinite(trace)) return false;
    // A short tonal reference is rank deficient. Ridge regularization prevents
    // an arbitrary large inverse filter from fitting independent mic sounds.
    const double ridge = trace / n * 0.03;
    for (int i = 0; i < n; ++i) {
        covariance[i * n + i] += ridge;
        for (int j = 0; j < i; ++j) covariance[j * n + i] = covariance[i * n + j];
    }
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j <= i; ++j) {
            double value = covariance[i * n + j];
            for (int k = 0; k < j; ++k) value -= covariance[i * n + k] * covariance[j * n + k];
            if (i == j) {
                if (!(value > 0) || !std::isfinite(value)) return false;
                covariance[i * n + j] = std::sqrt(value);
            } else {
                covariance[i * n + j] = value / covariance[j * n + j];
            }
        }
    }
    for (int i = 0; i < n; ++i) {
        for (int k = 0; k < i; ++k) target[i] -= covariance[i * n + k] * target[k];
        target[i] /= covariance[i * n + i];
    }
    for (int i = n - 1; i >= 0; --i) {
        for (int k = i + 1; k < n; ++k) target[i] -= covariance[k * n + i] * target[k];
        target[i] /= covariance[i * n + i];
        if (!std::isfinite(target[i])) return false;
    }
    return true;
}

inline double PredictAt(const int16_t *reference, int microphoneFrame, int channel,
    const EchoFirChannelEstimate &estimate)
{
    const int anchor = microphoneFrame - estimate.delayFrames + ECHO_FIR_TAPS / 2;
    double prediction = 0;
    for (int tap = 0; tap < ECHO_FIR_TAPS; ++tap)
        prediction += reference[(anchor - tap) * 2 + channel] * estimate.taps[tap];
    return prediction;
}

/**
 * Ridge fitting determines the response shape; held-out data determines the
 * safe amplitude. Using the lower train/validation optimum with 2% headroom
 * guarantees a small positive residual instead of an audible inverse echo.
 */
inline bool ApplyConservativeFirScale(const int16_t *reference, const int16_t *microphone,
    int first, int end, int channel, EchoFirChannelEstimate &estimate)
{
    double product[2]{}, predictionEnergy[2]{};
    for (int frame = first; frame < end; ++frame) {
        const int part = (frame / 480) & 1;
        const double prediction = PredictAt(reference, frame, channel, estimate) / 32768.0;
        const double observed = microphone[frame * 2 + channel] / 32768.0;
        product[part] += prediction * observed;
        predictionEnergy[part] += prediction * prediction;
    }
    if (!(predictionEnergy[0] > 1e-12) || !(predictionEnergy[1] > 1e-12)) return false;
    const double trainingScale = product[0] / predictionEnergy[0];
    const double validationScale = product[1] / predictionEnergy[1];
    if (!std::isfinite(trainingScale) || !std::isfinite(validationScale) ||
        !(trainingScale > 0) || !(validationScale > 0)) return false;
    constexpr double UNDER_CANCEL_HEADROOM = 0.98;
    const double scale = std::min({1.0, trainingScale, validationScale}) *
        UNDER_CANCEL_HEADROOM;
    if (scale < 0.05) return false;
    for (auto &tap : estimate.taps) tap *= scale;
    estimate.appliedScale *= scale;
    return true;
}

inline void ValidateFir(const int16_t *reference, const int16_t *microphone,
    int first, int end, int channel, EchoFirChannelEstimate &estimate)
{
    double before[2]{}, after[2]{}, predictionEnergy[2]{}, product[2]{};
    for (int frame = first; frame < end; ++frame) {
        const int part = (frame / 480) & 1;
        const double y = microphone[frame * 2 + channel] / 32768.0;
        const double prediction = PredictAt(reference, frame, channel, estimate) / 32768.0;
        before[part] += y * y;
        after[part] += (y - prediction) * (y - prediction);
        predictionEnergy[part] += prediction * prediction;
        product[part] += prediction * y;
    }
    if (!(before[0] > 1e-12) || !(before[1] > 1e-12) || !(predictionEnergy[1] > 1e-12)) return;
    estimate.trainingReduction = 1.0 - after[0] / before[0];
    estimate.validationReduction = 1.0 - after[1] / before[1];
    estimate.validationCorrelation = product[1] / std::sqrt(before[1] * predictionEnergy[1]);
    // Validation data never enters the fit. A strong independent near-end
    // sound or changing room path therefore disables subtraction locally.
    estimate.enabled = estimate.trainingReduction > 0.12 && estimate.validationReduction > 0.12 &&
        estimate.validationCorrelation > 0.45;
}
}

/**
 * Fit one offline, local 48 kHz stereo probe (recommended 1.6 s, maximum 2 s).
 * The 256 tap response models channel-specific speaker/room frequency response;
 * it never changes the app stem, capture clock, playback route, or mic gain.
 * Callers crossfade predicted echo between neighboring probes, not raw taps or
 * signed delays. A rejected probe contributes zero, preserving the mic signal.
 */
inline StereoEchoFirEstimate EstimateStereoEchoFir(const int16_t *alignedInner,
    const int16_t *alignedMic, int frameCount, int maximumLagFrames = 14400,
    double maximumReferenceGain = 4.0)
{
    StereoEchoFirEstimate result;
    if (alignedInner == nullptr || alignedMic == nullptr || frameCount <
        echo_detail::MINIMUM_COMPARISON_FRAMES + ECHO_FIR_TAPS || frameCount > 96000 ||
        maximumLagFrames < 0 || !std::isfinite(maximumReferenceGain) ||
        maximumReferenceGain <= 0 || maximumReferenceGain > 4) return result;
    const int maxLag = std::min(maximumLagFrames,
        (frameCount - echo_detail::MINIMUM_COMPARISON_FRAMES - ECHO_FIR_TAPS) / 2);
    const int first = maxLag + ECHO_FIR_TAPS / 2;
    const int end = frameCount - maxLag - ECHO_FIR_TAPS / 2;
    const auto coarse = echo_detail::EstimateStereoEchoImpl(alignedInner, alignedMic, frameCount,
        maxLag, maximumReferenceGain, true);
    const auto positive = EstimateStereoEcho(alignedInner, alignedMic, frameCount, maxLag, maximumReferenceGain);
    constexpr int MAX_TRAINING_ROWS = 1600;
    constexpr double MINIMUM_REFERENCE_ENERGY = ECHO_FIR_TAPS * (64.0 / 32768) * (64.0 / 32768);
    const int stride = std::max(16, ((end - first + MAX_TRAINING_ROWS * 2 - 1) /
        (MAX_TRAINING_ROWS * 2) + 15) / 16 * 16);
    for (int channel = 0; channel < 2; ++channel) {
        const auto envelope = echo_detail::EstimateEnvelopeDelay(alignedInner, alignedMic,
            frameCount, maxLag, channel);
        const int candidateDelays[2] = {
            envelope.valid ? envelope.frames : coarse.channels[channel].delayFrames,
            positive.channels[channel].delayFrames
        };
        const int candidateCount = envelope.valid ? 1 : 2;
        result.channels[channel].delayFrames = candidateDelays[0];
        // An envelope lock is deliberately the only candidate: neighboring
        // sample-phase peaks alternate with the 660/880 Hz beat sequence.
        // Raw signed candidates remain a fallback for low-envelope material.
        for (int candidate = 0; candidate < candidateCount; ++candidate) {
            if (candidate == 1 && candidateDelays[1] == candidateDelays[0]) continue;
            EchoFirChannelEstimate estimate;
            estimate.delayFrames = candidateDelays[candidate];
            std::vector<double> covariance(ECHO_FIR_TAPS * ECHO_FIR_TAPS, 0);
            std::array<double, ECHO_FIR_TAPS> features{};
            int trainingRows = 0;
            for (int frame = first; frame < end && trainingRows < MAX_TRAINING_ROWS; frame += stride) {
                if (((frame / 480) & 1) != 0) continue;
                const int anchor = frame - estimate.delayFrames + ECHO_FIR_TAPS / 2;
                double energy = 0;
                for (int tap = 0; tap < ECHO_FIR_TAPS; ++tap) {
                    const double sample = alignedInner[(anchor - tap) * 2 + channel] / 32768.0;
                    features[tap] = sample;
                    energy += sample * sample;
                }
                if (energy < MINIMUM_REFERENCE_ENERGY) continue;
                const double y = alignedMic[frame * 2 + channel] / 32768.0;
                for (int i = 0; i < ECHO_FIR_TAPS; ++i) {
                    estimate.taps[i] += features[i] * y;
                    const double x = features[i];
                    for (int j = 0; j <= i; ++j) covariance[i * ECHO_FIR_TAPS + j] += x * features[j];
                }
                ++trainingRows;
            }
            if (trainingRows < 64 || !echo_detail::SolveRegularizedCovariance(covariance, estimate.taps)) continue;
            double norm = 0;
            for (double tap : estimate.taps) norm += tap * tap;
            if (!std::isfinite(norm) || norm > maximumReferenceGain * maximumReferenceGain) continue;
            if (!echo_detail::ApplyConservativeFirScale(alignedInner, alignedMic,
                first, end, channel, estimate)) continue;
            echo_detail::ValidateFir(alignedInner, alignedMic, first, end, channel, estimate);
            auto &best = result.channels[channel];
            if ((estimate.enabled && (!best.enabled || estimate.validationReduction > best.validationReduction)) ||
                (!estimate.enabled && !best.enabled && estimate.validationReduction > best.validationReduction))
                best = estimate;
        }
    }
    return result;
}

/**
 * Reuse only a previously strong filter shape during local double talk. The
 * current probe learns one gain from training data and verifies it separately;
 * it never relearns the 256 tap response from dominant near-end sound.
 * Callers retain the original reliable model and its age (recommended at most
 * 8 s). A successful fallback does not renew that model's lifetime/provenance.
 */
inline EchoFirChannelEstimate RevalidateEchoFir(const EchoFirChannelEstimate &previous,
    const int16_t *alignedInner, const int16_t *alignedMic, int frameCount, int channel)
{
    EchoFirChannelEstimate rejected;
    constexpr int MARGIN = 14400 + ECHO_FIR_TAPS / 2;
    if (!previous.enabled || previous.revalidated || !(previous.trainingReduction > 0.12) ||
        !(previous.validationReduction > 0.12) ||
        !(previous.validationCorrelation > 0.45) || alignedInner == nullptr || alignedMic == nullptr ||
        channel < 0 || channel > 1 || frameCount > 96000 || frameCount < MARGIN * 2 +
        echo_detail::MINIMUM_COMPARISON_FRAMES || std::abs(static_cast<int64_t>(previous.delayFrames)) > 14400)
        return rejected;
    double norm = 0;
    for (double tap : previous.taps) {
        if (!std::isfinite(tap)) return rejected;
        norm += tap * tap;
    }
    if (!(norm > 0) || norm > 16) return rejected;
    double product[2]{}, predictionEnergy[2]{};
    const int end = frameCount - MARGIN;
    for (int frame = MARGIN; frame < end; ++frame) {
        const int part = (frame / 480) & 1;
        const double predicted = echo_detail::PredictAt(alignedInner, frame, channel, previous) / 32768.0;
        const double observed = alignedMic[frame * 2 + channel] / 32768.0;
        product[part] += predicted * observed;
        predictionEnergy[part] += predicted * predicted;
    }
    if (!(predictionEnergy[0] > 1e-12) || !(predictionEnergy[1] > 1e-12)) return rejected;
    const double trainingScale = product[0] / predictionEnergy[0];
    const double validationScale = product[1] / predictionEnergy[1];
    if (!std::isfinite(trainingScale) || !std::isfinite(validationScale) ||
        trainingScale < 0.05 || trainingScale > 2 || !(validationScale > 0)) return rejected;
    const double ratio = validationScale / trainingScale;
    constexpr double UNDER_CANCEL_HEADROOM = 0.98;
    const double safeScale = std::min({1.0, trainingScale, validationScale}) * UNDER_CANCEL_HEADROOM;
    if (ratio < 0.5 || ratio > 2 || safeScale < 0.05 || norm * safeScale * safeScale > 16) return rejected;
    auto result = previous;
    result.enabled = false;
    result.revalidated = true;
    result.trainingReduction = 0;
    result.validationReduction = 0;
    result.validationCorrelation = 0;
    for (auto &tap : result.taps) tap *= safeScale;
    result.appliedScale *= safeScale;
    echo_detail::ValidateFir(alignedInner, alignedMic, MARGIN, end, channel, result);
    // Weak echo can explain little of a loud independent near-end signal.
    // Only a known shape with repeatable gain may use this smaller residual
    // threshold; new 256-dimensional fits keep their original strong gate.
    result.enabled = result.trainingReduction > 0.002 && result.validationReduction > 0.002 &&
        result.validationCorrelation > 0.02;
    return result;
}

/** First of 256 interleaved stereo reference frames, ordered oldest to newest. */
inline int64_t EchoFirReferenceFirstFrame(int64_t outputFrame, int signedDelayFrames)
{
    const int64_t reference = EchoReferenceFrame(outputFrame, signedDelayFrames);
    constexpr int shift = ECHO_FIR_TAPS - 1 - ECHO_FIR_TAPS / 2;
    if (reference < std::numeric_limits<int64_t>::min() + shift) return std::numeric_limits<int64_t>::min();
    return reference - shift;
}

/** Returns an unclipped prediction in PCM sample units; the caller preserves mic and app separately. */
inline double PredictEchoFirSample(const int16_t *oldestToNewestReference, int channel,
    const EchoFirChannelEstimate &estimate)
{
    if (!estimate.enabled || oldestToNewestReference == nullptr || channel < 0 || channel > 1) return 0;
    double prediction = 0;
    for (int tap = 0; tap < ECHO_FIR_TAPS; ++tap)
        prediction += oldestToNewestReference[(ECHO_FIR_TAPS - 1 - tap) * 2 + channel] * estimate.taps[tap];
    return prediction;
}

/** The app coefficient is one; only this final combined sample is limited. */
inline int16_t MixEchoFirSample(int16_t app, int16_t microphone, double microphoneGain,
    double predictedEcho)
{
    if (microphoneGain == 0) return app;
    const double mixed = app + microphoneGain * (static_cast<double>(microphone) - predictedEcho);
    return static_cast<int16_t>(std::lround(std::clamp(mixed, -32768.0, 32767.0)));
}

}
#endif
