import Foundation
import Darwin
import CryptoKit

/// The Desktop login is deliberately a separate credential from Claude Code's OAuth grant.
/// Snapshots live only in the Keychain; nothing containing a Desktop credential is written to
/// AgentSwap's state directory.
public protocol ClaudeDesktopAccountManaging: Sendable {
    func captureCurrent(for account: AccountRecord) async throws
    func prepareSwitch(target: AccountRecord, registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> UUID
    func finish(transactionID: UUID, cliApplied: Bool) async throws -> String
    func recover(registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> String
    func deleteSnapshot(accountID: UUID) async throws
    /// The regular CLI path reads only AgentSwap's Keychain journal.  It never wakes or
    /// inspects Claude Desktop, but cannot race a prepared combined transaction.
    func verifyCanSwitchCLI(allowing transactionID: UUID?) async throws
}

public extension ClaudeDesktopAccountManaging {
    func verifyCanSwitchCLI(allowing transactionID: UUID?) async throws {}
}

/// Bounded access to Desktop authentication files.  It is public so tests can inject a failing
/// store without ever putting a real browser profile in a fixture.
public protocol ClaudeDesktopAuthFileAccess: Sendable {
    func read(_ url: URL, maximumBytes: Int) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
    func children(of directory: URL) throws -> [URL]
    func createDirectory(_ url: URL) throws
}

private struct DesktopConfig: Codable, Equatable {
    var lastKnownAccountUuid: String
    var tokenCache: String
    var tokenCacheV2: String
}

private struct DesktopFile: Codable, Equatable {
    var relativePath: String
    var contents: Data
}

private struct DesktopSnapshot: Codable, Equatable {
    var version = 2
    var desktopVersion: String
    var accountID: UUID
    var identity: AccountIdentity
    var config: DesktopConfig
    var browserFiles: [DesktopFile]
    var verifiedCacheDigest: Data?
}

private enum DesktopTransactionPhase: String, Codable { case prepared, committed }
private struct DesktopTransaction: Codable, Equatable {
    var version = 1
    var id: UUID
    var source: AccountIdentity
    var target: AccountIdentity
    var cliAtPrepare: AccountIdentity?
    var sourceSnapshot: DesktopSnapshot
    var targetSnapshot: DesktopSnapshot
    var authMutations: [AuthMutation]
    var codeMutations: [AuthMutation]
    var codeProof: [ClaudeDesktopCodeFingerprint]
    var targetCodeNames: [String]
    var tracked: [DesktopTrackedProcess]
    var phase: DesktopTransactionPhase
}

private struct DesktopTrackedProcess: Codable, Equatable {
    var pid: Int32
    var startedAt: UInt64
}

private struct DesktopFileJournal: Decodable {
    var version: Int
    var committed: Bool
    var mutations: [AuthMutation]
}

private struct DesktopAuthFileAdapter: AuthFileAccess {
    let base: any ClaudeDesktopAuthFileAccess
    func read(_ url: URL) throws -> Data? { try base.read(url, maximumBytes: SecureClaudeDesktopAuthFileAccess.maximumFileBytes) }
    func write(_ data: Data, to url: URL) throws {
        try base.createDirectory(url.deletingLastPathComponent())
        try base.write(data, to: url)
    }
    func delete(_ url: URL) throws { try base.remove(url) }
}

/// Swaps Claude Desktop's known login fields and browser-auth stores, and publishes a validated
/// Code-index transfer plan. Source indexes and shared transcripts are never written.
public actor ClaudeDesktopAccountManager: ClaudeDesktopAccountManaging {
    public static let service = "net.mercen.agentswap.desktop"
    private static let supportedDesktopVersions: Set<String> = ["2.42304.0"]
    private static let transactionService = "net.mercen.agentswap.recovery"
    private static let transactionAccount = "claude-desktop-account-switch"
    private static let maxFileBytes = 32 * 1_024 * 1_024
    private static let maxTotalBytes = 64 * 1_024 * 1_024
    private static let maxJournalBytes = 128 * 1_024 * 1_024
    private let home: URL
    private let keychain: any KeychainAccess
    private let processes: any ClaudeDesktopConversationProcessControlling
    private let mutationProcesses: any ClaudeDesktopMutationProcessChecking
    private let files: any ClaudeDesktopAuthFileAccess
    private let loginVerifier: any ClaudeDesktopLoginVerifying
    private let appURL: URL?
    private var operating = false

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                keychain: any KeychainAccess = AppVaultKeychainAccess(),
                processes: any ClaudeDesktopConversationProcessControlling = SystemClaudeDesktopConversationProcessController(),
                files: (any ClaudeDesktopAuthFileAccess)? = nil,
                loginVerifier: any ClaudeDesktopLoginVerifying = SystemClaudeDesktopLoginVerifier(),
                appURL: URL? = nil,
                mutationProcesses: any ClaudeDesktopMutationProcessChecking = SystemClaudeDesktopMutationProcessChecker()) {
        self.home = home.standardizedFileURL; self.keychain = keychain; self.processes = processes
        self.files = files ?? SecureClaudeDesktopAuthFileAccess(home: home)
        self.loginVerifier = loginVerifier; self.appURL = appURL
        self.mutationProcesses = mutationProcesses
    }

    public func captureCurrent(for account: AccountRecord) async throws {
        try begin(); defer { operating = false }
        try validate(account)
        guard try readTransaction() == nil else { throw AgentSwapError.storage("진행 중인 Claude 데스크톱 전환의 복구가 필요합니다.") }
        let installation = try await installation()
        let tracked = try await stop(installation)
        do {
            try await ensureStopped(installation, tracked: tracked)
            try Task.checkCancellation()
            let snapshot = try await verifiedSnapshot(for: account, installation: installation, tracked: tracked)
            try save(snapshot)
            if !tracked.isEmpty { try await processes.relaunch(at: installation.url) }
        } catch {
            if !tracked.isEmpty { try? await reopenStopped(installation, tracked: tracked) }
            throw error
        }
    }

    public func prepareSwitch(target: AccountRecord, registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> UUID {
        try begin(); defer { operating = false }
        try validate(target)
        let source = try desktopSource(registered: registered)
        guard target.provider == .claude else { throw AgentSwapError.unsupported("Claude 데스크톱에는 Claude 계정만 전환할 수 있습니다.") }
        guard try keychain.read(service: Self.transactionService, account: Self.transactionAccount) == nil else {
            throw AgentSwapError.storage("이전 Claude 데스크톱 전환의 복구가 필요합니다.")
        }
        let savedTarget = source.id == target.id ? nil : try load(accountID: target.id)
        if let savedTarget { try validate(snapshot: savedTarget, for: target) }
        let installation = try await installation()
        if let savedTarget, savedTarget.desktopVersion != installation.version {
            throw AgentSwapError.unsupported("현재 Claude Desktop 버전에서 대상 로그인을 다시 저장해 주세요.")
        }
        let tracked = try await stop(installation)
        do {
            try await ensureStopped(installation, tracked: tracked)
            try Task.checkCancellation()
            let sourceSnapshot = try await verifiedSnapshot(for: source, installation: installation, tracked: tracked)
            try save(sourceSnapshot)
            // If Desktop is already on the selected target, this fresh post-termination read is
            // both the source rollback image and the target generation to retain.
            let targetSnapshot = savedTarget ?? sourceSnapshot
            try validate(snapshot: targetSnapshot, for: target)
            let targetNames = try codeNames(target.identity)
            let codePlan = try ClaudeDesktopCodeTransfer(home: home).prepare(source: source.identity, target: target.identity)
            guard try codeNames(target.identity) == targetNames else {
                throw AgentSwapError.storage("대상 Code 대화 목록이 준비하는 중 변경되었습니다.")
            }
            let authMutations = try desktopMutations(source: sourceSnapshot, target: targetSnapshot)
            let transaction = DesktopTransaction(id: UUID(), source: source.identity, target: target.identity,
                                                 cliAtPrepare: currentCLI, sourceSnapshot: sourceSnapshot,
                                                 targetSnapshot: targetSnapshot, authMutations: authMutations, codeMutations: codePlan.mutations,
                                                 codeProof: codePlan.fingerprints, targetCodeNames: targetNames,
                                                 tracked: tracked.map { .init(pid: $0.pid, startedAt: $0.startedAt) }, phase: .prepared)
            try codePlan.verifyOriginals()
            try validate(transaction: transaction)
            if let savedTarget, try load(accountID: target.id) != savedTarget {
                throw AgentSwapError.storage("저장된 Desktop 대상 로그인이 준비 중 변경되어 CLI 전환을 시작하지 않았습니다.")
            }
            try writeTransaction(transaction)
            return transaction.id
        } catch {
            if !tracked.isEmpty { try? await reopenStopped(installation, tracked: tracked) }
            throw error
        }
    }

    public func finish(transactionID: UUID, cliApplied: Bool) async throws -> String {
        try begin(); defer { operating = false }
        guard let transaction = try readTransaction(), transaction.id == transactionID else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록을 확인하지 못했습니다.")
        }
        let installation = try await installation()
        if transaction.phase == .committed {
            try await processes.relaunch(at: installation.url)
            try cleanCommitted(transaction)
            return "저장된 Desktop 로그인 적용은 이미 완료되어 앱을 다시 열었습니다."
        }
        if !cliApplied {
            let fileTransaction = fileTransaction(for: transaction)
            if try validatedChildJournal(transaction) != nil {
                try await ensureStopped(installation, tracked: processIdentities(transaction))
                try verifyRecoverableInventory(transaction)
                try fileTransaction.recover(allowedLocations: allowedLocations(for: transaction))
            }
            try await processes.relaunch(at: installation.url)
            try deleteTransaction(transaction)
            return "Claude CLI 전환이 적용되지 않아 데스크톱 로그인은 변경하지 않았습니다."
        }
        return try await finishPrepared(transactionID: transactionID, transaction: transaction)
    }

    public func recover(registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> String {
        try begin(); defer { operating = false }
        guard let transaction = try readTransaction() else { return "복구할 Claude 데스크톱 전환 기록이 없습니다." }
        if transaction.phase == .committed {
            let installation = try await installation()
            try await processes.relaunch(at: installation.url)
            try cleanCommitted(transaction)
            return "적용된 Desktop 인증을 변경하지 않고 앱을 다시 열었습니다."
        }
        guard (currentCLI == nil || registered.contains(where: { $0.identity == currentCLI })),
              registered.contains(where: { $0.id == transaction.sourceSnapshot.accountID && $0.identity == transaction.sourceSnapshot.identity }),
              registered.contains(where: { $0.id == transaction.targetSnapshot.accountID && $0.identity == transaction.targetSnapshot.identity }) else {
            throw AgentSwapError.authentication("현재 Claude CLI 계정이 등록되지 않아 데스크톱 전환을 복구하지 않았습니다.")
        }
        let installation = try await installation()
        // A CLI already on target is authoritative even when Desktop started on a different
        // account.  This is the normal recovery route after a crash between CLI and Desktop.
        if currentCLI == transaction.target {
            return try await finishPrepared(transactionID: transaction.id, transaction: transaction)
        }
        if currentCLI == transaction.cliAtPrepare {
            try await ensureStopped(installation, tracked: processIdentities(transaction))
            let recovery = fileTransaction(for: transaction)
            if try validatedChildJournal(transaction) != nil {
                try verifyRecoverableInventory(transaction)
                try recovery.recover(allowedLocations: allowedLocations(for: transaction))
            }
            try await processes.relaunch(at: installation.url)
            try deleteTransaction(transaction)
            return "Claude CLI가 이전 계정이므로 데스크톱 로그인 전환을 취소했습니다."
        }
        throw AgentSwapError.storage("현재 Claude CLI 계정이 전환 기록의 양쪽 계정과 달라 데스크톱 로그인을 변경하지 않았습니다.")
    }

    public func deleteSnapshot(accountID: UUID) async throws {
        try begin(); defer { operating = false }
        if let transaction = try readTransaction(), transaction.sourceSnapshot.accountID == accountID || transaction.targetSnapshot.accountID == accountID {
            throw AgentSwapError.storage("진행 중인 Claude 데스크톱 전환 기록이 이 계정을 참조합니다.")
        }
        try keychain.delete(service: Self.service, account: snapshotAccount(accountID))
    }

    public func verifyCanSwitchCLI(allowing transactionID: UUID?) async throws {
        guard let transaction = try readTransaction() else { return }
        if transaction.phase == .committed {
            try cleanCommitted(transaction)
            return
        }
        guard transactionID == transaction.id else {
            throw AgentSwapError.storage("Claude 데스크톱 로그인 전환의 복구가 필요합니다. 전환을 다시 시도하거나 복구를 완료해 주세요.")
        }
    }

    // MARK: snapshot representation

    private func verifiedSnapshot(for account: AccountRecord, installation: ClaudeDesktopConversationInstallation,
                                  tracked: Set<ClaudeDesktopConversationProcessIdentity>) async throws -> DesktopSnapshot {
        var snapshot = try takeSnapshot(for: account, desktopVersion: installation.version)
        try await loginVerifier.verify(tokenCacheV1: snapshot.config.tokenCache, tokenCacheV2: snapshot.config.tokenCacheV2, expected: account.identity)
        try Task.checkCancellation()
        try await ensureStopped(installation, tracked: tracked)
        guard try takeSnapshot(for: account, desktopVersion: installation.version) == snapshot else {
            throw AgentSwapError.storage("Desktop 로그인이 프로필 확인 중 변경되어 저장하지 않았습니다.")
        }
        snapshot.verifiedCacheDigest = verificationDigest(snapshot)
        return snapshot
    }

    private func verificationDigest(_ snapshot: DesktopSnapshot) -> Data {
        let values = [snapshot.identity.provider.rawValue, snapshot.identity.userID, snapshot.identity.workspaceID,
                      snapshot.config.lastKnownAccountUuid, snapshot.config.tokenCache, snapshot.config.tokenCacheV2]
        return Data(SHA256.hash(data: Data(values.joined(separator: "\0").utf8)))
    }

    private var configURL: URL { home.appendingPathComponent("Library/Application Support/Claude/config.json") }
    private var profileURL: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    private var browserRoots: [(String, URL)] {
        [("Cookies", profileURL.appendingPathComponent("Cookies")),
         ("Cookies-shm", profileURL.appendingPathComponent("Cookies-shm")),
         ("Cookies-wal", profileURL.appendingPathComponent("Cookies-wal")),
         ("Cookies-journal", profileURL.appendingPathComponent("Cookies-journal")),
         ("Local Storage", profileURL.appendingPathComponent("Local Storage", isDirectory: true)),
         ("Session Storage", profileURL.appendingPathComponent("Session Storage", isDirectory: true)),
         ("IndexedDB", profileURL.appendingPathComponent("IndexedDB", isDirectory: true))]
    }

    private func takeSnapshot(for account: AccountRecord, desktopVersion: String) throws -> DesktopSnapshot {
        let bridge = profileURL.appendingPathComponent("bridge-state.json")
        if let data = try files.read(bridge, maximumBytes: Self.maxFileBytes), !data.isEmpty {
            throw AgentSwapError.unsupported("Claude 데스크톱 원격 연결 상태가 있어 계정 전환을 중단했습니다.")
        }
        let configData = try required(configURL)
        let object = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        guard let object,
              let uuid = object["lastKnownAccountUuid"] as? String, UUID(uuidString: uuid) != nil,
              uuid.caseInsensitiveCompare(account.identity.userID) == .orderedSame,
              let v1 = object["oauth:tokenCache"] as? String, !v1.isEmpty,
              let v2 = object["oauth:tokenCacheV2"] as? String, !v2.isEmpty,
              !object.keys.contains(where: { $0.hasPrefix("oauth:") && $0 != "oauth:tokenCache" && $0 != "oauth:tokenCacheV2" }) else {
            throw AgentSwapError.authentication("Claude 데스크톱 로그인 계정을 확인하지 못했습니다.")
        }
        let files = try browserSnapshot()
        return DesktopSnapshot(desktopVersion: desktopVersion, accountID: account.id, identity: account.identity,
                               config: .init(lastKnownAccountUuid: uuid, tokenCache: v1, tokenCacheV2: v2), browserFiles: files)
    }

    private func browserSnapshot() throws -> [DesktopFile] {
        var saved: [DesktopFile] = [], total = 0
        var remaining = 4_096
        for (prefix, root) in browserRoots {
            for url in try descend(root, depth: 0, remaining: &remaining) {
                let suffix = url.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let relative = suffix.isEmpty ? prefix : prefix + "/" + suffix
                guard saved.count < 4_096, relative.utf8.count <= 1024,
                      let data = try files.read(url, maximumBytes: Self.maxFileBytes) else {
                    throw AgentSwapError.storage("Claude 데스크톱 인증 저장소가 읽는 중 변경되었습니다.")
                }
                total += data.count
                guard total <= Self.maxTotalBytes else { throw AgentSwapError.unsupported("Claude 데스크톱 인증 저장소 크기를 지원하지 않습니다.") }
                saved.append(.init(relativePath: relative, contents: data))
            }
        }
        return saved.sorted { $0.relativePath < $1.relativePath }
    }

    private func descend(_ root: URL, depth: Int, remaining: inout Int) throws -> [URL] {
        guard depth <= 32, remaining > 0 else { throw AgentSwapError.storage("Desktop 인증 저장소의 항목 또는 폴더 깊이 한도를 넘었습니다.") }
        var info = stat()
        if lstat(root.path, &info) != 0 { if errno == ENOENT { return [] }; throw AgentSwapError.storage("Claude 데스크톱 인증 저장소를 읽지 못했습니다.") }
        if (info.st_mode & S_IFMT) == S_IFREG { remaining -= 1; return [root] }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AgentSwapError.unsupported("Claude 데스크톱 인증 저장소 형식을 지원하지 않습니다.") }
        var result: [URL] = []
        for child in try files.children(of: root) { result += try descend(child, depth: depth + 1, remaining: &remaining) }
        return result
    }

    /// Creates the complete, exact Desktop-auth write set while Claude Desktop is stopped.
    /// The source configuration's unknown fields are retained semantically; only its three known
    /// identity fields are replaced by the target snapshot.
    private func desktopMutations(source: DesktopSnapshot, target: DesktopSnapshot) throws -> [AuthMutation] {
        let beforeConfig = try required(configURL)
        guard try configMatches(beforeConfig, source.config) else {
            throw AgentSwapError.storage("Claude 데스크톱 로그인이 백업 뒤 변경되었습니다.")
        }
        let afterConfig = try mergedConfig(before: beforeConfig, target: target.config)
        var mutations = [AuthMutation(location: .file(configURL.path), before: beforeConfig, after: afterConfig)]
        guard Set(source.browserFiles.map(\.relativePath)).count == source.browserFiles.count,
              Set(target.browserFiles.map(\.relativePath)).count == target.browserFiles.count else {
            throw AgentSwapError.storage("Claude 데스크톱 브라우저 인증 백업 경로가 중복되었습니다.")
        }
        let before = Dictionary(uniqueKeysWithValues: source.browserFiles.map { ($0.relativePath, $0.contents) })
        let after = Dictionary(uniqueKeysWithValues: target.browserFiles.map { ($0.relativePath, $0.contents) })
        for relative in Set(before.keys).union(after.keys).sorted() {
            let url = try resolvedBrowserPath(relative)
            let current = try files.read(url, maximumBytes: Self.maxFileBytes)
            guard current == before[relative] else {
                throw AgentSwapError.storage("Claude 데스크톱 브라우저 인증 저장소가 백업 뒤 변경되었습니다.")
            }
            mutations.append(.init(location: .file(url.path), before: current, after: after[relative]))
        }
        return mutations
    }

    private func mergedConfig(before: Data, target: DesktopConfig) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: before) as? [String: Any] else {
            throw AgentSwapError.unsupported("Claude 데스크톱 설정 형식을 지원하지 않습니다.")
        }
        object["lastKnownAccountUuid"] = target.lastKnownAccountUuid
        object["oauth:tokenCache"] = target.tokenCache
        object["oauth:tokenCacheV2"] = target.tokenCacheV2
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func configMatches(_ data: Data, _ expected: DesktopConfig) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["lastKnownAccountUuid"] as? String,
              let one = object["oauth:tokenCache"] as? String,
              let two = object["oauth:tokenCacheV2"] as? String,
              !object.keys.contains(where: { $0.hasPrefix("oauth:") && $0 != "oauth:tokenCache" && $0 != "oauth:tokenCacheV2" }) else { return false }
        return DesktopConfig(lastKnownAccountUuid: account, tokenCache: one, tokenCacheV2: two) == expected
    }

    private func resolvedBrowserPath(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard relative.utf8.count <= 1024, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw AgentSwapError.storage("Claude 데스크톱 인증 경로가 안전하지 않습니다.")
        }
        for (name, root) in browserRoots where relative == name || relative.hasPrefix(name + "/") {
            let isFile = name.hasPrefix("Cookies")
            guard isFile ? parts.count == 1 : parts.count > 1 else { throw AgentSwapError.storage("Claude 데스크톱 인증 경로 형식이 안전하지 않습니다.") }
            let suffix = String(relative.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return root.appendingPathComponent(suffix)
        }
        throw AgentSwapError.storage("Claude 데스크톱 인증 경로가 안전하지 않습니다.")
    }

    private func readConfig() throws -> DesktopConfig {
        let data = try required(configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["lastKnownAccountUuid"] as? String,
              let v1 = object["oauth:tokenCache"] as? String, let v2 = object["oauth:tokenCacheV2"] as? String else {
            throw AgentSwapError.storage("Claude 데스크톱 인증 설정을 다시 읽지 못했습니다.")
        }
        return .init(lastKnownAccountUuid: account, tokenCache: v1, tokenCacheV2: v2)
    }

    private func required(_ url: URL) throws -> Data {
        guard let result = try files.read(url, maximumBytes: Self.maxFileBytes) else { throw AgentSwapError.authentication("Claude 데스크톱 로그인을 찾지 못했습니다.") }
        return result
    }

    private func save(_ snapshot: DesktopSnapshot) throws {
        try validate(snapshot: snapshot)
        let data = try encode(snapshot)
        guard data.count <= Self.maxTotalBytes else { throw AgentSwapError.unsupported("Claude 데스크톱 인증 저장소 크기를 지원하지 않습니다.") }
        try keychain.write(data, service: Self.service, account: snapshotAccount(snapshot.accountID))
        guard try keychain.read(service: Self.service, account: snapshotAccount(snapshot.accountID)) == data else { throw AgentSwapError.storage("Claude 데스크톱 로그인 백업을 확인하지 못했습니다.") }
    }
    private func load(accountID: UUID) throws -> DesktopSnapshot {
        guard let data = try keychain.read(service: Self.service, account: snapshotAccount(accountID)) else { throw AgentSwapError.authentication("대상 Claude 데스크톱 로그인 백업이 없습니다. 먼저 해당 계정으로 Desktop에 로그인해 주세요.") }
        guard data.count <= Self.maxTotalBytes else { throw AgentSwapError.storage("Claude 데스크톱 로그인 백업 크기를 지원하지 않습니다.") }
        do {
            let snapshot = try PropertyListDecoder().decode(DesktopSnapshot.self, from: data)
            try validate(snapshot: snapshot)
            return snapshot
        }
        catch { throw AgentSwapError.storage("Claude 데스크톱 로그인 백업의 계정 확인 형식을 읽지 못했습니다. 해당 계정으로 Desktop에 로그인한 뒤 로그인을 다시 저장해 주세요.") }
    }
    private func validate(snapshot: DesktopSnapshot, for account: AccountRecord? = nil) throws {
        guard snapshot.version == 2, Self.supportedDesktopVersions.contains(snapshot.desktopVersion), snapshot.identity.provider == .claude,
              snapshot.verifiedCacheDigest == verificationDigest(snapshot),
              UUID(uuidString: snapshot.identity.userID) != nil, UUID(uuidString: snapshot.identity.workspaceID) != nil,
              UUID(uuidString: snapshot.config.lastKnownAccountUuid) != nil,
              snapshot.config.lastKnownAccountUuid.caseInsensitiveCompare(snapshot.identity.userID) == .orderedSame,
              !snapshot.config.tokenCache.isEmpty, !snapshot.config.tokenCacheV2.isEmpty,
              snapshot.browserFiles.count <= 4_096,
              Set(snapshot.browserFiles.map(\.relativePath)).count == snapshot.browserFiles.count,
              snapshot.browserFiles.reduce(0, { $0 + $1.contents.count }) <= Self.maxTotalBytes,
              snapshot.browserFiles.allSatisfy({ $0.contents.count <= Self.maxFileBytes }) else {
            throw AgentSwapError.storage("Claude 데스크톱 로그인 백업을 확인하지 못했습니다.")
        }
        for file in snapshot.browserFiles { _ = try resolvedBrowserPath(file.relativePath) }
        if let account { guard snapshot.accountID == account.id, snapshot.identity == account.identity else { throw AgentSwapError.authentication("Claude 데스크톱 로그인 백업의 계정이 일치하지 않습니다.") } }
    }
    private func validate(_ account: AccountRecord) throws {
        guard account.provider == .claude, UUID(uuidString: account.identity.userID) != nil,
              UUID(uuidString: account.identity.workspaceID) != nil else { throw AgentSwapError.authentication("Claude 계정 식별자를 확인하지 못했습니다.") }
    }

    private func desktopSource(registered: [AccountRecord]) throws -> AccountRecord {
        let config = try readConfig()
        let matches = registered.filter { $0.provider == .claude && $0.identity.userID.caseInsensitiveCompare(config.lastKnownAccountUuid) == .orderedSame }
        guard matches.count == 1, let match = matches.first else {
            throw AgentSwapError.authentication("Claude 데스크톱 로그인 계정을 등록된 계정 하나와 일치하는지 확인하지 못했습니다.")
        }
        return match
    }

    private func finishPrepared(transactionID: UUID, transaction: DesktopTransaction) async throws -> String {
        guard transaction.phase == .prepared, transaction.id == transactionID else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록을 확인하지 못했습니다.")
        }
        let installation = try await installation()
        guard transaction.targetSnapshot.desktopVersion == installation.version else {
            throw AgentSwapError.unsupported("Claude Desktop 버전이 전환 준비 뒤 변경되었습니다.")
        }
        try await ensureStopped(installation, tracked: processIdentities(transaction))
        try Task.checkCancellation()
        let fileTransaction = fileTransaction(for: transaction)
        let transfer = ClaudeDesktopCodeTransfer(home: home)
        if let child = try validatedChildJournal(transaction) {
            if child.committed { return try await completeApplied(transaction, installation: installation) }
            try transfer.verifyOriginals(transaction.codeProof, source: transaction.source)
            try verifyRecoverableInventory(transaction)
            try fileTransaction.recover(allowedLocations: allowedLocations(for: transaction))
        }
        try transfer.verifyOriginals(transaction.codeProof, source: transaction.source)
        guard try load(accountID: transaction.targetSnapshot.accountID) == transaction.targetSnapshot else {
            throw AgentSwapError.storage("저장된 Desktop 대상 로그인이 준비 뒤 변경되었습니다.")
        }
        try verifyRecoverableInventory(transaction)
        let mutations = transaction.authMutations + transaction.codeMutations
        if try mutations.allSatisfy({ try read($0.location) == $0.after }) {
            return try await completeApplied(transaction, installation: installation)
        }
        guard try mutations.allSatisfy({ try read($0.location) == $0.before }) else {
            throw AgentSwapError.storage("Desktop 전환의 정확한 원본을 확인하지 못해 복구 기록을 보존했습니다.")
        }
        guard try codeNames(transaction.target) == transaction.targetCodeNames else {
            throw AgentSwapError.storage("대상 Code 대화 목록이 준비 뒤 변경되었습니다.")
        }
        try fileTransaction.perform(effectiveMutations(transaction), checkCancellation: { try Task.checkCancellation() },
            verifyCompletion: {
                try transfer.verifyOriginals(transaction.codeProof, source: transaction.source)
                try self.verifyRecoverableInventory(transaction)
                guard try self.effectiveMutations(transaction).allSatisfy({ try self.read($0.location) == $0.after }) else {
                    throw AgentSwapError.storage("Desktop 전환 완료 전에 대상 인증 또는 대화 목록이 변경되었습니다.")
                }
                guard try self.codeNames(transaction.target) == self.finalCodeNames(transaction) else {
                    throw AgentSwapError.storage("대상 Code 대화 목록이 전환 중 변경되었습니다.")
                }
            }, verifyLock: {
                try self.mutationProcesses.verifyStopped(applicationURL: installation.url, tracked: self.processIdentities(transaction))
            })
        return try await completeApplied(transaction, installation: installation)
    }

    private func completeApplied(_ transaction: DesktopTransaction, installation: ClaudeDesktopConversationInstallation) async throws -> String {
        var committed = transaction; committed.phase = .committed
        try writeTransaction(committed)
        try await processes.relaunch(at: installation.url)
        try cleanCommitted(committed)
        return "저장된 Claude 데스크톱 로그인 상태를 적용하고 앱을 다시 열었습니다. 대화 원본 파일은 변경하지 않았습니다."
    }

    private func read(_ location: AuthMutation.Location) throws -> Data? {
        guard case .file(let path) = location else { throw AgentSwapError.storage("지원하지 않는 Desktop 인증 위치입니다.") }
        return try files.read(URL(fileURLWithPath: path), maximumBytes: Self.maxFileBytes)
    }

    private func verifyRecoverableInventory(_ transaction: DesktopTransaction) throws {
        let expectedNames = Set((transaction.sourceSnapshot.browserFiles + transaction.targetSnapshot.browserFiles).map(\.relativePath))
        let current = try browserSnapshot()
        guard current.allSatisfy({ expectedNames.contains($0.relativePath) }) else {
            throw AgentSwapError.storage("Desktop 인증 저장소에 외부 파일이 생겨 복구를 중단했습니다.")
        }
        for mutation in transaction.authMutations + transaction.codeMutations {
            let value = try read(mutation.location)
            guard value == mutation.before || value == mutation.after else {
                throw AgentSwapError.storage("Desktop 인증 또는 대화 목록이 외부에서 변경되어 복구 자료를 보존했습니다.")
            }
        }
        let names = Set(try codeNames(transaction.target))
        guard Set(transaction.targetCodeNames).isSubset(of: names), names.isSubset(of: Set(finalCodeNames(transaction))) else {
            throw AgentSwapError.storage("대상 Code 대화의 외부 추가 또는 삭제를 발견해 복구를 중단했습니다.")
        }
    }

    private func codeNames(_ identity: AccountIdentity) throws -> [String] {
        let directory = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            .appendingPathComponent(identity.userID).appendingPathComponent(identity.workspaceID)
        let children = try files.children(of: directory)
        guard children.count <= 1_000 else { throw AgentSwapError.storage("대상 Code 대화 목록의 개수 한도를 넘었습니다.") }
        return children.map(\.lastPathComponent).sorted()
    }

    private func finalCodeNames(_ transaction: DesktopTransaction) -> [String] {
        let added = transaction.codeMutations.compactMap { mutation -> String? in
            guard mutation.before == nil, mutation.after != nil, case .file(let path) = mutation.location else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return Set(transaction.targetCodeNames + added).sorted()
    }

    private func validatedChildJournal(_ transaction: DesktopTransaction) throws -> DesktopFileJournal? {
        guard let data = try fileTransaction(for: transaction).recoveryJournalData() else { return nil }
        guard data.count <= Self.maxJournalBytes,
              let journal = try? JSONDecoder().decode(DesktopFileJournal.self, from: data), journal.version == 1 else {
            throw AgentSwapError.storage("Desktop 파일 복구 기록의 형식 또는 크기를 확인하지 못했습니다.")
        }
        let expected = effectiveMutations(transaction)
        guard journal.mutations.count == expected.count,
              zip(journal.mutations, expected).allSatisfy({ actual, expected in
                  actual.location == expected.location && actual.before == expected.before && actual.after == expected.after
              }) else {
            throw AgentSwapError.storage("Desktop 파일 복구 기록이 준비한 변경과 일치하지 않습니다.")
        }
        return journal
    }

    private func cleanCommitted(_ transaction: DesktopTransaction) throws {
        if let child = try validatedChildJournal(transaction) {
            guard child.committed else { throw AgentSwapError.storage("완료 상태와 다른 Desktop 파일 복구 기록을 보존했습니다.") }
            try fileTransaction(for: transaction).discardCommittedRecovery(allowedLocations: allowedLocations(for: transaction))
        }
        try deleteTransaction(transaction)
    }

    private func fileTransaction(for transaction: DesktopTransaction) -> AuthTransaction {
        .init(identifier: "claude-desktop-files-\(transaction.id.uuidString)", keychain: keychain,
              files: DesktopAuthFileAdapter(base: files))
    }
    private func effectiveMutations(_ transaction: DesktopTransaction) -> [AuthMutation] {
        (transaction.authMutations + transaction.codeMutations).filter { $0.before != $0.after }
    }
    private func allowedLocations(for transaction: DesktopTransaction) -> Set<AuthMutation.Location> {
        Set((transaction.authMutations + transaction.codeMutations).map(\.location))
    }

    private func snapshotAccount(_ id: UUID) -> String { "desktop-profile-\(id.uuidString)" }
    private func writeTransaction(_ transaction: DesktopTransaction) throws {
        try validate(transaction: transaction)
        let data = try encode(transaction)
        guard data.count <= Self.maxJournalBytes else { throw AgentSwapError.storage("Desktop 전환 기록 크기 한도를 넘었습니다.") }
        try keychain.write(data, service: Self.transactionService, account: Self.transactionAccount)
        guard try keychain.read(service: Self.transactionService, account: Self.transactionAccount) == data else { throw AgentSwapError.storage("Claude 데스크톱 전환 기록 저장을 확인하지 못했습니다.") }
    }
    private func readTransaction() throws -> DesktopTransaction? {
        guard let data = try keychain.read(service: Self.transactionService, account: Self.transactionAccount) else { return nil }
        guard data.count <= Self.maxJournalBytes else { throw AgentSwapError.storage("Claude 데스크톱 전환 기록 크기를 지원하지 않습니다.") }
        guard let transaction = try? PropertyListDecoder().decode(DesktopTransaction.self, from: data), transaction.version == 1 else { throw AgentSwapError.storage("Claude 데스크톱 전환 기록 형식을 읽지 못했습니다.") }
        try validate(transaction: transaction)
        return transaction
    }
    private func deleteTransaction(_ transaction: DesktopTransaction) throws {
        guard try readTransaction() == transaction else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록이 변경되었습니다.")
        }
        try keychain.delete(service: Self.transactionService, account: Self.transactionAccount)
        guard try keychain.read(service: Self.transactionService, account: Self.transactionAccount) == nil else {
            throw AgentSwapError.storage("Desktop 전환 기록 삭제 결과를 확인하지 못했습니다.")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func processIdentities(_ transaction: DesktopTransaction) -> Set<ClaudeDesktopConversationProcessIdentity> {
        Set(transaction.tracked.map { .init(pid: $0.pid, startedAt: $0.startedAt) })
    }

    private func reopenStopped(_ installation: ClaudeDesktopConversationInstallation, tracked: Set<ClaudeDesktopConversationProcessIdentity>) async throws {
        try await ensureStopped(installation, tracked: tracked)
        try await processes.relaunch(at: installation.url)
    }

    private func installation() async throws -> ClaudeDesktopConversationInstallation {
        guard let installation = await processes.installation(at: appURL) else { throw AgentSwapError.storage("Claude 데스크톱 앱을 찾지 못했습니다.") }
        guard Self.supportedDesktopVersions.contains(installation.version) else {
            throw AgentSwapError.unsupported("이 Claude Desktop 버전은 결합 전환을 검증하지 않았습니다. 지원 버전: 2.42304.0. 일반 CLI 전환은 계속 사용할 수 있습니다.")
        }
        return installation
    }
    private func stop(_ installation: ClaudeDesktopConversationInstallation) async throws -> Set<ClaudeDesktopConversationProcessIdentity> {
        let scan = await processes.scan(applicationURL: installation.url)
        guard scan.reliable else { throw AgentSwapError.storage("Claude 데스크톱 프로세스를 확인하지 못했습니다.") }
        let tracked = scan.desktop.union(scan.related)
        if !tracked.isEmpty, !(await processes.requestNormalTermination()) { throw AgentSwapError.storage("Claude 데스크톱을 정상 종료하지 못했습니다.") }
        return tracked
    }
    private func ensureStopped(_ installation: ClaudeDesktopConversationInstallation, tracked: Set<ClaudeDesktopConversationProcessIdentity>) async throws {
        for attempt in 0..<200 {
            let scan = await processes.scan(applicationURL: installation.url)
            if scan.reliable, scan.desktop.isEmpty, scan.related.isEmpty,
               tracked.allSatisfy({ !scan.live.contains($0) }) { return }
            if attempt < 199 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw AgentSwapError.storage("Claude 데스크톱이 완전히 종료된 뒤 다시 시도해 주세요.")
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !operating else { throw AgentSwapError.storage("다른 Claude 데스크톱 로그인 작업이 진행 중입니다.") }; operating = true
    }

    private func validate(transaction: DesktopTransaction) throws {
        try validate(snapshot: transaction.sourceSnapshot)
        try validate(snapshot: transaction.targetSnapshot)
        guard transaction.source.provider == .claude, transaction.target.provider == .claude,
              transaction.sourceSnapshot.desktopVersion == transaction.targetSnapshot.desktopVersion,
              transaction.sourceSnapshot.identity == transaction.source,
              transaction.targetSnapshot.identity == transaction.target,
              transaction.authMutations.count <= 10_000, transaction.codeMutations.count <= 1_000,
              transaction.codeProof.count <= 2_002, transaction.tracked.count <= 4_096,
              transaction.targetCodeNames.count <= 1_000,
              transaction.targetCodeNames.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
              Set(transaction.targetCodeNames).count == transaction.targetCodeNames.count,
              transaction.tracked.allSatisfy({ $0.pid > 0 && $0.startedAt > 0 }) else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록이 안전하지 않습니다.")
        }
        guard Set(transaction.authMutations.map(\.location)).count == transaction.authMutations.count else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록에 중복된 인증 위치가 있습니다.")
        }
        guard let configMutation = transaction.authMutations.first(where: { $0.location == .file(configURL.path) }),
              let configBefore = configMutation.before,
              try configMatches(configBefore, transaction.sourceSnapshot.config),
              configMutation.after == (try mergedConfig(before: configBefore, target: transaction.targetSnapshot.config)) else {
            throw AgentSwapError.storage("Claude 데스크톱 전환 기록의 설정 변경이 안전하지 않습니다.")
        }
        let sourceBrowser = Dictionary(uniqueKeysWithValues: transaction.sourceSnapshot.browserFiles.map { ($0.relativePath, $0.contents) })
        let targetBrowser = Dictionary(uniqueKeysWithValues: transaction.targetSnapshot.browserFiles.map { ($0.relativePath, $0.contents) })
        guard sourceBrowser.count == transaction.sourceSnapshot.browserFiles.count,
              targetBrowser.count == transaction.targetSnapshot.browserFiles.count else { throw AgentSwapError.storage("Claude 데스크톱 브라우저 인증 백업 경로가 중복되었습니다.") }
        var expectedAuth = Set<AuthMutation.Location>([.file(configURL.path)])
        for relative in Set(sourceBrowser.keys).union(targetBrowser.keys) {
            let location = AuthMutation.Location.file(try resolvedBrowserPath(relative).path)
            expectedAuth.insert(location)
            guard let mutation = transaction.authMutations.first(where: { $0.location == location }),
                  mutation.before == sourceBrowser[relative], mutation.after == targetBrowser[relative] else {
                throw AgentSwapError.storage("Claude 데스크톱 브라우저 인증 전환 기록이 안전하지 않습니다.")
            }
        }
        guard Set(transaction.authMutations.map(\.location)) == expectedAuth else { throw AgentSwapError.storage("Claude 데스크톱 전환 기록에 허용되지 않은 인증 위치가 있습니다.") }
        let targetPrefix = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/\(transaction.target.userID)/\(transaction.target.workspaceID)").path + "/"
        guard Set(transaction.codeMutations.map(\.location)).count == transaction.codeMutations.count else {
            throw AgentSwapError.storage("Claude Code 전환 기록에 중복된 위치가 있습니다.")
        }
        for mutation in transaction.codeMutations {
            guard case .file(let path) = mutation.location, path.hasPrefix(targetPrefix),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path,
                  !path.dropFirst(targetPrefix.count).contains("/"),
                  path.dropFirst(targetPrefix.count).hasPrefix("local_"), path.hasSuffix(".json"),
                  UUID(uuidString: String(path.dropFirst(targetPrefix.count + 6).dropLast(5))) != nil,
                  mutation.before?.count ?? 0 <= 1_024 * 1_024,
                  let after = mutation.after, after.count <= 1_024 * 1_024 else {
                throw AgentSwapError.storage("Claude Code 전환 기록의 경로 또는 크기가 안전하지 않습니다.")
            }
            guard let object = try JSONSerialization.jsonObject(with: after) as? [String: Any],
                  object["sessionId"] as? String == String(path.dropFirst(targetPrefix.count).dropLast(5)),
                  let cliID = object["cliSessionId"] as? String, UUID(uuidString: cliID) != nil else {
                throw AgentSwapError.storage("Claude Code 전환 기록의 대화 식별자를 확인하지 못했습니다.")
            }
        }
        for file in transaction.sourceSnapshot.browserFiles + transaction.targetSnapshot.browserFiles {
            _ = try resolvedBrowserPath(file.relativePath)
        }
        let bytes = transaction.authMutations.reduce(0) { $0 + ($1.before?.count ?? 0) + ($1.after?.count ?? 0) }
            + transaction.codeMutations.reduce(0) { $0 + ($1.before?.count ?? 0) + ($1.after?.count ?? 0) }
        guard bytes <= 64 * 1_024 * 1_024 else { throw AgentSwapError.storage("Claude 데스크톱 전환 기록 크기를 지원하지 않습니다.") }
    }
}
