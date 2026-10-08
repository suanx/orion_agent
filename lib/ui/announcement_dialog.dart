import 'package:flutter/material.dart';

import '../services/announcement_service.dart';
import '../theme.dart';
import 'glass.dart';

/// 云端公告弹窗。
///
/// 全项目统一的弹窗口径：[showGlassDialog] + [glassAlertDialog]
/// （紧凑居中玻璃卡片，不铺满屏）。长公告内容在内部滚动，
/// 玻璃面板的 maxHeight 兜底不会被裁掉。
///
/// 返回 true = 用户点「我知道了」（标记已读）；
/// 返回 false/null = 点「稍后看」或遮罩（静默 6 小时后再提醒）。
Future<bool?> showAnnouncementDialog(
  BuildContext context,
  CloudAnnouncement ann,
) {
  return showGlassDialog<bool>(
    context: context,
    builder: (ctx) => glassAlertDialog(
      title: Row(
        children: [
          Icon(Icons.campaign_outlined,
              size: 20, color: Theme.of(ctx).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ann.title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      content: Text(
        ann.content,
        style: TextStyle(fontSize: 14.5, height: 1.55, color: onSurface(ctx, 0.82)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('稍后看',
              style: TextStyle(color: onSurface(ctx, 0.6), fontSize: 14)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          ),
          child: const Text('我知道了', style: TextStyle(fontSize: 14)),
        ),
      ],
    ),
  );
}
