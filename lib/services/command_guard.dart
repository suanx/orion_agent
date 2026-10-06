/// run_command 风险分级与用户确认（评估项 S1/F7，v0.2.27-beta）。
///
/// 此前模型可以不经用户确认直接在 proot 内执行任意 shell（含
/// apk install、rm 等）。分级规则：
/// - **白名单直行**：只读命令（ls/cat/grep/find…）与低风险写入
///   （mkdir/touch）直接执行，不打断用户；
/// - **其余一律视为高风险**（未知命令、安装、网络下载、删除、写
///   重定向、多段拼接中出现非白名单段），先经 [confirm] 请求用户
///   放行，拒绝则把拒绝原因回给模型让它调整；
/// - **fail-closed**：没有注册确认处理器（应用不在前台的后台任务、
///   测试环境）时默认拒绝。
class CommandGuard {
  CommandGuard._();
  static final CommandGuard instance = CommandGuard._();

  /// 用户确认处理器：返回 true 放行。UI 层（main.dart）启动时注册，
  /// 弹玻璃确认卡等待用户选择。
  Future<bool> Function(String command)? handler;

  Future<bool> confirm(String command) async {
    final h = handler;
    if (h == null) return false; // fail-closed
    try {
      return await h(command);
    } catch (_) {
      return false;
    }
  }

  /// 只读 / 低风险白名单：段首命令命中即免确认。
  /// 注意保守性优先——不在表里的命令（sed、python、tar、unzip、
  /// docker…）一律走确认，即使多数用法其实无害。
  static const _safeCommands = {
    'ls', 'pwd', 'echo', 'printf', 'cat', 'head', 'tail', 'grep', 'egrep',
    'fgrep', 'find', 'stat', 'file', 'du', 'df', 'wc', 'sort', 'uniq',
    'diff', 'cmp', 'which', 'whoami', 'id', 'uname', 'date', 'cal',
    'uptime', 'env', 'printenv', 'hostname', 'tree', 'ps', 'free', 'clear',
    'basename', 'dirname', 'realpath', 'readlink', 'md5sum', 'sha256sum',
    'base64', 'mkdir', 'touch', 'bc',
  };

  /// 判断命令是否高风险（需要用户确认）。宁可误报不放过：
  /// 判断不了的一律 true。
  static bool isRisky(String command) {
    final c = command.trim();
    if (c.isEmpty) return false;

    // 写重定向（> / >>）算写入。先抹掉 -> 与 >= 这类比较/箭头，再查。
    final withoutOps = c.replaceAll('->', ' ').replaceAll('>=', ' ');
    if (withoutOps.contains('>')) return true;

    // 反引号 / $() 命令替换：内容无法静态判断，一律确认
    if (c.contains('`') || c.contains(r'$(')) return true;

    // 按管道 / 顺序拼接分段，每段的首命令都必须在白名单里
    final segments = c.split(RegExp(r'\|\||&&|;|\|'));
    for (final seg in segments) {
      final words = seg.trim().split(RegExp(r'\s+'));
      final word = words.isEmpty ? '' : words.first;
      if (word.isEmpty) continue;
      if (!_safeCommands.contains(word)) return true;
    }

    // 兜底：白名单命令的参数里出现高危关键字（如 find 的 -exec rm、
    // awk 内嵌 system("rm …)")）也算高风险。段首判断覆盖大多数，这里
    // 拦「白名单命令 + 危险参数」的漏网形态。
    if (RegExp(r'''[\s/"'](rm|mv|dd|chmod|chown|chattr|kill|pkill|reboot|shutdown|mkfs|fdisk|curl|wget|tee|truncate|ln)\b''')
        .hasMatch(c)) {
      return true;
    }
    if (RegExp(r'\b(apk|apt|apt-get|pkg|snap)\s+(add|del|install|remove|purge|upgrade)\b')
        .hasMatch(c)) {
      return true;
    }
    if (RegExp(r'\b(pip3?|npm|gem|cargo|yarn)\s+(install|remove|add|i)\b')
        .hasMatch(c)) {
      return true;
    }
    return false;
  }
}
