#ifndef ONEBEAT_RECORDING_RESIDUAL_LAG_H
#define ONEBEAT_RECORDING_RESIDUAL_LAG_H
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace onebeat_recording {
/**
 * Measures how late the MIC content that is time-locked to the accompaniment arrives
 * in a speaker + system LIVE AEC take, so the MIC can be advanced by that lag. The
 * locked content is whatever dominates: an audible accompaniment residual (one Pura 80
 * take: 134 ms) or, when the AEC removed it, the player's own performance (another
 * take on the same phone: 62 ms). The lag is therefore a property of each take, not
 * of the device, and is never reused across takes.
 *
 * Method: >1 kHz envelopes in 2 ms bins; non-negative deconvolution
 * micEnv(t) ~= sum_L h[L] innerEnv(t - L) + c over L = 0..300 ms. Deconvolution
 * removes the accompaniment's own periodicity, which makes plain cross-correlation
 * pick pattern aliases. The normal matrix uses the accompaniment autocorrelation
 * (Toeplitz approximation) so cost stays linear in take length.
 *
 * The result measures MIC content time-locked to the accompaniment. A take whose
 * residual is too weak is reported unreliable; callers must not invent a lag then.
 */
struct ResidualLagEstimate {
    int64_t lagUs = 0;
    /** Share of the non-negative response inside the chosen 10 ms cluster. */
    double share = 0;
    /**
     * Fraction of MIC envelope variance the accompaniment model explains. A share
     * alone is a ratio and becomes 1.0 when almost nothing is left (one tiny tap);
     * this absolute strength rejects those near-empty fits.
     */
    double explained = 0;
    bool reliable = false;
};

class ResidualLagEstimator {
public:
    static constexpr int SAMPLE_RATE = 48000;
    static constexpr int BIN_FRAMES = 96;            // 2 ms
    static constexpr int TAPS = 151;                 // 0..300 ms
    // 60 ms: chosen for residual round trips; content locked earlier lies outside the search.
    static constexpr int SEARCH_FIRST = 30;
    static constexpr int SEARCH_LAST = 125;          // 250 ms
    static constexpr double MIN_SHARE = 0.2;         // device takes: clear 0.28-0.44, unclear <= 0.14
    // Device takes: real residual 0.039; a near-empty Pura X fit had share 1.00 but 0.0001.
    static constexpr double MIN_EXPLAINED = 0.01;
    static constexpr int MIN_BINS = 5000;            // 10 s of overlap before a lag is trusted

    ResidualLagEstimator() : alpha_(std::exp(-2 * M_PI * 1000.0 / SAMPLE_RATE)) {}

    /** Stereo S16 frames already aligned to the output timeline; MIC is averaged to mono. */
    void Append(const int16_t *inner, const int16_t *microphone, int frames)
    {
        for (int f = 0; f < frames; ++f) {
            const double x = 0.5 * (inner[2 * f] + inner[2 * f + 1]);
            const double y = 0.5 * (microphone[2 * f] + microphone[2 * f + 1]);
            innerHp_ = alpha_ * (innerHp_ + x - innerPrev_); innerPrev_ = x;
            micHp_ = alpha_ * (micHp_ + y - micPrev_); micPrev_ = y;
            innerAcc_ += innerHp_ * innerHp_; micAcc_ += micHp_ * micHp_;
            if (++binFill_ == BIN_FRAMES) {
                innerEnv_.push_back(static_cast<float>(std::sqrt(innerAcc_ / BIN_FRAMES)));
                micEnv_.push_back(static_cast<float>(std::sqrt(micAcc_ / BIN_FRAMES)));
                innerAcc_ = micAcc_ = 0; binFill_ = 0;
            }
        }
    }

    ResidualLagEstimate Estimate() const
    {
        ResidualLagEstimate result;
        const int count = static_cast<int>(std::min(innerEnv_.size(), micEnv_.size()));
        if (count < MIN_BINS + TAPS) return result;
        double innerMean = 0, micMean = 0;
        for (int t = 0; t < count; ++t) { innerMean += innerEnv_[t]; micMean += micEnv_[t]; }
        innerMean /= count; micMean /= count;
        std::vector<double> autocorr(TAPS, 0), cross(TAPS, 0);
        double micVariance = 0;
        for (int t = TAPS; t < count; ++t) {
            const double y = micEnv_[t] - micMean;
            micVariance += y * y;
            const double x0 = innerEnv_[t] - innerMean;
            for (int l = 0; l < TAPS; ++l) {
                const double xl = innerEnv_[t - l] - innerMean;
                cross[l] += xl * y;
                autocorr[l] += x0 * xl;
            }
        }
        if (!(autocorr[0] > 0)) return result;
        const double ridge = 1e-3 * autocorr[0];
        // Projected gradient NNLS on the Toeplitz normal equations.
        std::vector<double> h(TAPS, 0);
        const double step = 1.0 / (TAPS * autocorr[0] + ridge);
        for (int iteration = 0; iteration < 3000; ++iteration) {
            for (int i = 0; i < TAPS; ++i) {
                double gradient = ridge * h[i] - cross[i];
                for (int j = 0; j < TAPS; ++j) gradient += autocorr[std::abs(i - j)] * h[j];
                h[i] = std::max(0.0, h[i] - step * gradient);
            }
        }
        double total = 0;
        for (double v : h) total += v;
        if (!(total > 0) || !(micVariance > 0)) return result;
        // SSE = Syy - 2 h.cross + h' R h (same Toeplitz approximation as the fit).
        double fitTerm = 0, quadratic = 0;
        for (int i = 0; i < TAPS; ++i) {
            fitTerm += h[i] * cross[i];
            double row = 0;
            for (int j = 0; j < TAPS; ++j) row += autocorr[std::abs(i - j)] * h[j];
            quadratic += h[i] * row;
        }
        result.explained = std::max(0.0, (2 * fitTerm - quadratic) / micVariance);
        int best = SEARCH_FIRST;
        double bestMass = -1;
        for (int center = SEARCH_FIRST; center <= SEARCH_LAST; ++center) {
            double mass = 0;
            for (int k = -2; k <= 2; ++k) mass += h[center + k];
            if (mass > bestMass) { bestMass = mass; best = center; }
        }
        double weighted = 0, mass = 0;
        for (int k = -2; k <= 2; ++k) { weighted += (best + k) * h[best + k]; mass += h[best + k]; }
        const double lagBins = mass > 0 ? weighted / mass : best;
        result.lagUs = std::llround(lagBins * BIN_FRAMES * 1000000.0 / SAMPLE_RATE);
        result.share = bestMass / total;
        result.reliable = std::isfinite(result.share) && result.share >= MIN_SHARE &&
            std::isfinite(result.explained) && result.explained >= MIN_EXPLAINED;
        return result;
    }

private:
    const double alpha_;
    double innerHp_ = 0, innerPrev_ = 0, micHp_ = 0, micPrev_ = 0, innerAcc_ = 0, micAcc_ = 0;
    int binFill_ = 0;
    std::vector<float> innerEnv_, micEnv_;
};
}
#endif
