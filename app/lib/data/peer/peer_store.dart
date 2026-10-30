import 'dart:io';

import 'peer_crypto.dart';
import 'peer_files.dart';

/// One trusted partner device. [token] is the 32-byte opaque bearer secret
/// (64 hex chars) the remote device must present; [pairedAt]/[lastIp] are
/// bookkeeping. Records live in `library/peers.json` inside filesDir.
class PeerRecord {
  PeerRecord({
    required this.deviceId,
    required this.name,
    required this.token,
    required this.pairedAt,
    this.outboundToken,
    this.lastIp,
    this.lastHttpPort,
  });

  final String deviceId;
  String name;

  /// Inbound secret: the token THIS partner presents when calling our
  /// server; our server authenticates requests against it.
  final String token;

  /// Outbound secret: the token WE present when calling this partner. It
  /// was minted on this device during pairing and stored on the partner.
  /// Null for records learned before bidirectional pairing existed.
  String? outboundToken;

  final DateTime pairedAt;
  String? lastIp;

  /// Best-effort TCP fallback target; rotates whenever the partner reopens
  /// the peers page (their HTTP server uses a random port each time).
  int? lastHttpPort;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'token': token,
        'pairedAt': pairedAt.toUtc().toIso8601String(),
        if (outboundToken != null) 'outboundToken': outboundToken,
        if (lastIp != null) 'lastIp': lastIp,
        if (lastHttpPort != null) 'lastHttpPort': lastHttpPort,
      };

  static PeerRecord fromJson(Map<String, dynamic> j) => PeerRecord(
        deviceId: j['deviceId'] as String,
        name: (j['name'] as String?) ?? '伙伴',
        token: j['token'] as String,
        pairedAt: DateTime.tryParse((j['pairedAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.now(),
        outboundToken: j['outboundToken'] as String?,
        lastIp: j['lastIp'] as String?,
        lastHttpPort: (j['lastHttpPort'] as num?)?.toInt(),
      );
}

/// Trusted-partner credential store. Removing a record immediately revokes
/// access: the HTTP server authenticates every request against this list with
/// a constant-time token comparison. A corrupt peers.json yields an empty
/// store rather than crashing (and is repaired on the next save).
class PeerStore {
  PeerStore(this.filesDir, [List<PeerRecord>? peers]) : _peers = peers ?? [];

  final String filesDir;
  final List<PeerRecord> _peers;

  File get _file => File('$filesDir/library/peers.json');

  static Future<PeerStore> load(String filesDir) async {
    final j = PeerFiles.readJsonOrNull(File('$filesDir/library/peers.json'));
    final out = PeerStore(filesDir);
    if (j is Map && j['peers'] is List) {
      for (final raw in (j['peers'] as List)) {
        if (raw is Map &&
            raw['deviceId'] is String &&
            raw['token'] is String) {
          try {
            out._peers.add(PeerRecord.fromJson(raw.cast<String, dynamic>()));
          } catch (_) {/* skip malformed record */}
        }
      }
    }
    return out;
  }

  List<PeerRecord> get list => List.unmodifiable(_peers);

  bool get isEmpty => _peers.isEmpty;

  PeerRecord? get(String deviceId) {
    for (final p in _peers) {
      if (p.deviceId == deviceId) return p;
    }
    return null;
  }

  PeerRecord? byIp(String ip) {
    for (final p in _peers) {
      if (p.lastIp == ip) return p;
    }
    return null;
  }

  /// Constant-time token lookup used by the server auth middleware.
  PeerRecord? byToken(String token) {
    PeerRecord? match;
    for (final p in _peers) {
      if (PeerCrypto.fixedTimeEquals(p.token, token)) match = p;
    }
    return match;
  }

  /// Insert or replace a partner (re-pairing rotates the token and pairing
  /// time). Persists immediately.
  Future<PeerRecord> upsert({
    required String deviceId,
    required String name,
    required String token,
    String? outboundToken,
    String? lastIp,
    int? lastHttpPort,
  }) async {
    _peers.removeWhere((p) => p.deviceId == deviceId);
    final record = PeerRecord(
      deviceId: deviceId,
      name: name,
      token: token,
      outboundToken: outboundToken,
      pairedAt: DateTime.now(),
      lastIp: lastIp,
      lastHttpPort: lastHttpPort,
    );
    _peers.add(record);
    _peers.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await save();
    return record;
  }

  /// Refresh mutable display/address info for a known partner without
  /// rotating its token.
  Future<void> touch(String deviceId,
      {String? name, String? lastIp, int? lastHttpPort}) async {
    final p = get(deviceId);
    if (p == null) return;
    if (name != null && name.trim().isNotEmpty) p.name = name.trim();
    if (lastIp != null) p.lastIp = lastIp;
    if (lastHttpPort != null) p.lastHttpPort = lastHttpPort;
    await save();
  }

  /// Revoke a partner. Subsequent requests bearing the old token get 401.
  Future<bool> remove(String deviceId) async {
    final before = _peers.length;
    _peers.removeWhere((p) => p.deviceId == deviceId);
    if (_peers.length != before) {
      await save();
      return true;
    }
    return false;
  }

  Future<void> save() => PeerFiles.atomicWriteJson(_file, {
        'version': 1,
        'peers': _peers.map((p) => p.toJson()).toList(),
      });
}
