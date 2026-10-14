import Foundation
import Testing
@testable import AgentSwapCore

// Safety invariant: mutable simulated process state and histories are accessed under one NSLock.
private final class FixtureInteractionControl: KeychainInteractionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool
    private var changes: [Bool] = []
    private var rejectsDisable = false
    init(allowed: Bool = true) { self.allowed = allowed }
    func isAllowed() -> Bool { lock.withLock { allowed } }
    func setAllowed(_ value: Bool) throws {
        try lock.withLock {
            if !value && rejectsDisable { throw AgentSwapError.storage("Fixture policy failure") }
            allowed = value; changes.append(value)
        }
    }
    func failDisabling() { lock.withLock { rejectsDisable = true } }
    func history() -> [Bool] { lock.withLock { changes } }
}

// Safety invariant: NSCondition guards the simulated synchronous native prompt; the test thread never awaits with it locked.
private final class FixturePrompt: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false, completed = false
    func waitForRelease() {
        condition.lock(); entered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func didEnter() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func finish() { condition.lock(); completed = true; condition.broadcast(); condition.unlock() }
    func didFinish() -> Bool { condition.lock(); defer { condition.unlock() }; return completed }
}

@Suite("Keychain interaction boundaries")
struct KeychainInteractionTests {
    @Test("Unattended calls disable legacy UI and restore its previous setting on errors")
    func backgroundRestoresInteraction() throws {
        let control = FixtureInteractionControl(), gate = KeychainInteractionGate(controller: control)
        #expect(KeychainInteraction.mode == .noninteractive)
        #expect(throws: AgentSwapError.self) {
            try gate.perform {
                #expect(!control.isAllowed())
                throw AgentSwapError.storage("Fixture ACL denial")
            }
        }
        #expect(control.isAllowed())
        #expect(control.history() == [false, true])
    }

    @Test("An explicit user action allows UI only during its synchronous Security operation")
    func explicitActionRestoresInteraction() throws {
        let control = FixtureInteractionControl(allowed: false), gate = KeychainInteractionGate(controller: control)
        try KeychainInteraction.$mode.withValue(.interactive) {
            try gate.perform { #expect(control.isAllowed()) }
        }
        #expect(!control.isAllowed())
        #expect(control.history() == [true, false])
        #expect(KeychainInteraction.mode == .noninteractive)
    }

    @Test("A failed UI suppression prevents the credential operation from running")
    func suppressionFailureFailsClosed() {
        let control = FixtureInteractionControl(), gate = KeychainInteractionGate(controller: control)
        control.failDisabling()
        var credentialOperationRan = false
        #expect(throws: AgentSwapError.self) { try gate.perform { credentialOperationRan = true } }
        #expect(!credentialOperationRan)
        #expect(control.isAllowed())
    }

    @Test("Unattended work fails instead of waiting behind an interactive native prompt")
    func backgroundDoesNotWaitForPrompt() async throws {
        let control = FixtureInteractionControl(), gate = KeychainInteractionGate(controller: control), prompt = FixturePrompt()
        DispatchQueue.global().async {
            try? KeychainInteraction.$mode.withValue(.interactive) { try gate.perform { prompt.waitForRelease() } }
            prompt.finish()
        }
        defer { prompt.release() }
        for _ in 0..<200 {
            if prompt.didEnter() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(prompt.didEnter())
        // Bound even a broken implementation so the fixture cannot leave a worker blocked.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { prompt.release() }
        var backgroundReadRan = false
        #expect(throws: AgentSwapError.self) { try gate.perform { backgroundReadRan = true } }
        #expect(!backgroundReadRan)
        prompt.release()
        for _ in 0..<200 {
            if prompt.didFinish() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(prompt.didFinish())
        #expect(control.isAllowed())
    }
}

private actor PolicyFixtureProvider: ProviderAdapter {
    nonisolated let provider = Provider.claude
    private var imported: ImportedAccount
    private let requiresPermission: Bool
    private let nativeMissing: Bool
    private var observed: [String: [KeychainInteractionMode]] = [:]
    init(_ imported: ImportedAccount, requiresPermission: Bool = true, nativeMissing: Bool = false) {
        self.imported = imported; self.requiresPermission = requiresPermission; self.nativeMissing = nativeMissing
    }
    private func record(_ action: String) { observed[action, default: []].append(KeychainInteraction.mode) }
    func modes(_ action: String) -> [KeychainInteractionMode] { observed[action] ?? [] }
    func compatibility() -> CompatibilityStatus {
        record("compatibility")
        return requiresPermission && !nativeMissing && KeychainInteraction.mode == .noninteractive ? .readOnly("현재 로그인 가져오기로 Keychain 접근을 허용해 주세요.") : .supported("Fixture")
    }
    func importCurrent() throws -> ImportedAccount {
        record("import")
        if nativeMissing { throw AgentSwapError.authentication("Claude Code에 로그인한 계정이 없습니다.") }
        if requiresPermission && KeychainInteraction.mode == .noninteractive { throw AgentSwapError.storage("현재 로그인 가져오기로 Keychain 접근을 허용해 주세요.") }
        return imported
    }
    func login() -> ImportedAccount { record("login"); return imported }
    func cancelLogin() { record("cancel") }
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { record("refresh"); return credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot { record("usage"); return .init(windows: [.init(id: "common", title: "Fixture", usedPercent: 20)]) }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        record("activate"); imported = .init(account: account, credential: credential); return .applied(message: "Fixture")
    }
    func hasRunningConsumers() -> Bool { false }
    func recoverInterruptedSwitch() { record("recover") }
}

@Suite("Engine Keychain interaction scopes") @MainActor
struct EngineKeychainInteractionTests {
    @Test("Startup preserves cached active metadata and usage when legacy ACL permission is needed")
    func unattendedStartupKeepsCache() async {
        let account = AccountRecord(identity: .init(provider: .claude, userID: "fixture", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture", expiresAt: Date().addingTimeInterval(3_600), rawAuth: Data("fixture".utf8))
        let snapshot = UsageSnapshot(windows: [.init(id: "common", title: "Fixture", usedPercent: 50)])
        var state = PersistedState(); state.accounts = [account]; state.activeAccounts[.claude] = account.id
        state.usage[account.id] = .init(snapshot: snapshot)
        let adapter = PolicyFixtureProvider(.init(account: account, credential: credential))
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: MemoryState(state))
        await KeychainInteraction.$mode.withValue(.interactive) { await model.start() }; model.stop()
        #expect(await adapter.modes("import") == [.noninteractive])
        #expect(await adapter.modes("compatibility") == [.noninteractive])
        #expect(model.state.activeAccounts[.claude] == account.id)
        #expect(model.state.usage[account.id]?.snapshot == snapshot)
        #expect(model.message?.contains("현재 로그인 가져오기") == true)
    }

    @Test("Explicit import, login, switch, and recovery are interactive; follow-up polling stays silent")
    func userActionsAndFollowupPolling() async throws {
        let account = AccountRecord(identity: .init(provider: .claude, userID: "fixture", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture", expiresAt: Date().addingTimeInterval(3_600), rawAuth: Data("fixture".utf8))
        let adapter = PolicyFixtureProvider(.init(account: account, credential: credential))
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: MemoryState())
        await model.importCurrent(.claude)
        #expect(await adapter.modes("import") == [.interactive, .noninteractive])
        await model.login(.claude)
        for _ in 0..<200 {
            if !model.isLoggingIn && !model.isBusy { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!model.isLoggingIn)
        #expect(await adapter.modes("login") == [.interactive])
        await model.switchAccount(account.id)
        await model.recoverInterruptedSwitch(.claude)
        #expect(await adapter.modes("activate") == [.interactive, .interactive])
        #expect(await adapter.modes("recover") == [.interactive])
        #expect(KeychainInteraction.mode == .noninteractive)
    }

    @Test("Automatic switching never escalates unattended Keychain access to an interactive scope")
    func automaticSwitchIsNoninteractive() async {
        let now = Date()
        let current = AccountRecord(identity: .init(provider: .claude, userID: "current", workspaceID: "workspace")), candidate = AccountRecord(identity: .init(provider: .claude, userID: "candidate", workspaceID: "workspace"), automaticSwitchEligible: true)
        let credential = Credential(accessToken: "fixture", expiresAt: now.addingTimeInterval(3_600), rawAuth: Data("fixture".utf8))
        var state = PersistedState(); state.accounts = [current, candidate]; state.activeAccounts[.claude] = current.id
        state.settings.automation[.claude]?.enabled = true
        state.usage[current.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "Fixture", usedPercent: 95)]), attemptedAt: now)
        state.usage[candidate.id] = .init(snapshot: .init(fetchedAt: now, windows: [.init(id: "common", title: "Fixture", usedPercent: 20)]), attemptedAt: now)
        let vault = MemorySecrets(); await vault.save(credential, accountID: current.id); await vault.save(credential, accountID: candidate.id)
        let adapter = PolicyFixtureProvider(.init(account: current, credential: credential), requiresPermission: false)
        let model = AppModel(adapters: [adapter], secrets: vault, store: MemoryState(state))
        await model.start(); model.stop()
        await KeychainInteraction.$mode.withValue(.interactive) { await model.refreshDue(now: now) }
        #expect(model.state.activeAccounts[.claude] == candidate.id)
        #expect(await adapter.modes("activate") == [.noninteractive])
    }

    @Test("Confirmed native logout clears only active identity; an empty provider is not a startup error", arguments: [true, false])
    func confirmedMissingAuth(savedAccount: Bool) async {
        let account = AccountRecord(identity: .init(provider: .claude, userID: "fixture", workspaceID: "workspace"))
        let credential = Credential(accessToken: "fixture", rawAuth: Data("fixture".utf8))
        let snapshot = UsageSnapshot(windows: [.init(id: "common", title: "Fixture", usedPercent: 50)])
        var state = PersistedState()
        if savedAccount {
            state.accounts = [account]; state.activeAccounts[.claude] = account.id
            state.usage[account.id] = .init(snapshot: snapshot)
        }
        let adapter = PolicyFixtureProvider(.init(account: account, credential: credential), nativeMissing: true)
        let model = AppModel(adapters: [adapter], secrets: MemorySecrets(), store: MemoryState(state))
        await model.start(); model.stop()
        #expect(model.state.activeAccounts[.claude] == nil)
        if savedAccount { #expect(model.state.usage[account.id]?.snapshot == snapshot) }
        else { #expect(model.message == nil) }
    }
}
