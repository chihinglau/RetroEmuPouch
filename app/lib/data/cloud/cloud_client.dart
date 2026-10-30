import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_config.dart';
import 'cloud_discovery.dart';
import 'security_policy.dart';
import '../../config/app_channel.dart';

class CloudException implements Exception {
  CloudException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// Result of an OTA update check.
class ReleaseInfo {
  ReleaseInfo({required this.j, required this.downloadUrl});
  final Map<String, dynamic> j;
  final String downloadUrl;

  int get versionCode => (j['versionCode'] as num?)?.toInt() ?? 0;
  String get versionName => (j['versionName'] as String?) ?? '';
  String get channel => (j['channel'] as String?) ?? 'stable';
  String get notes => (j['notes'] as String?) ?? '';
  bool get mandatory => j['mandatory'] == true;
  int get size => (j['size'] as num?)?.toInt() ?? 0;
  String get sha256 => (j['sha256'] as String?) ?? '';
}

/// Zero-dependency (dart:io only) HTTP client for the GamePouch cloud service.
class CloudClient {
  CloudClient(this.config);

  final CloudConfig config;

  /// Total seconds for small JSON calls. ROM/APK streams use a longer budget.
  static const Duration _jsonTimeout = Duration(seconds: 15);

  Uri _uri(String path, [Map<String, String>? query]) {
    final q = query == null || query.isEmpty
        ? null
        : query.map((k, v) => MapEntry(k, Uri.encodeQueryComponent(v)));
    final uri = Uri.parse('${config.baseUrl}$path').replace(queryParameters: q);
    // Single choke-point: every request (ROM, cover, OTA, auth, ...) is vetted
    // here so no plaintext call can slip through (P0-2).
    SecurityPolicy.assertSafe(uri);
    return uri;
  }

  HttpClient _http() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (cert, host, port) => false;
    return c;
  }

  /// Runs [action], and on a transport-level failure (no HTTP status — server
  /// unreachable / timeout) performs one cooldown-limited LAN rediscovery; if
  /// the server moved to another IP, the new base URL is persisted and the
  /// request replayed exactly once. HTTP errors (4xx/5xx) are never retried.
  Future<T> _withRediscovery<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on CloudException catch (e) {
      if (e.statusCode != null) rethrow;
      if (config.baseUrl.isEmpty) rethrow;
      final found =
          await CloudDiscovery.auto(previousUrl: config.baseUrl);
      if (found == null || found == config.baseUrl) rethrow;
      config.baseUrl = found;
      await config.save();
      return action();
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
  }) =>
      _withRediscovery(() => _jsonOnce(method, path,
          body: body, query: query, auth: auth));

  Future<Map<String, dynamic>> _jsonOnce(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
    final client = _http();
    try {
      final req = await client.openUrl(method, _uri(path, query));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (auth) {
        final t = config.token;
        if (t == null || t.isEmpty) {
          throw CloudException('尚未登录', statusCode: 401);
        }
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(_jsonTimeout);
      final text = await res.transform(utf8.decoder).join().timeout(_jsonTimeout);
      Map<String, dynamic> j = const {};
      if (text.trim().isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) j = decoded;
      }
      if (res.statusCode >= 400) {
        throw CloudException(
          (j['error'] as String?)?.trim().isNotEmpty == true
              ? j['error'] as String
              : '请求失败（${res.statusCode}）',
          statusCode: res.statusCode,
        );
      }
      return j;
    } on SocketException catch (e) {
      throw CloudException('无法连接服务器：${e.osError?.message ?? e.message}');
    } on TimeoutException {
      throw CloudException('服务器响应超时');
    } on HttpException catch (e) {
      throw CloudException(e.message);
    } finally {
      client.close(force: true);
    }
  }

  /// Streams a binary GET into [dest]. Reports 0..1 progress when the server
  /// provides content length. Returns the number of bytes written.
  Future<int> _download(
    String path, {
    Map<String, String>? query,
    required File dest,
    void Function(double progress, int received, int? total)? onProgress,
  }) async {
    final client = _http();
    try {
      final req = await client.openUrl('GET', _uri(path, query));
      final t = config.token;
      if (t != null && t.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        final text = await res.transform(utf8.decoder).join();
        String msg = '下载失败（${res.statusCode}）';
        try {
          final j = jsonDecode(text);
          if (j is Map && j['error'] is String) msg = j['error'] as String;
        } catch (_) {/* binary or empty error body */}
        throw CloudException(msg, statusCode: res.statusCode);
      }
      await dest.parent.create(recursive: true);
      final sink = dest.openWrite();
      var received = 0;
      final total = res.contentLength >= 0 ? res.contentLength : null;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(
            total == null || total == 0 ? -1 : received / total,
            received,
            total,
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return received;
    } on SocketException catch (e) {
      throw CloudException('下载中断：${e.osError?.message ?? e.message}');
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------ auth
  Future<Map<String, dynamic>> register(String name, String password) =>
      _json('POST', '/api/cloud/auth/register',
          auth: false, body: {'name': name, 'password': password});

  Future<Map<String, dynamic>> login(String name, String password) =>
      _json('POST', '/api/cloud/auth/login',
          auth: false, body: {'name': name, 'password': password});

  Future<void> logout() async {
    try {
      await _json('POST', '/api/cloud/auth/logout');
    } catch (_) {
      // local sign-out must always succeed even if the server is unreachable
    }
  }

  Future<Map<String, dynamic>> me() => _json('GET', '/api/cloud/auth/me');

  Future<void> changePassword(String oldPassword, String newPassword) =>
      _json('POST', '/api/cloud/auth/password', body: {
        'oldPassword': oldPassword,
        'newPassword': newPassword,
      });

  // ------------------------------------------------------------ catalog
  Future<List<Map<String, dynamic>>> catalog() async {
    final j = await _json('GET', '/api/cloud/catalog');
    return (j['items'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  Future<Set<String>> subscriptions() async {
    final j = await _json('GET', '/api/cloud/subscriptions');
    return ((j['crcs'] as List?) ?? const [])
        .map((e) => e.toString().toUpperCase())
        .toSet();
  }

  Future<void> setSubscriptions(List<String> crcs) async {
    await _json('POST', '/api/cloud/subscriptions',
        body: {'crcs': crcs});
  }

  // ------------------------------------------------------------ sync
  Future<Map<String, dynamic>> syncLibrary() =>
      _json('GET', '/api/cloud/sync/library');

  Future<int> downloadRom(
    String crc, {
    required File dest,
    void Function(double progress, int received, int? total)? onProgress,
  }) {
    // R1: store channels must never fetch game files — users import locally.
    if (!appChannel.canCloudRom) {
      throw UnsupportedError('此版本不下发游戏文件，请使用本地导入');
    }
    return _download('/api/cloud/sync/rom',
        query: {'crc': crc}, dest: dest, onProgress: onProgress);
  }

  Future<int> downloadCover(
    String crc, {
    required File dest,
  }) {
    if (!appChannel.canCloudRom) {
      throw UnsupportedError('此版本不下发游戏资源');
    }
    return _download('/api/cloud/cover', query: {'crc': crc}, dest: dest);
  }

  // ------------------------------------------------------------ OTA
  Future<ReleaseInfo?> checkUpdate(int versionCode, String channel) async {
    final j = await _json('GET', '/api/cloud/releases/check',
        auth: false,
        query: {'versionCode': '$versionCode', 'channel': channel});
    if (j['update'] != true) return null;
    final r = (j['release'] as Map?)?.cast<String, dynamic>();
    if (r == null) return null;
    var url = (r['downloadUrl'] as String?) ?? '';
    final base = config.baseUrl;
    if (url.startsWith('/')) {
      url = '$base$url';
    } else if (url.isNotEmpty && base.isNotEmpty) {
      // Normalize to the origin that actually served this check: the
      // server-advertised URL may carry a stale/other-interface host after a
      // Wi-Fi switch, and must stay on 127.0.0.1 under an adb-reverse tunnel.
      try {
        final u = Uri.parse(url);
        final rel = u.hasQuery ? '${u.path}?${u.query}' : u.path;
        url = Uri.parse(base).resolve(rel).toString();
      } catch (_) {/* keep the server-provided URL */}
    }
    return ReleaseInfo(j: r, downloadUrl: url);
  }

  /// Downloads an APK. [url] may carry its own `?token=` query parameter;
  /// the Bearer header is also sent for same-origin requests.
  Future<int> downloadRelease(
    String url, {
    required File dest,
    void Function(double progress, int received, int? total)? onProgress,
  }) async {
    final u = Uri.parse(url);
    // _download works with same-origin paths; absolute URLs point at the same
    // service by contract, so strip the origin.
    final path = u.hasQuery ? '${u.path}?${u.query}' : u.path;
    return _download(path, dest: dest, onProgress: onProgress);
  }
}
