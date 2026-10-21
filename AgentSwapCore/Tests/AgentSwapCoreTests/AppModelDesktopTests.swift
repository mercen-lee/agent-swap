import Foundation
import Testing
@testable import AgentSwapCore

private actor DesktopManagerFixture: ClaudeDesktopAccountManaging {
    struct Preparation: Sendable, Equatable {
        let target: UUID
        let currentCLI: AccountIdentity?
    }

    let transactionID = UUID()
    var captureIDs: [UUID] = []
    var preparations: [Preparation] = []
    var finishes: [(UUID, Bool)] = []
    var verifies: [UUID?] = []
    var recoveries: [(registered: [AccountIdentity], currentCLI: AccountIdentity?)] = []
    var deleted: [UUID] = []
    var prepareError: (any Error)?
    var finishError: (any Error)?
    var verifyError: (any Error)?
    var deleteError: (any Error)?

    func captureCurrent(for account: AccountRecord) async throws { captureIDs.append(account.id) }
    func prepareSwitch(target: AccountRecord, registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> UUID {
        if let prepareError { throw prepareError }
        preparations.append(.init(target: target.id, currentCLI: currentCLI))
        return transactionID
    }
    func finish(transactionID: UUID, cliApplied: Bool) async throws -> String {
        finishes.append((transactionID, cliApplied))
        if let finishError { throw finishError }
        return "fixture Desktop applied"
    }
    func verifyCanSwitchCLI(allowing transactionID: UUID?) async throws {
        verifies.append(transactionID)
        if transactionID == nil, let verifyError { throw verifyError }
    }
    func recover(registered: [AccountRecord], currentCLI: AccountIdentity?) async throws -> String {
        recoveries.append((registered.map(\.identity), currentCLI))
        return "fixture Desktop recovered"
    }
    func deleteSnapshot(accountID: UUID) async throws {
        if let deleteError { throw deleteError }
        deleted.append(accountID)
    }
    func setPrepareError(_ error: (any Error)?) { prepareError = error }
    func setFinishError(_ error: (any Error)?) { finishError = error }
    func setVerifyError(_ error: (any Error)?) { verifyError = error }
    func setDeleteError(_ error: (any Error)?) { deleteError = error }
    func resetVerifications() { verifies = [] }
}

@Suite("Claude Desktop과 CLI의 명시적 결합 전환") @MainActor
struct AppModelDesktopTests {
    private func setup(automatic: Bool = false, pendingAtStartup: Bool = false) async -> (AppModel, FakeProvider, DesktopManagerFixture, AccountRecord, AccountRecord) {
        let source = AccountRecord(identity: .init(provider: .claude, userID: "desktop-source", workspaceID: "desktop-source-org"), automaticSwitchEligible: true)
        let target = AccountRecord(identity: .init(provider: .claude, userID: "desktop-target", workspaceID: "desktop-target-org"), automaticSwitchEligible: true)
        let credential = Credential(accessToken: "desktop-source-token", expiresAt: .now.addingTimeInterval(3600), rawAuth: Data("{}".utf8))
        let adapter = FakeProvider(.init(account: source, credential: credential))
        let secrets = MemorySecrets()
        await secrets.save(credential, accountID: source.id)
        await secrets.save(.init(accessToken: "desktop-target-token", expiresAt: .now.addingTimeInterval(3600), rawAuth: Data("{}".utf8)), accountID: target.id)
        var state = PersistedState()
        state.accounts = [source, target]
        state.activeAccounts[.claude] = source.id
        state.settings.automation[.claude]?.enabled = automatic
        let now = Date()
        state.usage[source.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "공통", usedPercent: 95, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        state.usage[target.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "공통", usedPercent: 30, resetsAt: now.addingTimeInterval(3600))]), attemptedAt: now)
        let desktop = DesktopManagerFixture()
        if pendingAtStartup { await desktop.setVerifyError(AgentSwapError.storage("fixture pending Desktop recovery")) }
        let model = AppModel(adapters: [adapter], secrets: secrets, store: MemoryState(state), claudeDesktop: desktop)
        await model.start(); model.stop()
        await desktop.resetVerifications()
        return (model, adapter, desktop, source, target)
    }

    @Test("시작 시 보류된 Desktop 기록은 Desktop을 열지 않고 복구 상태로 표시한다")
    func pendingRecoveryAppearsAtStartup() async {
        let (model, adapter, desktop, _, _) = await setup(pendingAtStartup: true)
        #expect(model.claudeDesktopRecoveryRequired)
        #expect(await desktop.preparations.isEmpty)
        #expect(await desktop.captureIDs.isEmpty)
        #expect(await adapter.activationCount == 0)
    }

    @Test("Desktop 로그인 캡처는 CLI 인증을 적용하지 않는다")
    func captureDoesNotApplyCLI() async {
        let (model, adapter, desktop, source, _) = await setup()
        await model.captureClaudeDesktopLogin(source.id)
        #expect(await adapter.activationCount == 0)
        #expect(await desktop.captureIDs == [source.id])
        #expect(model.state.activeAccounts[.claude] == source.id)
    }

    @Test("명시적 결합 전환은 Desktop 준비 뒤 기존 CLI 안전 경로를 거쳐 완료한다")
    func combinedSwitchCommitsDesktopAfterCLI() async {
        let (model, adapter, desktop, source, target) = await setup()
        await model.switchClaudeDesktopAccount(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(await desktop.preparations == [.init(target: target.id, currentCLI: source.identity)])
        #expect(await desktop.finishes.map { $0.1 } == [true])
        let verifications = await desktop.verifies
        #expect(verifications.first == .some(nil))
        #expect(verifications.dropFirst().allSatisfy { $0 == desktop.transactionID })
    }

    @Test("Desktop 준비 실패는 CLI 인증을 적용하지 않는다")
    func preparationFailurePreventsCLI() async {
        let (model, adapter, desktop, source, target) = await setup()
        await desktop.setPrepareError(AgentSwapError.storage("fixture desktop prepare failed"))
        await model.switchClaudeDesktopAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await desktop.finishes.isEmpty)
    }

    @Test("CLI 적용 실패는 Desktop 준비를 false로 완료한다")
    func cliFailureAbortsDesktopPreparation() async {
        let (model, adapter, desktop, source, target) = await setup()
        await adapter.setActivation(.failed(message: "fixture CLI failed"))
        await model.switchClaudeDesktopAccount(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(await desktop.finishes.map { $0.1 } == [false])
    }

    @Test("CLI 적용 뒤 Desktop 완료 실패는 CLI를 되돌리지 않고 부분 완료를 명시한다")
    func finishFailureRetainsAppliedCLI() async {
        let (model, adapter, desktop, _, target) = await setup()
        await desktop.setFinishError(AgentSwapError.storage("fixture desktop finish failed"))
        await model.switchClaudeDesktopAccount(target.id)
        #expect(await adapter.activationCount == 1)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.claudeDesktopRecoveryRequired)
        #expect(model.message?.contains("CLI는 선택한 계정으로 전환됐습니다") == true)
    }

    @Test("일반·자동 CLI 전환은 Desktop 캡처·준비·완료를 호출하지 않는다", arguments: [false, true])
    func plainSwitchNeverTouchesDesktop(automatic: Bool) async {
        let (model, adapter, desktop, _, target) = await setup(automatic: automatic)
        if automatic { await model.refreshDue() } else { await model.switchAccount(target.id) }
        #expect(await adapter.activationCount == 1)
        #expect(await desktop.captureIDs.isEmpty)
        #expect(await desktop.preparations.isEmpty)
        #expect(await desktop.finishes.isEmpty)
        #expect(await desktop.verifies.allSatisfy { $0 == nil })
    }

    @Test("보류된 Desktop 전환 저널은 일반 CLI 전환을 차단한다")
    func pendingDesktopGuardBlocksPlainSwitch() async {
        let (model, adapter, desktop, source, target) = await setup()
        await desktop.setVerifyError(AgentSwapError.storage("fixture pending Desktop transaction"))
        await model.switchAccount(target.id)
        #expect(await adapter.activationCount == 0)
        #expect(model.state.activeAccounts[.claude] == source.id)
        #expect(model.claudeDesktopRecoveryRequired)
    }

    @Test("Desktop 복구는 실제 현재 CLI 계정 ID를 전달한다")
    func recoveryReceivesActualCurrentCLIIdentity() async throws {
        let (model, _, desktop, source, _) = await setup()
        await model.recoverClaudeDesktopSwitch()
        let recoveries = await desktop.recoveries
        #expect(recoveries.count == 1)
        let recovery = try #require(recoveries.first)
        #expect(recovery.currentCLI == source.identity)
        #expect(recovery.registered.contains(source.identity))
    }

    @Test("Desktop 프로필 삭제 성공은 계정을 제거하고 실패는 등록을 보존한다", arguments: [false, true])
    func deletingAccountCoordinatesDesktopSnapshot(failDelete: Bool) async {
        let (model, _, desktop, source, _) = await setup()
        if failDelete { await desktop.setDeleteError(AgentSwapError.storage("fixture desktop delete failed")) }
        await model.deleteAccount(source.id)
        if failDelete {
            #expect(model.state.accounts.contains(where: { $0.id == source.id }))
            #expect(await desktop.deleted.isEmpty)
        } else {
            #expect(!model.state.accounts.contains(where: { $0.id == source.id }))
            #expect(await desktop.deleted == [source.id])
        }
    }
}
