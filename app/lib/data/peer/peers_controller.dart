import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../pal/platform_pal.dart';
import '../play/multiplayer_catalog.dart';
import '../play/play_session.dart';
import '../rom_library.dart';
import 'peer_discovery.dart';
import 'peer_identity.dart';
import 'peer_server.dart';
import 'peer_store.dart';

/// Online entry merged from a fresh [PeerEndpoint] and the locally stored
/// credential (null while unpaired).
class PeerView {
  PeerView({required this.endpoint, this.record});

  final PeerEndpoint endpoint;
  PeerRecord? record;

  bool get paired => record != null;
  String get id => endpoint.deviceId;
  String get name => record?.name ?? endpoint.name;
  String get ip => endpoint.ip;
  int get port => endpoint.httpPort;
  String get baseUrl => endpoint.baseUrl;

  /// Token WE present when calling this partner (minted here at pairing).
  String? get outboundToken => record?.outboundToken;
}

/// Owns the foreground-only peer lifecycle: HTTP server, UDP responder,
/// periodic low-frequency scan and the identity/credential stores.
///
/// Everything stops in [stop] (NFR-4 / AC-13): HTTP server closed, UDP
/// sockets closed, timers cancelled, multicast lock released. The class is
/// plain Dart (Flutter `ChangeNotifier` only) so start/stop symmetry is
/// unit-testable with a fake [PlatformPal].
class PeersController extends ChangeNotifier {
  PeersController({
    required this.pal,
    PeerScanner? scanner,
    this.refreshInterval = const Duration(seconds: 9),
  }) : _scanner = scanner ?? PeerScanner();

  final PlatformPal pal;
  final PeerScanner _scanner;
  final Duration refreshInterval;

  String? filesDir;
  PeerIdentity? identity;
  PeerStore? store;
  PeerServer? server;
  PeerResponder? responder;

  /// Netplay signaling session owner (single active session per device).
  /// Lives as long as the peer foreground services. Task 9 extends its
  /// lifetime across the lobby→game boundary.
  PlaySessionManager? plays;

  final List<PeerView> peers = [];
  bool scanning = false;
  bool active = false;
  bool responderListening = true;

  /// 0 = no cycle has finished yet; otherwise true when the last cycle
  /// found at least one device. Drives the unreachable-network empty state.
  bool? get lastCycleFound => _lastCycleFound;
  bool? _lastCycleFound;

  Timer? _refreshTimer;
  int _generation = 0;

  /// Native EmulatorActivity → local PlaySession terminal bridge, and the
  /// watcher that releases retained services once a retained session ends
  /// while no peers page owns this controller (Task 9).
  StreamSubscription<NetplayPlayEnd>? _playEndSub;
  StreamSubscription<PlaySession>? _playChangesSub;

  /// App-global chain serializing start/stop across controller instances.
  /// PeersPage builds a new controller per visit and its dispose does not
  /// await stop(); without this chain a quick back→re-enter could bind a new
  /// HTTP server / UDP responder while the previous ones are still closing —
  /// two responders on UDP 43801 would then advertise different HTTP ports
  /// and partners could invite a zombie server (200 with no UI listener).
  static Future<void> _lifecycle = Future<void>.value();

  static Future<T> _chain<T>(Future<T> Function() action) {
    final done = _lifecycle.then((_) => action());
    _lifecycle = done.then((_) {}, onError: (_) {});
    return done;
  }

  String get selfDeviceId => identity?.deviceId ?? '';
  String get selfName => identity?.name ?? '趣玩匣';
  PeerServer? get pairServer => server;

  /// Start all local services and run the first discovery cycle.
  Future<void> start() => _chain(_startLocked);

  Future<void> _startLocked() async {
    if (active) return;
    // Adopt the stack an earlier stop() kept alive for a live session (same
    // controller restarted while the game/signaling is still running).
    final retained = plays;
    if (retained != null &&
        retained.current != null &&
        server?.isRunning == true) {
      active = true;
      _refreshTimer = Timer.periodic(refreshInterval, (_) => refresh());
      notifyListeners();
      unawaited(refresh());
      return;
    }
    if (retained != null) {
      // Retained manager whose session is over / services gone: drop it
      // before building the fresh stack below.
      plays = null;
      await _cancelPlaySubs();
      await retained.dispose();
    }
    active = true;
    final dir = await pal.filesDir();
    filesDir = dir;
    final model = await pal.deviceModel();
    final id = await PeerIdentity.load(dir, defaultName: model);
    identity = id;
    final st = await PeerStore.load(dir);
    store = st;
    String version = '';
    var versionCode = 0;
    try {
      final v = await pal.appVersion();
      version = v.versionName;
      versionCode = v.versionCode;
    } catch (_) {/* version is informational only */}

    final catalog = MultiplayerCatalog.instance;
    final playManager = PlaySessionManager(
      selfDeviceId: id.deviceId,
      selfName: id.name,
      localVersionCode: versionCode,
      // Authoritative gate backing the hidden UI entry: invitees re-check the
      // game against the bundled catalog. FC keys off CRC; arcade keys off
      // the locally-owned zip's MAME driver name. Everything else (unknown
      // core, missing local ROM, hacks) fails closed.
      multiplayerAllowed: catalog == null
          ? null
          : (coreId, romCrc) async {
              if (coreId == 'fceumm') {
                return catalog.isMultiplayer(
                    coreId: coreId, romCrc: romCrc);
              }
              if (coreId == 'fbalpha2012' || coreId == 'mame') {
                final entries = await RomLibrary(dir).load();
                for (final e in entries) {
                  if (e.crcKey == romCrc) {
                    // Key the catalog on the driver file name, not the
                    // localised display name (see RomEntry.driverFileName) —
                    // `拳皇97.zip` never matches the catalog driver `kof97`,
                    // which made every renamed arcade invite fail with
                    // `not_multiplayer`.
                    return catalog.isMultiplayer(
                      coreId: coreId,
                      driverName: MultiplayerCatalog.driverFromFileName(
                          e.driverFileName),
                    );
                  }
                }
                return false;
              }
              return false;
            },
    );
    // Bridge native session teardown into the local PlaySession so a game
    // ending always frees the one-session slot (Task 9, TR-9.2).
    await _playEndSub?.cancel();
    _playEndSub = pal.netplayPlayEnds.listen((e) {
      playManager.notifyNativePlayEnded(roomId32: e.roomId32, clean: e.clean);
    });
    await _playChangesSub?.cancel();
    _playChangesSub = playManager.changes.listen((s) {
      // The page left while a session was live, so stop() retained both the
      // manager and these listeners. Once that session reaches a terminal
      // state there is nobody left to observe it: dispose the manager.
      if (s.isTerminal && !active) unawaited(_releaseOrphanedSession());
    });
    plays = playManager;

    final srv = PeerServer(filesDir: dir, identity: id, store: st,
        appVersion: version, plays: playManager);
    await srv.start();
    server = srv;

    final r = PeerResponder();
    responderListening =
        await r.start(deviceId: id.deviceId, name: id.name, httpPort: srv.port);
    responder = r;

    // Without this lock many firmwares (Huawei included) filter broadcast
    // UDP while the screen is on; held only while this page is foreground.
    await pal.acquireMulticastLock();

    _refreshTimer = Timer.periodic(refreshInterval, (_) => refresh());
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> stop() => _chain(_stopLocked);

  Future<void> _stopLocked() async {
    if (!active) return;
    active = false;
    _generation++;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    // Keep-alive (Task 9): while a netplay session is live the server, UDP
    // responder and multicast lock stay up even without a peers page on
    // screen, so invite/bye signaling and the native playEnded bridge keep
    // working across the lobby→game boundary. The changes watcher tears the
    // retained stack down once the session terminates.
    if (plays?.current != null) {
      peers.clear();
      scanning = false;
      notifyListeners();
      return;
    }
    await _tearDownServices();
    final pm = plays;
    if (pm != null) {
      plays = null;
      await _cancelPlaySubs();
      await pm.dispose();
    }
    peers.clear();
    scanning = false;
    notifyListeners();
  }

  /// Stops responder + HTTP server and releases the multicast lock. Safe to
  /// call with everything already null (e.g. orphan release after a prior
  /// teardown).
  Future<void> _tearDownServices() async {
    final r = responder;
    responder = null;
    await r?.stop();
    final s = server;
    server = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {/* already torn down */}
    }
    await pal.releaseMulticastLock();
  }

  Future<void> _cancelPlaySubs() async {
    await _playEndSub?.cancel();
    _playEndSub = null;
    await _playChangesSub?.cancel();
    _playChangesSub = null;
  }

  /// Last step of the keep-alive policy: stop() retained a live session and
  /// its signaling stack after the peers page went away; the session has now
  /// terminated (native playEnded / remote bye / timeout) with no page coming
  /// back, so release everything for good.
  Future<void> _releaseOrphanedSession() => _chain(() async {
        if (active) return;
        final pm = plays;
        if (pm == null || pm.current != null) return;
        plays = null;
        await _tearDownServices();
        await _cancelPlaySubs();
        await pm.dispose();
        peers.clear();
        scanning = false;
      });

  /// One discovery cycle: UDP broadcast + unicast probes at every saved
  /// partner's last address, plus a TCP /info probe of the saved endpoint
  /// (same session only — peer HTTP ports are random per page open).
  Future<void> refresh() async {
    final id = identity;
    final st = store;
    if (!active || id == null || st == null || scanning) return;
    final gen = ++_generation;
    scanning = true;
    notifyListeners();

    final unicast = <({InternetAddress address, int port})>[];
    for (final p in st.list) {
      final ip = p.lastIp;
      if (ip == null) continue;
      try {
        unicast.add((address: InternetAddress(ip), port: PeerProtocol.udpPort));
      } catch (_) {/* malformed saved IP */}
    }

    List<PeerEndpoint> found;
    try {
      found = await _scanner.scan(
          selfDeviceId: id.deviceId, unicastTargets: unicast);
    } catch (_) {
      found = const [];
    }

    // TCP fallback for saved endpoints whose UDP reply was missed (only
    // usable while the partner kept the same page session / port).
    for (final p in st.list) {
      final ip = p.lastIp;
      final port = p.lastHttpPort;
      if (ip == null || port == null) continue;
      if (found.any((e) => e.deviceId == p.deviceId)) continue;
      try {
        final ep = await _scanner.probeHttp(ip, port,
            selfDeviceId: id.deviceId);
        if (ep != null) found = [...found, ep];
      } catch (_) {/* unreachable — simply stays offline */}
    }

    if (gen != _generation || !active) return;

    // Refresh mutable address/name bookkeeping for paired devices.
    for (final ep in found) {
      final rec = st.get(ep.deviceId);
      if (rec != null) {
        await st.touch(ep.deviceId,
            name: ep.name, lastIp: ep.ip, lastHttpPort: ep.httpPort);
      }
    }

    peers
      ..clear()
      ..addAll(found.map((ep) =>
          PeerView(endpoint: ep, record: st.get(ep.deviceId))))
      ..sort((a, b) {
        if (a.paired != b.paired) return a.paired ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    _lastCycleFound = found.isNotEmpty;
    scanning = false;
    notifyListeners();
  }

  /// Paired partners absent from the latest scan (shown in an offline
  /// section so credentials can still be managed).
  List<PeerRecord> get offlinePaired {
    final onlineIds = peers.map((p) => p.id).toSet();
    return store?.list
            .where((r) => !onlineIds.contains(r.deviceId))
            .toList() ??
        const [];
  }

  Future<void> rename(String newName) async {
    final id = identity;
    final srv = server;
    if (id == null || srv == null) return;
    await id.rename(newName);
    // The responder caches the advertised name; restart it with the new one.
    final r = responder;
    if (r != null) {
      responderListening = await r.start(
          deviceId: id.deviceId, name: id.name, httpPort: srv.port);
    }
    notifyListeners();
  }

  Future<void> unpair(String deviceId) async {
    await store?.remove(deviceId);
    peers.removeWhere((p) => p.id == deviceId);
    notifyListeners();
  }

  /// Record a freshly completed pairing (initiator side). [remoteToken] is
  /// tokenB returned by the responder (the token IT presents to us);
  /// [outboundToken] is tokenA we minted and present to it.
  Future<void> savePaired({
    required String deviceId,
    required String name,
    required String remoteToken,
    required String outboundToken,
    required String ip,
    required int httpPort,
  }) async {
    await store?.upsert(
      deviceId: deviceId,
      name: name,
      token: remoteToken,
      outboundToken: outboundToken,
      lastIp: ip,
      lastHttpPort: httpPort,
    );
    // Reflect pairing immediately in the live list without waiting for the
    // next 9-second scan cycle.
    for (final p in peers) {
      if (p.id == deviceId) {
        p.record = store?.get(deviceId);
        break;
      }
    }
    notifyListeners();
  }

  /// Locate a peer by deviceId in the current online list.
  PeerView? byId(String deviceId) {
    for (final p in peers) {
      if (p.id == deviceId) return p;
    }
    return null;
  }

  /// Incoming pairing requests from the local server (responder UX).
  Stream<PeerPairRequest> get pairRequests =>
      server?.pairRequests ?? const Stream<PeerPairRequest>.empty();
}
