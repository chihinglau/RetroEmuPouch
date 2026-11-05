import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../features/account/account_backend.dart'
    show AccountStore, kAccountToken, kAccountUserId, openAccountStore;
import '../../features/membership/membership.dart';
import '../../pal/platform_pal.dart';
import 'cloud_client.dart';
import 'cloud_save_sync.dart';

/// 云存档的无界面入口。
///
/// 「云存档」原先只存在于账号页的 widget 里，而「启动检查」「退出游戏自动上传」
/// 这类后台钩子拿不到密码与登录态，因此把「账号存储 + 密码读取 + 同步」抽到这里，
/// UI 与钩子共用同一套逻辑（含鸿蒙无 flutter_secure_storage 时的文件兜底）。
class CloudSaveService {
  CloudSaveService._(this.pal, this.store);

  final PlatformPal pal;
  final AccountStore store;

  static const FlutterSecureStorage _sec = FlutterSecureStorage();
  static CloudSaveService? _instance;

  /// 最近一次「启动检查」的结果，供游戏库顶部横幅读取（null = 未检查/不可用）。
  static SaveDiff? cachedDiff;
  static DateTime? cachedAt;

  /// 进程内单例：main() 与游戏库共用同一个 store，避免重复打开。
  static Future<CloudSaveService> of(PlatformPal pal) async {
    final existing = _instance;
    if (existing != null) return existing;
    final s = CloudSaveService._(pal, await openAccountStore());
    _instance = s;
    return s;
  }

  static CloudSaveService? get existing => _instance;

  // ------------------------------------------------------------------ 身份

  String? get userId {
    final id = store.getString(kAccountUserId)?.trim();
    return (id == null || id.isEmpty) ? null : id;
  }

  bool get loggedIn => (store.getString(kAccountToken) ?? '').trim().isNotEmpty;

  String get _passKey => 'cloud_save_pwd_${userId ?? 'default'}';

  /// 系统安全存储不可用（鸿蒙等无插件实现的平台）时置 true：密码落在
  /// 账号 KV 存储（应用私有文件），与登录 token 同一沙盒。
  bool passViaFallback = false;

  Future<String?> passphrase() async {
    try {
      return await _sec.read(key: _passKey);
    } catch (_) {
      passViaFallback = true;
      return store.getString(_passKey);
    }
  }

  Future<void> setPassphrase(String pwd) async {
    try {
      await _sec.write(key: _passKey, value: pwd);
      passViaFallback = false;
    } catch (_) {
      passViaFallback = true;
      await store.setString(_passKey, pwd);
    }
  }

  // ------------------------------------------------------------------ 状态

  Future<bool> entitled() async {
    try {
      final m = await Membership.instance
          .timeout(const Duration(seconds: 5), onTimeout: () => throw StateError('timeout'));
      return m.entitlement.current.cloudSaveEnabled;
    } catch (_) {
      return false;
    }
  }

  /// 登录 + 会员 + 已设密码三者齐备才返回同步器，否则 null（调用方静默跳过）。
  Future<CloudSaveSync?> syncIfReady() async {
    if (!loggedIn) return null;
    if (!await entitled()) return null;
    final pwd = await passphrase();
    if (pwd == null || pwd.isEmpty) return null;
    return CloudSaveSync(
      filesDir: await pal.filesDir(),
      client: CloudClient(store),
    );
  }

  /// 拉一次本地/云端差异并写入 [cachedDiff]。
  Future<SaveDiff?> refresh() async {
    final sync = await syncIfReady();
    if (sync == null) return null;
    final diff = sync.diff(sync.scanLocal(), await sync.listCloud());
    cachedDiff = diff;
    cachedAt = DateTime.now();
    return diff;
  }

  /// 上传所有「未上传 / 本地较新」的存档（含槽位缩略图）。
  ///
  /// 返回 null 表示前置条件不满足（未登录 / 非会员 / 未设密码）——
  /// 后台钩子应静默忽略，不要弹错误。
  Future<SaveUploadReport?> uploadPending() async {
    final sync = await syncIfReady();
    if (sync == null) return null;
    final pwd = await passphrase();
    if (pwd == null || pwd.isEmpty) return null;

    final diff = sync.diff(sync.scanLocal(), await sync.listCloud());
    final keys = [
      for (final l in diff.localOnly) l.key,
      for (final l in diff.localNewer) l.key,
    ];
    if (keys.isEmpty) return SaveUploadReport();

    final report = await sync.uploadLocal(passphrase: pwd, only: keys);
    await refresh();
    return report;
  }
}
