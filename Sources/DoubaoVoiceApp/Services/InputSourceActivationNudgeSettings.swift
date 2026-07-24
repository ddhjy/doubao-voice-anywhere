import AppKit
import Foundation

enum InputSourceActivationNudgeSettings {
    static let changedNotification = Notification.Name("InputSourceActivationNudgeSettings.changed")

    private static let bundleIDsKey = "InputSourceActivationNudgeBundleIDs"
    private static let seededDefaultsKey = "InputSourceActivationNudgeSeededDefaults_v1"

    /// Electron 类应用切完输入法后文本上下文经常滞后，把已确认受影响的应用
    /// 一次性补进白名单（用户仍可在设置界面移除，之后不会再自动加回来）。
    static func seedDefaultBundleIDsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededDefaultsKey) else { return }
        defaults.set(true, forKey: seededDefaultsKey)

        for bundleID in ["notion.id"] where !bundleIDs.contains(bundleID) {
            add(bundleID: bundleID)
        }
    }

    static var bundleIDs: Set<String> {
        get {
            let values = UserDefaults.standard.stringArray(forKey: bundleIDsKey) ?? []
            return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        set {
            let values = Array(newValue).sorted()
            UserDefaults.standard.set(values, forKey: bundleIDsKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
            Logger.shared.info("输入源激活补丁 App 白名单已更新: \(values.joined(separator: ", "))")
        }
    }

    @discardableResult
    static func add(bundleID: String) -> Bool {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        var values = bundleIDs
        let inserted = values.insert(normalized).inserted
        bundleIDs = values
        return inserted
    }

    static func remove(bundleID: String) {
        var values = bundleIDs
        values.remove(bundleID)
        bundleIDs = values
    }

    static func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "未安装"
        }

        if let displayName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}
