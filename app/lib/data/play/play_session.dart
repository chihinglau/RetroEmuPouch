import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../peer/peer_client.dart';
import '../peer/peer_crypto.dart';
import '../peer/peer_store.dart';

/// Netplay protocol version exchanged in signaling and checked against the
/// native packet header (`kProtoVersion`). Must stay in sync with both.
class PlayProtocol {
  PlayProtocol._();

  static const int netplayProtoVersion = 1;

  /// Conservative starting delay (frames). Adaptive-D may lower it to 1.
  static const int initialDelay = 2;
}

enum PlayState {
  /// Session object exists but no remote event has been observed yet.
  idle,

  /// Invite sent (host) or received (guest); waiting for accept/decline.
  inviting,

  /// Both sides agreed; lobby page is open.
  lobby,

  /// Host pressed start; emulators are bootstrapping.
  starting,

  /// Frame channel is running.
  playing,

  /// Terminal: ended cleanly or by a remote event (see [PlayEndReason]).
  ended,

  /// Terminal: local error made the session unusable.
  failed,
}

enum PlayRole { host, guest }

/// Why a session reached [PlayState.ended].
enum PlayEndReason {
  /// Guest declined the invitation (host side).
  declined,

  /// Either side cancelled before/during the game.
  cancelled,

  /// Invitation was neither accepted nor declined before its TTL.
  timedOut,

  /// Remote side sent `/play/bye` (game finished or errored there).
  remoteBye,

  /// Local game finished normally.
  finished,
}

/// Pushed to the guest UI when an authenticated partner invites us.
class PlayInvite {
  PlayInvite({
    required this.roomId,
    required this.fromDeviceId,
    required this.fromName,
    required this.coreId,
    required this.romCrc,
    required this.romName,
    required this.versionCode,
    required this.proto,
    required this.hostUdpPort,
    required this.expiresAt,
  });

  final String roomId;
  final String fromDeviceId;
  final String fromName;
  final String coreId;
  final String romCrc;
  final String romName;
  final int versionCode;
  final int proto;
  final int hostUdpPort;
  final DateTime expiresAt;

  Duration get ttl => expiresAt.difference(DateTime.now());
}

/// Signaling-layer rejection: [status] is the HTTP status the server should
/// answer, [code] the stable error code in the JSON envelope.
class PlayReject implements Exception {
  const PlayReject(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'PlayReject($status, $code)';
}

/// One netplay session. The 32-byte [sessionKey] lives in memory only; it is
/// never part of [toString], never written to disk and never logged.
class PlaySession {
  PlaySession({
    required this.roomId,
    required this.role,
    required this.peerDeviceId,
    required this.peerName,
    this.peerIp,
    required this.coreId,
    required this.romCrc,
    required this.romName,
    required this.versionCode,
    required this.proto,
    required this.createdAt,
    required this.expiresAt,
    this.hostUdpPort,
    this.guestUdpPort,
    this.initialD = PlayProtocol.initialDelay,
    this.sessionKey,
    this.state = PlayState.inviting,
  });

  final String roomId;
  final PlayRole role;
  final String peerDeviceId;
  final String peerName;
  String? peerIp;
  final String coreId;
  final String romCrc;
  final String romName;
  final int versionCode;
  final int proto;
  final DateTime createdAt;
  final DateTime expiresAt;

  int? hostUdpPort;
  int? guestUdpPort;
  int initialD;

  /// Host-side only: guest pressed 「准备」 in the lobby (POST /play/ready).
  bool guestReady = false;

  /// Host-side Kotlin bootstrap HTTP port, delivered to the guest with
  /// POST /play/start so its EmulatorActivity can fetch SRAM/state0.
  int? bootstrapPort;

  PlayState state;
  PlayEndReason? endReason;
  String? errorCode;

  /// 64 lowercase hex chars (32 bytes). Host has it from creation; the guest
  /// receives it in the accept response. Null after [dispose].
  String? sessionKey;

  /// Set once the session reached a terminal state; every further mutator
  /// throws.
  bool get isTerminal =>
      state == PlayState.ended || state == PlayState.failed;

  bool get isExpired =>
      state == PlayState.inviting &&
      DateTime.now().isAfter(expiresAt);

  /// Native lockstep header carries a 32-bit room id; derive it from the
  /// first 8 hex chars of the signaling roomId (16 hex chars). Normalized to
  /// unsigned 32-bit (0..0xFFFFFFFF) so it matches the Kotlin-side Int
  /// delivered over the method channel regardless of sign.
  int get roomId32 => int.parse(roomId.substring(0, 8), radix: 16) & 0xFFFFFFFF;

  void _requireLive() {
    if (isTerminal) throw StateError('play session $roomId is $state');
  }

  void markLobby({int? guestUdpPort, String? sessionKey}) {
    _requireLive();
    if (state != PlayState.inviting && state != PlayState.lobby) {
      throw StateError('cannot accept session in $state');
    }
    if (guestUdpPort != null) this.guestUdpPort = guestUdpPort;
    if (sessionKey != null) this.sessionKey = sessionKey;
    state = PlayState.lobby;
  }

  void markStarting() {
    _requireLive();
    if (state != PlayState.lobby) {
      throw StateError('cannot start session in $state');
    }
    state = PlayState.starting;
  }

  void markPlaying() {
    _requireLive();
    if (state != PlayState.starting && state != PlayState.lobby) {
      throw StateError('cannot play session in $state');
    }
    state = PlayState.playing;
  }

  void end(PlayEndReason reason) {
    if (isTerminal) return;
    endReason = reason;
    state = PlayState.ended;
  }

  void fail(String code) {
    if (isTerminal) return;
    errorCode = code;
    state = PlayState.failed;
  }

  /// Drop the key material. The object is unusable afterwards.
  void dispose() {
    if (!isTerminal) end(PlayEndReason.cancelled);
    sessionKey = null;
  }

  @override
  String toString() =>
      'PlaySession($roomId, ${role.name}, $coreId/$romCrc, ${state.name}'
      '${endReason == null ? '' : '/${endReason!.name}'}, '
      'peer=$peerDeviceId)';
}

/// Owns the single live [PlaySession] on this device, enforces the
/// one-active-session / roomId-reuse guards and the 60s invite TTL, and
/// exposes the typed hooks the HTTP server delegates `/api/peer/play/*` to.
class PlaySessionManager {
  PlaySessionManager({
    required this.selfDeviceId,
    required this.selfName,
    required this.localVersionCode,
    this.netplayProtoVersion = PlayProtocol.netplayProtoVersion,
    this.inviteTtl = const Duration(seconds: 60),
    this.multiplayerAllowed,
  });

  final String selfDeviceId;
  final String selfName;
  final int localVersionCode;
  final int netplayProtoVersion;
  final Duration inviteTtl;

  /// Server-side authority for the multiplayer gate. Returns true when the
  /// invited ROM genuinely supports two players. Null disables the check
  /// (unit tests only). The production closure consults the built-in
  /// [MultiplayerCatalog] (unknown / hacks / single-player => false) so a
  /// crafted direct POST cannot bypass the hidden UI entry.
  final Future<bool> Function(String coreId, String romCrc)?
      multiplayerAllowed;

  PlaySession? _current;

  /// Recently terminated sessions, kept only to reject roomId replays.
  final Map<String, PlaySession> _history = {};
  static const int _historyCap = 16;

  Timer? _ttlTimer;

  final _invitations = StreamController<PlayInvite>.broadcast();
  final _changes = StreamController<PlaySession>.broadcast();

  /// Last invitation that may not have reached any UI listener yet. The
  /// invitations stream is broadcast: an event fired between the HTTP
  /// server starting and the page attaching its listener is silently
  /// dropped, leaving the host in a phantom waiting lobby. The page drains
  /// this right after subscribing.
  PlayInvite? _pendingInvite;

  /// Guest-side: fires for every valid authenticated incoming invitation.
  Stream<PlayInvite> get invitations => _invitations.stream;

  /// Pop the buffered invitation if it is still presentable (session alive,
  /// in `inviting` state, not expired). Called by the peers page right after
  /// subscribing to [invitations].
  PlayInvite? drainPendingInvite() {
    final inv = _pendingInvite;
    if (inv == null) return null;
    final s = _current;
    if (s == null ||
        s.isTerminal ||
        s.state != PlayState.inviting ||
        inv.expiresAt.isBefore(DateTime.now())) {
      _pendingInvite = null;
      return null;
    }
    _pendingInvite = null;
    return inv;
  }

  /// Fires whenever the current session changes state (including terminal).
  Stream<PlaySession> get changes => _changes.stream;

  /// The live session, or null once it terminated.
  PlaySession? get current {
    final s = _current;
    if (s == null) return null;
    if (s.isTerminal) return null;
    return s;
  }

  PlaySession? get currentOrNull => _current;

  // ------------------------------------------------------------- validation

  static final _roomIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
  static final _coreRe = RegExp(r'^[a-z0-9_]{2,32}$');
  static final _crcRe = RegExp(r'^[0-9A-Fa-f]{8}$');

  static String _str(Map<String, dynamic> j, String k) {
    final v = j[k];
    return v is String ? v.trim() : '';
  }

  static int? _port(Map<String, dynamic> j, String k) {
    final v = j[k];
    if (v is int && v >= 1 && v <= 65535) return v;
    return null;
  }

  // ------------------------------------------------------------ host local

  /// Host UI: create the session before POSTing the invite. Generates the
  /// roomId and the 32-byte session key.
  PlaySession createHost({
    required String peerDeviceId,
    required String peerName,
    String? peerIp,
    required String coreId,
    required String romCrc,
    required String romName,
    int? hostUdpPort,
    int initialD = PlayProtocol.initialDelay,
  }) {
    if (current != null) {
      throw const PlayReject(HttpStatus.conflict, 'session_active');
    }
    final now = DateTime.now();
    final s = PlaySession(
      roomId: PeerCrypto.randomHex(16),
      role: PlayRole.host,
      peerDeviceId: peerDeviceId,
      peerName: peerName,
      peerIp: peerIp,
      coreId: coreId,
      romCrc: romCrc.toUpperCase(),
      romName: romName,
      versionCode: localVersionCode,
      proto: netplayProtoVersion,
      createdAt: now,
      expiresAt: now.add(inviteTtl),
      hostUdpPort: hostUdpPort,
      initialD: initialD,
      // 32 bytes from the platform CSPRNG; never leaves this process except
      // in the accept response over the pairing-token-protected channel.
      sessionKey: PeerCrypto.randomHex(32),
    );
    _setCurrent(s);
    return s;
  }

  // ----------------------------------------------------------- guest local

  /// Guest UI: accept [roomId] after POSTing accept and receiving the key.
  PlaySession completeLocalAccept({
    required String roomId,
    required int guestUdpPort,
    required String sessionKey,
  }) {
    final s = _requireCurrentRoom(roomId, PlayRole.guest);
    if (!_keyShapeOk(sessionKey)) {
      throw const PlayReject(HttpStatus.badRequest, 'bad_key');
    }
    s.markLobby(guestUdpPort: guestUdpPort, sessionKey: sessionKey);
    _pendingInvite = null;
    _emit(s);
    return s;
  }

  /// Guest UI: reject the invitation.
  void declineLocally(String roomId) {
    final s = _current;
    if (s != null && s.role == PlayRole.guest && s.roomId == roomId) {
      _terminate(s, PlayEndReason.declined);
    }
  }

  /// Either side: cancel the live session (invite, lobby or game).
  void cancelLocally([String? roomId]) {
    final s = _current;
    if (s != null && (roomId == null || s.roomId == roomId)) {
      _terminate(s, PlayEndReason.cancelled);
    }
  }

  void beginStart([String? roomId]) {
    final s = _requireCurrentRoom(roomId, null);
    s.markStarting();
    _emit(s);
  }

  /// Host UI: remember the Kotlin bootstrap port and flip to starting.
  /// Called right before POSTing /play/start to the guest.
  void dispatchStartLocally(int bootstrapPort, [String? roomId]) {
    final s = _requireCurrentRoom(roomId, PlayRole.host);
    if (bootstrapPort < 1 || bootstrapPort > 65535) {
      throw const PlayReject(HttpStatus.badRequest, 'bad_request');
    }
    s.bootstrapPort = bootstrapPort;
    s.markStarting();
    _emit(s);
  }

  /// `POST /api/peer/play/ready` on the host: guest announced lobby
  /// readiness. Idempotent.
  Map<String, dynamic> handleReady({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final s = _current;
    if (s != null &&
        !s.isTerminal &&
        s.roomId == roomId &&
        s.role == PlayRole.host &&
        s.peerDeviceId == caller.deviceId) {
      s.guestReady = true;
      _emit(s);
    }
    return {'ok': true};
  }

  /// `POST /api/peer/play/start` on the guest: host opens the gate and hands
  /// over the bootstrap HTTP port. The guest lobby auto-launches the
  /// EmulatorActivity on this.
  Map<String, dynamic> handleStart({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final bootstrapPort = _port(j, 'bootstrapPort');
    if (!_roomIdRe.hasMatch(roomId) || bootstrapPort == null) {
      throw const PlayReject(HttpStatus.badRequest, 'bad_request');
    }
    final s = _current;
    if (s == null ||
        s.isTerminal ||
        s.roomId != roomId ||
        s.role != PlayRole.guest ||
        s.peerDeviceId != caller.deviceId) {
      throw const PlayReject(HttpStatus.gone, 'unknown_session');
    }
    if (s.state != PlayState.lobby) {
      throw const PlayReject(HttpStatus.conflict, 'not_in_lobby');
    }
    s.bootstrapPort = bootstrapPort;
    s.markStarting();
    _emit(s);
    return {'ok': true};
  }

  void beginPlay([String? roomId]) {
    final s = _requireCurrentRoom(roomId, null);
    s.markPlaying();
    _emit(s);
  }

  /// Local game ended normally.
  void finish([String? roomId]) {
    final s = _current;
    if (s != null && (roomId == null || s.roomId == roomId)) {
      _terminate(s, PlayEndReason.finished);
    }
  }

  /// Native EmulatorActivity reports the lockstep session for [roomId32] has
  /// been torn down — clean exit (BYE/X) maps to [PlayEndReason.finished],
  /// drop/timeout/kill maps to [PlayEndReason.cancelled]. This is what frees
  /// the single-session slot after the emulator Activity finishes; without
  /// it the next invite is blocked by a phantom "session in progress"
  /// (Task 9). A mismatched/stale room id or a terminal session is a no-op.
  void notifyNativePlayEnded({required int roomId32, required bool clean}) {
    final s = _current;
    if (s == null || s.isTerminal || s.roomId32 != roomId32) return;
    _terminate(
        s, clean ? PlayEndReason.finished : PlayEndReason.cancelled);
  }

  /// Local unrecoverable error.
  void failLocal(String code, [String? roomId]) {
    final s = _current;
    if (s != null && (roomId == null || s.roomId == roomId)) {
      s.fail(code);
      _retire(s);
      _emit(s);
    }
  }

  // -------------------------------------------------------- server hooks

  /// `POST /api/peer/play/invite` on the guest. [caller] is the authenticated
  /// partner record. Throws [PlayReject] for every rejection branch.
  Future<Map<String, dynamic>> handleInvite({
    required PeerRecord caller,
    required String? callerIp,
    required Map<String, dynamic> j,
  }) async {
    final roomId = _str(j, 'roomId');
    final coreId = _str(j, 'coreId');
    final crcRaw = _str(j, 'romCrc');
    final romName = _str(j, 'romName');
    final hostName = _str(j, 'hostName');
    final versionCode = (j['versionCode'] as num?)?.toInt();
    final proto = (j['proto'] as num?)?.toInt();
    final hostUdpPort = _port(j, 'hostUdpPort');

    if (!_roomIdRe.hasMatch(roomId) ||
        !_coreRe.hasMatch(coreId) ||
        !_crcRe.hasMatch(crcRaw) ||
        romName.isEmpty ||
        romName.length > 128 ||
        hostName.isEmpty ||
        hostName.length > 64 ||
        versionCode == null ||
        proto == null ||
        hostUdpPort == null) {
      throw const PlayReject(HttpStatus.badRequest, 'bad_request');
    }
    if (proto != netplayProtoVersion) {
      throw const PlayReject(HttpStatus.badRequest, 'proto_mismatch');
    }
    if (versionCode != localVersionCode) {
      throw const PlayReject(HttpStatus.conflict, 'version_mismatch');
    }

    // Authoritative multiplayer gate (defends against direct POSTs aimed at
    // single-player games the UI hides). Unknown ROMs fail closed.
    final gate = multiplayerAllowed;
    if (gate != null && !await gate(coreId, crcRaw.toUpperCase())) {
      throw const PlayReject(HttpStatus.badRequest, 'not_multiplayer');
    }

    // A roomId we have already buried must never come back to life.
    final old = _history[roomId];
    if (old != null) {
      throw PlayReject(
        HttpStatus.gone,
        old.endReason == PlayEndReason.timedOut ? 'expired' : 'room_reused',
      );
    }
    final active = _current;
    if (active != null && !active.isTerminal) {
      throw const PlayReject(HttpStatus.conflict, 'session_active');
    }

    final now = DateTime.now();
    final s = PlaySession(
      roomId: roomId,
      role: PlayRole.guest,
      peerDeviceId: caller.deviceId,
      peerName: caller.name,
      peerIp: callerIp,
      coreId: coreId,
      romCrc: crcRaw.toUpperCase(),
      romName: romName,
      versionCode: versionCode,
      proto: proto,
      createdAt: now,
      expiresAt: now.add(inviteTtl),
      hostUdpPort: hostUdpPort,
    );
    _setCurrent(s);
    final inv = PlayInvite(
      roomId: roomId,
      fromDeviceId: caller.deviceId,
      fromName: caller.name,
      coreId: coreId,
      romCrc: crcRaw.toUpperCase(),
      romName: romName,
      versionCode: versionCode,
      proto: proto,
      hostUdpPort: hostUdpPort,
      expiresAt: s.expiresAt,
    );
    _pendingInvite = inv;
    if (!_invitations.isClosed) _invitations.add(inv);
    return {'ok': true, 'ttlMs': inviteTtl.inMilliseconds};
  }

  /// `POST /api/peer/play/accept` on the host. Idempotent: a retried accept
  /// while already in the lobby returns the same key instead of failing.
  Map<String, dynamic> handleAccept({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final guestUdpPort = _port(j, 'guestUdpPort');
    if (!_roomIdRe.hasMatch(roomId) || guestUdpPort == null) {
      throw const PlayReject(HttpStatus.badRequest, 'bad_request');
    }
    final s = _resolveHostRoom(roomId, caller.deviceId);
    if (s.state == PlayState.inviting && s.isExpired) {
      _terminate(s, PlayEndReason.timedOut);
      throw const PlayReject(HttpStatus.gone, 'expired');
    }
    s.markLobby(guestUdpPort: guestUdpPort);
    _emit(s);
    return {
      'ok': true,
      'sessionKey': s.sessionKey,
      'proto': s.proto,
      'initialD': s.initialD,
    };
  }

  /// `POST /api/peer/play/decline` on the host. Idempotent terminal.
  Map<String, dynamic> handleDecline({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final s = _current;
    if (s != null &&
        !s.isTerminal &&
        s.roomId == roomId &&
        s.role == PlayRole.host &&
        s.peerDeviceId == caller.deviceId) {
      _terminate(s, PlayEndReason.declined);
    }
    return {'ok': true};
  }

  /// `POST /api/peer/play/cancel` on either side. Idempotent terminal.
  Map<String, dynamic> handleCancel({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final s = _current;
    if (s != null &&
        !s.isTerminal &&
        s.roomId == roomId &&
        s.peerDeviceId == caller.deviceId) {
      _terminate(s, PlayEndReason.cancelled);
    }
    return {'ok': true};
  }

  /// `POST /api/peer/play/bye` on either side. Best effort, idempotent.
  Map<String, dynamic> handleBye({
    required PeerRecord caller,
    required Map<String, dynamic> j,
  }) {
    final roomId = _str(j, 'roomId');
    final s = _current;
    if (s != null &&
        !s.isTerminal &&
        s.roomId == roomId &&
        s.peerDeviceId == caller.deviceId) {
      _terminate(s, PlayEndReason.remoteBye);
    }
    return {'ok': true};
  }

  // ------------------------------------------------------------ internals

  PlaySession _requireCurrentRoom(String? roomId, PlayRole? role) {
    final s = current;
    if (s == null || (roomId != null && s.roomId != roomId)) {
      throw const PlayReject(HttpStatus.gone, 'unknown_session');
    }
    if (role != null && s.role != role) {
      throw const PlayReject(HttpStatus.conflict, 'wrong_role');
    }
    if (s.state == PlayState.inviting && s.isExpired) {
      _terminate(s, PlayEndReason.timedOut);
      throw const PlayReject(HttpStatus.gone, 'expired');
    }
    return s;
  }

  PlaySession _resolveHostRoom(String roomId, String callerDeviceId) {
    final s = current;
    if (s == null) {
      final old = _history[roomId];
      if (old != null) {
        throw PlayReject(
          HttpStatus.gone,
          old.endReason == PlayEndReason.timedOut ? 'expired' : 'session_ended',
        );
      }
      throw const PlayReject(HttpStatus.gone, 'unknown_session');
    }
    if (s.roomId != roomId ||
        s.role != PlayRole.host ||
        s.peerDeviceId != callerDeviceId) {
      throw const PlayReject(HttpStatus.gone, 'unknown_session');
    }
    return s;
  }

  void _setCurrent(PlaySession s) {
    _ttlTimer?.cancel();
    _current = s;
    _ttlTimer = Timer(s.expiresAt.difference(DateTime.now()), () {
      final cur = _current;
      if (identical(cur, s) &&
          !s.isTerminal &&
          s.state == PlayState.inviting) {
        _terminate(s, PlayEndReason.timedOut);
      }
    });
    _emit(s);
  }

  void _terminate(PlaySession s, PlayEndReason reason) {
    s.end(reason);
    _retire(s);
    _emit(s);
  }

  void _retire(PlaySession s) {
    if (identical(_current, s)) {
      // Keep the reference so UI/tests can observe the terminal session via
      // [currentOrNull]; [current] itself reports null for terminal state.
      _ttlTimer?.cancel();
      _ttlTimer = null;
      _pendingInvite = null;
    }
    _history.remove(s.roomId);
    // Newest entries last; cap by dropping the oldest tombstone.
    _history[s.roomId] = s;
    while (_history.length > _historyCap) {
      _history.remove(_history.keys.first);
    }
  }

  void _emit(PlaySession s) {
    if (!_changes.isClosed) _changes.add(s);
  }

  static bool _keyShapeOk(String key) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(key);

  /// Tear everything down: cancels timers, zeros key material, closes
  /// streams. The manager must not be used afterwards.
  Future<void> dispose() async {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    _current?.dispose();
    for (final s in _history.values) {
      s.dispose();
    }
    _current = null;
    _history.clear();
    await _invitations.close();
    await _changes.close();
  }
}

/// Client for the five `/api/peer/play/*` endpoints on one partner. Uses
/// the same `Peer <token>` authorization discipline as [PeerClient].
class PlaySignalingClient {
  PlaySignalingClient({
    required this.baseUrl,
    required this.peerToken,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 5);
  }

  final String baseUrl;
  final String peerToken;
  final HttpClient _http;

  Future<Map<String, dynamic>> _post(
    String path,
    Object? payload, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final req = await _http.postUrl(Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Peer $peerToken');
    req.write(jsonEncode(payload));
    final res = await req.close().timeout(timeout);
    final body = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == HttpStatus.unauthorized) {
      throw PeerUnauthorizedException('$path returned 401');
    }
    Map<String, dynamic> j;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException();
      j = decoded.cast<String, dynamic>();
    } catch (_) {
      throw PeerApiException(res.statusCode, 'http_${res.statusCode}');
    }
    if (res.statusCode != HttpStatus.ok) {
      throw PeerApiException(
        res.statusCode,
        (j['error'] as String?) ?? 'http_${res.statusCode}',
        j['message'] as String?,
      );
    }
    return j;
  }

  /// Host → guest. Returns the server-side TTL in milliseconds.
  Future<int> invite({
    required String roomId,
    required String coreId,
    required String romCrc,
    required String romName,
    required int versionCode,
    required int proto,
    required int hostUdpPort,
    required String hostName,
  }) async {
    final r = await _post('/api/peer/play/invite', {
      'roomId': roomId,
      'coreId': coreId,
      'romCrc': romCrc,
      'romName': romName,
      'versionCode': versionCode,
      'proto': proto,
      'hostUdpPort': hostUdpPort,
      'hostName': hostName,
    });
    return (r['ttlMs'] as num?)?.toInt() ?? 60000;
  }

  /// Guest → host. Returns the session key plus negotiated constants.
  Future<({String sessionKey, int proto, int initialD})> accept({
    required String roomId,
    required int guestUdpPort,
  }) async {
    final r = await _post('/api/peer/play/accept', {
      'roomId': roomId,
      'guestUdpPort': guestUdpPort,
    });
    return (
      sessionKey: r['sessionKey'] as String,
      proto: (r['proto'] as num?)?.toInt() ?? PlayProtocol.netplayProtoVersion,
      initialD:
          (r['initialD'] as num?)?.toInt() ?? PlayProtocol.initialDelay,
    );
  }

  /// Guest → host: lobby 「准备」.
  Future<void> ready(String roomId) async {
    await _post('/api/peer/play/ready', {'roomId': roomId},
        timeout: const Duration(seconds: 5));
  }

  /// Host → guest: open the start gate with the Kotlin bootstrap port.
  Future<void> start(String roomId, int bootstrapPort) async {
    await _post('/api/peer/play/start', {
      'roomId': roomId,
      'bootstrapPort': bootstrapPort,
    });
  }

  Future<void> decline(String roomId) async {
    try {
      await _post('/api/peer/play/decline', {'roomId': roomId},
          timeout: const Duration(seconds: 5));
    } catch (_) {/* idempotent terminal, best effort */}
  }

  Future<void> cancel(String roomId) async {
    try {
      await _post('/api/peer/play/cancel', {'roomId': roomId},
          timeout: const Duration(seconds: 5));
    } catch (_) {/* idempotent terminal, best effort */}
  }

  Future<void> bye(String roomId) async {
    try {
      await _post('/api/peer/play/bye', {'roomId': roomId},
          timeout: const Duration(seconds: 5));
    } catch (_) {/* best effort notification */}
  }

  void close() => _http.close(force: true);
}
