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
import 'consent_policy.dart';
import 'eula_page.dart';
import 'privacy_policy_page.dart';

/// 首次启动 / 政策升版时的同意门（R8 + R16：版本号感知）。
///
/// 2026-11-05 修正：旧实现把「本地已有同意记录」的跳过分支写在了
/// `base.isEmpty` 里，而 [effectiveBaseUrl] 永远回退到公网默认地址，
/// 导致该分支是死代码 —— **每次冷启动都弹欢迎页**、每次都重新 POST
/// `/api/consent/accept`，同意记录无限增长。
///
/// 现行流程：
///   - 首次安装（本地无任何同意记录）→ 展示欢迎页；
///   - 已同意 → 直接进主界面，**不联网、不闪屏**；
///   - 距上次校验超过 [recheckInterval] → 后台静默查一次
///     `GET /api/consent/status`，仅当发现 `needs_reconsent` / 版本升高时
///     记下标记，**下一次冷启动**才弹门（不打断用户正在进行的游戏）；
///   - 网络不可用时使用本地已同意版本，绝不因此把老用户挡在门外。
///
/// 入口为单一根组件（不再「runApp 两次」），因此升版后仍能切回欢迎页。
class ConsentGate extends StatefulWidget {
  const ConsentGate({super.key, required this.mainApp});

  /// 通过同意后展示的主应用。
  final WidgetBuilder mainApp;

  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  static const String _kDeviceId = 'consent_device_id';
  static const String _kConsentVerPrefix = 'consent_ver_';
  static const String _kVersions = 'consent_versions';
  static const String _kCheckedAt = 'consent_checked_at';
  static const String _kPending = 'consent_reconsent_pending';
  static const String _kPendingStatus = 'consent_pending_status';

  /// 政策 / 协议属低频变更内容，一天校验一次即可。
  static const Duration recheckInterval = Duration(hours: 24);

  /// 后端返回的全部文档状态；网络失败且无缓存时为 null。
  List<ConsentDocVersion>? _remoteStatus;

  /// 本地持久化的 device id（首次启动生成 UUID）。
  String? _deviceId;
  AccountStore? _store;

  /// 本地已同意的 `{docKey: version}`。
  Map<String, int> _accepted = <String, int>{};

  /// 是否还在读本地存储（磁盘读取，毫秒级）。
  bool _checking = true;
  bool _showGate = false;

  /// 内层 MaterialApp 的导航 key。ConsentGate 是 runApp 的根组件，其 build
  /// context 之上不存在任何 Navigator（内嵌 MaterialApp 在它下方），
  /// `Navigator.of(context)` 会抛 "does not include a Navigator"，
  /// 因此用 navigatorKey 显式拿到内层导航器。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    unawaited(_decide());
  }

  /// 冷启动判定：先看本地，再决定要不要展示欢迎页 / 后台校验。
  Future<void> _decide() async {
    final store = await openAccountStore();
    _store = store;
    _accepted = _readVersions(store);
    final legacy = await readBool('consent_given');
    final decision = decideConsentGate(
      hasPriorConsent: hasPriorConsent(_accepted, legacy),
      reconsentPending: store.getString(_kPending) == '1',
    );
    await _ensureDeviceId();

    if (decision == ConsentGateDecision.showGate) {
      if (mounted) {
        setState(() {
          _checking = false;
          _showGate = true;
        });
      }
      unawaited(_loadStatusForGate());
      return;
    }

    // 已同意：立即进主界面，不等任何网络请求。
    if (mounted) {
      setState(() {
        _checking = false;
        _showGate = false;
      });
    }
    final atMs = int.tryParse(store.getString(_kCheckedAt) ?? '') ?? 0;
    if (shouldRecheckConsent(atMs, DateTime.now(), interval: recheckInterval)) {
      unawaited(_backgroundCheck());
    }
  }

  /// 本地生成 device id（UUID），跨启动持久化。
  Future<String> _ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    final store = _store ?? await openAccountStore();
    _store = store;
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

  Map<String, int> _readVersions(AccountStore store) {
    final parsed = parseConsentVersions(store.getString(_kVersions));
    if (parsed != null) return parsed;
    // 兼容旧版：逐个读 consent_ver_<docKey>。
    final out = <String, int>{};
    for (final key in const ['privacy_policy', 'eula']) {
      final v = int.tryParse(store.getString('$_kConsentVerPrefix$key') ?? '');
      if (v != null) out[key] = v;
    }
    return out;
  }

  /// 查后端各文档的最新已发布版本；失败返回 null（调用方自行兜底）。
  Future<List<ConsentDocVersion>?> _fetchStatuses() async {
    final store = _store ?? await openAccountStore();
    _store = store;
    final base = await effectiveBaseUrl(store);
    final deviceId = await _ensureDeviceId();
    if (base.isEmpty) return null;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/consent/status');
      final req = await client.getUrl(uri);
      req.headers.set('X-Device-Id', deviceId);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(text) as Map<String, dynamic>;
      final list = j['statuses'] as List<dynamic>? ?? [];
      return list
          .map(ConsentDocVersion.fromJson)
          .whereType<ConsentDocVersion>()
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 欢迎页已展示时补齐远端版本；离线则复用上次缓存的待重新同意状态。
  Future<void> _loadStatusForGate() async {
    final remote = await _fetchStatuses();
    final store = _store;
    List<ConsentDocVersion>? statuses = remote;
    if (statuses == null && store != null) {
      final raw = store.getString(_kPendingStatus);
      if (raw != null && raw.isNotEmpty) {
        try {
          statuses = (jsonDecode(raw) as List<dynamic>)
              .map(ConsentDocVersion.fromJson)
              .whereType<ConsentDocVersion>()
              .toList();
        } catch (_) {}
      }
    }
    if (statuses != null && statuses.isNotEmpty && mounted) {
      setState(() => _remoteStatus = statuses);
    }
  }

  /// 已同意用户的静默校验：只有版本升高才登记「下次启动重新征求同意」。
  Future<void> _backgroundCheck() async {
    final store = _store ?? await openAccountStore();
    final statuses = await _fetchStatuses();
    if (statuses == null || statuses.isEmpty) {
      // 离线 / 后端不可达：不写时间戳，下次冷启动再试一次。
      return;
    }
    await store.setString(
        _kCheckedAt, DateTime.now().millisecondsSinceEpoch.toString());
    final need = docsNeedingReconsent(statuses, _accepted);
    if (need.isEmpty) {
      await store.remove(_kPending);
      await store.remove(_kPendingStatus);
      return;
    }
    await store.setString(_kPending, '1');
    await store.setString(
        _kPendingStatus, jsonEncode(need.map((s) => s.toJson()).toList()));
  }

  Future<void> _acceptAll() async {
    final store = _store ?? await openAccountStore();
    final base = await effectiveBaseUrl(store);
    final deviceId = await _ensureDeviceId();
    final token = store.getString(kAccountToken);
    final statuses = _remoteStatus;

    if (statuses != null && statuses.isNotEmpty) {
      // 后端已部署 → 逐篇确认 + 落库
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      for (final s in statuses) {
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
        } catch (_) {
          // 单篇失败不阻断：本地仍记下已同意版本，下次联网再补写服务端。
        }
        _accepted[s.docKey] = s.latestPublishedVersion;
        await store.setString('$_kConsentVerPrefix${s.docKey}',
            s.latestPublishedVersion.toString());
      }
      client.close(force: true);
    } else {
      // 完全离线：用内置最低版本占位，避免每次冷启动都被挡住。
      _accepted['privacy_policy'] = _accepted['privacy_policy'] ?? 1;
      _accepted['eula'] = _accepted['eula'] ?? 1;
    }

    await writeBool('consent_given', true);
    await store.setString(_kVersions, jsonEncode(_accepted));
    // 离线同意时不记校验时间，联网后首个冷启动会补查一次版本。
    await store.setString(_kCheckedAt,
        statuses == null ? '0' : DateTime.now().millisecondsSinceEpoch.toString());
    await store.remove(_kPending);
    await store.remove(_kPendingStatus);
    if (mounted) setState(() => _showGate = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (!_showGate) return widget.mainApp(context);

    final theme = Theme.of(context);
    return MaterialApp(
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4FC3F7),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
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
                      onPressed: () => _navKey.currentState!.push(
                        MaterialPageRoute(
                            builder: (_) => const PrivacyPolicyPage()),
                      ),
                      child: const Text('查看隐私政策'),
                    ),
                    TextButton(
                      onPressed: () => _navKey.currentState!.push(
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
