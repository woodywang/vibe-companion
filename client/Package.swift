// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeCompanion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VibeCompanion", targets: ["VibeCompanion"])
    ],
    dependencies: [
        // 轻量 SQLite 客户端，存储用量缓冲与 offset 游标
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeCompanion",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "VibeCompanion/Sources"
            // 速度表为纯 SwiftUI 绘制，无需 Lottie 资源
        ),
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests"
        )
    ]
)
