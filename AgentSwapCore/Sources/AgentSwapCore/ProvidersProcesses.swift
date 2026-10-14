import Foundation
import AppKit
import Darwin

public enum CodexConsumerKind: String, Sendable { case desktop, commandLine, ide, daemon }
public struct CodexConsumer: Sendable, Equatable {
    public var pid: Int32
    public var kind: CodexConsumerKind
    public var name: String
    public init(pid: Int32, kind: CodexConsumerKind, name: String) { self.pid = pid; self.kind = kind; self.name = name }
}
public struct CodexProcessScan: Sendable {
    public var consumers: [CodexConsumer]
    public var reliable: Bool
    public init(consumers: [CodexConsumer] = [], reliable: Bool = true) { self.consumers = consumers; self.reliable = reliable }
    public var hasConsumers: Bool { !reliable || !consumers.isEmpty }
}
public struct CodexDesktopInstallation: Sendable {
    public var url: URL
    public var version: String
    public var bundleID: String
    public init(url: URL, version: String, bundleID: String = "com.openai.codex") { self.url = url; self.version = version; self.bundleID = bundleID }
}
public protocol CodexProcessControlling: Sendable {
    func scan() async -> CodexProcessScan
    func installation() async -> CodexDesktopInstallation?
    func requestDesktopTermination() async -> Bool
    func relaunchDesktop() async throws
}

/// Detects desktop helpers, CLI, IDE bundles, and app-server/daemon versions without executing Codex.
public struct SystemCodexProcessController: CodexProcessControlling {
    public static let desktopBundleID = "com.openai.codex"
    public init() {}
    public func installation() async -> CodexDesktopInstallation? {
        await MainActor.run {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.desktopBundleID),
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == Self.desktopBundleID else { return nil }
            return .init(url: url, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "알 수 없음")
        }
    }
    public func scan() async -> CodexProcessScan {
        let desktopURL = await installation()?.url
        let desktopPIDs = await MainActor.run {
            Set(NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundleID).map(\.processIdentifier))
        }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return .init(reliable: false) }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let result = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard result > 0, Int(result) < pids.count else { return .init(reliable: false) }
        var consumers: [CodexConsumer] = []
        for pid in pids.prefix(Int(result)) where pid > 0 {
            var nameBytes = [CChar](repeating: 0, count: 256)
            let nameCount = proc_name(pid, &nameBytes, UInt32(nameBytes.count))
            guard nameCount > 0 else { continue } // Short lived processes may vanish during enumeration.
            let name = String(decoding: nameBytes.prefix(Int(nameCount)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable to Swift.
            var pathBytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathCount = proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count))
            let path = pathCount > 0 ? String(decoding: pathBytes.prefix(Int(pathCount)).map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 }), as: UTF8.self) : ""
            let lowerName = name.lowercased(), lowerPath = path.lowercased()
            let candidate = lowerName.contains("codex") || lowerName == "chatgpt" || lowerName.hasPrefix("node") || lowerName.contains("code")
            guard candidate || desktopURL.map({ path.hasPrefix($0.path + "/") }) == true else { continue }
            let arguments = Self.commandLine(pid: pid)
            let isBundledCLI = lowerName == "codex" && desktopURL.map({ path.hasPrefix($0.path + "/") }) == true
            let owned = isBundledCLI ? Self.desktopOwnership(pid: pid, desktopPIDs: desktopPIDs) : true
            guard let owned else { return .init(consumers: consumers, reliable: false) }
            if let consumer = Self.classify(pid: pid, name: name, executable: path, arguments: arguments ?? "", desktopURL: desktopURL, desktopOwned: owned) {
                consumers.append(consumer)
            } else if arguments == nil && (lowerName.contains("codex") || lowerName.hasPrefix("node") || lowerPath.contains("openai.chatgpt")) {
                return .init(consumers: consumers, reliable: false)
            }
        }
        return .init(consumers: consumers)
    }
    public static func classify(pid: Int32, name: String, executable: String, arguments: String, desktopURL: URL?, desktopOwned: Bool = true) -> CodexConsumer? {
        let path = executable.lowercased(), command = arguments.lowercased(), short = name.lowercased()
        if desktopOwned, let desktopURL, executable.hasPrefix(desktopURL.path + "/") {
            return .init(pid: pid, kind: .desktop, name: name)
        }
        let isCodex = short == "codex" || short.hasPrefix("codex-") || path.hasSuffix("/codex") || command.contains("@openai/codex") || command.contains("codex.js")
        let isExtension = path.contains("openai.chatgpt") || command.contains("openai.chatgpt") || path.contains("openai.codex") || command.contains("openai.codex")
        guard isCodex || isExtension else { return nil }
        if isExtension || path.contains(".vscode/extensions/") || path.contains(".cursor/extensions/") || path.contains(".jetbrains/") { return .init(pid: pid, kind: .ide, name: "Codex IDE") }
        if short.contains("daemon") || command.contains("app-server") || command.contains(" daemon") { return .init(pid: pid, kind: .daemon, name: "Codex 서버") }
        return .init(pid: pid, kind: .commandLine, name: "Codex CLI")
    }
    private static func desktopOwnership(pid: Int32, desktopPIDs: Set<Int32>) -> Bool? {
        if desktopPIDs.isEmpty { return false }
        var current = pid, visited = Set<Int32>()
        for _ in 0..<64 {
            if desktopPIDs.contains(current) { return true }
            guard current > 1 else { return false }
            guard visited.insert(current).inserted else { return nil }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(current, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
            guard read == size else { return nil }
            current = Int32(info.pbi_ppid)
        }
        return nil
    }
    private static func commandLine(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &count, nil, 0) == 0, count > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &count, nil, 0) }
        guard status == 0 else { return nil }
        // Read only argc command arguments, excluding environment variables which may contain secrets.
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var offset = MemoryLayout<Int32>.size
        while offset < count && bytes[offset] != 0 { offset += 1 }
        while offset < count && bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<max(0, argc) {
            let start = offset
            while offset < count && bytes[offset] != 0 { offset += 1 }
            if start < offset { arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self)) }
            offset += 1
        }
        return arguments.joined(separator: " ")
    }
    public func requestDesktopTermination() async -> Bool {
        await MainActor.run {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundleID)
            return running.allSatisfy { $0.terminate() } // Sends a normal quit request; never force terminates.
        }
    }
    public func relaunchDesktop() async throws {
        guard let installation = await installation() else { throw AgentSwapError.unsupported("Codex 데스크톱 앱을 찾지 못했습니다.") }
        try await Self.openDesktop(at: installation.url)
    }
    @MainActor private static func openDesktop(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if error != nil || app == nil { continuation.resume(throwing: AgentSwapError.unsupported("Codex 데스크톱 앱을 실행하지 못했습니다.")) }
                else { continuation.resume() }
            }
        }
    }
}
