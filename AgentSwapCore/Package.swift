// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSwapCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentSwapCore", targets: ["AgentSwapCore"])],
    targets: [
        .target(name: "AgentSwapVaultProtocol"),
        .executableTarget(name: "AgentSwapVaultService", dependencies: ["AgentSwapVaultProtocol"], exclude: ["Info.plist"]),
        .target(name: "AgentSwapCore", dependencies: ["AgentSwapVaultProtocol"], resources: [.copy("Resources/ClaudeKeychainWriter.swift")]),
        .testTarget(name: "AgentSwapVaultServiceTests", dependencies: ["AgentSwapVaultService", "AgentSwapVaultProtocol"]),
        .testTarget(name: "AgentSwapCoreTests", dependencies: ["AgentSwapCore"])
    ],
    swiftLanguageModes: [.v6]
)
