import AppKit

/// 应用入口。
///
/// AppKit 菜单栏 / 后台型应用：
/// - 不需要 Dock 图标和主菜单
/// - `LSUIElement = true`（Info.plist）+ `.accessory` activation policy 双保险
@main
enum DoubaoVoiceApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
