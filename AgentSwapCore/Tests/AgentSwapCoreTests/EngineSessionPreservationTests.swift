import Foundation
import Testing
@testable import AgentSwapCore

private actor EngineSessionPreserver: ClaudeDesktopSessionPreserving {
    struct Request: Sendable {
        var source: AccountIdentity?
        var target: AccountIdentity
        var relaunch: Bool
    }
    let preparation: ClaudeDesktopSessionPreparation
    let preparationError: AgentSwapError?
    let finishError: AgentSwapError?
    var requests: [Request] = []
    var finished: [Bool] = []
    init(_ preparation: ClaudeDesktopSessionPreparation, preparationError: AgentSwapError? = nil,
         finishError: AgentSwapError? = nil) {
        self.preparation = preparation; self.preparationError = preparationError; self.finishError = finishError
    }
    func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) throws -> ClaudeDesktopSessionPreparation {
        requests.append(.init(source: source?.identity, target: target.identity, relaunch: relaunch))
        if let preparationError { throw preparationError }
        return preparation
    }
    func finish(_ preparation: ClaudeDesktopSessionPreparation, applied: Bool) throws -> String? {
        finished.append(applied)
        if let finishError { throw finishError }
        if case .prepared = preparation { return "Code 대화 목록을 보존했습니다." }
        return nil
    }
}

@Suite("계정 전환의 자동 Code 세션 보존") @MainActor
struct EngineSessionPreservationTests {
    private func setup(_ sessions: EngineSessionPreserver, provider: Provider = .claude,
                       automatic: Bool = false) async -> (AppModel, FakeProvider, MemorySecrets, AccountRecord, AccountRecord) {
        let source = AccountRecord(identity: .init(provider: provider, userID: "fixture-source", workspaceID: "fixture-source-org"), automaticSwitchEligible: true)
        let target = AccountRecord(identity: .init(provider: provider, userID: "fixture-target", workspaceID: "fixture-target-org"), automaticSwitchEligible: true)
        let credential = Credential(accessToken: "fixture-source-token", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential)), vault = MemorySecrets()
        await vault.save(credential, accountID: source.id)
        await vault.save(.init(accessToken: "fixture-target-token", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("{}".utf8)), accountID: target.id)
        var state = PersistedState(); state.accounts = [source, target]; state.activeAccounts[provider] = source.id
        state.settings.automation[provider]?.enabled = automatic
        let now = Date()
        state.usage[source.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        state.usage[target.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 30, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state), claudeSessions: sessions)
        await model.start(); model.stop()
        return (model, adapter, vault, source, target)
    }

    @Test("재실행을 기다릴 때 인증·활성 계정·유예 시간을 바꾸지 않는다")
    func pendingKeepsCurrentAuthentication() async {
        let sessions = EngineSessionPreserver(.pendingRelaunch("세션 보존 및 재실행을 기다립니다."))
        let (model, adapter, vault, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.finished.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.state.lastSwitch[.claude] == nil)
        #expect(model.pendingSwitch[.claude] == target.id)
        #expect(await vault.load(accountID: source.id)?.accessToken == "fixture-source-token")
        #expect(await vault.load(accountID: target.id)?.accessToken == "fixture-target-token")
        let requests = await sessions.requests
        #expect(requests.count == 1 && requests[0].source == source.identity && requests[0].target == target.identity && !requests[0].relaunch)
    }

    @Test("기존 전환 버튼에서 보존을 준비하고 인증 적용 후 완료한다")
    func successfulSwitchCommitsPreparation() async {
        let sessions = EngineSessionPreserver(.prepared(transactionID: UUID(), count: 2))
        let (model, adapter, _, _, target) = await setup(sessions)
        await model.switchAccount(target.id, relaunch: true)
        #expect(await adapter.activationCount == 1)
        #expect(await sessions.finished == [true])
        #expect(await sessions.requests.first?.relaunch == true)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.message?.contains("Code 대화 목록을 보존했습니다.") == true)
        #expect(model.pendingSwitch[.claude] == nil)
    }

    @Test("인증 적용 실패는 이번에 준비한 대상 목록을 되돌린다")
    func failedSwitchRollsBackPreparation() async {
        let sessions = EngineSessionPreserver(.prepared(transactionID: UUID(), count: 1))
        let (model, adapter, _, source, target) = await setup(sessions)
        await adapter.setActivation(.failed(message: "fixture auth write failure"))
        await model.switchAccount(target.id)
        #expect(await sessions.finished == [false])
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.state.lastSwitch[.claude] == nil)
    }

    @Test("보존 실패는 대상 인증을 쓰지 않는다")
    func preparationFailureStopsAuthenticationWrite() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: .storage("fixture preservation failure"))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.finished.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.message == "fixture preservation failure")
    }

    @Test("보존 도중 다른 계정으로 바뀌면 대상 인증 적용을 거부한다")
    func changedSourceStopsAuthenticationWrite() async {
        let sessions = EngineSessionPreserver(.prepared(transactionID: UUID(), count: 1))
        let (model, adapter, _, _, target) = await setup(sessions)
        let other = AccountRecord(identity: .init(provider: .claude, userID: "fixture-external", workspaceID: "fixture-external-org"))
        await adapter.setCurrentBeforeBackup(.init(account: other, credential: .init(accessToken: "fixture-external-token", rawAuth: Data())))
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.finished == [false])
        #expect(model.state.activeAccounts[.claude] != target.id)
    }

    @Test("완료 확인 실패에서도 실제 적용된 CLI 계정과 오류를 함께 표시한다")
    func finishFailureDoesNotMisreportAuthentication() async {
        let sessions = EngineSessionPreserver(.prepared(transactionID: UUID(), count: 1), finishError: .storage("fixture finish failure"))
        let (model, adapter, _, _, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.message?.contains("fixture finish failure") == true)
    }

    @Test("자동 전환도 같은 보존 경로를 거치며 임의로 데스크톱을 종료하지 않는다")
    func automaticSwitchWaitsForExplicitRelaunch() async {
        let sessions = EngineSessionPreserver(.pendingRelaunch("세션 보존 및 재실행을 기다립니다."))
        let (model, adapter, _, source, target) = await setup(sessions, automatic: true)
        await model.refreshDue()
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.requests.count == 1)
        #expect(await sessions.requests.first?.relaunch == false)
        #expect(model.pendingSwitch[.claude] == target.id)
        #expect(model.state.activeAccounts[.claude] == source.id)
    }

    @Test("Codex 전환은 Claude 대화 저장소를 읽거나 쓰지 않는다")
    func codexSkipsClaudePreserver() async {
        let sessions = EngineSessionPreserver(.prepared(transactionID: UUID(), count: 1))
        let (model, adapter, _, _, target) = await setup(sessions, provider: .codex)
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(await sessions.requests.isEmpty)
        #expect(await sessions.finished.isEmpty)
    }
}
