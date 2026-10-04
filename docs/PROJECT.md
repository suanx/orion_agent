# Orion Agent 项目详细说明

>本文档是 Orion Agent 的**技术实现全集**，记录真实代码行为（含行号定位）、
> 已验证的缺陷与修复、待办事项与后续规划。
>
> **文档约定**：本文所有结论均以实际代码为准，行号对应 `main` 分支。
> 改动代码后请同步更新对应小节，特别是行号会随编辑漂移。
>
> 面向读者：需要修改本项目的人。假设你熟悉 Dart/Flutter，但不熟悉本项目。

---

## 目录

- [1. 项目定位](#1-项目定位)
- [2. 架构总览](#2-架构总览)
- [3. 目录结构与文件职责](#3-目录结构与文件职责)
- [4. 数据层](#4-数据层)
- [5. 服务层详解](#5-服务层详解)
  - [5.1 LLM 客户端](#51-llm-客户端-llm_clientdart)
  - [5.2 Agent 编排器](#52-agent-编排器-agent_orchestratordart)
  - [5.3 工具系统](#53-工具系统-toolsdart)
  - [5.4 RAG 知识库](#54-rag-知识库-rag_servicedart)
  - [5.5 长期记忆](#55-长期记忆-memory_servicedart)
  - [5.6 终端环境](#56-终端环境-terminal_servicedart)
  - [5.7 语音](#57-语音-voice_servicedart)
  - [5.8 通知](#58-通知-notification_servicedart)
  - [5.9 MCP 客户端](#59-mcp-客户端-mcp_clientdart)
  - [5.10 技能系统](#510-技能系统-skill_servicedart)
  - [5.11 角色系统](#511-角色-system-role_servicedart)
  - [5.12 文件与存储](#512-文件与存储-file_storage_servicedart)
  - [5.13 导航服务](#513-导航服务-navigation_servicedart)
- [6. 状态层](#6-状态层)
- [7. UI 层](#7-ui-层)
- [8. 构建与 CI](#8-构建与-ci)
- [9. 配置项全集](#9-配置项全集)
- [10. 数据模型](#10-数据模型)
- [11. 已修复的缺陷档案](#11-已修复的缺陷档案)（含 §11.8 CI 调试实录）
- [12. 待修复的问题](#12-待修复的问题)
- [13. 后续可增加的功能](#13-后续可增加的功能)
- [14. 测试](#14-测试)
- [15. 开发注意事项](#15-开发注意事项)

---

## 1. 项目定位

**Orion Agent** 是一个运行在 Android 手机上的个人 AI 助手，形态接近 ChatGPT / Claude 移动端
应用，但强调「能干活」而不只是「能聊天」。

三个差异化能力：

1. **内置 Linux 终端**——通过 proot 在手机上跑真实的 Alpine/Debian，
   Agent 可以真的执行 shell 命令、装软件、跑脚本（`lib/services/terminal_service.dart`）
2. **本地知识库（RAG）**——导入文档后语义检索，回答可溯源到资料（`lib/services/rag_service.dart`）
3. **完全本地化**——会话、记忆、知识库全部存本机 SQLite，API Key 存 Keystore/Keychain

**技术栈**：Flutter + Riverpod + Drift(SQLite) + Dio，单一 Android 目标（侧载分发，不上架 Play）。

> ⚠️ **平台限制**：终端环境仅 **aarch64**；应用 **不面向 iOS**（terminal_service 在非 Android
> 平台直接抛异常）。

---

## 2. 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│  UI 层 (lib/ui/)                                              │
│  home_shell(4 Tab+抽屉) chat_screen tasks skills profile ...  │
└───────────────┬──────────────────────────────────────────────┘
                │ Riverpod ConsumerWidget
┌───────────────▼──────────────────────────────────────────────┐
│  状态层 (lib/providers/providers.dart)                         │
│  chatProvider / configProvider / 各设置项StateProvider          │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│  服务层 (lib/services/)                                       │
│                                                                │
│  chat_screen ──> ChatNotifier.send()                          │
│                      ││
│                      ▼                      │
│              AgentOrchestrator.run()  ←── ToolRegistry.execute()
│                   │       │
│                   │       └── 内置工具 + MCP 工具
│                   ▼
│              LlmClient.chatStream()  ──SSE──> OpenAI 兼容服务
│                                                                │
│  辅助服务：RagService / MemoryService / TerminalService         │
│           VoiceService / NotificationService / McpService│
│           SkillService / RoleService / NavigationService       │
│           StorageService / FileStorageService                  │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│  数据层                                     │
│  AppDatabase (Drift/SQLite, 8 张表)   │
│  SharedPreferences (设置项)             │
│  FlutterSecureStorage (API Key 加密)     │
└──────────────────────────────────────────────────────────────┘
```

### 一次对话的完整链路

```
用户输入
  → chat_screen._send()
  → ChatNotifier.send()
      ├─ 若配置了 embedding → RagService.search() 预检索知识库
      ├─ 插入 user 消息 → StorageService → SQLite
      └─ AgentOrchestrator.run()
           ├─ _systemPrompt()：基础 prompt + 角色 + 记忆 + 知识库
           └─ 循环最多 8 轮：
                ├─ LlmClient.chatStream() → SSE 增量文本 → AgentDelta → UI
                ├─ 若模型返回 tool_calls：
                │    ├─ ToolRegistry.execute() 执行
                │    └─ 结果以 role:"tool" 回灌messages
                └─ 否则产出 AgentAnswer
  → 落库 → TTS 播报 → 通知
```

---

## 3. 目录结构与文件职责

```
orion_agent/
├── lib/
│   ├── main.dart                      应用入口、ProviderContainer、沉浸式 UI
│   ├── theme.dart                     6 套配色主题 + Material3 主题构建
│   │
│   ├── models/                        纯数据模型（无逻辑）
│   │   ├── chat_message.dart          ChatMessage / ToolCall
│   │   ├── chat_session.dart          ChatSession
│   │   ├── llm_config.dart            LlmConfig / ProviderModel（含 JSON 序列化与旧数据迁移）
│   │   └── memory_note.dart           MemoryNote
│   │
│   ├── providers/
│   │   └── providers.dart             全部 Riverpod provider（690 行）
│   │
│   ├── services/                      业务逻辑层
│   │   ├── database.dart              Drift 表定义 + 迁移
│   │   ├── storage_service.dart       会话/消息持久化
│   │   ├── llm_client.dart            OpenAI 兼容 SSE 客户端
│   │   ├── agent_orchestrator.dart    ReAct 循环
│   │   ├── tools.dart                 7 个内置工具 + ToolRegistry
│   │   ├── rag_service.dart           向量检索
│   │   ├── text_chunker.dart          文本分块
│   │   ├── memory_service.dart        长期记忆
│   │   ├── terminal_service.dartproot 终端
│   │   ├── voice_service.dart         Edge TTS + STT
│   │   ├── notification_service.dart  本地通知
│   │   ├── mcp_client.dart            MCP 协议客户端
│   │   ├── mcp_service.dart           MCP 连接管理
│   │   ├── cloud_service.dart         云端后端客户端（账号/卡密/中继/更新，国内可达）
│   │   ├── skill_service.dart         技能（18 个内置）
│   │   ├── role_service.dart          角色（无预置）
│   │   ├── file_storage_service.dart  存储统计与清理
│   │   ├── workspace_store.dart       工作区目录解析（默认/自定义统一入口）
│   │   └── navigation_service.dart    全局导航（通知点击跳转）
│   │
│   └── ui/                界面层
│       ├── home_shell.dart             4 Tab 外壳 + 抽屉 + 底部导航
│       ├── chat_screen.dart            对话页（1867 行，最大文件；无气泡正文版式）
│       ├── sessions_drawer.dart        会话抽屉
│       ├── tasks_screen.dart           自动任务（M3 占位页）
│       ├── skills_screen.dart          技能管理
│       ├── roles_screen.dart           Agent 角色管理
│       ├── knowledge_screen.dart       知识库管理
│       ├── mcp_screen.dart             MCP 服务器配置
│       ├── terminal_screen.dart        终端环境管理
│       ├── settings_screen.dart        模型服务配置
│       ├── appearance_screen.dart      主题/明暗模式
│       ├── notification_settings_screen.dart  通知设置
│       ├── storage_settings_screen.dart     存储管理 + 工作区目录选择
│       ├── about_screen.dart           关于页（软件介绍 + 在线更新）
│       ├── profile_screen.dart         我的
│       ├── cloud_account_screen.dart   云端服务（Hero 登录页 + 多功能个人中心）
│       └── setup_screen.dart           首次运行引导
│
├── test/                单元测试（10 个文件）
├── ci/MainActivity.kt   CI 注入的原生 Activity（MethodChannel）
├── .github/workflows/build.yml   唯一工作流：构建 APK
└── assets/images/       吉祥物与默认头像
```

### 代码规模

| 层 | 行数 |
|---|---|
| UI (`lib/ui/`) | ~3,300 |
| 服务 (`lib/services/`) | ~3,000 |
| 状态 (`lib/providers/`) | 690 |
| 模型 (`lib/models/`) | ~200 |
| 测试 (`test/`) | ~1,150 |
| **合计** | **~10,800** |

---

## 4. 数据层

### 4.1 Drift 表定义（`lib/services/database.dart`）

`schemaVersion = 9`

| 表 | 字段 | 用途 |
|---|---|---|
| `session_rows` | id(PK, text), title, createdAt, updatedAt | 会话 |
| `message_rows` | id(PK, autoInc), mid, sessionId, role, content, toolCallsJson, toolCallId, toolName, imagesJson, reasoning, createdAt | 消息 |
| `memory_note_rows` | id(PK), body, createdAt | 长期记忆 |
| `knowledge_docs` | id(PK), title, chunkCount, createdAt | 知识库文档 |
| `knowledge_chunks` | id(PK, autoInc), docId, idx, content, embeddingJson | 知识库分块 |
| `skill_items` | id(PK), name, template, createdAt | 技能 |
| `agent_roles` | id(PK), name, prompt, createdAt | 角色 |
| `mcp_servers` | id(PK), name, url, enabled, createdAt | MCP 服务器 |
| `token_usage_rows` | id(PK), createdAt, provider, model, inputTokens, outputTokens, cachedTokens, requests, costCents | Token 用量 |
| `task_rows` | id(PK), emoji, name, prompt, scheduleType(manual/daily), scheduleHour, scheduleMinute, enabled, lastRunAt, lastStatus, lastResult, createdAt | 自动任务 |

**索引**：`message_rows(session_id, id)` 复合索引（`database.dart:40`）
—— 按会话取消息是高频操作，无索引会全表扫描。

**迁移历史**：

| 版本 | 变更 |
|---|---|
| 2 | 新增 `knowledge_docs` / `knowledge_chunks` |
| 3 | `message_rows` 新增 `images_json`（多模态） |
| 4 | 新增 `skill_items` / `agent_roles` |
| 5 | 新增 `mcp_servers` |
| 6 | 新增 `idx_message_rows_session` 索引 |
| 7 | 新增 `token_usage_rows`（Token 统计） |
| 8 | `message_rows` 新增 `reasoning`（思考过程） |
| 9 | 新增 `task_rows`（自动任务：定时/手动触发的 Agent 提示词） |

> ⚠️ **索引绝对不能写在 `Table.customConstraints` 里**。
> drift 会把customConstraints 的内容拼进 `CREATE TABLE` 的括号内（当作列约束，
> 见 drift 源码 `migration.dart`），写成 `CREATE INDEX` 会得到非法 SQL：
> ```sql
> CREATE TABLE message_rows (..., CREATE INDEX IF NOT EXISTS ... ON message_rows (...))
> -- SqliteException: near "CREATE": syntax error
> ```
> 这会让**建表直接失败**，表现为所有涉及数据库的测试全部报错。
> 正确做法：在 `onCreate`（`m.createAll()` 之后）与 `onUpgrade` 里用
> `customStatement` 建索引——见 `AppDatabase._indexStatements` / `_createIndexes`。

### 4.2 唯一 ID 生成（`database.dart:141-145`）

```dart
int _idSeq = 0;
String uniqueId(String prefix) =>
    '${prefix}_${DateTime.now().millisecondsSinceEpoch}_${++_idSeq}';
```

带自增序列。**不要**用 `DateTime.now().millisecondsSinceEpoch` 单独作ID——
同毫秒内的多条记录会主键冲突（这曾是真实 bug，见 §11）。

### 4.3 存储位置

| 数据 | 位置 |
|---|---|
| 会话/消息/记忆/知识库 | `<appSupport>/orion_agent.sqlite` |
| 设置项 | SharedPreferences |
| API Key | FlutterSecureStorage（Keystore/Keychain 加密） |
| Alpine rootfs | `<appSupport>/alpine-rootfs` |
| Debian rootfs | `<appSupport>/debian-rootfs` |
| TTS 临时音频 | `<temp>/tts/` |

> ⚠️ **数据库文件名随项目更名而改**（`database.dart:122`）。
> 原为 `pocket_agent.sqlite`，现为 `orion_agent.sqlite`，**未做迁移**。
> 旧版安装的用户升级后会读到空库（数据文件仍在，只是不会被打开）。
> 若后续要支持平滑升级，在这里加一步「检测旧库并改名/复制」即可。

> ⚠️ **rootfs 目录名未随项目更名**（仍是 `alpine-rootfs` / `debian-rootfs`）。
> 这是有意的——改名会让已安装终端环境的用户需要重新下载几百 MB。

> ⚠️ **Debian rootfs 的备用下载地址依赖 GitHub Release**（`terminal_service.dart:53`）：
> `https://github.com/suanx/orion_agent/releases/download/terminal-env/...`
> 该 asset 由 CI 第 11 步自动构建并发布（用 `gh` CLI 绑定当前仓库，
> 不硬编码仓库名）。
>
> **迁移状态**：旧仓库 `suanx/pocket-agent` 已删除，代码与 git remote 均已
> 指向 `suanx/orion_agent` 并推送完成（提交历史完整保留）。
> 新仓库首次 CI 已成功运行并自动重建 `terminal-env` release
> （`debian-bookworm-arm64-rootfs.tar.xz`，14.7 MB）。
>
> **CI 已全绿**（run #9，`a1ac991`）：`flutter analyze` 0 error、
> 全部测试通过、产出 `orion-agent-apk`（12.2 MB）。
> 从旧仓库迁移后共迭代 9 轮才全绿，详见 §11.8。
>
> 好在它只是**备用源**：`install()` 里国内 Docker 镜像
> （daocloud / 1ms / dockerproxy）**优先**尝试，三个全失败才走 GitHub
> （`terminal_service.dart:212-225`）。所以国内用户通常感知不到这个依赖。
> 同理通知渠道 id 虽然改了（`orion_agent_agent`），但旧渠道残留不影响，
> Android 会保留未使用的渠道。

---

## 5. 服务层详解

### 5.1 LLM 客户端 (`llm_client.dart`)

OpenAI 兼容协议的 SSE 流式客户端。

**`chatStream()`** (`:38-176`) — 生成 `Stream<LlmEvent>`：

- `ContentDelta`：增量文本
- `FinalMessage`：本轮完整 assistant 消息（含工具调用）

**关键实现细节**：

1. **空闲超时** (`:88-95`)：60 秒无任何数据则抛异常。Dio 的 `receiveTimeout`
   在流式场景**不生效**（响应头已到达，计时器停止），必须自己实现。
2. **类型逐层收敛** (`:100-115`)：`decoded is! Map` / `rawChoices is! List` /
   `rawDelta is! Map`。网关可能返回 `{"error":{...}}` 或 `delta` 是 String，
   原来的强制转换会抛 `TypeError`。
3. **`finally { body0.close(); }`** (`:161-163`)：异常路径下关闭响应体，
   否则连接不释放，反复触发会耗尽连接池。
4. **tool_call name 兼容两种网关行为** (`:139-147`)：
   - 增量分片（主流）：`"web"` + `"_sea"` + `"rch"` → 拼接
   - 重复下发（部分网关）：每个 chunk 都给完整 `"web_search"` → 忽略重复

   实现：`if (cur == null || cur.isEmpty) → 赋值; else if (cur != n && !n.startsWith(cur)) → 拼接`
5. **index 缺失兜底** (`:132`)：`?? toolAcc.length`，避免并行 tool_call 全并进同一累加器。

**`embedBatch()`** (`:194-268`)：

- 按 `index` 显式对齐（不按响应顺序），否则网关乱序会导致向量错位
- 逐条校验：数量必须等于请求数、维度必须一致且非空
- 少数服务不返回 `index`，此时退回顺序对齐（`:221-241`）

### 5.2 Agent 编排器 (`agent_orchestrator.dart`)

ReAct 循环（推理 → 工具 → 观察 → 继续），**最多 8 轮**（`_maxSteps = 8`）。

**system prompt 拼装顺序** (`:206-231`)：

```
基础 prompt（含当前日期）
  + 角色设定
  + 长期记忆
  + 知识库检索结果（带【资料N｜来源: X】标注）
```

**关键行为**：

| 场景 | 处理 | 行号 |
|---|---|---|
| 空 `name` 的 tool_call | 仍回填 `role:"tool"`，内容为错误说明 | `:139-145` |
| 同一工具重复调用 3 次 | 提前中止，避免空转烧 token | `:148-156` |
| 用户取消 | 产出"已取消"，不报错 | `:107-111` |
| 中间轮有文本、末轮也有 | `lead` 累积各轮文本，避免"说过的话消失" | `:126-134` |
| 达到 8 轮上限 | 交付当前进展 + 说明，而非丢弃全部 | `:172-181` |
| 空内容返回 | 视为失败（可能被内容过滤），不落库空消息 | `:125-129` |

> ⚠️ **协议要求**：OpenAI 兼容协议要求 assistant 消息里的**每个** `tool_call`
> 都必须紧跟一条 `role:"tool"` 且 `tool_call_id` 匹配的回复。跳过任何一个
> 都会让下一轮请求被服务端以 `400 Invalid parameter` 拒绝，整轮 Agent 终止。

### 5.3 工具系统 (`tools.dart`)

**基类** (`:13-19`)：

```dart
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get parameters;   // JSON Schema
  Future<String> execute(Map<String, dynamic> args);
}
```

**7 个内置工具**：

| 工具名 | 类 | 说明 |
|---|---|---|
| `current_time` | `DateTimeTool` | 当前日期时间，含时区（支持 UTC±HH:MM） |
| `calculator` | `CalculatorTool` |递归下降解析器，精确计算 |
| `web_fetch` | `WebFetchTool` | 网页正文抓取 |
| `web_search` | `WebSearchTool` | DuckDuckGo 搜索，无需 Key |
| `save_memory` | `SaveMemoryTool` | 写入长期记忆 |
| `search_knowledge` | `SearchKnowledgeTool` | 知识库语义检索 |
| `run_command` | `RunCommandTool` | 终端执行 shell 命令 |

**计算器** (`:99-197`)：

- 文法：`_expr → _term → _unary → _power → _primary`
- 一元负号优先级**高于**幂运算：`-2^2 = -4`（不是 `4`）
- 幂运算右结合：`2^3^2 = 2^9 = 512`
- NaN / Infinity 会被拦下并返回错误说明（`:88-94`）——
  它们不是异常，会被当成功结果返回，Agent 会复述"计算结果是 NaN"
- 结果格式化：整数不带 `.0`，消除浮点尾数（`0.1+0.2 = 0.3`）

**ToolRegistry** (`:536-597`)：

- `register(Tool)`：同名跳过（幂等）
- `unregisterPrefix(String)`：按前缀批量注销 —— **MCP 重连必需**，
  否则同名跳过会让旧工具（持有旧 client）永久保留
- `execute(name, rawArgs)`：永不抛异常，错误转为文本返回给模型
- `toOpenAiTools()`：转 OpenAI `tools` 参数格式

**`web_search` 摘要配对** (`:307-360`)：

标题与摘要按**出现位置**配对，搜索范围截到下一条标题为止。
不能"按下标配对"也不能"向后贪心"——某条结果没有摘要时会错配到邻居。

### 5.4 RAG 知识库 (`rag_service.dart`)

**入库** `addDocument()` (`:52-104`)：

```
分块(chunkText, maxLen=800) → 分批向量化(每批16) → 逐批校验 → 事务写入
```

逐批校验长度与维度是**必需的**：只比总数时，两批互相抵消
（首批少 1、末批多 1）会通过检查，但从第 16 块起向量**永久错位**。

**检索** `search()` (`:118-180`)：

- 暴力余弦相似度（v1 规模几百块足够）
- `_minScore = 0.2`，`_defaultTopK = 4`
- 单条脏数据跳过并计数，**不毁掉整次检索**
- 维度不一致的分块跳过（余弦无意义）

**分块** (`text_chunker.dart`)：按空行分段→ 段内合并到 ≤800 → 超长按**字素簇**硬切。

> ⚠️ 必须按字素簇（`characters` 包）而非 UTF-16 code unit。裸 `substring`
> 会劈开代理对（emoji/扩展汉字），Dart 在 `jsonEncode`/`utf8.encode` 时
> 把它静默替换为 `U+FFFD` —— 不报错，emoji 变成 "�"。

> ⚠️ **当前无文件导入能力**：`knowledge_screen.dart` 只提供两个 `TextField`
> （标题 + 正文），**没有 file_picker / PDF / Word 解析**。图标用了
> `Icons.upload_file` 但功能是纯文本粘贴，容易误解。

### 5.5 长期记忆 (`memory_service.dart`)

- 上限：持久化 200 条，注入 prompt 最近 60 条、每条 200 字
- **去重**：`addNote` 按 trim 后文本判重（Agent 在 ReAct 循环里会反复存同一件事）
- **加载语义** (`load()` `:28-48`)：`_loaded` 只在查询**成功后**置位，
  并发调用共享同一个 `Future`。失败后允许重试
- 淘汰时**先 insert 后 delete**，否则新记录可能被当最旧的删掉

### 5.6 终端环境 (`terminal_service.dart`)

**运行机制** (`startOn()` `:387-421`)：

```bash
$nativeLibraryDir/libproot.so \
  -r <rootfs> -0 -w /root --link2symlink \
  -b /dev -b /proc -b /sys -b <hostWorkspace>:/workspace \
  /bin/sh            # 或 /bin/bash
```

- proot **不是独立打包的二进制**，而是放在 `jniLibs/arm64-v8a/libproot.so`，
  借用应用自身的 `nativeLibraryDir` 获得 exec 权限（`MainActivity.kt` 的
  MethodChannel `native_libDir`）
- 环境变量：`PROOT_TMP_DIR` / `PROOT_NO_SECCOMP=1` / `HOME=/root` / `PATH` / `LANG=C.UTF-8`

**发行版**：

| id | 名称 | 压缩 | 来源 |
|---|---|---|---|
| `alpine` | Alpine 3.22 | tar.gz | 清华镜像 |
| `debian` | Debian 12 bookworm | tar.xz / tar.gz | GitHub Release 或 Docker 代理 |

> ⚠️ **仅 aarch64**。Debian 走 Docker 代理时拉取 `debian:bookworm-slim` 的根层
> （经 `docker.m.daocloud.io` / `docker.1ms.run` / `dockerproxy.net` 三个代理依次尝试），
> 与 GitHub 的tar.xz 是**不同来源的两套 rootfs**。

**国内镜像配置** (`_postConfigure` `:340-356`)：

- DNS 写死 `223.5.5.5` / `119.29.29.29`
- Alpine → 清华 `apk/repositories`
- Debian → 改写 `sources.list` 为清华（含 contrib non-free non-free-firmware）
- npm → `registry.npmmirror.com`

**挂载点**：`/dev`、`/proc`、`/sys`、`<宿主 workspace>:/workspace`

**安装标记**：Alpine 看 `bin/busybox`，Debian 看 `usr/bin/apt-get`

**组件检测** (`terminal_screen.dart:15-25`)：nodejs / npm / git / python / uv / pip / opencode / ssh / sshd

**自启动任务** (`autostartTasks` `:146-156`)：

- 数据：`TerminalTask{name, command, enabled, distro}`，SharedPreferences key `terminal_tasks`
- 触发：**仅 App 冷启动时**（`main.dart:100-103`），不阻塞启动
- 同名任务幂等（重复调用忽略）
- ⚠️ **不是系统级开机自启**，没有 WorkManager/AlarmManager

### 5.7 语音 (`voice_service.dart`)

**Edge TTS**（免鉴权，仅需硬编码的 `TrustedClientToken`）：

| 项 | 值 |
|---|---|
| 端点 | `wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1` |
| 签名 | `Sec-MS-GEC` = SHA256(向下圆整到5分钟的 FILETIME + token) 大写 hex |
| UA 声明 | Chromium **143**（实测 131 及以下直接 403） |
| Origin | 伪造成 Chrome 扩展 |
| 输出 | `audio-24khz-48kbitrate-mono-mp3` |
| 语速音量 | SSML 百分比增量（`+N%`） |

握手分两次文本帧：`Path:speech.config` → `Path:ssml`。

> ⚠️ **三个必须遵守的协议约束**（任一不满足都合成不出声音）：
>
> 1. **不能用 `WebSocket.connect`**。Dart 会在 User-Agent 前面拼上
>    `Dart/<版本> (dart:io), `，变成
>    `user-agent: Dart/3.13 (dart:io), Mozilla/5.0 ... Edg/143.0.0.0`，
>    微软按 UA 判定客户端，非浏览器 UA **直接 403**。
>    实测（同一台机器、同一网络、同一份签名）：
>    - 裸 socket + 纯浏览器 UA → `101 Switching Protocols`
>    - `WebSocket.connect`（UA 被污染）→ `403 Forbidden`
>
>    因此改为手工实现握手（`_edgeHandshake`）：`SecureSocket` + 手写
>    HTTP Upgrade + 自己的帧编解码（`_WsFrameDecoder` / `_wsEncodeText`）。
>
> 2. **音频在文本帧（opcode 0x1）里，不在二进制帧**。格式是
>    `X-RequestId:…\r\nContent-Type:audio/mpeg\r\nX-StreamId:…\r\nPath:audio\r\n\r\n<MP3>`。
>    原实现只解析二进制帧（opcode 0x2），握手成功后**一字节音频都拿不到**。
>
> 3. **SSML 的 `X-Timestamp` 必须是 JavaScript 风格且以大写 `Z` 结尾**：
>    `Sat Oct 03 2026 05:00:10 GMT+0000 (Coordinated Universal Time)Z`
>    （官方 edge-tts 源码标注 "This is not a mistake, Microsoft Edge bug"）。
>    另需 32 位十六进制 `X-RequestId`。
>
> 4. **音色名必须用正确的完整形式**（真根因，详见 §11.13）：
>    `Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)`
>    —— locale 与音色名之间是**「逗号 + 空格」**。
>    服务端接受短名 `zh-CN-XiaoxiaoNeural`，但**不接受**「短名直接塞进括号」
>    的混血形式，会回关闭帧 `code=1007 Unsupported voice`。
>    统一由 `edgeVoiceName()` 转换。

**播放**：`audioplayers`（底层 ExoPlayer/MediaPlayer）播放合成的 MP3 文件，
播放期间轮询世代号响应「停止」。原先依次尝试 `/system/bin/stagefright` →
`/system/bin/toybox play` → `ffplay`，现代 Android 上三者全部不可用
（stagefright 已从系统移除、toybox 无 play 子命令、ffplay 在 proot 环境里
app 进程的 PATH 看不到），导致合成成功也无声（详见 §11.16）。

**引擎**：`edge`（默认）/ `system`（flutter_tts）。Edge 失败**自动回退**系统 TTS。
失败原因记录在 `VoiceService.lastError`，语音设置页试听后展示，便于排查。

**播报竞态**：用**世代号** `_generation` 机制 (`:72`)：
`stopSpeaking()` 自增世代号作废所有在途流程。
原先用共享 `bool _cancelled`，新一次 `speak` 会把它重置为 false，
导致上一段"复活"、两段声音重叠；且 `Process.start` 的 await 窗口内杀不掉进程。

**7 个音色**（全 zh-CN，`voice_service.dart:34-40`）：
晓晓（女·温柔，默认）、晓伊（女·活泼）、云希（男·阳光）、
云扬（男·播报）、云健（男·沉稳）、晓北（女·东北口音）、晓妮（女·陕西口音）

**STT**：`speech_to_text`，系统 ASR。

> ⚠️ `onError` / `onStatus` 必须传给 **`initialize()`**，不是 `listen()`——
> `listen()` 只有 `onResult` / `listenOptions` 等参数。插件文档还明确说明
> 这两个回调在首次 `initialize` 后**无法重置**，所以必须在 `ensureSpeech()`
> 里一次性注册（`voice_service.dart:89-101`）。
>
> 不注册的话，`cancelOnError: true` 让底层自动停止后 `_listening` 不复位，
> UI 仍显示红色麦克风，用户得点两次才能恢复。

**文本预处理** `stripMarkdownForSpeech` (`:477-494`)：
代码块 → 「（代码略）」、去标记符号、按**字素簇**截断 400 字。

### 5.8 通知 (`notification_service.dart`)

**两个渠道**（Android O+ 必须显式建）：

| id | 名称 | importance |
|---|---|---|
| `orion_agent_agent` | Agent 通知 | `defaultImportance` |
| `orion_agent_answer_silent` | Agent 通知（静音） | `low` |

> ⚠️ **必须两个渠道**：Android O 起通知重要度由**渠道**决定，实例级
> importance 会被**向上钳制**到渠道、不能低于渠道。只有一个 defaultImportance
> 渠道时，「静音通知」开关会被系统忽略、仍然响铃震动。

**触发场景**：

| 场景 | id | payload |
|---|---|---|
| 回答完成 | 1001 | `NavPayload.chat`（点击跳对话页） |
| 任务结束 | 1002 | 无 |
| 设置页测试 | 1002 | 无 |

摘要截断 120 字；>40 字自动 `BigTextStyleInformation` 展开。

**`init()` 并发保护** (`:39-74`)：共享进行中的 `Future`。
原来无保护时，两个调用方并发进入，输的一方在 catch 里把 `_ready` 改回
`false`——**此后每次 `show()` 都失败，通知永久失效**。

**iOS 权限**：`hasPermission()` 查 `checkPermissions().isAuthorized`。
原来 iOS 直接返回 `true`，用户拒绝授权后设置页仍显示"已开启"。

### 5.9 MCP 客户端 (`mcp_client.dart`)

- **传输**：Streamable HTTP，JSON-RPC 2.0 over POST
- **协议版本**：`2024-11-05`
- **Accept**：`application/json, text/event-stream`（两种响应都解析）
- **握手**：`initialize` → `notifications/initialized`
- **能力**：⚠️ **仅 tools**。`initialize` 的 capabilities 传空 `{}`，
  **不支持** resources / prompts / sampling / roots

**工具命名**：

```
最终名 = sanitizePublic(服务器名) + "__" + sanitize(原始工具名)
sanitize: replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
```

调用时用**原始名**。描述兜底：`MCP 工具 X（来自 Y）`。

**连接管理** (`mcp_service.dart:51-96`)：

- 默认超时 8 秒，`initialize` 给 2 倍
- **重连前先按服务器名前缀注销旧工具** —— 否则旧 `McpTool`（持有旧 client/Dio）
  被永久保留，新连接被丢弃
- 每个服务器独立 Dio，失败 `close(force: true)`，失败打日志不静默

### 5.10 技能系统 (`skill_service.dart`)

**形态**：提示词模板（**不是可执行逻辑**）。表`skill_items`。

**内置 18 个技能，4 个分类**：

| 分类 | 技能 |
|---|---|
| 写作办公 | 写周报、润色文字、总结归纳、翻译、回邮件、提取待办 |
| 信息检索 | 今日要闻、读链接总结、专题调研、对比选型 |
| 生活助手 | 做行程规划、记账算账、查我的资料、记住这件事 |
| 开发者工具 | 跑代码⚡、解释报错、写正则、整理成表格 |

「跑代码」是唯一带 `needsTerminal: true` 的技能，安装时终端未就绪会跳过。

**调用**：输入以 `/` 开头 → 第一个空格前段为技能名，空格后为参数。
名字**精确匹配**，无模糊/别名。

**占位符**：唯一占位符 `{input}`（全局替换）。
模板不含 `{input}` 时：参数非空则追加「补充输入：」，否则直接返回模板。

> ⚠️ 缓存 `_loaded` 只在查询成功后置位（`:300-318`）。原来前置置位导致
> 查询失败后 `findByName()` 恒 null，`/技能名` **整个App 生命周期失效**。

### 5.11 角色系统 (`role_service.dart`)

角色是**注入 system prompt 的人格设定**：

```
'\n你当前的角色设定：${persona.trim()}'
```

作用域：**对所有对话生效**（UI 明确说明，无法按会话切换）。

> ⚠️ **没有预置角色**。代码里只有 CRUD + 缓存，无 preset 列表。
> UI 中唯一的固定条目是「默认助手」，它的作用是**取消角色**（`activeRoleId = ''`），
> 不是可编辑的预置角色。预置的是**技能**（18 个）和**主题**（6 套）。

### 5.12 文件与存储 (`file_storage_service.dart`)

**6 个统计条目**（范围**互斥**，做了减法）：

| 条目 | 可清理 |
|---|---|
| 工作区 | ✅ |
| Alpine 终端环境 | ❌ |
| Debian 终端环境 | ❌ |
| TTS 音频缓存 | ✅ |
| 临时文件 | ✅（= temp − tts）|
| 应用数据 | ❌（= support − 两个 rootfs）|

> ⚠️ 范围必须互斥。不做减法时 `temp/tts` 会被计入「TTS 缓存」和「临时文件」
> 两项，`alpine-rootfs`/`debian-rootfs` 会被计入终端环境与「应用数据」两项，
> 展示的占用**明显虚高**。

**统计必须在后台 isolate** (`compute` `:76-81`)：
rootfs 是数万文件、数百 MB，同步遍历会卡死 UI 触发 ANR。

**`clearCache()` 白名单** (`:173`)：只清temp 下的 `tts` 子目录。
不能全清 temp——终端安装过程中的解压临时文件也在 temp 下，
全清会破坏进行中的安装。

### 5.13 导航服务 (`navigation_service.dart`)

通知点击跳转的基础设施。

**`NavIntent(tab, prefill, seq)`** — `seq` 是必需的：
`StateProvider` 只在值不相等时才通知，没有 `seq` 时
**连续点两条相同通知会被静默吞掉**。

**为什么不用 navigatorKey**：底部 Tab 选中态是 `HomeShell._tab` 这个内部
State，只有 `HomeShell` 知道怎么切；navigatorKey 只能 push/pop。

**冷启动**：通知回调可能在 `runApp` 之前触发，那时没有 widget 可导航。
意图先记在 provider 里，`HomeShell` 首帧主动 `read` 一次补执行。
> 实测确认：`StateProvider` 在监听注册前写入的值**不会补发通知**，
> 所以「记账」与「首帧补消费」必须成对存在。
> 这顺带修好了「App 被系统杀死后点通知进来，落在任务页而非对话页」。

消费时**先清空再执行**，避免在 `ref.listen` 回调里同步写同一个 provider 而递归。

---

## 6. 状态层

`lib/providers/providers.dart`（690 行），全部 provider 集中在此。

### 6.1 聊天状态

`chatProvider = StateNotifierProvider<ChatNotifier, ChatState>`

`ChatState`：`sessions` / `activeSessionId` / `isStreaming` / `streamingContent` / `steps` / `error`

**`send()` 的关键行为**：

- 锁定 `sessionId`（`:527`）—— 流式结束后按它回写，
  **不能**读 `state.activeSession`：整个 `await for` 期间用户可切换会话，
  回答会被写错地方，甚至产生没有 session 行的孤儿记录（重启即丢）
- 每个事件前检查 `mounted`（`:531`）
- 所有 DB 写入走 `_persistOp` 包裹（`:632-640`）——
  原来是裸 Future，磁盘满/DB 关闭时错误被完全吞掉
- 收尾 `isStreaming = false` 放在函数末尾统一处理

**会话 CRUD**：`newSession` / `selectSession` / `deleteSession` / `clearAllSessions`
删除与清空前会先 `stop()` 流式，避免产生孤儿消息行。

### 6.2 配置状态

`configProvider = StateNotifierProvider<ConfigNotifier, ConfigState>`

`ConfigState`：`configs` / `activeId` / `error`

**配置存储分离**：配置 JSON（含 API Key）进 `FlutterSecureStorage`，
`activeId` 进 SharedPreferences。

**`_persist()` 串行化** (`:251-271`)：`_persistChain` 链式调用避免并发写同一 key
时旧快照覆盖新值（用户「加 A → 立刻加 B → 立刻删 A」会导致重启后 B 消失、A 复活）。
失败时记录 `error`，设置页顶部展示错误卡片。

**`_load()` 不覆盖用户修改** (`:190-246`)：`_localTouched` 标志——
用户可能在 `_secure.read` 返回前就添加了模型，随后 `_load` 用旧列表整体覆盖。

### 6.3 设置项 Provider

均为 `StateProvider`，持久化到 SharedPreferences：

| Provider | pref key |
|---|---|
| `ttsEngineProvider` | `tts_engine` |
| `ttsVoiceProvider` | `tts_voice` |
| `ttsRateProvider` | `tts_rate` |
| `ttsVolumeProvider` | `tts_volume` |
| `notifyOnAnswerProvider` | `notify_on_answer` |
| `notifyPreviewProvider` | `notify_preview` |
| `notifySilentProvider` | `notify_silent` |
| `activeRoleIdProvider` | （内存）|
| `prefillProvider` | （内存）|
| `themeProvider` | `theme_id` |
| `themeModeProvider` | `theme_mode` |

> `prefillProvider` / `navIntentProvider` 刻意**不自动 dispose**——
> 冷启动时它们必须活到首帧之后。

---

## 7. UI 层

### 7.1 外壳

`HomeShell` = 4 Tab（`IndexedStack` 保持状态）+ 会话抽屉（`Drawer`）+ 磨砂玻璃底部导航。

Tab 顺序：`ChatScreen` / `TasksScreen` / `SkillsScreen` / `ProfileScreen`
—— 与 `HomeTab` 常量一一对应。

`ref.listen(navIntentProvider)` 注册在 `initState`（**不能放 build**：
每次重建会新增监听，且回调里改 provider 会触发「build 期间不可修改 provider」断言）。

首次运行会检测终端环境，全部缺失时推入 `SetupScreen` 引导下载。

### 7.2 对话页（最大文件，1867 行）

- 消息列表 + 流式气泡（`_StreamingBubble` 显示 `steps`）
- **消息版式**（参考主流 AI 对话产品重构）：用户消息 = 右对齐
  `primaryContainer` 浅色气泡（深浅色/六主题自适应）；助手消息 = **无气泡**
  满宽 Markdown 正文（`_mdStyleSheet` 定制标题/引用/列表样式）；
  消息列表底部「内容由 AI 生成，请注意核实」水印
- **思考行**（`_ReasoningPanel`）：收起一行「正在思考/已思考 ›」，右侧 ⚡模式徽章
  （快速回答/深度思考，跟随输入栏思考开关，仅流式期间显示）；展开为限高 220
  圆角卡片可滚动，流式结束瞬间自动收起
- **代码块**（`_CodeBlock`）：语言栏（语言名 + 复制 + 全屏玻璃弹窗）+ 轻量语法
  高亮（注释/字符串/数字/关键字四类着色，`_highlightSpans` 正则分词）；
  超 12 行默认折叠到 240 高，底部渐隐 + 圆形箭头展开；行内 `code` 仍走
  MarkdownBody builders 的紧凑样式
- **Markdown 缓存**：`_CachedMarkdown` 键含明暗模式（样式随亮度变化），
  流式 delta 不重复解析历史消息
- 输入栏：发送/停止按钮切换、图片附件（`image_picker` 拍照或相册，1600px/quality80）
- 语音输入（麦克风按钮）、技能调用（`/技能名`）
- **发送前拦截**（`:112-119`）：流式期间必须**先拦截再清空输入框**，
  否则用户刚输入的文字和已选图片会被静默销毁
- **自动滚动**（`:214-221`）：按 `streamingContent` 长度去重后才注册
  post-frame 回调。原实现无条件在 `build` 里注册，流式期间每秒注册几十个，
  不断重启 250ms 动画 → 滚动抖动
- **图片解码缓存**（`:18-47`）：`Image.memory` 缓存键取自 bytes **对象身份**，
  每次 build 新建 `Uint8List` 会让缓存永不命中 → 每帧重新 base64 解码
- `dispose` 里停止录音（`:105-111`）

### 7.3 页面清单

| 页面 | 状态 |
|---|---|
| `chat_screen` | ✅ 完整（无气泡正文 + 思考行 + 代码块卡片） |
| `cloud_account_screen` | ✅ 云端登录页 + 个人中心（卡密/设备/用量） |
| `sessions_drawer` | ✅ 会话列表、切换、删除 |
| `skills_screen` | ✅ 18 内置 + 自定义 |
| `roles_screen` | ✅ CRUD（无预置） |
| `knowledge_screen` | ⚠️ 仅文本粘贴，无文件导入 |
| `mcp_screen` | ✅ 添加/启用/删除 + 重连 |
| `terminal_screen` | ✅ 安装/卸载/组件检测/自启任务 |
| `settings_screen` | ✅ 多模型服务 CRUD |
| `appearance_screen` | ✅ 6 主题 + 3 明暗模式 |
| `notification_settings_screen` | ✅ 4 项设置 + 权限申请 |
| `storage_settings_screen` | ✅ 统计 + 2 项清理 |
| `tasks_screen` | ⚠️ **M3 占位页，无任何实现** |

---

## 8. 构建与 CI

**唯一工作流**：`.github/workflows/build.yml`（push to main +手动触发）

**18 个步骤**：

1. Flutter stable setup（`subosito/flutter-action@v2`，带缓存）
2. `flutter create --platforms android --project-name orion_agent .`
   ——平台目录**不提交**，CI 按当前 stable 生成
3. 注入 `ci/MainActivity.kt`（MethodChannel `orion_agent/system`）
4. `sed` 把 `targetSdk` 降到 **28**
5. 追加第二个 `android {}` 块（关闭 release lint + 开启 core library desugaring）
6. **校验** Kotlin jvmTarget（不注入任何 DSL，见下）
7. 注入 edge-to-edge 到 `styles.xml`
8. ImageMagick 从 `assets/images/mascot.webp` 生成全套图标
9. 下载 Termux 的 proot 四件套（proot / proot-loader / libtalloc.so.2 /
   libandroid-shmem.so）→ `assets/`，逐一校验 ELF magic
10. 注入权限与通知 receiver
11. 构建 Debian rootfs 并发布到 Release（tag `terminal-env`，已存在则跳过）
12. `flutter pub get`
13. `dart run build_runner build`（Drift codegen）
14. `flutter analyze`
15. `flutter test`
16. `flutter build apk --release --target-platform android-arm64`
17. 上传 artifact `orion-agent-apk`
18. job 收尾

### 为什么 targetSdk = 28

Android 10+ 禁止 app 在自有目录内 `exec()`；终端环境（proot）需要在数据目录
执行 guest 二进制，Termux 系方案均以 targetSdk 28 规避。副作用：
Android 13+ 的 `requestNotificationsPermission()` 返回 null，
需回查 `areNotificationsEnabled()`。

### ⚠️ 血泪教训：不要在 CI 里注入 Gradle 代码

**这个仓库曾连续 5 次提交修同一个 CI 失败**，每次修复都引入新问题：

| 提交 | 引入的问题 |
|---|---|
| `63fe47e` | `ci/MainActivity.kt` 用 `///` 注释（Kotlin 无此语法）→ 编译失败 |
| `8e89f70` | Java设 11 / Kotlin 默认 17 → `Inconsistent JVM-target` |
| `d6afd5d` | 注入 `build.gradle.kts` 的注释用了 shell 风格 `#` → `Expecting an element` |
| `d82608b` | 注入已废弃的 `kotlinOptions` → 脚本编译失败 |

**根因**：CI 注入代码去改 `flutter create` 生成的模板，
而 Flutter 升级会改变模板 → 必然再次破裂。

**当前做法**（步骤 6）：**只校验，不注入**。

```bash
# 检测到 kotlinOptions 即失败（Kotlin 2.x 已废弃该 DSL）
if grep -q "kotlinOptions" "$F"; then exit 1; fi
# 确认模板自带 compilerOptions + JVM_17 + VERSION_17
grep -q "compilerOptions" "$F" || exit 1
grep -qE 'jvmTarget\s*=\s*.*(JVM_17|VERSION_17)' "$F" || exit 1
```

> 📌 **根本性建议**（未实施）：改为提交 `android/` 目录，
> 停止在 CI 里 `flutter create` + 注入。这是唯一能根治的做法。
>
> 另一个注意点：追加第二个 `android {}` 块是**合法且正确**的
> （Kotlin DSL 允许多个同名配置块，Gradle 会合并）。
> 不要"顺手清理"或改成改写模板——那正是前几轮反复失败的原因。

### 失败诊断

三个关键步骤都做了 annotation 输出（无 repo 管理员权限也能在 PR 页看到）：

- **Analyze**：`grep -E '^\s*(error|warning|info)'` → `::error ::`
- **Test**：抓 `[E]` 结尾的失败用例名 + 其后的 Expected/Actual/Which/reason
- **Build APK**：抓 `e:`/`w:`/`error:`/`What went wrong`/`Execution failed`/`Caused by`

> 💡 测试断言**务必带 `reason`**，把真实字符串带出来，
> CI annotation 会直接显示，无需依赖 `print` 或 job log。

---

## 9. 配置项全集

### SharedPreferences

| key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `llm_active_id` | String | `''` | 当前启用的模型服务 id |
| `tts_enabled` | bool | `false` | TTS 总开关 |
| `tts_engine` | String | `edge` | `edge` / `system` |
| `tts_voice` | String | `zh-CN-XiaoxiaoNeural` | 音色 |
| `tts_rate` | double | `1.0` | 语速 0.5–2.0 |
| `tts_volume` | double | `1.0` | 音量 0.0–1.0 |
| `notify_on_answer` | bool | `false` | 回答完成后通知 |
| `notify_preview` | bool | `true` | 显示回答摘要 |
| `notify_silent` | bool | `false` | 静音通知 |
| `theme_id` | String | `classic` | 配色主题 |
| `theme_mode` | String | `system` | `system`/`light`/`dark` |
| `terminal_setup_done` | bool | `false` | 首次运行引导是否已完成 |
| `terminal_tasks` | String(JSON) | `[]` | 终端自启动任务数组 |
| `cloud_base_url` | String | 无 | 云端服务器地址（空 = 云功能降级，本地不受影响） |
| `cloud_device_id` | String | 自动生成 | 云端设备标识（激活/登录/设备管理用） |
| `cloud_email` | String | 无 | 登录邮箱（后端响应不回传，登录时本地记录，登出清除） |

> `pubspec.lock` 被 `.gitignore` 忽略，依赖在 CI 统一解析。

### FlutterSecureStorage

| key | 说明 |
|---|---|
| `llm_configs` | 模型服务 JSON 数组（含 API Key）|
| `cloud_tokens` | 云端账号 JWT（access + refresh，2h/30d 轮换）|
| `cloud_device_token` | 云端 MCP 设备令牌（`dt_` 前缀，编进 MCP URL）|

> 旧版本把配置明文存在 SharedPreferences，读取时会自动迁移到加密存储并删除明文
> （`providers.dart:196-204`）。

### CI 注入的 Android 权限

`INTERNET` / `RECORD_AUDIO` / `POST_NOTIFICATIONS` / `VIBRATE` / `WAKE_LOCK` /
`READ_EXTERNAL_STORAGE` (maxSdk 32) / `WRITE_EXTERNAL_STORAGE` (maxSdk 28)

---

## 10. 数据模型

### ChatMessage (`models/chat_message.dart`)

```dart
class ChatMessage {
  final String id;
  final String role;        // system / user / assistant / tool
  final String content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;
  final List<String> images;// data URL（base64），user 消息可附带
  final DateTime createdAt;
}
```

`toApiJson()`（`:52-73`）：带图片的 user 消息用多段 content
（`text` + `image_url`），实现多模态。

### ToolCall

```dart
class ToolCall {
  final String id;
  final String name;
  final String arguments;   // 原始 JSON 字符串
}
```

### ChatSession (`models/chat_session.dart`)

`id` / `title` / `messages` / `createdAt` / `updatedAt`

> ⚠️ 构造时**必须复制 messages 列表**。直接 `s.messages.add(...)` 就地修改会
> 让 `copyWith` 检测到引用未变而不触发重建，界面不刷新。

### LlmConfig (`models/llm_config.dart`)

> ⚠️ **2026-10-03 结构调整：一条配置 = 一个提供商 = 一组模型。**
> 原先「一条配置 = 一个模型」，同一家的多个模型要建多条配置、API Key
> 重复填。现在改为两级：`LlmConfig`（提供商）持有 `List<ProviderModel>`。
> 模型级参数（上下文、输出上限、温度）从提供商挪到了模型上。

**`LlmConfig`（提供商）字段**

| 分组 | 字段 |
|---|---|
| 基本信息 | `id` / `name` / `baseUrl` / `apiKey` / `userAgent` / `type` |
| 选项 | `enabled` / `fullUrl` / `responsesApi` / `promptCacheKey` / `multiKey` / `proxy` |
| 多 Key | `extraKeys` |
| 模型 | `models` / `defaultChatModel` / `defaultEmbeddingModel` |

**`ProviderModel`（模型）字段**：`name` / `kind` / `contextWindow` /
`maxOutputTokens` / `temperature`。温度范围 **0–1.5**，默认 **0.7**。

**关键派生属性**

| 属性 | 语义 |
|---|---|
| `chatModel` | 取 `defaultChatModel` 指定的；被删掉则回退列表第一个 |
| `model` | `chatModel?.name ?? ''`（兼容旧调用方） |
| `embeddingModelName` | 同上，供 RAG 使用 |
| `ready` | 有 Base URL 且有聊天模型 |
| `effectiveKeys` | 主 Key + （多 Key 开启时的）备用 Key |
| `displayName` | name → host → 兜底文案 |

**旧数据迁移**：`fromJson` 里，若没有 `models` 字段，就把根上的
`model` / `embeddingModel` / `kind` / `contextWindow` / `maxOutputTokens` /
`temperature` 折成模型条目。已验证三种旧形态（纯聊天、聊天+向量、
纯向量）都能无损迁移——丢了 embedding 名会导致「AI 不认识导入的资料」。

**`enabled` 取代了旧的单选 `activeId`**：多个提供商可同时启用
（列表页会显示多个「已启用」徽标），对话使用**列表中第一个已启用的**。
`ConfigState.activeConfig` 逐级降级（已启用且可用 → 已启用 → 任意一条），
保证老数据不会因为没人勾选 enabled 而彻底用不了。

**请求地址推导**（`LlmClient.chatUrl` / `embeddingUrl` / `modelsUrl`）
见 §11.14 —— 完整 URL 模式下有个「端点后缀是两段」的坑。

---

## 11. 已修复的缺陷档案

以下缺陷均已修复并有回归测试。按严重程度排序。

### 11.1 CI 阻塞

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 1 | Build APK 失败 | 模板已自带 `kotlin{compilerOptions{}}`，CI 又注入已废弃的 `kotlinOptions` | 改为纯校验，检测到 `kotlinOptions` 即失败 |

### 11.2 静默丢数据 / 功能永久失效

| # | 缺陷 | 根因 | 修复位置 |
|---|---|---|---|
| 2 | AI 回答写到错误会话，重启即丢 | 流式结束后读 `state.activeSession`，期间用户可切换 | `providers.dart:527` 锁定 `sessionId` |
| 3 | 流式期间回车，用户输入被静默销毁 | 输入框先清空，`send()` 的并发守卫才return | `chat_screen.dart:135-144` 清空前拦截 |
| 4 | 通知**永久失效** | `init()` 无并发保护，输的一方在 catch 里把 `_ready` 改回 false | `notification_service.dart:39-74` 共享 Future |
| 5 | 静音通知开关无效 | Android O+ 实例级 importance 被渠道钳制 | `notification_service.dart:84-100` 双渠道 |
| 6 | 长期记忆永久失效 | `_loaded` 在 await 之前置位，失败后无法重试 | `memory_service.dart:28-48` 成功后置位 |
| 7 | 技能永久失效（`/技能名` 无效） | 同上 | `skill_service.dart:300-318` |
| 8 | 角色永久失效 | 同上 | `role_service.dart:29-49` |
| 9 | 数据库写入错误被吞 | 裸 Future，磁盘满时静默丢消息 | `providers.dart:637-645` `_persistOp` |
| 10 | 麦克风永久卡死 | `cancelOnError: true` 下底层自动停止，但 `_listening` 未复位 | `voice_service.dart:89-101` 在 `initialize()` 注册 `onError`/`onStatus` |
| 11 | 配置保存失败无提示 | 异常被吞，UI 显示保存成功 | `settings_screen.dart` 错误卡片 |

### 11.3 协议层正确性

| # | 缺陷 | 根因 | 修复位置 |
|---|---|---|---|
| 12 | 第一步工具调用后突然 400 | 空 `name` 的 tool_call 被跳过，未回填 `role:"tool"` | `agent_orchestrator.dart:139-145` |
| 13 | 工具永远找不到 | 网关重复下发完整 name，`web_search` + `web_search` = 错名 | `llm_client.dart:139-147` |
| 14 | 停止按钮显示"请求失败（HTTP null）" | `DioExceptionType.cancel` 未区分 | `agent_orchestrator.dart:107-111` |
| 15 | 模型说过的话凭空消失 | 中间轮文本未累积进最终答案 | `agent_orchestrator.dart:126-134` |
| 16 | 8 轮工具调用后全部作废 | 达到上限只报错，不交付已有进展 | `agent_orchestrator.dart:172-181` |
| 17 | 连接池耗尽 | SSE 异常路径未关闭响应体 | `llm_client.dart:161-163` |
| 18 | 向量永久错位入库 | `addDocument` 只比总数，两批可互相抵消 | `rag_service.dart:66-84` 逐批校验 |
| 19 | 知识库整体失效 | 单条脏 JSON 毁掉整次检索，且异常被空 catch 吞掉 | `rag_service.dart:135-155` 跳过+计数 |
| 20 | MCP 停用后工具仍被调用 | 无 `unregisterPrefix`，重连因同名跳过而保留旧工具 | `tools.dart:558-560` + `mcp_service.dart:61-63` |
| 21 | Edge TTS 的 `ConnectionId` 与 `X-RequestId` 不一致 | 调用两次 `edgeConnectionId()` | `voice_service.dart:263-264` |
| 22 | WebSocket 握手超时泄漏 socket | `.timeout()` 只中断等待，不关闭进行中的握手 | `voice_service.dart:266-281` |

### 11.4 计算正确性

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 23 | `-2^2` 返回 4 | `_power()` 先调 `_unary()`，负号被贪婪吃掉 | `tools.dart:171-189` 一元负号提到 `_power` 之上 |
| 24 | Agent 复述"计算结果是 NaN" | NaN/Infinity 不是异常，被拼进结果字符串 | `tools.dart:88-94` 显式拦下 |
| 25 | `0.1+0.2` 显示 `0.30000000000000004` | 全程 double 无格式化 | `tools.dart:96-114` `_fmtNum` |
| 26 | 摘要张冠李戴 | title/snippet 独立正则按下标配对 | `tools.dart:307-360` 按位置配对+范围截断 |
| 27 | 时区丢掉 30/45 分钟偏移 | `Duration.inHours` 截断 | `tools.dart:63-75` |

### 11.5 数据完整性

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 28 | emoji 在知识库里变成 "�" | 按 code unit 硬切劈开代理对，Dart静默替换为 U+FFFD | `text_chunker.dart:28-35` 按字素簇 |
| 29 | 知识库分类占用显示虚高 | `temp/tts` 被计入两项，rootfs 被计入两项 | `file_storage_service.dart:146-166` 互斥减法 |
| 30 | UI 冻结 / ANR | 主 isolate 同步重复扫描数百 MB rootfs | `file_storage_service.dart:76-81` `compute` |
| 31 | 清理缓存破坏进行中的终端安装 | 无白名单全清 temp | `file_storage_service.dart:173`白名单 |
| 32 | 主键冲突 | ID 无自增序列，`sessions.length` 会因删除而回落 | 统一用 `database.dart` 的 `uniqueId()` |
| 33 | 启动长白屏 | `loadSessions` N+1 查询 + `sessionId` 无索引 | `storage_service.dart:18-38` +复合索引 |

### 11.6 UI / 生命周期

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 34 | `setState() called after dispose()` | 读图片字节的 async gap 后无 `mounted` 检查 | `chat_screen.dart:194` |
| 35 | 滚动抖动、动画推不到底 | 在 `build` 里无条件注册 post-frame 回调 | `chat_screen.dart:233-240` 按长度去重 |
| 36 | 滚动卡顿 | 每帧重新 base64 解码图片 | `chat_screen.dart:20-49` 解码缓存 |
| 37 | 录音一直占用麦克风 | `dispose` 未停止录音 | `chat_screen.dart:106-112` |
| 38 | 双声重叠播放、"停止"杀不掉进程 | 共享 `bool _cancelled` + `Process.start` 的 await 窗口 | `voice_service.dart:72` 世代号 |
| 39 | 语音播报永久卡住 | `await p.exitCode` 无超时 | `voice_service.dart:359` 120s 超时 |
| 40 | TTS 临时 mp3 永久残留 | 同上（finally 永不执行） | 同上 |
| 41 | 「第二条回答以后就不响了」 | `onlyAlertOnce: true` + 固定 id 1001 | `notification_service.dart:177` |
| 42 | Edge 音色"配了没用" | 裸 `substring` 截断产生 U+FFFD | `voice_service.dart:493` 字素簇 |
| 43 | 通知点击无响应 | `init()` 无参调用，`onTap` 永不注册 | `main.dart:92-96` |
| 44 | 存储页卡顿数秒 | 6 项统计同步在 UI isolate | `file_storage_service.dart` |

### 11.7 可观测性

| # | 缺陷 | 修复 |
|---|---|---|
| 45 | 知识库为何失效完全无迹可循 | `providers.dart:461-465` 空 catch → `debugPrint` |
| 46 | MCP 连接失败与"没有可用服务器"无法区分 | `mcp_service.dart:91` 打日志含URL 与原因 |
| 47 | 配置解析失败静默 | `providers.dart:234-236` 打日志 |

### 11.9 Edge TTS 完全失效（403 / 无音频）

用户反馈"edge 语言失败"。实测定位到**三个叠加的独立原因**，
任一都会导致合成失败，必须全部满足：

| # | 根因 | 症状 | 修复 |
|---|---|---|---|
| 48 | `WebSocket.connect` 污染 User-Agent（Dart 前缀） | 握手直接 **403** | 改手工握手 `_edgeHandshake`（`SecureSocket` + 手写 Upgrade） |
| 49 | 只解析二进制帧（opcode 0x2） | 握手成功但**一字节音频都没有** | `parseEdgeFrame(bytes, isText:)` 双格式；音频在文本帧里 |
| 50 | SSML 用 ISO 时间戳 | 服务端只回 `turn.start`，不产音频 | 新增 `edgeJsTimestamp()`，JS 风格 + 末尾大写 `Z` |

**定位过程（可复用的方法）**：

1. 写探测脚本连真实端点，确认能复现 403
2. **交叉验证**：同机器装官方 `edge-tts 7.2.8` → **成功**。
   由此排除"网络/服务端/签名算法"三种可能，把范围缩到"客户端实现"
3. **抓握手报文**：把 `WebSocket.connect` 指向本地 ServerSocket，
   打印实际发出的字节 → 发现 `user-agent: Dart/3.13 (dart:io), Mozilla/5.0 …`
4. **裸 socket 对照**：同一份签名，干净 UA → 101；带 Dart 前缀 → 403。因果链闭合
5. 剩下两个原因靠**读官方源码**（`edge_tts/communicate.py`）确认：
   `ssml_headers_plus_data` 的注释直接写明 X-Timestamp 必须补 `Z`；
   音色名的转换规则在 `TTSConfig.__post_init__` 里
   （当时误读成「短名不被接受」，实际是「拼错的完整名不被接受」，
   见 §11.13）

> 💡 **关键教训**：Dart 的 `WebSocket` 会在 UA 前拼 `Dart/x.y (dart:io), `。
> 任何需要"伪装成浏览器"的服务（不只是 Edge TTS）都不能用
> `WebSocket.connect`，必须手工握手并完全控制请求头。
>
> 同时，"连接成功"不等于"工作正常"——本次握手返回 101，
> 但因为解析的是错误的帧类型，表现依然是"没有声音"。

### 11.8 CI 调试实录（迁移到orion_agent 后）

仓库迁移后CI 迭代 9 轮才全绿。**这一节记录的是方法论，不是代码**——
本地无法运行 `flutter test`（Flutter SDK 不可达），所有问题都由 CI 暴露。

| run | 报错数 | 根因 |
|---|---|---|
| #1–2 | 10 errors | `material.dart' show ThemeMode` 连带挡掉 `debugPrint`；`ordered` 类型写错 |
| #3 | 5 errors | `speech_to_text.listen()` 没有 onError/onDone；`isAuthorized` 应为 `isEnabled`；final 重复赋值 |
| #4 | 1 error | 修final 时忘了删旧声明，产生 duplicate_definition |
| #5 | analyze 通过，**9 tests failed** | 索引写进 `customConstraints` → 建表 SQL 非法 |
| #6 | **3 tests failed** | 测试断言假设错误（`ToolRegistry` 非空、关闭 db 不抛异常） |
| #7 | **1 test failed** | 同上，测试假设不成立 |
| #8 | 4 errors | **我的操作失误**：按行号切片替换时误删了相邻`test()` 声明行 |
| #9 | ✅ **Success** | analyze 0 error、全测试通过、APK 12.2 MB |

**四条方法论**：

1. **本地 `dart analyze` 在缺 Flutter 依赖时会大量漏报** —— 包括语法错误。
   验证语法要把文件复制到独立目录单独 analyze，或用大括号配平检查兜底。

2. **CI 的报错可能指向错误的方向**。9 个测试失败看起来像"数据库逻辑坏了"，
   实际是建表 SQL 语法错误（索引放错位置）。逐个读测试代码、验证数据、
   审查自己的 diff，最后靠**读 drift 源码**才找到真因。

3. **查证 API 必须读官方文档/源码**，不能凭印象：
   - `speech_to_text.listen()` 没有 onError/onDone，它们是 `initialize()` 的参数
   - `NotificationsEnabledOptions` 字段是 `isEnabled`
   - `ResponseBody.close()` 在 dio 里被标`@internal`
   - drift 的 `customConstraints` 只能放列约束，不能放 CREATE INDEX

   PubCache 里的插件源码是权威依据：
   `C:\Users\<user>\AppData\Local\Pub\Cache\hosted\pub.dev\<pkg>-<ver>\`

4. **写测试前先确认被测对象的真实状态**。我假设 `ToolRegistry` 是空的、
   假设关闭 db 后查询一定抛异常 —— 两次都错。而且我曾写了一个
   "验证 `_loaded` 语义"的测试，用真实 Dart 一跑就发现
   **它对正确实现和错误实现的行为完全一致**，根本测不出回归。
   写完测试要用真实数据跑一遍，确认它真的能失败。

> ⚠️ 结构性改动用「按内容匹配」，不要用「按行号切片」——
> run #8 的 4 个 error 就是这么来的。

### 11.10 代码审查发现并修复的缺陷（2026-10-03）

打包前对全部未提交改动做了一轮静态审查，发现 9 个问题，均已修复：

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 48 | **drift 编译不过** | `TokenUsageRows` 没注册进 `@DriftDatabase(tables: [...])`，drift 不会生成 `tokenUsageRows` getter 与 Companion | `database.dart` 补上表声明 |
| 49 | **proot 路径指向共享库** | `_prootPath = target.path` 写在 `for` 循环内，最终值是字典最后一个键（`libtalloc.so`）的路径 | 移到循环外，显式指向 `proot` |
| 50 | 源码含裸 NUL 字节 | 分桶键用 `'$provider\0$model'` 拼接，git 把文件当二进制、diff 与审查工具全失效 | 改用 Record 作键，彻底不用分隔符 |
| 51 | `chmod` 找不到 | `Process.run('chmod', ...)` 依赖 PATH，Android 上会抛 `ProcessException` 而非返回非 0 退出码 | 改用绝对路径 `/system/bin/chmod`，权限降到 755 |
| 52 | **清空统计会崩** | 确认对话框弹出期间用户返回页面，`_load()` 里的 `setState` 抛 after-dispose | `_load()` 开头加 `mounted` 守卫 |
| 53 | **安装中退出会崩** | `_checkTools` 开头无 `mounted` 检查，而安装过程长达 20 分钟 | 同上 |
| 54 | 向量模型被当聊天模型用 | 发送守卫只查 `activeConfig == null`，没查 `kind`，只配向量模型时会去打 `/chat/completions` | 守卫加 `kind != ModelKind.chat` 分支 |
| 55 | 思考开关重启丢失 | provider 从 prefs 读初值，但切换时只改内存不落盘 | 切换时 `setBool` 写回 |
| 56 | 建议语在点按时换掉 | 随机抽样写在 `build()` 里，流式输出时每个 delta 都重抽 | 改为 `StatefulWidget`，`initState` 抽一次 |
| 57 | 卡片水波纹露角 | `Container` 只画背景不裁子节点 | 加 `clipBehavior: Clip.antiAlias` |
| 58 | usage 统计偏小 | `if (rawUsage is Map && usage == null)` 只取第一帧，但部分网关每帧都下发累计值 | 去掉守卫，取最后一帧 |
| 59 | 本地 `flutter test` 失败 | `pubspec.yaml` 声明的 proot asset 本地不存在 | 仓库内放占位文件，CI 构建时用真实二进制覆盖 |

> 💡 #48 与 #49 是**阻断性**的：前者会让 CI 三步全红，后者让终端功能
> 100% 不可用。这两个都是「analyze 查不出来」的问题——本地无 Flutter SDK、
> 依赖解析不了，只能靠逐行审查发现。

### 11.11 状态栏黑边（修了两轮才找到真根因）

**症状**：状态栏位置一条黑边，页面本身正常。第一轮修复无效——因为改错了地方。

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 60 | 状态栏黑边（真根因） | **CI 往 `styles.xml` 注入了 `windowDrawsSystemBarBackgrounds=true`**，把系统栏背景的绘制权交给 Android 框架。框架用主题默认值（不透明黑）画状态栏，且画在 Flutter 之上——`main.dart` 里 `statusBarColor: Colors.transparent` 被完全架空 | CI 不再注入该属性，改为显式声明 `statusBarColor`/`navigationBarColor` 为透明 |
| 61 | 深色模式下黑边依旧 | CI 用 `find ... \| head -1` **只处理一个** `styles.xml`。项目通常有 `values/` 与 `values-night/` 两份，`find` 返回顺序不保证，深色模式用到的那份没被处理 | 改用 `mapfile` 遍历**全部** `styles.xml`，逐个校验 |
| 62 | 三个页面顶栏没背景 | 只给 `chat_screen` 包了 `Container`，`tasks`/`profile`/`skills` 的 `SafeArea` 是裸露的 | 抽出公共组件 `StatusBarArea`，四个页面统一使用 |
| 63 | 状态栏与页面有色差 | `HomeShell` 的 `Scaffold(backgroundColor: surface(context))` 用的是**卡片色**（纯白），而页面用 `scaffoldBackgroundColor`（灰白 `#F6F6F6`） | 统一为 `scaffoldBg(context)` |

**为什么第一轮会失败**：第一轮只在 Flutter 侧给 `chat_screen` 加了 `Container`，
而黑边是**系统层**画的——在 Flutter 内容之上。Flutter 里涂什么色都盖不住。
这类问题的教训是：**先分清是谁在画**。修 UI 黑边/透明区域前，先确认那层
是系统画的（styles.xml）还是 Flutter 画的（widget 树），两者的修法完全不同。

**`windowDrawsSystemBarBackgrounds` 是什么**：Android 主题属性，决定
「系统栏背景由谁画」。为 `true` 时 Android 框架会用主题默认色绘制状态栏和
导航栏（不透明），Flutter 侧设的透明色无效。edge-to-edge 下应该让
Flutter 画，所以**不能设成 true**。

**新增公共组件** `lib/ui/status_bar_area.dart`：这是一条**全局约束**
（edge-to-edge 下所有顶栏都必须给状态栏区域涂底色），逐页包 `Container`
必然会漏、以后新增页面又要记得包一次。组件独立成文件而非放在
`home_shell.dart`，是因为 HomeShell 导入了 tasks/profile/skills 三个页面，
组件放那里会让它们形成循环依赖。

### 11.12 环境组件检测永久卡死（runOn 死锁）

**症状**：安装 Alpine 完成后，日志停在最后一行「检测 alpine 环境组件…」，
界面永久转圈、再也点不动。rootfs 其实**早已安装成功**。

**根因**：`runOn` 里的这两行

```dart
await sub1.asFuture<void>();
await sub2.asFuture<void>();
```

等的是「**stream 关闭**」，不是「进程退出」。proot 会把 stdout/stderr 的
文件描述符**继承**给 guest 里的子进程；只要 guest 内还有任何进程持有这个
fd（残留的 apk 进程、后台任务、甚至 proot 自身的辅助线程），Dart 侧的
stream 就永远收不到 done 事件 → `asFuture()` 永不完成。

关键点：**此时 `proc.exitCode` 早就返回了**（进程确实退出了），
是这两行白等。所以表现为「命令跑完了但界面不动」，极具迷惑性——
我第一反应是 proot 起不来、rootfs 损坏，方向完全错了。

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 64 | **检测永久卡死** | `await sub.asFuture()` 等 stream 关闭；proot 把 fd 继承给 guest 进程后永不关闭 | 抽出 `drainProcessStreams()`，加 1.5s grace 超时，超时后 `cancel()` 订阅 |
| 65 | 探测串行极慢 | 9 个组件串行，每个 proot 启动 0.3~2 秒 → 最坏 18 秒 | 改 `Future.wait` 并发探测 |
| 66 | 单个组件可拖垮整轮 | 用 `runOn` 默认的 120s 超时；某个组件（如 `opencode --version` 可能联网）挂住就卡 2 分钟 | 单项降到 20s，且 `catchError` 兜住不让单点失败中断整轮 |
| 67 | 异常时 `_busy` 永不复位 | `_checkTools` 没有 try/finally，未预料的异常直接冒泡，界面卡在 busy | 整体包 try/catch/finally，`finally` 里强制 `_busy = false` |
| 68 | `startOn` 无超时 | 读 asset（proot 几 MB）+ 准备挂载点，任一步卡住就无限等 | 加 20s 超时并给出可读错误 |

**修复后的实测**（用真实 Dart 复现「stderr 永不关闭」场景）：

| 场景 | 耗时 | 结果 |
|---|---|---|
| stderr 正常关闭 | 44 ms | 立即返回 |
| stderr 永不关闭 | 226 ms | grace 后放行，输出完整 |
| 旧实现（无 grace） | 800 ms 后仍未完成 | 确认会挂死 |

**排查方法**：`Process` 无法在单元测试里构造，所以把「等待 stream 关闭」
这段抽成顶层函数 `drainProcessStreams()`，用 `StreamController` 精确控制
close 行为即可复现。测试里还踩了两个坑（都靠跑真实 Dart 抓到）：

1. `Future.wait(...).timeout()` 的 `onTimeout` **必须返回 `List<void>`**，
   返回 `null` 或 `void` 会编译失败 —— 本地 `dart analyze` 漏报。
2. `StreamSubscription` **没有 `isClosed` 属性**；且不能用 `asFuture()`
   判断「是否已关闭」—— 流没关闭时它不会完成。正确做法是用
   `StreamController(onCancel: ...)` 判定。

### 11.13 Edge 语音完全没声音（音色名拼错，真根因）

**症状**：设置页点试听，按钮永久停在「播放中…」；实际对话里朗读也没有声音。
**我此前修了三轮都没修对**——前几轮改的 UA、帧类型、时间戳格式都是**真问题**
但不是**这一个**问题。

**真根因**：音色名拼成了「短名直接塞进括号」的混血形式。

```dart
// 错误（原实现）
'Microsoft Server Speech Text to Speech Voice ($voice)'
// → Microsoft Server Speech Text to Speech Voice (zh-CN-XiaoxiaoNeural)
//                                      横线 ↖          （应为逗号+空格）
```

服务端收到后先回 `Path:turn.start`，紧接着发**关闭帧**并断开：

```
code=1007  reason="Unsupported voice
  Microsoft Server Speech Text to Speech Voice (zh-CN-XiaoxiaoNeural)."
```

服务端实际接受两种写法：
1. 短名 `zh-CN-XiaoxiaoNeural`（服务端自行解析）
2. 完整名 `Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)`

**唯独不接受混血形式**。而我们恰好拼成了第三种。

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 69 | **Edge 语音无声音** | 音色名拼成混血形式，服务端 1007 拒绝并断开 | 新增 `edgeVoiceName()`，按官方规则转换 |
| 70 | 关闭帧被静默丢弃 | 关闭帧负载没有 `\r\n\r\n` 头，`parseEdgeFrame` 返回 null 后被忽略；调用方只能干等 30s 超时，拿到「未返回音频」这种无线索的错误 | `_onFrames` 单独处理 opcode 0x8，用 `edgeCloseReason()` 解析出状态码与原因并抛出 `EdgeClosedException` |

**转换规则**（与官方 `edge_tts` 的 `TTSConfig.__post_init__` 完全一致）：

```
zh-CN-XiaoxiaoNeural          → (zh-CN, XiaoxiaoNeural)
zh-CN-liaoning-XiaobeiNeural  → (zh-CN-liaoning, XiaobeiNeural)
```

即分隔符是「逗号 + 空格」；三段式 locale（如 `liaoning`、`shaanxi`）
把第三段并入 locale 段，音色名只留末段。

**定位方法（本轮最有价值的部分）**：

1. **先做交叉验证排除环境**：同机装官方 `edge-tts 7.2.8` → 合成成功
   （11 KB）。排除网络、服务端、签名算法。
2. **把官方源码里消息的构造函数全部打印出来**（`mkssml`、
   `ssml_headers_plus_data`、`date_to_string`、`TTSConfig.__post_init__`），
   逐条与自己的实现比对——**转换规则就在这里，一次就能看到**。
3. **写一个能跑真实实现的端到端脚本**：`voice_service.dart` 依赖 Flutter
   无法 `dart run`，所以程序化抽出相关函数（连同文档注释）拼成独立脚本，
   跑真实网络、打印每一帧。
4. **必须解码关闭帧**。第一轮跑完只看到「turn.start 之后超时」，
   毫无线索；把 opcode 0x8 的负载按「2 字节状态码 + UTF-8 原因」解出来，
   服务端才把真正的错因写在脸上。

**诊断脚本的输出（修复前后对比）**：

```
修复前：
  帧 op=0x1 ... Path:turn.start
  帧 op=0x8 len=88        ← 被忽略
  超时 30s：未收到 turn.end      音频字节=0

修复后：
  帧 op=0x1 ... Path:turn.start
  帧 op=0x1 ... Path:response
  帧 op=0x2 ... Path:audio   ×N
  帧 op=0x1 ... Path:turn.end
  音频字节=26352（MP3 合法：头 fff3）
```

**四个音色实测**（含两个三段式 locale）：

| 音色 | 音频字节 |
|---|---|
| `zh-CN-XiaoxiaoNeural` | 26352 |
| `zh-CN-liaoning-XiaobeiNeural` | 33408 |
| `zh-CN-shaanxi-XiaoniNeural` | 28512 |
| `zh-CN-YunxiNeural` | 26352 |

**教训**：这是同一个功能上**第四次**「以为修好了」。前三次每次都能自圆其说
（UA 污染、帧类型、时间戳格式），但都没有真正打通端到端。
真正的突破口不是继续读代码，而是**拿官方实现做对照实验**并在失败时
**把服务端的错误原样解出来**——而不是只看自己的代码哪里可能有问题。

### 11.14 提供商 / 模型两级重构

把「一条配置 = 一个模型」改成「一个提供商 = 一组模型」，
并落地截图里的三个页面（提供商列表 / 配置 tab / 模型 tab）。

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 71 | **完整 URL 模式推出错误路径** | `_rootOf` 最初只砍最后一段路径，`https://host/v1/chat/completions` → `https://host/v1/chat` → 拼出 `https://host/v1/chat/embeddings`（实测确认） | 端点后缀 `chat/completions` 是**两段**，按已知后缀整体剥离 |
| 72 | 换模型会导致默认模型漂移 | 原先靠「列表第一个」当默认值，增删模型会让选中项改变 | 新增 `defaultChatModel` / `defaultEmbeddingModel` 显式记录 |
| 73 | 老数据升级后可能一条都不能用 | 新增 `enabled` 字段，老数据没有该字段 | `fromJson` 默认 `enabled=true`；`activeConfig` 逐级降级兜底 |
| 74 | 点错「+」会留下空提供商 | 新建即落库，用户直接返回就留一条空记录 | 详情页记录 `_touched`，未填写任何内容时 `dispose` 里删除 |
| 75 | 模型编辑器输入被键盘遮挡 | 底部表单未随键盘上移 | `viewInsets.bottom` 计入 padding |

**新增/变更文件**：`settings_screen.dart`（三个页面）、
`tts_settings_screen.dart`（语音设置从模型设置里拆出）、
`llm_config.dart`（结构重写 + 迁移）、`llm_client.dart`（多 Key 失败切换、
代理、自定义 UA、缓存键、拉取模型、测试连接）、`providers.dart`（enabled 语义）。

**多 Key 故障切换的边界**：只在「产出任何内容**之前**失败」时切换。
已吐过字再重试会导致内容重复，那种情况直接抛错。只对 401/402/403/429
切换——5xx 换 Key 没意义，超时换 Key 也一样超时。

**`Response API（新版）` 与`面板脚本`已从界面移除（2026-10-04）**：
两者都未实现（前者缺 Responses 协议栈，后者缺脚本运行时），
参考同类产品的反馈，「暂未支持」的占位开关对用户是噪音，
决定直接删掉入口；`responsesApi` 字段保留在数据模型里以兼容旧配置，
待真正实现协议栈后再恢复界面。

### 11.15 打包前全量复查（2026-10-03，第三次推送前）

本地无 Flutter SDK，跑不了 `flutter analyze`，改用四层静态体检：
语法配平扫描、import 有效性、**类作用域检查**、CI shell 块 `bash -n`，
覆盖 58 个 dart 文件与 11 个 CI run 块。

第一轮（run#16 前）改了 2 处，CI 仍挂在 Analyze；annotation 暴露出真正的
error 是另一个文件。合并成下表：

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 78 | **`drainProcessStreams` 外部不可见**（error ×3） | 函数写在了 `class TerminalService` 的**大括号之内**，只是缩进为 0。Dart 按成员声明解析它 → 变成实例方法。类内 `runOn` 调用一切正常，测试 `import` 后却是 `undefined_function` | 移到两个 class 之间（真正顶层） |
| 79 | 构建失败诊断被污染 | `build.yml` 里有一行 `// Execution failed、Caused by 等`。`run:` 块是 **sh**，`//` 不是注释而是命令，会去执行路径 `/` 并报 `Is a directory`，把真正的 Gradle 错误挤走 | 改回 shell 的 `#` |
| 80 | `_uaDioCache` 未使用（warning） | 注释写「UA 单独缓存」，但实现里 UA 其实拼进了 `_proxyDioCache` 的 key，字段是多余的 | 删字段，注释改成与实现一致 |
| 81 | 多余的 `!`（warning） | 见下方「Dart 的 `!` 会提升变量」 | 去掉 |

**踩坑一 · 缩进 0 不等于顶层**。`drainProcessStreams` 缩进是 0，
括号配平也对，肉眼和格式化工具都不会报错——但它在类的 `{` 与 `}` 之间。
判断只能靠**全局大括号深度**（深度 ≥1 即在某个类型体内）。
为此写了 `ci_check/class_scope.py` 专查这一类，并用手写样例验证过它
确实能报出该问题、且不误报正常代码。教训：凡往 Dart 文件里插入
顶层函数/常量，先确认插入点在类的闭合大括号之外。

**踩坑二 · Dart 的 `!` 会提升变量**（第一轮判断反了，CI 打脸）。
初看 `active!.chatModel!.name` 后面接闭包里的 `active.copyWith(...)`，
认定 `!` 只作用于所在表达式、闭包里 receiver 仍可空，于是补了个 `!`。
CI 立刻报 `unnecessary_non_null_assertion` —— 说明原写法本来就是对的：
Dart 的 flow analysis 把 `x!` 当作**类型提升点**，且 `active` 是 final 局部
变量时，提升在闭包内同样有效。`flutter_lints` 不提示这一点，只能靠
annotation 验证。以后遇到「`!` 之后又在别处用该变量」，先怀疑原代码没问题。

**顺带修正**：附录 A 中 `schemaVersion` 记为 6，实际已是 7
（Token 用量统计表 `TokenUsageRows` 加入时升版）。

### 11.16 终端 proot 无法启动（依赖三缺一错）与 TTS 播放层重构（2026-10-03）

两个「修了还坏」的顽疾，这次拿到了**二进制级证据**。

**终端**：rootfs 安装成功，但「检测组件」时 proot 必挂。用 python 直接下载
CI 同款的 Termux deb 包、解析 `proot` 二进制的 ELF 动态段，实锤：

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 82 | **libtalloc 名字错误** | proot 的 `DT_NEEDED` 是 `libtalloc.so.2`（精确匹配），CI 却把 `libtalloc.so.2.5.0` 复制改名成 `libtalloc.so`——设备上链接器按 `.so.2` 查找必然失败 | asset 改名 `libtalloc.so.2`，部署保持该名字 |
| 83 | **缺 `libandroid-shmem.so`** | Termux 构建的 proot 链接了它（`DT_NEEDED` 第二项），此前从未打包 | CI 追加下载 `libandroid-shmem_0.7` 包并注入 |
| 84 | **缺 `proot-loader`** | Termux 的 proot 是「loader + ptrace」双进程架构，二进制里有字符串 `the loader was not found or doesn't work`；不设 `PROOT_LOADER` 时它按编译进去的 `/data/data/com.termux/.../libexec/proot/loader` 找，必败 | CI 额外提取 deb 内 `libexec/proot/loader`，运行时设 `PROOT_LOADER` |
| 85 | **`LD_LIBRARY_PATH` 未设置** | bionic 链接器不搜索 app 数据目录，库就算在也不被找到 | `startOn` 的 environment 加 `LD_LIBRARY_PATH=<binDir>` |

排查方法值得留档：**错误文本不在 proot 二进制里**（字符串搜索无命中），
说明它来自链接器或更底层；而 `DT_NEEDED` 是确定性证据，不依赖对
错误消息的 OCR 猜测。CI 端新增 ELF magic 校验（`od` 读前 4 字节），
占位文本/空文件/架构不对当场拦下。

**TTS**：「试听」永久停在「播放中…」且无声。两层问题：

| # | 缺陷 | 根因 | 修复 |
|---|---|---|---|
| 86 | **播放层全废** | 依次尝试 `/system/bin/stagefright`（Android 10 起已移除）→ `toybox play`（toybox 无此子命令）→ `ffplay`（在 proot 环境里，app 进程 PATH 看不到）——合成成功也一字节放不出 | 改用 `audioplayers`（ExoPlayer/MediaPlayer），`onPlayerComplete` + 世代号轮询实现可打断的等待 |
| 87 | **Sec-MS-GEC 低概率错位** | 官方算法是「FILETIME 秒 → mod 300 → ×10^7」；原实现先乘 10^7 再对 3×10^9 取模，当秒余数恰为 299 且亚秒部分 ≥0.1s 时结果比官方多一个窗口（300s），服务端 403。约 0.3% 的时间段必现 | 按官方顺序重写，注释说明为什么顺序不能颠倒 |
| 88 | **失败静默** | `_speakSystem` 的 `catch (_) {}` 吞掉一切（设备缺 TTS 引擎也无声无息），UI 永远「播放中…」 | `lastError` 字段记录失败原因；试听后展示；系统 TTS 的 `speak` 加 60s 超时兜底 |

定位「播放层全废」的关键：UI 卡死 ≠ 合成失败。合成层有 15s/30s 超时会
抛错回退，真正挂住的是 `await speak()` 之后的播放层与被吞错误的系统 TTS。

---

### 11.17 更新提示永远指向「相同版本」（kAppVersion 未随发版同步）

**现象**：安装最新版 APK 后，启动弹窗/关于页仍一直提示安装同一版本。

**根因**：应用自报版本是 `about_screen.dart` 里手写的 `kAppVersion` 常量。
v0.2.0 发版只升了 `pubspec.yaml` 的 `version`，忘升 `kAppVersion`（停在 0.1.9）。
更新检查拿 0.1.9 比远端 0.2.0 → 永远「发现新版本 V0.2.0」，用户装完最新包
自报版本仍是 0.1.9，如此循环。

**修复**：`kAppVersion` 同步为 0.2.0；「我的」页关于行版本号改为引用
`kAppVersion`（原来还有一处硬编码 V0.1.9）；AGENTS.md 发版清单第 1 步
强制 pubspec 与 `kAppVersion` 同步。

**教训**：版本号必须单一事实来源；发版 checklist 要覆盖所有自报版本的位置。

## 12. 待修复的问题

按建议优先级排序。**均未实现**。

### P0 — 影响功能可用

| # | 问题 | 位置 | 说明 |
|---|---|---|---|
| 1 | **知识库不支持文件导入** | `knowledge_screen.dart:31-108` | 只有标题+正文两个 `TextField`，无 `file_picker`/PDF/Word/Markdown 解析。图标用 `Icons.upload_file` 但功能是纯文本粘贴，**容易误解**。若要支持需引入 `file_picker` + 文档解析器，且 `rag_service` 要能处理非纯文本 |
| 2 | **定时任务完全未实现** | `tasks_screen.dart`（128 行） | M3 占位页：无 service、无 provider、无 `Timer`、无任务表。3 张硬编码示例卡片标签一律写"非定时"，按钮只弹 SnackBar。通知里的「任务结束」（`notifyTaskDone`）目前**只被测试按钮调用** |
| 3 | **终端环境不支持非 arm64** | `terminal_service.dart` | 只有 `aarch64` 的 proot 与 rootfs。需要 x86_64（模拟器）或 arm32 |
| 4 | **CI 从未验证过全部改动** | — | 本地无 Flutter SDK（官方站与国内镜像均不可达），`flutter test` 无法执行。三个提交均未推送（remote 需交互式认证）。**所有新测试都未经实际运行** |

### P1 — 体验与健壮性

| # | 问题 | 位置 | 说明 |
|---|---|---|---|
| 5 | 冷启动任务不精确 | `main.dart:100-103` | `autostartTasks` 在首帧后立即执行，但此时 proot 可能还在安装中；且任务耗时较长时与首屏渲染竞争 |
| 6 | RAG 全表扫描 | `rag_service.dart:140` | 每次检索加载全部分块的向量 JSON。数据量上千块后明显变慢。注释提到"后续可换 sqlite-vec" |
| 7 | 会话无分页加载 | `storage_service.dart:18-38` | 启动时全量加载所有会话的所有消息。会话多时占用内存大 |
| 8 | 知识库检索无 docId 过滤 | `rag_service.dart` | 只能全库检索，无法限定文档范围 |
| 9 | TTS 音色不可试听 | `settings_screen.dart` | 7 个音色只能靠猜，无试听按钮 |
| 10 | 无导出/分享功能 | — | 对话不能导出为文本/Markdown，技能不能分享 |
| 11 | 图片仅 base64 存库 | `message_rows.images_json` | 大图会让 `message_rows` 膨胀，且 JSON 存储无压缩 |
| 12 | Edge TTS 无重试 | `voice_service.dart` | WebSocket 失败直接回退系统 TTS，中间不留重试 |

### P2 — 工程改进

| # | 问题 | 说明 |
|---|---|---|
| 13 | **CI 注入 Gradle 的根本问题** | 见§8。根治方案：提交 `android/` 目录，停止 `flutter create` + 注入 |
| 14 | 无集成测试 | 只有单元测试。Agent 主链路（send → SSE → tool → 落库）无端到端测试 |
| 15 | 无 mock LLM 服务 | 测试 SSE 解析需要真实/伪服务端|
| 16 | `chat_screen.dart` 782 行 | 偏大，可拆分为消息列表/输入栏/工具栏/图片查看器 |
| 17 | `providers.dart` 690 行 | 所有 provider 集中一处，可按域拆分 |
| 18 | 错误提示为裸字符串 | 无错误码/i18n 体系。如需多语言要重构 |
| 19 | 无崩溃上报/日志文件 | Release崩溃只能靠用户反馈 |
| 20 | 依赖版本宽松 | `pubspec.lock` 不跟踪，构建可复现性差 |

---

## 13. 后续可增加的功能

按价值/成本比排序。

### 13.1 高价值低成本

| 功能 | 涉及 | 说明 |
|---|---|---|
| **知识库文件导入** | `file_picker` + 解析器 | 支持 PDF / Word / Markdown / txt。PDF 可用 `syncfusion_flutter_pdfviewer` 或纯 Dart 的 `pdfx`；Markdown 需剥离 front-matter 与代码块（避免代码污染向量） |
| **定时任务落地** | `tasks_screen` + service + 表 | Android 用 `WorkManager`（可精确调度且系统级存活），iOS 用 `BGTaskScheduler`。需新建 `task_items` 表并升 schemaVersion 到 7 |
| **流式内容的知识库注入** | `agent_orchestrator` | 当前仅发送前检索一次。多轮工具调用后应重新检索 |
| **TTS 音色试听** | `settings_screen` | 点击即 `speak()` 一段样音 |
| **对话导出** | `chat_screen` | 导出为 Markdown / 纯文本，走 `SharePlus` 或写文件 + `open_filex`（项目已有） |
| **会话搜索** | `sessions_drawer` | 按标题与消息内容检索 |
| **MCP 只读资源支持** | `mcp_client` | 支持 `resources/list` + `resources/read`，让 Agent 能读 MCP 提供的静态资源 |

### 13.2 中等功能

| 功能 | 说明 |
|---|---|
| **RAG 性能优化** | 引入 sqlite-vec 或 hnsw；向量量化（int8）降低内存；embedding 结果缓存 |
| **多模态输入** | 消息已支持 `images`，但需确认各模型服务的多模态兼容性；可加"拍照提问"的显式入口 |
| **Agent 流式步骤可视化** | `steps` 已有数据，可做成可折叠的执行轨迹面板 |
| **提示词编辑器** | 让用户可视化调整 system prompt，加预设模板 |
| **角色按会话切换** | 当前角色对所有对话生效，可改为会话级|
| **技能参数化** | `{input}` 之外支持 `{selection}`、`{date}` 等内置变量 |
| **知识库文档预览** | 导入后能查看分块结果，便于排查检索质量 |
| **MCP 服务器健康状态** | 显示最后连接时间、工具数、错误原因 |

### 13.3 探索性

| 功能 | 说明 |
|---|---|
| **本地小模型接入** | llama.cpp / Ollama 本地推理，隐私优先模式 |
| **多 Agent 协作** | 规划Agent + 执行 Agent + 审查 Agent |
| **记忆分层** | 短期（会话内）/ 中期（最近 N 轮）/ 长期（知识库）三级记忆 |
| **主动性** | 基于定时任务主动推送（今日要闻、日程提醒） |
| **插件系统** | 类似 MCP 但面向 Dart 扩展 |
| **SQLite 向量索引** | 用 `sqlite-vec` 替代暴力检索 |
| **对话分支** | 从任意历史轮次 fork 新分支 |

---

## 14. 测试

### 现有测试

| 文件 | 覆盖 |
|---|---|
| `chat_message_test.dart` | 消息序列化、多模态 JSON |
| `database_test.dart` | Drift 表定义 |
| `mcp_test.dart` | MCP 协议解析 |
| `rag_test.dart` | 分块 + RAG 检索 |
| `services_db_test.dart` | SkillService / RoleService |
| `storage_test.dart` | 会话持久化 |
| `terminal_test.dart` | 终端服务 |
| `theme_test.dart` | 主题构建 |
| `voice_test.dart` | 朗读文本清理 |
| `widget_test.dart` | Widget 冒烟 |
| `calculator_test.dart` | 计算器优先级/NaN/格式化 |
| `regression_test.dart` | emoji 分块、ToolRegistry 注销、记忆去重、RAG 脏数据 |
| `navigation_test.dart` | 通知 payload 映射、冷启动记账、seq 去重 |

### 约定

> ⚠️ **断言必须带 `reason`**。测试里用 `reason:` 把真实字符串带出来，
> CI annotation 会直接显示，无需依赖 `print` 或 job log权限。

```dart
// ✅ 好
expect(s.contains('#'), isFalse, reason: '仍含#，s=$s');

// ❌ 差：失败时看不到实际值
expect(s.contains('#'), isFalse);
```

### 待补测试

- Agent 主链路集成测试（伪 LLM 服务驱动 SSE）
- `AgentOrchestrator` 的 8 轮上限、重复调用中止、空 tool_call 回填
- `HomeShell` 导航意图消费的 Widget 测试
- `StorageService.loadSessions` 的 N+1 回归（查询次数断言）

---

## 15. 开发注意事项

### 必须遵守

1. **不要在 CI 里注入 Gradle 代码**。见 §8，这是本项目最大的坑源。
2. **新增 drift 索引要在 `onCreate` 和 `onUpgrade` 两处建**
   （用 `_createIndexes()`，**不要**写进 `customConstraints`——会让建表 SQL 非法）。
3. **列表必须不可变替换**。`[...list, item]` 而非 `list.add()`，
   否则 `copyWith` 检测不到变化，UI 不刷新。
4. **异步间隙后检查 `mounted`**。任何 `await` 之后碰 State/Context 前。
5. **断言带 `reason`**。
6. **文本截断用字素簇**（`characters` 包），不要裸 `substring`。

### 容易踩的坑

| 坑 | 说明 |
|---|---|
| **主键冲突** | 用 `uniqueId(prefix)`，不要用 `millisecondsSinceEpoch` 单独作ID |
| **`StateProvider` 相等判断** | 值相同不通知。需要重复触发时加自增字段 |
| **`StateProvider` 不补发** | 监听注册前写入的值不会被回调，需主动 `read` |
| **Dio `receiveTimeout` 在流式无效** | 响应头到达即停表，要自己实现空闲超时 |
| **Android 通知 importance被渠道钳制** | 实例级不能低于渠道，静音需独立渠道 |
| **`jsonDecode` 静默替换非法字符** | 孤立代理项变U+FFFD，不抛异常 |
| **`chunkText` 会合并相邻短段落** | 造测试数据时用超长段落（>800 字）才能真正分块 |
| **`orderBy` 后 N+1 查询** | 批量查询后在内存分组 |
| **`main.dart` 的 `load()` 在 runApp 前** | 抛异常会阻断启动，必须 try/catch 降级 |

### Dart 3 便利 API（无需 import `collection`）

`firstOrNull` / `lastOrNull` / `isNotEmpty` 等在 Dart 3 中内置于 `dart:core`。
但 `Completer` 需要 `import 'dart:async'`；`Value` 需要 `import 'package:drift/drift.dart'`。

> ⚠️ `Uri.pathSegments` 会保留结尾空串（`'file:///a/b/'` → `[a, b, '']），
> 所以 `lastOrNull` 返回空串而非 `b`。需先 `.where((s) => s.isNotEmpty)`。

---

## 附录 A：关键常量速查

| 常量 | 值 | 位置 |
|---|---|---|
| Agent 最大轮数 | 8 | `agent_orchestrator.dart:58` |
| 分块长度 | 800 | `text_chunker.dart:5` |
| Embedding 批大小 | 16 | `rag_service.dart:38` |
| 检索 topK / 阈值 | 4 / 0.2 | `rag_service.dart:39-40` |
| SSE 空闲超时 | 60s | `llm_client.dart:88` |
| 记忆存储上限 | 200 条 | `memory_service.dart:13` |
| 记忆注入上限 | 60 条 × 200 字 | `memory_service.dart:15-16` |
| 终端命令超时 | 120s | `terminal_service.dart:369` |
| TTS 文本截断 | 400 字 | `voice_service.dart:493` |
| 工具输出截断 | 4000 字 | `tools.dart:288/383/466` |
| 通知摘要截断 | 120 字 | `notification_service.dart:202` |
| 温度范围 | 0–1.5，默认 0.7 | `settings_screen.dart:388/335` |
| schemaVersion | 7 | `database.dart:156` |

## 附录 B：文档维护约定

- 改动代码后**必须**同步更新本文档对应小节
- 修复缺陷请在 §11 追加一行（含根因与修复位置）
- 新增功能请在 §13 移除对应条目并补进 §5 或 §7
- 行号会随编辑漂移，**以文件为准**；发现行号失效请顺手修正
- `README.md` 面向使用者（快速上手），本文档面向维护者（实现细节）
