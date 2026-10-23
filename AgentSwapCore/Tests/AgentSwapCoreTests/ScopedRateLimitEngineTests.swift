import Foundation
import Testing
@testable import AgentSwapCore

private actor ScopedRateLimitProvider: ProviderAdapter {
    nonisolated let provider: Provider
    let current: ImportedAccount
    private var nativeError: AgentSwapError?
    private var usageErrors: [UUID: AgentSwapError] = [:]
    private var restoredLimits: [ProviderRequestRateLimit] = []
    private(set) var imports = 0
    private(set) var refreshed: [UUID] = []
    private(set) var verified: [UUID] = []
    private(set) var usages: [UUID] = []
    private(set) var activations = 0

    init(_ current: ImportedAccount) { self.current = current; provider = current.account.provider }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount {
        imports += 1
        if let nativeError { throw nativeError }
        return current
    }
    func login() throws -> ImportedAccount { throw AgentSwapError.cancelled }
    func cancelLogin() {}
    func hasRunningConsumers() -> Bool { false }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        refreshed.append(account.id)
        return credential
    }
    func verifyCredential(_ credential: Credential, account: AccountRecord) -> Credential {
        verified.append(account.id)
        return credential
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot {
        usages.append(account.id)
        await Task.yield()
        if let error = usageErrors[account.id] { throw error }
        return .init(windows: [.init(id: "common", title: "fixture", usedPercent: 20)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activations += 1
        return .applied(message: "fixture")
    }
    func restoreRequestRateLimits(_ records: [ProviderRequestRateLimit]) { restoredLimits = records }
    func activeRequestRateLimits() -> [ProviderRequestRateLimit] { restoredLimits }
    func restoredRequestLimits() -> [ProviderRequestRateLimit] { restoredLimits }
    func setNativeError(_ error: AgentSwapError?) { nativeError = error }
    func setUsageError(_ error: AgentSwapError?, accountID: UUID) { usageErrors[accountID] = error }
    func resetCounts() { imports = 0; refreshed = []; verified = []; usages = []; activations = 0 }
}

private actor ScopedRateLimitFailingState: StateStore {
    private var value: PersistedState
    private var failSaving = false
    private(set) var failedSaveAttempts = 0
    init(_ value: PersistedState) { self.value = value }
    func load() -> PersistedState { value }
    func save(_ state: PersistedState) async throws {
        await Task.yield()
        if failSaving {
            failedSaveAttempts += 1
            throw AgentSwapError.storage("Fixture state persistence failed")
        }
        value = state
    }
    func failSubsequentSaves() { failSaving = true }
}

@Suite("Request-scoped server limits in the account engine") @MainActor
struct ScopedRateLimitEngineTests {
    private struct Fixture {
        let first: AccountRecord
        let second: AccountRecord
        let codex: AccountRecord
        let claudeProvider: ScopedRateLimitProvider
        let codexProvider: ScopedRateLimitProvider
        let vault: MemorySecrets
        let store: MemoryState
        let model: AppModel
        let initial: PersistedState
    }

    private func credential(_ account: AccountRecord, ownerBound: Bool = true, expired: Bool = false) throws -> Credential {
        let expiry = Date().addingTimeInterval(expired ? -60 : 100_000)
        if account.provider == .codex {
            return .init(accessToken: "fixture-codex-access", refreshToken: "fixture-codex-refresh", expiresAt: expiry,
                         rawAuth: Data("fixture-codex-auth".utf8))
        }
        let credential = try CredentialParser.claude(rawAuth: ProviderJSON.data([
            "claudeAiOauth": ["accessToken": "fixture-access-\(account.identity.userID)",
                              "refreshToken": "fixture-refresh-\(account.identity.userID)",
                              "expiresAt": expiry.timeIntervalSince1970 * 1000],
            "organizationUuid": account.identity.workspaceID
        ]), accountMetadata: ProviderJSON.data([
            "accountUuid": account.identity.userID, "organizationUuid": account.identity.workspaceID
        ]))
        return ownerBound ? try credential.withVerifiedClaudeIdentity(account.identity) : credential
    }

    private func fixture(stateChange: (inout PersistedState) -> Void = { _ in }) async throws -> Fixture {
        let first = AccountRecord(identity: .init(provider: .claude, userID: "first", workspaceID: "fixture-workspace"))
        let second = AccountRecord(identity: .init(provider: .claude, userID: "second", workspaceID: "fixture-workspace"))
        let codex = AccountRecord(identity: .init(provider: .codex, userID: "codex", workspaceID: "fixture-workspace"))
        let claudeProvider = ScopedRateLimitProvider(.init(account: first, credential: try credential(first)))
        let codexProvider = ScopedRateLimitProvider(.init(account: codex, credential: try credential(codex)))
        let vault = MemorySecrets()
        var state = PersistedState(); state.accounts = [first, second, codex]
        state.activeAccounts = [.claude: first.id, .codex: codex.id]
        for account in state.accounts {
            await vault.save(try credential(account), accountID: account.id)
            state.usage[account.id] = .init(
                snapshot: .init(fetchedAt: Date().addingTimeInterval(-60),
                                windows: [.init(id: "common", title: "fixture", usedPercent: 30)]),
                attemptedAt: Date())
        }
        stateChange(&state)
        let store = MemoryState(state)
        let model = AppModel(adapters: [claudeProvider, codexProvider], secrets: vault, store: store)
        await model.start(); model.stop()
        await claudeProvider.resetCounts(); await codexProvider.resetCounts()
        return .init(first: first, second: second, codex: codex, claudeProvider: claudeProvider,
                     codexProvider: codexProvider, vault: vault, store: store, model: model, initial: state)
    }

    private func usageLimit(_ account: AccountRecord, retry: Date) -> ProviderRequestRateLimit {
        .init(key: .account(provider: account.provider, kind: .usage, accountID: account.id), retryAfter: retry)
    }

    @Test("One account's usage 429 preserves its values while other Claude and Codex accounts continue")
    func usageLimitDoesNotStopOtherAccounts() async throws {
        let fixture = try await fixture()
        let record = usageLimit(fixture.first, retry: Date().addingTimeInterval(1200))
        let previousCredential = await fixture.vault.load(accountID: fixture.first.id)
        await fixture.claudeProvider.setUsageError(.requestRateLimited(record), accountID: fixture.first.id)
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.usages == [fixture.first.id, fixture.second.id])
        #expect(await fixture.codexProvider.usages == [fixture.codex.id])
        #expect(fixture.model.providerRetryAfter(.claude) == nil)
        #expect(fixture.model.providerRetryAfter(.codex) == nil)
        #expect(fixture.model.state.usage[fixture.first.id]?.snapshot == fixture.initial.usage[fixture.first.id]?.snapshot)
        #expect(fixture.model.state.usage[fixture.first.id]?.requestRateLimit == record)
        #expect(fixture.model.state.usage[fixture.first.id]?.retryAfter == record.retryAfter)
        #expect(fixture.model.state.usage[fixture.first.id]?.retryReason == .serverRateLimit)
        #expect(fixture.model.state.usage[fixture.second.id]?.error == nil)
        #expect(fixture.model.state.usage[fixture.second.id]?.snapshot?.windows.first?.usedPercent == 20)
        #expect(fixture.model.state.accounts.allSatisfy { $0.authenticationState == .valid })
        #expect(await fixture.vault.load(accountID: fixture.first.id) == previousCredential)
        #expect(fixture.model.state.requestRateLimits?.contains(record) == true)
        #expect(await fixture.store.load().requestRateLimits?.contains(record) == true)
    }

    @Test("Concurrent and repeated forced requests recheck the account deadline after acquiring the provider queue")
    func forcedRefreshesRespectAccountLimit() async throws {
        let fixture = try await fixture()
        let record = usageLimit(fixture.first, retry: Date().addingTimeInterval(1200))
        await fixture.claudeProvider.setUsageError(.requestRateLimited(record), accountID: fixture.first.id)
        async let first: Void = fixture.model.refreshAll()
        async let second: Void = fixture.model.refreshAll()
        _ = await (first, second)
        await fixture.model.refreshAll()
        let usages = await fixture.claudeProvider.usages
        let verifications = await fixture.claudeProvider.verified
        #expect(usages.filter { $0 == fixture.first.id }.count == 1)
        #expect(verifications.filter { $0 == fixture.first.id }.count == 1)
        #expect(await fixture.claudeProvider.imports == 1)
        #expect(await fixture.claudeProvider.refreshed.isEmpty)
        #expect(await fixture.claudeProvider.activations == 0)
        #expect(usages.contains(fixture.second.id))
        #expect(await fixture.codexProvider.usages.contains(fixture.codex.id))
        #expect(fixture.model.providerRetryAfter(.claude) == nil)
    }

    @Test("A scoped deadline survives Codable restart without seeding a provider-wide legacy delay")
    func restartRetainsOnlyTheAffectedAccountLimit() async throws {
        let fixture = try await fixture()
        let record = usageLimit(fixture.first, retry: Date().addingTimeInterval(1200))
        await fixture.claudeProvider.setUsageError(.requestRateLimited(record), accountID: fixture.first.id)
        await fixture.model.refreshAll()
        let persisted = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(await fixture.store.load()))
        let claude = ScopedRateLimitProvider(fixture.claudeProvider.current)
        let codex = ScopedRateLimitProvider(fixture.codexProvider.current)
        let restarted = AppModel(adapters: [claude, codex], secrets: fixture.vault, store: MemoryState(persisted))
        await restarted.start(); restarted.stop()
        await restarted.refreshAll()
        #expect(restarted.providerRetryAfter(.claude) == nil)
        #expect(await claude.usages == [fixture.second.id])
        #expect(await codex.usages == [fixture.codex.id])
        #expect(await claude.restoredRequestLimits().contains(record))
        #expect(restarted.state.usage[fixture.first.id]?.snapshot == fixture.initial.usage[fixture.first.id]?.snapshot)
        #expect(restarted.state.accounts.allSatisfy { $0.authenticationState == .valid })
    }

    @Test("Restoring new scoped records preserves an older provider-wide deadline")
    func restartPreservesLegacyProviderGate() async throws {
        let retry = Date().addingTimeInterval(1200)
        let fixture = try await fixture { state in
            state.providerRetryAfter = [.claude: retry]
            state.requestRateLimits = [.init(key: .account(provider: .codex, kind: .usage, accountID: state.accounts[2].id),
                                             retryAfter: retry)]
        }
        await fixture.model.refreshAll()
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.claudeProvider.usages.isEmpty)
        #expect(await fixture.claudeProvider.imports == 0)
        #expect(await fixture.codexProvider.usages.isEmpty)
        #expect(fixture.model.state.usage[fixture.first.id] == fixture.initial.usage[fixture.first.id])
    }

    @Test("A native profile 429 allows only owner-bound saved usage and never authorizes rotation or application", arguments: [false, true])
    func nativeProfileLimitDoesNotImplyNativeOwnership(ownerBound: Bool) async throws {
        let fixture = try await fixture()
        let saved = try credential(fixture.first, ownerBound: ownerBound, expired: true)
        await fixture.vault.save(saved, accountID: fixture.first.id)
        let record = ProviderRequestRateLimit(key: .credential(provider: .claude, kind: .profile, token: "fixture-unknown-native-token"),
                                              retryAfter: Date().addingTimeInterval(1200))
        await fixture.claudeProvider.setNativeError(.requestRateLimited(record))
        var initial = fixture.initial
        initial.pendingNativeRefreshPredecessor = [fixture.first.id: String(repeating: "a", count: 64)]
        initial.lastSwitch[.claude] = Date().addingTimeInterval(-600)
        let store = MemoryState(initial)
        let model = AppModel(adapters: [fixture.claudeProvider, fixture.codexProvider], secrets: fixture.vault, store: store)
        await model.start(); model.stop()
        let activeBefore = initial.activeAccounts
        let pendingBefore = initial.pendingNativeRefreshPredecessor
        #expect(model.state.requestRateLimits?.contains(record) == true)
        await model.refreshAll()
        let usages = await fixture.claudeProvider.usages
        #expect(usages.contains(fixture.first.id) == ownerBound)
        #expect(usages.contains(fixture.second.id))
        #expect(await fixture.claudeProvider.refreshed.isEmpty)
        #expect(await fixture.claudeProvider.activations == 0)
        #expect(model.state.activeAccounts == activeBefore)
        #expect(model.state.pendingNativeRefreshPredecessor == pendingBefore)
        #expect(model.state.lastSwitch == initial.lastSwitch)
        #expect(model.state.accounts.allSatisfy { $0.authenticationState == .valid })
        #expect(await fixture.vault.load(accountID: fixture.first.id) == saved)
        #expect(model.providerRetryAfter(.claude) == nil)
        #expect(model.state.requestRateLimits?.contains(record) == true)
        #expect(await store.load().requestRateLimits?.contains(record) == true)
        if ownerBound {
            #expect(model.state.usage[fixture.first.id]?.error == nil)
            #expect(model.state.usage[fixture.first.id]?.snapshot?.windows.first?.usedPercent == 20)
        } else {
            #expect(model.state.usage[fixture.first.id]?.snapshot == initial.usage[fixture.first.id]?.snapshot)
        }
    }

    @Test("Successful usage for another scope does not erase an independent profile cooldown")
    func successfulUsageKeepsOtherScope() async throws {
        let profile = ProviderRequestRateLimit(key: .credential(provider: .claude, kind: .profile, token: "fixture-unrelated-profile-token"),
                                               retryAfter: Date().addingTimeInterval(1200))
        let fixture = try await fixture { $0.requestRateLimits = [profile] }
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.usages == [fixture.first.id, fixture.second.id])
        #expect(fixture.model.state.requestRateLimits?.contains(profile) == true)
        #expect(await fixture.store.load().requestRateLimits?.contains(profile) == true)
        #expect(fixture.model.providerRetryAfter(.claude) == nil)
    }

    @Test("A restored token-refresh deadline still permits usage with a valid saved access token")
    func refreshDeadlineDoesNotBlockValidUsage() async throws {
        var restoredLimit: ProviderRequestRateLimit?
        let fixture = try await fixture { state in
            let accountID = state.accounts[0].id
            let limit = ProviderRequestRateLimit(key: .account(provider: .claude, kind: .tokenRefresh, accountID: accountID),
                                                 retryAfter: Date().addingTimeInterval(1200))
            restoredLimit = limit
            state.requestRateLimits = [limit]
            state.usage[accountID]?.error = "Fixture earlier refresh request was limited"
            state.usage[accountID]?.retryAfter = limit.retryAfter
            state.usage[accountID]?.retryReason = .serverRateLimit
            state.usage[accountID]?.requestRateLimit = limit
        }
        let limit = try #require(restoredLimit)
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.usages == [fixture.first.id, fixture.second.id])
        #expect(await fixture.claudeProvider.refreshed.isEmpty)
        #expect(fixture.model.state.usage[fixture.first.id]?.error == nil)
        #expect(fixture.model.state.usage[fixture.first.id]?.requestRateLimit == nil)
        #expect(fixture.model.state.usage[fixture.first.id]?.snapshot?.windows.first?.usedPercent == 20)
        #expect(fixture.model.state.requestRateLimits?.contains(limit) == true)
        #expect(await fixture.store.load().requestRateLimits?.contains(limit) == true)
        #expect(fixture.model.providerRetryAfter(.claude) == nil)
    }

    @Test("A failed profile-cooldown save stops saved-usage fallback and every queued or subsequent account request")
    func failedProfileLimitPersistenceStopsFurtherHTTP() async throws {
        let fixture = try await fixture()
        let store = ScopedRateLimitFailingState(fixture.initial)
        let model = AppModel(adapters: [fixture.claudeProvider, fixture.codexProvider], secrets: fixture.vault, store: store)
        await model.start(); model.stop()
        await fixture.claudeProvider.resetCounts(); await fixture.codexProvider.resetCounts()
        let persistedBefore = await store.load()
        let accountsBefore = model.state.accounts
        let activeBefore = model.state.activeAccounts
        let credentialBefore = await fixture.vault.load(accountID: fixture.first.id)
        let limit = ProviderRequestRateLimit(key: .credential(provider: .claude, kind: .profile, token: "fixture-unsaved-native-profile-token"),
                                             retryAfter: Date().addingTimeInterval(1200))
        await fixture.claudeProvider.setNativeError(.requestRateLimited(limit))
        await store.failSubsequentSaves()
        async let first: Void = model.refreshAll()
        async let second: Void = model.refreshAll()
        _ = await (first, second)
        await model.refreshAll()
        #expect(await store.failedSaveAttempts == 1)
        #expect(await store.load() == persistedBefore)
        #expect(model.state.requestRateLimits?.contains(limit) == true)
        #expect(model.switchOperationBlockReason?.contains("저장 오류") == true)
        #expect(await fixture.claudeProvider.imports == 1)
        #expect(await fixture.claudeProvider.verified.isEmpty)
        #expect(await fixture.claudeProvider.usages.isEmpty)
        #expect(await fixture.claudeProvider.refreshed.isEmpty)
        #expect(await fixture.claudeProvider.activations == 0)
        #expect(await fixture.codexProvider.imports == 0)
        #expect(await fixture.codexProvider.verified.isEmpty)
        #expect(await fixture.codexProvider.usages.isEmpty)
        #expect(await fixture.codexProvider.refreshed.isEmpty)
        #expect(await fixture.codexProvider.activations == 0)
        #expect(model.state.accounts == accountsBefore)
        #expect(model.state.activeAccounts == activeBefore)
        #expect(model.state.pendingNativeRefreshPredecessor == persistedBefore.pendingNativeRefreshPredecessor)
        #expect(await fixture.vault.load(accountID: fixture.first.id) == credentialBefore)
        #expect(credentialBefore?.verifiedClaudeAccountIdentity == fixture.first.identity)
        for account in persistedBefore.accounts {
            #expect(model.state.usage[account.id]?.snapshot == persistedBefore.usage[account.id]?.snapshot)
        }
    }
}
