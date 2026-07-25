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
        // Lottie 矢量动画：蹬车速度映射 animationSpeed
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.5.0"),
        // 轻量 SQLite 客户端，存储用量缓冲与 offset 游标
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeCompanion",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "VibeCompanion/Sources",
            resources: [
                // 默认蹬车形象动画（MVP 占位，后续替换原创）
                .copy("../Resources/Animations")
            ]
        )
        ,
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests"
        )
    ]
)
