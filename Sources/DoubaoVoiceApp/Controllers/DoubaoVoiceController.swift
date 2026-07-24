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
    // 豆包输入法是本 App 的固定目标（产品身份），保持常量；
    // 「日常输入法」是用户偏好，可在菜单栏「设置…」里修改（见 GeneralSettings），
    // 这里全部走动态解析：配置的输入法未启用时自动降级或停用相关功能。
    //
    // 每个目标都同时记 sourceID：localized name 在不同进程 locale 下可能不一致
    // （比如 Squirrel 父 IM 的 name 在 zh-Hans 下是「鼠须管」，en 下是 "Squirrel"），
    // 优先用 sourceID 匹配可以避开这个坑。

    static let targetInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
    static let targetInputMethod = "豆包输入法"

    /// 解析后的「日常中文输入法」；配置无效时自动降级到系统里第一个中文输入法，可能为 nil。
    static func resolvedNormalChineseInputSource() -> InputSource? {
        GeneralSettings.resolvedNormalChineseInputSource(excludingSourceIDs: [targetInputSourceID])
    }

    /// 解析后的「日常英文键盘布局」；配置无效时自动降级到系统里第一个键盘布局，可能为 nil。
    static func resolvedNormalEnglishLayout() -> InputSource? {
        GeneralSettings.resolvedNormalEnglishKeyboardLayout()
    }

    // MARK: - 时间常量（单位：秒）

    private let actionAfterFnUpDelay: TimeInterval = 0.2
    private let voiceTriggerAfterSwitchDelay: TimeInterval = 0.08
    private let inputSourceSwitchTimeout: TimeInterval = 2.0
    private let inputSourcePollInterval: TimeInterval = 0.01
    private let inputMethodBridgeDelay: TimeInterval = 0.15
    /// 胶囊探测未生效时，停止后到恢复输入法的固定延迟（老行为，兜底用）。
    private let restoreAfterVoiceStopDelay: TimeInterval = 1.0

    /// 停止录音后豆包并不会立刻收尾：先进入「优化识别中」阶段（内容越长越久，
    /// 实测数秒），期间输入框里的文字还是未上屏的组合文本（marked text），
    /// 胶囊也仍在屏；识别结果替换上屏后胶囊才消失。此时才能安全切走输入法——
    /// 过早切走会让替换永远无法完成，下次输入会话重置时整段内容被系统丢弃。
    /// 因此恢复输入法前轮询等待胶囊消失，并要求连续静默若干周期
    /// （容忍「波形 → 优化识别中」形态切换时窗口短暂 order out 的空档）。
    private let imeFinalizePollInterval: TimeInterval = 0.2
    private let imeFinalizeQuietTicks = 5
    /// 等待豆包收尾的上限：识别优化一般 1-3s，网络差时更久；
    /// 超过上限就不再等（宁可冒丢字风险也不让输入法永远悬在豆包上）。
    private let imeFinalizeTimeout: TimeInterval = 10.0

    /// Option 单击发出后等待语音胶囊出现的时长（实测正常 0.2-0.6s 内出现）。
    private let hudAppearTimeout: TimeInterval = 1.2
    private let hudPollInterval: TimeInterval = 0.06
    /// 录音中巡检语音胶囊的周期；连续缺席两次（约 1s）才认定豆包已自行结束，
    /// 容忍胶囊在「准备录音 → 波形 → 识别中」形态切换时的短暂消失。
    private let hudWatchInterval: TimeInterval = 0.5
    private let hudWatchMissThreshold = 2

    // MARK: - 键码常量

    private let keyCodeFn: Int64 = 63
    // 新款键盘的 Fn/Globe 有时还会额外发一个 keyDown 179。
    private let keyCodeFnKeyDown: Int64 = 179
    private let keyCodeSpace: Int64 = 49

    // MARK: - 状态

    // 以下状态只在主线程访问。
    private var previousInputSource: InputSource?
    private var sourceBeforeFnTap: InputSource?
    private var lastNonDoubaoInputSource: InputSource?
    private var voiceTransitionInProgress: Bool = false

    // 以下状态只在事件监听线程访问（EventTapDelegate 回调都在该线程上）。
    private var fnIsDown: Bool = false
    private var fnWasUsedWithOtherKey: Bool = false

    // 主线程写、事件监听线程读，用锁保护。
    private let voiceActiveLock = NSLock()
    private var _doubaoVoiceActive = false
    private(set) var doubaoVoiceActive: Bool {
        get {
            voiceActiveLock.lock()
            defer { voiceActiveLock.unlock() }
            return _doubaoVoiceActive
        }
        set {
            voiceActiveLock.lock()
            _doubaoVoiceActive = newValue
            voiceActiveLock.unlock()
        }
    }

    // Ctrl+Space 拦截门：只有「开关开启 && 日常中文/英文输入源都可用」时才拦截，
    // 否则透传给系统，避免把用户的 Ctrl+Space 吞进一个注定失败的切换。
    // 解析涉及 TIS，不能在事件监听线程做，所以主线程预计算、事件线程只读缓存。
    private let ctrlSpaceGateLock = NSLock()
    private var _ctrlSpaceInterceptionActive = false
    private var ctrlSpaceInterceptionActive: Bool {
        get {
            ctrlSpaceGateLock.lock()
            defer { ctrlSpaceGateLock.unlock() }
            return _ctrlSpaceInterceptionActive
        }
        set {
            ctrlSpaceGateLock.lock()
            _ctrlSpaceInterceptionActive = newValue
            ctrlSpaceGateLock.unlock()
        }
    }

    private var pendingActionTimer: DispatchWorkItem?
    private var restoreImeTimer: DispatchWorkItem?

    // 语音胶囊探测（主线程访问）。
    // hudDetectionProven：本次进程运行期间是否成功观测到过胶囊。观测到过，
    // 才敢把「胶囊不在」当作「豆包没在录音」的依据；否则（豆包改版、进程没找到）
    // 一律退回旧的盲切换行为，探测失效时行为不会比从前更差。
    private var hudDetectionProven = false
    private var hudWatchTimer: DispatchSourceTimer?
    private var hudWatchMissCount = 0

    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

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
        enabledSourcesObserver = InputSourceManager.observeEnabledInputSourcesChanged { [weak self] in
            self?.refreshCtrlSpaceGate()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: GeneralSettings.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCtrlSpaceGate()
        }
        refreshCtrlSpaceGate()

        Logger.shared.info("目标输入法 source id: \(Self.targetInputSourceID)")
        Logger.shared.info("Fn 轻按：启动/停止豆包语音输入")
        Logger.shared.info("输入源激活补丁 App 白名单: \(InputSourceActivationNudgeSettings.bundleIDs.sorted().joined(separator: ", "))")
    }

    func tearDown() {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceObserver = nil
        }
        if let observer = enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            enabledSourcesObserver = nil
        }
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        cancelPendingActionTimer()
        cancelRestoreImeTimer()
        stopHudWatch()
        voiceTransitionInProgress = false
    }

    /// 重新计算 Ctrl+Space 是否应当拦截（主线程调用；配置或系统输入法列表变化时触发）。
    private func refreshCtrlSpaceGate() {
        let enabled = GeneralSettings.ctrlSpaceSwitchEnabled
        let chinese = Self.resolvedNormalChineseInputSource()
        let english = Self.resolvedNormalEnglishLayout()
        let active = enabled && chinese != nil && english != nil

        if active != ctrlSpaceInterceptionActive || !gateLoggedOnce {
            gateLoggedOnce = true
            if active {
                Logger.shared.info("Ctrl+Space 轮换已启用: \(chinese!.value) ↔ \(english!.value)")
            } else if !enabled {
                Logger.shared.info("Ctrl+Space 轮换已在设置中关闭，按键透传给系统")
            } else {
                Logger.shared.warn("Ctrl+Space 轮换已自动停用（日常输入法不可用：中文=\(chinese?.value ?? "无") 英文=\(english?.value ?? "无")），按键透传给系统")
            }
        }
        ctrlSpaceInterceptionActive = active
    }

    private var gateLoggedOnce = false

    // MARK: - EventTapDelegate
    //
    // 这些回调运行在事件监听线程上，必须立即返回：
    // 只做键码/flags 判断和轻量状态更新，任何可能阻塞的调用（TIS、日志外的 IO）
    // 都派发到主队列异步执行。回调里一旦卡超过约 1 秒，系统会禁用整个 tap，
    // 造成"按 Fn 没反应"。

    func handleFlagsChanged(event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // 我们只关心 Fn 键（keycode 63）。其它修饰键透传，避免误吞。
        guard keycode == keyCodeFn else { return false }

        let fnPressed = event.flags.contains(.maskSecondaryFn)

        if fnPressed && !fnIsDown {
            fnIsDown = true
            fnWasUsedWithOtherKey = false
            // TIS 读取可能阻塞（服务冷启动时长达秒级），不能放在回调里。
            DispatchQueue.main.async { [weak self] in
                self?.sourceBeforeFnTap = InputSourceManager.nowSource()
            }
            return true
        }

        if !fnPressed && fnIsDown {
            fnIsDown = false
            let usedWithOtherKey = fnWasUsedWithOtherKey
            fnWasUsedWithOtherKey = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if usedWithOtherKey {
                    self.sourceBeforeFnTap = nil
                } else {
                    self.scheduleDoubaoToggle()
                }
            }
            return true
        }

        return false
    }

    func handleKeyDown(event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1

        if fnIsDown && !isFnKeyDownEvent(keycode) {
            fnWasUsedWithOtherKey = true
        }

        if isFnKeyDownEvent(keycode) {
            return true
        }

        if doubaoVoiceActive {
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    self?.markDoubaoVoiceStoppedByExternalActivity("检测到键盘输入 \(keycode) 结束豆包语音")
                }
            }
            return false
        }

        guard keycode == keyCodeSpace else { return false }

        // 开关关闭或配置的日常输入源不可用时透传，让系统按默认行为处理 Ctrl+Space。
        guard ctrlSpaceInterceptionActive else { return false }

        let flags = event.flags
        let onlyControl = flags.contains(.maskControl)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskSecondaryFn)

        guard onlyControl else { return false }

        if !isRepeat {
            DispatchQueue.main.async { [weak self] in
                self?.toggleNormalInputSource()
            }
        }
        return true
    }

    func handleMouseDown(event: CGEvent, type: CGEventType) -> Bool {
        if doubaoVoiceActive {
            DispatchQueue.main.async { [weak self] in
                self?.markDoubaoVoiceStoppedByExternalActivity("检测到鼠标点击 \(type) 结束豆包语音")
            }
        }
        return false
    }

    /// tap 被系统禁用又恢复后调用（事件监听线程）。
    /// 禁用期间可能只收到了 Fn down 而丢了 Fn up，把按键跟踪状态清零，
    /// 避免 fnIsDown 卡死导致后续轻按被误判成"Fn+其它键"。
    func eventTapWasInterrupted() {
        fnIsDown = false
        fnWasUsedWithOtherKey = false
        DispatchQueue.main.async { [weak self] in
            self?.sourceBeforeFnTap = nil
        }
    }

    private func isFnKeyDownEvent(_ keycode: Int64) -> Bool {
        keycode == keyCodeFn || keycode == keyCodeFnKeyDown
    }

    // MARK: - Fn 单按调度

    private func scheduleDoubaoToggle() {
        Logger.shared.debug("检测到 Fn 轻按，\(actionAfterFnUpDelay)s 后切换豆包语音")
        cancelPendingActionTimer()
        // 立刻取消挂起的输入法恢复：否则「停止后 0.8-1.0s 内再按 Fn」时，
        // 恢复计时器会赶在本次切换前触发，把输入法闪切回去再切回豆包。
        cancelRestoreImeTimer()
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
        guard !voiceTransitionInProgress else {
            Logger.shared.warn("豆包语音启动/停止仍在处理中，忽略本次 Fn")
            return
        }

        voiceTransitionInProgress = true
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
        restorePreviousIME(force: true)
    }

    private func startDoubaoVoice() {
        cancelRestoreImeTimer()
        previousInputSource = restoreTargetFrom(sourceBeforeFnTap ?? InputSourceManager.nowSource())
        sourceBeforeFnTap = nil

        let triggerVoice: () -> Void = {
            if !self.isDoubaoIMEActive() && !self.setDoubaoIME() {
                self.showAlert("切不到豆包输入法，请确认已安装")
                self.finishVoiceTransition()
                return
            }
            self.waitForDoubaoIME(onTimeout: {
                self.finishVoiceTransition()
            }) {
                self.fireVoiceStartTap(allowRetry: true)
            }
        }

        if isDoubaoIMEActive() {
            triggerVoice()
            return
        }

        if let previous = previousInputSource, previous.kind == .layout,
           let chinese = Self.resolvedNormalChineseInputSource() {
            let ok = selectNormalChineseInputMethod()
            Logger.shared.debug("当前是键盘布局 \(previous.value)，先桥接到日常中文输入法 \(chinese.value)，结果: \(ok)")
            if ok {
                waitForNormalChineseInputMethod(onTimeout: { [weak self] in
                    self?.finishVoiceTransition()
                }, then: triggerVoice)
                return
            }
        }

        triggerVoice()
    }

    private func stopDoubaoVoice() {
        stopHudWatch()

        // 豆包早已不在录音（静音自动退出、上次启动其实没成功等）时，
        // 绝不能再发 Option 单击——那会反向拉起一段新录音，
        // 然后又被 1s 后的输入法恢复杀掉，表现成「触发了立刻又消失」。
        if hudDetectionProven && !hudVisibleNow() {
            Logger.shared.debug("语音胶囊已不在屏，跳过停止单击，直接恢复输入法")
            doubaoVoiceActive = false
            scheduleRestorePreviousIME(reason: "豆包语音已自行结束")
            finishVoiceTransition()
            return
        }

        KeyboardSimulator.tapLeftOption {
            self.doubaoVoiceActive = false
            self.scheduleRestorePreviousIME(reason: "豆包语音输入已停止")
            self.finishVoiceTransition()
        }
    }

    private func finishVoiceTransition() {
        voiceTransitionInProgress = false
    }

    private func markDoubaoVoiceStoppedByExternalActivity(_ reason: String) {
        stopHudWatch()
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: reason)
    }

    // MARK: - 启动确认与录音巡检（语音胶囊真值）

    /// 发送启动用的 Option 单击，并用语音胶囊确认豆包真的开始录音了。
    ///
    /// 单击可能落空：Electron 应用（Notion 等）的文本输入上下文经常滞后于
    /// TIS 切换，按键发出时上下文还挂在旧输入法上，豆包收不到。以前这里盲目
    /// 把状态置成「录音中」，一旦落空，后续每次 Fn 的语义都是反的。
    private func fireVoiceStartTap(allowRetry: Bool) {
        KeyboardSimulator.tapLeftOption {
            self.verifyVoiceStarted(
                deadline: Date(timeIntervalSinceNow: self.hudAppearTimeout),
                allowRetry: allowRetry
            )
        }
    }

    private func verifyVoiceStarted(deadline: Date, allowRetry: Bool) {
        if hudVisibleNow() {
            doubaoVoiceActive = true
            finishVoiceTransition()
            startHudWatch()
            Logger.shared.debug("豆包语音输入已启动（语音胶囊已确认出现），等待再次按 Fn 停止")
            return
        }

        if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + hudPollInterval) { [weak self] in
                self?.verifyVoiceStarted(deadline: deadline, allowRetry: allowRetry)
            }
            return
        }

        guard hudDetectionProven else {
            // 从未成功观测到过胶囊：探测可能不适配当前豆包版本，退回旧的盲切换行为。
            doubaoVoiceActive = true
            finishVoiceTransition()
            Logger.shared.warn("没探测到语音胶囊（本次运行从未观测到过，可能豆包界面有变化），按旧逻辑视为已启动。豆包在屏窗口: \(DoubaoVoiceHUDDetector.describeOnscreenWindows())")
            return
        }

        if allowRetry {
            Logger.shared.warn("Option 单击后语音胶囊没出现（前台应用输入上下文可能没跟上切换），强制焦点刷新后重发一次")
            InputSourceActivationNudge.shared.performForced(description: "豆包语音启动重试") { [weak self] in
                guard let self = self else { return }
                guard self.isDoubaoIMEActive() else {
                    Logger.shared.warn("重试时当前输入法已不是豆包，放弃本次启动")
                    self.doubaoVoiceActive = false
                    self.finishVoiceTransition()
                    return
                }
                self.fireVoiceStartTap(allowRetry: false)
            }
            return
        }

        // 重试也没拉起来：如实置为未启动，让下一次 Fn 走干净的启动流程，
        // 不留下「App 以为在录音、豆包其实没在录」的脏状态。
        doubaoVoiceActive = false
        finishVoiceTransition()
        showAlert("豆包语音没拉起来，请再按一次 Fn")
    }

    private func hudVisibleNow() -> Bool {
        let visible = DoubaoVoiceHUDDetector.isHUDVisible()
        if visible && !hudDetectionProven {
            hudDetectionProven = true
            Logger.shared.info("语音胶囊探测生效: \(DoubaoVoiceHUDDetector.describeOnscreenWindows())")
        }
        return visible
    }

    /// 录音期间周期巡检：豆包会因静音超时、Esc 等自行结束录音而不通知我们。
    /// 胶囊连续缺席两个周期就同步状态并恢复输入法，避免状态反转。
    private func startHudWatch() {
        stopHudWatch()
        guard hudDetectionProven else { return }

        hudWatchMissCount = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + hudWatchInterval,
            repeating: hudWatchInterval
        )
        timer.setEventHandler { [weak self] in
            self?.hudWatchTick()
        }
        timer.resume()
        hudWatchTimer = timer
    }

    private func stopHudWatch() {
        hudWatchTimer?.cancel()
        hudWatchTimer = nil
        hudWatchMissCount = 0
    }

    private func hudWatchTick() {
        guard doubaoVoiceActive else {
            stopHudWatch()
            return
        }
        if hudVisibleNow() {
            hudWatchMissCount = 0
            return
        }
        hudWatchMissCount += 1
        guard hudWatchMissCount >= hudWatchMissThreshold else { return }

        stopHudWatch()
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: "语音胶囊已消失（豆包自行结束了录音）")
    }

    private func scheduleRestorePreviousIME(reason: String) {
        cancelRestoreImeTimer()

        // 胶囊探测生效时，用「胶囊消失」作为豆包识别结果已上屏的真值信号，
        // 等它收尾后再恢复输入法，避免把「优化识别中」的未上屏内容切丢。
        if hudDetectionProven {
            Logger.shared.debug("\(reason)，等待豆包识别结果上屏后恢复输入法")
            scheduleRestorePoll(
                deadline: Date(timeIntervalSinceNow: imeFinalizeTimeout),
                quietTicks: 0
            )
            return
        }

        // 探测未生效（豆包界面变化、进程没找到等）：退回固定延迟的老行为。
        Logger.shared.debug("\(reason)，已安排恢复之前输入法")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.restoreImeTimer = nil
            self.restorePreviousIME()
        }
        restoreImeTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + restoreAfterVoiceStopDelay,
            execute: work
        )
    }

    /// 轮询等待豆包收尾：胶囊连续 imeFinalizeQuietTicks 个周期不可见，
    /// 视为识别结果已替换上屏，恢复输入法；超时则强制恢复。
    /// 轮询链挂在 restoreImeTimer 上，新一轮 Fn 动作会经 cancelRestoreImeTimer 整体取消。
    private func scheduleRestorePoll(deadline: Date, quietTicks: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.restoreImeTimer = nil

            let ticks = self.hudVisibleNow() ? 0 : quietTicks + 1
            if ticks >= self.imeFinalizeQuietTicks {
                Logger.shared.debug("豆包识别结果已上屏（胶囊已消失），恢复之前输入法")
                self.restorePreviousIME()
                return
            }
            if Date() >= deadline {
                Logger.shared.warn("等待豆包识别结果上屏超时（胶囊仍在屏），强制恢复输入法，未上屏内容可能丢失")
                self.restorePreviousIME()
                return
            }
            self.scheduleRestorePoll(deadline: deadline, quietTicks: ticks)
        }
        restoreImeTimer = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + imeFinalizePollInterval,
            execute: work
        )
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
        guard let chinese = Self.resolvedNormalChineseInputSource() else { return false }
        return (chinese.sourceID != nil && InputSourceManager.currentSourceID() == chinese.sourceID)
            || InputSourceManager.currentMethod() == chinese.value
    }

    private func selectNormalChineseInputMethod() -> Bool {
        guard let chinese = Self.resolvedNormalChineseInputSource() else { return false }
        if let id = chinese.sourceID, InputSourceManager.selectSource(byID: id) { return true }
        return InputSourceManager.selectMethod(byName: chinese.value)
    }

    private func selectNormalEnglishKeyboardLayout() -> Bool {
        guard let english = Self.resolvedNormalEnglishLayout() else { return false }
        if let id = english.sourceID, InputSourceManager.selectSource(byID: id) { return true }
        return InputSourceManager.selectLayout(byName: english.value)
    }

    private func isDoubaoInputSource(_ source: InputSource?) -> Bool {
        guard let source = source else { return false }
        return source.sourceID == Self.targetInputSourceID
            || (source.kind == .method && source.value == Self.targetInputMethod)
    }

    /// 挑选恢复目标；没有任何可用目标（极端情况：日常输入法也解析不到）时返回 nil。
    private func restoreTargetFrom(_ candidate: InputSource?) -> InputSource? {
        if let candidate = candidate, !isDoubaoInputSource(candidate) {
            return candidate
        }
        return lastNonDoubaoInputSource ?? Self.resolvedNormalChineseInputSource()
    }

    private func rememberLastNonDoubaoInputSource() {
        guard let source = InputSourceManager.nowSource() else { return }
        if !isDoubaoInputSource(source) {
            lastNonDoubaoInputSource = source
            Logger.shared.debug("记录最近非豆包输入源 \(source.kind.rawValue): \(source.value) (\(source.sourceID ?? "nil"))")
        }
    }

    /// - Parameter force: true 表示用户显式要求恢复（菜单动作），跳过所有守卫。
    private func restorePreviousIME(force: Bool = false) {
        if !force {
            // 恢复计时器可能晚到：新一轮 Fn 动作已经开始（或马上开始）时，
            // 输入法归属权在那个流程手里，这里不要抢着切回去。
            if voiceTransitionInProgress || pendingActionTimer != nil || doubaoVoiceActive {
                Logger.shared.debug("有进行中的语音切换或录音，跳过本次输入法恢复")
                return
            }
            // 用户已手动切走（或恢复早已生效）时不再强切，避免覆盖用户的选择。
            guard isDoubaoIMEActive() else {
                Logger.shared.debug("当前已不是豆包输入法，跳过输入法恢复")
                previousInputSource = nil
                return
            }
        }
        if previousInputSource == nil {
            Logger.shared.debug("没有记录到之前的输入来源，恢复到日常中文输入法")
        }
        guard let target = restoreTargetFrom(previousInputSource) else {
            Logger.shared.warn("没有可恢复的输入源（日常输入法也不可用），保持当前输入法不变")
            previousInputSource = nil
            return
        }
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
        onTimeout: (() -> Void)? = nil,
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
            onTimeout?()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) { [weak self] in
            self?.waitForInputSource(
                description: description,
                timeoutMessage: timeoutMessage,
                isReady: isReady,
                deadline: realDeadline,
                onTimeout: onTimeout,
                onReady: onReady
            )
        }
    }

    private func waitForDoubaoIME(onTimeout: (() -> Void)? = nil, then onReady: @escaping () -> Void) {
        waitForInputSource(
            description: "豆包输入法",
            timeoutMessage: "豆包输入法没切过去，再按一次 Fn",
            isReady: { [weak self] in self?.isDoubaoIMEActive() ?? false },
            onTimeout: onTimeout
        ) {
            self.nudgeForegroundAppIfNeeded(description: "豆包输入法") {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.voiceTriggerAfterSwitchDelay, execute: onReady)
            }
        }
    }

    private func waitForNormalChineseInputMethod(onTimeout: (() -> Void)? = nil, then onReady: @escaping () -> Void) {
        waitForInputSource(
            description: "日常中文输入法",
            timeoutMessage: "切回中文输入法超时了",
            isReady: { [weak self] in self?.isNormalChineseInputMethodActive() ?? false },
            onTimeout: onTimeout
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
        // 拦截门开启才会走到这里；解析结果仍可能在拦截后一瞬间变化，做兜底检查。
        guard let chinese = Self.resolvedNormalChineseInputSource(),
              let english = Self.resolvedNormalEnglishLayout()
        else {
            Logger.shared.warn("Ctrl+Space: 日常输入源不可用，跳过本次切换")
            refreshCtrlSpaceGate()
            return
        }

        let currentSourceID = InputSourceManager.currentSourceID()
        let currentMethod = InputSourceManager.currentMethod()
        let currentLayout = InputSourceManager.currentLayout()
        Logger.shared.debug("Ctrl+Space: currentSourceID=\(currentSourceID ?? "nil"), currentMethod=\(currentMethod ?? "nil"), currentLayout=\(currentLayout ?? "nil")")

        let isDoubao = currentSourceID == Self.targetInputSourceID
        let isNormalChinese = (chinese.sourceID != nil && currentSourceID == chinese.sourceID)
            || currentMethod == chinese.value

        if isDoubao || isNormalChinese {
            let ok = selectNormalEnglishKeyboardLayout()
            Logger.shared.debug("Ctrl+Space: 切换到英文键盘布局 \(english.value), 结果: \(ok)")
            return
        }

        let ok = selectNormalChineseInputMethod()
        Logger.shared.debug("Ctrl+Space: 切换到中文输入法 \(chinese.value), 结果: \(ok)")
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
