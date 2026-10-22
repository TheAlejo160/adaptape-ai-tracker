// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdaptaPEAITracker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AdaptaPEAITracker", path: "Sources/AdaptaPEAITracker"),
        .testTarget(name: "AdaptaPEAITrackerTests", dependencies: ["AdaptaPEAITracker"])
    ]
)
