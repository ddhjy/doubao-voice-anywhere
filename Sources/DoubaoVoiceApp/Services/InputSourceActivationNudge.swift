import AppKit
import ApplicationServices
import Foundation

/// 通过让一个「不激活本 App」的小面板短暂成为 key window，强制前台 App 刷新当前输入源。
///
/// 背景：对 CJKV 输入法，单纯调用 `TISSelectInputSource` 有时只会更新菜单栏，
/// 不会让 Electron 等 App 的文本输入上下文立刻生效，需要一次焦点变化来刷新（参考 macism）。
/// 但 macism 式的「激活自己再切回去」会让前台 App 短暂失活，Electron 应用（如 Mira）
/// 会因此丢掉输入框焦点，用户得重新点回输入框。
/// 这里改用 `.nonactivatingPanel`：前台 App 全程保持 active，只有 key window 短暂换手到面板；
/// 面板关闭后系统把 key window 还给前台 App，文本输入上下文重新激活时即拿到新输入源，
/// 输入框焦点不丢。
final class InputSourceActivationNudge {

    /// 能成为 key window 但绝不激活本 App 的面板。
    private final class KeyableNudgePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    static let shared = InputSourceActivationNudge()

    private let windowSize = CGSize(width: 3, height: 3)
    private let windowMargin: CGFloat = 8
    /// 面板持有 key window 的时长：太短的话 key 焦点换手会被窗口服务器合并掉，
    /// 前台 App 收不到 resign/become key，输入上下文就不会刷新。
    private let keyWindowHoldDuration: TimeInterval = 0.05
    private let keyWindowReturnDelay: TimeInterval = 0.05

    private var panel: NSPanel?
    private var completions: [() -> Void] = []
    private var isRunning = false

    private init() {}

    func performIfNeeded(
        description: String,
        completion: (() -> Void)? = nil
    ) {
        let previousApp = currentInteractionApplication()
        guard isAllowedApp(previousApp) else {
            logSkippedApp(previousApp, description: description)
            completion?()
            return
        }

        guard InputSourceManager.currentSourceNeedsActivationNudge() else {
            completion?()
            return
        }
        perform(description: description, previousApp: previousApp, completion: completion)
    }

    private func perform(
        description: String,
        previousApp: NSRunningApplication?,
        completion: (() -> Void)?
    ) {
        if let completion = completion {
            completions.append(completion)
        }

        guard !isRunning else { return }
        isRunning = true

        let previousAppName = previousApp?.localizedName ?? "未知应用"
        Logger.shared.debug("输入源激活补丁开始: \(description), 前台应用: \(previousAppName)")

        guard let screen = NSScreen.main else {
            finish(previousApp: previousApp, description: description)
            return
        }

        let screenRect = screen.visibleFrame
        let x = screenRect.maxX - windowSize.width - windowMargin
        let y = screenRect.minY + windowMargin

        let panel = KeyableNudgePanel(
            contentRect: NSRect(origin: CGPoint(x: x, y: y), size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .purple
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        self.panel = panel
        // 只接管 key window，不调用 NSApp.activate：前台 App 保持 active，输入框焦点不受影响。
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + keyWindowHoldDuration) { [weak self] in
            self?.finish(previousApp: previousApp, description: description)
        }
    }

    private func finish(previousApp: NSRunningApplication?, description: String) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil

        // 正常情况下前台 App 从未失活，面板关掉后系统会自动把 key window 还给它；
        // 仅在它意外失活时才显式拉回，避免多余的激活动作再去碰它的焦点。
        let currentBundleID = Bundle.main.bundleIdentifier
        if let previousApp = previousApp,
           previousApp.bundleIdentifier != currentBundleID,
           !previousApp.isTerminated,
           !previousApp.isActive {
            Logger.shared.debug("输入源激活补丁: 前台应用意外失活，重新激活 \(previousApp.localizedName ?? "未知应用")")
            previousApp.activate(options: [.activateIgnoringOtherApps])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + keyWindowReturnDelay) { [weak self] in
            guard let self = self else { return }
            let callbacks = self.completions
            self.completions.removeAll()
            self.isRunning = false
            Logger.shared.debug("输入源激活补丁完成: \(description)")
            callbacks.forEach { $0() }
        }
    }

    private func isAllowedApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        guard let bundleID = app.bundleIdentifier else { return false }
        return InputSourceActivationNudgeSettings.bundleIDs.contains(bundleID)
    }

    private func currentInteractionApplication() -> NSRunningApplication? {
        if let focusedApp = accessibilityFocusedApplication(), !isCurrentApp(focusedApp) {
            return focusedApp
        }

        if let topmostApp = topmostVisibleWindowApplication(), !isCurrentApp(topmostApp) {
            return topmostApp
        }

        return NSWorkspace.shared.frontmostApplication
    }

    private func accessibilityFocusedApplication() -> NSRunningApplication? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard result == .success, let focusedAppValue = focusedAppValue else { return nil }

        let focusedAppElement = focusedAppValue as! AXUIElement
        var pid = pid_t()
        guard AXUIElementGetPid(focusedAppElement, &pid) == .success else { return nil }

        return NSRunningApplication(processIdentifier: pid)
    }

    private func topmostVisibleWindowApplication() -> NSRunningApplication? {
        guard let windowInfos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in windowInfos {
            guard isVisibleInteractionWindow(info),
                  let pid = pid(from: info[kCGWindowOwnerPID as String]),
                  let app = NSRunningApplication(processIdentifier: pid),
                  !isCurrentApp(app)
            else { continue }

            return app
        }

        return nil
    }

    private func isVisibleInteractionWindow(_ info: [String: Any]) -> Bool {
        let alpha = double(from: info[kCGWindowAlpha as String]) ?? 1.0
        guard alpha > 0 else { return false }

        let boundsDict = info[kCGWindowBounds as String] as? [String: Any]
        let width = double(from: boundsDict?["Width"]) ?? 0
        let height = double(from: boundsDict?["Height"]) ?? 0
        guard width >= 40, height >= 40 else { return false }

        guard let layer = int(from: info[kCGWindowLayer as String]) else { return false }
        return layer >= 0
    }

    private func pid(from value: Any?) -> pid_t? {
        if let pid = value as? pid_t {
            return pid
        }
        if let intValue = value as? Int {
            return pid_t(intValue)
        }
        if let number = value as? NSNumber {
            return pid_t(number.intValue)
        }
        return nil
    }

    private func int(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func double(from value: Any?) -> Double? {
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let cgFloatValue = value as? CGFloat {
            return Double(cgFloatValue)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }

    private func isCurrentApp(_ app: NSRunningApplication) -> Bool {
        guard let currentBundleID = Bundle.main.bundleIdentifier else { return false }
        return app.bundleIdentifier == currentBundleID
    }

    private func logSkippedApp(_ app: NSRunningApplication?, description: String) {
        let name = app?.localizedName ?? "未知应用"
        let bundleID = app?.bundleIdentifier ?? "nil"
        Logger.shared.debug("跳过输入源激活补丁: \(description), 当前交互应用未配置: \(name) (\(bundleID))")
    }
}
