import CoreGraphics
import Foundation

/// 事件回调接收者：决定是否拦截某条事件（true 表示拦截/吞掉）。
protocol EventTapDelegate: AnyObject {
    func handleFlagsChanged(event: CGEvent) -> Bool
    func handleKeyDown(event: CGEvent) -> Bool
    func handleMouseDown(event: CGEvent, type: CGEventType) -> Bool
}

/// 包装 CGEventTap：监听 `flagsChanged`（Fn）、`keyDown` 和鼠标点击。
///
/// - 需要"辅助功能"权限
/// - 由 RunLoop 驱动，被系统禁用时（超时/用户输入）会自动重启
final class EventTapController {

    weak var delegate: EventTapDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        if eventTap != nil { return true }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: EventTapController.callback,
            userInfo: opaqueSelf
        ) else {
            Logger.shared.error("CGEvent.tapCreate 失败：通常是缺少辅助功能权限")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source

        Logger.shared.info("EventTap 已启动（监听 flagsChanged + keyDown + mouseDown）")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func reEnable() {
        guard let tap = eventTap else { return }
        Logger.shared.warn("EventTap 被系统禁用，正在重新启用")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.reEnable()
            return Unmanaged.passUnretained(event)
        }

        guard let delegate = controller.delegate else {
            return Unmanaged.passUnretained(event)
        }

        let handled: Bool
        switch type {
        case .flagsChanged:
            handled = delegate.handleFlagsChanged(event: event)
        case .keyDown:
            handled = delegate.handleKeyDown(event: event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handled = delegate.handleMouseDown(event: event, type: type)
        default:
            handled = false
        }

        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
