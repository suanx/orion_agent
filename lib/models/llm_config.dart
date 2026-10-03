/// 模型服务的用途类型。
///
/// 同一套 OpenAI 兼容接口里，**聊天模型**与**向量（Embedding）模型**是
/// 两个不同的模型名、走不同的 API 路径（`/chat/completions` 与 `/embeddings`）。
/// 配置时必须能明确区分，否则用户不知道该把哪个模型名填到哪个字段。
enum ModelKind {
  /// 聊天 / 补全模型，用于对话与工具调用。
  chat,

  /// 向量模型，用于知识库 RAG 的 embedding。
  embedding,
}

extension ModelKindX on ModelKind {
  String get label => this == ModelKind.chat ? '聊天模型' : '向量模型';

  String get hint => this == ModelKind.chat
      ? '用于对话、工具调用'
      : '用于知识库检索的向量化';

  /// 供持久化与协议层使用的稳定字符串。
  String get wire => name;

  static ModelKind fromWire(String? s) =>
      s == ModelKind.embedding.name ? ModelKind.embedding : ModelKind.chat;
}

/// LLM 服务配置（OpenAI 兼容协议）。
class LlmConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;

  /// Embedding 模型名（用于知识库 RAG 检索，留空则禁用知识库检索）。
  final String embeddingModel;

  /// 本条配置服务的用途。聊天配置填 `model`，向量配置填 `model`。
  ///
  /// 之前靠「model 和 embeddingModel 两个字段谁填了」来隐式判断，
  /// 会出现「两个都填了但用户其实想配向量服务」这类歧义。
  final ModelKind kind;

  /// 上下文窗口（token 数）。0 表示不限制，由服务端决定。
  final int contextWindow;

  /// 单次回复的最大输出 token 数。0 表示不限制。
  final int maxOutputTokens;

  const LlmConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.7,
    this.embeddingModel = '',
    this.kind = ModelKind.chat,
    this.contextWindow = 0,
    this.maxOutputTokens = 0,
  });

  factory LlmConfig.fromJson(Map<String, dynamic> j) => LlmConfig(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        model: j['model'] as String? ?? '',
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
        embeddingModel: j['embeddingModel'] as String? ?? '',
        kind: ModelKindX.fromWire(j['kind'] as String?),
        contextWindow: (j['contextWindow'] as num?)?.toInt() ?? 0,
        maxOutputTokens: (j['maxOutputTokens'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'embeddingModel': embeddingModel,
        'kind': kind.wire,
        'contextWindow': contextWindow,
        'maxOutputTokens': maxOutputTokens,
      };

  LlmConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    String? embeddingModel,
    ModelKind? kind,
    int? contextWindow,
    int? maxOutputTokens,
  }) =>
      LlmConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        embeddingModel: embeddingModel ?? this.embeddingModel,
        kind: kind ?? this.kind,
        contextWindow: contextWindow ?? this.contextWindow,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      );

  /// 供 UI 展示的上下文长度文案。
  String get contextLabel => contextWindow <= 0 ? '不限制' : '$contextWindow';

  String get maxOutputLabel =>
      maxOutputTokens <= 0 ? '不限制' : '$maxOutputTokens';
}
