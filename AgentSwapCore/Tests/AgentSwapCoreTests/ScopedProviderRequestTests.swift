import Foundation
import Testing
@testable import AgentSwapCore

private actor ScopedRequestTransport: ProviderHTTPTransport {
    private var responses: [ProviderHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AgentSwapError.network("Unexpected fixture HTTP request") }
        return responses.removeFirst()
    }
}

private struct ScopedRequestLogin: ProviderLoginRunner {
    func login(provider: Provider) throws -> Credential { throw AgentSwapError.cancelled }
    func cancel() {}
}

private struct ScopedRequestKeychain: KeychainAccess {
    func read(service: String, account: String) -> Data? { nil }
    func write(_ data: Data, service: String, account: String) throws {
        throw AgentSwapError.storage("Unexpected fixture credential write")
    }
    func delete(service: String, account: String) throws {
        throw AgentSwapError.storage("Unexpected fixture credential deletion")
    }
}

private struct ScopedRequestProcesses: CodexProcessControlling {
    func scan() -> CodexProcessScan { .init(consumers: [], reliable: true) }
    func installation() -> CodexDesktopInstallation? { nil }
    func requestDesktopTermination() -> Bool { false }
    func relaunchDesktop() throws { throw AgentSwapError.cancelled }
}

private struct ScopedRequestFixture {
    let home: URL
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapScopedRequests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func account(_ provider: Provider, name: String, verified: Bool = true) throws -> ImportedAccount {
        if provider == .claude {
            let metadata = try ProviderJSON.data(["accountUuid": "fixture-\(name)", "organizationUuid": "fixture-workspace-\(name)"])
            var credential = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": [
                "accessToken": "fixture-access-\(name)", "refreshToken": "fixture-refresh-\(name)",
                "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
            ]]), accountMetadata: metadata)
            let account = try ProviderAccountParser.claude(credential).account
            if verified { credential = try credential.withVerifiedClaudeIdentity(account.identity) }
            return .init(account: account, credential: credential)
        }
        let claims: [String: Any] = ["sub": "fixture-\(name)", "https://api.openai.com/auth": [
            "chatgpt_user_id": "fixture-\(name)", "chatgpt_account_id": "fixture-workspace-\(name)", "chatgpt_plan_type": "pro"
        ]]
        let encoded = try ProviderJSON.data(claims).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let credential = try CredentialParser.codex(rawAuth: ProviderJSON.data(["auth_mode": "chatgpt", "tokens": [
            "access_token": "fixture-access-\(name)", "refresh_token": "fixture-refresh-\(name)",
            "id_token": "fixture.\(encoded).signature", "account_id": "fixture-workspace-\(name)"
        ]]))
        return try ProviderAccountParser.codex(credential)
    }
    func adapter(_ provider: Provider, transport: ScopedRequestTransport) -> any ProviderAdapter {
        if provider == .claude {
            return ClaudeProviderAdapter(authStore: ClaudeAuthStore(home: home, keychain: ScopedRequestKeychain()),
                                         transport: transport, loginRunner: ScopedRequestLogin())
        }
        return CodexProviderAdapter(authStore: CodexAuthStore(home: home, keychain: ScopedRequestKeychain()),
                                    transport: transport, loginRunner: ScopedRequestLogin(), processController: ScopedRequestProcesses())
    }
    func usage(_ provider: Provider) -> ProviderHTTPResponse {
        .init(data: Data((provider == .claude
            ? #"{"five_hour":{"utilization":23}}"#
            : #"{"rate_limit":{"primary_window":{"used_percent":23}}}"#).utf8), statusCode: 200)
    }
    func profile(_ account: AccountRecord) throws -> ProviderHTTPResponse {
        .init(data: try ProviderJSON.data(["account": ["uuid": account.identity.userID],
                                           "organization": ["uuid": account.identity.workspaceID]]), statusCode: 200)
    }
}

private func scopedLimit(_ operation: () async throws -> Void) async throws -> ProviderRequestRateLimit {
    do {
        try await operation()
        throw AgentSwapError.storage("Expected a scoped fixture rate limit")
    } catch AgentSwapError.requestRateLimited(let limit) { return limit }
}

@Suite("Scoped provider HTTP requests")
struct ScopedProviderRequestTests {
    @Test("Unusable server deadlines use a five-minute fallback", arguments: [
        nil, "", "0", "-1", "NaN", "inf", "Wed, 14 Oct 2026 00:00:00 GMT"
    ] as [String?])
    func unusableRetryAfter(_ header: String?) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = ProviderRequestKey.account(provider: .claude, kind: .usage, accountID: UUID())
        let headers = header.map { ["Retry-After": $0] } ?? [:]
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(), statusCode: 429, headers: headers), now: now, rateLimitKey: key)
            Issue.record("Expected a scoped rate limit")
        } catch AgentSwapError.requestRateLimited(let limit) {
            #expect(limit.key == key)
            #expect(limit.retryAfter == now.addingTimeInterval(300))
            #expect(limit.source == .fallback)
        }
    }

    @Test("Future server deadlines are kept exactly", arguments: ["120", " 0.5 ", "Wed, 14 Oct 2026 03:00:00 GMT"])
    func futureRetryAfter(_ header: String) throws {
        let now = try #require(ProviderJSON.date("2026-10-14T02:00:00Z"))
        let expected = header.contains("GMT") ? 3600 : Double(header.trimmingCharacters(in: .whitespacesAndNewlines))!
        let key = ProviderRequestKey.account(provider: .codex, kind: .tokenRefresh, accountID: UUID())
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(), statusCode: 429, headers: ["Retry-After": header]),
                                         now: now, rateLimitKey: key)
            Issue.record("Expected a scoped rate limit")
        } catch AgentSwapError.requestRateLimited(let limit) {
            #expect(limit.retryAfter == now.addingTimeInterval(expected))
            #expect(limit.source == .serverHeader)
        }
    }

    @Test("Unscoped callers retain the legacy error shape")
    func legacyHTTPError() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(), statusCode: 429), now: now)
            Issue.record("Expected the legacy rate limit")
        } catch AgentSwapError.rateLimited(let retry) { #expect(retry == now.addingTimeInterval(300)) }
    }

    @Test("One account's usage throttle blocks repeat HTTP while another account succeeds", arguments: Provider.allCases)
    func usageThrottleIsScoped(_ provider: Provider) async throws {
        let fixture = try ScopedRequestFixture(); defer { fixture.cleanup() }
        let first = try fixture.account(provider, name: "first")
        let second = try fixture.account(provider, name: "second")
        let transport = ScopedRequestTransport([.init(data: Data(), statusCode: 429, headers: ["Retry-After": "1200"]), fixture.usage(provider)])
        let adapter = fixture.adapter(provider, transport: transport)
        let firstLimit = try await scopedLimit { _ = try await adapter.fetchUsage(first.credential, account: first.account) }
        #expect(firstLimit.key == .account(provider: provider, kind: .usage, accountID: first.account.id))
        let repeatLimit = try await scopedLimit { _ = try await adapter.fetchUsage(first.credential, account: first.account) }
        #expect(repeatLimit.retryAfter == firstLimit.retryAfter)
        #expect(await transport.requests.count == 1)
        _ = try await adapter.fetchUsage(second.credential, account: second.account)
        #expect(await transport.requests.count == 2)
        let retained = await adapter.activeRequestRateLimits()
        #expect(retained.count == 1)
        #expect(retained.first?.key == firstLimit.key)
        #expect(retained.first?.retryAfter == firstLimit.retryAfter)
        #expect((await transport.requests).allSatisfy { $0.url?.path.contains("usage") == true })
    }

    @Test("Restored usage gates survive a new adapter and never become token-refresh gates", arguments: Provider.allCases)
    func restoredGatesKeepRequestKind(_ provider: Provider) async throws {
        let fixture = try ScopedRequestFixture(); defer { fixture.cleanup() }
        let imported = try fixture.account(provider, name: "restored")
        let usageKey = ProviderRequestKey.account(provider: provider, kind: .usage, accountID: imported.account.id)
        let refreshKey = ProviderRequestKey.account(provider: provider, kind: .tokenRefresh, accountID: imported.account.id)
        let retry = Date().addingTimeInterval(1200)
        let transport = ScopedRequestTransport([.init(data: Data(), statusCode: 429, headers: ["Retry-After": "600"])])
        let adapter = fixture.adapter(provider, transport: transport)
        await adapter.restoreRequestRateLimits([.init(key: usageKey, retryAfter: retry, source: .serverHeader)])
        _ = try await scopedLimit { _ = try await adapter.fetchUsage(imported.credential, account: imported.account) }
        #expect(await transport.requests.isEmpty)
        let refreshLimit = try await scopedLimit { _ = try await adapter.refresh(imported.credential, account: imported.account) }
        #expect(refreshLimit.key == refreshKey)
        #expect(await transport.requests.count == 1)
        #expect((await transport.requests).first?.url?.path.contains("token") == true)
        _ = try await scopedLimit { _ = try await adapter.refresh(imported.credential, account: imported.account) }
        #expect(await transport.requests.count == 1)
        #expect(Set((await adapter.activeRequestRateLimits()).map(\.key)) == Set([usageKey, refreshKey]))
    }

    @Test("Restoration keeps the longest same-key deadline and ignores expired or foreign-provider gates", arguments: Provider.allCases)
    func restoreMergesOnlyMatchingProvider(_ provider: Provider) async throws {
        let fixture = try ScopedRequestFixture(); defer { fixture.cleanup() }
        let imported = try fixture.account(provider, name: "merged")
        let key = ProviderRequestKey.account(provider: provider, kind: .usage, accountID: imported.account.id)
        let otherProvider: Provider = provider == .claude ? .codex : .claude
        let foreign = ProviderRequestKey.account(provider: otherProvider, kind: .usage, accountID: UUID())
        let expired = ProviderRequestKey.account(provider: provider, kind: .tokenRefresh, accountID: imported.account.id)
        let retry = Date().addingTimeInterval(1200)
        let transport = ScopedRequestTransport([])
        let adapter = fixture.adapter(provider, transport: transport)
        await adapter.restoreRequestRateLimits([.init(key: key, retryAfter: retry, source: .serverHeader)])
        await adapter.restoreRequestRateLimits([
            .init(key: key, retryAfter: retry.addingTimeInterval(-100), source: .fallback),
            .init(key: foreign, retryAfter: retry, source: .serverHeader),
            .init(key: expired, retryAfter: Date().addingTimeInterval(-1), source: .fallback)
        ])
        let retained = await adapter.activeRequestRateLimits()
        #expect(retained.count == 1)
        #expect(retained.first?.key == key)
        #expect(retained.first?.retryAfter == retry)
        #expect(retained.first?.source == .serverHeader)
        #expect(await transport.requests.isEmpty)
    }

    @Test("An unknown Claude profile throttle keeps its exact credential scope across adapter restoration")
    func profileThrottleUsesCredentialScope() async throws {
        let fixture = try ScopedRequestFixture(); defer { fixture.cleanup() }
        let first = try fixture.account(.claude, name: "profile-first", verified: false)
        let second = try fixture.account(.claude, name: "profile-second", verified: false)
        let transport = ScopedRequestTransport([
            .init(data: Data(), statusCode: 429, headers: ["Retry-After": "1200"]),
            try fixture.profile(second.account), fixture.usage(.claude)
        ])
        let adapter = fixture.adapter(.claude, transport: transport)
        let limit = try await scopedLimit { _ = try await adapter.verifyCredential(first.credential, account: first.account) }
        #expect(limit.key == .credential(provider: .claude, kind: .profile, token: first.credential.accessToken))
        _ = try await scopedLimit { _ = try await adapter.verifyCredential(first.credential, account: first.account) }
        #expect(await transport.requests.count == 1)
        _ = try await adapter.fetchUsage(second.credential, account: second.account)
        #expect((await transport.requests).map { $0.url?.path } == ["/api/oauth/profile", "/api/oauth/profile", "/api/oauth/usage"])
        let restoredTransport = ScopedRequestTransport([])
        let restored = fixture.adapter(.claude, transport: restoredTransport)
        await restored.restoreRequestRateLimits(await adapter.activeRequestRateLimits())
        let restoredLimit = try await scopedLimit { _ = try await restored.verifyCredential(first.credential, account: first.account) }
        #expect(restoredLimit.key == limit.key)
        #expect(restoredLimit.retryAfter == limit.retryAfter)
        #expect(await restoredTransport.requests.isEmpty)
    }
}
