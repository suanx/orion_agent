# Orion Agent

运行在 Android 手机上的个人 AI 助手。能聊天，也能干活——内置 Linux 终端、本地知识库、
MCP 工具扩展，数据全部留在本机。

> **当前状态**：功能完整可用，侧载分发（不上架应用商店）。Android arm64 only。

> ⚠️ **从旧版（pocket_agent）升级说明**：本项目已更名为 orion_agent，
> 数据库文件名同步改为 `orion_agent.sqlite`，**不做迁移**。
> 旧版安装的用户升级后会看到空库（会话、长期记忆、知识库都读不到，
> 但数据文件仍在），需要重新配置模型服务与知识库。
> 全新安装不受影响。
>
> 仓库已从 `suanx/pocket-agent` 迁至 **`suanx/orion_agent`**（旧仓库已删除）。
> Git 提交历史完整保留，无需额外操作。

---

## 功能

### 对话

- **多模型服务**——任意 OpenAI 兼容接口（OpenAI / GLM / DeepSeek / Ollama / 硅基流动 等），
  可配置多个并随时切换
- **SSE 流式输出**——逐字显示，支持 Markdown 渲染
- **多模态**——聊天时可发送图片

### Agent 能力

- **ReAct 工具循环**——推理 → 调工具 → 看结果 → 继续推理，最多 8 轮
- **7 个内置工具**：

  | 工具 | 作用 |
  |---|---|
  | 联网搜索 | DuckDuckGo，无需 API Key |
  | 网页抓取 | 提取网页正文 |
  | 精确计算器 | 支持括号、取余、幂运算 |
  | 当前时间 | 含时区信息 |
  | 长期记忆 | 记住你的偏好，跨对话生效 |
  | 知识库检索 | 语义搜索你导入的资料 |
  | **终端命令** | 在手机里跑真实 shell |

- **内置 Linux 环境**——通过 proot 运行 Alpine 3.22 / Debian 12，
  可安装 nodejs、python3、git、uv 等组件；已配置国内镜像（清华源、npmmirror）

### 知识库（RAG）

- 导入文档后自动分块 + 向量化，检索时按语义召回
- 回答中标注来源（【资料N｜来源: 文档名】），可溯源
- ⚠️ **当前仅支持粘贴文本**，暂不支持 PDF/Word 文件导入（见 [待修复](#待修复)）

### 技能与角色

- **18 个内置技能**，覆盖写作办公、信息检索、生活助手、开发者工具四类
- 聊天框输入 `/技能名 参数` 即可调用，例如 `/写周报 本周做了A、B、C`
- 可自建技能（提示词模板）
- **角色**：设定人格，会注入 system prompt。当前无预置角色，可自建

### 语音

- **Edge TTS**（微软在线音色，免鉴权）——7 个中文音色，语速/音量可调
- **系统 TTS** 兜底——Edge 失败时自动切换
- **语音输入**——说话转文字

### 通知

- 回答完成、任务结束时提醒
- 可选是否显示摘要、是否静音（独立通知渠道，Android 8+ 真正不响铃）
- **点击通知直接跳回对话页**

### 其他

- **MCP 接入**——连接外部 MCP 服务器，把它们的工具纳入 Agent
- **终端自启动任务**——冷启动时自动执行预设命令
- **6 套配色主题** + 跟随系统/浅色/深色
- **存储管理**——查看各类占用，清理缓存与工作区
- **会话管理**——多会话、历史切换、删除

---

## 隐私

- 会话、消息、长期记忆、知识库**全部存本机 SQLite**，不上传
- API Key 存于 **Android Keystore**（加密）
- 边缘 TTS 需要联网合成语音；除此之外无任何数据外发
- 联网搜索 / 网页抓取会把**关键词 / URL** 发给对应服务（DuckDuckGo / 目标站点）

---

## 快速开始

### 1. 获取安装包

前往 [Actions](https://github.com/suanx/orion_agent/actions) → 最新成功 run →
**Artifacts** → 下载 `orion-agent-apk` → 解压得到 `app-release.apk`。

> 需允许「安装未知来源应用」。

### 2. 配置模型服务

进入 **我的 → 模型设置 → 添加模型服务**：

| 字段 | 说明 | 示例 |
|---|---|---|
| 名称 | 自定义 | 智谱 |
| Base URL | OpenAI 兼容端点 | `https://open.bigmodel.cn/api/paas/v4` |
| API Key | 服务商的密钥 | `xxxxxx` |
| 模型名 | 对话模型 | `glm-4-flash` |
| Embedding 模型 | **可选**，知识库检索需要 | `embedding-3` |
| 温度 | 0–1.5，默认 0.7 | 0.7 |

保存后**点选该服务**使其生效。

### 3. 开始对话

回到「对话」页直接提问。需要实时信息、精确计算或执行命令时，
Agent 会自动调用工具。

### 4.（可选）安装终端环境

**我的 → 终端环境** → 选择 Alpine 或 Debian → 下载安装（约 100–300 MB）。

安装后可让 Agent 执行 shell 命令、装软件、跑脚本。

> ⚠️ 目标设备必须是 **arm64**（绝大多数真机）。模拟器（x86）不支持。

### 5.（可选）配置知识库

**我的 → 知识库** → 粘贴文本 → 导入并向量化。
需要先在模型设置里填 Embedding 模型名。

之后提问时 Agent 会自动检索相关资料并标注来源。

### 6.（可选）接入 MCP

**我的 → MCP 服务器** → 添加（名称 + 端点 URL，如 `http://192.168.1.10:3000/mcp`）→ 开启。

该服务器提供的工具会自动加入 Agent 的工具列表。

---

## 构建

本地**无需安装 Flutter**，推送后由 GitHub Actions 自动构建。

- 工作流：`.github/workflows/build.yml`（push to main 时自动触发）
- 产物：Actions → 最新 run → Artifacts → `orion-agent-apk`（约 12 MB）
- 当前状态：✅ analyze 0 error、全部测试通过

平台目录（`android/`）不提交，由 CI 在构建时按当前 Flutter stable 生成，
保证平台配置与 Flutter 版本一致。

> ⚠️ **不要在 CI 里注入 Gradle 代码**。历史上曾因此连续 5 次构建失败
> （每次修复都引入新问题）。`flutter create` 模板已自带
> `kotlin { compilerOptions { jvmTarget = JVM_17 } }`，CI 只做**校验**不做注入。
> 详见 [docs/PROJECT.md §8](docs/PROJECT.md#8-构建与-ci)。

---

## 项目结构

```
lib/
├── main.dart          入口
├── theme.dart         主题
├── models/            数据模型
├── providers/         Riverpod 状态
├── services/          业务逻辑
└── ui/                界面
```

详细的技术实现、架构说明、待修复问题与后续规划见
**[docs/PROJECT.md](docs/PROJECT.md)**。

---

## 待修复

功能尚未完成的部分，按优先级：

| 优先级 | 项目 | 说明 |
|---|---|---|
| P0 | **知识库文件导入** | 目前只能粘贴文本，不支持 PDF/Word |
| P0 | **定时任务** | 「任务」页是占位页，尚未实现 |
| P0 | **非 arm64 支持** | 终端环境仅 arm64，模拟器不可用 |
| P1 | 冷启动任务时序 | 终端安装中执行自启任务会失败 |
| P1 | RAG 大规模性能 | 当前暴力检索，文档上千块后变慢 |
| P1 | 会话无分页 | 启动时全量加载所有消息 |
| P1 | 对话导出 | 缺少分享功能 |

完整清单见 [docs/PROJECT.md §12](docs/PROJECT.md#12-待修复的问题)。

---

## 后续规划

- 知识库支持 PDF / Word / Markdown
- 定时任务落地（WorkManager）
- 流式知识库检索（多轮工具调用后重新检索）
- 对话导出与分享
- MCP 资源（resources）支持
- 本地小模型接入（隐私优先模式）

完整规划见 [docs/PROJECT.md §13](docs/PROJECT.md#13-后续可增加的功能)。

---

## 技术栈

| 项 | 选型 |
|---|---|
| 框架 | Flutter |
| 状态管理 | Riverpod |
| 本地数据库 | Drift (SQLite) |
| 网络 | Dio |
| 密钥存储 | Flutter Secure Storage |
| 语音合成 | Edge TTS (WebSocket) + flutter_tts |
| 语音识别 | speech_to_text |
| 通知 | flutter_local_notifications |
| CI/CD | GitHub Actions |

---

## 许可

仅供个人学习与使用。
