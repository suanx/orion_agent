/// 云端后端（orion_agent_cloud）接入配置 —— **全局唯一改址入口**。
///
/// ⚠️⚠️ 后端部署地址在这里写死，【不暴露给用户配置】：
/// - 更换后端地址 / 迁移部署域名时，只改 [baseUrl] 这一处即可，
///   所有云功能（账号 / 搜索抓取中继 / 云端任务 / MCP / 公告）自动跟随；
/// - 改完无需其他改动，重新打包发布即可。
///
/// 设计原则（与 builtin_mcp.dart 的内置 MCP 同款）：端点写死在代码里，
/// 不进任何管理页 / 设置页，避免被探测与滥用。
///
/// 端点清单（后端 orion_agent_cloud 提供，均为 baseUrl 相对路径）：
/// - /api/auth/*        账号（注册/登录/刷新/登出/设备/设备令牌）
/// - /api/license/status  授权状态（激活已下线，授权由管理台设置）
/// - /api/relay/*       搜索 / 抓取中继
/// - /api/tasks/*       云端定时任务
/// - /api/mcp           MCP JSON-RPC
/// - /api/update/check  更新检查
/// - /api/announcement  弹窗公告
///
/// 相关文档：docs/PROJECT.md「云端接入」节 / README.md 云功能说明。
class CloudConfig {
  CloudConfig._();

  /// ⚠️ 云端后端根地址（不要以 / 结尾）。换后端地址只改这一行。
  static const String baseUrl = 'https://orion.suen.us.ci';
}
