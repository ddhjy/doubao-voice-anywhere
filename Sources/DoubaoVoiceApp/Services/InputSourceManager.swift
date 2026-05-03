import Carbon
import Foundation

/// 包装 macOS Text Input Sources (TIS) API。
enum InputSourceManager {

    // MARK: - 读取当前输入源

    /// 当前键盘输入源（可能是输入法，也可能是键盘布局）。
    static func currentKeyboardInputSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// 当前键盘布局（即便正在使用输入法也会返回底层布局）。
    static func currentKeyboardLayoutInputSource() -> TISInputSource? {
        TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    /// 当前输入源的 sourceID。
    static func currentSourceID() -> String? {
        guard let src = currentKeyboardInputSource() else { return nil }
        return string(of: src, key: kTISPropertyInputSourceID)
    }

    /// 当前是输入法时返回 localized name，否则 nil。
    static func currentMethod() -> String? {
        guard let src = currentKeyboardInputSource(),
              let type = string(of: src, key: kTISPropertyInputSourceType)
        else { return nil }
        guard isMethodType(type) else { return nil }
        return string(of: src, key: kTISPropertyLocalizedName)
    }

    /// 当前是键盘布局时返回 localized name，否则 nil。
    static func currentLayout() -> String? {
        guard let src = currentKeyboardInputSource(),
              let type = string(of: src, key: kTISPropertyInputSourceType)
        else { return nil }
        guard type == (kTISTypeKeyboardLayout as String) else { return nil }
        return string(of: src, key: kTISPropertyLocalizedName)
    }

    /// 当前输入源的统一描述：优先返回 method，其次 layout。
    static func nowSource() -> InputSource? {
        let sourceID = currentSourceID()
        if let method = currentMethod() {
            return InputSource(kind: .method, value: method, sourceID: sourceID)
        }
        if let layout = currentLayout() {
            return InputSource(kind: .layout, value: layout, sourceID: sourceID)
        }
        return nil
    }

    /// 当前输入源是否需要通过短暂焦点切换来让前台 App 真正刷新输入上下文。
    ///
    /// macOS 对部分 CJKV 输入法存在一个长期问题：`TISSelectInputSource` 返回成功，
    /// 菜单栏图标也已经变化，但 Electron 等 App 的文本输入上下文仍停留在旧输入源。
    /// 这类输入法需要在切换后触发一次极短的焦点刷新。
    static func currentSourceNeedsActivationNudge() -> Bool {
        guard let src = currentKeyboardInputSource() else { return false }
        return sourceNeedsActivationNudge(src)
    }

    // MARK: - 切换输入源

    /// 按 sourceID 切换输入源。
    @discardableResult
    static func selectSource(byID id: String) -> Bool {
        let filter: [CFString: Any] = [kTISPropertyInputSourceID: id]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource],
              let src = list.first
        else { return false }
        let status = TISSelectInputSource(src)
        return status == noErr
    }

    /// 按 localized name 找输入法并切换。
    @discardableResult
    static func selectMethod(byName name: String) -> Bool {
        guard let list = enabledInputSources() else { return false }
        for src in list {
            guard let type = string(of: src, key: kTISPropertyInputSourceType),
                  isMethodType(type) else { continue }
            if string(of: src, key: kTISPropertyLocalizedName) == name {
                return TISSelectInputSource(src) == noErr
            }
        }
        return false
    }

    /// 按 localized name 找键盘布局并切换。
    @discardableResult
    static func selectLayout(byName name: String) -> Bool {
        guard let list = enabledInputSources() else { return false }
        for src in list {
            guard let type = string(of: src, key: kTISPropertyInputSourceType),
                  type == (kTISTypeKeyboardLayout as String) else { continue }
            if string(of: src, key: kTISPropertyLocalizedName) == name {
                return TISSelectInputSource(src) == noErr
            }
        }
        return false
    }

    // MARK: - 输入源变化通知

    /// 注册分布式通知，当系统切换输入源时回调。
    /// 返回 observer 句柄，调用方需要保存以便手动移除。
    @discardableResult
    static func observeInputSourceChanged(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        let name = kTISNotifySelectedKeyboardInputSourceChanged as String
        return center.addObserver(
            forName: NSNotification.Name(name),
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }

    // MARK: - 工具

    private static func enabledInputSources() -> [TISInputSource]? {
        // includeAllInstalled = false：只列已启用的（与系统切换器一致）
        guard let list = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return nil }
        return list
    }

    private static func sourceNeedsActivationNudge(_ src: TISInputSource) -> Bool {
        guard let type = string(of: src, key: kTISPropertyInputSourceType),
              isMethodType(type),
              let languages = stringArray(of: src, key: kTISPropertyInputSourceLanguages)
        else { return false }

        return languages.contains { language in
            language == "ko"
                || language == "ja"
                || language == "vi"
                || language.hasPrefix("zh")
        }
    }

    private static func string(of src: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    private static func stringArray(of src: TISInputSource, key: CFString) -> [String]? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        let cf = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        return cf as? [String]
    }

    private static func isMethodType(_ type: String) -> Bool {
        type == (kTISTypeKeyboardInputMethodWithoutModes as String)
            || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
            || type == (kTISTypeKeyboardInputMode as String)
    }
}
