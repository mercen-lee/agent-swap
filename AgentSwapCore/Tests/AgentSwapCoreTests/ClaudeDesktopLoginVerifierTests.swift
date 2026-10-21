import Foundation
import CommonCrypto
import Testing
@testable import AgentSwapCore

private final class DesktopVerifierKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + "|" + account] = data } }
    func delete(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + "|" + account) } }
}

private actor DesktopVerifierTransport: ProviderHTTPTransport {
    private let response: ProviderHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ response: ProviderHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        return response
    }
    func requestCount() -> Int { requests.count }
    func firstRequest() -> URLRequest? { requests.first }
}

@Suite("Claude Desktop 로그인 확인") struct ClaudeDesktopLoginVerifierTests {
    private let user = "11111111-1111-1111-1111-111111111111"
    private let organization = "22222222-2222-2222-2222-222222222222"
    private let password = Data("fixture-electron-safe-storage".utf8)

    @Test func verifiesFixedProfileForMatchingEncryptedCache() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "api.anthropic.com"), expected: identity)
        #expect(await transport.requestCount() == 1)
        let request = try #require(await transport.firstRequest())
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
    }

    @Test func rejectsProfileMismatchAfterOneFixedRequest() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: "33333333-3333-3333-3333-333333333333"), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "https://api.anthropic.com"), expected: identity)
        }
        #expect(await transport.requestCount() == 1)
    }

    @Test func rejectsUnknownHostBeforeSendingToken() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "attacker.example"), expected: identity)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func rejectsTamperedCiphertextAndMissingSafeStorageKeyWithoutHTTP() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        var broken = cache(host: "api.anthropic.com")
        broken.removeLast()
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: broken, expected: identity)
        }
        #expect(await transport.requestCount() == 0)

        let missing = SystemClaudeDesktopLoginVerifier(keychain: DesktopVerifierKeychain(), transport: transport)
        await #expect(throws: AgentSwapError.self) {
            try await missing.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "api.anthropic.com"), expected: identity)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func rejectsUnsupportedCacheFormatBeforeHTTP() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: "not-a-Desktop-cache", expected: identity)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func rejectsForeignUserOrOrganizationBeforeHTTP() async throws {
        for foreign in ["acct:33333333-3333-3333-3333-333333333333|fixture-client:\(organization):api.anthropic.com:scope",
                        "acct:\(user)|fixture-client:33333333-3333-3333-3333-333333333333:api.anthropic.com:scope"] {
            let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
            let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
            await #expect(throws: AgentSwapError.self) {
                try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "api.anthropic.com", extra: [foreign: credential(token: "foreign-token", expiry: 4_102_444_801)]), expected: identity)
            }
            #expect(await transport.requestCount() == 0)
        }
    }

    @Test func choosesUniqueNewestScopeForSameIdentity() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        let otherScope = "acct:\(user)|fixture-client:\(organization):api.anthropic.com:other-scope"
        try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "api.anthropic.com", extra: [otherScope: credential(token: "newest-token", expiry: 4_102_444_801)]), expected: identity)
        #expect(await transport.firstRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer newest-token")
        #expect(await transport.requestCount() == 1)
    }

    @Test func rejectsTiedDistinctTokensBeforeHTTP() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        let otherScope = "acct:\(user)|fixture-client:\(organization):api.anthropic.com:other-scope"
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: emptyLegacyCache, tokenCacheV2: cache(host: "api.anthropic.com", extra: [otherScope: credential(token: "tied-token", expiry: 4_102_444_800)]), expected: identity)
        }
        #expect(await transport.requestCount() == 0)
    }

    @Test func refusesAnyLegacyCacheEntryBeforeHTTP() async throws {
        for value: [String: Any] in [["old-entry": NSNull()], ["old-entry": ["token": "legacy-token"]]] {
            let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
            let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
            let json = try JSONSerialization.data(withJSONObject: value)
            let legacy = (Data("v10".utf8) + encrypt(json, password: password)).base64EncodedString()
            await #expect(throws: AgentSwapError.self) {
                try await verifier.verify(tokenCacheV1: legacy, tokenCacheV2: cache(host: "api.anthropic.com"), expected: identity)
            }
            #expect(await transport.requestCount() == 0)
        }
    }

    @Test func refusesUnknownCipherVersionBeforeHTTP() async throws {
        let transport = DesktopVerifierTransport(.init(data: profile(user: user, organization: organization), statusCode: 200))
        let verifier = SystemClaudeDesktopLoginVerifier(keychain: keychain(), transport: transport)
        let unknown = (Data("v11".utf8) + encrypt(Data("{}".utf8), password: password)).base64EncodedString()
        await #expect(throws: AgentSwapError.self) {
            try await verifier.verify(tokenCacheV1: unknown, tokenCacheV2: cache(host: "api.anthropic.com"), expected: identity)
        }
        #expect(await transport.requestCount() == 0)
    }

    private var emptyLegacyCache: String { (Data("v10".utf8) + encrypt(Data("{}".utf8), password: password)).base64EncodedString() }

    private var identity: AccountIdentity { .init(provider: .claude, userID: user, workspaceID: organization) }

    private func keychain() -> DesktopVerifierKeychain {
        let result = DesktopVerifierKeychain()
        try! result.write(password, service: "Claude Safe Storage", account: "Claude Key")
        return result
    }

    private func credential(token: String, expiry: Double) -> [String: Any] {
        ["token": token, "refreshToken": "fixture-refresh-token", "expiresAt": expiry]
    }

    private func cache(host: String, extra: [String: Any] = [:]) -> String {
        let key = "acct:\(user)|fixture-client:\(organization):\(host):scope"
        var object: [String: Any] = [key: credential(token: "fixture-access-token", expiry: 4_102_444_800)]
        object.merge(extra, uniquingKeysWith: { _, latest in latest })
        let plaintext = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (Data("v10".utf8) + encrypt(plaintext, password: password)).base64EncodedString()
    }

    private func profile(user: String, organization: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["account": ["uuid": user], "organization": ["uuid": organization]], options: [.sortedKeys])
    }

    private func encrypt(_ plaintext: Data, password: Data) -> Data {
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                Data("saltysalt".utf8).withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                          saltBytes.bindMemory(to: UInt8.self).baseAddress, 9, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                          keyBytes.bindMemory(to: UInt8.self).baseAddress, keyCount)
                }
            }
        }
        precondition(status == kCCSuccess)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var encrypted = Data(repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        let capacity = encrypted.count
        var length = 0
        let encryptedStatus = encrypted.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    plaintext.withUnsafeBytes { source in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, plaintext.count,
                                destination.baseAddress, capacity, &length)
                    }
                }
            }
        }
        precondition(encryptedStatus == kCCSuccess)
        encrypted.removeSubrange(length..<encrypted.count)
        return encrypted
    }
}
