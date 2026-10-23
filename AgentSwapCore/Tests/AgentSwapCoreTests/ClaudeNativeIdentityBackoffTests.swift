import Foundation
import Testing
@testable import AgentSwapCore

private final class NativeIdentityBackoffKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) { lock.withLock { values[service + "|" + account] = data } }
    func delete(service: String, account: String) { lock.withLock { _ = values.removeValue(forKey: service + "|" + account) } }
}

private actor NativeIdentityBackoffTransport: ProviderHTTPTransport {
    private var status = 401
    private(set) var requests: [String] = []
    func send(_ request: URLRequest) throws -> ProviderHTTPResponse {
        let path = request.url?.path ?? ""
        requests.append(path)
        guard path == "/api/oauth/profile" else { throw AgentSwapError.network("Unexpected fixture request") }
        let data = status == 200 ? try ProviderJSON.data([
            "account": ["uuid": NativeIdentityBackoffFixture.identity.userID],
            "organization": ["uuid": NativeIdentityBackoffFixture.identity.workspaceID]
        ]) : Data("{}".utf8)
        return .init(data: data, statusCode: status)
    }
    func succeed() { status = 200 }
}

private struct NativeIdentityBackoffLogin: ProviderLoginRunner {
    let credential: Credential
    func login(provider: Provider) -> Credential { credential }
    func cancel() {}
}

private struct NativeIdentityBackoffFixture {
    static let identity = AccountIdentity(provider: .claude, userID: "fixture-backoff-user", workspaceID: "fixture-backoff-workspace")
    let home: URL
    let keychain = NativeIdentityBackoffKeychain()
    let store: ClaudeAuthStore
    let credential: Credential
    let transport = NativeIdentityBackoffTransport()
    var adapter: ClaudeProviderAdapter { .init(authStore: store, transport: transport, loginRunner: NativeIdentityBackoffLogin(credential: credential)) }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapNativeIdentityBackoffFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        store = ClaudeAuthStore(home: home, keychain: keychain)
        credential = try Self.makeCredential()
        keychain.write(credential.rawAuth, service: store.keychainService, account: store.keychainAccount)
        let metadata = try #require(credential.accountMetadata)
        try AtomicAuthFileAccess().write(ProviderJSON.data([
            "oauthAccount": ProviderJSON.object(metadata)
        ]), to: store.configURL)
    }

    static func makeCredential(access: String = "fixture-backoff-access", refresh: String = "fixture-backoff-refresh") throws -> Credential {
        try CredentialParser.claude(rawAuth: ProviderJSON.data([
            "claudeAiOauth": ["accessToken": access, "refreshToken": refresh,
                              "expiresAt": Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000],
            "organizationUuid": identity.workspaceID
        ]), accountMetadata: ProviderJSON.data(["accountUuid": identity.userID, "organizationUuid": identity.workspaceID]))
    }

    func replaceNative(with credential: Credential) {
        keychain.write(credential.rawAuth, service: store.keychainService, account: store.keychainAccount)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Claude native identity retry backoff")
struct ClaudeNativeIdentityBackoffTests {
    @Test("Repeated native identity rejection reuses a short failure backoff without consuming OAuth")
    func repeatedNativeRejectionMakesOneRequest() async throws {
        let fixture = try NativeIdentityBackoffFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        for _ in 0..<3 {
            do {
                _ = try await adapter.importCurrentIfPresent()
                Issue.record("A rejected native grant must remain unidentified")
            } catch let error as AgentSwapError {
                guard case .nativeIdentityUnverified = error else { Issue.record("Native rejection must preserve its error classification"); return }
            }
        }
        #expect(await fixture.transport.requests == ["/api/oauth/profile"])
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == fixture.credential.rawAuth)
    }

    @Test("A changed native access or refresh token does not inherit another grant's rejection", arguments: [true, false])
    func changedNativeGrantRetriesProfile(changeAccess: Bool) async throws {
        let fixture = try NativeIdentityBackoffFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        await #expect(throws: AgentSwapError.self) { try await adapter.importCurrent() }
        let replacement = try NativeIdentityBackoffFixture.makeCredential(
            access: changeAccess ? "fixture-backoff-successor-access" : fixture.credential.accessToken,
            refresh: changeAccess ? fixture.credential.refreshToken! : "fixture-backoff-successor-refresh")
        fixture.replaceNative(with: replacement)
        await fixture.transport.succeed()
        let imported = try await adapter.importCurrent()
        #expect(imported.account.identity == NativeIdentityBackoffFixture.identity)
        #expect(imported.credential.accessToken == replacement.accessToken)
        #expect(imported.credential.refreshToken == replacement.refreshToken)
        #expect(await fixture.transport.requests == ["/api/oauth/profile", "/api/oauth/profile"])
    }

    @Test("An exact persisted identity proof supersedes a cached native rejection without a new request")
    func registeredProofSupersedesNativeRejection() async throws {
        let fixture = try NativeIdentityBackoffFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        await #expect(throws: AgentSwapError.self) { try await adapter.importCurrent() }
        let verified = try fixture.credential.withVerifiedClaudeIdentity(NativeIdentityBackoffFixture.identity)
        let account = AccountRecord(identity: NativeIdentityBackoffFixture.identity)
        await adapter.registerStoredCredential(verified, account: account)
        let imported = try await adapter.importCurrent()
        #expect(imported.account.identity == account.identity)
        #expect(imported.credential.verifiedClaudeAccountIdentity == account.identity)
        #expect(await fixture.transport.requests == ["/api/oauth/profile"])
    }

    @Test("Independent login and stored verification do not inherit a native rejection", arguments: [true, false])
    func nonnativeIdentificationBypassesBackoff(login: Bool) async throws {
        let fixture = try NativeIdentityBackoffFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter
        await #expect(throws: AgentSwapError.self) { try await adapter.importCurrent() }
        await fixture.transport.succeed()
        let identified: Credential
        if login {
            identified = try await adapter.login().credential
        } else {
            identified = try await adapter.verifyCredential(fixture.credential, account: AccountRecord(identity: NativeIdentityBackoffFixture.identity))
        }
        #expect(identified.verifiedClaudeAccountIdentity == NativeIdentityBackoffFixture.identity)
        #expect(await fixture.transport.requests == ["/api/oauth/profile", "/api/oauth/profile"])
    }
}
