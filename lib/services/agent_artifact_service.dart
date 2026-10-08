import 'package:flutter/foundation.dart';

import 'cloud_service.dart';

/// 云端 Agent 的沙箱产物读取服务。
///
/// **产物不走 SSE 事件**（这是与 orion-forge 对接时最容易被误解的一点）：
/// Agent 干完活产出在沙箱里 —— 改过的文件、起的 dev server —— 这些只能通过
/// orion-forge 的独立 REST 端点读。而 App 只认自家后端的 `/api/agent/*`，
/// 拿不到实例地址与API Key，所以由后端转发（见 orion_agent_cloud
/// `src/routes/agent.ts` 的 `/files`、`/file`、`/dev-server`）。
///
/// 因此本服务只做三件事：列文件树、读单文件、开关 dev server。
class AgentArtifactService {
  AgentArtifactService(this._cloud);

  final CloudService _cloud;

  /// 列出 Agent 在沙箱里改动的文件。
  ///
  /// 返回值按 forge 的 `FileSuggestion` 解析：`value` 目录带尾`/`。
  /// [appSessionId] 是 **App 自己的会话 id**，后端靠它反查远端 session，
  /// App 不需要（也不应该）知道远端 session 的存在。
  Future<List<AgentFileNode>> listFiles(String appSessionId) async {
    final data = await _cloud.authedGet(
      '/api/agent/files?appSessionId=${Uri.encodeComponent(appSessionId)}',
    );
    final list = data['files'];
    if (list is! List) return const [];
    final nodes = <AgentFileNode>[];
    for (final item in list) {
      if (item is! Map) continue;
      final value = item['value']?.toString() ?? '';
      final display = item['display']?.toString() ?? value;
      if (value.isEmpty) continue;
      nodes.add(AgentFileNode(
        path: value,
        display: display,
        isDirectory: value.endsWith('/'),
      ));
    }
    return nodes;
  }

  /// 读取单个文件内容。
  ///
  /// forge 侧限制 200KB 且拒绝二进制（含 `\0`），超限会返回 413/400，
  /// 由 [CloudException] 原样带出原因，用户能看到「文件过大」而不是空白页。
  Future<AgentFileContent> readFile(String appSessionId, String path) async {
    final data = await _cloud.authedGet(
      '/api/agent/file?appSessionId=${Uri.encodeComponent(appSessionId)}'
      '&path=${Uri.encodeComponent(path)}',
    );
    final content = data['content']?.toString() ?? '';
    return AgentFileContent(
      path: data['path']?.toString() ?? path,
      content: content,
      size: (data['size'] as num?)?.toInt() ?? content.length,
    );
  }

  /// 启动（或复用）沙箱里的 dev server，返回预览地址。
  ///
  /// 已跑起来时后端是幂等的，直接回既有地址，不会重复装依赖。
  /// 注意这是 **写操作**（要装依赖、起进程），可能等十几秒。
  Future<AgentDevServer> startDevServer(String appSessionId) async {
    final data = await _cloud.authedPost(
      '/api/agent/dev-server?appSessionId=${Uri.encodeComponent(appSessionId)}',
      const {},
    );
    return AgentDevServer.fromJson(data);
  }

  /// 停掉 dev server，释放沙箱端口。
  Future<void> stopDevServer(String appSessionId) async {
    await _cloud.authedDelete(
      '/api/agent/dev-server?appSessionId=${Uri.encodeComponent(appSessionId)}',
    );
  }

  /// 无Agent 会话时的降级：静默返回空，不打扰用户。
  ///
  /// 「先发一条消息再来看产物」是正常路径，不该弹错误框。
  Future<List<AgentFileNode>> listFilesQuiet(String appSessionId) async {
    try {
      return await listFiles(appSessionId);
    } on CloudException catch (e) {
      debugPrint('读取 Agent 产物失败：${e.message}');
      return const [];
    }
  }
}

/// 沙箱里的一个文件或目录。
class AgentFileNode {
  const AgentFileNode({
    required this.path,
    required this.display,
    required this.isDirectory,
  });

  /// 完整路径，目录带尾`/`（forge 的约定）。
  final String path;

  /// 展示名（forge 原样给出，通常等于 [path]）。
  final String display;

  final bool isDirectory;

  /// 去掉尾`/` 后的路径，供文件读取与面包屑使用。
  String get cleanPath =>
      isDirectory && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

/// 单个文件的读取结果。
class AgentFileContent {
  const AgentFileContent({
    required this.path,
    required this.content,
    required this.size,
  });

  final String path;
  final String content;
  final int size;

  /// 人类可读的体积（forge 按字节给）。
  String get readableSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// dev server 预览信息。
class AgentDevServer {
  const AgentDevServer({
    this.packagePath = 'root',
    this.port = 0,
    this.url = '',
  });

  /// 承载 dev server 的子包路径，根目录为 `root`。
  final String packagePath;

  final int port;

  /// 沙箱预览地址。
  final String url;

  bool get isRunning => url.isNotEmpty;

  factory AgentDevServer.fromJson(Map<String, dynamic> json) => AgentDevServer(
        packagePath: json['packagePath']?.toString() ?? 'root',
        port: (json['port'] as num?)?.toInt() ?? 0,
        url: json['url']?.toString() ?? '',
      );
}