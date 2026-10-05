# orion_agent 开发约定（Agent 必读）

## 推送与发版规则（用户指令，最高优先级，每次必须遵守）

1. **未经用户明确指令，禁止推送**。改完代码先本地验证（`ci_check/brace_check.js`），
   停下等用户说「推送」。
2. **用户说「推送」= 发正式版本**，每次都必须完成：
   1. **版本号递增**：`pubspec.yaml` 的 `version:`（如 `0.2.0+11` → `0.2.1+12`，
      `+` 后 build 号 +1）**同时**把 `lib/ui/about_screen.dart` 的 `kAppVersion`
      改成同版本号（不带 build 号）。只改 pubspec 不改 kAppVersion →
      应用自报版本落后，装了最新版也会一直提示更新同版本（见 docs/PROJECT.md §11.17）。
   2. `RELEASE_NOTES.md` 顶部新增本版更新说明
   3. 推送到 main → 等 CI（flutter analyze/test/build）全绿
      **注意：build.yml 已内置自动发版**——CI 绿了之后 GitHub Actions bot
      会自动创建 tag `vX.Y.Z` 的 Release（正文取 RELEASE_NOTES.md 顶部段落）
      并上传 `orion-agent-vX.Y.Z.apk`，无需手动发版；
   4. （兜底）若 CI 没自动发版，用 `ci_check/make_release.mjs <run_id> <版本>`
      手动完成：下载 APK artifact → 创建 Release → 上传 APK。
      推送用 `ci_check/push_update.mjs`（Git Data API 单 commit 快进 main，
      支持 GITHUB_TOKEN 环境变量或 credential manager 凭据，
      永远不要回显密码）

注意：本机 git 直连 github.com 不通，推送/发版一律走 GitHub REST API
（可复用工作区的 `push_update.mjs` 与 credential manager 中的凭据，
永远不要回显密码）。

## 其它关键约定

- 本地无 Flutter SDK：`flutter analyze/test` 只能在 CI 验证；本地改 Dart 后
  先跑 `ci_check/` 下的静态检查（大括号配平等），最终以 CI 为准
- 改动代码必须同步更新 `docs/PROJECT.md` 对应小节（见其附录 B 维护约定）
- CI 结论看 Actions annotation；analyze 报错优先修，不要绕过
