import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/llm_config.dart';
import '../services/agent_orchestrator.dart';
import '../services/database.dart';
import '../services/llm_client.dart';
import '../services/mcp_service.dart';
import '../services/memory_service.dart';
import '../services/rag_service.dart';
import '../services/role_service.dart';
import '../services/skill_service.dart';
import '../services/storage_service.dart';
import '../services/tools.dart';
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
    ));

final llmClientProvider = Provider<LlmClient>(
    (ref) => LlmClient(Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)))));

final orchestratorProvider = Provider<AgentOrchestrator>((ref) => AgentOrchestrator(
      llm: ref.watch(llmClientProvider),
      tools: ref.watch(toolRegistryProvider),
      memory: ref.watch(memoryServiceProvider),
    ));

final voiceProvider = Provider<VoiceService>((ref) => VoiceService());

final skillServiceProvider =
    Provider<SkillService>((ref) => SkillService(ref.watch(databaseProvider)));

final roleServiceProvider =
    Provider<RoleService>((ref) => RoleService(ref.watch(databaseProvider)));

/// 当前激活的 Agent 角色 id（'' = 默认助手）。
final activeRoleIdProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('active_role_id') ?? '';
});

/// 技能页 → 聊天输入框的预填文本（用后即清）。
final prefillProvider = StateProvider<String>((ref) => '');

final mcpServiceProvider = Provider<McpService>((ref) =>
    McpService(ref.watch(databaseProvider), ref.watch(toolRegistryProvider)));

// ---------------- 模型配置 ----------------

class ConfigState {
  final List<LlmConfig> configs;
  final String activeId;

  const ConfigState({required this.configs, required this.activeId});

  LlmConfig? get activeConfig {
    for (final c in configs) {
      if (c.id == activeId) return c;
    }
    return configs.isEmpty ? null : configs.first;
  }
}

/// 配置存两处：配置 JSON（含 API Key）进 flutter_secure_storage
/// （Keychain/Keystore 加密），activeId 进 shared_preferences。
class ConfigNotifier extends StateNotifier<ConfigState> {
  ConfigNotifier(this._prefs, this._secure)
      : super(const ConfigState(configs: [], activeId: '')) {
    _load();
  }

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kConfigs = 'llm_configs';
  static const _kActive = 'llm_active_id';

  Future<void> _load() async {
    var raw = await _secure.read(key: _kConfigs);
    if (raw == null) {
      // 旧版本把配置明文存在 shared_preferences，迁移到加密存储后删除明文。
      final legacy = _prefs.getString(_kConfigs);
      if (legacy != null) {
        raw = legacy;
        await _secure.write(key: _kConfigs, value: legacy);
        await _prefs.remove(_kConfigs);
      }
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
      } catch (_) {}
    }
    if (!mounted) return;
    state = ConfigState(configs: list, activeId: _prefs.getString(_kActive) ?? '');
  }

  Future<void> _persist() async {
    await _secure.write(key: _kConfigs,
        value: jsonEncode(state.configs.map((c) => c.toJson()).toList()));
    await _prefs.setString(_kActive, state.activeId);
  }

  void upsert(LlmConfig config) {
    final list = [...state.configs];
    final idx = list.indexWhere((c) => c.id == config.id);
    if (idx >= 0) {
      list[idx] = config;
    } else {
      list.add(config);
    }
    state = ConfigState(configs: list, activeId: state.activeId);
    _persist();
  }

  void remove(String id) {
    final list = state.configs.where((c) => c.id != id).toList();
    state = ConfigState(
      configs: list,
      activeId: state.activeId == id ? '' : state.activeId,
    );
    _persist();
  }

  void setActive(String id) {
    state = ConfigState(configs: state.configs, activeId: id);
    _persist();
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
  final List<String> steps;
  final String? error;

  const ChatState({
    required this.sessions,
    this.activeSessionId,
    this.isStreaming = false,
    this.streamingContent = '',
    this.steps = const [],
    this.error,
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
    String? streamingContent,
    List<String>? steps,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        sessions: sessions ?? this.sessions,
        activeSessionId: activeSessionId ?? this.activeSessionId,
        isStreaming: isStreaming ?? this.isStreaming,
        streamingContent: streamingContent ?? this.streamingContent,
        steps: steps ?? this.steps,
        error: clearError ? null : (error ?? this.error),
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
  })  : _storage = storage,
        _orchestrator = orchestrator,
        _rag = rag,
        _llm = llm,
        _voice = voice,
        _ttsEnabled = ttsEnabled,
        _getPersona = getPersona,
        _getConfig = getConfig,
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

  CancelToken? _cancelToken;

  String _newId(String prefix) =>
      '${prefix}_${DateTime.now().millisecondsSinceEpoch}_${state.sessions.length}';

  void newSession() {
    final s = ChatSession(
      id: _newId('sess'),
      messages: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    state = state.copyWith(sessions: [s, ...state.sessions], activeSessionId: s.id, clearError: true);
    _storage.insertSession(s);
  }

  void selectSession(String id) {
    state = state.copyWith(activeSessionId: id, clearError: true);
  }

  void deleteSession(String id) {
    final remaining = state.sessions.where((s) => s.id != id).toList();
    final newActive = state.activeSessionId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeSessionId;
    state = state.copyWith(sessions: remaining, activeSessionId: newActive);
    _storage.deleteSession(id);
  }

  Future<void> clearAllSessions() async {
    state = ChatState(sessions: const [], activeSessionId: null);
    await _storage.clearSessions();
  }

  void _touch(ChatSession updated) {
    final sessions = state.sessions.map((s) => s.id == updated.id ? updated : s).toList();
    state = state.copyWith(sessions: sessions);
    _storage.updateSessionMeta(updated);
  }

  Future<void> send(String text, {List<String> images = const []}) async {
    final content = text.trim();
    if ((content.isEmpty && images.isEmpty) || state.isStreaming) return;

    final config = _getConfig();
    if (config == null) {
      state = state.copyWith(error: '请先在「设置」中添加并选择一个模型服务。');
      return;
    }

    var session = state.activeSession;
    if (session == null) {
      newSession();
      session = state.activeSession;
      if (session == null) return;
    }

    final userMsg = ChatMessage(
      id: 'u_${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: content,
      images: images,
    );
    final updated = session
      ..messages.add(userMsg)
      ..updatedAt = DateTime.now();
    if (session.title == '新对话') {
      updated.title = content.isEmpty
          ? '[图片]'
          : (content.length > 16 ? '${content.substring(0, 16)}…' : content);
    }
    _touch(updated);
    _storage.insertMessage(session.id, userMsg);

    state = state.copyWith(
      isStreaming: true,
      streamingContent: '',
      steps: [],
      clearError: true,
    );

    _cancelToken = CancelToken();
    final history = List<ChatMessage>.from(updated.messages);

    // 发送前自动检索知识库（未配置 embedding 模型或检索失败时静默跳过）
    var knowledge = const <RagHit>[];
    if (config.embeddingModel.trim().isNotEmpty) {
      try {
        knowledge = await _rag.search(
          query: content,
          embedOne: (q) async =>
              (await _llm.embedBatch(config: config, inputs: [q])).first,
        );
      } catch (_) {}
    }

    final buf = StringBuffer();
    ChatMessage? answer;

    try {
      await for (final ev in _orchestrator.run(
        config: config,
        history: history,
        cancelToken: _cancelToken,
        knowledge: knowledge,
        persona: _getPersona(),
      )) {
        if (ev is AgentDelta) {
          buf.write(ev.delta);
          state = state.copyWith(streamingContent: buf.toString());
        } else if (ev is AgentStatus) {
          state = state.copyWith(steps: [...state.steps, '⏳ ${ev.text}']);
        } else if (ev is AgentToolDone) {
          final brief = ev.result.length > 120
              ? '${ev.result.substring(0, 120)}…'
              : ev.result;
          state = state.copyWith(
              steps: [...state.steps, '🔧 ${ev.toolName} → $brief']);
        } else if (ev is AgentAnswer) {
          answer = ev.message;
        } else if (ev is AgentFailure) {
          state = state.copyWith(error: ev.message);
        }
      }
    } catch (e) {
      state = state.copyWith(error: '运行出错：$e');
    }

    // 最终回答写入会话历史（工具中间过程不入库，节省上下文长度）
    final s2 = state.activeSession;
    if (answer != null && s2 != null) {
      s2.messages.add(answer);
      s2.updatedAt = DateTime.now();
      _touch(s2);
      _storage.insertMessage(s2.id, answer);
      if (_ttsEnabled()) {
        _voice.speak(answer.content);
      }
    }

    state = state.copyWith(isStreaming: false, streamingContent: '', steps: []);
    _cancelToken = null;
  }

  Future<void> stop() async {
    final t = _cancelToken;
    if (t != null && !t.isCancelled) {
      t.cancel();
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(
    initialSessions: ref.watch(initialSessionsProvider),
    storage: ref.watch(storageServiceProvider),
    orchestrator: ref.watch(orchestratorProvider),
    rag: ref.watch(ragServiceProvider),
    llm: ref.watch(llmClientProvider),
    voice: ref.watch(voiceProvider),
    ttsEnabled: () =>
        ref.read(sharedPreferencesProvider).getBool('tts_enabled') ?? false,
    getPersona: () {
      final id = ref.read(activeRoleIdProvider);
      return ref.read(roleServiceProvider).promptOf(id) ?? '';
    },
    getConfig: () => ref.read(configProvider).activeConfig,
  );
});
