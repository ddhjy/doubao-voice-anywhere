import CoreGraphics
import Foundation

/// 豆包「免按模式」绑定的 Option 键。左右两侧的虚拟键码和设备修饰位不同。
enum VoiceOptionKey: Int {
    case left = 58
    case right = 61

    var label: String { self == .left ? "左 Option" : "右 Option" }
    fileprivate var deviceMask: UInt64 { self == .left ? 0x20 : 0x40 }
}

/// 单击会话开始时选定的 Option 键，抬起后核对同一侧的修饰键状态。
enum KeyboardSimulator {

    /// 合成事件的自识别标记（"DVAP"）。
    ///
    /// 我们自己发的 Option 单击会绕回本 App 的 event tap。用户一旦把某个快捷键
    /// 设成单独点 Option，这一击就会被当成用户按键，触发语音又发一击，来回递归。
    /// 打上标记，事件回调认出来直接透传。
    private static let syntheticMarker: Int64 = 0x4456_4150
    private static let foreignModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskSecondaryFn, .maskAlphaShift,
        .maskNumericPad, .maskHelp,
    ]

    /// 是不是本 App 自己合成的事件。
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    private static let optionTapHoldDuration: TimeInterval = 0.05
    /// 自适应按住：豆包把 Option 按下当作「长按说话」候选，抬起时录音面板若还没打开，
    /// 就按「长按取消」处理，刚开的录音被掐掉；按住超过约 200ms 又会被当成长按，
    /// 松开即停止。所以等豆包确认开始启动后再松开，并且绝不超过上限。
    private static let adaptiveHoldPollInterval: TimeInterval = 0.01
    private static let adaptiveHoldMinimum: TimeInterval = 0.04
    private static let adaptiveHoldMaximum: TimeInterval = 0.17
    private static let optionReleaseSettleDuration: TimeInterval = 0.03
    private static let optionReleaseRetryCount = 8

    private static var isTapInProgress = false
    private struct PendingTap {
        let key: VoiceOptionKey
        let shouldSend: () -> Bool
        /// 非 nil 时按住直到它返回 true（受最短 / 最长按住时长约束）。
        let releaseWhen: (() -> Bool)?
        let completion: (Bool) -> Void
    }
    private static var pendingTaps: [PendingTap] = []

    private static let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// 明确指定按键的左右侧与按下状态，避免会话中残留的 Fn 等修饰键混入事件。
    private static func postOption(_ key: VoiceOptionKey, isDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: CGKeyCode(key.rawValue),
            keyDown: isDown
        ) else {
            Logger.shared.error("无法创建豆包语音按键事件")
            return
        }

        event.type = .flagsChanged
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        if !event.flags.intersection(foreignModifiers).isEmpty {
            Logger.shared.warn("合成单击带上了无关修饰键（flags=\(formatFlags(event.flags.rawValue))），已清除")
        }
        event.flags = isDown ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | key.deviceMask) : []
        event.post(tap: .cghidEventTap)
    }

    /// 模拟一次 Option 的"轻按"：按下 -> 保持 -> 抬起。
    /// `releaseWhen` 为 nil 时固定按住 `optionTapHoldDuration`。
    private static func tapOptionOnce(_ key: VoiceOptionKey, releaseWhen: (() -> Bool)? = nil, completion: (() -> Void)? = nil) {
        postOption(key, isDown: true)
        let release = {
            postOption(key, isDown: false)
            confirmOptionReleased(key, attemptsLeft: optionReleaseRetryCount, completion: completion)
        }
        guard let releaseWhen = releaseWhen else {
            DispatchQueue.main.asyncAfter(deadline: .now() + optionTapHoldDuration, execute: release)
            return
        }
        let pressedAt = ProcessInfo.processInfo.systemUptime
        func poll() {
            let held = ProcessInfo.processInfo.systemUptime - pressedAt
            if held >= adaptiveHoldMaximum || (held >= adaptiveHoldMinimum && releaseWhen()) {
                release()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + adaptiveHoldPollInterval, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + adaptiveHoldMinimum, execute: poll)
    }

    /// 排队及修饰键释放完成后，在真正按下前复查条件。取消时也回调（false），
    /// 让调用方接管迟到的胶囊，不会把队列或语音切换卡在进行中。
    static func tapOption(
        _ key: VoiceOptionKey,
        if shouldSend: @escaping () -> Bool,
        releaseWhen: (() -> Bool)? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                tapOption(key, if: shouldSend, releaseWhen: releaseWhen, completion: completion)
            }
            return
        }

        pendingTaps.append(PendingTap(key: key, shouldSend: shouldSend, releaseWhen: releaseWhen, completion: completion))
        if isTapInProgress {
            Logger.shared.warn("语音单击仍在发送中，已排队等待上一轮释放完成")
            return
        }

        runNextTap()
    }

    private static func runNextTap() {
        guard !pendingTaps.isEmpty else {
            isTapInProgress = false
            return
        }

        isTapInProgress = true
        let tap = pendingTaps.removeFirst()

        runWhenModifiersClear {
            ensureOptionReleased(tap.key) {
                performTap(tap)
            }
        }
    }

    private static func performTap(_ tap: PendingTap) {
        DispatchQueue.main.async {
            guard tap.shouldSend() else {
                Logger.shared.debug("语音单击发送前条件已变化，跳过本次单击")
                tap.completion(false)
                DispatchQueue.main.async { runNextTap() }
                return
            }
            Logger.shared.debug("发送豆包语音快捷键：\(tap.key.label) 单击")
            tapOptionOnce(tap.key, releaseWhen: tap.releaseWhen) {
                ensureOptionReleased(tap.key) {
                    tap.completion(true)
                    DispatchQueue.main.async {
                        runNextTap()
                    }
                }
            }
        }
    }

    private static func ensureOptionReleased(_ key: VoiceOptionKey, completion: (() -> Void)? = nil) {
        if optionAppearsPressed(key) {
            postOption(key, isDown: false)
        }
        confirmOptionReleased(key, attemptsLeft: optionReleaseRetryCount, completion: completion)
    }

    private static func confirmOptionReleased(_ key: VoiceOptionKey, attemptsLeft: Int, completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + optionReleaseSettleDuration) {
            if optionAppearsPressed(key) {
                Logger.shared.warn("检测到\(key.label) 仍处于按下状态，补发抬起事件，flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
                postOption(key, isDown: false)
                if attemptsLeft > 1 {
                    confirmOptionReleased(key, attemptsLeft: attemptsLeft - 1, completion: completion)
                    return
                }
                Logger.shared.error("多次补发后\(key.label) 仍未释放，flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
            }
            completion?()
        }
    }

    private static func optionAppearsPressed(_ key: VoiceOptionKey) -> Bool {
        if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.rawValue))
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.rawValue))
        {
            return true
        }

        return optionAppearsPressed(key, in: CGEventSource.flagsState(.hidSystemState))
            || optionAppearsPressed(key, in: CGEventSource.flagsState(.combinedSessionState))
    }

    private static func optionAppearsPressed(_ key: VoiceOptionKey, in flags: CGEventFlags) -> Bool {
        let rawFlags = flags.rawValue
        if rawFlags & key.deviceMask != 0 {
            return true
        }
        if rawFlags & (VoiceOptionKey.left.deviceMask | VoiceOptionKey.right.deviceMask) != 0 {
            return false
        }
        return flags.contains(.maskAlternate)
    }

    // MARK: - 修饰键状态守门

    /// 等到当前所有修饰键都松开再执行 `block`，防止真实按下的 Fn / Ctrl 干扰单击 Option。
    ///
    /// 超时后仍然发送：卡住的多半是幽灵修饰键（键早就松了、状态没清），死等只会让快捷键
    /// 彻底失灵。`postOption` 会把无关修饰键从事件里剥掉，脏状态污染不到这一击。
    static func runWhenModifiersClear(attemptsLeft: Int = 30, _ block: @escaping () -> Void) {
        if modifiersAreClear() {
            block()
            return
        }
        if attemptsLeft <= 0 {
            Logger.shared.warn("等待修饰键释放超时（可能是卡住的幽灵修饰键），仍按干净的 Option 发送，当前 flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
            block()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            runWhenModifiersClear(attemptsLeft: attemptsLeft - 1, block)
        }
    }

    private static func modifiersAreClear() -> Bool {
        let busyMask: CGEventFlags = [
            .maskCommand, .maskAlternate, .maskShift,
            .maskControl, .maskSecondaryFn,
        ]
        let hidFlags = CGEventSource.flagsState(.hidSystemState)
        let combinedFlags = CGEventSource.flagsState(.combinedSessionState)
        return hidFlags.intersection(busyMask).rawValue == 0
            && combinedFlags.intersection(busyMask).rawValue == 0
    }

    private static func formatFlags(_ rawValue: UInt64) -> String {
        String(format: "0x%08llx", rawValue)
    }
}
