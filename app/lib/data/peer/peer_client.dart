import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'peer_files.dart';

/// Raised on HTTP 401 — the partner revoked us (or never paired). The UI
/// should drop this partner's stored session and offer re-pairing.
class PeerUnauthorizedException implements Exception {
  PeerUnauthorizedException(this.message);
  final String message;
  @override
  String toString() => 'PeerUnauthorized: $message';
}

/// Any non-2xx response that carries our `{error,message}` envelope.
class PeerApiException implements Exception {
  PeerApiException(this.statusCode, this.code, [this.message]);
  final int statusCode;
  final String code;
  final String? message;

  /// 202 during pairing: the responder human has not confirmed yet; the
  /// caller is expected to poll confirm again.
  bool get responderPending => code == 'responder_pending';

  @override
  String toString() => 'PeerApi($statusCode, $code${message == null ? '' : ': $message'})';
}

/// HTTP client for one partner. Every partner gets its own instance so
/// sessions/tokens never cross between devices (AC-7).
class PeerClient {
  PeerClient({
    required this.baseUrl,
    required this.selfDeviceId,
    this.token,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 5);
  }

  final String baseUrl;
  final String selfDeviceId;
  String? token;
  final HttpClient _http;

  Map<String, String> get _auth {
    final t = token;
    return t == null ? const {} : {HttpHeaders.authorizationHeader: 'Peer $t'};
  }

  Future<Map<String, dynamic>> _getJson(String path,
      {Map<String, String>? headers,
      Duration timeout = const Duration(seconds: 15)}) async {
    final req = await _http.getUrl(Uri.parse('$baseUrl$path'));
    headers?.forEach(req.headers.set);
    _auth.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    if (res.statusCode != HttpStatus.ok) {
      throw _apiError(res.statusCode, body);
    }
    return repairJsonMojibake(jsonDecode(body)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(String path, Object? payload,
      {bool auth = false,
      Duration timeout = const Duration(seconds: 25)}) async {
    final req = await _http.postUrl(Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    if (auth) _auth.forEach(req.headers.set);
    req.write(jsonEncode(payload));
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    if (res.statusCode != HttpStatus.ok) {
      throw _apiError(res.statusCode, body);
    }
    return repairJsonMojibake(jsonDecode(body)) as Map<String, dynamic>;
  }

  PeerApiException _apiError(int status, String body) {
    String code = 'http_$status';
    String? message;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        code = (j['error'] as String?) ?? code;
        message = j['message'] as String?;
      }
    } catch (_) {/* non-JSON error body */}
    return PeerApiException(status, code, message);
  }

  // ------------------------------------------------------------ discovery

  Future<Map<String, dynamic>> info() => _getJson('/api/peer/info');

  // -------------------------------------------------------------- pairing

  Future<int> startPair({
    required String pairId,
    required String code,
    required String selfName,
    required String tokenA,
  }) async {
    final r = await _postJson('/api/peer/pair/start', {
      'pairId': pairId,
      'code': code,
      'deviceId': selfDeviceId,
      'name': selfName,
      'tokenA': tokenA,
    }, timeout: const Duration(seconds: 10));
    return (r['ttlMs'] as num?)?.toInt() ?? 120000;
  }

  /// Long-polled by the initiator after its user confirms. Throws
  /// [PeerApiException] with responderPending==true when the partner human
  /// has not confirmed yet — call [confirmPair] again.
  Future<({String token, String deviceId, String name})> confirmPair(
      {required String pairId, required String code}) async {
    final r = await _postJson('/api/peer/pair/confirm', {
      'pairId': pairId,
      'code': code,
    }, timeout: const Duration(seconds: 25));
    return (
      token: r['token'] as String,
      deviceId: r['deviceId'] as String,
      name: (r['name'] as String?) ?? '伙伴',
    );
  }

  Future<void> cancelPair(String pairId) async {
    try {
      await _postJson('/api/peer/pair/cancel', {'pairId': pairId},
          timeout: const Duration(seconds: 5));
    } catch (_) {/* best effort */}
  }

  // ------------------------------------------------------------ inventory

  /// Full inventory. Large libraries (1000+ ROMs) can take >20s on the
  /// partner's first cold-cache build; allow 60s and retry once — the second
  /// pull hits the partner's short-lived cached payload.
  Future<Map<String, dynamic>> library() async {
    const timeout = Duration(seconds: 60);
    try {
      return await _getJson('/api/peer/library', timeout: timeout);
    } on TimeoutException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return _getJson('/api/peer/library', timeout: timeout);
    } on HttpException {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return _getJson('/api/peer/library', timeout: timeout);
    }
  }

  // ------------------------------------------------------------- downloads

  Future<File> _download(
    String path,
    File dest, {
    required void Function(int received, int? total) onProgress,
    void Function(Map<String, String> headers)? onHeaders,
  }) async {
    final req = await _http.getUrl(Uri.parse('$baseUrl$path'));
    _auth.forEach(req.headers.set);
    final res = await req.close();
    onHeaders?.call(_headerMap(res.headers));
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    if (res.statusCode != HttpStatus.ok) {
      final body = await res.transform(utf8.decoder).join();
      throw _apiError(res.statusCode, body);
    }
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    var received = 0;
    final total = res.contentLength >= 0 ? res.contentLength : null;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return dest;
  }

  Future<File> downloadRom(String crc, File dest,
      {void Function(int, int?)? onProgress}) async {
    String? expected;
    final file = await _download('/api/peer/rom/$crc', dest,
        onProgress: onProgress ?? (_, _) {},
        onHeaders: (h) => expected = h['x-file-crc']);
    // Verify the transferred bytes equal the SOURCE's actual on-disk CRC
    // (advertised via X-File-Crc), not the index crc32 — that one is a
    // dump-agnostic game-identity key and differs across ROM dumps, so checking
    // the file against it would reject every cross-dump import. Older hosts that
    // don't send the header are trusted as-is.
    if (expected != null && expected!.isNotEmpty) {
      final actual = _crc32HexOfFile(file);
      if (actual.toUpperCase() != expected!.toUpperCase()) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception(
            'ROM 校验失败（数据不完整或已损坏）：期望 $expected，实际 $actual');
      }
    }
    return file;
  }

  static Map<String, String> _headerMap(HttpHeaders h) {
    final m = <String, String>{};
    h.forEach((name, values) {
      if (values.isNotEmpty) m[name.toLowerCase()] = values.last;
    });
    return m;
  }

  static final List<int> _crc32Table = () {
    final t = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[i] = c;
    }
    return t;
  }();

  /// CRC-32 (8-hex uppercase) of [f], matching the host's advertised file CRC
  /// and the emulator's native Crc32File.
  static String _crc32HexOfFile(File f) {
    final table = _crc32Table;
    var crc = 0xFFFFFFFF;
    final bytes = f.readAsBytesSync();
    for (final b in bytes) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return ((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF)
        .toRadixString(16)
        .padLeft(8, '0')
        .toUpperCase();
  }

  Future<File> downloadCover(String crc, File dest,
          {void Function(int, int?)? onProgress}) =>
      _download('/api/peer/cover/$crc', dest,
          onProgress: onProgress ?? (_, _) {});

  Future<Map<String, dynamic>> downloadCheats(String crc) =>
      _getJson('/api/peer/cheats/$crc');

  Future<File> downloadSave(String crc, String kind, File dest,
      {void Function(int, int?)? onProgress}) async {
    return _download('/api/peer/save/$crc?kind=$kind', dest,
        onProgress: onProgress ?? (_, _) {});
  }

  /// List BIOS blobs the partner has available in their `system/` directory
  /// (only the names the cores require; never arbitrary files). Returns
  /// `[{'name': ..., 'size': ...}, ...]`.
  Future<List<Map<String, dynamic>>> biosList() async {
    final r = await _getJson('/api/peer/bios');
    final list = r['bios'];
    return list is List
        ? list
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList()
        : const [];
  }

  /// Download a single BIOS blob by name (name is validated against the known
  /// BIOS set on the server; traversal is impossible by construction).
  Future<File> downloadBios(String name, File dest,
          {void Function(int, int?)? onProgress}) =>
      _download('/api/peer/bios/${Uri.encodeComponent(name)}', dest,
          onProgress: onProgress ?? (_, _) {});

  // --------------------------------------------------- save/settings sync
  static final _crcRe = RegExp(r'^[0-9A-F]{8}$');

  String _crc8(String c) {
    final u = c.toUpperCase();
    if (!_crcRe.hasMatch(u)) throw ArgumentError('bad crc: $c');
    return u;
  }

  /// List saves the paired PC holds (across all CRCs). Returns
  /// `[{crc, name, size, mtime}, ...]`.
  Future<List<Map<String, dynamic>>> listSaves() async {
    final r = await _getJson('/api/peer/sync/save');
    final s = r['saves'];
    return s is List
        ? s
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList()
        : const [];
  }

  Future<File> downloadSaveFile(String crc, String name, File dest,
          {void Function(int, int?)? onProgress}) =>
      _download('/api/peer/sync/save/${_crc8(crc)}/${Uri.encodeComponent(name)}',
          dest, onProgress: onProgress ?? (_, _) {});

  /// Upload a save file to the paired PC's sync store.
  Future<void> uploadSave(String crc, String name, File file) async {
    final bytes = await file.readAsBytes();
    await _putBytes(
        '/api/peer/sync/save/${_crc8(crc)}/${Uri.encodeComponent(name)}',
        bytes);
  }

  Future<Map<String, dynamic>> getSettings() =>
      _getJson('/api/peer/sync/settings');

  Future<void> putSettings(Map<String, dynamic> settings) async {
    await _putJson('/api/peer/sync/settings', settings);
  }

  Future<void> _putBytes(String path, List<int> bytes) async {
    final req = await _http.putUrl(Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType('application', 'octet-stream');
    _auth.forEach(req.headers.set);
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 30));
    await res.drain();
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    if (res.statusCode != HttpStatus.ok) {
      final b = await res.transform(utf8.decoder).join();
      throw _apiError(res.statusCode, b);
    }
  }

  Future<Map<String, dynamic>> _putJson(String path, Object payload) async {
    final req = await _http.putUrl(Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    _auth.forEach(req.headers.set);
    req.write(jsonEncode(payload));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.transform(utf8.decoder).join().timeout(
        const Duration(seconds: 30));
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    if (res.statusCode != HttpStatus.ok) {
      throw _apiError(res.statusCode, body);
    }
    if (body.isEmpty) return const {};
    return repairJsonMojibake(jsonDecode(body)) as Map<String, dynamic>;
  }

  void close() => _http.close(force: true);
}
