// Dart 语法结构检查器 —— 在没有 Dart SDK 的环境里做最低限度的静态把关。
//
// 定位：不是完整的 Dart parser，只针对「上一轮 CI 真实踩过的坑」做检查：
//   ① 块头与首个成员被合到同一行（class Foo {  const Foo(); ）
//   ② 声明行以 { 结尾但下一行又紧跟另一个声明（漏分号/漏换行）
//   ③ 花括号在同一行内开又闭的空函数体（写残了）
//   ④ 单引号总数为奇数（未闭合字符串）
//   ⑤ 三元/字符串插值里混入未转义的单引号
//
// 用法：node scripts/dart-syntax-check.mjs <file...>

import fs from "node:fs";

/** 去掉注释与字符串字面量，避免它们里的括号/引号干扰统计。 */
function strip(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    // 注释
    if (c === "/" && d === "/") {
      while (i < n && src[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    // 三引号字符串
    if (c === "'" && d === "'" && src[i + 2] === "'") {
      i += 3;
      while (i < n && !(src[i] === "'" && src[i + 1] === "'" && src[i + 2] === "'")) i++;
      i += 3;
      out += '""';
      continue;
    }
    // 普通字符串（含 r 前缀与插值）
    if (c === "'" || c === '"' || c === "$") {
      const raw = c === "$";
      const q = raw ? src[i + 1] : c;
      if (raw && q !== "'" && q !== '"') {
        out += c;
        i++;
        continue;
      }
      i++;
      while (i < n && src[i] !== q) {
        if (src[i] === "\\") i += 2;
        else i++;
      }
      i++; // 跳过闭引号
      out += '""';
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** 检查单个文件，返回问题列表。 */
function checkFile(file) {
  const raw = fs.readFileSync(file, "utf8");
  const issues = [];

  // ① 引号配平
  //    必须基于「剔除注释后」的内容：注释里写 "保存失败" 这类中文引号很常见，
  //    直接统计全文会得到奇数而误报（v0.2.40 首次跑就误报了 3 个文件）。
  const noComment = strip(raw);
  const sq = (noComment.match(/'/g) || []).length;
  const dq = (noComment.match(/"/g) || []).length;
  if (sq % 2 !== 0) {
    issues.push({ line: 0, kind: "单引号未闭合", detail: `代码中单引号 ${sq} 个（奇数）` });
  }
  if (dq % 2 !== 0) {
    issues.push({ line: 0, kind: "双引号未闭合", detail: `代码中双引号 ${dq} 个（奇数）` });
  }

  const code = strip(raw);
  const lines = code.split("\n");
  const rawLines = raw.split("\n");

  // ② 括号配平
  let curly = 0, paren = 0, brack = 0;
  for (let i = 0; i < code.length; i++) {
    const ch = code[i];
    if (ch === "{") curly++;
    else if (ch === "}") curly--;
    else if (ch === "(") paren++;
    else if (ch === ")") paren--;
    else if (ch === "[") brack++;
    else if (ch === "]") brack--;
  }
  if (curly !== 0) issues.push({ line: 0, kind: "花括号不配平", detail: `净 ${curly}` });
  if (paren !== 0) issues.push({ line: 0, kind: "圆括号不配平", detail: `净 ${paren}` });
  if (brack !== 0) issues.push({ line: 0, kind: "方括号不配平", detail: `净 ${brack}` });

  // ③ 块头与首个成员同行（本轮真实踩过的坑）
  //    形如：class Foo extends Bar {  const Foo();
  const declRe =
    /\b(class|abstract class|enum|mixin|extension)\s+\w+[^{;]*\{\s+(const|final|static|void|Widget|String|int|bool|double|var)\b/;
  for (let i = 0; i < lines.length; i++) {
    if (declRe.test(lines[i])) {
      issues.push({
        line: i + 1,
        kind: "声明与首个成员同行",
        detail: rawLines[i].trim().slice(0, 100),
      });
    }
  }

  // ④ 可疑的「空实现残缺」：行内出现 {...} 但内容只有空白
  //    合法例外：=> {} / {}) {} 这类单表达式空 body
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i];
    if (/\{[^{}]*\}\s*$/.test(t) && !/=>\s*\{\s*\}|catch[^{]*\{\s*\}/.test(t)) {
      // 形如 "foo() { }" 或 "Foo() {}" 出现在语句中间（不是顶层 class 体结束）
      if (/[;}]\s*\w+\s*\([^)]*\)\s*\{[^{}]*\}\s*$/.test(t)) {
        issues.push({ line: i + 1, kind: "疑似残缺空实现", detail: rawLines[i].trim().slice(0, 100) });
      }
    }
  }

  // ⑤ 上一行以 { 结尾、下一行又紧跟声明 —— 说明可能漏了换行
  for (let i = 1; i < lines.length; i++) {
    const prev = lines[i - 1].trimEnd();
    const cur = lines[i].trim();
    if (/[^{]\$\{$/.test(prev) && /^(const|final|static|void)\b/.test(cur)) {
      // class 体首行通常是空行或注释；若紧跟声明且同行出现过 { 后有内容，需人工确认
      const prevRaw = rawLines[i - 1];
      if (/\{[^{}]+\S/.test(prevRaw) && /^\s*$/.test(cur) === false) {
        issues.push({
          line: i,
          kind: "块头后紧跟声明（需人工确认）",
          detail: `${prevRaw.trim().slice(0, 70)} ←→ ${cur.slice(0, 60)}`,
        });
      }
    }
  }

  return issues;
}

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("用法: node dart-syntax-check.mjs <file...>");
  process.exit(2);
}

let total = 0;
for (const f of files) {
  if (!fs.existsSync(f)) {
    console.log(`❌ ${f}  (文件不存在)`);
    total++;
    continue;
  }
  const issues = checkFile(f);
  if (issues.length === 0) {
    console.log(`✅ ${f}`);
  } else {
    console.log(`❌ ${f}`);
    for (const it of issues) {
      console.log(`   [${it.kind}] 行 ${it.line || "?"}: ${it.detail}`);
      total++;
    }
  }
}
process.exit(total === 0 ? 0 : 1);
