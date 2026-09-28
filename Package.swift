// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeUsageMonitor", targets: ["ClaudeUsageMonitor"]),
    ],
    targets: [
        // 纯数据层：解析、去重、定价、时间窗口计算。与 UI 无关，便于单元测试。
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 菜单栏 App：AppKit 容器 + SwiftUI 视图 + 设计系统。
        .executableTarget(
            name: "ClaudeUsageMonitor",
            dependencies: ["UsageCore"],
            path: "Sources/ClaudeUsageMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
