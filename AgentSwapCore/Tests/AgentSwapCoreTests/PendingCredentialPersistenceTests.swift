import Foundation
import CryptoKit
import Testing
@testable import AgentSwapCore

private enum RotationTrigger: CaseIterable, Sendable { case expiry, unauthorized }
private enum ClaudeNativeMatch: CaseIterable, Sendable { case sameGrant, distinctGrant, differentIdentity }

private actor RotationState: StateStore {
    private var state: PersistedState
    private var denied = false
    private(set) var saveAttempts = 0
    init(_ state: PersistedState) { self.state = state }
    func load() -> PersistedState { state }
    func save(_ value: PersistedState) throws {
        saveAttempts += 1
        guard !denied else { throw AgentSwapError.storage("Fixture metadata write denied") }
        state = value
    }
    func denyWrites(_ value: Bool) { denied = value }
}

private actor RotationPause {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { suspended = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}

private actor RotationVault: SecretStore {
    private var values: [UUID: Credential]
    private var denySuccessor = true
    private var denyDeletion = false
    private var postWriteFailure = false
    private var simulatedRecoveryCredential: Credential?
    private(set) var savedTokens: [String] = []
    private(set) var loadedInteractions: [Bool] = []
    init(_ values: [UUID: Credential]) { self.values = values }
    func load(accountID: UUID) -> Credential? {
        loadedInteractions.append(KeychainInteraction.mode == .interactive)
        return values[accountID]
    }
    func save(_ credential: Credential, accountID: UUID) throws {
        savedTokens.append(credential.accessToken)
        if denySuccessor, credential.accessToken == "fixture-successor" {
            if postWriteFailure { values[accountID] = credential }
            throw AgentSwapError.storage("Fixture vault denied")
        }
        values[accountID] = credential
    }
    func delete(accountID: UUID) throws {
        if denyDeletion { throw AgentSwapError.storage("Fixture deletion denied") }
        values.removeValue(forKey: accountID)
    }
    func allowSuccessor() { denySuccessor = false }
    func setDenyDeletion(_ value: Bool) { denyDeletion = value }
    func failAfterWrite() { postWriteFailure = true }
    func saveRecovery(_ credential: Credential) throws {
        if denySuccessor { throw AgentSwapError.storage("Fixture recovery save denied") }
        simulatedRecoveryCredential = credential
    }
    func token(_ id: UUID) -> String? { values[id]?.accessToken }
    func credential(_ id: UUID) -> Credential? { values[id] }
    func expire(_ id: UUID) {
        guard var credential = values[id] else { return }
        credential.expiresAt = Date().addingTimeInterval(-10); values[id] = credential
    }
    func resetObservations() { savedTokens.removeAll(); loadedInteractions.removeAll() }
}

private actor RotationProvider: ProviderAdapter {
    nonisolated let provider: Provider
    private var native: ImportedAccount
    private let vault: RotationVault
    private let unauthorized: Bool
    private var retainInBackend = false
    private var backend: ImportedAccount?
    private var durableBackend: ImportedAccount?
    private var backendWasActive = false
    private var backendPredecessor: String?
    private var receipts: [PersistedCredentialGeneration] = []
    private var freshLogin: ImportedAccount?
    private var importPause: RotationPause?
    private var running = false
    private var successorToken = "fixture-successor"
    private(set) var refreshTokens: [String] = []
    private(set) var usageTokens: [String] = []
    private(set) var activatedTokens: [String] = []
    private(set) var discarded: [UUID] = []
    private(set) var backendFlushes = 0

    init(_ native: ImportedAccount, vault: RotationVault, unauthorized: Bool) {
        self.native = native; provider = native.account.provider; self.vault = vault; self.unauthorized = unauthorized
    }
    func compatibility() -> CompatibilityStatus {
        durableBackend == nil ? .supported("Fixture") : .readOnly("Fixture 복원 필요")
    }
    func importCurrent() async throws -> ImportedAccount {
        await importPause?.pause()
        guard durableBackend == nil else { throw AgentSwapError.storage("Fixture journal recovery needed") }
        return native
    }
    func login() -> ImportedAccount { freshLogin ?? native }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) throws -> Credential {
        guard durableBackend == nil else { throw AgentSwapError.storage("Fixture journal recovery needed") }
        refreshTokens.append(credential.accessToken)
        let successor = Credential(accessToken: successorToken, refreshToken: successorToken + "-refresh",
                                   expiresAt: Date().addingTimeInterval(86_400), rawAuth: Data((successorToken + "-auth").utf8))
        if retainInBackend {
            backend = .init(account: account, credential: successor)
            backendWasActive = account.identity == native.account.identity
            backendPredecessor = Self.digest(credential.rawAuth)
            throw AgentSwapError.storage("Fixture backend first save denied")
        }
        return successor
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) throws -> UsageSnapshot {
        usageTokens.append(credential.accessToken)
        if unauthorized, credential.accessToken == "fixture-original" { throw AgentSwapError.authentication("Fixture 401") }
        return .init(windows: [.init(id: "common", title: "Fixture", usedPercent: 20)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activatedTokens.append(credential.accessToken); native = .init(account: account, credential: credential)
        return .applied(message: "Fixture applied")
    }
    func hasRunningConsumers() -> Bool { running }
    func hasPendingCredentialPersistence() async -> Bool { backend != nil }
    func flushPendingCredentialPersistence() async throws {
        guard let backend else { return }
        backendFlushes += 1
        if backendWasActive {
            try await vault.saveRecovery(backend.credential)
            durableBackend = backend
        } else {
            try await vault.save(backend.credential, accountID: backend.account.id)
            if let predecessor = backendPredecessor {
                receipts.append(.init(accountID: backend.account.id, predecessorDigest: predecessor, successorDigest: Self.digest(backend.credential.rawAuth)))
            }
        }
        self.backend = nil
    }
    func recoverInterruptedSwitch() async throws {
        guard let durableBackend else { return }
        try await vault.save(durableBackend.credential, accountID: durableBackend.account.id)
        native = durableBackend; self.durableBackend = nil
    }
    func discardPendingCredentialPersistence(accountID: UUID) async {
        discarded.append(accountID)
        if backend?.account.id == accountID { backend = nil }
        receipts.removeAll { $0.accountID == accountID }
    }
    func takePersistedCredentialGenerations() async -> [PersistedCredentialGeneration] {
        let result = receipts; receipts.removeAll(); return result
    }
    func retainRefreshInBackend() { retainInBackend = true }
    func setFreshLogin(_ value: ImportedAccount) { freshLogin = value }
    func pauseImport(_ value: RotationPause) { importPause = value }
    func setRunning(_ value: Bool) { running = value }
    func setNativeCredential(_ credential: Credential) { native.credential = credential }
    func setNative(_ value: ImportedAccount) { native = value }
    func setSuccessorToken(_ value: String) { successorToken = value }
    func nativeToken() -> String { native.credential.accessToken }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@Suite("갱신 인증 저장 실패 보존") @MainActor
struct PendingCredentialPersistenceTests {
    private struct Fixture {
        let model: AppModel
        let vault: RotationVault
        let adapter: RotationProvider
        let store: RotationState
        let selected: AccountRecord
        let now: Date
    }

    private func fixture(provider: Provider = .claude, trigger: RotationTrigger = .expiry, inactive: Bool = false) async -> Fixture {
        let now = Date()
        let source = AccountRecord(identity: .init(provider: provider, userID: "source", workspaceID: "workspace"))
        let selected = inactive ? AccountRecord(identity: .init(provider: provider, userID: "target", workspaceID: "workspace")) : source
        let original = Credential(accessToken: "fixture-original", refreshToken: "fixture-original-refresh",
                                  expiresAt: now.addingTimeInterval(trigger == .expiry ? -10 : 86_400), rawAuth: Data("fixture-original-auth".utf8))
        let sourceAuth = inactive ? Credential(accessToken: "fixture-source", expiresAt: now.addingTimeInterval(86_400), rawAuth: Data("fixture-source-auth".utf8)) : original
        var state = PersistedState(); state.accounts = inactive ? [source, selected] : [source]
        state.activeAccounts[provider] = source.id
        for account in state.accounts {
            state.usage[account.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "Fixture", usedPercent: 45)]),
                                           attemptedAt: now, retryAfter: now.addingTimeInterval(120))
        }
        var credentials = [source.id: sourceAuth]; credentials[selected.id] = original
        let vault = RotationVault(credentials)
        let adapter = RotationProvider(.init(account: source, credential: sourceAuth), vault: vault, unauthorized: trigger == .unauthorized)
        let store = RotationState(state), model = AppModel(adapters: [adapter], secrets: vault, store: store)
        await model.start(); model.stop(); await vault.resetObservations()
        return .init(model: model, vault: vault, adapter: adapter, store: store, selected: selected, now: now)
    }

    @Test("Expiry and 401 retry the successor save before any further grant exchange", arguments: Provider.allCases, RotationTrigger.allCases)
    fileprivate func refreshFirstSaveFailure(provider: Provider, trigger: RotationTrigger) async throws {
        let fixture = await fixture(provider: provider, trigger: trigger)
        let cached = fixture.model.state.usage[fixture.selected.id]?.snapshot
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-original")
        #expect(fixture.model.state.usage[fixture.selected.id]?.snapshot == cached)
        #expect(fixture.model.state.usage[fixture.selected.id]?.error?.contains("메모리") == true)
        let attempts = await fixture.adapter.usageTokens
        #expect(attempts == (trigger == .unauthorized ? ["fixture-original"] : []))
        let metadata = try JSONEncoder().encode(fixture.model.state)
        #expect(!String(decoding: metadata, as: UTF8.self).contains("fixture-successor"))
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(182))
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.usageTokens == attempts)
        await fixture.vault.allowSuccessor()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(243))
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.usageTokens.last == "fixture-successor")
        #expect(fixture.model.state.usage[fixture.selected.id]?.error == nil)
        #expect(fixture.model.state.accounts.first?.authenticationState == .valid)
        #expect(fixture.model.state.activeAccounts[provider] == fixture.selected.id)
    }

    @Test("An expired manual switch retains its successor before activation")
    func switchFirstSaveFailure() async {
        let fixture = await fixture(provider: .codex, inactive: true)
        let source = fixture.model.state.activeAccounts[.codex]
        await fixture.model.switchAccount(fixture.selected.id)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        #expect(fixture.model.state.activeAccounts[.codex] == source)
        await fixture.vault.allowSuccessor()
        await fixture.model.switchAccount(fixture.selected.id)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.activatedTokens == ["fixture-successor"])
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(fixture.model.state.activeAccounts[.codex] == fixture.selected.id)
    }

    @Test("Read-only permission approval does not flush or exchange a retained successor")
    func approvalRemainsReadOnly() async {
        let fixture = await fixture()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        await fixture.vault.resetObservations()
        let before = fixture.model.state
        await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(await fixture.vault.savedTokens.isEmpty)
        #expect(await fixture.vault.loadedInteractions == [true])
        #expect(fixture.model.state == before)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        await fixture.vault.allowSuccessor()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(182))
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.refreshTokens.count == 1)
    }

    @Test("Quit is refused while a successor is undurable and succeeds after saving it")
    func quitPreservesMemoryUntilDurable() async {
        let fixture = await fixture()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        let before = fixture.model.state, usage = await fixture.adapter.usageTokens
        #expect(await fixture.model.prepareForTermination() == false)
        #expect(fixture.model.message?.contains("종료를 보류") == true)
        #expect(fixture.model.state.accounts == before.accounts)
        #expect(fixture.model.state.activeAccounts == before.activeAccounts)
        #expect(fixture.model.state.usage == before.usage)
        #expect(fixture.model.state.settings == before.settings)
        #expect(!fixture.model.isBusy)
        await fixture.vault.allowSuccessor()
        #expect(await fixture.model.prepareForTermination())
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.refreshTokens.count == 1)
        #expect(await fixture.adapter.usageTokens == usage)
        #expect(fixture.model.state.accounts == before.accounts)
        #expect(fixture.model.state.activeAccounts == before.activeAccounts)
        #expect(fixture.model.state.usage == before.usage)
        #expect(fixture.model.state.settings == before.settings)
        #expect(fixture.model.state.pendingNativeRefreshPredecessor?[fixture.selected.id] != nil)
        #expect(!fixture.model.isBusy)
    }

    @Test("Backend-retained successors are flushed before reads and protect quit too")
    func backendRetentionIsCoordinated() async {
        let fixture = await fixture()
        await fixture.adapter.retainRefreshInBackend()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.adapter.hasPendingCredentialPersistence())
        #expect(await fixture.model.prepareForTermination() == false)
        #expect(await fixture.adapter.refreshTokens.count == 1)
        await fixture.vault.allowSuccessor()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(182))
        #expect(!(await fixture.adapter.hasPendingCredentialPersistence()))
        #expect(await fixture.adapter.backendFlushes == 2)
        #expect(await fixture.adapter.refreshTokens.count == 1)
        #expect(fixture.model.compatibility[.claude]?.canWrite == false)
        #expect(fixture.model.compatibility[.claude]?.message.contains("복원") == true)
        #expect(await fixture.adapter.usageTokens.isEmpty)
        await fixture.model.recoverInterruptedSwitch(.claude)
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(243))
        #expect(await fixture.adapter.usageTokens == ["fixture-successor"])
        #expect(await fixture.adapter.refreshTokens.count == 1)
        #expect(await fixture.model.prepareForTermination())
    }

    @Test("A saved Codex successor still exposes pending relaunch while new consumers run")
    func codexConsumerStartsBeforeRetry() async {
        let fixture = await fixture(provider: .codex)
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        await fixture.adapter.setRunning(true)
        await fixture.vault.allowSuccessor()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(182))
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.refreshTokens.count == 1)
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        #expect(fixture.model.pendingSwitch[.codex] == fixture.selected.id)
        #expect(fixture.model.state.pendingNativeRefreshPredecessor?[fixture.selected.id] != nil)
        #expect(await fixture.adapter.usageTokens == ["fixture-successor"])
        #expect(await fixture.model.prepareForTermination())
    }

    @Test("An ambiguous write that saved bytes still retains the successor until verification")
    func postWriteFailureRetainsSuccessor() async {
        let fixture = await fixture()
        await fixture.vault.failAfterWrite()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.model.prepareForTermination() == false)
        #expect(await fixture.adapter.refreshTokens.count == 1)
        await fixture.vault.allowSuccessor()
        #expect(await fixture.model.prepareForTermination())
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.refreshTokens.count == 1)
    }

    @Test("Recognizing a later native generation retires the temporary predecessor guard")
    func laterNativeGenerationRetiresGuard() async {
        let fixture = await fixture()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        await fixture.vault.allowSuccessor()
        let third = Credential(accessToken: "fixture-third", expiresAt: Date().addingTimeInterval(86_400), rawAuth: Data("fixture-third-auth".utf8))
        await fixture.adapter.setNativeCredential(third)
        await fixture.model.importCurrent(.claude)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-third")
        let original = Credential(accessToken: "fixture-original", expiresAt: Date().addingTimeInterval(86_400), rawAuth: Data("fixture-original-auth".utf8))
        await fixture.adapter.setNativeCredential(original)
        await fixture.model.importCurrent(.claude)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-original")
        #expect(fixture.model.message?.contains("가져왔습니다") == true)
        #expect(await fixture.adapter.refreshTokens.count == 1)
    }

    @Test("A completed inactive backend receipt protects its successor before native import", arguments: [false, true])
    func inactiveBackendReceiptProtectsSuccessor(alreadyFlushed: Bool) async throws {
        let fixture = await fixture(inactive: true)
        await fixture.adapter.retainRefreshInBackend()
        await fixture.model.switchAccount(fixture.selected.id)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        await fixture.vault.allowSuccessor()
        if alreadyFlushed { try await fixture.adapter.flushPendingCredentialPersistence() }
        let stale = Credential(accessToken: "fixture-original", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data("fixture-original-auth".utf8))
        await fixture.adapter.setNative(.init(account: fixture.selected, credential: stale))
        await fixture.model.importCurrent(.claude)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(fixture.model.state.activeAccounts[.claude] == fixture.selected.id)
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.usageTokens.last == "fixture-successor")
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
    }

    @Test("A failed inactive save survives normal quit and restart before native recollection", arguments: [false, true])
    func inactiveSuccessorSurvivesRestart(backendOwned: Bool) async {
        let provider: Provider = backendOwned ? .claude : .codex
        let fixture = await fixture(provider: provider, inactive: true)
        if backendOwned { await fixture.adapter.retainRefreshInBackend() }
        await fixture.model.switchAccount(fixture.selected.id)
        await fixture.vault.allowSuccessor()
        let source = fixture.model.state.activeAccounts[provider]
        #expect(await fixture.model.prepareForTermination())
        #expect(fixture.model.state.activeAccounts[provider] == source)
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        let stale = Credential(accessToken: "fixture-original", expiresAt: Date().addingTimeInterval(-10), rawAuth: Data("fixture-original-auth".utf8))
        await fixture.adapter.setNative(.init(account: fixture.selected, credential: stale))
        let restarted = AppModel(adapters: [fixture.adapter], secrets: fixture.vault, store: fixture.store)
        await restarted.start(); restarted.stop()
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(restarted.pendingSwitch[provider] == fixture.selected.id)
        #expect(restarted.state.pendingNativeRefreshPredecessor?[fixture.selected.id] != nil)
        await restarted.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.activatedTokens == ["fixture-successor"])
        #expect(await fixture.adapter.nativeToken() == "fixture-successor")
        #expect(restarted.state.pendingNativeRefreshPredecessor?[fixture.selected.id] == nil)
    }

    @Test("A failed metadata fence remains retryable after its receipt is consumed")
    func metadataFailureRefusesQuitUntilFenceIsDurable() async {
        let fixture = await fixture(inactive: true)
        await fixture.adapter.retainRefreshInBackend()
        await fixture.model.switchAccount(fixture.selected.id)
        await fixture.vault.allowSuccessor(); await fixture.store.denyWrites(true)
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.model.prepareForTermination() == false)
        #expect(fixture.model.message?.contains("복구 상태") == true)
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        await fixture.store.denyWrites(false)
        #expect(await fixture.model.prepareForTermination())
        let saved = await fixture.store.load()
        #expect(saved.pendingNativeRefreshPredecessor?[fixture.selected.id] != nil)
        #expect(await fixture.adapter.activatedTokens.isEmpty)
    }

    @Test("Loaded saved auth remains readable after a metadata failure while its successor is unsaved")
    func metadataFailureDoesNotBlockReadOnlyAuthorization() async {
        let fixture = await fixture()
        await fixture.store.denyWrites(true)
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        let before = fixture.model.state, metadataAttempts = await fixture.store.saveAttempts
        #expect(fixture.model.message?.contains("저장 실패") == true)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-original")
        await fixture.vault.resetObservations()
        await fixture.model.authorizeSavedCredential(fixture.selected.id)
        #expect(await fixture.vault.loadedInteractions == [true])
        #expect(await fixture.vault.savedTokens.isEmpty)
        #expect(await fixture.store.saveAttempts == metadataAttempts)
        #expect(fixture.model.state == before)
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        #expect(fixture.model.message?.contains("접근할 수 있습니다") == true)
        await fixture.vault.allowSuccessor(); await fixture.store.denyWrites(false)
        #expect(await fixture.model.prepareForTermination())
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
        #expect(await fixture.adapter.refreshTokens == ["fixture-original"])
        #expect(await fixture.adapter.activatedTokens.isEmpty)
    }

    @Test("Chained inactive rotations keep the earliest native predecessor and newest successor")
    func chainedInactiveReceiptsPreserveEarliestPredecessor() async {
        let fixture = await fixture(inactive: true)
        await fixture.adapter.retainRefreshInBackend()
        await fixture.model.switchAccount(fixture.selected.id)
        await fixture.vault.allowSuccessor()
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(121))
        let earliest = fixture.model.state.pendingNativeRefreshPredecessor?[fixture.selected.id]
        #expect(earliest != nil)
        await fixture.vault.expire(fixture.selected.id)
        await fixture.adapter.setSuccessorToken("fixture-successor-2")
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(182))
        await fixture.model.refreshDue(force: true, now: fixture.now.addingTimeInterval(243))
        #expect(fixture.model.state.pendingNativeRefreshPredecessor?[fixture.selected.id] == earliest)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor-2")
        #expect(await fixture.adapter.refreshTokens == ["fixture-original", "fixture-successor"])
        #expect(await fixture.adapter.nativeToken() == "fixture-source")
        #expect(await fixture.adapter.activatedTokens.isEmpty)
        #expect(await fixture.model.prepareForTermination())
    }

    @Test("Claude canonical auth preserves native shared fields only for the same parsed account and grant", arguments: ClaudeNativeMatch.allCases)
    fileprivate func canonicalClaudeGrantReconciliation(match: ClaudeNativeMatch) async throws {
        let account = AccountRecord(identity: .init(provider: .claude, userID: "canonical-user", workspaceID: "canonical-workspace"))
        let metadata = try ProviderJSON.data(["accountUuid": account.identity.userID, "organizationUuid": account.identity.workspaceID])
        let vaultMetadata = try ProviderJSON.data(["accountUuid": match == .differentIdentity ? "other-user" : account.identity.userID,
                                                  "organizationUuid": account.identity.workspaceID])
        let vaultObject: [String: Any] = ["claudeAiOauth": ["accessToken": "fixture-successor", "refreshToken": "fixture-successor-refresh", "expiresAt": 1_900_000_000_000],
                                          "pluginSecrets": ["fixture": "이전 값"]]
        let nativeToken = match == .distinctGrant ? "fixture-third" : "fixture-successor"
        let nativeObject: [String: Any] = ["claudeAiOauth": ["accessToken": nativeToken, "refreshToken": nativeToken + "-refresh", "expiresAt": 1_900_000_000_000],
                                           "pluginSecrets": ["fixture": "새 값"]]
        let successor = try CredentialParser.claude(rawAuth: ProviderJSON.data(vaultObject), accountMetadata: vaultMetadata)
        let native = try CredentialParser.claude(rawAuth: claudeCLIAuthData(nativeObject), accountMetadata: metadata)
        let vault = RotationVault([account.id: successor]); await vault.allowSuccessor()
        let adapter = RotationProvider(.init(account: account, credential: native), vault: vault, unauthorized: false)
        let originalDigest = SHA256.hash(data: Data("fixture-original-auth".utf8)).map { String(format: "%02x", $0) }.joined()
        var state = PersistedState(); state.accounts = [account]; state.activeAccounts[.claude] = account.id
        state.pendingNativeRefreshPredecessor = [account.id: originalDigest]
        state.usage[account.id] = .init(attemptedAt: Date(), retryAfter: Date().addingTimeInterval(120))
        let model = AppModel(adapters: [adapter], secrets: vault, store: RotationState(state))
        await model.start(); model.stop()
        if match == .sameGrant {
            #expect(await vault.credential(account.id)?.rawAuth == native.rawAuth)
            #expect(model.state.pendingNativeRefreshPredecessor?[account.id] == nil)
            #expect(model.pendingSwitch[.claude] == nil)
        } else {
            #expect(await vault.credential(account.id)?.rawAuth == successor.rawAuth)
            #expect(model.state.pendingNativeRefreshPredecessor?[account.id] == originalDigest)
            #expect(model.pendingSwitch[.claude] == account.id)
        }
        #expect(await adapter.refreshTokens.isEmpty)
        #expect(await adapter.activatedTokens.isEmpty)
    }

    @Test("Only a confirmed account deletion discards its retained credential", arguments: [false, true])
    func confirmedDeletionDiscardsMemory(succeeds: Bool) async {
        let fixture = await fixture(inactive: true)
        await fixture.model.switchAccount(fixture.selected.id)
        await fixture.vault.setDenyDeletion(!succeeds)
        await fixture.model.deleteAccount(fixture.selected.id)
        if succeeds {
            #expect(!fixture.model.state.accounts.contains { $0.id == fixture.selected.id })
            #expect(await fixture.adapter.discarded == [fixture.selected.id])
            #expect(await fixture.model.prepareForTermination())
        } else {
            #expect(fixture.model.state.accounts.contains { $0.id == fixture.selected.id })
            #expect(await fixture.adapter.discarded.isEmpty)
            #expect(await fixture.model.prepareForTermination() == false)
            fixture.model.stop()
            await fixture.vault.allowSuccessor()
            await fixture.model.switchAccount(fixture.selected.id)
            #expect(await fixture.vault.token(fixture.selected.id) == "fixture-successor")
            #expect(await fixture.adapter.refreshTokens.count == 1)
        }
    }

    @Test("A durably saved fresh login supersedes the same account's retained rotation")
    func freshLoginSupersedesOnlyAfterSave() async throws {
        let fixture = await fixture(inactive: true)
        await fixture.model.switchAccount(fixture.selected.id)
        let fresh = Credential(accessToken: "fixture-fresh-login", expiresAt: Date().addingTimeInterval(86_400), rawAuth: Data("fixture-fresh-login-auth".utf8))
        await fixture.adapter.setFreshLogin(.init(account: fixture.selected, credential: fresh))
        await fixture.model.login(.claude)
        for _ in 0..<1_000 where fixture.model.isLoggingIn { await Task.yield() }
        try #require(!fixture.model.isLoggingIn)
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-fresh-login")
        #expect(await fixture.adapter.discarded == [fixture.selected.id])
        #expect(await fixture.model.prepareForTermination())
        #expect(await fixture.vault.token(fixture.selected.id) == "fixture-fresh-login")
        #expect(await fixture.adapter.refreshTokens.count == 1)
    }

    @Test("Quit drains a startup spanning both provider queues without holding its next queue", .timeLimit(.minutes(1)))
    func terminationWaitsForStartup() async {
        let now = Date(), pause = RotationPause()
        let claude = AccountRecord(identity: .init(provider: .claude, userID: "startup-claude", workspaceID: "workspace"))
        let codex = AccountRecord(identity: .init(provider: .codex, userID: "startup-codex", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture-original", expiresAt: now.addingTimeInterval(86_400), rawAuth: Data("fixture-original-auth".utf8))
        let vault = RotationVault([claude.id: credential, codex.id: credential])
        let claudeProvider = RotationProvider(.init(account: claude, credential: credential), vault: vault, unauthorized: false)
        let codexProvider = RotationProvider(.init(account: codex, credential: credential), vault: vault, unauthorized: false)
        await claudeProvider.pauseImport(pause)
        var state = PersistedState(); state.accounts = [claude, codex]
        state.activeAccounts = [.claude: claude.id, .codex: codex.id]
        let model = AppModel(adapters: [claudeProvider, codexProvider], secrets: vault, store: MemoryState(state))
        let starting = Task { await model.start() }
        await pause.waitUntilEntered()
        let quitting = Task { await model.prepareForTermination() }
        await Task.yield()
        #expect(model.isBusy)
        await pause.release()
        await starting.value
        #expect(await quitting.value)
        #expect(!model.isBusy)
        #expect(await claudeProvider.refreshTokens.isEmpty)
        #expect(await codexProvider.refreshTokens.isEmpty)
        await model.refreshAll()
        #expect(await claudeProvider.usageTokens.isEmpty)
        #expect(await codexProvider.usageTokens.isEmpty)
    }
}
