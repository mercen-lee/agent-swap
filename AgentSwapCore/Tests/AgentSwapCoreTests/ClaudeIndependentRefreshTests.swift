import Foundation
import Testing
@testable import AgentSwapCore

private final class IndependentKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes = 0
    private var failVault = false
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            if failVault, service == KeychainSecretStore.service { failVault = false; throw AgentSwapError.storage("Fixture vault write failed") }
            values[service + "|" + account] = data; writes += 1
        }
    }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account); writes += 1 } }
    func mutationCount() -> Int { lock.withLock { writes } }
    func failNextVaultWrite() { lock.withLock { failVault = true } }
}
private actor IndependentProbe {
    var calls = 0
    func rotate(_ successor: Credential) -> Credential { calls += 1; return successor }
}
private struct IndependentFixture {
    static let targetIdentity = AccountIdentity(provider: .claude, userID: "fixture-independent-user", workspaceID: "fixture-independent-workspace")
    static let nativeIdentity = AccountIdentity(provider: .claude, userID: "fixture-native-user", workspaceID: "fixture-native-workspace")
    let home: URL
    let keychain = IndependentKeychain()
    let store: ClaudeAuthStore
    let target: Credential
    let native: Credential
    let successor: Credential
    let accountID = UUID()
    let config: Data
    var vault: KeychainSecretStore { .init(keychain: keychain) }
    var nativeProof: ImportedAccount { get throws { try ProviderAccountParser.claude(native) } }
    init(sameOwner: Bool = false) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapIndependentRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = ClaudeAuthStore(home: home, keychain: keychain)
        target = try Self.credential("fixture-independent-old", identity: Self.targetIdentity, expired: true)
        successor = try Self.credential("fixture-independent-new", identity: Self.targetIdentity, expired: false)
        native = sameOwner ? target : try Self.credential("fixture-native-current", identity: Self.nativeIdentity, expired: false)
        let owner = sameOwner ? Self.targetIdentity : Self.nativeIdentity
        config = try ProviderJSON.data(["oauthAccount": ["accountUuid": owner.userID, "organizationUuid": owner.workspaceID], "fixtureSharedSetting": true])
        try keychain.write(native.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try AtomicAuthFileAccess().write(native.rawAuth, to: home.appendingPathComponent(".claude/.credentials.json"))
        try AtomicAuthFileAccess().write(config, to: store.configURL)
    }
    static func credential(_ token: String, identity: AccountIdentity, expired: Bool) throws -> Credential {
        let value = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
            "accessToken": token, "refreshToken": token + "-refresh", "expiresAt": Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000
        ], "organizationUuid": identity.workspaceID]), accountMetadata: ProviderJSON.data(["accountUuid": identity.userID, "organizationUuid": identity.workspaceID]))
        return try value.withVerifiedClaudeIdentity(identity)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func assertNativeUnchanged() throws {
        #expect(keychain.read(service: store.keychainService, account: store.keychainAccount) == native.rawAuth)
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) == native.rawAuth)
        #expect(try Data(contentsOf: store.configURL) == config)
    }
}
private actor IndependentTransport: ProviderHTTPTransport {
    let keychain: IndependentKeychain
    let accountID: UUID
    var paths: [String] = []
    init(keychain: IndependentKeychain, accountID: UUID) { self.keychain = keychain; self.accountID = accountID }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        let path = request.url?.path ?? ""; paths.append(path)
        switch path {
        case "/api/oauth/profile":
            let isTarget = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-independent-new"
            if isTarget {
                let saved = try keychain.read(service: KeychainSecretStore.service, account: accountID.uuidString).map { try JSONDecoder().decode(Credential.self, from: $0) }
                guard saved?.accessToken == "fixture-independent-new" else { throw AgentSwapError.storage("Profile requested before durable successor") }
            }
            let identity = isTarget ? IndependentFixture.targetIdentity : IndependentFixture.nativeIdentity
            return .init(data: try ProviderJSON.data(["account": ["uuid": identity.userID], "organization": ["uuid": identity.workspaceID]]), statusCode: 200)
        case "/v1/oauth/token": return .init(data: try ProviderJSON.data(["access_token": "fixture-independent-new", "refresh_token": "fixture-independent-new-refresh", "expires_in": 3600]), statusCode: 200)
        case "/api/oauth/usage":
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-independent-new" else { throw AgentSwapError.network("Wrong fixture usage token") }
            return .init(data: try ProviderJSON.data(["five_hour": ["utilization": 23]]), statusCode: 200)
        default: throw AgentSwapError.network("Unexpected fixture request")
        }
    }
}
private struct IndependentLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

@Suite("Independent reauthenticated Claude renewal")
struct ClaudeIndependentRefreshTests {
    @Test("A positively different native owner permits vault-only renewal and durable-successor recovery")
    func differentOwnerRenewsWithoutNativeMutation() async throws {
        let fixture = try IndependentFixture(); defer { fixture.cleanup() }
        try await fixture.vault.save(fixture.target, accountID: fixture.accountID)
        fixture.keychain.failNextVaultWrite()
        let probe = IndependentProbe()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.target, accountID: fixture.accountID, verifiedNative: fixture.nativeProof,
                requiresVerifiedNative: true, requiresInactive: true) { _ in await probe.rotate(fixture.successor) }
        }
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == fixture.target)
        #expect(await fixture.store.hasPendingCredentialPersistence())
        try fixture.assertNativeUnchanged()
        try await fixture.store.flushPendingCredentialPersistence()
        let recovered = try await fixture.store.refresh(fixture.target, accountID: fixture.accountID, verifiedNative: fixture.nativeProof,
            requiresVerifiedNative: true, requiresInactive: true) { _ in await probe.rotate(fixture.successor) }
        #expect(recovered == fixture.successor)
        #expect(await probe.calls == 1)
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == fixture.successor)
        try fixture.assertNativeUnchanged()
    }

    @Test("The same native owner is rejected before OAuth or any credential mutation")
    func sameOwnerNeverRotates() async throws {
        let fixture = try IndependentFixture(sameOwner: true); defer { fixture.cleanup() }
        let probe = IndependentProbe(), before = fixture.keychain.mutationCount()
        await #expect(throws: IndependentCredentialRefreshBlocked.self) {
            try await fixture.store.refresh(fixture.target, accountID: fixture.accountID, verifiedNative: fixture.nativeProof,
                requiresVerifiedNative: true, requiresInactive: true) { _ in await probe.rotate(fixture.successor) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNativeUnchanged()
    }

    @Test("An other-to-same native race cannot cross the locked generation fence")
    func nativeOwnerRaceCannotRotateOrWrite() async throws {
        let fixture = try IndependentFixture(); defer { fixture.cleanup() }
        let proof = try fixture.nativeProof, probe = IndependentProbe()
        try fixture.keychain.write(fixture.target.rawAuth, service: fixture.store.keychainService, account: fixture.store.keychainAccount)
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.target, accountID: fixture.accountID, verifiedNative: proof,
                requiresVerifiedNative: true, requiresInactive: true) { _ in await probe.rotate(fixture.successor) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.target.rawAuth)
    }

    @Test("A missing native proof never permits independent OAuth")
    func missingProofBlocksRenewal() async throws {
        let fixture = try IndependentFixture(); defer { fixture.cleanup() }
        let probe = IndependentProbe(), before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.target, accountID: fixture.accountID,
                requiresVerifiedNative: true, requiresInactive: true) { _ in await probe.rotate(fixture.successor) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNativeUnchanged()
    }

    @Test("Flagged account polls retain independent renewal across save failure and restart without replaying OAuth", arguments: [false, true])
    @MainActor func engineRenewsIndependentAccount(_ failFirstSave: Bool) async throws {
        let fixture = try IndependentFixture(); defer { fixture.cleanup() }
        try await fixture.vault.save(fixture.target, accountID: fixture.accountID)
        let transport = IndependentTransport(keychain: fixture.keychain, accountID: fixture.accountID)
        let adapter = ClaudeProviderAdapter(authStore: fixture.store, transport: transport, loginRunner: IndependentLogin())
        var state = PersistedState()
        let account = AccountRecord(id: fixture.accountID, identity: IndependentFixture.targetIdentity)
        state.accounts = [account]
        state.requiresExplicitCredentialApplication = [account.id]
        state.usage[account.id] = .init(attemptedAt: Date())
        let persisted = MemoryState(state)
        let model = AppModel(adapters: [adapter], secrets: fixture.vault, store: persisted)
        await model.start(); model.stop()
        if failFirstSave { fixture.keychain.failNextVaultWrite() }
        await model.refreshAll()
        if failFirstSave {
            #expect(model.state.usage[account.id]?.error != nil)
            #expect(!(await transport.paths).contains("/api/oauth/usage"))
            #expect(await fixture.store.hasPendingCredentialPersistence())
            #expect(try await fixture.vault.load(accountID: account.id) == fixture.target)
            try fixture.assertNativeUnchanged()
            await model.refreshDue(force: true, now: Date().addingTimeInterval(61))
        }
        #expect(model.state.usage[account.id]?.error == nil)
        #expect(model.state.requiresExplicitCredentialApplication == [account.id])
        #expect(try await fixture.vault.load(accountID: account.id)?.verifiedClaudeAccountIdentity == account.identity)
        #expect(await transport.paths.filter { $0 == "/v1/oauth/token" }.count == 1)
        try fixture.assertNativeUnchanged()
        let restarted = AppModel(adapters: [adapter], secrets: fixture.vault, store: persisted)
        await restarted.start(); restarted.stop()
        await restarted.refreshAll()
        #expect(restarted.state.requiresExplicitCredentialApplication == [account.id])
        #expect(try await fixture.vault.load(accountID: account.id)?.accessToken == "fixture-independent-new")
        #expect(await transport.paths.filter { $0 == "/v1/oauth/token" }.count == 1)
        try fixture.assertNativeUnchanged()
    }
}
