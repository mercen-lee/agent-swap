import Foundation
import Testing
@testable import AgentSwapCore

@Suite("메모리 데모 전환 시나리오") @MainActor
struct AppModelFactoryTests {
    @Test("Explicit keep-current recovery restores polling without switching the active demo account")
    func recoveryPreview() async throws {
        let model = AppModel.preview(claudeRecoveryConflict: true)
        await model.start(); model.stop()
        await model.refreshAll()
        let source = try #require(model.state.activeAccounts[.claude])
        let before = try #require(model.state.accounts.first { $0.id == source })
        #expect(model.compatibility[.claude]?.canWrite == false)
        #expect(model.state.usage[source]?.error != nil)
        await model.recoverClaudeKeepingCurrentLogin(source)
        #expect(model.state.activeAccounts[.claude] == source)
        #expect(model.state.accounts.first { $0.id == source } == before)
        #expect(model.compatibility[.claude]?.canWrite == true)
        #expect(model.state.accounts.filter { $0.provider == .claude }.allSatisfy { model.state.usage[$0.id]?.error == nil })
        #expect(model.state.lastSwitch[.claude] == nil)
        #expect(!model.isBusy)
    }

    @Test("Keep-current recovery cannot accept an inactive demo account")
    func recoveryRejectsInactivePreview() async throws {
        let model = AppModel.preview(claudeRecoveryConflict: true)
        await model.start(); model.stop()
        let source = try #require(model.state.activeAccounts[.claude])
        let target = try #require(model.state.accounts.first { $0.provider == .claude && $0.id != source })
        await model.recoverClaudeKeepingCurrentLogin(target.id)
        #expect(model.state.activeAccounts[.claude] == source)
        #expect(model.compatibility[.claude]?.canWrite == false)
        #expect(!model.isBusy)
    }

    @Test("Default preview keeps the existing compatible in-memory switch behavior")
    func compatiblePreview() async throws {
        let model = AppModel.preview()
        await model.start(); model.stop()
        let source = try #require(model.state.activeAccounts[.claude])
        let target = try #require(model.state.accounts.first { $0.provider == .claude && $0.id != source })
        let codex = model.state.activeAccounts[.codex]
        await model.switchAccount(target.id)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.state.activeAccounts[.codex] == codex)
        #expect(model.message?.contains("기존 대화 파일과 목록은 변경하지 않았습니다") == true)
        #expect(!model.isBusy)
    }

    @Test("Incompatible local Code metadata does not prevent the synthetic authentication-only switch")
    func incompatiblePreview() async throws {
        let model = AppModel.preview(claudeSessionIncompatible: true)
        await model.start(); model.stop()
        let source = try #require(model.state.activeAccounts[.claude])
        let target = try #require(model.state.accounts.first { $0.provider == .claude && $0.id != source })
        let codex = model.state.activeAccounts[.codex]
        await model.switchAccount(target.id)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.state.activeAccounts[.codex] == codex)
        #expect(model.state.lastSwitch[.claude] != nil)
        #expect(model.message?.contains("기존 대화 파일과 목록은 변경하지 않았습니다") == true)
        #expect(model.state.accounts.allSatisfy { $0.identity.userID.hasPrefix("demo-") && $0.email.hasSuffix("@example.com") })
        #expect(!model.isBusy)
    }
}
