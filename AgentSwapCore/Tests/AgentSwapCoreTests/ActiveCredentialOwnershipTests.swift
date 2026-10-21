import Foundation
import Testing
@testable import AgentSwapCore

private actor OwnershipProvider: ProviderAdapter {
    nonisolated let provider = Provider.codex
    var current: ImportedAccount?
    var importError: AgentSwapError?
    var running = true
    var usageError: AgentSwapError?
    var rotatedDuringUsage: ImportedAccount?
    var refreshCount = 0
    var activationCount = 0
    var usageTokens: [String] = []

    init(_ current: ImportedAccount?) { self.current = current }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrentIfPresent() throws -> ImportedAccount? {
        if let importError { throw importError }
        return current
    }
    func importCurrent() throws -> ImportedAccount {
        guard let current = try importCurrentIfPresent() else { throw AgentSwapError.authentication("fixture native auth absent") }
        return current
    }
    func login() throws -> ImportedAccount { try importCurrent() }
    func cancelLogin() {}
    func hasRunningConsumers() -> Bool { running }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        refreshCount += 1
        return .init(accessToken: "refreshed-\(credential.accessToken)", refreshToken: "fixture-successor",
                     expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("refreshed-\(credential.accessToken)".utf8))
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) throws -> UsageSnapshot {
        usageTokens.append(credential.accessToken)
        if let rotatedDuringUsage {
            current = rotatedDuringUsage
            self.rotatedDuringUsage = nil
            throw AgentSwapError.authentication("fixture stale access token")
        }
        if let usageError { throw usageError }
        return .init(windows: [.init(id: "short", title: "5시간", usedPercent: 30)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activationCount += 1
        current = .init(account: account, credential: credential)
        return .applied(message: "fixture")
    }
    func setCurrent(_ value: ImportedAccount?) { current = value }
    func setImportError(_ value: AgentSwapError?) { importError = value }
    func setRunning(_ value: Bool) { running = value }
    func setUsageError(_ value: AgentSwapError?) { usageError = value }
    func setRotationDuringUsage(_ value: ImportedAccount) { rotatedDuringUsage = value }
}

@Suite("Codex native credential ownership") @MainActor
struct ActiveCredentialOwnershipTests {
    private func account(_ name: String) -> AccountRecord {
        .init(identity: .init(provider: .codex, userID: name, workspaceID: "fixture-workspace"))
    }
    private func credential(_ name: String, expired: Bool = false) -> Credential {
        .init(accessToken: name, refreshToken: "fixture-refresh-\(name)",
              expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), rawAuth: Data(name.utf8))
    }
    private func model(accounts: [AccountRecord], current: ImportedAccount?, active: UUID? = nil) async -> (AppModel, OwnershipProvider, MemorySecrets) {
        var state = PersistedState(); state.accounts = accounts; state.activeAccounts[.codex] = active
        let vault = MemorySecrets()
        for account in accounts { await vault.save(credential(account.identity.userID), accountID: account.id) }
        let provider = OwnershipProvider(current)
        let model = AppModel(adapters: [provider], secrets: vault, store: MemoryState(state))
        await model.start(); model.stop()
        return (model, provider, vault)
    }

    @Test("External account changes cannot refresh a running Codex grant using stale active metadata", arguments: [false, true])
    func staleActiveAccountDoesNotOwnRefresh(cachedActiveUnknown: Bool) async {
        let target = account("first-row"), previous = account("previous"), external = account("unregistered")
        let startup = cachedActiveUnknown ? external : previous
        let (model, provider, vault) = await model(accounts: [target, previous],
                                                  current: .init(account: startup, credential: credential(startup.identity.userID)),
                                                  active: cachedActiveUnknown ? nil : previous.id)
        let expired = credential("target-current", expired: true)
        await vault.save(expired, accountID: target.id)
        await provider.setCurrent(.init(account: target, credential: expired))
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(model.state.activeAccounts[.codex] == target.id)
        #expect(await vault.load(accountID: target.id)?.accessToken == "target-current")
        #expect(model.state.accounts.first?.authenticationState == .valid)
    }

    @Test("An external active change is applied after safe refresh when Codex has stopped")
    func stoppedConsumerRefreshAppliesToFreshNativeIdentity() async {
        let target = account("first-row"), previous = account("previous")
        let (model, provider, vault) = await model(accounts: [target, previous],
                                                  current: .init(account: previous, credential: credential("previous")), active: previous.id)
        let expired = credential("target-current", expired: true)
        await vault.save(expired, accountID: target.id)
        await provider.setCurrent(.init(account: target, credential: expired))
        await provider.setRunning(false)
        await model.refreshAll()
        #expect(await provider.refreshCount == 1)
        #expect(await provider.current?.credential.accessToken == "refreshed-target-current")
        #expect(model.state.activeAccounts[.codex] == target.id)
        #expect(model.state.pendingNativeRefreshPredecessor?[target.id] == nil)
    }

    @Test("A running Codex 401 retains authenticated state and the last successful usage")
    func consumerOwned401DoesNotDeclareLogout() async {
        let account = account("current")
        let (model, provider, _) = await model(accounts: [account], current: .init(account: account, credential: credential("current")))
        await model.refreshAll()
        let snapshot = model.state.usage[account.id]?.snapshot
        await provider.setUsageError(.authentication("fixture stale token"))
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(model.state.usage[account.id]?.snapshot == snapshot)
        #expect(model.state.usage[account.id]?.retryAfter != nil)
        #expect(model.state.usage[account.id]?.error?.contains("Codex") == true)
    }

    @Test("A 401 racing with Codex rotation retries the new native token without refreshing")
    func consumerRotationDuringFetchRetriesSuccessor() async {
        let account = account("current")
        let (model, provider, vault) = await model(accounts: [account], current: .init(account: account, credential: credential("old")))
        await provider.setRotationDuringUsage(.init(account: account, credential: credential("native-successor")))
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(await provider.usageTokens == ["old", "native-successor"])
        #expect(await vault.load(accountID: account.id)?.accessToken == "native-successor")
        #expect(model.state.usage[account.id]?.error == nil)
        #expect(model.state.accounts.first?.authenticationState == .valid)
    }

    @Test("Absent native auth permits usage reads while running consumers keep refresh ownership")
    func absentNativeAuthDoesNotBlockReadOrConsumeLiveGrant() async {
        let account = account("saved")
        let (model, provider, vault) = await model(accounts: [account], current: nil)
        await vault.save(credential("saved", expired: true), accountID: account.id)
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(model.state.usage[account.id]?.snapshot != nil)
        #expect(model.state.activeAccounts[.codex] == nil)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        await provider.setRunning(false)
        await model.refreshAll()
        #expect(await provider.refreshCount == 1)
    }

    @Test("Unreadable native auth blocks rotation without changing saved authentication state")
    func nativeReadFailureIsNotLogout() async {
        let account = account("saved")
        let (model, provider, vault) = await model(accounts: [account], current: .init(account: account, credential: credential("saved")))
        await vault.save(credential("saved", expired: true), accountID: account.id)
        await provider.setImportError(.authentication("fixture unreadable native identity"))
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(model.state.usage[account.id]?.retryAfter != nil)
    }

    @Test("The default activation boundary cannot bypass a failed native backup read")
    func defaultActivationPropagatesNativeReadFailure() async {
        let account = account("saved")
        let provider = OwnershipProvider(.init(account: account, credential: credential("saved")))
        await provider.setImportError(.storage("fixture locked native auth"))
        let result = await provider.activatePreservingSource(credential("target"), account: account, relaunch: false) { _ in
            Issue.record("A failed source read must not invoke backup")
        }
        guard case .failed = result else { Issue.record("A failed source read must block activation"); return }
        #expect(await provider.activationCount == 0)
        #expect(await provider.current?.credential.accessToken == "saved")
    }

    @Test("A provider permission failure preserves usage and never refreshes a valid grant")
    func permissionFailureDoesNotConsumeRefreshGrant() async {
        let account = account("saved")
        let (model, provider, _) = await model(accounts: [account], current: nil)
        await provider.setRunning(false)
        await model.refreshAll()
        let snapshot = model.state.usage[account.id]?.snapshot
        await provider.setUsageError(.network("fixture HTTP 403 permission rejected"))
        await model.refreshAll()
        #expect(await provider.refreshCount == 0)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(model.state.usage[account.id]?.snapshot == snapshot)
    }
}
