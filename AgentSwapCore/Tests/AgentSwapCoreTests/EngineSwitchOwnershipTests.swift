import Foundation
import Testing
@testable import AgentSwapCore

private actor SwitchLookupProvider: ProviderAdapter {
    nonisolated let provider = Provider.codex
    let original: ImportedAccount
    private var lookupError: AgentSwapError?
    private(set) var refreshCount = 0
    private(set) var activationCount = 0

    init(_ original: ImportedAccount) { self.original = original }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount {
        if let lookupError { throw lookupError }
        return original
    }
    func login() throws -> ImportedAccount { throw AgentSwapError.cancelled }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential {
        refreshCount += 1
        var next = credential
        next.accessToken = "fixture-rotated"
        next.expiresAt = .now.addingTimeInterval(3_600)
        return next
    }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot {
        .init(windows: [.init(id: "fixture", title: "5시간", usedPercent: 20)])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        activationCount += 1
        return .applied(message: "fixture")
    }
    func hasRunningConsumers() -> Bool { false }
    func failLookup(_ error: AgentSwapError) { lookupError = error }
}

@Suite("Switch refresh ownership after an external native account change") @MainActor
struct EngineSwitchOwnershipTests {
    @Test("A native lookup error blocks a switch before consuming a saved refresh grant", arguments: [false, true])
    func unreadableNativeStopsBeforeRefresh(authenticationError: Bool) async {
        let account = AccountRecord(identity: .init(provider: .codex, userID: "fixture-user", workspaceID: "fixture-workspace"))
        let initial = credential("fixture-initial")
        let adapter = SwitchLookupProvider(.init(account: account, credential: initial))
        let vault = MemorySecrets()
        await vault.save(initial, accountID: account.id)
        var state = PersistedState()
        state.accounts = [account]
        state.activeAccounts[.codex] = account.id
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        let expired = credential("fixture-expired", expired: true)
        await vault.save(expired, accountID: account.id)
        await adapter.failLookup(authenticationError ? .authentication("fixture malformed native auth") : .storage("fixture read denied"))

        await model.switchAccount(account.id)

        #expect(await adapter.refreshCount == 0)
        #expect(await adapter.activationCount == 0)
        #expect(await vault.load(accountID: account.id) == expired)
        #expect(model.state.lastSwitch[.codex] == nil)
    }

    @Test("Switching to the actual running Codex account never rotates its token using a stale active-account cache")
    func runningNativeTargetOwnsRefresh() async throws {
        let fixture = await setup()
        let expired = credential("fixture-native-b", expired: true)
        await fixture.vault.save(expired, accountID: fixture.second.id)
        await fixture.adapter.setCurrent(.init(account: fixture.second, credential: expired))
        await fixture.adapter.setRunning(true)
        #expect(fixture.model.state.activeAccounts[.codex] == fixture.first.id)
        let before = await fixture.adapter.refreshCount

        await fixture.model.switchAccount(fixture.second.id)

        #expect(await fixture.adapter.refreshCount == before)
        #expect(await fixture.vault.load(accountID: fixture.second.id)?.accessToken == expired.accessToken)
        #expect(fixture.model.state.activeAccounts[.codex] == fixture.second.id)
    }

    @Test("A stale active-account cache does not prevent refreshing the now-inactive switch target")
    func externalNativeSourceReleasesInactiveTarget() async throws {
        let fixture = await setup()
        await fixture.vault.save(credential("fixture-inactive-a", expired: true), accountID: fixture.first.id)
        await fixture.adapter.setCurrent(.init(account: fixture.second, credential: credential("fixture-native-b")))
        await fixture.adapter.setRunning(true)
        #expect(fixture.model.state.activeAccounts[.codex] == fixture.first.id)
        let before = await fixture.adapter.refreshCount

        await fixture.model.switchAccount(fixture.first.id)

        #expect(await fixture.adapter.refreshCount == before + 1)
        #expect(await fixture.adapter.refreshTokens.last == "fixture-inactive-a")
        #expect(await fixture.vault.load(accountID: fixture.second.id)?.accessToken == "fixture-native-b")
        #expect(fixture.model.state.activeAccounts[.codex] == fixture.first.id)
    }

    private func credential(_ token: String, expired: Bool = false) -> Credential {
        .init(accessToken: token, refreshToken: token + "-refresh",
              expiresAt: .now.addingTimeInterval(expired ? -10 : 3_600), rawAuth: Data((token + "-auth").utf8))
    }

    private func setup() async -> (model: AppModel, adapter: FakeProvider, vault: MemorySecrets,
                                  first: AccountRecord, second: AccountRecord) {
        let first = AccountRecord(identity: .init(provider: .codex, userID: "fixture-a", workspaceID: "fixture-workspace-a"))
        let second = AccountRecord(identity: .init(provider: .codex, userID: "fixture-b", workspaceID: "fixture-workspace-b"))
        var state = PersistedState()
        state.accounts = [first, second]
        state.activeAccounts[.codex] = first.id
        let vault = MemorySecrets()
        let original = credential("fixture-native-a")
        await vault.save(original, accountID: first.id)
        await vault.save(credential("fixture-saved-b"), accountID: second.id)
        let adapter = FakeProvider(.init(account: first, credential: original))
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start()
        model.stop()
        return (model, adapter, vault, first, second)
    }
}
