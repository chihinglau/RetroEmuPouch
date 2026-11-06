import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show kDebugMode;

import '../../features/account/account_backend.dart'
    show
        AccountStore,
        effectiveBaseUrl,
        kAccountToken,
        kAccountUserId,
        kAccountRefreshToken;
import '../../features/cloud/cloud_crypto.dart';
import 'cloud_save_models.dart';
import 'security_policy.dart';

// 兼容既有导入：`import 'cloud_client.dart' show CloudSaveSummary` 仍然可用。
export 'cloud_save_models.dart' show CloudSaveSummary, CloudSaveTransport;

// ============================================================================
// 异常
// ============================================================================

class CloudException implements Exception {
  CloudException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

// ============================================================================
// CloudClient — RetroEmuPouch 账号/云存档后端客户端
// ============================================================================

/// 对接 `tools/account_backend` 的 HTTP 客户端。
///
/// 负责 RetroEmuPouch 后端路由（auth / billing / cloud saves / consent /
/// cms / pairing）。**不再包含** PC 管理台专属的 catalog / subscriptions /
/// cloud ROM 下载等路由——那些功能由独立服务承载，且本后端完全没有。
///
/// 鉴权 token 和 base URL 都从 [AccountStore] 读取（与 [HttpAccountService] /
/// [HttpReceiptVerifier] 共享同一份登录态），避免 CloudConfig / 安全存储那套
/// 过时的平行状态。
class CloudClient implements CloudSaveTransport {
  CloudClient(this._store);
  final AccountStore _store;

  /// 云存档列表的**本地磁盘缓存**：跨冷启动复用，TTL 内打开页面不联网。
  /// 内存层只是进程内快速路径，磁盘层才是"本地缓存"的本体。
  ///
  /// 一次打开「网络」页里 `_refresh()` 与 `sync.listCloud()` 会各调一次
  /// [listSaves]，缓存也能把这两次合并掉。上传 / 删除 / 手动刷新后失效。
  /// 缓存 key 用 `base|userId`，**不能用 access_token**：后者 15 分钟刷新一次，
  /// 拿它做 key 会导致缓存几乎永远不命中（上一版的疏漏）。
  static const Duration savesListTtl = Duration(minutes: 30);
  static const String _kListJson = 'cloud_saves_list_json';
  static const String _kListAt = 'cloud_saves_list_at';
  static const String _kListKey = 'cloud_saves_list_key';

  static List<CloudSaveSummary>? _savesListCache;
  static DateTime? _savesListCacheAt;
  static String? _savesListCacheKey;

  static List<CloudSaveSummary>? _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((m) => CloudSaveSummary.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static bool _fresh(int atMs) =>
      atMs > 0 &&
      DateTime.now().millisecondsSinceEpoch - atMs <
          savesListTtl.inMilliseconds;

  /// 让缓存失效（内存 + 磁盘）。上传 / 删除成功后、以及用户手动刷新时调用。
  Future<void> invalidateSavesCache() async {
    _savesListCache = null;
    _savesListCacheAt = null;
    _savesListCacheKey = null;
    try {
      await _store.remove(_kListJson);
      await _store.remove(_kListAt);
      await _store.remove(_kListKey);
    } catch (_) {}
  }

  Future<String> get _base async => await effectiveBaseUrl(_store);
  String get _token => _store.getString(kAccountToken) ?? '';

  /// 用 refresh_token 换新 access_token（与 [HttpAccountService] 同款逻辑）。
  ///
  /// 云存档走独立的 [CloudClient]，此前没有这套自动续期：access_token（15 分钟）
  /// 过期后，云存储请求带着过期 token 直发后端被 401 拒绝，表现为"云存储连不上"。
  /// 这里补上，并在 [_json] / [uploadSave] / [listSaves] / [downloadSave] 的 401
  /// 分支触发它、换新后无缝重试一次。
  Future<bool> _refresh() async {
    final rt = _store.getString(kAccountRefreshToken) ?? '';
    if (rt.isEmpty) return false;
    try {
      final j = await _json('POST', '/api/auth/refresh',
          auth: false, body: {'refresh_token': rt});
      final at = (j['access_token'] as String?)?.trim() ?? '';
      if (at.isEmpty) return false;
      await _store.setString(kAccountToken, at);
      final nrt = (j['refresh_token'] as String?)?.trim() ?? '';
      if (nrt.isNotEmpty) await _store.setString(kAccountRefreshToken, nrt);
      return true;
    } catch (_) {
      return false;
    }
  }

  HttpClient _http() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = _acceptDebugCert;
    return c;
  }

  /// debug 模式下对回环 + RFC1918 私网的自签证书放行。
  static bool _acceptDebugCert(X509Certificate cert, String host, int port) {
    if (!kDebugMode) return false;
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return true;
    final p = host.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]);
    final b = int.tryParse(p[1]);
    if (a == null || b == null) return false;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  // ------------------------------------------------------- 后端错误信息解析
  /// 后端（FastAPI）错误体是 `{"detail": ...}`，历史实现还带 `error` 键；
  /// 两者都认，并把已知错误码翻成中文（原始码保留在括号里便于排障）。
  static String? errorOf(Object? decoded) {
    if (decoded is! Map) return null;
    final err = decoded['error'];
    if (err is String && err.trim().isNotEmpty) {
      return _friendlyError(err.trim());
    }
    final detail = decoded['detail'];
    if (detail is String && detail.trim().isNotEmpty) {
      return _friendlyError(detail.trim());
    }
    if (detail is List && detail.isNotEmpty) {
      final first = detail.first;
      if (first is Map && first['msg'] is String) return first['msg'] as String;
    }
    return null;
  }

  static String _friendlyError(String raw) {
    switch (raw) {
      case 'cloud_save_requires_premium':
        return '云存档需要会员';
      case 'too_large':
        return '存档超过 10MB 上限';
      case 'forbidden_keyword':
        return '文件名含受限关键词，ROM/BIOS 不允许上传';
      case 'bad_save_name':
        return '存档文件名不合法';
      case 'blob_not_found':
        return '云端存档不存在或已被删除';
    }
    if (raw.startsWith('extension_not_allowed')) {
      final m = RegExp(r'got\s+(\S+)\)').firstMatch(raw);
      return '存档扩展名不允许${m == null ? '' : '（${m.group(1)}）'}';
    }
    return raw;
  }

  /// 把网络层异常统一转成 [CloudException]，避免 UI 层只 catch
  /// [CloudException] 时漏出未处理的 SocketException / TimeoutException。
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on CloudException {
      rethrow;
    } on SocketException catch (e) {
      throw CloudException('无法连接服务器：${e.osError?.message ?? e.message}');
    } on TimeoutException {
      throw CloudException('服务器响应超时');
    } on HttpException catch (e) {
      throw CloudException(e.message);
    } on HandshakeException catch (e) {
      throw CloudException('TLS 握手失败：${e.message}');
    }
  }

  // ---------------------------------------------------------------- JSON
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    bool retried = false,
  }) async {
    final base = await _base;
    if (base.isEmpty) {
      throw CloudException('未配置后端地址');
    }
    final q = query == null || query.isEmpty
        ? null
        : query.map((k, v) => MapEntry(k, Uri.encodeQueryComponent(v)));
    final uri = Uri.parse('$base$path').replace(queryParameters: q);
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      final j = await _guard(() async {
        final req = await client.openUrl(method, uri);
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (auth) {
          final t = _token;
          if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
        }
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close().timeout(const Duration(seconds: 15));
        final text = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        Map<String, dynamic> j = const {};
        if (text.trim().isNotEmpty) {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) j = decoded;
        }
        if (res.statusCode >= 400) {
          throw CloudException(
            errorOf(j) ?? '请求失败（${res.statusCode}）',
            statusCode: res.statusCode,
          );
        }
        return j;
      });
      return j;
    } on CloudException catch (e) {
      // access_token 过期：用 refresh_token 换新后无缝重试一次。
      if (auth && !retried && e.statusCode == 401) {
        if (await _refresh()) {
          return _json(method, path,
              body: body, query: query, auth: auth, retried: true);
        }
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  // ==========================================================================
  // 云存档 —— POST /api/cloud/saves/upload, GET|DELETE /api/cloud/saves/*
  // ==========================================================================

  /// 上传云存档（multipart/form-data）。
  ///
  /// [saveName] 存档文件名（例如 `FF7_SAVE_001.sav`）。
  /// [clientKey] 客户端侧唯一标识（例如 `gameId_slot_0`）。后端按
  /// `sha256(clientKey + salt)` 落库；同一用户同一 clientKey 再次上传会**覆盖**
  /// 原 blob（id 不变），因此备份类操作应传稳定 key，避免无限堆积。
  /// [file] 存档文件（**明文**）；本方法先以 [passphrase] 做 AES-256-GCM 加密，
  /// 再上传密文，服务端不解密。
  /// [passphrase] 云存档密码（用于派生密钥；见 [CloudCrypto]）。
  /// 返回新存档的 server-assigned id。
  @override
  Future<String> uploadSave({
    required String saveName,
    required String clientKey,
    required File file,
    required String passphrase,
    bool retried = false,
  }) async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    if (!await file.exists()) throw CloudException('存档文件不存在');

    final uri = Uri.parse('$base/api/cloud/saves/upload');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      final id = await _guard(() async {
        final req = await client.postUrl(uri);
        final t = _token;
        if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');

        // 手写 multipart/form-data（dart:io 无现成 Form 类）
        // boundary 值本身不要带前导 `--`（分隔符由下面显式拼 `--$boundary`）。
        final boundary = 'retroemupouch-${DateTime.now().microsecondsSinceEpoch}'
            '-${file.path.hashCode.abs()}';
        const crlf = '\r\n';
        req.headers.contentType = ContentType('multipart', 'form-data',
            parameters: {'boundary': boundary});

        // 客户端加密后再上传（合规红线：服务端只存密文）。
        final plain = await file.readAsBytes();
        final fileBytes = await CloudCrypto.encrypt(plain, passphrase);

        // 首段必须是 `--boundary`：它前面不允许有前导 CRLF（否则被当成 preamble）。
        // save_name
        req.write('--$boundary$crlf');
        req.write('Content-Disposition: form-data; name="save_name"$crlf$crlf');
        req.write('$saveName$crlf');

        // client_key
        req.write('--$boundary$crlf');
        req.write('Content-Disposition: form-data; name="client_key"$crlf$crlf');
        req.write('$clientKey$crlf');

        // file
        req.write('--$boundary$crlf');
        req.write(
            'Content-Disposition: form-data; name="file"; filename="$saveName"$crlf');
        req.write('Content-Type: application/octet-stream$crlf$crlf');
        req.add(fileBytes);
        req.write('$crlf--$boundary--$crlf');

        final res = await req.close().timeout(const Duration(seconds: 60));
        final text = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));

        if (res.statusCode >= 400) {
          if (!retried && res.statusCode == 401) {
            if (await _refresh()) {
              return uploadSave(
                saveName: saveName,
                clientKey: clientKey,
                file: file,
                passphrase: passphrase,
                retried: true,
              );
            }
          }
          Map<String, dynamic> j = const {};
          try {
            final d = jsonDecode(text);
            if (d is Map<String, dynamic>) j = d;
          } catch (_) {}
          throw CloudException(
            errorOf(j) ?? '上传失败（${res.statusCode}）',
            statusCode: res.statusCode,
          );
        }
        final j = jsonDecode(text);
        final saveId = (j is Map ? j['save_id'] : null) as String?;
        if (saveId == null || saveId.isEmpty) {
          throw CloudException('上传成功但未返回 save_id');
        }
        return saveId;
      });
      await invalidateSavesCache();
      return id;
    } finally {
      client.close(force: true);
    }
  }

  /// 列出当前用户的全部云端存档（后端按 updated_at DESC 排序）。
  /// 后端 `GET /api/cloud/saves/list` 直接返回 JSON 数组，不走 `_json`。
  @override
  Future<List<CloudSaveSummary>> listSaves({bool retried = false}) async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    final cacheKey = '$base|${_store.getString(kAccountUserId) ?? ''}';

    // 1) 内存缓存：同一进程内反复打开页面直接命中。
    // retried 时跳过缓存，强制走联网重试。
    final mem = _savesListCache;
    final memAt = _savesListCacheAt;
    if (!retried &&
        mem != null &&
        memAt != null &&
        _savesListCacheKey == cacheKey &&
        DateTime.now().difference(memAt) < savesListTtl) {
      return mem;
    }
    // 2) 磁盘缓存：跨冷启动命中，页面秒开、不联网。
    final disk = _readDiskCache(cacheKey);
    if (!retried && disk != null) return disk;

    // 3) 都没命中才真正联网。
    final uri = Uri.parse('$base/api/cloud/saves/list');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      late final List<CloudSaveSummary> result;
      try {
        result = await _guard(() async {
          final req = await client.getUrl(uri);
          final t = _token;
          if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
          final res = await req.close().timeout(const Duration(seconds: 15));
          final text = await res
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 15));
          if (res.statusCode >= 400) {
            if (!retried && res.statusCode == 401) {
              if (await _refresh()) {
                return listSaves(retried: true);
              }
            }
            Map<String, dynamic> j = const {};
            try {
              final d = jsonDecode(text);
              if (d is Map<String, dynamic>) j = d;
            } catch (_) {}
            throw CloudException(
              errorOf(j) ?? '列表获取失败（${res.statusCode}）',
              statusCode: res.statusCode,
            );
          }
          final decoded = jsonDecode(text);
          final List list = decoded is List ? decoded : const [];
          return list
              .whereType<Map>()
              .map((m) => CloudSaveSummary.fromJson(m.cast<String, dynamic>()))
              .toList();
        });
      } on CloudException {
        // 断网 / 后端不可达：用过期缓存兜底，页面不会变空白。
        final stale = _decodeList(_store.getString(_kListJson));
        if (stale != null && _store.getString(_kListKey) == cacheKey) {
          _remember(cacheKey, stale);
          return stale;
        }
        rethrow;
      }
      _remember(cacheKey, result);
      await _persistList(cacheKey, result);
      return result;
    } finally {
      client.close(force: true);
    }
  }

  List<CloudSaveSummary>? _readDiskCache(String key) {
    if (_store.getString(_kListKey) != key) return null;
    final atMs = int.tryParse(_store.getString(_kListAt) ?? '') ?? 0;
    if (!_fresh(atMs)) return null;
    final list = _decodeList(_store.getString(_kListJson));
    if (list != null) _remember(key, list);
    return list;
  }

  void _remember(String key, List<CloudSaveSummary> list) {
    _savesListCache = list;
    _savesListCacheAt = DateTime.now();
    _savesListCacheKey = key;
  }

  Future<void> _persistList(String key, List<CloudSaveSummary> list) async {
    try {
      await _store.setString(
          _kListJson, jsonEncode(list.map((s) => s.toJson()).toList()));
      await _store.setString(_kListKey, key);
      await _store.setString(
          _kListAt, DateTime.now().millisecondsSinceEpoch.toString());
    } catch (_) {}
  }

  /// 下载指定存档到 [dest]。返回写入字节数（明文）。
  /// 后端只存密文，本方法下载后即时以 [passphrase] 解密再落盘。
  @override
  Future<int> downloadSave(
    String saveId, {
    required File dest,
    required String passphrase,
    bool retried = false,
  }) async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    final uri = Uri.parse('$base/api/cloud/saves/$saveId');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      return await _guard(() async {
        final req = await client.getUrl(uri);
        final t = _token;
        if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
        final res = await req.close().timeout(const Duration(seconds: 60));
        if (res.statusCode >= 400) {
          if (!retried && res.statusCode == 401) {
            if (await _refresh()) {
              return downloadSave(saveId,
                  dest: dest, passphrase: passphrase, retried: true);
            }
          }
          Map<String, dynamic> j = const {};
          try {
            final text = await res.transform(utf8.decoder).join();
            final d = jsonDecode(text);
            if (d is Map<String, dynamic>) j = d;
          } catch (_) {}
          throw CloudException(
            errorOf(j) ?? '下载失败（${res.statusCode}）',
            statusCode: res.statusCode,
          );
        }
        // 收集密文 → 校验 sha256 → 客户端解密 → 落盘明文。
        final cipher = <int>[];
        await for (final chunk in res) {
          cipher.addAll(chunk);
        }
        final cipherBytes = Uint8List.fromList(cipher);
        final want = res.headers.value('x-save-sha256');
        if (want != null && want.isNotEmpty) {
          final got = (await Sha256().hash(cipherBytes)).bytes;
          final gotHex =
              got.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          if (gotHex != want.toLowerCase()) {
            throw CloudException('下载校验失败：密文校验和与服务器不一致，请重试');
          }
        }
        late final Uint8List plain;
        try {
          plain = await CloudCrypto.decrypt(cipherBytes, passphrase);
        } catch (_) {
          // GCM tag 校验失败几乎只有两种原因：密码错 / 密文损坏。
          throw CloudException('解密失败：云存档密码不正确，或文件已损坏');
        }
        await dest.parent.create(recursive: true);
        final sink = dest.openWrite(mode: FileMode.write);
        try {
          sink.add(plain);
          await sink.flush();
        } finally {
          await sink.close();
        }
        return plain.length;
      });
    } finally {
      client.close(force: true);
    }
  }

  /// 删除指定云端存档。
  @override
  Future<void> deleteSave(String saveId) async {
    await _json('DELETE', '/api/cloud/saves/$saveId');
    await invalidateSavesCache();
  }
}

// ============================================================================
// 遗留：静态工具（保留供 peer_sync.dart 使用）
// ============================================================================

/// 按平台 id 推出 ROM 文件扩展名（与 CloudSyncer.extForPlatform 等价）。
String romExtForPlatform(String platform) => switch (platform) {
      'fds' => '.fds',
      'gameBoy' => '.gb',
      'gba' => '.gba',
      'atari2600' => '.a26',
      'masterSystem' => '.sms',
      'genesis' => '.md',
      'mame' || 'neogeo' => '.zip',
      _ => '.nes',
    };
