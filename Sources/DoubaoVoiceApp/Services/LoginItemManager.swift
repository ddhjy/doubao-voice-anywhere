import Foundation

enum LoginItemManager {
    // label 从 bundle ID 派生，让开发版（….menubar.dev）与正式版的登录项
    // 互不覆盖；正式版结果与旧版硬编码值一致，保持向后兼容。
    private static let label =
        "\(Bundle.main.bundleIdentifier ?? "com.doubaovoiceapp.menubar").autostart"
    private static let launchAgentFileName = "\(label).plist"

    static var isEnabled: Bool {
        guard let url = launchAgentURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    static func refreshIfEnabled() throws {
        guard isEnabled else { return }
        try enable()
    }

    private static func enable() throws {
        guard let launchAgentURL = launchAgentURL else {
            throw LoginItemError.launchAgentsDirectoryUnavailable
        }

        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw LoginItemError.notRunningFromAppBundle(appURL.path)
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                "-g",
                appURL.path,
            ],
            "RunAtLoad": true,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let directoryURL = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: launchAgentURL, options: .atomic)
        Logger.shared.info("已启用登录时自动启动: \(launchAgentURL.path)")
    }

    private static func disable() throws {
        guard let url = launchAgentURL else {
            throw LoginItemError.launchAgentsDirectoryUnavailable
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        Logger.shared.info("已关闭登录时自动启动")
    }

    private static var launchAgentURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(launchAgentFileName)
    }
}

private enum LoginItemError: LocalizedError {
    case launchAgentsDirectoryUnavailable
    case notRunningFromAppBundle(String)

    var errorDescription: String? {
        switch self {
        case .launchAgentsDirectoryUnavailable:
            return "无法定位当前用户的 LaunchAgents 目录。"
        case .notRunningFromAppBundle(let path):
            return "请从 .app 应用包运行后再开启自启动。当前路径：\(path)"
        }
    }
}
