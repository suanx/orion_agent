import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';

/// 云同步的端上加密原语（可单测的纯逻辑，无 Flutter/网络依赖）。
///
/// 密钥派生：PBKDF2-HMAC-SHA256(账号密码, 固定盐, 2 万次) → 32 字节。
/// 盐必须是**固定值**——各设备用同一密码独立派生，任何设备上传的数据
/// 其他设备才能解出来；用随机盐的话密钥本身就得上云同步，与零知识冲突。
///
/// 加密：AES-256-GCM，每次 12 字节随机 nonce（与密文一并存储）。
class CloudSyncCrypto {
  const CloudSyncCrypto._();

  static const kdfSalt = 'orion_agent_cloud_sync_v1';

  /// 迭代次数：纯 Dart 的 HMAC 循环实测（桌面 Dart）1 万次≈270ms、5 万次≈1.5s，
  /// 手机 ARM 更慢；10 万次会让"解锁"卡住数秒。取 2 万次：真机约 0.3~0.5s，
  /// 且密钥只在首次解锁时派生一次（之后缓存在系统安全存储）。
  static const kdfIterations = 20000;
  static const keyLength = 32;

  /// PBKDF2-HMAC-SHA256，dkLen=32（正好一个 SHA-256 块）。
  static Uint8List deriveKey(String password) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final salt = utf8.encode(kdfSalt);
    // U1 = HMAC(password, salt || INT(1))；U_i = HMAC(password, U_{i-1})
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(u);
    for (var i = 1; i < kdfIterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return Uint8List.fromList(out);
  }

  /// 随机 12 字节 nonce（GCM 推荐长度），base64 便于 JSON 传输。
  static String newNonce() {
    final rnd = Random.secure();
    return base64Encode(List<int>.generate(12, (_) => rnd.nextInt(256)));
  }

  /// 加密任意可 JSON 化对象，返回 base64 密文与 nonce。
  static ({String payload, String nonce}) encryptJson(
      Uint8List key, Object data) {
    final encrypter = Encrypter(AES(Key(key), mode: AESMode.gcm));
    final nonce = newNonce();
    final out = encrypter.encryptBytes(utf8.encode(jsonEncode(data)),
        iv: IV.fromBase64(nonce));
    return (payload: base64Encode(out.bytes), nonce: nonce);
  }

  /// 解密。密钥不匹配或密文被篡改时抛 [CloudSyncCryptoError]
  /// （GCM 认证标签校验失败）。
  static Object decryptJson(
      Uint8List key, String payloadB64, String nonceB64) {
    if (nonceB64.isEmpty) {
      throw const CloudSyncCryptoError('密文缺少 nonce');
    }
    try {
      final encrypter = Encrypter(AES(Key(key), mode: AESMode.gcm));
      final out = encrypter.decryptBytes(Encrypted.fromBase64(payloadB64),
          iv: IV.fromBase64(nonceB64));
      return jsonDecode(utf8.decode(out)) as Object;
    } catch (_) {
      throw const CloudSyncCryptoError('解密失败：密钥不匹配或数据被篡改');
    }
  }
}

/// 加密层错误（密钥不匹配 / 数据损坏）。
class CloudSyncCryptoError implements Exception {
  const CloudSyncCryptoError(this.message);
  final String message;
  @override
  String toString() => message;
}