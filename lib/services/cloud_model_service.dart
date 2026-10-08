import 'package:flutter/foundation.dart';

import '../models/llm_config.dart';
import 'cloud_service.dart';

/// 云端模型（由后端持 Key 中继的免费额度模型）。
///
/// 定位：用户不想或不能自己填 API Key 时，登录云端账号即可直接对话。
/// 与用户自建供应商的差别：
///   - `fullUrl = true`，`baseUrl` 就是后端中继的完整地址（不再拼
///     `/chat/completions`，后端路径本来就是 `/api/ai/chat`）；
///   - `apiKey` 填占位串——真正的鉴权由 [LlmClient] 注入的登录令牌完成，
///     占位只是为了让 `effectiveKeys` 非空（空 Key 会被客户端拒绝发请求）。
///   - 不落盘：这些配置每次从后端拉取，`id` 带 `cloud:` 前缀避免与用户
///     自建配置混淆，也不会被备份/同步带走。
class CloudModelService {
  const CloudModelService._();

  /// 云端配置在本地配置列表里的 ID 前缀。
  ///
  /// 用 `cloud:` 而不是供应商 id，是为了让「一家供应商多个」在本地合成
  /// 一条配置（模型列表合并），同时保证不会与用户自建 id 撞车。
  static const idPrefix = 'cloud:';

  /// 占位 API Key。真正的鉴权走登录令牌，这个值只为通过非空校验。
  static const placeholderApiKey = 'cloud-managed';

  /// 把后端下发的供应商包装成本地 [LlmConfig]。
  ///
  /// 一家供应商 = 一条本地配置（其下所有聊天模型合并为模型列表），
  /// 这样模型选择器里只多出「云端」相关的条目，不会为每家供应商各占一行。
  static LlmConfig toConfig(CloudModelProvider p) {
    final models = p.chatModels
        .map((m) => ProviderModel(
              name: m.name,
              kind: ModelKind.chat,
              contextWindow: m.contextWindow,
            ))
        .toList();
    return LlmConfig(
      id: '$idPrefix${p.id}',
      name: '${p.name}（云端）',
      // fullUrl=true：baseUrl 即完整请求地址，后端路径不是 OpenAI 标准路径
      baseUrl: p.chatUrl,
      apiKey: placeholderApiKey,
      fullUrl: true,
      enabled: true,
      models: models,
      defaultChatModel: models.isNotEmpty ? models.first.name : '',
    );
  }

  /// 判断某个本地配置是否为云端配置。
  static bool isCloud(LlmConfig c) => c.id.startsWith(idPrefix);

  /// 把云端配置列表转成 [LlmConfig]（已过滤掉没有聊天模型的供应商）。
  static List<LlmConfig> toConfigs(List<CloudModelProvider> providers) =>
      providers
          .where((p) => p.chatModels.isNotEmpty && p.chatUrl.isNotEmpty)
          .map(toConfig)
          .toList();
}

/// 云端模型列表的加载状态，供 UI 决定是否展示「云端模型」分组。
class CloudModelsState {
  const CloudModelsState({
    this.configs = const [],
    this.loading = false,
    this.available = false,
    this.error,
  });

  final List<LlmConfig> configs;

  /// 后端是否已配置供应商。false 时 UI 应隐藏云端入口而不是报错。
  final bool available;

  final bool loading;
  final String? error;

  bool get hasModels => configs.isNotEmpty;

  CloudModelsState copyWith({
    List<LlmConfig>? configs,
    bool? loading,
    bool? available,
    String? error,
    bool clearError = false,
  }) =>
      CloudModelsState(
        configs: configs ?? this.configs,
        available: available ?? this.available,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 云端模型加载器（ChangeNotifier，供 Provider 包装）。
///
/// 刻意做成可缓存的：模型列表变化不频繁，而每次进对话页都拉一次会
/// 白耗一次网络往返。登录状态变化时由调用方 [refresh] 强制刷新。
class CloudModelsController extends ChangeNotifier {
  CloudModelsController(this._cloud);

  final CloudService _cloud;

  CloudModelsState _state = const CloudModelsState();
  CloudModelsState get state => _state;

  /// 上次成功加载的时间，用于避免频繁刷新。
  DateTime? _loadedAt;

  /// 缓存有效期：5 分钟。期间内 [load] 直接用缓存。
  static const cacheTtl = Duration(minutes: 5);

  bool _disposed = false;

  /// 拉取云端模型列表。
  ///
  /// [force] 为 true 时忽略缓存。未登录或后端未配置供应商时静默返回空列表
  /// —— 这些都是正常状态（不是错误），不该在 UI 上弹红字。
  Future<void> load({bool force = false}) async {
    if (_cloud.email == null || _cloud.email!.isEmpty) {
      _apply(const CloudModelsState());
      return;
    }
    final cached = _loadedAt;
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached) < cacheTtl &&
        _state.hasModels) {
      return;
    }
    _apply(_state.copyWith(loading: true, clearError: true));
    try {
      final res = await _cloud.fetchAiProviders();
      _loadedAt = DateTime.now();
      _apply(CloudModelsState(
        configs: CloudModelService.toConfigs(res.providers),
        available: res.available,
      ));
    } catch (e) {
      // 拉取失败保留旧列表(可能仍可用), 只记录错误
      _apply(_state.copyWith(loading: false, error: e.toString()));
    }
  }

  void _apply(CloudModelsState s) {
    if (_disposed) return;
    _state = s;
    notifyListeners();
  }

  /// 登录后调用：清缓存并重新拉取。
  Future<void> refresh() async {
    _loadedAt = null;
    await load(force: true);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
