import Foundation
import Testing
@testable import AgentSwapCore

private actor RateLimitProvider: ProviderAdapter {
    nonisolated let provider: Provider
    private let current: ImportedAccount
    private var usageError: AgentSwapError?
    private var importError: AgentSwapError?
    private var loginError: AgentSwapError?
    private var verificationError: AgentSwapError?
    private(set) var importedCount = 0
    private(set) var refreshedCount = 0
    private(set) var verifiedCount = 0
    private(set) var usageAccounts: [UUID] = []
    private(set) var activatedCount = 0
    private(set) var loginStartedCount = 0

    init(_ current: ImportedAccount) { self.current = current; provider = current.account.provider }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount {
        importedCount += 1
        if let importError { throw importError }
        return current
    }
    func login() throws -> ImportedAccount {
        loginStartedCount += 1
        if let loginError { throw loginError }
        return current
    }
    func cancelLogin() {}
    func hasRunningConsumers() -> Bool { false }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        refreshedCount += 1
        return credential
    }
    func verifyCredential(_ credential: Credential, account: AccountRecord) throws -> Credential {
        verifiedCount += 1
        if let verificationError { throw verificationError }
        return credential
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot {
        usageAccounts.append(account.id)
        await Task.yield()
        if let usageError { throw usageError }
        return .init(windows: [.init(id: "common", title: "fixture", usedPercent: 20)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activatedCount += 1
        return .applied(message: "fixture")
    }
    func setUsageError(_ value: AgentSwapError?) { usageError = value }
    func setImportError(_ value: AgentSwapError?) { importError = value }
    func setLoginError(_ value: AgentSwapError?) { loginError = value }
    func setVerificationError(_ value: AgentSwapError?) { verificationError = value }
    func resetCounts() {
        importedCount = 0; refreshedCount = 0; verifiedCount = 0
        usageAccounts = []; activatedCount = 0
        loginStartedCount = 0
    }
    func requestCount() -> Int { importedCount + refreshedCount + verifiedCount + usageAccounts.count + activatedCount + loginStartedCount }
}

private actor RateLimitDesktopManager: ClaudeDesktopAccountManaging {
    private var error: AgentSwapError?
    private(set) var captures = 0
    private(set) var preparations = 0
    private(set) var finishes = 0
    func captureCurrent(for account: AccountRecord) throws {
        captures += 1
        if let error { throw error }
    }
    func prepareSwitch(target: AccountRecord, registered: [AccountRecord], currentCLI: AccountIdentity?) throws -> UUID {
        preparations += 1
        if let error { throw error }
        return UUID()
    }
    func finish(transactionID: UUID, cliApplied: Bool) -> String { finishes += 1; return "fixture" }
    func recover(registered: [AccountRecord], currentCLI: AccountIdentity?) -> String { "fixture" }
    func deleteSnapshot(accountID: UUID) {}
    func setError(_ error: AgentSwapError) { self.error = error }
}

@Suite("Provider-wide server rate limits") @MainActor
struct ProviderRateLimitTests {
    private struct Fixture {
        let first: AccountRecord
        let second: AccountRecord
        let codex: AccountRecord
        let claudeProvider: RateLimitProvider
        let codexProvider: RateLimitProvider
        let vault: MemorySecrets
        let store: MemoryState
        let model: AppModel
        let initial: PersistedState
    }

    private func credential(_ name: String, expired: Bool = false) -> Credential {
        .init(accessToken: "fixture-\(name)", refreshToken: "fixture-refresh-\(name)",
              expiresAt: Date().addingTimeInterval(expired ? -60 : 100_000), rawAuth: Data(name.utf8))
    }

    private func fixture(desktop: RateLimitDesktopManager? = nil,
                         stateChange: (inout PersistedState) -> Void = { _ in }) async -> Fixture {
        let first = AccountRecord(identity: .init(provider: .claude, userID: "first", workspaceID: "fixture-workspace"))
        let second = AccountRecord(identity: .init(provider: .claude, userID: "second", workspaceID: "fixture-workspace"))
        let codex = AccountRecord(identity: .init(provider: .codex, userID: "codex", workspaceID: "fixture-workspace"))
        let claudeProvider = RateLimitProvider(.init(account: first, credential: credential("first")))
        let codexProvider = RateLimitProvider(.init(account: codex, credential: credential("codex")))
        let vault = MemorySecrets()
        var state = PersistedState(); state.accounts = [first, second, codex]
        state.activeAccounts = [.claude: first.id, .codex: codex.id]
        for account in state.accounts {
            await vault.save(credential(account.identity.userID), accountID: account.id)
            state.usage[account.id] = .init(
                snapshot: .init(fetchedAt: Date().addingTimeInterval(-60),
                                windows: [.init(id: "common", title: "fixture", usedPercent: 30)]),
                attemptedAt: Date())
        }
        stateChange(&state)
        let store = MemoryState(state)
        let model = AppModel(adapters: [claudeProvider, codexProvider], secrets: vault, store: store, claudeDesktop: desktop)
        await model.start(); model.stop()
        await claudeProvider.resetCounts(); await codexProvider.resetCounts()
        return .init(first: first, second: second, codex: codex, claudeProvider: claudeProvider,
                     codexProvider: codexProvider, vault: vault, store: store, model: model, initial: state)
    }

    @Test("The first 429 stops the provider batch while another provider still polls")
    func firstThrottleStopsProviderBatch() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setUsageError(.rateLimited(retry))
        await fixture.vault.save(credential("second", expired: true), accountID: fixture.second.id)
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.usageAccounts == [fixture.first.id])
        #expect(await fixture.claudeProvider.refreshedCount == 0)
        #expect(await fixture.codexProvider.usageAccounts == [fixture.codex.id])
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(fixture.model.providerRetryAfter(.codex) == nil)
        #expect(fixture.model.state.usage[fixture.first.id]?.snapshot == fixture.initial.usage[fixture.first.id]?.snapshot)
        #expect(fixture.model.state.usage[fixture.first.id]?.retryReason == .serverRateLimit)
        #expect(fixture.model.state.usage[fixture.second.id] == fixture.initial.usage[fixture.second.id])
        #expect(fixture.model.state.accounts.allSatisfy { $0.authenticationState == .valid })
    }

    @Test("Concurrent forced refreshes recheck a newly established provider deadline inside the queue")
    func concurrentForcedRefreshesHonorThrottle() async {
        let fixture = await fixture()
        await fixture.claudeProvider.setUsageError(.rateLimited(Date().addingTimeInterval(1200)))
        async let first: Void = fixture.model.refreshAll()
        async let second: Void = fixture.model.refreshAll()
        _ = await (first, second)
        #expect(await fixture.claudeProvider.usageAccounts == [fixture.first.id])
        #expect(await fixture.claudeProvider.verifiedCount == 1)
    }

    @Test("Forced refreshes and explicit switching make no new provider requests during the cooldown")
    func userActionsDoNotBypassThrottle() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setUsageError(.rateLimited(retry))
        await fixture.model.refreshAll()
        let count = await fixture.claudeProvider.requestCount()
        await fixture.model.refreshAll()
        await fixture.model.switchAccount(fixture.second.id)
        await fixture.model.importCurrent(.claude)
        await fixture.model.login(.claude)
        await fixture.model.reauthenticateAccount(fixture.second.id)
        #expect(await fixture.claudeProvider.requestCount() == count)
        #expect(await fixture.claudeProvider.loginStartedCount == 0)
        #expect(!fixture.model.isLoggingIn)
        #expect(fixture.model.switchOperationBlockReason(for: fixture.second.id)?.contains("서버 요청 제한") == true)
        #expect(fixture.model.state.lastSwitch[.claude] == nil)
        #expect(await fixture.model.authorizeSavedCredential(fixture.second.id))
        await fixture.model.refreshAll()
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.claudeProvider.requestCount() == count)
    }

    @Test("An explicit current-login import records its server throttle for every account")
    func importThrottleIsShared() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setImportError(.rateLimited(retry))
        await fixture.model.importCurrent(.claude)
        #expect(await fixture.claudeProvider.importedCount == 1)
        #expect(await fixture.claudeProvider.usageAccounts.isEmpty)
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.store.load().providerRetryAfter?[.claude] == retry)
        await fixture.model.importCurrent(.claude)
        #expect(await fixture.claudeProvider.importedCount == 1)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.first.id)
    }

    @Test("The first login profile throttle persists a provider cooldown without changing saved accounts", arguments: [false, true])
    func loginThrottleIsShared(reauthentication: Bool) async throws {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        let previousCredential = await fixture.vault.load(accountID: fixture.second.id)
        await fixture.claudeProvider.setLoginError(.rateLimited(retry))
        if reauthentication { await fixture.model.reauthenticateAccount(fixture.second.id) }
        else { await fixture.model.login(.claude) }
        let completionDeadline = Date().addingTimeInterval(2)
        while fixture.model.isLoggingIn || fixture.model.isBusy {
            try #require(Date() < completionDeadline, "Fixture login failure must finish promptly")
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.claudeProvider.loginStartedCount == 1)
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.store.load().providerRetryAfter?[.claude] == retry)
        #expect(fixture.model.state.accounts == fixture.initial.accounts)
        #expect(fixture.model.state.usage[fixture.first.id] == fixture.initial.usage[fixture.first.id])
        #expect(fixture.model.state.usage[fixture.second.id] == fixture.initial.usage[fixture.second.id])
        #expect(await fixture.vault.load(accountID: fixture.second.id) == previousCredential)
        let count = await fixture.claudeProvider.requestCount()
        await fixture.model.refreshAll()
        await fixture.model.login(.claude)
        await fixture.model.reauthenticateAccount(fixture.second.id)
        #expect(await fixture.claudeProvider.requestCount() == count)
        #expect(!fixture.model.isLoggingIn)
    }

    @Test("A target verification throttle stops switching before activation and blocks subsequent provider requests")
    func switchVerificationThrottleIsShared() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        let previousCredential = await fixture.vault.load(accountID: fixture.second.id)
        await fixture.claudeProvider.setVerificationError(.rateLimited(retry))
        await fixture.model.switchAccount(fixture.second.id)
        #expect(await fixture.claudeProvider.verifiedCount == 1)
        #expect(await fixture.claudeProvider.activatedCount == 0)
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.store.load().providerRetryAfter?[.claude] == retry)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.first.id)
        #expect(fixture.model.state.lastSwitch[.claude] == nil)
        #expect(await fixture.vault.load(accountID: fixture.second.id) == previousCredential)
        #expect(fixture.model.state.usage[fixture.first.id] == fixture.initial.usage[fixture.first.id])
        #expect(fixture.model.state.usage[fixture.second.id] == fixture.initial.usage[fixture.second.id])
        let count = await fixture.claudeProvider.requestCount()
        await fixture.model.switchAccount(fixture.second.id)
        await fixture.model.refreshAll()
        await fixture.model.importCurrent(.claude)
        await fixture.model.login(.claude)
        #expect(await fixture.claudeProvider.requestCount() == count)
        #expect(await fixture.claudeProvider.activatedCount == 0)
    }

    @Test("Known throttles block combined Desktop preparation and capture before any process operation")
    func throttleBlocksDesktopPreparation() async {
        let desktop = RateLimitDesktopManager()
        let fixture = await fixture(desktop: desktop) { state in
            state.providerRetryAfter = [.claude: Date().addingTimeInterval(1200)]
        }
        await fixture.model.switchClaudeDesktopAccount(fixture.second.id)
        await fixture.model.captureClaudeDesktopLogin(fixture.second.id)
        #expect(await fixture.claudeProvider.requestCount() == 0)
        #expect(await desktop.preparations == 0)
        #expect(await desktop.captures == 0)
        #expect(await desktop.finishes == 0)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.first.id)
    }

    @Test("Desktop preparation and capture propagate profile 429 into the shared provider deadline", arguments: [false, true])
    func desktopThrottleIsShared(capture: Bool) async {
        let desktop = RateLimitDesktopManager()
        let fixture = await fixture(desktop: desktop)
        let retry = Date().addingTimeInterval(1200)
        await desktop.setError(.rateLimited(retry))
        if capture { await fixture.model.captureClaudeDesktopLogin(fixture.second.id) }
        else { await fixture.model.switchClaudeDesktopAccount(fixture.second.id) }
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        #expect(await fixture.store.load().providerRetryAfter?[.claude] == retry)
        #expect(await fixture.claudeProvider.activatedCount == 0)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.first.id)
    }

    @Test("A startup identity request that receives 429 blocks the first polling pass")
    func startupThrottleStopsPolling() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setImportError(.rateLimited(retry))
        let restarted = AppModel(adapters: [fixture.claudeProvider, fixture.codexProvider],
                                 secrets: fixture.vault, store: MemoryState(fixture.initial))
        await restarted.start(); restarted.stop()
        #expect(await fixture.claudeProvider.importedCount == 1)
        #expect(restarted.providerRetryAfter(.claude) == retry)
        await restarted.refreshAll()
        #expect(await fixture.claudeProvider.requestCount() == 1)
        #expect(await fixture.codexProvider.usageAccounts == [fixture.codex.id])
        #expect(restarted.state.usage[fixture.first.id] == fixture.initial.usage[fixture.first.id])
    }

    @Test("A provider cooldown prevents automatic switching from otherwise eligible cached usage")
    func cooldownBlocksAutomaticSwitch() async {
        let retry = Date().addingTimeInterval(1200)
        let fixture = await fixture { state in
            state.providerRetryAfter = [.claude: retry]
            state.settings.automation[.claude]?.enabled = true
            state.accounts[1].automaticSwitchEligible = true
            state.usage[state.accounts[0].id]?.snapshot?.windows[0].usedPercent = 95
        }
        #expect(AutomaticSwitchPolicy.decide(provider: .claude, state: fixture.initial) == .switchTo(fixture.second.id))
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.requestCount() == 0)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.first.id)
        #expect(fixture.model.state.lastSwitch[.claude] == nil)
    }

    @Test("A server deadline survives restart and blocks native identity requests at startup")
    func restartHonorsPersistedThrottle() async throws {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setUsageError(.rateLimited(retry))
        await fixture.model.refreshAll()
        let persisted = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(await fixture.store.load()))
        #expect(persisted.providerRetryAfter?[.claude] == retry)
        let count = await fixture.claudeProvider.requestCount()
        let restarted = AppModel(adapters: [fixture.claudeProvider, fixture.codexProvider],
                                 secrets: fixture.vault, store: MemoryState(persisted))
        await restarted.start(); restarted.stop()
        await restarted.refreshAll()
        #expect(await fixture.claudeProvider.requestCount() == count)
        #expect(restarted.state.activeAccounts[.claude] == fixture.first.id)
        #expect(restarted.state.accounts.allSatisfy { $0.authenticationState == .valid })
    }

    @Test("Legacy account throttles seed the longest provider deadline without changing their caches")
    func legacyThrottleMigration() async throws {
        let shorter = Date().addingTimeInterval(600), longer = Date().addingTimeInterval(1200)
        let fixture = await fixture { state in
            state.usage[state.accounts[0].id]?.retryAfter = shorter
            state.usage[state.accounts[0].id]?.retryReason = .serverRateLimit
            state.usage[state.accounts[1].id]?.retryAfter = longer
            state.usage[state.accounts[1].id]?.retryReason = .serverRateLimit
        }
        #expect(fixture.model.providerRetryAfter(.claude) == longer)
        #expect(await fixture.store.load().providerRetryAfter?[.claude] == longer)
        #expect(fixture.model.state.usage[fixture.first.id] == fixture.initial.usage[fixture.first.id])
        #expect(fixture.model.state.usage[fixture.second.id] == fixture.initial.usage[fixture.second.id])
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.requestCount() == 0)
        // Optional storage remains compatible with states written before this field existed.
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.initial)) as? [String: Any])
        encoded.removeValue(forKey: "providerRetryAfter")
        let legacy = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(legacy.providerRetryAfter == nil)
    }

    @Test("Only known server throttles migrate to provider cooldowns", arguments: [UsageRetryReason.localFailure, .transientFailure, nil])
    func localDelaysDoNotThrottleProvider(reason: UsageRetryReason?) async {
        let fixture = await fixture { state in
            state.usage[state.accounts[0].id]?.retryAfter = Date().addingTimeInterval(1200)
            state.usage[state.accounts[0].id]?.retryReason = reason
        }
        #expect(fixture.model.providerRetryAfter(.claude) == nil)
        await fixture.model.refreshAll()
        #expect(await fixture.claudeProvider.usageAccounts == [fixture.second.id])
    }

    @Test("The exact server deadline permits a retry and successful requests preserve it")
    func retryAtDeadline() async {
        let fixture = await fixture()
        let retry = Date().addingTimeInterval(1200)
        await fixture.claudeProvider.setUsageError(.rateLimited(retry))
        // A stale cycle time must not become the basis of the server's absolute deadline.
        await fixture.model.refreshDue(force: true, now: Date().addingTimeInterval(-3600))
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
        await fixture.claudeProvider.setUsageError(nil)
        await fixture.model.refreshDue(force: true, now: retry.addingTimeInterval(-0.001))
        #expect(await fixture.claudeProvider.usageAccounts == [fixture.first.id])
        await fixture.model.refreshDue(force: true, now: retry)
        #expect(await fixture.claudeProvider.usageAccounts == [fixture.first.id, fixture.first.id, fixture.second.id])
        #expect(fixture.model.state.usage[fixture.first.id]?.error == nil)
        #expect(fixture.model.providerRetryAfter(.claude) == retry)
    }
}
