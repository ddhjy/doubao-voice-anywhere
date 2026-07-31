import AppKit
import Foundation

enum InputSourceActivationNudgeSettings {
    struct Preset: Identifiable, Hashable {
        let name: String
        let bundleID: String

        var id: String { bundleID }
    }

    static let changedNotification = Notification.Name("InputSourceActivationNudgeSettings.changed")

    static let presets = [
        Preset(name: "Mira", bundleID: "net.byteintl.mira"),
        Preset(name: "Notion", bundleID: "notion.id"),
    ]

    private static let bundleIDsKey = "InputSourceActivationNudgeBundleIDs"
    private static let seededPresetBundleIDsKey = "InputSourceActivationNudgeSeededPresetBundleIDs_v2"
    private static let legacySeededDefaultsKey = "InputSourceActivationNudgeSeededDefaults_v1"

    /// Electron 类应用切完输入法后文本上下文经常滞后，把已确认受影响的应用
    /// 各补进白名单一次。记录的是已经补过的具体预设，用户移除后不会在下次启动
    /// 时被自动加回来；以后新增预设也可以只迁移新增的那一项。
    static func seedDefaultBundleIDsIfNeeded() {
        let defaults = UserDefaults.standard
        var seededBundleIDs = Set(defaults.stringArray(forKey: seededPresetBundleIDsKey) ?? [])

        // v1 只预置过 Notion。把这段历史迁进按项记录，避免曾经主动删除 Notion
        // 的老用户升级后又被自动加回来。
        if defaults.bool(forKey: legacySeededDefaultsKey) {
            seededBundleIDs.insert("notion.id")
        }

        let presetBundleIDs = Set(presets.map(\.bundleID))
        let newBundleIDs = presetBundleIDs.subtracting(seededBundleIDs)
        guard !newBundleIDs.isEmpty else { return }

        bundleIDs.formUnion(newBundleIDs)
        seededBundleIDs.formUnion(presetBundleIDs)
        defaults.set(Array(seededBundleIDs).sorted(), forKey: seededPresetBundleIDsKey)
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
