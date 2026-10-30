// Per-session UDP anti-replay window (RFC 6479 style bitmap).
//
// Tracks the highest accepted packet sequence number and a W-bit bitmap of
// received packets behind it. Arbitrary forward jumps are accepted (first
// packet after loss or a reordered burst); duplicates and packets that
// fall behind the window are rejected. Sequence numbers are per-session
// (HMAC already proves the sender owns the session key).
#pragma once

#include <cstdint>
#include <vector>

namespace np {

enum ReplayVerdict {
    RP_ACCEPT = 0,
    RP_DUPLICATE, // already seen inside the window
    RP_OLD,      // behind the window
};

class ReplayWindow {
public:
    explicit ReplayWindow(uint32_t windowBits = 4096);

    ReplayVerdict examine(uint32_t seq);

    // Counters since construction.
    uint64_t accepted() const { return accepted_; }
    uint64_t duplicates() const { return dups_; }
    uint64_t expired() const { return old_; }
    bool primed() const { return primed_; }
    uint32_t maxSeq() const { return maxSeq_; }

private:
    uint32_t bits_;
    uint32_t mask_;
    bool primed_ = false;
    uint32_t maxSeq_ = 0;
    std::vector<uint8_t> bitmap_;
    uint64_t accepted_ = 0, dups_ = 0, old_ = 0;

    bool bitAt(uint32_t seq) const;
    void setBit(uint32_t seq);
    void clearBit(uint32_t seq);
};

} // namespace np
