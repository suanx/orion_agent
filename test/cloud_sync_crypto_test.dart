import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/cloud_sync_crypto.dart';

/// 云同步加密原语单测。
///
/// 锁住三件事：
/// 1. 同一密码在不同设备派生出**同一把**密钥（否则跨设备无法解密）
/// 2. 密文往返一致（含中文/嵌套结构）
/// 3. 换密码或篡改密文必须失败（宁可报错也不能解出垃圾）
void main() {
  group('PBKDF2 密钥派生', () {
    test('同一密码两次派生结果完全一致（跨设备可解密的前提）', () {
      final a = CloudSyncCrypto.deriveKey('MyPass123');
      final b = CloudSyncCrypto.deriveKey('MyPass123');
      expect(a.length, CloudSyncCrypto.keyLength);
      expect(a, b);
    });

    test('不同密码派生出不同密钥', () {
      final a = CloudSyncCrypto.deriveKey('MyPass123');
      final b = CloudSyncCrypto.deriveKey('MyPass124');
      expect(a, isNot(b));
    });

    test('空密码也能派生出合法长度的密钥（不崩溃）', () {
      expect(CloudSyncCrypto.deriveKey('').length, CloudSyncCrypto.keyLength);
    });
  });

  group('AES-256-GCM 加解密', () {
    final key = CloudSyncCrypto.deriveKey('MyPass123');

    test('往返：Map 数据解出后与原文一致', () {
      final data = {
        'id': 's_1',
        'title': '与模型讨论架构设计',
        'messages': [
          {'mid': 'm1', 'content': '帮我看看这段代码 🧐'},
        ],
        'count': 42,
      };
      final c = CloudSyncCrypto.encryptJson(key, data);
      expect(base64Safe(c.payload), isTrue);
      final back = CloudSyncCrypto.decryptJson(key, c.payload, c.nonce);
      expect(back, isA<Map>());
      final m = (back as Map).cast<String, dynamic>();
      expect(m['id'], 's_1');
      expect(m['title'], '与模型讨论架构设计');
      expect(m['count'], 42);
      expect((m['messages'] as List).length, 1);
    });

    test('同一明文两次加密得到不同密文（随机 nonce）', () {
      final a = CloudSyncCrypto.encryptJson(key, {'x': 1});
      final b = CloudSyncCrypto.encryptJson(key, {'x': 1});
      expect(a.payload, isNot(b.payload));
      expect(a.nonce, isNot(b.nonce));
    });

    test('换密码的密钥解不开（抛 CloudSyncCryptoError）', () {
      final c = CloudSyncCrypto.encryptJson(key, {'secret': 'API Key'});
      final wrongKey = CloudSyncCrypto.deriveKey('OtherPass999');
      expect(
        () => CloudSyncCrypto.decryptJson(wrongKey, c.payload, c.nonce),
        throwsA(isA<CloudSyncCryptoError>()),
      );
    });

    test('密文被篡改（改一个字符）必须失败', () {
      final c = CloudSyncCrypto.encryptJson(key, {'secret': 'API Key'});
      final tampered =
          c.payload.substring(0, c.payload.length - 2) +
              (c.payload.endsWith('A') ? 'BB' : 'AA');
      expect(
        () => CloudSyncCrypto.decryptJson(key, tampered, c.nonce),
        throwsA(isA<CloudSyncCryptoError>()),
      );
    });

    test('nonce 为空直接报密钥不匹配路径的错误', () {
      expect(
        () => CloudSyncCrypto.decryptJson(key, 'YWJj', ''),
        throwsA(isA<CloudSyncCryptoError>()),
      );
    });
  });
}

bool base64Safe(String s) => RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(s);