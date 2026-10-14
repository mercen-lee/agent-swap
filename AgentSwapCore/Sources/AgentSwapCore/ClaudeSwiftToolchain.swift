import Foundation
import Security

/// Large Claude writes use an Apple-signed Swift process so SecurityTool remains able
/// to read the existing item's Apple-tool partition. Credentials never enter arguments.
struct ClaudeSwiftToolchain: Sendable {
    let executableURL: URL
    let sdkURL: URL

    static func resolve() throws -> Self {
        let files = FileManager.default
        var developerDirectories = ["/Library/Developer/CommandLineTools"]
        if let selected = try? files.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"), selected.hasPrefix("/") {
            developerDirectories.append(selected)
        }
        developerDirectories.append("/Applications/Xcode.app/Contents/Developer")
        for directory in developerDirectories {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let commandLineTools = root.lastPathComponent == "CommandLineTools"
            let executable = root.appendingPathComponent(commandLineTools ? "usr/bin/swift-frontend" : "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend").resolvingSymlinksInPath()
            let sdk = root.appendingPathComponent(commandLineTools ? "SDKs/MacOSX.sdk" : "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").resolvingSymlinksInPath()
            guard files.isExecutableFile(atPath: executable.path), isTrustedInterpreter(executable),
                  files.fileExists(atPath: sdk.appendingPathComponent("System/Library/Frameworks/Security.framework").path),
                  files.fileExists(atPath: sdk.appendingPathComponent("System/Library/Frameworks/Foundation.framework").path) else { continue }
            return .init(executableURL: executable, sdkURL: sdk)
        }
        throw AgentSwapError.unsupported("큰 Claude 인증을 저장하려면 Apple Command Line Tools 또는 Xcode가 필요합니다. 설치 후 전환 호환성을 다시 확인해 주세요.")
    }

    static func isTrustedInterpreter(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: 0)
        guard SecStaticCodeCreateWithPath(url as CFURL, flags, &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.swift-frontend\"" as CFString,
                                             flags, &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
