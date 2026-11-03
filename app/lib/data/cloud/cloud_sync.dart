import 'cloud_client.dart' show romExtForPlatform;

/// 遗留壳：peer_sync.dart 只引用 [extForPlatform] 这个静态工具。
///
/// 原 CloudSyncer 的 catalog / subscriptions / cloud ROM 下载等功能是
/// PC 管理台专用，RetroEmuPouch 后端没有对应路由——CloudClient 重写后
/// 这些方法已全部移除，同步功能由独立服务承载。
class CloudSyncer {
  static String extForPlatform(String platform) =>
      romExtForPlatform(platform);
}
