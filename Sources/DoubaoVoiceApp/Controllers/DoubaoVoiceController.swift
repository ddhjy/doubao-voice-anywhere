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
    private let editorFocusTimeout: TimeInterval = 2.5
    private let editorFocusPollInterval: TimeInterval = 0.05
    /// 轮换快捷键切到豆包后，这段时间内的切换通知都归这次手动切换（一次切换会来两三条通知）。
    private let cycleSwitchNotificationWindow: TimeInterval = 1.0
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
    /// 启动请求遇到旧会话时最多排队多久。到期只放弃启动，旧会话仍可继续整理。
    private let previousVoiceStartWaitTimeout: TimeInterval = 10.0

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
    /// 打字用的输入源（剔除了豆包唤起语音时闪过的中转），语音结束后的切回目标。
    private var typingSources = TypingSourceTracker()
    /// 轮换快捷键最近一次把输入法切成豆包的时间。这是用户主动切换，不是豆包全局语音在唤起自己，
    /// 随后的切换通知不能据此安排「语音结束后切回」。
    private var cycleSwitchedToDoubaoAt: Date?
    private var voiceTransitionInProgress: Bool = false

    // 以下状态只在事件监听线程访问（EventTapDelegate 回调都在该线程上）。

    private var voiceModifier = BareModifierTapTracker()
    private var cycleModifier = BareModifierTapTracker()

    // 以下属于主线程。按下时确定是否待机，避免停止键抬起时录音已结束又被当成启动。
    private enum NativeFnAction {
        case start(pid_t, InputSource?)
        case stopStarting, stopRecording
        case continueAfterFinish(VoiceInputTarget, downTime: TimeInterval)
    }
    private var nativeFnObserver: NativeFnTapObserver?
    private var nativeFnAction: NativeFnAction?
    var nativeFnMonitoringChanged: (() -> Void)?

    // 主线程写、事件监听线程读，用锁保护。
    private let voiceActiveLock = NSLock()
    private var _doubaoVoiceActive = false
    private var _voiceStartPending = false
    private var canInterruptVoiceWithKey: Bool {
        voiceActiveLock.lock()
        defer { voiceActiveLock.unlock() }
        return _doubaoVoiceActive || _voiceStartPending
    }
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

    /// 语音会话或切换尚未收尾：自动更新应等它结束再重启，避免打断录音。
    var isBusyForAppUpdate: Bool {
        doubaoVoiceActive || voiceTransitionInProgress || pendingActionTimer != nil
            || globalVoiceRecording || restoreImeTimer != nil
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
        var observesNativeFn = false

        /// Fn 被本 App 当作裸修饰键吞掉时，它额外发的 keyDown 179 要跟着一起吞。
        var usesFnAsBareModifier: Bool {
            (voice.bareModifier == .fn && !voiceDelegatedToDoubao && !observesNativeFn) || cycle.bareModifier == .fn
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
    private var restoreImeTimer: DispatchSourceTimer?
    private var finalizeQuietTicks = 0
    /// 完全没有收到录音或胶囊信号的启动失败，允许立即重试；正常录音要先完成提交。
    private var unansweredStartTarget: VoiceInputTarget?
    private struct VoiceContinuation {
        var target: VoiceInputTarget
        let requestedAt: Date
        let tapNotBefore: DispatchTime
    }
    private var pendingContinuation: VoiceContinuation?
    private var isPressingContinuation: Bool {
        guard case let .continueAfterFinish(_, downTime) = nativeFnAction else { return false }
        return ProcessInfo.processInfo.systemUptime - downTime <= NativeFnTapObserver.maxTap
    }
    private var voiceTapNotBefore: DispatchTime?
    private var voiceStartRequestedAt: TimeInterval? {
        didSet {
            voiceActiveLock.lock()
            _voiceStartPending = voiceStartRequestedAt != nil
            voiceActiveLock.unlock()
        }
    }
    private var voiceInputTarget: VoiceInputTarget?
    private var stopRequestedDuringStart = false
    private var voiceStartTapCount = 0
    private var startSawVoiceAssertion = false
    private var voiceOptionKey: VoiceOptionKey = .left

    // 语音胶囊探测（主线程访问）。
    // 观测到过胶囊，才用它的消失判定会话自行结束。恢复输入法还要检查录音断言。
    private var hudDetectionProven = false
    /// 未提供组合文本范围的编辑器，要确实见过本段语音的胶囊，才能用它消失来判断收尾。
    private var sessionHUDObserved = false
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

        let voiceLine: String
        if pendingContinuation != nil {
            voiceLine = "豆包整理完这段文字后会继续录音"
        } else if doubaoVoiceActive || globalVoiceRecording {
            voiceLine = "豆包语音 录音中，按 \(voiceHotkeyLabel) 结束"
        } else if unansweredStartTarget != nil {
            voiceLine = "豆包语音未启动，按 \(voiceHotkeyLabel) 重试"
        } else if restoreImeTimer != nil {
            voiceLine = "豆包正在整理文字"
        } else {
            voiceLine = "豆包语音 待机中，按 \(voiceHotkeyLabel) 开始"
        }
        return "\(label)\n\(voiceLine)"
    }

    /// 面向用户的说话快捷键写法，用于提示与日志（主线程调用）。
    private var voiceHotkeyLabel: String { GeneralSettings.voiceHotkey.displayString }

    // MARK: - 生命周期

    func setUp() {
        observeInputSourceChange()
        inputSourceObserver = InputSourceManager.observeInputSourceChanged { [weak self] in
            self?.observeInputSourceChange()
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
        stopNativeFnMonitoring()
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
        let nativeFn = !delegated && voice.bareModifier == .fn && GeneralSettings.nativeFnStop

        hotkeyStateLock.lock()
        let nativeFnChanged = _hotkeySnapshot.observesNativeFn != nativeFn
        let voiceChanged = _hotkeySnapshot.voice != voice || _hotkeySnapshot.voiceDelegatedToDoubao != delegated || nativeFnChanged
        let changed = voiceChanged || _hotkeySnapshot.cycle != cycle
            || _hotkeySnapshot.cycleInterceptionActive != active
        _hotkeySnapshot.voice = voice
        _hotkeySnapshot.cycle = cycle
        _hotkeySnapshot.cycleInterceptionActive = active
        _hotkeySnapshot.voiceDelegatedToDoubao = delegated
        _hotkeySnapshot.observesNativeFn = nativeFn
        hotkeyStateLock.unlock()

        if voiceChanged { cancelContinuation() }
        if nativeFnChanged { nativeFnMonitoringChanged?() }
        guard changed || !gateLoggedOnce else { return }
        gateLoggedOnce = true

        if delegated {
            Logger.shared.info("说话快捷键交给豆包输入法的全局语音处理，本 App 只旁观（用于说话时暂停媒体）")
        } else {
            Logger.shared.info("按 \(voice.displayString) 直接切到豆包，免按模式使用\(GeneralSettings.voiceOptionKey.label)")
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

    func updateNativeFnMonitoring() -> Bool {
        guard hotkeySnapshot.observesNativeFn else {
            stopNativeFnMonitoring()
            return true
        }
        let observer = nativeFnObserver ?? NativeFnTapObserver(optionPressed: { [weak self] key in
            self?.observeNativeOptionPress(key)
        }) { [weak self] edge, downTime in
            self?.observeNativeFn(edge, downTime: downTime)
        }
        nativeFnObserver = observer
        return observer.start()
    }

    func stopNativeFnMonitoring() {
        nativeFnObserver?.stop()
        nativeFnObserver = nil
        nativeFnAction = nil
        cancelContinuation()
    }

    private func observeNativeOptionPress(_ key: VoiceOptionKey) {
        let snapshot = hotkeySnapshot
        guard snapshot.observesNativeFn, !snapshot.captureActive, key == GeneralSettings.voiceOptionKey,
              !isBusyForAppUpdate, globalVoiceWatchTimer == nil else { return }
        let source = InputSourceManager.nowSource()
        globalVoiceReturnSource = isDoubaoInputSource(source) ? nil : source
        startGlobalVoiceWatch()
    }

    private func observeNativeFn(_ edge: BareModifierTapTracker.Edge, downTime: TimeInterval) {
        let snapshot = hotkeySnapshot
        guard snapshot.observesNativeFn, !snapshot.captureActive else {
            nativeFnAction = nil
            return
        }
        switch edge {
        case .pressed:
            nativeFnAction = nil
            if voiceStartRequestedAt != nil {
                nativeFnAction = .stopStarting
                return
            }
            // 按键时刻来自 HID，排除豆包为本次轻按自己短暂创建的录音断言。
            let pressed = Date(timeIntervalSinceNow: downTime - ProcessInfo.processInfo.systemUptime)
            let wasRecording = DoubaoVoiceHUDDetector.voiceInputAssertion(createdBefore: pressed)
            let active = doubaoVoiceActive || globalVoiceRecording
            let alreadyStopped = active && (voiceAssertionProven || globalVoiceRecording) && wasRecording == false
            if restoreImeTimer != nil || voiceTransitionInProgress || alreadyStopped {
                if let target = VoiceInputTarget() {
                    nativeFnAction = .continueAfterFinish(target, downTime: downTime)
                    Logger.shared.debug("收尾期间按下 Fn，等待轻按确认")
                }
                return
            }
            if active {
                nativeFnAction = .stopRecording
                Logger.shared.debug("录音中按下 Fn，由豆包处理原生结束键")
                return
            }
            guard !isBusyForAppUpdate, DoubaoVoiceHUDDetector.hudVisibility() == false,
                  wasRecording == false,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != "com.bytedance.inputmethod.doubaoime.settings" else { return }
            if globalVoiceWatchTimer != nil {
                globalVoiceReturnSource = nil
                stopGlobalVoiceWatch()
            }
            nativeFnAction = .start(app.processIdentifier, InputSourceManager.nowSource())
        case .tapped:
            let action = nativeFnAction
            nativeFnAction = nil
            switch action {
            case .stopStarting where voiceStartRequestedAt != nil:
                // 第二下已经送到了豆包。撤销尚未发出的启动/补发，避免额外的 Option 又开麦。
                // 未发过免按单击时，短暂的录音断言可能只来自第二下 Fn 自己的长按候选。
                let observedVoice = sessionHUDObserved || hudVisibleNow() || (voiceStartTapCount > 0 && startSawVoiceAssertion)
                cancelPendingActionTimer()
                scheduleRestorePreviousIME(reason: "启动期间收到原生停止键 Fn", afterRecording: observedVoice)
                finishVoiceTransition()
            case .stopStarting, .stopRecording:
                finishNativeRecording()
            case .continueAfterFinish(var target, let downTime):
                // 松键回调排队时上一段可能已经正常切回。仍把这次轻按交给当前编辑框。
                if !isBusyForAppUpdate {
                    guard target.pinFocusedEditor() else { return }
                    toggleDoubaoVoice()
                    return
                }
                let pressed = Date(timeIntervalSinceNow: downTime - ProcessInfo.processInfo.systemUptime)
                queueContinuation(at: target, requestedAt: pressed)
                // Option 停止或静音结束后，巡检可能还没发现关麦。
                finishNativeRecording()
            case let .start(pid, source):
                guard !isBusyForAppUpdate, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                sourceBeforeVoiceHotkey = source
                Logger.shared.debug("待机时轻按 Fn，启动豆包免按语音")
                toggleDoubaoVoice()
            case nil:
                break
            }
        case .cancelled:
            nativeFnAction = nil
        case .none:
            break
        }
    }

    private func finishNativeRecording() {
        if globalVoiceRecording {
            finishGlobalVoice()
        } else {
            markDoubaoVoiceStoppedByExternalActivity("收到豆包原生停止键 Fn")
        }
    }

    /// 设置窗口录制快捷键期间暂停全部拦截（主线程调用）。
    func setHotkeyCaptureActive(_ active: Bool) {
        hotkeyStateLock.lock()
        _hotkeySnapshot.captureActive = active
        hotkeyStateLock.unlock()
        if active { cancelContinuation() }
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
        let now = ProcessInfo.processInfo.systemUptime
        var swallow = false

        markPassthroughModifiersUsed(byModifierKeyCode: keycode, snapshot: snapshot)

        if !snapshot.observesNativeFn && snapshot.voice.matchesModifierKeyCode(keycode) {
            let edge = voiceModifier.update(hotkey: snapshot.voice, flags: flags, at: now)
            if snapshot.voiceDelegatedToDoubao {
                switch edge {
                case .pressed:
                    // 豆包在抬起时才切输入法，按下这一刻的输入源就是之后要切回的目标。
                    DispatchQueue.main.async { [weak self] in
                        self?.sourceBeforeVoiceHotkey = InputSourceManager.nowSource()
                    }
                case .tapped:
                    DispatchQueue.main.async { [weak self] in self?.watchDoubaoGlobalVoice() }
                case .cancelled:
                    DispatchQueue.main.async { [weak self] in self?.sourceBeforeVoiceHotkey = nil }
                case .none:
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
            let edge = cycleModifier.update(hotkey: snapshot.cycle, flags: flags, at: now)
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

        if canInterruptVoiceWithKey {
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    self?.stopVoiceForKey(keycode)
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

    /// 裸修饰键按着的时候来了别的输入，这一次就不算轻按了。
    /// `keyCode` 为 nil 表示来源是鼠标点击。
    private func markBareModifiersUsedWithOtherInput(keycode: Int64?, snapshot: HotkeySnapshot) {
        if !isOwnKeyCode(keycode, of: snapshot.voice) {
            voiceModifier.markUsedWithOtherInput()
        }
        if !isOwnKeyCode(keycode, of: snapshot.cycle) {
            cycleModifier.markUsedWithOtherInput()
        }
    }

    /// 别的修饰键动了：不吞的修饰键（⌃⌥⇧⌘）按着时就不算「单独点一下」了。
    /// Fn 是独占键，不参与这条判定。
    private func markPassthroughModifiersUsed(byModifierKeyCode keycode: Int64, snapshot: HotkeySnapshot) {
        if !snapshot.voice.swallowsEvent, !snapshot.voice.matchesModifierKeyCode(keycode) {
            voiceModifier.markUsedWithOtherInput()
        }
        if !snapshot.cycle.swallowsEvent, !snapshot.cycle.matchesModifierKeyCode(keycode) {
            cycleModifier.markUsedWithOtherInput()
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

    /// 豆包有时会再次切换输入法才真正打开麦克风，实测一次 Fn 到录音接近 3 秒。
    private let globalVoiceStartWindow: TimeInterval = 5.0
    private let globalVoicePollInterval: TimeInterval = 0.1
    private var globalVoiceWatchTimer: DispatchSourceTimer?
    private var globalVoiceStartDeadline: TimeInterval = 0
    private var globalVoiceRecording = false
    /// 这次唤起之前的输入源。只有确认录过音且仍在豆包里，才交给恢复计时器。
    private var globalVoiceReturnSource: InputSource?

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
        // 录音结束的采样可能先于停止键的抬起。已有的巡检或切回继续负责这段录音。
        guard globalVoiceWatchTimer == nil, restoreImeTimer == nil else { return }
        globalVoiceReturnSource = isDoubaoInputSource(pressedSource) ? nil : pressedSource
        startGlobalVoiceWatch()
    }

    /// 从别的输入法切到豆包：多半是豆包全局语音在唤起自己，开始巡检。
    /// 用户手动切到豆包也会走到这里，但没有录音就不会切回（见巡检超时分支）。
    private func detectDoubaoGlobalVoiceSwitch() {
        if let switchedAt = cycleSwitchedToDoubaoAt,
           Date().timeIntervalSince(switchedAt) < cycleSwitchNotificationWindow {
            return
        }
        guard !voiceTransitionInProgress, !doubaoVoiceActive, restoreImeTimer == nil,
              let source = currentTypingSource()
        else { return }
        // 两段语音间隔不到一个巡检周期时，先结清已经离开豆包的上一段。
        if globalVoiceRecording && !DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() {
            finishGlobalVoice(alreadyLeftSource: true)
        }
        // 快捷键回调和切换通知都可能先到。保留按下时的有效来源；
        // 快捷键没看到来源时，用本次真正进入豆包的通知补上。
        if globalVoiceReturnSource == nil ||
            (!globalVoiceRecording && ProcessInfo.processInfo.systemUptime >= globalVoiceStartDeadline) {
            globalVoiceReturnSource = source
        }
        startGlobalVoiceWatch()
    }

    private func startGlobalVoiceWatch() {
        globalVoiceStartDeadline = ProcessInfo.processInfo.systemUptime + globalVoiceStartWindow
        guard globalVoiceWatchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + globalVoicePollInterval, repeating: globalVoicePollInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let recording = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
            let visible = self.hudVisibleNow()
            if recording {
                self.observeGlobalRecording(hudVisible: visible)
                return
            }
            if self.globalVoiceRecording {
                if visible { self.sessionHUDObserved = true }
                self.finishGlobalVoice()
            } else if ProcessInfo.processInfo.systemUptime >= self.globalVoiceStartDeadline {
                // 没开始录音：可能是用户手动切到了豆包，保持现状不切回。
                self.globalVoiceReturnSource = nil
                self.stopGlobalVoiceWatch()
            }
        }
        timer.resume()
        globalVoiceWatchTimer = timer
    }

    private func observeGlobalRecording(hudVisible: Bool) {
        if !globalVoiceRecording {
            globalVoiceRecording = true
            sessionHUDObserved = false
            voiceInputTarget = VoiceInputTarget()
            _ = voiceInputTarget?.focus()
            Logger.shared.debug("豆包全局语音已开始")
            mediaPauser.pauseForVoiceSession()
        }
        if hudVisible { sessionHUDObserved = true }
    }

    private func finishGlobalVoice(alreadyLeftSource: Bool = false) {
        globalVoiceRecording = false
        let target = globalVoiceReturnSource
        globalVoiceReturnSource = nil
        if alreadyLeftSource {
            voiceInputTarget = nil
            mediaPauser.resumeAfterVoiceSessionWhenRouteSettles()
        } else {
            previousInputSource = target
            // 用户本来就在豆包里时只等整理完成，让轮换和更新在此期间也能避让。
            scheduleRestorePreviousIME(reason: "豆包全局语音已结束", afterRecording: true, restoreSource: target != nil)
        }
        stopGlobalVoiceWatch()
    }

    private func stopGlobalVoiceWatch() {
        globalVoiceWatchTimer?.cancel()
        globalVoiceWatchTimer = nil
        notifyIdleForAppUpdateIfNeeded()
    }

    // MARK: - 说话快捷键调度

    /// - Parameter afterRelease: 快捷键是抬起才触发的单独修饰键，按键已松开，无需再等。
    private func scheduleDoubaoToggle(afterRelease: Bool) {
        let releaseDelay = afterRelease ? 0 : actionAfterHotkeyDelay
        guard !voiceTransitionInProgress else {
            sourceBeforeVoiceHotkey = nil
            if voiceStartRequestedAt != nil && !stopRequestedDuringStart {
                stopRequestedDuringStart = true
            } else {
                queueContinuation(releaseDelay: releaseDelay)
            }
            return
        }
        if pendingActionTimer != nil, doubaoVoiceActive {
            queueContinuation(releaseDelay: releaseDelay)
            return
        }
        if doubaoVoiceActive, voiceAssertionProven, DoubaoVoiceHUDDetector.voiceInputAssertion() == false {
            queueContinuation(releaseDelay: releaseDelay)
            markDoubaoVoiceStoppedByExternalActivity("再次按快捷键时检测到上一段已关麦")
            return
        }
        cancelPendingActionTimer()
        if !doubaoVoiceActive {
            toggleDoubaoVoice(releaseDelay: releaseDelay)
            return
        }
        Logger.shared.debug("检测到说话快捷键 \(voiceHotkeyLabel)，\(releaseDelay)s 后停止豆包语音")
        // 恢复输入法会检查 pendingActionTimer，不会抢在停止动作前切走输入法。
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingActionTimer = nil
            // 按下时已经决定停止。豆包在松键等待期间自行结束时，不能反过来启动录音。
            guard self.doubaoVoiceActive else { return }
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
        finalizeQuietTicks = 0
        unansweredStartTarget = nil
    }

    private func queueContinuation(at target: VoiceInputTarget? = nil, requestedAt: Date = Date(), releaseDelay: TimeInterval = 0) {
        sourceBeforeVoiceHotkey = nil
        guard pendingContinuation == nil, var target = target ?? VoiceInputTarget() else { return }
        guard target.pinFocusedEditor() else {
            Logger.shared.debug("续录时原窗口没有编辑焦点")
            return
        }
        pendingContinuation = VoiceContinuation(target: target, requestedAt: requestedAt, tapNotBefore: .now() + releaseDelay)
        Logger.shared.debug("已收到续录请求，等待上一段语音整理完成")
    }

    private func cancelContinuation() {
        pendingContinuation = nil
        if case .continueAfterFinish = nativeFnAction { nativeFnAction = nil }
    }

    /// 豆包的临时模式也会自行切回。只有在豆包里已观察到收尾，才可跨过这次切换续录。
    /// 切走之后有的编辑器会留下无法通过 AX 检出的组合文字，再开麦会覆盖上一句。
    private func canFinishSession(in source: InputSource) -> Bool {
        if isDoubaoInputSource(source) { return true }
        guard finalizeQuietTicks >= startWaitQuietTicks, pendingContinuation != nil || isPressingContinuation,
              let previousInputSource else { return false }
        return TypingSourceTracker.isSame(source, previousInputSource)
    }

    private func cancelRestoreAfterSourceChange() {
        if pendingContinuation != nil || isPressingContinuation {
            showAlert("输入法已在确认上一段提交前切走，续录已取消")
        }
        cancelRestoreImeTimer()
        cancelContinuation()
        previousInputSource = nil
        notifyIdleForAppUpdateIfNeeded()
    }

    // MARK: - 豆包语音切换

    /// 等价于按一次说话快捷键：启动 / 停止豆包语音，菜单栏可直接调用。
    func toggleDoubaoVoice(releaseDelay: TimeInterval = 0) {
        if restoreImeTimer != nil {
            guard let target = unansweredStartTarget, isDoubaoIMEActive(),
                  DoubaoVoiceHUDDetector.voiceInputAssertion() == false,
                  DoubaoVoiceHUDDetector.hudVisibility() == false,
                  target.mayHaveMarkedText() != true else {
                queueContinuation(releaseDelay: releaseDelay)
                return
            }
            cancelContinuation()
            cancelRestoreImeTimer()
            Logger.shared.debug("上次启动未收到录音信号，在当前输入源重试")
        }
        guard !voiceTransitionInProgress else {
            Logger.shared.warn("豆包语音启动/停止仍在处理中，忽略本次触发")
            return
        }

        voiceTransitionInProgress = true
        if doubaoVoiceActive {
            stopDoubaoVoice()
        } else {
            voiceTapNotBefore = .now() + releaseDelay
            startDoubaoVoice()
        }
    }

    /// 仅做输入源切换（不触发语音），用于"快速切到豆包"。
    func switchToDoubaoInputSource() {
        guard !isDoubaoVoiceUnfinished() else { return }
        guard setDoubaoIME() else {
            showAlert("切不到豆包输入法，请确认已安装")
            return
        }
        waitForDoubaoIME {
            guard !self.isDoubaoVoiceUnfinished() else { return }
            InputSourceActivationNudge.shared.performIfNeeded(description: "豆包输入法")
        }
    }

    /// 立即恢复到上次记录的非豆包输入源。
    func restoreLastNonDoubaoInputSource() {
        cancelContinuation()
        cancelRestoreImeTimer()
        if previousInputSource == nil {
            previousInputSource = globalVoiceReturnSource ?? currentTypingSource()
        }
        restorePreviousIME(force: true)
        notifyIdleForAppUpdateIfNeeded()
    }

    private func startDoubaoVoice(continuingAt target: VoiceInputTarget? = nil) {
        voiceStartRequestedAt = ProcessInfo.processInfo.systemUptime
        voiceStartTapCount = 0
        startSawVoiceAssertion = false
        sessionHUDObserved = false
        voiceInputTarget = target ?? VoiceInputTarget()
        voiceOptionKey = GeneralSettings.voiceOptionKey
        voiceSessionStartedAt = nil
        // 音乐/视频在播时先暂停，与下面的输入法切换并行进行，不增加启动延迟；
        // 用户开口前媒体就能静下来。所有失败结束路径都会触发恢复（见
        // scheduleRestorePreviousIME 与 finishVoiceTransition 两个收口）。
        mediaPauser.pauseForVoiceSession()
        let source = sourceBeforeVoiceHotkey ?? InputSourceManager.nowSource()
        if target == nil && (!isDoubaoInputSource(source) || previousInputSource == nil) {
            previousInputSource = restoreTargetFrom(source)
        }
        sourceBeforeVoiceHotkey = nil

        voiceStartIsCold = !DoubaoVoiceHUDDetector.isIMEProcessRunning()
        if voiceStartIsCold {
            Logger.shared.debug("豆包输入法进程还没起来，按冷启动放宽胶囊等待")
        }

        waitForPreviousVoiceToFinish {
            // 紧接着输入源轮换按 Fn 时，等已有面板归还焦点，再检查原窗口。
            InputSourceActivationNudge.shared.whenCurrentRefreshFinishes {
                self.whenVoiceEditorReady { self.prepareInputSourceForVoice() }
            }
        }
    }

    private func prepareInputSourceForVoice() {
        if !isDoubaoIMEActive() && !setDoubaoIME() {
            showAlert("切不到豆包输入法，请确认已安装")
            finishVoiceTransition()
            return
        }
        waitForDoubaoIME(onTimeout: { self.cancelVoiceStartAtTarget("等待豆包输入法启动超时") }) {
            self.logVoiceStartLatency(stage: "豆包输入源已选中，进程已就绪")
            // 语音写回依赖原编辑框的 IMK 上下文。即使是白名单应用，这里也不借用 key window。
            let sourceReadyAt = DispatchTime.now() + self.voiceTriggerAfterSwitchDelay
            self.voiceTapNotBefore = max(self.voiceTapNotBefore ?? sourceReadyAt, sourceReadyAt)
            self.fireVoiceStartTap(attempt: .initial)
        }
    }

    private func whenVoiceEditorReady(deadline: TimeInterval? = nil, then ready: @escaping () -> Void) {
        guard voiceStartRequestedAt != nil, !handleStopDuringStart() else { return }
        switch voiceInputTarget?.focus() {
        case .changed:
            cancelVoiceStartAtTarget("输入焦点已经离开原窗口")
        case .waitingForEditor:
            let now = ProcessInfo.processInfo.systemUptime
            let limit = deadline ?? now + editorFocusTimeout
            guard now < limit else {
                cancelVoiceStartAtTarget("等待原窗口的编辑框就绪超时")
                showAlert("请把光标放在输入框，再按 \(voiceHotkeyLabel)")
                return
            }
            if deadline == nil { logVoiceStartLatency(stage: "等待原窗口的编辑框取得焦点") }
            DispatchQueue.main.asyncAfter(deadline: .now() + editorFocusPollInterval) { [weak self] in
                self?.whenVoiceEditorReady(deadline: limit, then: ready)
            }
        case .ready:
            if deadline != nil { logVoiceStartLatency(stage: "原窗口的编辑框已取得焦点") }
            ready()
        case .unavailable, nil:
            // 未提供辅助功能文本信息的自绘编辑器，沿用原有的发键与录音确认。
            logVoiceStartLatency(stage: "系统未提供编辑控件，保留当前焦点并检查豆包录音")
            ready()
        }
    }

    private func cancelVoiceStartAtTarget(_ reason: String) {
        Logger.shared.debug("\(reason)，取消本次语音启动")
        scheduleRestorePreviousIME(reason: reason)
        finishVoiceTransition()
    }

    /// 在旧胶囊仍显示「识别优化中」时发 Option，不会开始一段新录音。
    /// 必须先等旧会话完全结束；只有遇到旧会话才等待，正常热启动不增加延迟。
    private func waitForPreviousVoiceToFinish(
        requireQuietPeriod: Bool = false,
        observing attempt: VoiceStartAttempt? = nil,
        deadline: Date? = nil,
        quietTicks: Int = 0,
        then completion: @escaping () -> Void
    ) {
        guard voiceStartRequestedAt != nil else { return }
        let recording = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
        if attempt != nil, recording { startSawVoiceAssertion = true }
        guard !handleStopDuringStart() else { return }
        if let attempt, recording {
            // 启动前已经排除了旧会话。选中豆包后出现的录音属于本次启动，
            // 包括尚未发第一击就开麦的情形；此时等待胶囊消失会等掉整段录音。
            guard isDoubaoIMEActive() else {
                cancelVoiceStartAtTarget("确认录音前输入法已改变")
                return
            }
            whenVoiceEditorReady { self.verifyVoiceStarted(tappedAt: Date(), attempt: attempt) }
            return
        }
        let visible = hudVisibleNow()
        if attempt != nil, visible { sessionHUDObserved = true }
        let busy = visible || recording
        if !busy && !requireQuietPeriod {
            completion()
            return
        }
        if deadline == nil {
            Logger.shared.debug("启动前上一段豆包语音尚未收尾，等待胶囊完全消失后再启动")
        }
        let ticks = busy ? 0 : quietTicks + 1
        if ticks >= startWaitQuietTicks {
            completion()
            return
        }
        let limit = deadline ?? Date(timeIntervalSinceNow: previousVoiceStartWaitTimeout)
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
                observing: attempt,
                deadline: limit,
                quietTicks: ticks,
                then: completion
            )
        }
    }

    /// 同步已经出现的语音会话。胶囊可见只证明会话存在，不区分录音与识别优化；
    /// 因此启动前的旧胶囊必须由 waitForPreviousVoiceToFinish 排除。
    private func confirmVoiceSessionStarted(signal: String) {
        guard isDoubaoIMEActive() else {
            cancelVoiceStartAtTarget("确认录音时输入法已改变")
            return
        }
        // 保留接收语音时记录的编辑框，收尾仍须检查那个控件的组合文本。
        var target = voiceInputTarget
        if case .changed = target?.focus() {
            cancelVoiceStartAtTarget("确认录音时焦点已离开原窗口")
            return
        }
        doubaoVoiceActive = true
        let startedAt = Date()
        voiceSessionStartedAt = startedAt
        logVoiceStartLatency(stage: "\(signal)，发送启动单击 \(voiceStartTapCount) 次")
        finishVoiceTransition()
        startHudWatch()
        Logger.shared.debug("豆包语音会话已启动，等待再次按 \(voiceHotkeyLabel) 停止")
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
        var editorPending = false
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
        KeyboardSimulator.tapOption(voiceOptionKey, if: { [weak self] in
            guard let self = self, self.voiceTransitionInProgress, !self.stopRequestedDuringStart else { return false }
            guard self.isDoubaoIMEActive() else {
                Logger.shared.debug("启动发键前输入法已改变，取消本次语音启动")
                self.finishVoiceTransition()
                return false
            }
            switch self.voiceInputTarget?.focus() {
            case .changed:
                self.cancelVoiceStartAtTarget("发键前焦点已离开原窗口")
                return false
            case .waitingForEditor:
                editorPending = true
                return false
            default:
                break
            }
            // 等待修饰键释放、排队期间，先前的 Option 可能才被豆包处理。
            // 这次检查必须贴着真正的 key down，而不是仅在调用 tap 时检查。
            // 豆包正在启动（胶囊还没画出来）时再发一击会把它停掉。
            guard !DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() else {
                Logger.shared.debug("发键前检测到豆包已开麦，跳过单击并确认录音")
                self.startSawVoiceAssertion = true
                doubaoAlreadyStarting = true
                return false
            }
            guard !self.hudVisibleNow() else { return false }
            self.voiceStartTapCount += 1
            self.logVoiceStartLatency(stage: "发送第 \(self.voiceStartTapCount) 次启动单击")
            return true
        }, releaseWhen: releaseWhen) { [weak self] sent in
            guard let self = self, self.voiceTransitionInProgress, !self.handleStopDuringStart(atSelectedSource: true) else { return }
            if editorPending {
                self.whenVoiceEditorReady { self.fireVoiceStartTap(attempt: attempt) }
                return
            }
            if !sent, attempt == .initial, !doubaoAlreadyStarting {
                self.waitForPreviousVoiceToFinish(requireQuietPeriod: true, observing: attempt) {
                    self.fireVoiceStartTap(attempt: attempt)
                }
                return
            }
            self.verifyVoiceStarted(tappedAt: Date(), attempt: attempt, sawAssertion: assertionSeenAt != nil)
        }
    }

    private func handleStopDuringStart(atSelectedSource: Bool = false) -> Bool {
        guard stopRequestedDuringStart else { return false }
        if voiceStartTapCount > 0 {
            stopDoubaoVoice()
        } else if startSawVoiceAssertion || (atSelectedSource && isDoubaoIMEActive() && DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()) {
            // 豆包可能在键盘队列等待期间自行开麦。停止前再查断言，避免把已结束的会话重新开启。
            stopDoubaoVoice(requireAssertion: true)
        } else {
            cancelVoiceStartAtTarget("准备期间收到停止键")
        }
        return true
    }

    private func stopVoiceForKey(_ keycode: Int64) {
        if voiceStartRequestedAt != nil {
            stopRequestedDuringStart = true
            return
        }
        guard doubaoVoiceActive, !voiceTransitionInProgress else { return }
        stopHudWatch()
        voiceTransitionInProgress = true
        // 豆包通常自己处理普通键。给它一个巡检周期，只在麦克风仍打开时补发停止键。
        DispatchQueue.main.asyncAfter(deadline: .now() + imeFinalizePollInterval) {
            self.stopDoubaoVoice(reason: "检测到键盘输入 \(keycode) 结束豆包语音", requireAssertion: true)
        }
    }

    private func stopDoubaoVoice(reason: String = "豆包语音输入已停止", requireAssertion: Bool = false) {
        stopHudWatch()
        voiceSessionStartedAt = nil
        sourceBeforeVoiceHotkey = nil
        let wasRecording = doubaoVoiceActive || (voiceStartRequestedAt != nil && startSawVoiceAssertion)
            || DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()

        // 停止键排队期间豆包可能已经自行停止。发键前核对麦克风，防止把它重新开启。
        KeyboardSimulator.tapOption(voiceOptionKey, if: {
            guard self.isDoubaoIMEActive() else { return false }
            let visible = self.hudVisibleNow()
            if visible { self.sessionHUDObserved = true }
            if DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld() { return true }
            return !requireAssertion && !self.voiceAssertionProven && visible
        }) { sent in
            if sent {
                Logger.shared.debug("已发送停止单击（\(self.voiceOptionKey.label)），等待豆包识别优化")
            }
            self.doubaoVoiceActive = false
            self.scheduleRestorePreviousIME(reason: reason, afterRecording: wasRecording)
            self.finishVoiceTransition()
        }
    }

    private func finishVoiceTransition() {
        stopRequestedDuringStart = false
        voiceTapNotBefore = nil
        voiceStartRequestedAt = nil
        if !doubaoVoiceActive { voiceInputTarget = nil }
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
        guard doubaoVoiceActive, !voiceTransitionInProgress else { return }
        stopHudWatch()
        voiceSessionStartedAt = nil
        doubaoVoiceActive = false
        scheduleRestorePreviousIME(reason: reason, afterRecording: true)
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

    /// 切换前已排除旧胶囊。准备第一击和补发时，都要接管这期间出现的录音。
    private func fireVoiceStartTap(attempt: VoiceStartAttempt) {
        waitForPreviousVoiceToFinish(observing: attempt) {
            self.continueVoiceStart(attempt: attempt)
        }
    }

    private func verifyVoiceStarted(
        tappedAt: Date, attempt: VoiceStartAttempt, sawAssertion: Bool = false, hudVisibleSince: Date? = nil
    ) {
        guard voiceTransitionInProgress, !handleStopDuringStart(atSelectedSource: true) else { return }
        let elapsed = Date().timeIntervalSince(tappedAt)
        let assertionHeld = DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
        if assertionHeld || sawAssertion { startSawVoiceAssertion = true }
        if (assertionHeld || sawAssertion) && !voiceAssertionProven {
            voiceAssertionProven = true
            Logger.shared.info("豆包语音电源断言探测生效")
        }
        let visibleSince = hudVisibleNow() ? (hudVisibleSince ?? Date()) : nil
        if visibleSince != nil { sessionHUDObserved = true }
        let poll = { [weak self] (saw: Bool) in
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.hudPollInterval ?? 0.06)) {
                self?.verifyVoiceStarted(tappedAt: tappedAt, attempt: attempt, sawAssertion: saw, hudVisibleSince: visibleSince)
            }
        }

        if assertionHeld {
            // 连续两次采样确认录音，排除 20–30ms 就释放的启动尝试。胶囊绘制可以更晚。
            if sawAssertion {
                confirmVoiceSessionStarted(signal: "已确认正在录音")
            } else {
                poll(true)
            }
            return
        }

        // 仅在整次运行都探测不到录音断言时，才退回用持续可见的胶囊确认。
        // 已知可探测时，没有断言的胶囊可能已经是「识别优化中」。
        if !voiceAssertionProven, let visibleSince {
            if Date().timeIntervalSince(visibleSince) >= hudAppearTimeout {
                confirmVoiceSessionStarted(signal: "仅观察到持续可见的语音胶囊")
            } else {
                poll(false)
            }
            return
        }
        let abandoned = sawAssertion || hudVisibleSince != nil || (voiceAssertionProven && visibleSince != nil)
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
        // 重试只重新触发语音。切走再切回会打断刚建立的输入上下文，也可能覆盖用户刚选的输入法。
        Logger.shared.warn("\(reason)（\(Int(elapsed * 1000))ms），\(voiceStartResendDelay)s 后原样补发第 \(resendIndex) 次")
        DispatchQueue.main.asyncAfter(deadline: .now() + voiceStartResendDelay) { [weak self] in
            self?.resendVoiceStartTap(attempt: .resend(resendIndex))
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
        logVoiceStartFailureDiagnostics()
        // 别把用户扔在豆包输入法上：拉起失败时它只是个用不了的空壳，
        // 用户还得自己切回去才能打字。
        let unansweredTarget = noResponse && !startSawVoiceAssertion && !sessionHUDObserved ? voiceInputTarget : nil
        scheduleRestorePreviousIME(reason: "豆包语音启动失败")
        if restoreImeTimer != nil { unansweredStartTarget = unansweredTarget }
        finishVoiceTransition()
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

    /// 静音、Esc 等也能结束录音。麦克风已释放时进入整理阶段，胶囊可能仍在屏。
    private func startHudWatch() {
        stopHudWatch()
        guard hudDetectionProven || voiceAssertionProven else { return }

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
        let visible = hudVisibleNow()
        if visible { sessionHUDObserved = true }
        let recording = DoubaoVoiceHUDDetector.voiceInputAssertion()
        let stillActive = voiceAssertionProven ? recording != false : (recording == true || visible)
        if stillActive {
            hudWatchMissCount = 0
            return
        }
        hudWatchMissCount += 1
        guard hudWatchMissCount >= hudWatchMissThreshold else { return }

        stopHudWatch()
        let exitedDuringStartup = !visible && pendingActionTimer == nil && voiceSessionStartedAt.map {
            Date().timeIntervalSince($0) < voiceStartupFailureWindow
        } == true
        voiceSessionStartedAt = nil
        doubaoVoiceActive = false
        if exitedDuringStartup {
            Logger.shared.warn("豆包语音刚启动就自行退出，本次启动未保持录音。豆包在屏窗口: \(DoubaoVoiceHUDDetector.describeOnscreenWindows())")
            scheduleRestorePreviousIME(reason: "豆包语音启动后立即退出", afterRecording: true)
        } else {
            scheduleRestorePreviousIME(reason: "检测到豆包已结束录音", afterRecording: true)
        }
    }

    private func scheduleRestorePreviousIME(reason: String, afterRecording: Bool = false, restoreSource: Bool = true) {
        cancelRestoreImeTimer()
        let inputTarget = voiceInputTarget
        voiceInputTarget = nil

        // 录音已经结束（快捷键停止 / 外部活动 / 胶囊消失 / 启动失败），把媒体
        // 恢复交给 MediaPlaybackPauser：它会先等音频路由从通话档退回正常档
        // （豆包放掉麦克风、蓝牙耳机从 HFP 切回 A2DP）再真正发 play，否则音乐
        // 会先以通话档的偏大音量播出、路由切回时再跳一次。实测路由恢复晚于
        // 胶囊消失，所以媒体恢复不搭输入法收尾的时序，两条线各盯各的信号。
        mediaPauser.resumeAfterVoiceSessionWhenRouteSettles()

        if let source = InputSourceManager.nowSource(), !canFinishSession(in: source) {
            cancelRestoreAfterSourceChange()
            return
        }
        Logger.shared.debug("\(reason)，等待豆包整理文字")
        var sawRecording = false
        var sawFinishingHUD = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + imeFinalizePollInterval, repeating: imeFinalizePollInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let source = InputSourceManager.nowSource() else {
                self.finalizeQuietTicks = 0
                sawRecording = false
                return
            }
            guard self.canFinishSession(in: source) else {
                self.cancelRestoreAfterSourceChange()
                return
            }

            // 任何忙信号都重新计数。连续空闲只用于滤掉胶囊换形的闪烁，整理本身没有时限。
            let visible = DoubaoVoiceHUDDetector.hudVisibility()
            let recording = DoubaoVoiceHUDDetector.voiceInputAssertion()
            if visible == true {
                self.sessionHUDObserved = true
                self.unansweredStartTarget = nil
                if recording == false { sawFinishingHUD = true }
            }
            if recording == true {
                self.finalizeQuietTicks = 0
                // 轻按原生 Fn 可能只在按住时短暂开麦。持续录音才接管，上一轮仍占麦就继续等它提交。
                if (self.hotkeySnapshot.observesNativeFn || self.pendingContinuation != nil)
                    && (!sawRecording || self.isPressingContinuation) {
                    sawRecording = true
                    return
                }
                if let request = self.pendingContinuation,
                   DoubaoVoiceHUDDetector.voiceInputAssertion(createdBefore: request.requestedAt) != false { return }
                let activeTarget = self.pendingContinuation?.target ?? inputTarget
                self.cancelContinuation()
                self.resumeRecordingWatch(inputTarget: activeTarget, hudVisible: visible == true)
                return
            }
            sawRecording = false
            guard visible == false, recording == false else {
                self.finalizeQuietTicks = 0
                return
            }
            let marked = inputTarget?.mayHaveMarkedText()
            if marked == true { self.unansweredStartTarget = nil }
            // 两种收尾信号都无法观察时，保留输入法；用户仍可从系统或菜单手动切回。
            let canConfirmEnd = !afterRecording || self.sessionHUDObserved || marked == false
                || !DoubaoVoiceHUDDetector.isIMEProcessRunning()
            guard marked != true, canConfirmEnd else {
                self.finalizeQuietTicks = 0
                return
            }
            self.finalizeQuietTicks += 1
            // 已见过关麦后的胶囊，且仍在同一输入源，连续确认空闲后即可续录。
            // 最后一段切回输入法仍走原来的完整静默窗口。
            let readyToContinue = self.pendingContinuation != nil && sawFinishingHUD
                && self.isDoubaoInputSource(source) && self.finalizeQuietTicks >= self.startWaitQuietTicks
            guard (readyToContinue || self.finalizeQuietTicks >= self.imeFinalizeQuietTicks),
                  !self.isPressingContinuation else { return }
            self.completeVoiceFinalization(in: source, restoreSource: restoreSource)
        }
        restoreImeTimer = timer
        timer.resume()
    }

    private func completeVoiceFinalization(in source: InputSource, restoreSource: Bool) {
        cancelRestoreImeTimer()
        Logger.shared.debug("豆包语音胶囊已消失，未检测到待提交文字")
        if var request = pendingContinuation {
            pendingContinuation = nil
            switch request.target.focus() {
            case .ready, .unavailable:
                if !restoreSource { previousInputSource = source }
                voiceTapNotBefore = request.tapNotBefore
                voiceTransitionInProgress = true
                Logger.shared.debug("上一段已整理完成，在原输入框开始下一段语音")
                startDoubaoVoice(continuingAt: request.target)
                return
            case .changed, .waitingForEditor:
                Logger.shared.debug("输入焦点已离开续录时的编辑框，取消续录")
            }
        }
        if restoreSource { restorePreviousIME() }
        notifyIdleForAppUpdateIfNeeded()
    }

    private func resumeRecordingWatch(inputTarget: VoiceInputTarget?, hudVisible: Bool) {
        cancelRestoreImeTimer()
        if GeneralSettings.voiceHandledByDoubao {
            // 两段之间输入法没变。沿用切回目标，从新一段实际录音的编辑框观察文字。
            globalVoiceReturnSource = previousInputSource
            observeGlobalRecording(hudVisible: hudVisible)
            startGlobalVoiceWatch()
        } else {
            // 停止键或鼠标点击没让麦克风关闭，仍允许用户按 Fn 停止这一段。
            voiceInputTarget = inputTarget
            voiceAssertionProven = true
            doubaoVoiceActive = true
            mediaPauser.pauseForVoiceSession()
            startHudWatch()
        }
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
        isDoubaoInputSource(InputSourceManager.nowSource())
    }

    /// 轮换和语音后恢复共用。切入和切出 CJKV 输入法都可能需要刷新白名单应用的输入框。
    private func selectInputSource(_ target: InputSource) -> Bool {
        let previousSourceNeededNudge = InputSourceManager.currentSourceNeedsActivationNudge()
        let ok: Bool
        if let id = target.sourceID, InputSourceManager.selectSource(byID: id) {
            ok = true
        } else {
            switch target.kind {
            case .method: ok = InputSourceManager.selectMethod(byName: target.value)
            case .layout: ok = InputSourceManager.selectLayout(byName: target.value)
            }
        }
        if ok {
            confirmTypingSource(target)
            waitForRestoredInputSource(target, previousSourceNeededNudge: previousSourceNeededNudge)
        }
        return ok
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
        return currentTypingSource() ?? Self.resolvedNormalChineseInputSource()
    }

    // MARK: - 打字输入源

    /// 系统通知输入源变了：交给 `TypingSourceTracker` 判断它算不算打字用的输入源。
    private func observeInputSourceChange() {
        guard let source = InputSourceManager.nowSource() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasDoubao = typingSources.doubaoActive
        let observed = isDoubaoInputSource(source) ? nil : source
        logTypingSourceEvents(typingSources.observe(observed, at: now))
        if restoreImeTimer != nil && !canFinishSession(in: source) {
            Logger.shared.debug("已离开豆包输入法，取消上一段语音的待切回操作")
            cancelRestoreAfterSourceChange()
        }
        // 双键模式下右 Option 仍可从其他输入源直接唤起豆包，也要跟踪它的切回目标。
        let delegated = GeneralSettings.voiceHandledByDoubao
        guard delegated || (hotkeySnapshot.observesNativeFn && globalVoiceWatchTimer != nil) else { return }

        if !wasDoubao && typingSources.doubaoActive {
            if !delegated, case .start = nativeFnAction { return }
            detectDoubaoGlobalVoiceSwitch()
        } else if wasDoubao && !typingSources.doubaoActive {
            // 豆包自己切回、或用户手动离开，都结束本轮对输入源的控制。若等到
            // 定时器触发才检查，用户可能已经从另一个输入源按 Fn 开启了下一段。
            if globalVoiceRecording {
                globalVoiceReturnSource = nil
            } else if delegated && globalVoiceWatchTimer != nil {
                // 还没开麦就离开：豆包有时会经另一个输入源重试一次。只在中转窗口内
                // 保留第一次的来源，否则这次手动切换会污染下一段录音的恢复目标。
                globalVoiceStartDeadline = min(globalVoiceStartDeadline, now + TypingSourceTracker.transientWindow)
            }
        }
    }

    /// 本 App 自己切过去的输入源（轮换、语音后切回）直接算数。
    private func confirmTypingSource(_ source: InputSource) {
        guard !isDoubaoInputSource(source) else { return }
        logTypingSourceEvents(typingSources.confirm(source, at: ProcessInfo.processInfo.systemUptime))
        // 上次只看到了系统切换，还没确认录音。用户主动选了打字输入源，
        // 后续再按 Fn 应从这个新选择开始观察。
        if globalVoiceWatchTimer != nil && !globalVoiceRecording {
            globalVoiceReturnSource = nil
            stopGlobalVoiceWatch()
        }
    }

    private func currentTypingSource() -> InputSource? {
        typingSources.current
    }

    private func logTypingSourceEvents(_ events: [TypingSourceTracker.Event]) {
        for event in events {
            switch event {
            case .adopted(let source):
                Logger.shared.debug("记录打字输入源 \(source.kind.rawValue): \(source.value) (\(source.sourceID ?? "nil"))")
            case .discarded(let source, let heldFor, let kept):
                Logger.shared.debug("输入源 \(source.value) 只停留 \(String(format: "%.2f", heldFor))s 就切到了豆包，不记为打字输入源，仍是 \(kept.value)")
            }
        }
    }

    /// - Parameter force: true 表示用户显式要求恢复（菜单动作），跳过所有守卫。
    private func restorePreviousIME(force: Bool = false) {
        if !force {
            if isDoubaoInputSource(previousInputSource) {
                // 原本就在豆包中使用原生免按键，续录仍沿用第一段的输入源。
                previousInputSource = nil
                return
            }
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
            onTimeout: onTimeout,
            onReady: onReady
        )
    }

    private func waitForRestoredInputSource(_ target: InputSource, previousSourceNeededNudge: Bool) {
        waitForInputSource(
            description: "恢复输入源 \(target.value)",
            timeoutMessage: "切回 \(target.value) 超时了",
            isReady: { [weak self] in self?.isInputSourceActive(target) ?? false }
        ) {
            guard !self.isDoubaoVoiceUnfinished() else { return }
            InputSourceActivationNudge.shared.performIfNeeded(
                description: "切换输入源 \(target.value)",
                previousSourceNeededNudge: previousSourceNeededNudge
            )
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

    // MARK: - 输入源轮换

    private func toggleNormalInputSource() {
        if voiceStartRequestedAt != nil {
            stopRequestedDuringStart = true
            return
        }
        // 拦截门开启才会走到这里；解析结果仍可能在拦截后一瞬间变化，做兜底检查。
        let members = Self.resolvedCycleInputSources()
        guard members.count >= 2 else {
            Logger.shared.warn("输入源轮换: 可用的轮换输入源不足两个，跳过本次切换")
            refreshHotkeyGate()
            return
        }

        let current = InputSourceManager.nowSource()

        // 语音还没收尾（在录音，或识别结果还没上屏）时切走输入法，没上屏的字会丢。
        if isDoubaoInputSource(current), isDoubaoVoiceUnfinished() {
            Logger.shared.debug("输入源轮换: 豆包语音尚未收尾，忽略本次切换")
            return
        }
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
    }

    /// 豆包这一段语音还占着输入法：本 App 发起的会话在进行、豆包在录音，或已安排的切回还没执行。
    private func isDoubaoVoiceUnfinished() -> Bool {
        doubaoVoiceActive || voiceTransitionInProgress || pendingActionTimer != nil
            || restoreImeTimer != nil || globalVoiceRecording
            || DoubaoVoiceHUDDetector.isVoiceInputAssertionHeld()
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
