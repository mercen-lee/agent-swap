import Foundation
import Testing
@testable import AgentSwapCore

private actor SavedAccessEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor SavedAccessPause {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var suspended: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !released else { return }
        entered = true
        observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { suspended = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        suspended?.resume(); suspended = nil
    }
}

private enum SavedAccessFailure: CaseIterable, Sendable { case missing, denied }
private struct SavedAccessRead: Equatable, Sendable {
    let id: UUID
    let interactive: Bool
}

private actor SavedAccessVault: SecretStore {
    private var credentials: [UUID: Credential]
    private var failure: SavedAccessFailure?
    private(set) var reads: [SavedAccessRead] = []
    private(set) var mutations = 0
    private let events: SavedAccessEvents

    init(credentials: [UUID: Credential], events: SavedAccessEvents) {
        self.credentials = credentials; self.events = events
    }
    func load(accountID: UUID) async throws -> Credential? {
        let interactive = KeychainInteraction.mode == .interactive
        reads.append(.init(id: accountID, interactive: interactive))
        if interactive { await events.append("interactive-read") }
        switch failure {
        case .missing: return nil
        case .denied: throw AgentSwapError.storage("Fixture permission denied")
        case nil: return credentials[accountID]
        }
    }
    func save(_ credential: Credential, accountID: UUID) {
        mutations += 1; credentials[accountID] = credential
    }
    func delete(accountID: UUID) { mutations += 1; credentials.removeValue(forKey: accountID) }
    func fail(_ value: SavedAccessFailure?) { failure = value }
    func resetObservations() { reads.removeAll(); mutations = 0 }
}

private actor SavedAccessState: StateStore {
    private var value: PersistedState
    private(set) var writes = 0
    init(_ value: PersistedState) { self.value = value }
    func load() -> PersistedState { value }
    func save(_ state: PersistedState) { value = state; writes += 1 }
    func resetObservations() { writes = 0 }
}

private actor SavedAccessProvider: ProviderAdapter {
    nonisolated let provider: Provider
    private(set) var calls: [String] = []
    private var fetchPause: SavedAccessPause?
    private var nativeCurrent: ImportedAccount?
    private let events: SavedAccessEvents

    init(provider: Provider, events: SavedAccessEvents) { self.provider = provider; self.events = events }
    func compatibility() -> CompatibilityStatus { calls.append("compatibility"); return .supported("Fixture") }
    func importCurrent() throws -> ImportedAccount {
        calls.append("import")
        if let nativeCurrent { return nativeCurrent }
        // Permission errors at startup preserve the cached current account. No native auth is used.
        throw AgentSwapError.storage("Fixture native credentials unavailable")
    }
    func login() throws -> ImportedAccount { calls.append("login"); throw AgentSwapError.cancelled }
    func cancelLogin() { calls.append("cancel") }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        calls.append("refresh"); return credential
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) async -> UsageSnapshot {
        calls.append("usage")
        await events.append("fetch-begin")
        await fetchPause?.pause()
        await events.append("fetch-end")
        return .init(windows: [.init(id: "common", title: "Fixture", usedPercent: 50)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        calls.append("activate")
        return .pendingRelaunch(message: "Fixture pending relaunch")
    }
    func hasRunningConsumers() -> Bool { calls.append("consumers"); return false }
    func resetObservations() { calls.removeAll() }
    func pauseFetch(_ pause: SavedAccessPause) { fetchPause = pause }
    func setNativeCurrent(_ current: ImportedAccount) { nativeCurrent = current }
}

@Suite("선택한 저장 인증 접근") @MainActor
struct CoreSavedCredentialAccessTests {
    private struct Fixture {
        let model: AppModel
        let provider: SavedAccessProvider
        let vault: SavedAccessVault
        let store: SavedAccessState
        let events: SavedAccessEvents
        let source: AccountRecord
        let selected: AccountRecord
    }

    private func fixture(provider: Provider = .claude, active: Bool = true, healthy: Bool = false,
                         retryReason: UsageRetryReason? = nil) async -> Fixture {
        let source = AccountRecord(identity: .init(provider: provider, userID: "source", workspaceID: "workspace"), automaticSwitchEligible: true)
        let selected = AccountRecord(identity: .init(provider: provider, userID: "selected", workspaceID: "workspace"),
                                     nickname: "Saved account", automaticSwitchEligible: true, authenticationState: healthy ? .valid : .expired)
        var state = PersistedState(); state.accounts = [source, selected]
        if active { state.activeAccounts[provider] = source.id }
        let now = Date()
        for (account, percent) in [(source, 95.0), (selected, 10.0)] {
            state.usage[account.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "Fixture", usedPercent: percent)]),
                                           attemptedAt: now, error: healthy ? nil : "Fixture cached permission error",
                                           retryAfter: now.addingTimeInterval(120), retryReason: retryReason)
        }
        state.lastSwitch[provider] = now.addingTimeInterval(-600)
        let events = SavedAccessEvents(), adapter = SavedAccessProvider(provider: provider, events: events)
        let credential = Credential(accessToken: "fixture-secret", expiresAt: now.addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let vault = SavedAccessVault(credentials: [source.id: credential, selected.id: credential], events: events)
        let store = SavedAccessState(state), model = AppModel(adapters: [adapter], secrets: vault, store: store)
        await model.start(); model.stop()
        await adapter.resetObservations(); await vault.resetObservations(); await store.resetObservations()
        return .init(model: model, provider: adapter, vault: vault, store: store, events: events, source: source, selected: selected)
    }

    @Test("Only the chosen saved credential is read interactively and unknown legacy retry delays remain", arguments: Provider.allCases)
    func selectedReadOnly(provider: Provider) async {
        let fixture = await fixture(provider: provider), before = fixture.model.state
        let outerMode = KeychainInteraction.mode
        let approved = await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(approved)
        #expect(await fixture.vault.reads == [.init(id: fixture.selected.id, interactive: true)])
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.store.writes == 0)
        #expect(fixture.model.state == before)
        #expect(fixture.model.state.usage[fixture.selected.id]?.error != nil)
        #expect(fixture.model.message?.contains("기존 재시도 대기는 유지") == true)
        #expect(!fixture.model.isBusy)
        #expect(KeychainInteraction.mode == outerMode)
    }

    @Test("Approval clears only the selected account's local retry delay without querying or switching", arguments: Provider.allCases)
    func approvalClearsSelectedLocalDelay(provider: Provider) async {
        let fixture = await fixture(provider: provider, retryReason: .localFailure)
        var settings = fixture.model.state.settings; settings.automation[provider]?.enabled = true
        await fixture.model.updateSettings(settings)
        await fixture.store.resetObservations()
        let before = fixture.model.state

        await fixture.model.authorizeSavedCredential(fixture.selected.id)

        var expected = before
        expected.usage[fixture.selected.id]?.retryAfter = nil
        expected.usage[fixture.selected.id]?.retryReason = nil
        expected.usage[fixture.selected.id]?.attemptedAt = nil
        #expect(fixture.model.state == expected)
        #expect(await fixture.vault.reads == [.init(id: fixture.selected.id, interactive: true)])
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.store.writes == 1)
        #expect(await fixture.store.load() == expected)
        #expect(fixture.model.message?.contains("재시도 대기를 해제") == true)
        #expect(fixture.model.pendingSwitch.isEmpty)
    }

    @Test("Approval never clears server or unrelated transient retry delays", arguments: [UsageRetryReason.serverRateLimit, .transientFailure])
    func approvalPreservesUnrelatedDelay(reason: UsageRetryReason) async {
        let fixture = await fixture(retryReason: reason), before = fixture.model.state
        await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(fixture.model.state == before)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.store.writes == 0)
        if reason == .serverRateLimit {
            #expect(fixture.model.message?.contains("서버가 지정한 재시도 시각") == true)
        } else {
            #expect(fixture.model.message?.contains("기존 재시도 대기는 유지") == true)
        }
    }

    @Test("A genuine local access failure becomes eligible for the next normal poll after approval")
    func localFailureRetriesWithoutWaitingForPollInterval() async throws {
        let fixture = await fixture()
        await fixture.vault.fail(.denied)
        await fixture.model.refreshDue(force: true, now: Date().addingTimeInterval(121))
        #expect(fixture.model.state.usage[fixture.selected.id]?.retryReason == .localFailure)
        #expect(fixture.model.state.usage[fixture.selected.id]?.retryAfter != nil)
        let snapshot = fixture.model.state.usage[fixture.selected.id]?.snapshot
        await fixture.vault.fail(nil)
        await fixture.provider.resetObservations(); await fixture.vault.resetObservations()

        await fixture.model.authorizeSavedCredential(fixture.selected.id)

        #expect(await fixture.provider.calls.isEmpty)
        #expect(fixture.model.state.usage[fixture.selected.id]?.snapshot == snapshot)
        #expect(fixture.model.state.usage[fixture.selected.id]?.error == "Fixture permission denied")
        // A regular scheduler poll must be eligible immediately; no forced refresh is needed.
        await fixture.model.refreshDue()
        #expect(await fixture.provider.calls.filter { $0 == "usage" }.count == 1)
        let refreshed = try #require(fixture.model.state.usage[fixture.selected.id])
        #expect(refreshed.error == nil)
        #expect(refreshed.retryAfter == nil)
        #expect(refreshed.retryReason == nil)
        #expect(refreshed.attemptedAt != nil)
    }

    @Test("Legacy persisted cache without a retry reason decodes without reclassifying its delay")
    func legacyCacheKeepsUnknownDelay() throws {
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let oldCache = UsageCache(attemptedAt: deadline.addingTimeInterval(-120), error: "Fixture cached error", retryAfter: deadline)
        let encoded = try JSONEncoder().encode(oldCache)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["retryReason"] == nil)
        let decoded = try JSONDecoder().decode(UsageCache.self, from: encoded)
        #expect(decoded == oldCache)
        #expect(decoded.retryAfter == deadline)
        #expect(decoded.retryReason == nil)
    }

    @Test("Missing or denied saved auth preserves all account and pending state", arguments: SavedAccessFailure.allCases)
    fileprivate func failedAccessDoesNotChangeState(failure: SavedAccessFailure) async throws {
        let fixture = await fixture(provider: .codex, retryReason: .localFailure)
        // Establish a readable source for the switch itself. Startup's permission-denied
        // fixture must not authorize applying auth without a current source backup.
        let sourceCredential = try #require(try await fixture.vault.load(accountID: fixture.source.id))
        await fixture.provider.setNativeCurrent(.init(account: fixture.source, credential: sourceCredential))
        await fixture.model.switchAccount(fixture.selected.id)
        let before = fixture.model.state, pending = fixture.model.pendingSwitch, attention = fixture.model.attentionProviders
        #expect(pending[.codex] == fixture.selected.id)
        await fixture.provider.resetObservations(); await fixture.vault.resetObservations(); await fixture.store.resetObservations()
        await fixture.vault.fail(failure)
        let approved = await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(!approved)
        #expect(await fixture.vault.reads == [.init(id: fixture.selected.id, interactive: true)])
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.store.writes == 0)
        #expect(fixture.model.state == before)
        #expect(fixture.model.pendingSwitch == pending)
        #expect(fixture.model.attentionProviders == attention)
        #expect(fixture.model.message != nil)
        #expect(!fixture.model.isBusy)
    }

    @Test("Permission approval never evaluates an otherwise eligible automatic switch")
    func approvalNeverAutomaticallySwitches() async {
        let fixture = await fixture(healthy: true)
        var settings = fixture.model.state.settings; settings.automation[.claude]?.enabled = true
        await fixture.model.updateSettings(settings)
        let before = fixture.model.state
        #expect(AutomaticSwitchPolicy.decide(provider: .claude, state: before) == .switchTo(fixture.selected.id))
        await fixture.store.resetObservations()
        await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(fixture.model.state == before)
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.source.id)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.store.writes == 0)
    }

    @Test("Saved auth approval waits for an ongoing refresh of the same provider")
    func approvalUsesProviderOperationQueue() async throws {
        let fixture = await fixture(active: false), pause = SavedAccessPause()
        await fixture.provider.pauseFetch(pause)
        // Make the fixture cache eligible for the actual refresh path without OS/network calls.
        let future = Date().addingTimeInterval(121)
        let refreshing = Task { await fixture.model.refreshDue(force: true, now: future) }
        await pause.waitUntilEntered()
        #expect(fixture.model.isBusy)
        let approving = Task { await fixture.model.authorizeSavedCredential(fixture.selected.id) }
        await Task.yield()
        #expect(await fixture.vault.reads.filter(\.interactive).isEmpty)
        await pause.release()
        #expect(await approving.value); await refreshing.value
        let events = await fixture.events.values
        let finished = try #require(events.firstIndex(of: "fetch-end"))
        let approved = try #require(events.firstIndex(of: "interactive-read"))
        #expect(approved > finished)
        #expect(await fixture.vault.reads.filter(\.interactive) == [.init(id: fixture.selected.id, interactive: true)])
        #expect(await fixture.vault.mutations == 0)
        #expect(!fixture.model.isBusy)
    }

    @Test("Unknown and already cancelled requests perform no credential I/O")
    func invalidRequestsReleaseWithoutIO() async {
        let fixture = await fixture(), before = fixture.model.state
        await fixture.model.authorizeSavedCredential(UUID())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.model.authorizeSavedCredential(fixture.selected.id)
        }
        await cancelled.value
        #expect(await fixture.vault.reads.isEmpty)
        #expect(await fixture.vault.mutations == 0)
        #expect(await fixture.provider.calls.isEmpty)
        #expect(fixture.model.state == before)
        #expect(!fixture.model.isBusy)
        // A cancelled request must release the provider queue for the next user action.
        await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(await fixture.vault.reads == [.init(id: fixture.selected.id, interactive: true)])
    }
}
