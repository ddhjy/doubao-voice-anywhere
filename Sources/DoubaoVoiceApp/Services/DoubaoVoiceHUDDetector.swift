import AppKit
import CoreGraphics
import Foundation

/// 探测豆包语音 HUD（屏幕下方的录音胶囊）是否可见，作为「豆包是否正在录音」的真值源。
///
/// 背景：本 App 与豆包之间只有「模拟左 Option 单击」这一条单向通道，同一个单击既是开始
/// 也是结束。只要有一次单击没送达（Electron 应用的文本输入上下文滞后于 TIS 切换），或者
/// 豆包自己结束了录音（静音自动退出、Esc 取消），内部状态就会与豆包真实状态反转：
/// 想开变成关、想关变成开，表现为「按了 Fn 不触发」或「刚拉起的录音立刻又消失」。
///
/// 豆包输入法进程在录音时会把语音胶囊窗口 order 到屏幕上，空闲时 order out
/// （onscreen=false）。用 CGWindowList 查询它有没有「足够大的在屏浮层窗口」
/// 即可判断录音状态。只读取 bounds/pid/alpha/layer 这类元数据，不需要屏幕录制权限。
///
/// 胶囊在「录音 → 优化识别中」的整个工作周期内都在屏，形态会变：
/// 旧版是 ~494x64pt 的大胶囊；2026-07 实测新版录音波形条缩小为 124x32pt@layer3，
/// 结束录音后的「优化识别中」条更宽一些，识别结果上屏后才 order out。
enum DoubaoVoiceHUDDetector {

    static let imeBundleID = "com.bytedance.inputmethod.doubaoime"

    /// 语音胶囊的尺寸门槛。豆包另有一个跟随插入点的「⌥」角标小窗（宽 ~90pt），
    /// 用宽度门槛把它和其它辅助小窗排除掉，避免把「输入法已挂上」误判成「正在录音」。
    /// 上限取角标（~90）与新版波形条（~124）之间：再收窄就会把录音中误判成空闲，
    /// 引发「停止时反向拉起新录音」「未上屏内容被提前丢弃」等状态反转问题。
    private static let minWindowWidth: Double = 110
    private static let minWindowHeight: Double = 25

    private static var cachedIMEPid: pid_t?

    /// 豆包语音胶囊当前是否在屏。找不到豆包输入法进程时返回 false。
    /// 必须在主线程调用（内部使用 NSWorkspace / CGWindowList）。
    static func isHUDVisible() -> Bool {
        guard let pid = imePid() else { return false }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return false }

        return infos.contains { isVoiceHUDWindow($0, pid: pid) }
    }

    /// 调试用：描述豆包进程当前所有在屏窗口，方便在日志里核对胶囊窗口的真实尺寸。
    static func describeOnscreenWindows() -> String {
        guard let pid = imePid() else { return "豆包输入法进程不在运行" }
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return "CGWindowList 查询失败" }

        let descriptions = infos.compactMap { info -> String? in
            guard windowOwnerPid(info) == pid else { return nil }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = doubleValue(bounds?["Width"]) ?? 0
            let height = doubleValue(bounds?["Height"]) ?? 0
            let layer = doubleValue(info[kCGWindowLayer as String]) ?? 0
            return "\(Int(width))x\(Int(height))@layer\(Int(layer))"
        }
        return descriptions.isEmpty ? "无在屏窗口" : descriptions.joined(separator: ", ")
    }

    // MARK: - 内部

    private static func isVoiceHUDWindow(_ info: [String: Any], pid: pid_t) -> Bool {
        guard windowOwnerPid(info) == pid else { return false }

        let alpha = doubleValue(info[kCGWindowAlpha as String]) ?? 1.0
        guard alpha > 0.1 else { return false }

        // 胶囊是高层级浮层；普通窗口 layer 为 0。
        let layer = doubleValue(info[kCGWindowLayer as String]) ?? 0
        guard layer > 0 else { return false }

        let bounds = info[kCGWindowBounds as String] as? [String: Any]
        let width = doubleValue(bounds?["Width"]) ?? 0
        let height = doubleValue(bounds?["Height"]) ?? 0
        return width >= minWindowWidth && height >= minWindowHeight
    }

    private static func imePid() -> pid_t? {
        if let pid = cachedIMEPid,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           app.bundleIdentifier == imeBundleID
        {
            return pid
        }

        cachedIMEPid = NSRunningApplication
            .runningApplications(withBundleIdentifier: imeBundleID)
            .first?
            .processIdentifier
        return cachedIMEPid
    }

    private static func windowOwnerPid(_ info: [String: Any]) -> pid_t? {
        guard let value = doubleValue(info[kCGWindowOwnerPID as String]) else { return nil }
        return pid_t(value)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return value as? Double
    }
}
