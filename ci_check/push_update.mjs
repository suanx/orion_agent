#!/usr/bin/env node
// 推送脚本: 把本地指定文件以一次 commit 推到 GitHub main（Git Data API）。
// 本机 git 直连 github.com 不通，凭据走 credential manager（永不回显）。
//
// 用法:
//   node push_update.mjs                 # 按 push_files.txt 清单推送
//   node push_update.mjs f1 f2 ...       # 命令行指定文件（仓库相对路径）
//
// push_files.txt 每行一个仓库相对路径，# 开头为注释。
import { execFileSync, execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const REPO = "suanx/orion_agent";
const API = "https://api.github.com";
const BRANCH = "main";

// 凭据: 优先环境变量 GITHUB_TOKEN（git credential fill 在部分 Windows
// 沙箱下 spawnSync 会报 EBUSY），否则走 credential manager（永不回显）。
let token = process.env.GITHUB_TOKEN;
if (!token) {
  const cred = execFileSync("git", ["credential", "fill"], {
    input: "protocol=https\nhost=github.com\n",
    encoding: "utf8",
  });
  token = /^password=(.*)$/m.exec(cred)?.[1];
}
if (!token) { console.error("无凭据"); process.exit(1); }
const headers = {
  Authorization: `Bearer ${token}`,
  Accept: "application/vnd.github+json",
  "User-Agent": "orion-agent-push",
};

async function gh(method, path, body) {
  const resp = await fetch(`${API}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!resp.ok) throw new Error(`${method} ${path} -> ${resp.status}: ${(await resp.text()).slice(0, 500)}`);
  return resp.json();
}

// 文件清单
let files = process.argv.slice(2);
if (files.length === 0) {
  files = readFileSync("push_files.txt", "utf8")
    .split(/\r?\n/).map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"));
}
if (files.length === 0) { console.error("没有要推送的文件"); process.exit(1); }

// 1. 基准: 远端 main 当前 commit
const ref = await gh("GET", `/repos/${REPO}/git/ref/heads/${BRANCH}`);
const baseCommit = await gh("GET", `/repos/${REPO}/git/commits/${ref.object.sha}`);
console.log(`base: ${baseCommit.sha.slice(0, 10)} ${baseCommit.message.split("\n")[0]}`);

// 2. 为每个文件建 blob（内容 = 本地工作区当前内容）
const treeItems = [];
for (const f of files) {
  const content = readFileSync(f); // Buffer，二进制安全
  const blob = await gh("POST", `/repos/${REPO}/git/blobs`, {
    content: content.toString("base64"),
    encoding: "base64",
  });
  treeItems.push({ path: f, mode: "100644", type: "blob", sha: blob.sha });
  console.log(`blob: ${f}`);
}

// 3. 新 tree（基于基准 tree，替换指定路径）
const tree = await gh("POST", `/repos/${REPO}/git/trees`, {
  base_tree: baseCommit.tree.sha,
  tree: treeItems,
});

// 4. 新 commit
const message = process.env.PUSH_MSG || "update";
const commit = await gh("POST", `/repos/${REPO}/git/commits`, {
  message,
  tree: tree.sha,
  parents: [baseCommit.sha],
});

// 5. 快进 main
await gh("PATCH", `/repos/${REPO}/git/refs/heads/${BRANCH}`, {
  sha: commit.sha,
  force: false, // 非强制，远端若前移会失败保护
});
console.log(`\n推送完成: ${commit.sha.slice(0, 10)} (${files.length} 个文件)`);
