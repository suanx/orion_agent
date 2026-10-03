import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/llm_config.dart';

/// LLM 流式事件。
abstract class LlmEvent {
  const LlmEvent();
}

/// 一段增量文本。
class ContentDelta extends LlmEvent {
  final String delta;
  const ContentDelta(this.delta);
}

/// 一段思考过程增量（模型在正式回答前输出的推理文本）。
///
/// 两种主流下发字段都兼容（见 `_chatStreamOnce` 的解析）：
///   - DeepSeek / 智谱 / 千问等兼容网关：`delta.reasoning_content`
///   - OpenRouter 及部分网关：`delta.reasoning`
/// 服务端不下发思考内容时不会有这个事件。
class ReasoningDelta extends LlmEvent {
  final String delta;
  const ReasoningDelta(this.delta);
}

/// 一轮响应结束后的完整 assistant 消息（可能携带工具调用）。
class FinalMessage extends LlmEvent {
  final ChatMessage message;
  const FinalMessage(this.message);
}

/// 一轮响应的 token 用量（OpenAI 兼容协议顶层 `usage` 字段）。
///
/// 单独作为事件而不是塞进 [FinalMessage]：Agent 循环里只有「拿到最终
/// 消息」这一处会收敛统计，混进去容易被漏掉。
class TokenUsage extends LlmEvent {
  final int promptTokens;
  final int completionTokens;

  /// 命中提示词缓存的输入 token（`prompt_tokens_details.cached_tokens`）。
  /// 不少网关不下发这个子对象，此时为 0。
  final int cachedTokens;

  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.cachedTokens = 0,
  });

  bool get isEmpty => promptTokens <= 0 && completionTokens <= 0;
}

/// 拉取模型列表时返回的一项。
class RemoteModel {
  final String id;
  const RemoteModel(this.id);
}

class _ToolCallAcc {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// OpenAI 兼容协议的客户端（SSE 流式）。
class LlmClient {
  LlmClient(this._defaultDio);

  /// 无代理时复用的 Dio（绝大多数请求走这里，不必每次新建连接池）。
  final Dio _defaultDio;

  /// 按「代理 + UA」组合缓存的 Dio：同一组合的所有请求复用同一个连接池。
  ///
  /// UA 的隔离也靠这个 key 完成 —— 临时改 UA 会写到 Dio 的默认 header 上，
  /// 而 Dio 是共享实例，所以带自定义 UA 的组合必须各自持有独立实例，
  /// 否则会污染走默认 UA 的请求。
  final _proxyDioCache = <String, Dio>{};

  /// 默认 User-Agent。
  ///
  /// 部分网关（Cloudflare 前置、企业代理）会拦截空 UA 或明显是脚本的 UA，
  /// 给一个正常的客户端标识能减少无谓的 403。
  static const defaultUserAgent = 'OrionAgent/1.0 (Android; Flutter)';

  /// 取出适用的 Dio：按「代理 + UA」组合缓存。
  ///
  /// Dio 的 BaseOptions 没有 proxy 字段，必须换掉 httpClientAdapter。
  /// UA 用 Options.headers 就能覆盖，但为隔离起见仍单独缓存。
  Dio _dioFor(LlmConfig config) {
    final proxy = config.proxy.trim();
    final ua = config.userAgent.trim();
    if (proxy.isEmpty && ua.isEmpty) return _defaultDio;

    final key = '$proxy|$ua';
    final hit = _proxyDioCache[key];
    if (hit != null) return hit;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      headers: ua.isEmpty ? null : {HttpHeaders.userAgentHeader: ua},
    ));
    if (proxy.isNotEmpty) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          // findProxy 返回 'PROXY host:port'；https 也走同一个代理
          client.findProxy = (_) => 'PROXY $proxy';
          client.connectionTimeout = const Duration(seconds: 30);
          return client;
        },
      );
    }
    _proxyDioCache[key] = dio;
    return dio;
  }

  /// 去掉尾部斜杠的 Base URL。
  static String _trim(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// 对话请求的完整地址。
  ///
  /// [LlmConfig.fullUrl] 为真时 Base URL 就是完整地址，不再拼路径 ——
  /// 用于把请求打到自定义路径的网关。
  static String chatUrl(LlmConfig config) => config.fullUrl
      ? config.baseUrl.trim()
      : '${_trim(config.baseUrl.trim())}/chat/completions';

  /// 从「完整 URL」里推出可复用的根路径。
  ///
  /// ⚠️ 不能只砍最后一段路径：`https://host/v1/chat/completions` 砍一段
  /// 得到 `https://host/v1/chat`，再拼 `/embeddings` 就成了
  /// `https://host/v1/chat/embeddings`（实测确认是错的）。
  /// 端点后缀是两段（`chat/completions`），必须整体识别。
  static String _rootOf(String baseUrl) {
    final b = _trim(baseUrl.trim());
    // 已知的对话端点后缀，按长度从长到短匹配
    for (final suffix in const [
      '/chat/completions',
      '/completions',
      '/chat',
    ]) {
      if (b.endsWith(suffix)) {
        return b.substring(0, b.length - suffix.length);
      }
    }
    // 认不出来就退化为「去掉最后一段」，至少不会拼出更长的怪路径
    final i = b.lastIndexOf('/');
    return i <= 'https://'.length ? b : b.substring(0, i);
  }

  /// 向量请求地址。同样是完整 URL 模式下不拼路径。
  static String embeddingUrl(LlmConfig config) => config.fullUrl
      ? '${_rootOf(config.baseUrl)}/embeddings'
      : '${_trim(config.baseUrl.trim())}/embeddings';

  /// 模型列表接口地址（用于「拉取模型」）。
  static String modelsUrl(LlmConfig config) => config.fullUrl
      ? '${_rootOf(config.baseUrl)}/models'
      : '${_trim(config.baseUrl.trim())}/models';

  /// 组装请求头。[apiKey] 单独传入是为了支持多 Key 轮换。
  Map<String, String> _headers(LlmConfig config, String apiKey) => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        HttpHeaders.userAgentHeader:
            config.userAgent.trim().isEmpty
                ? defaultUserAgent
                : config.userAgent.trim(),
      };

  /// 本轮使用的模型参数：优先取当前聊天模型的设置。
  static ProviderModel? _activeModel(LlmConfig c) => c.chatModel;

  // ---------------------------------------------------------------- 对话

  /// 发起一轮流式对话。
  ///
  /// 多 Key 模式下，若某个 Key 在**产出任何内容之前**就失败，
  /// 会自动换下一个 Key 重发。已经吐过字再重试会导致内容重复，
  /// 所以那种情况直接抛错。
  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',
  }) async* {
    final keys = config.effectiveKeys;
    if (keys.isEmpty) {
      throw Exception('未配置 API Key');
    }
    for (var i = 0; i < keys.length; i++) {
      var yieldedAnything = false;
      try {
        await for (final ev in _chatStreamOnce(
          config: config,
          apiKey: keys[i],
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
        )) {
          yieldedAnything = true;
          yield ev;
        }
        return;
      } catch (e) {
        final canRetry = !yieldedAnything &&
            i < keys.length - 1 &&
            isKeyFailure(e);
        if (!canRetry) rethrow;
        debugPrint('第 ${i + 1} 个 Key 不可用（$e），自动切换到下一个');
      }
    }
  }

  /// 判断异常是否属于「这个 Key 不行，换一个可能行」。
  ///
  /// 只认鉴权/额度类状态码。5xx 换 Key 没有意义（是服务端问题），
  /// 超时同样不换（换 Key 也一样超时）。
  static bool isKeyFailure(Object e) {
    if (e is! DioException) return false;
    final code = e.response?.statusCode;
    if (code == 401 || code == 402 || code == 403 || code == 429) return true;
    return false;
  }

  Stream<LlmEvent> _chatStreamOnce({
    required LlmConfig config,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',
  }) async* {
    final url = chatUrl(config);
    final m = _activeModel(config);
    final temperature = m?.temperature ?? 0.7;

    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'temperature': temperature,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      // 思考开关。reasoning_effort 是 OpenAI 推理模型的参数，
      // glm / qwen 等网关也接受同名字段。不开就不下发——
      // 部分服务见到未知参数会直接返回 400。
      if (thinking) 'reasoning_effort': reasoningEffort,
      // 配置里显式填了最大输出才下发，避免覆盖服务端默认值。
      if ((m?.maxOutputTokens ?? 0) > 0) 'max_tokens': m!.maxOutputTokens,
      // 提示词缓存键：让服务端把相同前缀的请求命中缓存，降低首 token 延迟
      // 与费用（OpenAI / 部分兼容网关支持）。
      if (config.promptCacheKey) 'prompt_cache_key': _cacheKeyOf(config),
    };

    final resp = await _dioFor(config).post<ResponseBody>(
      url,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: _headers(config, apiKey),
      ),
    );

    final contentBuf = StringBuffer();
    // 思考过程累积：FinalMessage 带给 Agent 层，随回答一起落库展示。
    final reasoningBuf = StringBuffer();
    final toolAcc = <int, _ToolCallAcc>{};

    // 本轮累积到的 usage。流式里它只在最后一帧出现，
    // 用可空变量收集，循环结束后统一 yield。
    TokenUsage? usage;

    // 服务端返回空响应体（代理拦截、204、网关返回空）时 resp.data 为 null，
    // 原来的 resp.data! 会直接抛空指针。这里改为给出明确错误。
    final body0 = resp.data;
    if (body0 == null) {
      throw Exception('模型服务返回空响应体（HTTP ${resp.statusCode}）');
    }

    final lines = body0.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    // SSE 是长连接：服务端建立连接后若不再写入也不关闭（代理挂起、云函数缩容、
    // keep-alive 复用），await for 会永久阻塞，界面卡在"生成中"。
    // Dio 的 receiveTimeout 在流式场景不生效（响应头已到达，计时器停止），
    // 因此这里显式加单行空闲超时。
    const idle = Duration(seconds: 60);

    await for (final line in lines.timeout(
      idle,
      onTimeout: (sink) => sink.addError(
        Exception('模型响应超时（连续 $idle 秒未收到任何数据）'),
      ),
    )) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') break;

      final Object? decoded;
      try {
        decoded = jsonDecode(data);
      } catch (_) {
        continue; // 跳过无法解析的行
      }
      // 网关有时返回 {"error": {...}} 之类结构，这里逐层做类型收敛而不是强转。
      if (decoded is! Map) continue;
      final json = decoded.cast<String, dynamic>();

      // usage 在**顶层**，不在 choices 里。流式协议有两种下发方式：
      //   1) 最后一个带 content 的 chunk 里带 usage
      //   2) 额外发一个 choices: [] 的空帧专门携带 usage
      // 所以必须在 `rawChoices` 判空**之前**取。
      //
      // 不加 `usage == null` 守卫：部分网关每帧都下发累计 usage，
      // 只有最后一帧是完整值。取最后一次才是对的。
      final rawUsage = json['usage'];
      if (rawUsage is Map) {
        final u = rawUsage.cast<String, dynamic>();
        final prompt = (u['prompt_tokens'] as num?)?.toInt() ?? 0;
        final completion = (u['completion_tokens'] as num?)?.toInt() ?? 0;
        var cached = 0;
        final details = u['prompt_tokens_details'];
        if (details is Map) {
          cached =
              (details.cast<String, dynamic>()['cached_tokens'] as num?)
                      ?.toInt() ??
                  0;
        }
        // 有些网关用 input_tokens / output_tokens（Anthropic 风格别名）
        if (prompt == 0) {
          cached = (u['cache_read_input_tokens'] as num?)?.toInt() ?? cached;
        }
        final effPrompt =
            prompt != 0 ? prompt : ((u['input_tokens'] as num?)?.toInt() ?? 0);
        final effCompletion = completion != 0
            ? completion
            : ((u['output_tokens'] as num?)?.toInt() ?? 0);
        if (effPrompt > 0 || effCompletion > 0) {
          usage = TokenUsage(
            promptTokens: effPrompt,
            completionTokens: effCompletion,
            cachedTokens: cached,
          );
        }
      }

      final Object? rawChoices = json['choices'];
      if (rawChoices is! List || rawChoices.isEmpty) continue;
      final Object? rawChoice = rawChoices.first;
      if (rawChoice is! Map) continue;
      final choice = rawChoice.cast<String, dynamic>();

      final Object? rawDelta = choice['delta'];
      final delta = rawDelta is Map
          ? rawDelta.cast<String, dynamic>()
          : const <String, dynamic>{};

      final c = delta['content'];
      if (c is String && c.isNotEmpty) {
        contentBuf.write(c);
        yield ContentDelta(c);
      }

      // 思考过程：DeepSeek 系字段是 reasoning_content，OpenRouter 系是
      // reasoning。两者取其一（并存时拼接会导致内容重复，实际上不会并存）。
      final rc = delta['reasoning_content'] ?? delta['reasoning'];
      if (rc is String && rc.isNotEmpty) {
        reasoningBuf.write(rc);
        yield ReasoningDelta(rc);
      }

      final Object? rawTcs = delta['tool_calls'];
      if (rawTcs is List) {
        for (final tc in rawTcs) {
          if (tc is! Map) continue;
          final tcm = tc.cast<String, dynamic>();
          // index 缺失时退化为"按到达顺序追加"，避免并行 tool_call 全被并进同一个累加器。
          final idx = (tcm['index'] as num?)?.toInt() ?? toolAcc.length;
          final acc = toolAcc.putIfAbsent(idx, () => _ToolCallAcc());
          final id = tcm['id'];
          if (id is String &&
              id.isNotEmpty &&
              (acc.id == null || acc.id!.isEmpty)) {
            acc.id = id;
          }
          final Object? fn = tcm['function'];
          if (fn is Map) {
            final f = fn.cast<String, dynamic>();
            final n = f['name'];
            if (n is String && n.isNotEmpty) {
              // 增量分片是主流行为，但部分网关会在每个 chunk 重复下发完整
              // name。若无条件拼接会得到 web_searchweb_search...，工具查找
              // 必然失败。两种行为都兼容：完全相同→忽略，是真前缀→忽略。
              final cur = acc.name;
              if (cur == null || cur.isEmpty) {
                acc.name = n;
              } else if (cur != n && !n.startsWith(cur)) {
                acc.name = cur + n;
              }
            }
            final a = f['arguments'];
            if (a is String) acc.arguments.write(a);
          }
        }
      }
    }

    final entries = toolAcc.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final finalMsg = ChatMessage(
      id: 'asst_${DateTime.now().millisecondsSinceEpoch}',
      role: 'assistant',
      content: contentBuf.toString(),
      reasoning: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
      toolCalls: entries
          .map((e) => ToolCall(
                id: e.value.id ?? 'call_${e.key}',
                name: e.value.name ?? '',
                arguments: e.value.arguments.toString(),
              ))
          .toList(),
    );
    yield FinalMessage(finalMsg);
    // usage 放在最后：Agent 循环先处理消息再记账，顺序稳定。
    if (usage != null && !usage.isEmpty) yield usage;
  }

  /// 提示词缓存键。同一提供商下保持稳定，才能让服务端命中缓存。
  ///
  /// 用 id + 模型名派生：换模型要换缓存域（不同模型的缓存不通用），
  /// 但同一模型下多次请求必须一致。
  static String _cacheKeyOf(LlmConfig c) {
    final raw = '${c.id}:${c.model}';
    var h = 0;
    for (final unit in raw.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return 'orion_${h.toRadixString(16)}';
  }

  // ------------------------------------------------------------ 模型列表

  /// 拉取该提供商可用的模型名列表（`GET /models`）。
  ///
  /// 返回去重后的模型名，按字母序排序，便于界面上稳定展示。
  Future<List<String>> listModels({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async {
    final keys = config.effectiveKeys;
    if (keys.isEmpty) throw Exception('未配置 API Key');
    final url = modelsUrl(config);

    DioException? lastAuthError;
    for (final key in keys) {
      try {
        final resp = await _dioFor(config).get<Map<String, dynamic>>(
          url,
          cancelToken: cancelToken,
          options: Options(headers: _headers(config, key)),
        );
        final data = resp.data?['data'];
        if (data is! List) {
          throw Exception('返回结构异常（缺少 data 数组），'
              '该服务可能不支持 /models 接口');
        }
        final names = <String>{};
        for (final item in data) {
          if (item is String) {
            if (item.trim().isNotEmpty) names.add(item.trim());
            continue;
          }
          if (item is! Map) continue;
          final id = item.cast<String, dynamic>()['id'];
          if (id is String && id.trim().isNotEmpty) names.add(id.trim());
        }
        if (names.isEmpty) throw Exception('该服务未返回任何模型');
        return names.toList()..sort();
      } on DioException catch (e) {
        // 多 Key 模式下换下一个 Key 再试
        if (isKeyFailure(e) && key != keys.last) {
          lastAuthError = e;
          continue;
        }
        rethrow;
      }
    }
    throw lastAuthError ?? Exception('拉取模型失败');
  }

  /// 连通性自检：请求 `/models`，把结果整理成一行可读结论。
  ///
  /// 「测试运行」按钮用它 —— 用户配完一堆参数后最需要知道的就是
  /// 「这套配置到底能不能用」，而不是自己发一条消息去撞运气。
  Future<String> testConnection({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async {
    final sw = Stopwatch()..start();
    final models = await listModels(config: config, cancelToken: cancelToken);
    final ms = sw.elapsedMilliseconds;
    final hasChat = config.chatModels.isNotEmpty;
    final hasEmb = config.embeddingModels.isNotEmpty;
    final buf = StringBuffer()
      ..writeln('连接成功（${ms}ms）')
      ..writeln('地址：${modelsUrl(config)}')
      ..writeln('可用模型：${models.length} 个');
    if (models.length <= 8) {
      buf.writeln(models.join('、'));
    } else {
      buf.writeln('${models.take(8).join('、')} 等');
    }
    if (!hasChat) {
      buf.writeln('\n⚠️ 尚未添加聊天模型，无法对话。');
    } else if (!models.contains(config.model)) {
      buf.writeln('\n⚠️ 当前聊天模型「${config.model}」不在服务端返回的列表里，'
          '可能是名称写错或该模型未开放。');
    }
    if (hasEmb && !models.contains(config.embeddingModelName)) {
      buf.writeln('⚠️ 向量模型「${config.embeddingModelName}」不在返回列表里。');
    }
    return buf.toString().trimRight();
  }

  // -------------------------------------------------------------- 向量

  /// 批量调用 OpenAI 兼容的 /embeddings 接口，返回与输入顺序一致的向量列表。
  Future<List<List<double>>> embedBatch({
    required LlmConfig config,
    required List<String> inputs,
    CancelToken? cancelToken,
  }) async {
    final modelName = config.embeddingModelName;
    if (modelName.trim().isEmpty) {
      throw Exception('未配置向量模型（提供商 → 模型 → 添加向量模型）');
    }
    final keys = config.effectiveKeys;
    if (keys.isEmpty) throw Exception('未配置 API Key');

    DioException? lastAuthError;
    late Response<Map<String, dynamic>> resp;
    for (final key in keys) {
      try {
        resp = await _dioFor(config).post<Map<String, dynamic>>(
          embeddingUrl(config),
          data: {'model': modelName, 'input': inputs},
          cancelToken: cancelToken,
          options: Options(headers: _headers(config, key)),
        );
        break;
      } on DioException catch (e) {
        if (isKeyFailure(e) && key != keys.last) {
          lastAuthError = e;
          continue;
        }
        rethrow;
      }
    }
    if (resp.data == null) {
      throw lastAuthError ?? Exception('Embedding 请求失败');
    }

    final data = resp.data!['data'];
    if (data is! List) {
      throw Exception('Embedding 接口返回结构异常（缺少 data 数组），请确认该服务支持 /embeddings');
    }
    // 按 index 显式对齐：某些网关返回顺序不保证与请求一致，
    // 若按到达顺序建表会让「分块 i」写入「分块 j 的向量」而永久错位。
    final slots = <int, List<double>>{};
    var anyIndex = false;
    for (final item in data) {
      if (item is! Map) continue;
      final m = item.cast<String, dynamic>();
      final idx = (m['index'] as num?)?.toInt();
      if (idx == null) continue;
      anyIndex = true;
      final rawVec = m['embedding'];
      if (rawVec is! List) continue;
      final vec = rawVec.whereType<num>().map((e) => e.toDouble()).toList();
      // 空向量会让余弦相似度恒为 0，等于往知识库里塞入一条永远检索不到、
      // 又会在 search 里触发维度不匹配的数据，直接丢弃。
      if (vec.isEmpty) continue;
      slots[idx] = vec;
    }
    // 少数服务不返回 index 字段，此时按响应顺序对应（OpenAI 规范要求 index，
    // 但不能因此直接判失败）。仅当一条都没带 index 时才退回顺序对齐。
    if (!anyIndex) {
      final vecs = <List<double>>[];
      for (final item in data) {
        if (item is! Map) continue;
        final rawVec = item.cast<String, dynamic>()['embedding'];
        if (rawVec is! List) continue;
        final vec = rawVec.whereType<num>().map((e) => e.toDouble()).toList();
        if (vec.isEmpty) continue;
        vecs.add(vec);
      }
      if (vecs.length != inputs.length) {
        throw Exception(
          'Embedding 返回 ${vecs.length} 条有效向量，与请求的 ${inputs.length} 条不符',
        );
      }
      _checkDims(vecs);
      return vecs;
    }

    if (slots.length != inputs.length) {
      throw Exception(
        'Embedding 返回 ${slots.length} 条有效向量，与请求的 ${inputs.length} 条不符',
      );
    }
    _checkDims(slots.values);
    final ordered = List<List<double>>.filled(inputs.length, const <double>[]);
    slots.forEach((i, v) => ordered[i] = v);
    return ordered;
  }

  /// 维度必须处处一致且非空，否则余弦相似度恒为 0，检索形同虚设。
  static void _checkDims(Iterable<List<double>> vectors) {
    final dims = vectors.map((e) => e.length).toSet();
    if (dims.length != 1 || dims.first == 0) {
      throw Exception('Embedding 返回了不一致或为空的向量维度：$dims');
    }
  }
}
