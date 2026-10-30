import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Finds a GamePouch cloud server on the LAN without the user typing an IP.
///
/// Two phases, mirroring tools/library/cloud/discovery.dart on the PC:
///   1. UDP broadcast probe `GP-PING` -> unicast `GP-PONG {json}` (~3.5s)
///   2. TCP sweep of the device wlan subnet against /api/cloud/server/info
///      (~4s), used when Windows firewall / "Public" network blocks UDP
///
/// The UDP reply's **sender** address is used (never a self-reported IP): on
/// a multi-homed PC the reply arrives from the adapter the phone can route
/// to. TCP sweep candidates are restricted to `wlan*` interfaces so cellular
/// (rmnet) and VPN (tun) networks are never scanned, and the device's own
/// wlan address is excluded (a local forwarder must not impersonate the
/// server).
class CloudDiscovery {
  static const int udpPort = 43801;
  static const int defaultHttpPort = 8848;
  static const String serviceTag = 'GamePouch Cloud';

  /// Automatic rediscovery after transport failures is rate-limited; the
  /// manual "重新探测" button bypasses this with force:true.
  static const Duration cooldown = Duration(seconds: 30);

  static DateTime? _lastAutoAt;
  static Future<String?>? _inFlight;

  /// Full two-phase discovery. Returns the base URL like
  /// `http://192.168.1.20:8848`, or null when nothing answered.
  static Future<String?> discover({String? previousUrl}) async {
    final byUdp = await _discoverByUdp(
        timeout: const Duration(milliseconds: 3500));
    if (byUdp != null) return byUdp;
    return _discoverByTcp(previousUrl: previousUrl);
  }

  /// Discovery with cooldown + shared in-flight: concurrent transport
  /// failures trigger at most one scan.
  static Future<String?> auto({String? previousUrl, bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final now = DateTime.now();
    if (!force &&
        _lastAutoAt != null &&
        now.difference(_lastAutoAt!) < cooldown) {
      return Future<String?>.value();
    }
    _lastAutoAt = now;
    final fut = _runAuto(previousUrl);
    _inFlight = fut;
    return fut;
  }

  static Future<String?> _runAuto(String? previousUrl) async {
    try {
      return await discover(previousUrl: previousUrl);
    } finally {
      _inFlight = null;
    }
  }

  // ------------------------------------------------------------- phase 1 UDP

  static Future<String?> _discoverByUdp({required Duration timeout}) async {
    final completer = Completer<String?>();
    RawDatagramSocket? sock;
    Timer? probeTimer;
    Timer? timeoutTimer;
    var probesLeft = 3;

    void finish(String? url) {
      if (!completer.isCompleted) completer.complete(url);
    }

    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final s = sock; // non-null alias captured by the closures below
      s.broadcastEnabled = true;

      void sendPing() {
        if (probesLeft <= 0) return;
        probesLeft--;
        try {
          s.send(utf8.encode('GP-PING'),
              InternetAddress('255.255.255.255'), udpPort);
        } catch (_) {/* broadcast blocked: keep listening for prior probes */}
      }

      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = s.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        const prefix = 'GP-PONG ';
        if (!text.startsWith(prefix)) return;
        try {
          final m = jsonDecode(text.substring(prefix.length)) as Map;
          // Only adopt a replier that identifies as our service.
          if ((m['service'] as String? ?? '') != serviceTag) return;
          final port =
              (m['httpPort'] as num?)?.toInt() ?? defaultHttpPort;
          finish('http://${dg.address.address}:$port');
        } catch (_) {/* malformed payload */}
      });
      sendPing();
      probeTimer = Timer.periodic(
          const Duration(milliseconds: 700), (_) => sendPing());
      timeoutTimer = Timer(timeout, () => finish(null));
    } catch (_) {
      finish(null);
    }

    try {
      return await completer.future;
    } finally {
      probeTimer?.cancel();
      timeoutTimer?.cancel();
      sock?.close();
    }
  }

  // ------------------------------------------------------------- phase 2 TCP

  static Future<String?> _discoverByTcp({String? previousUrl}) async {
    // host:port candidates; a LinkedHashSet keeps insertion order so the
    // last-known host is probed first.
    final candidates = <String>{};
    void addCandidate(String host, int port) {
      if (host.isNotEmpty && port > 0 && port < 65536) {
        candidates.add('$host:$port');
      }
    }

    final prev = previousUrl == null ? null : Uri.tryParse(previousUrl);
    if (prev != null && prev.host.isNotEmpty) {
      addCandidate(
          prev.host, prev.hasPort ? prev.port : defaultHttpPort);
    }

    for (final ni
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      // Wi-Fi interfaces only — never sweep cellular/VPN subnets.
      if (!ni.name.toLowerCase().startsWith('wlan')) continue;
      for (final addr in ni.addresses) {
        final parts = addr.address.split('.');
        if (parts.length != 4) continue;
        final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
        for (var i = 1; i <= 254; i++) {
          final host = '$subnet.$i';
          // Never probe the device's own address: a port-forwarder
          // (e.g. `adb reverse` listening on all interfaces) or a local
          // proxy could answer and masquerade as the LAN server.
          if (host == addr.address) continue;
          addCandidate(host, defaultHttpPort);
        }
      }
    }
    if (candidates.isEmpty) return null;

    // ONE shared client: per-candidate clients would exhaust ephemeral ports
    // with hundreds of concurrent TIME_WAIT sockets.
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700);
    final completer = Completer<String?>();
    final deadline = Timer(const Duration(seconds: 4), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    Future<void> probe(String hostPort) async {
      if (completer.isCompleted) return;
      final idx = hostPort.lastIndexOf(':');
      final host = hostPort.substring(0, idx);
      final port =
          int.tryParse(hostPort.substring(idx + 1)) ?? defaultHttpPort;
      try {
        final req =
            await client.get(host, port, '/api/cloud/server/info');
        final res =
            await req.close().timeout(const Duration(milliseconds: 900));
        if (res.statusCode != 200) {
          unawaited(res.drain<void>().catchError((_) {}));
          return;
        }
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(milliseconds: 900));
        final m = jsonDecode(body) as Map;
        if ((m['service'] as String? ?? '').startsWith('GamePouch') &&
            !completer.isCompleted) {
          completer.complete('http://$host:$port');
        }
      } catch (_) {/* refused / timeout / wrong service */}
    }

    unawaited(Future.wait(candidates.map(probe)));
    try {
      return await completer.future;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
