import Foundation
import Testing
@testable import AgentSwapCore

// This fixture owns every secret and file; it never accesses a real Keychain or provider.
private final class StaleIdentityKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) { lock.withLock { values[service + "|" + account] = data } }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account) } }
}

private actor StaleIdentityTransport: ProviderHTTPTransport {
    let actualIdentity: AccountIdentity
    var paths: [String] = []
    private var profileFailure: ProviderHTTPResponse?
    private var rejectSuccessorProfiles = false
    init(actualIdentity: AccountIdentity) { self.actualIdentity = actualIdentity }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/oauth/profile":
            if let profileFailure { return profileFailure }
            if rejectSuccessorProfiles, request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-native-successor" {
                return .init(data: Data("{}".utf8), statusCode: 503)
            }
            let identity = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cached-successor"
                ? StaleIdentityFixture.cachedIdentity : actualIdentity
            return .init(data: try ProviderJSON.data([
                "account": ["uuid": identity.userID],
                "organization": ["uuid": identity.workspaceID]
            ]), statusCode: 200)
        case "/v1/oauth/token":
            return .init(data: try ProviderJSON.data([
                "access_token": "fixture-native-successor", "refresh_token": "fixture-native-successor-refresh", "expires_in": 3600
            ]), statusCode: 200)
        case "/api/oauth/usage":
            return .init(data: try ProviderJSON.data(["five_hour": ["utilization": 20]]), statusCode: 200)
        default:
            throw AgentSwapError.network("Unexpected fixture request")
        }
    }
    func failProfile(status: Int, data: Data = Data("{}".utf8)) { profileFailure = .init(data: data, statusCode: status) }
    func failSuccessorProfiles() { rejectSuccessorProfiles = true }
}

private struct StaleIdentityLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

private struct StaleIdentityFixture {
    static let cachedIdentity = AccountIdentity(provider: .claude, userID: "fixture-cached-user", workspaceID: "fixture-cached-workspace")
    static let actualIdentity = AccountIdentity(provider: .claude, userID: "fixture-actual-user", workspaceID: "fixture-actual-workspace")
    let home: URL
    let keychain = StaleIdentityKeychain()
    let store: ClaudeAuthStore
    let native: Credential
    let cachedBackup: Credential
    let configData: Data
    let transport = StaleIdentityTransport(actualIdentity: actualIdentity)
    var adapter: ClaudeProviderAdapter { .init(authStore: store, transport: transport, loginRunner: StaleIdentityLogin()) }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapStaleIdentityFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = ClaudeAuthStore(home: home, keychain: keychain)
        // Older native grants can lack organizationUuid; their complete oauthAccount cache
        // can therefore appear well formed even after the token owner changes.
        native = try Self.credential(token: "fixture-native", identity: Self.actualIdentity, expired: true)
        cachedBackup = try Self.credential(token: "fixture-cached-successor", identity: Self.cachedIdentity, expired: false)
        configData = try ProviderJSON.data(["oauthAccount": ["accountUuid": Self.cachedIdentity.userID,
            "organizationUuid": Self.cachedIdentity.workspaceID], "fixtureSharedSetting": true])
        try keychain.write(native.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try AtomicAuthFileAccess().write(configData, to: store.configURL)
    }
    static func credential(token: String, identity: AccountIdentity, expired: Bool) throws -> Credential {
        try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
            "accessToken": token, "refreshToken": token + "-refresh",
            "expiresAt": Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000
        ]]), accountMetadata: ProviderJSON.data(["accountUuid": identity.userID, "organizationUuid": identity.workspaceID]))
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Claude stale complete identity cache")
struct ClaudeStaleIdentityCacheTests {
    @Test("A complete cached identity cannot label another account's native grant")
    func nativeImportAuthenticatesIdentity() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let imported = try await fixture.adapter.importCurrent()
        #expect(imported.account.identity == StaleIdentityFixture.actualIdentity)
        #expect(await fixture.transport.paths == ["/api/oauth/profile"])
        #expect(try Data(contentsOf: fixture.store.configURL) == fixture.configData)
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
    }

    @Test("Profile failures never fall back to a complete native identity cache", arguments: [200, 401, 403, 429, 503])
    func failedProfileDoesNotTrustCache(_ status: Int) async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        await fixture.transport.failProfile(status: status)
        let adapter = fixture.adapter
        do {
            _ = try await adapter.importCurrent()
            Issue.record("A rejected profile must not identify a native account")
        } catch let error as AgentSwapError {
            if case .nativeIdentityUnverified = error { #expect(status == 401) }
            else { #expect(status != 401) }
        }
        await #expect(throws: AgentSwapError.self) { try await adapter.importCurrent() }
        #expect(await fixture.transport.paths == Array(repeating: "/api/oauth/profile", count: status == 401 ? 1 : 2))
        #expect(try Data(contentsOf: fixture.store.configURL) == fixture.configData)
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
    }

    @Test("A persisted verified grant can identify an expired native token after restart without trusting its stale cache")
    func persistedProofSurvivesAdapterRestart() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let firstAdapter = fixture.adapter
        let imported = try await firstAdapter.importCurrent()
        let restarted = fixture.adapter
        await restarted.registerStoredCredential(imported.credential, account: imported.account)
        await fixture.transport.failProfile(status: 401)
        let current = try await restarted.importCurrent()
        #expect(current.account.identity == StaleIdentityFixture.actualIdentity)
        #expect(current.credential.verifiedClaudeAccountIdentity == StaleIdentityFixture.actualIdentity)
        #expect(await fixture.transport.paths == ["/api/oauth/profile"])
    }

    @Test("Unverified legacy metadata cannot seed a native identity proof")
    func legacyCredentialDoesNotCreateProof() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        let account = AccountRecord(identity: StaleIdentityFixture.actualIdentity)
        await adapter.registerStoredCredential(fixture.native, account: account)
        await fixture.transport.failProfile(status: 401)
        do {
            _ = try await adapter.importCurrent()
            Issue.record("An expired legacy grant must remain unverified")
        } catch let error as AgentSwapError {
            guard case .nativeIdentityUnverified = error else { Issue.record("Identity verification failure is not evidence of logout"); return }
        }
        #expect(await fixture.transport.paths == ["/api/oauth/profile"])
    }

    @Test("An expired legacy backup without an authenticated binding never consumes OAuth")
    func unknownExpiredBackupCannotRefresh() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        await fixture.transport.failProfile(status: 401)
        let adapter = fixture.adapter
        let account = AccountRecord(identity: StaleIdentityFixture.actualIdentity)
        do {
            _ = try await adapter.refresh(fixture.native, account: account)
            Issue.record("Unknown expired ownership must block refresh")
        } catch let error as AgentSwapError {
            guard case .storage = error else { Issue.record("Unverified ownership is not evidence of logout"); return }
        }
        #expect(await fixture.transport.paths == ["/api/oauth/profile"])
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
        #expect(try Data(contentsOf: fixture.store.configURL) == fixture.configData)
    }

    @Test("Mismatched saved metadata blocks usage and refresh before making any request")
    func savedIdentityCannotTargetDifferentAccount() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        let wrongAccount = AccountRecord(identity: StaleIdentityFixture.cachedIdentity)
        await #expect(throws: AgentSwapError.self) { try await adapter.fetchUsage(fixture.native, account: wrongAccount) }
        await #expect(throws: AgentSwapError.self) { try await adapter.refresh(fixture.native, account: wrongAccount) }
        #expect(await fixture.transport.paths.isEmpty)
    }

    @Test("A contaminated token cannot publish another user's usage under the saved metadata")
    func remoteProfileMustMatchSavedAccount() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        var contaminated = fixture.native
        contaminated.accountMetadata = fixture.cachedBackup.accountMetadata
        let wrongAccount = AccountRecord(identity: StaleIdentityFixture.cachedIdentity)
        await #expect(throws: AgentSwapError.self) { try await adapter.fetchUsage(contaminated, account: wrongAccount) }
        await #expect(throws: AgentSwapError.self) { try await adapter.refresh(contaminated, account: wrongAccount) }
        let activation = await adapter.activate(contaminated, account: wrongAccount, relaunch: false)
        guard case .failed = activation else { Issue.record("A contaminated target must not be applied"); return }
        #expect(await fixture.transport.paths == ["/api/oauth/profile"])
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.native.rawAuth)
        #expect(try Data(contentsOf: fixture.store.configURL) == fixture.configData)
    }

    @Test("A verified OAuth successor retains its owner without another profile request")
    @MainActor func successorSurvivesProfileFailure() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let account = AccountRecord(identity: StaleIdentityFixture.actualIdentity)
        let vault = KeychainSecretStore(keychain: fixture.keychain)
        try await vault.save(fixture.native, accountID: account.id)
        var state = PersistedState()
        state.accounts = [account]
        state.activeAccounts[.claude] = account.id
        let model = AppModel(adapters: [fixture.adapter], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        await fixture.transport.failSuccessorProfiles()
        await model.refreshDue(force: true)
        let successor = try #require(try await vault.load(accountID: account.id))
        #expect(successor.accessToken == "fixture-native-successor")
        #expect(successor.verifiedClaudeAccountIdentity == account.identity)
        #expect(model.state.usage[account.id]?.error == nil)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        await model.refreshDue(force: true, now: Date().addingTimeInterval(61))
        #expect(try await vault.load(accountID: account.id)?.accessToken == successor.accessToken)
        #expect(await fixture.transport.paths.filter { $0 == "/v1/oauth/token" }.count == 1)
        #expect(await fixture.transport.paths.filter { $0 == "/api/oauth/profile" }.count == 1)
        #expect(await fixture.transport.paths.filter { $0 == "/api/oauth/usage" }.count == 2)
    }

    @Test("A stale native cache neither conflicts with a different saved successor nor strands the real owner at expiry")
    @MainActor func nativeCacheDoesNotStrandTwoAccounts() async throws {
        let fixture = try StaleIdentityFixture()
        defer { fixture.cleanup() }
        let cached = AccountRecord(identity: StaleIdentityFixture.cachedIdentity)
        let actual = AccountRecord(identity: StaleIdentityFixture.actualIdentity)
        let vault = MemorySecrets()
        await vault.save(fixture.cachedBackup, accountID: cached.id)
        await vault.save(fixture.native, accountID: actual.id)
        var state = PersistedState()
        state.accounts = [cached, actual]
        state.activeAccounts[.claude] = cached.id
        state.pendingNativeRefreshPredecessor = [cached.id: String(repeating: "0", count: 64)]
        let model = AppModel(adapters: [fixture.adapter], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        await model.refreshDue(force: true)
        #expect(model.state.activeAccounts[.claude] == actual.id)
        #expect(model.state.usage[cached.id]?.error == nil)
        #expect(model.state.usage[cached.id]?.snapshot != nil)
        #expect(model.state.usage[actual.id]?.error == nil)
        #expect(model.state.usage[actual.id]?.snapshot != nil)
        #expect(model.state.accounts.allSatisfy { $0.authenticationState == .valid })
        let preservedBackup = try #require(await vault.load(accountID: cached.id))
        #expect(preservedBackup.rawAuth == fixture.cachedBackup.rawAuth)
        #expect(preservedBackup.accessToken == fixture.cachedBackup.accessToken)
        #expect(preservedBackup.verifiedClaudeAccountIdentity == cached.identity)
    }
}
