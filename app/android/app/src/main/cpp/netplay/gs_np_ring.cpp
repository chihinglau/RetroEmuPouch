#include "gs_np_ring.h"

namespace np {

InputRing::InputRing(uint32_t capacity) {
    if (capacity < 16) capacity = 16;
    uint32_t w = 16;
    while (w < capacity) w <<= 1;
    cap_ = w;
    mask_ = w - 1;
    masks_.assign(w, 0);
    frames_.assign(w, 0);
    present_.assign(w, 0);
}

void InputRing::put(uint32_t frame, uint16_t mask) {
    const uint32_t idx = frame & mask_;
    // Wrapped-around slot holding an older frame must look empty first.
    if (!present_[idx] || frames_[idx] != frame) {
        present_[idx] = 1;
        frames_[idx] = frame;
    } // duplicate (frame,mask) or retransmit: keep stored value
    masks_[idx] = mask;
    if (!ever_ || frame > newest_) newest_ = frame;
    ever_ = true;
}

bool InputRing::has(uint32_t frame) const {
    const uint32_t idx = frame & mask_;
    return present_[idx] != 0 && frames_[idx] == frame;
}

bool InputRing::get(uint32_t frame, uint16_t &mask) const {
    const uint32_t idx = frame & mask_;
    if (!present_[idx] || frames_[idx] != frame) return false;
    mask = masks_[idx];
    return true;
}

uint32_t InputRing::contiguous(uint32_t start) const {
    uint32_t n = 0;
    while (n < cap_ && has(start + n)) ++n;
    return n;
}

} // namespace np

