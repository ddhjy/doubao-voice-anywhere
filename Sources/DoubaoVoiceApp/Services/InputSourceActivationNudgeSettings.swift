import AppKit
import Foundation

enum InputSourceActivationNudgeSettings {
    static let changedNotification = Notification.Name("InputSourceActivationNudgeSettings.changed")

    private static let bundleIDsKey = "InputSourceActivationNudgeBundleIDs"

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
