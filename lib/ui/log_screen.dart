import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../services/app_log.dart';
import '../theme.dart';

/// 诊断日志页（关于 → 日志）。
///
/// 回答两个问题：
/// 1. **哪项功能启动失败了** —— 启动阶段与后台任务在 main.dart 里逐条打点，
///    失败标 `[E]`，用「错误」筛选一眼看到；
/// 2. **刚才发生了什么** —— 全 App 的 `debugPrint` 经 [AppLog] 桥接进来。
///
/// 数据源两个：
/// - **本次启动**：内存环形（2000 条），[AppLog.revision] 一变就自动重建，
///   流式输出时能"看着日志滚动"，不需要手动刷新；
/// - **上次启动**：磁盘文件，崩溃后靠它翻崩溃前的最后几条。
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  /// 只有「本次启动」是活的，用 0/1 直接当下标用。
  int _tab = 0;
  String _level = 'ALL';
  final TextEditingController _queryCtrl = TextEditingController();
  String _query = '';

  /// 上次启动的日志（磁盘读，读一次即可——文件在本次会话内不再变化）。
  List<String>? _prev;

  /// 读盘是否正在进行，避免列表未就绪时闪烁"无日志"。
  bool _prevLoading = false;

  static const _levelLabels = {
    'ALL': '全部',
    'E': '错误',
    'W': '警告',
    'I': '信息',
    'D': '调试',
  };

  @override
  void initState() {
    super.initState();
    // initState 里不能 setState（还没完成首次 build），所以直接给初值，
    // 读盘结果回来后再 setState 更新。
    if (AppLog.previousFile != null) {
      _prevLoading = true;
      _readPrevious();
    }
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _readPrevious() async {
    final lines = await AppLog.previousSessionEntries();
    if (!mounted) return;
    setState(() {
      _prev = lines;
      _prevLoading = false;
    });
  }

  /// 手动重读（上次启动标签的刷新按钮）。setState 此时合法。
  Future<void> _loadPrevious() async {
    if (_prevLoading) return;
    setState(() => _prevLoading = true);
    await _readPrevious();
  }

  /// 当前会话（按所选标签）的原始日志，尚未做级别/关键词过滤。
  List<String> get _base => _tab == 0 ? AppLog.entries.toList() : (_prev ?? const <String>[]);

  /// 关键词过滤（不区分大小写），级别统计也基于这一层——
  /// 这样搜 "mcp" 时看到的 E/W 数就是 mcp 相关的 E/W 数。
  List<String> get _searched {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _base;
    return _base.where((l) => l.toLowerCase().contains(q)).toList();
  }

  /// 最终展示列表。
  List<String> get _visible {
    final s = _searched;
    if (_level == 'ALL') return s;
    return s.where((l) => l.contains('[$_level]')).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '复制当前列表',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () {
              final text = AppLog.asText(_visible);
              Clipboard.setData(ClipboardData(text: text));
              _toast('已复制 ${_visible.length} 条日志');
            },
          ),
          IconButton(
            tooltip: '导出为文件',
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            onPressed: () => _export(_visible),
          ),
          if (_tab == 1)
            IconButton(
              tooltip: '重新读取',
              icon: const Icon(Icons.refresh_rounded, size: 22),
              onPressed: _loadPrevious,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildSessionSwitch(context),
          _buildSearchBox(context),
          _buildLevelChips(context),
          Expanded(
            // 本次启动监听 revision 实现自动刷新；上次启动是静态文件，
            // 直接渲染即可。
            child: _tab == 0
                ? ValueListenableBuilder<int>(
                    valueListenable: AppLog.revision,
                    builder: (_, __, ___) => _buildList(context),
                  )
                : _buildList(context),
          ),
          _buildStatusBar(context),
        ],
      ),
    );
  }

  // ---------------- 会话切换 ----------------

  Widget _buildSessionSwitch(BuildContext context) {
    final hasPrev = AppLog.previousFile != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          _seg(context, 0, '本次启动'),
          const SizedBox(width: 8),
          _seg(context, 1, hasPrev ? '上次启动' : '上次启动（无）', enabled: hasPrev),
        ],
      ),
    );
  }

  Widget _seg(BuildContext context, int index, String label, {bool enabled = true}) {
    final active = _tab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? () => setState(() => _tab = index) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
              : onSurface(context, 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: enabled
                ? (active
                    ? Theme.of(context).colorScheme.primary
                    : onSurface(context, 0.6))
                : onSurface(context, 0.3),
          ),
        ),
      ),
    );
  }

  // ---------------- 搜索 ----------------

  Widget _buildSearchBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: _queryCtrl,
          onChanged: (v) => setState(() => _query = v),
          style: TextStyle(fontSize: 13, color: onSurface(context, 0.9)),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索日志内容…',
            hintStyle: TextStyle(fontSize: 13, color: onSurface(context, 0.35)),
            prefixIcon: Icon(Icons.search_rounded,
                size: 18, color: onSurface(context, 0.45)),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 16, color: onSurface(context, 0.45)),
                    onPressed: () {
                      _queryCtrl.clear();
                      setState(() => _query = '');
                    },
                  ),
            filled: true,
            fillColor: onSurface(context, 0.05),
            contentPadding: const EdgeInsets.symmetric(vertical: 0),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 级别筛选 ----------------

  Widget _buildLevelChips(BuildContext context) {
    final counts = AppLog.countLevels(_searched);
    final total = _searched.length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          for (final key in _levelLabels.keys)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _chip(
                context,
                key,
                _levelLabels[key]!,
                key == 'ALL' ? total : (counts[key] ?? 0),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String key, String label, int count) {
    final active = _level == key;
    final color = switch (key) {
      'E' => const Color(0xFFD93025),
      'W' => const Color(0xFFE37400),
      _ => onSurface(context, 0.75),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() => _level = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.14) : onSurface(context, 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? color : onSurface(context, 0.6),
          ),
        ),
      ),
    );
  }

  // ---------------- 列表 ----------------

  Widget _buildList(BuildContext context) {
    if (_tab == 1 && _prevLoading) {
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 2, color: onSurface(context, 0.4)),
      );
    }
    final items = _visible;
    if (items.isEmpty) {
      return Center(
        child: Text(
          _base.isEmpty
              ? (_tab == 0 ? '暂无日志' : '上次启动没有留下日志')
              : '没有匹配的日志',
          style: TextStyle(fontSize: 14, color: onSurface(context, 0.4)),
        ),
      );
    }
    // 倒序展示：最新在顶部，打开页面不用先滚到底。
    // ListView.builder 惰性构建 —— 环形缓冲 2000 条全量挂载会掉帧。
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      itemCount: items.length,
      itemBuilder: (_, i) {
        // 倒序列表：i=0 是最后一行
        final line = items[items.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(
            line,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              fontFamily: 'monospace',
              color: line.contains('[E]')
                  ? const Color(0xFFD93025)
                  : line.contains('[W]')
                      ? const Color(0xFFE37400)
                      : line.contains('[D]')
                          ? onSurface(context, 0.5)
                          : onSurface(context, 0.75),
            ),
          ),
        );
      },
    );
  }

  // ---------------- 底部统计 ----------------

  Widget _buildStatusBar(BuildContext context) {
    final items = _visible;
    final counts = AppLog.countLevels(items);
    final err = counts['E'] ?? 0;
    final warn = counts['W'] ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: onSurface(context, 0.07))),
      ),
      child: Text(
        '共 ${items.length} 条'
        '${err > 0 ? ' · 错误 $err' : ''}'
        '${warn > 0 ? ' · 警告 $warn' : ''}'
        '${_tab == 0 ? '' : ' · ${AppLog.previousSessionLabel ?? ''}'}',
        style: TextStyle(fontSize: 11.5, color: onSurface(context, 0.5)),
      ),
    );
  }

  // ---------------- 导出 ----------------

  /// 导出**当前筛选结果**（不是全量）——用户筛选完再导出，
  /// 拿到的就该是他看的那部分。
  Future<void> _export(List<String> lines) async {
    final path = await AppLog.exportToFile(lines);
    if (!mounted) return;
    if (path == null) {
      _toast('导出失败');
      return;
    }
    AppLog.i('日志已导出: $path');
    _toast('已导出 ${lines.length} 条');
    try {
      await OpenFilex.open(path);
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
