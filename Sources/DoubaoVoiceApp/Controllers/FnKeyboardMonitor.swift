import Foundation
import IOKit.hid

/// 某些版本的豆包在取消录音后会换掉自己的事件监听，后面的 Quartz 监听收不到 Fn。
/// 已有设备读取权限时，从系统键盘读同一按键的物理边沿。全程共享设备，不改键。
final class FnKeyboardMonitor {
    private let onFn: (Bool, TimeInterval) -> Void
    private let onOtherKey: () -> Void
    private var manager: IOHIDManager?
    private var devices: Set<IOHIDDevice> = []
    private var pressedElements: Set<IOHIDElement> = []
    private var otherModifiers: Set<IOHIDElement> = []
    private static let fnPages = [0xff, 0xff01] // Apple Top Case、Apple Vendor Keyboard
    private static let fnUsage = 3
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    init(onFn: @escaping (Bool, TimeInterval) -> Void, onOtherKey: @escaping () -> Void) {
        self.onFn = onFn
        self.onOtherKey = onOtherKey
    }

    func start() {
        guard manager == nil, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<FnKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<FnKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        for device in Array(devices) { detach(device) }
        self.manager = nil
    }

    private func attach(_ device: IOHIDDevice) {
        guard !devices.contains(device) else { return }
        let fnMatches = Self.fnPages.map { [kIOHIDElementUsagePageKey: $0, kIOHIDElementUsageKey: Self.fnUsage] }
        guard fnMatches.contains(where: {
            (IOHIDDeviceCopyMatchingElements(device, $0 as CFDictionary, 0) as? [IOHIDElement])?.isEmpty == false
        }), IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { return }
        devices.insert(device)
        // 其它键只用来排除 Fn 组合键，不读取文字。独占的实体键盘会跳过，改键工具输出的系统键盘仍可读。
        let keyMatch = [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad]
        IOHIDDeviceSetInputValueMatchingMultiple(device, (fnMatches + [keyMatch]) as CFArray)
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            Unmanaged<FnKeyboardMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        Logger.shared.debug("已连接键盘的 Fn 状态监听")
    }

    private func detach(_ device: IOHIDDevice) {
        guard devices.remove(device) != nil else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceClose(device, 0)
        let wasDown = !pressedElements.isEmpty
        pressedElements = pressedElements.filter { IOHIDElementGetDevice($0) != device }
        otherModifiers = otherModifiers.filter { IOHIDElementGetDevice($0) != device }
        if wasDown && pressedElements.isEmpty {
            onOtherKey()
            onFn(false, ProcessInfo.processInfo.systemUptime)
        }
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let down = IOHIDValueGetIntegerValue(value) != 0
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = IOHIDElementGetUsage(element)
        guard Self.fnPages.contains(page), usage == Self.fnUsage else {
            let modifier = page == kHIDPage_KeyboardOrKeypad
                && (kHIDUsage_KeyboardLeftControl...kHIDUsage_KeyboardRightGUI).contains(Int(usage))
            if modifier {
                if down { otherModifiers.insert(element) } else { otherModifiers.remove(element) }
            }
            if (down || modifier) && !pressedElements.isEmpty { onOtherKey() }
            return
        }
        let wasDown = !pressedElements.isEmpty
        if down { pressedElements.insert(element) } else { pressedElements.remove(element) }
        let isDown = !pressedElements.isEmpty
        if wasDown != isDown {
            onFn(isDown, Double(IOHIDValueGetTimeStamp(value)) * Self.secondsPerTick)
            if isDown && !otherModifiers.isEmpty { onOtherKey() }
        }
    }
}
