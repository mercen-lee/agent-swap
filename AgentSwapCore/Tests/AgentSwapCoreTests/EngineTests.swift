import Foundation
import Testing
@testable import AgentSwapCore

actor MemorySecrets: SecretStore {
    var values: [UUID: Credential] = [:]
    func load(accountID: UUID) -> Credential? { values[accountID] }
    func save(_ credential: Credential, accountID: UUID) { values[accountID] = credential }
    func delete(accountID: UUID) { values.removeValue(forKey: accountID) }
}
actor MemoryState: StateStore {
    var value: PersistedState
    init(_ value: PersistedState = .init()) { self.value = value }
    func load() -> PersistedState { value }
    func save(_ state: PersistedState) { value = state }
}
actor FakeProvider: ProviderAdapter {
    nonisolated let provider: Provider
    var imported: ImportedAccount
    var usageError: AgentSwapError?
    var activation: SwitchResult = .applied(message: "완료")
    var running = false
    var refreshCount = 0
    var overlap = 0
    var maxOverlap = 0
    var startRunningOnRefresh = false
    var loginResult: ImportedAccount?
    var currentAfterLogin: ImportedAccount?
    var activationCount = 0
    var refreshTokens: [String] = []
    var currentBeforeNextBackup: ImportedAccount?
    var compatibilityStatus: CompatibilityStatus = .supported("fixture")
    var compatibilityChecks = 0
    var compatibilityModes: [KeychainInteractionMode] = []
    init(_ imported: ImportedAccount) { self.imported = imported; provider = imported.account.provider }
    func compatibility() -> CompatibilityStatus {
        compatibilityChecks += 1
        compatibilityModes.append(KeychainInteraction.mode)
        return compatibilityStatus
    }
    func importCurrent() -> ImportedAccount { imported }
    func login() -> ImportedAccount {
        let result = loginResult ?? imported
        if let currentAfterLogin { imported = currentAfterLogin }
        return result
    }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) async -> Credential {
        refreshCount += 1; refreshTokens.append(credential.accessToken)
        var next = credential; next.accessToken = "rotated"; next.rawAuth = Data("fixture-rotated".utf8); next.expiresAt = Date().addingTimeInterval(3600)
        if startRunningOnRefresh { running = true; activation = .pendingRelaunch(message: "새 프로세스 실행") }
        return next
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot {
        overlap += 1; maxOverlap = max(maxOverlap, overlap)
        try await Task.sleep(for: .milliseconds(5)); overlap -= 1
        if let usageError { throw usageError }
        return .init(windows: [.init(id: "short", title: "5시간", usedPercent: 30)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activationCount += 1
        if case .applied = activation { imported = .init(account: account, credential: credential) }
        return activation
    }
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool,
                                  saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        if let currentBeforeNextBackup { imported = currentBeforeNextBackup; self.currentBeforeNextBackup = nil }
        do {
            try await saveLatest(imported)
            return activate(credential, account: account, relaunch: relaunch)
        } catch { return .failed(message: error.localizedDescription) }
    }
    func hasRunningConsumers() -> Bool { running }
    func setError(_ error: AgentSwapError?) { usageError = error }
    func setActivation(_ value: SwitchResult) { activation = value }
    func setRunning(_ value: Bool) { running = value }
    func setCurrent(_ value: ImportedAccount) { imported = value }
    func setStartRunningOnRefresh(_ value: Bool = true) { startRunningOnRefresh = value }
    func setLogin(_ value: ImportedAccount, currentAfterLogin: ImportedAccount? = nil) {
        loginResult = value; self.currentAfterLogin = currentAfterLogin
    }
    func setCurrentBeforeBackup(_ value: ImportedAccount) { currentBeforeNextBackup = value }
    func setCompatibility(_ value: CompatibilityStatus) { compatibilityStatus = value }
}

@Suite("공유 엔진") @MainActor
struct EngineTests {
    func setup(expired: Bool = false, provider: Provider = .codex) async -> (AppModel, FakeProvider, MemorySecrets, UUID) {
        let account = AccountRecord(identity: .init(provider: provider, userID: "fixture-user", workspaceID: "fixture-workspace"))
        let credential = Credential(accessToken: "fixture", expiresAt: Date().addingTimeInterval(expired ? -10 : 3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: account, credential: credential))
        let vault = MemorySecrets(); await vault.save(credential, accountID: account.id)
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState())
        await model.importCurrent(provider)
        return (model, adapter, vault, account.id)
    }
    @Test func duplicateImportRetainsIdentityAndPreferences() async {
        let (model, _, _, id) = await setup()
        await model.updateAccount(id, nickname: "팀", automaticSwitchEligible: true)
        await model.importCurrent(.codex)
        #expect(model.state.accounts.count == 1)
        #expect(model.state.accounts.first?.id == id)
        #expect(model.state.accounts.first?.nickname == "팀")
        #expect(model.state.accounts.first?.automaticSwitchEligible == true)
    }
    @Test func failedFetchRetainsLastGoodSnapshot() async {
        let (model, adapter, _, id) = await setup()
        let old = model.state.usage[id]?.snapshot
        await adapter.setError(.network("오프라인")); await model.refreshAll()
        #expect(model.state.usage[id]?.snapshot == old)
        #expect(model.state.usage[id]?.error == "오프라인")
        #expect(model.state.usage[id]?.snapshot?.minimumRemaining == 70)
    }
    @Test func retryAfterBlocksForcedFetch() async {
        let (model, adapter, _, id) = await setup()
        let retry = Date().addingTimeInterval(100)
        await adapter.setError(.rateLimited(retry)); await model.refreshAll()
        let attempted = model.state.usage[id]?.attemptedAt
        await model.refreshAll()
        #expect(model.state.usage[id]?.retryAfter == retry)
        #expect(model.state.usage[id]?.attemptedAt == attempted)
    }
    @Test func rotatedTokenSavedBeforeFailingFetch() async {
        let (model, adapter, vault, id) = await setup(expired: true)
        await adapter.setError(.network("오프라인")); await model.refreshAll()
        #expect(await vault.load(accountID: id)?.accessToken == "rotated")
    }
    @Test func pendingDoesNotChangeActiveAccountOrCooldown() async {
        let (model, adapter, _, id) = await setup()
        await adapter.setActivation(.pendingRelaunch(message: "실행 중")); await model.switchAccount(id)
        #expect(model.pendingSwitch[.codex] == id)
        #expect(model.state.lastSwitch[.codex] == nil)
    }
    @Test func providerQueueSerializesAcrossSuspensions() async {
        let (model, adapter, _, _) = await setup()
        async let first: Void = model.refreshAll()
        async let second: Void = model.refreshAll()
        _ = await (first, second)
        #expect(await adapter.maxOverlap == 1)
    }
    @Test func settingsEnforceMinimumSafetyMargins() async {
        let (model, _, _, _) = await setup(); var settings = AppSettings()
        settings.activePollInterval = 0; settings.automation[.codex]?.cooldown = 0
        settings.automation[.codex]?.minimumImprovement = 0
        await model.updateSettings(settings)
        #expect(model.state.settings.activePollInterval == 30)
        #expect(model.state.settings.automation[.codex]?.cooldown == 300)
        #expect(model.state.settings.automation[.codex]?.minimumImprovement == 5)
    }
    @Test func runningActiveCodexDoesNotRotateTokens() async {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "running", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture-expired", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data())
        let provider = FakeProvider(.init(account: account, credential: credential)); await provider.setRunning(true)
        let model = AppModel(adapters: [provider], secrets: MemorySecrets(), store: MemoryState())
        await model.importCurrent(.codex)
        #expect(await provider.refreshCount == 0)
        #expect(model.state.activeAccounts[.codex] == account.id)
    }
    @Test func externalAccountChangeDoesNotReactivateOldAccount() async {
        let (model, provider, _, id) = await setup()
        let other = AccountRecord(identity: .init(provider: .codex, userID: "other", workspaceID: "workspace"))
        await provider.setCurrent(.init(account: other, credential: .init(accessToken: "external", rawAuth: Data())))
        await model.refreshAll()
        #expect(model.state.activeAccounts[.codex] == nil)
        #expect(model.state.accounts.first?.id == id)
        #expect(model.state.accounts.count == 1)
    }
    @Test func nativeRefreshRacePreservesSuccessorAcrossPollAndRestart() async {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "race", workspaceID: "workspace"))
        let original = Credential(accessToken: "old", refreshToken: "fixture-old", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data("fixture-original".utf8))
        let provider = FakeProvider(.init(account: account, credential: original)); await provider.setStartRunningOnRefresh()
        let vault = MemorySecrets(), store = MemoryState()
        let model = AppModel(adapters: [provider], secrets: vault, store: store)
        await model.importCurrent(.codex)
        #expect(await vault.load(accountID: account.id)?.accessToken == "rotated")
        #expect(model.pendingSwitch[.codex] == account.id)
        await model.refreshDue(force: true, now: Date().addingTimeInterval(61))
        #expect(await vault.load(accountID: account.id)?.accessToken == "rotated")
        #expect(await provider.refreshCount == 1)
        let restarted = AppModel(adapters: [provider], secrets: vault, store: store)
        await restarted.start(); restarted.stop()
        #expect(await vault.load(accountID: account.id)?.accessToken == "rotated")
        #expect(restarted.pendingSwitch[.codex] == account.id)
        #expect(restarted.state.pendingNativeRefreshPredecessor?[account.id] != nil)
    }

    @Test("A near-expired pending successor preserves the earliest native predecessor")
    func pendingSuccessorCanRefreshAgainBeforeApplying() async throws {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "pending", workspaceID: "workspace"))
        let original = Credential(accessToken: "old", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data("fixture-original".utf8))
        let provider = FakeProvider(.init(account: account, credential: original)); await provider.setStartRunningOnRefresh()
        let vault = MemorySecrets(), model = AppModel(adapters: [provider], secrets: vault, store: MemoryState())
        await model.importCurrent(.codex)
        let predecessor = model.state.pendingNativeRefreshPredecessor?[account.id]
        var pending = try #require(await vault.load(accountID: account.id)); pending.expiresAt = Date().addingTimeInterval(-10)
        await vault.save(pending, accountID: account.id)
        await provider.setRunning(false); await provider.setStartRunningOnRefresh(false); await provider.setActivation(.applied(message: "적용"))
        await model.switchAccount(account.id)
        #expect(predecessor != nil)
        #expect(await provider.refreshTokens == ["old", "rotated"])
        #expect(await provider.importCurrent().credential.accessToken == "rotated")
        #expect(model.state.pendingNativeRefreshPredecessor?[account.id] == nil)
        #expect(model.pendingSwitch[.codex] == nil)
    }

    @Test("A missing pending vault never silently resurrects its consumed native predecessor")
    func missingPendingVaultRequiresExplicitImport() async {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "missing-successor", workspaceID: "workspace"))
        let original = Credential(accessToken: "old-native", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("fixture-native-predecessor".utf8))
        var state = PersistedState(); state.accounts = [account]; state.activeAccounts[.codex] = account.id
        state.pendingNativeRefreshPredecessor = [account.id: "fixture-predecessor-digest"]
        let adapter = FakeProvider(.init(account: account, credential: original)), vault = MemorySecrets()
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start(); model.stop()
        #expect(await vault.load(accountID: account.id) == nil)
        #expect(await adapter.refreshCount == 0)
        await model.importCurrent(.codex)
        #expect(await vault.load(accountID: account.id)?.accessToken == "old-native")
        #expect(model.state.pendingNativeRefreshPredecessor?[account.id] == nil)
    }

    @Test("Duplicate GUI login replaces the saved auth and applies the same current identity", arguments: Provider.allCases)
    func duplicateGUIAuthenticationAppliesFreshCredential(provider: Provider) async throws {
        let (model, adapter, vault, id) = await setup(provider: provider)
        await model.updateAccount(id, nickname: "등록 별명", automaticSwitchEligible: true)
        var account = await adapter.importCurrent().account; account.id = UUID(); account.email = "fixture@example.invalid"
        let fresh = Credential(accessToken: "fresh-gui-login", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("fixture-fresh-login".utf8))
        await adapter.setLogin(.init(account: account, credential: fresh))
        try await finishLogin(model, provider: provider)
        #expect(await vault.load(accountID: id)?.accessToken == "fresh-gui-login")
        #expect(await adapter.importCurrent().credential.accessToken == "fresh-gui-login")
        #expect(model.state.accounts.count == 1)
        #expect(model.state.accounts.first?.id == id)
        #expect(model.state.accounts.first?.nickname == "등록 별명")
        #expect(model.state.accounts.first?.automaticSwitchEligible == true)
        #expect(model.state.pendingNativeRefreshPredecessor?[id] == nil)
        #expect(model.pendingSwitch[provider] == nil)
    }

    @Test("A fresh isolated login replaces a pending vault without being mistaken for native auth")
    func pendingDuplicateCodexLoginSurvivesRestart() async throws {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "duplicate-pending", workspaceID: "workspace"))
        let old = Credential(accessToken: "old", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data("fixture-native-old".utf8))
        let provider = FakeProvider(.init(account: account, credential: old)); await provider.setStartRunningOnRefresh()
        let vault = MemorySecrets(), store = MemoryState()
        // Use the same durable state store when reconstructing the application.
        let persistedModel = AppModel(adapters: [provider], secrets: vault, store: store)
        await persistedModel.importCurrent(.codex)
        let predecessor = persistedModel.state.pendingNativeRefreshPredecessor?[account.id]
        let fresh = Credential(accessToken: "fresh-gui-login", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("fixture-isolated-fresh".utf8))
        await provider.setLogin(.init(account: account, credential: fresh))
        try await finishLogin(persistedModel, provider: .codex)
        #expect(await vault.load(accountID: account.id)?.accessToken == "fresh-gui-login")
        #expect(await provider.importCurrent().credential.accessToken == "old")
        #expect(persistedModel.state.pendingNativeRefreshPredecessor?[account.id] == predecessor)
        #expect(persistedModel.pendingSwitch[.codex] == account.id)
        let restarted = AppModel(adapters: [provider], secrets: vault, store: store)
        await restarted.start(); restarted.stop(); persistedModel.stop()
        #expect(await vault.load(accountID: account.id)?.accessToken == "fresh-gui-login")
        #expect(restarted.state.pendingNativeRefreshPredecessor?[account.id] == predecessor)
        #expect(restarted.pendingSwitch[.codex] == account.id)
    }

    @Test("GUI login never reactivates an account externally changed during the browser flow", arguments: Provider.allCases)
    func externalNativeChangeDuringLoginIsPreserved(provider: Provider) async throws {
        let (model, adapter, vault, id) = await setup(provider: provider)
        let account = await adapter.importCurrent().account
        let external = AccountRecord(identity: .init(provider: provider, userID: "external-user", workspaceID: "external-workspace"))
        let native = ImportedAccount(account: external, credential: .init(accessToken: "external-current", rawAuth: Data("fixture-external-native".utf8)))
        let fresh = Credential(accessToken: "fresh-gui-login", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("fixture-fresh".utf8))
        let activationsBefore = await adapter.activationCount
        await adapter.setLogin(.init(account: account, credential: fresh), currentAfterLogin: native)
        try await finishLogin(model, provider: provider)
        #expect(await vault.load(accountID: id)?.accessToken == "fresh-gui-login")
        #expect(await adapter.importCurrent().account.identity == external.identity)
        #expect(await adapter.activationCount == activationsBefore)
        #expect(model.state.activeAccounts[provider] == nil)
        #expect(model.state.pendingNativeRefreshPredecessor?[id] == nil)
    }

    @Test("A late external account change blocks applying a duplicate login", arguments: Provider.allCases)
    func externalChangeBeforeLoginApplicationIsPreserved(provider: Provider) async throws {
        let (model, adapter, vault, id) = await setup(provider: provider)
        let account = await adapter.importCurrent().account
        let external = AccountRecord(identity: .init(provider: provider, userID: "late-external", workspaceID: "external-workspace"))
        let native = ImportedAccount(account: external, credential: .init(accessToken: "external-current", rawAuth: Data("fixture-late-external".utf8)))
        let fresh = Credential(accessToken: "fresh-gui-login", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("fixture-late-login".utf8))
        let activationsBefore = await adapter.activationCount
        await adapter.setLogin(.init(account: account, credential: fresh))
        await adapter.setCurrentBeforeBackup(native)
        try await finishLogin(model, provider: provider)
        #expect(await vault.load(accountID: id)?.accessToken == "fresh-gui-login")
        #expect(await adapter.importCurrent().account.identity == external.identity)
        #expect(await adapter.activationCount == activationsBefore)
        #expect(model.state.activeAccounts[provider] == nil)
        #expect(model.state.pendingNativeRefreshPredecessor?[id] != nil)
    }

    private func finishLogin(_ model: AppModel, provider: Provider) async throws {
        await model.login(provider)
        for _ in 0..<200 {
            if !model.isLoggingIn && !model.isBusy { await model.refreshAll(); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Fixture GUI login did not finish")
    }
}
