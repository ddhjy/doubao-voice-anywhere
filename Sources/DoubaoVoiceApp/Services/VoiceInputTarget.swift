import AppKit
import ApplicationServices

/// 新对话窗口可能先出现，稍后才创建编辑器。只查询焦点归属和控件类型，不读取输入内容。
struct VoiceInputTarget {
    enum Focus {
        case ready, waitingForEditor, changed, unavailable
    }

    private let pid: pid_t
    private let application: AXUIElement
    private let window: AXUIElement?
    private var editor: AXUIElement?
    private var editorPinned = false

    init?() {
        guard let app = InputSourceActivationNudge.shared.currentInteractionApplication() else { return nil }
        pid = app.processIdentifier
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        window = Self.element(application, kAXFocusedWindowAttribute).1
    }

    mutating func focus() -> Focus {
        guard editorPinned else { return resolveFocus() }
        var current = self
        current.editor = nil
        let focus = current.resolveFocus()
        if let editor {
            guard let focused = current.editor, CFEqual(editor, focused) else { return .changed }
        }
        return focus
    }

    /// 续录可能要等上一段整理，把请求绑定到轻按快捷键时的窗口和编辑框。
    mutating func pinFocusedEditor() -> Bool {
        switch focus() {
        case .ready, .unavailable:
            editorPinned = true
            return true
        case .changed, .waitingForEditor:
            return false
        }
    }

    private mutating func resolveFocus() -> Focus {
        guard let app = InputSourceActivationNudge.shared.currentInteractionApplication(), app.processIdentifier == pid else {
            return .changed
        }
        let currentWindow = Self.element(application, kAXFocusedWindowAttribute).1
        if let window, let currentWindow, !CFEqual(window, currentWindow) {
            return .changed
        }
        if editorPinned, window != nil, currentWindow == nil { return .changed }
        let (result, focused) = Self.element(application, kAXFocusedUIElementAttribute)
        // 微信 4 的自绘聊天框可以接收输入法文字，但 AX 可能只暴露窗口边框。
        // 只在仍是原来的微信普通窗口、且它只报告窗口或明确没有焦点控件时，交给豆包确认录音。
        if app.bundleIdentifier == "com.tencent.xinWeChat", app.isActive,
           window != nil, let currentWindow,
           result == .noValue || focused.map({ CFEqual($0, currentWindow) }) == true {
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentWindow, kAXSubroleAttribute as CFString, &subrole) == .success,
               subrole as? String == kAXStandardWindowSubrole {
                return .unavailable
            }
        }
        guard let focused else {
            return result == .noValue || result == .cannotComplete ? .waitingForEditor : .unavailable
        }
        AXUIElementSetMessagingTimeout(focused, 0.08)
        var value: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &value)
        guard roleResult == .success, let role = value as? String else {
            return roleResult == .cannotComplete ? .waitingForEditor : .unavailable
        }
        switch role {
        case kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole:
            editor = focused
            return .ready
        default:
            // Chromium 的 contenteditable 子节点也可能把编辑能力暴露在祖先节点上。
            if let editable = Self.element(focused, "AXEditableAncestor").1 {
                AXUIElementSetMessagingTimeout(editable, 0.08)
                editor = editable
                return .ready
            }
            switch role {
            case kAXWindowRole, kAXApplicationRole, kAXSheetRole, "AXWebArea", kAXScrollAreaRole,
                 kAXSplitGroupRole, kAXButtonRole, kAXToolbarRole, kAXStaticTextRole:
                return .waitingForEditor
            case kAXGroupRole:
                // 自绘编辑器也会报告为组；有文字选区的组可以直接接键。
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(focused, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
                   settable.boolValue {
                    editor = focused
                    return .ready
                }
                return .waitingForEditor
            default:
                editor = focused
                return .unavailable
            }
        }
    }

    /// 始终查录音时的编辑框。只读组合文本范围，不读文字，也不改变焦点。
    /// 编辑器不支持组合范围时返回 nil，由本次语音胶囊的出现和消失确认收尾。
    func mayHaveMarkedText() -> Bool? {
        guard let editor else { return nil }
        var value: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(editor, "AXMarkedTextRange" as CFString, &value)
        var hasEmptyRange = false
        if rangeResult == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range) {
                if range.location != kCFNotFound, range.length > 0 { return true }
                hasEmptyRange = true
            }
        }

        // 网页编辑器可以用不透明的文本标记表示组合范围，结束组合后返回空值。
        value = nil
        let markerResult = AXUIElementCopyAttributeValue(editor, "AXTextInputMarkedTextMarkerRange" as CFString, &value)
        if markerResult == .success, let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() {
            return true
        }
        if rangeResult == .cannotComplete || markerResult == .cannotComplete { return true }
        if hasEmptyRange || rangeResult == .noValue || markerResult == .noValue
            || rangeResult == .invalidUIElement { return false }
        return nil
    }

    private static func element(_ owner: AXUIElement, _ name: String) -> (AXError, AXUIElement?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, name as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (result, nil)
        }
        return (result, (value as! AXUIElement))
    }
}
