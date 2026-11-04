import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/helpers.dart';

/// 云存档客户端加密 —— 合规红线：存档由客户端 AES-256-GCM 加密后上传，
/// 服务端只存密文 [`encrypted_blob`]，不持有密钥、不解密（见后端 `CloudSaveBlob`）。
///
/// 加密 blob 布局：
///   [ salt(16) ][ nonce(12) ][ ciphertext ][ mac(16) ]
/// salt 为 PBKDF2 派生密钥所用的随机盐；nonce 为 AES-GCM 随机 IV。
///
/// 密钥来源：用户设定的「云存档密码」经 PBKDF2-HMAC-SHA256（15 万次）派生。
/// 该密码跨设备可复用（在新设备重新输入即可还原同一密钥），满足云存档跨设备恢复。
class CloudCrypto {
  static const int _iterations = 150000;
  static const int _saltLen = 16;
  static const int _nonceLen = 12;
  static const int _macLen = 16;

  /// 用 [passphrase] 加密 [plain]，返回可安全上传的二进制 blob。
  static Future<Uint8List> encrypt(Uint8List plain, String passphrase) async {
    final salt = Uint8List(_saltLen);
    fillBytesWithSecureRandom(salt);
    final key = await _derive(passphrase, salt);
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(plain, secretKey: key, nonce: aes.newNonce());
    return Uint8List.fromList([...salt, ...box.concatenation()]);
  }

  /// 解密 [blob]（由 [encrypt] 产生）。密码错误会抛异常（GCM tag 校验失败）。
  static Future<Uint8List> decrypt(Uint8List blob, String passphrase) async {
    if (blob.length < _saltLen + _nonceLen + _macLen) {
      throw const FormatException('云存档密文格式无效');
    }
    final salt = blob.sublist(0, _saltLen);
    final rest = blob.sublist(_saltLen);
    final key = await _derive(passphrase, salt);
    final box = SecretBox.fromConcatenation(
      rest,
      nonceLength: _nonceLen,
      macLength: _macLen,
    );
    final aes = AesGcm.with256bits();
    return Uint8List.fromList(await aes.decrypt(box, secretKey: key));
  }

  static Future<SecretKey> _derive(String passphrase, List<int> salt) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }
}
