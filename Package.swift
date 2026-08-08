// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageRing",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "UsageRing",
            path: "Sources/UsageRing"
        ),
        .testTarget(
            name: "UsageRingTests",
            dependencies: ["UsageRing"],
            path: "Tests/UsageRingTests"
        ),
    ]
)
