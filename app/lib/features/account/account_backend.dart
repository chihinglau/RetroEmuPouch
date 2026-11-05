import 'package:shared_preferences/shared_preferences.dart';

import 'mock_account.dart';
import 'http_account.dart';

/// 账号用户模型。后端就绪后由真实接口返回的同结构对象替换。
class AccountUser {
  final String id;
  final String name;
  final bool online;

  const AccountUser({
    required this.id,
    required this.name,
    this.online = true,
  });
}

/// 账号会话：登录态的唯一真相源。包含用户与其令牌；token 非空即视为已登录。
/// 权益与购买均以会话为前提（见 design-auth-membership-entitlement.md §3.1）。
class AuthSession {
  final AccountUser user;
  final String token;
  const AuthSession(this.user, this.token);
}

/// 账号后端抽象：把"本地桩"与"真实 HTTP 后端"统一为同一接口。
/// UI 只依赖本接口，切换实现即可在联调 / 上线之间无缝切换，无需改动界面。
///
/// 实现：
/// - [MockAccountService]：本地桩，不连接任何后端（默认）。
/// - [HttpAccountService]：真实调用 `tools/account_backend` 的 `/api/auth/*`。
abstract interface class AccountBackend {
  /// 当前已登录用户；未登录为 null。
  AccountUser? get current;

  /// 当前会话；未登录为 null。
  AuthSession? get session;

  /// 登录态变更流：已登录会话 ↔ null。订阅即可联动权益与 UI（单一真相源）。
  Stream<AuthSession?> get authStateChanges;

  /// 启动时恢复登录态（本地桩读 SharedPreferences；HTTP 实现用 token 拉 /me）。
  Future<AccountUser?> load();

  /// 一键快捷登录（仅本地桩支持；真实后端应走账号密码）。
  Future<AccountUser> quickLogin();

  /// 注册新账号。真实后端调用 `/api/auth/register`；本地桩等同于演示登录。
  Future<AccountUser> register(String name, String password);

  /// 账号密码登录。真实后端按 email 处理（内部会把无 @ 的输入补全为本地域名）。
  Future<AccountUser> login(String name, String password);

  Future<void> logout();

  Future<void> changePassword(String oldPw, String newPw);

  /// 账户注销（删除云端账号数据）。
  Future<void> deregister();
}

// ---- 持久化键 ----
const String kUseHttpBackend = 'account_use_http';
const String kAccountBaseUrl = 'account_base_url';
const String kAccountToken = 'account_token';
/// 刷新令牌：access_token（15 分钟）过期后用它换新，避免"用着用着全 401"。
const String kAccountRefreshToken = 'account_refresh_token';
const String kAccountUserId = 'account_user_id';
const String kAccountUserName = 'account_user_name';

/// App 上线默认的公网后端（Cloudflare Tunnel 转发到本地）。
/// 用户可在「我的账号」页改为自建后端（IP+端口），或清空回到此默认。
const String kDefaultBackendUrl = 'https://api.gamepouch.cn';

/// 安全获取有效后端 URL：优先读用户配置 → 空则用公网默认值。
Future<String> effectiveBaseUrl(AccountStore store) async {
  final raw = (await store.getString(kAccountBaseUrl))?.trim() ?? '';
  return raw.isEmpty ? kDefaultBackendUrl : raw;
}

bool buildUseHttpBackend() =>
    String.fromEnvironment('BACKEND', defaultValue: 'mock') == 'http';

/// 是否已登录后端（存在会话 token）。会员购买 / 试用依赖该会话，
/// 未登录不应发起（权益与账号绑定，无账号即无权益）。
Future<bool> hasBackendSession() async {
  final store = await _openStore();
  return (store.getString(kAccountToken) ?? '').trim().isNotEmpty;
}

// ---- OHOS fallback store（shared_preferences 在鸿蒙无原生 handler）----
// HarmonyOS 上 `SharedPreferences.getInstance()` 会抛 MissingPluginException。
// 沿用 AppSettings / EntitlementService 的同款"梯子"：优先 shared_preferences，
// 无 handler 时落到 main() 接好的 PlatformPal 文件存储。账号相关的全部持久化
// （登录 token / 用户 id / 后端地址 / 演示账号 / 同意标记）都经此，使鸿蒙上登录态
// 也能跨启动恢复——这正是此前 `Membership.instance` 在鸿蒙抛异常（导致"会员服务
// 加载失败"）与会话永远停在未登录态（"登录界面与安卓差异大"）的根因。
class AccountStore {
  AccountStore.prefs(this._prefs) : _fb = const {};
  AccountStore.fallback(Map<String, Object> snapshot)
      : _prefs = null,
        _fb = snapshot;

  final SharedPreferences? _prefs;
  final Map<String, Object> _fb;

  String? getString(String k) => _prefs?.getString(k) ?? (_fb[k] as String?);
  bool? getBool(String k) => _prefs?.getBool(k) ?? (_fb[k] as bool?);

  Future<void> setString(String k, String v) async {
    if (_prefs != null) {
      await _prefs.setString(k, v);
      return;
    }
    _fb[k] = v;
    await _persistFb();
  }

  Future<void> setBool(String k, bool v) async {
    if (_prefs != null) {
      await _prefs.setBool(k, v);
      return;
    }
    _fb[k] = v;
    await _persistFb();
  }

  Future<void> remove(String k) async {
    if (_prefs != null) {
      await _prefs.remove(k);
      return;
    }
    _fb.remove(k);
    await _persistFb();
  }

  Future<void> _persistFb() async {
    try {
      await _fallbackSave?.call(_fb);
    } catch (_) {
      // 尽力而为：本会话仅留在内存。
    }
  }
}

Future<Map<String, Object>?> Function()? _fallbackLoad;
Future<void> Function(Map<String, Object>) ? _fallbackSave;

/// 在 main() 接好 PlatformPal 文件存储（shared_preferences 缺失的鸿蒙平台）。
void setFallbackStore({
  required Future<Map<String, Object>?> Function() load,
  required Future<void> Function(Map<String, Object>) save,
}) {
  _fallbackLoad = load;
  _fallbackSave = save;
}

/// 打开账号 KV 存储：Android 走 shared_preferences，鸿蒙走 PlatformPal 文件存储。
///
/// 缓存为**单例**：鸿蒙文件兜底下每个 AccountStore 实例只在构造时把文件快照读进
/// 内存 `_fb`、彼此不共享；若不缓存，登录 [HttpAccountService] 写入的 token 对
/// [Membership]/[ReceiptVerifier] 拿到的另一份实例不可见，导致带鉴权的请求 401。
/// 单例保证全应用共享同一份内存状态与底层存储（Android 侧 prefs 本就是单例，无影响）。
Future<AccountStore>? _openStoreCache;
Future<AccountStore> _openStore() => _openStoreCache ??= _doOpenStore();

/// Test-only: drop the cached singleton so each test can inject a fresh
/// fallback store. Never called in production (the singleton is deliberate).
void resetAccountStoreForTest() => _openStoreCache = null;

Future<AccountStore> _doOpenStore() async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {
    prefs = null;
  }
  if (prefs != null) return AccountStore.prefs(prefs);
  final snap = await _fallbackLoad?.call() ?? <String, Object>{};
  return AccountStore.fallback(snap);
}

/// 兜底感知的布尔标记——供同意页等任何需在鸿蒙持久化的开关使用。
Future<bool> readBool(String key, {bool def = false}) async =>
    (await _openStore()).getBool(key) ?? def;
Future<void> writeBool(String key, bool v) async =>
    (await _openStore()).setBool(key, v);

/// 兜底感知的账号 KV 存储（Android=shared_preferences / 鸿蒙=PlatformPal 文件存储）。
/// 供会员/收据校验等非账号后端模块读取后台地址与会话 token。切勿裸读
/// SharedPreferences——鸿蒙上 getInstance() 会抛异常，导致读不到已配置的后台地址，
/// 进而调试态 mock 购买路径不激活、会员永远"购买未完成"。
Future<AccountStore> openAccountStore() => _openStore();

/// 读取"本地桩 / 真实后端"开关与地址（带鸿蒙兜底），供调试切换入口使用。
Future<({bool useHttp, String baseUrl})> readBackendConfig() async {
  final s = await _openStore();
  return (
    useHttp: s.getBool(kUseHttpBackend) ?? buildUseHttpBackend(),
    baseUrl: s.getString(kAccountBaseUrl) ?? '',
  );
}

Future<void> writeBackendConfig(bool useHttp, String baseUrl) async {
  final s = await _openStore();
  await s.setBool(kUseHttpBackend, useHttp);
  await s.setString(kAccountBaseUrl, baseUrl);
}

// ---- 运行期 / 编译期选择 + 单例缓存 ----
// 单例确保 account_page 与 membership 持有同一后端实例，从而共享 authStateChanges。
AccountBackend? _backendInstance;

/// 清空缓存的账号后端实例（仅调试入口切换"本地桩 / 真实后端"时使用，
/// 之后下一次 [createAccountBackend] 会按最新开关重建）。
void resetAccountBackend() => _backendInstance = null;

/// 按"运行期开关 > 编译期开关"选择账号后端实现。返回单例（首次创建时恢复登录态）。
Future<AccountBackend> createAccountBackend() async {
  if (_backendInstance != null) return _backendInstance!;
  final store = await _openStore();
  final useHttp = store.getBool(kUseHttpBackend) ?? buildUseHttpBackend();
  // 真实后端模式：始终走 HttpAccountService；空地址由 HttpAccountService 回退到
  // kDefaultBackendUrl（公网域名），避免设备上因未填地址而坠入 Mock 或报"未配置"。
  AccountBackend svc;
  if (!useHttp) {
    svc = MockAccountService(store);
  } else {
    svc = HttpAccountService(store);
  }
  // 启动即恢复登录态并产出会话，订阅方首次 listen 即可拿到当前状态。
  // 恢复失败（如网络不可达）不阻断后端实例创建，避免调用方拿到未就绪实例。
  try {
    await svc.load();
  } catch (_) {}
  _backendInstance = svc;
  return svc;
}
