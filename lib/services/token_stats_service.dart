import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';

/// 统计时间范围。
enum StatsRange {
  today,
  week7,
  month30,
  all,
}

extension StatsRangeX on StatsRange {
  String get label => switch (this) {
        StatsRange.today => '今天',
        StatsRange.week7 => '近7天',
        StatsRange.month30 => '近30天',
        StatsRange.all => '全部',
      };

  /// 起始时间戳；[StatsRange.all] 返回 0（不限）。
  int get sinceMs => switch (this) {
        StatsRange.today => DateTime(DateTime.now().year, DateTime.now().month,
                DateTime.now().day)
            .millisecondsSinceEpoch,
        StatsRange.week7 =>
          DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch,
        StatsRange.month30 =>
          DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch,
        StatsRange.all => 0,
      };
}

/// 单个模型服务的用量小计。
class ProviderUsage {
  final String provider;
  final String model;
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  const ProviderUsage({
    required this.provider,
    required this.model,
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
  });

  int get totalTokens => inputTokens + outputTokens;

  /// 缓存命中率 = 命中缓存的输入 token / 总输入 token。
  double get cacheHitRate =>
      inputTokens <= 0 ? 0 : cachedTokens / inputTokens;
}

/// 某一天（或某个时间桶）的用量。
class DailyUsage {
  final DateTime day;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  const DailyUsage({
    required this.day,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
  });
}

/// 统计页需要的全部聚合结果。
class StatsSummary {
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final int costCents;
  final List<DailyUsage> daily;
  final List<ProviderUsage> providers;

  const StatsSummary({
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
    required this.costCents,
    required this.daily,
    required this.providers,
  });

  static const empty = StatsSummary(
    requests: 0,
    inputTokens: 0,
    outputTokens: 0,
    cachedTokens: 0,
    costCents: 0,
    daily: [],
    providers: [],
  );

  int get totalTokens => inputTokens + outputTokens;

  double get cacheHitRate => inputTokens <= 0 ? 0 : cachedTokens / inputTokens;
}

/// Token 用量统计服务。
class TokenStatsService {
  TokenStatsService(this._db);

  final AppDatabase _db;

  /// 记录一次模型调用的用量。
  Future<void> record({
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
    int cachedTokens = 0,
    int costCents = 0,
    DateTime? at,
  }) async {
    // 全零的记录没有统计价值，还会把「请求次数」算错
    if (inputTokens <= 0 && outputTokens <= 0) return;
    final ts = at ?? DateTime.now();
    try {
      await _db.into(_db.tokenUsageRows).insert(
            TokenUsageRowsCompanion.insert(
              id: uniqueId('usage'),
              createdAt: ts.millisecondsSinceEpoch,
              provider: Value(provider),
              model: Value(model),
              inputTokens: Value(inputTokens),
              outputTokens: Value(outputTokens),
              cachedTokens: Value(cachedTokens),
              requests: const Value(1),
              costCents: Value(costCents),
            ),
          );
    } catch (e) {
      // 统计失败绝不能影响正常对话
      debugPrint('Token 用量写入失败：$e');
    }
  }

  /// 聚合指定范围的用量。
  Future<StatsSummary> summary(StatsRange range) async {
    final since = range.sinceMs;

    // 一次性取回范围内的原始行，后续在内存里聚合。
    // 数据量按「每天几十次调用」估算，几年内也就万级行，
    // 一次全取比多次 SQL聚合更快（省掉 N 次 group by）。
    final rows = await (_db.select(_db.tokenUsageRows)
          ..where((t) => t.createdAt.isBiggerOrEqualValue(since))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    if (rows.isEmpty) return StatsSummary.empty;

    var requests = 0;
    var input = 0;
    var output = 0;
    var cached = 0;
    var cost = 0;

    // 按天分桶
    final dayBuckets = <int, List<int>>{};
    // 按「服务+模型」分桶。
    // 键用 Record 而非拼接字符串：服务名/模型名本身可能含空格或分隔符，
    // 拼接后再 split 会把维度算错。
    final providerBuckets =
        <(String, String), ({int req, int in, int out, int cached})>{};

    for (final r in rows) {
      requests += r.requests;
      input += r.inputTokens;
      output += r.outputTokens;
      cached += r.cachedTokens;
      cost += r.costCents;

      // 本地时区的当天零点
      final d = DateTime.fromMillisecondsSinceEpoch(r.createdAt);
      final dayKey = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
      final acc = dayBuckets.putIfAbsent(dayKey, () => [0, 0, 0]);
      acc[0] += r.inputTokens;
      acc[1] += r.outputTokens;
      acc[2] += r.cachedTokens;

      final key = (r.provider, r.model);
      final prev = providerBuckets[key];
      providerBuckets[key] = (
        req: (prev?.req ?? 0) + r.requests,
        in: (prev?.in ?? 0) + r.inputTokens,
        out: (prev?.out ?? 0) + r.outputTokens,
        cached: (prev?.cached ?? 0) + r.cachedTokens,
      );
    }

    final daily = [
      for (final e in dayBuckets.entries)
        DailyUsage(
          day: DateTime.fromMillisecondsSinceEpoch(e.key),
          inputTokens: e.value[0],
          outputTokens: e.value[1],
          cachedTokens: e.value[2],
        ),
    ]..sort((a, b) => a.day.compareTo(b.day));

    final providers = [
      for (final e in providerBuckets.entries)
        ProviderUsage(
          provider: e.key.$1,
          model: e.key.$2,
          requests: e.value.req,
          inputTokens: e.value.in,
          outputTokens: e.value.out,
          cachedTokens: e.value.cached,
        ),
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));

    return StatsSummary(
      requests: requests,
      inputTokens: input,
      outputTokens: output,
      cachedTokens: cached,
      costCents: cost,
      daily: daily,
      providers: providers,
    );
  }

  /// 清空全部用量记录。
  Future<void> clear() async {
    await _db.delete(_db.tokenUsageRows).go();
  }
}
