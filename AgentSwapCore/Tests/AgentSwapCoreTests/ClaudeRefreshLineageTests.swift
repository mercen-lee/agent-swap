import Foundation
import Testing
@testable import AgentSwapCore

// Every item is synthetic and local to one fixture, including captured write attempts.
private final class RefreshLineageKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var attemptedCredentials: [Credential] = []
    private var failVaultWrite = false
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            if service == KeychainSecretStore.service {
                attemptedCredentials.append(try JSONDecoder().decode(Credential.self, from: data))
                if failVaultWrite { failVaultWrite = false; throw AgentSwapError.storage("Fixture first vault write failure") }
            } else if service == AuthTransaction.service,
                      let object = try? ProviderJSON.object(data), let credential = object["credential"] as? [String: Any] {
                attemptedCredentials.append(try JSONDecoder().decode(Credential.self, from: ProviderJSON.data(credential)))
            }
            values[service + "|" + account] = data
        }
    }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account) } }
    func clearAttempts(failNextVaultWrite: Bool = false) {
        lock.withLock { attemptedCredentials = []; failVaultWrite = failNextVaultWrite }
    }
    func attempts() -> [Credential] { lock.withLock { attemptedCredentials } }
}

private actor RefreshLineageTransport: ProviderHTTPTransport {
    let keychain: RefreshLineageKeychain
    let accountID: UUID
    let identity: AccountIdentity
    private(set) var paths: [String] = []
    private(set) var refreshes = 0
    init(keychain: RefreshLineageKeychain, accountID: UUID, identity: AccountIdentity) {
        self.keychain = keychain; self.accountID = accountID; self.identity = identity
    }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/oauth/profile":
            return .init(data: Data("{}".utf8), statusCode: 401)
        case "/v1/oauth/token":
            refreshes += 1
            return .init(data: try ProviderJSON.data([
                "access_token": "fixture-lineage-successor-\(refreshes)",
                "refresh_token": "fixture-lineage-refresh-\(refreshes)", "expires_in": 0.000_001
            ]), statusCode: 200)
        case "/api/oauth/usage":
            let saved = try keychain.read(service: KeychainSecretStore.service, account: accountID.uuidString)
                .map { try JSONDecoder().decode(Credential.self, from: $0) }
            #expect(saved?.verifiedClaudeAccountIdentity == identity)
            return .init(data: Data("{}".utf8), statusCode: 429, headers: ["retry-after": "3600"])
        default: throw AgentSwapError.network("Unexpected fixture request")
        }
    }
}

private struct RefreshLineageLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

private struct RefreshLineageFixture {
    let home: URL
    let keychain = RefreshLineageKeychain()
    let account = AccountRecord(identity: .init(provider: .claude, userID: "fixture-lineage-user", workspaceID: "fixture-lineage-workspace"))
    let nativeAccount = AccountRecord(identity: .init(provider: .claude, userID: "fixture-native-user", workspaceID: "fixture-native-workspace"))
    let target: Credential
    let native: Credential
    let store: ClaudeAuthStore
    let active: Bool
    var vault: KeychainSecretStore { .init(keychain: keychain) }
    init(active: Bool) throws {
        self.active = active
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapRefreshLineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = ClaudeAuthStore(home: home, keychain: keychain)
        target = try Self.credential("fixture-lineage-original", identity: account.identity)
        native = active ? target : try Self.credential("fixture-native-original", identity: nativeAccount.identity)
        try keychain.write(native.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let identity = active ? account.identity : nativeAccount.identity
        try AtomicAuthFileAccess().write(ProviderJSON.data(["oauthAccount": [
            "accountUuid": identity.userID, "organizationUuid": identity.workspaceID
        ]]), to: store.configURL)
    }
    static func credential(_ token: String, identity: AccountIdentity) throws -> Credential {
        try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
            "accessToken": token, "refreshToken": token + "-refresh", "expiresAt": 1
        ], "organizationUuid": identity.workspaceID]), accountMetadata: ProviderJSON.data([
            "accountUuid": identity.userID, "organizationUuid": identity.workspaceID
        ])).withVerifiedClaudeIdentity(identity)
    }
    func adapter(_ transport: RefreshLineageTransport, store: ClaudeAuthStore? = nil) async -> ClaudeProviderAdapter {
        let adapter = ClaudeProviderAdapter(authStore: store ?? self.store, transport: transport, loginRunner: RefreshLineageLogin())
        if !active { await adapter.registerStoredCredential(native, account: nativeAccount) }
        return adapter
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Claude verified OAuth refresh lineage")
struct ClaudeRefreshLineageTests {
    @Test("The first durable successor keeps owner proof through usage 429, restart and expiry", arguments: [false, true])
    func successorProofSurvivesRestart(_ active: Bool) async throws {
        let fixture = try RefreshLineageFixture(active: active); defer { fixture.cleanup() }
        try await fixture.vault.save(fixture.target, accountID: fixture.account.id)
        fixture.keychain.clearAttempts()
        let transport = RefreshLineageTransport(keychain: fixture.keychain, accountID: fixture.account.id, identity: fixture.account.identity)
        let adapter = await fixture.adapter(transport)
        let successor = try await adapter.refresh(fixture.target, account: fixture.account)
        let firstAttempt = try #require(fixture.keychain.attempts().first)
        #expect(firstAttempt.accessToken == successor.accessToken)
        #expect(firstAttempt.verifiedClaudeAccountIdentity == fixture.account.identity)
        #expect(fixture.keychain.attempts().allSatisfy { $0.verifiedClaudeAccountIdentity == fixture.account.identity })
        #expect(try await fixture.vault.load(accountID: fixture.account.id) == successor)
        await #expect(throws: AgentSwapError.self) { try await adapter.fetchUsage(successor, account: fixture.account) }
        #expect(successor.expiresAt.map { $0 <= Date() } == true)

        let restartedStore = ClaudeAuthStore(home: fixture.home, keychain: fixture.keychain)
        let restarted = await fixture.adapter(transport, store: restartedStore)
        let saved = try #require(try await fixture.vault.load(accountID: fixture.account.id))
        let renewed = try await restarted.refresh(saved, account: fixture.account)
        #expect(renewed.accessToken == "fixture-lineage-successor-2")
        #expect(renewed.verifiedClaudeAccountIdentity == fixture.account.identity)
        #expect(await transport.refreshes == 2)
        #expect(!(await transport.paths).contains("/api/oauth/profile"))
        if !active {
            #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
        }
    }

    @Test("A failed first vault save retries the bound successor without another OAuth exchange")
    func firstSaveFailureRetainsProof() async throws {
        let fixture = try RefreshLineageFixture(active: false); defer { fixture.cleanup() }
        try await fixture.vault.save(fixture.target, accountID: fixture.account.id)
        fixture.keychain.clearAttempts(failNextVaultWrite: true)
        let transport = RefreshLineageTransport(keychain: fixture.keychain, accountID: fixture.account.id, identity: fixture.account.identity)
        let adapter = await fixture.adapter(transport)
        await #expect(throws: AgentSwapError.self) { try await adapter.refreshIndependentCredential(fixture.target, account: fixture.account) }
        #expect(await adapter.hasPendingCredentialPersistence())
        #expect(try #require(fixture.keychain.attempts().first).verifiedClaudeAccountIdentity == fixture.account.identity)
        try await adapter.flushPendingCredentialPersistence()
        let saved = try #require(try await fixture.vault.load(accountID: fixture.account.id))
        #expect(saved.verifiedClaudeAccountIdentity == fixture.account.identity)
        let retried = try await adapter.refreshIndependentCredential(fixture.target, account: fixture.account)
        #expect(retried == saved)
        #expect(await transport.refreshes == 1)
        #expect(!(await transport.paths).contains("/api/oauth/profile"))
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
    }

    @Test("Missing or wrong owner proof never reaches OAuth", arguments: ["unverified", "wrong-owner"])
    func unverifiedPredecessorCannotCreateProof(_ mode: String) async throws {
        let fixture = try RefreshLineageFixture(active: false); defer { fixture.cleanup() }
        let transport = RefreshLineageTransport(keychain: fixture.keychain, accountID: fixture.account.id, identity: fixture.account.identity)
        let adapter = await fixture.adapter(transport)
        var input = fixture.target
        if mode == "unverified" { input.claudeIdentityBinding = nil }
        let account = mode == "wrong-owner" ? fixture.nativeAccount : fixture.account
        await #expect(throws: AgentSwapError.self) { try await adapter.refreshIndependentCredential(input, account: account) }
        #expect(await transport.refreshes == 0)
        #expect(fixture.keychain.attempts().isEmpty)
    }
}
