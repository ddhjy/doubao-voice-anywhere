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

    // MARK: - 枚举已启用的输入源（设置界面与配置解析用）

    /// 已启用、可被用户选择的输入法列表（与系统输入法切换器可见项一致）。
    static func enabledSelectableMethods() -> [InputSource] {
        selectableEntries().filter { $0.inputSource.kind == .method }.map { $0.inputSource }
    }

    /// 已启用、可被用户选择的键盘布局列表。
    static func enabledSelectableLayouts() -> [InputSource] {
        selectableEntries().filter { $0.inputSource.kind == .layout }.map { $0.inputSource }
    }

    /// 按 sourceID 查找已启用且可选择的输入源；未启用返回 nil。
    static func enabledSource(byID id: String) -> InputSource? {
        selectableEntries().first { $0.inputSource.sourceID == id }?.inputSource
    }

    /// sourceID 对应的输入源当前是否已启用且可选择。
    static func isSourceEnabled(id: String) -> Bool {
        enabledSource(byID: id) != nil
    }

    /// 已启用输入法里的第一个中文输入法（按系统列表顺序），用于配置失效时自动降级。
    static func firstEnabledChineseMethod(excludingIDs: Set<String> = []) -> InputSource? {
        for entry in selectableEntries() {
            guard entry.inputSource.kind == .method else { continue }
            if let id = entry.inputSource.sourceID, excludingIDs.contains(id) { continue }
            guard let languages = stringArray(of: entry.source, key: kTISPropertyInputSourceLanguages)
            else { continue }
            if languages.contains(where: { $0.hasPrefix("zh") }) {
                return entry.inputSource
            }
        }
        return nil
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

    /// 注册分布式通知，当系统「已启用的输入源列表」变化（用户增删输入法）时回调。
    @discardableResult
    static func observeEnabledInputSourcesChanged(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        let name = kTISNotifyEnabledKeyboardInputSourcesChanged as String
        return center.addObserver(
            forName: NSNotification.Name(name),
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }

    // MARK: - 工具

    private struct SourceEntry {
        let source: TISInputSource
        let inputSource: InputSource
    }

    /// 过滤出「已启用 + 可选择 + 键盘类」的输入源，排除表情面板、按住候选等系统辅助项。
    private static func selectableEntries() -> [SourceEntry] {
        guard let list = enabledInputSources() else { return [] }
        return list.compactMap { src in
            guard let category = string(of: src, key: kTISPropertyInputSourceCategory),
                  category == (kTISCategoryKeyboardInputSource as String),
                  bool(of: src, key: kTISPropertyInputSourceIsSelectCapable),
                  bool(of: src, key: kTISPropertyInputSourceIsEnabled),
                  let type = string(of: src, key: kTISPropertyInputSourceType),
                  let name = string(of: src, key: kTISPropertyLocalizedName)
            else { return nil }

            let kind: InputSource.Kind
            if type == (kTISTypeKeyboardLayout as String) {
                kind = .layout
            } else if isMethodType(type) {
                kind = .method
            } else {
                return nil
            }

            let id = string(of: src, key: kTISPropertyInputSourceID)
            return SourceEntry(
                source: src,
                inputSource: InputSource(kind: kind, value: name, sourceID: id)
            )
        }
    }

    private static func enabledInputSources() -> [TISInputSource]? {
        // includeAllInstalled = false：只列已启用的（与系统切换器一致）
        guard let list = TISCreateInputSourceList(nil, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return nil }
        return list
    }

    private static func bool(of src: TISInputSource, key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(src, key) else { return false }
        let cf = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(cf)
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
