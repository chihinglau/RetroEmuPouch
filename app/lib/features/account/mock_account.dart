import 'dart:async';

import 'account_backend.dart';

/// 本地桩账号服务：不连接任何真实后端，所有登录/改密/注销均为演示实现，
/// 状态持久化在 shared_preferences。后端接口确定后，把 [HttpAccountService]
/// 切为默认实现即可，UI 层无需改动（两者都实现 [AccountBackend]）。
class MockAccountService implements AccountBackend {
  final StreamController<AuthSession?> _authCtrl =
      StreamController<AuthSession?>.broadcast();
  AuthSession? _session;
  final AccountStore _store;

  MockAccountService(this._store);

  @override
  AuthSession? get session => _session;

  @override
  AccountUser? get current => _session?.user;

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

  /// 启动时恢复已登录态（模拟"记住登录"）。
  @override
  Future<AccountUser?> load() async {
    final name = _store.getString(_kName);
    if (name == null) {
      _setSession(null);
      return null;
    }
    final u = AccountUser(
      id: _store.getString(_kId) ?? 'u_$name',
      name: name,
      online: true,
    );
    _setSession(AuthSession(u, 'mock'));
    return u;
  }

  /// 一键快捷登录：返回内置演示账号。
  @override
  Future<AccountUser> quickLogin() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return _persist(const AccountUser(id: 'demo-1001', name: '演示用户'));
  }

  /// 注册新账号：演示环境等同于登录（任意非空账号密码均通过）。
  @override
  Future<AccountUser> register(String name, String password) async {
    if (name.trim().isEmpty || password.isEmpty) {
      throw Exception('请输入账号与密码');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final n = name.trim();
    return _persist(AccountUser(id: 'u_${n.hashCode}', name: n));
  }

  /// 账号密码登录：演示环境任意非空账号密码均通过。
  @override
  Future<AccountUser> login(String name, String password) async {
    if (name.trim().isEmpty || password.isEmpty) {
      throw Exception('请输入账号与密码');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final n = name.trim();
    return _persist(AccountUser(id: 'u_${n.hashCode}', name: n));
  }

  @override
  Future<void> logout() async {
    await _store.remove(_kName);
    await _store.remove(_kId);
    _setSession(null);
  }

  /// 切换账号：本地桩无法同时存在多账号，等价于退出后重新登录。
  Future<void> switchAccount() => logout();

  /// 修改密码：演示仅校验长度。
  @override
  Future<void> changePassword(String oldPw, String newPw) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (newPw.length < 6 || newPw.length > 64) {
      throw Exception('新密码需 6~64 位');
    }
    if (oldPw.isEmpty) throw Exception('请填写当前密码');
  }

  /// 账户注销：演示环境直接清空本地账号。
  @override
  Future<void> deregister() => logout();

  Future<AccountUser> _persist(AccountUser u) async {
    _setSession(AuthSession(u, 'mock'));
    await _store.setString(_kName, u.name);
    await _store.setString(_kId, u.id);
    return u;
  }

  static const _kName = 'mock_account_name';
  static const _kId = 'mock_account_id';
}
