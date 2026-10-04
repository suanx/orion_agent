import 'package:flutter/material.dart';

/// 全项目共享的轻量格式化工具。
///
/// 抽取自 chat_screen / token_stats_screen / default_models_screen /
/// settings_screen 的重复实现（P2-22）：各处原来各自维护一份
/// token 紧凑格式化，口径不一致，现统一到 [compactTokens]。

/// 128000 → "128K"，1048576 → "1.1M"，避免长文本把状态条挤爆。
String compactTokens(int n) {
  if (n >= 1000000) {
    final v = n / 1000000;
    return '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)}M';
  }
  if (n >= 1000) return '${(n / 1000).round()}K';
  return '$n';
}

/// 解析用户输入的 token 数量："128k" → 128000、"1.5m" → 1500000、
/// 纯数字按原值。非法输入（负数、非数字、乱后缀、非整数结果）返回
/// null，由调用方给出提示；0 是合法值（部分场景 0 = 不限制/不压缩）。
int? parseTokenCount(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty || s.startsWith('-')) return null;

  var body = s;
  var scale = 1;
  if (body.endsWith('k')) {
    scale = 1000;
    body = body.substring(0, body.length - 1);
  } else if (body.endsWith('m')) {
    scale = 1000000;
    body = body.substring(0, body.length - 1);
  }
  if (body.isEmpty) return null;

  final v = double.tryParse(body);
  if (v == null) return null;
  final out = v * scale;
  if (out % 1 != 0) return null; // token 数必须是整数
  return out.round();
}

/// SnackBar 捷径（避免各屏重复写 hide/show 组合）。
void showHint(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(msg), duration: const Duration(seconds: 2)));
}
