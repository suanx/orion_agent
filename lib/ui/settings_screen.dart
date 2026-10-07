import 'dart:async';

import '../theme.dart';
import 'format_utils.dart';
import 'glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/llm_config.dart';
import '../services/app_log.dart';
import '../providers/providers.dart';
import '../services/llm_client.dart' show FetchedModel;

/// 「AI 提供商」列表页：一条卡片一个提供商，点进详情。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(configProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 提供商'),
        actions: [
          IconButton(
            tooltip: '添加提供商',
            icon: const Icon(Icons.add),
            onPressed: () => _addProvider(context, ref),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // 配置持久化失败（Keystore 损坏 / 加密存储初始化失败）时，
          // 不提示的话用户会以为保存成功，重启后才发现配置全丢了。
          if (state.error != null) _ErrorBanner(message: state.error!),
          if (state.configs.isEmpty)
            const _EmptyProviders()
          else ...[
            ...state.configs.map((c) => _ProviderCard(
                  config: c,
                  // 「使用中」= activeConfig 选中的那条：优先是用户在对话页
                  // 模型浮层里最近选中的提供商，否则退回第一个已启用且可用。
                  inUse: c.id == state.usingId,
                  onTap: () => _openProvider(context, c.id),
                  onDelete: () => _confirmDelete(context, ref, c),
                )),
            const SizedBox(height: 12),
            Text(
              '多个提供商可同时「已启用」；对话默认用列表中第一个已启用的，'
              '在对话页模型列表里选过其他提供商的模型后会记住选择。',
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.4)),
            ),
          ],
        ],
      ),
    );
  }

  /// 新建提供商：先落一条空记录再进详情页，让详情页可以「边改边存」。
  ///
  /// 用户直接返回、什么都没填时，详情页会把它删掉（见 ProviderScreen）。
  static Future<void> _addProvider(BuildContext context, WidgetRef ref) async {
    final c = LlmConfig(
      id: 'cfg_${DateTime.now().millisecondsSinceEpoch}',
      name: '',
      baseUrl: '',
      apiKey: '',
    );
    ref.read(configProvider.notifier).upsert(c);
    await _openProvider(context, c.id);
  }

  /// 删除确认（2026-10-06）：删除不可撤销，且会连带清掉该配置里的
  /// API Key 与模型清单，所以必须二次确认，并提示「使用中」的影响。
  static Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, LlmConfig c) async {
    final name = c.displayName;
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('删除提供商'),
        content: Text('确定删除「$name」？\n'
            '该配置里的 API Key 与模型清单会一并删除，且无法撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(configProvider.notifier).remove(c.id);
    // 删除动作落进「诊断日志」，便于用户反馈「我明明删了」时回溯
    AppLog.i('删除 AI 提供商：$name（${c.id}）');
  }

  static Future<void> _openProvider(BuildContext context, String id) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ProviderScreen(configId: id)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProviders extends StatelessWidget {
  const _EmptyProviders();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 120),
      child: Column(
        children: [
          Icon(Icons.dns_outlined, size: 56, color: onSurface(context, 0.2)),
          const SizedBox(height: 16),
          Text('暂无提供商',
              style: TextStyle(fontSize: 15, color: onSurface(context, 0.6))),
          const SizedBox(height: 8),
          Text('点击右上角「+」添加',
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.4))),
        ],
      ),
    );
  }
}

/// 提供商卡片：图标 + 名称 + 类型/模型数徽标 + 已启用徽标 + 箭头。
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.config,
    required this.inUse,
    required this.onTap,
    required this.onDelete,
  });

  final LlmConfig config;
  final bool inUse;
  final VoidCallback onTap;

  /// 删除该提供商（2026-10-06 补：原先只有添加/编辑，删不掉）。
  /// 独立按钮而不是长按菜单——用户明确反馈「添加后无法删除」，
  /// 入口必须一眼可见。
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            child: Row(
              children: [
                // 提供商图标
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.smart_toy_outlined,
                      size: 24, color: primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.displayName,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _Badge(text: config.type.label),
                          const SizedBox(width: 6),
                          if (config.models.isNotEmpty)
                            _Badge(text: config.modelCountLabel),
                          if (!config.ready) ...[
                            const SizedBox(width: 6),
                            _Badge(text: '未配置完整', warn: true),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除提供商',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 20, color: onSurface(context, 0.45)),
                  onPressed: onDelete,
                ),
                if (config.enabled) ...[
                  const _Badge(text: '已启用', ok: true),
                  const SizedBox(width: 4),
                ],
                Icon(Icons.chevron_right,
                    size: 20, color: onSurface(context, 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 小徽标（类型 / 模型数 / 已启用 / 未配置完整）。
class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.ok = false, this.warn = false});

  final String text;
  final bool ok;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (ok) {
      bg = const Color(0xFFE6F4EA);
      fg = const Color(0xFF137333);
    } else if (warn) {
      bg = const Color(0xFFFEF7E0);
      fg = const Color(0xFFB06000);
    } else {
      bg = onSurface(context, 0.06);
      fg = onSurface(context, 0.55);
    }
    // 深色模式下固定浅底会刺眼，整体压暗一档
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: dark && ok
            ? scheme.primary.withValues(alpha: 0.18)
            : (dark && warn
                ? scheme.tertiary.withValues(alpha: 0.18)
                : bg),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: dark && ok
                ? scheme.primary
                : (dark && warn ? scheme.tertiary : fg)),
      ),
    );
  }
}

// ============================================================ 提供商详情

/// 提供商详情页：底部「配置 / 模型」两个 tab。
class ProviderScreen extends ConsumerStatefulWidget {
  const ProviderScreen({super.key, required this.configId});

  final String configId;

  @override
  ConsumerState<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends ConsumerState<ProviderScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  /// 本页是否真的写入过内容。用于「新建后什么都没填就返回」时清理空记录，
  /// 否则列表里会慢慢堆积一堆点错产生的空提供商。
  bool _touched = false;

  @override
  void dispose() {
    _cleanupIfEmpty();
    _tabs.dispose();
    super.dispose();
  }

  void _cleanupIfEmpty() {
    final c = ref.read(configProvider.notifier).byId(widget.configId);
    if (c == null) return;
    if (!_touched &&
        c.name.trim().isEmpty &&
        c.baseUrl.trim().isEmpty &&
        c.apiKey.trim().isEmpty &&
        c.models.isEmpty) {
      ref.read(configProvider.notifier).remove(widget.configId);
    }
  }

  void _markTouched() => _touched = true;

  /// 从 state 里取当前配置；被删掉时返回一条占位，避免各处判空。
  LlmConfig _findConfig(ConfigState state) {
    for (final c in state.configs) {
      if (c.id == widget.configId) return c;
    }
    return LlmConfig(
        id: widget.configId, name: '', baseUrl: '', apiKey: '');
  }

  @override
  Widget build(BuildContext context) {
    // watch 的是 state 而不是 notifier —— notifier 实例不变，
    // 只 watch 它不会在配置变化时重建，表单会看起来「点了没反应」。
    final config = _findConfig(ref.watch(configProvider));

    final isNew = config.name.trim().isEmpty &&
        config.baseUrl.trim().isEmpty &&
        config.models.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '添加提供商' : config.displayName),
        actions: [
          // tab 0 的「+」＝再建一个提供商（与列表页一致）；
          // tab 1 的「+」＝给当前提供商添加模型（截图里那句
          // 「点击右上方按钮添加模型」指的就是它）。
          IconButton(
            tooltip: _tabs.index == 0 ? '添加提供商' : '添加模型',
            icon: const Icon(Icons.add),
            onPressed: _tabs.index == 0
                ? () {
                    _markTouched();
                    SettingsScreen._addProvider(context, ref);
                  }
                : () => _ModelsTabState._addModel(context, ref, config),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabs,
              // 禁止左右滑动切 tab：表单里有横向手势（文本框选词），
              // 会频繁误触切走。
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _ConfigTab(
                  configId: widget.configId,
                  onChanged: _markTouched,
                ),
                _ModelsTab(
                  configId: widget.configId,
                  onChanged: _markTouched,
                ),
              ],
            ),
          ),
          _BottomTabs(controller: _tabs),
        ],
      ),
    );
  }
}

/// 底部胶囊 tab（配置 / 模型）。
class _BottomTabs extends StatelessWidget {
  const _BottomTabs({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            color: onSurface(context, 0.05),
            borderRadius: BorderRadius.circular(29),
          ),
          child: TabBar(
            controller: controller,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(24),
            ),
            labelColor: scheme.primary,
            unselectedLabelColor: onSurface(context, 0.6),
            labelStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            tabs: const [
              Tab(icon: Icon(Icons.tune, size: 20), text: '配置'),
              Tab(icon: Icon(Icons.memory, size: 20), text: '模型'),
            ],
          ),
        ),
      ),
    );
  }
}

// ================================================================ 配置 tab

class _ConfigTab extends ConsumerStatefulWidget {
  const _ConfigTab({required this.configId, required this.onChanged});

  final String configId;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends ConsumerState<_ConfigTab> {
  /// 取当前配置；不存在时返回占位，避免各处判空。
  LlmConfig _find(ConfigState state) {
    for (final c in state.configs) {
      if (c.id == widget.configId) return c;
    }
    return LlmConfig(
        id: widget.configId, name: '', baseUrl: '', apiKey: '');
  }

  late final TextEditingController _name;
  late final TextEditingController _key;
  late final TextEditingController _url;
  late final TextEditingController _ua;
  bool _obscureKey = true;

  /// 文本输入的防抖：每敲一个字就写一次加密存储太浪费
  /// （Keystore 写入是平台通道调用），400ms 足够跟手。
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 不强解包：极端情况下（进页面前配置被删）这里会是 null，
    // 用空字符串兜底比直接崩掉好。
    final c = ref.read(configProvider.notifier).byId(widget.configId);
    _name = TextEditingController(text: c?.name ?? '')
      ..addListener(_scheduleCommit);
    _key = TextEditingController(text: c?.apiKey ?? '')
      ..addListener(_scheduleCommit);
    _url = TextEditingController(text: c?.baseUrl ?? '')
      ..addListener(_scheduleCommit);
    _ua = TextEditingController(text: c?.userAgent ?? '')
      ..addListener(_scheduleCommit);
  }

  @override
  void dispose() {
    // 防抖未触发就退出时，最后一次输入会丢，这里补一次
    _debounce?.cancel();
    _commit();
    _name.dispose();
    _key.dispose();
    _url.dispose();
    _ua.dispose();
    super.dispose();
  }

  void _scheduleCommit() {
    widget.onChanged();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _commit);
  }

  /// 把当前表单写回 store。
  ///
  /// 全部字段一次性提交：分字段提交要各自记住其它字段的当前值，
  /// 反而更容易漏。
  void _commit() {
    if (!mounted) return;
    final notifier = ref.read(configProvider.notifier);
    final c = notifier.byId(widget.configId);
    if (c == null) return;
    notifier.upsert(c.copyWith(
      name: _name.text.trim(),
      apiKey: _key.text.trim(),
      baseUrl: _url.text.trim(),
      userAgent: _ua.text.trim(),
    ));
  }

  void _patch(LlmConfig Function(LlmConfig) f) {
    widget.onChanged();
    final notifier = ref.read(configProvider.notifier);
    final c = notifier.byId(widget.configId);
    if (c == null) return;
    notifier.upsert(f(c));
  }

  @override
  Widget build(BuildContext context) {
    final config = _find(ref.watch(configProvider));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // ---------------- 基本信息 ----------------
        const _SectionTitle('基本信息'),
        _Card(
          children: [
            _Field(controller: _name, hint: '名称'),
            _Field(
              controller: _key,
              hint: 'API Key',
              obscure: _obscureKey,
              suffix: IconButton(
                icon: Icon(
                  _obscureKey
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
            _Field(controller: _url, hint: 'Base URL'),
            _Field(controller: _ua, hint: 'User-Agent'),
            _NavRow(
              label: '供应商类型',
              value: config.type.label,
              onTap: () => _pickType(context, config),
            ),
          ],
        ),

        // ---------------- 选项 ----------------
        const _SectionTitle('选项'),
        _Card(
          children: [
            _SwitchRow(
              label: '已启用',
              value: config.enabled,
              onChanged: (v) => _patch((c) => c.copyWith(enabled: v)),
            ),
            _SwitchRow(
              label: '完整 URL',
              subtitle: 'Base URL 即完整请求地址，不自动拼接默认路径',
              value: config.fullUrl,
              onChanged: (v) => _patch((c) => c.copyWith(fullUrl: v)),
            ),
            _SwitchRow(
              label: 'OpenAI 兼容缓存键',
              subtitle: '为请求携带 prompt_cache_key 缓存键',
              value: config.promptCacheKey,
              onChanged: (v) => _patch((c) => c.copyWith(promptCacheKey: v)),
            ),
            _SwitchRow(
              label: '多 Key 模式',
              subtitle: '同一提供商下配多个 Key，密钥不可用时自动切换并重发',
              value: config.multiKey,
              onChanged: (v) => _patch((c) => c.copyWith(multiKey: v)),
            ),
            if (config.multiKey) _KeyList(config: config, onPatch: _patch),
            _NavRow(
              label: '网络代理',
              value: config.proxy.trim().isEmpty ? '未启用' : config.proxy,
              onTap: () => _editProxy(context, config),
            ),
            _NavRow(
              label: '测试连接',
              subtitle: '请求 /models 接口，验证这套配置是否可用',
              icon: Icons.play_arrow_outlined,
              onTap: () => _testConnection(context, config),
            ),
          ],
        ),

        if (config.baseUrl.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '⚠️ Base URL 为空，无法发起请求。',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (config.chatModel == null && config.models.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '⚠️ 还没有聊天模型，去「模型」页添加后才能对话。',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Future<void> _pickType(BuildContext context, LlmConfig config) async {
    final picked = await showGlassDialog<ProviderType>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        backgroundColor: Colors.transparent,
        title: const Text('提供商类型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in ProviderType.values)
              ListTile(
                title: Text(t.label),
                subtitle: Text(t.hint),
                trailing: t == config.type
                    ? Icon(Icons.check,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(ctx).pop(t),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _patch((c) => c.copyWith(type: picked));
  }

  Future<void> _editProxy(BuildContext context, LlmConfig config) async {
    final ctrl = TextEditingController(text: config.proxy);
    // 值随 pop 一起带出（P2-6）：whenComplete 会先 dispose 控制器，
    // 之后再读 ctrl.text 会抛「used after dispose」。
    final result = await showGlassDialog<(bool, String)>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('网络代理'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '代理地址',
                hintText: 'http://127.0.0.1:7890',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '留空表示直连。仅对本提供商生效。',
              style: TextStyle(
                  fontSize: 12, color: onSurface(ctx, 0.45)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          if (config.proxy.trim().isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop((true, '')),
              child: const Text('清除'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop((true, ctrl.text.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
    if (result == null || !result.$1) return;
    // 「清除」与「保存」都返回 true；靠输入框内容是否为空区分意图
    _patch((c) => c.copyWith(proxy: result.$2));
  }

  Future<void> _testConnection(BuildContext context, LlmConfig config) async {
    final messenger = ScaffoldMessenger.of(context);
    showGlassDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    String result;
    try {
      // 先把表单里的最新值提交，否则用户刚改完 Base URL 就点测试会用到旧值
      _commit();
      final fresh =
          ref.read(configProvider.notifier).byId(widget.configId) ?? config;
      result = await ref.read(llmClientProvider).testConnection(config: fresh);
    } catch (e) {
      result = '连接失败：$e';
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关掉 loading
    await showGlassDialog<void>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('测试连接'),
        content: SingleChildScrollView(child: Text(result)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    messenger.hideCurrentSnackBar();
  }
}

/// 多 Key 列表：显示备用 Key，可增删。
class _KeyList extends StatelessWidget {
  const _KeyList({required this.config, required this.onPatch});

  final LlmConfig config;
  final void Function(LlmConfig Function(LlmConfig)) onPatch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (config.extraKeys.isEmpty)
            Text('还没有备用 Key。第一个 Key 用上面的「API Key」字段填。',
                style: TextStyle(fontSize: 12, color: onSurface(context, 0.45))),
          for (var i = 0; i < config.extraKeys.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      // 不完整展示密钥，只露头 6 位 + 尾 4 位
                      _mask(config.extraKeys[i]),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => onPatch((c) => c.copyWith(
                          extraKeys: [
                            for (var k = 0; k < c.extraKeys.length; k++)
                              if (k != i) c.extraKeys[k],
                          ],
                        )),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加备用 Key'),
              onPressed: () => _add(context),
            ),
          ),
        ],
      ),
    );
  }

  static String _mask(String key) {
    if (key.length <= 10) return key;
    return '${key.substring(0, 6)}****${key.substring(key.length - 4)}';
  }

  Future<void> _add(BuildContext context) async {
    // 单文本输入统一走 showGlassTextDialog（P2-6）：
    // 控制器由助手内部创建并在弹窗关闭时 dispose，调用方不再持有。
    final v = await showGlassTextDialog(
      context: context,
      title: '添加备用 Key',
      labelText: 'API Key',
      confirmLabel: '添加',
    );
    if (v == null || v.isEmpty) return;
    if (config.extraKeys.contains(v)) return;
    onPatch((c) => c.copyWith(extraKeys: [...c.extraKeys, v]));
  }
}

// ================================================================ 模型 tab

class _ModelsTab extends ConsumerStatefulWidget {
  const _ModelsTab({required this.configId, required this.onChanged});

  final String configId;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ModelsTab> createState() => _ModelsTabState();
}

class _ModelsTabState extends ConsumerState<_ModelsTab> {
  bool _fetching = false;

  LlmConfig _find(ConfigState state) {
    for (final c in state.configs) {
      if (c.id == widget.configId) return c;
    }
    return LlmConfig(
        id: widget.configId, name: '', baseUrl: '', apiKey: '');
  }

  LlmConfig _read() => _find(ref.read(configProvider));

  @override
  Widget build(BuildContext context) {
    final config = _find(ref.watch(configProvider));
    final models = config.models;

    return Column(
      children: [
        // 顶部一行：模型 (N) + 拉取模型
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(
            children: [
              Text('模型（${models.length}）',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: onSurface(context, 0.75))),
              const Spacer(),
              TextButton.icon(
                onPressed: _fetching ? null : _fetchModels,
                icon: _fetching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_download_outlined, size: 18),
                label: Text(_fetching ? '拉取中…' : '拉取模型'),
              ),
            ],
          ),
        ),
        Expanded(
          child: models.isEmpty
              ? _empty(context)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: models.length,
                  itemBuilder: (ctx, i) => _ModelCard(
                    model: models[i],
                    isDefaultChat: models[i].kind == ModelKind.chat &&
                        models[i].name == config.chatModel?.name,
                    isDefaultEmbed:
                        models[i].kind == ModelKind.embedding &&
                            models[i].name == config.embeddingModel?.name,
                    onSetDefault: () => _setDefault(models[i]),
                    onEdit: () => _addModel(context, ref, config,
                        existing: models[i]),
                    onDelete: () => _delete(models[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 60),
            Text('暂无模型',
                style: TextStyle(fontSize: 15, color: onSurface(context, 0.55))),
            const SizedBox(height: 8),
            Text('点击右上方按钮添加模型',
                style: TextStyle(fontSize: 13, color: onSurface(context, 0.4))),
          ],
        ),
      );

  void _setDefault(ProviderModel m) {
    widget.onChanged();
    final notifier = ref.read(configProvider.notifier);
    final c = notifier.byId(widget.configId);
    if (c == null) return;
    notifier.upsert(m.kind == ModelKind.chat
        ? c.copyWith(defaultChatModel: m.name)
        : c.copyWith(defaultEmbeddingModel: m.name));
  }

  Future<void> _delete(ProviderModel m) async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => glassAlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除「${m.name}」？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.onChanged();
    ref.read(configProvider.notifier).removeModel(widget.configId, m.name);
  }

  /// 拉取模型：请求 /models，让用户勾选要导入的模型。
  Future<void> _fetchModels() async {
    final config = _read();
    if (config.baseUrl.trim().isEmpty) {
      _toast('请先填写 Base URL');
      return;
    }
    if (config.effectiveKeys.isEmpty) {
      _toast('请先填写 API Key');
      return;
    }
    setState(() => _fetching = true);
    List<FetchedModel> fetched;
    try {
      fetched = await ref.read(llmClientProvider).listModels(config: config);
    } catch (e) {
      if (mounted) setState(() => _fetching = false);
      _toast('拉取失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _fetching = false);

    // 已存在的模型默认不勾选，避免重复导入
    final existing = {for (final m in config.models) m.name};
    final picked = await showGlassDialog<Set<String>>(
      context: context,
      builder: (ctx) => _FetchResultDialog(
        models: fetched,
        existing: existing,
      ),
    );
    if (picked == null || picked.isEmpty) return;
    widget.onChanged();
    final notifier = ref.read(configProvider.notifier);
    // name -> 元数据：Dart 3 core 没有 firstWhereOrNull，用 map 直查
    final metaByName = {for (final m in fetched) m.name: m};
    var autoFilled = 0;
    for (final n in picked) {
      // 网关若附带 context_length / max_output_tokens，自动填充，
      // 省去逐个模型手填上下文与最大输出
      final meta = metaByName[n];
      if (meta?.hasMeta == true) autoFilled++;
      notifier.addModel(
        widget.configId,
        ProviderModel(
          name: n,
          kind: _guessKind(n),
          contextWindow: meta?.contextWindow ?? 0,
          maxOutputTokens: meta?.maxOutputTokens ?? 0,
        ),
      );
    }
    _toast(autoFilled > 0
        ? '已导入 ${picked.length} 个模型（$autoFilled 个自动填充了上下文/最大输出）'
        : '已导入 ${picked.length} 个模型（网关未返回上下文/最大输出，请手动填写）');
  }

  /// 从模型名猜用途。名字里带 embed / bge / rerank 的基本都是向量模型，
  /// 猜错用户可以在模型详情里改，比一律当成聊天模型好。
  static ModelKind _guessKind(String name) {
    final n = name.toLowerCase();
    if (n.contains('embed') || n.contains('bge') || n.contains('rerank')) {
      return ModelKind.embedding;
    }
    return ModelKind.chat;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 拉取结果选择弹窗。
  static Future<void> _addModel(
      BuildContext context, WidgetRef ref, LlmConfig config,
      {ProviderModel? existing}) {
    // showGlassDialog 已做紧凑居中（inset + maxWidth 400），
    // 模型编辑表单不再包一层 Dialog。
    return showGlassDialog<void>(
      context: context,
      builder: (_) => _ModelEditorSheet(
        configId: config.id,
        existing: existing,
      ),
    );
  }
}

class _FetchResultDialog extends StatefulWidget {
  const _FetchResultDialog({
    required this.models,
    required this.existing,
  });

  final List<FetchedModel> models;
  final Set<String> existing;

  @override
  State<_FetchResultDialog> createState() => _FetchResultDialogState();
}

class _FetchResultDialogState extends State<_FetchResultDialog> {
  late final List<String> names = widget.models.map((m) => m.name).toList();
  late final Set<String> _checked = {
    // 默认只勾选还没导入过的；已存在的默认不勾，避免重复添加
    for (final n in names)
      if (!widget.existing.contains(n)) n,
  };

  @override
  Widget build(BuildContext context) {
    final all = names;
    final allChecked = _checked.length == all.length;
    // 网关带回上下文/最大输出的模型数：0 = 该网关的 /models 只返回 id，
    // 自动填充功能无从生效（弹窗内明确展示，避免用户以为功能失效）
    final withMeta = widget.models.where((m) => m.hasMeta).length;
    String? metaLabel(FetchedModel m) {
      if (!m.hasMeta) return null;
      final parts = <String>[
        if (m.contextWindow != null) '上下文 ${m.contextWindow}',
        if (m.maxOutputTokens != null) '输出 ${m.maxOutputTokens}',
      ];
      return parts.join(' · ');
    }

    return glassAlertDialog(
      title: Text('发现 ${all.length} 个模型'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    if (allChecked) {
                      _checked.clear();
                    } else {
                      _checked
                        ..clear()
                        ..addAll(all);
                    }
                  }),
                  child: Text(allChecked ? '全不选' : '全选'),
                ),
                const Spacer(),
                Text('已选 ${_checked.length}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              ],
            ),
            if (withMeta == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('该服务的 /models 未返回上下文/最大输出信息，导入后需手动填写',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.error)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('其中 $withMeta 个模型带上下文/最大输出信息，导入时自动填充',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline)),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: all.length,
                itemBuilder: (ctx, i) {
                  final n = all[i];
                  final m = widget.models[i];
                  final exists = widget.existing.contains(n);
                  final meta = metaLabel(m);
                  return CheckboxListTile(
                    dense: true,
                    value: _checked.contains(n),
                    title: Text(n, style: const TextStyle(fontSize: 14)),
                    subtitle: exists
                        ? Text('已添加',
                            style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(ctx).colorScheme.outline))
                        : meta == null
                            ? null
                            : Text(meta,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(ctx).colorScheme.outline)),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _checked.add(n);
                      } else {
                        _checked.remove(n);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_checked),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.isDefaultChat,
    required this.isDefaultEmbed,
    required this.onSetDefault,
    required this.onEdit,
    required this.onDelete,
  });

  final ProviderModel model;
  final bool isDefaultChat;
  final bool isDefaultEmbed;
  final VoidCallback onSetDefault;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDefault = isDefaultChat || isDefaultEmbed;
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: surface(context),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                Icon(
                  model.kind == ModelKind.chat
                      ? Icons.chat_bubble_outline
                      : Icons.gradient,
                  size: 20,
                  color: onSurface(context, 0.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        '${model.kind.fullLabel} · 上下文 ${model.contextLabel}'
                        ' · 输出 ${model.maxOutputLabel}'
                        // 图片是聊天模型的默认能力（旧数据即如此），不展示；
                        // 只把较少见的视频能力标出来
                        '${model.supportsVideo ? ' · 视频' : ''}',
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.45)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isDefault)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('使用中',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: primary)),
                  ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert,
                      size: 20, color: onSurface(context, 0.5)),
                  onSelected: (v) {
                    if (v == 'default') onSetDefault();
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    if (!isDefault)
                      PopupMenuItem(
                          value: 'default', child: Text('设为默认模型')),
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 添加 / 编辑模型的底部表单。
class _ModelEditorSheet extends ConsumerStatefulWidget {
  const _ModelEditorSheet({required this.configId, this.existing});

  final String configId;
  final ProviderModel? existing;

  @override
  ConsumerState<_ModelEditorSheet> createState() => _ModelEditorSheetState();
}

class _ModelEditorSheetState extends ConsumerState<_ModelEditorSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _ctx = TextEditingController(
      text: (widget.existing?.contextWindow ?? 0) <= 0
          ? ''
          : '${widget.existing!.contextWindow}');
  late final TextEditingController _out = TextEditingController(
      text: (widget.existing?.maxOutputTokens ?? 0) <= 0
          ? ''
          : '${widget.existing!.maxOutputTokens}');
  late ModelKind _kind = widget.existing?.kind ?? ModelKind.chat;
  late double _temp = widget.existing?.temperature ?? 0.7;
  // 多模态输入能力：'text' 恒在，仅勾选 image / video。
  // 旧数据无字段时默认 text+image（与旧版「图片附件始终可用」一致）。
  // 只增删元素不重新赋值，final 即可（late 因为要读 widget.existing）。
  late final List<String> _modalities =
      List.of(widget.existing?.modalities ?? const ['text', 'image']);

  /// 勾选/取消一个模态；'text' 不允许取消（无意义的纯无输入模型）。
  void _toggleModality(String m) {
    setState(() {
      if (_modalities.contains(m)) {
        _modalities.remove(m);
      } else {
        _modalities.add(m);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _ctx.dispose();
    _out.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('模型名不能为空')));
      return;
    }
    // 空串按 0（未设置）；填了但非法（如 "128k"、"-500"）解析得 null，
    // 提示后阻止保存，不再被静默归 0（P2-23）。
    final ctxText = _ctx.text.trim();
    final outText = _out.text.trim();
    final ctxV = ctxText.isEmpty ? 0 : parseTokenCount(ctxText);
    final outV = outText.isEmpty ? 0 : parseTokenCount(outText);
    if (ctxV == null || outV == null) {
      showHint(context, '请输入正整数，支持 128k / 1.5m 格式');
      return;
    }
    final model = ProviderModel(
      name: name,
      kind: _kind,
      contextWindow: ctxV,
      maxOutputTokens: outV,
      temperature: _temp,
      // 'text' 恒在且排首位；向量模型不带多模态
      modalities: _kind == ModelKind.embedding
          ? const ['text']
          : ['text', ..._modalities.where((m) => m != 'text')],
    );
    final notifier = ref.read(configProvider.notifier);
    final old = widget.existing;
    final renamed = old != null && old.name != name;
    // 编辑既有模型且改了名：先删旧名条目再加新条目（P1-15）。
    // addModel 按 name 替换，不改名时单独调用即可覆盖旧参数。
    if (renamed) {
      notifier.removeModel(widget.configId, old.name);
    }
    notifier.addModel(widget.configId, model);
    if (renamed) {
      // 配置内指向旧名的默认模型字段逐个改指新名，否则用户改的
      // 参数对当前对话不生效（chatModel getter 按 defaultChatModel 查找）。
      final c = notifier.byId(widget.configId);
      if (c != null) {
        notifier.upsert(c.copyWith(
          defaultChatModel: c.defaultChatModel == old.name ? name : null,
          defaultEmbeddingModel:
              c.defaultEmbeddingModel == old.name ? name : null,
        ));
      }
      // 专项模型引用存在 SharedPreferences（vision/compress/summary_model），
      // 同样指向模型名，改名后一并迁移。
      final prefs = ref.read(sharedPreferencesProvider);
      final specialties = <String, StateProvider<String>>{
        'vision_model': visionModelProvider,
        'compress_model': compressModelProvider,
        'summary_model': summaryModelProvider,
      };
      specialties.forEach((key, provider) {
        if (prefs.getString(key) == old.name) {
          prefs.setString(key, name);
          ref.read(provider.notifier).state = name;
        }
      });
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(editing ? '编辑模型' : '添加模型',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            SegmentedButton<ModelKind>(
              segments: [
                for (final k in ModelKind.values)
                  ButtonSegment(
                    value: k,
                    label: Text(k.fullLabel),
                    icon: Icon(k == ModelKind.chat
                        ? Icons.chat_bubble_outline
                        : Icons.gradient),
                  ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 4),
            Text(_kind.hint,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '模型名',
                hintText: '如 gpt-4o-mini、glm-4-flash',
              ),
            ),
            if (_kind == ModelKind.chat) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctx,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '上下文长度',
                        hintText: '如 128000 或 128k',
                        helperText: '0 = 不自动压缩',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _out,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '最大输出',
                        hintText: '如 4096',
                        helperText: '0 = 不限制',
                      ),
                    ),
                  ),
                ],
              ),
              // 预设参数：点选直接填入对应输入框，省得手动换算 token 数。
              _PresetRow(
                label: '上下文',
                presets: const [8192, 16384, 32768, 65536, 131072, 262144, 1048576],
                onTap: (v) => setState(() => _ctx.text = '$v'),
              ),
              _PresetRow(
                label: '最大输出',
                presets: const [1024, 2048, 4096, 8192, 16384, 32768],
                onTap: (v) => setState(() => _out.text = '$v'),
              ),
              // 多模态输入能力：文本恒支持，图片/视频按模型实际能力勾选
              Row(
                children: [
                  const Text('多模态输入',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('图片'),
                    selected: _modalities.contains('image'),
                    onSelected: (_) => _toggleModality('image'),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('视频'),
                    selected: _modalities.contains('video'),
                    onSelected: (_) => _toggleModality('video'),
                  ),
                ],
              ),
              Text('勾选后该模型会出现在对应能力的候选列表（当前对话已支持发送图片）',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline)),
              Row(
                children: [
                  const Text('温度'),
                  Expanded(
                    child: Slider(
                      value: _temp,
                      min: 0,
                      max: 1.5,
                      divisions: 15,
                      label: _temp.toStringAsFixed(1),
                      onChanged: (v) => setState(() => _temp = v),
                    ),
                  ),
                  Text(_temp.toStringAsFixed(1),
                      style: TextStyle(
                          fontSize: 12, color: onSurface(context, 0.6))),
                ],
              ),
            ],
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _save,
              child: Text(editing ? '保存' : '添加'),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================ 小组件

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: onSurface(context, 0.5))),
    );
  }
}

/// 白色圆角卡片，子项之间用分割线（与设计稿一致：线从文字起点开始）。
class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      // 必须裁剪：Container 只画背景不裁子节点，
      // 没有它 InkWell 的水波纹会在卡片四角露出直角缺口。
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i != children.length - 1)
              Divider(
                height: 1,
                thickness: 0.5,
                indent: 16,
                endIndent: 16,
                color: onSurface(context, 0.07),
              ),
          ],
        ],
      ),
    );
  }
}

/// 文本输入行。用无边框样式贴合设计稿（卡片本身就是输入框的边框）。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.suffix,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          hintText: hint,
          suffixIcon: suffix,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: onSurface(context, 0.14)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: onSurface(context, 0.14)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary, width: 1.4),
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? subtitle;
  final bool value;

  /// null 表示不可交互。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return SwitchListTile(
      value: value,
      onChanged: enabled ? (v) => onChanged!(v) : null,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: enabled ? null : onSurface(context, 0.35),
              ),
            ),
          ),
        ],
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.45))),
    );
  }
}

/// 「标签 —— 值 ›」式的可点击行。
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    this.subtitle,
    this.value,
    this.icon,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final String? value;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: onSurface(context, 0.55)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!,
                        style: TextStyle(
                            fontSize: 12, color: onSurface(context, 0.45))),
                  ],
                ],
              ),
            ),
            if (value != null)
              Text(value!,
                  style: TextStyle(
                      fontSize: 13, color: onSurface(context, 0.55))),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                size: 20, color: onSurface(context, 0.3)),
          ],
        ),
      ),
    );
  }
}

/// 上下文长度 / 最大输出的预设参数 chips。
///
/// 点选直接把数值填入对应的 TextEditingController——预设覆盖常见档位
/// （8K ~ 1M 上下文，1K ~ 32K 输出），手输仍然可用（TextField 不受限）。
class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.label,
    required this.presets,
    required this.onTap,
  });

  final String label;
  final List<int> presets;
  final ValueChanged<int> onTap;

  static String _k(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return '${v.toStringAsFixed(v % 1 == 0 ? 0 : 1)}M';
    }
    return '${n ~/ 1000}K';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12, color: onSurface(context, 0.5))),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final v in presets)
                  ActionChip(
                    label: Text(_k(v),
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: onSurface(context, 0.15)),
                    onPressed: () => onTap(v),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
