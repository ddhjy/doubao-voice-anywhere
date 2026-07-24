// 离线诊断脚本：查看系统输入源、验证 TIS 切换链路。
//
// 用法：
//   swift tools/check_switch.swift                # 列出所有已启用的输入源及其 sourceID
//   swift tools/check_switch.swift <id1> <id2>…   # 依次切换到指定 sourceID，验证切换是否生效
//
// 示例：
//   swift tools/check_switch.swift com.bytedance.inputmethod.doubaoime.pinyin com.apple.keylayout.ABC
import Carbon
import Foundation

func property(_ src: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func boolProperty(_ src: TISInputSource, _ key: CFString) -> Bool {
    guard let raw = TISGetInputSourceProperty(src, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
}

func currentSnapshot() -> String {
    guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "nil" }
    let name = property(cur, kTISPropertyLocalizedName) ?? "?"
    let id = property(cur, kTISPropertyInputSourceID) ?? "?"
    return "\(name)  \(id)"
}

func listEnabledSources() {
    guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
        print("TISCreateInputSourceList 查询失败")
        return
    }

    print("已启用的输入源（可用于「设置…」或本脚本的切换测试）：\n")
    for src in list {
        guard let category = property(src, kTISPropertyInputSourceCategory),
              category == (kTISCategoryKeyboardInputSource as String),
              boolProperty(src, kTISPropertyInputSourceIsSelectCapable)
        else { continue }
        let name = property(src, kTISPropertyLocalizedName) ?? "?"
        let id = property(src, kTISPropertyInputSourceID) ?? "?"
        let type = property(src, kTISPropertyInputSourceType) ?? "?"
        let kind = type == (kTISTypeKeyboardLayout as String) ? "键盘布局" : "输入法　"
        print("  [\(kind)] \(name)\n             \(id)")
    }
    print("\n切换测试：swift tools/check_switch.swift <sourceID> [<sourceID>…]")
}

func selectByID(_ id: String) -> Bool {
    let filter: [CFString: Any] = [kTISPropertyInputSourceID: id]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first
    else {
        print("找不到 sourceID=\(id)（是否已在系统设置里启用？）")
        return false
    }
    let r = TISSelectInputSource(src)
    return r == noErr
}

let targets = Array(CommandLine.arguments.dropFirst())

if targets.isEmpty {
    listEnabledSources()
} else {
    let original = currentSnapshot()
    print("起始: \(original)")
    for id in targets {
        print("→ 切到 \(id)：\(selectByID(id))")
        Thread.sleep(forTimeInterval: 0.6)
        print("当前: \(currentSnapshot())")
    }
}
