import AppKit
import CoreGraphics
import Foundation

/// 主状态机：
/// - 说话快捷键（默认 Fn 轻按）：启动/停止豆包语音
/// - 轮换快捷键（默认 Ctrl+Space）：在用户挑选的输入源之间依次轮换
///   （没挑过就是日常中文输入法 ↔ 日常英文键盘）
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

    /// 参与轮换、且当前在系统里已启用的输入源，按系统输入源列表的顺序轮换。
    /// 没挑过时沿用老行为：日常中文输入法 ↔ 日常英文键盘。少于两个时轮换不生效。
    static func resolvedCycleInputSources() -> [InputSource] {
        guard let ids = GeneralSettings.cycleInputSourceIDs else {
            return [resolvedNormalChineseInputSource(), resolvedNormalEnglishLayout()].compactMap { $0 }
        }
        let wanted = Set(ids)
        return InputSourceManager.enabledSelectableSources().filter {
            guard let id = $0.sourceID else { return false }
            return wanted.contains(id)
        }
    }

    // MARK: - 时间常量（单位：秒）

    /// 组合键 / 功能键按下即触发，给用户松开快捷键留出的最短时间；输入源准备与这段等待并行。
    /// 单独修饰键（Fn 等）本来就是抬起才触发，不用再等。
    private let actionAfterHotkeyDelay: TimeInterval = 0.2
    private let voiceTriggerAfterSwitchDelay: TimeInterval = 0.08
    private let inputSourceSwitchTimeout: TimeInterval = 2.0
    /// 豆包进程还没起来时，TIS 报成功也要再等进程；开机冷启动可能到数秒。
    private let inputSourceColdStartTimeout: TimeInterval = 5.0
    private let inputSourcePollInterval: TimeInterval = 0.01
    private let inputMethodBridgeDelay: TimeInterval = 0.15
    /// 轮换快捷键切到豆包后，这段时间内的切换通知都归这次手动切换（一次切换会来两三条通知）。
    private let cycleSwitchNotificationWindow: TimeInterval = 1.0
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
    /// 启动前等上一段收尾：此时胶囊已是「识别优化中」，消失即结束，
    /// 不需要容忍录音形态切换的空档，静默 0.3s 就够。
    private let startWaitPollInterval: TimeInterval = 0.1
    private let startWaitQuietTicks = 3
    /// 等待豆包收尾的上限：识别优化一般 1-3s，网络差时更久；
    /// 超过上限就不再等（宁可冒丢字风险也不让输入法永远悬在豆包上）。
    private let imeFinalizeTimeout: TimeInterval = 10.0

    /// Option 单击后豆包既没出胶囊、也没创建语音电源断言的判定时长。
    /// 断言约 40ms 出现、胶囊热启动 p95 约 0.39s；两者都没有就是这一击落空，可以补发。
    private let hudAppearTimeout: TimeInterval = 0.5
    /// 本次运行还没见过语音电源断言（豆包改名等）时，只能靠胶囊判断，放宽等待，
    /// 避免把慢启动误判成落空、补发的 Option 反把录音停掉。
    private let hudAppearTimeoutWithoutSignal: TimeInterval = 1.2
    /// 冷启动（豆包进程还没起来）时胶囊出现更慢，给更长窗口。
    private let coldHudAppearTimeout: TimeInterval = 2.5
    private let hudPollInterval: TimeInterval = 0.06
    /// 落空后补发前的停顿：刚切过输入法时前台 App 还在处理，给它一点时间。
    private let voiceStartResendDelay: TimeInterval = 0.3
    /// 豆包收到单击却放弃启动时，原样补发的次数上限。
    private let voiceStartMaxResendsAfterAbandon = 2
    /// 豆包对单击毫无反应（多半是输入框没获得焦点）时只补发一次，随后放弃并提示。
    private let voiceStartMaxResendsWithoutResponse = 1
    /// 录音中巡检语音胶囊的周期；连续缺席两次（约 1s）才认定豆包已自行结束，
    /// 容忍胶囊在「准备录音 → 波形 → 识别中」形态切换时的短暂消失。
    private let hudWatchInterval: TimeInterval = 0.5
    private let hudWatchMissThreshold = 2
    /// 未收到停止操作，胶囊就连续缺席首轮巡检：豆包可能只打开了几十毫秒麦克风。
    private let voiceStartupFailureWindow: TimeInterval = 1.5

    // MARK: - 键码常量

    /// 新款键盘的 Fn/Globe 除了 flagsChanged，有时还会额外发一个 keyDown 179。
    private let keyCodeFnKeyDown: Int64 = 179

    // MARK: - 状态

    // 以下状态只在主线程访问。
    private var previousInputSource: InputSource?
    private var sourceBeforeVoiceHotkey: InputSource?
    private var lastNonDoubaoInputSource: InputSource?
    /// 轮换快捷键最近一次把输入法切成豆包的时间。这是用户主动切换，不是豆包全局语音在唤起自己，
    /// 随后的切换通知不能据此安排「语音结束后切回」。
    private var cycleSwitchedToDoubaoAt: Date?
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
            let wasActive = _doubaoVoiceActive
            _doubaoVoiceActive = newValue
            voiceActiveLock.unlock()
            if wasActive && !newValue {
                notifyIdleForAppUpdateIfNeeded()
            }
        }
    }

    /// 语音会话或切换尚未收尾：自动更新应等它结束再重启，避免打断录音。
    var isBusyForAppUpdate: Bool {
        doubaoVoiceActive || voiceTransitionInProgress || pendingActionTimer != nil
            || globalVoiceMediaPaused
    }

    /// 事件监听线程唯一能读的快捷键状态。
    ///
    /// 读配置要摸 UserDefaults、解析输入源要走 TIS，都不能进事件回调（硬约束 1），
    /// 所以主线程预先算好一份快照，事件线程只读。
    private struct HotkeySnapshot {
        var voice: Hotkey
        var cycle: Hotkey
        /// 轮换拦截门：只有「开关开启 && 至少两个参与轮换的输入源可用」时才拦截，
        /// 否则透传给系统，避免把按键吞进一个注定失败的切换。
        var cycleInterceptionActive: Bool
        /// 设置窗口正在录制快捷键：全部透传。我们的 tap 挂在 headInsert，
        /// 不让路的话录制控件根本收不到已生效的那个快捷键。
        var captureActive: Bool
        /// 说话快捷键交给豆包全局语音：只旁观、绝不吞，让豆包自己的监听收到。
        var voiceDelegatedToDoubao: Bool

        /// Fn 被本 App 当作裸修饰键吞掉时，它额外发的 keyDown 179 要跟着一起吞。
        var usesFnAsBareModifier: Bool {
            (voice.bareModifier == .fn && !voiceDelegatedToDoubao) || cycle.bareModifier == .fn
        }
    }

    private let hotkeyStateLock = NSLock()
    private var _hotkeySnapshot = HotkeySnapshot(
        voice: GeneralSettings.Defaults.voiceHotkey,
        cycle: GeneralSettings.Defaults.cycleInputSourceHotkey,
        cycleInterceptionActive: false,
        captureActive: false,
        voiceDelegatedToDoubao: false
    )
    private var hotkeySnapshot: HotkeySnapshot {
        hotkeyStateLock.lock()
        defer { hotkeyStateLock.unlock() }
        return _hotkeySnapshot
    }

    private var pendingActionTimer: DispatchWorkItem?
    private var restoreImeTimer: DispatchWorkItem?
    private var voiceTapNotBefore: DispatchTime?
    private var voiceStartRequestedAt: TimeInterval?
    private var voiceStartTapCount = 0

    // 语音胶囊探测（主线程访问）。
    // hudDetectionProven：本次进程运行期间是否成功观测到过胶囊。观测到过，
    // 才敢把「胶囊不在」当作「豆包没在录音」的依据；否则（豆包改版、进程没找到）
    // 停止与输入法恢复沿用固定延迟；启动仍须确认胶囊，角标不能作为成功依据。
    private var hudDetectionProven = false
    /// 本次运行是否观测到过豆包的语音电源断言；观测到过，才敢用它提前判定落空。
    private var voiceAssertionProven = false
    private var hudWatchTimer: DispatchSourceTimer?
    private var hudWatchMissCount = 0

    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    /// 语音期间暂停/恢复系统媒体播放（主线程调用）。
    private let mediaPauser = MediaPlaybackPauser()
    /// 豆包进程冷启动：加长胶囊等待。只在主线程访问。
    private var voiceStartIsCold = false
    private var voiceSessionStartedAt: Date?

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
            self?.detectDoubaoGlobalVoiceSwitch()
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
        globalVoiceWatchTimer?.cancel()
        globalVoiceWatchTimer = nil
        voiceSessionStartedAt = nil
        voiceTapNotBefore = nil
        voiceStartRequestedAt = nil
        voiceTransitionInProgress = false
        // 退出前把被暂停的媒体还给用户（没暂停过则是 no-op）。
        mediaPauser.resumeAfterVoiceSession()
    }

    /// 重算快捷键快照（主线程调用；配置或系统输入法列表变化时触发）。
    private func refreshHotkeyGate() {
        let voice = GeneralSettings.voiceHotkey
        let cycle = GeneralSettings.cycleInputSourceHotkey
        let enabled = GeneralSettings.ctrlSpaceSwitchEnabled
        let members = Self.resolvedCycleInputSources()
        let active = enabled && members.count >= 2
        let delegated = GeneralSettings.voiceHandledByDoubao

        hotkeyStateLock.lock()
        let changed = _hotkeySnapshot.voice != voice
            || _hotkeySnapshot.cycle != cycle
            || _hotkeySnapshot.cycleInterceptionActive != active
            || _hotkeySnapshot.voiceDelegatedToDoubao != delegated
        _hotkeySnapshot.voice = voice
        _hotkeySnapshot.cycle = cycle
        _hotkeySnapshot.cycleInterceptionActive = active
        _hotkeySnapshot.voiceDelegatedToDoubao = delegated
        hotkeyStateLock.unlock()

        guard changed || !gateLoggedOnce else { return }
        gateLoggedOnce = true

        if delegated {
            Logger.shared.info("说话快捷键交给豆包输入法的全局语音处理，本 App 只旁观（用于说话时暂停媒体）")
        } else {
            Logger.shared.info("说话快捷键: \(voice.displayString)")
        }
        if active {
            Logger.shared.info("\(cycle.displayString) 轮换已启用: \(members.map(\.value).joined(separator: " → "))")
        } else if !enabled {
            Logger.shared.info("输入源轮换已在设置中关闭，\(cycle.displayString) 透传给系统")
        } else {
            Logger.shared.warn("输入源轮换已自动停用（可用的轮换输入源不足两个：\(members.map(\.value).joined(separator: "、"))），\(cycle.displayString) 透传给系统")
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
            if snapshot.voiceDelegatedToDoubao {
                switch edge {
                case .pressed:
                    // 豆包在抬起时才切输入法，按下这一刻的输入源就是之后要切回的目标。
                    DispatchQueue.main.async { [weak self] in
                        self?.sourceBeforeVoiceHotkey = InputSourceManager.nowSource()
                    }
                case .tapped:
                    DispatchQueue.main.async { [weak self] in self?.watchDoubaoGlobalVoice() }
                default:
                    break
                }
            } else {
            switch edge {
            case .pressed:
                // TIS 读取可能阻塞（服务冷启动时长达秒级），不能放在回调里。
                DispatchQueue.main.async { [weak self] in
                    self?.sourceBeforeVoiceHotkey = InputSourceManager.nowSource()
                }
            case .tapped:
                DispatchQueue.main.async { [weak self] in self?.scheduleDoubaoToggle(afterRelease: true) }
            case .cancelled:
                DispatchQueue.main.async { [weak self] in self?.sourceBeforeVoiceHotkey = nil }
            case .none:
                break
            }
            if edge != .none, snapshot.voice.swallowsEvent { swallow = true }
            }
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
            if snapshot.voiceDelegatedToDoubao {
                if !isRepeat {
                    DispatchQueue.main.async { [weak self] in
                        self?.sourceBeforeVoiceHotkey = InputSourceManager.nowSource()
                        self?.watchDoubaoGlobalVoice()
                    }
                }
                return false
            }
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in self?.scheduleDoubaoToggle(afterRelease: false) }
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

    // MARK: - 豆包全局语音（旁观模式）

    /// 快捷键按下后多久内没见到豆包的语音断言，就认为这一下没有开始语音。
    private let globalVoiceStartWindow: TimeInterval = 1.5
    private let globalVoicePollInterval: TimeInterval = 0.1
    private var globalVoiceWatchTimer: DispatchSourceTimer?
    private var globalVoiceMediaPaused = false
    /// 本轮全局语音是从别的输入法唤起的，结束后需要切回。
    private var globalVoiceRestoreNeeded = false

    /// 说话快捷键交给豆包后，本 App 只做两件事：豆包录音期间暂停媒体；
    /// 识别结果上屏（胶囊消失）后把输入法切回按快捷键前的那个——豆包全局语音
    /// 默认不切回（它的恢复开关没有界面）。录音与否看豆包的「ASR Voice Input」电源断言。
    ///
    /// 豆包自己的 event tap 会吞掉它的语音快捷键，本 App 通常看不到这一下按键；
    /// 可靠的起点是「输入法被切成了豆包」这条系统通知（见 detectDoubaoGlobalVoiceSwitch）。
    /// 快捷键没被吞时（组合键等）也会走到这里，两条路径由巡检计时器去重。
    private func watchDoubaoGlobalVoice() {
        let pressedSource = sourceBeforeVoiceHotkey
        sourceBeforeVoiceHotkey = nil
        // 录音中再按一次是停止键，已有的巡检会接着处理。
        guard globalVoiceWatchTimer == nil else { return }

        // 新一轮语音开始：上一轮还没执行的切回先撤掉，由这一轮结束后统一切回。
        let restoreWasPending = restoreImeTimer != nil
        cancelRestoreImeTimer()
        if let source = pressedSource, !isDoubaoInputSource(source) {
            previousInputSource = source
            globalVoiceRestoreNeeded = true
        } else if !restoreWasPending {
            // 本来就在用豆包打字：结束后保持豆包，不切走。
            globalVoiceRestoreNeeded = false
        }
        startGlobalVoiceWatch()
    }

    /// 从别的输入法切到豆包：多半是豆包全局语音在唤起自己，开始巡检。
    /// 用户手动切到豆包也会走到这里，但没有录音就不会切回（见巡检超时分支）。
    private func detectDoubaoGlobalVoiceSwitch() {
        if let switchedAt = cycleSwitchedToDoubaoAt,
           Date().timeIntervalSince(switchedAt) < cycleSwitchNotificationWindow {
            return
        }
        guard GeneralSettings.voiceHandledByDoubao, isDoubaoIMEActive(),
              globalVoiceWatchTimer == nil, restoreImeTimer == nil,
              let source = lastNonDoubaoInputSource
        else { return }
        previousInputSource = source
        globalVoiceRestoreNeeded = true
        startGlobalVoiceWatch()
    }

    private func startGlobalVoiceWatch() {
        guard globalVoiceWatchTimer == nil else { return }
        let startedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + globalVoicePollInterval, repeating: globalVoicePollInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let recording = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
            _ = self.hudVisibleNow() // 让胶囊探测尽早生效，切回才会等识别结果上屏
            if recording {
                if !self.globalVoiceMediaPaused {
                    self.globalVoiceMediaPaused = true
                    Logger.shared.debug("豆包全局语音已开始")
                    self.mediaPauser.pauseForVoiceSession()
                }
                return
            }
            if self.globalVoiceMediaPaused {
                self.globalVoiceMediaPaused = false
                self.stopGlobalVoiceWatch()
                self.finishGlobalVoice(reason: "豆包全局语音已结束")
            } else if Date().timeIntervalSince(startedAt) > self.globalVoiceStartWindow {
                // 没开始录音：可能是用户手动切到了豆包，保持现状不切回。
                self.globalVoiceRestoreNeeded = false
                self.stopGlobalVoiceWatch()
            }
        }
        timer.resume()
        globalVoiceWatchTimer = timer
    }

    private func finishGlobalVoice(reason: String) {
        if globalVoiceRestoreNeeded {
            globalVoiceRestoreNeeded = false
            // 同时负责恢复媒体（等音频路由沉降）与等胶囊消失后切回输入法。
            scheduleRestorePreviousIME(reason: reason)
        } else {
            Logger.shared.debug("\(reason)，本来就在用豆包输入法，不切换")
            mediaPauser.resumeAfterVoiceSessionWhenRouteSettles()
        }
    }

    private func stopGlobalVoiceWatch() {
        globalVoiceWatchTimer?.cancel()
        globalVoiceWatchTimer = nil
        notifyIdleForAppUpdateIfNeeded()
    }

    // MARK: - 说话快捷键调度

    /// - Parameter afterRelease: 快捷键是抬起才触发的单独修饰键，按键已松开，无需再等。
    private func scheduleDoubaoToggle(afterRelease: Bool) {
        guard !voiceTransitionInProgress else {
            sourceBeforeVoiceHotkey = nil
            Logger.shared.debug("豆包语音仍在准备或停止，忽略重复快捷键")
            return
        }
        cancelPendingActionTimer()
        let releaseDelay = afterRelease ? 0 : actionAfterHotkeyDelay
        if !doubaoVoiceActive {
            Logger.shared.debug("检测到说话快捷键 \(voiceHotkeyLabel)，立即准备输入源，与按键释放等待并行")
            voiceStartRequestedAt = ProcessInfo.processInfo.systemUptime
            voiceTapNotBefore = .now() + releaseDelay
            toggleDoubaoVoice()
            return
        }
        Logger.shared.debug("检测到说话快捷键 \(voiceHotkeyLabel)，\(releaseDelay)s 后停止豆包语音")
        // 恢复输入法会检查 pendingActionTimer，不会抢在停止动作前切走输入法。
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingActionTimer = nil
            self.toggleDoubaoVoice()
        }
        pendingActionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay, execute: work)
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
        if voiceStartRequestedAt == nil {
            voiceStartRequestedAt = ProcessInfo.processInfo.systemUptime
        }
        voiceStartTapCount = 0
        voiceSessionStartedAt = nil
        let wasFinalizing = restoreImeTimer != nil
        cancelRestoreImeTimer()
        // 音乐/视频在播时先暂停，与下面的输入法切换并行进行，不增加启动延迟；
        // 用户开口前媒体就能静下来。所有失败结束路径都会触发恢复（见
        // scheduleRestorePreviousIME 与 finishVoiceTransition 两个收口）。
        mediaPauser.pauseForVoiceSession()
        let source = sourceBeforeVoiceHotkey ?? InputSourceManager.nowSource()
        // 上一段尚在收尾时当前输入法仍是豆包，继续保留那一段的恢复目标。
        if !isDoubaoInputSource(source) || previousInputSource == nil {
            previousInputSource = restoreTargetFrom(source)
        }
        sourceBeforeVoiceHotkey = nil

        voiceStartIsCold = !DoubaoVoiceHUDDetector.isIMEProcessRunning()
        if voiceStartIsCold {
            Logger.shared.debug("豆包输入法进程还没起来，按冷启动放宽胶囊等待")
        }

        let triggerVoice: () -> Void = {
            if !self.isDoubaoIMEActive() && !self.setDoubaoIME() {
                self.showAlert("切不到豆包输入法，请确认已安装")
                self.finishVoiceTransition()
                return
            }
            self.waitForDoubaoIME(onTimeout: {
                self.finishVoiceTransition()
            }) {
                self.logVoiceStartLatency(stage: "输入上下文已就绪")
                self.fireVoiceStartTap(attempt: .initial)
            }
        }

        waitForPreviousVoiceToFinish(requireQuietPeriod: wasFinalizing) {
            if !self.isDoubaoIMEActive(),
               let previous = self.previousInputSource, previous.kind == .layout,
               let chinese = Self.resolvedNormalChineseInputSource() {
                let ok = self.selectNormalChineseInputMethod()
                Logger.shared.debug("当前是键盘布局 \(previous.value)，先桥接到日常中文输入法 \(chinese.value)，结果: \(ok)")
                if ok {
                    self.waitForNormalChineseInputMethod(onTimeout: { [weak self] in
                        self?.finishVoiceTransition()
                    }, then: triggerVoice)
                    return
                }
            }
            triggerVoice()
        }
    }

    /// 在旧胶囊仍显示「识别优化中」时发 Option，不会开始一段新录音。
    /// 必须先等旧会话完全结束；只有遇到旧会话才等待，正常热启动不增加延迟。
    private func waitForPreviousVoiceToFinish(
        requireQuietPeriod: Bool = false,
        deadline: Date? = nil,
        quietTicks: Int = 0,
        then completion: @escaping () -> Void
    ) {
        guard voiceTransitionInProgress else { return }
        let visible = hudVisibleNow()
        if !visible && !requireQuietPeriod {
            completion()
            return
        }
        if deadline == nil {
            Logger.shared.debug("启动前上一段豆包语音尚未收尾，等待胶囊完全消失后再启动")
        }
        let ticks = visible ? 0 : quietTicks + 1
        if ticks >= startWaitQuietTicks {
            completion()
            return
        }
        let limit = deadline ?? Date(timeIntervalSinceNow: imeFinalizeTimeout)
        if Date() >= limit {
            Logger.shared.warn("启动前等待旧语音收尾超时，本次未发送启动单击")
            scheduleRestorePreviousIME(reason: "上一段豆包语音尚未结束")
            finishVoiceTransition()
            showAlert("豆包还在处理上一段语音，请等胶囊消失后再按 \(voiceHotkeyLabel)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + startWaitPollInterval) { [weak self] in
            self?.waitForPreviousVoiceToFinish(
                requireQuietPeriod: true,
                deadline: limit,
                quietTicks: ticks,
                then: completion
            )
        }
    }

    /// 同步已经出现的语音会话。胶囊可见只证明会话存在，不区分录音与识别优化；
    /// 因此启动前的旧胶囊必须由 waitForPreviousVoiceToFinish 排除。
    private func confirmVoiceSessionStarted() {
        doubaoVoiceActive = true
        let startedAt = Date()
        voiceSessionStartedAt = startedAt
        logVoiceStartLatency(stage: "新胶囊已出现，发送启动单击 \(voiceStartTapCount) 次")
        finishVoiceTransition()
        startHudWatch()
        Logger.shared.debug("豆包语音会话已启动（新胶囊已确认出现），等待再次按 \(voiceHotkeyLabel) 停止")
    }

    private func continueVoiceStart(attempt: VoiceStartAttempt) {
        if let deadline = voiceTapNotBefore, DispatchTime.now() < deadline {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.voiceTransitionInProgress else { return }
                self.pendingActionTimer = nil
                self.fireVoiceStartTap(attempt: attempt)
            }
            pendingActionTimer = work
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
            return
        }
        var doubaoAlreadyStarting = false
        // 按住 Option 直到豆包确认开始启动（语音断言出现后再稳 30ms）再松开，见 KeyboardSimulator。
        var assertionSeenAt: TimeInterval?
        let releaseWhen: () -> Bool = {
            let now = ProcessInfo.processInfo.systemUptime
            if assertionSeenAt == nil, DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() {
                assertionSeenAt = now
            }
            guard let seenAt = assertionSeenAt else { return false }
            return now - seenAt >= 0.03
        }
        KeyboardSimulator.tapLeftOption(if: { [weak self] in
            guard let self = self, self.voiceTransitionInProgress else { return false }
            guard self.isDoubaoIMEActive() else {
                Logger.shared.debug("启动发键前输入法已改变，取消本次语音启动")
                self.finishVoiceTransition()
                return false
            }
            // 等待修饰键释放、排队期间，先前的 Option 可能才被豆包处理。
            // 这次检查必须贴着真正的 key down，而不是仅在调用 tap 时检查。
            guard !self.hudVisibleNow() else { return false }
            // 豆包正在启动（胶囊还没画出来）时再发一击会把它停掉。
            guard !DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() else {
                Logger.shared.debug("豆包语音已在启动中，取消本次单击，等胶囊出现")
                doubaoAlreadyStarting = true
                return false
            }
            self.voiceStartTapCount += 1
            self.logVoiceStartLatency(stage: "发送第 \(self.voiceStartTapCount) 次启动单击")
            return true
        }, releaseWhen: releaseWhen) { [weak self] sent in
            guard let self = self, self.voiceTransitionInProgress else { return }
            if !sent, attempt == .initial, !doubaoAlreadyStarting {
                self.waitForPreviousVoiceToFinish(requireQuietPeriod: true) {
                    self.fireVoiceStartTap(attempt: attempt)
                }
                return
            }
            self.verifyVoiceStarted(tappedAt: Date(), attempt: attempt)
        }
    }

    private func stopDoubaoVoice() {
        stopHudWatch()
        voiceSessionStartedAt = nil

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
        voiceTapNotBefore = nil
        voiceStartRequestedAt = nil
        voiceTransitionInProgress = false
        // 启动失败的静默分支（切不到豆包输入法、等待超时、重试放弃等）
        // 不经过 scheduleRestorePreviousIME，在这里兜底立即恢复媒体——这些
        // 分支里豆包从没开始录音，麦克风没被占用过，不存在通话档窗口。
        // restoreImeTimer 非空说明 scheduleRestorePreviousIME 已接管本次收尾
        // （媒体恢复正在等音频路由沉降），立即恢复绝不能在这里抢跑。
        if !doubaoVoiceActive && restoreImeTimer == nil {
            mediaPauser.resumeAfterVoiceSession()
        }
        notifyIdleForAppUpdateIfNeeded()
    }

    private func logVoiceStartLatency(stage: String) {
        guard let requestedAt = voiceStartRequestedAt else { return }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1_000)
        Logger.shared.debug("语音启动耗时：\(stage)，距触发 \(milliseconds) 毫秒")
    }

    private func markDoubaoVoiceStoppedByExternalActivity(_ reason: String) {
        stopHudWatch()
        voiceSessionStartedAt = nil
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: reason)
    }

    // MARK: - 启动确认与录音巡检（语音胶囊真值）

    /// 启动落空后只原样补发，绝不强制刷新焦点或重挂输入法。
    ///
    /// - 豆包收到单击却放弃启动（前台 App 刚切完输入法还没缓过来）：过一会儿原样再发就能成。
    /// - 豆包毫无反应：多半是前台 App 的输入框根本没获得焦点。此时强制刷新焦点能把
    ///   豆包短暂激活、拉起录音，但 Claude 等 Electron 应用约 120ms 后又会把它
    ///   Deactivate——麦克风一直开着、文字写不进去、停止单击也送不到。宁可放弃并提示。
    private enum VoiceStartAttempt: Equatable {
        case initial
        case resend(Int)
    }

    /// 发送启动用的 Option 单击，并用语音胶囊确认豆包真的开始录音了。
    ///
    /// 单击可能落空：Electron 应用（Notion 等）的文本输入上下文经常滞后于
    /// TIS 切换，按键发出时上下文还挂在旧输入法上，豆包收不到。以前这里盲目
    /// 把状态置成「录音中」，一旦落空，后续每次按快捷键的语义都是反的。
    private func fireVoiceStartTap(attempt: VoiceStartAttempt) {
        guard voiceTransitionInProgress else { return }
        if attempt == .initial {
            // 输入源切换 / 焦点刷新期间也可能重新出现旧胶囊，不能把它当成新录音。
            waitForPreviousVoiceToFinish {
                self.continueVoiceStart(attempt: attempt)
            }
        } else if hudVisibleNow() && DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() {
            Logger.shared.debug("重试前豆包已在录音，取消补发 Option，避免反向停止录音")
            confirmVoiceSessionStarted()
        } else {
            // 豆包放弃启动时仍会弹出「识别优化中」胶囊；它不是录音，等它消失再补发。
            waitForPreviousVoiceToFinish {
                self.continueVoiceStart(attempt: attempt)
            }
        }
    }

    /// 用胶囊确认启动成功；用豆包的语音电源断言尽早区分「正在启动」和「落空 / 放弃」。
    private func verifyVoiceStarted(tappedAt: Date, attempt: VoiceStartAttempt, sawAssertion: Bool = false) {
        guard voiceTransitionInProgress else { return }
        if hudVisibleNow() {
            confirmVoiceSessionStarted()
            return
        }

        let elapsed = Date().timeIntervalSince(tappedAt)
        let assertionHeld = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
        if assertionHeld && !voiceAssertionProven {
            voiceAssertionProven = true
            Logger.shared.info("豆包语音电源断言探测生效")
        }
        let poll = { [weak self] (saw: Bool) in
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.hudPollInterval ?? 0.06)) {
                self?.verifyVoiceStarted(tappedAt: tappedAt, attempt: attempt, sawAssertion: saw)
            }
        }

        if assertionHeld {
            // 豆包已经在启动：再发 Option 只会把它停掉，耐心等胶囊。
            if elapsed < coldHudAppearTimeout {
                poll(true)
                return
            }
            Logger.shared.warn("豆包语音断言已持续 \(coldHudAppearTimeout)s 仍未探测到胶囊，按已启动处理")
            confirmVoiceSessionStarted()
            return
        }

        // 断言出现过又消失、胶囊也没出来：豆包收到了单击但放弃了启动，不必再等。
        let abandoned = sawAssertion
        let limit: TimeInterval
        if voiceStartIsCold {
            limit = coldHudAppearTimeout
        } else {
            limit = voiceAssertionProven ? hudAppearTimeout : hudAppearTimeoutWithoutSignal
        }
        if !abandoned && elapsed < limit {
            poll(false)
            return
        }

        let reason = abandoned ? "豆包收到单击但放弃了启动" : "豆包没有响应单击"
        let resendIndex: Int
        if case .resend(let n) = attempt { resendIndex = n + 1 } else { resendIndex = 1 }
        let maxResends = abandoned ? voiceStartMaxResendsAfterAbandon : voiceStartMaxResendsWithoutResponse
        guard resendIndex <= maxResends else {
            Logger.shared.warn("\(reason)，已补发 \(resendIndex - 1) 次，放弃本次启动")
            giveUpVoiceStart(noResponse: !abandoned)
            return
        }
        if abandoned {
            Logger.shared.warn("\(reason)（\(Int(elapsed * 1000))ms），\(voiceStartResendDelay)s 后原样补发第 \(resendIndex) 次")
            DispatchQueue.main.asyncAfter(deadline: .now() + voiceStartResendDelay) { [weak self] in
                self?.resendVoiceStartTap(attempt: .resend(resendIndex))
            }
            return
        }
        // 毫无反应：前台 App 常常根本没激活豆包（系统日志里没有 Activate Server）。
        // 把输入法切走再切回来，让它重新走一次激活，而不是动焦点。
        Logger.shared.warn("\(reason)（\(Int(elapsed * 1000))ms），切走再切回豆包后补发第 \(resendIndex) 次")
        bounceDoubaoInputSource { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.giveUpVoiceStart(noResponse: true)
                return
            }
            self.resendVoiceStartTap(attempt: .resend(resendIndex))
        }
    }

    /// 切到恢复目标（日常输入法）再切回豆包，各自等 TIS 生效，最后留出切换稳定期。
    private func bounceDoubaoInputSource(completion: @escaping (Bool) -> Void) {
        guard let away = restoreTargetFrom(previousInputSource) else {
            completion(false)
            return
        }
        let selectAway: () -> Bool = {
            (away.sourceID.flatMap { InputSourceManager.selectSource(byID: $0) } ?? false)
                || (away.kind == .method
                    ? InputSourceManager.selectMethod(byName: away.value)
                    : InputSourceManager.selectLayout(byName: away.value))
        }
        guard selectAway() else {
            completion(false)
            return
        }
        waitUntil({ [weak self] in self?.isInputSourceActive(away) ?? false }, timeout: 0.6) { [weak self] _ in
            guard let self = self, self.voiceTransitionInProgress else { return }
            guard self.setDoubaoIME() else {
                completion(false)
                return
            }
            self.waitUntil({ [weak self] in self?.isDoubaoIMEActive() ?? false }, timeout: 0.6) { [weak self] _ in
                guard let self = self, self.voiceTransitionInProgress else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.voiceTriggerAfterSwitchDelay) {
                    // 连续两次 TIS 切换可能乱序生效：切走那一下晚到，会把豆包又覆盖掉。
                    if self.isDoubaoIMEActive() {
                        completion(true)
                        return
                    }
                    Logger.shared.debug("切回豆包后被晚到的切换覆盖，重新选中豆包")
                    _ = self.setDoubaoIME()
                    self.waitUntil({ [weak self] in self?.isDoubaoIMEActive() ?? false }, timeout: 0.6) { ok in
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.voiceTriggerAfterSwitchDelay) {
                            completion(ok && self.isDoubaoIMEActive())
                        }
                    }
                }
            }
        }
    }

    private func waitUntil(
        _ isReady: @escaping () -> Bool,
        timeout: TimeInterval,
        deadline: Date? = nil,
        then completion: @escaping (Bool) -> Void
    ) {
        if isReady() {
            completion(true)
            return
        }
        let limit = deadline ?? Date(timeIntervalSinceNow: timeout)
        if Date() >= limit {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourcePollInterval) { [weak self] in
            self?.waitUntil(isReady, timeout: timeout, deadline: limit, then: completion)
        }
    }

    private func resendVoiceStartTap(attempt: VoiceStartAttempt) {
        guard voiceTransitionInProgress else { return }
        guard isDoubaoIMEActive() else {
            Logger.shared.warn("重试时当前输入法已不是豆包，放弃本次启动")
            doubaoVoiceActive = false
            finishVoiceTransition()
            return
        }
        fireVoiceStartTap(attempt: attempt)
    }

    /// 补救都救不回来：如实置为未启动，让下一次触发走干净的启动流程，
    /// 不留下「App 以为在录音、豆包其实没在录」的脏状态。
    private func giveUpVoiceStart(noResponse: Bool) {
        doubaoVoiceActive = false
        finishVoiceTransition()
        logVoiceStartFailureDiagnostics()
        // 别把用户扔在豆包输入法上：拉起失败时它只是个用不了的空壳，
        // 用户还得自己切回去才能打字。
        scheduleRestorePreviousIME(reason: "豆包语音启动失败")
        if noResponse {
            showAlert("豆包没有响应，请先点一下输入框，再按 \(voiceHotkeyLabel)")
        } else {
            showAlert("豆包语音没拉起来，请再按一次 \(voiceHotkeyLabel)")
        }
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
        let exitedDuringStartup = pendingActionTimer == nil && voiceSessionStartedAt.map {
            Date().timeIntervalSince($0) < voiceStartupFailureWindow
        } == true
        voiceSessionStartedAt = nil
        doubaoVoiceActive = false
        if exitedDuringStartup {
            Logger.shared.warn("豆包语音刚启动就自行退出，本次启动未保持录音。豆包在屏窗口: \(DoubaoVoiceHUDDetector.describeOnscreenWindows())")
            scheduleRestorePreviousIME(reason: "豆包语音启动后立即退出")
        } else {
            scheduleRestorePreviousIME(reason: "语音胶囊已消失（豆包自行结束了录音）")
        }
    }

    private func scheduleRestorePreviousIME(reason: String) {
        cancelRestoreImeTimer()

        // 录音已经结束（快捷键停止 / 外部活动 / 胶囊消失 / 启动失败），把媒体
        // 恢复交给 MediaPlaybackPauser：它会先等音频路由从通话档退回正常档
        // （豆包放掉麦克风、蓝牙耳机从 HFP 切回 A2DP）再真正发 play，否则音乐
        // 会先以通话档的偏大音量播出、路由切回时再跳一次。实测路由恢复晚于
        // 胶囊消失，所以媒体恢复不搭输入法收尾的时序，两条线各盯各的信号。
        mediaPauser.resumeAfterVoiceSessionWhenRouteSettles()

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
    /// 轮询链挂在 restoreImeTimer 上，新一轮语音动作会经 cancelRestoreImeTimer 整体取消。
    /// 媒体恢复不在这条链上（见 scheduleRestorePreviousIME 顶部）。
    private func scheduleRestorePoll(deadline: Date, quietTicks: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.restoreImeTimer = nil

            // 豆包全局语音可以在切回之前就开始新一段录音（输入法仍是豆包，不会有切换通知），
            // 录音中既不算静默，也绝不强制切走。
            let recording = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
            let ticks = (self.hudVisibleNow() || recording) ? 0 : quietTicks + 1
            if ticks >= self.imeFinalizeQuietTicks {
                Logger.shared.debug("豆包识别结果已上屏（胶囊已消失），恢复之前输入法")
                self.restorePreviousIME()
                return
            }
            if recording {
                self.scheduleRestorePoll(deadline: Date(timeIntervalSinceNow: self.imeFinalizeTimeout), quietTicks: 0)
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

    /// 优先按 sourceID 切，找不到再按名称。
    private func selectInputSource(_ target: InputSource) -> Bool {
        if let id = target.sourceID, InputSourceManager.selectSource(byID: id) { return true }
        switch target.kind {
        case .method: return InputSourceManager.selectMethod(byName: target.value)
        case .layout: return InputSourceManager.selectLayout(byName: target.value)
        }
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
        let ok = selectInputSource(target)
        switch target.kind {
        case .method:
            Logger.shared.debug("恢复之前输入法 method: \(target.value)(\(target.sourceID ?? "nil")), 结果: \(ok)")
        case .layout:
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

    private func waitForDoubaoIME(
        onTimeout: (() -> Void)? = nil,
        then onReady: @escaping () -> Void
    ) {
        let processAlreadyRunning = DoubaoVoiceHUDDetector.isIMEProcessRunning()
        let timeout = processAlreadyRunning ? inputSourceSwitchTimeout : inputSourceColdStartTimeout
        waitForInputSource(
            description: "豆包输入法",
            timeoutMessage: "豆包输入法没切过去，再按一次 \(voiceHotkeyLabel)",
            isReady: { [weak self] in
                guard let self = self else { return false }
                return self.isDoubaoIMEActive() && DoubaoVoiceHUDDetector.isIMEProcessRunning()
            },
            deadline: Date(timeIntervalSinceNow: timeout),
            onTimeout: onTimeout
        ) {
            self.ensureDoubaoAttachedThenTrigger(then: onReady)
        }
    }

    /// TIS 已是豆包且进程在跑之后再发 Option。
    ///
    /// 只对白名单 App 刷新焦点，不能无差别强制刷新：Claude 等 Electron 应用在 key window
    /// 换手后约 200ms 才异步「Deactivate」豆包，正好落在刚发出的 Option 上——
    /// 要么单击被吞，要么刚开的麦克风被掐断，胶囊直接跳到「识别优化中」。
    /// TIS 切换本身就会让前台 App 激活豆包（实测 <50ms）。
    private func ensureDoubaoAttachedThenTrigger(then onReady: @escaping () -> Void) {
        let switchReadyAt = DispatchTime.now() + voiceTriggerAfterSwitchDelay
        let proceed = {
            DispatchQueue.main.asyncAfter(
                deadline: switchReadyAt,
                execute: onReady
            )
        }

        nudgeForegroundAppIfNeeded(description: "豆包输入法", completion: proceed)
    }

    private func waitForNormalChineseInputMethod(onTimeout: (() -> Void)? = nil, then onReady: @escaping () -> Void) {
        waitForInputSource(
            description: "日常中文输入法",
            timeoutMessage: "切回中文输入法超时了",
            isReady: { [weak self] in self?.isNormalChineseInputMethodActive() ?? false },
            onTimeout: onTimeout
        ) {
            let bridgeReadyAt = DispatchTime.now() + self.inputMethodBridgeDelay
            self.nudgeForegroundAppIfNeeded(description: "日常中文输入法") {
                DispatchQueue.main.asyncAfter(deadline: bridgeReadyAt, execute: onReady)
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
        let members = Self.resolvedCycleInputSources()
        guard members.count >= 2 else {
            Logger.shared.warn("输入源轮换: 可用的轮换输入源不足两个，跳过本次切换")
            refreshHotkeyGate()
            return
        }

        let current = InputSourceManager.nowSource()
        Logger.shared.debug("输入源轮换: 当前 \(current?.value ?? "nil")(\(current?.sourceID ?? "nil"))")

        let target: InputSource
        if let index = members.firstIndex(where: { isInputSourceActive($0) }) {
            target = members[(index + 1) % members.count]
        } else {
            // 当前输入源不在轮换里（比如语音刚结束还停在豆包）：先去一个类型不同的，
            // 老的「中文 ↔ 英文」配置下就是：输入法 → 英文键盘、别的键盘布局 → 中文输入法。
            target = members.first { $0.kind != current?.kind } ?? members[0]
        }

        if isDoubaoInputSource(target) {
            cycleSwitchedToDoubaoAt = Date()
        }
        let ok = selectInputSource(target)
        Logger.shared.debug("输入源轮换: 切换到 \(target.value)(\(target.sourceID ?? "nil")), 结果: \(ok)")
        // TIS 切换可能只改了菜单栏、输入框没跟上（CJKV 输入法的老问题，切出中文输入法时
        // 输入框也可能还由它处理），两个方向都对白名单 App 刷新一次。
        if ok {
            waitForRestoredInputSource(target)
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
    static let didBecomeIdleNotification = Notification.Name("DoubaoVoiceController.didBecomeIdle")

    private func notifyIdleForAppUpdateIfNeeded() {
        guard !isBusyForAppUpdate else { return }
        NotificationCenter.default.post(name: Self.didBecomeIdleNotification, object: nil)
    }
}
