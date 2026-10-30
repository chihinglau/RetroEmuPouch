import 'dart:convert';
import 'dart:io';

/// Re-decode strings that were mistakenly read as Latin-1 over UTF-8 bytes
/// (the classic "ä¸­æ–‡" mojibake: a UTF-8 Chinese string decoded with
/// ISO-8859-1, then stored back as UTF-8). This happens when a ROM index /
/// DAT file with Chinese names is ingested through a non-UTF-8 path, and the
/// resulting `rom_index.json` carries the mojibake verbatim — both peers then
/// forward it byte-for-byte over the (correctly UTF-8) peer protocol, so the
/// receiver sees garbled Chinese even though the transport is fine.
///
/// Returns [tree] unchanged unless a string is actually mis-encoded: we only
/// accept a repair when it *introduces* CJK that the original lacked, so
/// already-correct Chinese (and any non-Latin-1 text) is never touched.
dynamic repairJsonMojibake(dynamic tree) {
  if (tree is String) {
    // 1) Percent-encoded UTF-8 (observed on device: ROM names stored as
    //    "%E4%B8%89%E5%9B%BD..." — the name was Uri-encoded during import and
    //    saved verbatim into rom_index.json). Decode when the result actually
    //    introduces CJK the original lacked.
    if (tree.contains('%')) {
      try {
        final decoded = Uri.decodeComponent(tree);
        if (decoded != tree && _hasCjk(decoded) && !_hasCjk(tree)) {
          return decoded;
        }
      } catch (_) {/* malformed % sequence — not encoded text */}
    }
    // 2) Latin-1-over-UTF-8 mojibake ("ä¸­æ–‡").
    try {
      final bytes = latin1.encode(tree);
      final fixed = utf8.decode(bytes, allowMalformed: false);
      if (fixed != tree && _hasCjk(fixed) && !_hasCjk(tree)) return fixed;
    } catch (_) {
      // [latin1.encode] throws for any code point > 0xFF (already real
      // Unicode, e.g. genuine Chinese) — leave the string untouched. Catching
      // broadly is required: the encoder raises FormatException, NOT
      // ArgumentError, so a narrow `on ArgumentError` would let it escape and
      // abort the whole peer-library fetch.
    }
    return tree;
  }
  if (tree is List) {
    // Build concrete containers instead of calling tree.map(...) through
    // `dynamic`: a dynamic invocation of the generic map() instantiates its
    // type parameters to `dynamic`, yielding Map<dynamic, dynamic>, which then
    // fails the `as Map<String, dynamic>` casts in peer_client/_getJson.
    final out = <dynamic>[];
    for (final v in tree) {
      out.add(repairJsonMojibake(v));
    }
    return out;
  }
  if (tree is Map) {
    final out = <String, dynamic>{};
    tree.forEach((k, v) {
      out[k is String ? k : '$k'] = repairJsonMojibake(v);
    });
    return out;
  }
  return tree;
}

bool _hasCjk(String s) {
  for (final r in s.runes) {
    if (r >= 0x3400 && r <= 0x4DBF) return true; // CJK Ext-A
    if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK Unified
    if (r >= 0xF900 && r <= 0xFAFF) return true; // CJK Compatibility
    if (r >= 0x3000 && r <= 0x303F) return true; // CJK symbols/punct
    if (r >= 0xFF00 && r <= 0xFFEF) return true; // Fullwidth forms
  }
  return false;
}

/// File helpers shared by the peer subsystem: atomic JSON persistence
/// (write `.tmp` then rename) and tolerant JSON reads. A corrupt peer file
/// must never crash the app — callers fall back to an empty state.
class PeerFiles {
  /// Atomically write [content] to [file]: same-directory temp file,
  /// flush, then rename over the target.
  static Future<void> atomicWriteString(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }

  static Future<void> atomicWriteJson(File file, Object? data) =>
      atomicWriteString(file, const JsonEncoder.withIndent('  ').convert(data));

  /// Decode [file] as JSON; return null when missing, unreadable or malformed.
  static dynamic readJsonOrNull(File file) {
    try {
      if (!file.existsSync()) return null;
      return repairJsonMojibake(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  /// Validate that [crc] is exactly 8 hex characters and return its uppercase
  /// form; throws [ArgumentError] otherwise. Every CRC-keyed file lookup goes
  /// through this so user-controlled path segments can never escape filesDir.
  static String crc8(String crc) {
    final upper = crc.toUpperCase();
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(upper)) {
      throw ArgumentError.value(crc, 'crc', 'expected 8 hex chars');
    }
    return upper;
  }
}
