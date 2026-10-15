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
    let preparationError: (any Error)?
    let finishError: AgentSwapError?
    let verificationError: AgentSwapError?
    let rejectedVerification: Int?
    let verificationBarrier: EngineSessionVerificationBarrier?
    let barrierVerification: Int?
    var requests: [Request] = []
    var verified: [Request] = []
    var finished: [Bool] = []
    init(_ preparation: ClaudeDesktopSessionPreparation, preparationError: (any Error)? = nil,
         finishError: AgentSwapError? = nil, verificationError: AgentSwapError? = nil,
         rejectedVerification: Int? = nil, verificationBarrier: EngineSessionVerificationBarrier? = nil,
         barrierVerification: Int? = nil) {
        self.preparation = preparation; self.preparationError = preparationError; self.finishError = finishError
        self.verificationError = verificationError; self.rejectedVerification = rejectedVerification
        self.verificationBarrier = verificationBarrier
        self.barrierVerification = barrierVerification
    }
    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {
        verified.append(.init(source: source?.identity, target: target.identity, relaunch: false))
        if let verificationBarrier, barrierVerification == nil || barrierVerification == verified.count { await verificationBarrier.block() }
        if let verificationError, rejectedVerification == nil || rejectedVerification == verified.count { throw verificationError }
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

private actor EngineSessionVerificationBarrier {
    private var entered = false
    private var readiness: [CheckedContinuation<Void, Never>] = []
    private var suspended: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        for waiter in readiness { waiter.resume() }
        readiness.removeAll()
        await withCheckedContinuation { suspended = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { readiness.append($0) }
    }
    func release() { suspended?.resume(); suspended = nil }
}

private actor EngineSessionBlockingSecrets: SecretStore {
    nonisolated let base = MemorySecrets()
    private var nextRead: EngineSessionVerificationBarrier?
    func holdNextRead(_ barrier: EngineSessionVerificationBarrier) { nextRead = barrier }
    func load(accountID: UUID) async -> Credential? {
        if let barrier = nextRead { nextRead = nil; await barrier.block() }
        return await base.load(accountID: accountID)
    }
    func save(_ credential: Credential, accountID: UUID) async { await base.save(credential, accountID: accountID) }
    func delete(accountID: UUID) async { await base.delete(accountID: accountID) }
}

@MainActor private final class EngineSessionActionStarted {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { started = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor EngineSessionToggleState: StateStore {
    private var state: PersistedState
    private var fails = false
    init(_ state: PersistedState) { self.state = state }
    func load() -> PersistedState { state }
    func save(_ state: PersistedState) throws {
        if fails { throw AgentSwapError.storage("fixture metadata write failed") }
        self.state = state
    }
    func failWrites() { fails = true }
}

@Suite("계정 전환의 자동 Code 세션 보존") @MainActor
struct EngineSessionPreservationTests {
    private func setup(_ sessions: EngineSessionPreserver, provider: Provider = .claude,
                       automatic: Bool = false, expiredTarget: Bool = false,
                       blockingVault: EngineSessionBlockingSecrets? = nil) async -> (AppModel, FakeProvider, MemorySecrets, AccountRecord, AccountRecord) {
        let source = AccountRecord(identity: .init(provider: provider, userID: "fixture-source", workspaceID: "fixture-source-org"), automaticSwitchEligible: true)
        let target = AccountRecord(identity: .init(provider: provider, userID: "fixture-target", workspaceID: "fixture-target-org"), automaticSwitchEligible: true)
        let credential = Credential(accessToken: "fixture-source-token", expiresAt: Date().addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential)), vault = blockingVault?.base ?? MemorySecrets()
        await vault.save(credential, accountID: source.id)
        await vault.save(.init(accessToken: "fixture-target-token", expiresAt: Date().addingTimeInterval(expiredTarget ? -60 : 3600), rawAuth: Data("{}".utf8)), accountID: target.id)
        var state = PersistedState(); state.accounts = [source, target]; state.activeAccounts[provider] = source.id
        state.settings.automation[provider]?.enabled = automatic
        let now = Date()
        state.usage[source.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        state.usage[target.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 30, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        let secrets: any SecretStore
        if let blockingVault { secrets = blockingVault } else { secrets = vault }
        let model = AppModel(adapters: [adapter], secrets: secrets, store: MemoryState(state), claudeSessions: sessions)
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
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: AgentSwapError.storage("fixture preservation failure"))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.finished.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.message == "fixture preservation failure")
        #expect(model.claudeCLIOnlySwitchTarget == nil)
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

    @Test("Typed preflight unavailability offers an explicit CLI-only action; default auth stays untouched")
    func explicitCLIOnlyFallback() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, vault, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(model.claudeCLIOnlySwitchTarget == target.id)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.verified.isEmpty)
        #expect(await sessions.finished.isEmpty)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(await sessions.requests.count == 1)
        #expect(await sessions.verified.count == 2)
        #expect(await sessions.verified.allSatisfy { $0.source == source.identity && $0.target == target.identity && !$0.relaunch })
        #expect(await sessions.finished.isEmpty)
        #expect(await vault.load(accountID: source.id)?.accessToken == "fixture-source-token")
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.message?.contains("대화 파일과 목록은 변경하지 않았습니다") == true)
        #expect(model.message?.contains("데스크톱 로그인은 CLI 로그인과 별개") == true)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await adapter.activationCount == 1)
    }

    @Test("Generic failures and cancellation never offer a preservation bypass", arguments: [AgentSwapError.storage("fixture recovery failure"), .unsupported("fixture unsupported state"), .cancelled])
    func genericErrorsDoNotOfferCLIOnly(error: AgentSwapError) async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: error)
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.verified.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
    }

    @Test("Automatic switching does not silently fall back after unsupported local metadata")
    func automaticNeverUsesCLIOnlyFallback() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, _, source, target) = await setup(sessions, automatic: true)
        await model.refreshDue()
        #expect(await sessions.requests.count == 1)
        #expect(await sessions.verified.isEmpty)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.state.lastSwitch[.claude] == nil)
        #expect(model.claudeCLIOnlySwitchTarget == target.id)
    }

    @Test("The explicit offer cannot target another account or run after dismissal")
    func wrongTargetAndDismissalRejectCLIOnly() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        await model.switchClaudeCLIOnly(source.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.verified.isEmpty)
        model.dismissClaudeCLIOnlySwitch()
        await model.switchClaudeCLIOnly(target.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(await adapter.activationCount == 0)
    }

    @Test("A changed current source rejects the offer before recovery verification or activation")
    func externalSourceChangeRejectsCLIOnly() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        let other = AccountRecord(identity: .init(provider: .claude, userID: "fixture-external", workspaceID: "fixture-external-org"))
        await adapter.setCurrent(.init(account: other, credential: .init(accessToken: "fixture-external-token", rawAuth: Data())))
        await model.switchClaudeCLIOnly(target.id)
        #expect(await sessions.verified.isEmpty)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
    }

    @Test("The normal late source backup fence still rejects an external account change in CLI-only mode")
    func lateSourceChangeRejectsCLIOnly() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        let other = AccountRecord(identity: .init(provider: .claude, userID: "fixture-external", workspaceID: "fixture-external-org"))
        await adapter.setCurrentBeforeBackup(.init(account: other, credential: .init(accessToken: "fixture-external-token", rawAuth: Data())))
        await model.switchClaudeCLIOnly(target.id)
        #expect(await sessions.verified.count == 1)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
    }

    @Test("A pending or unknown preservation journal blocks the explicit fallback")
    func recoveryVerificationFailureBlocksCLIOnly() async {
        let sessions = EngineSessionPreserver(.notNeeded,
            preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields),
            verificationError: .storage("fixture pending journal"))
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await sessions.verified.count == 1)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
    }

    @Test("A journal appearing after target refresh prevents native apply while retaining the rotated target")
    func lateRecoveryBoundaryBlocksCLIOnly() async {
        let sessions = EngineSessionPreserver(.notNeeded,
            preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields),
            verificationError: .storage("fixture late journal"), rejectedVerification: 2)
        let (model, adapter, vault, source, target) = await setup(sessions, expiredTarget: true)
        await model.switchAccount(target.id)
        let refreshesBeforeFallback = await adapter.refreshCount
        // Expire the managed target again so the explicit flow itself crosses a refresh await.
        await vault.save(.init(accessToken: "fixture-target-fresh", expiresAt: .now.addingTimeInterval(-60), rawAuth: Data("fixture-expired-target".utf8)), accountID: target.id)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await adapter.refreshCount == refreshesBeforeFallback + 1)
        #expect(await vault.load(accountID: target.id)?.accessToken == "rotated")
        #expect(await sessions.verified.count == 2)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.message?.contains("fixture late journal") == true)
    }

    @Test("Cancellation after read-only verification cannot apply authentication")
    func cancellationDuringVerificationBlocksCLIOnly() async {
        let barrier = EngineSessionVerificationBarrier()
        let sessions = EngineSessionPreserver(.notNeeded,
            preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields), verificationBarrier: barrier)
        let (model, adapter, _, source, target) = await setup(sessions)
        await model.switchAccount(target.id)
        let operation = Task { await model.switchClaudeCLIOnly(target.id) }
        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()
        await operation.value
        #expect(await sessions.verified.count == 1)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(!model.isBusy)
    }

    @Test("A queued explicit request cannot outlive dismissal or cancellation", arguments: [false, true])
    func queuedRequestCannotReuseOffer(cancel: Bool) async {
        let vault = EngineSessionBlockingSecrets(), barrier = EngineSessionVerificationBarrier()
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (model, adapter, _, source, target) = await setup(sessions, blockingVault: vault)
        await model.switchAccount(target.id)
        await vault.holdNextRead(barrier)
        let authority = Task { await model.authorizeSavedCredential(target.id) }
        await barrier.waitUntilEntered()
        let started = EngineSessionActionStarted()
        let fallback = Task {
            // This synchronous signal precedes the same-actor call's first suspension, so
            // the queued operation captures its immutable offer before the test resumes.
            started.signal()
            await model.switchClaudeCLIOnly(target.id)
        }
        await started.wait()
        if cancel { fallback.cancel() } else { model.dismissClaudeCLIOnlySwitch() }
        await barrier.release()
        await authority.value; await fallback.value
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.verified.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(!model.isBusy)
    }

    @Test("A metadata failure invalidates the prior offer and prevents CLI-only switching")
    func storageFailureInvalidatesOffer() async {
        let sessions = EngineSessionPreserver(.notNeeded, preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields))
        let (initial, adapter, vault, source, target) = await setup(sessions)
        let store = EngineSessionToggleState(initial.state)
        let model = AppModel(adapters: [adapter], secrets: vault, store: store, claudeSessions: sessions)
        await model.start(); model.stop()
        await model.switchAccount(target.id)
        #expect(model.claudeCLIOnlySwitchTarget == target.id)
        await store.failWrites()
        await model.updateAccount(target.id, nickname: "fixture changed nickname")
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.switchOperationBlockReason?.contains("저장 오류") == true)
        await model.switchClaudeCLIOnly(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(await sessions.verified.isEmpty)
        #expect(model.state.activeAccounts[.claude] == source.id)
    }

    @Test("A metadata failure during the final recovery check still stops native authentication")
    func lateStorageFailureStopsCLIOnly() async {
        let barrier = EngineSessionVerificationBarrier()
        let sessions = EngineSessionPreserver(.notNeeded,
            preparationError: ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields),
            verificationBarrier: barrier, barrierVerification: 2)
        let (initial, adapter, vault, source, target) = await setup(sessions)
        let store = EngineSessionToggleState(initial.state)
        let model = AppModel(adapters: [adapter], secrets: vault, store: store, claudeSessions: sessions)
        await model.start(); model.stop()
        await model.switchAccount(target.id)
        let operation = Task { await model.switchClaudeCLIOnly(target.id) }
        await barrier.waitUntilEntered()
        await store.failWrites()
        await model.updateAccount(target.id, nickname: "fixture late metadata failure")
        await barrier.release()
        await operation.value
        #expect(await sessions.verified.count == 2)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.switchOperationBlockReason?.contains("저장 오류") == true)
    }
}
