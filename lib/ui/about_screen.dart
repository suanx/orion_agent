import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../theme.dart';

/// 当前版本号。发版时与 pubspec.yaml 的 `version` 同步更新。
const String kAppVersion = '0.1.1';

/// GitHub Releases 最新版 API 与页面。
const _latestApi =
    'https://api.github.com/repos/suanx/orion_agent/releases/latest';
const _releasesPage = 'https://github.com/suanx/orion_agent/releases';

/// 关于页：软件介绍 + 在线更新。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  // 检查更新状态机：idle → checking → upToDate / available / downloading / error
  String _state = 'idle';
  String? _message;
  String? _remoteVersion;
  String? _changelog;
  String? _apkUrl;
  int _downloadPct = 0;

  Future<void> _checkUpdate() async {
    if (_state == 'checking' || _state == 'downloading') return;
    setState(() {
      _state = 'checking';
      _message = null;
    });
    try {
      final resp = await Dio()
          .get<Map<String, dynamic>>(
        _latestApi,
        options: Options(responseType: ResponseType.json),
      )
          .timeout(const Duration(seconds: 15));
      final data = resp.data;
      if (data == null) throw Exception('无响应数据');
      final tag = (data['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (tag.isEmpty) throw Exception('release 缺少 tag_name');
      final changelog = (data['body'] as String? ?? '').trim();
      String? apkUrl;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map) continue;
          final m = a.cast<String, dynamic>();
          final name = m['name'] as String? ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = m['browser_download_url'] as String?;
            break;
          }
        }
      }
      if (!mounted) return;
      if (_isNewer(tag, kAppVersion)) {
        setState(() {
          _state = 'available';
          _remoteVersion = tag;
          _changelog = changelog.isEmpty ? null : changelog;
          _apkUrl = apkUrl;
        });
      } else {
        setState(() {
          _state = 'upToDate';
          _message = '当前已是最新版本（$kAppVersion）';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'error';
        _message = '检查更新失败：$e';
      });
    }
  }

  Future<void> _downloadUpdate() async {
    final url = _apkUrl;
    if (url == null || _state == 'downloading') return;
    setState(() => _state = 'downloading');
    try {
      final tmp = await getTemporaryDirectory();
      final savePath = '${tmp.path}/orion_agent_update.apk';
      await Dio().download(url, savePath,
          onReceiveProgress: (received, total) {
        if (total > 0 && mounted) {
          setState(() => _downloadPct = (received / total * 100).round());
        }
      });
      // 安装 APK 需要用户在系统设置里允许「安装未知应用」，
      // 首次触发时系统会弹授权页，这里只负责把安装器拉起来。
      final r = await OpenFilex.open(savePath);
      if (!mounted) return;
      if (r.type != ResultType.done) {
        throw Exception(r.message);
      }
      setState(() {
        _state = 'available';
        _message = '已启动安装器，如未弹出请允许「安装未知应用」权限。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'available';
        _message = '下载失败：$e';
      });
    }
  }

  /// 版本比较：逐段数字比较，段数不足补 0。'v' 前缀已在调用前剥掉。
  static bool _isNewer(String remote, String local) {
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final a = parse(remote);
    final b = parse(local);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ------- 应用卡片 -------
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                MascotAvatar(size: 72, image: mascotAsset(context)),
                const SizedBox(height: 12),
                const Text('Orion Agent',
                    style: TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('V$kAppVersion',
                    style: TextStyle(
                        fontSize: 13, color: onSurface(context, 0.45))),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ------- 软件介绍 -------
          _label('软件介绍'),
          _card(
            context,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Orion Agent 是一款运行在手机上的本地 AI 智能体。',
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.6,
                        color: onSurface(context, 0.8)),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '它接入了你配置的大模型服务，能理解意图、拆解任务、'
                    '调用工具并交付结果，全程数据只保存在本机。',
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: onSurface(context, 0.55)),
                  ),
                  const SizedBox(height: 14),
                  _feature(context, Icons.forum_outlined, '智能对话',
                      '多会话管理，支持图片输入、深度思考与思考强度调节'),
                  _feature(context, Icons.construction_outlined, '工具调用',
                      '内置网页搜索、文件读写、代码执行等工具，自动编排多步任务'),
                  _feature(context, Icons.terminal_rounded, '终端环境',
                      '内置 Alpine / Debian 虚拟系统，可安装 Node.js、Python 等完整开发环境'),
                  _feature(context, Icons.record_voice_over_outlined, '语音能力',
                      '语音输入 + 语音播报，支持微软 Edge 在线音色与系统语音'),
                  _feature(context, Icons.auto_stories_outlined, '知识与记忆',
                      '本地知识库检索（RAG）与长期记忆，越用越懂你'),
                  _feature(context, Icons.hub_outlined, '开放扩展',
                      'MCP 协议接入外部工具，自定义 Agent 角色与提示词技能'),
                  _feature(context, Icons.shield_outlined, '隐私优先',
                      '会话、记忆、密钥全部本地存储，模型直连你配置的服务商'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ------- 在线更新 -------
          _label('在线更新'),
          _card(context, Column(children: _updateTiles(context))),
          const SizedBox(height: 20),

          // ------- 项目信息 -------
          _label('项目'),
          _card(
            context,
            ListTile(
              leading:
                  const Icon(Icons.code_rounded, size: 20),
              title: const Text('GitHub 仓库',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('github.com/suanx/orion_agent',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              trailing: Icon(Icons.open_in_new_rounded,
                  size: 18, color: onSurface(context, 0.3)),
              onTap: () async {
                try {
                  await OpenFilex.open(_releasesPage);
                } catch (_) {}
              },
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '基于 Flutter 构建 · 数据存储于本机',
              style: TextStyle(
                  fontSize: 12, color: onSurface(context, 0.35)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _updateTiles(BuildContext context) {
    final tiles = <Widget>[
      ListTile(
        leading: const Icon(Icons.system_update_outlined, size: 20),
        title: const Text('检查更新',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        // _updateSubtitle 返回 String?，ListTile.subtitle 要 Widget?，
        // 必须包一层 Text（CI run#18 的 error 之一）
        subtitle: _subtitleText(context),
        trailing: _updateTrailing(context),
        onTap:
            (_state == 'checking' || _state == 'downloading')
                ? null
                : (_state == 'available' && _apkUrl != null
                    ? _downloadUpdate
                    : _checkUpdate),
      ),
    ];
    // 发现新版时展示更新日志
    if (_state == 'available' && _changelog != null) {
      tiles.add(Divider(height: 1, color: onSurface(context, 0.06)));
      tiles.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('更新日志',
                style: TextStyle(
                    fontSize: 12, color: onSurface(context, 0.45))),
            const SizedBox(height: 6),
            SelectableText(
              _changelog!,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: onSurface(context, 0.6)),
            ),
          ],
        ),
      ));
    }
    return tiles;
  }

  /// 取检查更新状态对应的副标题文本，包成 Text（null 则不显示）。
  Widget? _subtitleText(BuildContext context) {
    final s = _updateSubtitle(context);
    if (s == null) return null;
    return Text(s,
        style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)));
  }

  String? _updateSubtitle(BuildContext context) {
    switch (_state) {
      case 'checking':
        return '正在检查…';
      case 'available':
        return '发现新版本 V$_remoteVersion'
            '${_apkUrl == null ? '（release 未附带 APK，请前往 GitHub 下载）' : ''}';
      case 'downloading':
        return '下载中 $_downloadPct%';
      case 'upToDate':
      case 'error':
        return _message;
      default:
        return '当前 V$kAppVersion，检查是否有新版本';
    }
  }

  Widget? _updateTrailing(BuildContext context) {
    switch (_state) {
      case 'checking':
        return const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2));
      case 'downloading':
        return SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, value: _downloadPct / 100));
      case 'available':
        return Icon(Icons.download_rounded,
            size: 20, color: Theme.of(context).colorScheme.primary);
      default:
        return Icon(Icons.chevron_right_rounded,
            size: 20, color: onSurface(context, 0.26));
    }
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
        child: Text(t,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: onSurface(context, 0.45))),
      );

  Widget _card(BuildContext context, Widget child) => Container(
        decoration: BoxDecoration(
          color: surface(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      );

  Widget _feature(BuildContext context, IconData icon, String title,
      String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(desc,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: onSurface(context, 0.5))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
