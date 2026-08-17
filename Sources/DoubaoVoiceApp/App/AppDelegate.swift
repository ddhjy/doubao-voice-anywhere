import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let voiceController = DoubaoVoiceController()
    private let eventTap = EventTapController()
    private let updateController = UpdateController()

    private var statusItem: NSStatusItem?
    private var permissionRetryTimer: Timer?
    private var keepAliveActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pendingIMEWarmup: DispatchWorkItem?
    private lazy var preferencesWindowController = PreferencesWindowController(
        restartEventTap: { [weak self] in self?.restartTap(nil) },
        setHotkeyCaptureActive: { [weak self] active in
            self?.voiceController.setHotkeyCaptureActive(active)
        },
        updateBridge: SettingsStore.UpdateBridge(
            isEnabled: updateController.isEnabled,
            automaticUpdatesEnabled: { [updateController] in
                updateController.automaticallyUpdates
            },
            setAutomaticUpdatesEnabled: { [updateController] enabled in
                updateController.automaticallyUpdates = enabled
            },
            checkNow: { [updateController] in updateController.checkForUpdates() }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateController.isAppBusy = { [weak self] in
            self?.voiceController.isBusyForAppUpdate ?? false
        }

        Logger.shared.info("DoubaoVoiceApp 启动 (PID \(ProcessInfo.processInfo.processIdentifier))")
        if let path = Logger.shared.logFilePath {
            Logger.shared.info("日志文件: \(path)")
        }

        // 后台菜单栏 App 闲置后会进入 App Nap，被降频/挂起的进程来不及响应
        // 事件回调，第一次按快捷键会因 tap 超时被系统放行（表现为"没反应"）。
        // 这里申请常驻活跃退出 App Nap；AllowingIdleSystemSleep 不阻止系统正常休眠。
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "保持全局键盘事件监听即时响应"
        )
        Logger.shared.info("已申请退出 App Nap，保证闲置后第一次按快捷键即时响应")

        installStatusItem()
        observeAlerts()
        refreshLoginItemIfNeeded()

        InputSourceActivationNudgeSettings.seedDefaultBundleIDsIfNeeded()

        eventTap.delegate = voiceController
        voiceController.setUp()

        // 第一次询问；如果用户尚未授予权限，CGEventTap 会创建失败，我们后续轮询。
        let trusted = PermissionManager.ensureAccessibility(prompt: true)
        Logger.shared.info("辅助功能权限: \(trusted ? "已授予" : "未授予")")

        if !startEventTapWithRetry() {
            scheduleEventTapRetry()
        }

        observeWakeForIMEWarmup()
        voiceController.startIMEKeepAlive()
        scheduleIMEWarmup(after: 2.0, reason: "启动")

        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingIMEWarmup?.cancel()
        pendingIMEWarmup = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        eventTap.stop()
        voiceController.tearDown()
        Logger.shared.info("DoubaoVoiceApp 退出")
    }

    // MARK: - 状态栏

    /// 取 bundle 显示名（正式版「豆包随时说」，开发版「豆包随时说 Dev」），
    /// 让菜单栏提示和「关于」弹窗能区分当前跑的是哪个版本。
    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "豆包随时说"
    }

    private static var defaultStatusItemToolTip: String {
        "\(appDisplayName) — 按 \(GeneralSettings.voiceHotkey.displayString) 开始 / 结束语音输入"
    }

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

        // 已授权时不占一行：权限状态在「设置…」的「通用」分栏里能看到。
        if !trusted {
            let permItem = NSMenuItem(
                title: "去开启辅助功能权限…",
                action: #selector(openAccessibility(_:)),
                keyEquivalent: ""
            )
            permItem.target = self
            menu.addItem(permItem)
        }

        let restartItem = NSMenuItem(title: "重新连接键盘监听", action: #selector(restartTap(_:)), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: "开始 / 结束豆包语音（等同于按 \(GeneralSettings.voiceHotkey.displayString)）",
            action: #selector(toggleVoice(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let switchItem = NSMenuItem(title: "切到豆包输入法", action: #selector(switchToDoubao(_:)), keyEquivalent: "")
        switchItem.target = self
        menu.addItem(switchItem)

        let restoreItem = NSMenuItem(title: "切回上一个输入法", action: #selector(restoreInput(_:)), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "设置…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "在 Finder 中显示日志", action: #selector(revealLog(_:)), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        // 开发版没有更新源，不显示这一项（见 UpdateController）。
        if updateController.isEnabled {
            let updateItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
            // 交给 Sparkle 自己管：它会按 canCheckForUpdates 处理灰显，
            // 更新进行中时这一项自动不可点，不用我们写 validateMenuItem。
            updateItem.target = updateController.menuItemTarget
            updateItem.action = updateController.menuItemAction
            menu.addItem(updateItem)
        }

        let aboutItem = NSMenuItem(title: "关于豆包随时说", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出豆包随时说", action: #selector(quit(_:)), keyEquivalent: "q")
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

    // MARK: - 豆包输入法预热

    private func observeWakeForIMEWarmup() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleIMEWarmup(after: 1.5, reason: "唤醒")
        }
    }

    private func scheduleIMEWarmup(after delay: TimeInterval, reason: String) {
        pendingIMEWarmup?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingIMEWarmup = nil
            self.voiceController.warmupDoubaoIME(reason: reason)
        }
        pendingIMEWarmup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

        let cycleHotkey = GeneralSettings.cycleInputSourceHotkey.displayString
        let cycleLine: String
        if GeneralSettings.ctrlSpaceSwitchEnabled,
           let chinese = DoubaoVoiceController.resolvedNormalChineseInputSource(),
           let english = DoubaoVoiceController.resolvedNormalEnglishLayout() {
            cycleLine = "按 \(cycleHotkey)：在「\(chinese.value)」和「\(english.value)」之间轮换，不会切到豆包。"
        } else {
            cycleLine = "输入源轮换当前未启用，可在「设置…」里开启。"
        }

        let pauseMediaLine = GeneralSettings.pauseMediaDuringVoice
            ? "说话时自动暂停正在播放的媒体，说完自动恢复。"
            : "语音时暂停媒体当前未启用，可在「设置…」里开启。"

        let alert = NSAlert()
        alert.messageText = "\(Self.appDisplayName)\(titleSuffix)"
        alert.informativeText = """
        按一下 \(GeneralSettings.voiceHotkey.displayString)：开始或结束豆包语音输入。
        \(pauseMediaLine)
        \(cycleLine)

        两个快捷键都能在「设置…」里改，纯原生 macOS App，不依赖 Hammerspoon 等任何脚本运行时。
        """
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
