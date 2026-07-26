import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 设置界面的状态桥接层。
///
/// 真值仍然在既有服务里（`GeneralSettings`、`InputSourceActivationNudgeSettings`、
/// `LoginItemManager`、`PermissionManager`）：这里只把它们读成 SwiftUI 能观察的形式，
/// 写入一律原样转交回去，`DoubaoVoiceController` 那条通知订阅链路不受影响。
///
/// 只在主线程使用：实例由设置窗口创建，三个变更源的回调都会弹回主队列。
final class SettingsStore: ObservableObject {

    /// 输入源下拉框里的一项。`isEnabledInSystem == false` 表示这是为了保住用户
    /// 已有配置补出来的占位项——系统里当前没启用它。
    struct InputSourceChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let isEnabledInSystem: Bool

        var title: String { isEnabledInSystem ? name : "\(name)（未启用）" }
    }

    struct CompatibilityApp: Identifiable, Hashable {
        /// bundle ID，同时作为列表的稳定身份。
        let id: String
        let displayName: String
    }

    struct AlertContent: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - 派生状态
    //
    // 枚举输入源要走 Carbon、读自启动状态要摸磁盘，都不适合每次 body 求值时重算，
    // 统一缓存在这里，由 refresh() 刷新。

    @Published private(set) var chineseChoices: [InputSourceChoice] = []
    @Published private(set) var englishChoices: [InputSourceChoice] = []
    @Published private(set) var inputSourceWarnings: [String] = []
    @Published private(set) var compatibilityApps: [CompatibilityApp] = []
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var accessibilityTrusted = false

    @Published var compatibilitySelection: Set<String> = []
    @Published var alert: AlertContent?

    /// 「重新连接键盘监听」的实现在 AppDelegate，设置窗口只借用，不自己持有 event tap。
    private let restartEventTap: () -> Void

    /// NSOpenPanel 需要一个宿主窗口才能以 sheet 形式弹出。
    weak var hostWindow: NSWindow?

    private var observers: [NSObjectProtocol] = []
    private var enabledSourcesObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var refreshScheduled = false

    init(restartEventTap: @escaping () -> Void) {
        self.restartEventTap = restartEventTap

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: GeneralSettings.changedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            },
            center.addObserver(
                forName: InputSourceActivationNudgeSettings.changedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            },
        ]
        enabledSourcesObserver = InputSourceManager.observeEnabledInputSourcesChanged { [weak self] in
            self?.scheduleRefresh()
        }

        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let enabledSourcesObserver = enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(enabledSourcesObserver)
        }
        permissionTimer?.invalidate()
    }

    // MARK: - 刷新

    /// 重新从各服务读一遍状态。窗口每次显示、以及任一变更源触发时调用。
    func refresh() {
        refreshScheduled = false

        chineseChoices = choices(
            from: InputSourceManager.enabledSelectableMethods()
                .filter { !($0.sourceID ?? "").hasPrefix(DoubaoVoiceHUDDetector.imeBundleID) },
            configuredID: GeneralSettings.normalChineseInputSourceID,
            configuredName: GeneralSettings.normalChineseInputMethodName
        )
        englishChoices = choices(
            from: InputSourceManager.enabledSelectableLayouts(),
            configuredID: GeneralSettings.normalEnglishKeyboardLayoutID,
            configuredName: GeneralSettings.normalEnglishKeyboardLayoutName
        )
        inputSourceWarnings = computeInputSourceWarnings()

        compatibilityApps = InputSourceActivationNudgeSettings.bundleIDs.sorted().map {
            CompatibilityApp(
                id: $0,
                displayName: InputSourceActivationNudgeSettings.applicationName(for: $0)
            )
        }
        compatibilitySelection.formIntersection(compatibilityApps.map(\.id))

        launchAtLoginEnabled = LoginItemManager.isEnabled
        accessibilityTrusted = PermissionManager.ensureAccessibility(prompt: false)
    }

    /// 变更通知可能在写入的同一次调用栈里同步发出，弹回下一轮 runloop 再刷新，
    /// 避免在 SwiftUI 更新过程中发布新状态。
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// 列出系统里已启用的输入源；配置项当前未启用时在末尾补一个占位项——
    /// Picker 找不到选中值会自己跳到第一项，等于静默改掉用户的配置。
    private func choices(
        from sources: [InputSource],
        configuredID: String,
        configuredName: String
    ) -> [InputSourceChoice] {
        var result = sources.compactMap { source -> InputSourceChoice? in
            guard let id = source.sourceID else { return nil }
            return InputSourceChoice(id: id, name: source.value, isEnabledInSystem: true)
        }
        if !result.contains(where: { $0.id == configuredID }) {
            result.append(
                InputSourceChoice(id: configuredID, name: configuredName, isEnabledInSystem: false)
            )
        }
        return result
    }

    private func computeInputSourceWarnings() -> [String] {
        var lines: [String] = []

        if !InputSourceManager.isSourceEnabled(id: GeneralSettings.normalChineseInputSourceID) {
            if let fallback = DoubaoVoiceController.resolvedNormalChineseInputSource() {
                lines.append("配置的中文输入法未启用，暂时改用「\(fallback.value)」。")
            } else {
                lines.append("系统里没有已启用的中文输入法，Ctrl+Space 轮换已自动暂停（按键交回系统）。")
            }
        }
        if !InputSourceManager.isSourceEnabled(id: GeneralSettings.normalEnglishKeyboardLayoutID) {
            if let fallback = DoubaoVoiceController.resolvedNormalEnglishLayout() {
                lines.append("配置的英文键盘未启用，暂时改用「\(fallback.value)」。")
            } else {
                lines.append("系统里没有已启用的键盘布局，Ctrl+Space 轮换已自动暂停（按键交回系统）。")
            }
        }

        return lines
    }

    // MARK: - 绑定
    //
    // 开关和下拉框直接读写服务层，不在本地留副本：写入后服务发通知回来，
    // 读到的还是同一个值，不会来回抖。同值写入一律短路，避免多发一轮通知。

    var pauseMediaDuringVoice: Binding<Bool> {
        Binding(
            get: { GeneralSettings.pauseMediaDuringVoice },
            set: { newValue in
                guard newValue != GeneralSettings.pauseMediaDuringVoice else { return }
                GeneralSettings.pauseMediaDuringVoice = newValue
            }
        )
    }

    var ctrlSpaceSwitchEnabled: Binding<Bool> {
        Binding(
            get: { GeneralSettings.ctrlSpaceSwitchEnabled },
            set: { newValue in
                guard newValue != GeneralSettings.ctrlSpaceSwitchEnabled else { return }
                GeneralSettings.ctrlSpaceSwitchEnabled = newValue
            }
        )
    }

    var chineseSourceID: Binding<String> {
        Binding(
            get: { GeneralSettings.normalChineseInputSourceID },
            set: { [weak self] id in
                guard id != GeneralSettings.normalChineseInputSourceID,
                      let name = self?.chineseChoices.first(where: { $0.id == id })?.name
                else { return }
                GeneralSettings.setNormalChineseInputSource(id: id, name: name)
            }
        )
    }

    var englishSourceID: Binding<String> {
        Binding(
            get: { GeneralSettings.normalEnglishKeyboardLayoutID },
            set: { [weak self] id in
                guard id != GeneralSettings.normalEnglishKeyboardLayoutID,
                      let name = self?.englishChoices.first(where: { $0.id == id })?.name
                else { return }
                GeneralSettings.setNormalEnglishKeyboardLayout(id: id, name: name)
            }
        )
    }

    var launchAtLogin: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.launchAtLoginEnabled ?? false },
            set: { [weak self] in self?.setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLoginEnabled else { return }
        do {
            try LoginItemManager.setEnabled(enabled)
        } catch {
            Logger.shared.error("切换自启动失败: \(error.localizedDescription)")
            alert = AlertContent(title: "自启动设置失败", message: error.localizedDescription)
        }
        // 写失败时开关要弹回真实状态，所以统一以磁盘上的结果为准。
        launchAtLoginEnabled = LoginItemManager.isEnabled
    }

    // MARK: - 权限

    /// 辅助功能授权没有系统通知，窗口在屏期间轮询兜底。
    func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = PermissionManager.ensureAccessibility(prompt: false)
            if trusted != self.accessibilityTrusted {
                self.accessibilityTrusted = trusted
            }
        }
    }

    func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    func restartKeyboardMonitoring() {
        restartEventTap()
        refresh()
    }

    // MARK: - 应用兼容性列表

    func presentApplicationPicker() {
        let panel = NSOpenPanel()
        panel.title = "选择需要修复的应用"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.addApplications(at: panel.urls)
        }

        if let hostWindow = hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func addApplications(at urls: [URL]) {
        guard !urls.isEmpty else { return }

        var added = 0
        var unreadable: String?
        for url in urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                unreadable = url.lastPathComponent
                continue
            }
            if InputSourceActivationNudgeSettings.add(bundleID: bundleID) {
                added += 1
            }
        }
        refresh()

        if let unreadable = unreadable {
            alert = AlertContent(
                title: "读不到这个应用的 Bundle ID",
                message: "\(unreadable) 看起来不是一个有效的 .app。"
            )
        } else if added == 0 {
            alert = AlertContent(title: "已经添加过了", message: "选中的应用早已在列表里。")
        }
    }

    func addCompatibilityApp(bundleID: String) {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            alert = AlertContent(title: "请先填写一个 Bundle ID", message: "格式类似 com.example.app。")
            return
        }

        InputSourceActivationNudgeSettings.add(bundleID: normalized)
        refresh()
    }

    func removeSelectedCompatibilityApps() {
        guard !compatibilitySelection.isEmpty else { return }
        for bundleID in compatibilitySelection {
            InputSourceActivationNudgeSettings.remove(bundleID: bundleID)
        }
        compatibilitySelection.removeAll()
        refresh()
    }
}

extension View {
    /// 各分栏共用的出错提示。设置项即时生效，只有真的失败才需要打断用户。
    func settingsAlert(_ store: SettingsStore) -> some View {
        alert(
            store.alert?.title ?? "",
            isPresented: Binding(
                get: { store.alert != nil },
                set: { if !$0 { store.alert = nil } }
            ),
            presenting: store.alert
        ) { _ in
            Button("好") { store.alert = nil }
        } message: { content in
            Text(content.message)
        }
    }
}
