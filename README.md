# Pocket Agent

Flutter 手机端 AI Agent 应用（规划中的 M0 + M1 阶段）。

## 功能

- **多模型流式对话**：任意 OpenAI 兼容接口（OpenAI / GLM / DeepSeek / Ollama 等），SSE 流式输出，Markdown 渲染
- **Agent 工具循环**：ReAct 循环（推理 → 调用工具 → 观察结果 → 继续推理），最多 8 轮
- **内置工具**：联网搜索（DuckDuckGo，无需 Key）、网页抓取、精确计算器、日期时间、长期记忆保存
- **多会话管理**：本地持久化、历史会话切换与删除
- **长期记忆**：Agent 可通过 `save_memory` 工具记住用户偏好，也可手动维护，自动注入 system prompt
- **隐私**：所有会话与记忆仅存本机；API Key 存于 SharedPreferences（MVP，后续迁移 secure storage）

## 构建

本地无需安装 Flutter 环境，推送后由 GitHub Actions 自动构建：

- 工作流：`.github/workflows/build.yml`
- 产物：Actions 页面 → 最新 run → Artifacts → `pocket-agent-apk`

平台脚手架（`android/`）在 CI 中由 `flutter create` 按当前 stable 版本生成，保证平台配置与 Flutter 版本一致。

## 使用

1. 安装 APK 后进入「设置」→「添加模型服务」
2. 填入 Base URL（如 `https://open.bigmodel.cn/api/paas/v4`）、API Key、模型名
3. 返回聊天即可开始对话；首个对话前需选择一个已启用的服务
