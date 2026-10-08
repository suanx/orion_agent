<!-- 由 CI 自动生成：Analyze 失败时的完整报错 -->

更新时间：2026-10-08T18:20:35Z　commit：135891f

### flutter analyze 失败（退出码 1）
```
  error • The expression doesn't evaluate to a function, so it can't be invoked • lib/services/announcement_service.dart:102:7 • invocation_of_non_function_expression
```

<details><summary>analyze 原始输出（前 120 行）</summary>

```
Analyzing orion_agent...                                        

  error • The expression doesn't evaluate to a function, so it can't be invoked • lib/services/announcement_service.dart:102:7 • invocation_of_non_function_expression
   info • Don't use 'BuildContext's across async gaps, guarded by an unrelated 'mounted' check. Guard a 'State.context' use with a 'mounted' check on the State, and other BuildContext use with a 'mounted' check on the BuildContext • lib/ui/backup_screen.dart:459:50 • use_build_context_synchronously
   info • Don't use 'BuildContext's across async gaps, guarded by an unrelated 'mounted' check. Guard a 'State.context' use with a 'mounted' check on the State, and other BuildContext use with a 'mounted' check on the BuildContext • lib/ui/chat_screen.dart:315:15 • use_build_context_synchronously
   info • Don't use 'BuildContext's across async gaps. Try rewriting the code to not use the 'BuildContext', or guard the use with a 'mounted' check • lib/ui/chat_screen.dart:468:46 • use_build_context_synchronously
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:39:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:74:7 • prefer_const_declarations
   info • Use 'const' for final variables initialized to a constant value. Try replacing 'final' with 'const' • test/doc_extract_test.dart:76:7 • prefer_const_declarations

7 issues found. (ran in 7.2s)
```
</details>
