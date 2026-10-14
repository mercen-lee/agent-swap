import Foundation
import Testing
@testable import AgentSwapCore

private struct QuitRotationConfiguration: CodexConfigurationGuard {
    func validateDefaultProfile() {}
}
private struct QuitRotationNoLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}
private actor QuitRotationNoHTTP: ProviderHTTPTransport {
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        throw AgentSwapError.network("Unexpected fixture HTTP request")
    }
}

// All mutable fake-Keychain data stays under this lock; no Security APIs are called.
// This synchronous protocol boundary can use Mutex when macOS 14 support is retired.
private final class QuitRotationKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) { lock.withLock { values[service + "|" + account] = data } }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account) } }
}

private actor QuitRotationProcesses: CodexProcessControlling {
    private var running = true
    private var stoppedScanCount = 0
    private let onQuit: @Sendable () throws -> Void
    private let accepted: Bool
    private let staysRunning: Bool
    private var respawnConsumers: [CodexConsumer]
    private var reliable = true
    private let launchFails: Bool
    private(set) var quitCount = 0
    private(set) var launchCount = 0
    init(accepted: Bool = true, staysRunning: Bool = false, respawnConsumers: [CodexConsumer] = [],
         launchFails: Bool = false, onQuit: @escaping @Sendable () throws -> Void) {
        self.accepted = accepted; self.staysRunning = staysRunning; self.respawnConsumers = respawnConsumers
        self.launchFails = launchFails; self.onQuit = onQuit
    }
    func scan() -> CodexProcessScan {
        if running { return .init(consumers: [.init(pid: 1, kind: .desktop, name: "Synthetic Codex")], reliable: reliable) }
        stoppedScanCount += 1
        return .init(consumers: stoppedScanCount > 1 ? respawnConsumers : [], reliable: reliable)
    }
    func respawn(_ consumers: [CodexConsumer]) { respawnConsumers = consumers }
    func makeScanUnreliable() { reliable = false }
    func installation() -> CodexDesktopInstallation? { nil }
    func requestDesktopTermination() -> Bool {
        quitCount += 1
        guard accepted else { return false }
        do { try onQuit() } catch { return false }
        if !staysRunning { running = false }
        return true
    }
    func relaunchDesktop() throws {
        launchCount += 1
        if launchFails { throw AgentSwapError.unsupported("Synthetic desktop reopening failure") }
    }
}

private actor QuitRotationBackup {
    private(set) var saved: [ImportedAccount] = []
    func save(_ account: ImportedAccount) { saved.append(account) }
}

/// Every file is in a unique private fixture directory; processes, login, HTTP, and Keychain are fakes.
private struct QuitRotationFixture: Sendable {
    let home: URL
    let mode: String
    let keychain = QuitRotationKeychain()
    let files = AtomicAuthFileAccess()
    let store: CodexAuthStore
    let configuration: Data
    let history = Data("Synthetic conversation history must stay unchanged".utf8)
    var authURL: URL { home.appendingPathComponent("auth.json") }
    init(mode: String, source: Credential) throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AgentSwapQuitRotationTests-\(UUID().uuidString)")
        self.mode = mode
        configuration = Data("cli_auth_credentials_store = \"\(mode)\"\nmodel = \"fixture-model\"\n".utf8)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = CodexAuthStore(home: home, keychain: keychain, files: files, configurationGuard: QuitRotationConfiguration())
        try files.write(configuration, to: home.appendingPathComponent("config.toml"))
        try files.write(history, to: home.appendingPathComponent("history.jsonl"))
        try writeNative(source)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func writeNative(_ credential: Credential) throws {
        if mode == "file" { try files.write(credential.rawAuth, to: authURL) }
        else { keychain.write(credential.rawAuth, service: CodexAuthStore.keychainService, account: store.keychainAccount) }
    }
    func removeNative() throws {
        if mode == "file" { try files.delete(authURL) }
        else { keychain.delete(service: CodexAuthStore.keychainService, account: store.keychainAccount) }
    }
    func nativeBytes() throws -> Data? {
        if mode == "file" { return try files.read(authURL) }
        return keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount)
    }
    func leavePendingRecovery() throws {
        struct Journal: Encodable {
            let version = 1
            let committed = false
            let mutations: [AuthMutation]
        }
        let location: AuthMutation.Location = mode == "file" ? .file(authURL.path)
            : .keychain(service: CodexAuthStore.keychainService, account: store.keychainAccount)
        let before = try nativeBytes()
        let journal = Journal(mutations: [.init(location: location, before: before, after: before)])
        keychain.write(try JSONEncoder().encode(journal), service: AuthTransaction.service,
                       account: "codex|" + storageDigest(home.path, prefix: 32))
    }
    func adapter(_ processes: QuitRotationProcesses, terminationTimeout: TimeInterval = 15) -> CodexProviderAdapter {
        .init(authStore: store, transport: QuitRotationNoHTTP(), loginRunner: QuitRotationNoLogin(),
              processController: processes, terminationTimeout: terminationTimeout)
    }
    func expectSharedFilesPreserved() throws {
        #expect(try files.read(home.appendingPathComponent("config.toml")) == configuration)
        #expect(try files.read(home.appendingPathComponent("history.jsonl")) == history)
    }
    static func account(token: String, user: String = "fixture-user", workspace: String = "fixture-workspace") throws -> ImportedAccount {
        let claims: [String: Any] = ["sub": user, "email": "fixture@example.invalid",
            "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": workspace, "chatgpt_plan_type": "pro"]]
        let encoded = try ProviderJSON.data(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let raw = try ProviderJSON.data(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
            "tokens": ["access_token": token, "refresh_token": "fixture-refresh-" + token,
                       "id_token": "fixture.\(encoded).signature", "account_id": workspace]])
        return try ProviderAccountParser.codex(CredentialParser.codex(rawAuth: raw))
    }
}

@Suite("Codex token rotation during graceful quit")
struct CodexQuitRotationTests {
    @Test("Same-account relaunch retains the native token rotated during quit", arguments: ["file", "keyring", "auto"])
    func retainPostQuitNative(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let latest = try QuitRotationFixture.account(token: "fixture-post-quit")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.writeNative(latest.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(original.credential, account: original.account,
                                                                              relaunch: true, saveLatest: { await backup.save($0) })
        guard case .applied = result else { Issue.record("Expected successful same-account relaunch"); return }
        #expect(try await fixture.store.read().rawAuth == latest.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [latest.credential.rawAuth])
        #expect(await processes.quitCount == 1)
        #expect(await processes.launchCount == 1)
        try fixture.expectSharedFilesPreserved()
    }

    @Test("An explicit pending successor is not replaced by the same-account native generation", arguments: ["file", "keyring", "auto"])
    func preserveDeliberateSuccessor(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let latest = try QuitRotationFixture.account(token: "fixture-post-quit")
        let successor = try QuitRotationFixture.account(token: "fixture-vault-successor")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.writeNative(latest.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(successor.credential, account: successor.account,
                                                                              relaunch: true, saveLatest: { await backup.save($0) })
        guard case .applied = result else { Issue.record("Expected explicit successor to apply"); return }
        #expect(try await fixture.store.read().rawAuth == successor.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [latest.credential.rawAuth])
        #expect(await processes.launchCount == 1)
    }

    @Test("Different-account switching backs up the final source and applies the selected target", arguments: ["file", "keyring", "auto"])
    func preserveDifferentTarget(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let latest = try QuitRotationFixture.account(token: "fixture-post-quit")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user", workspace: "fixture-target-workspace")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.writeNative(latest.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(target.credential, account: target.account,
                                                                              relaunch: true, saveLatest: { await backup.save($0) })
        guard case .applied = result else { Issue.record("Expected selected different target to apply"); return }
        #expect(try await fixture.store.read().rawAuth == target.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [latest.credential.rawAuth])
        #expect(await processes.launchCount == 1)
        try fixture.expectSharedFilesPreserved()
    }

    @Test("A different identity after quit cannot restore the old current-account credential", arguments: ["file", "keyring", "auto"])
    func refuseChangedIdentity(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let external = try QuitRotationFixture.account(token: "fixture-external", user: "fixture-other-user", workspace: "fixture-other-workspace")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.writeNative(external.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(original.credential, account: original.account,
                                                                              relaunch: true, saveLatest: { await backup.save($0) })
        guard case .failed = result else { Issue.record("Changed current identity must refuse stale target"); return }
        #expect(try await fixture.store.read().rawAuth == external.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [external.credential.rawAuth])
        #expect(await processes.launchCount == 1)
    }

    @Test("A missing post-quit source cannot silently recreate an old same-account login", arguments: ["file", "keyring", "auto"])
    func refuseMissingPostQuitSource(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.removeNative() }
        let result = await fixture.adapter(processes).activatePreservingSource(original.credential, account: original.account,
                                                                              relaunch: true, saveLatest: { await backup.save($0) })
        guard case .failed = result else { Issue.record("Missing source must refuse stale target"); return }
        #expect(try await fixture.store.readIfPresent() == nil)
        #expect(await backup.saved.isEmpty)
        #expect(await processes.launchCount == 1)
    }

    @Test("Latest source backup failure retains final auth and reopens the confirmed stopped desktop", arguments: ["file", "keyring", "auto"])
    func refuseBackupFailure(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let latest = try QuitRotationFixture.account(token: "fixture-post-quit")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let processes = QuitRotationProcesses { try fixture.writeNative(latest.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(original.credential, account: original.account,
                                                                              relaunch: true, saveLatest: { _ in throw AgentSwapError.storage("Synthetic backup failure") })
        guard case .failed(let message) = result else { Issue.record("Failed backup must refuse activation"); return }
        #expect(try await fixture.store.read().rawAuth == latest.credential.rawAuth)
        #expect(message.contains("Synthetic backup failure"))
        #expect(message.contains("다시 열었습니다"))
        #expect(await processes.launchCount == 1)
    }

    @Test("An external rotation after backing up adopted auth still trips the generation fence", arguments: ["file", "keyring", "auto"])
    func refuseChangedGenerationAfterBackup(mode: String) async throws {
        let original = try QuitRotationFixture.account(token: "fixture-original")
        let latest = try QuitRotationFixture.account(token: "fixture-post-quit")
        let newer = try QuitRotationFixture.account(token: "fixture-external-newer")
        let fixture = try QuitRotationFixture(mode: mode, source: original.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses { try fixture.writeNative(latest.credential) }
        let result = await fixture.adapter(processes).activatePreservingSource(original.credential, account: original.account,
                                                                              relaunch: true, saveLatest: {
            await backup.save($0)
            try fixture.writeNative(newer.credential)
        })
        guard case .failed = result else { Issue.record("Changed generation must refuse adopted auth"); return }
        #expect(try await fixture.store.read().rawAuth == newer.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [latest.credential.rawAuth])
        #expect(await processes.launchCount == 1)
    }

    @Test("Failure to reopen the stopped desktop remains a failed switch", arguments: ["file", "keyring", "auto"])
    func reopeningFailureStaysFailed(mode: String) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let processes = QuitRotationProcesses(launchFails: true, onQuit: {})
        let result = await fixture.adapter(processes).activatePreservingSource(source.credential, account: source.account,
                                                                             relaunch: true, saveLatest: { _ in throw AgentSwapError.storage("Synthetic backup failure") })
        guard case .failed(let message) = result else { Issue.record("Reopening failure must not change the switch outcome"); return }
        #expect(message.contains("Synthetic backup failure"))
        #expect(message.contains("다시 열기에 실패"))
        #expect(try await fixture.store.read().rawAuth == source.credential.rawAuth)
        #expect(await processes.launchCount == 1)
    }

    @Test("Respawned external consumers before backup allow only safe desktop reopening", arguments: ["file", "keyring", "auto"], [CodexConsumerKind.commandLine, .ide, .daemon, .desktop])
    func pendingBeforeBackup(mode: String, kind: CodexConsumerKind) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses(respawnConsumers: [.init(pid: 2, kind: kind, name: "Synthetic respawn")], onQuit: {})
        let result = await fixture.adapter(processes).activatePreservingSource(target.credential, account: target.account,
                                                                             relaunch: true, saveLatest: { await backup.save($0) })
        guard case .pendingRelaunch(let message) = result else { Issue.record("Respawned consumer must keep the switch pending"); return }
        #expect(try await fixture.store.read().rawAuth == source.credential.rawAuth)
        #expect(await backup.saved.isEmpty)
        #expect(await processes.launchCount == (kind == .desktop ? 0 : 1))
        #expect(message.contains("다시 열었습니다") == (kind != .desktop))
    }

    @Test("Respawned consumers after backup retain pending status without applying target auth", arguments: ["file", "keyring", "auto"], [CodexConsumerKind.commandLine, .ide, .daemon, .desktop])
    func pendingAfterBackup(mode: String, kind: CodexConsumerKind) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let backup = QuitRotationBackup()
        let processes = QuitRotationProcesses(onQuit: {})
        let result = await fixture.adapter(processes).activatePreservingSource(target.credential, account: target.account,
                                                                             relaunch: true, saveLatest: {
            await backup.save($0)
            await processes.respawn([.init(pid: 2, kind: kind, name: "Synthetic respawn")])
        })
        guard case .pendingRelaunch = result else { Issue.record("Respawned consumer must keep the switch pending"); return }
        #expect(try await fixture.store.read().rawAuth == source.credential.rawAuth)
        #expect(await backup.saved.map(\.credential.rawAuth) == [source.credential.rawAuth])
        #expect(await processes.launchCount == (kind == .desktop ? 0 : 1))
    }

    @Test("Pending recovery, unknown configuration or auth, and unreliable scanning block reopening", arguments: ["file", "keyring", "auto"], ["journal", "configuration", "auth", "scanner"])
    func unsafeStateNeverReopens(mode: String, blocker: String) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let processes = QuitRotationProcesses(onQuit: {})
        let unknownRaw = try ProviderJSON.data(["future_store": true])
        let result = await fixture.adapter(processes).activatePreservingSource(target.credential, account: target.account,
                                                                             relaunch: true, saveLatest: { _ in
            switch blocker {
            case "journal": try fixture.leavePendingRecovery()
            case "configuration": try fixture.files.write(Data("cli_auth_credentials_store = 'future-mode'\n".utf8), to: fixture.home.appendingPathComponent("config.toml"))
            case "auth":
                if mode == "file" { try fixture.files.write(unknownRaw, to: fixture.authURL) }
                else { fixture.keychain.write(unknownRaw, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) }
            default: await processes.makeScanUnreliable()
            }
            throw AgentSwapError.storage("Synthetic unsafe-state backup failure")
        })
        guard case .failed(let message) = result else { Issue.record("Unsafe state must remain failed"); return }
        #expect(await processes.launchCount == 0)
        #expect(!message.contains("다시 열었습니다"))
        #expect(try fixture.nativeBytes() == (blocker == "auth" ? unknownRaw : source.credential.rawAuth))
    }

    @Test("Refused and unconfirmed quit never authorize recovery reopening", arguments: ["file", "keyring", "auto"], [false, true])
    func noConfirmedStopNeverReopens(mode: String, acceptsButStays: Bool) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let processes = QuitRotationProcesses(accepted: acceptsButStays, staysRunning: acceptsButStays, onQuit: {})
        let result = await fixture.adapter(processes, terminationTimeout: 0).activatePreservingSource(target.credential, account: target.account,
                                                                                                    relaunch: true, saveLatest: { _ in Issue.record("Unconfirmed quit must not reach backup") })
        guard case .pendingRelaunch = result else { Issue.record("Quit refusal must keep switch pending"); return }
        #expect(try await fixture.store.read().rawAuth == source.credential.rawAuth)
        #expect(await processes.quitCount == 1)
        #expect(await processes.launchCount == 0)
    }

    @Test("Launch failure after a successful switch stays applied and does not reopen a second time", arguments: ["file", "keyring", "auto"])
    func appliedAuthLaunchFailure(mode: String) async throws {
        let source = try QuitRotationFixture.account(token: "fixture-original")
        let target = try QuitRotationFixture.account(token: "fixture-target", user: "fixture-target-user")
        let fixture = try QuitRotationFixture(mode: mode, source: source.credential); defer { fixture.cleanup() }
        let processes = QuitRotationProcesses(launchFails: true, onQuit: {})
        let result = await fixture.adapter(processes).activatePreservingSource(target.credential, account: target.account,
                                                                             relaunch: true, saveLatest: { _ in })
        guard case .applied(let message) = result else { Issue.record("Auth was applied before launch failed"); return }
        #expect(message.contains("재실행 실패"))
        #expect(try await fixture.store.read().rawAuth == target.credential.rawAuth)
        #expect(await processes.launchCount == 1)
    }
}
