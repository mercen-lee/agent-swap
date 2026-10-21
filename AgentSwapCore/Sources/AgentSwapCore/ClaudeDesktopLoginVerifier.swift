import Foundation
import CommonCrypto

/// Confirms that an opaque Claude Desktop token cache belongs to the registered account.
/// It only reads the Electron safe-storage key and makes one fixed profile request; it never
/// refreshes a token or changes either Keychain item.
public protocol ClaudeDesktopLoginVerifying: Sendable {
    func verify(tokenCacheV1: String, tokenCacheV2: String, expected: AccountIdentity) async throws
}

public struct SystemClaudeDesktopLoginVerifier: ClaudeDesktopLoginVerifying {
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"
    private static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    private static let maximumEncodedBytes = 32 * 1_024 * 1_024
    private static let maximumJSONEntries = 256
    private static let maximumTokenBytes = 100 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    private let keychain: any KeychainAccess
    private let transport: any ProviderHTTPTransport

    public init(keychain: any KeychainAccess = SystemKeychainAccess(),
                transport: any ProviderHTTPTransport = URLSessionProviderTransport()) {
        self.keychain = keychain
        self.transport = transport
    }

    public func verify(tokenCacheV1: String, tokenCacheV2: String, expected: AccountIdentity) async throws {
        guard expected.provider == .claude,
              let userID = canonicalUUID(expected.userID),
              let organizationID = canonicalUUID(expected.workspaceID) else {
            throw unsupported()
        }
        let legacyEnvelope = try envelope(tokenCacheV1)
        let currentEnvelope = try envelope(tokenCacheV2)
        guard let password = try keychain.read(service: Self.safeStorageService, account: Self.safeStorageAccount),
              !password.isEmpty, password.count <= Self.maximumTokenBytes else {
            throw unsupported()
        }

        let legacy = try decryptElectronCache(legacyEnvelope, password: password)
        guard let legacyObject = try? JSONSerialization.jsonObject(with: legacy) as? [String: Any], legacyObject.isEmpty else {
            // V1 can independently serve or seed credentials; never pair an unverified legacy
            // grant with a profile-verified V2 login.
            throw unsupported()
        }
        let plaintext = try decryptElectronCache(currentEnvelope, password: password)
        let token = try credentialToken(plaintext: plaintext, userID: userID, organizationID: organizationID)
        var request = ProviderHTTP.request(Self.profileURL, token: token)
        request.httpMethod = "GET"
        let response = try await transport.send(request)
        guard response.data.count <= Self.maximumResponseBytes else { throw unsupported() }
        let data = try ProviderHTTP.checked(response)
        let root = try ProviderJSON.object(data)
        guard let account = root["account"] as? [String: Any],
              let organization = root["organization"] as? [String: Any],
              let actualUser = canonicalUUID(account["uuid"] as? String),
              let actualOrganization = canonicalUUID(organization["uuid"] as? String),
              actualUser == userID, actualOrganization == organizationID else {
            throw AgentSwapError.authentication("Claude Desktop 로그인 계정을 확인하지 못했습니다.")
        }
    }

    private func envelope(_ value: String) throws -> Data {
        guard value.utf8.count <= Self.maximumEncodedBytes,
              let data = Data(base64Encoded: value, options: []),
              data.count >= 3 + kCCBlockSizeAES128,
              data.starts(with: Data("v10".utf8)) else { throw unsupported() }
        return Data(data.dropFirst(3))
    }

    private func credentialToken(plaintext: Data, userID: String, organizationID: String) throws -> String {
        guard plaintext.count <= Self.maximumEncodedBytes,
              let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              root.count <= Self.maximumJSONEntries else {
            throw unsupported()
        }
        var tokens: [String: Double] = [:]
        for (key, value) in root {
            if value is NSNull { continue }
            guard let entry = parseKey(key) else { throw unsupported() }
            guard let credential = value as? [String: Any] else { throw unsupported() }
            // A cache containing another identity does not prove which account is active.
            guard entry.userID == userID, entry.organizationID == organizationID else {
                throw AgentSwapError.authentication("현재 Claude Desktop 로그인과 선택한 계정 또는 조직이 다릅니다. Desktop의 현재 로그인을 확인해 주세요.")
            }
            // An unrecognized endpoint is never allowed to control an Authorization request.
            guard entry.host == "api.anthropic.com" else { throw unsupported() }
            guard let token = credential["token"] as? String,
                  !token.isEmpty, token.utf8.count <= Self.maximumTokenBytes,
                  token.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
                  let expiry = ProviderJSON.number(credential["expiresAt"]), expiry > 0 else {
                throw unsupported()
            }
            tokens[token] = max(tokens[token] ?? 0, expiry)
        }
        guard let newestExpiry = tokens.values.max() else { throw unsupported() }
        let newest = tokens.filter { $0.value == newestExpiry }
        guard newest.count == 1, let token = newest.keys.first else { throw unsupported() }
        return token
    }

    private func parseKey(_ key: String) -> CacheKey? {
        guard key.utf8.count <= 4_096,
              key.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
              key.hasPrefix("acct:"),
              let pipe = key.firstIndex(of: "|") else { return nil }
        let userText = String(key[key.index(key.startIndex, offsetBy: 5)..<pipe])
        guard let userID = canonicalUUID(userText) else { return nil }
        let afterPipe = key[key.index(after: pipe)...]
        guard let clientSeparator = afterPipe.firstIndex(of: ":"), clientSeparator != afterPipe.startIndex else { return nil }
        let afterClient = afterPipe[afterPipe.index(after: clientSeparator)...]
        guard let organizationSeparator = afterClient.firstIndex(of: ":"),
              let organizationID = canonicalUUID(String(afterClient[..<organizationSeparator])) else { return nil }
        let endpointAndScope = afterClient[afterClient.index(after: organizationSeparator)...]
        for prefix in ["api.anthropic.com:", "https://api.anthropic.com:"] {
            guard endpointAndScope.hasPrefix(prefix) else { continue }
            let scope = endpointAndScope.dropFirst(prefix.count)
            guard !scope.isEmpty else { return nil }
            return CacheKey(userID: userID, organizationID: organizationID, host: "api.anthropic.com")
        }
        return nil
    }

    private func decryptElectronCache(_ ciphertext: Data, password: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { throw unsupported() }
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        let keyCount = key.count
        let derivationStatus = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                Data("saltysalt".utf8).withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                          saltBytes.bindMemory(to: UInt8.self).baseAddress, 9,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                          keyBytes.bindMemory(to: UInt8.self).baseAddress, keyCount)
                }
            }
        }
        guard derivationStatus == kCCSuccess else { throw unsupported() }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let cryptStatus = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    ciphertext.withUnsafeBytes { cipherBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                cipherBytes.baseAddress, ciphertext.count,
                                outputBytes.baseAddress, outputCapacity, &outputLength)
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess, outputLength <= Self.maximumEncodedBytes else { throw unsupported() }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private func canonicalUUID(_ value: String?) -> String? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func unsupported() -> AgentSwapError {
        .unsupported("Claude Desktop 로그인 확인 형식을 지원하지 않습니다. Desktop에서 다시 로그인한 뒤 저장해 주세요.")
    }
}

private struct CacheKey: Sendable {
    var userID: String
    var organizationID: String
    var host: String
}
