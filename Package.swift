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
    targets: [
        .executableTarget(
            name: "VibeCompanion",
            path: "VibeCompanion/Sources",
            resources: [
                .copy("Resources/litellm-pricing-snapshot.json")
            ]
        ),
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests",
            resources: [
                .copy("Fixtures/claude-golden.jsonl")
            ]
        )
    ]
)
