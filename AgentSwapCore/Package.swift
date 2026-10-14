// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSwapCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentSwapCore", targets: ["AgentSwapCore"])],
    targets: [
        .target(name: "AgentSwapCore", resources: [.copy("Resources/ClaudeKeychainWriter.swift")]),
        .testTarget(name: "AgentSwapCoreTests", dependencies: ["AgentSwapCore"])
    ],
    swiftLanguageModes: [.v6]
)
