#include "gs_np_delay.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace np {

DelayCtrl::DelayCtrl(int minD, int maxD, double framePeriodSec,
                   double windowSec, double downgradeMarginFactor)
    : minD_(std::min(minD, maxD)),
      maxD_(std::max(minD, maxD)),
      d_(maxD),
      period_(framePeriodSec > 0 ? framePeriodSec : 1.0 / 59.61),
      windowSec_(windowSec),
      margin_(downgradeMarginFactor * period_) {}

void DelayCtrl::reset(int initialD, double nowSec) {
    d_ = std::max(minD_, std::min(maxD_, initialD));
    samples_.clear();
    upgrades_ = downgrades_ = late_ = 0;
    lastChangeSec_ = nowSec;
}

void DelayCtrl::prune(double nowSec) {
    while (!samples_.empty() && samples_.front().t < nowSec - windowSec_) {
        samples_.pop_front();
    }
}

bool DelayCtrl::eligibleDowngrade(double nowSec) const {
    if (d_ <= minD_) return false;
    if (nowSec - lastChangeSec_ < windowSec_) return false;
    // At 59.61fps a 2.0s window holds at most 119 inter-frame gaps
    // (~1.996s), so require 120 samples and span >= window - 2 frames.
    if (samples_.size() < 120) return false;
    const double span = samples_.back().t - samples_.front().t;
    if (span < windowSec_ - 2.0 * period_) return false;

    std::vector<double> leads;
    leads.reserve(samples_.size());
    for (const auto &s : samples_) {
        if (s.lead <= 0.0) return false; // any late frame blocks downgrade
        leads.push_back(s.lead);
    }
    std::sort(leads.begin(), leads.end());
    const size_t i = (size_t)std::lround(0.95 * (leads.size() - 1));
    return leads[i] >= margin_;
}

bool DelayCtrl::onFrame(double leadSec, double nowSec) {
    samples_.push_back({nowSec, leadSec});
    prune(nowSec);

    if (leadSec <= 0.0) {
        ++late_;
        if (d_ < maxD_) {
            d_ = maxD_;
            lastChangeSec_ = nowSec;
            samples_.clear();
            ++upgrades_;
            return true;
        }
        lastChangeSec_ = nowSec; // keep the cooldown alive during bad network
        return false;
    }

    if (eligibleDowngrade(nowSec)) {
        --d_;
        lastChangeSec_ = nowSec;
        samples_.clear();
        ++downgrades_;
        return true;
    }
    return false;
}

} // namespace np
