import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' show ThemeMode;
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
import '../services/notification_service.dart';
import '../services/rag_service.dart';
import '../services/role_service.dart';
import '../services/skill_service.dart';
import '../services/storage_service.dart';
import '../services/terminal_service.dart';
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
      terminalService: ref.watch(terminalServiceProvider),
    ));

final llmClientProvider = Provider<LlmClient>(
    (ref) => LlmClient(Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)))));

final orchestratorProvider = Provider<AgentOrchestrator>((ref) => AgentOrchestrator(
      llm: ref.watch(llmClientProvider),
      tools: ref.watch(toolRegistryProvider),
      memory: ref.watch(memoryServiceProvider),
    ));

final voiceProvider = Provider<VoiceService>((ref) => VoiceService());

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());

/// 当前语音合成引擎（edge = 免 Key 在线合成，system = 系统 TTS）。
final ttsEngineProvider = StateProvider<TtsEngine>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('tts_engine') == 'system'
      ? TtsEngine.system
      : TtsEngine.edge;
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

final roleServiceProvider =
    Provider<RoleService>((ref) => RoleService(ref.watch(databaseProvider)));

/// 当前激活的 Agent 角色 id（'' = 默认助手）。
final activeRoleIdProvider = StateProvider<String>((ref) {
  return ref.watch(sharedPreferencesProvider).getString('active_role_id') ?? '';
});

/// 技能页 → 聊天输入框的预填文本（用后即清）。
final prefillProvider = StateProvider<String>((ref) => '');

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
    TtsEngine Function()? getTtsEngine,
    String Function()? getTtsVoice,
    double Function()? getTtsRate,
    double Function()? getTtsVolume,
    bool Function()? notifyOnAnswer,
    bool Function()? notifyPreview,
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
  final bool Function() _notifyPreview;

  /// 由外部注入的通知发送回调（在 Provider 里绑定 NotificationService）。
  Future<void> Function(String title, String body)? onAnswerNotification;

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

  /// 清除当前错误提示（供 UI 关闭错误条使用）。
  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
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
    // 同样避免就地修改：构造新的 ChatSession 再交给 _touch。
    final title = session.title == '新对话'
        ? (content.isEmpty
            ? '[图片]'
            : (content.length > 16 ? '${content.substring(0, 16)}…' : content))
        : session.title;
    final updated = ChatSession(
      id: session.id,
      title: title,
      messages: [...session.messages, userMsg],
      createdAt: session.createdAt,
      updatedAt: DateTime.now(),
    );
    _touch(updated);
    _storage.insertMessage(updated.id, userMsg);

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
      _touch(withAnswer);
      _storage.insertMessage(withAnswer.id, answer);

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
            ? (brief.length > 120 ? '${brief.substring(0, 120)}…' : brief)
            : '';
        unawaited(onAnswerNotification?.call(
          withAnswer.title,
          body,
        ));
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
  final notifier = ChatNotifier(
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
    getTtsEngine: () => ref.read(ttsEngineProvider),
    getTtsVoice: () => ref.read(ttsVoiceProvider),
    getTtsRate: () => ref.read(ttsRateProvider),
    getTtsVolume: () => ref.read(ttsVolumeProvider),
    notifyOnAnswer: () => ref.read(notifyOnAnswerProvider),
    notifyPreview: () => ref.read(notifyPreviewProvider),
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
