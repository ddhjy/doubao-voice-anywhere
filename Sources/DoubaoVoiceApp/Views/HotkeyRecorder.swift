import AppKit
import CoreGraphics
import SwiftUI

/// 快捷键录制控件：点一下进入录制态，按下的键位就是新快捷键，Esc 取消。
///
/// 录制会话由 `SettingsStore` 持有——窗口关掉时要能从外面收掉，
/// 否则监听器留在那儿、全局拦截也一直停着。
struct HotkeyRecorder: View {

    @ObservedObject var store: SettingsStore
    let target: SettingsStore.HotkeyTarget

    var body: some View {
        Button(action: toggle) {
            Text(isRecording ? "按下新快捷键…" : store.hotkey(for: target).displayString)
                .frame(minWidth: 110)
        }
        .help(isRecording
            ? "按 Esc 取消"
            : "点一下开始录制。可以是组合键，也可以单独点一个修饰键（比如只点一下 ⌥）。")
    }

    private var isRecording: Bool { store.recordingHotkeyTarget == target }

    private func toggle() {
        if isRecording {
            store.cancelHotkeyRecording()
        } else {
            store.beginHotkeyRecording(target)
        }
    }
}

/// 一次录制会话，负责接管键盘事件并识别出键位。
///
/// 用 local monitor（只在本 App 是 key window 时收事件）并返回 nil 吞掉：
/// 不吞的话按下的 Space 会顺手去点设置窗口里的按钮。
final class HotkeyCaptureSession {

    private(set) var isRecording = false

    private var monitor: Any?
    private var onCapture: ((Hotkey) -> Void)?
    private var onFinish: (() -> Void)?

    /// 当前按住的修饰键，以及按住期间有没有按过别的键。
    private var pressedModifier: Hotkey.ModifierKey?
    private var modifierUsedWithOtherKey = false

    func start(onCapture: @escaping (Hotkey) -> Void, onFinish: @escaping () -> Void) {
        cancel()
        self.onCapture = onCapture
        self.onFinish = onFinish
        pressedModifier = nil
        modifierUsedWithOtherKey = false
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func cancel() {
        finish()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        let flags = Self.flags(of: event)

        // 无修饰的 Esc 退出录制，不改配置。
        if keyCode == 53, flags.intersection(Hotkey.significantModifierMask).isEmpty {
            finish()
            return
        }

        modifierUsedWithOtherKey = true
        deliver(Hotkey(keyCode: keyCode, modifiers: flags))
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // CapsLock 之类不在表里的键没有干净的按下 / 抬起沿，直接忽略。
        guard let modifier = Hotkey.ModifierKey.forKeyCode(Int64(event.keyCode)) else { return }

        if Self.flags(of: event).contains(modifier.flag) {
            pressedModifier = modifier
            modifierUsedWithOtherKey = false
            return
        }

        // 抬起：按住期间没碰别的键，才算「单独点了一下这个修饰键」。
        let wasCleanTap = pressedModifier == modifier && !modifierUsedWithOtherKey
        pressedModifier = nil
        guard wasCleanTap else { return }
        deliver(Hotkey(keyCode: modifier.canonicalKeyCode))
    }

    private func deliver(_ hotkey: Hotkey) {
        onCapture?(hotkey)
        finish()
    }

    private func finish() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pressedModifier = nil
        modifierUsedWithOtherKey = false

        let notify = onFinish
        onCapture = nil
        onFinish = nil
        guard isRecording else { return }
        isRecording = false
        notify?()
    }

    /// 直接取事件底层的 CGEvent flags：录制和事件回调里的匹配用的就是同一份
    /// 数据，不会出现「录的时候带 Fn、匹配的时候不带」这类对不上的情况。
    private static func flags(of event: NSEvent) -> CGEventFlags {
        if let cgEvent = event.cgEvent {
            return cgEvent.flags
        }
        var result: CGEventFlags = []
        let modifierFlags = event.modifierFlags
        if modifierFlags.contains(.command) { result.insert(.maskCommand) }
        if modifierFlags.contains(.option) { result.insert(.maskAlternate) }
        if modifierFlags.contains(.control) { result.insert(.maskControl) }
        if modifierFlags.contains(.shift) { result.insert(.maskShift) }
        if modifierFlags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}
