// Pure delay-based frame-delay controller (no socket IO).
//
// D is the number of frames inputs are held back before they are
// consumed; frame K runs with masks for frame K-D. Host only:
// the host measures the remote input lead time per frame and announces
// symmetric D changes via CTRL_DCHANGE.
//
// Rules (see spec FR-16), frame period p:
//   upgrade:   any frame whose remote input is late (lead <= 0)
//              immediately raises D to maxD.
//   downgrade: D > minD and, over a trailing 2s window, zero late
//             frames and p95(lead) >= 1.5*p (one full frame to
//             shed plus half a frame of jitter margin), and the last
//             change happened >= 2s ago -> D -= 1.
#pragma once

#include <cstdint>
#include <deque>

namespace np {

class DelayCtrl {
public:
    DelayCtrl(int minD = 1, int maxD = 2,
             double framePeriodSec = 1.0 / 59.61,
             double windowSec = 2.0,
             double downgradeMarginFactor = 1.5);

    // Feed one per-frame lead-time sample (seconds; >=0 early, <0 late).
    // Returns true exactly when d() changed; the caller must announce.
    bool onFrame(double leadSec, double nowSec);

    int d() const { return d_; }
    int minD() const { return minD_; }
    int maxD() const { return maxD_; }
    uint64_t upgrades() const { return upgrades_; }
    uint64_t downgrades() const { return downgrades_; }
    uint64_t lateFrames() const { return late_; }

    // Begin at initialD; resets the sample window and change timer.
    void reset(int initialD, double nowSec);

private:
    struct Sample {
        double t;
        double lead;
    };

    bool eligibleDowngrade(double nowSec) const;
    void prune(double nowSec);

    int minD_, maxD_, d_;
    double period_;
    double windowSec_;
    double margin_;
    double lastChangeSec_ = -1e9;
    std::deque<Sample> samples_;
    uint64_t upgrades_ = 0, downgrades_ = 0, late_ = 0;
};

} // namespace np
