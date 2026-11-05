/// 同意门的纯判定逻辑（2026-11-05 从 ConsentGate 抽出，便于单测）。
///
/// 不依赖 Flutter、网络或存储；只做决策。ConsentGate 负责读写与 UI，
/// 决策全部委托给这里，避免把"首次/升版/离线"三态埋在 Widget 的异步流程里。
library;

import 'dart:convert';

/// 冷启动两种结果：展示欢迎页，或直接进入主应用。
enum ConsentGateDecision { showGate, enterApp }

/// 单个文档的版本状态（后端 `/api/consent/status` 返回 + 本地待办缓存）。
class ConsentDocVersion {
  final String docKey;
  final int latestPublishedVersion;
  final int? myConsentedVersion;
  final bool needsReconsent;

  const ConsentDocVersion({
    required this.docKey,
    required this.latestPublishedVersion,
    this.myConsentedVersion,
    required this.needsReconsent,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'doc_key': docKey,
        'latest_published_version': latestPublishedVersion,
        'my_consented_version': myConsentedVersion,
        'needs_reconsent': needsReconsent,
      };

  static ConsentDocVersion? fromJson(Object? e) {
    if (e is! Map) return null;
    final m = e.cast<String, dynamic>();
    final key = m['doc_key'] as String? ?? '';
    if (key.isEmpty) return null;
    return ConsentDocVersion(
      docKey: key,
      latestPublishedVersion:
          (m['latest_published_version'] as num?)?.toInt() ?? 1,
      myConsentedVersion: (m['my_consented_version'] as num?)?.toInt(),
      needsReconsent: m['needs_reconsent'] as bool? ?? true,
    );
  }
}

/// 本地是否已有任何同意记录。`consent_ver_*` 是新版，
/// `consent_given` 是老版本留下的兼容标记。
bool hasPriorConsent(Map<String, int> acceptedVersions, bool legacyConsentGiven) =>
    acceptedVersions.isNotEmpty || legacyConsentGiven;

/// 冷启动决策：**只有首次安装或政策升版**才展示欢迎页。
ConsentGateDecision decideConsentGate({
  required bool hasPriorConsent,
  required bool reconsentPending,
}) =>
    (!hasPriorConsent || reconsentPending)
        ? ConsentGateDecision.showGate
        : ConsentGateDecision.enterApp;

/// 距上次版本校验是否已超过 [interval]；从未校验过（0）也需要校验。
bool shouldRecheckConsent(
  int checkedAtMs,
  DateTime now, {
  Duration interval = const Duration(hours: 24),
}) =>
    checkedAtMs <= 0 ||
    now.millisecondsSinceEpoch - checkedAtMs >= interval.inMilliseconds;

/// 单篇文档是否需要重新征求同意。
///
/// 本地已同意**当前最新版本**时直接跳过：避免后端同意记录写入失败导致
/// 用户被反复弹窗（这正是旧实现无限增长 consent_records 的成因之一）。
bool needsReconsentForDoc(
        ConsentDocVersion doc, Map<String, int> acceptedVersions) {
  final local = acceptedVersions[doc.docKey];
  if (local != null && local >= doc.latestPublishedVersion) return false;
  return doc.needsReconsent ||
      (doc.myConsentedVersion ?? 0) < doc.latestPublishedVersion;
}

List<ConsentDocVersion> docsNeedingReconsent(
        Iterable<ConsentDocVersion> statuses,
        Map<String, int> acceptedVersions) =>
    statuses
        .where((s) => needsReconsentForDoc(s, acceptedVersions))
        .toList(growable: false);

/// 解析 `consent_versions` JSON；损坏时返回 null，由调用方回退到
/// 逐项读取 `consent_ver_<docKey>`。
Map<String, int>? parseConsentVersions(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return decoded.map(
        (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0));
  } catch (_) {
    return null;
  }
}
