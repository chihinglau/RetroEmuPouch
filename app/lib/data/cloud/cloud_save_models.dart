import 'dart:io';

/// 云端存档摘要（来自 `GET /api/cloud/saves/list`）。
///
/// 后端只返回元信息（文件名/大小/sha256/时间），**不返回明文**：
/// 存档在客户端以 AES-256-GCM 加密，服务端只存密文。
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

/// 云存档传输层接口 —— 由 `CloudClient` 实现（真实 HTTP），
/// 单测可注入假实现，避免把 `CloudSaveSync` 的逻辑绑死在网络上。
abstract class CloudSaveTransport {
  /// 上传一份（明文）文件；实现方负责加密与 multipart。
  Future<String> uploadSave({
    required String saveName,
    required String clientKey,
    required File file,
    required String passphrase,
  });

  Future<List<CloudSaveSummary>> listSaves();

  Future<int> downloadSave(
    String saveId, {
    required File dest,
    required String passphrase,
  });

  Future<void> deleteSave(String saveId);
}
