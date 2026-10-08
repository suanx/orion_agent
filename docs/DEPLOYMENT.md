# 部署速查（三端）

> **完整版在 [orion_agent_cloud/docs/DEPLOYMENT.md](https://github.com/suanx/orion_agent_cloud/blob/main/docs/DEPLOYMENT.md)**，
> 本文只给自部署者需要的最小信息。

三端职责：**App**（本仓库，用户界面）→ **后端**（账号/配额/云备份/中继）→ **Agent 平台**（可选，云端 Coding Agent）。

---

## 你需要准备

| 服务 | 必需 | 用途 |
|---|---|---|
| GitHub | ✅ | 源码 + CI 构建 |
| 腾讯云 EdgeOne Pages | ✅ | 跑后端边缘函数 |
| Turso | ✅ | 托管数据库（18 张表） |
| Cloudflare R2 | ✅ | 存 APK + 更新清单 |
| Vercel | ❌ | 只有要用云端 Agent 才需要 |

---

## 三步走

### ① 先部署后端（必须先做）

App 编译时把后端地址写死在代码里，后端没上线就改地址等于指向空气。

```bash
git clone https://github.com/suanx/orion_agent_cloud.git
cd orion_agent_cloud
npm install
cp .env.example .env
```

编辑 `.env`，最少填这 5 项：

```dotenv
TURSO_DATABASE_URL=libsql://orion-xxx.turso.io
TURSO_AUTH_TOKEN=<token>
JWT_SECRET=<openssl rand -hex 32>
ADMIN_TOKEN=<自己定的管理台口令>
PUBLIC_BASE_URL=https://你的后端域名
```

**建表**（漏这步会出现「保存成功但列表不显示」）：

```bash
npm run db:migrate      # 应输出 18 张表
```

部署到 EdgeOne Pages（仓库自带 `edgeone.json`，配置会被自动识别）：

| 项 | 值 |
|---|---|
| Install Command | `npm install` |
| Build Command | `npm run typecheck` |
| Output Directory | `public` |
| Framework | `none` |

环境变量在 EdgeOne 控制台配（同 `.env` 内容）。

**验证**：

```bash
curl -i https://你的域名/api/health    # 返回 401 = 路由通、鉴权生效
```

浏览器打开 `https://你的域名/api/admin`，用 `ADMIN_TOKEN` 能登录 = 成功。

> ⚠️ 所有接口都带 `/api` 前缀，少了这个前缀全部 404。

### ② 改 App 里的后端地址

```dart
// lib/services/cloud_config.dart —— 全项目唯一改址入口
static const String baseUrl = 'https://你的后端域名';
```

配 GitHub Secrets（`Settings → Secrets and variables → Actions`）：

```
R2_ENDPOINT  R2_ACCESS_KEY_ID  R2_SECRET_ACCESS_KEY  R2_BUCKET  R2_PUBLIC_BASE
```

### ③ 升版本号并推送

```bash
# pubspec.yaml（唯一真相源）
version: 0.2.41+53

# lib/ui/about_screen.dart
const String kAppVersion = '0.2.41';
```

```bash
git push origin main    # CI 自动构建，33 步全绿后出 APK
```

> 🔴 **必须在已发布版本上 bump 版本号。** 忘了升 → 客户端与服务端版本号相等 →
> `isNewer` 返回 false → **CI 全绿、APK 已上传，但用户收不到更新提示**。
> `buildNumber` 不参与版本比较，改它没用。这个坑踩过两次。

---

## 后台配置（部署完必做）

打开 `https://你的域名/api/admin`。

### 必做 · 录入 AI 模型供应商

「AI 模型 → 供应商配置」→ 新建，填上游根地址、API Key、模型列表。

单个模型的最简填法：

```json
[{"name": "gpt-4o-mini"}]
```

完整填法：

```json
[{"name": "gpt-4o-mini", "label": "GPT-4o mini", "contextWindow": 128000}]
```

`name` 必须是上游文档里的**真实模型名**（后端原样转发给上游）。
`contextWindow` 只影响界面显示，不影响请求。

**不配这个，App 登录后额度卡片不显示、模型选择器里没有云端模型。**

### 可选 · 发公告

「账号授权 → 公告管理」→ 新建并启用。App 启动后 1.2 秒拉取并弹窗。

### 可选 · 授权用户使用云端 Agent

见完整文档的「第 4 步 · 部署 Agent 平台」。

---

## 验证清单

**后端**

- [ ] `/api/health` 返回 401（路由通）
- [ ] `/api/announcement` 返回 `{"announcement":null}`
- [ ] 管理台能用 `ADMIN_TOKEN` 登录

**App**

- [ ] 「关于」显示版本号正确
- [ ] 能注册并登录
- [ ] 登录后账号页显示套餐与周额度
- [ ] 模型选择器底部出现云端模型
- [ ] 选云端模型发消息能正常回复
- [ ] 收到后台公告弹窗

---

## 排障速查

| 现象 | 多半是 |
|---|---|
| 所有接口 404 | 少了 `/api` 前缀 |
| 保存成功但列表空 | 没跑 `npm run db:migrate` |
| 收不到更新提示 | 版本号没 bump（buildNumber 改了没用） |
| 云端模型不显示 | 没录供应商 / 没配 `PUBLIC_BASE_URL` / 没重新登录 |
| 公告不弹 | 没启用 / 版本范围不匹配 / 已标记已读 |
| CI 挂了看不到报错 | `git fetch && git show origin/main:docs/CI_ANALYZE_REPORT.md` |
| 额度显示 0 | 后端没配 `JWT_SECRET` |

更细的排查步骤见[完整部署文档](https://github.com/suanx/orion_agent_cloud/blob/main/docs/DEPLOYMENT.md)。

---

## 安全注意

- `JWT_SECRET` / `ADMIN_TOKEN` 用随机长串，不要用默认值
- R2 token 权限限定到单个 bucket，别用全局 API Token
- `DEBUG_ERRORS=false`（生产环境开会返回原始错误与堆栈）
- 换 `JWT_SECRET` 会导致已录入的上游 Key 无法解密，需重新录入

---

## 相关链接

- [完整三端部署文档](https://github.com/suanx/orion_agent_cloud/blob/main/docs/DEPLOYMENT.md)
- [后端仓库](https://github.com/suanx/orion_agent_cloud) · [Agent 平台仓库](https://github.com/suanx/orion-forge)
- [开发文档](docs/PROJECT.md)
