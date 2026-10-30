#include "gs_np_codec.h"

#include <string.h>

extern "C" {
#include "gs_np_sha256.h"
}

namespace np {

namespace {

// Constant-time compare for fixed-length tags (avoids leaking match
// position through timing; input length is always kTagLen).
bool tagEqual(const uint8_t *a, const uint8_t *b) {
    uint8_t diff = 0;
    for (size_t i = 0; i < kTagLen; ++i) diff |= (uint8_t)(a[i] ^ b[i]);
    return diff == 0;
}

} // namespace

void computeTag(const Packet &p, const uint8_t *payload, size_t payloadLen,
               const uint8_t key[kKeyLen], uint8_t tagOut[kTagLen]) {
    // MAC the exact wire bytes with the tag field zeroed, followed by the
    // CTRL payload (empty for INPUT packets).
    std::vector<uint8_t> buf(kHeaderLen + payloadLen);
    Packet tmp = p;
    memset(tmp.tag, 0, kTagLen);
    memcpy(buf.data(), &tmp, kHeaderLen);
    if (payloadLen) memcpy(buf.data() + kHeaderLen, payload, payloadLen);

    uint8_t mac[GS_SHA256_DIGEST_SIZE];
    gs_hmac_sha256(key, kKeyLen, buf.data(), buf.size(), mac);
    memcpy(tagOut, mac, kTagLen);
}

size_t encode(uint8_t type, uint32_t room, uint32_t seq, uint32_t frame,
             uint16_t mask, uint16_t flags,
             const uint8_t *payload, size_t payloadLen,
             const uint8_t key[kKeyLen],
             uint8_t *out, size_t outCap) {
    const size_t total = kHeaderLen + payloadLen;
    if (!out || outCap < total) return 0;
    if (type == PKT_INPUT && payloadLen != 0) return 0; // use encodeInputBatch

    Packet p{};
    p.magic = kMagic;
    p.ver = kProtoVersion;
    p.type = type;
    p.room = room;
    p.seq = seq;
    p.frame = frame;
    p.mask = mask;
    p.flags = flags;
    memset(p.tag, 0, kTagLen);
    computeTag(p, payload, payloadLen, key, p.tag);

    memcpy(out, &p, kHeaderLen);
    if (payloadLen) memcpy(out + kHeaderLen, payload, payloadLen);
    return total;
}

size_t encodeInputBatch(uint32_t room, uint32_t seq, uint32_t newestFrame,
                        const uint16_t *masks, size_t count,
                        const uint8_t key[kKeyLen],
                        uint8_t *out, size_t outCap) {
    if (!masks || count == 0 || count > kInputBatchMax) return 0;
    const size_t payloadLen = 1 + 2 * count;
    const size_t total = kHeaderLen + payloadLen;
    if (!out || outCap < total) return 0;

    std::vector<uint8_t> payload(payloadLen);
    payload[0] = static_cast<uint8_t>(count);
    for (size_t i = 0; i < count; ++i) {
        payload[1 + 2 * i] = static_cast<uint8_t>(masks[i] & 0xFF);
        payload[2 + 2 * i] = static_cast<uint8_t>(masks[i] >> 8);
    }

    Packet p{};
    p.magic = kMagic;
    p.ver = kProtoVersion;
    p.type = PKT_INPUT;
    p.room = room;
    p.seq = seq;
    p.frame = newestFrame;
    p.mask = masks[0]; // newest frame's mask, mirrored in the fixed header
    p.flags = 0;
    memset(p.tag, 0, kTagLen);
    computeTag(p, payload.data(), payloadLen, key, p.tag);

    memcpy(out, &p, kHeaderLen);
    memcpy(out + kHeaderLen, payload.data(), payloadLen);
    return total;
}

bool inputBatchShape(size_t payloadLen, uint8_t countByte, size_t &count) {
    if (payloadLen == 0) {
        count = 0;
        return true; // single-frame INPUT
    }
    count = countByte;
    if (count == 0 || count > kInputBatchMax) return false;
    return payloadLen == 1 + 2 * count;
}

RejectReason verify(const uint8_t *buf, size_t len,
                 const uint8_t key[kKeyLen], Decoded &out) {
    if (!buf || len < kHeaderLen) return REJ_BAD_LEN;
    Packet p{};
    memcpy(&p, buf, kHeaderLen);
    if (p.magic != kMagic) return REJ_BAD_MAGIC;
    if (p.ver != kProtoVersion) return REJ_BAD_VERSION;

    const size_t payloadLen = len - kHeaderLen;
    if (p.type == PKT_INPUT) {
        size_t count = 0;
        const uint8_t countByte = payloadLen > 0 ? buf[kHeaderLen] : 0;
        if (!inputBatchShape(payloadLen, countByte, count)) return REJ_BAD_LEN;
    } else if (p.type != PKT_CTRL) {
        return REJ_BAD_MAGIC;
    }

    uint8_t expect[kTagLen];
    computeTag(p, buf + kHeaderLen, payloadLen, key, expect);
    if (!tagEqual(p.tag, expect)) return REJ_BAD_TAG;

    out.hdr = p;
    if (payloadLen) out.payload.assign(buf + kHeaderLen, buf + len);
    else out.payload.clear();
    return REJ_OK;
}

const char *rejectName(RejectReason r) {
    switch (r) {
        case REJ_OK: return "ok";
        case REJ_BAD_LEN: return "badLen";
        case REJ_BAD_MAGIC: return "badMagic";
        case REJ_BAD_VERSION: return "badVersion";
        case REJ_BAD_TAG: return "badTag";
    }
    return "?";
}

} // namespace np
