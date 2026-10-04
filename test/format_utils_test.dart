import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/ui/format_utils.dart';

void main() {
  group('compactTokens', () {
    test('千以下原样输出', () {
      expect(compactTokens(999), '999');
      expect(compactTokens(0), '0');
    });

    test('千位段转为 K', () {
      expect(compactTokens(128000), '128K');
      expect(compactTokens(1000), '1K');
    });

    test('百万位段转为 M', () {
      expect(compactTokens(1000000), '1M');
      // 1.048576 保留一位小数
      expect(compactTokens(1048576), '1.0M');
    });
  });

  group('parseTokenCount', () {
    test('小写 k 后缀按 1000 倍展开', () {
      expect(parseTokenCount('128k'), 128000);
    });

    test('大写与前后空白同样处理', () {
      expect(parseTokenCount('128K'), 128000);
      expect(parseTokenCount('  2m '), 2000000);
    });

    test('m 后缀按 1000000 倍展开', () {
      expect(parseTokenCount('1.5m'), 1500000);
    });

    test('负数返回 null', () {
      expect(parseTokenCount('-5'), isNull);
    });

    test('非数字返回 null', () {
      expect(parseTokenCount('abc'), isNull);
    });

    test('0 是合法值', () {
      expect(parseTokenCount('0'), 0);
    });

    test('空串返回 null', () {
      expect(parseTokenCount(''), isNull);
      expect(parseTokenCount('   '), isNull);
    });

    test('只有后缀没有数字返回 null', () {
      expect(parseTokenCount('k'), isNull);
      expect(parseTokenCount('m'), isNull);
    });

    test('展开后为非整数返回 null，整数则合法', () {
      expect(parseTokenCount('1.5'), isNull); // 1.5 不是整数 token 数
      expect(parseTokenCount('1.5k'), 1500); // 展开后 1500 是整数
      expect(parseTokenCount('1.234k'), 1234);
    });
  });
}
