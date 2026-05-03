// 离线测试脚本：手动复现 InputSourceManager 的切换链路。
// 用法：swift tools/check_switch.swift
import Carbon
import Foundation

func name(of src: TISInputSource) -> String {
    guard let raw = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func sourceID(of src: TISInputSource) -> String {
    guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func currentSnapshot() -> String {
    guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "nil" }
    return "\(name(of: cur))  \(sourceID(of: cur))"
}

func selectByID(_ id: String) -> Bool {
    let filter: [CFString: Any] = [kTISPropertyInputSourceID: id]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource], let src = list.first else {
        print("找不到 sourceID=\(id)")
        return false
    }
    let r = TISSelectInputSource(src)
    return r == noErr
}

let doubao = "com.bytedance.inputmethod.doubaoime.pinyin"
let squirrelHans = "im.rime.inputmethod.Squirrel.Hans"
let usLayout = "com.apple.keylayout.US"

print("起始: \(currentSnapshot())")

print("→ 切到豆包：\(selectByID(doubao))")
Thread.sleep(forTimeInterval: 0.6)
print("当前: \(currentSnapshot())")

print("→ 切回鼠须管 .Hans：\(selectByID(squirrelHans))")
Thread.sleep(forTimeInterval: 0.6)
print("当前: \(currentSnapshot())")

print("→ 切到 U.S. 键盘布局：\(selectByID(usLayout))")
Thread.sleep(forTimeInterval: 0.6)
print("当前: \(currentSnapshot())")

print("→ 切回鼠须管 .Hans：\(selectByID(squirrelHans))")
Thread.sleep(forTimeInterval: 0.6)
print("最终: \(currentSnapshot())")
