import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/cloud_sync_service.dart';
import '../theme.dart';
import 'glass.dart';

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

  // ---- 云端备份 / 多端同步 ----
  bool _cloudBusy = false;
  ({int bytes, int limit})? _cloudUsage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCloudUsage());
  }

  Future<void> _loadCloudUsage() async {
    final cloud = ref.read(cloudServiceProvider);
    if (!cloud.isLoggedIn) return;
    try {
      final u = await ref.read(cloudSyncServiceProvider).cloudUsage();
      if (mounted) setState(() => _cloudUsage = u);
    } catch (_) {
      // 未登录/网络问题：保持为空即可，不打扰用户
    }
  }

  Future<void> _runCloud(Future<void> Function() action, String okMsg) async {
    setState(() => _cloudBusy = true);
    try {
      await action();
      // okMsg 为空表示调用方自己弹提示(如同步结果)
      if (mounted && okMsg.isNotEmpty) _toast(okMsg);
    } on CloudSyncPasswordWrong catch (e) {
      if (mounted) _toast(e.message);
    } on CloudSyncException catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('云端操作失败：$e');
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
      await _loadCloudUsage();
    }
  }

  /// 解锁：输入账号密码派生密钥（换设备时需做一次）。
  Future<bool> _ensureUnlocked() async {
    final sync = ref.read(cloudSyncServiceProvider);
    if (sync.isUnlocked) return true;
    final pwd = await showGlassTextDialog(
      context: context,
      title: '解锁云同步',
      labelText: '账号密码',
      hint: '用于派生加密密钥（不会保存密码本身）',
      confirmLabel: '解锁',
    );
    if (pwd == null || pwd.isEmpty) return false;
    await sync.unlock(pwd);
    return true;
  }

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
        // Android/iOS 的 SAF 必须拿到内容本身，只给路径会报
        // "Bytes are required on Android & iOS when saving a file"
        bytes: Uint8List.fromList(utf8.encode(jsonText)),
      );
      if (!mounted) return;
      if (result == null) return; // 用户取消
      if (selected['configs'] == true) {
        _toast('已导出备份\n⚠️ 含 API Key，请妥善保管');
      } else {
        _toast('已导出备份');
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
      builder: (ctx) => glassAlertDialog(
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
      builder: (ctx) => glassAlertDialog(
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
          const SizedBox(height: 24),
          _cloudSection(context),
        ],
      ),
    );
  }

  /// 云端区块：端上加密（AES-GCM，密钥由账号密码派生），服务端零知识。
  Widget _cloudSection(BuildContext context) {
    final cloud = ref.read(cloudServiceProvider);
    final sync = ref.read(cloudSyncServiceProvider);
    final usage = _cloudUsage;
    final usageText = usage == null
        ? '登录后可查看云端占用'
        : '已用 ${(usage.bytes / 1024).toStringAsFixed(1)} KB'
            ' / 上限 ${(usage.limit / 1024 / 1024).toStringAsFixed(0)} MB'
            '（${sync.isEnabled ? "pro/lifetime 更大" : "free 5MB"}）';
    final last = sync.lastSyncAt;

    if (!cloud.isLoggedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('云端备份与多端同步'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '登录云端账号后可用：数据在端上加密后上传，多台设备自动保持一致。',
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.55)),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel('云端备份与多端同步'),
        Container(
          decoration: BoxDecoration(
            color: surface(context),
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.sync_alt_outlined, size: 20),
                title: const Text('多端同步',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text(
                  sync.isEnabled
                      ? (last == null ? '已开启，尚未同步' : '上次同步：${_fmtTime(last)}')
                      : '开启后聊天记录/配置/设置在多台设备间自动同步',
                  style:
                      TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
                ),
                value: sync.isEnabled,
                onChanged: _cloudBusy
                    ? null
                    : (v) async {
                        if (v) {
                          if (!await _ensureUnlocked()) return;
                          await _runCloud(() async {
                            await ref
                                .read(cloudSyncServiceProvider)
                                .setEnabled(true);
                            await ref.read(cloudSyncServiceProvider).syncNow();
                          }, '多端同步已开启并完成首次同步');
                        } else {
                          await ref
                              .read(cloudSyncServiceProvider)
                              .setEnabled(false);
                          setState(() {});
                        }
                      },
              ),
              Divider(height: 1, color: onSurface(context, 0.06)),
              ListTile(
                enabled: !_cloudBusy,
                leading: _cloudBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_upload_outlined, size: 20),
                title: const Text('上传云端备份',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text(usageText,
                    style:
                        TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                onTap: _cloudBusy
                    ? null
                    : () async {
                        if (!await _ensureUnlocked()) return;
                        await _runCloud(
                          () => ref.read(cloudSyncServiceProvider).uploadAll(),
                          '已加密上传到云端（换设备可恢复）',
                        );
                      },
              ),
              Divider(height: 1, color: onSurface(context, 0.06)),
              ListTile(
                enabled: !_cloudBusy,
                leading: const Icon(Icons.cloud_download_outlined, size: 20),
                title: const Text('从云端恢复',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text('拉取云端快照并合并到本机（重启后完全生效）',
                    style:
                        TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                onTap: _cloudBusy
                    ? null
                    : () async {
                        if (!await _ensureUnlocked()) return;
                        await _runCloud(() async {
                          final syncSvc = ref.read(cloudSyncServiceProvider);
                          final parts = <String>[];
                          for (final t in CloudSyncService.syncTables) {
                            parts.addAll(await syncSvc.restoreTable(t));
                          }
                          if (parts.isEmpty) {
                            throw const CloudSyncException('云端还没有备份数据');
                          }
                          if (mounted) _toast(parts.join('；'));
                        }, '');
                      },
              ),
              Divider(height: 1, color: onSurface(context, 0.06)),
              ListTile(
                enabled: !_cloudBusy,
                leading: const Icon(Icons.sync_outlined, size: 20),
                title: const Text('立即同步',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text(last == null ? '尚未同步' : '上次：${_fmtTime(last)}',
                    style:
                        TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                onTap: _cloudBusy
                    ? null
                    : () async {
                        if (!await _ensureUnlocked()) return;
                        await _runCloud(() async {
                          final r =
                              await ref.read(cloudSyncServiceProvider).syncNow();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('同步完成：${r.describe()}')));
                          }
                        }, '');
                      },
              ),
              Divider(height: 1, color: onSurface(context, 0.06)),
              ListTile(
                enabled: !_cloudBusy,
                leading: const Icon(Icons.cloud_off_outlined, size: 20),
                title: const Text('删除云端备份',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text('清空云端全部快照与同步数据（本机数据不受影响）',
                    style:
                        TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
                onTap: _cloudBusy
                    ? null
                    : () async {
                        final ok = await showGlassTextDialog(
                          context: context,
                          title: '删除云端备份',
                          labelText: '输入 DELETE 确认',
                          hint: 'DELETE',
                          confirmLabel: '删除',
                        );
                        if (ok != 'DELETE') return;
                        final syncSvc = ref.read(cloudSyncServiceProvider);
                        await _runCloud(() async {
                          await syncSvc.deleteCloudBackups();
                          await syncSvc.deleteAllCloudSyncData();
                        }, '云端备份与同步数据已清空');
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '端上加密：密钥由账号密码派生（PBKDF2 → AES-256-GCM），服务端只保存密文，'
            '无法读取内容。换设备时用同一账号密码解锁一次即可。修改账号密码后旧数据将无法解密。',
            style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
          ),
        ),
      ],
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
