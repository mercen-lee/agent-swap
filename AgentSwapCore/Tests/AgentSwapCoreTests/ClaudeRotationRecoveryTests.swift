import Foundation
import Testing
@testable import AgentSwapCore

// Every mutable fixture value and failure counter is serialized by this one lock.
private final class RotationRecoveryKeychain: KeychainWritePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failingWrites: [String: Int] = [:]
    private var failingDeletes = Set<String>()
    private var providerReads = 0, providerWrites = 0
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(service: String, account: String) -> Data? {
        lock.withLock {
            if service != AuthTransaction.service && service != KeychainSecretStore.service { providerReads += 1 }
            return items[key(service, account)]
        }
    }
    func validateWrite(_ data: Data, service: String, account: String) throws {
        if service.hasPrefix("Claude Code-credentials") { _ = try NativeSecurityCommand.write(data, service: service, account: account) }
    }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let item = key(service, account)
            if let remaining = failingWrites[item] {
                if remaining == 0 {
                    failingWrites.removeValue(forKey: item)
                    throw AgentSwapError.storage("Fixture write failure")
                }
                failingWrites[item] = remaining - 1
            }
            if service != AuthTransaction.service && service != KeychainSecretStore.service { providerWrites += 1 }
            items[item] = data
        }
    }
    func delete(service: String, account: String) throws {
        try lock.withLock {
            let item = key(service, account)
            if failingDeletes.remove(item) != nil { throw AgentSwapError.storage("Fixture delete failure") }
            items.removeValue(forKey: item)
        }
    }
    func seed(_ data: Data, service: String, account: String) { lock.withLock { items[key(service, account)] = data } }
    func failWrite(service: String, account: String, afterSuccesses: Int = 0) {
        lock.withLock { failingWrites[key(service, account)] = afterSuccesses }
    }
    func failDelete(service: String, account: String) { _ = lock.withLock { failingDeletes.insert(key(service, account)) } }
    func counts() -> (reads: Int, writes: Int) { lock.withLock { (providerReads, providerWrites) } }
}

// Only private temporary files are used. Faults and counters have the same synchronization rule.
private final class RotationRecoveryFiles: AuthFileAccess, @unchecked Sendable {
    private let lock = NSLock(), base = AtomicAuthFileAccess()
    private var failedWriteURL: URL?
    private var reads = 0, writes = 0
    func read(_ url: URL) throws -> Data? { lock.withLock { reads += 1 }; return try base.read(url) }
    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock {
            if failedWriteURL == url { failedWriteURL = nil; return true }
            writes += 1; return false
        }
        if fail { throw AgentSwapError.storage("Fixture mirror failure") }
        try base.write(data, to: url)
    }
    func delete(_ url: URL) throws { try base.delete(url) }
    func failNextWrite(_ url: URL) { lock.withLock { failedWriteURL = url } }
    func counts() -> (reads: Int, writes: Int) { lock.withLock { (reads, writes) } }
}

private struct RotationRecoveryFixture: Sendable {
    let home: URL
    let keychain = RotationRecoveryKeychain()
    let files = RotationRecoveryFiles()
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapRotationRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func store() -> ClaudeAuthStore {
        ClaudeAuthStore(home: home, keychain: keychain, files: files, environmentUser: "fixture-user", systemUser: "fixture-user")
    }
    func credential(token: String, sharedLabel: String) throws -> Credential {
        try CredentialParser.claude(rawAuth: authData([
            "claudeAiOauth": ["accessToken": token, "refreshToken": "fixture-refresh-\(token)", "expiresAt": 1_900_000_000_000],
            "organizationUuid": "fixture-workspace",
            "mcpOAuth": ["fixture": ["label": sharedLabel, "token": "fixture-mcp-grant"]],
            "pluginSecrets": ["fixture": ["label": sharedLabel]]
        ]), accountMetadata: authData(["accountUuid": "fixture-user", "organizationUuid": "fixture-workspace"]))
    }
    @discardableResult
    func seed(_ credential: Credential, store: ClaudeAuthStore, mirror: Bool = true) throws -> Data {
        let nativeBefore = try claudeCLIAuthData(authObject(credential.rawAuth, name: "Fixture source"))
        keychain.seed(nativeBefore, service: store.keychainService, account: store.keychainAccount)
        if mirror { try files.write(nativeBefore, to: store.configDirectory.appendingPathComponent(".credentials.json")) }
        try files.write(authData(["oauthAccount": authObject(try #require(credential.accountMetadata), name: "Fixture"), "theme": "dark"]), to: store.configURL)
        return nativeBefore
    }
    func rotationKey(_ store: ClaudeAuthStore) -> String { journalKey(store) + "|rotation" }
    func journalKey(_ store: ClaudeAuthStore) -> String { "claude|" + storageDigest(store.configDirectory.path, prefix: 32) }
    func marker(_ store: ClaudeAuthStore) throws -> Data {
        try #require(keychain.read(service: AuthTransaction.service, account: rotationKey(store)))
    }
    func nativeImage(_ successor: Credential, source: Credential) throws -> Data {
        var object = try authObject(successor.rawAuth, name: "Fixture successor")
        let before = try authObject(source.rawAuth, name: "Fixture source")
        object["mcpOAuth"] = before["mcpOAuth"]; object["pluginSecrets"] = before["pluginSecrets"]
        return try claudeCLIAuthData(object)
    }
}

@Suite("Exact Claude rotation and committed transaction recovery")
struct ClaudeRotationRecoveryTests {
    @Test("Unicode integrations recover their exact native successor after committed marker cleanup fails")
    func committedUnicodeSuccessor() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let old = try fixture.credential(token: "old", sharedLabel: "원본 🔒"), successor = try fixture.credential(token: "successor", sharedLabel: "교체하면 안 됨 🎉")
        try fixture.seed(old, store: store)
        let config = try fixture.files.read(store.configURL)
        let expected = try fixture.nativeImage(successor, source: old)
        #expect(expected != successor.rawAuth)
        fixture.keychain.failDelete(service: AuthTransaction.service, account: fixture.rotationKey(store))
        _ = try await store.refresh(old, accountID: id) { _ in successor }
        let marker = try fixture.marker(store)
        #expect(try authObject(marker, name: "Fixture marker")["nativeAfter"] as? String == expected.base64EncodedString())
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == expected)
        #expect(expected.allSatisfy { (32...126).contains($0) })
        #expect(!(await store.compatibility()).canWrite)

        // A new store instance exercises durable recovery rather than in-memory refresh state.
        let restarted = fixture.store()
        try await restarted.recoverInterruptedSwitch()
        #expect(try await restarted.read().accessToken == successor.accessToken)
        #expect(try await KeychainSecretStore(keychain: fixture.keychain).load(accountID: id)?.refreshToken == successor.refreshToken)
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == expected)
        #expect(try fixture.files.read(store.configDirectory.appendingPathComponent(".credentials.json")) == expected)
        #expect(try fixture.files.read(store.configURL) == config)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == nil)
    }

    @Test("An interrupted precommit rollback restores the source before applying the exact canonical successor")
    func interruptedUnicodeRollback() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let old = try fixture.credential(token: "old", sharedLabel: "원본 🔒"), successor = try fixture.credential(token: "successor", sharedLabel: "응답의 다른 플러그인 값")
        let nativeBefore = try fixture.seed(old, store: store)
        let authURL = store.configDirectory.appendingPathComponent(".credentials.json")
        let expected = try fixture.nativeImage(successor, source: old)
        fixture.files.failNextWrite(authURL)
        fixture.keychain.failWrite(service: store.keychainService, account: store.keychainAccount, afterSuccesses: 1)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(old, accountID: id) { _ in successor } }
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == expected)
        #expect(try fixture.files.read(authURL) == nativeBefore)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.journalKey(store)) != nil)
        #expect(try await KeychainSecretStore(keychain: fixture.keychain).load(accountID: id)?.accessToken == successor.accessToken)
        try await fixture.store().recoverInterruptedSwitch()
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == expected)
        #expect(try fixture.files.read(authURL) == expected)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.journalKey(store)) == nil)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == nil)
    }

    @Test("A newer external grant remains untouched by rotation recovery", arguments: [false, true])
    func externalRotation(afterCommit: Bool) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let old = try fixture.credential(token: "old", sharedLabel: "원본 🔒"), successor = try fixture.credential(token: "successor", sharedLabel: "원본 🔒")
        try fixture.seed(old, store: store)
        if afterCommit { fixture.keychain.failDelete(service: AuthTransaction.service, account: fixture.rotationKey(store)) }
        else { fixture.keychain.failWrite(service: KeychainSecretStore.service, account: id.uuidString) }
        if afterCommit { _ = try await store.refresh(old, accountID: id) { _ in successor } }
        else { await #expect(throws: AgentSwapError.self) { try await store.refresh(old, accountID: id) { _ in successor } } }
        let marker = try fixture.marker(store)
        let external = try fixture.credential(token: "third-newer-grant", sharedLabel: "원본 🔒")
        let externalData = try claudeCLIAuthData(authObject(external.rawAuth, name: "Fixture external"))
        fixture.keychain.seed(externalData, service: store.keychainService, account: store.keychainAccount)
        let counts = fixture.keychain.counts()
        await #expect(throws: AgentSwapError.self) { try await fixture.store().recoverInterruptedSwitch() }
        #expect(fixture.keychain.counts().writes == counts.writes)
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == externalData)
        #expect(try fixture.marker(store) == marker)
    }

    @Test("Malformed, missing and unbound native rotation images are retained without native writes", arguments: ["missingAfter", "missingBefore", "differentAfter", "wrongSourceOrganization", "wrongCredentialToken"])
    func unknownRotationMarker(change: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let old = try fixture.credential(token: "old", sharedLabel: "원본 🔒"), successor = try fixture.credential(token: "successor", sharedLabel: "원본 🔒")
        let nativeBefore = try fixture.seed(old, store: store)
        fixture.keychain.failWrite(service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(old, accountID: id) { _ in successor } }
        var marker = try authObject(fixture.marker(store), name: "Fixture marker")
        switch change {
        case "missingAfter": marker.removeValue(forKey: "nativeAfter")
        case "missingBefore": marker.removeValue(forKey: "expectedRaw")
        case "differentAfter": marker["nativeAfter"] = old.rawAuth.base64EncodedString()
        case "wrongSourceOrganization":
            var source = try authObject(old.rawAuth, name: "Fixture source")
            source["organizationUuid"] = "other-workspace"
            marker["expectedRaw"] = try authData(source).base64EncodedString()
        default:
            var credential = try #require(marker["credential"] as? [String: Any])
            credential["accessToken"] = "different-model-token"; marker["credential"] = credential
        }
        let malformed = try authData(marker)
        fixture.keychain.seed(malformed, service: AuthTransaction.service, account: fixture.rotationKey(store))
        let counts = fixture.keychain.counts()
        await #expect(throws: AgentSwapError.self) { try await fixture.store().recoverInterruptedSwitch() }
        #expect(fixture.keychain.counts().writes == counts.writes)
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == nativeBefore)
        #expect(try fixture.marker(store) == malformed)
    }

    @Test("Committed cleanup preserves a later consumer grant and external configuration without even reading them")
    func committedJournalExternalChange() throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let account = "fixture", service = "fixture-native", identifier = "fixture-committed"
        let configURL = fixture.home.appendingPathComponent("config.json")
        let before = Data("old-grant".utf8), after = Data("applied-grant".utf8), external = Data("consumer-rotated-grant".utf8)
        let configBefore = Data("old-config".utf8), configAfter = Data("applied-config".utf8), configExternal = Data("external-config".utf8)
        fixture.keychain.seed(before, service: service, account: account)
        try fixture.files.write(configBefore, to: configURL)
        let locations: Set<AuthMutation.Location> = [.keychain(service: service, account: account), .file(configURL.path)]
        let transaction = AuthTransaction(identifier: identifier, keychain: fixture.keychain, files: fixture.files)
        fixture.keychain.failDelete(service: AuthTransaction.service, account: identifier)
        try transaction.perform([
            .init(location: .keychain(service: service, account: account), before: before, after: after),
            .init(location: .file(configURL.path), before: configBefore, after: configAfter)
        ]) {}
        #expect(try transaction.hasPendingRecovery())
        fixture.keychain.seed(external, service: service, account: account)
        try fixture.files.write(configExternal, to: configURL)
        let keychainCounts = fixture.keychain.counts(), fileCounts = fixture.files.counts()
        try transaction.recover(allowedLocations: locations)
        #expect(fixture.keychain.counts().reads == keychainCounts.reads)
        #expect(fixture.keychain.counts().writes == keychainCounts.writes)
        #expect(fixture.files.counts().reads == fileCounts.reads)
        #expect(fixture.files.counts().writes == fileCounts.writes)
        #expect(fixture.keychain.read(service: service, account: account) == external)
        #expect(try fixture.files.read(configURL) == configExternal)
        #expect(try !transaction.hasPendingRecovery())
    }

    @Test("Uncommitted recovery refuses external grants and configuration before any restore")
    func uncommittedJournalExternalChange() throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let account = "fixture", service = "fixture-native", identifier = "fixture-uncommitted"
        let configURL = fixture.home.appendingPathComponent("config.json")
        let before = Data("old-grant".utf8), after = Data("applied-grant".utf8), external = Data("external-grant".utf8)
        let configBefore = Data("old-config".utf8), configAfter = Data("applied-config".utf8), configExternal = Data("external-config".utf8)
        fixture.keychain.seed(before, service: service, account: account)
        try fixture.files.write(configBefore, to: configURL)
        let transaction = AuthTransaction(identifier: identifier, keychain: fixture.keychain, files: fixture.files)
        fixture.files.failNextWrite(configURL)
        fixture.keychain.failWrite(service: service, account: account, afterSuccesses: 1)
        #expect(throws: AgentSwapError.self) {
            try transaction.perform([
                .init(location: .keychain(service: service, account: account), before: before, after: after),
                .init(location: .file(configURL.path), before: configBefore, after: configAfter)
            ]) {}
        }
        let marker = try #require(fixture.keychain.read(service: AuthTransaction.service, account: identifier))
        fixture.keychain.seed(external, service: service, account: account)
        try fixture.files.write(configExternal, to: configURL)
        let keychainCounts = fixture.keychain.counts(), fileCounts = fixture.files.counts()
        #expect(throws: AgentSwapError.self) {
            try transaction.recover(allowedLocations: [.keychain(service: service, account: account), .file(configURL.path)])
        }
        #expect(fixture.keychain.counts().writes == keychainCounts.writes)
        #expect(fixture.files.counts().writes == fileCounts.writes)
        #expect(fixture.keychain.read(service: service, account: account) == external)
        #expect(try fixture.files.read(configURL) == configExternal)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: identifier) == marker)
    }

    @Test("Committed journals still require their known schema and complete location allowlist", arguments: [false, true])
    func committedJournalValidation(unknownVersion: Bool) throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let service = "fixture-native", account = "fixture", identifier = "fixture-validation"
        let transaction = AuthTransaction(identifier: identifier, keychain: fixture.keychain, files: fixture.files)
        fixture.keychain.failDelete(service: AuthTransaction.service, account: identifier)
        try transaction.perform([.init(location: .keychain(service: service, account: account), before: nil, after: Data("new-grant".utf8))]) {}
        if unknownVersion {
            var journal = try authObject(try #require(fixture.keychain.read(service: AuthTransaction.service, account: identifier)), name: "Fixture journal")
            journal["version"] = 2
            fixture.keychain.seed(try authData(journal), service: AuthTransaction.service, account: identifier)
        }
        let marker = try #require(fixture.keychain.read(service: AuthTransaction.service, account: identifier))
        let counts = fixture.keychain.counts()
        #expect(throws: AgentSwapError.self) {
            try transaction.recover(allowedLocations: unknownVersion ? [.keychain(service: service, account: account)] : [])
        }
        #expect(fixture.keychain.counts().reads == counts.reads)
        #expect(fixture.keychain.counts().writes == counts.writes)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: identifier) == marker)
    }
}
