# orion_agent 开发约定（Agent 必读）

## 发版规则（必须遵守，每次发版都执行）

**每次发布正式版本，必须同时做到：**

1. **创建 GitHub Release**（tag 形如 `v0.2.0`，名称 `Orion Agent v0.2.0`）
2. **Release 附更新说明**——正文写清本版功能/修复要点（与 `RELEASE_NOTES.md` 顶部版本一致）
3. **Release 附 APK 文件**——命名 `orion-agent-v{版本}.apk`，从最新成功 CI run 的
   Artifacts `orion-agent-apk` 解压取得 `app-release.apk` 后改名上传

### 标准发版流程

1. `pubspec.yaml` 的 `version:` 升版（如 `0.1.9+10` → `0.2.0+11`，`+` 后为 build 号递增）
2. `RELEASE_NOTES.md` 顶部新增本版更新说明
3. 推送到 main → 等 CI（flutter analyze/test/build）全绿
4. 用 GitHub API 下载最新 run 的 Artifacts → 解压出 APK
5. `POST /repos/suanx/orion_agent/releases` 创建 Release（附更新说明）
6. `POST .../releases/{id}/assets?name=orion-agent-vX.Y.Z.apk` 上传 APK

注意：本机 git 直连 github.com 不通，推送/发版一律走 GitHub REST API
（可复用工作区的 `push_update.mjs` 与 credential manager 中的凭据）。

## 其它关键约定

- 本地无 Flutter SDK：`flutter analyze/test` 只能在 CI 验证；本地改 Dart 后
  先跑 `ci_check/` 下的静态检查（大括号配平等），最终以 CI 为准
- 改动代码必须同步更新 `docs/PROJECT.md` 对应小节（见其附录 B 维护约定）
- CI 结论看 Actions annotation；analyze 报错优先修，不要绕过
