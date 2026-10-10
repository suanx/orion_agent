<!-- 由 CI 自动生成：Analyze 失败时的完整报错 -->

更新时间：2026-10-10T23:04:11Z　commit：54e4769

### flutter analyze 失败（退出码 1）
```
warning • The '!' will have no effect because the receiver can't be null. Try removing the '!' operator • lib/services/llm_client.dart:680:25 • unnecessary_non_null_assertion
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/chat_screen.dart:780:29 • undefined_named_parameter
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/skills_screen.dart:136:23 • undefined_named_parameter
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/tasks_screen.dart:222:13 • undefined_named_parameter
```

<details><summary>analyze 原始输出（前 120 行）</summary>

```
Analyzing orion_agent...                                        

warning • The '!' will have no effect because the receiver can't be null. Try removing the '!' operator • lib/services/llm_client.dart:680:25 • unnecessary_non_null_assertion
   info • Unused import: 'glass.dart'. Try removing the import directive • lib/ui/agent_artifact_screen.dart:9:8 • unused_import
   info • Don't use 'BuildContext's across async gaps, guarded by an unrelated 'mounted' check. Guard a 'State.context' use with a 'mounted' check on the State, and other BuildContext use with a 'mounted' check on the BuildContext • lib/ui/backup_screen.dart:462:50 • use_build_context_synchronously
   info • Use a function declaration rather than a variable assignment to bind a function to a name. Try rewriting the closure assignment as a function declaration • lib/ui/chat_screen.dart:202:13 • prefer_function_declarations_over_variables
   info • Don't use 'BuildContext's across async gaps. Try rewriting the code to not use the 'BuildContext', or guard the use with a 'mounted' check • lib/ui/chat_screen.dart:555:46 • use_build_context_synchronously
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/chat_screen.dart:780:29 • undefined_named_parameter
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/skills_screen.dart:136:23 • undefined_named_parameter
  error • The named parameter 'key' isn't defined. Try correcting the name to an existing named parameter's name, or defining a named parameter with the name 'key' • lib/ui/tasks_screen.dart:222:13 • undefined_named_parameter
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:39:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:74:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:76:7 • prefer_const_declarations

11 issues found. (ran in 9.3s)
```
</details>
