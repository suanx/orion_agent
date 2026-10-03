import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/file_storage_service.dart';

void main() {
  group('formatBytes', () {
    test('小于 1KB 显示原始字节数', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('KB / MB / GB 逐级换算', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('大于 100 时省略小数', () {
      expect(formatBytes(200 * 1024), '200 KB');
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
    });

    test('GB 是最大单位，不再继续换算', () {
      expect(formatBytes(2048 * 1024 * 1024), '2.0 GB');
    });
  });

  group('StorageEntry', () {
    test('sizeText 复用 formatBytes', () {
      const e = StorageEntry(
        label: '缓存',
        path: '/tmp/tts',
        bytes: 2048,
        fileCount: 3,
      );
      expect(e.sizeText, '2.0 KB');
      expect(e.deletable, isTrue);
      expect(e.note, isNull);
    });

    test('可标记为不可清理并附带说明', () {
      const e = StorageEntry(
        label: 'Alpine 终端环境',
        path: '/data/alpine',
        bytes: 0,
        fileCount: 0,
        deletable: false,
        note: '删除后需重新安装',
      );
      expect(e.deletable, isFalse);
      expect(e.note, '删除后需重新安装');
    });
  });
}
