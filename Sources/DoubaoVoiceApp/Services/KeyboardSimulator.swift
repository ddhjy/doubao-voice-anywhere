import CoreGraphics
import Foundation

/// 模拟键盘事件。当前仅需要"左 Option 单击"，对应豆包语音的触发方式。
///
/// 关键点：左 Option 本身是修饰键，要发送带 `deviceLeftAlternate` 的 `flagsChanged`。
/// 抬起后必须等系统确认 Option 已清掉，再继续下一次触发。
enum KeyboardSimulator {

    /// macOS 虚拟键码：左 Option。
    static let leftOptionKeyCode: CGKeyCode = 58

    // 与 NXEvent 的位掩码对齐（参见 IOKit/hidsystem/IOLLEvent.h）。
    private static let rawMaskDeviceLeftAlternate: UInt64 = 0x0000_0020
    private static let rawMaskDeviceRightAlternate: UInt64 = 0x0000_0040

    private static let optionTapHoldDuration: TimeInterval = 0.05
    private static let optionReleaseSettleDuration: TimeInterval = 0.03
    private static let optionReleaseRetryCount = 8

    private static var isTapInProgress = false
    private static var pendingTapCompletions: [(() -> Void)?] = []

    private static let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// 发送一次左 Option 的 flagsChanged 事件。`isDown` 为 true 表示按下、false 表示抬起。
    static func postLeftOption(isDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: leftOptionKeyCode,
            keyDown: isDown
        ) else {
            Logger.shared.error("无法创建 CGEvent for left Option")
            return
        }

        if event.type != .flagsChanged {
            event.type = .flagsChanged
        }

        event.post(tap: .cghidEventTap)
    }

    /// 模拟一次左 Option 的"轻按"：按下 -> 短暂保持 -> 抬起。
    static func tapLeftOptionOnce(completion: (() -> Void)? = nil) {
        postLeftOption(isDown: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + optionTapHoldDuration) {
            postLeftOption(isDown: false)
            confirmLeftOptionReleased(attemptsLeft: optionReleaseRetryCount, completion: completion)
        }
    }

    /// 单击左 Option：豆包语音的触发快捷键。
    static func tapLeftOption(completion: (() -> Void)? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                tapLeftOption(completion: completion)
            }
            return
        }

        pendingTapCompletions.append(completion)
        if isTapInProgress {
            Logger.shared.warn("左 Option 单击仍在发送中，已排队等待上一轮释放完成")
            return
        }

        runNextTap()
    }

    private static func runNextTap() {
        guard !pendingTapCompletions.isEmpty else {
            isTapInProgress = false
            return
        }

        isTapInProgress = true
        let completion = pendingTapCompletions.removeFirst()

        runWhenModifiersClear {
            ensureLeftOptionReleased {
                performTap(completion: completion)
            }
        }
    }

    private static func performTap(completion: (() -> Void)?) {
        DispatchQueue.main.async {
            Logger.shared.debug("发送豆包语音快捷键：左 Option 单击")
            tapLeftOptionOnce {
                ensureLeftOptionReleased {
                    completion?()
                    DispatchQueue.main.async {
                        runNextTap()
                    }
                }
            }
        }
    }

    private static func ensureLeftOptionReleased(completion: (() -> Void)? = nil) {
        if leftOptionAppearsPressed() {
            postLeftOption(isDown: false)
        }
        confirmLeftOptionReleased(attemptsLeft: optionReleaseRetryCount, completion: completion)
    }

    private static func confirmLeftOptionReleased(attemptsLeft: Int, completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + optionReleaseSettleDuration) {
            if leftOptionAppearsPressed() {
                Logger.shared.warn("检测到左 Option 仍处于按下状态，补发抬起事件，flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
                postLeftOption(isDown: false)
                if attemptsLeft > 1 {
                    confirmLeftOptionReleased(attemptsLeft: attemptsLeft - 1, completion: completion)
                    return
                }
                Logger.shared.error("多次补发后左 Option 仍未释放，flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
            }
            completion?()
        }
    }

    private static func leftOptionAppearsPressed() -> Bool {
        if CGEventSource.keyState(.hidSystemState, key: leftOptionKeyCode)
            || CGEventSource.keyState(.combinedSessionState, key: leftOptionKeyCode)
        {
            return true
        }

        return leftOptionAppearsPressed(in: CGEventSource.flagsState(.hidSystemState))
            || leftOptionAppearsPressed(in: CGEventSource.flagsState(.combinedSessionState))
    }

    private static func leftOptionAppearsPressed(in flags: CGEventFlags) -> Bool {
        let rawFlags = flags.rawValue
        if rawFlags & rawMaskDeviceLeftAlternate != 0 {
            return true
        }
        if rawFlags & rawMaskDeviceRightAlternate != 0 {
            return false
        }
        return flags.contains(.maskAlternate)
    }

    // MARK: - 修饰键状态守门

    /// 等到当前所有修饰键都松开再执行 `block`，防止真实按下的 Fn / Ctrl 干扰单击 Option。
    static func runWhenModifiersClear(attemptsLeft: Int = 30, _ block: @escaping () -> Void) {
        if modifiersAreClear() {
            block()
            return
        }
        if attemptsLeft <= 0 {
            Logger.shared.warn("等待修饰键释放超时，继续发送左 Option 单击，flags=\(formatFlags(CGEventSource.flagsState(.combinedSessionState).rawValue))")
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
