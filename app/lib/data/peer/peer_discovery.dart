import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// LAN discovery for 「发现伙伴」, deliberately separate from the PC-cloud
/// discovery line: distinct magic strings (`GP-PEER-PING`/`GP-PEER-PONG `)
/// and service tag (`GamePouch Peer`) share only UDP port 43801, so cloud
/// servers never appear as peers and vice versa.
///
/// Topology is symmetric: every device runs a [PeerResponder] while the peers
/// page is open AND scans for other responders. A peer's HTTP server binds a
/// random high port; that port is carried in the PONG payload. The UDP
/// reply's **sender** address is authoritative — self-reported IPs are
/// ignored.
///
/// Design constraint: a random HTTP port cannot be found by a full /24 TCP
/// sweep (65k candidates per host). Therefore the TCP fallback only probes
/// the last-known `ip:port` of already-paired partners via /api/peer/info.
class PeerProtocol {
  static const int udpPort = 43801;
  static const int protocolVersion = 1;
  static const String serviceTag = 'GamePouch Peer';
  static const String pingMagic = 'GP-PEER-PING';
  static const String pongPrefix = 'GP-PEER-PONG ';
}

/// A discovered peer (paired status is filled in by the page via PeerStore).
class PeerEndpoint {
  PeerEndpoint({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.httpPort,
    required this.protocolVersion,
  });

  final String deviceId;
  final String name;
  final String ip;
  final int httpPort;
  final int protocolVersion;

  String get baseUrl => 'http://$ip:$httpPort';

  static PeerEndpoint? parsePong(Map<dynamic, dynamic> m, String senderIp) {
    if ((m['service'] as String? ?? '') != PeerProtocol.serviceTag) {
      return null;
    }
    final deviceId = m['deviceId'];
    final httpPort = (m['httpPort'] as num?)?.toInt();
    if (deviceId is! String || deviceId.isEmpty || httpPort == null) {
      return null;
    }
    return PeerEndpoint(
      deviceId: deviceId,
      name: (m['name'] as String?) ?? '伙伴',
      ip: senderIp,
      httpPort: httpPort,
      protocolVersion:
          (m['protocolVersion'] as num?)?.toInt() ?? PeerProtocol.protocolVersion,
    );
  }
}

/// Answers `GP-PEER-PING` datagrams with a unicast PONG. Binding 43801 can
/// fail when another local instance (e.g. a second app in a work profile)
/// already holds it; [start] then returns false and the device simply stays
/// silent while still able to scan others.
class PeerResponder {
  RawDatagramSocket? _sock;
  String? _deviceId;
  String? _name;
  int? _httpPort;

  bool get isListening => _sock != null;

  Future<bool> start({
    required String deviceId,
    required String name,
    required int httpPort,
    int port = PeerProtocol.udpPort,
  }) async {
    await stop();
    _deviceId = deviceId;
    _name = name;
    _httpPort = httpPort;
    try {
      _sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    } catch (_) {
      _sock = null; // degraded: scan-only mode
      return false;
    }
    _sock!.listen(_onEvent);
    return true;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final sock = _sock;
    if (sock == null) return;
    // Drain every queued datagram: under load Windows may surface several
    // arrivals with a single read event and receive() alone would drop the
    // rest (partners going invisible during scans).
    Datagram? dg;
    while ((dg = sock.receive()) != null) {
      final incoming = dg!;
      // Exact magic match — anything else (including GP-PING from the cloud
      // line or random noise) gets no reply.
      final text = utf8.decode(incoming.data, allowMalformed: true);
      if (text != PeerProtocol.pingMagic) continue;
      final payload = jsonEncode({
        'service': PeerProtocol.serviceTag,
        'deviceId': _deviceId,
        'name': _name,
        'httpPort': _httpPort,
        'protocolVersion': PeerProtocol.protocolVersion,
      });
      try {
        sock.send(
            utf8.encode('${PeerProtocol.pongPrefix}$payload'),
            incoming.address,
            incoming.port);
      } catch (_) {/* sender gone; irrelevant */}
    }
  }

  Future<void> stop() async {
    _sock?.close();
    _sock = null;
  }
}

/// Broadcasts PING probes and collects PONG replies from every responder.
class PeerScanner {
  PeerScanner({
    this.scanTimeout = const Duration(milliseconds: 3500),
    this.probeInterval = const Duration(milliseconds: 700),
    this.probeCount = 3,
  });

  final Duration scanTimeout;
  final Duration probeInterval;
  final int probeCount;

  /// One discovery cycle.
  ///
  /// Sends [probeCount] UDP broadcasts to [port] spaced by [probeInterval],
  /// plus unicast PINGs to [unicastTargets] (used for loopback tests and for
  /// re-probing paired partners at their saved address/port). Results are
  /// deduped by deviceId and the device itself ([selfDeviceId]) is removed.
  Future<List<PeerEndpoint>> scan({
    required String selfDeviceId,
    int port = PeerProtocol.udpPort,
    List<({InternetAddress address, int port})>? unicastTargets,
  }) async {
    final byDevice = <String, PeerEndpoint>{};
    RawDatagramSocket? sock;
    Timer? probeTimer;
    Timer? timeoutTimer;
    final completer = Completer<void>();

    void collect(PeerEndpoint ep) {
      if (ep.deviceId == selfDeviceId) return; // never list ourselves
      byDevice.putIfAbsent(ep.deviceId, () => ep);
    }

    void sendPing(InternetAddress address, int targetPort) {
      try {
        sock?.send(utf8.encode(PeerProtocol.pingMagic), address, targetPort);
      } catch (_) {/* broadcast blocked on this interface */}
    }

    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final s = sock;

      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        // Drain the whole receive queue per event (see PeerResponder).
        Datagram? dg;
        while ((dg = s.receive()) != null) {
          final incoming = dg!;
          final text =
              utf8.decode(incoming.data, allowMalformed: true);
          if (!text.startsWith(PeerProtocol.pongPrefix)) continue;
          try {
            final m = jsonDecode(
                    text.substring(PeerProtocol.pongPrefix.length))
                as Map;
            final ep =
                PeerEndpoint.parsePong(m, incoming.address.address);
            if (ep != null) collect(ep);
          } catch (_) {/* malformed PONG */}
        }
      });

      var left = probeCount;
      void burst() {
        if (left <= 0) return;
        left--;
        sendPing(InternetAddress('255.255.255.255'), port);
        for (final t in unicastTargets ?? const []) {
          sendPing(t.address, t.port);
        }
      }

      burst();
      probeTimer = Timer.periodic(probeInterval, (_) => burst());
      timeoutTimer = Timer(scanTimeout, () {
        if (!completer.isCompleted) completer.complete();
      });
    } catch (_) {
      return []; // cannot even allocate a probe socket
    }

    try {
      await completer.future;
    } finally {
      probeTimer.cancel();
      timeoutTimer.cancel();
      sock.close();
    }
    return byDevice.values.toList();
  }

  /// Quick unicast PING to one known partner IP. Used right before sending a
  /// netplay invite: the partner's random HTTP port changes every time their
  /// peers page is reopened, and the library page may have cached a stale
  /// base URL. Returns the fresh endpoint on the first matching PONG, or
  /// null within [timeout].
  Future<PeerEndpoint?> probeOne(
    InternetAddress target, {
    required String selfDeviceId,
    String? expectDeviceId,
    int port = PeerProtocol.udpPort,
    Duration timeout = const Duration(milliseconds: 1300),
  }) async {
    final completer = Completer<PeerEndpoint?>();
    RawDatagramSocket? sock;
    Timer? timer;
    var left = 3;
    void finish(PeerEndpoint? ep) {
      if (!completer.isCompleted) completer.complete(ep);
    }

    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final s = sock;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = s.receive()) != null) {
          final incoming = dg!;
          final text = utf8.decode(incoming.data, allowMalformed: true);
          if (!text.startsWith(PeerProtocol.pongPrefix)) continue;
          try {
            final m =
                jsonDecode(text.substring(PeerProtocol.pongPrefix.length))
                    as Map;
            final ep = PeerEndpoint.parsePong(m, incoming.address.address);
            if (ep == null || ep.deviceId == selfDeviceId) continue;
            if (expectDeviceId != null && ep.deviceId != expectDeviceId) {
              continue;
            }
            finish(ep);
          } catch (_) {/* malformed PONG */}
        }
      });
      void ping() {
        if (left <= 0) return;
        left--;
        try {
          s.send(utf8.encode(PeerProtocol.pingMagic), target, port);
        } catch (_) {/* target unreachable */}
      }

      ping();
      timer = Timer.periodic(const Duration(milliseconds: 350), (_) => ping());
      Timer(timeout, () => finish(null));
    } catch (_) {
      timer?.cancel();
      sock?.close();
      return null;
    }

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      sock.close();
    }
  }

  /// TCP fallback / direct probe of a known partner at `http://[ip]:[port]`.
  /// Random peer HTTP ports make a subnet sweep impossible, so this is only
  /// used against paired partners' saved endpoints (best-effort; the port
  /// changes every time the partners page is reopened).
  Future<PeerEndpoint?> probeHttp(
    String ip,
    int port, {
    required String selfDeviceId,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 900);
    try {
      final req = await client.get(ip, port, '/api/peer/info');
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        unawaited(res.drain<void>().catchError((_) {}));
        return null;
      }
      final body =
          await res.transform(utf8.decoder).join().timeout(timeout);
      final m = jsonDecode(body) as Map;
      if (m['deviceId'] == selfDeviceId) return null;
      return PeerEndpoint(
        deviceId: m['deviceId'] as String,
        name: (m['name'] as String?) ?? '伙伴',
        ip: ip,
        httpPort: port,
        protocolVersion: (m['protocolVersion'] as num?)?.toInt() ??
            PeerProtocol.protocolVersion,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// IPv4 addresses of wlan* interfaces — the same restriction the cloud
  /// discovery uses, so cellular (rmnet) and VPN (tun) are never touched.
  static Future<Set<String>> wlanAddresses() async {
    final out = <String>{};
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4)) {
        if (!ni.name.toLowerCase().startsWith('wlan')) continue;
        for (final a in ni.addresses) {
          out.add(a.address);
        }
      }
    } catch (_) {/* interface enumeration unavailable */}
    return out;
  }
}
