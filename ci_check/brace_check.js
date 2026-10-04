// Dart 大括号配平粗检（本地无 Flutter SDK 时的兜底校验，来自 PROJECT.md §11.8 方法论）
const fs = require('fs');
const files = [
  'lib/services/cloud_service.dart',
  'lib/services/tools.dart',
  'lib/services/update_service.dart',
  'lib/providers/providers.dart',
  'lib/ui/cloud_account_screen.dart',
  'lib/ui/chat_screen.dart',
  'lib/ui/about_screen.dart',
  'lib/ui/profile_screen.dart',
  'lib/main.dart',
];
let fail = 0;
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  // 先按「感知转义」的规则剥字符串（"\\." 能吃掉 \" 与 \\，
  // 否则正则/高亮代码里的转义引号会把字符串截断、括号计数误报），
  // 再清剩余转义与注释。
  const s = src
    .replace(/'(?:\\.|[^'\\\n])*'/g, "''")
    .replace(/"(?:\\.|[^"\\\n])*"/g, '""')
    .replace(/\\./g, '')
    .replace(/\/\/[^\n]*/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '');
  const count = (ch) => s.split(ch).length - 1;
  const pairs = [
    ['{', '}'],
    ['(', ')'],
    ['[', ']'],
  ];
  const bad = pairs.filter(([a, b]) => count(a) !== count(b));
  if (bad.length) {
    fail++;
    console.log('MISMATCH', f, bad.map(([a, b]) => `${a}=${count(a)} ${b}=${count(b)}`).join(', '));
  } else {
    console.log('OK      ', f);
  }
}
process.exit(fail ? 1 : 0);
