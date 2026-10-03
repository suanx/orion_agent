import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/theme.dart';

void main() {
  test('主题定义：id 唯一且至少 4 套', () {
    expect(appThemes.length, greaterThanOrEqualTo(4));
    expect(appThemes.map((t) => t.id).toSet().length, appThemes.length);
  });

  test('未知 id 回退到默认主题', () {
    expect(themeById('not_exist').id, appThemes.first.id);
  });

  test('buildAppTheme 应用所选主色', () {
    expect(buildAppTheme(themeById('blue')).colorScheme.primary,
        const Color(0xFF2563EB));
    expect(buildAppTheme(themeById('classic')).colorScheme.primary,
        Colors.black);
  });
}
