import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

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

/// 一轮响应结束后的完整 assistant 消息（可能携带工具调用）。
class FinalMessage extends LlmEvent {
  final ChatMessage message;
  const FinalMessage(this.message);
}

class _ToolCallAcc {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

/// OpenAI 兼容协议的流式客户端（SSE）。
class LlmClient {
  LlmClient(this._dio);

  final Dio _dio;

  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
  }) async* {
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    final url = '$base/chat/completions';

    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'temperature': config.temperature,
      'stream': true,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
    };

    final resp = await _dio.post<ResponseBody>(
      url,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
      ),
    );

    final contentBuf = StringBuffer();
    final toolAcc = <int, _ToolCallAcc>{};

    // 服务端返回空响应体（代理拦截、204、网关返回空）时 resp.data 为 null，
    // 原来的 resp.data! 会直接抛空指针。这里改为给出明确错误。
    //
    // 必须显式转型为 ResponseBody：resp.data 是 dynamic，不收窄的话
    // analyzer 会把它当成 Dio 的内部实现类型，随后 body.close() 报
    // invalid_use_of_internal_member（warning，升级易炸）。
    // 也因此不能用三元表达式——其静态类型会退化成 Object。
    final raw = resp.data;
    if (raw == null) {
      throw Exception('模型服务返回空响应体（HTTP ${resp.statusCode}）');
    }
    final ResponseBody body0;
    if (raw is ResponseBody) {
      body0 = raw;
    } else {
      // 非流式响应（例如拦截器把 body 转成了 Map）：包一层再按行解析，
      // 保证下游只有一条代码路径。
      body0 = ResponseBody.fromString(
        jsonEncode(raw),
        resp.statusCode ?? 200,
        headers: const {},
      );
    }

    final lines = body0.stream.cast<List<int>>().transform(utf8.decoder).transform(
          const LineSplitter(),
        );

    // SSE 是长连接：服务端建立连接后若不再写入也不关闭（代理挂起、云函数缩容、
    // keep-alive 复用），await for 会永久阻塞，界面卡在"生成中"。
    // Dio 的 receiveTimeout 在流式场景不生效（响应头已到达，计时器停止），
    // 因此这里显式加单行空闲超时。
    const idle = Duration(seconds: 60);

    try {
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
        // 原来的 `as Map<String, dynamic>` 在 delta 是 String 时抛 TypeError，
        // 异常从 async* 抛出后响应体未被关闭，反复触发会耗尽连接池。
        if (decoded is! Map) continue;
        final json = decoded.cast<String, dynamic>();

        final Object? rawChoices = json['choices'];
        if (rawChoices is! List || rawChoices.isEmpty) continue;
        final Object? rawChoice = rawChoices.first;
        if (rawChoice is! Map) continue;
        final choice = rawChoice.cast<String, dynamic>();

        final Object? rawDelta = choice['delta'];
        final delta = rawDelta is Map ? rawDelta.cast<String, dynamic>() : const <String, dynamic>{};

        final c = delta['content'];
        if (c is String && c.isNotEmpty) {
          contentBuf.write(c);
          yield ContentDelta(c);
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
            if (id is String && id.isNotEmpty && (acc.id == null || acc.id!.isEmpty)) {
              acc.id = id;
            }
            final Object? fn = tcm['function'];
            if (fn is Map) {
              final f = fn.cast<String, dynamic>();
              final n = f['name'];
              if (n is String && n.isNotEmpty) {
                // 增量分片是主流行为（arguments 同理），但部分网关会在每个 chunk
                // 重复下发完整 name。若无条件拼接会得到 web_searchweb_search...，
                // 工具查找必然失败。两种行为都兼容：完全相同→忽略，是真前缀→忽略。
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
    } finally {
      // 异常路径（超时/解析错误/调用方提前 break）下必须关闭响应体，
      // 否则底层连接不释放，多次触发后连接池耗尽、后续请求全部超时。
      body0.close();
    }

    final entries = toolAcc.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final finalMsg = ChatMessage(
      id: 'asst_${DateTime.now().millisecondsSinceEpoch}',
      role: 'assistant',
      content: contentBuf.toString(),
      toolCalls: entries
          .map((e) => ToolCall(
                id: e.value.id ?? 'call_${e.key}',
                name: e.value.name ?? '',
                arguments: e.value.arguments.toString(),
              ))
          .toList(),
    );
    yield FinalMessage(finalMsg);
  }

  /// 批量调用 OpenAI 兼容的 /embeddings 接口，返回与输入顺序一致的向量列表。
  Future<List<List<double>>> embedBatch({
    required LlmConfig config,
    required List<String> inputs,
    CancelToken? cancelToken,
  }) async {
    if (config.embeddingModel.trim().isEmpty) {
      throw Exception('未配置 Embedding 模型（设置 → 模型服务 → Embedding 模型名）');
    }
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;

    final resp = await _dio.post<Map<String, dynamic>>(
      '$base/embeddings',
      data: {'model': config.embeddingModel, 'input': inputs},
      cancelToken: cancelToken,
      options: Options(headers: {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      }),
    );

    final data = resp.data?['data'];
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
    final List<List<double>> ordered =
        List<List<double>>.filled(inputs.length, const <double>[]);
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
    ordered = List<List<double>>.filled(inputs.length, const <double>[]);
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
