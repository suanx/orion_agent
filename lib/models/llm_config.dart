/// 模型服务的用途类型。
///
/// 同一套 OpenAI 兼容接口里，**聊天模型**与**向量（Embedding）模型**是
/// 两个不同的模型名、走不同的 API 路径（`/chat/completions` 与 `/embeddings`）。
enum ModelKind {
  /// 聊天 / 补全模型，用于对话与工具调用。
  chat,

  /// 向量模型，用于知识库 RAG 的 embedding。
  embedding,
}

extension ModelKindX on ModelKind {
  String get label => this == ModelKind.chat ? '聊天' : '向量';

  String get fullLabel => this == ModelKind.chat ? '聊天模型' : '向量模型';

  String get hint => this == ModelKind.chat
      ? '用于对话、工具调用'
      : '用于知识库检索的向量化';

  /// 供持久化与协议层使用的稳定字符串。
  String get wire => name;

  static ModelKind fromWire(String? s) =>
      s == ModelKind.embedding.name ? ModelKind.embedding : ModelKind.chat;
}

/// 提供商类型。
///
/// 目前只支持 OpenAI 兼容协议（绝大多数国内厂商都提供兼容端点，
/// 如 GLM / DeepSeek / Qwen / Kimi）。保留枚举是为了以后接入别家协议时
/// 不用改数据结构。
enum ProviderType { openai }

extension ProviderTypeX on ProviderType {
  String get label => 'OpenAI';

  String get hint => 'OpenAI 兼容接口（/chat/completions、/embeddings、/models）';

  String get wire => name;

  static ProviderType fromWire(String? s) {
    for (final t in ProviderType.values) {
      if (t.name == s) return t;
    }
    return ProviderType.openai;
  }
}

/// 提供商下的单个模型。
///
/// 一个提供商（如「OpenCode」）通常同时提供多个可用的模型名，
/// 每个模型的上下文长度、输出上限、温度都可能不同，所以这些参数
/// 挂在模型上而不是提供商上。
class ProviderModel {
  /// 模型名，直接作为请求体里的 `model` 字段。
  final String name;

  final ModelKind kind;

  /// 上下文窗口（token 数）。0 表示不限制，由服务端决定。
  final int contextWindow;

  /// 单次回复的最大输出 token 数。0 表示不限制。
  final int maxOutputTokens;

  /// 采样温度。
  final double temperature;

  const ProviderModel({
    required this.name,
    this.kind = ModelKind.chat,
    this.contextWindow = 0,
    this.maxOutputTokens = 0,
    this.temperature = 0.7,
  });

  factory ProviderModel.fromJson(Map<String, dynamic> j) => ProviderModel(
        name: j['name'] as String? ?? '',
        kind: ModelKindX.fromWire(j['kind'] as String?),
        contextWindow: (j['contextWindow'] as num?)?.toInt() ?? 0,
        maxOutputTokens: (j['maxOutputTokens'] as num?)?.toInt() ?? 0,
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.wire,
        'contextWindow': contextWindow,
        'maxOutputTokens': maxOutputTokens,
        'temperature': temperature,
      };

  ProviderModel copyWith({
    String? name,
    ModelKind? kind,
    int? contextWindow,
    int? maxOutputTokens,
    double? temperature,
  }) =>
      ProviderModel(
        name: name ?? this.name,
        kind: kind ?? this.kind,
        contextWindow: contextWindow ?? this.contextWindow,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
        temperature: temperature ?? this.temperature,
      );

  String get contextLabel => contextWindow <= 0 ? '不限制' : '$contextWindow';

  String get maxOutputLabel =>
      maxOutputTokens <= 0 ? '不限制' : '$maxOutputTokens';
}

/// AI 提供商配置（OpenAI 兼容协议）。
///
/// 一个配置 = 一个提供商 = 一组模型。之前是「一个配置 = 一个模型」，
/// 导致同一家的多个模型要建多条配置、API Key 重复填。
class LlmConfig {
  final String id;
  final String name;
  final String baseUrl;

  /// 主 API Key。
  final String apiKey;

  /// 多 Key 模式下额外备用的 Key（不含 [apiKey]）。
  final List<String> extraKeys;

  /// 自定义 User-Agent。留空则用内置的默认值。
  ///
  /// 部分网关会按 UA 判断客户端、拦截「非官方 SDK」的请求，
  /// 留一个可覆盖的口子比让用户去改代码强。
  final String userAgent;

  final ProviderType type;

  /// 是否启用。停用后不参与请求（列表页显示为「已停用」）。
  final bool enabled;

  /// Base URL 即完整请求地址，不再自动拼接 `/chat/completions`。
  ///
  /// 用于把请求打到自定义路径的网关（如自建的转发端点）。
  final bool fullUrl;

  /// 使用 Response API（新版）。协议栈未实现，界面入口已移除（2026-10-04），
  /// 字段保留以兼容旧配置数据，实现后恢复界面。
  final bool responsesApi;

  /// 请求体携带 `prompt_cache_key`，让服务端命中提示词缓存。
  final bool promptCacheKey;

  /// 多 Key 模式：某个 Key 不可用时自动切到下一个并重发。
  final bool multiKey;

  /// 网络代理地址，如 `http://127.0.0.1:7890`。留空表示直连。
  final String proxy;

  /// 该提供商下可用的模型。
  final List<ProviderModel> models;

  /// 当前用于对话的模型名。留空则取 [models] 里第一个聊天模型。
  ///
  /// 必须显式记录：模型列表是用户可以增删的，靠「列表第一个」当默认值
  /// 会随着增删而漂移，用户选好的模型会在下次拉取后莫名换掉。
  final String defaultChatModel;

  /// 当前用于知识库检索的向量模型名。留空则取第一个向量模型。
  final String defaultEmbeddingModel;

  const LlmConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    this.extraKeys = const [],
    this.userAgent = '',
    this.type = ProviderType.openai,
    this.enabled = true,
    this.fullUrl = false,
    this.responsesApi = false,
    this.promptCacheKey = false,
    this.multiKey = false,
    this.proxy = '',
    this.models = const [],
    this.defaultChatModel = '',
    this.defaultEmbeddingModel = '',
  });

  /// 从旧结构迁移：
  /// 旧版是「一条配置一个模型」，字段 `model` / `embeddingModel` /
  /// `kind` / `contextWindow` / `maxOutputTokens` / `temperature` 平铺在根上。
  /// 读到旧数据时把它们折成 [models] 里的条目，**不丢任何配置**。
  factory LlmConfig.fromJson(Map<String, dynamic> j) {
    var models = <ProviderModel>[];
    final rawModels = j['models'];
    if (rawModels is List) {
      for (final m in rawModels) {
        if (m is Map) {
          models.add(ProviderModel.fromJson(m.cast<String, dynamic>()));
        }
      }
    }

    // 旧版迁移：根上的 model / embeddingModel
    if (models.isEmpty) {
      final legacyKind = ModelKindX.fromWire(j['kind'] as String?);
      final ctx = (j['contextWindow'] as num?)?.toInt() ?? 0;
      final maxOut = (j['maxOutputTokens'] as num?)?.toInt() ?? 0;
      final temp = (j['temperature'] as num?)?.toDouble() ?? 0.7;
      final chatName = j['model'] as String? ?? '';
      final embName = j['embeddingModel'] as String? ?? '';
      if (chatName.trim().isNotEmpty) {
        models.add(ProviderModel(
          name: chatName,
          // 旧的 kind 指明这条配置是聊天还是向量
          kind: legacyKind,
          contextWindow: ctx,
          maxOutputTokens: maxOut,
          temperature: temp,
        ));
      }
      // 旧的「聊天配置里附带 embedding 名」也要保留
      if (embName.trim().isNotEmpty) {
        models.add(ProviderModel(name: embName, kind: ModelKind.embedding));
      }
    }

    return LlmConfig(
      id: j['id'] as String? ?? '',
      name: j['name'] as String? ?? '',
      baseUrl: j['baseUrl'] as String? ?? '',
      apiKey: j['apiKey'] as String? ?? '',
      extraKeys: _stringList(j['extraKeys']),
      userAgent: j['userAgent'] as String? ?? '',
      type: ProviderTypeX.fromWire(j['type'] as String?),
      enabled: j['enabled'] as bool? ?? true,
      fullUrl: j['fullUrl'] as bool? ?? false,
      responsesApi: j['responsesApi'] as bool? ?? false,
      promptCacheKey: j['promptCacheKey'] as bool? ?? false,
      multiKey: j['multiKey'] as bool? ?? false,
      proxy: j['proxy'] as String? ?? '',
      models: models,
      defaultChatModel: j['defaultChatModel'] as String? ?? '',
      defaultEmbeddingModel: j['defaultEmbeddingModel'] as String? ?? '',
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final v in raw)
        if (v is String && v.trim().isNotEmpty) v,
    ];
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'extraKeys': extraKeys,
        'userAgent': userAgent,
        'type': type.wire,
        'enabled': enabled,
        'fullUrl': fullUrl,
        'responsesApi': responsesApi,
        'promptCacheKey': promptCacheKey,
        'multiKey': multiKey,
        'proxy': proxy,
        'models': [for (final m in models) m.toJson()],
        'defaultChatModel': defaultChatModel,
        'defaultEmbeddingModel': defaultEmbeddingModel,
      };

  // ------- 派生属性 -------

  List<ProviderModel> get chatModels =>
      [for (final m in models) if (m.kind == ModelKind.chat) m];

  List<ProviderModel> get embeddingModels =>
      [for (final m in models) if (m.kind == ModelKind.embedding) m];

  /// 当前使用的聊天模型。
  ///
  /// 优先取 [defaultChatModel] 指定的那个；指定的模型被删掉时退回列表第一个，
  /// 保证不会因为一次误删就彻底不能对话。
  ProviderModel? get chatModel {
    for (final m in chatModels) {
      if (m.name == defaultChatModel) return m;
    }
    return chatModels.isEmpty ? null : chatModels.first;
  }

  /// 当前使用的向量模型。
  ProviderModel? get embeddingModel {
    for (final m in embeddingModels) {
      if (m.name == defaultEmbeddingModel) return m;
    }
    return embeddingModels.isEmpty ? null : embeddingModels.first;
  }

  /// 聊天模型名。无可用模型时为空串。
  String get model => chatModel?.name ?? '';

  /// 向量模型名。
  String get embeddingModelName => embeddingModel?.name ?? '';

  /// 是否可发起对话：必须有 Base URL 和至少一个聊天模型。
  bool get ready => baseUrl.trim().isNotEmpty && chatModel != null;

  /// 可用作请求的全部 Key（多 Key 模式下含备用 Key）。
  List<String> get effectiveKeys {
    final all = <String>[
      if (apiKey.trim().isNotEmpty) apiKey.trim(),
      if (multiKey)
        for (final k in extraKeys)
          if (k.trim().isNotEmpty) k.trim(),
    ];
    return all;
  }

  /// 列表页显示用的模型数量文案。
  String get modelCountLabel => '${models.length} 个模型';

  /// 展示名：未填名称时退回主机名，再退回 Base URL 原文。
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isNotEmpty) return host;
    return baseUrl.isEmpty ? '未命名提供商' : baseUrl;
  }

  LlmConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    List<String>? extraKeys,
    String? userAgent,
    ProviderType? type,
    bool? enabled,
    bool? fullUrl,
    bool? responsesApi,
    bool? promptCacheKey,
    bool? multiKey,
    String? proxy,
    List<ProviderModel>? models,
    String? defaultChatModel,
    String? defaultEmbeddingModel,
  }) =>
      LlmConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        extraKeys: extraKeys ?? this.extraKeys,
        userAgent: userAgent ?? this.userAgent,
        type: type ?? this.type,
        enabled: enabled ?? this.enabled,
        fullUrl: fullUrl ?? this.fullUrl,
        responsesApi: responsesApi ?? this.responsesApi,
        promptCacheKey: promptCacheKey ?? this.promptCacheKey,
        multiKey: multiKey ?? this.multiKey,
        proxy: proxy ?? this.proxy,
        models: models ?? this.models,
        defaultChatModel: defaultChatModel ?? this.defaultChatModel,
        defaultEmbeddingModel:
            defaultEmbeddingModel ?? this.defaultEmbeddingModel,
      );
}
