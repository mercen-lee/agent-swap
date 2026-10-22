import Foundation
import Testing
@testable import AgentSwapCore

private actor FixtureTransport: ProviderHTTPTransport {
    var responses: [ProviderHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AgentSwapError.network("Fixture network failure") }
        return responses.removeFirst()
    }
}
private struct NoLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}
private actor FixtureLoginURLOpener: ProviderLoginURLOpening {
    private(set) var urls: [URL] = []
    private var blocked: CheckedContinuation<Void, Never>?
    private let holdOpen: Bool
    init(holdOpen: Bool = false) { self.holdOpen = holdOpen }
    func open(_ url: URL) async {
        urls.append(url)
        if holdOpen { await withCheckedContinuation { blocked = $0 } }
    }
    func release() { blocked?.resume(); blocked = nil }
}
// Safety invariant: the fake Keychain dictionary is accessed only under this lock.
private final class ProviderFixtureKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var refusesDelete = false
    private var unreadableService: String?
    private var appearanceService: String?
    private var appearanceData: Data?
    private var observedDeleteMode: KeychainInteractionMode?
    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            if service == unreadableService { throw AgentSwapError.storage("Fixture native credential read failure") }
            let previous = values[service + account]
            if previous == nil, service == appearanceService, let appearanceData {
                values[service + account] = appearanceData
                self.appearanceData = nil; appearanceService = nil
            }
            return previous
        }
    }
    func write(_ data: Data, service: String, account: String) { lock.withLock { values[service + account] = data } }
    func delete(service: String, account: String) throws {
        try lock.withLock {
            observedDeleteMode = KeychainInteraction.mode
            if refusesDelete { throw AgentSwapError.storage("Fixture cleanup permission failure") }
            _ = values.removeValue(forKey: service + account)
        }
    }
    func refuseDeletion() { lock.withLock { refusesDelete = true } }
    func refuseReads(service: String?) { lock.withLock { unreadableService = service } }
    func appearAfterAbsentRead(service: String, data: Data) {
        lock.withLock { appearanceService = service; appearanceData = data }
    }
    func lastDeleteMode() -> KeychainInteractionMode? { lock.withLock { observedDeleteMode } }
}
private actor FixtureProcesses: CodexProcessControlling {
    var consumers: [CodexConsumer]
    var reliable: Bool
    let accepted: Bool
    let staysRunning: Bool
    let onQuit: @Sendable () throws -> Void
    var quitCount = 0
    var launchCount = 0
    var launchFails = false
    init(_ consumers: [CodexConsumer] = [], reliable: Bool = true, accepted: Bool = true, staysRunning: Bool = false,
         onQuit: @escaping @Sendable () throws -> Void = {}) {
        self.consumers = consumers; self.reliable = reliable; self.accepted = accepted
        self.staysRunning = staysRunning; self.onQuit = onQuit
    }
    func scan() -> CodexProcessScan { .init(consumers: consumers, reliable: reliable) }
    func installation() -> CodexDesktopInstallation? { .init(url: URL(fileURLWithPath: "/Fixture/Codex.app"), version: "fixture") }
    func requestDesktopTermination() -> Bool {
        quitCount += 1
        guard accepted else { return false }
        do { try onQuit() } catch { return false }
        if !staysRunning { consumers = [] }
        return true
    }
    func relaunchDesktop() throws {
        launchCount += 1
        if launchFails { throw AgentSwapError.unsupported("Fixture launch failed") }
    }
    func failLaunch() { launchFails = true }
}
private actor SourceBackup {
    var value: ImportedAccount?
    func save(_ value: ImportedAccount) { self.value = value }
}
private actor ClaudeBackupBarrier {
    private var value: ImportedAccount?
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func backup(_ source: ImportedAccount) async {
        value = source
        for waiter in ready { waiter.resume() }
        ready.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilBackedUp() async {
        if value != nil { return }
        await withCheckedContinuation { ready.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}
private struct ProviderFixture {
    let directory: URL
    let keychain = ProviderFixtureKeychain()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func claude() throws -> ImportedAccount {
        let credential = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-access", "refreshToken": "fixture-refresh", "expiresAt": 1_900_000_000_000, "scopes": ["user:profile", "user:inference"]], "mcpOAuth": ["fixture": "preserve"]]), accountMetadata: ProviderJSON.data(["accountUuid": "fixture-user", "organizationUuid": "fixture-workspace", "emailAddress": "fixture@example.com"]))
        return try ProviderAccountParser.claude(credential)
    }
    func claudeSwitch(token: String = "fixture-source", user: String = "00000000-0000-4000-8000-000000000020",
                      workspace: String = "00000000-0000-4000-8000-000000000021") throws -> ImportedAccount {
        let credential = try CredentialParser.claude(
            rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": token, "refreshToken": "fixture-refresh", "expiresAt": 1_900_000_000_000], "organizationUuid": workspace]),
            accountMetadata: ProviderJSON.data(["accountUuid": user, "organizationUuid": workspace]))
        return try ProviderAccountParser.claude(credential)
    }
    func claudeProfile(_ account: AccountRecord) throws -> ProviderHTTPResponse {
        .init(data: try ProviderJSON.data([
            "account": ["uuid": account.identity.userID],
            "organization": ["uuid": account.identity.workspaceID]
        ]), statusCode: 200)
    }
    func codex(token: String = "fixture-old", user: String = "fixture-user", workspace: String = "fixture-workspace") throws -> ImportedAccount {
        let claims: [String: Any] = ["sub": user, "email": "fixture@example.com", "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": workspace, "chatgpt_plan_type": "pro"]]
        let encoded = try ProviderJSON.data(claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let credential = try CredentialParser.codex(rawAuth: ProviderJSON.data(["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["access_token": token, "refresh_token": "fixture-refresh", "id_token": "fixture.\(encoded).signature", "account_id": workspace]]))
        return try ProviderAccountParser.codex(credential)
    }
    func store(_ credential: Credential) throws -> CodexAuthStore {
        try AtomicAuthFileAccess().write(credential.rawAuth, to: directory.appendingPathComponent("auth.json"))
        return CodexAuthStore(home: directory, keychain: keychain)
    }
}

@Suite("Provider wire formats and process safety")
struct ProviderTests {
    private func expectClaudeRefreshProof(_ requests: [URLRequest]) {
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://api.anthropic.com/api/oauth/profile",
            "https://platform.claude.com/v1/oauth/token",
            "https://api.anthropic.com/api/oauth/profile"
        ])
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "GET"])
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(requests.dropFirst().first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-successor")
    }
    @Test("An optional native import distinguishes absent authentication from unreadable or malformed data", arguments: [Provider.claude, Provider.codex])
    func optionalNativeImport(_ provider: Provider) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let adapter: any ProviderAdapter
        let service: String
        let account: String
        switch provider {
        case .claude:
            let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
            adapter = ClaudeProviderAdapter(authStore: store, transport: FixtureTransport([]), loginRunner: NoLogin())
            service = store.keychainService; account = store.keychainAccount
        case .codex:
            try AtomicAuthFileAccess().write(Data("cli_auth_credentials_store = 'keyring'".utf8), to: fixture.directory.appendingPathComponent("config.toml"))
            let store = CodexAuthStore(home: fixture.directory, keychain: fixture.keychain)
            adapter = CodexProviderAdapter(authStore: store, transport: FixtureTransport([]), loginRunner: NoLogin(), processController: FixtureProcesses())
            service = CodexAuthStore.keychainService; account = store.keychainAccount
        }
        #expect(try await adapter.importCurrentIfPresent() == nil)
        fixture.keychain.refuseReads(service: service)
        await #expect(throws: AgentSwapError.storage("Fixture native credential read failure")) {
            try await adapter.importCurrentIfPresent()
        }
        fixture.keychain.refuseReads(service: nil)
        fixture.keychain.write(Data("fixture-malformed-native-auth".utf8), service: service, account: account)
        await #expect(throws: AgentSwapError.self) {
            try await adapter.importCurrentIfPresent()
        }
    }

    @Test("Claude missing usage remains unknown and model windows remain display-only")
    func claudeWindows() throws {
        let data = Data(#"{"five_hour":{"utilization":91,"resets_at":"2026-10-14T03:00:00.123Z"},"seven_day":{"utilization":null,"resets_at":"2026-10-21T03:00:00Z"},"seven_day_sonnet":{"utilization":12},"future_model":{"utilization":25},"extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":25}}"#.utf8)
        let snapshot = try ProviderUsageParser.claude(data)
        #expect(snapshot.windows.count == 4)
        #expect(snapshot.commonWindows.count == 2)
        #expect(snapshot.minimumRemaining == nil)
        #expect(snapshot.windows.first { $0.id == "seven_day" }?.usedPercent == nil)
        #expect(snapshot.windows.first { $0.id == "five_hour" }?.resetsAt == ProviderJSON.date("2026-10-14T03:00:00.123Z"))
        #expect(snapshot.extras.contains { $0.id == "used_credits" && $0.value == "25" })
    }
    @Test("Claude modern common meters replace legacy aliases and extra usage stays separate")
    func claudeModernAliases() throws {
        let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-10-14T03:00:00Z"},"seven_day":{"utilization":100,"resets_at":"2026-10-21T03:00:00Z"},"extra_usage":{"is_enabled":false,"utilization":null},"limits":[{"kind":"session","group":"session","percent":20,"resets_at":"2026-10-14T03:00:00Z"},{"kind":"weekly_all","group":"weekly","percent":100,"resets_at":"2026-10-21T03:00:00Z"},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-10-21T03:00:00Z","scope":{"model":{"display_name":"Sonnet"}}}]}"#.utf8)
        let snapshot = try ProviderUsageParser.claude(data)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.commonWindows.map(\.id) == ["five_hour", "seven_day"])
        #expect(snapshot.commonWindows.map(\.usedPercent) == [20, 100])
        #expect(snapshot.windows.filter { $0.kind == .model }.map(\.title) == ["Sonnet 주간"])
        #expect(!snapshot.windows.contains { $0.id == "extra_usage" || $0.title == "session" || $0.title == "weekly_all" })
        #expect(snapshot.extras.contains { $0.id == "is_enabled" })
    }
    @Test("Claude limits-only common meters remain eligible for safe common-window comparisons")
    func claudeModernOnly() throws {
        let data = Data(#"{"limits":[{"kind":"session","group":"session","percent":25,"resets_at":"2026-10-14T03:00:00Z"},{"kind":"weekly_all","group":"weekly","percent":40,"resets_at":null},{"kind":"weekly_scoped","group":"weekly","percent":60,"resets_at":null,"scope":{"surface":{"display_name":"Claude Code"}}},{"kind":"future_meter","group":"unknown","percent":99,"resets_at":null}]}"#.utf8)
        let snapshot = try ProviderUsageParser.claude(data)
        #expect(snapshot.commonWindows.count == 2)
        #expect(snapshot.minimumRemaining == 60)
        #expect(snapshot.windows.contains { $0.title == "Claude Code 주간" && $0.kind == .additional })
        #expect(snapshot.windows.contains { $0.title == "future_meter" && $0.kind == .additional })
        #expect(snapshot.commonWindows.first?.duration == 18_000)
    }
    @Test("Unknown modern common percentages do not fall back to a complete legacy projection")
    func claudeModernUnknownCommon() throws {
        let data = Data(#"{"five_hour":{"utilization":20},"seven_day":{"utilization":10},"limits":[{"kind":"session","group":"session","percent":null,"resets_at":null},{"kind":"weekly_all","group":"weekly","percent":10,"resets_at":null}]}"#.utf8)
        let snapshot = try ProviderUsageParser.claude(data)
        #expect(snapshot.commonWindows.count == 2)
        #expect(snapshot.commonWindows.first?.usedPercent == nil)
        #expect(snapshot.minimumRemaining == nil)
        #expect(throws: AgentSwapError.self) {
            try ProviderUsageParser.claude(Data(#"{"limits":[{"kind":"session","percent":20},{"kind":"session","percent":30}]}"#.utf8))
        }
    }
    @Test("Codex variable window durations, additional quotas, credits, and resets")
    func codexWindows() throws {
        let snapshot = try ProviderUsageParser.codex(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":60},"future_window":{"used_percent":null,"limit_window_seconds":7200}},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":99,"limit_window_seconds":86400,"reset_at":1800000100}}}],"credits":{"balance":"125.50","unlimited":false},"rate_limit_reset_credits":{"available_count":2}}"#.utf8), now: Date(timeIntervalSince1970: 1_799_999_000))
        #expect(snapshot.windows.count == 4)
        #expect(snapshot.commonWindows.count == 3)
        #expect(snapshot.minimumRemaining == nil) // Incomplete future common windows must not qualify for automation.
        #expect(snapshot.windows.last?.kind == .additional)
        #expect(snapshot.windows.first { $0.id == "rate_limit.primary_window" }?.duration == 18_000)
        #expect(snapshot.windows.first { $0.id == "rate_limit.secondary_window" }?.resetsAt == Date(timeIntervalSince1970: 1_799_999_060))
        #expect(snapshot.extras.contains { $0.id == "rate_limit_reset_credits.available_count" && $0.value == "2" })
        #expect(snapshot.plan == "pro")
    }
    @Test("Codex code review quotas stay separate from subscription headroom")
    func codexCodeReviewWindows() throws {
        let now = Date(timeIntervalSince1970: 1_799_999_000)
        let snapshot = try ProviderUsageParser.codex(Data(#"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000}},"code_review_rate_limit":{"primary_window":{"used_percent":95,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":null,"reset_after_seconds":60}}}"#.utf8), now: now)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.commonWindows.count == 1)
        #expect(snapshot.minimumRemaining == 60)
        let review = try #require(snapshot.windows.first { $0.id == "code_review_rate_limit.primary_window" })
        #expect(review.kind == .additional)
        #expect(review.title == "코드 검토 5시간")
        #expect(review.usedPercent == 95)
        #expect(review.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        let secondary = try #require(snapshot.windows.first { $0.id == "code_review_rate_limit.secondary_window" })
        #expect(secondary.kind == .additional)
        #expect(secondary.usedPercent == nil)
        #expect(secondary.resetsAt == now.addingTimeInterval(60))
    }
    @Test("A lone optional code review window never becomes a common allowance", arguments: ["primary_window", "secondary_window"])
    func codexCodeReviewOnly(_ key: String) throws {
        let data = try ProviderJSON.data(["code_review_rate_limit": [key: ["used_percent": NSNull()]]])
        let snapshot = try ProviderUsageParser.codex(data)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.id == "code_review_rate_limit." + key)
        #expect(snapshot.windows.first?.usedPercent == nil)
        #expect(snapshot.windows.first?.resetsAt == nil)
        #expect(snapshot.windows.first?.kind == .additional)
        #expect(snapshot.commonWindows.isEmpty)
        #expect(snapshot.minimumRemaining == nil)
    }
    @Test("Unknown usage schemas fail instead of displaying exhausted accounts")
    func unsupportedUsage() throws {
        #expect(throws: AgentSwapError.self) { try ProviderUsageParser.claude(Data(#"{"unknown":true}"#.utf8)) }
        #expect(throws: AgentSwapError.self) { try ProviderUsageParser.codex(Data(#"{"rate_limit":null}"#.utf8)) }
    }
    @Test("429 honors seconds and HTTP date Retry-After", arguments: ["120", "Wed, 14 Oct 2026 03:00:00 GMT"])
    func retryAfter(_ header: String) throws {
        let now = try #require(ProviderJSON.date("2026-10-14T02:00:00Z"))
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(), statusCode: 429, headers: ["Retry-After": header]), now: now)
            Issue.record("429 should throw")
        } catch AgentSwapError.rateLimited(let date) {
            #expect(date == now.addingTimeInterval(header == "120" ? 120 : 3_600))
        }
    }
    @Test("Network errors do not expose server body or authentication")
    func networkError() throws {
        do { _ = try ProviderHTTP.checked(.init(data: Data("fixture-secret".utf8), statusCode: 500)); Issue.record("Should throw") }
        catch { #expect(!error.localizedDescription.contains("fixture-secret")) }
    }
    @Test("Codex refresh rotates all returned tokens and preserves account identity")
    func codexRefresh() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.codex()
        let transport = FixtureTransport([.init(data: Data(#"{"access_token":"fixture-successor","refresh_token":"fixture-next-refresh","expires_in":3600}"#.utf8), statusCode: 200)])
        let adapter = CodexProviderAdapter(authStore: CodexAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin(), processController: FixtureProcesses())
        let result = try await adapter.refresh(initial.credential, account: initial.account)
        #expect(result.accessToken == "fixture-successor")
        #expect(result.refreshToken == "fixture-next-refresh")
        #expect(result.expiresAt != nil)
        #expect(try ProviderAccountParser.codex(result).account.identity == initial.account.identity)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "auth.openai.com")
        #expect(request.httpMethod == "POST")
    }
    @Test("Claude refresh preserves MCP authentication while rotating account tokens")
    func claudeRefresh() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.claude()
        let transport = FixtureTransport([
            try fixture.claudeProfile(initial.account),
            .init(data: Data(#"{"access_token":"fixture-successor","refresh_token":"fixture-next","expires_in":3600,"scope":"user:profile user:inference"}"#.utf8), statusCode: 200),
            try fixture.claudeProfile(initial.account)
        ])
        let adapter = ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin())
        let result = try await adapter.refresh(initial.credential, account: initial.account)
        #expect(result.accessToken == "fixture-successor")
        #expect((try ProviderJSON.object(result.rawAuth)["mcpOAuth"] as? [String: String])?["fixture"] == "preserve")
        #expect(result.expiresAt != initial.credential.expiresAt)
        expectClaudeRefreshProof(await transport.requests)
    }
    @Test("Claude refresh uses the client ID recorded by its official login")
    func claudeStoredClientID() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.claude()
        var credential = initial.credential, root = try ProviderJSON.object(credential.rawAuth)
        var oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        oauth["clientId"] = "fixture-cli-client"
        root["claudeAiOauth"] = oauth; credential.rawAuth = try ProviderJSON.data(root)
        let transport = FixtureTransport([
            try fixture.claudeProfile(initial.account),
            .init(data: Data(#"{"access_token":"fixture-successor","refresh_token":"fixture-next","expires_in":3600}"#.utf8), statusCode: 200),
            try fixture.claudeProfile(initial.account)
        ])
        let adapter = ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin())
        let result = try await adapter.refresh(credential, account: initial.account)
        let request = try #require(await transport.requests.dropFirst().first)
        let body = try ProviderJSON.object(#require(request.httpBody))
        #expect(body["client_id"] as? String == "fixture-cli-client")
        #expect(request.url?.host == "platform.claude.com")
        #expect((try ProviderJSON.object(result.rawAuth)["claudeAiOauth"] as? [String: Any])?["clientId"] as? String == "fixture-cli-client")
        expectClaudeRefreshProof(await transport.requests)
    }
    @Test("The default Claude client fills absent or empty scopes with its registered native scope set", arguments: [false, true])
    func claudeDefaultRefreshScopes(_ emptyArray: Bool) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.claude()
        var credential = initial.credential, root = try ProviderJSON.object(credential.rawAuth)
        var oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        if emptyArray { oauth["scopes"] = [String]() } else { oauth.removeValue(forKey: "scopes") }
        root["claudeAiOauth"] = oauth; credential.rawAuth = try ProviderJSON.data(root)
        let transport = FixtureTransport([
            try fixture.claudeProfile(initial.account),
            .init(data: Data(#"{"access_token":"fixture-successor","refresh_token":"fixture-next","expires_in":3600}"#.utf8), statusCode: 200),
            try fixture.claudeProfile(initial.account)
        ])
        let adapter = ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin())
        _ = try await adapter.refresh(credential, account: initial.account)
        let request = try #require(await transport.requests.dropFirst().first)
        let body = try ProviderJSON.object(#require(request.httpBody))
        #expect(body["scope"] as? String == "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload user:plugins")
        #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        expectClaudeRefreshProof(await transport.requests)
    }
    @Test("Recorded Claude scopes remain authoritative for a custom client, including plugin access")
    func claudeRecordedRefreshScopes() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.claude()
        let scopes = ["user:profile", "user:plugins", "user:mcp_servers"]
        var credential = initial.credential, root = try ProviderJSON.object(credential.rawAuth)
        var oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        oauth["clientId"] = "fixture-recorded-client"; oauth["scopes"] = scopes
        root["claudeAiOauth"] = oauth; credential.rawAuth = try ProviderJSON.data(root)
        let transport = FixtureTransport([
            try fixture.claudeProfile(initial.account),
            .init(data: Data(#"{"access_token":"fixture-successor","refresh_token":"fixture-next","expires_in":3600}"#.utf8), statusCode: 200),
            try fixture.claudeProfile(initial.account)
        ])
        let adapter = ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin())
        let result = try await adapter.refresh(credential, account: initial.account)
        let request = try #require(await transport.requests.dropFirst().first)
        let body = try ProviderJSON.object(#require(request.httpBody))
        #expect(body["scope"] as? String == scopes.joined(separator: " "))
        #expect((try ProviderJSON.object(result.rawAuth)["claudeAiOauth"] as? [String: Any])?["scopes"] as? [String] == scopes)
        #expect((try ProviderJSON.object(result.rawAuth)["mcpOAuth"] as? [String: String])?["fixture"] == "preserve")
        expectClaudeRefreshProof(await transport.requests)
    }
    @Test("Malformed Claude refresh metadata and unknown custom grants stop before HTTP", arguments: ["string", "null", "mixed", "emptyItem", "whitespace", "control", "customAbsent", "customEmpty", "badClient", "blankClient"])
    func claudeInvalidRefreshScopes(_ shape: String) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.claude()
        var credential = initial.credential, root = try ProviderJSON.object(credential.rawAuth)
        var oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        switch shape {
        case "string": oauth["scopes"] = "user:profile"
        case "null": oauth["scopes"] = NSNull()
        case "mixed": oauth["scopes"] = ["user:profile", 1] as [Any]
        case "emptyItem": oauth["scopes"] = [""]
        case "whitespace": oauth["scopes"] = ["user:profile user:plugins"]
        case "control": oauth["scopes"] = ["user:profile\n"]
        case "customAbsent": oauth["clientId"] = "fixture-custom-client"; oauth.removeValue(forKey: "scopes")
        case "customEmpty": oauth["clientId"] = "fixture-custom-client"; oauth["scopes"] = [String]()
        case "badClient": oauth["clientId"] = 1
        default: oauth["clientId"] = " "
        }
        root["claudeAiOauth"] = oauth; credential.rawAuth = try ProviderJSON.data(root)
        let transport = FixtureTransport([])
        let adapter = ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin())
        await #expect(throws: AgentSwapError.self) { try await adapter.refresh(credential, account: initial.account) }
        #expect(await transport.requests.isEmpty)
        #expect(try fixture.keychain.read(service: KeychainSecretStore.service, account: initial.account.id.uuidString) == nil)
    }
    @Test("Codex usage adds the workspace header")
    func usageHeader() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.codex()
        let transport = FixtureTransport([.init(data: Data(#"{"rate_limit":{"primary_window":{"used_percent":45,"limit_window_seconds":18000,"reset_at":1800000000}}}"#.utf8), statusCode: 200)])
        let adapter = CodexProviderAdapter(authStore: CodexAuthStore(home: fixture.directory, keychain: fixture.keychain), transport: transport, loginRunner: NoLogin(), processController: FixtureProcesses())
        _ = try await adapter.fetchUsage(initial.credential, account: initial.account)
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-workspace")
    }
    @Test("Claude preservation never skips a disappeared or unreadable latest source", arguments: [false, true])
    func claudeRequiresReadableSource(_ unreadable: Bool) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch()
        let target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        if unreadable {
            try await store.activate(source.credential)
            fixture.keychain.refuseReads(service: store.keychainService)
        }
        let backup = SourceBackup()
        let transport = FixtureTransport([])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                    saveLatest: { await backup.save($0) }) else {
            Issue.record("Source read failure must stop before target activation"); return
        }
        #expect(await backup.value == nil)
        #expect(await transport.requests.isEmpty)
        fixture.keychain.refuseReads(service: nil)
        if unreadable { #expect(try await store.read().accessToken == source.credential.accessToken) }
        else { #expect(try fixture.keychain.read(service: store.keychainService, account: store.keychainAccount) == nil) }
    }
    @Test("Claude source backup failure leaves actual native authentication unchanged")
    func claudeBackupFailure() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch(), target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        try await store.activate(source.credential)
        let transport = FixtureTransport([try fixture.claudeProfile(source.account)])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        let backup = SourceBackup()
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                    saveLatest: { current in
            await backup.save(current)
            throw AgentSwapError.storage("fixture source backup failure")
        }) else {
            Issue.record("Backup failure must stop target activation"); return
        }
        #expect(await backup.value?.account.identity == source.account.identity)
        #expect(await backup.value?.credential.accessToken == source.credential.accessToken)
        #expect(await transport.requests.map { $0.url?.absoluteString } == ["https://api.anthropic.com/api/oauth/profile"])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-source")
        #expect(try await store.read().accessToken == source.credential.accessToken)
    }
    @Test("Claude cancellation after the backup suspension cannot apply target authentication")
    func claudeCancellationAfterBackup() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch(), target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        try await store.activate(source.credential)
        let transport = FixtureTransport([try fixture.claudeProfile(source.account)])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        let barrier = ClaudeBackupBarrier()
        let task = Task { await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                 saveLatest: { await barrier.backup($0) }) }
        await barrier.waitUntilBackedUp()
        task.cancel()
        await barrier.release()
        guard case .failed = await task.value else { Issue.record("Cancelled activation must not apply"); return }
        #expect(await transport.requests.map { $0.url?.absoluteString } == ["https://api.anthropic.com/api/oauth/profile"])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-source")
        #expect(try await store.read().accessToken == source.credential.accessToken)
    }
    @Test("Claude detects native identity or token rotation after backup under the final store lock", arguments: [false, true])
    func claudeSourceFenceAfterBackup(_ rotation: Bool) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch(), target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let external = try fixture.claudeSwitch(token: "fixture-external-latest", user: rotation ? source.account.identity.userID : "00000000-0000-4000-8000-000000000040")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        try await store.activate(source.credential)
        let backup = SourceBackup()
        let transport = FixtureTransport([
            try fixture.claudeProfile(source.account),
            try fixture.claudeProfile(target.account)
        ])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false, saveLatest: { current in
            await backup.save(current)
            try await store.activate(external.credential) // Fixture for a CLI change during the backup await.
        }) else { Issue.record("Changed native generation must stop target authentication"); return }
        #expect(await backup.value?.account.identity == source.account.identity)
        #expect(await backup.value?.credential.accessToken == source.credential.accessToken)
        #expect(await transport.requests.map { $0.url?.absoluteString } == Array(repeating: "https://api.anthropic.com/api/oauth/profile", count: 2))
        #expect(await transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer fixture-source", "Bearer fixture-target"])
        #expect(try await store.read().accessToken == external.credential.accessToken)
    }
    @Test("Direct Claude activation can initialize a clean profile without inventing a source")
    func claudeDirectActivationWithoutSource() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let target = try fixture.claudeSwitch(token: "fixture-target")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let transport = FixtureTransport([try fixture.claudeProfile(target.account)])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        guard case .applied(let text) = await adapter.activate(target.credential, account: target.account, relaunch: false) else {
            Issue.record("Explicit direct activation should initialize a clean CLI profile"); return
        }
        #expect(try await store.read().accessToken == target.credential.accessToken)
        #expect(text.contains("CLI") && text.contains("데스크톱 로그인은 별도로"))
        #expect(await transport.requests.map { $0.url?.absoluteString } == ["https://api.anthropic.com/api/oauth/profile"])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-target")
    }
    @Test("Explicit first activation proves source absence instead of inventing a backup")
    func claudeConfirmedFirstActivation() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let target = try fixture.claudeSwitch(token: "fixture-target")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        let transport = FixtureTransport([try fixture.claudeProfile(target.account)])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        let backup = SourceBackup()
        guard case .applied = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                     allowMissingSource: true, saveLatest: { await backup.save($0) }) else {
            Issue.record("Proven clean first activation should apply"); return
        }
        #expect(await backup.value == nil)
        #expect(try await store.read().accessToken == target.credential.accessToken)
        #expect(await transport.requests.map { $0.url?.absoluteString } == ["https://api.anthropic.com/api/oauth/profile"])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-target")
    }
    @Test("Initially unknown or appeared source is never treated as a clean first activation")
    func claudeSourcePresentInsteadOfAbsent() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch(), target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        try await store.activate(source.credential)
        let adapter = ClaudeProviderAdapter(authStore: store, transport: FixtureTransport([]), loginRunner: NoLogin())
        let backup = SourceBackup()
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                    allowMissingSource: true, saveLatest: { await backup.save($0) }) else {
            Issue.record("Present source requires retry rather than unbacked activation"); return
        }
        #expect(await backup.value == nil)
        #expect(try await store.read().accessToken == source.credential.accessToken)
    }
    @Test("Source appearing after the absence read is protected by the final locked absence check")
    func claudeSourceAppearsAfterAbsentRead() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.claudeSwitch(), target = try fixture.claudeSwitch(token: "fixture-target", user: "00000000-0000-4000-8000-000000000030")
        let store = ClaudeAuthStore(home: fixture.directory, keychain: fixture.keychain)
        fixture.keychain.appearAfterAbsentRead(service: store.keychainService, data: source.credential.rawAuth)
        let transport = FixtureTransport([try fixture.claudeProfile(target.account)])
        let adapter = ClaudeProviderAdapter(authStore: store, transport: transport, loginRunner: NoLogin())
        let backup = SourceBackup()
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false,
                                                                    allowMissingSource: true, saveLatest: { await backup.save($0) }) else {
            Issue.record("Appeared native source must stop target activation"); return
        }
        #expect(await backup.value == nil)
        #expect(try await store.read().accessToken == source.credential.accessToken)
        #expect(await transport.requests.map { $0.url?.absoluteString } == ["https://api.anthropic.com/api/oauth/profile"])
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-target")
    }
    @Test("Running desktop requires explicit relaunch and leaves authentication intact")
    func pendingDesktop() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential)
        let processes = FixtureProcesses([.init(pid: 1, kind: .desktop, name: "Fixture Codex")])
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes)
        let result = await adapter.activate(target.credential, account: target.account, relaunch: false)
        guard case .pendingRelaunch = result else { Issue.record("Should wait for relaunch"); return }
        #expect(try await store.read() == source.credential)
        #expect(await processes.quitCount == 0)
    }
    @Test("CLI, IDE, and daemon consumers block relaunch", arguments: [CodexConsumerKind.commandLine, .ide, .daemon])
    func externalConsumers(_ kind: CodexConsumerKind) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential)
        let processes = FixtureProcesses([.init(pid: 1, kind: kind, name: "Fixture")])
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes)
        guard case .pendingRelaunch = await adapter.activate(target.credential, account: target.account, relaunch: true) else { Issue.record("Should block"); return }
        #expect(try await store.read() == source.credential)
        #expect(await processes.quitCount == 0)
    }
    @Test("Refused or unconfirmed graceful quit cannot change authentication", arguments: [false, true])
    func failedQuit(_ acceptsButStays: Bool) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential)
        let processes = FixtureProcesses([.init(pid: 1, kind: .desktop, name: "Fixture")], accepted: acceptsButStays, staysRunning: acceptsButStays)
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes, terminationTimeout: 0)
        guard case .pendingRelaunch = await adapter.activate(target.credential, account: target.account, relaunch: true) else { Issue.record("Should block"); return }
        #expect(try await store.read() == source.credential)
        #expect(await processes.launchCount == 0)
    }
    @Test("Unreliable process scanning blocks every write")
    func unreliableScan() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential)
        let processes = FixtureProcesses(reliable: false)
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes)
        #expect(await adapter.hasRunningConsumers()) // Failed discovery must also defer active token refresh in the engine.
        guard case .pendingRelaunch = await adapter.activate(target.credential, account: target.account, relaunch: true) else { Issue.record("Should block"); return }
        #expect(try await store.read() == source.credential)
    }
    @Test("Latest auth is backed up after quit, before target activation and relaunch")
    func postQuitBackup() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), latest = try fixture.codex(token: "fixture-post-quit"), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential), backup = SourceBackup()
        let processes = FixtureProcesses([.init(pid: 1, kind: .desktop, name: "Fixture")], onQuit: {
            try AtomicAuthFileAccess().write(latest.credential.rawAuth, to: fixture.directory.appendingPathComponent("auth.json"))
        })
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes)
        guard case .applied = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: true, saveLatest: { await backup.save($0) }) else { Issue.record("Should apply"); return }
        #expect(await backup.value?.credential.accessToken == "fixture-post-quit")
        #expect(try await store.read().accessToken == "fixture-target")
        #expect(await processes.launchCount == 1)
    }
    @Test("Backup failure prevents target activation")
    func backupFailure() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential)
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: FixtureProcesses())
        guard case .failed = await adapter.activatePreservingSource(target.credential, account: target.account, relaunch: false, saveLatest: { _ in throw AgentSwapError.storage("Fixture backup failed") }) else { Issue.record("Should fail"); return }
        #expect(try await store.read() == source.credential)
    }
    @Test("Auth stays applied when desktop relaunch fails")
    func launchFailure() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let source = try fixture.codex(), target = try fixture.codex(token: "fixture-target", user: "target-user")
        let store = try fixture.store(source.credential), processes = FixtureProcesses()
        await processes.failLaunch()
        let adapter = CodexProviderAdapter(authStore: store, loginRunner: NoLogin(), processController: processes)
        guard case .applied(let message) = await adapter.activate(target.credential, account: target.account, relaunch: true) else { Issue.record("Target is already applied"); return }
        #expect(message.contains("재실행 실패"))
        #expect(try await store.read().accessToken == "fixture-target")
    }
    @Test("Process classifier covers IDE and server consumers without matching arbitrary commands")
    func classifier() {
        #expect(SystemCodexProcessController.classify(pid: 1, name: "node", executable: "/usr/bin/node", arguments: "node /x/@openai/codex/bin/codex.js", desktopURL: nil)?.kind == .commandLine)
        #expect(SystemCodexProcessController.classify(pid: 2, name: "codex", executable: "/x/.vscode/extensions/openai.chatgpt/bin/codex", arguments: "codex app-server", desktopURL: nil)?.kind == .ide)
        #expect(SystemCodexProcessController.classify(pid: 3, name: "codex", executable: "/x/codex", arguments: "codex app-server", desktopURL: nil)?.kind == .daemon)
        #expect(SystemCodexProcessController.classify(pid: 4, name: "node", executable: "/usr/bin/node", arguments: "node unrelated.js", desktopURL: nil) == nil)
        #expect(SystemCodexProcessController.classify(pid: 5, name: "codex", executable: "/Fixture/Codex.app/Contents/Resources/codex", arguments: "codex", desktopURL: URL(fileURLWithPath: "/Fixture/Codex.app"), desktopOwned: false)?.kind == .commandLine)
        #expect(SystemCodexProcessController.classify(pid: 6, name: "codex", executable: "/Fixture/Codex.app/Contents/Resources/codex", arguments: "codex app-server", desktopURL: URL(fileURLWithPath: "/Fixture/Codex.app"), desktopOwned: true)?.kind == .desktop)
    }
    @Test("Browser fallback accepts only provider-owned HTTPS login destinations")
    func safeLoginURLs() {
        let text = "https://evil.example/oauth/authorize https://auth.openai.com.evil.example/oauth/authorize https://auth.openai.com/oauth/authorize?fixture=1 http://auth.openai.com/oauth/authorize https://auth.openai.com:8443/oauth/authorize"
        #expect(OfficialCLILoginRunner.loginURLs(text, provider: .codex).map(\.host) == ["auth.openai.com"])
        #expect(OfficialCLILoginRunner.loginURLs(text, provider: .claude).isEmpty)
    }
    @Test("Only the first allowlisted explicit fallback is selected from repeated printed URLs")
    func explicitLoginURLSelection() {
        let fallback = "https://claude.com/cai/oauth/authorize?fixture=manual"
        let text = "https://claude.ai/oauth/authorize?fixture=automatic\nIf the browser didn't open, visit: https://evil.example/oauth/authorize\nIf the browser didn't open, visit: \(fallback) \(fallback) https://platform.claude.com/oauth/authorize?fixture=other\n"
        #expect(OfficialCLILoginRunner.loginPageURL(text, provider: .claude)?.absoluteString == fallback)
        #expect(OfficialCLILoginRunner.loginPageURL("If the browser didn't open, visit:\n\(fallback)\n", provider: .claude)?.absoluteString == fallback)
        #expect(OfficialCLILoginRunner.loginPageURL("https://evil.example/oauth/authorize", provider: .claude) == nil)
        #expect(OfficialCLILoginRunner.loginPageURL("https://auth.openai.com/oauth/authorize?fixture=codex", provider: .codex)?.host == "auth.openai.com")
    }
    @Test("CLI owns automatic browser opening; explicit fallback opens one page and keeps code login", arguments: [Provider.claude, .codex])
    func explicitBrowserFallback(_ provider: Provider) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try provider == .claude ? fixture.claudeSwitch() : fixture.codex()
        let seed = fixture.directory.appendingPathComponent("seed.json")
        try initial.credential.rawAuth.write(to: seed)
        let marker = fixture.directory.appendingPathComponent("profile-path")
        let cliBrowserMarker = fixture.directory.appendingPathComponent("cli-browser-opened")
        let script = fixture.directory.appendingPathComponent("fixture-login")
        let homeKey = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let authName = provider == .claude ? ".credentials.json" : "auth.json"
        let automatic = provider == .claude ? "https://claude.ai/oauth/authorize?fixture=automatic" : "https://auth.openai.com/oauth/authorize?fixture=automatic"
        let fallback = provider == .claude ? "https://claude.com/cai/oauth/authorize?fixture=manual" : "https://auth.openai.com/oauth/authorize?fixture=manual"
        let arguments = provider == .claude ? "test \"$1\" = auth\ntest \"$2\" = login\ntest \"$3\" = --claudeai\n" : "test \"$1\" = login\n"
        // The marker models the official CLI's own browser action, without opening a browser.
        let text = "#!/bin/sh\nset -eu\n\(arguments)printf '%s' \"$\(homeKey)\" > '\(marker.path)'\nprintf 'opened' > '\(cliBrowserMarker.path)'\nprintf '%s\\n' 'Opening browser to sign in' '\(automatic)'\nprintf '%s\\n' \"If the browser didn't open, visit: \(fallback)\" '\(fallback)' 'https://evil.example/oauth/authorize'\nprintf 'Paste code here if prompted > '\nIFS= read -r code\ntest \"$code\" = 'fixture-auth#fixture-state'\n/bin/cp '\(seed.path)' \"$\(homeKey)/\(authName)\"\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let opener = FixtureLoginURLOpener(holdOpen: true)
        let runner = OfficialCLILoginRunner(claudeExecutable: script, codexExecutable: script, keychain: fixture.keychain, urlOpener: opener)
        #expect(await runner.canOpenLoginPage() == false)
        await #expect(throws: AgentSwapError.self) { try await runner.openLoginPage() }
        let login = Task { try await runner.login(provider: provider) }
        let deadline = Date().addingTimeInterval(5)
        while !(await runner.canOpenLoginPage()) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let ready = await runner.canOpenLoginPage()
        guard ready else {
            await runner.cancel(); _ = try? await login.value
            Issue.record("Fixture did not expose a login fallback within the bounded wait")
            return
        }
        #expect(FileManager.default.fileExists(atPath: cliBrowserMarker.path))
        #expect(await opener.urls.isEmpty)
        let opening = Task { try await runner.openLoginPage() }
        let openingDeadline = Date().addingTimeInterval(5)
        while await opener.urls.isEmpty && Date() < openingDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard await opener.urls.count == 1 else {
            await opener.release(); await runner.cancel()
            _ = try? await opening.value; _ = try? await login.value
            Issue.record("Fixture browser opener was not called within the bounded wait")
            return
        }
        await #expect(throws: AgentSwapError.self) { try await runner.openLoginPage() }
        #expect(await opener.urls.map(\.absoluteString) == [fallback])
        await opener.release()
        try await opening.value
        try await runner.submitCode("fixture-auth#fixture-state")
        let credential = try await login.value
        #expect(credential.accessToken == initial.credential.accessToken)
        #expect(await opener.urls.count == 1)
        #expect(await runner.canOpenLoginPage() == false)
        await #expect(throws: AgentSwapError.self) { try await runner.openLoginPage() }
        let profile = try String(contentsOf: marker, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: profile))
    }
    @Test("Isolated CLI login collects only the temporary profile and removes it")
    func isolatedLogin() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.codex()
        let seed = fixture.directory.appendingPathComponent("seed.json")
        try initial.credential.rawAuth.write(to: seed)
        let marker = fixture.directory.appendingPathComponent("profile-path")
        let script = fixture.directory.appendingPathComponent("fixture-codex")
        let text = "#!/bin/sh\nset -eu\ntest -n \"$CODEX_HOME\"\ntest -z \"${OPENAI_API_KEY:-}\"\nprintf '%s' \"$CODEX_HOME\" > '\(marker.path)'\n/bin/cp '\(seed.path)' \"$CODEX_HOME/auth.json\"\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = OfficialCLILoginRunner(codexExecutable: script, keychain: fixture.keychain)
        let result = try await runner.login(provider: .codex)
        #expect(result.accessToken == initial.credential.accessToken)
        let profile = try String(contentsOf: marker, encoding: .utf8)
        #expect(profile.contains("AgentSwap-login-"))
        #expect(!FileManager.default.fileExists(atPath: profile))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("auth.json").path))
    }
    @Test("GUI authorization code reaches only the owned isolated CLI stdin")
    func manualCodeBridge() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let initial = try fixture.codex(), seed = fixture.directory.appendingPathComponent("seed.json")
        try initial.credential.rawAuth.write(to: seed)
        let marker = fixture.directory.appendingPathComponent("profile-path")
        let script = fixture.directory.appendingPathComponent("fixture-codex")
        let text = "#!/bin/sh\nset -eu\nprintf '%s' \"$CODEX_HOME\" > '\(marker.path)'\nprintf 'Paste code here if prompted > '\nIFS= read -r code\ntest \"$code\" = 'fixture-auth#fixture-state'\n/bin/cp '\(seed.path)' \"$CODEX_HOME/auth.json\"\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = OfficialCLILoginRunner(codexExecutable: script, keychain: fixture.keychain)
        let login = Task { try await runner.login(provider: .codex) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        for invalid in ["", "   ", "fixture\ncode", "fixture\rcode", "fixture\0code", String(repeating: "x", count: 16_385)] {
            await #expect(throws: AgentSwapError.self) { try await runner.submitCode(invalid) }
        }
        try await runner.submitCode(" fixture-auth#fixture-state ")
        let credential = try await login.value
        #expect(credential.accessToken == initial.credential.accessToken)
        let profile = try String(contentsOf: marker, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: profile))
        await #expect(throws: AgentSwapError.self) { try await runner.submitCode("fixture-auth#fixture-state") }
    }
    @Test("Optional login code capability has a safe unsupported default")
    func unsupportedCodeBridge() async {
        await #expect(throws: AgentSwapError.self) { try await NoLogin().submitCode("fixture-auth#fixture-state") }
        #expect(await NoLogin().canOpenLoginPage() == false)
        await #expect(throws: AgentSwapError.self) { try await NoLogin().openLoginPage() }
    }
    @Test("Failed login cleanup avoids permission UI and reports retained protected fixture data")
    func cleanupPermissionFailure() async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let marker = fixture.directory.appendingPathComponent("profile-path")
        let script = fixture.directory.appendingPathComponent("fixture-claude")
        let text = "#!/bin/sh\numask 077\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > '\(marker.path)'\nprintf 'fixture-auth-data' > \"$CLAUDE_CONFIG_DIR/.credentials.json\"\nexit 1\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        fixture.keychain.refuseDeletion()
        let runner = OfficialCLILoginRunner(claudeExecutable: script, keychain: fixture.keychain)
        do {
            _ = try await KeychainInteraction.$mode.withValue(.interactive) { try await runner.login(provider: .claude) }
            Issue.record("Fixture cleanup should fail")
        } catch {
            let profile = try String(contentsOf: marker, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: profile) }
            #expect(error.localizedDescription.contains(profile))
            #expect(!error.localizedDescription.contains("fixture-auth-data"))
            #expect(FileManager.default.fileExists(atPath: profile + "/.credentials.json"))
            #expect(fixture.keychain.lastDeleteMode() == .noninteractive)
        }
    }
    @Test("Both explicit and Task cancellation clean up a stubborn isolated login", arguments: [false, true])
    func cancelledLogin(_ taskCancellation: Bool) async throws {
        let fixture = try ProviderFixture(); defer { fixture.cleanup() }
        let marker = fixture.directory.appendingPathComponent("profile-path")
        let script = fixture.directory.appendingPathComponent("fixture-codex")
        let text = "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$CODEX_HOME\" > '\(marker.path)'\nprintf 'temporary-fixture-auth' > \"$CODEX_HOME/auth.json\"\nprintf '%s\\n' 'https://auth.openai.com/oauth/authorize?fixture=cancelled'\nwhile :; do /bin/sleep 1; done\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let opener = FixtureLoginURLOpener()
        let runner = OfficialCLILoginRunner(codexExecutable: script, keychain: fixture.keychain, urlOpener: opener)
        let task = Task { try await runner.login(provider: .codex) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        if taskCancellation { task.cancel() } else { await runner.cancel() }
        do { _ = try await task.value; Issue.record("Login should be cancelled") }
        catch { #expect(error as? AgentSwapError == .cancelled) }
        #expect(await runner.canOpenLoginPage() == false)
        await #expect(throws: AgentSwapError.self) { try await runner.openLoginPage() }
        #expect(await opener.urls.isEmpty)
        let profile = try String(contentsOf: marker, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: profile))
    }
}
