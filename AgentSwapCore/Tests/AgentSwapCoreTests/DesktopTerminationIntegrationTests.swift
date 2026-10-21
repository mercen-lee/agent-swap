import Foundation
import Observation
import Testing
@testable import AgentSwapCore

// One continuation and its result share this lock. Dispatch supplies the independent test
// deadline, so a broken provider-queue ordering cannot leave the regression test suspended.
private final class DesktopTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func complete(_ value: Bool = true) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }
            result = value
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
            else { DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.complete(false) } }
        }
    }
}

private actor TerminationLoginProvider: ProviderAdapter {
    nonisolated let provider = Provider.claude
    let entered: DesktopTerminationSignal
    private var pending: CheckedContinuation<ImportedAccount, any Error>?
    private(set) var cancellations = 0
    init(entered: DesktopTerminationSignal) { self.entered = entered }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount { throw AgentSwapError.authentication("Fixture login absent") }
    func importCurrentIfPresent() -> ImportedAccount? { nil }
    func login() async throws -> ImportedAccount {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            entered.complete()
        }
    }
    func cancelLogin() {
        cancellations += 1
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: AgentSwapError.cancelled)
    }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot { .init(windows: []) }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        .failed(message: "Fixture must never apply authentication")
    }
    func hasRunningConsumers() -> Bool { false }
}

private actor TerminationProfileStore: ClaudeDesktopProfileStoring {
    let profile = ClaudeDesktopProfile(name: "합성 프로필")
    func load() -> [ClaudeDesktopProfile] { [profile] }
    func save(_ profiles: [ClaudeDesktopProfile]) {}
    func prepareDirectory(profileID: UUID) -> URL {
        URL(fileURLWithPath: "/Fixture/DesktopProfiles/\(profileID.uuidString)", isDirectory: true)
    }
}

private actor TerminationProfileProcesses: ClaudeDesktopConversationProcessControlling {
    private(set) var scans = 0
    private(set) var terminations = 0
    func installation(at applicationURL: URL?) -> ClaudeDesktopConversationInstallation? {
        .init(url: URL(fileURLWithPath: "/Fixture/Claude.app"), version: "3.1623.0")
    }
    func scan(applicationURL: URL) -> ClaudeDesktopConversationProcessSnapshot { scans += 1; return .init() }
    func requestNormalTermination() -> Bool { terminations += 1; return true }
    func relaunch(at applicationURL: URL) { Issue.record("Fixture must never relaunch") }
}

private actor TerminationProfileLauncher: ClaudeDesktopProfileLaunching {
    private(set) var launches = 0
    func launch(applicationURL: URL, configuration: ClaudeDesktopProfileLaunchConfiguration) { launches += 1 }
}

@Suite("Shared CLI login and native Desktop shutdown") @MainActor
struct DesktopTerminationIntegrationTests {
    @Test("App termination cancels the login owning the queue before waiting for a queued Desktop profile action")
    func loginAndQueuedProfileDrain() async {
        let loginEntered = DesktopTerminationSignal()
        let adapter = TerminationLoginProvider(entered: loginEntered)
        let profileStore = TerminationProfileStore(), processes = TerminationProfileProcesses()
        let launcher = TerminationProfileLauncher()
        let desktop = ClaudeDesktopProfileModel(store: profileStore, processes: processes, launcher: launcher)
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: MemoryState(), claudeDesktop: desktop)
        await model.start()
        model.stop()
        await model.login(.claude)
        guard await loginEntered.wait() else {
            Issue.record("Fixture login did not acquire the provider queue")
            await model.cancelLogin()
            return
        }

        let queued = DesktopTerminationSignal()
        withObservationTracking { _ = desktop.isBusy } onChange: { queued.complete() }
        let profile = profileStore.profile
        let opening = Task { await desktop.openProfile(profile.id) }
        guard await queued.wait() else {
            Issue.record("Fixture Desktop action did not queue behind the login")
            await model.cancelLogin()
            await opening.value
            return
        }
        #expect(desktop.isBusy)
        #expect(await processes.scans == 0)

        let completed = DesktopTerminationSignal()
        let terminating = Task { completed.complete(await model.prepareForTermination()) }
        let finished = await completed.wait()
        #expect(finished, "Termination must cancel login before awaiting queued Desktop work")
        if !finished {
            // Also drains the old, broken ordering after recording the bounded failure.
            // Keeping cleanup independent prevents the test runner from hanging on failure.
            await model.cancelLogin()
        }
        await terminating.value
        await opening.value

        #expect(await adapter.cancellations >= 1)
        #expect(await launcher.launches == 0)
        #expect(await processes.scans == 0)
        #expect(await processes.terminations == 0)
        #expect(!model.isLoggingIn)
        #expect(!model.isBusy)
        #expect(!desktop.isBusy)
    }
}
