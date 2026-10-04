#!/usr/bin/env node
// 发版脚本: 下载 CI Artifacts APK → 创建 GitHub Release(附更新说明) → 上传 APK
// 用法: node make_release.mjs <run_id> <version>   例如: node make_release.mjs 37212665709 0.2.0
// 更新说明取 RELEASE_NOTES.md 顶部第一个版本段落。
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, createReadStream } from "node:fs";
import { execSync } from "node:child_process";

const [runId, version] = process.argv.slice(2);
if (!runId || !version) {
  console.error("用法: node make_release.mjs <run_id> <version>");
  process.exit(1);
}
const REPO = "suanx/orion_agent";
const API = "https://api.github.com";
const UPLOAD = "https://uploads.github.com";

const cred = execFileSync("git", ["credential", "fill"], {
  input: "protocol=https\nhost=github.com\n",
  encoding: "utf8",
});
const token = /^password=(.*)$/m.exec(cred)?.[1];
if (!token) { console.error("无凭据"); process.exit(1); }
const headers = {
  Authorization: `Bearer ${token}`,
  Accept: "application/vnd.github+json",
  "User-Agent": "orion-release",
};

async function gh(method, path, body, extraHeaders = {}) {
  const resp = await fetch(`${API}${path}`, {
    method,
    headers: { ...headers, ...extraHeaders },
    body: body ? (typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body)) : undefined,
  });
  if (!resp.ok) throw new Error(`${method} ${path} -> ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  return resp;
}

// 1. 从 RELEASE_NOTES.md 提取本版说明(第一个 "# Orion Agent vX.Y.Z" 到下一个 "# Orion Agent" 或 EOF)
const notesAll = readFileSync("RELEASE_NOTES.md", "utf8");
const sections = notesAll.split(/^# /m).filter((s) => s.startsWith(`Orion Agent v${version}`));
if (sections.length === 0) throw new Error(`RELEASE_NOTES.md 中没有 v${version} 段落`);
const body = "# " + sections[0].trim();

// 2. 下载 Artifacts
console.log("查询 artifacts ...");
const arts = await (await gh("GET", `/repos/${REPO}/actions/runs/${runId}/artifacts`)).json();
const apkArt = (arts.artifacts ?? []).find((a) => a.name === "orion-agent-apk");
if (!apkArt) throw new Error("找不到 orion-agent-apk artifact");
console.log(`下载 ${apkArt.name} (${(apkArt.size_in_bytes / 1e6).toFixed(1)} MB) ...`);
const zipResp = await fetch(`${API}/repos/${REPO}/actions/artifacts/${apkArt.id}/zip`, {
  headers: { Authorization: `Bearer ${token}`, "User-Agent": "orion-release" },
});
if (!zipResp.ok) throw new Error(`artifact 下载失败: ${zipResp.status}`);
writeFileSync("artifact.zip", Buffer.from(await zipResp.arrayBuffer()));

// 3. 解压取 app-release.apk
execSync("rm -rf artifact_out && mkdir artifact_out && cd artifact_out && unzip -o ../artifact.zip", { stdio: "inherit" });
const apkName = `orion-agent-v${version}.apk`;
execSync(`cp artifact_out/app-release.apk ${apkName}`);
console.log(`APK 就绪: ${apkName}`);

// 4. 创建 Release (tag 在 main 最新提交上)
console.log("创建 Release ...");
const relResp = await gh("POST", `/repos/${REPO}/releases`, {
  tag_name: `v${version}`,
  name: `Orion Agent v${version}`,
  body,
  target_commitish: "main",
});
const rel = await relResp.json();
console.log(`Release 已创建: ${rel.html_url}`);

// 5. 上传 APK
console.log("上传 APK ...");
const upResp = await fetch(
  `${UPLOAD}/repos/${REPO}/releases/${rel.id}/assets?name=${apkName}`,
  {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/vnd.android.package-archive",
      "User-Agent": "orion-release",
    },
    body: createReadStream(apkName),
    // Node fetch 需要 duplex 选项才能流式 body
    duplex: "half",
  }
);
if (!upResp.ok) throw new Error(`APK 上传失败: ${upResp.status}: ${(await upResp.text()).slice(0, 300)}`);
const asset = await upResp.json();
console.log(`\n完成: ${rel.html_url}\nAPK: ${asset.browser_download_url}`);
