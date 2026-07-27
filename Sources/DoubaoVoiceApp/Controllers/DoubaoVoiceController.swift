import AppKit
import CoreGraphics
import Foundation

/// 主状态机：
/// - 说话快捷键（默认 Fn 轻按）：启动/停止豆包语音
/// - 轮换快捷键（默认 Ctrl+Space）：仅在日常中文输入法与日常英文键盘之间轮换
///
/// 两个快捷键都可在设置里改（见 `Hotkey`），裸修饰键形态要求按下期间没配合
/// 别的键才算一次轻按。
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

    private let actionAfterHotkeyDelay: TimeInterval = 0.2
    private let voiceTriggerAfterSwitchDelay: TimeInterval = 0.08
    private let inputSourceSwitchTimeout: TimeInterval = 2.0
    private let inputSourcePollInterval: TimeInterval = 0.01
    /// 重挂载输入法时单跳的等待上限。这条路径已经是失败补救，三跳串起来不能太久，
    /// 否则用户在整个过程里按快捷键都会被「仍在处理中」挡掉。实测单跳 <100ms。
    private let remountStepTimeout: TimeInterval = 0.6
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

    /// 新款键盘的 Fn/Globe 除了 flagsChanged，有时还会额外发一个 keyDown 179。
    private let keyCodeFnKeyDown: Int64 = 179

    // MARK: - 状态

    // 以下状态只在主线程访问。
    private var previousInputSource: InputSource?
    private var sourceBeforeVoiceHotkey: InputSource?
    private var lastNonDoubaoInputSource: InputSource?
    private var voiceTransitionInProgress: Bool = false

    // 以下状态只在事件监听线程访问（EventTapDelegate 回调都在该线程上）。

    /// 裸修饰键形态的按下跟踪：按下期间来了别的键或鼠标就不算一次轻按。
    private struct BareModifierTracker {
        var isDown = false
        var usedWithOtherInput = false

        mutating func reset() {
            isDown = false
            usedWithOtherInput = false
        }
    }

    /// 修饰键按下 / 抬起时的边沿判定结果。
    private enum BareModifierEdge {
        case none
        case pressed
        /// 抬起，且按下期间干净——一次有效的轻按。
        case tapped
        /// 抬起，但按下期间配合了别的输入，不算轻按。
        case cancelled
    }

    private var voiceModifier = BareModifierTracker()
    private var cycleModifier = BareModifierTracker()

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

    /// 事件监听线程唯一能读的快捷键状态。
    ///
    /// 读配置要摸 UserDefaults、解析输入源要走 TIS，都不能进事件回调（硬约束 1），
    /// 所以主线程预先算好一份快照，事件线程只读。
    private struct HotkeySnapshot {
        var voice: Hotkey
        var cycle: Hotkey
        /// 轮换拦截门：只有「开关开启 && 日常中文/英文输入源都可用」时才拦截，
        /// 否则透传给系统，避免把按键吞进一个注定失败的切换。
        var cycleInterceptionActive: Bool
        /// 设置窗口正在录制快捷键：全部透传。我们的 tap 挂在 headInsert，
        /// 不让路的话录制控件根本收不到已生效的那个快捷键。
        var captureActive: Bool

        /// Fn 被任一快捷键用作裸修饰键。它额外发的 keyDown 179 要跟着一起吞。
        var usesFnAsBareModifier: Bool {
            voice.bareModifier == .fn || cycle.bareModifier == .fn
        }
    }

    private let hotkeyStateLock = NSLock()
    private var _hotkeySnapshot = HotkeySnapshot(
        voice: GeneralSettings.Defaults.voiceHotkey,
        cycle: GeneralSettings.Defaults.cycleInputSourceHotkey,
        cycleInterceptionActive: false,
        captureActive: false
    )
    private var hotkeySnapshot: HotkeySnapshot {
        hotkeyStateLock.lock()
        defer { hotkeyStateLock.unlock() }
        return _hotkeySnapshot
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

    /// 语音期间暂停/恢复系统媒体播放（主线程调用）。
    private let mediaPauser = MediaPlaybackPauser()

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
            ? "豆包语音 录音中，按 \(voiceHotkeyLabel) 结束"
            : "豆包语音 待机中，按 \(voiceHotkeyLabel) 开始"
        return "\(label)\n\(voiceLine)"
    }

    /// 面向用户的说话快捷键写法，用于提示与日志（主线程调用）。
    private var voiceHotkeyLabel: String { GeneralSettings.voiceHotkey.displayString }

    // MARK: - 生命周期

    func setUp() {
        rememberLastNonDoubaoInputSource()
        inputSourceObserver = InputSourceManager.observeInputSourceChanged { [weak self] in
            self?.rememberLastNonDoubaoInputSource()
        }
        enabledSourcesObserver = InputSourceManager.observeEnabledInputSourcesChanged { [weak self] in
            self?.refreshHotkeyGate()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: GeneralSettings.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHotkeyGate()
        }
        refreshHotkeyGate()

        Logger.shared.info("目标输入法 source id: \(Self.targetInputSourceID)")
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
        // 退出前把被暂停的媒体还给用户（没暂停过则是 no-op）。
        mediaPauser.resumeAfterVoiceSession()
    }

    /// 重算快捷键快照（主线程调用；配置或系统输入法列表变化时触发）。
    private func refreshHotkeyGate() {
        let voice = GeneralSettings.voiceHotkey
        let cycle = GeneralSettings.cycleInputSourceHotkey
        let enabled = GeneralSettings.ctrlSpaceSwitchEnabled
        let chinese = Self.resolvedNormalChineseInputSource()
        let english = Self.resolvedNormalEnglishLayout()
        let active = enabled && chinese != nil && english != nil

        hotkeyStateLock.lock()
        let changed = _hotkeySnapshot.voice != voice
            || _hotkeySnapshot.cycle != cycle
            || _hotkeySnapshot.cycleInterceptionActive != active
        _hotkeySnapshot.voice = voice
        _hotkeySnapshot.cycle = cycle
        _hotkeySnapshot.cycleInterceptionActive = active
        hotkeyStateLock.unlock()

        guard changed || !gateLoggedOnce else { return }
        gateLoggedOnce = true

        Logger.shared.info("说话快捷键: \(voice.displayString)")
        if active {
            Logger.shared.info("\(cycle.displayString) 轮换已启用: \(chinese!.value) ↔ \(english!.value)")
        } else if !enabled {
            Logger.shared.info("输入源轮换已在设置中关闭，\(cycle.displayString) 透传给系统")
        } else {
            Logger.shared.warn("输入源轮换已自动停用（日常输入法不可用：中文=\(chinese?.value ?? "无") 英文=\(english?.value ?? "无")），\(cycle.displayString) 透传给系统")
        }
    }

    private var gateLoggedOnce = false

    /// 设置窗口录制快捷键期间暂停全部拦截（主线程调用）。
    func setHotkeyCaptureActive(_ active: Bool) {
        hotkeyStateLock.lock()
        _hotkeySnapshot.captureActive = active
        hotkeyStateLock.unlock()
        Logger.shared.debug(active ? "开始录制快捷键，事件拦截已暂停" : "快捷键录制结束，事件拦截已恢复")
    }

    // MARK: - EventTapDelegate
    //
    // 这些回调运行在事件监听线程上，必须立即返回：
    // 只做键码/flags 判断和轻量状态更新，任何可能阻塞的调用（TIS、日志外的 IO）
    // 都派发到主队列异步执行。回调里一旦卡超过约 1 秒，系统会禁用整个 tap，
    // 造成"按快捷键没反应"。

    func handleFlagsChanged(event: CGEvent) -> Bool {
        // 我们自己发出去的 Option 单击会绕回这里，不能当成用户按键。
        guard !KeyboardSimulator.isSynthetic(event) else { return false }

        let snapshot = hotkeySnapshot
        guard !snapshot.captureActive else {
            // 录制期间的按下 / 抬起我们看不全，跟踪状态留着只会脏，清掉重来。
            voiceModifier.reset()
            cycleModifier.reset()
            return false
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        var swallow = false

        if snapshot.voice.matchesModifierKeyCode(keycode) {
            let edge = trackBareModifier(
                &voiceModifier,
                pressed: snapshot.voice.modifierIsPressed(in: flags)
            )
            switch edge {
            case .pressed:
                // TIS 读取可能阻塞（服务冷启动时长达秒级），不能放在回调里。
                DispatchQueue.main.async { [weak self] in
                    self?.sourceBeforeVoiceHotkey = InputSourceManager.nowSource()
                }
            case .tapped:
                DispatchQueue.main.async { [weak self] in self?.scheduleDoubaoToggle() }
            case .cancelled:
                DispatchQueue.main.async { [weak self] in self?.sourceBeforeVoiceHotkey = nil }
            case .none:
                break
            }
            if edge != .none, snapshot.voice.swallowsEvent { swallow = true }
        }

        if snapshot.cycle.matchesModifierKeyCode(keycode) {
            let edge = trackBareModifier(
                &cycleModifier,
                pressed: snapshot.cycle.modifierIsPressed(in: flags)
            )
            if edge == .tapped, snapshot.cycleInterceptionActive {
                DispatchQueue.main.async { [weak self] in self?.toggleNormalInputSource() }
            }
            if edge != .none, snapshot.cycle.swallowsEvent { swallow = true }
        }

        return swallow
    }

    func handleKeyDown(event: CGEvent) -> Bool {
        guard !KeyboardSimulator.isSynthetic(event) else { return false }

        let snapshot = hotkeySnapshot
        guard !snapshot.captureActive else {
            voiceModifier.reset()
            cycleModifier.reset()
            return false
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
        let flags = event.flags

        markBareModifiersUsedWithOtherInput(keycode: keycode, snapshot: snapshot)

        // Fn/Globe 自己那条 keyDown 只要它被当作快捷键就得吞，
        // 否则系统会在语音之外再弹一个 Emoji 面板 / 听写。
        if isFnKeyDownEvent(keycode) {
            return snapshot.usesFnAsBareModifier
        }

        // 说话快捷键要排在「任意按键结束语音」前面：它本身就是那个停止键。
        if snapshot.voice.matchesKeyDown(keyCode: keycode, flags: flags) {
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in self?.scheduleDoubaoToggle() }
            }
            return snapshot.voice.swallowsEvent
        }

        if doubaoVoiceActive {
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    self?.markDoubaoVoiceStoppedByExternalActivity("检测到键盘输入 \(keycode) 结束豆包语音")
                }
            }
            return false
        }

        guard snapshot.cycle.matchesKeyDown(keyCode: keycode, flags: flags) else { return false }

        // 开关关闭或配置的日常输入源不可用时透传，让系统按默认行为处理这个键。
        guard snapshot.cycleInterceptionActive else { return false }

        if !isRepeat {
            DispatchQueue.main.async { [weak self] in
                self?.toggleNormalInputSource()
            }
        }
        return snapshot.cycle.swallowsEvent
    }

    func handleMouseDown(event: CGEvent, type: CGEventType) -> Bool {
        guard !KeyboardSimulator.isSynthetic(event) else { return false }

        // 按着 Option 拖拽复制这类操作不该被当成「单独点了一下 Option」。
        markBareModifiersUsedWithOtherInput(keycode: nil, snapshot: hotkeySnapshot)

        if doubaoVoiceActive {
            DispatchQueue.main.async { [weak self] in
                self?.markDoubaoVoiceStoppedByExternalActivity("检测到鼠标点击 \(type) 结束豆包语音")
            }
        }
        return false
    }

    /// tap 被系统禁用又恢复后调用（事件监听线程）。
    /// 禁用期间可能只收到了修饰键的按下而丢了抬起，把跟踪状态清零，
    /// 避免 isDown 卡死导致后续轻按被误判成「配合了其它键」。
    func eventTapWasInterrupted() {
        voiceModifier.reset()
        cycleModifier.reset()
        DispatchQueue.main.async { [weak self] in
            self?.sourceBeforeVoiceHotkey = nil
        }
    }

    private func trackBareModifier(
        _ tracker: inout BareModifierTracker,
        pressed: Bool
    ) -> BareModifierEdge {
        if pressed && !tracker.isDown {
            tracker.isDown = true
            tracker.usedWithOtherInput = false
            return .pressed
        }
        if !pressed && tracker.isDown {
            let used = tracker.usedWithOtherInput
            tracker.reset()
            return used ? .cancelled : .tapped
        }
        return .none
    }

    /// 裸修饰键按着的时候来了别的输入，这一次就不算轻按了。
    /// `keyCode` 为 nil 表示来源是鼠标点击。
    private func markBareModifiersUsedWithOtherInput(keycode: Int64?, snapshot: HotkeySnapshot) {
        if voiceModifier.isDown, !isOwnKeyCode(keycode, of: snapshot.voice) {
            voiceModifier.usedWithOtherInput = true
        }
        if cycleModifier.isDown, !isOwnKeyCode(keycode, of: snapshot.cycle) {
            cycleModifier.usedWithOtherInput = true
        }
    }

    private func isOwnKeyCode(_ keycode: Int64?, of hotkey: Hotkey) -> Bool {
        guard let keycode = keycode else { return false }
        if hotkey.matchesModifierKeyCode(keycode) { return true }
        // Fn/Globe 额外发的那条 keyDown 是它自己，不算「配合了其它键」。
        return hotkey.bareModifier == .fn && keycode == keyCodeFnKeyDown
    }

    private func isFnKeyDownEvent(_ keycode: Int64) -> Bool {
        keycode == Hotkey.ModifierKey.fn.canonicalKeyCode || keycode == keyCodeFnKeyDown
    }

    // MARK: - 说话快捷键调度

    private func scheduleDoubaoToggle() {
        Logger.shared.debug("检测到说话快捷键 \(voiceHotkeyLabel)，\(actionAfterHotkeyDelay)s 后切换豆包语音")
        cancelPendingActionTimer()
        // 立刻取消挂起的输入法恢复：否则「停止后 0.8-1.0s 内再按一次」时，
        // 恢复计时器会赶在本次切换前触发，把输入法闪切回去再切回豆包。
        cancelRestoreImeTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingActionTimer = nil
            self.toggleDoubaoVoice()
        }
        pendingActionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + actionAfterHotkeyDelay, execute: work)
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

    /// 等价于按一次说话快捷键：启动 / 停止豆包语音，菜单栏可直接调用。
    func toggleDoubaoVoice() {
        guard !voiceTransitionInProgress else {
            Logger.shared.warn("豆包语音启动/停止仍在处理中，忽略本次触发")
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
        // 音乐/视频在播时先暂停，与下面的输入法切换并行进行，不增加启动延迟；
        // 用户开口前媒体就能静下来。所有失败结束路径都会触发恢复（见
        // scheduleRestorePreviousIME 与 finishVoiceTransition 两个收口）。
        mediaPauser.pauseForVoiceSession()
        previousInputSource = restoreTargetFrom(sourceBeforeVoiceHotkey ?? InputSourceManager.nowSource())
        sourceBeforeVoiceHotkey = nil

        let triggerVoice: () -> Void = {
            if !self.isDoubaoIMEActive() && !self.setDoubaoIME() {
                self.showAlert("切不到豆包输入法，请确认已安装")
                self.finishVoiceTransition()
                return
            }
            self.waitForDoubaoIME(onTimeout: {
                self.finishVoiceTransition()
            }) {
                self.fireVoiceStartTap(attempt: .initial)
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
        // 启动失败的静默分支（切不到豆包输入法、等待超时、重试放弃等）
        // 不经过 scheduleRestorePreviousIME，在这里兜底恢复媒体播放。
        // restoreImeTimer 非空说明收尾流程正在等豆包释放麦克风，媒体恢复
        // 归那条链管（见 scheduleRestorePreviousIME），这里不要提前拉起。
        // resumeAfterVoiceSession 幂等，与另一个收口重复触发无害。
        if !doubaoVoiceActive && restoreImeTimer == nil {
            mediaPauser.resumeAfterVoiceSession()
        }
    }

    private func markDoubaoVoiceStoppedByExternalActivity(_ reason: String) {
        stopHudWatch()
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: reason)
    }

    // MARK: - 启动确认与录音巡检（语音胶囊真值）

    /// 启动落空后的补救梯度：先刷新焦点，再整条重挂输入法，都不行才放弃。
    private enum VoiceStartAttempt {
        case initial
        case afterFocusNudge
        case afterImeRemount
    }

    /// 发送启动用的 Option 单击，并用语音胶囊确认豆包真的开始录音了。
    ///
    /// 单击可能落空：Electron 应用（Notion 等）的文本输入上下文经常滞后于
    /// TIS 切换，按键发出时上下文还挂在旧输入法上，豆包收不到。以前这里盲目
    /// 把状态置成「录音中」，一旦落空，后续每次按快捷键的语义都是反的。
    private func fireVoiceStartTap(attempt: VoiceStartAttempt) {
        KeyboardSimulator.tapLeftOption {
            self.verifyVoiceStarted(
                deadline: Date(timeIntervalSinceNow: self.hudAppearTimeout),
                attempt: attempt
            )
        }
    }

    private func verifyVoiceStarted(deadline: Date, attempt: VoiceStartAttempt) {
        if hudVisibleNow() {
            doubaoVoiceActive = true
            finishVoiceTransition()
            startHudWatch()
            Logger.shared.debug("豆包语音输入已启动（语音胶囊已确认出现），等待再次按 \(voiceHotkeyLabel) 停止")
            return
        }

        if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + hudPollInterval) { [weak self] in
                self?.verifyVoiceStarted(deadline: deadline, attempt: attempt)
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

        switch attempt {
        case .initial:
            Logger.shared.warn(String(
                format: "Option 单击后语音胶囊没出现（前台应用输入上下文可能没跟上切换），强制焦点刷新后重发一次，会话 flags=0x%08llx",
                CGEventSource.flagsState(.combinedSessionState).rawValue
            ))
            InputSourceActivationNudge.shared.performForced(description: "豆包语音启动重试") { [weak self] in
                guard let self = self else { return }
                guard self.isDoubaoIMEActive() else {
                    Logger.shared.warn("重试时当前输入法已不是豆包，放弃本次启动")
                    self.doubaoVoiceActive = false
                    self.finishVoiceTransition()
                    return
                }
                self.fireVoiceStartTap(attempt: .afterFocusNudge)
            }

        case .afterFocusNudge:
            Logger.shared.warn("焦点刷新后豆包仍无反应，重新挂载输入法再试一次")
            remountDoubaoIME { [weak self] ok in
                guard let self = self else { return }
                guard ok else {
                    self.giveUpVoiceStart()
                    return
                }
                self.fireVoiceStartTap(attempt: .afterImeRemount)
            }

        case .afterImeRemount:
            giveUpVoiceStart()
        }
    }

    /// 重挂输入法也救不回来：如实置为未启动，让下一次触发走干净的启动流程，
    /// 不留下「App 以为在录音、豆包其实没在录」的脏状态。
    private func giveUpVoiceStart() {
        doubaoVoiceActive = false
        finishVoiceTransition()
        logVoiceStartFailureDiagnostics()
        // 别把用户扔在豆包输入法上：拉起失败时它只是个用不了的空壳，
        // 用户还得自己切回去才能打字。
        scheduleRestorePreviousIME(reason: "豆包语音启动失败")
        showAlert("豆包语音没拉起来，请再按一次 \(voiceHotkeyLabel)")
    }

    /// 拉起失败时把现场一次性记全，便于下次复现时直接判定失败类型：
    /// flags 带无关修饰键 = 幽灵修饰键；豆包无在屏窗口 = 输入法没挂上；
    /// 两者都正常则是豆包侧的问题。
    private func logVoiceStartFailureDiagnostics() {
        let sessionFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let hidFlags = CGEventSource.flagsState(.hidSystemState).rawValue
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
        Logger.shared.warn(String(
            format: "拉起失败现场: 输入源=%@, 前台应用=%@, 会话 flags=0x%08llx, HID flags=0x%08llx, 豆包在屏窗口=%@",
            InputSourceManager.currentSourceID() ?? "nil",
            frontApp,
            sessionFlags,
            hidFlags,
            DoubaoVoiceHUDDetector.describeOnscreenWindows()
        ))
    }

    // MARK: - 输入法重挂载（启动失灵时的自愈）

    /// 把输入法整条链路重新走一遍：日常英文键盘布局 → 日常中文输入法 → 豆包。
    ///
    /// 豆包偶发会对模拟的 Option 单击完全没反应：输入法已选中、光标旁的「⌥」角标也在，
    /// 但连按十几次都拉不起录音，能持续几十秒。实测在两个输入法之间来回切没用，
    /// 必须先落到一个键盘布局上再切回来才能恢复（用户手动救回来的也是这条路径），
    /// 所以这里原样自动化一遍。中途任何一步失败都回 false，交给上层放弃。
    private func remountDoubaoIME(completion: @escaping (Bool) -> Void) {
        guard let english = Self.resolvedNormalEnglishLayout(),
              Self.resolvedNormalChineseInputSource() != nil
        else {
            Logger.shared.warn("重新挂载输入法：日常输入源不可用，跳过")
            completion(false)
            return
        }

        switchAndWait(
            "日常英文键盘布局",
            select: { self.selectNormalEnglishKeyboardLayout() },
            isReady: { self.isInputSourceActive(english) }
        ) { [weak self] ok in
            guard let self = self, ok else {
                completion(false)
                return
            }
            self.switchAndWait(
                "日常中文输入法",
                select: { self.selectNormalChineseInputMethod() },
                isReady: { self.isNormalChineseInputMethodActive() }
            ) { ok in
                guard ok else {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.inputMethodBridgeDelay) {
                    self.switchAndWait(
                        "豆包输入法",
                        select: { self.setDoubaoIME() },
                        isReady: { self.isDoubaoIMEActive() }
                    ) { ok in
                        guard ok else {
                            completion(false)
                            return
                        }
                        Logger.shared.debug("输入法已重新挂载，准备重发 Option 单击")
                        self.nudgeForegroundAppIfNeeded(description: "输入法重新挂载") {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + self.voiceTriggerAfterSwitchDelay
                            ) {
                                completion(true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 切换输入源并等它生效。这是内部自愈路径，超时只记日志、不弹提示。
    private func switchAndWait(
        _ description: String,
        select: () -> Bool,
        isReady: @escaping () -> Bool,
        then completion: @escaping (Bool) -> Void
    ) {
        guard select() else {
            Logger.shared.warn("重新挂载输入法：切到\(description)失败")
            completion(false)
            return
        }
        pollUntil(isReady, deadline: Date(timeIntervalSinceNow: remountStepTimeout)) { ok in
            if !ok {
                Logger.shared.warn("重新挂载输入法：等\(description)生效超时")
            }
            completion(ok)
        }
    }

    private func pollUntil(
        _ isReady: @escaping () -> Bool,
        deadline: Date,
        then completion: @escaping (Bool) -> Void
    ) {
        if isReady() {
            completion(true)
            return
        }
        if Date() >= deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            self.pollUntil(isReady, deadline: deadline, then: completion)
        }
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

        // 媒体恢复不在这里立刻做，而是等下面的收尾流程确认豆包会话真正结束
        // （胶囊消失）后再做：「优化识别中」阶段麦克风会话还没释放，蓝牙耳机
        // 仍处于通话档（HFP）、扬声器仍带回声消除配置，这时拉起音乐会先以
        // 偏大的音量播出，等豆包释放麦克风、音频路由切回正常档才跳回去，
        // 听感就是「刚恢复声音偏大，过一会儿才正常」。

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
            // 盲等场景下拿不到麦克风释放的真值信号，固定延迟后一并恢复媒体。
            self.mediaPauser.resumeAfterVoiceSession()
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
    /// 轮询链挂在 restoreImeTimer 上，新一轮语音动作会经 cancelRestoreImeTimer 整体取消。
    private func scheduleRestorePoll(deadline: Date, quietTicks: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.restoreImeTimer = nil

            let ticks = self.hudVisibleNow() ? 0 : quietTicks + 1
            if ticks >= self.imeFinalizeQuietTicks {
                Logger.shared.debug("豆包识别结果已上屏（胶囊已消失），恢复之前输入法")
                // 胶囊已消失 = 麦克风已释放、音频路由已切回正常播放档，
                // 此刻恢复媒体不会再出现音量先大后小的跳变。
                self.mediaPauser.resumeAfterVoiceSession()
                self.restorePreviousIME()
                return
            }
            if Date() >= deadline {
                Logger.shared.warn("等待豆包识别结果上屏超时（胶囊仍在屏），强制恢复输入法，未上屏内容可能丢失")
                // 超时兜底：宁可音量有一次跳变，也不能让媒体一直停着。
                self.mediaPauser.resumeAfterVoiceSession()
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
            // 恢复计时器可能晚到：新一轮语音动作已经开始（或马上开始）时，
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
            timeoutMessage: "豆包输入法没切过去，再按一次 \(voiceHotkeyLabel)",
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

    // MARK: - 输入源轮换

    private func toggleNormalInputSource() {
        // 拦截门开启才会走到这里；解析结果仍可能在拦截后一瞬间变化，做兜底检查。
        guard let chinese = Self.resolvedNormalChineseInputSource(),
              let english = Self.resolvedNormalEnglishLayout()
        else {
            Logger.shared.warn("输入源轮换: 日常输入源不可用，跳过本次切换")
            refreshHotkeyGate()
            return
        }

        let currentSourceID = InputSourceManager.currentSourceID()
        let currentMethod = InputSourceManager.currentMethod()
        let currentLayout = InputSourceManager.currentLayout()
        Logger.shared.debug("输入源轮换: currentSourceID=\(currentSourceID ?? "nil"), currentMethod=\(currentMethod ?? "nil"), currentLayout=\(currentLayout ?? "nil")")

        let isDoubao = currentSourceID == Self.targetInputSourceID
        let isNormalChinese = (chinese.sourceID != nil && currentSourceID == chinese.sourceID)
            || currentMethod == chinese.value

        if isDoubao || isNormalChinese {
            let ok = selectNormalEnglishKeyboardLayout()
            Logger.shared.debug("输入源轮换: 切换到英文键盘布局 \(english.value), 结果: \(ok)")
            return
        }

        let ok = selectNormalChineseInputMethod()
        Logger.shared.debug("输入源轮换: 切换到中文输入法 \(chinese.value), 结果: \(ok)")
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
