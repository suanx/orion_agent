import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 云同步的端上加密原语（可单测的纯逻辑，无 Flutter/网络依赖）。
///
/// 依赖说明：直接用 **pointycastle 4.x**（项目里 dartssh2 已经依赖它），
/// 而不是 `encrypt` 包 —— 后者依赖 pointycastle ^3.6.2，与 dartssh2 的
/// ^4.0.0 大版本互斥，会让 pub 版本求解直接失败（CI 实测）。
///
/// 密钥派生：PBKDF2-HMAC-SHA256(账号密码, 固定盐, 2 万次) → 32 字节。
/// 盐必须是**固定值**——各设备用同一密码独立派生，任何设备上传的数据
/// 其他设备才能解出来；用随机盐的话密钥本身就得上云同步，与零知识冲突。
///
/// 加密：AES-256-GCM，每次 12 字节随机 nonce（与密文一并存储）。
/// pointycastle 的 GCM 输出末尾自带 16 字节认证标签，密钥不符或密文被改
/// 都会抛 InvalidCipherTextException。
class CloudSyncCrypto {
  const CloudSyncCrypto._();

  static const kdfSalt = 'orion_agent_cloud_sync_v1';

  /// 迭代次数：实测（桌面 Dart）2 万次≈550ms，手机 ARM 更慢；密钥只在首次
  /// 解锁时派生一次（之后缓存在系统安全存储），5 万次会让解锁明显卡顿。
  static const kdfIterations = 20000;
  static const keyLength = 32;
  static const nonceLength = 12;
  static const _macBits = 128; // GCM 认证标签长度（位）

  /// PBKDF2-HMAC-SHA256，dkLen=32。
  static Uint8List deriveKey(String password) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
        Uint8List.fromList(utf8.encode(kdfSalt)),
        kdfIterations,
        keyLength,
      ));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// 随机 12 字节 nonce（GCM 推荐长度），base64 便于 JSON 传输。
  static String newNonce() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(nonceLength, (_) => rnd.nextInt(256));
    return base64Encode(bytes);
  }

  /// 加密任意可 JSON 化对象，返回 base64 密文与 nonce。
  static ({String payload, String nonce}) encryptJson(
      Uint8List key, Object data) {
    final nonceB64 = newNonce();
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          _macBits,
          Uint8List.fromList(base64Decode(nonceB64)),
          Uint8List(0),
        ),
      );
    final out =
        cipher.process(Uint8List.fromList(utf8.encode(jsonEncode(data))));
    return (payload: base64Encode(out), nonce: nonceB64);
  }

  /// 解密。密钥不匹配或密文被篡改时抛 [CloudSyncCryptoError]
  /// （底层为 InvalidCipherTextException）。
  static Object decryptJson(
      Uint8List key, String payloadB64, String nonceB64) {
    if (nonceB64.isEmpty) {
      throw const CloudSyncCryptoError('密文缺少 nonce');
    }
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            _macBits,
            Uint8List.fromList(base64Decode(nonceB64)),
            Uint8List(0),
          ),
        );
      final out = cipher.process(Uint8List.fromList(base64Decode(payloadB64)));
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