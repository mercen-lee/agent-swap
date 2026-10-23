import Foundation
import Testing
@testable import AgentSwapCore

private actor ReauthEventLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
    func clear() { entries.removeAll() }
}

private actor ReauthTestVault: SecretStore {
    private var values: [UUID: Credential] = [:]
    private var failure: String?
    private var unreadableNextRead = false
    let events: ReauthEventLog
    init(events: ReauthEventLog) { self.events = events }
    func seed(_ credential: Credential, id: UUID) { values[id] = credential }
    func peek(_ id: UUID) -> Credential? { values[id] }
    func fail(_ mode: String?) { failure = mode; unreadableNextRead = false }
    func load(accountID: UUID) throws -> Credential? {
        if unreadableNextRead { unreadableNextRead = false; throw AgentSwapError.storage("Fixture readback failure") }
        return values[accountID]
    }
    func save(_ credential: Credential, accountID: UUID) async throws {
        await events.append("vault-attempt:\(credential.accessToken)")
        if failure == "save" { throw AgentSwapError.storage("Fixture vault save failure") }
        values[accountID] = credential
        unreadableNextRead = failure == "readback"
        await events.append("vault-saved:\(credential.accessToken)")
    }
    func delete(accountID: UUID) { values.removeValue(forKey: accountID) }
}

private actor ReauthTestState: StateStore {
    private(set) var value: PersistedState
    private(set) var savedStates: [PersistedState] = []
    private(set) var attempts = 0
    private var failFromAttempt: Int?
    let targetID: UUID
    let events: ReauthEventLog
    init(_ state: PersistedState, targetID: UUID, events: ReauthEventLog) {
        value = state; self.targetID = targetID; self.events = events
    }
    func load() -> PersistedState { value }
    func fail(afterSuccessfulSaves count: Int) { failFromAttempt = attempts + count + 1 }
    func permitSaving() { failFromAttempt = nil }
    func save(_ state: PersistedState) async throws {
        attempts += 1
        if let failFromAttempt, attempts >= failFromAttempt { throw AgentSwapError.storage("Fixture state save failure") }
        value = state; savedStates.append(state)
        await events.append(state.requiresExplicitCredentialApplication?.contains(targetID) == true ? "state-fenced" : "state-unfenced")
    }
}

private actor ReauthControlledProvider: ProviderAdapter {
    nonisolated let provider: Provider
    private var native: ImportedAccount
    private var nativeAvailable = false
    private var pendingLogin: CheckedContinuation<ImportedAccount, any Error>?
    private var cancelResult: ImportedAccount?
    private var holdCompatibility = false
    private var compatibilityContinuation: CheckedContinuation<Void, Never>?
    private(set) var compatibilityIsBlocked = false
    private(set) var loginCount = 0
    private(set) var importCount = 0
    private(set) var cancelCount = 0
    private(set) var refreshCount = 0
    private(set) var independentRefreshCount = 0
    private(set) var activationCount = 0
    private(set) var usageTokens: [String] = []
    private var activation: SwitchResult = .applied(message: "Fixture explicit application")
    let vault: ReauthTestVault
    let events: ReauthEventLog
    init(_ native: ImportedAccount, vault: ReauthTestVault, events: ReauthEventLog) {
        self.native = native; provider = native.account.provider; self.vault = vault; self.events = events
    }
    func permitNative() { nativeAvailable = true }
    func currentNative() -> ImportedAccount { native }
    func clearCounts() { importCount = 0; activationCount = 0; refreshCount = 0; independentRefreshCount = 0; usageTokens.removeAll() }
    func setActivation(_ result: SwitchResult) { activation = result }
    func completeOnCancellation(_ result: ImportedAccount?) { cancelResult = result }
    func blockNextCompatibility() { holdCompatibility = true }
    func releaseCompatibility() { compatibilityContinuation?.resume(); compatibilityContinuation = nil }
    func compatibility() async -> CompatibilityStatus {
        if holdCompatibility {
            holdCompatibility = false; compatibilityIsBlocked = true
            await withCheckedContinuation { compatibilityContinuation = $0 }
            compatibilityIsBlocked = false
        }
        return .supported("Fixture provider")
    }
    func importCurrent() async throws -> ImportedAccount {
        importCount += 1
        await events.append("native-import")
        guard nativeAvailable else { throw AgentSwapError.network("Fixture startup native lookup unavailable") }
        return native
    }
    func login() async throws -> ImportedAccount {
        loginCount += 1
        await events.append("login")
        return try await withCheckedThrowingContinuation { pendingLogin = $0 }
    }
    func isWaitingForLogin() -> Bool { pendingLogin != nil }
    func completeLogin(_ result: ImportedAccount) { pendingLogin?.resume(returning: result); pendingLogin = nil }
    func cancelLogin() {
        cancelCount += 1
        if let cancelResult { pendingLogin?.resume(returning: cancelResult) }
        else { pendingLogin?.resume(throwing: AgentSwapError.cancelled) }
        pendingLogin = nil
    }
    func hasRunningConsumers() -> Bool { false }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { refreshCount += 1; return credential }
    func refreshIndependentCredential(_ credential: Credential, account: AccountRecord) throws -> Credential {
        independentRefreshCount += 1
        throw IndependentCredentialRefreshBlocked(message: "Fixture native owner remains unchanged")
    }
    func verifyCredential(_ credential: Credential, account: AccountRecord) throws -> Credential {
        if account.provider == .claude {
            guard credential.verifiedClaudeAccountIdentity == account.identity else { throw AgentSwapError.storage("Fixture unverified Claude credential") }
        } else {
            guard try ProviderAccountParser.codex(credential).account.identity == account.identity else { throw AgentSwapError.storage("Fixture wrong Codex identity") }
        }
        return credential
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) async -> UsageSnapshot {
        usageTokens.append(credential.accessToken)
        #expect(await vault.peek(account.id) == credential, "The exact fresh credential must be durably saved before usage")
        await events.append("usage:\(credential.accessToken)")
        return .init(windows: [.init(id: "five_hour", title: "5시간", usedPercent: 23)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) async -> SwitchResult {
        activationCount += 1
        await events.append("native-activate")
        if case .applied = activation { native = .init(account: account, credential: credential) }
        return activation
    }
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool,
                                 saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        do { try await saveLatest(native) }
        catch { return .failed(message: error.localizedDescription) }
        return await activate(credential, account: account, relaunch: relaunch)
    }
}

private struct ReauthTestFixture {
    let old: ImportedAccount
    let other: ImportedAccount
    let fresh: ImportedAccount
    let model: AppModel
    let adapter: ReauthControlledProvider
    let vault: ReauthTestVault
    let store: ReauthTestState
    let events: ReauthEventLog
    let baseline: PersistedState

    static func account(provider: Provider, token: String, user: String = "fixture-reauth-user", workspace: String = "fixture-reauth-workspace",
                        expired: Bool = false) throws -> ImportedAccount {
        let identity = AccountIdentity(provider: provider, userID: user, workspaceID: workspace)
        var credential: Credential
        if provider == .claude {
            credential = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
                "accessToken": token, "refreshToken": token + "-refresh", "expiresAt": Date().addingTimeInterval(expired ? -30 : 3600).timeIntervalSince1970 * 1000
            ]]), accountMetadata: ProviderJSON.data(["accountUuid": user, "organizationUuid": workspace, "emailAddress": "synthetic@example.com"]))
            credential = try credential.withVerifiedClaudeIdentity(identity)
            return try ProviderAccountParser.claude(credential)
        }
        let claims: [String: Any] = ["sub": user, "email": "synthetic@example.com", "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": workspace]]
        let encoded = try ProviderJSON.data(claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        credential = try CredentialParser.codex(rawAuth: ProviderJSON.data(["auth_mode": "chatgpt", "tokens": [
            "access_token": token, "refresh_token": token + "-refresh", "id_token": "fixture.\(encoded).signature", "account_id": workspace
        ]]))
        credential.expiresAt = Date().addingTimeInterval(expired ? -30 : 3600)
        return try ProviderAccountParser.codex(credential)
    }

    @MainActor static func make(_ provider: Provider = .claude, retry: UsageRetryReason? = nil, expiredFresh: Bool = false) async throws -> ReauthTestFixture {
        var old = try account(provider: provider, token: "fixture-old-login")
        old.account.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        old.account.nickname = "기존 별명"; old.account.automaticSwitchEligible = true
        old.account.authenticationState = .needsLogin
        let other = try account(provider: provider, token: "fixture-other-login", user: "fixture-reauth-other")
        let fresh = try account(provider: provider, token: "fixture-fresh-login", expired: expiredFresh)
        var state = PersistedState()
        state.accounts = [old.account, other.account]
        state.accountDisplayOrder = [other.account.id, old.account.id]
        state.activeAccounts[provider] = old.account.id
        state.pendingNativeRefreshPredecessor = [old.account.id: String(repeating: "a", count: 64)]
        state.lastSwitch[provider] = Date(timeIntervalSince1970: 1_700_000_100)
        for account in state.accounts {
            state.usage[account.id] = .init(snapshot: .init(fetchedAt: Date(timeIntervalSince1970: 1_700_000_200), windows: [
                .init(id: "five_hour", title: "5시간", usedPercent: 12)
            ]), attemptedAt: Date(), error: retry == nil ? nil : "Fixture previous lookup error",
            retryAfter: retry == nil ? nil : Date().addingTimeInterval(600), retryReason: retry)
        }
        let events = ReauthEventLog(), vault = ReauthTestVault(events: events)
        await vault.seed(old.credential, id: old.account.id); await vault.seed(other.credential, id: other.account.id)
        let store = ReauthTestState(state, targetID: old.account.id, events: events)
        let adapter = ReauthControlledProvider(old, vault: vault, events: events)
        let model = AppModel(adapters: [adapter], secrets: vault, store: store)
        await model.start(); model.stop()
        await adapter.permitNative(); await adapter.clearCounts(); await events.clear()
        return .init(old: old, other: other, fresh: fresh, model: model, adapter: adapter, vault: vault, store: store, events: events, baseline: model.state)
    }
}

@Suite("선택한 계정의 독립 재인증")
@MainActor
struct ReauthenticationTests {
    private func waitFor(_ message: String, until condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record(Comment(rawValue: message))
        throw AgentSwapError.storage("Fixture asynchronous checkpoint timed out")
    }
    private func begin(_ fixture: ReauthTestFixture) async throws {
        await fixture.model.reauthenticateAccount(fixture.old.account.id)
        try await waitFor("The selected-account login must start") { await fixture.adapter.isWaitingForLogin() }
        #expect(fixture.model.reauthenticatingAccountID == fixture.old.account.id)
    }
    private func finish(_ fixture: ReauthTestFixture, result: ImportedAccount? = nil, expectsUsage: Bool = false) async throws {
        await fixture.adapter.completeLogin(result ?? fixture.fresh)
        if expectsUsage { try await waitFor("A successful dedicated login must query only its saved grant") { await fixture.adapter.usageTokens.contains("fixture-fresh-login") } }
        try await waitFor("The dedicated login task must finish") { !fixture.model.isLoggingIn && !fixture.model.isBusy }
    }

    @Test("Another provider, user or workspace cannot replace the selected account", arguments: Provider.allCases, ["provider", "user", "workspace", "raw"])
    func wrongLoginIsRejected(_ provider: Provider, _ mismatch: String) async throws {
        let f = try await ReauthTestFixture.make(provider)
        var result = try ReauthTestFixture.account(provider: mismatch == "provider" ? (provider == .claude ? .codex : .claude) : provider,
            token: "fixture-wrong-login", user: mismatch == "user" ? "fixture-wrong-user" : f.old.account.identity.userID,
            workspace: mismatch == "workspace" ? "fixture-wrong-workspace" : f.old.account.identity.workspaceID)
        if mismatch == "raw" { result.credential.accessToken = "fixture-inconsistent-login" }
        try await begin(f)
        try await finish(f, result: result)
        #expect(f.model.state == f.baseline)
        #expect(await f.vault.peek(f.old.account.id) == f.old.credential)
        #expect(await f.store.value == f.baseline)
        #expect(await f.adapter.importCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.usageTokens.isEmpty)
    }

    @Test("A matching login preserves the latest preferences and order, fences before vault save, and saves before usage", arguments: Provider.allCases)
    func matchingLoginPreservesLatestRecord(_ provider: Provider) async throws {
        let f = try await ReauthTestFixture.make(provider)
        try await begin(f)
        await f.model.updateAccount(f.old.account.id, nickname: "새 별명", automaticSwitchEligible: false)
        let visible = f.model.displayAccounts.map(\.id)
        await f.model.moveAccounts(fromOffsets: IndexSet(integer: 1), toOffset: 0, visibleAccountIDs: visible)
        let chosenOrder = f.model.state.accountDisplayOrder
        try await finish(f, expectsUsage: true)
        let updated = try #require(f.model.state.accounts.first { $0.id == f.old.account.id })
        #expect(updated.id == f.old.account.id && updated.createdAt == f.old.account.createdAt)
        #expect(updated.identity == f.old.account.identity && updated.nickname == "새 별명")
        #expect(!updated.automaticSwitchEligible && updated.authenticationState == .valid)
        #expect(f.model.state.accounts.map(\.id) == f.baseline.accounts.map(\.id))
        #expect(f.model.state.accountDisplayOrder == chosenOrder)
        #expect(f.model.state.activeAccounts == f.baseline.activeAccounts)
        #expect(f.model.state.pendingNativeRefreshPredecessor == f.baseline.pendingNativeRefreshPredecessor)
        #expect(f.model.state.lastSwitch == f.baseline.lastSwitch)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(updated.id) == true)
        #expect(await f.vault.peek(updated.id) == f.fresh.credential)
        #expect(await f.adapter.importCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.usageTokens == ["fixture-fresh-login"])
        let events = await f.events.entries
        let fence = try #require(events.firstIndex(of: "state-fenced"))
        let saved = try #require(events.firstIndex(of: "vault-saved:fixture-fresh-login"))
        let usage = try #require(events.firstIndex(of: "usage:fixture-fresh-login"))
        #expect(fence < saved && saved < usage)
    }

    @Test("Reauthentication waits for server cooldowns and completed logins clear only local retry timers", arguments: [UsageRetryReason.localFailure, .serverRateLimit, .transientFailure])
    func retryPolicyIsPreserved(_ reason: UsageRetryReason) async throws {
        let f = try await ReauthTestFixture.make(retry: reason)
        if reason == .serverRateLimit {
            let saveCount = await f.store.attempts
            await f.model.reauthenticateAccount(f.old.account.id)
            #expect(await f.adapter.loginCount == 0)
            #expect(!f.model.isLoggingIn && f.model.reauthenticatingAccountID == nil)
            #expect(f.model.message?.contains("서버 요청 제한") == true)
            #expect(f.model.state == f.baseline)
            #expect(await f.vault.peek(f.old.account.id) == f.old.credential)
            #expect(await f.store.attempts == saveCount)
            #expect(await f.adapter.importCount == 0)
            #expect(await f.adapter.refreshCount == 0)
            #expect(await f.adapter.activationCount == 0)
            #expect(await f.adapter.usageTokens.isEmpty)
            return
        }
        try await begin(f)
        try await finish(f, expectsUsage: reason == .localFailure)
        let saved = try #require(await f.store.savedStates.first { $0.accounts.first?.authenticationState == .valid && $0.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true })
        let cache = try #require(saved.usage[f.old.account.id])
        let before = try #require(f.baseline.usage[f.old.account.id])
        #expect(cache.snapshot == before.snapshot && cache.error == before.error)
        if reason == .localFailure {
            #expect(cache.retryAfter == nil && cache.retryReason == nil && cache.attemptedAt == nil)
        } else {
            #expect(cache == before)
            #expect(await f.adapter.usageTokens.isEmpty)
        }
        #expect(await f.adapter.refreshCount == 0)
        #expect(await f.adapter.activationCount == 0)
    }

    @Test("Cancelling pending login preserves old credentials; a fresh response arriving during cancellation is still saved", arguments: [false, true])
    func cancellationOwnsReceivedCredential(_ returnsFresh: Bool) async throws {
        let f = try await ReauthTestFixture.make()
        try await begin(f)
        if returnsFresh { await f.adapter.completeOnCancellation(f.fresh) }
        await f.model.cancelLogin()
        #expect(!f.model.isLoggingIn && f.model.reauthenticatingAccountID == nil)
        #expect(await f.vault.peek(f.old.account.id) == (returnsFresh ? f.fresh.credential : f.old.credential))
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == (returnsFresh ? true : nil))
        #expect(await f.adapter.importCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.usageTokens.isEmpty)
    }

    @Test("Deleting a target queued ahead of its login prevents even starting the login")
    func deletedQueuedTargetNeverLogsIn() async throws {
        let f = try await ReauthTestFixture.make()
        await f.adapter.blockNextCompatibility()
        let blocking = Task { await f.model.recheckCompatibility(.claude) }
        try await waitFor("The provider queue must be occupied") { await f.adapter.compatibilityIsBlocked }
        var deletionStarted = false
        let deletion = Task { deletionStarted = true; await f.model.deleteAccount(f.old.account.id) }
        try await waitFor("The deletion must queue before login") { deletionStarted }
        await f.model.reauthenticateAccount(f.old.account.id)
        await f.adapter.releaseCompatibility()
        await blocking.value; await deletion.value
        try await waitFor("The obsolete queued login must finish") { !f.model.isLoggingIn && !f.model.isBusy }
        #expect(await f.adapter.loginCount == 0)
        #expect(await f.adapter.importCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(!f.model.state.accounts.contains { $0.id == f.old.account.id })
        #expect(await f.vault.peek(f.old.account.id) == nil)
    }

    @Test("A restart and normal poll cannot replace a fresh independent login with the old native grant", arguments: Provider.allCases)
    func restartPreservesIndependentGrant(_ provider: Provider) async throws {
        let f = try await ReauthTestFixture.make(provider)
        try await begin(f); try await finish(f, expectsUsage: true)
        await f.adapter.clearCounts()
        let restarted = AppModel(adapters: [f.adapter], secrets: f.vault, store: f.store)
        await restarted.start(); restarted.stop()
        await restarted.refreshAll()
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
        #expect(await f.adapter.currentNative().credential == f.old.credential)
        #expect(restarted.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.refreshCount == 0)
        #expect(await f.adapter.usageTokens.contains("fixture-fresh-login"))
    }

    @Test("Only an applied explicit same-account switch clears the independent-login fence", arguments: ["applied", "pending", "failed"])
    func explicitApplicationClearsOnlyOnSuccess(_ result: String) async throws {
        let f = try await ReauthTestFixture.make()
        try await begin(f); try await finish(f, expectsUsage: true)
        await f.adapter.clearCounts()
        await f.adapter.setActivation(result == "applied" ? .applied(message: "Fixture applied") : (result == "pending" ? .pendingRelaunch(message: "Fixture pending") : .failed(message: "Fixture failed")))
        await f.model.switchAccount(f.old.account.id)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == (result == "applied" ? false : true))
        #expect(await f.adapter.activationCount == 1)
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
    }

    @Test("An expired independent same-owner grant is never refreshed through the old native login")
    func expiredFlaggedManualSwitchDoesNotAdoptNative() async throws {
        let f = try await ReauthTestFixture.make(expiredFresh: true)
        try await begin(f); try await finish(f, expectsUsage: true)
        await f.adapter.clearCounts()
        await f.model.switchAccount(f.old.account.id)
        #expect(await f.adapter.refreshCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.independentRefreshCount == 1)
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true)
    }

    @Test("A flagged source cannot switch to another account before its independent login is explicitly resolved")
    func flaggedSourceCannotSwitchAway() async throws {
        let f = try await ReauthTestFixture.make()
        try await begin(f); try await finish(f, expectsUsage: true)
        await f.adapter.clearCounts()
        #expect(f.model.switchOperationBlockReason(for: f.other.account.id) != nil)
        await f.model.switchAccount(f.other.account.id)
        #expect(await f.adapter.refreshCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true)
    }

    @Test("Explicit current-login import clears the fence only after saving and verifying the chosen native grant")
    func explicitNativeImportRequiresDurableSave() async throws {
        let f = try await ReauthTestFixture.make()
        try await begin(f); try await finish(f, expectsUsage: true)
        await f.vault.fail("save")
        await f.model.importCurrent(.claude)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true)
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
        await f.vault.fail(nil)
        await f.model.importCurrent(.claude)
        #expect(f.model.state.requiresExplicitCredentialApplication?.contains(f.old.account.id) == false)
        #expect(await f.vault.peek(f.old.account.id) == f.old.credential)
        #expect(await f.adapter.activationCount == 0)
    }

    @Test("State, vault and readback failures retain the fresh login and retry persistence without logging in again", arguments: ["fenceState", "finalState", "save", "readback"])
    func failedPersistenceRetriesFreshLogin(_ failure: String) async throws {
        let f = try await ReauthTestFixture.make()
        if failure == "fenceState" { await f.store.fail(afterSuccessfulSaves: 0) }
        else if failure == "finalState" { await f.store.fail(afterSuccessfulSaves: 1) }
        else { await f.vault.fail(failure) }
        try await begin(f); try await finish(f)
        if failure == "fenceState" {
            #expect(await f.vault.peek(f.old.account.id) == f.old.credential)
            #expect(await f.store.value.requiresExplicitCredentialApplication?.contains(f.old.account.id) != true)
        }
        #expect(await f.adapter.usageTokens.isEmpty)
        #expect(!(await f.model.prepareForTermination()))
        f.model.stop()
        await f.store.permitSaving(); await f.vault.fail(nil)
        #expect(await f.model.prepareForTermination())
        #expect(await f.vault.peek(f.old.account.id) == f.fresh.credential)
        #expect(await f.store.value.requiresExplicitCredentialApplication?.contains(f.old.account.id) == true)
        #expect(await f.adapter.loginCount == 1)
        #expect(await f.adapter.refreshCount == 0)
        #expect(await f.adapter.activationCount == 0)
        #expect(await f.adapter.usageTokens.isEmpty)
    }
}
