import ApplicationServices
import AppKit
import Foundation

/// 辅助功能权限管理。CGEventTap 必须有该权限才能监听全局键盘事件。
enum PermissionManager {

    /// 检查并（按需）弹出系统授权窗。
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 直接打开"系统设置 - 隐私与安全 - 辅助功能"。
    static func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
