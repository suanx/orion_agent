package com.example.orion_agent

import android.accessibilityservice.AccessibilityServiceInfo
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
                    // 运行时权限（相机/麦克风等）：直接弹系统授权对话框。
                    // 结果由系统回调 activity，Dart 侧在 resumed 时刷新状态。
                    "requestRuntimePermission" -> {
                        val kind = call.argument<String>("kind") ?: ""
                        val perms = when (kind) {
                            "camera" -> arrayOf(
                                android.Manifest.permission.CAMERA
                            )
                            "mic" -> arrayOf(
                                android.Manifest.permission.RECORD_AUDIO
                            )
                            else -> null
                        }
                        if (perms != null) {
                            androidx.core.app.ActivityCompat.requestPermissions(
                                this, perms, 7001
                            )
                            result.success(null)
                        } else {
                            // 未知 permission kind 不能静默 success（会让 Dart 侧
                            // 误以为已发起授权）：返回带错误信息的失败结果。
                            result.error(
                                "unknown_permission_kind",
                                "未知的权限类型：$kind（支持 camera / mic）",
                                null
                            )
                        }
                    }
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
        out["camera"] = try {
            androidx.core.content.ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.CAMERA
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) { false }
        out["mic"] = try {
            androidx.core.content.ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.RECORD_AUDIO
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) { false }
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
            // 组件在设置串里的标准格式是「包名/完整类名」，用完整服务类名
            // 精确匹配，避免子串匹配被同名前缀的其他包误判。
            val service = "$packageName/com.example.orion_agent.AgentAccessibilityService"
            enabled.split(':').any { it.equals(service, ignoreCase = true) }
        } catch (_: Exception) { false }
        out["appsList"] = try {
            // 用系统无障碍管理器判断本应用的无障碍服务是否启用，替代不可靠的
            // 「可见包数>50」启发式。getEnabledAccessibilityServiceList 与
            // FEEDBACK_ALL_MASK 均 API 14+ 可用，兼容 targetSdk 28，无额外依赖。
            val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            am?.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                ?.any { it.resolveInfo?.serviceInfo?.packageName == packageName } ?: false
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
