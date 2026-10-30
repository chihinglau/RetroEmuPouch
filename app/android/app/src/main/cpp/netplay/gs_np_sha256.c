// Compact SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104).
// Written from the standard pseudocode; no third-party code.
#include "gs_np_sha256.h"

#include <string.h>

static const uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_transform(uint32_t state[8], const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = ((uint32_t)block[i * 4] << 24) |
                ((uint32_t)block[i * 4 + 1] << 16) |
                ((uint32_t)block[i * 4 + 2] << 8) |
                ((uint32_t)block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (int i = 0; i < 64; ++i) {
        uint32_t S1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + K[i] + w[i];
        uint32_t S0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void gs_sha256_init(gs_sha256_ctx *ctx) {
    ctx->state[0] = 0x6a09e667u;
    ctx->state[1] = 0xbb67ae85u;
    ctx->state[2] = 0x3c6ef372u;
    ctx->state[3] = 0xa54ff53au;
    ctx->state[4] = 0x510e527fu;
    ctx->state[5] = 0x9b05688cu;
    ctx->state[6] = 0x1f83d9abu;
    ctx->state[7] = 0x5be0cd19u;
    ctx->bitlen = 0;
    ctx->buflen = 0;
}

void gs_sha256_update(gs_sha256_ctx *ctx, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        size_t take = GS_SHA256_BLOCK_SIZE - ctx->buflen;
        if (take > len) take = len;
        memcpy(ctx->buffer + ctx->buflen, p, take);
        ctx->buflen += take;
        p += take;
        len -= take;
        if (ctx->buflen == GS_SHA256_BLOCK_SIZE) {
            sha256_transform(ctx->state, ctx->buffer);
            ctx->bitlen += (uint64_t)GS_SHA256_BLOCK_SIZE * 8;
            ctx->buflen = 0;
        }
    }
}

void gs_sha256_final(gs_sha256_ctx *ctx, uint8_t out[GS_SHA256_DIGEST_SIZE]) {
    ctx->bitlen += (uint64_t)ctx->buflen * 8;
    ctx->buffer[ctx->buflen++] = 0x80;
    if (ctx->buflen > 56) {
        while (ctx->buflen < GS_SHA256_BLOCK_SIZE) ctx->buffer[ctx->buflen++] = 0;
        sha256_transform(ctx->state, ctx->buffer);
        ctx->buflen = 0;
    }
    while (ctx->buflen < 56) ctx->buffer[ctx->buflen++] = 0;
    for (int i = 7; i >= 0; --i)
        ctx->buffer[ctx->buflen++] = (uint8_t)(ctx->bitlen >> (i * 8));
    sha256_transform(ctx->state, ctx->buffer);
    for (int i = 0; i < 8; ++i) {
        out[i * 4]     = (uint8_t)(ctx->state[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(ctx->state[i]);
    }
}

void gs_sha256(const void *data, size_t len, uint8_t out[GS_SHA256_DIGEST_SIZE]) {
    gs_sha256_ctx ctx;
    gs_sha256_init(&ctx);
    gs_sha256_update(&ctx, data, len);
    gs_sha256_final(&ctx, out);
}

void gs_hmac_sha256(const uint8_t *key, size_t keyLen,
                    const uint8_t *data, size_t dataLen,
                    uint8_t out[GS_SHA256_DIGEST_SIZE]) {
    uint8_t k[GS_SHA256_BLOCK_SIZE];
    memset(k, 0, sizeof(k));
    if (keyLen > GS_SHA256_BLOCK_SIZE) {
        gs_sha256(key, keyLen, k); // remaining bytes stay zero
    } else {
        memcpy(k, key, keyLen);
    }
    uint8_t ipad[GS_SHA256_BLOCK_SIZE];
    uint8_t opad[GS_SHA256_BLOCK_SIZE];
    for (size_t i = 0; i < GS_SHA256_BLOCK_SIZE; ++i) {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }
    gs_sha256_ctx ctx;
    uint8_t inner[GS_SHA256_DIGEST_SIZE];
    gs_sha256_init(&ctx);
    gs_sha256_update(&ctx, ipad, sizeof(ipad));
    gs_sha256_update(&ctx, data, dataLen);
    gs_sha256_final(&ctx, inner);

    gs_sha256_init(&ctx);
    gs_sha256_update(&ctx, opad, sizeof(opad));
    gs_sha256_update(&ctx, inner, sizeof(inner));
    gs_sha256_final(&ctx, out);
}
