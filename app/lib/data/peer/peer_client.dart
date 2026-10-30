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
  }) async {
    final req = await _http.getUrl(Uri.parse('$baseUrl$path'));
    _auth.forEach(req.headers.set);
    final res = await req.close();
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
          {void Function(int, int?)? onProgress}) =>
      _download('/api/peer/rom/$crc', dest,
          onProgress: onProgress ?? (_, _) {});

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

  void close() => _http.close(force: true);
}
