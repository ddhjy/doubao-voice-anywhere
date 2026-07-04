import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let voiceController = DoubaoVoiceController()
    private let eventTap = EventTapController()

    private var statusItem: NSStatusItem?
    private var permissionRetryTimer: Timer?
    private var keepAliveActivity: NSObjectProtocol?
    private lazy var preferencesWindowController = PreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("DoubaoVoiceApp 启动 (PID \(ProcessInfo.processInfo.processIdentifier))")
        if let path = Logger.shared.logFilePath {
            Logger.shared.info("日志文件: \(path)")
        }

        // 后台菜单栏 App 闲置后会进入 App Nap，被降频/挂起的进程来不及响应
        // 事件回调，第一次按 Fn 会因 tap 超时被系统放行（表现为"没反应"）。
        // 这里申请常驻活跃退出 App Nap；AllowingIdleSystemSleep 不阻止系统正常休眠。
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "保持全局键盘事件监听即时响应"
        )
        Logger.shared.info("已申请退出 App Nap，保证闲置后第一次 Fn 即时响应")

        installStatusItem()
        observeAlerts()
        refreshLoginItemIfNeeded()

        eventTap.delegate = voiceController
        voiceController.setUp()

        // 第一次询问；如果用户尚未授予权限，CGEventTap 会创建失败，我们后续轮询。
        let trusted = PermissionManager.ensureAccessibility(prompt: true)
        Logger.shared.info("辅助功能权限: \(trusted ? "已授予" : "未授予")")

        if !startEventTapWithRetry() {
            scheduleEventTapRetry()
        }

        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTap.stop()
        voiceController.tearDown()
        Logger.shared.info("DoubaoVoiceApp 退出")
    }

    // MARK: - 状态栏

    private static let defaultStatusItemToolTip = "豆包语音输入助手 — 按 Fn 开始 / 结束语音输入"
    private static let statusItemLength: CGFloat = 24.5
    private static let statusIconPointSize: CGFloat = 15.5

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.statusItemLength)
        if let button = item.button {
            // 使用 SF Symbols；如缺失则回落为 emoji 文本。
            if let image = Self.makeStatusIcon() {
                button.image = image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
            } else {
                button.title = "🎤"
            }
            button.toolTip = Self.defaultStatusItemToolTip
        }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private static func makeStatusIcon() -> NSImage? {
        let symbolNames = ["microphone.badge.ellipsis", "mic.circle"]
        guard let symbol = symbolNames.lazy.compactMap({
            NSImage(systemSymbolName: $0, accessibilityDescription: "豆包语音")
        }).first else {
            return nil
        }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: statusIconPointSize,
            weight: NSFont.Weight.medium
        )
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        image.isTemplate = true
        image.size = NSSize(width: statusIconPointSize, height: statusIconPointSize)
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = buildMenu()
        fresh.delegate = self
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let trusted = PermissionManager.ensureAccessibility(prompt: false)

        let statusText = trusted
            ? voiceController.statusDescription
            : "还没准备好：缺少辅助功能权限\n开启后请点下面「重新连接键盘监听」"
        let statusTitle = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusTitle.isEnabled = false
        menu.addItem(statusTitle)

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(
            title: trusted ? "辅助功能权限 已开启" : "去开启辅助功能权限…",
            action: trusted ? nil : #selector(openAccessibility(_:)),
            keyEquivalent: ""
        )
        permItem.target = self
        menu.addItem(permItem)

        let restartItem = NSMenuItem(title: "重新连接键盘监听", action: #selector(restartTap(_:)), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "开始 / 结束豆包语音（等同于按 Fn）", action: #selector(toggleVoice(_:)), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let switchItem = NSMenuItem(title: "切到豆包输入法", action: #selector(switchToDoubao(_:)), keyEquivalent: "")
        switchItem.target = self
        menu.addItem(switchItem)

        let restoreItem = NSMenuItem(title: "切回上一个输入法", action: #selector(restoreInput(_:)), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "应用兼容性设置…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let launchAtLoginItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "在 Finder 中显示日志", action: #selector(revealLog(_:)), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于豆包语音输入助手", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出豆包语音输入助手", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func refreshMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func refreshLoginItemIfNeeded() {
        do {
            try LoginItemManager.refreshIfEnabled()
        } catch {
            Logger.shared.warn("刷新自启动配置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 监听重试

    private func startEventTapWithRetry() -> Bool {
        if eventTap.start() {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            return true
        }
        return false
    }

    private func scheduleEventTapRetry() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.startEventTapWithRetry() {
                Logger.shared.info("辅助功能权限已就绪，事件监听已启动")
                self.refreshMenu()
            }
        }
    }

    // MARK: - 菜单动作

    @objc private func openAccessibility(_ sender: Any?) {
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func toggleVoice(_ sender: Any?) {
        voiceController.toggleDoubaoVoice()
    }

    @objc private func switchToDoubao(_ sender: Any?) {
        voiceController.switchToDoubaoInputSource()
    }

    @objc private func restoreInput(_ sender: Any?) {
        voiceController.restoreLastNonDoubaoInputSource()
    }

    @objc private func openPreferences(_ sender: Any?) {
        preferencesWindowController.showWindow(sender)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        let shouldEnable = !LoginItemManager.isEnabled
        do {
            try LoginItemManager.setEnabled(shouldEnable)
        } catch {
            Logger.shared.error("切换自启动失败: \(error.localizedDescription)")
            showMessage(
                "自启动设置失败",
                informativeText: error.localizedDescription
            )
        }
        refreshMenu()
    }

    @objc private func restartTap(_ sender: Any?) {
        eventTap.stop()
        if !startEventTapWithRetry() {
            Logger.shared.warn("重启事件监听失败，请检查辅助功能权限")
            scheduleEventTapRetry()
        }
        refreshMenu()
    }

    @objc private func revealLog(_ sender: Any?) {
        guard let path = Logger.shared.logFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let titleSuffix = version.map { " \($0)" } ?? ""

        let alert = NSAlert()
        alert.messageText = "豆包语音输入助手\(titleSuffix)"
        alert.informativeText = """
        按一下 Fn：开始或结束豆包语音输入。
        按 Ctrl + Space：在「\(DoubaoVoiceController.normalChineseInputMethod)」和「\(DoubaoVoiceController.normalEnglishKeyboardLayout)」之间轮换，不会切到豆包。

        纯原生 macOS App，不依赖 Hammerspoon 等任何脚本运行时。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showMessage(_ messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - 提示通知

    private func observeAlerts() {
        NotificationCenter.default.addObserver(
            forName: DoubaoVoiceController.alertNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.userInfo?["message"] as? String else { return }
            self?.flashStatusItem(with: message)
        }
    }

    /// 状态栏空间小，长文案会被裁断；这里在状态栏只显示一个固定的精简提示，
    /// 完整 message 同步写到 toolTip，让用户 hover 能看到。
    private func flashStatusItem(with message: String) {
        guard let button = statusItem?.button else { return }
        let originalImage = button.image
        let originalToolTip = button.toolTip
        button.image = nil
        button.title = "⚠️ 出了点问题（hover 查看）"
        button.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            button.title = ""
            button.image = originalImage
            button.toolTip = originalToolTip ?? Self.defaultStatusItemToolTip
        }
    }
}
