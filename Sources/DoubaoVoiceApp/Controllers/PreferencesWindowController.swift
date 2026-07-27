import AppKit
import SwiftUI

/// 「设置」窗口：工具栏式分栏，每个分栏是一张 SwiftUI 分组 Form。
/// - 「通用」：说话快捷键、启动方式、说话时的媒体行为、辅助功能权限
/// - 「输入法」：日常中文输入法 / 英文键盘布局，以及轮换的开关与快捷键
/// - 「应用兼容性」：需要输入上下文刷新的 App 白名单
///
/// 用 `NSTabViewController` 而不是 SwiftUI 的 `Settings` scene：本 App 是手写
/// `NSApplication` 入口的 AppKit 程序，没有 SwiftUI `App`，`TabView` 放进
/// `NSHostingController` 只会渲染成普通分段控件，拿不到设置窗口的工具栏样式、
/// 标题跟随分栏、切换分栏时窗口自动改尺寸这些系统行为。
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    /// 分栏内容的固定宽度。窗口宽度由它决定，高度交给各分栏的固有尺寸。
    private static let paneWidth: CGFloat = 480

    private let store: SettingsStore

    /// - Parameters:
    ///   - restartEventTap: 「重新连接键盘监听」的实现，由 AppDelegate 注入。
    ///   - setHotkeyCaptureActive: 录制快捷键期间暂停 event tap 拦截，同上。
    ///   - updateBridge: 自动更新的开关与「现在检查」，同上。
    init(
        restartEventTap: @escaping () -> Void,
        setHotkeyCaptureActive: @escaping (Bool) -> Void,
        updateBridge: SettingsStore.UpdateBridge
    ) {
        store = SettingsStore(
            restartEventTap: restartEventTap,
            setHotkeyCaptureActive: setHotkeyCaptureActive,
            updateBridge: updateBridge
        )

        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar
        tabController.addTabViewItem(
            Self.paneItem(label: "通用", symbol: "gearshape", content: GeneralSettingsPane(store: store))
        )
        tabController.addTabViewItem(
            Self.paneItem(label: "输入法", symbol: "keyboard", content: InputSourceSettingsPane(store: store))
        )
        tabController.addTabViewItem(
            Self.paneItem(
                label: "应用兼容性",
                symbol: "puzzlepiece.extension",
                content: AppCompatibilityPane(store: store)
            )
        )

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        // 切换分栏时 NSTabViewController 会把标题换成分栏名，初始标题也对齐它。
        window.title = tabController.tabViewItems.first?.label ?? "设置"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        store.hostWindow = window
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        store.refresh()
        store.startPermissionPolling()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.stopPermissionPolling()
        // 录到一半就关窗口的话，键盘监听器和暂停中的全局拦截都得收掉。
        store.cancelHotkeyRecording()
    }

    private static func paneItem<Content: View>(
        label: String,
        symbol: String,
        content: Content
    ) -> NSTabViewItem {
        let controller = NSHostingController(rootView: content.frame(width: paneWidth))
        // 让 SwiftUI 内容的固有尺寸决定窗口大小，切换分栏时窗口会跟着调整。
        controller.sizingOptions = [.preferredContentSize]
        // NSTabViewController 用它给窗口起标题；不设就会显示「未命名」。
        controller.title = label

        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}
