// Fixed-size wire packet codec for GamePouch netplay.
//
// On-wire layout (28-byte header, little-endian, packed):
//   u16 magic 'GS'  u8 protoVer  u8 type
//   u32 roomId
//   u32 seq          (per-session monotonic packet number; replay window)
//   u32 frame        (libretro frame number the payload belongs to)
//   u16 mask         (retropad bitmask for INPUT packets)
//   u16 flags        (CTRL subtype in low byte for type==CTRL, else 0)
//   u8  tag[8]       HMAC-SHA256(sessionKey, header-with-zeroed-tag || payload)
// CTRL packets may append a small payload after the header (e.g. 8-byte
// echoed timestamp).
//
// INPUT packets come in two shapes:
//   - single: exactly 28 bytes, mask belongs to hdr.frame.
//   - batch:  28 + 1 + 2*count bytes; payload is u8 count (1..kInputBatchMax)
//             followed by count little-endian u16 masks, starting at hdr.frame
//             for the newest frame and stepping back by one per entry. This
//             bundles the N=D+2 redundant frames (and CTRL_NEED re-dumps) into
//             ONE authenticated datagram instead of N separate ones.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace np {

constexpr uint16_t kMagic = 0x5347; // 'G','S' little-endian
constexpr uint8_t  kProtoVersion = 1;
constexpr size_t   kTagLen = 8;
constexpr size_t   kHeaderLen = 28;
constexpr size_t   kKeyLen = 32;
constexpr size_t   kInputBatchMax = 64; // ring horizon; covers CTRL_NEED dumps

enum PktType : uint8_t {
    PKT_INPUT = 1,
    PKT_CTRL = 2,
};

// CTRL packet subtypes (stored in flags low byte).
enum CtrlType : uint16_t {
    CTRL_PING = 1,   // payload: u64 sender t0 ns
    CTRL_PONG = 2,   // payload: u64 echoed t0 ns
    CTRL_PAUSE = 3,
    CTRL_RESUME = 4,
    CTRL_BYE = 5,
    CTRL_DCHANGE = 6, // payload: u8 newDelay
    CTRL_START = 7,
    CTRL_NEED = 8,    // payload: u32 first frame the gate is missing
                      // (FR-15 gap resend; receiver dumps its local ring
                      // from that frame; ring depth 64 is the recoverable
                      // horizon, older gaps fall through to the 10s drop)
};

#pragma pack(push, 1)
struct Packet {
    uint16_t magic;
    uint8_t  ver;
    uint8_t  type;
    uint32_t room;
    uint32_t seq;
    uint32_t frame;
    uint16_t mask;
    uint16_t flags;
    uint8_t  tag[kTagLen];
};
#pragma pack(pop)
static_assert(sizeof(Packet) == kHeaderLen, "netplay header must be 28 bytes");

enum RejectReason {
    REJ_OK = 0,
    REJ_BAD_LEN,
    REJ_BAD_MAGIC,
    REJ_BAD_VERSION,
    REJ_BAD_TAG,
};

struct Decoded {
    Packet hdr;
    std::vector<uint8_t> payload;
};

// Builds an authenticated packet into out (must have room for kHeaderLen+payloadLen).
// Returns total bytes written, or 0 if out is too small.
size_t encode(uint8_t type, uint32_t room, uint32_t seq, uint32_t frame,
             uint16_t mask, uint16_t flags,
             const uint8_t *payload, size_t payloadLen,
             const uint8_t key[kKeyLen],
             uint8_t *out, size_t outCap);

// Validates length/magic/version/HMAC. Payload (CTRL only) is copied into out.
RejectReason verify(const uint8_t *buf, size_t len,
                 const uint8_t key[kKeyLen], Decoded &out);

// Build a batched INPUT datagram: masks[0] belongs to newestFrame, masks[i]
// to newestFrame-i (contiguous). count must be 1..kInputBatchMax.
size_t encodeInputBatch(uint32_t room, uint32_t seq, uint32_t newestFrame,
                        const uint16_t *masks, size_t count,
                        const uint8_t key[kKeyLen],
                        uint8_t *out, size_t outCap);

// Validates an INPUT payload shape. Empty payload (single-frame packet)
// yields count=0; otherwise *count is the u8 count byte (1..batch max) and
// payloadLen must equal 1 + 2*count.
bool inputBatchShape(size_t payloadLen, uint8_t countByte, size_t &count);

const char *rejectName(RejectReason r);

// Recomputes the 8-byte truncated tag for header(+payload); exposed for tests.
void computeTag(const Packet &p, const uint8_t *payload, size_t payloadLen,
               const uint8_t key[kKeyLen], uint8_t tagOut[kTagLen]);

} // namespace np
