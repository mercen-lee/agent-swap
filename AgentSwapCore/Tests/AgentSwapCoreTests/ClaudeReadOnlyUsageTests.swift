import Foundation
import Testing
@testable import AgentSwapCore

private actor ReadOnlyClaudeProvider: ProviderAdapter {
    nonisolated let provider = Provider.claude
    let nativeError: AgentSwapError
    let usageError: AgentSwapError?
    private(set) var refreshCount = 0
    private(set) var activationCount = 0
    private(set) var verificationCount = 0
    private(set) var usageCount = 0
    init(nativeError: AgentSwapError, usageError: AgentSwapError? = nil) {
        self.nativeError = nativeError; self.usageError = usageError
    }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount { throw nativeError }
    func login() throws -> ImportedAccount { throw AgentSwapError.cancelled }
    func cancelLogin() {}
    func hasRunningConsumers() -> Bool { false }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        refreshCount += 1
        return credential
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activationCount += 1
        return .applied(message: "Unexpected fixture activation")
    }
    func verifyCredential(_ credential: Credential, account: AccountRecord) throws -> Credential {
        verificationCount += 1
        guard credential.verifiedClaudeAccountIdentity == account.identity else {
            throw AgentSwapError.storage("Unexpected unverified fixture grant")
        }
        return credential
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) throws -> UsageSnapshot {
        usageCount += 1
        if let usageError { throw usageError }
        return .init(windows: [.init(id: "five_hour", title: "5시간", usedPercent: 23)])
    }
}

// All values and counters belong to this fixture and are protected by the lock.
private final class ReadOnlyNativeKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes = 0
    private var deniedService: String?
    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            if service == deniedService { throw AgentSwapError.storage("Fixture native Keychain access denied") }
            return values[service + "|" + account]
        }
    }
    func write(_ data: Data, service: String, account: String) { lock.withLock { values[service + "|" + account] = data; writes += 1 } }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account); writes += 1 } }
    func deny(service: String?) { lock.withLock { deniedService = service } }
    func mutationCount() -> Int { lock.withLock { writes } }
}

private actor ReadOnlyNativeTransport: ProviderHTTPTransport {
    let nativeProfileStatus: Int
    let usageBearer: String
    private(set) var paths: [String] = []
    private(set) var usageBearers: [String?] = []
    init(nativeProfileStatus: Int, usageBearer: String) { self.nativeProfileStatus = nativeProfileStatus; self.usageBearer = usageBearer }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/oauth/profile": return .init(data: Data("{}".utf8), statusCode: nativeProfileStatus)
        case "/api/oauth/usage":
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            usageBearers.append(bearer)
            guard bearer == usageBearer else { throw AgentSwapError.network("Wrong fixture usage token") }
            return .init(data: try ProviderJSON.data(["five_hour": ["utilization": 23]]), statusCode: 200)
        default: throw AgentSwapError.network("Unexpected fixture mutation request")
        }
    }
}

private struct ReadOnlyNativeLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

private struct ReadOnlyClaudeFixture {
    static let nativeUnverified = AgentSwapError.nativeIdentityUnverified("Fixture native profile returned HTTP 401")
    let account = AccountRecord(identity: .init(provider: .claude, userID: "fixture-readonly-user", workspaceID: "fixture-readonly-workspace"))
    let credential: Credential
    let snapshot = UsageSnapshot(fetchedAt: Date().addingTimeInterval(-300), windows: [.init(id: "five_hour", title: "5시간", usedPercent: 12)])
    let predecessor = String(repeating: "a", count: 64)
    let lastSwitch = Date().addingTimeInterval(-600)
    init(proof: String = "verified", expired: Bool = false) throws {
        var credential = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
            "accessToken": "fixture-readonly-access", "refreshToken": "fixture-readonly-refresh",
            "expiresAt": Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000
        ]]), accountMetadata: ProviderJSON.data([
            "accountUuid": account.identity.userID, "organizationUuid": account.identity.workspaceID
        ]))
        if proof != "legacy" { credential = try credential.withVerifiedClaudeIdentity(account.identity) }
        switch proof {
        case "changedToken": credential.accessToken = "fixture-tampered-access"
        case "changedMetadata": credential.accountMetadata = try ProviderJSON.data(["accountUuid": "fixture-other-user", "organizationUuid": account.identity.workspaceID])
        case "wrongAccount":
            if let binding = credential.claudeIdentityBinding {
                credential.claudeIdentityBinding = .init(identity: .init(provider: .claude, userID: "fixture-other-user", workspaceID: account.identity.workspaceID), grantDigest: binding.grantDigest)
            }
        default: break
        }
        self.credential = credential
    }
    @MainActor func model(nativeError: AgentSwapError = Self.nativeUnverified, usageError: AgentSwapError? = nil) async -> (AppModel, ReadOnlyClaudeProvider, MemorySecrets) {
        let provider = ReadOnlyClaudeProvider(nativeError: nativeError, usageError: usageError)
        let vault = MemorySecrets()
        await vault.save(credential, accountID: account.id)
        var state = PersistedState()
        state.accounts = [account]
        state.activeAccounts[.claude] = account.id
        state.pendingNativeRefreshPredecessor = [account.id: predecessor]
        state.lastSwitch[.claude] = lastSwitch
        state.usage[account.id] = .init(snapshot: snapshot, attemptedAt: Date())
        let model = AppModel(adapters: [provider], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        return (model, provider, vault)
    }
    @MainActor func assertOwnershipState(_ model: AppModel) {
        #expect(model.state.activeAccounts[.claude] == account.id)
        #expect(model.state.pendingNativeRefreshPredecessor == [account.id: predecessor])
        #expect(model.state.lastSwitch[.claude] == lastSwitch)
        #expect(model.pendingSwitch[.claude] == nil)
    }
}

@Suite("Claude verified saved usage with unverified native identity")
@MainActor
struct ClaudeReadOnlyUsageTests {
    @Test("The actual adapter uses only the verified saved bearer after native HTTP 401 and never mutates native auth", arguments: [
        "native401", "native403", "native503", "malformed-auth", "malformed-cache", "denied-native"
    ])
    func actualAdapterReadOnlyBoundary(_ mode: String) async throws {
        let fixture = try ReadOnlyClaudeFixture(expired: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapReadOnlyNative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let keychain = ReadOnlyNativeKeychain()
        let authStore = ClaudeAuthStore(home: home, keychain: keychain)
        let native = mode == "malformed-auth" ? Data("{}".utf8) : try ProviderJSON.data(["claudeAiOauth": [
            "accessToken": "fixture-stale-native-access", "refreshToken": "fixture-stale-native-refresh",
            "expiresAt": Date().addingTimeInterval(-300).timeIntervalSince1970 * 1000
        ]])
        let cachedIdentity: [String: Any] = mode == "malformed-cache"
            ? ["accountUuid": 7, "organizationUuid": fixture.account.identity.workspaceID]
            : ["accountUuid": fixture.account.identity.userID, "organizationUuid": fixture.account.identity.workspaceID]
        let config = try ProviderJSON.data(["oauthAccount": cachedIdentity, "fixtureSharedSetting": true])
        keychain.write(native, service: authStore.keychainService, account: authStore.keychainAccount)
        try AtomicAuthFileAccess().write(config, to: authStore.configURL)
        let vault = KeychainSecretStore(keychain: keychain)
        try await vault.save(fixture.credential, accountID: fixture.account.id)
        let mutationCount = keychain.mutationCount()
        if mode == "denied-native" { keychain.deny(service: authStore.keychainService) }
        let transport = ReadOnlyNativeTransport(nativeProfileStatus: mode == "native403" ? 403 : (mode == "native503" ? 503 : 401),
                                                usageBearer: "Bearer " + fixture.credential.accessToken)
        let adapter = ClaudeProviderAdapter(authStore: authStore, transport: transport, loginRunner: ReadOnlyNativeLogin())
        var state = PersistedState()
        state.accounts = [fixture.account]
        state.activeAccounts[.claude] = fixture.account.id
        state.pendingNativeRefreshPredecessor = [fixture.account.id: fixture.predecessor]
        state.lastSwitch[.claude] = fixture.lastSwitch
        state.usage[fixture.account.id] = .init(snapshot: fixture.snapshot, attemptedAt: Date())
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        await model.refreshAll()
        let usageAllowed = mode == "native401"
        #expect(await transport.usageBearers == (usageAllowed ? ["Bearer " + fixture.credential.accessToken] : []))
        #expect(!(await transport.paths).contains("/v1/oauth/token"))
        #expect(keychain.mutationCount() == mutationCount)
        keychain.deny(service: nil)
        #expect(try keychain.read(service: authStore.keychainService, account: authStore.keychainAccount) == native)
        #expect(try Data(contentsOf: authStore.configURL) == config)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path))
        #expect(try await vault.load(accountID: fixture.account.id) == fixture.credential)
        if usageAllowed {
            #expect(model.state.usage[fixture.account.id]?.error == nil)
            #expect(model.state.usage[fixture.account.id]?.snapshot?.windows.first?.usedPercent == 23)
        } else { #expect(model.state.usage[fixture.account.id]?.snapshot == fixture.snapshot) }
        fixture.assertOwnershipState(model)
    }

    @Test("An exact verified vault grant can read usage while preserving native ownership and pending generations", arguments: [false, true])
    func verifiedUsageDoesNotRotateOrApply(_ expired: Bool) async throws {
        let fixture = try ReadOnlyClaudeFixture(expired: expired)
        let (model, provider, vault) = await fixture.model()
        await model.refreshAll()
        #expect(model.state.usage[fixture.account.id]?.error == nil)
        #expect(model.state.usage[fixture.account.id]?.snapshot?.windows.first?.usedPercent == 23)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(await provider.usageCount == 1)
        #expect(await provider.verificationCount == 1)
        #expect(await provider.refreshCount == 0)
        #expect(await provider.activationCount == 0)
        #expect(await vault.load(accountID: fixture.account.id) == fixture.credential)
        #expect(model.message == ReadOnlyClaudeFixture.nativeUnverified.localizedDescription)
        fixture.assertOwnershipState(model)
    }

    @Test("A usage 401 preserves last values and never exchanges a refresh grant or applies pending auth")
    func usage401DoesNotRefresh() async throws {
        let fixture = try ReadOnlyClaudeFixture(expired: true)
        let (model, provider, vault) = await fixture.model(usageError: .authentication("Fixture usage HTTP 401"))
        await model.refreshAll()
        #expect(model.state.usage[fixture.account.id]?.snapshot == fixture.snapshot)
        #expect(model.state.usage[fixture.account.id]?.retryReason == .localFailure)
        #expect(model.state.usage[fixture.account.id]?.retryAfter != nil)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(await provider.usageCount == 1)
        #expect(await provider.refreshCount == 0)
        #expect(await provider.activationCount == 0)
        #expect(await vault.load(accountID: fixture.account.id) == fixture.credential)
        fixture.assertOwnershipState(model)
    }

    @Test("Server retry-after remains authoritative in the read-only usage path")
    func rateLimitIsPreserved() async throws {
        let fixture = try ReadOnlyClaudeFixture()
        let retry = Date().addingTimeInterval(600)
        let (model, provider, _) = await fixture.model(usageError: .rateLimited(retry))
        await model.refreshAll()
        await model.refreshAll()
        #expect(model.state.usage[fixture.account.id]?.snapshot == fixture.snapshot)
        #expect(model.state.usage[fixture.account.id]?.retryAfter == retry)
        #expect(model.state.usage[fixture.account.id]?.retryReason == .serverRateLimit)
        #expect(await provider.usageCount == 1)
        #expect(await provider.refreshCount == 0)
        #expect(await provider.activationCount == 0)
        fixture.assertOwnershipState(model)
    }

    @Test("Legacy, tampered, or wrong-account proof never enables the fallback", arguments: ["legacy", "changedToken", "changedMetadata", "wrongAccount"])
    func onlyExactPersistedProofPermitsUsage(_ proof: String) async throws {
        let fixture = try ReadOnlyClaudeFixture(proof: proof)
        let (model, provider, vault) = await fixture.model()
        await model.refreshAll()
        #expect(model.state.usage[fixture.account.id]?.snapshot == fixture.snapshot)
        #expect(model.state.usage[fixture.account.id]?.retryReason == .localFailure)
        #expect(await provider.verificationCount == 0)
        #expect(await provider.usageCount == 0)
        #expect(await provider.refreshCount == 0)
        #expect(await provider.activationCount == 0)
        #expect(await vault.load(accountID: fixture.account.id) == fixture.credential)
        fixture.assertOwnershipState(model)
    }

    @Test("Storage, malformed, and network failures do not enable the native HTTP-401 fallback", arguments: [
        AgentSwapError.storage("Fixture native Keychain access denied"), .unsupported("Fixture malformed native identity"), .network("Fixture native profile offline")
    ])
    func unrelatedNativeFailureDoesNotPermitUsage(_ error: AgentSwapError) async throws {
        let fixture = try ReadOnlyClaudeFixture()
        let (model, provider, _) = await fixture.model(nativeError: error)
        await model.refreshAll()
        #expect(model.state.usage[fixture.account.id]?.snapshot == fixture.snapshot)
        #expect(await provider.verificationCount == 0)
        #expect(await provider.usageCount == 0)
        #expect(await provider.refreshCount == 0)
        #expect(await provider.activationCount == 0)
        fixture.assertOwnershipState(model)
    }
}
