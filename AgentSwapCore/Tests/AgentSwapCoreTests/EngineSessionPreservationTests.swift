import Foundation
import Testing
@testable import AgentSwapCore

private actor AuthOnlySessionGuard: ClaudeDesktopSessionPreserving {
    struct Request: Sendable, Equatable {
        let source: AccountIdentity?
        let target: AccountIdentity
    }

    let preparation: ClaudeDesktopSessionPreparation
    let preparationError: (any Error)?
    var verificationErrorAt: Int?
    let verificationBarrier: AuthOnlyVerificationBarrier?
    let blockVerificationAt: Int?
    var preparedCalls = 0
    var finishedCalls = 0
    var verifications: [Request] = []
    var preparations: [Request] = []

    init(preparation: ClaudeDesktopSessionPreparation = .prepared(transactionID: UUID(), count: 2),
         preparationError: (any Error)? = nil,
         verificationErrorAt: Int? = nil,
         verificationBarrier: AuthOnlyVerificationBarrier? = nil,
         blockVerificationAt: Int? = nil) {
        self.preparation = preparation
        self.preparationError = preparationError
        self.verificationErrorAt = verificationErrorAt
        self.verificationBarrier = verificationBarrier
        self.blockVerificationAt = blockVerificationAt
    }

    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {
        verifications.append(.init(source: source?.identity, target: target.identity))
        if blockVerificationAt == verifications.count { await verificationBarrier?.block() }
        if verificationErrorAt == verifications.count {
            throw AgentSwapError.storage("fixture pending local Code journal")
        }
    }

    func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation {
        preparedCalls += 1
        preparations.append(.init(source: source?.identity, target: target.identity))
        if let preparationError { throw preparationError }
        return preparation
    }

    func finish(_ preparation: ClaudeDesktopSessionPreparation, applied: Bool) async throws -> String? {
        finishedCalls += 1
        return "fixture should never be shown"
    }
}

private actor AuthOnlyVerificationBarrier {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor AuthOnlyFailingSecrets: SecretStore {
    private var values: [UUID: Credential]
    init(_ values: [UUID: Credential]) { self.values = values }
    func load(accountID: UUID) -> Credential? { values[accountID] }
    func save(_ credential: Credential, accountID: UUID) throws {
        throw AgentSwapError.storage("fixture source credential save failed")
    }
    func delete(accountID: UUID) { values.removeValue(forKey: accountID) }
}

@Suite("인증 전용 Claude 전환") @MainActor
struct EngineSessionPreservationTests {
    private func setup(_ sessionGuard: AuthOnlySessionGuard, provider: Provider = .claude,
                       automatic: Bool = false) async -> (AppModel, FakeProvider, MemorySecrets, AccountRecord, AccountRecord) {
        let source = AccountRecord(identity: .init(provider: provider, userID: "fixture-source", workspaceID: "fixture-source-org"), automaticSwitchEligible: true)
        let target = AccountRecord(identity: .init(provider: provider, userID: "fixture-target", workspaceID: "fixture-target-org"), automaticSwitchEligible: true)
        let credential = Credential(accessToken: "fixture-source-token", expiresAt: .now.addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential))
        let vault = MemorySecrets()
        await vault.save(credential, accountID: source.id)
        await vault.save(.init(accessToken: "fixture-target-token", expiresAt: .now.addingTimeInterval(3600), rawAuth: Data("{}".utf8)), accountID: target.id)
        var state = PersistedState()
        state.accounts = [source, target]
        state.activeAccounts[provider] = source.id
        state.settings.automation[provider]?.enabled = automatic
        let now = Date()
        state.usage[source.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        state.usage[target.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "session", title: "공통", usedPercent: 30, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state), claudeSessions: sessionGuard)
        await model.start(); model.stop()
        return (model, adapter, vault, source, target)
    }

    @Test("일반 Claude 전환은 준비된 로컬 대화 보존기를 호출하지 않는다")
    func normalSwitchDoesNotPreserveLocalCode() async {
        let sessionGuard = AuthOnlySessionGuard(preparation: .prepared(transactionID: UUID(), count: 9), preparationError: AgentSwapError.storage("must not run"))
        let (model, adapter, _, source, target) = await setup(sessionGuard)

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
        let checks = await sessionGuard.verifications
        #expect(checks.count >= 2)
        for check in checks {
            #expect(check.source == source.identity)
            #expect(check.target == target.identity)
        }
    }

    @Test("자동 Claude 전환도 로컬 Code 준비나 완료를 호출하지 않는다")
    func automaticSwitchDoesNotPreserveLocalCode() async {
        let sessionGuard = AuthOnlySessionGuard(preparation: .pendingRelaunch("must not run"), preparationError: AgentSwapError.unsupported("must not run"))
        let (model, adapter, _, source, target) = await setup(sessionGuard, automatic: true)

        await model.refreshDue()

        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
        let checks = await sessionGuard.verifications
        #expect(checks.count >= 2)
        for check in checks {
            #expect(check.source == source.identity)
            #expect(check.target == target.identity)
        }
    }

    @Test("기존 로컬 Code 저널은 인증 전용 전환도 차단한다")
    func existingJournalBlocksAuthenticationSwitch() async {
        let sessionGuard = AuthOnlySessionGuard(verificationErrorAt: 1)
        let (model, adapter, _, source, target) = await setup(sessionGuard)

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
    }

    @Test("중단된 이전 대화 보존 저널은 별도 복구에서만 같은 계정으로 처리한다")
    func explicitLegacyRecoveryDoesNotSwitchAuthentication() async {
        let sessionGuard = AuthOnlySessionGuard(preparation: .notNeeded, verificationErrorAt: 1)
        let (model, adapter, _, source, target) = await setup(sessionGuard)

        await model.switchAccount(target.id)

        #expect(model.claudeSessionRecoveryRequired)
        #expect(await adapter.activationCount == 0)
        #expect(await sessionGuard.preparedCalls == 0)
        await model.recoverInterruptedClaudeSessions()

        #expect(!model.claudeSessionRecoveryRequired)
        #expect(await adapter.activationCount == 0)
        #expect(await sessionGuard.preparedCalls == 1)
        #expect(await sessionGuard.finishedCalls == 0)
        let preparations = await sessionGuard.preparations
        #expect(preparations == [.init(source: source.identity, target: source.identity)])
    }

    @Test("원본 인증을 백업하는 사이 생긴 로컬 Code 저널은 적용을 차단한다")
    func lateJournalBlocksAfterSourceBackup() async {
        let sessionGuard = AuthOnlySessionGuard(verificationErrorAt: 2)
        let (model, adapter, _, source, target) = await setup(sessionGuard)

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
        #expect((await sessionGuard.verifications).count >= 2)
    }

    @Test("외부 계정 변경은 로컬 대화를 건드리지 않고 인증 적용을 거부한다")
    func sourceIdentityChangeFailsClosed() async {
        let sessionGuard = AuthOnlySessionGuard()
        let (model, adapter, vault, source, target) = await setup(sessionGuard)
        let other = AccountRecord(identity: .init(provider: .claude, userID: "fixture-external", workspaceID: "fixture-external-org"))
        await adapter.setCurrentBeforeBackup(.init(account: other, credential: .init(accessToken: "fixture-external", rawAuth: Data())))

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == nil)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
        #expect(await vault.load(accountID: source.id)?.accessToken == "fixture-source-token")
        #expect(await vault.load(accountID: target.id)?.accessToken == "fixture-target-token")
    }

    @Test("가드 확인 중 취소되면 인증 적용과 로컬 대화 작업을 모두 중단한다")
    func cancellationFailsClosed() async {
        let barrier = AuthOnlyVerificationBarrier()
        let sessionGuard = AuthOnlySessionGuard(verificationBarrier: barrier, blockVerificationAt: 1)
        let (model, adapter, _, source, target) = await setup(sessionGuard)

        let operation = Task { await model.switchAccount(target.id) }
        await barrier.waitUntilEntered()
        operation.cancel()
        await barrier.release()
        await operation.value

        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
    }

    @Test("Codex 전환은 Claude 로컬 대화 가드를 호출하지 않는다")
    func codexDoesNotUseClaudeSessionService() async {
        let sessionGuard = AuthOnlySessionGuard()
        let (model, adapter, _, _, target) = await setup(sessionGuard, provider: .codex)

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 1)
        #expect(await sessionGuard.verifications.isEmpty)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
    }

    @Test("저장 실패는 로컬 대화를 건드리지 않고 전환을 중단한다")
    func storageFailureFailsClosed() async throws {
        let sessionGuard = AuthOnlySessionGuard()
        let (initial, adapter, vault, source, target) = await setup(sessionGuard)
        let sourceCredential = try #require(await vault.load(accountID: source.id))
        let targetCredential = try #require(await vault.load(accountID: target.id))
        let secrets = AuthOnlyFailingSecrets([source.id: sourceCredential, target.id: targetCredential])
        let model = AppModel(adapters: [adapter], secrets: secrets, store: MemoryState(initial.state), claudeSessions: sessionGuard)
        await model.start(); model.stop()
        await adapter.setCurrentBeforeBackup(.init(account: source, credential: .init(accessToken: "externally-rotated", rawAuth: Data("externally-rotated".utf8))))

        await model.switchAccount(target.id)

        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await sessionGuard.preparedCalls == 0)
        #expect(await sessionGuard.finishedCalls == 0)
    }
}
