import Foundation
import Testing
@testable import AgentSwapCore

private struct BindingNativeKeychain: KeychainAccess {
    func read(service: String, account: String) -> Data? { nil }
    func write(_ data: Data, service: String, account: String) throws { throw AgentSwapError.storage("Unexpected fixture native write") }
    func delete(service: String, account: String) throws { throw AgentSwapError.storage("Unexpected fixture native delete") }
}
// Only fixture-owned data is accessed, under this lock; no system Keychain is used.
private final class BindingSwitchKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes = 0
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) {
        lock.withLock { values[service + account] = data; writes += 1 }
    }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + account) } }
    func writeCount() -> Int { lock.withLock { writes } }
}
private struct BindingLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}
private actor BindingTransport: ProviderHTTPTransport {
    let profile: Data
    var targetProfile: Data?
    var requests: [URLRequest] = []
    init(_ profile: Data) { self.profile = profile }
    func send(_ request: URLRequest) -> ProviderHTTPResponse {
        requests.append(request)
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-target-access", let targetProfile {
            return .init(data: targetProfile, statusCode: 200)
        }
        return .init(data: profile, statusCode: 200)
    }
    func setTargetProfile(_ data: Data) { targetProfile = data }
}
private actor BindingVault: SecretStore {
    var saves = 0
    func load(accountID: UUID) -> Credential? { nil }
    func save(_ credential: Credential, accountID: UUID) { saves += 1 }
    func delete(accountID: UUID) {}
}
private actor BindingBackup {
    var source: ImportedAccount?
    func save(_ source: ImportedAccount) { self.source = source }
}
private actor BindingState: StateStore {
    var state = PersistedState()
    func load() -> PersistedState { state }
    func save(_ state: PersistedState) { self.state = state }
}
private struct BindingFixture {
    static let user = "00000000-0000-4000-8000-000000000041"
    static let organization = "00000000-0000-4000-8000-000000000042"
    static let otherOrganization = "00000000-0000-4000-8000-000000000043"
    let home: URL
    let rawAuth: Data
    let configData: Data
    let store: ClaudeAuthStore
    init(cachedOrganization: String?, includeCache: Bool = true, cachedUser: String? = BindingFixture.user,
         keychain: any KeychainAccess = BindingNativeKeychain()) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapClaudeBindingTests-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        rawAuth = try ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-source-access", "refreshToken": "fixture-source-refresh"], "organizationUuid": Self.organization])
        var config: [String: Any] = ["fixtureSharedSetting": true]
        if includeCache {
            var account: [String: Any] = [:]
            if let cachedUser { account["accountUuid"] = cachedUser }
            if let cachedOrganization { account["organizationUuid"] = cachedOrganization }
            config["oauthAccount"] = account
        }
        configData = try ProviderJSON.data(config)
        try AtomicAuthFileAccess().write(rawAuth, to: directory.appendingPathComponent(".credentials.json"))
        try AtomicAuthFileAccess().write(configData, to: home.appendingPathComponent(".claude.json"))
        store = ClaudeAuthStore(home: home, keychain: keychain)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func profile() throws -> Data {
        try ProviderJSON.data(["account": ["uuid": Self.user], "organization": ["uuid": Self.organization]])
    }
    func target() throws -> ImportedAccount {
        let credential = try CredentialParser.claude(
            rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-target-access"], "organizationUuid": Self.otherOrganization]),
            accountMetadata: ProviderJSON.data(["accountUuid": "00000000-0000-4000-8000-000000000044", "organizationUuid": Self.otherOrganization]))
        return try ProviderAccountParser.claude(credential)
    }
    func assertNativeUnchanged() throws {
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json")) == rawAuth)
        #expect(try Data(contentsOf: home.appendingPathComponent(".claude.json")) == configData)
    }
}

@Suite("Claude native source workspace binding")
struct ClaudeReadBindingTests {
    @Test("A native grant is identified by its profile when the cached workspace is stale")
    @MainActor func mismatchedWorkspace() async throws {
        let fixture = try BindingFixture(cachedOrganization: BindingFixture.otherOrganization)
        defer { fixture.cleanup() }
        await #expect(throws: AgentSwapError.self) { try await fixture.store.readIfPresent() }
        #expect(!(await fixture.store.compatibility()).canWrite)
        let transport = BindingTransport(try fixture.profile())
        let adapter = ClaudeProviderAdapter(authStore: fixture.store, transport: transport, loginRunner: BindingLogin())
        let imported = try await adapter.importCurrent()
        #expect(imported.account.identity.workspaceID == BindingFixture.organization)
        let vault = BindingVault()
        let model = AppModel(adapters: [adapter], secrets: vault, store: BindingState())
        await model.importCurrent(.claude)
        #expect(model.state.accounts.count == 1)
        #expect(model.state.accounts.first?.identity.workspaceID == BindingFixture.organization)
        #expect(await vault.saves > 0)
        #expect(await transport.requests.count == 1)
        try fixture.assertNativeUnchanged()
    }

    @Test("Even matching complete native caches require profile HTTP before first identification")
    func matchingWorkspace() async throws {
        let fixture = try BindingFixture(cachedOrganization: BindingFixture.organization)
        defer { fixture.cleanup() }
        let transport = BindingTransport(try fixture.profile())
        let adapter = ClaudeProviderAdapter(authStore: fixture.store, transport: transport, loginRunner: BindingLogin())
        let imported = try await adapter.importCurrent()
        #expect(imported.account.identity.workspaceID == BindingFixture.organization)
        #expect(await transport.requests.count == 1)
        _ = try await adapter.importCurrent()
        #expect(await transport.requests.count == 1)
        try fixture.assertNativeUnchanged()
    }

    @Test("An absent or incomplete metadata cache still permits authenticated profile identification", arguments: [false, true])
    func missingMetadata(_ includeCache: Bool) async throws {
        let fixture = try BindingFixture(cachedOrganization: nil, includeCache: includeCache)
        defer { fixture.cleanup() }
        let transport = BindingTransport(try fixture.profile())
        let adapter = ClaudeProviderAdapter(authStore: fixture.store, transport: transport, loginRunner: BindingLogin())
        let imported = try await adapter.importCurrent()
        #expect(imported.account.identity.workspaceID == BindingFixture.organization)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-source-access")
        try fixture.assertNativeUnchanged()
    }

    @Test("A profile-identified source with incomplete cached identity is backed up and safely activated", arguments: ["organizationAbsent", "organizationEmpty", "userAbsent", "userEmpty", "bothAbsent", "bothEmpty", "cacheAbsent"])
    func incompleteCacheActivation(_ shape: String) async throws {
        let keychain = BindingSwitchKeychain()
        let cachedOrganization = shape == "organizationAbsent" || shape == "bothAbsent" ? nil :
            (shape == "organizationEmpty" || shape == "bothEmpty" ? "" : BindingFixture.organization)
        let cachedUser = shape == "userAbsent" || shape == "bothAbsent" ? nil :
            (shape == "userEmpty" || shape == "bothEmpty" ? "" : BindingFixture.user)
        let fixture = try BindingFixture(cachedOrganization: cachedOrganization, includeCache: shape != "cacheAbsent",
                                         cachedUser: cachedUser, keychain: keychain)
        defer { fixture.cleanup() }
        let target = try fixture.target(), backup = BindingBackup()
        let transport = BindingTransport(try fixture.profile())
        await transport.setTargetProfile(try ProviderJSON.data([
            "account": ["uuid": target.account.identity.userID],
            "organization": ["uuid": target.account.identity.workspaceID]
        ]))
        let adapter = ClaudeProviderAdapter(authStore: fixture.store, transport: transport, loginRunner: BindingLogin())
        let result = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                            saveLatest: { await backup.save($0) })
        guard case .applied = result else { Issue.record("Profile-filled source identity must permit the exact-generation switch"); return }
        let source = try #require(await backup.source)
        #expect(source.account.identity.userID == BindingFixture.user)
        #expect(source.account.identity.workspaceID == BindingFixture.organization)
        #expect(source.credential.rawAuth == fixture.rawAuth)
        #expect(await transport.requests.count == 2)
        #expect(try ProviderAccountParser.claude(await fixture.store.read()).account.identity == target.account.identity)
        #expect(try Data(contentsOf: fixture.home.appendingPathComponent(".claude/.credentials.json")) == target.credential.rawAuth)
        let config = try ProviderJSON.object(Data(contentsOf: fixture.home.appendingPathComponent(".claude.json")))
        #expect(config["fixtureSharedSetting"] as? Bool == true)
    }

    @Test("Incomplete cached identity cannot satisfy a source fence without an exact grant generation")
    func incompleteCacheRequiresGeneration() async throws {
        let keychain = BindingSwitchKeychain()
        let fixture = try BindingFixture(cachedOrganization: nil, keychain: keychain)
        defer { fixture.cleanup() }
        let target = try fixture.target()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.activate(target.credential,
                expectedSourceIdentity: .init(provider: .claude, userID: BindingFixture.user, workspaceID: BindingFixture.organization))
        }
        #expect(keychain.writeCount() == 0)
        try fixture.assertNativeUnchanged()
    }

    @Test("Malformed present identity fields remain blocked even with the exact source grant", arguments: ["accountUuid", "organizationUuid"])
    func malformedCacheIdentity(_ key: String) async throws {
        let keychain = BindingSwitchKeychain()
        let fixture = try BindingFixture(cachedOrganization: BindingFixture.organization, keychain: keychain)
        defer { fixture.cleanup() }
        var config = try ProviderJSON.object(fixture.configData)
        var cached = try #require(config["oauthAccount"] as? [String: Any]); cached[key] = 7
        config["oauthAccount"] = cached
        let malformed = try ProviderJSON.data(config), configURL = fixture.home.appendingPathComponent(".claude.json")
        try AtomicAuthFileAccess().write(malformed, to: configURL)
        await #expect(throws: AgentSwapError.self) { try await fixture.store.read() }
        let target = try fixture.target()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.activate(target.credential,
                expectedSourceIdentity: .init(provider: .claude, userID: BindingFixture.user, workspaceID: BindingFixture.organization),
                expectedSourceAuth: fixture.rawAuth)
        }
        #expect(keychain.writeCount() == 0)
        #expect(try Data(contentsOf: configURL) == malformed)
        #expect(try Data(contentsOf: fixture.home.appendingPathComponent(".claude/.credentials.json")) == fixture.rawAuth)
    }
}
