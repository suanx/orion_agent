<!-- 由 CI 自动生成：Analyze 失败时的完整报错 -->

更新时间：2026-10-09T22:05:58Z　commit：30e6d74

### flutter analyze 失败（退出码 1）
```
  error • The named parameter 'child' is required, but there's no corresponding argument. Try adding the required argument • lib/ui/privacy_screen.dart:19:19 • missing_required_argument
  error • 2 positional arguments expected by 'onSurface', but 1 found. Try adding the missing arguments • lib/ui/privacy_screen.dart:99:39 • not_enough_positional_arguments
```

<details><summary>analyze 原始输出（前 120 行）</summary>

```
Analyzing orion_agent...                                        

   info • Unused import: 'glass.dart'. Try removing the import directive • lib/ui/agent_artifact_screen.dart:9:8 • unused_import
   info • Don't use 'BuildContext's across async gaps, guarded by an unrelated 'mounted' check. Guard a 'State.context' use with a 'mounted' check on the State, and other BuildContext use with a 'mounted' check on the BuildContext • lib/ui/backup_screen.dart:462:50 • use_build_context_synchronously
   info • Use a function declaration rather than a variable assignment to bind a function to a name. Try rewriting the closure assignment as a function declaration • lib/ui/chat_screen.dart:202:13 • prefer_function_declarations_over_variables
   info • Don't use 'BuildContext's across async gaps. Try rewriting the code to not use the 'BuildContext', or guard the use with a 'mounted' check • lib/ui/chat_screen.dart:554:46 • use_build_context_synchronously
  error • The named parameter 'child' is required, but there's no corresponding argument. Try adding the required argument • lib/ui/privacy_screen.dart:19:19 • missing_required_argument
  error • 2 positional arguments expected by 'onSurface', but 1 found. Try adding the missing arguments • lib/ui/privacy_screen.dart:99:39 • not_enough_positional_arguments
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:39:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:74:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:76:7 • prefer_const_declarations

9 issues found. (ran in 8.6s)
```
</details>
