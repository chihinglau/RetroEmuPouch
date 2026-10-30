// Minimal SHA-256 + HMAC-SHA256 for GamePouch netplay packet authentication.
// Self-contained C99, no external dependencies. MAC output is truncated by
// the caller (8-byte tags on the wire). Reference vectors (FIPS 180-4 /
// RFC 4231) are exercised by the probe `selftest` mode.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GS_SHA256_DIGEST_SIZE 32
#define GS_SHA256_BLOCK_SIZE 64

typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t buffer[GS_SHA256_BLOCK_SIZE];
    size_t buflen;
} gs_sha256_ctx;

void gs_sha256_init(gs_sha256_ctx *ctx);
void gs_sha256_update(gs_sha256_ctx *ctx, const void *data, size_t len);
void gs_sha256_final(gs_sha256_ctx *ctx, uint8_t out[GS_SHA256_DIGEST_SIZE]);
void gs_sha256(const void *data, size_t len, uint8_t out[GS_SHA256_DIGEST_SIZE]);

// HMAC-SHA256; key may be any length (keys longer than the block size are
// hashed per RFC 2104). Always writes 32 bytes to out.
void gs_hmac_sha256(const uint8_t *key, size_t keyLen,
                    const uint8_t *data, size_t dataLen,
                    uint8_t out[GS_SHA256_DIGEST_SIZE]);

#ifdef __cplusplus
}
#endif
