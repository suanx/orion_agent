/// 内置 MCP 服务器（v0.2.29-beta）。
///
/// 用户自建的服务端点**写死在代码里**：不落库、不出现在 MCP 管理页
/// （防止 URL 泄漏与外部滥用），应用启动时随 McpService.connectAll
/// 自动连接，且在工具调度上获得优先调用（见 tools.dart 的权限放行
/// 与 agent_orchestrator 的系统提示词声明）。
///
/// name 为工具注册前缀，会被 `McpTool.sanitizePublic` 清理，
/// 必须是 ASCII（中文名会被清成纯下划线导致前缀不可读）。
class BuiltinMcpServer {
  const BuiltinMcpServer(this.id, this.name, this.url);

  /// 稳定 id（存活连接表的 key），builtin- 前缀避免与用户配置的 id 撞车。
  final String id;

  /// 工具前缀（ASCII）。
  final String name;

  /// Streamable HTTP 端点。
  final String url;
}

/// 用户自建的 MCP 服务（顺序即优先级：connectAll 先连先注册）。
const List<BuiltinMcpServer> builtinMcpServers = [
  // 搜神搜索：web_search / fetch_url / 搜索源诊断（Bing/Google 聚合）
  BuiltinMcpServer(
      'builtin-soushen', 'soushen', 'https://mcp.suen.us.ci/api/mcp'),
  // Android 逆向与移动安全知识库：list_skills / read_skill / search_skills
  BuiltinMcpServer(
      'builtin-revskills', 'rev-skills', 'https://eo.suen.us.ci/mcp'),
];

/// 该工具名是否属于内置 MCP 服务器（`前缀__工具名`）。
///
/// 内置服务是用户自己搭的可信端点，因此跨过「完全访问」档的门槛：
/// 工作区读写档即可调用（用户自配的第三方 MCP 仍维持原安全要求，
/// 仅完全访问档放行）。
bool isBuiltinMcpTool(String toolName) {
  for (final s in builtinMcpServers) {
    if (toolName.startsWith('${_sanitize(s.name)}__')) return true;
  }
  return false;
}

// 与 mcp_client.McpTool._sanitize 相同的规则（此处独立实现以避免依赖）。
String _sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
