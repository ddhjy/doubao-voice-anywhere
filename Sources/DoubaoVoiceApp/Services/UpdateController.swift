import AppKit
import Sparkle

/// 自动更新（Sparkle）。
///
/// 更新源是仓库里的 `appcast.xml`，地址与 EdDSA 公钥都写在 Info.plist。
/// 开发版不参与更新：`build.sh --dev` 会把 `SUFeedURL` 从 Info.plist 里剥掉，
/// 这里读不到 feed 就整个不实例化 updater，菜单和设置里的更新入口也一并隐藏
/// ——否则 Dev.app 一更新就会被正式版覆盖掉。
///
/// 只在主线程使用：Sparkle 的 `SPUStandardUpdaterController` 要求如此，
/// 它的回调也一律在主线程发出。
final class UpdateController: NSObject {

    /// 自动检查开关变化时发出，设置界面据此刷新。
    static let changedNotification = Notification.Name("UpdateController.changed")

    /// Info.plist 里配了 feed 才启用。为 false 时下面所有方法都是空操作。
    let isEnabled: Bool

    private var updaterController: SPUStandardUpdaterController?

    /// 更新会话期间临时切到 `.regular` 之前的激活策略，会话结束后还原。
    private var activationPolicyBeforeSession: NSApplication.ActivationPolicy?

    override init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        isEnabled = !(feedURL ?? "").isEmpty
        super.init()

        guard isEnabled else {
            Logger.shared.info("未配置更新源，自动更新已停用（开发版正常如此）")
            return
        }

        // updaterDelegate / userDriverDelegate 都是弱引用，靠本对象被 AppDelegate 持有存活。
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        Logger.shared.info("自动更新已启动，更新源: \(feedURL ?? "")")
    }

    // MARK: - 对外接口

    /// 菜单项「检查更新…」的 target。Sparkle 自己会按 `canCheckForUpdates` 处理灰显，
    /// 所以不用额外写 `validateMenuItem`。
    var menuItemTarget: AnyObject? { updaterController }

    var menuItemAction: Selector { #selector(SPUStandardUpdaterController.checkForUpdates(_:)) }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater = updaterController?.updater,
                  updater.automaticallyChecksForUpdates != newValue
            else { return }
            updater.automaticallyChecksForUpdates = newValue
            Logger.shared.info("自动检查更新已\(newValue ? "开启" : "关闭")")
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }

    /// 设置界面「现在检查」用。会弹进度框并汇报结果，等同于菜单里那一项。
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Logger.shared.info("发现新版本: \(item.displayVersionString)（当前 \(Self.currentDisplayVersion)）")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Logger.shared.info("已是最新版本: \(Self.currentDisplayVersion)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Logger.shared.info("开始安装新版本: \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // 用户主动取消也走这里，不当成错误刷 WARN。
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.installationCanceledError.rawValue) {
            Logger.shared.info("用户取消了更新")
            return
        }
        Logger.shared.warn("更新失败: \(error.localizedDescription)")
    }

    static var currentDisplayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {

    /// 后台 App 的必需项。Sparkle 2.2 起，无 Dock 图标的 App 定时检查到新版本时不再抢焦点，
    /// 提示窗会压在别的窗口后面；声明支持后由下面两个回调负责把窗口露出来。
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // `.accessory` 下的窗口进不了 Cmd-Tab、Dock 里也没有图标，用户很容易把更新窗口
        // 弄丢；更新期间临时变成普通 App，会话结束再变回去。
        if activationPolicyBeforeSession == nil {
            activationPolicyBeforeSession = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }

        if state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // 定时检查撞见新版本：不抢用户正在做的事，只让 Dock 图标弹跳提醒。
            NSApp.requestUserAttention(.informationalRequest)
            Logger.shared.info("定时检查发现新版本 \(update.displayVersionString)，已提示用户")
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard let policy = activationPolicyBeforeSession else { return }
        activationPolicyBeforeSession = nil
        NSApp.setActivationPolicy(policy)
    }
}
