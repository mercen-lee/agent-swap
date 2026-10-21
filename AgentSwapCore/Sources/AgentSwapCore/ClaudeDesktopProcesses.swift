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

/// Auth transactions cannot suspend between their process fence and a file mutation.
/// Tests inject this boundary separately from the asynchronous Desktop controller.
public protocol ClaudeDesktopMutationProcessChecking: Sendable {
    func verifyStopped(applicationURL: URL, tracked: Set<ClaudeDesktopConversationProcessIdentity>) throws
}

public struct SystemClaudeDesktopMutationProcessChecker: ClaudeDesktopMutationProcessChecking {
    public init() {}

    public func verifyStopped(applicationURL: URL, tracked: Set<ClaudeDesktopConversationProcessIdentity>) throws {
        for expected in tracked {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let found = withUnsafeMutablePointer(to: &info) { proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
            if found == size {
                // A zombie has exited and cannot consume credentials or write files, even
                // while its parent has not reaped the PID and kill(pid, 0) still succeeds.
                guard let current = ClaudeDesktopProcessTracking.identity(for: expected.pid, info: info) else { continue }
                guard current.startedAt != expected.startedAt else { throw AgentSwapError.storage("Claude 관련 프로세스가 남아 인증 저장을 중단했습니다.") }
            } else if !ClaudeDesktopProcessTracking.hasExited(pid: expected.pid) {
                throw AgentSwapError.storage("Claude 관련 프로세스 종료를 확인하지 못했습니다.")
            }
        }
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard byteCount > 0 else { throw AgentSwapError.storage("Claude 데스크톱 프로세스를 다시 확인하지 못했습니다.") }
        var pids = [Int32](repeating: 0, count: max(1, Int(byteCount) / MemoryLayout<Int32>.size + 64))
        let result = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, Int32($0.count)) }
        guard result > 0, Int(result) / MemoryLayout<Int32>.size < pids.count else { throw AgentSwapError.storage("Claude 데스크톱 프로세스를 다시 확인하지 못했습니다.") }
        for pid in pids.prefix(Int(result) / MemoryLayout<Int32>.size) where pid > 0 {
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            if count <= 0 {
                // ESRCH alone can also mean hidden access. Require a positive zombie
                // state when libproc cannot inspect an unreaped PID.
                if ClaudeDesktopProcessTracking.hasExited(pid: pid) { continue }
                throw AgentSwapError.storage("Claude 데스크톱 프로세스 경로를 확인하지 못했습니다.")
            }
            let path = String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(applicationURL.path + "/") { throw AgentSwapError.storage("Claude 데스크톱이 다시 실행되어 인증 저장을 중단했습니다.") }
        }
    }
}

/// Reconciles a prior Claude process generation with the current process inventory.
/// A cached PID is only retained when its start time proves it is the same process;
/// this keeps an orphaned helper visible across a retry without mistaking PID reuse
/// for the prior Desktop generation.
enum ClaudeDesktopProcessTracking {
    static func hasExited(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let killResult = Darwin.kill(pid, 0)
        let killError = errno
        return hasExited(pid: pid, killResult: killResult, killErrno: killError, confirmedZombie: confirmedZombie(pid: pid))
    }

    static func hasExited(pid: Int32, killResult: Int32, killErrno: Int32, confirmedZombie: Bool) -> Bool {
        guard pid > 0 else { return false }
        return (killResult == -1 && killErrno == ESRCH) || confirmedZombie
    }

    static func confirmedZombie(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let count = UInt32(mib.count)
        var info = kinfo_proc()
        var bytes = MemoryLayout<kinfo_proc>.size
        let result = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, count, &info, &bytes, nil, 0)
        }
        return confirmsZombie(info: info, result: result, returnedBytes: bytes)
    }

    static func confirmsZombie(info: kinfo_proc, result: Int32, returnedBytes: Int) -> Bool {
        result == 0 && returnedBytes == MemoryLayout<kinfo_proc>.size && Int32(info.kp_proc.p_stat) == SZOMB
    }

    enum MissingInventoryLookup {
        case live(ClaudeDesktopConversationProcessIdentity)
        case absent
        case unavailable
    }

    /// A zombie has exited and cannot retain or consume Desktop authentication.
    /// Other status values remain conservatively live because their meaning is
    /// process-state specific rather than proof of exit.
    static func identity(for pid: Int32, info: proc_bsdinfo) -> ClaudeDesktopConversationProcessIdentity? {
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return .init(pid: pid, startedAt: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    static func reconcile(
        previouslyRelated: inout [Int32: ClaudeDesktopConversationProcessIdentity],
        currentIdentities: inout [Int32: ClaudeDesktopConversationProcessIdentity],
        directRelated: Set<Int32>,
        parents: [Int32: Int32],
        missingInventory: [Int32: MissingInventoryLookup]
    ) throws -> Set<Int32> {
        var roots = directRelated
        for (pid, cached) in Array(previouslyRelated) {
            if let current = currentIdentities[pid] {
                guard current == cached else {
                    previouslyRelated.removeValue(forKey: pid)
                    continue
                }
                roots.insert(pid)
                continue
            }
            guard let lookup = missingInventory[pid] else {
                throw AgentSwapError.storage("Claude Desktop 프로세스 상태를 확인하지 못했습니다.")
            }
            switch lookup {
            case .live(let current) where current == cached:
                currentIdentities[pid] = current
                roots.insert(pid)
            case .absent, .live:
                previouslyRelated.removeValue(forKey: pid)
            case .unavailable:
                throw AgentSwapError.storage("Claude Desktop 프로세스 상태를 확인하지 못했습니다.")
            }
        }

        var related = roots
        var changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where related.contains(parent) {
                if related.insert(pid).inserted { changed = true }
            }
        }
        previouslyRelated = Dictionary(uniqueKeysWithValues: related.compactMap { pid in
            currentIdentities[pid].map { (pid, $0) }
        })
        return related
    }
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
                if ClaudeDesktopProcessTracking.hasExited(pid: pid) { continue }
                return .init(reliable: false)
            }
            guard let identity = ClaudeDesktopProcessTracking.identity(for: pid, info: info) else { continue }
            identities[pid] = identity
            parents[pid] = Int32(info.pbi_ppid)
            var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            if length > 0 {
                let path = String(decoding: bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) }.prefix(while: { $0 != 0 }), as: UTF8.self)
                if path.hasPrefix(applicationURL.path + "/") { bundled.insert(pid) }
            }
        }
        guard desktopPIDs.allSatisfy({ identities[$0] != nil }) else { return .init(reliable: false) }
        var missingInventory: [Int32: ClaudeDesktopProcessTracking.MissingInventoryLookup] = [:]
        for (pid, _) in previouslyRelated where identities[pid] == nil {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size)) }
            if result != size {
                missingInventory[pid] = ClaudeDesktopProcessTracking.hasExited(pid: pid) ? .absent : .unavailable
                continue
            }
            if let current = ClaudeDesktopProcessTracking.identity(for: pid, info: info) {
                missingInventory[pid] = .live(current)
            } else {
                missingInventory[pid] = .absent
            }
        }
        var relatedPIDs: Set<Int32>
        do {
            relatedPIDs = try ClaudeDesktopProcessTracking.reconcile(
                previouslyRelated: &previouslyRelated,
                currentIdentities: &identities,
                directRelated: desktopPIDs.union(bundled),
                parents: parents,
                missingInventory: missingInventory
            )
        } catch {
            return .init(reliable: false)
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
                        if ClaudeDesktopProcessTracking.hasExited(pid: child) { continue }
                        return .init(reliable: false)
                    }
                    guard let identity = ClaudeDesktopProcessTracking.identity(for: child, info: info) else { continue }
                    identities[child] = identity
                }
                relatedPIDs.insert(child); pendingParents.append(child)
            }
        }
        previouslyRelated = Dictionary(uniqueKeysWithValues: relatedPIDs.compactMap { pid in
            identities[pid].map { (pid, $0) }
        })
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
