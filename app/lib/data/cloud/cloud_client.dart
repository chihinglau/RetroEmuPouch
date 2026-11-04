import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;

import '../../features/account/account_backend.dart'
    show AccountStore, effectiveBaseUrl, kAccountToken;
import '../../features/cloud/cloud_crypto.dart';
import 'security_policy.dart';

// ============================================================================
// 异常 + 云存档数据模型
// ============================================================================

class CloudException implements Exception {
  CloudException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// 云端存档摘要（来自 `GET /api/cloud/saves/list`）。
class CloudSaveSummary {
  CloudSaveSummary({
    required this.id,
    required this.saveName,
    required this.sizeBytes,
    required this.sha256,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String saveName;
  final int sizeBytes;
  final String sha256;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory CloudSaveSummary.fromJson(Map<String, dynamic> j) {
    return CloudSaveSummary(
      id: j['id'] as String? ?? '',
      saveName: j['save_name'] as String? ?? '',
      sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
      sha256: j['sha256'] as String? ?? '',
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
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
class CloudClient {
  CloudClient(this._store);
  final AccountStore _store;

  Future<String> get _base async => await effectiveBaseUrl(_store);
  String get _token => _store.getString(kAccountToken) ?? '';

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

  // ---------------------------------------------------------------- JSON
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
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
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
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
    } on CloudException {
      rethrow;
    } on HttpException catch (e) {
      throw CloudException(e.message);
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
  /// [clientKey] 客户端侧唯一标识（例如 `gameId_slot_0`，后端用于去重判定）。
  /// [file] 存档文件（**明文**）；本方法先以 [passphrase] 做 AES-256-GCM 加密，
  /// 再上传密文，服务端不解密。
  /// [passphrase] 云存档密码（用于派生密钥；见 [CloudCrypto]）。
  /// 返回新存档的 server-assigned id。
  Future<String> uploadSave({
    required String saveName,
    required String clientKey,
    required File file,
    required String passphrase,
  }) async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    if (!await file.exists()) throw CloudException('存档文件不存在');

    final uri = Uri.parse('$base/api/cloud/saves/upload');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      final req = await client.postUrl(uri);
      final t = _token;
      if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');

      // 手写 multipart/form-data（dart:io 无现成 Form 类）
      final boundary =
          '--retroemupouch-${DateTime.now().millisecondsSinceEpoch}-${file.hashCode}';
      final LF = '\r\n';
      req.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});

      // 客户端加密后再上传（合规红线：服务端只存密文）。
      final plain = await file.readAsBytes();
      final fileBytes = await CloudCrypto.encrypt(plain, passphrase);

      // save_name
      req.write('$LF--$boundary$LF');
      req.write(
          'Content-Disposition: form-data; name="save_name"$LF$LF');
      req.write('$saveName$LF');

      // client_key
      req.write('--$boundary$LF');
      req.write('Content-Disposition: form-data; name="client_key"$LF$LF');
      req.write('$clientKey$LF');

      // file
      req.write('--$boundary$LF');
      req.write(
          'Content-Disposition: form-data; name="file"; filename="${Uri.encodeComponent(saveName)}"$LF');
      req.write('Content-Type: application/octet-stream$LF$LF');
      req.add(fileBytes);
      req.write('$LF--$boundary--$LF');

      final res = await req.close().timeout(const Duration(seconds: 30));
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));

      if (res.statusCode == 403) {
        throw CloudException('云存档需要会员', statusCode: 403);
      }
      if (res.statusCode >= 400) {
        String msg = '上传失败（${res.statusCode}）';
        try {
          final j = jsonDecode(text);
          if (j is Map && j['error'] is String) msg = j['error'] as String;
        } catch (_) {}
        throw CloudException(msg, statusCode: res.statusCode);
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      final saveId = j['save_id'] as String?;
      if (saveId == null || saveId.isEmpty) {
        throw CloudException('上传成功但未返回 save_id');
      }
      return saveId;
    } finally {
      client.close(force: true);
    }
  }

  /// 列出当前用户的全部云端存档（后端按 updated_at DESC 排序）。
  /// 后端 `GET /api/cloud/saves/list` 直接返回 JSON 数组，不走 `_json`。
  Future<List<CloudSaveSummary>> listSaves() async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    final uri = Uri.parse('$base/api/cloud/saves/list');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      final req = await client.getUrl(uri);
      final t = _token;
      if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        String msg = '列表获取失败（${res.statusCode}）';
        try {
          final j = jsonDecode(text);
          if (j is Map && j['error'] is String) msg = j['error'] as String;
        } catch (_) {}
        throw CloudException(msg, statusCode: res.statusCode);
      }
      final decoded = jsonDecode(text);
      final List list = decoded is List ? decoded : const [];
      return list
          .whereType<Map>()
          .map((m) => CloudSaveSummary.fromJson(m.cast<String, dynamic>()))
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  /// 下载指定存档到 [dest]。返回写入字节数（明文）。
  /// 后端只存密文，本方法下载后即时以 [passphrase] 解密再落盘。
  Future<int> downloadSave(
    String saveId, {
    required File dest,
    required String passphrase,
  }) async {
    final base = await _base;
    if (base.isEmpty) throw CloudException('未配置后端地址');
    final uri = Uri.parse('$base/api/cloud/saves/$saveId');
    SecurityPolicy.assertSafe(uri);
    final client = _http();
    try {
      final req = await client.getUrl(uri);
      final t = _token;
      if (t.isEmpty) throw CloudException('尚未登录', statusCode: 401);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        String msg = '下载失败（${res.statusCode}）';
        try {
          final text = await res.transform(utf8.decoder).join();
          final j = jsonDecode(text);
          if (j is Map && j['error'] is String) msg = j['error'] as String;
        } catch (_) {}
        throw CloudException(msg, statusCode: res.statusCode);
      }
      // 收集密文 → 客户端解密 → 落盘明文。
      final cipher = <int>[];
      await for (final chunk in res) {
        cipher.addAll(chunk);
      }
      final plain = await CloudCrypto.decrypt(Uint8List.fromList(cipher), passphrase);
      await dest.parent.create(recursive: true);
      final sink = dest.openWrite(mode: FileMode.write);
      try {
        sink.add(plain);
        await sink.flush();
      } finally {
        await sink.close();
      }
      return plain.length;
    } on SocketException catch (e) {
      throw CloudException('下载中断：${e.osError?.message ?? e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// 删除指定云端存档。
  Future<void> deleteSave(String saveId) async {
    await _json('DELETE', '/api/cloud/saves/$saveId');
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
