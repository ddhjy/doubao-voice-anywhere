import AppKit
import CoreGraphics
import Foundation

/// 主状态机：
/// - Fn 轻按：启动/停止豆包语音
/// - Fn + 其它键：不触发，仅记录
/// - Ctrl+Space：仅在日常中文输入法与日常英文键盘之间轮换
final class DoubaoVoiceController: EventTapDelegate {

    // MARK: - 配置
    //
    // 每个目标都同时记 sourceID：localized name 在不同进程 locale 下可能不一致
    // （比如 Squirrel 父 IM 的 name 在 zh-Hans 下是「鼠须管」，en 下是 "Squirrel"），
    // 优先用 sourceID 匹配可以避开这个坑。

    static let targetInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
    static let targetInputMethod = "豆包输入法"

    static let normalChineseInputMethod = "Squirrel - Simplified"
    static let normalChineseInputSourceID = "im.rime.inputmethod.Squirrel.Hans"
    static let normalEnglishKeyboardLayout = "U.S."
    static let normalEnglishKeyboardLayoutID = "com.apple.keylayout.US"

    // MARK: - 时间常量（单位：秒）

    private let actionAfterFnUpDelay: TimeInterval = 0.02
    private let voiceTriggerAfterSwitchDelay: TimeInterval = 0.08
    private let inputSourceSwitchTimeout: TimeInterval = 2.0
    private let inputSourcePollInterval: TimeInterval = 0.01
    private let inputMethodBridgeDelay: TimeInterval = 0.15
    private let restoreAfterVoiceStopDelay: TimeInterval = 1.0

    // MARK: - 键码常量

    private let keyCodeFn: Int64 = 63
    private let keyCodeSpace: Int64 = 49
    private let keyCodeReturn: Int64 = 36
    private let keyCodeKeypadEnter: Int64 = 76
    private let keyCodeEscape: Int64 = 53

    // MARK: - 状态

    private var previousInputSource: InputSource?
    private var sourceBeforeFnTap: InputSource?
    private var lastNonDoubaoInputSource: InputSource?
    private(set) var doubaoVoiceActive: Bool = false
    private var fnIsDown: Bool = false
    private var fnWasUsedWithOtherKey: Bool = false

    private var pendingActionTimer: DispatchWorkItem?
    private var restoreImeTimer: DispatchWorkItem?

    private var inputSourceObserver: NSObjectProtocol?

    // MARK: - 状态查询（暴露给 UI）

    /// 用户视角的当前状态。两行：第一行说当前输入法，第二行说豆包语音状态 + 下一步动作。
    /// - 没有输入源信息时，给一句简单的解释，不暴露内部数据格式。
    var statusDescription: String {
        let now = InputSourceManager.nowSource()
        guard let source = now else {
            return "暂时读不到当前输入源"
        }

        let label: String
        switch source.kind {
        case .method:
            label = "当前输入法：\(source.value)"
        case .layout:
            label = "当前键盘：\(source.value)"
        }

        let voiceLine = doubaoVoiceActive
            ? "豆包语音 录音中，按 Fn 结束"
            : "豆包语音 待机中，按 Fn 开始"
        return "\(label)\n\(voiceLine)"
    }

    // MARK: - 生命周期

    func setUp() {
        rememberLastNonDoubaoInputSource()
        inputSourceObserver = InputSourceManager.observeInputSourceChanged { [weak self] in
            self?.rememberLastNonDoubaoInputSource()
        }
        Logger.shared.info("目标输入法 source id: \(Self.targetInputSourceID)")
        Logger.shared.info("Fn 轻按：启动/停止豆包语音输入")
        Logger.shared.info("Ctrl+Space 仅在 \(Self.normalChineseInputMethod) / \(Self.normalEnglishKeyboardLayout) 之间切换")
        Logger.shared.info("输入源激活补丁 App 白名单: \(InputSourceActivationNudgeSettings.bundleIDs.sorted().joined(separator: ", "))")
    }

    func tearDown() {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceObserver = nil
        }
        cancelPendingActionTimer()
        cancelRestoreImeTimer()
    }

    // MARK: - EventTapDelegate

    func handleFlagsChanged(event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // 我们只关心 Fn 键（keycode 63）。其它修饰键透传，避免误吞。
        guard keycode == keyCodeFn else { return false }

        let flags = event.flags
        let fnPressed = flags.contains(.maskSecondaryFn)

        if fnPressed && !fnIsDown {
            fnIsDown = true
            fnWasUsedWithOtherKey = false
            sourceBeforeFnTap = InputSourceManager.nowSource()
            return true
        }

        if !fnPressed && fnIsDown {
            fnIsDown = false
            if !fnWasUsedWithOtherKey {
                scheduleDoubaoToggle()
            } else {
                sourceBeforeFnTap = nil
            }
            fnWasUsedWithOtherKey = false
            return true
        }

        return false
    }

    func handleKeyDown(event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1

        if fnIsDown && keycode != keyCodeFn {
            fnWasUsedWithOtherKey = true
        }

        if doubaoVoiceActive && isExternalDoubaoVoiceStopKey(keycode) {
            if !isRepeat {
                markDoubaoVoiceStoppedByExternalKey(keycode: keycode)
            }
            return false
        }

        guard keycode == keyCodeSpace else { return false }

        let flags = event.flags
        let onlyControl = flags.contains(.maskControl)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskSecondaryFn)

        guard onlyControl else { return false }

        if !isRepeat {
            toggleNormalInputSource()
        }
        return true
    }

    // MARK: - Fn 单按调度

    private func scheduleDoubaoToggle() {
        cancelPendingActionTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingActionTimer = nil
            self.toggleDoubaoVoice()
        }
        pendingActionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + actionAfterFnUpDelay, execute: work)
    }

    private func cancelPendingActionTimer() {
        pendingActionTimer?.cancel()
        pendingActionTimer = nil
    }

    private func cancelRestoreImeTimer() {
        restoreImeTimer?.cancel()
        restoreImeTimer = nil
    }

    // MARK: - 豆包语音切换

    /// 等价于按一次 Fn：启动 / 停止豆包语音，菜单栏可直接调用。
    func toggleDoubaoVoice() {
        if doubaoVoiceActive {
            stopDoubaoVoice()
        } else {
            startDoubaoVoice()
        }
    }

    /// 仅做输入源切换（不触发语音），用于"快速切到豆包"。
    func switchToDoubaoInputSource() {
        guard setDoubaoIME() else {
            showAlert("切不到豆包输入法，请确认已安装")
            return
        }
        waitForDoubaoIME {}
    }

    /// 立即恢复到上次记录的非豆包输入源。
    func restoreLastNonDoubaoInputSource() {
        if previousInputSource == nil {
            previousInputSource = lastNonDoubaoInputSource
        }
        restorePreviousIME()
    }

    private func startDoubaoVoice() {
        cancelRestoreImeTimer()
        previousInputSource = restoreTargetFrom(sourceBeforeFnTap ?? InputSourceManager.nowSource())
        sourceBeforeFnTap = nil

        let triggerVoice: () -> Void = {
            if !self.isDoubaoIMEActive() && !self.setDoubaoIME() {
                self.showAlert("切不到豆包输入法，请确认已安装")
                return
            }
            self.waitForDoubaoIME {
                KeyboardSimulator.doubleTapLeftOption {
                    self.doubaoVoiceActive = true
                    Logger.shared.debug("豆包语音输入已启动，等待再次按 Fn 停止")
                }
            }
        }

        if isDoubaoIMEActive() {
            triggerVoice()
            return
        }

        if let previous = previousInputSource, previous.kind == .layout {
            let ok = selectNormalChineseInputMethod()
            Logger.shared.debug("当前是键盘布局 \(previous.value)，先桥接到日常中文输入法 \(Self.normalChineseInputMethod)，结果: \(ok)")
            if ok {
                waitForNormalChineseInputMethod(then: triggerVoice)
                return
            }
        }

        triggerVoice()
    }

    private func stopDoubaoVoice() {
        KeyboardSimulator.doubleTapLeftOption {
            self.doubaoVoiceActive = false
            self.scheduleRestorePreviousIME(reason: "豆包语音输入已停止")
        }
    }

    private func isExternalDoubaoVoiceStopKey(_ keycode: Int64) -> Bool {
        keycode == keyCodeReturn
            || keycode == keyCodeKeypadEnter
            || keycode == keyCodeEscape
    }

    private func markDoubaoVoiceStoppedByExternalKey(keycode: Int64) {
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: "检测到按键 \(keycode) 结束豆包语音")
    }

    private func scheduleRestorePreviousIME(reason: String) {
        cancelRestoreImeTimer()
        let work = DispatchWorkItem { [weak self] in
            self?.restorePreviousIME()
        }
        restoreImeTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + restoreAfterVoiceStopDelay,
            execute: work
        )
        Logger.shared.debug("\(reason)，已安排恢复之前输入法")
    }

    // MARK: - 输入法切换的细节

    private func setDoubaoIME() -> Bool {
        let okByID = InputSourceManager.selectSource(byID: Self.targetInputSourceID)
        Logger.shared.debug("按 source id 切换到豆包输入法: \(Self.targetInputSourceID), 结果: \(okByID)")
        if okByID { return true }

        let okByName = InputSourceManager.selectMethod(byName: Self.targetInputMethod)
        Logger.shared.debug("按 method 名称切换到豆包输入法: \(Self.targetInputMethod), 结果: \(okByName)")
        return okByName
    }

    private func isDoubaoIMEActive() -> Bool {
        InputSourceManager.currentSourceID() == Self.targetInputSourceID
            || InputSourceManager.currentMethod() == Self.targetInputMethod
    }

    private func isNormalChineseInputMethodActive() -> Bool {
        InputSourceManager.currentSourceID() == Self.normalChineseInputSourceID
            || InputSourceManager.currentMethod() == Self.normalChineseInputMethod
    }

    private func selectNormalChineseInputMethod() -> Bool {
        if InputSourceManager.selectSource(byID: Self.normalChineseInputSourceID) { return true }
        return InputSourceManager.selectMethod(byName: Self.normalChineseInputMethod)
    }

    private func selectNormalEnglishKeyboardLayout() -> Bool {
        if InputSourceManager.selectSource(byID: Self.normalEnglishKeyboardLayoutID) { return true }
        return InputSourceManager.selectLayout(byName: Self.normalEnglishKeyboardLayout)
    }

    private func defaultNormalChineseInputSource() -> InputSource {
        InputSource(
            kind: .method,
            value: Self.normalChineseInputMethod,
            sourceID: Self.normalChineseInputSourceID
        )
    }

    private func isDoubaoInputSource(_ source: InputSource?) -> Bool {
        guard let source = source else { return false }
        return source.sourceID == Self.targetInputSourceID
            || (source.kind == .method && source.value == Self.targetInputMethod)
    }

    private func restoreTargetFrom(_ candidate: InputSource?) -> InputSource {
        if let candidate = candidate, !isDoubaoInputSource(candidate) {
            return candidate
        }
        return lastNonDoubaoInputSource ?? defaultNormalChineseInputSource()
    }

    private func rememberLastNonDoubaoInputSource() {
        guard let source = InputSourceManager.nowSource() else { return }
        if !isDoubaoInputSource(source) {
            lastNonDoubaoInputSource = source
            Logger.shared.debug("记录最近非豆包输入源 \(source.kind.rawValue): \(source.value) (\(source.sourceID ?? "nil"))")
        }
    }

    private func restorePreviousIME() {
        if previousInputSource == nil {
            Logger.shared.debug("没有记录到之前的输入来源，恢复到默认中文输入法")
        }
        let target = restoreTargetFrom(previousInputSource)
        let ok: Bool
        switch target.kind {
        case .method:
            ok = (target.sourceID.flatMap { InputSourceManager.selectSource(byID: $0) } ?? false)
                || InputSourceManager.selectMethod(byName: target.value)
            Logger.shared.debug("恢复之前输入法 method: \(target.value)(\(target.sourceID ?? "nil")), 结果: \(ok)")
        case .layout:
            ok = (target.sourceID.flatMap { InputSourceManager.selectSource(byID: $0) } ?? false)
                || InputSourceManager.selectLayout(byName: target.value)
            Logger.shared.debug("恢复之前键盘布局 layout: \(target.value)(\(target.sourceID ?? "nil")), 结果: \(ok)")
        }
        previousInputSource = nil
        if ok {
            waitForRestoredInputSource(target)
        }
        _ = ok
    }

    // MARK: - 等待输入源生效（带超时与轮询）

    private func waitForInputSource(
        description: String,
        timeoutMessage: String,
        isReady: @escaping () -> Bool,
        deadline: Date? = nil,
        onReady: @escaping () -> Void
    ) {
        if isReady() {
            onReady()
            return
        }
        let realDeadline = deadline ?? Date(timeIntervalSinceNow: inputSourceSwitchTimeout)
        if Date() >= realDeadline {
            Logger.shared.error("等待\(description)生效超时: currentSourceID=\(InputSourceManager.currentSourceID() ?? "nil"), currentMethod=\(InputSourceManager.currentMethod() ?? "nil"), currentLayout=\(InputSourceManager.currentLayout() ?? "nil")")
            showAlert(timeoutMessage)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) { [weak self] in
            self?.waitForInputSource(
                description: description,
                timeoutMessage: "\(description) 切换超时",
                isReady: isReady,
                deadline: realDeadline,
                onReady: onReady
            )
        }
    }

    private func waitForDoubaoIME(then onReady: @escaping () -> Void) {
        waitForInputSource(
            description: "豆包输入法",
            timeoutMessage: "豆包输入法没切过去，再按一次 Fn",
            isReady: { [weak self] in self?.isDoubaoIMEActive() ?? false }
        ) {
            self.nudgeForegroundAppIfNeeded(description: "豆包输入法") {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.voiceTriggerAfterSwitchDelay, execute: onReady)
            }
        }
    }

    private func waitForNormalChineseInputMethod(then onReady: @escaping () -> Void) {
        waitForInputSource(
            description: "日常中文输入法",
            timeoutMessage: "切回中文输入法超时了",
            isReady: { [weak self] in self?.isNormalChineseInputMethodActive() ?? false }
        ) {
            self.nudgeForegroundAppIfNeeded(description: "日常中文输入法") {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.inputMethodBridgeDelay, execute: onReady)
            }
        }
    }

    private func waitForRestoredInputSource(_ target: InputSource) {
        waitForInputSource(
            description: "恢复输入源 \(target.value)",
            timeoutMessage: "切回 \(target.value) 超时了",
            isReady: { [weak self] in self?.isInputSourceActive(target) ?? false }
        ) {
            self.nudgeForegroundAppIfNeeded(description: "恢复输入源 \(target.value)")
        }
    }

    private func isInputSourceActive(_ target: InputSource) -> Bool {
        if let sourceID = target.sourceID, InputSourceManager.currentSourceID() == sourceID {
            return true
        }

        switch target.kind {
        case .method:
            return InputSourceManager.currentMethod() == target.value
        case .layout:
            return InputSourceManager.currentLayout() == target.value
        }
    }

    private func nudgeForegroundAppIfNeeded(description: String, completion: (() -> Void)? = nil) {
        InputSourceActivationNudge.shared.performIfNeeded(
            description: description,
            completion: completion
        )
    }

    // MARK: - Ctrl+Space 轮换

    private func toggleNormalInputSource() {
        let currentSourceID = InputSourceManager.currentSourceID()
        let currentMethod = InputSourceManager.currentMethod()
        let currentLayout = InputSourceManager.currentLayout()
        Logger.shared.debug("Ctrl+Space: currentSourceID=\(currentSourceID ?? "nil"), currentMethod=\(currentMethod ?? "nil"), currentLayout=\(currentLayout ?? "nil")")

        let isDoubao = currentSourceID == Self.targetInputSourceID
        let isNormalChinese = currentSourceID == Self.normalChineseInputSourceID
            || currentMethod == Self.normalChineseInputMethod

        if isDoubao || isNormalChinese {
            let ok = selectNormalEnglishKeyboardLayout()
            Logger.shared.debug("Ctrl+Space: 切换到英文键盘布局 \(Self.normalEnglishKeyboardLayout), 结果: \(ok)")
            return
        }

        let ok = selectNormalChineseInputMethod()
        Logger.shared.debug("Ctrl+Space: 切换到中文输入法 \(Self.normalChineseInputMethod), 结果: \(ok)")
        if ok {
            waitForNormalChineseInputMethod {}
        }
    }

    // MARK: - 提示

    private func showAlert(_ message: String) {
        Logger.shared.warn(message)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: DoubaoVoiceController.alertNotification,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }

    static let alertNotification = Notification.Name("DoubaoVoiceController.alert")
}
