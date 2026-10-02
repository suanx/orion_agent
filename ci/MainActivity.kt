package com.example.pocket_agent

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * flutter create 生成的默认 MainActivity 之上，增加一个系统信息 MethodChannel，
 * 供 Dart 侧获取 nativeLibraryDir（proot 所在目录）等。
 *
 * 注意：这里必须用 KDoc。Kotlin 没有 Rust/Swift 风格的斜杠斜杠斜杠文档注释，
 * 那会被解析成连续的除号运算符从而编译失败。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocket_agent/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }
}
