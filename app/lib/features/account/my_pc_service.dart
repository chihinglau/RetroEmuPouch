import 'dart:async';
import 'dart:io';

import '../../data/peer/peer_client.dart';
import '../../data/peer/peer_store.dart';
import '../../pal/platform_pal.dart';
import '../settings/app_settings.dart';

/// A paired PC (from the local [PeerStore]) with everything required to reach
/// its save/settings sync endpoints over the LAN.
class MyPc {
  MyPc(this.record);
  final PeerRecord record;

  String get name => record.name;

  /// `http://ip:port` the partner's peer server last advertised, or null when
  /// the saved record has no reachable address yet.
  String? get baseUrl => (record.lastIp != null && record.lastHttpPort != null)
      ? 'http://${record.lastIp}:${record.lastHttpPort}'
      : null;

  /// Outbound token we present when calling this partner.
  String? get token => record.outboundToken;

  bool get ready => baseUrl != null && token != null;
}

/// LAN save/settings synchronisation with the user's own paired PC. Mirrors the
/// design's "self-hosted PC" model: ROMs are never touched; only the user's own
/// save files and settings cross the wire, and only inside the LAN.
class MyPcService {
  MyPcService(this.pal);
  final PlatformPal pal;

  /// Load the locally paired PCs (works without a live scan — uses the
  /// persisted [PeerStore]).
  Future<List<MyPc>> list() async {
    final dir = await pal.filesDir();
    final store = await PeerStore.load(dir);
    return store.list.map(MyPc.new).toList();
  }

  PeerClient? _client(MyPc pc) {
    if (!pc.ready) return null;
    return PeerClient(baseUrl: pc.baseUrl!, selfDeviceId: '', token: pc.token!);
  }

  /// Phone → PC: push the 11 [AppSettings] values.
  Future<void> pushSettings(MyPc pc) async {
    final c = _client(pc);
    if (c == null) throw StateError('PC 连接信息不完整，请在「发现伙伴」重新配对');
    try {
      final a = await AppSettings.load();
      await c.putSettings(a.toMap().cast<String, dynamic>());
    } finally {
      c.close();
    }
  }

  /// PC → Phone: download settings and write them into the live [AppSettings]
  /// (persisted via the OHOS file fallback store).
  Future<void> pullSettings(MyPc pc) async {
    final c = _client(pc);
    if (c == null) throw StateError('PC 连接信息不完整，请在「发现伙伴」重新配对');
    try {
      final remote = await c.getSettings();
      final map = remote.cast<String, Object>();
      final a = await AppSettings.load();
      a.applyMap(map);
      await a.save();
    } finally {
      c.close();
    }
  }

  /// Phone → PC: upload every local save file. Returns the count uploaded.
  Future<int> pushSaves(MyPc pc) async {
    final c = _client(pc);
    if (c == null) throw StateError('PC 连接信息不完整，请在「发现伙伴」重新配对');
    try {
      final dir = await pal.filesDir();
      final saveDir = Directory('$dir/saves');
      if (!await saveDir.exists()) return 0;
      var n = 0;
      await for (final ent in saveDir.list()) {
        if (ent is! File) continue;
        final name = ent.path.split(RegExp(r'[/\\]')).last;
        final crc = saveCrc(name);
        if (crc == null) continue;
        await c.uploadSave(crc, name, ent);
        n++;
      }
      return n;
    } finally {
      c.close();
    }
  }

  /// PC → Phone: download the PC's saves into the local save directory.
  /// Returns the count downloaded.
  Future<int> pullSaves(MyPc pc) async {
    final c = _client(pc);
    if (c == null) throw StateError('PC 连接信息不完整，请在「发现伙伴」重新配对');
    try {
      final dir = await pal.filesDir();
      final list = await c.listSaves();
      var n = 0;
      for (final s in list) {
        final crc = (s['crc'] as String?) ?? '';
        final name = (s['name'] as String?) ?? '';
        if (crc.isEmpty || name.isEmpty) continue;
        final dest = File('$dir/saves/$name');
        await c.downloadSaveFile(crc, name, dest);
        n++;
      }
      return n;
    } finally {
      c.close();
    }
  }

  /// Extract the CRC32 (8 hex) from a local save file name like `ABCD1234.sav`
  /// or `ABCD1234.slot3.state`. Returns null for unrelated files (covers,
  /// thumbnails, etc.).
  static String? saveCrc(String name) {
    final m = RegExp(r'^([0-9A-Fa-f]{8})\.(sav|state)$').firstMatch(name) ??
        RegExp(r'^([0-9A-Fa-f]{8})\.slot\d+\.state$').firstMatch(name);
    return m?.group(1)?.toUpperCase();
  }
}
