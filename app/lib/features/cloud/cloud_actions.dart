import 'package:flutter/material.dart';

/// 网络同步入口（**暂不可用**）。
///
/// 原实现对接 PC 管理台 `/api/cloud/sync/library` + catalog + ROM 下载，
/// RetroEmuPouch 账号后端没有这些路由；独立服务尚未接入。
/// 调用会立即返回 `null`，不阻塞 UI。
Future<Object?> runCloudSync(
  BuildContext context, {
  required Object config,
  required String filesDir,
}) async {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('网络同步功能即将上线')),
  );
  return null;
}
