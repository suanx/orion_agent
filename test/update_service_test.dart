import 'package:flutter_test/flutter_test.dart';
import 'package:orion_agent/services/update_service.dart';

/// UpdateService.parseReleaseEntry（Beta 通道的 release 解析）回归测试。
///
/// 纯函数：直接构造 GitHub releases API 的 JSON 断言，不发网络请求。
void main() {
  /// 构造一条 GitHub release JSON。apkName 传空字符串表示无附件
  /// （不能用 null——null 在函数体内会被替换为默认 APK 名）。
  Map<String, dynamic> release({
    required String tag,
    bool draft = false,
    bool prerelease = false,
    String apkName = 'x',
    String body = '更新说明',
  }) {
    // 默认 APK 名依赖 tag：默认值必须是编译期常量，只能在函数体内插值
    if (apkName == 'x') apkName = 'orion-agent-v$tag.apk';
    return {
      'tag_name': 'v$tag',
      'draft': draft,
      'prerelease': prerelease,
      'body': body,
      'assets': [
        if (apkName.isNotEmpty)
          {
            'name': apkName,
            'browser_download_url':
                'https://github.com/suanx/orion_agent/releases/download/v$tag/$apkName',
          },
      ],
    };
  }

  test('比当前新的稳定版：解析出版本、APK 地址与更新日志', () {
    final info = UpdateService.parseReleaseEntry(
      release(tag: '0.3.0'),
      currentVersion: '0.2.10',
    );
    expect(info, isNotNull, reason: '0.3.0 > 0.2.10 应命中');
    expect(info!.version, '0.3.0');
    expect(info.apkUrl, contains('orion-agent-v0.3.0.apk'));
    expect(info.changelog, '更新说明');
  });

  test('等于或旧于当前版本：返回 null（不提示更新）', () {
    expect(
      UpdateService.parseReleaseEntry(
          release(tag: '0.2.10'), currentVersion: '0.2.10'),
      isNull,
      reason: '同版本不应提示更新');
    expect(
      UpdateService.parseReleaseEntry(
          release(tag: '0.2.9'), currentVersion: '0.2.10'),
      isNull,
      reason: '旧版本不应提示更新');
  });

  test('draft 永远跳过（无 APK 且非公开）', () {
    expect(
      UpdateService.parseReleaseEntry(
        release(tag: '9.9.9', draft: true),
        currentVersion: '0.2.10',
      ),
      isNull,
      reason: 'draft 不应进入更新提示');
  });

  test('pre-release 标记不拦截：Beta 通道靠它提供测试版', () {
    final info = UpdateService.parseReleaseEntry(
      release(tag: '0.3.0', prerelease: true),
      currentVersion: '0.2.10',
    );
    expect(info, isNotNull,
        reason: 'prerelease=true 是 Beta 通道的数据来源，解析不应拦');
  });

  test('无 APK 附件：仍返回版本信息（apkUrl 为 null，UI 引导去 releases 页）', () {
    final info = UpdateService.parseReleaseEntry(
      release(tag: '0.3.0', apkName: ''),
      currentVersion: '0.2.10',
    );
    expect(info, isNotNull);
    expect(info!.apkUrl, isNull);
  });

  test('版本比较：段数不足补 0 且逐段数字比较', () {
    expect(UpdateService.isNewer('0.3', '0.2.10'), isTrue,
        reason: '0.3.0 > 0.2.10');
    expect(UpdateService.isNewer('0.2.10', '0.2.10'), isFalse);
    expect(UpdateService.isNewer('0.2.9', '0.2.10'), isFalse);
  });

  // ---- R2 更新清单（CI 正式发版上传的 latest.json）解析 ----

  Map<String, dynamic> manifest({
    required String version,
    String? apkUrl = 'https://gr.suen.us.ci/orion/orion-agent-vX.apk',
    String notes = '更新说明',
  }) =>
      {
        'version': version,
        'apkUrl': apkUrl,
        'notes': notes,
        'buildNumber': 109,
        'sha256': 'deadbeef',
      };

  test('R2 清单：比当前新的版本解析出版本、APK 地址与更新日志', () {
    final info = UpdateService.parseR2Manifest(
      manifest(version: '0.3.0', apkUrl: 'https://gr.suen.us.ci/orion/a.apk'),
      currentVersion: '0.2.10',
    );
    expect(info, isNotNull, reason: '0.3.0 > 0.2.10 应命中');
    expect(info!.version, '0.3.0');
    expect(info.apkUrl, 'https://gr.suen.us.ci/orion/a.apk');
    expect(info.changelog, '更新说明');
  });

  test('R2 清单：等于或旧于当前版本返回 null（不提示更新）', () {
    expect(
      UpdateService.parseR2Manifest(
          manifest(version: '0.2.10'), currentVersion: '0.2.10'),
      isNull,
      reason: '同版本不应提示更新（Beta 同号规则同源 isNewer）');
    expect(
      UpdateService.parseR2Manifest(
          manifest(version: '0.2.9'), currentVersion: '0.2.10'),
      isNull,
      reason: '旧版本不应提示更新');
  });

  test('R2 清单：非 Map / 缺 version / 空 apkUrl 的降级行为', () {
    expect(UpdateService.parseR2Manifest(null, currentVersion: '0.2.10'),
        isNull, reason: '响应非 JSON 对象应返回 null');
    expect(UpdateService.parseR2Manifest({'apkUrl': 'x'}, currentVersion: '0'),
        isNull, reason: '缺 version 应返回 null');
    final noApk = UpdateService.parseR2Manifest(
        manifest(version: '0.3.0', apkUrl: ''), currentVersion: '0.2.10');
    expect(noApk, isNotNull);
    expect(noApk!.apkUrl, isNull, reason: '空 apkUrl 置 null，UI 引导去 releases 页');
    final noNotes = UpdateService.parseR2Manifest(
        manifest(version: '0.3.0', notes: ''), currentVersion: '0.2.10');
    expect(noNotes!.changelog, isNull, reason: '空 notes 置 null');
  });
}
