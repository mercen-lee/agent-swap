import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Persisted request limit identities")
struct RateLimitPolicyTests {
    @Test("Profile keys use a stable SHA-256 digest of the exact access token")
    func profileKeysUseStableTokenFingerprints() {
        let key = ProviderRequestKey.credential(provider: .claude, kind: .profile, token: "abc")
        #expect(key.subject == "credential:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(key == .credential(provider: .claude, kind: .profile, token: "abc"))
        #expect(key != .credential(provider: .claude, kind: .profile, token: "abcd"))
    }

    @Test("Account keys distinguish the provider, operation and selected account")
    func accountKeysKeepRequestContextsSeparate() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let key = ProviderRequestKey.account(provider: .claude, kind: .usage, accountID: first)
        #expect(key.subject == "account:00000000-0000-0000-0000-000000000001")
        #expect(key == .account(provider: .claude, kind: .usage, accountID: first))
        #expect(key != .account(provider: .claude, kind: .usage, accountID: second))
        #expect(key != .account(provider: .codex, kind: .usage, accountID: first))
        #expect(key != .account(provider: .claude, kind: .tokenRefresh, accountID: first))
    }

    @Test("State and error messages never contain the raw profile token", arguments: [ProviderRequestRateLimit.Source.serverHeader, .fallback])
    func tokenIsAbsentFromPersistedStateAndUserErrors(source: ProviderRequestRateLimit.Source) throws {
        let token = "fixture-private-profile-token-never-persist"
        let key = ProviderRequestKey.credential(provider: .claude, kind: .profile, token: token)
        let record = ProviderRequestRateLimit(key: key, retryAfter: Date(timeIntervalSinceReferenceDate: 900_000_000), source: source)
        let accountID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        var state = PersistedState()
        state.requestRateLimits = [record]
        state.usage[accountID] = .init(error: AgentSwapError.requestRateLimited(record).localizedDescription,
                                    retryAfter: record.retryAfter, retryReason: .serverRateLimit, requestRateLimit: record)
        let data = try JSONEncoder().encode(state)
        let encoded = String(decoding: data, as: UTF8.self)
        let message = AgentSwapError.requestRateLimited(record).localizedDescription
        #expect(!encoded.contains(token))
        #expect(!message.contains(token))
        #expect(!message.contains(key.subject))
        #expect(encoded.contains(key.subject))
        #expect(message.contains(source == .serverHeader ? "서버가 지정한" : "앱이 설정한"))
        #expect(try JSONDecoder().decode(PersistedState.self, from: data) == state)
    }

    @Test("Malformed or mismatched request key fields are rejected", arguments: [
        #"{"provider":"other","kind":"profile","subject":"credential:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#,
        #"{"provider":"claude","kind":"other","subject":"credential:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#,
        #"{"provider":"claude","kind":"profile","subject":"account:00000000-0000-0000-0000-000000000001"}"#,
        #"{"provider":"claude","kind":"usage","subject":"credential:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#,
        #"{"provider":"claude","kind":"tokenRefresh","subject":"credential:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#,
        #"{"provider":"claude","kind":"profile","subject":"credential:abcd"}"#,
        #"{"provider":"claude","kind":"profile","subject":"credential:ga7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}"#,
        #"{"provider":"claude","kind":"profile","subject":"credential:BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"}"#,
        #"{"provider":"claude","kind":"usage","subject":"account:not-a-uuid"}"#,
        #"{"provider":"claude","kind":"usage","subject":"account:AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}"#,
        #"{"provider":"claude","kind":"profile","subject":"fixture-unhashed-bearer"}"#
    ])
    func decodingRejectsInvalidRequestKeys(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderRequestKey.self, from: Data(json.utf8))
        }
    }

    @Test("Both providers preserve valid account operation keys through persistence", arguments: [Provider.claude, .codex], [ProviderRequestKind.usage, .tokenRefresh])
    func accountRequestKeysRoundTrip(provider: Provider, kind: ProviderRequestKind) throws {
        let accountID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let key = ProviderRequestKey.account(provider: provider, kind: kind, accountID: accountID)
        #expect(try JSONDecoder().decode(ProviderRequestKey.self, from: JSONEncoder().encode(key)) == key)
    }

    @Test("Legacy state and usage cache without scoped fields retain their global deadline")
    func legacyStateWithoutScopedFieldsStillDecodes() throws {
        let account = AccountRecord(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                                    identity: .init(provider: .claude, userID: "fixture-owner", workspaceID: "fixture-workspace"))
        let retry = Date(timeIntervalSinceReferenceDate: 900_000_000)
        let cache = UsageCache(snapshot: .init(fetchedAt: retry.addingTimeInterval(-600),
                                              windows: [.init(id: "common", title: "fixture", usedPercent: 20)]),
                               attemptedAt: retry.addingTimeInterval(-300), error: "fixture-limit",
                               retryAfter: retry, retryReason: .serverRateLimit)
        var legacy = PersistedState()
        legacy.accounts = [account]
        legacy.activeAccounts[.claude] = account.id
        legacy.usage[account.id] = cache
        legacy.providerRetryAfter = [.claude: retry]
        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["requestRateLimits"] == nil)
        let encodedCache = try JSONEncoder().encode(cache)
        let cacheObject = try #require(JSONSerialization.jsonObject(with: encodedCache) as? [String: Any])
        #expect(cacheObject["requestRateLimit"] == nil)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: encoded)
        #expect(decoded == legacy)
        #expect(decoded.requestRateLimits == nil)
        #expect(decoded.usage[account.id]?.requestRateLimit == nil)
        #expect(decoded.providerRetryAfter?[.claude] == retry)
        #expect(decoded.usage[account.id]?.snapshot == cache.snapshot)
        #expect(decoded.usage[account.id]?.retryAfter == retry)
    }
}
