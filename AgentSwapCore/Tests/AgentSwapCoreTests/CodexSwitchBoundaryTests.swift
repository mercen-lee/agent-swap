import Foundation
import Testing
@testable import AgentSwapCore

private struct CodexBoundaryConfiguration: CodexConfigurationGuard {
    func validateDefaultProfile() {}
}

private struct CodexBoundaryNoLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

private actor CodexBoundaryNoHTTP: ProviderHTTPTransport {
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        throw AgentSwapError.network("Unexpected fixture HTTP request")
    }
}

private actor CodexBoundaryProcesses: CodexProcessControlling {
    private var scanCount = 0
    private var hooks: [Int: @Sendable () throws -> Void] = [:]
    private(set) var quitCount = 0
    private(set) var relaunchCount = 0

    func onScan(_ number: Int, _ hook: @escaping @Sendable () throws -> Void) { hooks[number] = hook }
    func scan() -> CodexProcessScan {
        scanCount += 1
        do { try hooks.removeValue(forKey: scanCount)?() }
        catch { return .init(reliable: false) }
        return .init()
    }
    func installation() -> CodexDesktopInstallation? { nil }
    func requestDesktopTermination() -> Bool { quitCount += 1; return true }
    func relaunchDesktop() { relaunchCount += 1 }
}

private actor CodexBoundaryBackup {
    private(set) var values: [ImportedAccount] = []
    func save(_ value: ImportedAccount) { values.append(value) }
}

private struct CodexBoundaryDriverOutcome<Value: Sendable>: Sendable {
    let entered: Bool
    let value: Value?
}

// The lock protects one result handoff only. No caller holds it across an await or waits for
// another task while holding it; Dispatch completes the result outside the cooperative pool.
// Replace this unchecked wrapper with Mutex-owned state when the minimum OS supports it.
private final class CodexBoundaryDriver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CodexBoundaryDriverOutcome<Value>?
    private var waiter: CheckedContinuation<CodexBoundaryDriverOutcome<Value>, Never>?

    func complete(_ value: CodexBoundaryDriverOutcome<Value>) {
        let continuation = lock.withLock {
            outcome = value
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }

    func value() async -> CodexBoundaryDriverOutcome<Value> {
        await withCheckedContinuation { continuation in
            let ready: CodexBoundaryDriverOutcome<Value>? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

// The condition protects the simulated synchronous file boundary. Enter/cancel/release is
// driven by Dispatch, so releasing a blocked actor never needs another cooperative worker.
// Both waits have independent bounds, and the test checks them instead of hiding a timeout.
private final class CodexBoundaryGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false

    func block() {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(3)
        while !released {
            if !condition.wait(until: deadline), !released {
                timedOut = true
                released = true
                condition.broadcast()
            }
        }
    }

    func driveWhenEntered<Value: Sendable>(_ action: @escaping @Sendable () -> Value) -> CodexBoundaryDriver<Value> {
        let driver = CodexBoundaryDriver<Value>()
        DispatchQueue.global(qos: .userInitiated).async {
            driver.complete(self.performWhenEntered(action))
        }
        return driver
    }

    private func performWhenEntered<Value: Sendable>(_ action: @Sendable () -> Value) -> CodexBoundaryDriverOutcome<Value> {
        defer { release() }
        condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while !entered {
            if !condition.wait(until: deadline), !entered {
                condition.unlock()
                return .init(entered: false, value: nil)
            }
        }
        condition.unlock()
        return .init(entered: true, value: action())
    }

    func didTimeOut() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return timedOut
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

// All fault decisions and logs are protected by one lock. The underlying operations access only
// this test's temporary home, and the blocking read gate is consumed before entering its wait.
private final class CodexBoundaryFiles: AuthFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let disk = AtomicAuthFileAccess()
    private var nextReadFailure: (URL, AgentSwapError)?
    private var readFailureCount = 0
    private var readGate: (URL, CodexBoundaryGate)?
    private var cancelWrite: URL?
    private var writeHook: (URL, @Sendable () throws -> Void)?
    private var writes: [(URL, Data)] = []

    func read(_ url: URL) throws -> Data? {
        let decision = lock.withLock { () -> (AgentSwapError?, CodexBoundaryGate?) in
            if let (path, error) = nextReadFailure, path == url.standardizedFileURL {
                nextReadFailure = nil
                readFailureCount += 1
                return (error, nil)
            }
            if let (path, gate) = readGate, path == url.standardizedFileURL {
                readGate = nil
                return (nil, gate)
            }
            return (nil, nil)
        }
        if let error = decision.0 { throw error }
        decision.1?.block()
        return try disk.read(url)
    }

    func write(_ data: Data, to url: URL) throws {
        try disk.write(data, to: url)
        let decision = lock.withLock { () -> (Bool, (@Sendable () throws -> Void)?) in
            writes.append((url.standardizedFileURL, data))
            var hook: (@Sendable () throws -> Void)?
            if let (path, action) = writeHook, path == url.standardizedFileURL { writeHook = nil; hook = action }
            if cancelWrite == url.standardizedFileURL { cancelWrite = nil; return (true, hook) }
            return (false, hook)
        }
        try decision.1?()
        if decision.0 { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func delete(_ url: URL) throws { try disk.delete(url) }
    func failNextRead(at url: URL, authentication: Bool = false) {
        lock.withLock { nextReadFailure = (url.standardizedFileURL, authentication ? .authentication("Fixture invalid source authentication") : .storage("Fixture auth read denied")) }
    }
    func blockNextRead(at url: URL, with gate: CodexBoundaryGate) { lock.withLock { readGate = (url.standardizedFileURL, gate) } }
    func cancelCurrentTaskAfterNextWrite(to url: URL) { lock.withLock { cancelWrite = url.standardizedFileURL } }
    func afterNextWrite(to url: URL, _ hook: @escaping @Sendable () throws -> Void) { lock.withLock { writeHook = (url.standardizedFileURL, hook) } }
    func failures() -> Int { lock.withLock { readFailureCount } }
    func wrote(_ data: Data, to url: URL) -> Bool {
        lock.withLock { writes.contains { $0.0 == url.standardizedFileURL && $0.1 == data } }
    }
}

// Every mutable credential, fault and hook counter is guarded by one lock. Hooks execute after
// releasing that lock, and can write only through the separate temporary-files fixture.
private final class CodexBoundaryKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes: [(String, Data)] = []
    private var cancelWrite: String?
    private var failedWrite: String?
    private var fallbackReadKey: String?
    private var fallbackReadsRemaining = 0
    private var fallbackHook: (@Sendable () throws -> Void)?
    private var armedFallbackHook: (@Sendable () throws -> Void)?
    private var failureCount = 0
    private var hookCount = 0
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }

    func read(service: String, account: String) throws -> Data? {
        let identifier = key(service, account)
        let result = lock.withLock { () -> (Data?, (@Sendable () throws -> Void)?) in
            var hook: (@Sendable () throws -> Void)?
            if fallbackReadKey == identifier, fallbackReadsRemaining > 0 {
                fallbackReadsRemaining -= 1
                if fallbackReadsRemaining == 0 {
                    hook = fallbackHook
                    fallbackHook = nil
                    fallbackReadKey = nil
                    hookCount += 1
                }
            }
            return (values[identifier], hook)
        }
        try result.1?()
        return result.0
    }

    func write(_ data: Data, service: String, account: String) throws {
        let identifier = key(service, account)
        let decision = lock.withLock { () -> (Bool, Bool) in
            if failedWrite == identifier {
                failedWrite = nil
                failureCount += 1
                fallbackReadKey = identifier
                // Recovery checks the before-image, then reads it again while restoring. The
                // following native read is the adapter store's final absence/fallback check.
                fallbackReadsRemaining = 3
                fallbackHook = armedFallbackHook
                armedFallbackHook = nil
                return (true, false)
            }
            values[identifier] = data
            writes.append((identifier, data))
            if cancelWrite == identifier { cancelWrite = nil; return (false, true) }
            return (false, false)
        }
        if decision.0 { throw AgentSwapError.storage("Fixture native Keychain write denied") }
        if decision.1 { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func delete(service: String, account: String) {
        lock.withLock { _ = values.removeValue(forKey: key(service, account)) }
    }
    func cancelCurrentTaskAfterNextWrite(service: String, account: String) { lock.withLock { cancelWrite = key(service, account) } }
    func failNativeWriteThenChangeFallback(service: String, account: String, _ hook: @escaping @Sendable () throws -> Void) {
        lock.withLock { failedWrite = key(service, account); armedFallbackHook = hook }
    }
    func nativeWriteFailures() -> Int { lock.withLock { failureCount } }
    func fallbackChanges() -> Int { lock.withLock { hookCount } }
    func wrote(_ data: Data, service: String, account: String) -> Bool {
        lock.withLock { writes.contains { $0.0 == key(service, account) && $0.1 == data } }
    }
    func journalCount() -> Int { lock.withLock { values.keys.filter { $0.hasPrefix(AuthTransaction.service + "|") }.count } }
}

private struct CodexBoundaryFixture: Sendable {
    let home: URL
    let mode: String
    let files = CodexBoundaryFiles()
    let keychain = CodexBoundaryKeychain()
    let store: CodexAuthStore
    let fileSource: ImportedAccount
    let secureSource: ImportedAccount
    let target: ImportedAccount
    let originalFile: Data?
    let originalKeychain: Data?
    let configuration: Data
    let history = Data("Keep the existing Codex session history".utf8)
    var authURL: URL { home.appendingPathComponent("auth.json") }
    var configURL: URL { home.appendingPathComponent("config.toml") }
    var historyURL: URL { home.appendingPathComponent("history.jsonl") }
    var effectiveSource: ImportedAccount { mode == "file" || originalKeychain == nil ? fileSource : secureSource }

    init(mode: String = "file", clean: Bool = false, seedKeychain: Bool = true) throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AgentSwapCodexBoundaryTests-\(UUID().uuidString)")
        self.mode = mode
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fileSource = try Self.account(token: "fixture-file-source")
        secureSource = try Self.account(token: "fixture-keychain-source")
        target = try Self.account(token: "fixture-target", user: "fixture-target-user", workspace: "fixture-target-workspace")
        originalFile = clean ? nil : fileSource.credential.rawAuth
        originalKeychain = clean || !seedKeychain ? nil : secureSource.credential.rawAuth
        configuration = Data("cli_auth_credentials_store = \"\(mode)\"\n".utf8)
        store = CodexAuthStore(home: home, keychain: keychain, files: files, configurationGuard: CodexBoundaryConfiguration())
        try files.write(configuration, to: configURL)
        try files.write(history, to: historyURL)
        if let originalFile { try files.write(originalFile, to: authURL) }
        if let originalKeychain { try keychain.write(originalKeychain, service: CodexAuthStore.keychainService, account: store.keychainAccount) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
    static func account(token: String, user: String = "fixture-source-user", workspace: String = "fixture-source-workspace") throws -> ImportedAccount {
        let claims: [String: Any] = ["sub": user, "email": "fixture@example.invalid",
                                    "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": workspace, "chatgpt_plan_type": "pro"]]
        let encoded = try ProviderJSON.data(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let raw = try ProviderJSON.data(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
                                        "tokens": ["access_token": token, "refresh_token": "fixture-refresh", "id_token": "fixture.\(encoded).signature", "account_id": workspace]])
        return try ProviderAccountParser.codex(CredentialParser.codex(rawAuth: raw))
    }
    func adapter(_ processes: CodexBoundaryProcesses) -> CodexProviderAdapter {
        .init(authStore: store, transport: CodexBoundaryNoHTTP(), loginRunner: CodexBoundaryNoLogin(), processController: processes)
    }
    func expectNative(file: Data?, secure: Data?) throws {
        #expect(try files.read(authURL) == file)
        #expect(try keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == secure)
        #expect(try files.read(configURL) == configuration)
        #expect(try files.read(historyURL) == history)
        #expect(keychain.journalCount() == 0)
    }
}

@Suite("Codex auth switching boundaries")
struct CodexSwitchBoundaryTests {
    @Test("A source token rotated during backup is retained instead of overwritten", arguments: ["file", "keyring", "auto"])
    func sourceRotationDuringBackupFailsClosed(mode: String) async throws {
        let fixture = try CodexBoundaryFixture(mode: mode); defer { fixture.cleanup() }
        let external = try CodexBoundaryFixture.account(token: "fixture-external-latest")
        let backup = CodexBoundaryBackup(), processes = CodexBoundaryProcesses()
        let result = await fixture.adapter(processes).activatePreservingSource(fixture.target.credential, account: fixture.target.account,
                                                                             relaunch: false, saveLatest: { current in
            await backup.save(current)
            if mode == "file" { try fixture.files.write(external.credential.rawAuth, to: fixture.authURL) }
            else { try fixture.keychain.write(external.credential.rawAuth, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) }
        })
        guard case .failed = result else { Issue.record("Changed source generation must refuse activation"); return }
        #expect(await backup.values.count == 1)
        #expect(await backup.values.first?.credential.rawAuth == fixture.effectiveSource.credential.rawAuth)
        try fixture.expectNative(file: mode == "file" ? external.credential.rawAuth : fixture.originalFile,
                                 secure: mode == "file" ? fixture.originalKeychain : external.credential.rawAuth)
        #expect(await processes.relaunchCount == 0)
    }

    @Test("Auth appearing after the clean source read cannot become an unbacked source", arguments: ["file", "keyring", "auto"])
    func firstActivationSourceAppearsDuringFinalScan(mode: String) async throws {
        let fixture = try CodexBoundaryFixture(mode: mode, clean: true); defer { fixture.cleanup() }
        let appeared = try CodexBoundaryFixture.account(token: "fixture-appeared-source")
        let processes = CodexBoundaryProcesses(), backup = CodexBoundaryBackup()
        await processes.onScan(3) {
            if mode == "file" { try fixture.files.write(appeared.credential.rawAuth, to: fixture.authURL) }
            else { try fixture.keychain.write(appeared.credential.rawAuth, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) }
        }
        let result = await fixture.adapter(processes).activatePreservingSource(fixture.target.credential, account: fixture.target.account,
                                                                             relaunch: false, saveLatest: { await backup.save($0) })
        guard case .failed = result else { Issue.record("An appeared source must refuse clean-profile activation"); return }
        #expect(await backup.values.isEmpty)
        try fixture.expectNative(file: mode == "file" ? appeared.credential.rawAuth : nil, secure: mode == "file" ? nil : appeared.credential.rawAuth)
    }

    @Test("A source read error cannot fall through as a clean profile", arguments: [false, true])
    func sourceReadFailureFailsClosed(authentication: Bool) async throws {
        let fixture = try CodexBoundaryFixture(); defer { fixture.cleanup() }
        let processes = CodexBoundaryProcesses(), backup = CodexBoundaryBackup()
        await processes.onScan(2) { fixture.files.failNextRead(at: fixture.authURL, authentication: authentication) }
        let result = await fixture.adapter(processes).activatePreservingSource(fixture.target.credential, account: fixture.target.account,
                                                                             relaunch: false, saveLatest: { await backup.save($0) })
        guard case .failed = result else { Issue.record("Unreadable source auth must refuse activation"); return }
        #expect(fixture.files.failures() == 1)
        #expect(await backup.values.isEmpty)
        try fixture.expectNative(file: fixture.originalFile, secure: fixture.originalKeychain)
    }

    @Test("Cancellation while activation waits for the auth-store actor prevents all native writes", .timeLimit(.minutes(1)), arguments: ["file", "keyring", "auto"])
    func cancellationWhileActorIsOccupied(mode: String) async throws {
        let fixture = try CodexBoundaryFixture(mode: mode); defer { fixture.cleanup() }
        let gate = CodexBoundaryGate()
        fixture.files.blockNextRead(at: fixture.configURL, with: gate)
        let driver = gate.driveWhenEntered {
            let activation = Task { try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.effectiveSource.credential.rawAuth) }
            activation.cancel()
            return activation
        }
        let occupyingRead = Task { try await fixture.store.storageMode() }
        let outcome = await driver.value()
        _ = try await occupyingRead.value
        let activation = try #require(outcome.value, "Independent cancellation controller did not reach the occupied actor")
        await #expect(throws: (any Error).self) { try await activation.value }
        #expect(outcome.entered && !gate.didTimeOut(), "Independent cancellation controller must release the fixture before its watchdog")
        try fixture.expectNative(file: fixture.originalFile, secure: fixture.originalKeychain)
        #expect(!fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL))
        #expect(!fixture.keychain.wrote(fixture.target.credential.rawAuth, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount))
    }

    @Test("Cancellation after activation enters its native critical section prevents forward writes", .timeLimit(.minutes(1)))
    func cancellationAfterActorEntry() async throws {
        let fixture = try CodexBoundaryFixture(); defer { fixture.cleanup() }
        let gate = CodexBoundaryGate()
        fixture.files.blockNextRead(at: fixture.configURL, with: gate)
        let activation = Task { try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.fileSource.credential.rawAuth) }
        let driver = gate.driveWhenEntered { activation.cancel() }
        let outcome = await driver.value()
        await #expect(throws: (any Error).self) { try await activation.value }
        #expect(outcome.entered && !gate.didTimeOut(), "Independent cancellation controller must release the fixture before its watchdog")
        try fixture.expectNative(file: fixture.originalFile, secure: fixture.originalKeychain)
        #expect(!fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL))
    }

    @Test("Cancellation after the first native write restores every credential and file mirror", arguments: ["file", "keyring", "auto", "auto-absent"])
    func cancellationAfterNativeWriteRollsBack(mode: String) async throws {
        let fixture = try CodexBoundaryFixture(mode: mode == "auto-absent" ? "auto" : mode, seedKeychain: mode != "auto-absent")
        defer { fixture.cleanup() }
        if mode == "file" { fixture.files.cancelCurrentTaskAfterNextWrite(to: fixture.authURL) }
        else { fixture.keychain.cancelCurrentTaskAfterNextWrite(service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) }
        let activation = Task { try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.effectiveSource.credential.rawAuth) }
        await #expect(throws: (any Error).self) { try await activation.value }
        if mode == "file" { #expect(fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL)) }
        else { #expect(fixture.keychain.wrote(fixture.target.credential.rawAuth, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount)) }
        try fixture.expectNative(file: fixture.originalFile, secure: fixture.originalKeychain)
    }

    @Test("Auto fallback retains unknown or API-key auth that appears after native rollback", arguments: ["unknown", "api-key"])
    func autoFallbackDoesNotOverwriteChangedFile(shape: String) async throws {
        let fixture = try CodexBoundaryFixture(mode: "auto", seedKeychain: false); defer { fixture.cleanup() }
        let external: Data
        if shape == "api-key" { external = try ProviderJSON.data(["OPENAI_API_KEY": "fixture-private-api-key", "auth_mode": "apikey"]) }
        else {
            var object = try authObject(fixture.fileSource.credential.rawAuth, name: "Fixture external auth")
            object["future_auth_store"] = ["fixture": true]
            external = try ProviderJSON.data(object)
        }
        fixture.keychain.failNativeWriteThenChangeFallback(service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) {
            try fixture.files.write(external, to: fixture.authURL)
        }
        await #expect(throws: (any Error).self) {
            try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.fileSource.credential.rawAuth)
        }
        #expect(fixture.keychain.nativeWriteFailures() == 1)
        #expect(fixture.keychain.fallbackChanges() == 1)
        try fixture.expectNative(file: external, secure: nil)
        #expect(!fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL))
    }

    @Test("Auto fallback restores its file when a new Keychain authority appears before commit")
    func autoFallbackNewKeychainIsPreserved() async throws {
        let fixture = try CodexBoundaryFixture(mode: "auto", seedKeychain: false); defer { fixture.cleanup() }
        let external = try CodexBoundaryFixture.account(token: "fixture-new-keychain-authority")
        fixture.keychain.failNativeWriteThenChangeFallback(service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) {}
        fixture.files.afterNextWrite(to: fixture.authURL) {
            try fixture.keychain.write(external.credential.rawAuth, service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount)
        }
        await #expect(throws: (any Error).self) {
            try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.fileSource.credential.rawAuth)
        }
        #expect(fixture.keychain.nativeWriteFailures() == 1)
        #expect(fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL))
        try fixture.expectNative(file: fixture.originalFile, secure: external.credential.rawAuth)
    }

    @Test("Cancellation after auto fallback writes its target file restores the original file")
    func cancellationAfterFallbackFileWriteRollsBack() async throws {
        let fixture = try CodexBoundaryFixture(mode: "auto", seedKeychain: false); defer { fixture.cleanup() }
        fixture.keychain.failNativeWriteThenChangeFallback(service: CodexAuthStore.keychainService, account: fixture.store.keychainAccount) {}
        fixture.files.cancelCurrentTaskAfterNextWrite(to: fixture.authURL)
        let activation = Task { try await fixture.store.activate(fixture.target.credential, expectedSourceAuth: fixture.fileSource.credential.rawAuth) }
        await #expect(throws: (any Error).self) { try await activation.value }
        #expect(fixture.keychain.nativeWriteFailures() == 1)
        #expect(fixture.files.wrote(fixture.target.credential.rawAuth, to: fixture.authURL))
        try fixture.expectNative(file: fixture.originalFile, secure: nil)
    }
}
