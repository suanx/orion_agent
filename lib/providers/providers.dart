import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/llm_config.dart';
import '../services/agent_orchestrator.dart';
import '../services/llm_client.dart';
import '../services/memory_service.dart';
import '../services/storage_service.dart';
import '../services/tools.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import 'package:dio/dio.dart';
import 'dart:async';

/// 在 main() 中 override 注入。
final sharedPreferencesProvider =
    Provider<SharedPreferences>((ref) => throw UnimplementedError());

/// 在 main() 中 override 注入（启动时已从磁盘加载）。
final initialSessionsProvider =
    Provider<List<ChatSession>>((ref) => throw UnimplementedError());

final storageServiceProvider = Provider<StorageService>((ref) => StorageService());

final memoryServiceProvider = Provider<MemoryService>((ref) {
  final m = MemoryService();
  // load() 在 addNote/removeNote 内部会自动触发
  return m;
});

final toolRegistryProvider = Provider<ToolRegistry>((ref) =>
    ToolRegistry(memoryService: ref.watch(memoryServiceProvider)));

final llmClientProvider = Provider<LlmClient>(
    (ref) => LlmClient(Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)))));

final orchestratorProvider = Provider<AgentOrchestrator>((ref) => AgentOrchestrator(
      llm: ref.watch(llmClientProvider),
      tools: ref.watch(toolRegistryProvider),
      memory: ref.watch(memoryServiceProvider),
    ));

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

class ConfigNotifier extends StateNotifier<ConfigState> {
  ConfigNotifier(this._prefs)
      : super(const ConfigState(configs: [], activeId: '')) {
    _load();
  }

  final SharedPreferences _prefs;

  static const _kConfigs = 'llm_configs';
  static const _kActive = 'llm_active_id';

  void _load() {
    final raw = _prefs.getString(_kConfigs);
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
    state = ConfigState(configs: list, activeId: _prefs.getString(_kActive) ?? '');
  }

  void _persist() {
    _prefs.setString(
        _kConfigs, jsonEncode(state.configs.map((c) => c.toJson()).toList()));
    _prefs.setString(_kActive, state.activeId);
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
  return ConfigNotifier(ref.watch(sharedPreferencesProvider));
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
    bool clearActiveSession = false,
    bool? isStreaming,
    String? streamingContent,
    List<String>? steps,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        sessions: sessions ?? this.sessions,
        activeSessionId: clearActiveSession
            ? null
            : (activeSessionId ?? this.activeSessionId),
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
    required LlmConfig? Function() getConfig,
  })  : _storage = storage,
        _orchestrator = orchestrator,
        _getConfig = getConfig,
        super(ChatState(
          sessions: initialSessions,
          activeSessionId: initialSessions.isEmpty ? null : initialSessions.first.id,
        ));

  final StorageService _storage;
  final AgentOrchestrator _orchestrator;
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
    _persist();
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
    _persist();
  }

  void _persist() {
    _storage.saveSessions(state.sessions);
  }

  void _touch(ChatSession updated) {
    final sessions = state.sessions.map((s) => s.id == updated.id ? updated : s).toList();
    state = state.copyWith(sessions: sessions);
  }

  Future<void> send(String text) async {
    final content = text.trim();
    if (content.isEmpty || state.isStreaming) return;

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
    );
    final updated = session
      ..messages.add(userMsg)
      ..updatedAt = DateTime.now();
    if (session.title == '新对话') {
      updated.title =
          content.length > 16 ? '${content.substring(0, 16)}…' : content;
    }
    _touch(updated);
    _persist();

    state = state.copyWith(
      isStreaming: true,
      streamingContent: '',
      steps: [],
      clearError: true,
    );

    _cancelToken = CancelToken();
    final history = List<ChatMessage>.from(updated.messages);

    final buf = StringBuffer();
    ChatMessage? answer;

    try {
      await for (final ev in _orchestrator.run(
        config: config,
        history: history,
        cancelToken: _cancelToken,
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
      _persist();
    }

    state = state.copyWith(isStreaming: false, streamingContent: '', steps: []);
    _cancelToken = null;
  }

  Future<void> stop() async {
    final t = _cancelToken;
    if (t != null && !t.isCancelled) {
      await t.cancel();
    }
  }
}

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(
    initialSessions: ref.watch(initialSessionsProvider),
    storage: ref.watch(storageServiceProvider),
    orchestrator: ref.watch(orchestratorProvider),
    getConfig: () => ref.read(configProvider).activeConfig,
  );
});
