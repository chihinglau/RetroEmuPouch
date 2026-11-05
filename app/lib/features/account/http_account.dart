import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

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
  final AccountStore _store;
  final StreamController<AuthSession?> _authCtrl =
      StreamController<AuthSession?>.broadcast();

  HttpAccountService(this._store);

  AuthSession? _session;

  @override
  AuthSession? get session => _session;

  @override
  AccountUser? get current => _session?.user;

  /// 订阅即先回放当前会话，再转发后续变更（单一真相源）。
  @override
  Stream<AuthSession?> get authStateChanges async* {
    yield _session;
    await for (final s in _authCtrl.stream) yield s;
  }

  void _setSession(AuthSession? s) {
    _session = s;
    if (!_authCtrl.isClosed) {
      _authCtrl.add(s);
    }
  }

  String get _baseUrl {
    final v = _store.getString(kAccountBaseUrl);
    return v != null && v.trim().isNotEmpty ? v.trim() : kDefaultBackendUrl;
  }
  String? get _token => _store.getString(kAccountToken);
  String? get _refreshToken => _store.getString(kAccountRefreshToken);

  /// 用 refresh_token 换新的 access_token（服务端 TTL 只有 15 分钟）。
  /// 返回是否成功；失败返回 false，由调用方按原 401 处理。
  Future<bool> _tryRefresh() async {
    final rt = _refreshToken;
    if (rt == null || rt.isEmpty) return false;
    try {
      final j = await _json('POST', '/api/auth/refresh',
          auth: false, body: {'refresh_token': rt});
      final at = (j['access_token'] as String?)?.trim() ?? '';
      if (at.isEmpty) return false;
      await _store.setString(kAccountToken, at);
      final nrt = (j['refresh_token'] as String?)?.trim() ?? '';
      if (nrt.isNotEmpty) await _store.setString(kAccountRefreshToken, nrt);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 账号资料（昵称 / 邮箱）变更极少：缓存有效期内进「网络」页或冷启动
  /// 都不再打 `/api/auth/me`。登出 / 换账号 / 重新登录时主动清除。
  static const String _kMeAt = 'account_me_at';
  static const Duration _meTtl = Duration(hours: 24);

  AccountUser? _cachedUserFromStore() {
    final id = _store.getString(kAccountUserId);
    final name = _store.getString(kAccountUserName);
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    return AccountUser(id: id, name: name, online: true);
  }

  Future<void> _markProfileFresh() async => _store.setString(
      _kMeAt, DateTime.now().millisecondsSinceEpoch.toString());

  @override
  Future<AccountUser?> load() async {
    final t = _token;
    if (t == null || t.isEmpty) {
      _setSession(null);
      return null;
    }
    final cached = _cachedUserFromStore();
    final at = int.tryParse(_store.getString(_kMeAt) ?? '') ?? 0;
    final fresh = at > 0 &&
        DateTime.now().millisecondsSinceEpoch - at < _meTtl.inMilliseconds;
    if (cached != null && fresh) {
      _setSession(AuthSession(cached, t));
      return cached;
    }
    try {
      final j = await _json('GET', '/api/auth/me');
      final u = _toUser(j);
      await _persistUser(j);
      await _markProfileFresh();
      _setSession(AuthSession(u, t));
      return u;
    } catch (_) {
      // 网络不可达时不要误判为「已登出」：本地凭据与资料快照都还在。
      if (cached != null) {
        _setSession(AuthSession(cached, t));
        return cached;
      }
      _setSession(null);
      return null;
    }
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
    await _store.setString(kAccountToken, tok);
    final rt = (j['refresh_token'] as String?)?.trim() ?? '';
    if (rt.isNotEmpty) await _store.setString(kAccountRefreshToken, rt);
    final me = await _json('GET', '/api/auth/me');
    final u = _toUser(me);
    await _persistUser(me);
    await _markProfileFresh();
    final s = AuthSession(u, tok);
    await _maybeStartTrial();
    _setSession(s);
    return u;
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
    await _store.setString(kAccountToken, tok);
    final rt = (j['refresh_token'] as String?)?.trim() ?? '';
    if (rt.isNotEmpty) await _store.setString(kAccountRefreshToken, rt);
    final me = await _json('GET', '/api/auth/me');
    final u = _toUser(me);
    await _persistUser(me);
    await _markProfileFresh();
    final s = AuthSession(u, tok);
    await _maybeStartTrial();
    _setSession(s);
    return u;
  }

  @override
  Future<void> logout() async {
    try {
      await _json('POST', '/api/auth/logout');
    } catch (_) {
      // 客户端清本地 token 即可，服务端无黑名单。
    }
    await _store.remove(kAccountToken);
    await _store.remove(kAccountRefreshToken);
    await _store.remove(kAccountUserId);
    await _store.remove(kAccountUserName);
    await _store.remove(_kMeAt);
    _setSession(null);
  }

  @override
  Future<void> changePassword(String oldPw, String newPw) async {
    await _json('POST', '/api/auth/change-password',
        body: {'old_password': oldPw, 'new_password': newPw});
  }

  @override
  Future<void> deregister() async {
    await _json('DELETE', '/api/auth/me');
    await _store.remove(kAccountToken);
    await _store.remove(kAccountRefreshToken);
    await _store.remove(kAccountUserId);
    await _store.remove(kAccountUserName);
    await _store.remove(_kMeAt);
    _setSession(null);
  }

  /// 首次登录时在服务端开启 7 天试用（服务端权威、单用判定）。
  /// 失败不阻断登录（下次刷新会再次尝试，服务端幂等）。
  Future<void> _maybeStartTrial() async {
    try {
      await _json('POST', '/api/billing/trial/start');
    } catch (_) {
      // 试用开启失败可忽略。
    }
  }

  // ---------------------------------------------------------------- helpers

  AccountUser _toUser(Map<String, dynamic> j) => AccountUser(
        id: (j['user_id'] ?? j['id'] ?? '').toString(),
        name: (j['display_name'] as String?)?.isNotEmpty == true
            ? j['display_name'] as String
            : (j['email'] as String? ?? '用户'),
        online: true,
      );

  Future<void> _persistUser(Map<String, dynamic> j) async {
    final id = (j['user_id'] ?? j['id']);
    final name = j['display_name'] ?? j['email'];
    if (id != null) await _store.setString(kAccountUserId, id.toString());
    if (name != null) await _store.setString(kAccountUserName, name.toString());
  }

  /// 统一 JSON 请求；复用 [SecurityPolicy] 作为唯一明文闸门（store 包只放行 HTTPS）。
  ///
  /// access_token 只有 15 分钟 TTL：带鉴权请求收到 401 时先用 refresh_token 换新
  /// 再重试一次（[retried] 防止死循环）。刷新失败按原 401 抛出。
  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    bool retried = false,
  }) async {
    final base = _baseUrl.trim();
    if (base.isEmpty) throw Exception('未配置后端地址（调试入口填写 https://...）');
    final uri = Uri.parse('$base$path');
    SecurityPolicy.assertSafe(uri);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    // dart:io 的 TLS 栈只信任系统证书库；Android/OHOS 的用户 CA（network_security_config
    // 对 dart:io 均不生效）不被认。debug 联调时，对回环地址与 RFC1918 私网（开发机/局域网
    // 常在此）放行自签证书，方便在真机用本机或局域网 https 开发服务器联调。仅 debug 放开，
    // release 不信任自签证书。
    final h = uri.host;
    if (kDebugMode && _isPrivateOrLoopback(h)) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
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
      if (res.statusCode == 401 && auth && !retried) {
        if (await _tryRefresh()) {
          return _json(method, path, body: body, auth: auth, retried: true);
        }
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

/// 回环或 RFC1918 私网地址（开发联调常连的开发机 / 局域网服务器）。
/// 与 [SecurityPolicy.allowsCleartext] 的私网判定保持一致。
bool _isPrivateOrLoopback(String host) {
  if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return true;
  final p = host.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]);
  final b = int.tryParse(p[1]);
  if (a == null || b == null) return false;
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}
