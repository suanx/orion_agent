import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import '../providers/providers.dart';
import 'log_screen.dart';

/// 当前版本号。发版时与 pubspec.yaml 的 `version` 同步更新
/// （只升 pubspec 不升这里 → 应用自报版本落后，更新检查会一直
/// 提示安装「新版本」，即使用户已经装上了最新包）。
const String kAppVersion = '0.2.25-beta';

/// 关于页：软件介绍 + 在线更新。
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen>
    with WidgetsBindingObserver {
  // 检查更新状态机：idle → checking → upToDate / available → downloading
  //   → downloaded（等待安装授权或用户点安装）→ available
  String _state = 'idle';
  String? _message;
  String? _remoteVersion;
  String? _changelog;
  String? _apkUrl;
  int _downloadPct = 0;

  /// 已下载的 APK 路径（downloaded 状态下点「安装」直接拉安装器）。
  String? _downloadPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从「安装未知应用」授权页返回后自动继续安装。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _state == 'downloaded' &&
        _downloadPath != null) {
      _installApk();
    }
  }

  Future<void> _checkUpdate() async {
    if (_state == 'checking' || _state == 'downloading') return;
    setState(() {
      _state = 'checking';
      _message = null;
    });
    try {
      final info = await ref
          .read(updateServiceProvider)
          .checkForUpdate(kAppVersion,
              timeout: const Duration(seconds: 15),
              // Beta 开启时走含预发布的 GitHub releases 列表
              includePrereleases: ref.read(betaOptInProvider));
      if (!mounted) return;
      if (info == null) {
        setState(() {
          _state = 'upToDate';
          _message = '当前已是最新版本（$kAppVersion）';
        });
      } else {
        setState(() {
          _state = 'available';
          _remoteVersion = info.version;
          _changelog = info.changelog;
          _apkUrl = info.apkUrl;
          _message = null;
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
      if (!mounted) return;
      _downloadPath = savePath;
      setState(() {
        _state = 'downloaded';
        _message = '下载完成，正在准备安装…';
      });
      // 下载完自动进入安装流程：没授权会先跳授权页，
      // 授权返回后 didChangeAppLifecycleState 会自动继续。
      await _installApk();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'available';
        _message = '下载失败：$e';
      });
    }
  }

  /// 拉起 APK 安装器。未授权「安装未知应用」时先跳授权页。
  Future<void> _installApk() async {
    final path = _downloadPath;
    if (path == null) return;
    final perms = ref.read(permissionServiceProvider);
    final canInstall = await perms.canInstallPackages();
    if (!canInstall) {
      if (!mounted) return;
      setState(() {
        _state = 'downloaded';
        _message = '需要允许「安装未知应用」：即将打开授权页，'
            '开启后返回会自动继续安装。';
      });
      await perms.open('install');
      return;
    }
    try {
      final r = await OpenFilex.open(path);
      if (!mounted) return;
      if (r.type != ResultType.done) {
        throw Exception(r.message);
      }
      setState(() {
        _state = 'available';
        _message = '已启动安装器，按系统提示完成升级。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = 'downloaded';
        _message = '安装器启动失败（$e），点「安装」重试。';
      });
    }
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

          // ------- 诊断 -------
          _label('诊断'),
          _card(
            context,
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined, size: 20),
              title: const Text('日志',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500)),
              subtitle: Text('运行事件与错误记录，可复制或导出排查问题',
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.4))),
              trailing: Icon(Icons.chevron_right_rounded,
                  size: 18, color: onSurface(context, 0.3)),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LogScreen())),
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
    final busy = _state == 'checking' || _state == 'downloading';
    final tiles = <Widget>[
      ListTile(
        leading: const Icon(Icons.system_update_outlined, size: 20),
        title: const Text('检查更新',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        // _updateSubtitle 返回 String?，ListTile.subtitle 要 Widget?，
        // 必须包一层 Text（CI run#18 的 error 之一）
        subtitle: _subtitleText(context),
        trailing: _updateTrailing(context),
        onTap: busy
            ? null
            : switch (_state) {
                // available 且下载过：点「安装」直接重试安装器
                'downloaded' => _installApk,
                'available' when _apkUrl != null => _downloadUpdate,
                _ => _checkUpdate,
              },
      ),
    ];
    // Beta 测试开关：开启后更新检查含 GitHub 预发布（pre-release）版本。
    // watch 放本方法内（build 调用链上），切换立即刷新本页开关状态。
    final beta = ref.watch(betaOptInProvider);
    tiles.add(Divider(height: 1, color: onSurface(context, 0.06)));
    tiles.add(SwitchListTile(
      secondary: const Icon(Icons.science_outlined, size: 20),
      title: const Text('加入 Beta 测试',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text('提前体验预发布测试版，可能不稳定',
          style: TextStyle(fontSize: 12, color: onSurface(context, 0.4))),
      value: beta,
      onChanged: (v) {
        ref.read(sharedPreferencesProvider).setBool('beta_opt_in', v);
        ref.read(betaOptInProvider.notifier).state = v;
        // 关闭 Beta 后若之前停在「发现新版（预发布）」状态，重置提示，
        // 避免继续展示用户已选择不再接收的预发布更新。
        if (!v && (_state == 'available' || _state == 'downloaded')) {
          setState(() {
            _state = 'idle';
            _message = null;
          });
        }
      },
    ));
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
      case 'downloaded':
        return _message ?? '已下载，点击安装';
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
      case 'downloaded':
        return Icon(Icons.install_mobile_rounded,
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
