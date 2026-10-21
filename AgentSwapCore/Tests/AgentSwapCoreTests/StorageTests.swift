import Foundation
import Testing
@testable import AgentSwapCore

// Safety invariant: every mutable dictionary and fault counter is accessed under the same NSLock.
private final class TestKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writeFaults: [String: Int] = [:]
    private var readFaults: Set<String> = []
    private var cancelOnWrite: Set<String> = []
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            let key = key(service, account)
            if readFaults.contains(key) { throw AgentSwapError.storage("Fixture Keychain read failure") }
            return values[key]
        }
    }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let key = key(service, account)
            if let remaining = writeFaults[key] {
                if remaining == 0 { writeFaults.removeValue(forKey: key); throw AgentSwapError.storage("Fixture Keychain write failure") }
                writeFaults[key] = remaining - 1
            }
            values[key] = data
            if cancelOnWrite.remove(key) != nil { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    func delete(service: String, account: String) throws { lock.withLock { values.removeValue(forKey: key(service, account)); return () } }
    func failWrite(service: String, account: String, afterSuccesses: Int = 0) { lock.withLock { writeFaults[key(service, account)] = afterSuccesses } }
    func failRead(service: String, account: String) { _ = lock.withLock { readFaults.insert(key(service, account)) } }
    func cancelCurrentTaskOnWrite(service: String, account: String) { _ = lock.withLock { cancelOnWrite.insert(key(service, account)) } }
    func journalCount() -> Int { lock.withLock { values.keys.filter { $0.hasPrefix(AuthTransaction.service + "|") }.count } }
}

// Safety invariant: the one-shot failure is guarded by a lock; filesystem operations use independent temp paths.
private final class FaultFiles: AuthFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var failURL: URL?
    private let files = AtomicAuthFileAccess()
    func failNextWrite(to url: URL) { lock.withLock { failURL = url } }
    func read(_ url: URL) throws -> Data? { try files.read(url) }
    func write(_ data: Data, to url: URL) throws {
        let fail = lock.withLock { if failURL == url { failURL = nil; return true }; return false }
        if fail { throw AgentSwapError.storage("Fixture file write failure") }
        try files.write(data, to: url)
    }
    func delete(_ url: URL) throws { try files.delete(url) }
}

private struct StorageFixture {
    let directory: URL
    let keychain = TestKeychain()
    let files = AtomicAuthFileAccess()
    var configurationGuard: SystemCodexConfigurationGuard { .init(configurationURLs: [], checkManagedPreferences: false) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func claude(token: String = "fixture-old", extra: [String: Any] = [:]) throws -> Credential {
        var root = extra
        root["claudeAiOauth"] = ["accessToken": token, "refreshToken": "fixture-refresh", "expiresAt": 1_900_000_000_000]
        return try CredentialParser.claude(rawAuth: authData(root), accountMetadata: authData(["accountUuid": "fixture-user", "organizationUuid": "fixture-workspace"]))
    }
    func codex(token: String = "fixture-old") throws -> Credential {
        try CredentialParser.codex(rawAuth: authData(["auth_mode": "chatgpt", "tokens": ["access_token": token, "id_token": "fixture.id.token", "refresh_token": "fixture-refresh", "account_id": "fixture-workspace"], "OPENAI_API_KEY": NSNull()]))
    }
    func codexStore(mode: String) throws -> CodexAuthStore {
        try files.write(Data("cli_auth_credentials_store = \"\(mode)\"\n".utf8), to: directory.appendingPathComponent("config.toml"))
        return CodexAuthStore(home: directory, keychain: keychain, configurationGuard: configurationGuard)
    }
}

@Suite("Credential storage and transactions")
struct StorageTests {
    @Test("Cancellation after the first native mutation still restores the complete previous authentication")
    func claudeCancellationAfterPartialNativeWriteRollsBack() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let source = try fixture.claude(), target = try fixture.claude(token: "fixture-target")
        try fixture.keychain.write(source.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let config = try authData(["oauthAccount": authObject(#require(source.accountMetadata), name: "Fixture"), "sharedSetting": "preserve"])
        try fixture.files.write(config, to: store.configURL)
        fixture.keychain.cancelCurrentTaskOnWrite(service: store.keychainService, account: store.keychainAccount)
        let operation = Task { try await store.activate(target) }
        await #expect(throws: AgentSwapError.self) { try await operation.value }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == source.rawAuth)
        #expect(try fixture.files.read(store.configURL) == config)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A first activation cannot overwrite credentials that appeared after the absent-source read")
    func claudeSourceAppearsAfterAbsenceProof() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        #expect(try await store.readIfPresent() == nil)
        let external = try fixture.claude(token: "fixture-external"), target = try fixture.claude(token: "fixture-target")
        try fixture.keychain.write(external.rawAuth, service: store.keychainService, account: store.keychainAccount)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target, expectedSourceAbsent: true) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == external.rawAuth)
        #expect(try fixture.files.read(store.configURL) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Claude verifies the prepared source identity and token generation inside its native locks", arguments: ["token", "identity", "malformed"])
    func claudePreparedSourceChanged(change: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let source = try fixture.claude(), target = try fixture.claude(token: "fixture-target")
        let identity = AccountIdentity(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace")
        let live = change == "token" ? try fixture.claude(token: "fixture-external-rotation") : source
        try fixture.keychain.write(live.rawAuth, service: store.keychainService, account: store.keychainAccount)
        var config: [String: Any] = ["sharedSetting": "preserve"]
        config["oauthAccount"] = change == "malformed" ? "unknown-schema" :
            ["accountUuid": change == "identity" ? "fixture-external-user" : identity.userID, "organizationUuid": identity.workspaceID]
        let bytes = try authData(config)
        try fixture.files.write(bytes, to: store.configURL)
        await #expect(throws: AgentSwapError.self) {
            try await store.activate(target, expectedSourceIdentity: identity, expectedSourceAuth: source.rawAuth)
        }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == live.rawAuth)
        #expect(try fixture.files.read(store.configURL) == bytes)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("The exact prepared auth generation permits profile-identified metadata without a native metadata cache")
    func claudePreparedSourceWithoutMetadataCache() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let source = try fixture.claude(), target = try fixture.claude(token: "fixture-target")
        try fixture.keychain.write(source.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try fixture.files.write(authData(["sharedSetting": "preserve"]), to: store.configURL)
        try await store.activate(target, expectedSourceIdentity: .init(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace"), expectedSourceAuth: source.rawAuth)
        #expect(try await store.read().accessToken == "fixture-target")
        let config = try authObject(#require(try fixture.files.read(store.configURL)), name: "Fixture")
        #expect(config["sharedSetting"] as? String == "preserve")
    }

    @Test("Claude matches the installed CLI username allowlist", arguments: [
        ("normal_user-1.2", "ignored", "normal_user-1.2"),
        ("fixture@example.invalid", "normal", "claude-code-user"),
        ("사용자", "normal", "claude-code-user"),
        ("", "system-user", "system-user"),
        ("", "fixture@example.invalid", "claude-code-user"),
        ("with space", "normal", "claude-code-user"),
        ("", "", "claude-code-user")
    ])
    func claudeKeychainUsername(environmentUser: String, systemUser: String, expected: String) {
        #expect(ClaudeAuthStore.keychainAccountName(environmentUser: environmentUser, systemUser: systemUser) == expected)
        #expect(ClaudeAuthStore.keychainAccountName(environmentUser: nil, systemUser: "system-user") == "system-user")
        #expect(ClaudeAuthStore.keychainAccountName(environmentUser: nil, systemUser: nil) == "claude-code-user")
    }

    @Test("Claude reads and cleans isolated fallback-account credentials without touching the default store")
    func claudeFallbackUsernameReadsAndCleansIsolated() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let invalidUsername = "fixture@example.invalid", fallback = "claude-code-user"
        let native = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, environmentUser: invalidUsername, systemUser: invalidUsername)
        let isolated = ClaudeAuthStore(home: fixture.directory, configDirectory: fixture.directory.appendingPathComponent("isolated"),
                                       keychain: fixture.keychain, environmentUser: invalidUsername, systemUser: invalidUsername)
        let credential = try fixture.claude(token: "fixture-fallback"), defaultCredential = try fixture.claude(token: "fixture-default")
        #expect(native.keychainAccount == fallback)
        #expect(isolated.keychainAccount == fallback)
        // The old raw USER query misses the item created by Claude Code itself.
        try fixture.keychain.write(credential.rawAuth, service: isolated.keychainService, account: fallback)
        try fixture.files.write(authData(["oauthAccount": authObject(#require(credential.accountMetadata), name: "Fixture")]), to: isolated.configURL)
        #expect(try fixture.keychain.read(service: isolated.keychainService, account: invalidUsername) == nil)
        #expect(try await isolated.read().accessToken == "fixture-fallback")
        #expect(try ProviderAccountParser.claude(await isolated.read()).account.identity == AccountIdentity(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace"))
        try fixture.keychain.write(defaultCredential.rawAuth, service: native.keychainService, account: fallback)
        try fixture.files.write(credential.rawAuth, to: isolated.configDirectory.appendingPathComponent(".credentials.json"))
        try await isolated.cleanupIsolatedAuthentication()
        #expect(try fixture.keychain.read(service: isolated.keychainService, account: fallback) == nil)
        #expect(try fixture.files.read(isolated.configDirectory.appendingPathComponent(".credentials.json")) == nil)
        #expect(try fixture.keychain.read(service: native.keychainService, account: fallback) == defaultCredential.rawAuth)
    }

    @Test("Application credentials round-trip through the injected Keychain")
    func secretStore() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = KeychainSecretStore(keychain: fixture.keychain), id = UUID(), credential = try fixture.claude()
        try await store.save(credential, accountID: id)
        #expect(try await store.load(accountID: id) == credential)
        try await store.delete(accountID: id)
        #expect(try await store.load(accountID: id) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test("State cache preserves dates and refuses corrupt or newer state")
    func stateStore() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = JSONStateStore(directory: fixture.directory)
        var state = PersistedState()
        let id = UUID(); state.lastSwitch[.codex] = Date(timeIntervalSince1970: 1_800_000_000)
        state.usage[id] = .init(snapshot: .init(windows: [.init(id: "common", title: "Fixture", usedPercent: nil, resetsAt: Date(timeIntervalSince1970: 1_800_000_100))]))
        try await store.save(state)
        #expect(try await store.load() == state)
        var newer = state; newer.schemaVersion = 2
        let url = await store.url
        let bytes = try JSONEncoder().encode(newer)
        try fixture.files.write(bytes, to: url)
        await #expect(throws: AgentSwapError.self) { try await store.save(state) }
        #expect(try fixture.files.read(url) == bytes)
        try fixture.files.write(Data("broken".utf8), to: url)
        await #expect(throws: AgentSwapError.self) { try await store.load() }
    }

    @Test("Claude switch preserves live MCP/plugin secrets and shared configuration")
    func claudePreservation() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let old = try fixture.claude(extra: ["mcpOAuth": ["live": "fixture-current"], "pluginSecrets": ["plugin": "fixture-current"]])
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let config: [String: Any] = ["oauthAccount": ["accountUuid": "old-user", "organizationUuid": "old-org"], "mcpServers": ["fixture": ["type": "http"]], "projects": ["fixture": true], "theme": "dark"]
        try fixture.files.write(authData(config), to: store.configURL)
        let target = try fixture.claude(token: "fixture-new", extra: ["mcpOAuth": ["stale": "fixture-old"], "mcpXaaIdp": ["stale": true], "trustedDeviceToken": "fixture-target-device"])
        try await store.activate(target)
        let raw = try #require(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount))
        let activated = try authObject(raw, name: "Fixture")
        #expect((activated["mcpOAuth"] as? [String: String]) == ["live": "fixture-current"])
        #expect(activated["mcpXaaIdp"] == nil)
        #expect(activated["trustedDeviceToken"] as? String == "fixture-target-device")
        let updated = try authObject(#require(try fixture.files.read(store.configURL)), name: "Fixture")
        #expect(updated["theme"] as? String == "dark")
        #expect((updated["projects"] as? [String: Bool]) == ["fixture": true])
        #expect(updated["mcpServers"] != nil)
        #expect(try await store.read().accessToken == "fixture-new")
        #expect(try fixture.files.read(store.configDirectory.appendingPathComponent(".credentials.json")) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Claude refuses an unknown authentication format before any write")
    func claudeUnknownFormat() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let unknown = try fixture.claude(extra: ["newSharedCredentialType": "fixture-secret"])
        await #expect(throws: AgentSwapError.self) { try await store.activate(unknown) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Claude recognizes account-bound organizationUuid and refuses metadata mismatch")
    func claudeOrganizationBinding() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let original = try fixture.claude(extra: ["organizationUuid": "fixture-workspace"])
        try fixture.keychain.write(original.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let target = try fixture.claude(token: "fixture-new", extra: ["organizationUuid": "fixture-workspace"])
        try await store.activate(target)
        let bound = try authObject(#require(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount)), name: "Fixture")
        #expect(bound["organizationUuid"] as? String == "fixture-workspace")
        let after = try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount)
        let mismatch = try fixture.claude(extra: ["organizationUuid": "other-workspace"])
        await #expect(throws: AgentSwapError.self) { try await store.activate(mismatch) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == after)
        let invalid = try fixture.claude(extra: ["organizationUuid": ["unexpected": "object"]])
        await #expect(throws: AgentSwapError.self) { try await store.activate(invalid) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == after)
    }

    @Test("Partial Claude failure rolls back both auth stores")
    func claudeRollback() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let files = FaultFiles(), store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, files: files)
        let old = try fixture.claude(), target = try fixture.claude(token: "fixture-new")
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let authURL = store.configDirectory.appendingPathComponent(".credentials.json")
        try files.write(old.rawAuth, to: authURL)
        files.failNextWrite(to: store.configURL)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == old.rawAuth)
        #expect(try files.read(authURL) == old.rawAuth)
        #expect(try files.read(store.configURL) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A failed rollback keeps its Keychain journal until explicit recovery")
    func interruptedRecovery() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let files = FaultFiles(), store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, files: files)
        let old = try fixture.claude(), target = try fixture.claude(token: "fixture-new")
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        fixture.keychain.failWrite(service: store.keychainService, account: store.keychainAccount, afterSuccesses: 1)
        files.failNextWrite(to: store.configURL)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        #expect(fixture.keychain.journalCount() == 1)
        #expect(!(await store.compatibility()).canWrite)
        try await store.recoverInterruptedSwitch()
        #expect(try await store.read().accessToken == "fixture-old")
        #expect(fixture.keychain.journalCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.contains("recovery") })
    }

    @Test("Codex file, direct Keychain and auto honor storage priority", arguments: ["file", "keyring", "auto"])
    func codexPriority(mode: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: mode)
        let file = try fixture.codex(token: "fixture-file"), secure = try fixture.codex(token: "fixture-keychain"), target = try fixture.codex(token: "fixture-new")
        try fixture.files.write(file.rawAuth, to: fixture.directory.appendingPathComponent("auth.json"))
        try fixture.keychain.write(secure.rawAuth, service: CodexAuthStore.keychainService, account: store.keychainAccount)
        let config = try fixture.files.read(fixture.directory.appendingPathComponent("config.toml"))
        let history = Data("Fixture history".utf8)
        try fixture.files.write(history, to: fixture.directory.appendingPathComponent("history.jsonl"))
        #expect(try await store.read().accessToken == (mode == "file" ? "fixture-file" : "fixture-keychain"))
        try await store.activate(target)
        #expect(try await store.read().accessToken == "fixture-new")
        #expect(try fixture.files.read(fixture.directory.appendingPathComponent("history.jsonl")) == history)
        #expect(try fixture.files.read(fixture.directory.appendingPathComponent("config.toml")) == config)
        if mode != "file" { #expect(try fixture.files.read(fixture.directory.appendingPathComponent("auth.json")) == nil) }
    }

    @Test("Recovery never overwrites a token changed by another consumer")
    func externalChangeBlocksRecovery() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let files = FaultFiles(), store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, files: files)
        let old = try fixture.claude(), target = try fixture.claude(token: "fixture-new")
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        fixture.keychain.failWrite(service: store.keychainService, account: store.keychainAccount, afterSuccesses: 1)
        files.failNextWrite(to: store.configURL)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        let external = try fixture.claude(token: "fixture-external")
        try fixture.keychain.write(external.rawAuth, service: store.keychainService, account: store.keychainAccount)
        await #expect(throws: AgentSwapError.self) { try await store.recoverInterruptedSwitch() }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == external.rawAuth)
        #expect(fixture.keychain.journalCount() == 1)
    }

    @Test("Active Claude refresh holds provider locks and persists its successor immediately")
    func claudeRefreshPersistence() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let old = try fixture.claude(), target = try fixture.claude(token: "fixture-rotated"), id = UUID()
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let metadata = try authObject(#require(old.accountMetadata), name: "Fixture")
        try fixture.files.write(authData(["oauthAccount": metadata, "theme": "dark"]), to: store.configURL)
        let directory = store.configDirectory, configURL = store.configURL
        let rotated = try await store.refresh(old, accountID: id) { input in
            #expect(input.accessToken == "fixture-old")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
            #expect(FileManager.default.fileExists(atPath: directory.path + ".lock"))
            #expect(FileManager.default.fileExists(atPath: configURL.path + ".lock"))
            return target
        }
        #expect(rotated.accessToken == "fixture-rotated")
        #expect(try await store.read().accessToken == "fixture-rotated")
        let secrets = KeychainSecretStore(keychain: fixture.keychain)
        #expect(try await secrets.load(accountID: id)?.accessToken == "fixture-rotated")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Inactive Claude refresh preserves native auth and releases provider locks")
    func inactiveClaudeRefresh() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let live = try fixture.claude(), id = UUID()
        var inactive = try fixture.claude(token: "fixture-inactive")
        inactive.accountMetadata = try authData(["accountUuid": "inactive-user", "organizationUuid": "inactive-workspace"])
        var target = inactive; target.accessToken = "fixture-rotated"; target.refreshToken = "fixture-successor"
        var object = try authObject(target.rawAuth, name: "Fixture")
        object["claudeAiOauth"] = ["accessToken": target.accessToken, "refreshToken": "fixture-successor"]
        target.rawAuth = try authData(object)
        try fixture.keychain.write(live.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try fixture.files.write(authData(["oauthAccount": authObject(#require(live.accountMetadata), name: "Fixture")]), to: store.configURL)
        let directory = store.configDirectory, expectedTarget = target
        _ = try await store.refresh(inactive, accountID: id) { input in
            #expect(input.accessToken == "fixture-inactive")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
            return expectedTarget
        }
        #expect(try await store.read().accessToken == "fixture-old")
        #expect(try await KeychainSecretStore(keychain: fixture.keychain).load(accountID: id)?.accessToken == "fixture-rotated")
    }

    @Test("Native refresh failure preserves the rotated grant and respects external rotation", arguments: [false, true])
    func rotatedGrantSurvivesFailure(externalChange: Bool) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let files = FaultFiles(), store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, files: files)
        let old = try fixture.claude(), target = try fixture.claude(token: "fixture-successor"), id = UUID()
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let authURL = store.configDirectory.appendingPathComponent(".credentials.json")
        try files.write(old.rawAuth, to: authURL)
        try files.write(authData(["oauthAccount": authObject(#require(old.accountMetadata), name: "Fixture")]), to: store.configURL)
        files.failNextWrite(to: authURL)
        await #expect(throws: AgentSwapError.self) {
            try await store.refresh(old, accountID: id) { _ in target }
        }
        #expect(try await KeychainSecretStore(keychain: fixture.keychain).load(accountID: id)?.accessToken == "fixture-successor")
        #expect(!(await store.compatibility()).canWrite)
        if externalChange {
            let external = try fixture.claude(token: "fixture-external-rotation")
            try fixture.keychain.write(external.rawAuth, service: store.keychainService, account: store.keychainAccount)
            await #expect(throws: AgentSwapError.self) { try await store.recoverInterruptedSwitch() }
            #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == external.rawAuth)
            #expect(fixture.keychain.journalCount() == 1)
            return
        }
        try await store.recoverInterruptedSwitch()
        #expect(try await store.read().accessToken == "fixture-successor")
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A failed vault save preserves the only rotated grant and blocks switching until recovery")
    func rotatedGrantSurvivesVaultFailure() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let vault = KeychainSecretStore(keychain: fixture.keychain), id = UUID()
        let old = try fixture.claude(), successor = try fixture.claude(token: "fixture-successor")
        var switchTarget = try fixture.claude(token: "fixture-other-account")
        switchTarget.accountMetadata = try authData(["accountUuid": "other-user", "organizationUuid": "other-workspace"])
        let authURL = store.configDirectory.appendingPathComponent(".credentials.json")
        let config = try authData(["oauthAccount": authObject(#require(old.accountMetadata), name: "Fixture"), "theme": "dark"])
        try fixture.keychain.write(old.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try fixture.files.write(old.rawAuth, to: authURL)
        try fixture.files.write(config, to: store.configURL)
        try await vault.save(old, accountID: id)
        fixture.keychain.failWrite(service: KeychainSecretStore.service, account: id.uuidString)
        await #expect(throws: AgentSwapError.self) { try await store.refresh(old, accountID: id) { _ in successor } }

        let rotationKey = "claude|" + storageDigest(store.configDirectory.path, prefix: 32) + "|rotation"
        let marker = try #require(try fixture.keychain.read(service: AuthTransaction.service, account: rotationKey))
        let pending = try authObject(marker, name: "Fixture rotation")
        #expect((pending["credential"] as? [String: Any])?["accessToken"] as? String == successor.accessToken)
        #expect(try await vault.load(accountID: id)?.accessToken == old.accessToken)
        await #expect(throws: AgentSwapError.self) { try await store.activate(switchTarget) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == old.rawAuth)
        #expect(try fixture.files.read(authURL) == old.rawAuth)
        #expect(try fixture.files.read(store.configURL) == config)
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: rotationKey) == marker)
        #expect(fixture.keychain.journalCount() == 1)

        try await store.recoverInterruptedSwitch()
        #expect(try await vault.load(accountID: id)?.accessToken == successor.accessToken)
        #expect(try await store.read().accessToken == successor.accessToken)
        #expect(try fixture.files.read(authURL) == successor.rawAuth)
        #expect(try fixture.files.read(store.configURL) == config)
        #expect(try fixture.keychain.read(service: AuthTransaction.service, account: rotationKey) == nil)
        #expect(fixture.keychain.journalCount() == 0)
        try await store.activate(switchTarget)
        #expect(try await store.read().accessToken == switchTarget.accessToken)
    }

    @Test("A live CLI credential lock prevents switching without leaving partial locks")
    func liveCLILock() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain, lockTimeout: 0.02)
        let legacy = URL(fileURLWithPath: store.configDirectory.path + ".lock")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        await #expect(throws: AgentSwapError.self) { try await store.activate(fixture.claude()) }
        #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.configDirectory.appendingPathComponent(".oauth_refresh.lock").path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Codex auto uses file fallback only when no Keychain credential can shadow it")
    func codexAutoFallback() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: "auto"), target = try fixture.codex(token: "fixture-new")
        fixture.keychain.failWrite(service: CodexAuthStore.keychainService, account: store.keychainAccount)
        try await store.activate(target)
        #expect(try await store.read().accessToken == "fixture-new")
        #expect(try fixture.files.read(fixture.directory.appendingPathComponent("auth.json")) == target.rawAuth)
        #expect(try fixture.keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == nil)
    }

    @Test("Codex ephemeral and secrets settings fail closed", arguments: ["cli_auth_credentials_store = 'ephemeral'", "cli_auth_credentials_store = 'auto'\n[features]\nsecret_auth_storage = true", "profile = 'work'", "cli_auth_credentials_store = 'unknown'"])
    func codexUnsupported(config: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        try fixture.files.write(Data(config.utf8), to: fixture.directory.appendingPathComponent("config.toml"))
        let store = CodexAuthStore(home: fixture.directory, keychain: fixture.keychain, configurationGuard: fixture.configurationGuard)
        await #expect(throws: AgentSwapError.self) { try await store.activate(fixture.codex()) }
        #expect(!(await store.compatibility()).canWrite)
        #expect(try fixture.files.read(fixture.directory.appendingPathComponent("auth.json")) == nil)
    }

    @Test("An unreadable auto Keychain is never mistaken for a file credential or an absent login", arguments: [false, true])
    func codexUnreadableKeychain(hasFile: Bool) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: "auto"), old = try fixture.codex()
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        if hasFile { try fixture.files.write(old.rawAuth, to: authURL) }
        fixture.keychain.failRead(service: CodexAuthStore.keychainService, account: store.keychainAccount)
        await #expect(throws: AgentSwapError.self) { try await store.read() }
        await #expect(throws: AgentSwapError.self) { try await store.readIfPresent() }
        #expect(!(await store.compatibility()).canWrite)
        await #expect(throws: AgentSwapError.self) { try await store.activate(fixture.codex(token: "fixture-new")) }
        #expect(try fixture.files.read(authURL) == (hasFile ? old.rawAuth : nil))
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A confirmed absent auto Keychain permits file fallback and a genuinely absent login")
    func codexAbsentAutoKeychain() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: "auto"), old = try fixture.codex()
        #expect(try await store.readIfPresent() == nil)
        try fixture.files.write(old.rawAuth, to: fixture.directory.appendingPathComponent("auth.json"))
        #expect(try await store.readIfPresent()?.accessToken == old.accessToken)
        #expect((await store.compatibility()).canWrite)
    }

    @Test("Codex rejects unknown target auth fields before changing any store", arguments: ["root", "tokens"])
    func codexUnknownTargetAuth(shape: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: "auto"), old = try fixture.codex()
        let authURL = fixture.directory.appendingPathComponent("auth.json"), configURL = fixture.directory.appendingPathComponent("config.toml")
        let historyURL = fixture.directory.appendingPathComponent("history.jsonl"), history = Data("Fixture history".utf8)
        try fixture.files.write(old.rawAuth, to: authURL)
        try fixture.files.write(history, to: historyURL)
        try fixture.keychain.write(old.rawAuth, service: CodexAuthStore.keychainService, account: store.keychainAccount)
        let config = try fixture.files.read(configURL)
        var target = try fixture.codex(token: "fixture-new"), object = try authObject(target.rawAuth, name: "Fixture")
        if shape == "root" { object["future_auth_store"] = ["fixture": true] }
        else {
            var tokens = try #require(object["tokens"] as? [String: Any])
            tokens["future_secret"] = "fixture-unknown"; object["tokens"] = tokens
        }
        target.rawAuth = try authData(object)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        #expect(try fixture.keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == old.rawAuth)
        #expect(try fixture.files.read(authURL) == old.rawAuth)
        #expect(try fixture.files.read(configURL) == config)
        #expect(try fixture.files.read(historyURL) == history)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A present malformed auto Keychain item never falls back to file auth or permits writes", arguments: ["root", "tokens", "shape", "json"])
    func codexMalformedAutoKeychain(shape: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let store = try fixture.codexStore(mode: "auto"), old = try fixture.codex(), target = try fixture.codex(token: "fixture-new")
        let authURL = fixture.directory.appendingPathComponent("auth.json"), configURL = fixture.directory.appendingPathComponent("config.toml")
        let historyURL = fixture.directory.appendingPathComponent("history.jsonl"), history = Data("Fixture history".utf8)
        try fixture.files.write(old.rawAuth, to: authURL)
        try fixture.files.write(history, to: historyURL)
        let config = try fixture.files.read(configURL)
        var object = try authObject(old.rawAuth, name: "Fixture")
        switch shape {
        case "root": object["future_auth_store"] = ["fixture": true]
        case "tokens":
            var tokens = try #require(object["tokens"] as? [String: Any])
            tokens["future_secret"] = "fixture-unknown"; object["tokens"] = tokens
        default: object["tokens"] = "unexpected token shape"
        }
        let invalid = shape == "json" ? Data("not JSON".utf8) : try authData(object)
        try fixture.keychain.write(invalid, service: CodexAuthStore.keychainService, account: store.keychainAccount)
        await #expect(throws: AgentSwapError.self) { try await store.read() }
        #expect(!(await store.compatibility()).canWrite)
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        #expect(try fixture.keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == invalid)
        #expect(try fixture.files.read(authURL) == old.rawAuth)
        #expect(try fixture.files.read(configURL) == config)
        #expect(try fixture.files.read(historyURL) == history)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Codex dotted feature keys and quoted table headers detect secrets storage", arguments: [
        "cli_auth_credentials_store = 'auto'\nfeatures\t.\tsecret_auth_storage = true",
        "cli_auth_credentials_store = 'auto'\n\"features\"\t.\t'secret_auth_storage' = true",
        "cli_auth_credentials_store = 'auto'\n[ \t 'features' \t ]\n'secret_auth_storage' = true",
        "cli_auth_credentials_store = 'auto'\n[ \"features\" ]\n\"secret_auth_storage\" = true"
    ])
    func codexAuthSettingsWhitespace(config: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let configURL = fixture.directory.appendingPathComponent("config.toml"), authURL = fixture.directory.appendingPathComponent("auth.json")
        let bytes = Data(config.utf8), original = try fixture.codex()
        try fixture.files.write(bytes, to: configURL); try fixture.files.write(original.rawAuth, to: authURL)
        let store = CodexAuthStore(home: fixture.directory, keychain: fixture.keychain, configurationGuard: fixture.configurationGuard)
        #expect(!(await store.compatibility()).canWrite)
        await #expect(throws: AgentSwapError.self) { try await store.activate(fixture.codex(token: "fixture-new")) }
        #expect(try fixture.files.read(configURL) == bytes)
        #expect(try fixture.files.read(authURL) == original.rawAuth)
        #expect(try fixture.keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == nil)
    }

    @Test("Codex quoted mode keys and tab-separated direct feature paths retain compatibility", arguments: [
        "'cli_auth_credentials_store'\t= 'keyring'\nfeatures\t.\tsecret_auth_storage = false",
        "\"cli_auth_credentials_store\" = \"keyring\"\n[ \t 'features' \t ]\n'secret_auth_storage' = false",
        "cli_auth_credentials_store = 'keyring'\n[ \"features\" ]\n\"secret_auth_storage\" = false"
    ])
    func codexQuotedDirectSettings(config: String) async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let configURL = fixture.directory.appendingPathComponent("config.toml"), historyURL = fixture.directory.appendingPathComponent("history.jsonl")
        let bytes = Data(config.utf8), history = Data("Fixture history".utf8)
        try fixture.files.write(bytes, to: configURL); try fixture.files.write(history, to: historyURL)
        let store = CodexAuthStore(home: fixture.directory, keychain: fixture.keychain, configurationGuard: fixture.configurationGuard)
        #expect(try await store.storageMode() == .keychain)
        #expect((await store.compatibility()).canWrite)
        try await store.activate(fixture.codex(token: "fixture-new"))
        #expect(try await store.read().accessToken == "fixture-new")
        #expect(try fixture.files.read(configURL) == bytes)
        #expect(try fixture.files.read(historyURL) == history)
    }

    @Test("Auth replacement refuses symlink targets and creates private files")
    func privateFiles() throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("auth.json"), target = fixture.directory.appendingPathComponent("target.json")
        try fixture.files.write(Data("Fixture".utf8), to: target)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: AgentSwapError.self) { try fixture.files.write(Data("Changed".utf8), to: file) }
        #expect(try fixture.files.read(target) == Data("Fixture".utf8))
    }

    @Test("Managed Codex configuration blocks access without changing either credential store")
    func codexManagedConfiguration() async throws {
        let fixture = try StorageFixture(); defer { fixture.cleanup() }
        let managed = fixture.directory.appendingPathComponent("administrator-config.toml")
        try fixture.files.write(Data("[features]\nsecret_auth_storage = true".utf8), to: managed)
        let guardPolicy = SystemCodexConfigurationGuard(configurationURLs: [managed], checkManagedPreferences: false)
        let store = CodexAuthStore(home: fixture.directory, keychain: fixture.keychain, configurationGuard: guardPolicy)
        let old = try fixture.codex(), target = try fixture.codex(token: "fixture-new")
        let authURL = fixture.directory.appendingPathComponent("auth.json")
        try fixture.files.write(old.rawAuth, to: authURL)
        #expect(!(await store.compatibility()).canWrite)
        await #expect(throws: AgentSwapError.self) { try await store.read() }
        await #expect(throws: AgentSwapError.self) { try await store.activate(target) }
        #expect(try fixture.files.read(authURL) == old.rawAuth)
        #expect(try fixture.keychain.read(service: CodexAuthStore.keychainService, account: store.keychainAccount) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }
}
