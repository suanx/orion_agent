import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/token_stats_service.dart';
import '../theme.dart';
import 'glass.dart';

/// Token 统计页。
///
/// 图表用 [CustomPainter] 手绘，没有引入图表库：
/// 需求只是折线 + 面积 + 三条 Y 轴刻度，为它加一个依赖不划算。
class TokenStatsScreen extends ConsumerStatefulWidget {
  const TokenStatsScreen({super.key});

  @override
  ConsumerState<TokenStatsScreen> createState() => _TokenStatsScreenState();
}

class _TokenStatsScreenState extends ConsumerState<TokenStatsScreen> {
  StatsRange _range = StatsRange.week7;
  StatsSummary? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 清空统计的确认对话框弹出期间用户可能返回页面，
    // 此时 await 回来再 setState 会抛 after dispose。
    if (!mounted) return;
    setState(() => _loading = true);
    final s = await ref.read(tokenStatsServiceProvider).summary(_range);
    if (!mounted) return;
    setState(() {
      _summary = s;
      _loading = false;
    });
  }

  Future<void> _confirmClear() async {
    final ok = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空统计'),
        content: const Text('将删除全部 token 用量记录，且无法恢复。\n'
            '只清空统计，不会删除任何对话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(tokenStatsServiceProvider).clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary ?? StatsSummary.empty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Token 统计'),
        actions: [
          IconButton(
            tooltip: '清空统计',
            onPressed: _loading ? null : _confirmClear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          // 时间范围切换
          Row(
            children: [
              for (final r in StatsRange.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(r.label),
                    selected: _range == r,
                    onSelected: (_) {
                      setState(() => _range = r);
                      _load();
                    },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (s.requests == 0)
            const _EmptyHint()
          else ...[
            // 概览四宫格
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    label: '总消耗',
                    value: _compact(s.totalTokens),
                    unit: 'tokens',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    label: '请求次数',
                    value: '${s.requests}',
                    unit: '次',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    label: '费用',
                    value: '\$${(s.costCents / 100).toStringAsFixed(2)}',
                    unit: s.costCents == 0 ? '未配置价格' : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    label: '缓存命中率',
                    value: '${(s.cacheHitRate * 100).toStringAsFixed(1)}%',
                    unit: '缓存 ${_compact(s.cachedTokens)}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 趋势图
            Text('消耗趋势',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: onSurface(context, 0.5))),
            const SizedBox(height: 10),
            _UsageChart(daily: s.daily),
            const SizedBox(height: 10),
            const _ChartLegend(),
            const SizedBox(height: 24),

            // 渠道统计
            Text('渠道统计',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: onSurface(context, 0.5))),
            const SizedBox(height: 10),
            for (final p in s.providers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ProviderRow(
                  usage: p,
                  // 以最大渠道为基准画比例条
                  maxTokens: s.providers.first.totalTokens,
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 1280000 → "1.3M"。图表轴与卡片共用，避免出现 1280000 这种长串。
  static String _compact(int n) {
    if (n >= 1000000) {
      final v = n / 1000000;
      return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}M';
    }
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
    return '$n';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          Icon(Icons.insights_outlined,
              size: 40, color: onSurface(context, 0.2)),
          const SizedBox(height: 12),
          Text('所选范围内没有用量记录',
              style: TextStyle(color: onSurface(context, 0.4))),
          const SizedBox(height: 4),
          Text('与模型对话后即可看到统计',
              style: TextStyle(fontSize: 12, color: onSurface(context, 0.3))),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: onSurface(context, 0.5))),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w600, height: 1.1)),
          if (unit != null) ...[
            const SizedBox(height: 2),
            Text(unit!,
                style: TextStyle(fontSize: 11, color: onSurface(context, 0.4))),
          ],
        ],
      ),
    );
  }
}

/// 折线 + 面积图。三条序列：输入 / 输出 / 缓存。
class _UsageChart extends StatelessWidget {
  const _UsageChart({required this.daily});

  final List<DailyUsage> daily;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: daily.isEmpty
          ? const SizedBox.shrink()
          : CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(
                daily: daily,
                lineColor: Theme.of(context).colorScheme.primary,
                gridColor: onSurface(context, 0.08),
                labelColor: onSurface(context, 0.45),
                axisColor: onSurface(context, 0.15),
              ),
            ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.daily,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
    required this.axisColor,
  });

  final List<DailyUsage> daily;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;
  final Color axisColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 左侧留给 Y 轴刻度文字
    const leftPad = 46.0;
    const bottomPad = 22.0;
    final chartW = size.width - leftPad;
    final chartH = size.height - bottomPad;
    if (chartW <= 0 || chartH <= 0) return;

    // 取三天以上的间隔轴上限做「好看」的整百/千/百万
    final peak = daily.fold<int>(0,
        (m, d) => math.max(m, math.max(d.inputTokens, math.max(d.outputTokens, d.cachedTokens))));
    final top = _niceMax(peak);

    // 横向网格 + Y 轴刻度
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const lines = 4;
    for (var i = 0; i <= lines; i++) {
      final y = chartH * i / lines;
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + chartW, y), grid);
      _text(canvas,
          _fmt(top * (lines - i) / lines),
          Offset(leftPad - 6, y - 6),
          labelColor,
          align: TextAlign.right,
          width: leftPad - 8);
    }

    // 折线：X 轴按天等分
    final n = daily.length;
    Offset pt(int i, double v) => Offset(
          leftPad + (n == 1 ? chartW / 2 : chartW * i / (n - 1)),
          chartH - (top <= 0 ? 0 : v / top * chartH),
        );

    void drawSeries(List<double> values, Color color, {bool fill = false}) {
      if (values.every((v) => v == 0)) return;
      final path = Path();
      final pts = <Offset>[];
      for (var i = 0; i < n; i++) {
        final p = pt(i, values[i].clamp(0, top).toDouble());
        pts.add(p);
      }
      path.moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(pts.last.dx, chartH)
          ..lineTo(pts.first.dx, chartH)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.28),
                color.withValues(alpha: 0.02),
              ],
            ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // 缓存（紫）在下、输入（蓝）填充
    drawSeries(daily.map((d) => d.cachedTokens.toDouble()).toList(),
        const Color(0xFF7C3AED),
        fill: true);
    drawSeries(daily.map((d) => d.inputTokens.toDouble()).toList(), lineColor);
    drawSeries(daily.map((d) => d.outputTokens.toDouble()).toList(),
        const Color(0xFFF59E0B));

    // X 轴：最多 6 个日期标签，避免挤成一团
    final step = math.max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += step) {
      final d = daily[i].day;
      _text(canvas, '${d.month}/${d.day}', pt(i, 0) + const Offset(-14, 4),
          labelColor);
    }
  }

  /// 把上限抬到 1/2/5×10^n 的整值，网格线才有整齐的刻度。
  ///
  /// 同时保证**至少能分出 4 档**：`niceMax(1)` 若返回 1，刻度会算成
  /// 1/1/1/0/0 这种重复值，所以低于 4 时直接兜到 4。
  static int _niceMax(int v) {
    if (v <= 4) return 4;
    final exp = (math.log(v) / math.ln10).floor();
    final pow = math.pow(10, exp).toDouble();
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      if (v <= pow * m) {
        final top = (pow * m).round();
        return top < 4 ? 4 : top;
      }
    }
    return (pow * 10).round();
  }

  /// 轴刻度文案。同一张图上若出现重复刻度（如 2K 与 2.0K），
  /// 说明精度选得不合适——退到更粗的单位。
  static String _fmt(double v) {
    if (v >= 1000000) {
      final m = v / 1000000;
      // 整数百万不带小数，1.5M 这种保留一位
      return m == m.roundToDouble() ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
    }
    if (v >= 1000) {
      final k = v / 1000;
      return k == k.roundToDouble() ? '${k.round()}K' : '${k.toStringAsFixed(1)}K';
    }
    return v.round().toString();
  }

  void _text(Canvas canvas, String s, Offset at, Color color,
      {TextAlign align = TextAlign.left, double? width}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: 10, color: color),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width ?? 60);
    tp.paint(canvas, Offset(width != null ? at.dx : at.dx, at.dy));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.daily != daily || old.lineColor != lineColor;
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _dot(context, '输入', Theme.of(context).colorScheme.primary),
        const SizedBox(width: 16),
        _dot(context, '输出', const Color(0xFFF59E0B)),
        const SizedBox(width: 16),
        _dot(context, '缓存', const Color(0xFF7C3AED)),
      ],
    );
  }

  // context 必须显式传进来：方法内嵌表达式里取不到 build 的 context
  Widget _dot(BuildContext context, String label, Color c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: onSurface(context, 0.6))),
        ],
      );
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.usage, required this.maxTokens});

  final ProviderUsage usage;
  final int maxTokens;

  @override
  Widget build(BuildContext context) {
    final ratio = maxTokens <= 0 ? 0.0 : usage.totalTokens / maxTokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage.provider.isEmpty ? usage.model : usage.provider,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${usage.requests} 次调用',
                  style: TextStyle(fontSize: 12, color: onSurface(context, 0.5))),
              const SizedBox(width: 12),
              Text('↑ ${_TokenStatsScreenState._compact(usage.inputTokens)}'
                  '  ↓ ${_TokenStatsScreenState._compact(usage.outputTokens)}',
                  style: TextStyle(fontSize: 12, color: onSurface(context, 0.65))),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: onSurface(context, 0.06),
            ),
          ),
          if (usage.model.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(usage.model,
                style: TextStyle(fontSize: 11, color: onSurface(context, 0.4)),
                overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}
