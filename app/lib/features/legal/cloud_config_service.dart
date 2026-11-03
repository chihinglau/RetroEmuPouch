/// 云端 CMS 配置服务。
///
/// 启动时从后端 `GET /api/cms/config` 拉取 AppConfig 键值对，覆盖
/// [LegalConstants] 的全部静态默认值。网络失败 / 后端未部署时 fallback 到
/// 本地默认值，保证 App 任何时候都能用——合规红线不变，只是"默认值来源"
/// 从硬编码变成了后端下发。
///
/// 接入点：main() 里调用 [CloudConfigService.instance.load()] 即可。
/// 使用处：替换 `LegalConstants.xxx` → `CloudConfigService.instance.xxx`
/// （或用 `.get(key, fallback: 'LegalConstants.xxx')` 兜底）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../account/account_backend.dart' show openAccountStore, effectiveBaseUrl;
import 'legal_constants.dart';

/// 单例：持有全部 AppConfig 键值对。
class CloudConfigService {
  CloudConfigService._();
  static final CloudConfigService instance = CloudConfigService._();

  /// 启动时拉取的完整配置字典；网络失败为 null。
  Map<String, String>? _configs;

  bool get loaded => _configs != null;

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

  /// 启动时调用一次；返回 true=后端配置拉取成功，false=用本地默认。
  Future<bool> load() async {
    final store = await openAccountStore();
    final base = await effectiveBaseUrl(store);
    if (base.isEmpty) return false;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/cms/config');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return false;
      final j = jsonDecode(text) as Map<String, dynamic>;
      final configs = j['configs'] as Map<String, dynamic>?;
      if (configs == null) return false;
      _configs = configs.map((k, v) => MapEntry(k, v.toString()));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 获取 CMS 文档 Markdown 正文（隐私政策 / 用户协议）。
  ///
  /// 后端：`GET /api/cms/docs/{doc_key}?lang=zh`
  /// 返回 [content] 或 null（网络失败）。调用方负责 fallback 到 Asset。
  Future<String?> fetchDoc(String docKey, {String lang = 'zh'}) async {
    final store = await openAccountStore();
    final base = await effectiveBaseUrl(store);
    if (base.isEmpty) return null;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      final uri = Uri.parse('$base/api/cms/docs/$docKey?lang=$lang');
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final text = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(text) as Map<String, dynamic>;
      final c = j['content'] as String?;
      return c?.isNotEmpty == true ? c : null;
    } catch (_) {
      return null;
    }
  }
}
