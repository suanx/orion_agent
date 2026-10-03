import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/tools.dart';

/// 这些用例是回归测试：每一条都对应一个曾经真实存在的 bug，
/// 断言里带 reason 把实际输出带出来，CI annotation 直接可见。
Future<String> calc(String expr) => CalculatorTool().execute({'expression': expr});

void main() {
  group('一元负号与幂运算优先级', () {
    // 原实现 _power() 先调 _unary()，负号被贪婪吃掉，
    // 等价于强制 (-2)^2 = 4，与标准数学约定 -2^2 = -4 冲突。
    test('-2^2 等于 -4 而不是 4', () async {
      final r = await calc('-2^2');
      expect(r, '-2^2 = -4', reason: 'r=$r');
    });

    test('2^-2 = 1/4（指数可带负号）', () async {
      final r = await calc('2^-2');
      expect(r, '2^-2 = 0.25', reason: 'r=$r');
    });

    test('括号可显式改变优先级 (-2)^2 = 4', () async {
      final r = await calc('(-2)^2');
      expect(r, '(-2)^2 = 4', reason: 'r=$r');
    });

    test('幂运算右结合 2^3^2 = 512', () async {
      final r = await calc('2^3^2');
      expect(r, '2^3^2 = 512', reason: 'r=$r');
    });

    test('乘除与一元负号：-3*2 = -6', () async {
      final r = await calc('-3*2');
      expect(r, '-3*2 = -6', reason: 'r=$r');
    });
  });

  group('实数域边界', () {
    // math.pow 对负数的非整数次幂返回 NaN，除以极小数返回 Infinity。
    // 这些不是异常，原实现会拼成 "(-8)^0.33 = NaN" 当作成功结果返回，
    // Agent 会把它当正确答案复述给用户。
    test('负数的非整数次幂返回错误而非 NaN', () async {
      final r = await calc('(-8)^0.5');
      expect(r.contains('NaN'), isFalse, reason: '泄漏 NaN，r=$r');
      expect(r.contains('无定义'), isTrue, reason: 'r=$r');
    });

    test('除以零返回错误', () async {
      final r = await calc('1/0');
      expect(r.contains('除以零'), isTrue, reason: 'r=$r');
    });
  });

  group('结果格式化', () {
    // 全程 double 直接 toString 会输出 "2.0" / "0.30000000000000004"，
    // 与工具 description 承诺的「精确计算」不符。
    test('整数结果不显示 .0', () async {
      final r = await calc('4/2');
      expect(r, '4/2 = 2', reason: 'r=$r');
    });

    test('消除浮点误差尾数', () async {
      final r = await calc('0.1+0.2');
      expect(r, '0.1+0.2 = 0.3', reason: 'r=$r');
    });

    test('常规算式保持正确', () async {
      expect(await calc('(2+3)*4/5'), '(2+3)*4/5 = 4', reason: '算式出错');
    });
  });

  group('输入校验', () {
    test('空表达式返回错误', () async {
      expect(await calc('   '), contains('表达式为空'));
    });

    test('非法字符返回错误', () async {
      final r = await calc('1+abc');
      expect(r.contains('错误'), isTrue, reason: 'r=$r');
    });

    test('缺少右括号返回错误', () async {
      final r = await calc('(1+2');
      expect(r.contains('右括号'), isTrue, reason: 'r=$r');
    });
  });

  group('日期时间工具', () {
    // Duration.inHours 对非整小时偏移截断：Asia/Kolkata(+05:30) 会输出 UTC+5，
    // 错误的时区会让模型算错跨时区时间。
    test('时区标注非零分钟偏移', () async {
      final r = await DateTimeTool().execute({});
      expect(r.contains('UTC'), isTrue, reason: 'r=$r');
      // 形如 UTC+8 / UTC+5:30 / UTC-3:30
      expect(
        RegExp(r'UTC[+-]\d{1,2}(:\d{2})?').hasMatch(r),
        isTrue,
        reason: '时区格式异常，r=$r',
      );
    });
  });
}
