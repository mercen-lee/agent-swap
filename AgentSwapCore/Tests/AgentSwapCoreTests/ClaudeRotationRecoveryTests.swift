import CryptoKit
import Foundation
import Testing
@testable import AgentSwapCore

// Every mutable fixture value and failure counter is serialized by this one lock.
private final class RotationRecoveryKeychain: KeychainWritePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failingWrites: [String: Int] = [:]
    private var failingDeletes = Set<String>()
    private var incorrectReadbackAfterWrite: [String: Data] = [:]
    private var nextReadOverrides: [String: Data] = [:]
    private var providerReads = 0, providerWrites = 0
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(service: String, account: String) -> Data? {
        lock.withLock {
            if service != AuthTransaction.service && service != KeychainSecretStore.service { providerReads += 1 }
            let item = key(service, account)
            if let incorrect = nextReadOverrides.removeValue(forKey: item) { return incorrect }
            return items[item]
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
            if let incorrect = incorrectReadbackAfterWrite.removeValue(forKey: item) { nextReadOverrides[item] = incorrect }
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
    func returnIncorrectReadbackAfterNextWrite(_ data: Data, service: String, account: String) {
        lock.withLock { incorrectReadbackAfterWrite[key(service, account)] = data }
    }
    func failDelete(service: String, account: String) { _ = lock.withLock { failingDeletes.insert(key(service, account)) } }
    func items(service: String, accountPrefix: String) -> [(account: String, data: Data)] {
        lock.withLock {
            let prefix = service + "|" + accountPrefix
            return items.compactMap { key, data in
                guard key.hasPrefix(prefix) else { return nil }
                return (String(key.dropFirst(service.count + 1)), data)
            }.sorted { $0.account < $1.account }
        }
    }
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
    func preservedKey(_ marker: Data, store: ClaudeAuthStore) -> String {
        let digest = SHA256.hash(data: marker).map { String(format: "%02x", $0) }.joined()
        return rotationKey(store) + "|preserved|" + digest
    }
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
    private func stagedThirdGeneration(_ fixture: RotationRecoveryFixture, id: UUID) async throws ->
        (store: ClaudeAuthStore, account: AccountRecord, pending: Credential, current: Credential,
         marker: Data, native: Data, vaultBefore: Data, config: Data) {
        let store = fixture.store()
        let original = try fixture.credential(token: "original", sharedLabel: "fixture")
        let pending = try fixture.credential(token: "pending-successor", sharedLabel: "fixture")
        let current = try fixture.credential(token: "current-third-generation", sharedLabel: "fixture")
        _ = try fixture.seed(original, store: store)
        fixture.keychain.failWrite(service: KeychainSecretStore.service, account: id.uuidString)
        do { _ = try await store.refresh(original, accountID: id) { _ in pending } }
        catch { /* The durable rotation marker is the intended interrupted state. */ }
        let marker = try fixture.marker(store)
        let native = try claudeCLIAuthData(authObject(current.rawAuth, name: "Fixture current"))
        let vaultBefore = try JSONEncoder().encode(pending)
        fixture.keychain.seed(native, service: store.keychainService, account: store.keychainAccount)
        try fixture.files.write(native, to: store.configDirectory.appendingPathComponent(".credentials.json"))
        fixture.keychain.seed(vaultBefore, service: KeychainSecretStore.service, account: id.uuidString)
        let account = AccountRecord(id: id, identity: .init(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace"))
        return (fixture.store(), account, pending, current, marker, native, vaultBefore,
                try #require(try fixture.files.read(store.configURL)))
    }

    private func preserveCurrent(_ staged: (store: ClaudeAuthStore, account: AccountRecord, pending: Credential, current: Credential,
                                                                  marker: Data, native: Data, vaultBefore: Data, config: Data)) async throws -> ImportedAccount {
        let imported = ImportedAccount(account: staged.account, credential: staged.current)
        return try await KeychainInteraction.$mode.withValue(.interactive) {
            try await staged.store.recoverKeepingCurrentLogin(account: staged.account) { candidate in
                guard candidate.accessToken == staged.current.accessToken,
                      candidate.refreshToken == staged.current.refreshToken else {
                    throw AgentSwapError.authentication("Fixture verified an unexpected current generation")
                }
                return imported
            }
        }
    }

    private func sortedCredentialData(_ credential: Credential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(credential)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Keeping a verified current native generation archives the pending successor without changing the current profile")
    func keepsCurrentNativeGenerationAndArchivesPendingSuccessor() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let vaultCurrent = try sortedCredentialData(staged.current)
        let imported = try await preserveCurrent(staged)
        #expect(imported.credential.accessToken == staged.current.accessToken)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
        #expect(try fixture.files.read(staged.store.configDirectory.appendingPathComponent(".credentials.json")) == staged.native)
        #expect(try fixture.files.read(staged.store.configURL) == staged.config)
        #expect(fixture.keychain.read(service: KeychainSecretStore.service, account: staged.account.id.uuidString) == vaultCurrent)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == nil)
        let archive = try #require(fixture.keychain.read(service: AuthTransaction.service, account: fixture.preservedKey(staged.marker, store: staged.store)))
        let object = try authObject(archive, name: "Fixture preserved rotation")
        #expect(object["originalRotationMarker"] as? String == staged.marker.base64EncodedString())
        #expect(object["vaultBefore"] as? String == staged.vaultBefore.base64EncodedString())
        #expect(object["currentVaultData"] as? String == vaultCurrent.base64EncodedString())
        #expect(object["nativeKeychainDigest"] as? String == digest(staged.native))
        #expect(object["nativeFileDigest"] as? String == digest(staged.native))
        #expect(object["configDigest"] as? String == digest(staged.config))
    }

    @Test("Profile verification failures or mismatched identities leave the current generation and marker untouched", arguments: ["throws", "identity"])
    func profileVerificationFailureDoesNotWrite(kind: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        await #expect(throws: (any Error).self) {
            try await KeychainInteraction.$mode.withValue(.interactive) {
                try await staged.store.recoverKeepingCurrentLogin(account: staged.account) { _ in
                    if kind == "throws" { throw AgentSwapError.authentication("Fixture profile failure") }
                    var other = staged.account; other.identity.userID = "different-user"
                    return .init(account: other, credential: staged.current)
                }
            }
        }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
        #expect(try fixture.files.read(staged.store.configURL) == staged.config)
        #expect(fixture.keychain.items(service: AuthTransaction.service, accountPrefix: fixture.rotationKey(staged.store) + "|preserved|").isEmpty)
    }

    @Test("A native or vault generation changed while profile verification awaits is preserved without recovery writes", arguments: ["native", "vault"])
    func verificationRaceFailsClosed(kind: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let replacement: Data
        if kind == "native" {
            let next = try fixture.credential(token: "raced-current", sharedLabel: "fixture")
            replacement = try claudeCLIAuthData(authObject(next.rawAuth, name: "Fixture race"))
        } else { replacement = try sortedCredentialData(try fixture.credential(token: "raced-vault", sharedLabel: "fixture")) }
        await #expect(throws: (any Error).self) {
            try await KeychainInteraction.$mode.withValue(.interactive) {
                try await staged.store.recoverKeepingCurrentLogin(account: staged.account) { _ in
                    if kind == "native" { fixture.keychain.seed(replacement, service: staged.store.keychainService, account: staged.store.keychainAccount) }
                    else { fixture.keychain.seed(replacement, service: KeychainSecretStore.service, account: staged.account.id.uuidString) }
                    return .init(account: staged.account, credential: staged.current)
                }
            }
        }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        if kind == "native" { #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == replacement) }
        else { #expect(fixture.keychain.read(service: KeychainSecretStore.service, account: staged.account.id.uuidString) == replacement) }
    }

    @Test("Current-login preservation is rejected outside an interactive operation")
    func noninteractivePreservationDoesNotWrite() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        await #expect(throws: (any Error).self) {
            try await staged.store.recoverKeepingCurrentLogin(account: staged.account) { _ in
                .init(account: staged.account, credential: staged.current)
            }
        }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.items(service: AuthTransaction.service, accountPrefix: fixture.rotationKey(staged.store) + "|preserved|").isEmpty)
    }

    @Test("Purging registered preserved recovery archives leaves the current login and vault intact, and refuses a pending marker")
    func purgePreservedArchivesDoesNotTouchCurrentAuthentication() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        _ = try await preserveCurrent(staged)
        let archiveKey = fixture.preservedKey(staged.marker, store: staged.store)
        let indexKey = fixture.journalKey(staged.store) + "|preserved-index|" + staged.account.id.uuidString
        let currentVault = try sortedCredentialData(staged.current)
        try await staged.store.deletePreservedRecoveryCredentials(accountID: staged.account.id)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: archiveKey) == nil)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: indexKey) == nil)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
        #expect(try fixture.files.read(staged.store.configDirectory.appendingPathComponent(".credentials.json")) == staged.native)
        #expect(try fixture.files.read(staged.store.configURL) == staged.config)
        #expect(fixture.keychain.read(service: KeychainSecretStore.service, account: staged.account.id.uuidString) == currentVault)

        let pending = try await stagedThirdGeneration(fixture, id: UUID())
        await #expect(throws: (any Error).self) { try await pending.store.deletePreservedRecoveryCredentials(accountID: pending.account.id) }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(pending.store)) == pending.marker)
    }

    @Test("A committed Claude transaction journal is discarded before preserving a third-generation current login")
    func committedJournalAllowsKeepingCurrentLogin() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let journal = AuthTransaction(identifier: fixture.journalKey(staged.store), keychain: fixture.keychain, files: fixture.files)
        fixture.keychain.failDelete(service: AuthTransaction.service, account: fixture.journalKey(staged.store))
        try journal.perform([.init(location: .file(staged.store.configURL.path), before: staged.config, after: staged.config)]) {}
        #expect(try journal.hasPendingRecovery())
        _ = try await preserveCurrent(staged)
        #expect(try !journal.hasPendingRecovery())
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == nil)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
    }

    @Test("Unfinished or malformed Claude transaction journals block current-login preservation without writes", arguments: ["unfinished", "malformed"])
    func unsafeTransactionJournalBlocksKeepingCurrentLogin(kind: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let journalKey = fixture.journalKey(staged.store)
        if kind == "malformed" { fixture.keychain.seed(Data("bad-journal".utf8), service: AuthTransaction.service, account: journalKey) }
        else {
            let journal = AuthTransaction(identifier: journalKey, keychain: fixture.keychain, files: fixture.files)
            fixture.files.failNextWrite(staged.store.configURL)
            fixture.keychain.failWrite(service: staged.store.keychainService, account: staged.store.keychainAccount, afterSuccesses: 1)
            #expect(throws: (any Error).self) {
                try journal.perform([
                    .init(location: .keychain(service: staged.store.keychainService, account: staged.store.keychainAccount), before: staged.native, after: Data("temporary".utf8)),
                    .init(location: .file(staged.store.configURL.path), before: staged.config, after: Data("changed".utf8))
                ]) {}
            }
            fixture.keychain.seed(staged.native, service: staged.store.keychainService, account: staged.store.keychainAccount)
        }
        let bytes = try #require(fixture.keychain.read(service: AuthTransaction.service, account: journalKey))
        await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) == bytes)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
    }

    @Test("Archive and current-vault persistence failures retain the active rotation marker", arguments: ["archive-write", "archive-readback", "vault-write", "vault-readback"])
    func preservingCurrentFailureRetainsMarker(kind: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let archiveKey = fixture.preservedKey(staged.marker, store: staged.store)
        if kind == "archive-write" { fixture.keychain.failWrite(service: AuthTransaction.service, account: archiveKey) }
        if kind == "archive-readback" { fixture.keychain.returnIncorrectReadbackAfterNextWrite(Data("wrong".utf8), service: AuthTransaction.service, account: archiveKey) }
        if kind == "vault-write" { fixture.keychain.failWrite(service: KeychainSecretStore.service, account: staged.account.id.uuidString) }
        if kind == "vault-readback" { fixture.keychain.returnIncorrectReadbackAfterNextWrite(Data("wrong".utf8), service: KeychainSecretStore.service, account: staged.account.id.uuidString) }
        await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
        #expect(try fixture.files.read(staged.store.configDirectory.appendingPathComponent(".credentials.json")) == staged.native)
        #expect(try fixture.files.read(staged.store.configURL) == staged.config)
    }

    @Test("An indexed archive intent blocks normal recovery even if native authentication returns to the interrupted generations", arguments: ["original", "successor"])
    func indexedArchiveIntentBlocksNormalRecovery(kind: String) async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        fixture.keychain.failWrite(service: AuthTransaction.service, account: fixture.preservedKey(staged.marker, store: staged.store))
        await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
        let marker = try authObject(staged.marker, name: "Fixture marker")
        let field = kind == "original" ? "expectedRaw" : "nativeAfter"
        let encoded = try #require(marker[field] as? String)
        let native = try #require(Data(base64Encoded: encoded))
        fixture.keychain.seed(native, service: staged.store.keychainService, account: staged.store.keychainAccount)
        try fixture.files.write(native, to: staged.store.configDirectory.appendingPathComponent(".credentials.json"))
        await #expect(throws: (any Error).self) { try await staged.store.recoverInterruptedSwitch() }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == native)
    }

    @Test("An exact unfinished native rotation is archived and resumes after either journal or marker deletion fails", arguments: ["success", "journal-delete", "marker-delete"])
    func exactUnfinishedJournalPreservesCurrentLogin(kind: String) async throws {
        struct FixtureJournal: Encodable {
            var version = 1
            var committed = false
            let mutations: [AuthMutation]
        }
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let marker = try authObject(staged.marker, name: "Fixture marker")
        let beforeString = try #require(marker["expectedRaw"] as? String)
        let afterString = try #require(marker["nativeAfter"] as? String)
        let before = try #require(Data(base64Encoded: beforeString))
        let after = try #require(Data(base64Encoded: afterString))
        let journalKey = fixture.journalKey(staged.store)
        let journalData = try JSONEncoder().encode(FixtureJournal(mutations: [
            .init(location: .keychain(service: staged.store.keychainService, account: staged.store.keychainAccount), before: before, after: after),
            .init(location: .file(staged.store.configDirectory.appendingPathComponent(".credentials.json").path), before: before, after: after)
        ]))
        fixture.keychain.seed(journalData, service: AuthTransaction.service, account: journalKey)
        if kind != "success" {
            let failingKey = kind == "journal-delete" ? journalKey : fixture.rotationKey(staged.store)
            fixture.keychain.failDelete(service: AuthTransaction.service, account: failingKey)
            await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
            #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
            #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) == (kind == "journal-delete" ? journalData : nil))
        }
        // Fresh profile display metadata must not prevent resuming the same archived grant.
        var refreshedProfile = staged.current
        refreshedProfile.accountMetadata = try authData(["accountUuid": "fixture-user", "organizationUuid": "fixture-workspace", "emailAddress": "updated@example.com"])
        let verified = ImportedAccount(account: staged.account, credential: refreshedProfile)
        _ = try await KeychainInteraction.$mode.withValue(.interactive) {
            try await staged.store.recoverKeepingCurrentLogin(account: staged.account) { _ in verified }
        }
        let archiveKey = fixture.preservedKey(staged.marker, store: staged.store)
        let archive = try #require(fixture.keychain.read(service: AuthTransaction.service, account: archiveKey))
        let archived = try authObject(archive, name: "Fixture archive")
        #expect(archived["originalTransactionJournal"] as? String == journalData.base64EncodedString())
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) == nil)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == nil)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
        #expect(try fixture.files.read(staged.store.configURL) == staged.config)
    }

    @Test("A file-only interrupted native rotation preserves a third-generation current login")
    func fileOnlyUnfinishedJournalPreservesCurrentLogin() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let store = fixture.store()
        let accountID = UUID()
        let original = try fixture.credential(token: "file-only-original", sharedLabel: "fixture")
        let pending = try fixture.credential(token: "file-only-successor", sharedLabel: "fixture")
        let current = try fixture.credential(token: "file-only-third-generation", sharedLabel: "fixture")
        _ = try fixture.seed(original, store: store)
        try fixture.keychain.delete(service: store.keychainService, account: store.keychainAccount)
        let authURL = store.configDirectory.appendingPathComponent(".credentials.json")
        fixture.files.failNextWrite(authURL)
        fixture.keychain.failDelete(service: store.keychainService, account: store.keychainAccount)
        do { _ = try await store.refresh(original, accountID: accountID) { _ in pending } }
        catch { /* The failed forward write and failed rollback retain the exact transaction journal. */ }

        _ = try fixture.marker(store)
        let journalKey = fixture.journalKey(store)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) != nil)
        let currentNative = try claudeCLIAuthData(authObject(current.rawAuth, name: "Fixture current"))
        try fixture.keychain.delete(service: store.keychainService, account: store.keychainAccount)
        try fixture.files.write(currentNative, to: authURL)

        let account = AccountRecord(id: accountID, identity: .init(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace"))
        let imported = try await KeychainInteraction.$mode.withValue(.interactive) {
            try await store.recoverKeepingCurrentLogin(account: account) { candidate in
                #expect(candidate.accessToken == current.accessToken)
                return .init(account: account, credential: current)
            }
        }
        #expect(imported.credential.accessToken == current.accessToken)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) == nil)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == nil)
        #expect(fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == nil)
        #expect(try fixture.files.read(authURL) == currentNative)
    }

    @Test("A file-only recovery rejects a journal with an absent file before-image")
    func fileOnlyUnfinishedJournalRejectsWrongAbsentBeforeImage() async throws {
        struct FixtureJournal: Encodable {
            var version = 1
            var committed = false
            let mutations: [AuthMutation]
        }
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        let marker = try authObject(staged.marker, name: "Fixture marker")
        let after = try #require((marker["nativeAfter"] as? String).flatMap { Data(base64Encoded: $0) })
        let journalData = try JSONEncoder().encode(FixtureJournal(mutations: [
            .init(location: .keychain(service: staged.store.keychainService, account: staged.store.keychainAccount), before: nil, after: after),
            .init(location: .file(staged.store.configDirectory.appendingPathComponent(".credentials.json").path), before: nil, after: after)
        ]))
        let journalKey = fixture.journalKey(staged.store)
        fixture.keychain.seed(journalData, service: AuthTransaction.service, account: journalKey)

        await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: journalKey) == journalData)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == staged.marker)
        #expect(fixture.keychain.read(service: staged.store.keychainService, account: staged.store.keychainAccount) == staged.native)
    }

    @Test("A failed active-marker deletion resumes from its preserved archive without creating another archive")
    func preservedArchiveRetriesIdempotently() async throws {
        let fixture = try RotationRecoveryFixture(); defer { fixture.cleanup() }
        let staged = try await stagedThirdGeneration(fixture, id: UUID())
        fixture.keychain.failDelete(service: AuthTransaction.service, account: fixture.rotationKey(staged.store))
        await #expect(throws: (any Error).self) { _ = try await preserveCurrent(staged) }
        let archiveKey = fixture.preservedKey(staged.marker, store: staged.store)
        let archive = try #require(fixture.keychain.read(service: AuthTransaction.service, account: archiveKey))
        await #expect(throws: (any Error).self) { try await staged.store.recoverInterruptedSwitch() }
        _ = try await preserveCurrent(staged)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: archiveKey) == archive)
        #expect(fixture.keychain.items(service: AuthTransaction.service, accountPrefix: fixture.rotationKey(staged.store) + "|preserved|").count == 1)
        #expect(fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(staged.store)) == nil)
    }

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
