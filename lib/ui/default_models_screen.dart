import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/llm_config.dart';
import 'glass.dart';
import '../providers/providers.dart';

/// 「我的 → 默认模型」页：专项模型设置。
///
/// 三个专项各自独立选择模型；值为空表示「跟随当前聊天模型」。
/// 点击条目弹出底部选择器（搜索 + 当前提供商的模型列表 + 重置）。
class DefaultModelsScreen extends ConsumerWidget {
  const DefaultModelsScreen({super.key});

  static const _items = <_SpecialtyItem>[
    _SpecialtyItem(
      keyName: 'vision_model',
      label: '识图模型',
      desc: '带图消息由它处理，适合当前聊天模型不支持视觉时',
      icon: Icons.image_outlined,
    ),
    _SpecialtyItem(
      keyName: 'compress_model',
      label: '压缩模型',
      desc: '长会话上下文压缩时用（暂未接入请求流程，仅保存设置）',
      icon: Icons.compress_rounded,
    ),
    _SpecialtyItem(
      keyName: 'summary_model',
      label: '标题总结模型',
      desc: '首轮回答完成后用它生成简短会话标题',
      icon: Icons.title_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vision = ref.watch(visionModelProvider);
    final compress = ref.watch(compressModelProvider);
    final summary = ref.watch(summaryModelProvider);
    final values = <String, String>{
      'vision_model': vision,
      'compress_model': compress,
      'summary_model': summary,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('默认模型')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Container(
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < _items.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 52),
                      child: Divider(
                          height: 1, color: onSurface(context, 0.06)),
                    ),
                  _row(context, ref, _items[i], values[_items[i].keyName]!),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '专项模型来自当前 AI 提供商的模型列表；'
              '选择「跟随当前聊天模型」时随默认模型自动切换。',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: onSurface(context, 0.4)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
      BuildContext context, WidgetRef ref, _SpecialtyItem item, String value) {
    return InkWell(
      onTap: () => _pick(context, ref, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(item.icon, size: 20, color: onSurface(context, 0.7)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.label,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(item.desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: onSurface(context, 0.38))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value.isEmpty ? '跟随当前聊天模型' : value,
              style: TextStyle(
                  fontSize: 13,
                  color: value.isEmpty
                      ? onSurface(context, 0.4)
                      : Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: onSurface(context, 0.26)),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(
      BuildContext context, WidgetRef ref, _SpecialtyItem item) async {
    final config = ref.read(configProvider).activeConfig;
    final models = config?.chatModels ?? const <ProviderModel>[];
    if (models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先在「AI 提供商」里添加模型，再选择专项模型')));
      return;
    }

    await showGlassDialog<void>(
      context: context,
      builder: (ctx) => _ModelPickerSheet(
        title: item.label,
        prefsKey: item.keyName,
        models: models,
        providerName: config?.displayName ?? '',
      ),
    );
  }
}

class _SpecialtyItem {
  const _SpecialtyItem({
    required this.keyName,
    required this.label,
    required this.desc,
    required this.icon,
  });

  final String keyName;
  final String label;
  final String desc;
  final IconData icon;
}

/// 底部模型选择器：重置 + 搜索框 + 模型列表。
class _ModelPickerSheet extends ConsumerStatefulWidget {
  const _ModelPickerSheet({
    required this.title,
    required this.prefsKey,
    required this.models,
    required this.providerName,
  });

  final String title;
  final String prefsKey;
  final List<ProviderModel> models;
  final String providerName;

  @override
  ConsumerState<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<_ModelPickerSheet> {
  String _filter = '';

  Future<void> _apply(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (value.isEmpty) {
      await prefs.remove(widget.prefsKey);
    } else {
      await prefs.setString(widget.prefsKey, value);
    }
    // 三个专项各自的 provider，键名即 provider 名的约定映射
    final map = {
      'vision_model': visionModelProvider,
      'compress_model': compressModelProvider,
      'summary_model': summaryModelProvider,
    };
    final p = map[widget.prefsKey];
    if (p != null) ref.read(p.notifier).state = value;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final current = switch (widget.prefsKey) {
      'vision_model' => ref.watch(visionModelProvider),
      'compress_model' => ref.watch(compressModelProvider),
      _ => ref.watch(summaryModelProvider),
    };
    final keyword = _filter.trim().toLowerCase();
    final filtered = keyword.isEmpty
        ? widget.models
        : widget.models
            .where((m) => m.name.toLowerCase().contains(keyword))
            .toList();

    // 居中玻璃弹窗形态：无底部拖柄，整体限高防止列表过长顶出屏幕
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460, maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题 + 重置
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                  GestureDetector(
                    onTap: () => _apply(''),
                    child: Text('重置',
                        style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.primary)),
                  ),
                ],
              ),
            ),
            // 搜索框
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                decoration: InputDecoration(
                  hintText: '输入模型名称筛选',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  isDense: true,
                  filled: true,
                  fillColor: onSurface(context, 0.04),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            // 分组标题
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${widget.providerName} (${filtered.length})',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.45)),
                ),
              ),
            ),
            // 列表
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('没有匹配的模型',
                          style: TextStyle(
                              fontSize: 13,
                              color: onSurface(context, 0.4))),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final m = filtered[i];
                        final selected = m.name == current;
                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 20),
                          leading: Icon(
                            Icons.memory_rounded,
                            size: 20,
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : onSurface(context, 0.35),
                          ),
                          title: Text(m.name,
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : onSurface(context, 0.85))),
                          subtitle: m.contextWindow > 0
                              ? Text(
                                  '上下文 ${_compact(m.contextWindow)}',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: onSurface(context, 0.4)),
                                )
                              : null,
                          trailing: selected
                              ? Icon(Icons.check_rounded,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary)
                              : null,
                          onTap: () => _apply(m.name),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)}M';
    }
    if (n >= 1000) return '${(n / 1000).round()}K';
    return '$n';
  }
}
