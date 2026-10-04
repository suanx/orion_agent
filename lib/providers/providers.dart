import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
// 字素簇安全截断（标题总结的输入/输出截断），避免劈开 emoji。
import 'package:characters/characters.dart';
//不能用 `show ThemeMode` 限制导入：material.dart 里同文件导出的
// debugPrint（来自 foundation）会被一起挡掉，导致下面多处
// "The method 'debugPrint' isn't defined"。改为显式补 foundation。
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/llm_config.dart';
import '../services/agent_orchestrator.dart';
import '../services/cloud_service.dart';
import '../services/database.dart';
import '../services/llm_client.dart';
import '../services/mcp_service.dart';
import '../services/memory_service.dart';
import '../services/notification_service.dart';
import '../services/permission_service.dart';
import '../services/rag_service.dart';
import '../services/role_service.dart';
import '../services/token_stats_service.dart';
import '../services/skill_search_service.dart';
import '../services/skill_service.dart';
import '../services/storage_service.dart';
import '../services/terminal_service.dart';
import '../services/tools.dart';
import '../services/update_service.dart';
import '../services/voice_service.dart';

/// 在 main() 中 override 注入。
final sharedPreferencesProvider =
    Provider<SharedPreferences>((ref) => throw UnimplementedError());

/// 在 main() 中 override 注入（启动时已从磁盘加载）。
final initialSessionsProvider =
    Provider<List<ChatSession>>((ref) => throw UnimplementedError());

/// 在 main() 中 override 注入，保证全 app 单一数据库连接。
final databaseProvider =
    Provider<AppDatabase>((ref) => throw UnimplementedError());

final storageServiceProvider =
    Provider<StorageService>((ref) => StorageService(ref.watch(databaseProvider)));

final memoryServiceProvider =
    Provider<MemoryService>((ref) => MemoryService(ref.watch(databaseProvider)));

final ragServiceProvider =
    Provider<RagService>((ref) => RagService(ref.watch(databaseProvider)));

/// 用当前激活的模型配置调用 /embeddings。未配置 Embedding 模型时调用会抛异常，
/// 由调用方（工具/聊天）捕获降级。
final batchEmbedProvider = Provider<BatchEmbed>((ref) {
  return (inputs) async {
    final config = ref.read(configProvider).activeConfig;
    if (config == null) {
      throw Exception('未配置模型服务');
    }
    return ref.read(llmClientProvider).embedBatch(config: config, inputs: inputs);
  };
});

final toolRegistryProvider = Provider<ToolRegistry>((ref) => ToolRegistry(
      memoryService: ref.watch(memoryServiceProvider),
      ragService: ref.watch(ragServiceProvider),
      batchEmbed: ref.watch(batchEmbedProvider),
      terminalService: ref.watch(terminalServiceProvider),
      skillService: ref.watch(skillServiceProvider),
      skillSearchService: ref.watch(skillSearchServiceProvider),
      cloudService: ref.watch(cloudServiceProvider),
    ));

final llmClientProvider = Provider<LlmClient>(
    (ref) => LlmClient(Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)))));

final orchestratorProvider = Provider<AgentOrchestrator>((ref) => AgentOrchestrator(
      llm: ref.watch(llmClientProvider),
      tools: ref.watch(toolRegistryProvider),
      memory: ref.watch(memoryServiceProvider),
      stats: ref.watch(tokenStatsServiceProvider),
      skills: ref.watch(skillServiceProvider),
    ));

/// Token 用量统计服务。
final tokenStatsServiceProvider =
    Provider<TokenStatsService>((ref) => TokenStatsService(ref.watch(databaseProvider)));

final voiceProvider = Provider<VoiceService>((ref) => VoiceService());

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());

/// 应用权限服务（授权页专用）。状态实时查询不缓存——
/// 用户从系统设置返回后要立刻看到最新状态。
final permissionServiceProvider =
    Provider<PermissionService>((ref) => PermissionService());

/// 应用内更新检查（云端优先，GitHub Releases 兜底）。
final updateServiceProvider = Provider<UpdateService>((ref) =>
    UpdateService(cloud: ref.watch(cloudServiceProvider)));

/// 启动自动检查发现的可用更新（null = 无）。
/// HomeShell 弹窗展示；用户点「去更新」后清除。
final pendingUpdateProvider = StateProvider<UpdateInfo?>((ref) => null);

/// 当前语音合成引擎（edge = 免 Key 在线合成，system = 系统 TTS）。
///
/// ⚠️ 设置页已移除「系统语音」选项，朗读统一走 Edge TTS（系统 TTS 只作为
/// Edge 失败时的自动回退，见 VoiceService.speak）。provider 保留仅为兼容
/// 旧 prefs 数据，不再有 UI 入口写入 'system'。
final ttsEngineProvider = StateProvider<TtsEngine>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('tts_engine') == 'system'
      ? TtsEngine.system
      : TtsEngine.edge;
});

/// 语音播报总开关：回答完成后是否自动朗读。
///
/// 两处可切换：语音播报设置页的总开关、聊天输入框下方的朗读图标。
/// 都必须同时写 provider 与 prefs（provider 初值从 prefs 读，
/// 不落盘重启后会弹回）。
final ttsEnabledProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('tts_enabled') ?? false;
});

/// ---- 专项模型（「我的 → 默认模型」页设置）----
///
/// 值为**模型名**；空字符串 = 「跟随当前聊天模型」。
/// 模型名不校验存在性：所属模型被删除时该设置自然失效，
/// 请求会退回当前聊天模型（copyWith 的名字找不到时 chatModel 不变？——
/// 不，chatModel 是按 defaultChatModel 查找的，找不到退回第一个，
/// 所以失效时表现为「用了该提供商的另一个模型」，可接受）。

/// 识图模型：带图消息用它处理（当前聊天模型可能不支持视觉输入）。
final visionModelProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('vision_model') ?? '';
});

/// 压缩模型：长会话上下文压缩时用（暂未接入请求流程，仅保存设置）。
final compressModelProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('compress_model') ?? '';
});

/// 标题总结模型：首轮回答完成后用它生成简短会话标题。
final summaryModelProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('summary_model') ?? '';
});

/// Agent 权限模式（聊天状态条的「权限」选择）。
/// 初值从 prefs 读；变化由 chatProvider 构造处的 ref.listen 同步到
/// ToolRegistry.permission（工具暴露与执行双重过滤）。
final agentPermissionProvider = StateProvider<AgentPermission>((ref) {
  final raw =
      ref.watch(sharedPreferencesProvider).getString('agent_permission');
  return AgentPermission.values.firstWhere(
    (v) => v.name == raw,
    orElse: () => AgentPermission.workspace,
  );
});

/// Edge TTS 音色 id。
final ttsVoiceProvider = StateProvider<String>((ref) {
  return ref
          .watch(sharedPreferencesProvider)
          .getString('tts_voice') ??
      edgeVoices.first.id;
});

/// 朗读语速倍率（0.5 ~ 2.0）。
final ttsRateProvider = StateProvider<double>((ref) {
  return ref.watch(sharedPreferencesProvider).getDouble('tts_rate') ?? 1.0;
});

/// 朗读音量（0.0 ~ 1.0）。
final ttsVolumeProvider = StateProvider<double>((ref) {
  return ref.watch(sharedPreferencesProvider).getDouble('tts_volume') ?? 1.0;
});

/// 回答完成后发通知。
final notifyOnAnswerProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('notify_on_answer') ?? false;
});

/// 通知里显示回答摘要。
final notifyPreviewProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('notify_preview') ?? true;
});

/// 通知静音（只震动/横幅，不响铃）。
final notifySilentProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('notify_silent') ?? false;
});

final skillServiceProvider =
    Provider<SkillService>((ref) => SkillService(ref.watch(databaseProvider)));

/// 远程技能搜索服务（内置默认源：中文技能库优先）。
final skillSearchServiceProvider =
    Provider<SkillSearchService>((ref) => SkillSearchService());

final roleServiceProvider =
    Provider<RoleService>((ref) => RoleService(ref.watch(databaseProvider)));

/// 当前激活的 Agent 角色 id（'' = 默认助手）。
final activeRoleIdProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('active_role_id') ?? '';
});

/// 技能页 → 聊天输入框的预填文本（用后即清）。
final prefillProvider = StateProvider<String>((ref) => '');

/// 「深度思考」开关。开启后会在请求里带 `reasoning_effort`，
/// 让支持该参数的模型先推理再回答（o1 / gpt-5 / glm / qwen-thinking 等）。
///
/// 默认关闭：不是所有服务都认这个参数，贸然开启会让部分网关报 400。
final thinkingProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('thinking_enabled') ?? false;
});

/// 思考强度：low / medium / high。配合 [thinkingProvider] 使用。
final reasoningEffortProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('reasoning_effort') ??
      'medium';
});

/// 当前主题配色 id（持久化在 shared_preferences，默认经典黑）。
final themeProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('theme_id') ?? 'blue';
});

/// 主题明暗模式：跟随系统 / 浅色 / 深色（持久化，默认跟随系统）。
final themeModeProvider = StateProvider<ThemeMode>((ref) {
  switch (ref.watch(sharedPreferencesProvider).getString('theme_mode')) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
});

final mcpServiceProvider = Provider<McpService>((ref) =>
    McpService(ref.watch(databaseProvider), ref.watch(toolRegistryProvider)));

final terminalServiceProvider =
    Provider<TerminalService>((ref) => TerminalService());

// ---------------- 模型配置 ----------------

class ConfigState {
  final List<LlmConfig> configs;

  /// 旧版单选「当前使用的配置」。新结构改为每条配置自带 `enabled`，
  /// 保留该字段只是为了兼容读取老的 shared_preferences，不再作为唯一依据。
  final String activeId;

  /// 持久化失败等一次性提示。为 null 表示无错误。
  final String? error;

  const ConfigState({
    required this.configs,
    this.activeId = '',
    this.error,
  });

  /// 实际用于对话的配置。
  ///
  /// 规则：**第一个「已启用且可用」的配置**。多选启用是允许的
  /// （列表页就是多个「已启用」徽标），但一次对话只能用一个提供商，
  /// 所以取列表顺序里的第一个。
  ///
  /// 逐级降级，保证老数据不会因为没人勾选 enabled 而彻底用不了：
  /// 已启用且可用 → 已启用 → 任意一条 → null。
  LlmConfig? get activeConfig {
    for (final c in configs) {
      if (c.enabled && c.ready) return c;
    }
    for (final c in configs) {
      if (c.enabled) return c;
    }
    return configs.isEmpty ? null : configs.first;
  }

  /// 正在使用的提供商 id（列表页标「使用中」用）。无可用时为 null。
  String? get usingId => activeConfig?.id;

  /// error 为 null 时默认保留原值；传 clearError 显式清除。
  ConfigState copyWith({
    List<LlmConfig>? configs,
    String? activeId,
    String? error,
    bool clearError = false,
  }) =>
      ConfigState(
        configs: configs ?? this.configs,
        activeId: activeId ?? this.activeId,
        error: clearError ? null : (error ?? this.error),
      );
}

/// 配置存两处：配置 JSON（含 API Key）进 flutter_secure_storage
/// （Keychain/Keystore 加密），activeId 进 shared_preferences（仅兼容旧版）。
class ConfigNotifier extends StateNotifier<ConfigState> {
  ConfigNotifier(this._prefs, this._secure)
      : super(const ConfigState(configs: [])) {
    _load();
  }

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kConfigs = 'llm_configs';
  static const _kActive = 'llm_active_id';

  /// 加载期间用户是否已通过 upsert/remove/setActive 修改过配置。
  /// 构造函数同步启动 _load() 但不 await，而 _secure.read 是平台通道调用
  /// （数十毫秒）。用户在返回前点「添加」，upsert 写入新列表后，
  /// _load 结尾会用加载出来的旧列表整体覆盖，刚添加的模型凭空消失。
  bool _localTouched = false;

  Future<void> _load() async {
    String? raw;
    try {
      raw = await _secure.read(key: _kConfigs);
      if (raw == null) {
        // 旧版本把配置明文存在 shared_preferences，迁移到加密存储后删除明文。
        final legacy = _prefs.getString(_kConfigs);
        if (legacy != null) {
          raw = legacy;
          await _secure.write(key: _kConfigs, value: legacy);
          await _prefs.remove(_kConfigs);
        }
      }
    } catch (e) {
      // Keystore 初始化失败/设备锁变更等会让 read 抛异常。数据其实还在，
      // 只是读不出来——置 error 提示而不是静默变空（否则用户以为配置全丢）。
      debugPrint('读取模型配置异常：$e');
      if (mounted) {
        state = state.copyWith(
            error: '读取模型配置失败（数据仍在，重启或重新解锁设备后可恢复）：$e');
      }
      return;
    }
    final list = <LlmConfig>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) list.add(LlmConfig.fromJson(item));
          }
        }
      } catch (e) {
        debugPrint('读取模型配置失败，使用空列表：$e');
      }
    }
    if (!mounted) return;
    // 用户已在加载期间改过配置 → 不能用旧数据覆盖
    if (_localTouched) return;
    state = ConfigState(
      configs: list,
      activeId: _prefs.getString(_kActive) ?? '',
    );
  }

  /// 串行化持久化，避免并发写同一 key 时旧快照覆盖新值。
  ///
  /// 原实现三个 _persist() 可以并发（平台通道完成顺序不保证与调用顺序一致），
  /// 用户「加 A → 立刻加 B → 立刻删 A」时最终可能落盘只含 A 的旧快照，
  /// 重启后 B 消失、A 复活。另外 state.activeId 是在 await 之后才读的，
  /// 并发下会读到已被后续调用改过的值。
  Future<void> _persist() async {
    final snapshot = state;
    final payload =
        jsonEncode(snapshot.configs.map((c) => c.toJson()).toList());
    try {
      await _secure.write(key: _kConfigs, value: payload);
      await _prefs.setString(_kActive, snapshot.activeId);
      // 成功后清掉上一次的失败提示，否则横幅会一直挂着
      if (mounted && state.error != null) {
        state = state.copyWith(clearError: true);
      }
    } catch (e) {
      // Keystore 损坏 / EncryptedSharedPreferences 初始化失败时 write 会抛。
      // 原来既没 await 也没 try/catch → unhandled async error，
      // 用户新增的 API Key 根本没保存，UI 却显示保存成功。
      debugPrint('配置持久化失败：$e');
      if (mounted) state = state.copyWith(error: '保存模型配置失败：$e');
    }
  }

  Future<void> _persistChain = Future<void>.value();

  void _schedulePersist() {
    _persistChain = _persistChain.then((_) => _persist());
  }

  void upsert(LlmConfig config) {
    _localTouched = true;
    final list = [...state.configs];
    final idx = list.indexWhere((c) => c.id == config.id);
    if (idx >= 0) {
      list[idx] = config;
    } else {
      list.add(config);
    }
    // 沿用 copyWith 而非新建 ConfigState：直接构造会把上一轮的 error 清空，
    // 让"保存失败"的提示在用户下一次编辑时凭空消失。
    state = state.copyWith(configs: list);
    _schedulePersist();
  }

  /// 就地替换某条配置（按 id）。
  LlmConfig? byId(String id) {
    for (final c in state.configs) {
      if (c.id == id) return c;
    }
    return null;
  }

  void remove(String id) {
    _localTouched = true;
    final list = state.configs.where((c) => c.id != id).toList();
    state = state.copyWith(
      configs: list,
      activeId: state.activeId == id ? '' : state.activeId,
    );
    _schedulePersist();
  }

  /// 启用 / 停用某条配置（列表页的「已启用」开关）。
  void setEnabled(String id, bool enabled) {
    _localTouched = true;
    final list = [
      for (final c in state.configs)
        c.id == id ? c.copyWith(enabled: enabled) : c,
    ];
    state = state.copyWith(configs: list);
    _schedulePersist();
  }

  /// 覆盖某条配置的模型列表（「拉取模型」用）。
  void setModels(String id, List<ProviderModel> models) {
    final c = byId(id);
    if (c == null) return;
    upsert(c.copyWith(models: models));
  }

  /// 往某条配置里追加模型（已存在同名则替换）。
  void addModel(String id, ProviderModel model) {
    final c = byId(id);
    if (c == null) return;
    final list = [...c.models];
    final idx = list.indexWhere((m) => m.name == model.name);
    if (idx >= 0) {
      list[idx] = model;
    } else {
      list.add(model);
    }
    upsert(c.copyWith(models: list));
  }

  void removeModel(String id, String modelName) {
    final c = byId(id);
    if (c == null) return;
    upsert(c.copyWith(
      models: [
        for (final m in c.models)
          if (m.name != modelName) m,
      ],
    ));
  }
}

final configProvider =
    StateNotifierProvider<ConfigNotifier, ConfigState>((ref) {
  return ConfigNotifier(
    ref.watch(sharedPreferencesProvider),
    const FlutterSecureStorage(),
  );
});

// ---------------- 会话与聊天 ----------------

class ChatState {
  final List<ChatSession> sessions;
  final String? activeSessionId;
  final bool isStreaming;
  final String streamingContent;

  /// 正在生成的内容所属会话。流式状态是全局单份，用它区分归属：
  /// UI 只在 activeSessionId == streamingSessionId 时渲染流式气泡，
  /// 避免用户切到别的会话后流式内容「串台」渲染进错误会话。
  final String? streamingSessionId;

  /// 流式期间的思考过程（开启思考且模型返回时才有内容）。
  final String streamingReasoning;
  final List<String> steps;
  final String? error;

  /// 当前会话的用量统计（应用启动以来累计；会话切换时按记录重置）。
  /// - prompt/completion：API 返回的真实 token 用量
  /// - toolRounds：工具调度轮次（内置 vs MCP）
  /// - compressCount：上下文自动压缩次数
  final int sessionPromptTokens;
  final int sessionCompletionTokens;
  final int toolRoundsBuiltIn;
  final int toolRoundsMcp;
  final int compressionCount;

  const ChatState({
    required this.sessions,
    this.activeSessionId,
    this.isStreaming = false,
    this.streamingSessionId,
    this.streamingContent = '',
    this.streamingReasoning = '',
    this.steps = const [],
    this.error,
    this.sessionPromptTokens = 0,
    this.sessionCompletionTokens = 0,
    this.toolRoundsBuiltIn = 0,
    this.toolRoundsMcp = 0,
    this.compressionCount = 0,
  });

  ChatSession? get activeSession {
    for (final s in sessions) {
      if (s.id == activeSessionId) return s;
    }
    return null;
  }

  ChatState copyWith({
    List<ChatSession>? sessions,
    String? activeSessionId,
    bool? isStreaming,
    String? streamingSessionId,
    String? streamingContent,
    String? streamingReasoning,
    List<String>? steps,
    String? error,
    bool clearError = false,
    bool clearStreamingSession = false,
    int? sessionPromptTokens,
    int? sessionCompletionTokens,
    int? toolRoundsBuiltIn,
    int? toolRoundsMcp,
    int? compressionCount,
  }) =>
      ChatState(
        sessions: sessions ?? this.sessions,
        activeSessionId: activeSessionId ?? this.activeSessionId,
        isStreaming: isStreaming ?? this.isStreaming,
        streamingSessionId: clearStreamingSession
            ? null
            : (streamingSessionId ?? this.streamingSessionId),
        streamingContent: streamingContent ?? this.streamingContent,
        streamingReasoning: streamingReasoning ?? this.streamingReasoning,
        steps: steps ?? this.steps,
        error: clearError ? null : (error ?? this.error),
        sessionPromptTokens: sessionPromptTokens ?? this.sessionPromptTokens,
        sessionCompletionTokens:
            sessionCompletionTokens ?? this.sessionCompletionTokens,
        toolRoundsBuiltIn: toolRoundsBuiltIn ?? this.toolRoundsBuiltIn,
        toolRoundsMcp: toolRoundsMcp ?? this.toolRoundsMcp,
        compressionCount: compressionCount ?? this.compressionCount,
      );
}

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier({
    required List<ChatSession> initialSessions,
    required StorageService storage,
    required AgentOrchestrator orchestrator,
    required RagService rag,
    required LlmClient llm,
    required VoiceService voice,
    required bool Function() ttsEnabled,
    required String Function() getPersona,
    required LlmConfig? Function() getConfig,
    TtsEngine Function()? getTtsEngine,
    String Function()? getTtsVoice,
    double Function()? getTtsRate,
    double Function()? getTtsVolume,
    bool Function()? notifyOnAnswer,
    bool Function()? notifyPreview,
    bool Function()? getThinking,
    String Function()? getReasoningEffort,
    String Function()? getVisionModel,
    String Function()? getSummaryModel,
    String Function()? getCompressModel,
  })  : _storage = storage,
        _orchestrator = orchestrator,
        _rag = rag,
        _llm = llm,
        _voice = voice,
        _ttsEnabled = ttsEnabled,
        _getPersona = getPersona,
        _getConfig = getConfig,
        _getTtsEngine = getTtsEngine ?? (() => TtsEngine.edge),
        _getTtsVoice = getTtsVoice ?? (() => edgeVoices.first.id),
        _getTtsRate = getTtsRate ?? (() => 1.0),
        _getTtsVolume = getTtsVolume ?? (() => 1.0),
        _notifyOnAnswer = notifyOnAnswer ?? (() => false),
        _notifyPreview = notifyPreview ?? (() => true),
        _getThinking = getThinking ?? (() => false),
        _getReasoningEffort = getReasoningEffort ?? (() => 'medium'),
        _getVisionModel = getVisionModel ?? (() => ''),
        _getSummaryModel = getSummaryModel ?? (() => ''),
        _getCompressModel = getCompressModel ?? (() => ''),
        super(ChatState(
          sessions: initialSessions,
          activeSessionId: initialSessions.isEmpty ? null : initialSessions.first.id,
        ));

  final StorageService _storage;
  final AgentOrchestrator _orchestrator;
  final RagService _rag;
  final LlmClient _llm;
  final VoiceService _voice;
  final bool Function() _ttsEnabled;
  final String Function() _getPersona;
  final LlmConfig? Function() _getConfig;
  final TtsEngine Function() _getTtsEngine;
  final String Function() _getTtsVoice;
  final double Function() _getTtsRate;
  final double Function() _getTtsVolume;
  final bool Function() _notifyOnAnswer;

  /// 「深度思考」开关与思考强度（供请求体带 reasoning_effort）。
  final bool Function() _getThinking;
  final String Function() _getReasoningEffort;
  final bool Function() _notifyPreview;

  /// 专项模型：识图（带图消息）、标题总结、上下文压缩。
  /// 空串 = 跟随当前聊天模型。
  final String Function() _getVisionModel;
  final String Function() _getSummaryModel;
  final String Function() _getCompressModel;

  /// 已做过标题总结的会话 id（内存即可：重启后标题已持久化）。
  final _titleSummarized = <String>{};

  /// 每会话用量：[prompt, completion, 内置工具轮, MCP 工具轮, 压缩次数]。
  /// 应用启动以来累计；会话切换时从该表恢复到 ChatState。
  final _usage = <String, List<int>>{};

  /// 由外部注入的通知发送回调（在 Provider 里绑定 NotificationService）。
  Future<void> Function(String title, String body)? onAnswerNotification;

  CancelToken? _cancelToken;

  /// 上下文压缩流的取消令牌：压缩进行中删除会话时取消，防止
  /// 压缩完成后把已删除的消息重新插回（孤儿数据）。
  CancelToken? _compressToken;

  /// send() 的同步互斥占位。原实现依赖 state.isStreaming，但该标志
  /// 在首个 await（_persistOp）之后才置位——守卫与置位之间隔着
  /// await，两条并发 send 都能通过检查。同步 bool 在任何 await
  /// 之前检查并置位，彻底封死竞态窗口。
  bool _sending = false;

  /// 流式期间每帧全量 state 重建是 O(n²) 拷贝；按时间合帧，
  /// 最多每 60ms 刷一次 UI（打字机观感不受影响）。
  DateTime _lastStreamFlush = DateTime.fromMillisecondsSinceEpoch(0);

  // 统一走 database.dart 的 uniqueId（带自增序列）。原来的实现用
  // state.sessions.length 做序列，而 deleteSession 会让长度回落，
  // 删除后再新建就可能复用已占用的 id → insertSession 抛 UNIQUE constraint。
  String _newId(String prefix) => uniqueId(prefix);

  void newSession() {
    final s = ChatSession(
      id: _newId('sess'),
      messages: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(sessions: [s, ...state.sessions], activeSessionId: s.id, clearError: true);
    unawaited(_persistOp(() => _storage.insertSession(s), '新建会话'));
  }

  void selectSession(String id) {
    // 切换会话时把用量统计恢复为该会话的记录（应用启动以来累计）
    final u = _usage[id] ?? const [0, 0, 0, 0, 0];
    state = state.copyWith(
      activeSessionId: id,
      clearError: true,
      sessionPromptTokens: u[0],
      sessionCompletionTokens: u[1],
      toolRoundsBuiltIn: u[2],
      toolRoundsMcp: u[3],
      compressionCount: u[4],
    );
  }

  /// 累加当前会话的一项用量并同步到 state。
  void _bumpUsage(String sessionId, int index, int delta) {
    final u = _usage.putIfAbsent(sessionId, () => [0, 0, 0, 0, 0]);
    u[index] += delta;
    if (state.activeSessionId != sessionId) return;
    state = state.copyWith(
      sessionPromptTokens: u[0],
      sessionCompletionTokens: u[1],
      toolRoundsBuiltIn: u[2],
      toolRoundsMcp: u[3],
      compressionCount: u[4],
    );
  }

  /// 清除当前错误提示（供 UI 关闭错误条使用）。
  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
  }

  void deleteSession(String id) {
    // 生成期间删除会话会让已写入的用户消息变成孤儿行，且随后的 AI 回答
    // 无处落地。先停止流式，让send() 正常收尾。
    if (state.isStreaming) {
      unawaited(stop());
    }
    // 压缩流不归 stop() 管（独立 CancelToken），单独取消。
    _compressToken?.cancel();
    // 该会话的用量/标题记录同步清掉，否则 Map 只增不减（内存缓慢泄漏）。
    _usage.remove(id);
    _titleSummarized.remove(id);
    final remaining = state.sessions.where((s) => s.id != id).toList();
    final newActive = state.activeSessionId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeSessionId;
    state = state.copyWith(sessions: remaining, activeSessionId: newActive);
    unawaited(_persistOp(() => _storage.deleteSession(id), '删除会话'));
  }

  Future<void> clearAllSessions() async {
    // 同上：先停下流式，避免删除后仍往里写入孤儿消息行。
    if (state.isStreaming) {
      await stop();
      // 给 send() 一点时间收尾（它会检测 isStreaming 并停止写入）
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _compressToken?.cancel();
    _usage.clear();
    _titleSummarized.clear();
    if (!mounted) return;
    state = ChatState(sessions: const [], activeSessionId: null);
    await _storage.clearSessions();
  }

  void _touch(ChatSession updated) {
    final sessions = state.sessions.map((s) => s.id == updated.id ? updated : s).toList();
    state = state.copyWith(sessions: sessions);
    unawaited(_persistOp(
        () => _storage.updateSessionMeta(updated), '更新会话元数据'));
  }

  Future<void> send(String text, {List<String> images = const []}) async {
    final content = text.trim();
    // 同步互斥：在任何 await 之前检查并占位（state.isStreaming 要到
    // 首个 await 之后才置位，只靠它会被并发 send 击穿）。
    if ((content.isEmpty && images.isEmpty) || _sending || state.isStreaming) {
      return;
    }
    _sending = true;

    final config = _getConfig();
    if (config == null) {
      _sending = false;
      state = state.copyWith(error: '请先在「设置」中添加并选择一个模型服务。');
      return;
    }

    var session = state.activeSession;
    if (session == null) {
      newSession();
      session = state.activeSession;
      if (session == null) {
        _sending = false;
        return;
      }
    }

    final userMsg = ChatMessage(
      id: uniqueId('u'),
      role: 'user',
      content: content,
      images: images,
    );
    // 同样避免就地修改：构造新的 ChatSession 再交给 _touch。
    final title = session.title == '新对话'
        ? (content.isEmpty
            ? '[图片]'
            : (content.characters.length > 16
                ? '${content.characters.take(16).toString()}…'
                : content))
        : session.title;
    final updated = ChatSession(
      id: session.id,
      title: title,
      messages: [...session.messages, userMsg],
      createdAt: session.createdAt,
      updatedAt: DateTime.now(),
    );
    _touch(updated);
    await _persistOp(() => _storage.insertMessage(updated.id, userMsg), '用户消息');

    state = state.copyWith(
      isStreaming: true,
      streamingSessionId: updated.id,
      streamingContent: '',
      streamingReasoning: '',
      steps: [],
      clearError: true,
    );
    _lastStreamFlush = DateTime.fromMillisecondsSinceEpoch(0);

    _cancelToken = CancelToken();
    final sessionId = updated.id;

    // 发送前自动检索知识库（未配置 embedding 模型或检索失败时静默跳过）。
    // 放在压缩之前：压缩估算需要把检索到的知识计入上下文占用。
    var knowledge = const <RagHit>[];
    if (config.embeddingModelName.trim().isNotEmpty) {
      try {
        knowledge = await _rag.search(
          query: content,
          // embedding 可能返回空数组，.first 会抛 StateError；这里兜底为空向量。
          embedOne: (q) async {
            final vecs = await _llm.embedBatch(config: config, inputs: [q]);
            return vecs.isEmpty ? const <double>[] : vecs.first;
          },
        );
      } catch (e) {
        // 原来空 catch：知识库为何失效完全无迹可循，表现为"AI 不认识我导入的资料"。
        // 检索失败降级为无知识库（不阻断对话），但必须留下日志。
        debugPrint('RAG 检索失败，已降级为无知识库：$e');
      }
    }

    // 上下文自动压缩：历史 token 估算超过模型窗口 75% 时，
    // 用压缩模型把较旧的历史折叠成一条摘要（保留最近几条原文）。
    // 失败静默降级为不压缩——压缩是优化，绝不能阻断对话。
    final historyMessages = await _maybeCompressHistory(updated, config,
        knowledge: knowledge);
    final history = List<ChatMessage>.from(historyMessages);

    final buf = StringBuffer();
    ChatMessage? answer;

    // 识图模型：带图消息走识图模型（当前聊天模型可能不支持视觉输入）。
    // 未设置时保持原样，图片直接随聊天模型发送。
    var effConfig = config;
    if (updated.messages.last.images.isNotEmpty) {
      final vm = _getVisionModel();
      if (vm.isNotEmpty) {
        effConfig = config.copyWith(defaultChatModel: vm);
      }
    }

    try {
      await for (final ev in _orchestrator.run(
        config: effConfig,
        history: history,
        cancelToken: _cancelToken,
        knowledge: knowledge,
        persona: _getPersona(),
        thinking: _getThinking(),
        reasoningEffort: _getReasoningEffort(),
      )) {
        // 长 Streaming 期间 notifier 可能已被 dispose（容器销毁/热重启），
        // 此时写 state 会抛 StateError 并让 isStreaming 永远无法复位。
        if (!mounted) return;
        if (ev is AgentDelta) {
          buf.write(ev.delta);
          // 合帧：每个 delta 都全量 toString + 重建整个 ChatState 是
          // O(n²) 拷贝，长回答会明显卡顿。60ms 内的 delta 只累积，
          // 到点或流结束时统一刷一次 UI。
          final now = DateTime.now();
          if (now.difference(_lastStreamFlush).inMilliseconds >= 60) {
            _lastStreamFlush = now;
            state = state.copyWith(streamingContent: buf.toString());
          }
        } else if (ev is AgentReasoning) {
          state = state.copyWith(
              streamingReasoning:
                  state.streamingReasoning + ev.delta);
        } else if (ev is AgentStatus) {
          state = state.copyWith(steps: [...state.steps, '⏳ ${ev.text}']);
        } else if (ev is AgentToolDone) {
          // 工具调度统计：MCP 工具名带「服务器名__工具名」双下划线约定
          if (ev.toolName.contains('__')) {
            _bumpUsage(sessionId, 3, 1);
          } else {
            _bumpUsage(sessionId, 2, 1);
          }
          final brief = ev.result.characters.take(120).toString();
          final briefText = ev.result.characters.length > 120 ? '$brief…' : brief;
          state = state.copyWith(
              steps: [...state.steps, '🔧 ${ev.toolName} → $briefText']);
        } else if (ev is AgentTokenUsage) {
          _bumpUsage(sessionId, 0, ev.promptTokens);
          _bumpUsage(sessionId, 1, ev.completionTokens);
        } else if (ev is AgentAnswer) {
          answer = ev.message;
        } else if (ev is AgentFailure) {
          // 用户主动取消不是错误：不弹错误横幅（部分内容如何落库见下方收尾逻辑）。
          if (ev.message != '已取消。') {
            state = state.copyWith(error: ev.message);
          }
        }
      }
    } catch (e) {
      if (mounted) state = state.copyWith(error: '运行出错：$e');
    }

    if (!mounted) return;

    // 取消但已产出部分内容：把已有内容作为部分回答落库，而不是整段丢弃。
    // 标记「（已停止）」让用户知道回答被截断。
    final wasCancelled = _cancelToken?.isCancelled ?? false;
    if (wasCancelled && answer == null && buf.toString().trim().isNotEmpty) {
      answer = ChatMessage(
        id: uniqueId('a'),
        role: 'assistant',
        content: '${buf.toString().trim()}\n\n（已停止）',
      );
    }

    // 最终回答写入会话历史（工具中间过程不入库，节省上下文长度）
    // 按锁定的 sessionId 定位，而不是读当前的 activeSession。
    final s2 = state.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (answer != null && s2 != null) {
      // 原实现直接 s2.messages.add(...) 就地改列表，sessions 里存的是同一份
      // 引用，copyWith 检测到引用未变就不会触发重建，界面可能不刷新。
      // 这里改为复制列表后再更新，保证状态是不可变替换。
      final withAnswer = ChatSession(
        id: s2.id,
        title: s2.title,
        messages: [...s2.messages, answer],
        createdAt: s2.createdAt,
        updatedAt: DateTime.now(),
      );
      // 显式提取成非空局部变量。
      // `answer` 是 ChatMessage? 且在 await for 中被赋值，Flutter analyzer
      // 不保证在闭包捕获场景下完成类型提升，直接传 answer 会报
      // "The argument type 'ChatMessage?' can't be assigned to 'ChatMessage'"。
      final msg = answer;
      _touch(withAnswer);
      await _persistOp(
          () => _storage.insertMessage(withAnswer.id, msg), 'AI 回答');

      // 标题总结：设置了总结模型时，用小模型为会话生成简短标题。
      // 只做一次（_titleSummarized），失败静默，不影响主流程。
      final sm = _getSummaryModel();
      if (sm.isNotEmpty) {
        unawaited(_summarizeTitle(sessionId, sm, answer.content));
      }

      // 语音播报（引擎/音色/语速/音量都来自设置）
      if (_ttsEnabled()) {
        unawaited(_voice.speak(
          answer.content,
          engine: _getTtsEngine(),
          edgeVoice: _getTtsVoice(),
          rate: _getTtsRate(),
          volume: _getTtsVolume(),
        ));
      }

      // 回答完成通知
      if (_notifyOnAnswer()) {
        final brief = answer.content.replaceAll(RegExp(r'\s+'), ' ').trim();
        final body = _notifyPreview()
            ? (brief.characters.length > 120
                ? '${brief.characters.take(120).toString()}…'
                : brief)
            : '';
        unawaited(onAnswerNotification?.call(
          withAnswer.title,
          body,
        ));
      }
    } else if (answer != null) {
      // 会话在生成期间被删除：回答无处可去，明确留痕而不是静默丢弃。
      debugPrint('会话 $sessionId 已被删除，回答未保存（id=${answer.id}）');
    }

    // 放在 finally 语义位置：任何提前 return 都不会让 isStreaming 卡在 true
    if (mounted) {
      state = state.copyWith(
        isStreaming: false,
        streamingContent: '',
        steps: [],
        clearStreamingSession: true,
      );
    }
    _cancelToken = null;
    _sending = false;
  }

  /// 统一处理数据库写入：原来是裸 Future，磁盘满/DB 关闭时错误被完全吞掉，
  /// 用户重启后发现消息丢了，日志里也没有任何线索。
  Future<void> _persistOp(Future<void> Function() op, String what) async {
    try {
      await op();
    } catch (e) {
      debugPrint('持久化失败（$what）：$e');
      if (mounted) state = state.copyWith(error: '保存到本地数据库失败：$e');
    }
  }

  Future<void> stop() async {
    final t = _cancelToken;
    if (t != null && !t.isCancelled) {
      t.cancel();
    }
  }

  /// 用标题总结模型为会话生成简短标题。
  ///

  /// 上下文自动压缩：估算整个历史的 token 占用，超过模型窗口 75% 时
  /// 把较旧的消息（保留最近 6 条）交给压缩模型生成要点摘要，
  /// 用「摘要消息 + 近期原文」整体替换会话消息（内存 + 落库）。
  ///
  /// - 压缩模型：专项设置优先，未设置回退当前聊天模型
  /// - 任何失败都静默返回原消息（压缩是优化，不能阻断对话）
  /// - 摘要以 role=user 消息存入历史（部分网关对历史中段的 system
  ///   消息返回 400），发送时随上下文带给模型
  /// - 压缩流有独立 CancelToken：压缩期间删除会话时取消，防止
  ///   已删除的消息被重新插回（孤儿行）
  Future<List<ChatMessage>> _maybeCompressHistory(
      ChatSession session, LlmConfig config,
      {List<RagHit> knowledge = const []}) async {
    final msgs = session.messages;
    final total = config.chatModel?.contextWindow ?? 0;
    if (total <= 0) return msgs; // 未知窗口大小，无法判断何时压缩

    // 估算不只算消息本身：系统提示词（人设）、检索到的知识库内容、
    // 工具定义都要占窗口。工具定义按 ~800 tokens 固定预留。
    var est = estimateTokens(_getPersona()) + 800;
    for (final h in knowledge) {
      est += estimateTokens(h.content) + 8;
    }
    for (final m in msgs) {
      est += estimateTokens(m.content) + 8; // 每条消息的包装开销
    }
    if (est < total * 0.75) return msgs;
    if (msgs.length <= 8) return msgs; // 太短不值得压缩

    final cm = _getCompressModel();
    final model = cm.isNotEmpty ? cm : (config.chatModel?.name ?? '');
    if (model.isEmpty) return msgs;

    const keep = 6;
    final older = msgs.take(msgs.length - keep).toList();
    final olderText = older
        .map((m) => '${m.role == 'user' ? '用户' : 'AI'}：${m.content}')
        .join('\n\n');
    // 只取较旧部分的【后半段】（靠近当下的内容信息密度更高）。
    // 用 characters 切尾，避免 substring 劈开 emoji 代理对。
    final text = olderText.characters.length > 20000
        ? olderText.characters
            .skip(olderText.characters.length - 20000)
            .toString()
        : olderText;

    final token = CancelToken();
    _compressToken = token;
    try {
      final eff = config.copyWith(defaultChatModel: model);
      final buf = StringBuffer();
      await for (final ev in _llm.chatStream(
        config: eff,
        cancelToken: token,
        messages: [
          {
            'role': 'system',
            'content': '把以下对话历史压缩成一份要点摘要。必须保留：'
                '用户的偏好与明确要求、关键事实与结论、未完成的任务。'
                '不超过 500 字，直接输出摘要正文，不要任何开场白。',
          },
          {'role': 'user', 'content': text},
        ],
      )) {
        if (ev is FinalMessage) {
          buf
            ..clear()
            ..write(ev.message.content);
        }
      }
      final summary = buf.toString().trim();
      if (summary.isEmpty) return msgs;

      // 压缩期间会话被删除（或已被别的压缩替换过）→ 放弃写回，
      // 否则已删除的消息会以「摘要」形式复活成孤儿数据。
      final stillExists = state.sessions.any((s) => s.id == session.id);
      if (!stillExists || token.isCancelled) return msgs;

      final summaryMsg = ChatMessage(
        id: uniqueId('sum'),
        role: 'user',
        content: '【此前对话已自动压缩，摘要如下】\n$summary',
      );
      final kept = msgs.sublist(msgs.length - keep);
      final newMessages = <ChatMessage>[summaryMsg, ...kept];

      // 持久化 + 同步内存会话
      await _storage.replaceMessages(session.id, newMessages);
      if (!mounted) return newMessages;
      final sessions = state.sessions
          .map((s) => s.id == session.id
              ? ChatSession(
                  id: s.id,
                  title: s.title,
                  messages: newMessages,
                  createdAt: s.createdAt,
                  updatedAt: s.updatedAt,
                )
              : s)
          .toList();
      state = state.copyWith(sessions: sessions);
      // 压缩次数统一走 _bumpUsage 按会话记账。原实现直接把
      // state.compressionCount+1 写进「当前激活会话」的显示值——
      // 压缩的是 A 会话、激活的是 B 会话时，计数被记到 B 头上。
      _bumpUsage(session.id, 4, 1);
      debugPrint('上下文压缩完成：${older.length} 条旧消息 → 摘要 '
          '(${estimateTokens(summary)} tokens)，保留最近 $keep 条');
      return newMessages;
    } catch (e) {
      debugPrint('上下文压缩失败（降级为不压缩）：$e');
      return msgs;
    } finally {
      if (identical(_compressToken, token)) _compressToken = null;
    }
  }
  /// 非流式语义但复用 chatStream（拿到 FinalMessage 即收敛）。
  /// 任何失败都静默——标题是锦上添花，绝不能因为它打断对话。
  Future<void> _summarizeTitle(
      String sessionId, String model, String answer) async {
    if (_titleSummarized.contains(sessionId)) return;
    _titleSummarized.add(sessionId);
    try {
      final config = _getConfig();
      if (config == null) return;
      final eff = config.copyWith(defaultChatModel: model);
      final buf = StringBuffer();
      await for (final ev in _llm.chatStream(
        config: eff,
        messages: [
          {
            'role': 'system',
            'content': '为用户提供的对话内容生成一个不超过12个字的简短标题。'
                '直接输出标题本身，不要引号、句号或任何解释。',
          },
          {
            'role': 'user',
            'content': answer.characters.take(500).toString(),
          },
        ],
      ).timeout(const Duration(seconds: 30))) {
        if (ev is FinalMessage) {
          // ContentDelta 与 FinalMessage 正常情况下都会发：直接累积会把
          // 同一段内容写两遍（生成的标题几乎必然是坏的）。
          // FinalMessage 是全量收敛，先 clear 再写。
          buf
            ..clear()
            ..write(ev.message.content);
          break;
        }
        if (ev is ContentDelta) buf.write(ev.delta);
      }
      var title = buf.toString().trim().replaceAll(RegExp(r'[\n\r"「」]'), '');
      if (title.isEmpty) return;
      title = title.characters.take(20).toString();
      if (!mounted) return;
      final s = state.sessions.where((x) => x.id == sessionId).firstOrNull;
      if (s == null) return;
      final updated = ChatSession(
        id: s.id,
        title: title,
        messages: s.messages,
        createdAt: s.createdAt,
        updatedAt: DateTime.now(),
      );
      _touch(updated);
      await _persistOp(() => _storage.updateSessionMeta(updated), '会话标题');
    } catch (e) {
      debugPrint('标题总结失败（不影响使用）：$e');
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  // 权限模式联动：初值设置 + UI 修改时同步到工具注册表。
  // ToolRegistry 是单例，orchestrator 的每次 run 都通过它拿工具清单。
  final registry = ref.watch(toolRegistryProvider);
  registry.permission = ref.read(agentPermissionProvider);
  ref.listen<AgentPermission>(agentPermissionProvider, (_, v) {
    registry.permission = v;
  });
  final notifier = ChatNotifier(
    initialSessions: ref.watch(initialSessionsProvider),
    storage: ref.watch(storageServiceProvider),
    orchestrator: ref.watch(orchestratorProvider),
    rag: ref.watch(ragServiceProvider),
    llm: ref.watch(llmClientProvider),
    voice: ref.watch(voiceProvider),
    ttsEnabled: () => ref.read(ttsEnabledProvider),
    getVisionModel: () => ref.read(visionModelProvider),
    getSummaryModel: () => ref.read(summaryModelProvider),
    getCompressModel: () => ref.read(compressModelProvider),
    getPersona: () {
      final id = ref.read(activeRoleIdProvider);
      return ref.read(roleServiceProvider).promptOf(id) ?? '';
    },
    getConfig: () => ref.read(configProvider).activeConfig,
    getTtsEngine: () => ref.read(ttsEngineProvider),
    getTtsVoice: () => ref.read(ttsVoiceProvider),
    getTtsRate: () => ref.read(ttsRateProvider),
    getTtsVolume: () => ref.read(ttsVolumeProvider),
    notifyOnAnswer: () => ref.read(notifyOnAnswerProvider),
    notifyPreview: () => ref.read(notifyPreviewProvider),
    getThinking: () => ref.read(thinkingProvider),
    getReasoningEffort: () => ref.read(reasoningEffortProvider),
  );

  // 绑定通知：读设置并在发送时遵循静音开关
  notifier.onAnswerNotification = (title, body) => ref
      .read(notificationServiceProvider)
      .notifyAnswerDone(
        sessionTitle: title,
        answer: body,
        preview: body.isNotEmpty,
        silent: ref.read(notifySilentProvider),
      );

  return notifier;
});

// ---------------- 自动任务 ----------------

/// 任务页状态：任务列表 + 正在运行的任务 id 集合。
class TasksState {
  final List<TaskRow> tasks;
  final Set<String> runningIds;

  const TasksState({this.tasks = const [], this.runningIds = const {}});

  TasksState copyWith({List<TaskRow>? tasks, Set<String>? runningIds}) =>
      TasksState(
        tasks: tasks ?? this.tasks,
        runningIds: runningIds ?? this.runningIds,
      );

  TaskRow? byId(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// 自动任务：定时 / 手动触发的 Agent 提示词。
///
/// - 运行 = 用当前聊天模型跑一遍 [TaskRow.prompt]，结果写回任务行
///   （lastResult），并发系统通知。结果不进消息表——任务运行
///   不属于任何会话。
/// - 调度器：App 存活期间每分钟 tick 一次检查每天任务；
///   错过的（App 关着）在 start() 时补跑当天已到期的。
class TasksNotifier extends StateNotifier<TasksState> {
  TasksNotifier({
    required StorageService storage,
    required AgentOrchestrator orchestrator,
    required NotificationService notifications,
    required LlmConfig? Function() getConfig,
    required bool Function() getThinking,
    required String Function() getReasoningEffort,
  })  : _storage = storage,
        _orchestrator = orchestrator,
        _notifications = notifications,
        _getConfig = getConfig,
        _getThinking = getThinking,
        _getReasoningEffort = getReasoningEffort,
        super(const TasksState());

  final StorageService _storage;
  final AgentOrchestrator _orchestrator;
  final NotificationService _notifications;
  final LlmConfig? Function() _getConfig;
  final bool Function() _getThinking;
  final String Function() _getReasoningEffort;

  /// 调度 tick 定时器。App 存活期间每分钟检查一次到期任务。
  Timer? _timer;

  /// 串行化任务运行：定时触发与手动触发可能撞车，LLM 调用
  /// 排队执行（同一时间只跑一个任务），避免 token 火并。
  Future<void> _queue = Future.value();

  Future<void> load() async {
    final tasks = await _storage.loadTasks();
    if (mounted) state = state.copyWith(tasks: tasks);
  }

  Future<void> upsert(TaskRow row) async {
    await _storage.insertTask(row);
    await load();
  }

  Future<void> remove(String id) async {
    await _storage.deleteTask(id);
    await load();
  }

  // ---------------- 调度 ----------------

  /// 启动调度：启动补跑 + 每分钟 tick。main.dart 调用（不 await）。
  Future<void> start() async {
    await load();
    await _catchUpMissed();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 每分钟 tick：命中「每天 HH:mm」且今天还没跑的启用任务。
  void _tick() {
    final now = DateTime.now();
    for (final t in state.tasks) {
      if (!_isDueToday(t, now)) continue;
      _enqueue(t.id);
    }
  }

  /// 启动补跑：App 关着错过了当天的定时任务，打开 App 后补跑一次。
  Future<void> _catchUpMissed() async {
    final now = DateTime.now();
    for (final t in state.tasks) {
      if (!_isDailyEnabled(t)) continue;
      final last = t.lastRunAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(t.lastRunAt!);
      final ranToday = last != null &&
          last.year == now.year &&
          last.month == now.month &&
          last.day == now.day;
      if (ranToday) continue;
      // 只补跑「计划时间已过」的；计划时间还没到交给 tick。
      final due = DateTime(now.year, now.month, now.day,
          t.scheduleHour ?? 0, t.scheduleMinute ?? 0);
      if (now.isBefore(due)) continue;
      _enqueue(t.id);
    }
  }

  bool _isDailyEnabled(TaskRow t) =>
      t.enabled && t.scheduleType == 'daily' && t.scheduleHour != null;

  bool _isDueToday(TaskRow t, DateTime now) {
    if (!_isDailyEnabled(t)) return false;
    if (t.scheduleHour != now.hour || t.scheduleMinute != now.minute) {
      return false;
    }
    final last = t.lastRunAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(t.lastRunAt!);
    final ranToday = last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day;
    return !ranToday;
  }

  /// 入队运行（串行执行，立即返回）。
  ///
  /// 不用 then(...).catchError((_) {})：run 返回 Future<bool>，
  /// catchError 回调必须返回 bool 才满足类型（CI run#24 的
  /// body_might_complete_normally_catch_error）。包一层 async 吞掉即可。
  void _enqueue(String id) {
    _queue = _queue.then((_) async {
      try {
        await run(id);
      } catch (_) {
        // 单个任务失败不阻断队列
      }
    });
  }

  // ---------------- 运行 ----------------

  /// 运行一个任务（手动或调度触发）。返回是否成功。
  ///
  /// 期间任务卡片显示转圈（runningIds）；结束后写回结果并发通知。
  Future<bool> run(String id) async {
    final task = state.byId(id);
    if (task == null) return false;
    if (state.runningIds.contains(id)) return false;

    final config = _getConfig();
    if (config == null || config.chatModel == null) {
      await _record(task, 'fail', '未配置模型服务：请先到「我的 → AI 提供商」配置并选择模型。');
      return false;
    }

    state = state.copyWith(
        runningIds: {...state.runningIds, id});

    final buf = StringBuffer();
    var failed = false;
    try {
      await for (final ev in _orchestrator.run(
        config: config,
        history: [
          ChatMessage(
            id: uniqueId('task'),
            role: 'user',
            content: task.prompt,
          ),
        ],
        thinking: _getThinking(),
        reasoningEffort: _getReasoningEffort(),
      )) {
        if (ev is AgentAnswer) {
          buf.clear();
          buf.write(ev.message.content);
        } else if (ev is AgentFailure) {
          buf.clear();
          buf.write(ev.message);
          failed = true;
        }
      }
    } catch (e) {
      buf.clear();
      buf.write('任务执行异常：$e');
      failed = true;
    } finally {
      final ids = {...state.runningIds}..remove(id);
      if (mounted) state = state.copyWith(runningIds: ids);
    }

    final ok = !failed && buf.toString().trim().isNotEmpty;
    await _record(task, ok ? 'ok' : 'fail', buf.toString());
    return ok;
  }

  /// 写回运行结果 + 发系统通知。
  Future<void> _record(TaskRow task, String status, String result) async {
    await _storage.recordTaskRun(
      task.id,
      lastRunAt: DateTime.now().millisecondsSinceEpoch,
      status: status,
      result: result.trim().isEmpty ? '（无输出）' : result,
    );
    await load();
    final summary = result.trim().isEmpty
        ? '（无输出）'
        : (result.characters.length > 80
            ? '${result.characters.take(80).toString()}…'
            : result);
    unawaited(_notifications.notifyTaskDone(
      title:
          '${status == 'ok' ? '✅' : '⚠️'} ${task.emoji} ${task.name} ${status == 'ok' ? '已完成' : '运行失败'}',
      detail: summary,
    ));
  }
}

/// 自动任务状态（任务页 + 调度器共用）。
final tasksProvider =
    StateNotifierProvider<TasksNotifier, TasksState>((ref) {
  final notifier = TasksNotifier(
    storage: ref.watch(storageServiceProvider),
    orchestrator: ref.watch(orchestratorProvider),
    notifications: ref.watch(notificationServiceProvider),
    getConfig: () => ref.read(configProvider).activeConfig,
    getThinking: () => ref.read(thinkingProvider),
    getReasoningEffort: () => ref.read(reasoningEffortProvider),
  );
  return notifier;
});

// ---------------- 云端服务（orion_agent_cloud 后端） ----------------

/// 套餐显示名。
String cloudPlanLabel(String plan) {
  switch (plan) {
    case 'trial':
      return '试用版';
    case 'pro':
      return '专业版';
    case 'lifetime':
      return '永久授权';
    default:
      return '免费版';
  }
}

class CloudState {
  const CloudState({
    this.restoring = false,
    this.loggedIn = false,
    this.plan = 'free',
    this.planExpiresAt,
    this.usageToday = const {},
    this.busy = false,
    this.error,
  });

  final bool restoring;
  final bool loggedIn;
  final String plan;
  final int? planExpiresAt;
  final Map<String, int> usageToday;
  final bool busy;
  final String? error;

  CloudState copyWith({
    bool? restoring,
    bool? loggedIn,
    String? plan,
    int? planExpiresAt,
    Map<String, int>? usageToday,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      CloudState(
        restoring: restoring ?? this.restoring,
        loggedIn: loggedIn ?? this.loggedIn,
        plan: plan ?? this.plan,
        planExpiresAt: planExpiresAt ?? this.planExpiresAt,
        usageToday: usageToday ?? this.usageToday,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class CloudNotifier extends StateNotifier<CloudState> {
  CloudNotifier(this._cloud, this._mcp) : super(const CloudState());

  static const _cloudMcpName = 'orion-cloud';

  final CloudService _cloud;
  final McpService _mcp;

  /// 启动时恢复登录态（只读本地，静默失败）。联网刷新延迟到首个请求的
  /// 401 路径，避免拖慢启动。
  Future<void> bootstrap() async {
    if (!_cloud.isConfigured) return;
    state = state.copyWith(restoring: true);
    await _cloud.restore();
    if (!mounted) return;
    state = state.copyWith(
      restoring: false,
      loggedIn: _cloud.isLoggedIn,
    );
    if (_cloud.isLoggedIn) {
      // 静默刷新套餐/用量，失败不打扰
      await refreshStatus();
    }
  }

  Future<void> setBaseUrl(String url) async {
    state = state.copyWith(busy: true, clearError: true);
    await _cloud.setBaseUrl(url);
    if (!mounted) return;
    state = state.copyWith(busy: false);
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _cloud.login(email, password);
      state = state.copyWith(busy: false, loggedIn: true, plan: _cloud.plan);
      await refreshStatus();
      // 登录成功后自动配置云端 MCP（幂等）
      await _ensureCloudMcp();
      return true;
    } on CloudException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    } catch (e) {
      state = state.copyWith(busy: false, error: '登录失败：$e');
    }
    return false;
  }

  Future<bool> register(String email, String password) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _cloud.register(email, password);
      state = state.copyWith(busy: false, loggedIn: true, plan: 'free');
      await refreshStatus();
      await _ensureCloudMcp();
      return true;
    } on CloudException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    } catch (e) {
      state = state.copyWith(busy: false, error: '注册失败：$e');
    }
    return false;
  }

  Future<void> logout() async {
    await _cloud.logout();
    state = const CloudState();
  }

  Future<bool> activate(String code) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _cloud.activate(code);
      await refreshStatus();
      state = state.copyWith(busy: false, error: null);
      return true;
    } on CloudException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    } catch (e) {
      state = state.copyWith(busy: false, error: '激活失败：$e');
    }
    return false;
  }

  /// 刷新套餐与今日用量。静默失败（不打扰 UI）。
  Future<void> refreshStatus() async {
    try {
      final info = await _cloud.fetchAccountInfo();
      state = state.copyWith(
        loggedIn: true,
        plan: info.plan,
        planExpiresAt: info.planExpiresAt,
        usageToday: info.usageToday,
      );
    } catch (_) {
      // 状态刷新失败保持现状（可能是离线），下次再试
    }
  }

  /// 登录成功后确保云端 MCP 服务器已配置（幂等）：
  /// 设备令牌编进 URL（orion 的 MCP 配置只有 URL 字段），名称固定
  /// 「orion-cloud」，已有配置则只在 URL 变化时替换。
  Future<void> _ensureCloudMcp() async {
    try {
      final base = _cloud.baseUrl;
      if (base == null || !_cloud.isLoggedIn) return;
      final token = await _cloud.getOrCreateDeviceToken();
      if (token.isEmpty) return;
      final url = '$base/api/mcp?token=$token';
      final servers = await _mcp.listServers();
      McpServer? existing;
      for (final s in servers) {
        if (s.name == _cloudMcpName) existing = s;
      }
      if (existing != null && existing.url == url) return;
      if (existing != null) await _mcp.removeServer(existing.id);
      await _mcp.addServer(_cloudMcpName, url);
      await _mcp.connectAll();
    } catch (e) {
      debugPrint('云端 MCP 自动配置失败（不影响登录）：$e');
    }
  }
}

final cloudServiceProvider = Provider<CloudService>((ref) =>
    CloudService(ref.watch(sharedPreferencesProvider), const FlutterSecureStorage()));

final cloudProvider = StateNotifierProvider<CloudNotifier, CloudState>((ref) =>
    CloudNotifier(
      ref.watch(cloudServiceProvider),
      ref.watch(mcpServiceProvider),
    ));
