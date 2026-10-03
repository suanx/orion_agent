package com.example.orion_agent

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * flutter create 生成的默认 MainActivity 之上，增加一个系统信息 MethodChannel：
 *  - nativeLibDir：proot 五件套所在目录（终端环境）
 *  - filesDir：应用数据目录
 *  - permissionStatus：应用授权页需要的全部权限状态（一次性返回）
 *  - openPermission：跳转对应的系统授权页
 *
 * 注意：这里必须用 KDoc。Kotlin 没有 Rust/Swift 风格的斜杠斜杠斜杠文档注释，
 * 那会被解析成连续的除号运算符从而编译失败。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "orion_agent/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "permissionStatus" -> result.success(permissionStatus())
                    "canInstallPackages" -> result.success(
                        try {
                            // 「安装未知应用」授权（API 26+；更早版本无此限制，
                            // 视为已授权）
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                        } catch (_: Exception) { false }
                    )
                    "openPermission" -> {
                        openPermission(call.argument<String>("kind") ?: "")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------- 应用授权页：权限状态 ----------------

    /**
     * 全部权限状态一次返回，键与 Dart 侧 PermissionService 约定一致。
     * 任何一项检查失败都返回 false 而不是抛异常——授权页要能打开，
     * 状态宁缺勿炸。
     */
    private fun permissionStatus(): Map<String, Boolean> {
        val out = HashMap<String, Boolean>()
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val a11y = getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager

        out["notification"] = nm?.areNotificationsEnabled() ?: false
        out["overlay"] = try {
            Settings.canDrawOverlays(this)
        } catch (_: Exception) { false }
        out["battery"] = try {
            pm?.isIgnoringBatteryOptimizations(packageName) ?: false
        } catch (_: Exception) { false }
        out["allFiles"] = try {
            // API 30 引入 MANAGE_EXTERNAL_STORAGE；低版本走旧的 READ/WRITE 外存
            // 权限（安装即授予），一律视为已授权。
            Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
        } catch (_: Exception) { false }
        out["accessibility"] = try {
            val enabled = Settings.Secure.getString(
                contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: ""
            // 按包名匹配：我们的服务是 com.example.orion_agent.AgentAccessibilityService
            enabled.split(':').any { it.contains(packageName) }
        } catch (_: Exception) { false }
        out["appsList"] = try {
            // QUERY_ALL_PACKAGES 已在 Manifest 声明时安装即授予，这里用
            // 「能看到的 installedPackages 数量」验证它真的生效：
            // 未授权时 API 30+ 只能看到极少数包（自己 + 交互过的系统组件）。
            packageManager.getInstalledPackages(0).size > 50
        } catch (_: Exception) { false }
        // a11yServiceEnabled 保留：区分「系统里有无此服务」与「服务已开启」
        out["a11yServiceDeclared"] = a11y != null
        return out
    }

    // ---------------- 应用授权页：跳转系统设置 ----------------

    private fun openPermission(kind: String) {
        try {
            when (kind) {
                "notification" -> {
                    // API 26+ 有应用级通知设置页；再低无运行时通知开关，
                    // 落到应用详情页。
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        startActivity(i)
                    } else {
                        openAppDetails()
                    }
                }
                "accessibility" ->
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                "battery" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        // 直接弹系统确认对话框（需要 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                        // 权限，Manifest 已声明），比跳设置列表体验好。
                        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:$packageName"))
                        startActivity(i)
                    }
                }
                "overlay" ->
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                    )
                "appsList" -> openAppDetails()
                "allFiles" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            // 优先直达本应用的「所有文件访问」开关页
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        } catch (_: Exception) {
                            // 部分 ROM 不支持直达，退到列表页让用户自己找
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    }
                }
                "install" -> {
                    // 应用内更新的前置授权：「安装未知应用」开关页。
                    // 直达本应用；旧版本落到应用详情页。
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")
                                )
                            )
                        } catch (_: Exception) {
                            openAppDetails()
                        }
                    } else {
                        openAppDetails()
                    }
                }
            }
        } catch (_: Exception) {
            // 目标设置页在某些 ROM 上可能被裁剪，静默失败即可
        }
    }

    private fun openAppDetails() {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
        )
    }
}
