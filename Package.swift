// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropship",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dropship",
            path: "Sources/Dropship",
            swiftSettings: [
                // 采用 Swift 5 语言模式：本项目大量使用 AppKit 委托与回调，
                // Swift 6 严格并发检查会带来与业务无关的大量改造成本。
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DropshipTests",
            dependencies: ["Dropship"],
            path: "Tests/DropshipTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
