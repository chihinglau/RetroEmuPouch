/// 云端 CMS 配置服务。
///
/// 启动时从后端 `GET /api/cms/config` 拉取 AppConfig 键值对，覆盖
/// [LegalConstants] 的全部静态默认值。网络失败 / 后端未部署时 fallback 到
/// 本地默认值——合规红线不变，只是"默认值来源"从硬编码变成了后端下发。
///
/// 缓存策略：配置与文档正文都**落盘**（复用 [AccountStore]，鸿蒙自动走
/// PAL 文件兜底），TTL 内 [load] / [fetchDoc] 直接返回缓存、完全不联网；
/// 网络失败保留旧缓存。只有显式 `force: true`（如「关于与支持」的手动
/// 刷新）才会发起请求。这些是**公开内容**，与登录态无关，登出无需清缓存。
///
/// 接入点：main() 里 `await warmCache()` 秒读磁盘，再 `unawaited(load())`
/// 后台按 TTL 更新；使用处直接读 `CloudConfigService.instance.xxx`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../account/account_backend.dart'
    show AccountStore, kDefaultBackendUrl, openAccountStore;
import 'legal_constants.dart';

/// 单例：持有全部 AppConfig 键值对。
class CloudConfigService {
  CloudConfigService._();
  static final CloudConfigService instance = CloudConfigService._();

  /// AppConfig / CMS 文档都是低频变更的公开内容，一天校验一次足够。
  static const Duration cacheTtl = Duration(hours: 24);

  static const String _kConfigs = 'cms_configs_json';
  static const String _kConfigsAt = 'cms_configs_at';
  static const String _kDocPrefix = 'cms_doc_';
  static const String _kAtSuffix = '_at';

  /// 启动时拉取的完整配置字典；网络失败为 null。
  Map<String, String>? _configs;
  int _configsAtMs = 0;
  AccountStore? _store;
  Future<void>? _warmFuture;
  Future<bool>? _loadFuture;

  bool get loaded => _configs != null;

  /// 缓存是否过期（公开以便单测覆盖边界）。
  static bool isStale(int atMs, Duration ttl) =>
      atMs <= 0 ||
      DateTime.now().millisecondsSinceEpoch - atMs >= ttl.inMilliseconds;

  /// Test-only: inject an [AccountStore] so tests never touch real prefs / files.
  void bindStoreForTest(AccountStore store) => _store = store;

  /// Test-only: reset the singleton between cases (cache + in-flight guards).
  void resetForTest() {
    _configs = null;
    _configsAtMs = 0;
    _store = null;
    _warmFuture = null;
    _loadFuture = null;
  }

  /// 只读磁盘、不联网；main() 在首帧前调用，保证冷启动也能立刻用上缓存值。
  Future<void> warmCache() {
    final pending = _warmFuture;
    if (pending != null) return pending;
    final f = _doWarmCache();
    _warmFuture = f;
    return f;
  }

  Future<void> _doWarmCache() async {
    try {
      final store = _store ?? await openAccountStore();
      _store = store;
      final raw = store.getString(_kConfigs);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _configs = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }
      _configsAtMs = int.tryParse(store.getString(_kConfigsAt) ?? '') ?? 0;
    } catch (_) {
      // 存储不可用（极端情况）：保持内存空缓存，全部走 LegalConstants 兜底。
    }
  }

  /// 按 key 取配置，fallback 到传入的默认值。
  String get(String key, {required String fallback}) {
    return _configs?[key]?.trim().isNotEmpty == true
        ? _configs![key]!
        : fallback;
  }

  // ---- 便捷 getter（覆盖 LegalConstants 的全部静态项） ----
  String get privacyPolicyUrl =>
      get('privacy_policy_url', fallback: LegalConstants.privacyPolicyUrl);
  String get filingNumber =>
      get('filing_number', fallback: LegalConstants.filingNumber);
  String get feedbackUrl =>
      get('feedback_url', fallback: LegalConstants.feedbackUrl);
  String get feedbackEmail =>
      get('feedback_email', fallback: LegalConstants.feedbackEmail);
  String get shareMessage =>
      get('share_message', fallback: LegalConstants.shareMessage);
  String get qqGroup => get('qq_group', fallback: LegalConstants.qqGroup);
  String get wechatId => get('wechat_id', fallback: LegalConstants.wechatId);

  /// 拉取 AppConfig；TTL 内且非 force 时直接复用磁盘缓存、不联网。
  ///
  /// 注意：CMS 文档与 AppConfig 属**公开内容**，与用户在「账号后端」里填写的
  /// 私有地址（可能是 127.0.0.1 / 局域网）无关，始终从公网默认域名拉取，
  /// 保证任何用户（含未登录）都能取到一致的政策 / 配置。
  /// 返回 true=本次用上了有效配置（新拉取或有效缓存），false=仅能用内置默认。
  Future<bool> load({bool force = false}) async {
    final pending = _loadFuture;
    if (pending != null) return pending;
    final f = _doLoad(force: force);
    _loadFuture = f;
    try {
      return await f;
    } finally {
      _loadFuture = null;
    }
  }

  Future<bool> _doLoad({required bool force}) async {
    await warmCache();
    if (!force && loaded && !isStale(_configsAtMs, cacheTtl)) return true;
    final base = kDefaultBackendUrl;
    if (base.isEmpty) return loaded;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/cms/config');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return loaded;
      final j = jsonDecode(text) as Map<String, dynamic>;
      final configs = j['configs'] as Map<String, dynamic>?;
      if (configs == null) return loaded;
      final next = configs.map((k, v) => MapEntry(k, v.toString()));
      _configs = next;
      _configsAtMs = DateTime.now().millisecondsSinceEpoch;
      await _persistConfigs(next);
      return true;
    } catch (_) {
      // 保留旧缓存；后台更新失败不影响已缓存的合规内容。
      return loaded;
    }
  }

  Future<void> _persistConfigs(Map<String, String> value) async {
    try {
      final store = _store ?? await openAccountStore();
      _store = store;
      await store.setString(_kConfigs, jsonEncode(value));
      await store.setString(_kConfigsAt, _configsAtMs.toString());
    } catch (_) {}
  }

  /// 获取 CMS 文档 Markdown 正文（隐私政策 / 用户协议）。
  ///
  /// 后端：`GET /api/cms/docs/{doc_key}?lang=zh`
  /// TTL 内直接返回磁盘缓存；网络失败也返回旧缓存，只有两者都没有时才
  /// 返回 null，由调用方 fallback 到内置模板。
  Future<String?> fetchDoc(String docKey,
      {String lang = 'zh', bool force = false}) async {
    await warmCache();
    final store = _store;
    if (store == null) return null;
    final key = '$_kDocPrefix${docKey}_$lang';
    final cached = store.getString(key);
    final atMs = int.tryParse(store.getString('$key$_kAtSuffix') ?? '') ?? 0;
    if (!force &&
        cached != null &&
        cached.isNotEmpty &&
        !isStale(atMs, cacheTtl)) {
      return cached;
    }
    final base = kDefaultBackendUrl;
    if (base.isEmpty) return cached;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/cms/docs/$docKey?lang=$lang');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return cached;
      final j = jsonDecode(text) as Map<String, dynamic>;
      final c = j['content'] as String?;
      if (c == null || c.isEmpty) return cached;
      await store.setString(key, c);
      await store.setString(
          '$key$_kAtSuffix', DateTime.now().millisecondsSinceEpoch.toString());
      return c;
    } catch (_) {
      return cached;
    }
  }
}
