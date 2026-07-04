import CoreGraphics
import Foundation

/// 事件回调接收者：决定是否拦截某条事件（true 表示拦截/吞掉）。
///
/// 注意：所有回调都运行在专用的事件监听线程上（不是主线程）。
/// 实现方必须立即返回，不能做任何可能阻塞的调用（尤其是 TIS / XPC / 磁盘同步 IO），
/// 否则 WindowServer 等不到回调返回会按超时禁用整个 tap，造成按键丢失。
protocol EventTapDelegate: AnyObject {
    func handleFlagsChanged(event: CGEvent) -> Bool
    func handleKeyDown(event: CGEvent) -> Bool
    func handleMouseDown(event: CGEvent, type: CGEventType) -> Bool
    /// tap 被系统禁用后重新启用时回调（同样在事件监听线程上）。
    /// 禁用期间可能丢过按键（比如只收到 Fn down、丢了 Fn up），需要重置按键跟踪状态。
    func eventTapWasInterrupted()
}

/// 包装 CGEventTap：监听 `flagsChanged`（Fn）、`keyDown` 和鼠标点击。
///
/// - 需要"辅助功能"权限
/// - tap 跑在专用线程的 RunLoop 上，主线程卡顿（如 TIS 调用变慢）不影响事件响应
/// - 被系统禁用时（超时/用户输入）立即重新启用；另有周期看门狗兜底，
///   覆盖"禁用通知本身也没送达"（进程被挂起、休眠唤醒等）的情况
final class EventTapController {

    weak var delegate: EventTapDelegate?

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var watchdogTimer: CFRunLoopTimer?

    private static let watchdogInterval: TimeInterval = 5.0
    private static let startTimeout: TimeInterval = 3.0

    func start() -> Bool {
        stateLock.lock()
        let alreadyRunning = eventTap != nil
        stateLock.unlock()
        if alreadyRunning { return true }

        let semaphore = DispatchSemaphore(value: 0)
        var started = false

        let thread = Thread { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            started = self.setUpTapOnCurrentThread()
            semaphore.signal()
            guard started else { return }
            CFRunLoopRun() // 由 stop() 调用 CFRunLoopStop 结束
            Logger.shared.info("事件监听线程退出")
        }
        thread.name = "com.doubaovoiceapp.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()

        if semaphore.wait(timeout: .now() + Self.startTimeout) == .timedOut {
            Logger.shared.error("等待事件监听线程启动超时")
            return false
        }
        return started
    }

    func stop() {
        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        let runLoop = tapRunLoop
        let timer = watchdogTimer
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        watchdogTimer = nil
        stateLock.unlock()

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        guard let runLoop = runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let source = source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            if let timer = timer {
                CFRunLoopTimerInvalidate(timer)
            }
            if let tap = tap {
                CFMachPortInvalidate(tap)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - 事件监听线程内部

    /// 在专用线程上创建 tap 并挂到该线程的 RunLoop。
    private func setUpTapOnCurrentThread() -> Bool {
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

        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.watchdogInterval,
            Self.watchdogInterval,
            0,
            0
        ) { [weak self] _ in
            self?.watchdogCheck()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        tapRunLoop = CFRunLoopGetCurrent()
        watchdogTimer = timer
        stateLock.unlock()

        Logger.shared.info("EventTap 已启动（独立线程，监听 flagsChanged + keyDown + mouseDown，看门狗 \(Int(Self.watchdogInterval))s）")
        return true
    }

    private func currentTap() -> CFMachPort? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return eventTap
    }

    /// 周期巡检：兜底处理"tap 被禁用但禁用通知没送达"的情况（进程挂起、休眠唤醒等）。
    private func watchdogCheck() {
        guard let tap = currentTap(), !CGEvent.tapIsEnabled(tap: tap) else { return }
        Logger.shared.warn("看门狗发现 EventTap 处于禁用状态，正在重新启用")
        CGEvent.tapEnable(tap: tap, enable: true)
        delegate?.eventTapWasInterrupted()
    }

    fileprivate func reEnable(after type: CGEventType) {
        guard let tap = currentTap() else { return }
        let reason = type == .tapDisabledByTimeout ? "回调超时" : "用户输入"
        Logger.shared.warn("EventTap 被系统禁用（\(reason)），正在重新启用")
        CGEvent.tapEnable(tap: tap, enable: true)
        delegate?.eventTapWasInterrupted()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.reEnable(after: type)
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
