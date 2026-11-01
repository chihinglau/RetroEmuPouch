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

/// 账号后端抽象：把"本地桩"与"真实 HTTP 后端"统一为同一接口。
/// UI 只依赖本接口，切换实现即可在联调 / 上线之间无缝切换，无需改动界面。
///
/// 实现：
/// - [MockAccountService]：本地桩，不连接任何后端（默认）。
/// - [HttpAccountService]：真实调用 `tools/account_backend` 的 `/api/auth/*`。
abstract interface class AccountBackend {
  /// 当前已登录用户；未登录为 null。
  AccountUser? get current;

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

// ---- 运行期 / 编译期选择（联调用） ----
// 编译期：--dart-define=BACKEND=http 让调试包默认走真实后端；不传则默认桩。
// 运行期：shared_preferences 键 [_kUseHttp] 可覆盖（仅调试构建暴露开关）。
const String kUseHttpBackend = 'account_use_http';
const String kAccountBaseUrl = 'account_base_url';
const String kAccountToken = 'account_token';
const String kAccountUserId = 'account_user_id';
const String kAccountUserName = 'account_user_name';

bool buildUseHttpBackend() =>
    String.fromEnvironment('BACKEND', defaultValue: 'mock') == 'http';
