import 'dart:io';

import 'peer_crypto.dart';
import 'peer_files.dart';

/// This device's stable identity on the peer network: a random [deviceId]
/// generated once and a user-editable display [name].
///
/// Persisted at `library/peer_identity.json` inside filesDir. The default name
/// comes from the Android device model (via the gs/storage channel); the
/// platform lookup is injected so this class stays pure-Dart and testable.
class PeerIdentity {
  PeerIdentity({required this.filesDir, required this.deviceId, required this.name});

  final String filesDir;
  final String deviceId;
  String name;

  File get _file => File('$filesDir/library/peer_identity.json');

  /// Load the identity, generating and persisting a fresh one on first use.
  /// [defaultName] is used only when creating; callers pass the device model
  /// or null (falls back to 「我的趣玩匣」).
  static Future<PeerIdentity> load(String filesDir,
      {String? defaultName}) async {
    final file = File('$filesDir/library/peer_identity.json');
    final j = PeerFiles.readJsonOrNull(file);
    if (j is Map) {
      final id = j['deviceId'];
      final name = j['name'];
      if (id is String && id.isNotEmpty && name is String && name.isNotEmpty) {
        return PeerIdentity(filesDir: filesDir, deviceId: id, name: name);
      }
    }
    final identity = PeerIdentity(
      filesDir: filesDir,
      deviceId: PeerCrypto.randomHex(16),
      name: (defaultName == null || defaultName.trim().isEmpty)
          ? '我的趣玩匣'
          : defaultName.trim(),
    );
    await identity.save();
    return identity;
  }

  Future<void> rename(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    name = trimmed;
    await save();
  }

  Future<void> save() => PeerFiles.atomicWriteJson(_file, {
        'version': 1,
        'deviceId': deviceId,
        'name': name,
      });
}
