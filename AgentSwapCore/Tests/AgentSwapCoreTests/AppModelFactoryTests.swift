import Foundation
import Testing
@testable import AgentSwapCore

@Suite("메모리 데모 전환 시나리오") @MainActor
struct AppModelFactoryTests {
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
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.message == "데모 계정을 전환했습니다.")
        #expect(!model.isBusy)
    }

    @Test("Incompatible preview reproduces the explicit CLI-only offer and continuation with synthetic accounts")
    func incompatiblePreview() async throws {
        let model = AppModel.preview(claudeSessionIncompatible: true)
        await model.start(); model.stop()
        let source = try #require(model.state.activeAccounts[.claude])
        let target = try #require(model.state.accounts.first { $0.provider == .claude && $0.id != source })
        let codex = model.state.activeAccounts[.codex]
        await model.switchAccount(target.id)
        #expect(model.state.activeAccounts[.claude] == source)
        #expect(model.claudeCLIOnlySwitchTarget == target.id)
        #expect(model.state.lastSwitch[.claude] == nil)
        await model.switchClaudeCLIOnly(target.id)
        #expect(model.state.activeAccounts[.claude] == target.id)
        #expect(model.state.activeAccounts[.codex] == codex)
        #expect(model.claudeCLIOnlySwitchTarget == nil)
        #expect(model.message?.contains("대화 파일과 목록은 변경하지 않았습니다") == true)
        #expect(model.message?.contains("데스크톱 로그인은 CLI 로그인과 별개") == true)
        #expect(model.state.accounts.allSatisfy { $0.identity.userID.hasPrefix("demo-") && $0.email.hasSuffix("@example.com") })
        #expect(!model.isBusy)
    }
}
