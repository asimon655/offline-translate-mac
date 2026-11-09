// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OfflineTranslate",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable without a GUI: the helper client, language rules, history.
        .target(name: "TranslateCore"),
        // The menu-bar app: AppKit + SwiftUI.
        .executableTarget(
            name: "OfflineTranslate",
            dependencies: ["TranslateCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(name: "TranslateCoreTests", dependencies: ["TranslateCore"]),
    ]
)
