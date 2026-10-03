package com.example.orion_agent

import android.accessibilityservice.AccessibilityService
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * 无障碍服务：让「应用授权」页能真实授予无障碍权限，
 * 并为后续「AI 操作手机」类能力（读屏、点击、输入）预留统一入口。
 *
 * ⚠️ 当前是【最小实现】：只接收事件并打日志，不执行任何自动化动作。
 * 具体的读屏 / 手势注入逻辑属于独立子系统（对标 aicode 的自动化模块），
 * 未实现前不得在此做任何用户不可见的操作。
 */
class AgentAccessibilityService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 暂不消费事件。开启调试时可查看事件流：
        // Log.d(TAG, "event=${event?.eventType} pkg=${event?.packageName}")
    }

    override fun onInterrupt() {
        Log.d(TAG, "interrupted")
    }

    companion object {
        private const val TAG = "AgentA11y"
    }
}
