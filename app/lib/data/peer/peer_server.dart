import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'peer_crypto.dart';
import 'peer_discovery.dart';
import 'peer_files.dart';
import 'peer_identity.dart';
import 'peer_store.dart';
import '../play/play_session.dart';
import '../../system_files.dart';

/// A pairing request pushed to the responder's UI (show the code + the
/// initiator's name in a confirmation dialog).
class PeerPairRequest {
  PeerPairRequest({
    required this.pairId,
    required this.initiatorId,
    required this.initiatorName,
    required this.code,
    required this.expiresAt,
  });

  final String pairId;
  final String initiatorId;
  final String initiatorName;
  final String code;
  final DateTime expiresAt;
}

class _PairSession {
  _PairSession({
    required this.code,
    required this.initiatorId,
    required this.initiatorName,
    required this.tokenA,
    required this.expiresAt,
  });

  final String code;
  final String initiatorId;
  final String initiatorName;

  /// Token the initiator hands out: the responder stores it and later
  /// presents it when calling the initiator's server.
  final String tokenA;
  int attempts = 0;
  bool responderConfirmed = false;
  bool finished = false;
  DateTime expiresAt;

  /// Completed true when the responder taps confirm, false on reject/cancel.
  /// The initiator's long-polled confirm request awaits this.
  final Completer<bool> responderGate = Completer<bool>();
}

/// HTTP server run by every device while the peers page is open.
///
/// Routing:
///   GET  /api/peer/info ..................... public minimal identity
///   POST /api/peer/pair/start|confirm|cancel  pairing handshake (public)
///   GET  /api/peer/library .................. full inventory (Peer token)
///   GET  /api/peer/rom|cover|cheats|save/...  file streams (Peer token)
///   POST /api/peer/play/invite|accept|decline|cancel|bye
///                                            netplay signaling (Peer token)
///
/// Every filesystem lookup derives from an 8-hex CRC whitelist plus fixed
/// directory conventions; raw path segments from the network are never
/// joined (path traversal is impossible by construction).
class PeerServer {
  PeerServer({
    required this.filesDir,
    required this.identity,
    required this.store,
    this.appVersion = '',
    this.plays,
    this.pairTtl = const Duration(minutes: 2),
    this.responderWait = const Duration(seconds: 20),
  });

  final String filesDir;
  final PeerIdentity identity;
  final PeerStore store;
  final String appVersion;

  /// Optional netplay signaling session owner; when null, /api/peer/play/*
  /// answers 404 (netplay is opt-in per foreground session).
  final PlaySessionManager? plays;

  final Duration pairTtl;
  final Duration responderWait;
  static const int maxCodeAttempts = 5;

  HttpServer? _server;
  final _sessions = <String, _PairSession>{};
  Timer? _sweep;
  final _pairRequestCtl = StreamController<PeerPairRequest>.broadcast();
  final _pairEndedCtl = StreamController<String>.broadcast();

  /// Short-lived cached /library payload. Building it on a 1000+ ROM device
  /// costs thousands of stat() calls plus two JSON layer reads; a cold page
  /// cache can push the first build past the client timeout. Consecutive
  /// pulls (retries, re-entering the library page) reuse it.
  String? _libraryPayloadCache;
  DateTime? _libraryBuiltAt;
  static const _libraryTtl = Duration(seconds: 5);

  /// Fires whenever a remote device asks to pair; the page shows the dialog.
  Stream<PeerPairRequest> get pairRequests => _pairRequestCtl.stream;

  /// Fires when a pairing session ends by cancellation / expiry / attempts
  /// exhausted (emits the pairId). The responder dialog uses it to close
  /// immediately instead of waiting out the full TTL.
  Stream<String> get pairSessionEnded => _pairEndedCtl.stream;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _sweep = Timer.periodic(const Duration(seconds: 10), (_) => _sweepExpired());
    server.listen(_handle, cancelOnError: false);
  }

  Future<void> stop() async {
    _sweep?.cancel();
    _sweep = null;
    for (final s in _sessions.values) {
      if (!s.responderGate.isCompleted) s.responderGate.complete(false);
    }
    _sessions.clear();
    _libraryPayloadCache = null;
    _libraryBuiltAt = null;
    final s = _server;
    _server = null;
    if (s != null) {
      await s.close(force: true);
    }
    _pairEndedCtl.close();
  }

  void _endSession(String pairId) {
    if (!_pairEndedCtl.isClosed) _pairEndedCtl.add(pairId);
  }

  // ---------------------------------------------------- responder UI hooks

  /// Responder-side: the user verified the code and tapped confirm.
  void responderConfirmed(String pairId) {
    final s = _sessions[pairId];
    if (s == null || s.finished) return;
    s.responderConfirmed = true;
    if (!s.responderGate.isCompleted) s.responderGate.complete(true);
  }

  /// Responder-side: user rejected, or the dialog was dismissed.
  void responderRejected(String pairId) {
    final s = _sessions.remove(pairId);
    if (s != null && !s.responderGate.isCompleted) {
      s.responderGate.complete(false);
    }
  }

  void _sweepExpired() {
    final now = DateTime.now();
    final dead =
        _sessions.entries.where((e) => e.value.expiresAt.isBefore(now)).toList();
    for (final e in dead) {
      _sessions.remove(e.key);
      if (!e.value.responderGate.isCompleted) e.value.responderGate.complete(false);
      _endSession(e.key);
    }
  }

  // ------------------------------------------------------------- request IO

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/api/peer/info') {
        await _sendJson(req, _infoBody());
        return;
      }
      if (req.method == 'POST' && path == '/api/peer/pair/start') {
        await _pairStart(req);
        return;
      }
      if (req.method == 'POST' && path == '/api/peer/pair/confirm') {
        await _pairConfirm(req);
        return;
      }
      if (req.method == 'POST' && path == '/api/peer/pair/cancel') {
        await _pairCancel(req);
        return;
      }

      // Everything else requires a valid Peer token.
      final caller = _authRecord(req);
      if (caller == null) {
        await _sendError(req, HttpStatus.unauthorized, 'unauthorized');
        return;
      }

      if (req.method == 'POST' && path.startsWith('/api/peer/play/')) {
        await _play(
          req,
          path.substring('/api/peer/play/'.length),
          caller,
        );
        return;
      }

      if (req.method == 'GET' && path == '/api/peer/library') {
        await _sendLibrary(req);
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/peer/rom/')) {
        await _sendFileByCrc(
          req,
          path.substring('/api/peer/rom/'.length),
          (crc) => _romFile(crc),
        );
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/peer/cover/')) {
        await _sendFileByCrc(
          req,
          path.substring('/api/peer/cover/'.length),
          (crc) => File('$filesDir/library/covers-cloud/$crc.png'),
          contentType: 'image/png',
        );
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/peer/cheats/')) {
        await _sendCheats(
            req, path.substring('/api/peer/cheats/'.length));
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/peer/save/')) {
        await _sendSave(req, path.substring('/api/peer/save/'.length));
        return;
      }
      if (req.method == 'GET' && path == '/api/peer/bios') {
        await _sendBiosList(req);
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/peer/bios/')) {
        await _sendBios(
          req,
          path.substring('/api/peer/bios/'.length),
        );
        return;
      }
      await _sendError(req, HttpStatus.notFound, 'not_found');
    } catch (_) {
      try {
        _sendError(req, HttpStatus.internalServerError, 'server_error');
      } catch (_) {/* client gone */}
    }
  }

  PeerRecord? _authRecord(HttpRequest req) {
    final h = req.headers.value(HttpHeaders.authorizationHeader);
    if (h == null || !h.startsWith('Peer ')) return null;
    final token = h.substring('Peer '.length).trim();
    if (token.isEmpty) return null;
    return store.byToken(token);
  }

  // ------------------------------------------------------------- netplay

  static const _playRoutes = {
    'invite',
    'accept',
    'decline',
    'cancel',
    'bye',
    'ready',
    'start',
  };

  Future<void> _play(
    HttpRequest req,
    String route,
    PeerRecord caller,
  ) async {
    final plays = this.plays;
    if (plays == null || !_playRoutes.contains(route)) {
      await _sendError(req, HttpStatus.notFound, 'not_found');
      return;
    }
    Map<String, dynamic> j;
    try {
      j = await _readJson(req);
    } catch (_) {
      await _sendError(req, HttpStatus.badRequest, 'bad_json');
      return;
    }
    try {
      final ip = req.connectionInfo?.remoteAddress.address;
      switch (route) {
        case 'invite':
          await _sendJson(req,
              await plays.handleInvite(caller: caller, callerIp: ip, j: j));
        case 'accept':
          await _sendJson(req, plays.handleAccept(caller: caller, j: j));
        case 'decline':
          await _sendJson(req, plays.handleDecline(caller: caller, j: j));
        case 'cancel':
          await _sendJson(req, plays.handleCancel(caller: caller, j: j));
        case 'bye':
          await _sendJson(req, plays.handleBye(caller: caller, j: j));
        case 'ready':
          await _sendJson(req, plays.handleReady(caller: caller, j: j));
        case 'start':
          await _sendJson(req, plays.handleStart(caller: caller, j: j));
      }
    } on PlayReject catch (e) {
      await _sendError(req, e.status, e.code);
    }
  }

  Map<String, dynamic> _infoBody() => {
        'service': PeerProtocol.serviceTag,
        'deviceId': identity.deviceId,
        'name': identity.name,
        'appVersion': appVersion,
        'protocolVersion': PeerProtocol.protocolVersion,
      };

  Future<void> _sendJson(HttpRequest req, Object body,
      {int status = HttpStatus.ok}) async {
    final data = utf8.encode(jsonEncode(body));
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    req.response.add(data);
    await _flush(req);
  }

  Future<void> _sendError(HttpRequest req, int status, String code,
      {String? message}) async {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.add(utf8.encode(
        jsonEncode({'error': code, 'message': message})));
    await _flush(req);
  }

  Future<void> _flush(HttpRequest req) async {
    try {
      await req.response.close();
    } catch (_) {/* broken pipe */}
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final builder = await req.fold<BytesBuilder>(
        BytesBuilder(), (b, chunk) => b..add(chunk));
    final j = jsonDecode(utf8.decode(builder.takeBytes(), allowMalformed: true));
    if (j is! Map) throw const FormatException('body must be a JSON object');
    return j.cast<String, dynamic>();
  }

  // --------------------------------------------------------------- pairing

  static final _pairIdRe = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  Future<void> _pairStart(HttpRequest req) async {
    Map<String, dynamic> j;
    try {
      j = await _readJson(req);
    } catch (_) {
      return _sendError(req, HttpStatus.badRequest, 'bad_json');
    }
    final pairId = j['pairId'];
    final code = j['code'];
    final deviceId = j['deviceId'];
    final name = j['name'];
    final tokenA = j['tokenA'];
    if (pairId is! String ||
        !_pairIdRe.hasMatch(pairId) ||
        code is! String ||
        !RegExp(r'^\d{6}$').hasMatch(code) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        tokenA is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenA)) {
      return _sendError(req, HttpStatus.badRequest, 'bad_request');
    }
    if (deviceId == identity.deviceId) {
      return _sendError(req, HttpStatus.badRequest, 'is_self');
    }
    if (_sessions.containsKey(pairId)) {
      return _sendError(req, HttpStatus.conflict, 'duplicate_pair_id');
    }
    _sessions[pairId] = _PairSession(
      code: code,
      initiatorId: deviceId,
      initiatorName: name.trim(),
      tokenA: tokenA,
      expiresAt: DateTime.now().add(pairTtl),
    );
    if (!_pairRequestCtl.isClosed) {
      _pairRequestCtl.add(PeerPairRequest(
        pairId: pairId,
        initiatorId: deviceId,
        initiatorName: name.trim(),
        code: code,
        expiresAt: DateTime.now().add(pairTtl),
      ));
    }
    _sendJson(req, {'ok': true, 'ttlMs': pairTtl.inMilliseconds});
  }

  Future<void> _pairConfirm(HttpRequest req) async {
    Map<String, dynamic> j;
    try {
      j = await _readJson(req);
    } catch (_) {
      return _sendError(req, HttpStatus.badRequest, 'bad_json');
    }
    final pairId = j['pairId'];
    final code = j['code'];
    if (pairId is! String || code is! String) {
      return _sendError(req, HttpStatus.badRequest, 'bad_request');
    }
    final s = _sessions[pairId];
    if (s == null || s.finished) {
      // Unknown or already consumed — replay attacks end here.
      return _sendError(req, HttpStatus.gone, 'unknown_session');
    }
    if (s.expiresAt.isBefore(DateTime.now())) {
      _sessions.remove(pairId);
      if (!s.responderGate.isCompleted) s.responderGate.complete(false);
      return _sendError(req, HttpStatus.gone, 'expired');
    }

    if (code != s.code) {
      s.attempts++;
      if (s.attempts >= maxCodeAttempts) {
        _sessions.remove(pairId);
        if (!s.responderGate.isCompleted) s.responderGate.complete(false);
        _endSession(pairId);
        return _sendError(req, HttpStatus.forbidden, 'too_many_attempts');
      }
      return _sendError(req, HttpStatus.badRequest, 'bad_code',
          message: '${maxCodeAttempts - s.attempts}');
    }

    // Code is right; both humans must have tapped confirm. Long-poll up to
    // ~20s for the responder side instead of making the client busy-loop.
    if (!s.responderConfirmed) {
      final ok = await s.responderGate.future
          .timeout(responderWait, onTimeout: () => false);
      if (!ok) {
        // Rejected/cancelled while we waited.
        if (!_sessions.containsKey(pairId) || s.finished) {
          return _sendError(req, HttpStatus.forbidden, 'cancelled');
        }
        return _sendError(
            req, HttpStatus.accepted, 'responder_pending');
      }
    }
    if (!s.responderConfirmed || s.expiresAt.isBefore(DateTime.now())) {
      _sessions.remove(pairId);
      _endSession(pairId);
      return _sendError(req, HttpStatus.gone, 'expired');
    }
    // Atomically claim the completion. A client-timed-out poll can still be
    // suspended here (its socket is gone) and would otherwise wake up with
    // the gate open and mint a SECOND tokenB, overwriting the one the live
    // client received — the first claim wins, late waiters get 410.
    if (s.finished) {
      return _sendError(req, HttpStatus.gone, 'session_consumed');
    }
    s.finished = true;
    _sessions.remove(pairId);
    final clientIp = req.connectionInfo?.remoteAddress.address;
    final tokenB = PeerCrypto.randomHex(32);
    await store.upsert(
      deviceId: s.initiatorId,
      name: s.initiatorName,
      token: s.tokenA,
      // WE present tokenB when calling the initiator later; the initiator
      // stores it from this response.
      outboundToken: tokenB,
      lastIp: clientIp,
    );
    _sendJson(req, {
      'ok': true,
      'token': tokenB,
      'deviceId': identity.deviceId,
      'name': identity.name,
    });
  }

  Future<void> _pairCancel(HttpRequest req) async {
    Map<String, dynamic> j;
    try {
      j = await _readJson(req);
    } catch (_) {
      return _sendError(req, HttpStatus.badRequest, 'bad_json');
    }
    final pairId = j['pairId'];
    if (pairId is String) {
      final s = _sessions.remove(pairId);
      if (s != null) {
        if (!s.responderGate.isCompleted) s.responderGate.complete(false);
        _endSession(pairId);
      }
    }
    _sendJson(req, {'ok': true});
  }

  // --------------------------------------------------------- library/index

  /// Raw rom_index.json (List) so every stored field is forwarded verbatim.
  List<dynamic> _readRomIndex() {
    final j = PeerFiles.readJsonOrNull(File('$filesDir/rom_index.json'));
    return j is List ? j : const [];
  }

  Map<String, dynamic>? _readByCrcLayer(String fileName) {
    final j = PeerFiles.readJsonOrNull(File('$filesDir/library/$fileName'));
    if (j is Map && j['byCrc'] is Map) {
      return (j['byCrc'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  /// Effective cheats for [crc]: the local player layer wins over the cloud
  /// snapshot (same precedence as RomLibrary/CheatStore).
  List<dynamic>? _effectiveCheats(String crc) {
    final local = _readByCrcLayer('cheats.json');
    final cloud = _readByCrcLayer('cloud_cheats.json');
    final pick = local?[crc] ?? cloud?[crc];
    return pick is List && pick.isNotEmpty ? pick : null;
  }

  Future<void> _sendLibrary(HttpRequest req) async {
    final cached = _libraryPayloadCache;
    if (cached != null &&
        _libraryBuiltAt != null &&
        DateTime.now().difference(_libraryBuiltAt!) < _libraryTtl) {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      req.response.add(utf8.encode(cached));
      await _flush(req);
      return;
    }

    final entries = _readRomIndex();
    final metadata = _readByCrcLayer('cloud_metadata.json');
    // Reading/parsing the cheat layers once (instead of once per ROM) removes
    // the dominant cost of this handler on large libraries.
    final localCheats = _readByCrcLayer('cheats.json');
    final cloudCheats = _readByCrcLayer('cloud_cheats.json');
    bool hasCheatsFor(String crc) {
      final pick = localCheats?[crc] ?? cloudCheats?[crc];
      return pick is List && pick.isNotEmpty;
    }

    final savesDir = Directory('$filesDir/saves');
    final slotRe = RegExp(r'^[0-9A-F]{8}\.slot(\d+)\.state$');
    final Map<String, List<Map<String, dynamic>>> slotIndex = {};
    if (savesDir.existsSync()) {
      for (final fe in savesDir.listSync()) {
        if (fe is! File) continue;
        final base = fe.uri.pathSegments.last;
        final m = slotRe.firstMatch(base);
        if (m == null) continue;
        final crc = base.substring(0, 8);
        final slot = int.parse(m.group(1)!);
        if (slot < 0 || slot > 99) continue;
        final st = fe.statSync();
        final thumbSt =
            File('$filesDir/saves/$crc.slot$slot.jpg').statSync();
        slotIndex.putIfAbsent(crc, () => []).add({
          'slot': slot,
          'mtime': st.modified.millisecondsSinceEpoch,
          'size': st.size,
          'hasThumb': thumbSt.type != FileSystemEntityType.notFound,
        });
      }
    }
    for (final list in slotIndex.values) {
      list.sort((a, b) => (a['slot'] as int).compareTo(b['slot'] as int));
    }

    // One stat() per file instead of exists()+length()+stat() triples.
    ({bool exists, int size, int? mtime}) probe(String path) {
      final st = File(path).statSync();
      if (st.type == FileSystemEntityType.notFound) {
        return (exists: false, size: 0, mtime: null);
      }
      return (
        exists: true,
        size: st.size,
        mtime: st.modified.millisecondsSinceEpoch,
      );
    }

    final games = <Map<String, dynamic>>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final e = raw.cast<String, dynamic>();
      final crc32 = (e['crc32'] as num?)?.toInt();
      if (crc32 == null) continue;
      final crc =
          (crc32 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();
      final battery = probe('$filesDir/saves/$crc.sav');
      final auto = probe('$filesDir/saves/$crc.state');
      final cover = probe('$filesDir/library/covers-cloud/$crc.png');
      games.add({
        ...e,
        'crc': crc,
        'metadata': metadata?[crc] is Map
            ? (metadata![crc] as Map).cast<String, dynamic>()
            : null,
        'hasCheats': hasCheatsFor(crc),
        'hasBattery': battery.exists,
        'batterySize': battery.size,
        'batteryMtime': battery.mtime,
        'hasAuto': auto.exists,
        'autoSize': auto.size,
        'autoMtime': auto.mtime,
        'slots': slotIndex[crc] ?? const [],
        'hasCover': cover.exists,
        'coverSize': cover.size,
      });
    }

    final payload = jsonEncode({
      'service': PeerProtocol.serviceTag,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'protocolVersion': PeerProtocol.protocolVersion,
      'games': games,
    });
    _libraryPayloadCache = payload;
    _libraryBuiltAt = DateTime.now();

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    req.response.add(utf8.encode(payload));
    await _flush(req);
  }

  /// Resolve a CRC to its ROM file via the (trusted, local) index; the
  /// network only supplies the CRC, never a path.
  File? _romFile(String crc) {
    for (final raw in _readRomIndex()) {
      if (raw is! Map) continue;
      final e = raw.cast<String, dynamic>();
      final v = (e['crc32'] as num?)?.toInt();
      if (v == null) continue;
      final key =
          (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();
      if (key == crc) {
        final rel = e['relativePath'];
        if (rel is String && rel.isNotEmpty) {
          final f = File(_safeInside(filesDir, rel));
          if (f.existsSync()) return f;
        }
        return null;
      }
    }
    return null;
  }

  Future<void> _sendCheats(HttpRequest req, String crcRaw) async {
    String crc;
    try {
      crc = PeerFiles.crc8(crcRaw);
    } catch (_) {
      await _sendError(req, HttpStatus.badRequest, 'bad_crc');
      return;
    }
    final cheats = _effectiveCheats(crc);
    if (cheats == null) {
      await _sendError(req, HttpStatus.notFound, 'no_cheats');
      return;
    }
    await _sendJson(req, {'crc': crc, 'cheats': cheats});
  }

  static final _slotKindRe = RegExp(r'^slot(?:Thumb)?(\d{1,2})$');

  Future<void> _sendSave(HttpRequest req, String crcRaw) async {
    String crc;
    try {
      crc = PeerFiles.crc8(crcRaw);
    } catch (_) {
      await _sendError(req, HttpStatus.badRequest, 'bad_crc');
      return;
    }
    final kind = req.uri.queryParameters['kind'];
    String fileName;
    String contentType;
    switch (kind) {
      case 'battery':
        fileName = '$crc.sav';
        contentType = 'application/octet-stream';
      case 'auto':
        fileName = '$crc.state';
        contentType = 'application/octet-stream';
      default:
        final m = kind == null ? null : _slotKindRe.firstMatch(kind);
        if (m == null) {
          await _sendError(req, HttpStatus.badRequest, 'bad_kind');
          return;
        }
        final slot = int.parse(m.group(1)!);
        if (slot > 99) {
          await _sendError(req, HttpStatus.badRequest, 'bad_kind');
          return;
        }
        final isThumb = kind!.startsWith('slotThumb');
        fileName =
            isThumb ? '$crc.slot$slot.jpg' : '$crc.slot$slot.state';
        contentType = isThumb ? 'image/jpeg' : 'application/octet-stream';
    }
    final f = File('$filesDir/saves/$fileName');
    if (!f.existsSync()) {
      await _sendError(req, HttpStatus.notFound, 'not_found');
      return;
    }
    _streamFile(req, f, contentType);
  }

  Future<void> _sendFileByCrc(
    HttpRequest req,
    String crcRaw,
    File? Function(String crc) resolve, {
    String contentType = 'application/octet-stream',
  }) async {
    String crc;
    try {
      crc = PeerFiles.crc8(crcRaw);
    } catch (_) {
      return _sendError(req, HttpStatus.badRequest, 'bad_crc');
    }
    final f = resolve(crc);
    if (f == null || !f.existsSync()) {
      return _sendError(req, HttpStatus.notFound, 'not_found');
    }
    _streamFile(req, f, contentType);
  }

  // --------------------------------------------------------------- BIOS

  /// Advertise the BIOS blobs present in `system/`: only the file names the
  /// installed cores require (neogeo.zip, …) — never arbitrary system files.
  Future<void> _sendBiosList(HttpRequest req) async {
    final baseDir = '$filesDir/system';
    final out = <Map<String, dynamic>>[];
    for (final name in SystemFiles.biosNames()) {
      File? f;
      for (final subdir in SystemFiles.systemDirs()) {
        final cand =
            File(subdir.isEmpty ? '$baseDir/$name' : '$baseDir/$subdir/$name');
        if (cand.existsSync()) {
          f = cand;
          break;
        }
      }
      if (f != null) out.add({'name': name, 'size': f.lengthSync()});
    }
    await _sendJson(req, {'bios': out});
  }

  /// Stream a single BIOS blob. The name is validated against the known BIOS
  /// set, so a crafted path segment cannot reach other files on disk.
  Future<void> _sendBios(HttpRequest req, String nameRaw) async {
    final name = Uri.decodeComponent(nameRaw);
    if (!SystemFiles.biosNames().contains(name)) {
      await _sendError(req, HttpStatus.badRequest, 'bad_name');
      return;
    }
    File? f;
    for (final subdir in SystemFiles.systemDirs()) {
      final cand = File(subdir.isEmpty
          ? '$filesDir/system/$name'
          : '$filesDir/system/$subdir/$name');
      if (cand.existsSync()) {
        f = cand;
        break;
      }
    }
    if (f == null) {
      await _sendError(req, HttpStatus.notFound, 'not_found');
      return;
    }
    _streamFile(req, f, 'application/octet-stream');
  }

  void _streamFile(HttpRequest req, File f, String contentType) {
    final len = f.lengthSync();
    req.response.statusCode = HttpStatus.ok;
    req.response.headers
      ..set(HttpHeaders.contentLengthHeader, len.toString())
      ..set(HttpHeaders.contentTypeHeader, contentType);
    f.openRead().listen(
      req.response.add,
      onError: (_) {
        try {
          req.response.close();
        } catch (_) {}
      },
      onDone: () {
        try {
          req.response.close();
        } catch (_) {}
      },
      cancelOnError: true,
    );
  }

  /// Normalize [rel] and guarantee the result stays under [base]. Throws
  /// ArgumentError on absolute paths or `..` escaping the root.
  static String _safeInside(String base, String rel) {
    final r = rel.replaceAll('\\', '/');
    if (r.startsWith('/') || r.contains(':/')) {
      throw ArgumentError('absolute path not allowed');
    }
    final parts = <String>[];
    for (final seg in r.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) throw ArgumentError('path escapes root');
        parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    final root =
        base.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return '$root/${parts.join('/')}';
  }
}
