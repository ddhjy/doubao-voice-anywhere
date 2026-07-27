// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoubaoVoiceApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // 自动更新。2.9.4 修了「后台 app 的窗口拿不到焦点」，菜单栏 App 必须用这版起。
        //
        // 锁到 2.9.x：Package.resolved 不入库（见 .gitignore），CI 每次都重新解析依赖，
        // 而 Sparkle 的 2.x 分支已经在往上抬最低系统版本要求。放开 minor 的话，
        // 某天 CI 会悄悄换成一个跑不了 macOS 13 的版本。
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.4"))
    ],
    targets: [
        .executableTarget(
            name: "DoubaoVoiceApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                // .app 里 Sparkle.framework 在 Contents/Frameworks，而 SwiftPM 默认
                // 只加 @loader_path（= Contents/MacOS），运行时找不到框架。
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
