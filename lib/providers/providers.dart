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
import '../services/agent_artifact_service.dart';
import '../services/backup_service.dart';
import '../services/cloud_service.dart';
import '../services/cloud_model_service.dart';
import '../services/cloud_sync_service.dart';
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

/// 备份与恢复：读写四类数据域（供应商 / 聊天历史 / MCP / 应用设置）。
final backupServiceProvider = Provider<BackupService>((ref) => BackupService(
      ref.watch(databaseProvider),
      ref.watch(sharedPreferencesProvider),
      const FlutterSecureStorage(),
    ));

/// 启动时自动同步一次（仅当已登录 + 已开启 + 已解锁）。
///
/// 失败一律静默：网络不通或密钥缺失都不该阻塞启动，用户可在
/// 「备份与恢复 → 多端同步」里手动触发并看到错误。
final cloudAutoSyncProvider = FutureProvider<void>((ref) async {
  final cloud = ref.watch(cloudServiceProvider);
  if (!cloud.isLoggedIn) return;
  final sync = ref.watch(cloudSyncServiceProvider);
  if (!sync.isEnabled || !sync.isUnlocked) return;
  try {
    await sync.syncNow();
  } catch (_) {
    // 忽略
  }
});

/// 云端备份 + 多端同步（端上 AES-GCM 加密，服务端只存密文）。
///
/// 密钥由账号密码 PBKDF2 派生后存进系统安全存储，**不保存密码本身**；
/// 因此换设备时需在新设备上输入同一密码解锁一次。
final cloudSyncServiceProvider = Provider<CloudSyncService>((ref) {
  return CloudSyncService(
    ref.watch(cloudServiceProvider),
    ref.watch(databaseProvider),
    ref.watch(sharedPreferencesProvider),
    const FlutterSecureStorage(),
    backup: ref.watch(backupServiceProvider),
  );
});

/// 长期记忆条数（响应式）。
///
/// 之前「我的」页直接读 `memory.notes.length`：MemoryService 是普通
/// Provider（非响应式）且懒加载，profile 首次 build 时 load() 还没被
/// 调过 → 恒显示 0 条（记忆页有记录也不刷新）。
/// 改为 FutureProvider：watch 到它即触发 load()；任何增删后调用方
/// `ref.invalidate(memoryCountProvider)` 刷新（load 幂等，已加载时
/// 直接返回内存中的最新列表）。
final memoryCountProvider = FutureProvider<int>((ref) async {
  final memory = ref.watch(memoryServiceProvider);
  await memory.load();
  return memory.notes.length;
});

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

final llmClientProvider = Provider<LlmClient>((ref) => LlmClient(
      Dio(BaseOptions(connectTimeout: const Duration(seconds: 30))),
      // 云端模型/Agent 的鉴权用云端登录令牌（真正的上游 Key 在后端），
      // 令牌在过期前自动续期。
      cloudTokenProvider: ref.watch(cloudServiceProvider).validAccessToken,
    ));

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

/// 云端 Agent 沙箱产物服务（文件树 / 文件内容 / dev server）。
final agentArtifactServiceProvider = Provider<AgentArtifactService>(
    (ref) => AgentArtifactService(ref.watch(cloudServiceProvider)));

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

/// 对话字体缩放系数（持久化，默认 1.0 标准字号）。
///
/// 只作用于对话页的【消息区域】（用户气泡 / Markdown 正文 / 思考面板），
/// 通过 MediaQuery textScaler 实现，顶栏与输入栏不受影响。
/// 取值来自 FontSettingsScreen 的四档预设（0.85 / 1.0 / 1.15 / 1.3），
/// 不开放任意滑杆——文字排版在极端缩放下（行高/气泡宽度）需要人工校验。
final chatFontScaleProvider = StateProvider<double>((ref) {
  return ref.watch(sharedPreferencesProvider)
          .getDouble('chat_font_scale') ??
      1.0;
});

/// 是否加入 Beta 测试（持久化，默认关闭）。
///
/// 开启后更新检查改走 GitHub releases 列表（含 pre-release），
/// 会提示安装标记为「预发布」的测试版本（可能不稳定）。
/// 入口：关于页「加入 Beta 测试」开关。
final betaOptInProvider = StateProvider<bool>((ref) {
  return ref.watch(sharedPreferencesProvider).getBool('beta_opt_in') ?? false;
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
  /// 规则：**优先用用户在对话页选中的那条**（[activeId]，模型选择浮层
  /// 跨提供商选模型时写入）；没有记录或该条已停用/未就绪时，退回
  /// **列表顺序里第一个「已启用且可用」的配置**。多选启用是允许的
  /// （列表页就是多个「已启用」徽标），但一次对话只能用一个提供商。
  ///
  /// 逐级降级，保证老数据不会因为没人勾选 enabled 而彻底用不了：
  /// 用户选中的已启用且可用 → 已启用且可用 → 已启用 → 任意一条 → null。
  LlmConfig? get activeConfig {
    for (final c in configs) {
      if (c.id == activeId && c.enabled && c.ready) return c;
    }
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
    // 云端配置不落盘（见 injectCloudConfigs 的说明）：用户切换云端模型
    // 只影响本次会话的内存态，下次进来重新从后端拉。
    if (!_isCloudManaged(config)) {
      _localTouched = true;
    }
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
    if (!_isCloudManaged(config)) {
      _schedulePersist();
    }
  }

  /// 是否为「后端托管」的配置（云端模型 `cloud:` / 云端 Agent `agent:`）。
  /// 这些不该落盘，也不该被用户删除。
  static bool _isCloudManaged(LlmConfig c) =>
      c.id.startsWith('cloud:') || c.id.startsWith('agent:');

  /// 就地替换某条配置（按 id）。
  LlmConfig? byId(String id) {
    for (final c in state.configs) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 注入云端托管配置（**仅内存，不落盘**）。
  ///
  /// 包含云端模型（`cloud:`）与云端 Agent（`agent:`）—— 两者都由后端持密钥、
  /// 随账号下发，不该写进 shared_preferences：
  /// 一是会把配置混入备份/多端同步，二是后端改了配置后本地这份就成了
  /// 过期副本。每次刷新都整体替换，避免残留。
  ///
  /// 落盘的 `defaultChatModel` 切换则走 [upsert]（用户主动选模型时），
  /// 那里同样会跳过托管配置的持久化。
  void injectCloudConfigs(List<LlmConfig> cloudConfigs) {
    // 先剔除旧的托管配置，再追加新的
    final localOnly =
        state.configs.where((c) => !_isCloudManaged(c)).toList();
    state = state.copyWith(configs: [...localOnly, ...cloudConfigs]);
    // activeId 指向已消失的托管配置时清空，避免 activeConfig 取不到值
    if (_isCloudManagedId(state.activeId) &&
        !cloudConfigs.any((c) => c.id == state.activeId)) {
      state = state.copyWith(activeId: '');
    }
  }

  static bool _isCloudManagedId(String id) =>
      id.startsWith('cloud:') || id.startsWith('agent:');

  void remove(String id) {
    // 云端托管配置由后端管理，用户删不掉（下次刷新会重新注入）。
    // 真正的"停用"需求由后端的 enabled 开关承担。
    if (_isCloudManagedId(id)) return;
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

  /// 记下用户在对话页模型浮层选中的提供商（activeConfig 优先用它）。
  /// 该条配置之后被停用/删除时，activeConfig 自动按降级链回退。
  void setActive(String id) {
    _localTouched = true;
    state = state.copyWith(activeId: id);
    _schedulePersist();
  }

  /// 覆盖某条配置的模型列表（「拉取模型」用）。
  void setModels(String id, List<ProviderModel> models) {    final c = byId(id);
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

/// 单个会话的流式进度。多个对话可同时各自生成，按会话各存一份。
class SessionStream {
  /// 生成中的回答正文。
  final String content;

  /// 流式期间的思考过程（开启思考且模型返回时才有内容）。
  final String reasoning;

  /// 状态行（⏳ 正在调用工具 / 🔧 工具完成）。
  final List<String> steps;

  const SessionStream({
    this.content = '',
    this.reasoning = '',
    this.steps = const [],
  });

  SessionStream copyWith({
    String? content,
    String? reasoning,
    List<String>? steps,
  }) =>
      SessionStream(
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        steps: steps ?? this.steps,
      );
}

class ChatState {
  final List<ChatSession> sessions;
  final String? activeSessionId;

  /// 流式状态按会话隔离：key = sessionId，value = 该会话的生成进度。
  /// 每个正在生成的对话各有一份，互不干扰——A 生成期间切到 B 发消息，
  /// 两条流并行推进，「停止」也只作用于当前会话。
  final Map<String, SessionStream> streams;

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
    this.streams = const {},
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

  /// 当前激活会话的流式进度；该会话未在生成时为 null。
  SessionStream? get activeStream =>
      activeSessionId == null ? null : streams[activeSessionId];

  /// 激活会话是否正在生成。UI 的发送/停止按钮与并发守卫都看这个——
  /// 只有【当前】会话在生成时才拦截；别的会话在生成不影响本会话发消息。
  bool get isStreaming => activeStream != null;

  /// 以下三个派生视图：只取激活会话的进度，其它会话的流不串台。
  String get streamingContent => activeStream?.content ?? '';
  String get streamingReasoning => activeStream?.reasoning ?? '';
  List<String> get steps => activeStream?.steps ?? const [];

  /// 指定会话是否正在生成（会话列表的「生成中」标记用）。
  bool isSessionStreaming(String id) => streams.containsKey(id);

  ChatState copyWith({
    List<ChatSession>? sessions,
    String? activeSessionId,
    Map<String, SessionStream>? streams,
    String? error,
    bool clearError = false,
    int? sessionPromptTokens,
    int? sessionCompletionTokens,
    int? toolRoundsBuiltIn,
    int? toolRoundsMcp,
    int? compressionCount,
  }) =>
      ChatState(
        sessions: sessions ?? this.sessions,
        activeSessionId: activeSessionId ?? this.activeSessionId,
        streams: streams ?? this.streams,
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
    void Function(int used, int limit)? onQuotaUsed,
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
        _onQuotaUsed = onQuotaUsed,
        super(ChatState(
          sessions: initialSessions,
          activeSessionId: initialSessions.isEmpty ? null : initialSessions.first.id,
        )) {
    // 启动只载入会话元信息（P1）：初始活跃会话的消息按需补载
    if (initialSessions.isNotEmpty) {
      unawaited(_ensureMessages(initialSessions.first.id));
    }
  }

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

  /// 云端模型每轮对话后回调（把已用/上限传出去更新额度卡片）。
  /// 为 null 表示不关心额度（非云端场景）。
  final void Function(int used, int limit)? _onQuotaUsed;

  /// 已做过标题总结的会话 id（内存即可：重启后标题已持久化）。
  final _titleSummarized = <String>{};

  /// 每会话用量：[prompt, completion, 内置工具轮, MCP 工具轮, 压缩次数]。
  /// 应用启动以来累计；会话切换时从该表恢复到 ChatState。
  final _usage = <String, List<int>>{};

  /// 由外部注入的通知发送回调（在 Provider 里绑定 NotificationService）。
  Future<void> Function(String title, String body)? onAnswerNotification;

  /// 每个会话一个取消令牌：停止/删除只动目标会话的那一条流，
  /// 不会殃及其它正在生成的对话（并行对话）。
  final _cancelTokens = <String, CancelToken>{};

  /// 上下文压缩流的取消令牌（按会话）：压缩进行中删除该会话时取消，
  /// 防止压缩完成后把已删除的消息重新插回（孤儿数据）。
  final _compressTokens = <String, CancelToken>{};

  /// send() 的同步互斥占位（按会话）。原实现依赖 state.isStreaming，但该标志
  /// 在首个 await（_persistOp）之后才置位——守卫与置位之间隔着
  /// await，两条并发 send 都能通过检查。同步集合在任何 await
  /// 之前检查并置位，彻底封死竞态窗口。
  /// 按会话隔离后，A 会话生成中不再阻塞 B 会话发消息。
  final _sending = <String>{};

  /// 流式期间每帧全量 state 重建是 O(n²) 拷贝；按时间合帧，
  /// 最多每 90ms 刷一次 UI（打字机观感不受影响）。按会话计时，
  /// 两条并行流各有自己的刷新窗口，互不抢帧。
  final _lastFlush = <String, DateTime>{};

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
    // 消息按需加载（P1）：切到某个会话时才把它的消息从 DB 读进内存
    unawaited(_ensureMessages(id));
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

  /// 已完成按需加载的会话 id。集合避免「空会话每次切换都查一次 DB」。
  final Set<String> _loadedSessions = {};

  /// 进行中的加载（id → Future）。selectSession 发起的加载还在跑时，
  /// 紧随其后的 send 必须等同一个 Future——只看 _loadedSessions 标记
  /// 会误判「已加载完成」，拿空历史把上下文发出去（并行对话下
  /// 「切过去马上发」是常态路径，这个窗口必须封死）。
  final _loadingMessages = <String, Future<void>>{};

  /// 确保会话消息已进内存（P1 按需加载）。已完成返回立即完成的 Future；
  /// 进行中则复用同一个 Future，多个调用方共享一次加载。
  Future<void> _ensureMessages(String id) {
    final inflight = _loadingMessages[id];
    if (inflight != null) return inflight;
    if (_loadedSessions.contains(id)) return Future<void>.value();
    final f = _loadMessages(id);
    _loadingMessages[id] = f;
    return f;
  }

  Future<void> _loadMessages(String id) async {
    _loadedSessions.add(id);
    List<ChatMessage> msgs;
    try {
      msgs = await _storage.loadMessages(id);
    } catch (e) {
      _loadedSessions.remove(id);
      debugPrint('会话消息按需加载失败：$e');
      return;
    } finally {
      _loadingMessages.remove(id);
    }
    if (!mounted) return;
    final idx = state.sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return; // 加载期间会话被删除
    final s = state.sessions[idx];
    if (s.messages.isNotEmpty) return; // 加载期间已写入新消息，不覆盖
    state = state.copyWith(sessions: [
      for (final x in state.sessions)
        x.id == id
            ? ChatSession(
                id: x.id,
                title: x.title,
                messages: msgs,
                createdAt: x.createdAt,
                updatedAt: x.updatedAt)
            : x,
    ]);
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

  /// 更新指定会话的流式进度。该会话的流已清理（被停止/删除）时
  /// 静默丢弃——收尾竞态里迟到的 delta 不该让状态复活。
  void _mutateStream(
      String sessionId, SessionStream Function(SessionStream) f) {
    if (!mounted) return;
    final cur = state.streams[sessionId];
    if (cur == null) return;
    state = state.copyWith(streams: {
      ...state.streams,
      sessionId: f(cur),
    });
  }

  /// 收尾一条流：清掉该会话的取消令牌/互斥占位/刷新计时与进度条目。
  /// 幂等：条目可能已被 deleteSession 提前移除。
  void _endStream(String sessionId) {
    _cancelTokens.remove(sessionId);
    _sending.remove(sessionId);
    _lastFlush.remove(sessionId);
    if (!mounted) return;
    if (!state.streams.containsKey(sessionId)) return;
    final m = {...state.streams}..remove(sessionId);
    state = state.copyWith(streams: m);
  }

  /// 清除当前错误提示（供 UI 关闭错误条使用）。
  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
  }

  void deleteSession(String id) {
    // 只停被删除会话自己的流（并行对话下别的会话继续生成）。
    // 压缩流是独立 CancelToken，同样按会话取消。
    // 先清进度条目：send() 收尾时的写入会因条目不存在被丢弃，
    // 用户消息变孤儿行的问题由「回答落库前按 id 查会话」兜底。
    _cancelTokens.remove(id)?.cancel();
    _compressTokens.remove(id)?.cancel();
    _sending.remove(id);
    _lastFlush.remove(id);
    if (state.streams.containsKey(id)) {
      final m = {...state.streams}..remove(id);
      state = state.copyWith(streams: m);
    }
    // 该会话的用量/标题记录同步清掉，否则 Map 只增不减（内存缓慢泄漏）。
    _usage.remove(id);
    _titleSummarized.remove(id);
    _loadedSessions.remove(id);
    final remaining = state.sessions.where((s) => s.id != id).toList();
    final newActive = state.activeSessionId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeSessionId;
    state = state.copyWith(sessions: remaining, activeSessionId: newActive);
    unawaited(_persistOp(() => _storage.deleteSession(id), '删除会话'));
    // 删除后活跃会话切换，其消息同样按需补载
    if (newActive != null) unawaited(_ensureMessages(newActive));
  }

  Future<void> clearAllSessions() async {
    // 同上：先停下所有流式（含压缩），避免删除后仍往里写入孤儿消息行。
    if (_sending.isNotEmpty || state.streams.isNotEmpty) {
      for (final t in _cancelTokens.values) {
        if (!t.isCancelled) t.cancel();
      }
      for (final t in _compressTokens.values) {
        if (!t.isCancelled) t.cancel();
      }
      // 给各 send() 一点时间收尾（它会检测流已清理并停止写入）
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _cancelTokens.clear();
    _compressTokens.clear();
    _sending.clear();
    _lastFlush.clear();
    _usage.clear();
    _titleSummarized.clear();
    _loadedSessions.clear();
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
    if (content.isEmpty && images.isEmpty) return;

    // 同步解析目标会话（newSession 内无 await，安全）。
    var session = state.activeSession;
    if (session == null) {
      newSession();
      session = state.activeSession;
      if (session == null) return;
    }
    // 同步互斥（按会话）：在任何 await 之前检查并占位（流进度要到
    // 首个 await 之后才写入，只靠它会被并发 send 击穿）。
    // 同一会话禁止并发 send；其它会话正在生成不拦——多个对话可同时各自流式。
    final sid = session.id;
    if (_sending.contains(sid) || state.streams.containsKey(sid)) return;
    _sending.add(sid);

    final config = _getConfig();
    if (config == null) {
      _sending.remove(sid);
      state = state.copyWith(error: '请先在「设置」中添加并选择一个模型服务。');
      return;
    }

    // 会话消息是按需加载的（P1）：必须等历史进内存后才能拼上下文。
    // 按 sid 重取而不是读 activeSession——等待期间用户可能已切到别的会话，
    // 读活跃会话会把这条消息写进错误的对话。
    await _ensureMessages(sid);
    session = state.sessions.where((s) => s.id == sid).firstOrNull;
    if (session == null) {
      _sending.remove(sid); // 加载期间会话被删除
      return;
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

    // 该会话进入生成态（进度条目 = 空白起点）。
    state = state.copyWith(
      streams: {...state.streams, sid: const SessionStream()},
      clearError: true,
    );
    _lastFlush[sid] = DateTime.fromMillisecondsSinceEpoch(0);

    final sessionId = updated.id;
    final token = CancelToken();
    _cancelTokens[sessionId] = token;
    // 云端 Agent 请求要带 App 会话 id（后端据此维持远端 session/chat 映射）。
    // 正式路径由 run(agentSessionId:) 逐层传递；此静态字段仅作未传参
    // 调用的兜底，并行对话下它会互相覆盖，不能再当主通道。
    LlmClient.agentSessionId = sessionId;

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
        cancelToken: token,
        agentSessionId: sessionId,
        knowledge: knowledge,
        persona: _getPersona(),
        thinking: _getThinking(),
        reasoningEffort: _getReasoningEffort(),
      )) {
        // 长 Streaming 期间 notifier 可能已被 dispose（容器销毁/热重启），
        // 此时写 state 会抛 StateError 并让进度条目永远无法清除。
        if (!mounted) return;
        if (ev is AgentDelta) {
          buf.write(ev.delta);
          // 合帧：每个 delta 都全量 toString + 重建整个 ChatState 是
          // O(n²) 拷贝，长回答会明显卡顿。窗口内的 delta 只累积，
          // 到点或流结束时统一刷一次 UI。
          //
          // 90ms 而非 60ms：UI 侧每次刷新都要重新布局流式气泡并解析
          // Markdown，60ms(约 16fps) 偏高，在中低端机上每帧都跑不满就
          // 触发掉帧，视觉上反而是「一顿一顿」。90ms(约 11fps) 已
          // 明显快于人眼阅读速度，且把每帧解析成本摊薄近三成。
          final now = DateTime.now();
          final last = _lastFlush[sessionId] ??
              DateTime.fromMillisecondsSinceEpoch(0);
          if (now.difference(last).inMilliseconds >= 90) {
            _lastFlush[sessionId] = now;
            _mutateStream(sessionId, (s) => s.copyWith(content: buf.toString()));
          }
        } else if (ev is AgentReasoning) {
          _mutateStream(sessionId,
              (s) => s.copyWith(reasoning: s.reasoning + ev.delta));
        } else if (ev is AgentStatus) {
          _mutateStream(
              sessionId, (s) => s.copyWith(steps: [...s.steps, '⏳ ${ev.text}']));
        } else if (ev is AgentToolDone) {
          // 工具调度统计：MCP 工具名带「服务器名__工具名」双下划线约定
          if (ev.toolName.contains('__')) {
            _bumpUsage(sessionId, 3, 1);
          } else {
            _bumpUsage(sessionId, 2, 1);
          }
          // 只记录工具名（UI 在「正在思考」行旁展示），
          // 不再拼接结果摘要——按用户要求不显示调用详情。
          _mutateStream(
              sessionId, (s) => s.copyWith(steps: [...s.steps, '🔧 ${ev.toolName}']));
        } else if (ev is AgentTokenUsage) {
          _bumpUsage(sessionId, 0, ev.promptTokens);
          _bumpUsage(sessionId, 1, ev.completionTokens);
        } else if (ev is AgentQuotaUsed) {
          // 云端模型：本轮扣掉的周额度即时回填，额度卡片无需手动刷新
          _onQuotaUsed?.call(ev.used, ev.limit);
        } else if (ev is AgentRoundRestart) {
          // 断流整轮重发：丢弃本轮残缺增量，思考面板回退到已完成轮次。
          // 不清 steps——「正在自动重试」的状态行要留着给用户看。
          buf.clear();
          _mutateStream(sessionId,
              (s) => s.copyWith(content: '', reasoning: ev.reasoningPrefix));
        } else if (ev is AgentAnswer) {
          answer = ev.message;
        } else if (ev is AgentFailure) {
          // 用户主动取消不是错误：不弹错误横幅（部分内容如何落库见下方收尾逻辑）。
          // 错误条只在【本会话】处于前台时弹：A 失败时用户正在 B 里，
          // 弹到 B 头上会让人以为是 B 出错。
          if (ev.message != '已取消。' && state.activeSessionId == sessionId) {
            state = state.copyWith(error: ev.message);
          }
        }
      }
    } catch (e) {
      if (mounted && state.activeSessionId == sessionId) {
        state = state.copyWith(error: '运行出错：$e');
      }
    }

    if (!mounted) return;

    // 取消但已产出部分内容：把已有内容作为部分回答落库，而不是整段丢弃。
    // 标记「（已停止）」让用户知道回答被截断。
    final wasCancelled = token.isCancelled;
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

    // 放在 finally 语义位置：任何提前 return 都不会让该会话的进度
    // 条目卡在生成态（提前 return 只发生在 notifier 已 dispose 时）。
    _endStream(sessionId);
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

  /// 停止【当前激活会话】的生成。其它会话正在生成的流不受影响。
  Future<void> stop() async {
    final sid = state.activeSessionId;
    if (sid == null) return;
    final t = _cancelTokens[sid];
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
    _compressTokens[session.id] = token;
    try {
      final eff = config.copyWith(defaultChatModel: model);
      final buf = StringBuffer();
      await for (final ev in _llm.chatStream(
        config: eff,
        cancelToken: token,
        // 压缩若走云端 Agent 配置，appSessionId 必须是本会话的 id。
        agentSessionId: session.id,
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
      if (identical(_compressTokens[session.id], token)) {
        _compressTokens.remove(session.id);
      }
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
        agentSessionId: sessionId,
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
    // 云端模型每轮扣掉额度后即时回填 CloudState.aiQuota，
    // 额度卡片无需手动刷新账号页
    onQuotaUsed: (used, limit) => ref
        .read(cloudProvider.notifier)
        .updateAiQuota(used: used, limit: limit),
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
    this.email,
    this.plan = 'free',
    this.planExpiresAt,
    this.usageToday = const {},
    this.aiQuota = const CloudAiQuota(),
    this.licenses = const [],
    this.busy = false,
    this.error,
  });

  final bool restoring;
  final bool loggedIn;

  /// 登录邮箱（登录时本地记录；后端响应不回传）。
  final String? email;
  final String plan;
  final int? planExpiresAt;
  final Map<String, int> usageToday;

  /// 云端模型周额度（每周一 00:00 UTC+8 自动归零）。
  ///
  /// [CloudAiQuota.empty] 表示后端未下发该字段（旧版后端），此时额度
  /// 卡片整节隐藏，而不是显示一个永远为 0 的进度条。
  final CloudAiQuota aiQuota;

  /// 已激活的卡密记录。
  final List<CloudActivatedLicense> licenses;
  final bool busy;
  final String? error;

  CloudState copyWith({
    bool? restoring,
    bool? loggedIn,
    String? email,
    String? plan,
    int? planExpiresAt,
    Map<String, int>? usageToday,
    CloudAiQuota? aiQuota,
    List<CloudActivatedLicense>? licenses,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      CloudState(
        restoring: restoring ?? this.restoring,
        loggedIn: loggedIn ?? this.loggedIn,
        email: email ?? this.email,
        plan: plan ?? this.plan,
        planExpiresAt: planExpiresAt ?? this.planExpiresAt,
        usageToday: usageToday ?? this.usageToday,
        aiQuota: aiQuota ?? this.aiQuota,
        licenses: licenses ?? this.licenses,
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

  Future<bool> login(String email, String password) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _cloud.login(email, password);
      state = state.copyWith(
        busy: false,
        loggedIn: true,
        email: _cloud.email,
        plan: _cloud.plan,
      );
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
      state = state.copyWith(
        busy: false,
        loggedIn: true,
        email: _cloud.email,
        plan: 'free',
      );
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
    // 不用 const CloudState()：那会把整个 state 换成新的常量对象，
    // loggedIn 由 true 变 false 仍会触发 watch（等价），但保留 copyWith
    // 语义更清晰——后续新增字段时不会静默丢值。
    state = state.copyWith(
      loggedIn: false,
      email: null,
      clearError: true,
    );
  }

  /// 云端模型对话后就地更新额度（不重新拉取账号信息）。
  ///
  /// 只改 used/limit 两个字段：tier 与重置时间在这一轮里没变，
  /// 没必要为一次扣减再打一次 /api/license/status。
  void updateAiQuota({required int used, required int limit}) {
    final old = state.aiQuota;
    if (!old.isSupported) return;
    state = state.copyWith(
      aiQuota: CloudAiQuota(
        tier: old.tier,
        tierLabel: old.tierLabel,
        used: used,
        limit: limit,
        remaining: (limit - used).clamp(0, limit),
        resetInMs: old.resetInMs,
      ),
    );
  }

  /// 刷新套餐与今日用量。静默失败（不打扰 UI）。
  Future<void> refreshStatus() async {
    try {
      final info = await _cloud.fetchAccountInfo();
      state = state.copyWith(
        loggedIn: true,
        email: _cloud.email,
        plan: info.plan,
        planExpiresAt: info.planExpiresAt,
        usageToday: info.usageToday,
        aiQuota: info.aiQuota,
        licenses: info.licenses,
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
      if (!_cloud.isLoggedIn) return;
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

/// 云端模型列表（登录后可用）。
///
/// 登录状态变化时自动重拉：登出后必须清掉，否则会把上一个账号的
/// 供应商列表留在内存里。令牌本身由 [llmClientProvider] 注入。
final cloudModelsProvider =
    ChangeNotifierProvider<CloudModelsController>((ref) {
  final controller = CloudModelsController(ref.watch(cloudServiceProvider));
  final configNotifier = ref.watch(configProvider.notifier);
  // 列表一变就把云端配置注入 ConfigNotifier（仅内存），对话链路因此
  // 与自建供应商完全同构，无需在 UI 层到处判断「这条是不是云端」。
  controller.addListener(() {
    final s = controller.state;
    // 云端 Agent（已开通时）也并入：未开通时 s.agentConfig 为 null，
    // 这里什么都不加 —— App 端因此完全没有 Agent 入口，也不显示任何提示。
    final managed = <LlmConfig>[
      ...s.configs,
      if (s.agentConfig != null) s.agentConfig!,
    ];
    configNotifier.injectCloudConfigs(managed);
  });
  // 依赖登录态：watch 整个 CloudState，登录/登出都会重建 controller，
  // 新的 controller 从头加载（登出后 _cloud.email 为空会直接置空列表）。
  //
  // ⚠️ 这里刻意**不用 ref.listen**：本回调的 ref 是
  // `ChangeNotifierProviderRef<CloudModelsController>`，即 `Ref<NotifierT>`，
  // 而 cloudProvider 是 `ProviderListenable<CloudState>`，State 泛型对不上，
  // ref.listen 会报 argument_type_not_assignable（连踩三轮：加 .notifier /
  // 去显式泛型 / 只传 provider）。
  // 也不要用 .select —— riverpod 2.6.1 的 ProviderListenable 没有 select 方法。
  // 直接 watch 整个 CloudState 最稳：它实现 ProviderListenable<CloudState>，
  // 与 watch 的用法完全一致（本文件 chatProvider 里就有
  // ref.watch(toolRegistryProvider) 这类直接 watch provider 的用法）。
  ref.watch(cloudProvider);
  // ⚠️ 必须在这里触发首次加载：controller 只是被"创建"，并不会自己去拉数据。
  // 之前漏了这句，导致 chat_screen 的 ref.read 永远读到空列表 —— 云端模型
  // 已在后端配好、App 也已登录，但对话界面就是看不到。
  // 用 Future.microtask 延到当前同步构建结束之后再发请求，避免在
  // provider 构造过程中直接 await（Riverpod 不允许在 create 里改状态）。
  Future.microtask(() => controller.load());
  return controller;
});

final cloudProvider = StateNotifierProvider<CloudNotifier, CloudState>((ref) =>
    CloudNotifier(
      ref.watch(cloudServiceProvider),
      ref.watch(mcpServiceProvider),
    ));

/// 「我的手机」（本地）最近使用的配置 id。
///
/// 顶部设备切换进「云端 Agent」前记下当前本地配置；从云端 Agent 页
/// 切回本地时恢复它，而不是粗暴跳到第一个可用配置。
final lastLocalConfigIdProvider = StateProvider<String>((ref) => '');
