import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Claude authenticated identity evidence persistence")
struct ClaudeCredentialIdentityBindingTests {
    private let identity = AccountIdentity(provider: .claude, userID: "fixture-user", workspaceID: "fixture-workspace")

    private func credential() throws -> Credential {
        try CredentialParser.claude(
            rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-access", "refreshToken": "fixture-refresh"], "sharedFixture": true]),
            accountMetadata: ProviderJSON.data(["accountUuid": identity.userID, "organizationUuid": identity.workspaceID]))
    }

    @Test("Old Keychain credentials decode without inventing an authenticated binding")
    func legacyDecode() throws {
        let original = try credential()
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        encoded.removeValue(forKey: "claudeIdentityBinding")
        let decoded = try JSONDecoder().decode(Credential.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded == original)
        #expect(decoded.verifiedClaudeAccountIdentity == nil)
    }

    @Test("A verified binding survives vault encoding and native JSON representation changes")
    func roundTrip() throws {
        let original = try credential().withVerifiedClaudeIdentity(identity)
        var decoded = try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(original))
        #expect(decoded.verifiedClaudeAccountIdentity == identity)
        decoded.rawAuth = try ProviderJSON.data(["claudeAiOauth": ["refreshToken": "fixture-refresh", "accessToken": "fixture-access"], "sharedFixture": false])
        #expect(decoded.verifiedClaudeAccountIdentity == identity)
    }

    @Test("Binding cannot authorize a changed grant, raw image or identity", arguments: ["access", "refresh", "raw", "rawOrganization", "user", "workspace", "provider", "version"])
    func rejectsMutation(_ field: String) throws {
        var changed = try credential().withVerifiedClaudeIdentity(identity)
        switch field {
        case "access": changed.accessToken = "fixture-other-access"
        case "refresh": changed.refreshToken = "fixture-other-refresh"
        case "raw": changed.rawAuth = try ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-other-access", "refreshToken": "fixture-refresh"]])
        case "rawOrganization": changed.rawAuth = try ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-access", "refreshToken": "fixture-refresh"], "organizationUuid": "fixture-other-workspace"])
        case "user": changed.accountMetadata = try ProviderJSON.data(["accountUuid": "fixture-other-user", "organizationUuid": identity.workspaceID])
        case "workspace": changed.accountMetadata = try ProviderJSON.data(["accountUuid": identity.userID, "organizationUuid": "fixture-other-workspace"])
        default:
            var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
            var binding = try #require(encoded["claudeIdentityBinding"] as? [String: Any])
            if field == "version" { binding["version"] = 2 }
            else {
                var boundIdentity = try #require(binding["identity"] as? [String: Any])
                boundIdentity["provider"] = "codex"; binding["identity"] = boundIdentity
            }
            encoded["claudeIdentityBinding"] = binding
            changed = try JSONDecoder().decode(Credential.self, from: JSONSerialization.data(withJSONObject: encoded))
        }
        #expect(changed.verifiedClaudeAccountIdentity == nil)
    }

    @Test("Grant digest distinguishes absent and different refresh tokens")
    func distinctGrantDigests() throws {
        var digests = Set<String>()
        for refresh: String? in [nil, "fixture-refresh-a", "fixture-refresh-b"] {
            var oauth = ["accessToken": "fixture-access"]
            if let refresh { oauth["refreshToken"] = refresh }
            let value = try CredentialParser.claude(rawAuth: ProviderJSON.data(["claudeAiOauth": oauth]), accountMetadata: credential().accountMetadata)
                .withVerifiedClaudeIdentity(identity)
            digests.insert(try #require(value.claudeIdentityBinding?.grantDigest))
        }
        #expect(digests.count == 3)
    }

    @Test("A binding cannot be stamped onto mismatched cached metadata")
    func rejectsMismatchedStamp() throws {
        let other = AccountIdentity(provider: .claude, userID: "fixture-other-user", workspaceID: identity.workspaceID)
        #expect(throws: AgentSwapError.self) { try credential().withVerifiedClaudeIdentity(other) }
    }
}
