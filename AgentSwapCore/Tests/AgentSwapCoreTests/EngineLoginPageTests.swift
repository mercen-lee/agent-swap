import Foundation
import Testing
@testable import AgentSwapCore

@Suite("로그인 페이지 사용자 동작") @MainActor
struct EngineLoginPageTests {
    @Test("Monitoring a CLI fallback does not open it; explicit action opens it and cancellation clears UI")
    func fallbackIsExplicitAndClearedOnCancel() async throws {
        let adapter = LoginPageFixtureProvider()
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: MemoryState())
        await model.login(.claude)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !model.canOpenLoginPage, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.canOpenLoginPage)
        #expect(await adapter.openCount == 0)
        await model.openLoginPage()
        #expect(await adapter.openCount == 1)
        #expect(!model.isOpeningLoginPage)
        await model.cancelLogin()
        #expect(!model.canOpenLoginPage)
        #expect(!model.isOpeningLoginPage)
        #expect(!model.isLoggingIn)
        #expect(!model.isBusy)
        await model.openLoginPage()
        #expect(await adapter.openCount == 1)
    }
}

private actor LoginPageFixtureProvider: ProviderAdapter {
    nonisolated let provider = Provider.claude
    var openCount = 0
    private var loginContinuation: CheckedContinuation<ImportedAccount, any Error>?
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount { throw AgentSwapError.authentication("Fixture login absent") }
    func login() async throws -> ImportedAccount {
        try await withCheckedThrowingContinuation { loginContinuation = $0 }
    }
    func cancelLogin() {
        let continuation = loginContinuation; loginContinuation = nil
        continuation?.resume(throwing: AgentSwapError.cancelled)
    }
    func canOpenLoginPage() -> Bool { loginContinuation != nil }
    func openLoginPage() throws {
        guard loginContinuation != nil else { throw AgentSwapError.cancelled }
        openCount += 1
    }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot { .init(windows: []) }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        .failed(message: "Fixture never switches")
    }
    func hasRunningConsumers() -> Bool { false }
}
