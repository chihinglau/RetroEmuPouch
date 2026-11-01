import 'dart:convert';
import 'dart:io';

import '../../pal/pal_factory.dart';
import '../../pal/platform_pal.dart';

/// A PC the user has paired with (their own self-hosted server).
class PairedPc {
  PairedPc({
    required this.id,
    required this.name,
    required this.token,
    required this.addedAt,
  });

  final String id;
  final String name;
  final String token;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'token': token,
        'addedAt': addedAt.toIso8601String(),
      };

  factory PairedPc.fromJson(Map<String, dynamic> j) => PairedPc(
        id: j['id'] as String,
        name: j['name'] as String,
        token: j['token'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String),
      );
}

/// Local record of the user's paired PCs. The PC server is user-self-hosted, so
/// no ROM binaries ever leave the LAN / your cloud — only user data + pairing
/// metadata. LAN mDNS discovery + a [PairingPal] seam is a later sub-step (TODO).
class PairingService {
  PairingService(this._pal);
  final PlatformPal _pal;

  List<PairedPc> _list = const [];
  List<PairedPc> get list => _list;

  static Future<PairingService> create() async {
    final pal = createPlatformPal();
    final s = PairingService(pal);
    await s.load();
    return s;
  }

  Future<void> load() async {
    final dir = Directory('${(await _pal.filesDir())}/account');
    final file = File('${dir.path}/paired_pcs.json');
    if (file.existsSync()) {
      final data = jsonDecode(await file.readAsString()) as List<dynamic>;
      _list = data
          .map((e) => PairedPc.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  }

  Future<void> add(PairedPc pc) async {
    _list = [..._list, pc];
    await _save();
  }

  Future<void> remove(String id) async {
    _list = _list.where((e) => e.id != id).toList();
    await _save();
  }

  Future<void> _save() async {
    final dir = Directory('${(await _pal.filesDir())}/account');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/paired_pcs.json');
    await file.writeAsString(
      jsonEncode(_list.map((e) => e.toJson()).toList()),
    );
  }
}
