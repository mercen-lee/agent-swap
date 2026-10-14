import Foundation
import CryptoKit
import Testing
@testable import AgentSwapCore

// All fixture data and one-shot failures share this lock; no real Keychain is accessed.
enum RetentionPersistenceFault: Sendable, Equatable { case beforeWrite, afterWrite, readback }

private final class RetentionKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var faults: [String: RetentionPersistenceFault] = [:]
    private var failedReads = Set<String>()
    private var writes: [String: Int] = [:]
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            let item = key(service, account)
            if failedReads.remove(item) != nil { throw AgentSwapError.storage("Fixture readback denied") }
            return values[item]
        }
    }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let item = key(service, account), fault = faults.removeValue(forKey: item)
            writes[item, default: 0] += 1
            if fault == .beforeWrite { throw AgentSwapError.storage("Fixture first save denied") }
            values[item] = data
            if fault == .afterWrite { throw AgentSwapError.storage("Fixture save reported failure") }
            if fault == .readback { failedReads.insert(item) }
        }
    }
    func delete(service: String, account: String) { _ = lock.withLock { values.removeValue(forKey: key(service, account)) } }
    func seed(_ data: Data, service: String, account: String) { lock.withLock { values[key(service, account)] = data } }
    func fail(_ fault: RetentionPersistenceFault, service: String, account: String) { lock.withLock { faults[key(service, account)] = fault } }
    func writeCount(service: String, account: String) -> Int { lock.withLock { writes[key(service, account), default: 0] } }
}

private actor RetentionExchange {
    private(set) var calls = 0
    func grant(_ result: Credential) -> Credential { calls += 1; return result }
}

private struct RetentionFixture: Sendable {
    let home: URL
    let keychain = RetentionKeychain()
    let files = AtomicAuthFileAccess()
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapRetention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func store() -> ClaudeAuthStore {
        ClaudeAuthStore(home: home, keychain: keychain, files: files, environmentUser: "fixture", systemUser: "fixture")
    }
    func credential(_ token: String, user: String = "fixture-user") throws -> Credential {
        try CredentialParser.claude(rawAuth: authData([
            "claudeAiOauth": ["accessToken": token, "refreshToken": "fixture-refresh-\(token)", "expiresAt": 1_900_000_000_000],
            "organizationUuid": "fixture-workspace", "pluginSecrets": ["fixture": ["label": "보존 🔒"]]
        ]), accountMetadata: authData(["accountUuid": user, "organizationUuid": "fixture-workspace"]))
    }
    @discardableResult
    func seedNative(_ credential: Credential, store: ClaudeAuthStore) throws -> Data {
        let raw = credential.rawAuth
        keychain.seed(raw, service: store.keychainService, account: store.keychainAccount)
        try files.write(authData(["oauthAccount": authObject(try #require(credential.accountMetadata), name: "Fixture"), "theme": "dark"]), to: store.configURL)
        return raw
    }
    func rotationKey(_ store: ClaudeAuthStore) -> String {
        "claude|" + storageDigest(store.configDirectory.path, prefix: 32) + "|rotation"
    }
    func vault(_ id: UUID) throws -> Credential? {
        try keychain.read(service: KeychainSecretStore.service, account: id.uuidString).map { try JSONDecoder().decode(Credential.self, from: $0) }
    }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@Suite("Claude successors survive their first persistence failure")
struct ClaudeCredentialRetentionTests {
    @Test("Active first-save failure retains the successor, retries without a grant exchange and recovers explicitly")
    func activeFirstMarkerFailure() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        let native = try fixture.seedNative(before, store: store)
        fixture.keychain.seed(try JSONEncoder().encode(before), service: KeychainSecretStore.service, account: id.uuidString)
        fixture.keychain.fail(.beforeWrite, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        #expect(await store.hasPendingCredentialPersistence())
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == nil)
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
        #expect(try fixture.vault(id) == before)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        #expect(!(await store.hasPendingCredentialPersistence()))
        #expect(await exchange.calls == 1)
        #expect(try fixture.vault(id) == before) // first durable capture is only the marker
        try await store.recoverInterruptedSwitch()
        let adopted = try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) }
        #expect(adopted.accessToken == successor.accessToken)
        #expect(await exchange.calls == 1)
        #expect(try fixture.vault(id)?.refreshToken == successor.refreshToken)
    }

    @Test("Exact marker readback retries an ambiguous first save without replacing it", arguments: [RetentionPersistenceFault.afterWrite, .readback])
    func ambiguousMarkerSave(fault: RetentionPersistenceFault) async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        let native = try fixture.seedNative(before, store: store)
        fixture.keychain.fail(fault, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        #expect(await store.hasPendingCredentialPersistence())
        let marker = try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store))
        try await store.flushPendingCredentialPersistence()
        #expect(!(await store.hasPendingCredentialPersistence()))
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == marker)
        #expect(fixture.keychain.writeCount(service: AuthTransaction.service, account: fixture.rotationKey(store)) == 1)
        #expect(fixture.keychain.writeCount(service: store.keychainService, account: store.keychainAccount) == 0)
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
        #expect(await exchange.calls == 1)
    }

    @Test("Flush can durably capture a retained response after an external native rotation without overwriting it")
    func activeExternalGeneration() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("retained-successor"), external = try fixture.credential("external-successor")
        try fixture.seedNative(before, store: store)
        fixture.keychain.fail(.beforeWrite, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        let native = try fixture.seedNative(external, store: store), config = try fixture.files.read(store.configURL)
        try await store.flushPendingCredentialPersistence()
        #expect(!(await store.hasPendingCredentialPersistence()))
        let marker = try #require(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)))
        let markerObject = try authObject(marker, name: "Fixture marker")
        let savedCredential = try #require(markerObject["credential"] as? [String: Any])
        #expect(savedCredential["refreshToken"] as? String == successor.refreshToken)
        #expect(fixture.keychain.writeCount(service: store.keychainService, account: store.keychainAccount) == 0)
        await #expect(throws: AgentSwapError.self) { try await store.recoverInterruptedSwitch() }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
        #expect(try fixture.files.read(store.configURL) == config)
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == marker)
        #expect(await exchange.calls == 1)
    }

    @Test("Inactive first-vault-save failures return the retained successor on retry", arguments: [RetentionPersistenceFault.beforeWrite, .afterWrite, .readback])
    func inactiveFirstSave(fault: RetentionPersistenceFault) async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor"), other = try fixture.credential("other", user: "fixture-other-user")
        let native = try fixture.seedNative(other, store: store)
        fixture.keychain.seed(try JSONEncoder().encode(before), service: KeychainSecretStore.service, account: id.uuidString)
        fixture.keychain.fail(fault, service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        #expect(await store.hasPendingCredentialPersistence())
        let retried = try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) }
        #expect(retried == successor)
        #expect(!(await store.hasPendingCredentialPersistence()))
        #expect(try fixture.vault(id) == successor)
        #expect(await exchange.calls == 1)
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
        #expect(fixture.keychain.writeCount(service: store.keychainService, account: store.keychainAccount) == 0)
        let receipts = await store.takePersistedCredentialGenerations()
        let receipt = try #require(receipts.first)
        #expect(receipts.count == 1 && receipt.accountID == id)
        #expect(receipt.predecessorDigest == fixture.digest(before.rawAuth))
        #expect(receipt.successorDigest == fixture.digest(successor.rawAuth))
    }

    @Test("Consuming the saved-generation receipt does not permit replaying the inactive predecessor")
    func receiptConsumptionDoesNotReplay() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor"), other = try fixture.credential("other", user: "fixture-other-user")
        try fixture.seedNative(other, store: store)
        fixture.keychain.fail(.beforeWrite, service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        try await store.flushPendingCredentialPersistence()
        #expect(await store.takePersistedCredentialGenerations().count == 1)
        #expect(await store.takePersistedCredentialGenerations().isEmpty)
        let result = try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) }
        #expect(result == successor)
        #expect(await exchange.calls == 1)
    }

    @Test("A distinct native generation replaces the retry cache without exchanging an obsolete grant")
    func inactiveNativeGenerationChanges() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor"), other = try fixture.credential("other", user: "fixture-other-user"), external = try fixture.credential("external-successor")
        try fixture.seedNative(other, store: store)
        fixture.keychain.fail(.beforeWrite, service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        try await store.flushPendingCredentialPersistence()
        let native = try fixture.seedNative(external, store: store)
        let result = try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) }
        #expect(result == external)
        #expect(await exchange.calls == 1)
        #expect(try fixture.vault(id) == external)
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
        #expect(await store.takePersistedCredentialGenerations().isEmpty)
    }

    @Test("Discarding an undurable successor or its receipt never deletes a durable rotation marker")
    func explicitDiscardScope() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        try fixture.seedNative(before, store: store)
        fixture.keychain.fail(.beforeWrite, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) } }
        try await store.flushPendingCredentialPersistence()
        let marker = try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store))
        await store.discardPendingCredentialPersistence(accountID: id)
        #expect(!(await store.hasPendingCredentialPersistence()))
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == marker)
        #expect(!(await store.compatibility()).canWrite)
    }

    @Test("An unrelated recovery marker is never overwritten by an undurable successor")
    func conflictingMarker() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        let native = try fixture.seedNative(before, store: store)
        fixture.keychain.fail(.beforeWrite, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in successor } }
        let otherMarker = Data("unknown-marker-fixture".utf8)
        fixture.keychain.seed(otherMarker, service: AuthTransaction.service, account: fixture.rotationKey(store))
        await #expect(throws: AgentSwapError.self) { try await store.flushPendingCredentialPersistence() }
        #expect(await store.hasPendingCredentialPersistence())
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: fixture.rotationKey(store)) == otherMarker)
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == native)
    }

    @Test("An already canceled task never exchanges a grant")
    func canceledBeforeExchange() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        try fixture.seedNative(before, store: store)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.refresh(before, accountID: id) { _ in await exchange.grant(successor) }
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await exchange.calls == 0)
        #expect(!(await store.hasPendingCredentialPersistence()))
    }

    @Test("Cancellation after receiving a successor cannot discard a failed first save")
    func canceledAfterResponse() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor")
        try fixture.seedNative(before, store: store)
        fixture.keychain.fail(.beforeWrite, service: AuthTransaction.service, account: fixture.rotationKey(store))
        let canceled = Task {
            try await store.refresh(before, accountID: id) { _ in
                let result = await exchange.grant(successor)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
        }
        await #expect(throws: AgentSwapError.self) { try await canceled.value }
        #expect(await store.hasPendingCredentialPersistence())
        try await store.flushPendingCredentialPersistence()
        #expect(!(await store.hasPendingCredentialPersistence()))
        try await store.recoverInterruptedSwitch()
        #expect(try fixture.vault(id) == successor)
        #expect(await exchange.calls == 1)
    }

    @Test("A second account cannot consume another grant while the first response remains undurable")
    func anotherAccountWaitsForDurableSave() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), firstID = UUID(), secondID = UUID(), exchange = RetentionExchange()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor"), other = try fixture.credential("other", user: "fixture-other-user")
        try fixture.seedNative(other, store: store)
        fixture.keychain.fail(.beforeWrite, service: KeychainSecretStore.service, account: firstID.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: firstID) { _ in await exchange.grant(successor) } }
        fixture.keychain.fail(.beforeWrite, service: KeychainSecretStore.service, account: firstID.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(other, accountID: secondID) { _ in await exchange.grant(other) } }
        #expect(await exchange.calls == 1)
        #expect(await store.hasPendingCredentialPersistence())
        try await store.flushPendingCredentialPersistence()
        #expect(try fixture.vault(firstID) == successor)
    }

    @Test("A durable fresh login may discard an undurable response without resurrecting it")
    func discardAfterFreshLogin() async throws {
        let fixture = try RetentionFixture(); defer { fixture.cleanup() }
        let store = fixture.store(), id = UUID()
        let before = try fixture.credential("before"), successor = try fixture.credential("successor"), fresh = try fixture.credential("fresh-login"), other = try fixture.credential("other", user: "fixture-other-user")
        try fixture.seedNative(other, store: store)
        fixture.keychain.fail(.beforeWrite, service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(before, accountID: id) { _ in successor } }
        try fixture.keychain.write(JSONEncoder().encode(fresh), service: KeychainSecretStore.service, account: id.uuidString)
        await store.discardPendingCredentialPersistence(accountID: id)
        try await store.flushPendingCredentialPersistence()
        #expect(!(await store.hasPendingCredentialPersistence()))
        #expect(try fixture.vault(id) == fresh)
        #expect(await store.takePersistedCredentialGenerations().isEmpty)
    }
}
