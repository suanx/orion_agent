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

  const LlmConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.7,
    this.embeddingModel = '',
  });

  factory LlmConfig.fromJson(Map<String, dynamic> j) => LlmConfig(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        baseUrl: j['baseUrl'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        model: j['model'] as String? ?? '',
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.7,
        embeddingModel: j['embeddingModel'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'embeddingModel': embeddingModel,
      };

  LlmConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    String? embeddingModel,
  }) =>
      LlmConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        temperature: temperature ?? this.temperature,
        embeddingModel: embeddingModel ?? this.embeddingModel,
      );
}
