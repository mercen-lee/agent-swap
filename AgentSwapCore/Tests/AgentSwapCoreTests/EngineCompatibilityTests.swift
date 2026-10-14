import Foundation
import Testing
@testable import AgentSwapCore

@Suite("전환 호환성 갱신") @MainActor
struct EngineCompatibilityTests {
    @Test("A successful poll clears a stale provider block for a different target account")
    func successfulPollUnblocksDifferentTarget() async throws {
        let source = AccountRecord(identity: .init(provider: .claude, userID: "source", workspaceID: "workspace"))
        let target = AccountRecord(identity: .init(provider: .claude, userID: "target", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture", expiresAt: .now.addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential))
        await adapter.setCompatibility(.readOnly("Fixture source store is not writable"))
        let vault = MemorySecrets()
        await vault.save(credential, accountID: source.id)
        await vault.save(credential, accountID: target.id)
        var state = PersistedState(); state.accounts = [source, target]; state.activeAccounts[.claude] = source.id
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start(); model.stop()
        #expect(model.compatibility[.claude]?.canWrite == false)
        let activations = await adapter.activationCount
        await adapter.setCompatibility(.supported("Fixture permission restored"))
        await model.refreshAll()
        #expect(model.compatibility[.claude]?.canWrite == true)
        #expect(model.state.accounts.allSatisfy { $0.authenticationState == .valid })
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == activations + 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.state.accounts.allSatisfy { !$0.automaticSwitchEligible })
    }

    @Test("A polling storage failure retains usage but refreshes the provider write block")
    func failureUpdatesCompatibilityWithoutLoggingOut() async {
        let (model, adapter, _, id) = await EngineTests().setup(provider: .claude)
        let lastGood = model.state.usage[id]?.snapshot
        await adapter.setCompatibility(.readOnly("Fixture pending recovery"))
        await adapter.setError(.storage("Fixture source write failure"))
        await model.refreshAll()
        #expect(model.compatibility[.claude]?.canWrite == false)
        #expect(model.state.usage[id]?.snapshot == lastGood)
        #expect(model.state.accounts.first?.authenticationState == .valid)
        #expect(!model.isBusy)
    }

    @Test("Explicit compatibility retry is interactive and never switches or writes account state")
    func explicitRetryDoesNotMutateAccounts() async {
        let (model, adapter, _, _) = await EngineTests().setup(provider: .claude)
        let before = model.state
        let activations = await adapter.activationCount
        await adapter.setCompatibility(.readOnly("Fixture permission required"))
        await model.recheckCompatibility(.claude)
        #expect(model.compatibility[.claude]?.canWrite == false)
        #expect(await adapter.compatibilityModes.last == .interactive)
        await adapter.setCompatibility(.supported("Fixture permission restored"))
        await model.recheckCompatibility(.claude)
        #expect(model.compatibility[.claude]?.canWrite == true)
        #expect(model.state == before)
        #expect(await adapter.activationCount == activations)
        #expect(model.switchOperationBlockReason == nil)
    }

    @Test("A failed metadata store explains why the engine refuses switching")
    func metadataFailureIsVisible() async {
        let source = AccountRecord(identity: .init(provider: .claude, userID: "source", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture", rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential))
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: FailingMetadataState())
        await model.start(); model.stop()
        #expect(model.switchOperationBlockReason?.contains("저장 오류") == true)
        let activations = await adapter.activationCount
        await model.switchAccount(source.id)
        #expect(await adapter.activationCount == activations)
    }
}

private actor FailingMetadataState: StateStore {
    func load() throws -> PersistedState { throw AgentSwapError.storage("Fixture metadata unavailable") }
    func save(_ state: PersistedState) throws { throw AgentSwapError.storage("Fixture metadata unavailable") }
}
