import CoreGraphics
import Foundation

/// 模拟键盘事件。当前仅需要"左 Option 双击"，对应豆包语音的触发方式。
///
/// 关键点：构造 `flagsChanged` 事件并设置设备级的 raw flags（含 `deviceLeftAlternate`），
/// 保证系统识别为"左侧 Option"。豆包语音对纯修饰键事件更敏感，普通 keyDown/keyUp 不行。
enum KeyboardSimulator {

    /// macOS 虚拟键码：左 Option。
    static let leftOptionKeyCode: CGKeyCode = 58

    // 与 NXEvent 的位掩码对齐（参见 IOKit/hidsystem/IOLLEvent.h）。
    private static let rawMaskNonCoalesced: UInt64 = 0x0000_0100
    private static let rawMaskAlternate: UInt64 = 0x0008_0000
    private static let rawMaskDeviceLeftAlternate: UInt64 = 0x0000_0020
    private static let rawMaskDeviceRightAlternate: UInt64 = 0x0000_0040

    private static let optionTapHoldDuration: TimeInterval = 0.025
    private static let optionDoubleTapInterval: TimeInterval = 0.07
    private static let optionReleaseSettleDuration: TimeInterval = 0.02

    private static let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
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

        // CGEvent 默认是 keyDown/keyUp，强制转成 flagsChanged。
        event.type = .flagsChanged
        event.flags = leftOptionFlags(isDown: isDown)

        event.post(tap: .cghidEventTap)
    }

    /// 模拟一次左 Option 的"轻按"：按下 -> 短暂保持 -> 抬起。
    static func tapLeftOptionOnce(completion: (() -> Void)? = nil) {
        postLeftOption(isDown: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + optionTapHoldDuration) {
            postLeftOption(isDown: false)
            completion?()
        }
    }

    /// 双击左 Option：豆包语音的触发快捷键。
    static func doubleTapLeftOption(completion: (() -> Void)? = nil) {
        runWhenModifiersClear {
            Logger.shared.debug("发送豆包语音快捷键：左 Option 双击")
            tapLeftOptionOnce {
                DispatchQueue.main.asyncAfter(deadline: .now() + optionDoubleTapInterval) {
                    tapLeftOptionOnce {
                        ensureLeftOptionReleased(completion: completion)
                    }
                }
            }
        }
    }

    private static func leftOptionFlags(isDown: Bool) -> CGEventFlags {
        var flags = CGEventSource.flagsState(.combinedSessionState).rawValue

        if isDown {
            flags |= rawMaskAlternate | rawMaskDeviceLeftAlternate
        } else {
            flags &= ~rawMaskDeviceLeftAlternate
            if flags & rawMaskDeviceRightAlternate == 0 {
                flags &= ~rawMaskAlternate
            }
        }

        flags |= rawMaskNonCoalesced
        return CGEventFlags(rawValue: flags)
    }

    private static func ensureLeftOptionReleased(completion: (() -> Void)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + optionReleaseSettleDuration) {
            if leftOptionAppearsPressed() {
                Logger.shared.warn("检测到左 Option 仍处于按下状态，补发抬起事件")
                postLeftOption(isDown: false)
            }
            completion?()
        }
    }

    private static func leftOptionAppearsPressed() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
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

    /// 等到当前所有修饰键都松开再执行 `block`，防止真实按下的 Fn / Ctrl 干扰双击 Option。
    static func runWhenModifiersClear(attemptsLeft: Int = 30, _ block: @escaping () -> Void) {
        if modifiersAreClear() || attemptsLeft <= 0 {
            block()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            runWhenModifiersClear(attemptsLeft: attemptsLeft - 1, block)
        }
    }

    private static func modifiersAreClear() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let busyMask: CGEventFlags = [
            .maskCommand, .maskAlternate, .maskShift,
            .maskControl, .maskSecondaryFn,
        ]
        return flags.intersection(busyMask).rawValue == 0
    }
}
