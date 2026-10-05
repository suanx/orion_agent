import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../theme.dart';

/// 备份与恢复页（我的 → 备份与恢复）。
///
/// 四类数据域以开关选择是否纳入备份：AI 供应商（含 API Key）、聊天历史、
/// MCP 服务器、应用设置。导出为 JSON 文件（系统保存对话框）；导入为
/// 全量替换语义，完成后需重启应用让内存中的 provider 重新加载。
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  // 开关持久化到 prefs（backup_inc_*），默认全部开启
  static const _domains = <(String, String, String)>[
    ('configs', 'backup_inc_configs', 'AI 供应商'),
    ('history', 'backup_inc_history', '聊天历史'),
    ('mcp', 'backup_inc_mcp', 'MCP 服务器'),
    ('settings', 'backup_inc_settings', '应用设置'),
  ];

  bool _switch(String prefKey) =>
      ref.watch(sharedPreferencesProvider).getBool(prefKey) ?? true;

  void _setSwitch(String prefKey, bool v) {
    ref.read(sharedPreferencesProvider).setBool(prefKey, v);
    setState(() {});
  }

  bool _busy = false;

  Future<void> _export() async {
    final selected = {
      for (final (id, key, _) in _domains) id: _switch(key),
    };
    if (!selected.values.any((v) => v)) {
      _toast('请至少选择一类要备份的数据');
      return;
    }
    setState(() => _busy = true);
    try {
      final svc = ref.read(backupServiceProvider);
      final jsonText = await svc.export(
        includeConfigs: selected['configs']!,
        includeHistory: selected['history']!,
        includeMcp: selected['mcp']!,
        includeSettings: selected['settings']!,
      );
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .substring(0, 15);
      final result = await FilePicker.platform.saveFile(
        fileName: 'orion_backup_$ts.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (!mounted) return;
      if (result == null) return; // 用户取消
      await svc.writeToFile(result, jsonText);
      if (selected['configs'] == true) {
        _toast('已导出：$result\n⚠️ 备份含 API Key，请妥善保管');
      } else {
        _toast('已导出：$result');
      }
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final ok = await showConfirm(
      '导入备份将覆盖当前对应数据域的全部内容（不可撤销），确定继续吗？',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (!mounted) return;
      final file = result?.files.singleOrNull;
      if (file == null) return;
      String text;
      if (file.bytes != null) {
        text = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        text = await ref.read(backupServiceProvider).readFromFile(file.path!);
      } else {
        _toast('读取备份文件失败');
        return;
      }
      final summary = await ref.read(backupServiceProvider).restore(text);
      if (!mounted) return;
      await showInfo(summary.join('\n'));
      _toast('导入完成，重启应用后全部生效');
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> showConfirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续')),
        ],
      ),
    );
    return r == true;
  }

  Future<void> showInfo(String msg) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入结果'),
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('好的')),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 4)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _SectionLabel('备份内容'),
          Container(
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < _domains.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: onSurface(context, 0.06)),
                  SwitchListTile(
                    secondary: Icon(_domainIcon(_domains[i].$1), size: 20),
                    title: Text(_domains[i].$3,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    subtitle: _domains[i].$1 == 'configs'
                        ? Text('包含 API Key，请妥善保管备份文件',
                            style: TextStyle(
                                fontSize: 12,
                                color: onSurface(context, 0.4)))
                        : null,
                    value: _switch(_domains[i].$2),
                    onChanged: (v) => _setSwitch(_domains[i].$2, v),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          _SectionLabel('操作'),
          Container(
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  enabled: !_busy,
                  leading: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.file_upload_outlined, size: 20),
                  title: const Text('导出备份',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  subtitle: Text('按上方开关选择的范围导出 JSON 文件',
                      style:
                          TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                  onTap: _export,
                ),
                Divider(height: 1, color: onSurface(context, 0.06)),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.file_download_outlined, size: 20),
                  title: const Text('导入备份',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500)),
                  subtitle: Text('从 JSON 备份恢复，覆盖当前对应数据（重启后生效）',
                      style:
                          TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                  onTap: _import,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '备份文件为明文 JSON，仅保存在你选择的位置，应用不会自动上传。'
              '导入为全量替换：目标数据域的现有内容会被备份内容覆盖。',
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
            ),
          ),
        ],
      ),
    );
  }

  IconData _domainIcon(String id) => switch (id) {
        'configs' => Icons.cloud_outlined,
        'history' => Icons.forum_outlined,
        'mcp' => Icons.hub_outlined,
        _ => Icons.settings_outlined,
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
      child: Text(text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: onSurface(context, 0.45),
          )),
    );
  }
}
