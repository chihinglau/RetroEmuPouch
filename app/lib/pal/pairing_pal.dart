import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

/// A user's self-hosted PC discovered over LAN mDNS.
///
/// Mirrors the fields the UDP `GP-PEER-PONG` payload carries so the rest of the
/// peer stack can treat mDNS and UDP discoveries identically.
class PcDiscovery {
  PcDiscovery({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.port,
    this.protocolVersion = 1,
  });

  final String deviceId;
  final String name;
  final String ip;
  final int port;
  final int protocolVersion;

  String get baseUrl => 'http://$ip:$port';
}

/// LAN discovery seam for self-hosted PCs. Mirrors [AdPal]/[BillingPal]: one
/// interface, a real implementation, and a safe NoOp fallback so the app still
/// builds/runs where multicast DNS is unavailable.
abstract interface class PairingPal {
  /// Browse the LAN for `_retroemupouch._tcp.local` services. Returns the
  /// discovered PCs (empty list when none / unsupported). Never throws.
  Future<List<PcDiscovery>> discover({
    Duration timeout = const Duration(seconds: 4),
  });
}

/// Pure-Dart mDNS browser. Works on both Android and OpenHarmony because it
/// relies only on `RawDatagramSocket` multicast, which the OHOS Flutter fork
/// already uses for the UDP `GP-PEER-PING` discovery. Degrades to `[]` on any
/// error (multicast filtered by the OS / AP isolation) so the existing UDP
/// broadcast path remains the dependable fallback.
///
/// The PC server advertises `_retroemupouch._tcp.local` with its stable
/// `deviceId` as the service instance label (so discovery yields a reliable id
/// even when the TXT record is stripped), and the human `name` + protocol
/// version in the TXT record (best-effort; falls back to the id for display if
/// the TXT is unavailable — the authoritative name arrives at pairing time).
class MdnsPairingPal implements PairingPal {
  MdnsPairingPal({
    this.serviceType = '_retroemupouch._tcp.local',
  });

  final String serviceType;

  @override
  Future<List<PcDiscovery>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient();
    final found = <String, PcDiscovery>{};
    Timer? stopper;
    try {
      await client.start();
      stopper = Timer(timeout, () {
        try {
          client.stop();
        } catch (_) {/* already stopping */}
      });
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(serviceType),
      )) {
        final label = _stripInstance(ptr.domainName);
        if (label.isEmpty) continue;
        var deviceId = label;
        var name = label;
        var proto = 1;

        // Best-effort TXT (multicast_dns returns the raw TXT string).
        try {
          await for (final txt in client.lookup<TxtResourceRecord>(
            ResourceRecordQuery.text(ptr.domainName),
          )) {
            final parsed = _parseTxt(txt.text);
            if (parsed.deviceId.isNotEmpty) deviceId = parsed.deviceId;
            if (parsed.name.isNotEmpty) name = parsed.name;
            proto = parsed.protocolVersion;
          }
        } catch (_) {/* TXT optional */}

        await for (final srv in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          await for (final ipRec in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            found[deviceId] = PcDiscovery(
              deviceId: deviceId,
              name: name,
              ip: ipRec.address.address,
              port: srv.port,
              protocolVersion: proto,
            );
          }
        }
      }
    } catch (_) {
      // multicast unavailable / filtered — UDP discovery still covers it
    } finally {
      stopper?.cancel();
      try {
        client.stop();
      } catch (_) {/* already stopped */}
    }
    return found.values.toList();
  }

  /// `pc-xxxx._retroemupouch._tcp.local` (optionally with a trailing dot) →
  /// `pc-xxxx`.
  static String _stripInstance(String domainName) {
    const suffix = '._retroemupouch._tcp.local';
    final lower = domainName.toLowerCase();
    final idx = lower.indexOf(suffix);
    final label = idx >= 0 ? domainName.substring(0, idx) : domainName;
    return label.replaceAll(RegExp(r'\.+$'), '');
  }

  /// Parses the `deviceId=…&name=…&protocolVersion=1` TXT blob zeroconf emits.
  static ({String deviceId, String name, int protocolVersion}) _parseTxt(
      String text) {
    var deviceId = '';
    var name = '';
    var pv = 1;
    for (final kv in text.split(RegExp(r'[&\n]'))) {
      final eq = kv.indexOf('=');
      if (eq <= 0) continue;
      final k = kv.substring(0, eq);
      final v = kv.substring(eq + 1);
      if (k == 'deviceId') {
        deviceId = v;
      } else if (k == 'name') {
        name = v;
      } else if (k == 'protocolVersion') {
        pv = int.tryParse(v) ?? 1;
      }
    }
    return (deviceId: deviceId, name: name, protocolVersion: pv);
  }
}

/// Fallback used when mDNS is unavailable; returns no PCs (the existing UDP
/// broadcast discovery remains the primary path).
class NoOpPairingPal implements PairingPal {
  @override
  Future<List<PcDiscovery>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async =>
      const [];
}

/// Returns the platform-appropriate [PairingPal]. mDNS works uniformly across
/// Android and OpenHarmony via the pure-Dart [MdnsPairingPal]; [NoOpPairingPal]
/// is available for tests / unsupported environments.
PairingPal createPairingPal() => MdnsPairingPal();
