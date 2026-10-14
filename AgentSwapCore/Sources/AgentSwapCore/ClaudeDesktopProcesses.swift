import Foundation
import AppKit
import Darwin
import CoreFoundation

public struct ClaudeDesktopConversationInstallation: Sendable, Equatable {
    public var url: URL
    public var version: String
    public init(url: URL, version: String) { self.url = url; self.version = version }
}

public struct ClaudeDesktopConversationProcessIdentity: Sendable, Hashable {
    public var pid: Int32
    public var startedAt: UInt64
    public init(pid: Int32, startedAt: UInt64) { self.pid = pid; self.startedAt = startedAt }
}

public struct ClaudeDesktopConversationProcessSnapshot: Sendable {
    public var desktop: Set<ClaudeDesktopConversationProcessIdentity>
    public var related: Set<ClaudeDesktopConversationProcessIdentity>
    public var live: Set<ClaudeDesktopConversationProcessIdentity>
    public var reliable: Bool
    public init(desktop: Set<ClaudeDesktopConversationProcessIdentity> = [], related: Set<ClaudeDesktopConversationProcessIdentity> = [],
                live: Set<ClaudeDesktopConversationProcessIdentity> = [], reliable: Bool = true) {
        self.desktop = desktop; self.related = related; self.live = live; self.reliable = reliable
    }
}

public protocol ClaudeDesktopConversationProcessControlling: Sendable {
    func installation(at applicationURL: URL?) async -> ClaudeDesktopConversationInstallation?
    func scan(applicationURL: URL) async -> ClaudeDesktopConversationProcessSnapshot
    func requestNormalTermination() async -> Bool
    func relaunch(at applicationURL: URL) async throws
}

public actor SystemClaudeDesktopConversationProcessController: ClaudeDesktopConversationProcessControlling {
    public static let bundleID = "com.anthropic.claudefordesktop"
    private var previouslyRelated: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]
    public init() {}
    public func installation(at applicationURL: URL?) async -> ClaudeDesktopConversationInstallation? {
        await MainActor.run {
            guard let url = applicationURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == Self.bundleID,
                  let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
            return .init(url: url, version: version)
        }
    }
    public func scan(applicationURL: URL) async -> ClaudeDesktopConversationProcessSnapshot {
        let applications = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).map { ($0.processIdentifier, $0.bundleURL) }
        }
        guard applications.allSatisfy({ $0.1?.standardizedFileURL == applicationURL.standardizedFileURL }) else { return .init(reliable: false) }
        let desktopPIDs = Set(applications.map { $0.0 })
        // Foreign system processes routinely reject BSD-info reads. Enumerate the current user,
        // then explicitly follow every related child (including a child which changes its uid).
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard byteCount > 0 else { return .init(reliable: false) }
        var pids = [Int32](repeating: 0, count: Int(byteCount) / MemoryLayout<Int32>.size + 256)
        let read = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, Int32($0.count)) }
        guard read > 0, Int(read) / MemoryLayout<Int32>.size < pids.count else { return .init(reliable: false) }
        var identities: [Int32: ClaudeDesktopConversationProcessIdentity] = [:], parents: [Int32: Int32] = [:]
        var bundled = Set<Int32>()
        for pid in pids.prefix(Int(read) / MemoryLayout<Int32>.size) where pid > 0 {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
            if result != size {
                if errno == ESRCH { continue }
                return .init(reliable: false)
            }
            identities[pid] = .init(pid: pid, startedAt: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
            parents[pid] = Int32(info.pbi_ppid)
            var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            if length > 0 {
                let path = String(decoding: bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 }), as: UTF8.self)
                if path.hasPrefix(applicationURL.path + "/") { bundled.insert(pid) }
            }
        }
        guard desktopPIDs.allSatisfy({ identities[$0] != nil }) else { return .init(reliable: false) }
        var relatedPIDs = desktopPIDs.union(bundled), changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where relatedPIDs.contains(parent) {
                if relatedPIDs.insert(pid).inserted { changed = true }
            }
        }
        var pendingParents = Array(relatedPIDs), checkedParents = Set<Int32>()
        while let parent = pendingParents.popLast() {
            guard checkedParents.insert(parent).inserted else { continue }
            let count = proc_listchildpids(parent, nil, 0)
            guard count >= 0 else { return .init(reliable: false) }
            if count == 0 { continue }
            var children = [Int32](repeating: 0, count: Int(count) + 64)
            let childCount = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            guard childCount >= 0, Int(childCount) < children.count else { return .init(reliable: false) }
            for child in children.prefix(Int(childCount)) where child > 0 {
                if identities[child] == nil {
                    var info = proc_bsdinfo()
                    let size = MemoryLayout<proc_bsdinfo>.size
                    let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(child, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
                    if result != size {
                        if errno == ESRCH { continue }
                        return .init(reliable: false)
                    }
                    identities[child] = .init(pid: child, startedAt: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
                }
                relatedPIDs.insert(child); pendingParents.append(child)
            }
        }
        for (pid, identity) in previouslyRelated where identities[pid] == nil {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
            if result != size {
                if errno == ESRCH { continue }
                return .init(reliable: false)
            }
            let current = ClaudeDesktopConversationProcessIdentity(pid: pid, startedAt: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
            if current == identity { identities[pid] = current }
        }
        for pid in relatedPIDs { previouslyRelated[pid] = identities[pid] }
        return .init(desktop: Set(desktopPIDs.compactMap { identities[$0] }), related: Set(relatedPIDs.compactMap { identities[$0] }), live: Set(identities.values))
    }
    public func requestNormalTermination() async -> Bool {
        await MainActor.run { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).allSatisfy { $0.terminate() } }
    }
    public func relaunch(at applicationURL: URL) async throws { try await Self.open(at: applicationURL) }
    @MainActor private static func open(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                if error != nil || application == nil { continuation.resume(throwing: AgentSwapError.storage("Claude 데스크톱을 다시 열지 못했습니다.")) }
                else { continuation.resume() }
            }
        }
    }
}
