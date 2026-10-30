import 'dart:math';
import 'dart:typed_data';

/// Minimal security primitives for 「发现伙伴」(peer-to-peer LAN sharing).
///
/// Only secure random tokens and constant-time comparison are needed: peers
/// authenticate with opaque random tokens exchanged during the one-time
/// numeric-code pairing handshake, so there are no passwords and no PBKDF2.
/// Pure `dart:math`, zero third-party dependencies (same philosophy as the
/// PC cloud's crypto.dart, of which this is a trimmed port).
class PeerCrypto {
  static final Random _rng = Random.secure();

  static final _hexChars = '0123456789abcdef'.codeUnits;

  /// Lowercase hex encoding of [bytes].
  static String hex(List<int> bytes) {
    final out = Uint8List(bytes.length * 2);
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i] & 0xFF;
      out[i * 2] = _hexChars[b >> 4];
      out[i * 2 + 1] = _hexChars[b & 0x0F];
    }
    return String.fromCharCodes(out);
  }

  /// [bytes] of cryptographically secure random data, hex encoded
  /// (so [bytes]=32 yields a 64-char token).
  static String randomHex(int bytes) {
    final b = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      b[i] = _rng.nextInt(256);
    }
    return hex(b);
  }

  /// A fresh 6-digit pairing code as a zero-padded string ("042917").
  static String pairingCode() => _rng.nextInt(1000000).toString().padLeft(6, '0');

  /// Constant-time string comparison to avoid trivial timing probes.
  static bool fixedTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// SHA-256 digest of [data] (FIPS 180-4), pure Dart.
  static Uint8List sha256(List<int> data) => _Sha256.hash(data);

  /// HMAC-SHA256 (RFC 2104). Keys longer than the 64-byte block are first
  /// hashed, exactly as the native `gs_hmac_sha256` does, so frame-packet
  /// tags computed on either side are byte-identical for the same inputs.
  static Uint8List hmacSha256({
    required List<int> key,
    required List<int> data,
  }) {
    var k = Uint8List.fromList(key);
    if (k.length > 64) k = _Sha256.hash(k);
    final block = Uint8List(64);
    block.setRange(0, k.length, k);
    final ipad = Uint8List(64);
    final opad = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      ipad[i] = block[i] ^ 0x36;
      opad[i] = block[i] ^ 0x5c;
    }
    final inner = _Sha256.hash([...ipad, ...data]);
    return _Sha256.hash([...opad, ...inner]);
  }

  /// Lowercase hex of [hmacSha256] (64 chars for a 32-byte digest).
  static String hmacSha256Hex({required List<int> key, required List<int> data}) =>
      hex(hmacSha256(key: key, data: data));
}

/// Minimal self-contained SHA-256 implementation (no external packages).
class _Sha256 {
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  static Uint8List hash(List<int> input) {
    final bytes = Uint8List.fromList(input);
    final bitLen = bytes.length * 8;
    // Padded length must be a multiple of 64: message + 0x80 + zeros + 8.
    final paddedLen = ((bytes.length + 8) ~/ 64 + 1) * 64;
    final padded = Uint8List(paddedLen);
    padded.setRange(0, bytes.length, bytes);
    padded[bytes.length] = 0x80;
    // 64-bit big-endian length; lengths fit in 32 bits for our payloads but
    // emit the full field per the spec.
    final hi = (bitLen ~/ 0x100000000) & 0xFFFFFFFF;
    final lo = bitLen & 0xFFFFFFFF;
    padded[paddedLen - 8] = (hi >> 24) & 0xFF;
    padded[paddedLen - 7] = (hi >> 16) & 0xFF;
    padded[paddedLen - 6] = (hi >> 8) & 0xFF;
    padded[paddedLen - 5] = hi & 0xFF;
    padded[paddedLen - 4] = (lo >> 24) & 0xFF;
    padded[paddedLen - 3] = (lo >> 16) & 0xFF;
    padded[paddedLen - 2] = (lo >> 8) & 0xFF;
    padded[paddedLen - 1] = lo & 0xFF;

    var h0 = 0x6a09e667;
    var h1 = 0xbb67ae85;
    var h2 = 0x3c6ef372;
    var h3 = 0xa54ff53a;
    var h4 = 0x510e527f;
    var h5 = 0x9b05688c;
    var h6 = 0x1f83d9ab;
    var h7 = 0x5be0cd19;

    final w = List<int>.filled(64, 0);
    for (var off = 0; off < padded.length; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = ((padded[off + i * 4] << 24) |
                (padded[off + i * 4 + 1] << 16) |
                (padded[off + i * 4 + 2] << 8) |
                padded[off + i * 4 + 3]) &
            0xFFFFFFFF;
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^
            _rotr(w[i - 15], 18) ^
            ((w[i - 15] >> 3) & 0x1FFFFFFF);
        final s1 = _rotr(w[i - 2], 17) ^
            _rotr(w[i - 2], 19) ^
            ((w[i - 2] >> 10) & 0x3FFFFF);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
        final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xFFFFFFFF;
        hh = g;
        g = f;
        f = e;
        e = (d + t1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xFFFFFFFF;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + hh) & 0xFFFFFFFF;
    }

    final out = Uint8List(32);
    final hs = [h0, h1, h2, h3, h4, h5, h6, h7];
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (hs[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (hs[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (hs[i] >> 8) & 0xFF;
      out[i * 4 + 3] = hs[i] & 0xFF;
    }
    return out;
  }
}
