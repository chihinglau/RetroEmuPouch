// Per-peer frame input ring.
//
// Stores the most recent W per-frame retropad masks from the remote
// side. Frames may arrive out of order (host redundancy carries the last
// N frames) and duplicates are common. Capacity only needs to cover
// the redundancy/rexmit window (D+2 frames) plus scheduling slack;
// 64 slots is ample for D <= 2 at 60fps.
#pragma once

#include <cstdint>
#include <vector>

namespace np {

class InputRing {
public:
    explicit InputRing(uint32_t capacity = 64);

    void put(uint32_t frame, uint16_t mask);
    bool has(uint32_t frame) const;
    bool get(uint32_t frame, uint16_t &mask) const;

    // Count of consecutively-present frames starting at `start`.
    uint32_t contiguous(uint32_t start) const;

    bool everReceived() const { return ever_; }
    uint32_t newest() const { return newest_; }
    uint32_t capacity() const { return cap_; }

private:
    uint32_t cap_;
    uint32_t mask_;
    bool ever_ = false;
    uint32_t newest_ = 0;
    std::vector<uint16_t> masks_;
    std::vector<uint32_t> frames_;
    std::vector<uint8_t> present_;
};

} // namespace np
