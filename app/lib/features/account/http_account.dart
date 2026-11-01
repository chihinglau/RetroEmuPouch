import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/cloud/security_policy.dart';
import 'account_backend.dart';
import 'mock_account.dart';

/// 真实账号后端实现：调用 `tools/account_backend` 的 `/api/auth/*`。
///
/// 与 [MockAccountService] 共享同一 [AccountBackend] 接口，UI 无需改动即可切换。
/// 后端契约见 `docs/design-account-backend.md`（Phase 1 已落地）：
///   POST /api/auth/register | /api/auth/login  -> { access_token, refresh_token }
///   GET  /api/auth/me                               -> { user_id, display_name, ... }
///   POST /api/auth/logout                           -> { ok: true }
///
/// 注意：真实后端 auth 路由**暂无**"修改密码 / 注销账号"端点，这两个方法先抛明确错误，
/// 待后台补齐（见设计文档 Phase 5 之外的小增补）。
class HttpAccountService implements AccountBackend {
  HttpAccountService(this._prefs);

  final SharedPreferences _prefs;
  AccountUser? _current;
  @override
  AccountUser? get current => _current;

  String get _baseUrl => _prefs.getString(kAccountBaseUrl) ?? '';
  String? get _token => _prefs.getString(kAccountToken);

  @override
  Future<AccountUser?> load() async {
    final t = _token;
    if (t == null || t.isEmpty) {
      _current = null;
      return null;
    }
    try {
      final j = await _json('GET', '/api/auth/me');
      _current = _toUser(j);
      _persistUser(j);
    } catch (_) {
      // token 失效或网络不可达：保守地视为未登录，避免卡死在错误态。
      _current = null;
    }
    return _current;
  }

  @override
  Future<AccountUser> quickLogin() =>
      throw UnsupportedError('真实后端不支持一键快捷登录，请使用账号密码');

  @override
  Future<AccountUser> register(String name, String password) async {
    if (name.trim().isEmpty || password.isEmpty) {
      throw Exception('请输入账号与密码');
    }
    final email =
        name.trim().contains('@') ? name.trim() : '${name.trim()}@local.dev';
    final j = await _json('POST', '/api/auth/register', auth: false, body: {
      'email': email,
      'password': password,
      'display_name': name.trim(),
    });
    final tok = j['access_token'] as String?;
    if (tok == null || tok.isEmpty) throw Exception('注册失败：未返回 token');
    await _prefs.setString(kAccountToken, tok);
    final me = await _json('GET', '/api/auth/me');
    _current = _toUser(me);
    _persistUser(me);
    return _current!;
  }

  @override
  Future<AccountUser> login(String name, String password) async {
    if (name.trim().isEmpty || password.isEmpty) {
      throw Exception('请输入账号与密码');
    }
    // 后端 register/login 用 email 字段；联调时允许输入不含 @ 的用户名，
    // 自动补全为本地域名，便于快速测试。
    final email =
        name.trim().contains('@') ? name.trim() : '${name.trim()}@local.dev';
    final j = await _json('POST', '/api/auth/login',
        auth: false, body: {'email': email, 'password': password});
    final tok = j['access_token'] as String?;
    if (tok == null || tok.isEmpty) throw Exception('登录失败：未返回 token');
    await _prefs.setString(kAccountToken, tok);
    final me = await _json('GET', '/api/auth/me');
    _current = _toUser(me);
    _persistUser(me);
    return _current!;
  }

  @override
  Future<void> logout() async {
    try {
      await _json('POST', '/api/auth/logout');
    } catch (_) {
      // 客户端清本地 token 即可，服务端无黑名单。
    }
    await _prefs.remove(kAccountToken);
    await _prefs.remove(kAccountUserId);
    await _prefs.remove(kAccountUserName);
    _current = null;
  }

  @override
  Future<void> changePassword(String oldPw, String newPw) async {
    await _json('POST', '/api/auth/change-password',
        body: {'old_password': oldPw, 'new_password': newPw});
  }

  @override
  Future<void> deregister() async {
    await _json('DELETE', '/api/auth/me');
    await _prefs.remove(kAccountToken);
    await _prefs.remove(kAccountUserId);
    await _prefs.remove(kAccountUserName);
    _current = null;
  }

  // ---------------------------------------------------------------- helpers

  AccountUser _toUser(Map<String, dynamic> j) => AccountUser(
        id: (j['user_id'] ?? j['id'] ?? '').toString(),
        name: (j['display_name'] as String?)?.isNotEmpty == true
            ? j['display_name'] as String
            : (j['email'] as String? ?? '用户'),
        online: true,
      );

  void _persistUser(Map<String, dynamic> j) {
    final id = (j['user_id'] ?? j['id']);
    final name = j['display_name'] ?? j['email'];
    if (id != null) _prefs.setString(kAccountUserId, id.toString());
    if (name != null) _prefs.setString(kAccountUserName, name.toString());
  }

  /// 统一 JSON 请求；复用 [SecurityPolicy] 作为唯一明文闸门（store 包只放行 HTTPS）。
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final base = _baseUrl.trim();
    if (base.isEmpty) throw Exception('未配置后端地址（调试入口填写 https://...）');
    final uri = Uri.parse('$base$path');
    SecurityPolicy.assertSafe(uri);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.openUrl(method, uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (auth) {
        final t = _token;
        if (t == null || t.isEmpty) throw Exception('尚未登录');
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join().timeout(
            const Duration(seconds: 15),
          );
      Map<String, dynamic> j = const {};
      if (text.trim().isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) j = decoded;
      }
      if (res.statusCode >= 400) {
        throw Exception(
          (j['error'] as String?)?.trim().isNotEmpty == true
              ? j['error'] as String
              : '请求失败（${res.statusCode}）',
        );
      }
      return j;
    } on SocketException catch (e) {
      throw Exception('无法连接服务器：${e.message}');
    } on HttpException catch (e) {
      throw Exception(e.message);
    } finally {
      client.close(force: true);
    }
  }
}

/// 按"运行期开关 > 编译期开关"选择账号后端实现。
/// 运行期 override 存于 [kUseHttpBackend]（仅调试构建暴露开关），否则取 [buildUseHttpBackend]。
Future<AccountBackend> createAccountBackend() async {
  final prefs = await SharedPreferences.getInstance();
  final useHttp = prefs.getBool(kUseHttpBackend) ?? buildUseHttpBackend();
  if (!useHttp) return MockAccountService();
  // 真实后端需要已配置地址；未配置则退回桩，避免启动即崩溃。
  if ((prefs.getString(kAccountBaseUrl) ?? '').trim().isEmpty) {
    return MockAccountService();
  }
  return HttpAccountService(prefs);
}
