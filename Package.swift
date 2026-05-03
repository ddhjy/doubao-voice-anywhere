// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoubaoVoiceApp",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "DoubaoVoiceApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
