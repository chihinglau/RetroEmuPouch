#include "gs_np_replay.h"

namespace np {

ReplayWindow::ReplayWindow(uint32_t windowBits) {
    if (windowBits < 64) windowBits = 64;
    // Round up to a power of two.
    uint32_t w = 64;
    while (w < windowBits && w < (1u << 31)) w <<= 1;
    bits_ = w;
    mask_ = w - 1;
    bitmap_.assign(w / 8, 0);
}

bool ReplayWindow::bitAt(uint32_t seq) const {
    const uint32_t idx = seq & mask_;
    return (bitmap_[idx >> 3] & (uint8_t)(1u << (idx & 7))) != 0;
}

void ReplayWindow::setBit(uint32_t seq) {
    const uint32_t idx = seq & mask_;
    bitmap_[idx >> 3] |= (uint8_t)(1u << (idx & 7));
}

void ReplayWindow::clearBit(uint32_t seq) {
    const uint32_t idx = seq & mask_;
    bitmap_[idx >> 3] &= (uint8_t)~(uint8_t)(1u << (idx & 7));
}

ReplayVerdict ReplayWindow::examine(uint32_t seq) {
    if (!primed_) {
        primed_ = true;
        maxSeq_ = seq;
        setBit(seq);
        ++accepted_;
        return RP_ACCEPT;
    }
    if (seq > maxSeq_) {
        const uint32_t gap = seq - maxSeq_;
        if (gap >= bits_) {
            std::fill(bitmap_.begin(), bitmap_.end(), (uint8_t)0);
        } else {
            // Frames strictly between old max and seq are still absent.
            for (uint32_t d = 1; d < gap; ++d) clearBit(maxSeq_ + d);
        }
        clearBit(seq); // position may still hold a wrapped-around entry
        setBit(seq);
        maxSeq_ = seq;
        ++accepted_;
        return RP_ACCEPT;
    }
    const uint32_t behind = maxSeq_ - seq;
    if (behind >= bits_) {
        ++old_;
        return RP_OLD;
    }
    if (bitAt(seq)) {
        ++dups_;
        return RP_DUPLICATE;
    }
    setBit(seq);
    ++accepted_;
    return RP_ACCEPT;
}

} // namespace np
