import 'package:shared_preferences/shared_preferences.dart';

import 'pairing_service.dart';

/// Local-first account state. Server auth / backend is a later phase (TODO).
class AccountService {
  AccountService._(this._prefs, this.pairing);

  final SharedPreferences _prefs;
  final PairingService pairing;

  static const _kUserId = 'account.userId';
  static const _kDisplayName = 'account.displayName';

  String? get userId => _prefs.getString(_kUserId);
  String? get displayName => _prefs.getString(_kDisplayName);
  bool get isSignedIn => userId != null;

  static Future<AccountService> create() async {
    final prefs = await SharedPreferences.getInstance();
    final pairing = await PairingService.create();
    return AccountService._(prefs, pairing);
  }

  Future<void> signIn({
    required String userId,
    String? displayName,
  }) async {
    await _prefs.setString(_kUserId, userId);
    if (displayName != null) {
      await _prefs.setString(_kDisplayName, displayName);
    }
    // TODO: also call EntitlementService.ensureTrialStarted() after sign-in.
  }

  Future<void> signOut() async {
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kDisplayName);
  }
}
