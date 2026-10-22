import Foundation
import CryptoKit

/// Evidence created after the fixed OAuth profile endpoint authenticates a grant.
/// It is stored only inside the Keychain Credential. Native metadata is merely a cache.
public struct ClaudeCredentialIdentityBinding: Codable, Equatable, Sendable {
    public let version: Int
    public let identity: AccountIdentity
    public let grantDigest: String

    init(identity: AccountIdentity, grantDigest: String) {
        self.version = 1
        self.identity = identity
        self.grantDigest = grantDigest
    }
}

public extension Credential {
    var verifiedClaudeAccountIdentity: AccountIdentity? {
        guard let binding = claudeIdentityBinding, binding.version == 1,
              binding.identity.provider == .claude,
              let digest = claudeGrantDigest, binding.grantDigest == digest,
              let parsed = try? CredentialParser.claude(rawAuth: rawAuth, accountMetadata: accountMetadata),
              parsed.accessToken == accessToken, parsed.refreshToken == refreshToken,
              let account = try? ProviderAccountParser.claude(parsed).account,
              account.identity == binding.identity,
              matchesClaudeOrganization(binding.identity) else { return nil }
        return binding.identity
    }

    /// Call only with identity supplied by an authenticated profile response, or an
    /// already validated binding for this exact grant; cached oauthAccount is insufficient.
    func withVerifiedClaudeIdentity(_ identity: AccountIdentity) throws -> Credential {
        guard identity.provider == .claude, let digest = claudeGrantDigest,
              let parsed = try? CredentialParser.claude(rawAuth: rawAuth, accountMetadata: accountMetadata),
              parsed.accessToken == accessToken, parsed.refreshToken == refreshToken,
              let account = try? ProviderAccountParser.claude(parsed).account,
              account.identity == identity, matchesClaudeOrganization(identity) else {
            throw AgentSwapError.storage("확인한 Claude 계정과 저장할 인증 정보가 일치하지 않습니다.")
        }
        var credential = self
        credential.claudeIdentityBinding = .init(identity: identity, grantDigest: digest)
        return credential
    }

    private var claudeGrantDigest: String? {
        // JSON array encoding distinguishes nil, empty strings and separator characters.
        guard let data = try? JSONEncoder().encode([accessToken, refreshToken]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func matchesClaudeOrganization(_ identity: AccountIdentity) -> Bool {
        guard let object = try? ProviderJSON.object(rawAuth) else { return false }
        guard let value = object["organizationUuid"] else { return true }
        return (value as? String) == identity.workspaceID
    }
}
