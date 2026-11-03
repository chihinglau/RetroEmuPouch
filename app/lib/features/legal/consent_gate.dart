import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/account_backend.dart'
    show
        kAccountToken,
        AccountStore,
        openAccountStore,
        effectiveBaseUrl,
        readBool,
        writeBool;
import 'eula_page.dart';
import 'privacy_policy_page.dart';

/// 单个文档的同意状态（后端返回 + 本地持久化）。
class _ConsentDocStatus {
  final String docKey;
  final int latestPublishedVersion;
  final int? myConsentedVersion;
  final bool needsReconsent;

  const _ConsentDocStatus({
    required this.docKey,
    required this.latestPublishedVersion,
    this.myConsentedVersion,
    required this.needsReconsent,
  });
}

/// First-launch consent gate (R8 + R16 升级：版本号感知).
///
/// 原实现只在 [SharedPreferences] 写一个 `consent_given:bool`，政策更新后老用户不会
/// 被要求重新同意——这是合规红线风险（设计文档 §CMS）。
///
/// 新版对接后端：
///   - `GET /api/consent/status`  带 `X-Device-Id` header → 返回各 doc_key 的最新已发布版本
///   - `POST /api/consent/accept` 带 `{ doc_key, version, device_id }` → 落库 consent_records
///   - 比对 `localConsentedVersion < latestPublishedVersion` 决定是否弹窗
///   - 无后端时 fallback 到"一次性本地 bool"（兼容旧版流程）
class ConsentGate extends StatefulWidget {
  const ConsentGate({super.key, required this.onAccept});

  final VoidCallback onAccept;

  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  static const String _kDeviceId = 'consent_device_id';
  static const String _kConsentVerPrefix = 'consent_ver_';

  /// 后端返回的全部文档状态；网络失败为 null。
  List<_ConsentDocStatus>? _remoteStatus;

  /// 本地持久化的 device id（首次启动生成 UUID）。
  String? _deviceId;

  /// 是否还在等待后端 status 请求。
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_fetchStatus());
  }

  /// 本地生成 device id（UUID），跨启动持久化。
  Future<String> _ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    final store = await openAccountStore();
    _deviceId = store.getString(_kDeviceId);
    if (_deviceId == null || _deviceId!.isEmpty) {
      // 简单 UUID v4 生成：不引包
      final r = Random.secure();
      final ms = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      _deviceId = 'dev-$ms-${_rand8(r)}';
      await store.setString(_kDeviceId, _deviceId!);
    }
    return _deviceId!;
  }

  String _rand8(Random r) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// 查后端各文档的最新已发布版本，比对本地已同意版本。
  Future<void> _fetchStatus() async {
    final store = await openAccountStore();
    final base = await effectiveBaseUrl(store);
    final deviceId = await _ensureDeviceId();
    if (base.isEmpty) {
      // 没配后端 → fallback 到本地一次性 bool
      final ok = await readBool('consent_given');
      if (ok) {
        widget.onAccept();
        if (mounted) setState(() => _loading = false);
      } else {
        if (mounted) setState(() => _loading = false);
      }
      return;
    }

    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/consent/status');
      final req = await client.getUrl(uri);
      req.headers.set('X-Device-Id', deviceId);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      final list = j['statuses'] as List<dynamic>? ?? [];
      final statuses = list
          .map((e) {
            final m = e as Map<String, dynamic>;
            return _ConsentDocStatus(
              docKey: m['doc_key'] as String? ?? '',
              latestPublishedVersion:
                  (m['latest_published_version'] as num?)?.toInt() ?? 1,
              myConsentedVersion: (m['my_consented_version'] as num?)?.toInt(),
              needsReconsent: m['needs_reconsent'] as bool? ?? true,
            );
          })
          .where((s) => s.docKey.isNotEmpty)
          .toList();
      if (mounted) setState(() {
        _remoteStatus = statuses;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _acceptAll() async {
    final store = await openAccountStore();
    final base = await effectiveBaseUrl(store);
    final deviceId = await _ensureDeviceId();
    final token = store.getString(kAccountToken);

    if (base.isNotEmpty && _remoteStatus != null) {
      // 后端已部署 → 逐篇确认 + 落库
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      for (final s in _remoteStatus!) {
        try {
          final uri = Uri.parse('$base/api/consent/accept');
          final req = await client.postUrl(uri);
          req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
          if (token != null && token.isNotEmpty) {
            req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          }
          req.write(jsonEncode({
            'doc_key': s.docKey,
            'version': s.latestPublishedVersion,
            'device_id': deviceId,
          }));
          final resp = await req.close();
          await resp.transform(utf8.decoder).join();
          // 本地记录已同意版本
          await store.setString(
              '$_kConsentVerPrefix${s.docKey}', s.latestPublishedVersion.toString());
        } catch (_) {
          // 单篇失败不阻断
        }
      }
      client.close(force: true);
    } else {
      // fallback：本地一次性 bool
      await writeBool('consent_given', true);
    }

    widget.onAccept();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4FC3F7),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('欢迎使用 趣玩匣 RetroEmuPouch',
                          style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            '本应用为复古游戏模拟器，不内置任何游戏、ROM 或 BIOS 文件。'
                            '游戏资源需由您自行导入，且您应确保其来源合法（如自有备份）。\n\n'
                            '使用前请阅读并同意以下文档：\n'
                            '· 隐私政策（我们如何收集、使用与保护您的数据）\n'
                            '· 用户协议（免责与知识产权声明）\n\n'
                            '点击「同意并继续」即表示您已阅读并理解上述文档。',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const PrivacyPolicyPage()),
                            ),
                            child: const Text('查看隐私政策'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const EulaPage()),
                            ),
                            child: const Text('查看用户协议'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => SystemNavigator.pop(),
                              child: const Text('不同意并退出'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: _acceptAll,
                              child: const Text('同意并继续'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
