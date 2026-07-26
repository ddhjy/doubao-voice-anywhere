import CoreGraphics
import Foundation

/// 用户可配置的通用设置（UserDefaults 持久化），可从菜单栏「设置…」修改。
///
/// 默认值与项目早期的硬编码常量一致：老用户升级后行为不变。
///
/// 「日常输入法」影响三处行为：
///   1. 轮换快捷键在日常中文输入法 / 日常英文键盘布局之间轮换
///   2. 从英文键盘布局启动豆包语音时，先桥接到日常中文输入法
///   3. 语音结束后找不到「之前的输入源」时，恢复到日常中文输入法
enum GeneralSettings {
    static let changedNotification = Notification.Name("GeneralSettings.changed")

    private enum Key {
        static let chineseSourceID = "NormalChineseInputSourceID"
        static let chineseName = "NormalChineseInputMethodName"
        static let englishSourceID = "NormalEnglishKeyboardLayoutID"
        static let englishName = "NormalEnglishKeyboardLayoutName"
        static let ctrlSpaceEnabled = "CtrlSpaceSwitchEnabled"
        static let pauseMediaDuringVoice = "PauseMediaDuringVoiceInput"
        static let voiceHotkeyKeyCode = "VoiceHotkeyKeyCode"
        static let voiceHotkeyModifiers = "VoiceHotkeyModifiers"
        static let cycleHotkeyKeyCode = "CycleInputSourceHotkeyKeyCode"
        static let cycleHotkeyModifiers = "CycleInputSourceHotkeyModifiers"
    }

    /// 与早期版本硬编码值一致的默认配置。
    /// 配置的输入源在系统里不存在时会自动降级，见 resolved 系列方法。
    enum Defaults {
        static let chineseSourceID = "im.rime.inputmethod.Squirrel.Hans"
        static let chineseName = "Squirrel - Simplified"
        static let englishSourceID = "com.apple.keylayout.US"
        static let englishName = "U.S."
        /// 裸 Fn 轻按，等价于快捷键可配置之前的硬编码行为。
        static let voiceHotkey = Hotkey(keyCode: Hotkey.ModifierKey.fn.canonicalKeyCode)
        /// Ctrl+Space，同上。
        static let cycleInputSourceHotkey = Hotkey(keyCode: 49, modifiers: .maskControl)
    }

    // MARK: - 存取

    static var normalChineseInputSourceID: String {
        UserDefaults.standard.string(forKey: Key.chineseSourceID) ?? Defaults.chineseSourceID
    }

    static var normalChineseInputMethodName: String {
        UserDefaults.standard.string(forKey: Key.chineseName) ?? Defaults.chineseName
    }

    static var normalEnglishKeyboardLayoutID: String {
        UserDefaults.standard.string(forKey: Key.englishSourceID) ?? Defaults.englishSourceID
    }

    static var normalEnglishKeyboardLayoutName: String {
        UserDefaults.standard.string(forKey: Key.englishName) ?? Defaults.englishName
    }

    /// 输入源轮换开关（默认开启，与早期版本一致）。
    /// 即便开启，配置的输入源在系统里找不到时也会自动透传按键，不会白吞一个快捷键。
    static var ctrlSpaceSwitchEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.ctrlSpaceEnabled) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.ctrlSpaceEnabled)
            postChanged()
        }
    }

    /// 开始 / 结束豆包语音的快捷键。
    static var voiceHotkey: Hotkey {
        get {
            hotkey(
                keyCodeKey: Key.voiceHotkeyKeyCode,
                modifiersKey: Key.voiceHotkeyModifiers,
                fallback: Defaults.voiceHotkey
            )
        }
        set {
            store(newValue, keyCodeKey: Key.voiceHotkeyKeyCode, modifiersKey: Key.voiceHotkeyModifiers)
            Logger.shared.info("说话快捷键已设置为: \(newValue.displayString)")
            postChanged()
        }
    }

    /// 在日常中文输入法与日常英文键盘之间轮换的快捷键。
    static var cycleInputSourceHotkey: Hotkey {
        get {
            hotkey(
                keyCodeKey: Key.cycleHotkeyKeyCode,
                modifiersKey: Key.cycleHotkeyModifiers,
                fallback: Defaults.cycleInputSourceHotkey
            )
        }
        set {
            store(newValue, keyCodeKey: Key.cycleHotkeyKeyCode, modifiersKey: Key.cycleHotkeyModifiers)
            Logger.shared.info("轮换快捷键已设置为: \(newValue.displayString)")
            postChanged()
        }
    }

    /// 说话时自动暂停正在播放的媒体、结束后恢复（默认开启）。
    /// 这是 2026-07 新增能力，没有对应的老版本硬编码行为；不想要的用户可在
    /// 设置里关闭。关闭后完全不触碰系统媒体会话。
    static var pauseMediaDuringVoice: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.pauseMediaDuringVoice) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pauseMediaDuringVoice)
            postChanged()
        }
    }

    static func setNormalChineseInputSource(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: Key.chineseSourceID)
        UserDefaults.standard.set(name, forKey: Key.chineseName)
        Logger.shared.info("日常中文输入法已设置为: \(name) (\(id))")
        postChanged()
    }

    static func setNormalEnglishKeyboardLayout(id: String, name: String) {
        UserDefaults.standard.set(id, forKey: Key.englishSourceID)
        UserDefaults.standard.set(name, forKey: Key.englishName)
        Logger.shared.info("日常英文键盘布局已设置为: \(name) (\(id))")
        postChanged()
    }

    private static func postChanged() {
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// 键码没写过就整体用默认值：`integer(forKey:)` 在未设置时返回 0，
    /// 而 0 是个合法键码（字母 A），会把老用户的行为改掉。
    private static func hotkey(keyCodeKey: String, modifiersKey: String, fallback: Hotkey) -> Hotkey {
        guard let keyCode = UserDefaults.standard.object(forKey: keyCodeKey) as? Int else {
            return fallback
        }
        let modifiers = UserDefaults.standard.object(forKey: modifiersKey) as? Int ?? 0
        return Hotkey(
            keyCode: Int64(keyCode),
            modifiers: CGEventFlags(rawValue: UInt64(bitPattern: Int64(modifiers)))
        )
    }

    private static func store(_ hotkey: Hotkey, keyCodeKey: String, modifiersKey: String) {
        UserDefaults.standard.set(Int(hotkey.keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(bitPattern: UInt(hotkey.modifiers.rawValue)), forKey: modifiersKey)
    }

    // MARK: - 解析（配置值 → 系统里真实可用的输入源）

    /// 解析「日常中文输入法」，按顺序尝试：
    ///   1. 配置的 sourceID 在系统里已启用 → 直接用
    ///   2. 按配置的名称在已启用输入法里找
    ///   3. 自动改用系统里已启用的第一个中文输入法（排除 excludingSourceIDs，通常是豆包）
    /// 全都找不到返回 nil，相关功能自动停用（不误吞按键）。
    static func resolvedNormalChineseInputSource(excludingSourceIDs: Set<String> = []) -> InputSource? {
        if let byID = InputSourceManager.enabledSource(byID: normalChineseInputSourceID),
           byID.kind == .method {
            return byID
        }
        let name = normalChineseInputMethodName
        if let byName = InputSourceManager.enabledSelectableMethods().first(where: { $0.value == name }) {
            return byName
        }
        return InputSourceManager.firstEnabledChineseMethod(excludingIDs: excludingSourceIDs)
    }

    /// 解析「日常英文键盘布局」，逻辑同上；找不到时改用系统里第一个键盘布局。
    static func resolvedNormalEnglishKeyboardLayout() -> InputSource? {
        if let byID = InputSourceManager.enabledSource(byID: normalEnglishKeyboardLayoutID),
           byID.kind == .layout {
            return byID
        }
        let name = normalEnglishKeyboardLayoutName
        let layouts = InputSourceManager.enabledSelectableLayouts()
        if let byName = layouts.first(where: { $0.value == name }) {
            return byName
        }
        return layouts.first
    }
}
