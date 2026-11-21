import CoreGraphics
import Foundation

/// 豆包把长按 Fn 当作自己的语音键，会在普通的会话监听之前收走它。
/// 在 HID 层只旁观轻按。所有原始事件仍交给豆包处理，包括录音中的停止键。
final class NativeFnTapObserver: EventTapDelegate {
    private static let fn = Hotkey(keyCode: Hotkey.ModifierKey.fn.canonicalKeyCode)
    static let maxTap: TimeInterval = 0.25
    private let tap = EventTapController(listenOnlyAtHID: true)
    private let optionPressed: (VoiceOptionKey) -> Void
    private let didReceive: (BareModifierTapTracker.Edge, TimeInterval) -> Void
    private lazy var keyboard = FnKeyboardMonitor(onFn: { [weak self] down, time in
        var flags = CGEventSource.flagsState(.combinedSessionState)
        if down { flags.insert(.maskSecondaryFn) } else { flags.remove(.maskSecondaryFn) }
        self?.updateFn(flags: flags, at: time)
    }, onOtherKey: { [weak self] in self?.markOtherInput() })
    private let lock = NSLock()
    private var tracker = BareModifierTapTracker()
    private var pressedAt: TimeInterval = 0
    private var lastFnEventAt: TimeInterval = 0

    init(optionPressed: @escaping (VoiceOptionKey) -> Void, didReceive: @escaping (BareModifierTapTracker.Edge, TimeInterval) -> Void) {
        self.optionPressed = optionPressed
        self.didReceive = didReceive
        tap.delegate = self
    }

    func start() -> Bool {
        guard tap.start() else { return false }
        keyboard.start()
        return true
    }
    func stop() {
        keyboard.stop()
        tap.stop()
    }

    func handleFlagsChanged(event: CGEvent) -> Bool {
        guard !KeyboardSimulator.isSynthetic(event) else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard Self.fn.matchesModifierKeyCode(code) else {
            markOtherInput()
            if let option = VoiceOptionKey(rawValue: Int(code)), event.flags.contains(.maskAlternate),
               event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskSecondaryFn]).isEmpty {
                DispatchQueue.main.async { [weak self] in self?.optionPressed(option) }
            }
            return false
        }
        updateFn(flags: event.flags, at: TimeInterval(event.timestamp) / 1_000_000_000)
        return false
    }

    private func updateFn(flags: CGEventFlags, at now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        // 同一物理边沿可能也经 Quartz 到达。重复的按下/抬起由 tracker 合并，迟到的旧边沿直接丢弃。
        guard now >= lastFnEventAt else { return }
        lastFnEventAt = now
        // 豆包可能收走上一次的抬起。新按下不能沿用上一段按住的状态。
        if flags.contains(.maskSecondaryFn), tracker.isDown, now - pressedAt > Self.maxTap {
            tracker.reset()
        }
        switch tracker.update(hotkey: Self.fn, flags: flags, at: now) {
        case .pressed:
            pressedAt = now
            if !flags.intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand]).isEmpty {
                tracker.markUsedWithOtherInput()
            } else {
                deliver(.pressed)
            }
        case .tapped:
            deliver((0...Self.maxTap).contains(now - pressedAt) ? .tapped : .cancelled)
        case .cancelled:
            deliver(.cancelled)
        case .none:
            break
        }
    }

    func handleKeyDown(event: CGEvent) -> Bool {
        guard !KeyboardSimulator.isSynthetic(event) else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code != 179 && code != Self.fn.keyCode { markOtherInput() }
        return false
    }

    func handleMouseDown(event: CGEvent, type: CGEventType) -> Bool {
        guard !KeyboardSimulator.isSynthetic(event) else { return false }
        markOtherInput()
        return false
    }

    func eventTapWasInterrupted() {
        lock.lock()
        defer { lock.unlock() }
        tracker.reset()
        deliver(.cancelled)
    }

    private func markOtherInput() {
        lock.lock()
        tracker.markUsedWithOtherInput()
        lock.unlock()
    }

    private func deliver(_ edge: BareModifierTapTracker.Edge) {
        let downTime = pressedAt
        DispatchQueue.main.async { [weak self] in self?.didReceive(edge, downTime) }
    }
}
