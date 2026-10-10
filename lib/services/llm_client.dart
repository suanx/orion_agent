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

/// 云端额度变化（本轮请求后服务端扣减了多少）。
///
/// 只在云端模型（[cloudModelId] 非空）时下发：后端在响应头里带
/// `x-orion-quota-used/limit`，对话结束后据此就地更新额度卡片，
/// 免得用户还要手动刷新账号页才知道这轮花了多少。
class QuotaUsed extends LlmEvent {
  final int used;
  final int limit;

  const QuotaUsed({required this.used, required this.limit});

  int get remaining => (limit - used).clamp(0, limit);
}

/// 云端 Agent 长任务降级信号（2026-10-11 长任务异步化）。
///
/// 中继在 EdgeOne 120s 平台上限前（105s）主动关流时会下发这一帧：
/// 任务**没有被取消**，只是这条流到点了。App 应改为轮询
/// `GET /agent/tasks/{taskId}/status?from=N` 把剩余输出接完。
///
/// [from] 是中继已消费的 forge chunk 数，正好是轮询的起始游标——带上它
/// 才不会把已经显示过的内容再取一遍。
class TaskFallback extends LlmEvent {
  final String taskId;
  final int from;
  const TaskFallback({required this.taskId, required this.from});
}

/// 一次任务轮询的结果。
class AgentTaskPoll {
  /// running | done | failed | stopped
  final String status;
  /// forge 已产出的 chunk 总数，即下一次轮询的游标。
  final int total;
  /// 本次新增的增量（元素形如 {'content': '...'} / {'reasoning_content': '...'}）。
  final List<Map<String, dynamic>> deltas;

  const AgentTaskPoll({
    required this.status,
    required this.total,
    required this.deltas,
  });

  bool get isRunning => status == 'running';
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
  LlmClient(this._defaultDio, {this.cloudTokenProvider});

  /// 无代理时复用的 Dio（绝大多数请求走这里，不必每次新建连接池）。
  final Dio _defaultDio;

  /// 云端模型的登录令牌提供器（由外部注入，避免本类依赖 CloudService）。
  ///
  /// 云端配置（[CloudModelService.isCloud]）的鉴权不是配置里的 Key，而是
  /// 用户的云端登录令牌——由后端解密上游 Key 并转发。没有令牌时云端请求
  /// 无法完成鉴权，此时会给出明确报错而不是拿占位串去撞 401。
  final Future<String?> Function()? cloudTokenProvider;

  /// 按「代理 + UA」组合缓存的 Dio：同一组合的所有请求复用同一个连接池。
  ///
  /// UA 的隔离也靠这个 key 完成 —— 临时改 UA 会写到 Dio 的默认 header 上，
  /// 而 Dio 是共享实例，所以带自定义 UA 的组合必须各自持有独立实例，
  /// 否则会污染走默认 UA 的请求。
  final _proxyDioCache = <String, Dio>{};

  /// 上述缓存的容量上限：超过后关闭并移除最早创建的条目，防止
  /// 用户反复更换代理/UA 组合导致 Dio（连接池）无界增长。
  static const _proxyDioCacheLimit = 16;

  /// 从 SSE error 帧里提取人类可读的错误描述。
  /// 兼容常见形态：纯字符串、{message}、{error:{message}}、{Message} 等。
  static String _describeSseError(Object raw) {
    if (raw is String) return raw;
    if (raw is Map) {
      final err = raw['error'];
      if (err is Map) {
        final m = err['message'] ?? err['msg'] ?? err['Message'];
        if (m != null) return m.toString();
      }
      final direct =
          raw['message'] ?? raw['msg'] ?? raw['Message'] ?? raw['code'];
      if (direct != null) return direct.toString();
    }
    return raw.toString();
  }

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
    // LinkedHashMap 保持插入序，keys.first 即最早创建的条目。
    while (_proxyDioCache.length >= _proxyDioCacheLimit) {
      final oldestKey = _proxyDioCache.keys.first;
      _proxyDioCache.remove(oldestKey)?.close(force: true);
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
  ///
  /// 云端配置（[cloudModelId] 非空）例外：真正的鉴权凭据是云端登录令牌，
  /// 由 [cloudTokenProvider] 异步取得后覆盖 Authorization —— 配置里那个
  /// 占位 Key 只是为了通过「Key 不能为空」的校验。
  Future<Map<String, String>> _headers(
    LlmConfig config,
    String apiKey,
  ) async {
    var bearer = apiKey;
    if (_isCloud(config)) {
      final token = await cloudTokenProvider?.call();
      if (token == null || token.isEmpty) {
        throw Exception('云端模型需要先登录云端账号');
      }
      bearer = token;
    }
    return {
      'Authorization': 'Bearer $bearer',
      'Content-Type': 'application/json',
      HttpHeaders.userAgentHeader:
          config.userAgent.trim().isEmpty
              ? defaultUserAgent
              : config.userAgent.trim(),
    };
  }

  /// 判断配置是否为云端托管模型。
  ///
  /// 判定用「配置 id 带 `cloud:` / `agent:` 前缀」，而不是嗅探 baseUrl 是否
  /// 指向自家后端——后者在用户自建指向同一域名的配置时会误判。
  static bool _isCloud(LlmConfig c) =>
      c.id.startsWith('cloud:') || c.id.startsWith('agent:');

  /// 是否为云端 Agent 配置（鉴权与云端模型同源，但请求体多一个 appSessionId）。
  static bool _isAgent(LlmConfig c) => c.id.startsWith('agent:');

  /// 当前对话的 App 会话 id（仅云端 Agent 请求需要）。
  ///
  /// Agent 侧每次对话必须绑定会话，后端靠它维持远端 session/chat 映射。
  ///
  /// ⚠️ 仅作未传参调用的兜底：并行对话下多个 send 会互相覆盖这个静态值，
  /// 主通道是 [chatStream] 的 `agentSessionId` 参数（由调用方按会话传入）。
  static String? agentSessionId;

  /// 本轮使用的模型参数：优先取当前聊天模型的设置。
  static ProviderModel? _activeModel(LlmConfig c) => c.chatModel;

  // ---------------------------------------------------------------- 对话

  /// 发起一轮流式对话。
  ///
  /// 两层自动恢复（只作用于**首个 token 产出之前**，已吐字后重发会
  /// 内容重复，一律直接抛错）：
  ///   1. 临时性网络/服务端故障（连接超时、流中断、5xx、429）→
  ///      原地退避重试最多 2 次（429 退避更长，给限流恢复窗口）；
  ///   2. 鉴权/额度类失败（401/402/403/429）→ 换下一个 Key 重发。
  ///
  /// 移动网络下首包前失败是常态，桌面端工具普遍内建这层重试——
  /// 之前没有它，「同样的 API 配置其他工具不断、本应用常断」。
  Stream<LlmEvent> chatStream({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',

    /// 本轮绑定的 App 会话 id（云端 Agent 用）。并行对话时各自传各自的，
    /// 不能依赖静态字段——它会被并发的另一次 send 覆盖导致串号。
    String? agentSessionId,
  }) async* {
    final keys = config.effectiveKeys;
    if (keys.isEmpty) {
      throw Exception('未配置 API Key');
    }
    const maxNetworkRetries = 2;
    for (var i = 0; i < keys.length; i++) {
      var yieldedAnything = false;
      var networkRetries = 0;
      while (true) {
        try {
          await for (final ev in _chatStreamOnce(
            config: config,
            apiKey: keys[i],
            messages: messages,
            tools: tools,
            cancelToken: cancelToken,
            thinking: thinking,
            reasoningEffort: reasoningEffort,
            agentSessionId: agentSessionId,
          )) {
            yieldedAnything = true;
            yield ev;
          }
          return;
        } catch (e) {
          if (yieldedAnything) rethrow;
          if (i < keys.length - 1 && isKeyFailure(e)) {
            debugPrint('第 ${i + 1} 个 Key 不可用（$e），自动切换到下一个');
            break;
          }
          final canRetry = networkRetries < maxNetworkRetries &&
              !(cancelToken?.isCancelled ?? false) &&
              isTransientFailure(e);
          if (!canRetry) rethrow;
          networkRetries++;
          // 退避 2s/4s；429 是限流，给更长的恢复窗口
          final isRateLimit = e is DioException && e.response?.statusCode == 429;
          final backoff =
              Duration(seconds: (isRateLimit ? 5 : 2) * networkRetries);
          debugPrint('chatStream 网络故障（$e），${backoff.inSeconds}s 后第 '
              '$networkRetries/$maxNetworkRetries 次重试');
          await Future<void>.delayed(backoff);
        }
      }
    }
  }

  /// 判断异常是否属于「Key 不行，换一个可能行」。
  ///
  /// 只认鉴权/额度类状态码。5xx 换 Key 没有意义（是服务端问题），
  /// 超时同样不换（换 Key 也一样超时）。
  static bool isKeyFailure(Object e) {
    if (e is! DioException) return false;
    final code = e.response?.statusCode;
    if (code == 401 || code == 402 || code == 403 || code == 429) return true;
    return false;
  }

  /// 判断异常是否属于「临时性故障，等一下原地重试可能就好」。
  ///
  /// 与 [isKeyFailure] 互补：那个管「换 Key 是否有意义」，这个管
  /// 「原地重试是否有意义」。覆盖：连接建立/发送/接收超时、连接被
  /// 重置（基站切换、NAT 超时、代理断开）、5xx、429、socket 级错误，
  /// 以及 SSE 空闲超时（本类抛的普通 Exception，非 DioException）。
  /// 用户取消（cancel）、证书错误、4xx 参数错误不在其列。
  /// 传 null（无异常）返回 false。
  static bool isTransientFailure(Object? e) {
    if (e == null) return false;
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode ?? 0;
          return code >= 500 || code == 429;
        default:
          // cancel / badCertificate 不重试；unknown 要解包看真实原因——
          // Dio 会把底层 socket 错误包成 type=unknown、response=null，
          // 真实异常在 e.error 里（2026-10-10 实测：EdgeOne 关闭空闲
          // keep-alive 连接后，App 复用死 socket 立即失败，表现为
          // 「请求失败（HTTP null）」且完全不重试。前几条成功、之后
          // 秒失败的间歇性正是连接复用撞上边缘节点回收的典型形态）。
          if (e.type == DioExceptionType.cancel ||
              e.type == DioExceptionType.badCertificate) {
            return false;
          }
          return isTransientFailure(e.error);
      }
    }
    if (e is SocketException) return true;
    // dart:io HttpException：socket 级断连在 Android 上常以 HttpException
    // 形态抛出（2026-10-10 实测：EdgeOne 边缘把 SSE 连接中途切断时抛
    // "HttpException: Connection closed while receiving data"）。之前只认
    // SocketException，这条被判为「不可重试」直接报错给用户。原地重试对
    // 「还没吐字就被断」的场景是安全的（已吐字的内容上层会 rethrow 不重试）。
    if (e is HttpException) return true;
    return e.toString().contains('模型响应超时') ||
        // 兜底：部分厂商 SDK 包装过的异常会丢失类型，只留消息文本
        e.toString().contains('Connection closed');
  }

  Stream<LlmEvent> _chatStreamOnce({
    required LlmConfig config,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    bool thinking = false,
    String reasoningEffort = 'medium',
    String? agentSessionId,
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

    // 云端 Agent：额外带上 App 会话 id，后端据此维持远端 session/chat
    // 映射（Agent 侧每次对话都必须绑定会话）。
    if (_isAgent(config)) {
      // 参数优先（并行对话各自持有正确会话 id），静态字段仅作兜底。
      final sid = agentSessionId ?? LlmClient.agentSessionId;
      if (sid != null && sid.isNotEmpty) body['appSessionId'] = sid;
      // 透传 modelId：让用户在 App 里选中的模型真正生效。
      //
      // ⚠️ 不能下发 model 字段：Agent 侧的真实模型由用户实例自己的
      // provider 配置决定，App 的 `agent` 只是虚拟名。body['model'] 会被
      // llm_client 早先填成这个虚拟名，若一并转发，上游可能拿它去查一个
      // 不存在的模型。modelId 是我们与后端约定的独立字段，由后端转交
      // 实例的 modelId，语义上不污染 OpenAI 兼容协议。
      final wanted = (m?.name ?? '').trim();
      if (wanted.isNotEmpty && wanted != 'agent') body['modelId'] = wanted;
      // Agent 自行决定用哪个模型与参数，透传 temperature/tools 反而可能
      // 让上游网关因不认识的字段报错，因此这里不发。
      body.remove('temperature');
      body.remove('tools');
    }

    final resp = await _dioFor(config).post<ResponseBody>(
      url,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: await _headers(config, apiKey),
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
    //
    // 180s 而不是更激进的 60s：思考型模型（深推理不开流式思考、长上下文
    // 无缓存命中的首 token 处理）静默期普遍在 1~3 分钟，60s 会把正常的
    // 深度推理误杀成「响应超时」——表现为长任务跑着跑着就断。
    const idle = Duration(seconds: 180);

    // 长任务降级信号：非空表示本条流被中继在 105s 处主动截断（任务仍在
    // forge 侧运行），本轮改由轮询路径续完。
    TaskFallback? taskFallback;

    await for (final line in lines.timeout(
      idle,
      onTimeout: (sink) => sink.addError(
        Exception('模型响应超时（连续 ${idle.inSeconds} 秒未收到任何数据）'),
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

      // one-api / new-api 类网关在限流、余额不足时会在流里下发
      // {"error": {...}} 帧（HTTP 状态仍是 200），原实现直接 continue 跳过，
      // 最终产出空内容被当正常回答。这里解析出服务端错误信息并抛出。
      // 抛出点位于任何内容 yield 之前（错误帧是网关在首 token 前下发的），
      // 处于 chatStream 多 Key 重试的 try 范围内，可自然参与其重试语义；
      // 若在已吐字后才出现错误帧，则沿用「不重试、直接抛」的原有行为。
      final rawError = json['error'];
      if (rawError != null) {
        throw Exception('模型服务返回错误：${_describeSseError(rawError)}');
      }

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

      // 长任务降级信号（2026-10-11）：中继抢在 EdgeOne 120s 平台强杀前
      // 主动关流，并告知「任务还在跑，改轮询接着取」。此时本条流到此为止，
      // 不发 FinalMessage——内容还没完，最终消息由轮询路径产出。
      final Object? rawFallback = delta['task_fallback'];
      if (rawFallback is Map) {
        final fb = rawFallback.cast<String, dynamic>();
        final tid = fb['taskId'];
        if (tid is String && tid.isNotEmpty) {
          taskFallback = TaskFallback(
            taskId: tid,
            from: (fb['from'] as num?)?.toInt() ?? 0,
          );
          break;
        }
      }

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

    // 降级：本条流只是「到点了」，不是结束。把 taskId 与游标交给上层，
    // 由 resumeAgentTask 轮询续完；这里绝不能发 FinalMessage——内容是
    // 残缺的，发了会被当成完整回答落库。
    if (taskFallback != null) {
      yield taskFallback!;
      if (_isCloud(config)) {
        final q = _quotaFromHeaders(resp);
        if (q != null) yield q;
      }
      return;
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
    // 云端模型：把本轮消耗的额度带回，调用方可就地更新额度卡片
    if (_isCloud(config)) {
      final q = _quotaFromHeaders(resp);
      if (q != null) yield q;
    }
  }

  /// 从响应头读云端额度（本轮请求后服务端扣减了多少）。
  static QuotaUsed? _quotaFromHeaders(Response<dynamic> resp) {
    final used = int.tryParse(resp.headers.value('x-orion-quota-used') ?? '');
    final limit = int.tryParse(resp.headers.value('x-orion-quota-limit') ?? '');
    if (used == null || limit == null || limit <= 0) return null;
    return QuotaUsed(used: used, limit: limit);
  }

  /// 云端 Agent 异步任务端点基址：`.../agent/chat` → `.../agent/tasks`。
  static String _agentTaskBase(LlmConfig config) {
    final chat = chatUrl(config);
    final i = chat.lastIndexOf('/chat');
    return i > 0 ? '${chat.substring(0, i)}/tasks' : '${_trim(chat)}/tasks';
  }

  /// 轮询一次云端 Agent 任务的增量输出。
  ///
  /// 长任务异步化（2026-10-11）：中继把长任务拆成「提交即返回 + 带游标
  /// 轮询」，本方法对应后者。返回已转换好的 delta（content /
  /// reasoning_content），与流式路径完全同构。
  Future<AgentTaskPoll> pollAgentTask({
    required LlmConfig config,
    required String taskId,
    int from = 0,
    CancelToken? cancelToken,
  }) async {
    final resp = await _dioFor(config).get<Map<String, dynamic>>(
      '${_agentTaskBase(config)}/$taskId/status?from=$from',
      cancelToken: cancelToken,
      options: Options(headers: await _headers(config, '')),
    );
    final d = resp.data ?? const <String, dynamic>{};
    final raw = d['deltas'];
    final deltas = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) deltas.add(item.cast<String, dynamic>());
      }
    }
    return AgentTaskPoll(
      status: (d['status'] as String?) ?? 'running',
      total: (d['total'] as num?)?.toInt() ?? from,
      deltas: deltas,
    );
  }

  /// 轮询续完一个云端 Agent 任务（降级续传 / App 重开自动续接共用）。
  ///
  /// 语义与 [chatStream] 一致：一路 yield ContentDelta / ReasoningDelta，
  /// 结束时给 FinalMessage。上层（AgentOrchestrator）无需区分内容是流来的
  /// 还是轮询来的。
  Stream<LlmEvent> resumeAgentTask({
    required LlmConfig config,
    required String taskId,
    int from = 0,
    CancelToken? cancelToken,
    Duration interval = const Duration(seconds: 2),
    int maxPolls = 900,
  }) async* {
    var cursor = from;
    final content = StringBuffer();
    final reasoning = StringBuffer();

    for (var i = 0; i < maxPolls; i++) {
      if (cancelToken?.isCancelled ?? false) break;
      AgentTaskPoll poll;
      try {
        poll = await pollAgentTask(
          config: config,
          taskId: taskId,
          from: cursor,
          cancelToken: cancelToken,
        );
      } catch (e) {
        // 单次轮询抖动不该让整个任务失败：退避后继续。
        debugPrint('任务轮询失败（第 ${i + 1} 次）：$e');
        await Future<void>.delayed(interval);
        continue;
      }
      for (final d in poll.deltas) {
        final c = d['content'];
        if (c is String && c.isNotEmpty) {
          content.write(c);
          yield ContentDelta(c);
        }
        final rc = d['reasoning_content'] ?? d['reasoning'];
        if (rc is String && rc.isNotEmpty) {
          reasoning.write(rc);
          yield ReasoningDelta(rc);
        }
      }
      cursor = poll.total;
      if (!poll.isRunning) break;
      await Future<void>.delayed(interval);
    }

    yield FinalMessage(ChatMessage(
      id: 'asst_${DateTime.now().millisecondsSinceEpoch}',
      role: 'assistant',
      content: content.toString(),
      reasoning: reasoning.isEmpty ? null : reasoning.toString(),
    ));
  }

  /// 当前用户未完成的云端 Agent 任务（App 重开自动续接用）。
  Future<List<Map<String, dynamic>>> listActiveAgentTasks({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async {
    final resp = await _dioFor(config).get<Map<String, dynamic>>(
      _agentTaskBase(config),
      cancelToken: cancelToken,
      options: Options(headers: await _headers(config, '')),
    );
    final raw = resp.data?['tasks'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
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
  Future<List<String>> listModelNames({
    required LlmConfig config,
    CancelToken? cancelToken,
  }) async =>
      (await listModels(config: config, cancelToken: cancelToken))
          .map((m) => m.name)
          .toList();

  /// 拉取模型列表（含可选的上下文/最大输出元数据）。
  ///
  /// OpenAI 标准的 /v1/models 只返回 id，但部分网关会附带更多字段——
  /// 能取到就自动填充编辑器的「上下文长度 / 最大输出」，取不到留 0：
  /// - `context_length`（OpenRouter）/ `context_window` / `context_size`
  /// - `max_output_tokens` / `max_completion_tokens` / `max_tokens`
  ///   / `top_provider.max_completion_tokens`（OpenRouter 嵌套）
  Future<List<FetchedModel>> listModels({
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
          options: Options(headers: await _headers(config, key)),
        );
        final data = resp.data?['data'];
        if (data is! List) {
          throw Exception('返回结构异常（缺少 data 数组），'
              '该服务可能不支持 /models 接口');
        }
        final models = <String, FetchedModel>{};
        for (final item in data) {
          if (item is String) {
            if (item.trim().isNotEmpty) {
              models.putIfAbsent(
                  item.trim(), () => FetchedModel(name: item.trim()));
            }
            continue;
          }
          if (item is! Map) continue;
          final m = item.cast<String, dynamic>();
          final id = m['id'];
          if (id is! String || id.trim().isEmpty) continue;
          final ctx = _firstInt(m, const [
            'context_length',
            'context_window',
            'contextWindow',
            'context_size',
            'max_model_len', // vLLM 的上下文字段名
          ]);
          var maxOut = _firstInt(m, const [
            'max_output_tokens',
            'max_completion_tokens',
            'maxOutputTokens',
            'max_tokens',
          ]);
          // OpenRouter 把最大输出藏在嵌套的 top_provider 里
          if (maxOut == null && m['top_provider'] is Map) {
            maxOut = _firstInt(
                (m['top_provider'] as Map).cast<String, dynamic>(),
                const ['max_completion_tokens']);
          }
          models.putIfAbsent(id.trim(),
              () => FetchedModel(name: id.trim(), contextWindow: ctx, maxOutputTokens: maxOut));
        }
        if (models.isEmpty) throw Exception('该服务未返回任何模型');
        final list = models.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        return list;
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

  /// 从 map 里按顺序取第一个能解析成正整数的字段；找不到返回 null。
  static int? _firstInt(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is num && v > 0) return v.toInt();
      if (v is String) {
        final n = int.tryParse(v.trim());
        if (n != null && n > 0) return n;
      }
    }
    return null;
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
    final names = models.map((m) => m.name).toList();
    final ms = sw.elapsedMilliseconds;
    final hasChat = config.chatModels.isNotEmpty;
    final hasEmb = config.embeddingModels.isNotEmpty;
    final buf = StringBuffer()
      ..writeln('连接成功（${ms}ms）')
      ..writeln('地址：${modelsUrl(config)}')
      ..writeln('可用模型：${names.length} 个');
    if (names.length <= 8) {
      buf.writeln(names.join('、'));
    } else {
      buf.writeln('${names.take(8).join('、')} 等');
    }
    if (!hasChat) {
      buf.writeln('\n⚠️ 尚未添加聊天模型，无法对话。');
    } else if (!names.contains(config.model)) {
      buf.writeln('\n⚠️ 当前聊天模型「${config.model}」不在服务端返回的列表里，'
          '可能是名称写错或该模型未开放。');
    }
    if (hasEmb && !names.contains(config.embeddingModelName)) {
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
          options: Options(headers: await _headers(config, key)),
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
    // 服务端可能返回非法 index（越界/负数），这些向量先攒着，
    // 之后按到达顺序兜底填进没被覆盖的槽位。
    final leftovers = <List<double>>[];
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
      if (idx < 0 || idx >= inputs.length) {
        debugPrint(
            'embedBatch: 忽略非法 index=$idx（请求 ${inputs.length} 条），向量转入兜底填充');
        leftovers.add(vec);
        continue;
      }
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

    if (slots.length + leftovers.length != inputs.length) {
      throw Exception(
        'Embedding 返回 ${slots.length + leftovers.length} 条有效向量，与请求的 ${inputs.length} 条不符',
      );
    }
    final ordered = List<List<double>>.filled(inputs.length, const <double>[]);
    slots.forEach((i, v) => ordered[i] = v);
    // 非法 index 留下的空槽按剩余向量（响应到达顺序）兜底填充。
    var li = 0;
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].isEmpty && li < leftovers.length) {
        ordered[i] = leftovers[li++];
      }
    }
    _checkDims(ordered);
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

/// /models 拉取到的单个模型条目（名称 + 可选元数据）。
class FetchedModel {
  const FetchedModel({
    required this.name,
    this.contextWindow,
    this.maxOutputTokens,
  });

  final String name;

  /// 上下文窗口（token）。网关未提供时为 null（编辑器留空 = 0 不限制）。
  final int? contextWindow;

  /// 单次回复最大输出（token）。网关未提供时为 null。
  final int? maxOutputTokens;

  /// 网关是否提供了任一元数据。false = /models 只返回 id，
  /// 自动填充无从生效（弹窗会明示，需手动填写）。
  bool get hasMeta => contextWindow != null || maxOutputTokens != null;
}
