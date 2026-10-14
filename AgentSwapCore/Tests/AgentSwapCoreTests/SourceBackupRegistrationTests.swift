import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Source backup registration boundary") @MainActor
struct SourceBackupRegistrationTests {
    @Test("An unregistered post-termination source is preserved until it is imported", arguments: Provider.allCases)
    func unknownSourceStopsSwitch(provider: Provider) async throws {
        let source = AccountRecord(identity: .init(provider: provider, userID: "fixture-source", workspaceID: "fixture-source-org"))
        let target = AccountRecord(identity: .init(provider: provider, userID: "fixture-target", workspaceID: "fixture-target-org"))
        let external = AccountRecord(identity: .init(provider: provider, userID: "fixture-external", workspaceID: "fixture-external-org"))
        func credential(_ value: String) -> Credential {
            .init(accessToken: value, expiresAt: Date().addingTimeInterval(3_600), rawAuth: Data(value.utf8))
        }
        let original = credential("fixture-original"), desired = credential("fixture-desired"), latest = credential("fixture-latest")
        let adapter = FakeProvider(.init(account: source, credential: original))
        let vault = MemorySecrets()
        await vault.save(original, accountID: source.id)
        await vault.save(desired, accountID: target.id)
        var initial = PersistedState(); initial.accounts = [source, target]; initial.activeAccounts[provider] = source.id
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(initial))
        await model.start(); model.stop()
        // Simulate the final auth written by a consumer as it exits, after the initial check.
        await adapter.setCurrentBeforeBackup(.init(account: external, credential: latest))
        await model.switchAccount(target.id, relaunch: true)
        #expect(await adapter.activationCount == 0)
        #expect(await adapter.importCurrent().credential == latest)
        #expect(await vault.load(accountID: target.id) == desired)
        #expect(await vault.load(accountID: external.id) == nil)
        #expect(model.state.accounts.count == 2)
        #expect(model.state.activeAccounts[provider] == nil)
        #expect(model.state.lastSwitch[provider] == nil)
        #expect(model.message?.contains("현재 로그인 가져오기") == true)
        #expect(!model.isBusy)

        await model.importCurrent(provider)
        let savedSource = try #require(model.state.accounts.first { $0.identity == external.identity })
        #expect(await vault.load(accountID: savedSource.id) == latest)
        await model.switchAccount(target.id, relaunch: true)
        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[provider] == target.id)
        #expect(await vault.load(accountID: savedSource.id) == latest)
    }
}
