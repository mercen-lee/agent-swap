import Foundation
import Testing
@testable import AgentSwapCore

// All values and one-shot faults are fixture-owned and protected by this lock.
private final class PartialRotationKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var failedWrite: String?
    private var mutations = 0
    func read(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            let key = service + "|" + account
            if failedWrite == key { failedWrite = nil; throw AgentSwapError.storage("Fixture vault write failure") }
            values[key] = data; mutations += 1
        }
    }
    func delete(service: String, account: String) {
        lock.withLock { _ = values.removeValue(forKey: service + "|" + account); mutations += 1 }
    }
    func failNextWrite(service: String, account: String) { lock.withLock { failedWrite = service + "|" + account } }
    func mutationCount() -> Int { lock.withLock { mutations } }
    func journalCount() -> Int { lock.withLock { values.keys.filter { $0.hasPrefix(AuthTransaction.service + "|") }.count } }
}
private actor PartialRotationProbe {
    var calls = 0
    func rotate(_ result: Credential) -> Credential { calls += 1; return result }
}
private struct PartialRotationFixture {
    static let user = "00000000-0000-4000-8000-000000000051"
    static let organization = "00000000-0000-4000-8000-000000000052"
    static let otherUser = "00000000-0000-4000-8000-000000000053"
    static let otherOrganization = "00000000-0000-4000-8000-000000000054"
    let home: URL
    let keychain = PartialRotationKeychain()
    let store: ClaudeAuthStore
    let source: Credential
    let configData: Data
    let accountID = UUID()
    var authURL: URL { home.appendingPathComponent(".claude/.credentials.json") }
    var configURL: URL { home.appendingPathComponent(".claude.json") }
    var vault: KeychainSecretStore { KeychainSecretStore(keychain: keychain) }
    init(cache: [String: Any]) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapPartialRotationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = ClaudeAuthStore(home: home, keychain: keychain)
        source = try Self.credential(token: "fixture-source")
        configData = try ProviderJSON.data(["oauthAccount": cache, "fixtureSharedSetting": true])
        try keychain.write(source.rawAuth, service: store.keychainService, account: store.keychainAccount)
        try AtomicAuthFileAccess().write(source.rawAuth, to: home.appendingPathComponent(".claude/.credentials.json"))
        try AtomicAuthFileAccess().write(configData, to: home.appendingPathComponent(".claude.json"))
    }
    static func credential(token: String, user: String = PartialRotationFixture.user,
                           organization: String = PartialRotationFixture.organization) throws -> Credential {
        try CredentialParser.claude(
            rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": token, "refreshToken": token + "-refresh", "expiresAt": 1_900_000_000_000],
                                       "organizationUuid": organization, "mcpOAuth": ["fixture": "preserve"]]),
            accountMetadata: ProviderJSON.data(["accountUuid": user, "organizationUuid": organization]))
    }
    static func partialCache(_ shape: String) -> [String: Any] {
        var cache: [String: Any] = ["accountUuid": user, "organizationUuid": organization]
        switch shape {
        case "organizationAbsent": cache.removeValue(forKey: "organizationUuid")
        case "organizationEmpty": cache["organizationUuid"] = ""
        case "userAbsent": cache.removeValue(forKey: "accountUuid")
        case "userEmpty": cache["accountUuid"] = ""
        case "bothEmpty": cache = ["accountUuid": "", "organizationUuid": ""]
        default: cache = [:]
        }
        return cache
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
    func assertNative(_ credential: Credential, config: Data? = nil) throws {
        #expect(keychain.read(service: store.keychainService, account: store.keychainAccount) == credential.rawAuth)
        #expect(try Data(contentsOf: authURL) == credential.rawAuth)
        #expect(try Data(contentsOf: configURL) == (config ?? configData))
    }
}

@Suite("Claude partial metadata rotation and recovery")
struct ClaudePartialMetadataRotationTests {
    private func verifiedNative(_ fixture: PartialRotationFixture) throws -> ImportedAccount {
        let identity = try ProviderAccountParser.claude(fixture.source).account.identity
        return try ProviderAccountParser.claude(fixture.source.withVerifiedClaudeIdentity(identity))
    }

    @Test("An identification read leaves conflicting cached identity unbound for profile verification")
    func unboundIdentificationRead() async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.otherUser,
                                                       "organizationUuid": PartialRotationFixture.otherOrganization])
        defer { fixture.cleanup() }
        await #expect(throws: AgentSwapError.self) { try await fixture.store.readIfPresent() }
        let candidate = try #require(try await fixture.store.readForIdentificationIfPresent())
        #expect(candidate.rawAuth == fixture.source.rawAuth)
        #expect(candidate.accessToken == fixture.source.accessToken)
        try fixture.assertNative(fixture.source)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A profile-verified native grant refreshes with stale complete cache without rewriting configuration")
    func profileProofPermitsStaleCache() async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.otherUser,
                                                       "organizationUuid": PartialRotationFixture.otherOrganization])
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        let result = try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                                     verifiedNative: verifiedNative(fixture), requiresVerifiedNative: true) { input in
            #expect(input.accountMetadata == fixture.source.accountMetadata)
            return successor
        }
        #expect(result == successor)
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        try fixture.assertNative(successor)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Profile-verified rotation recovery fences the exact unchanged stale configuration", arguments: [false, true])
    func profileProofRecoveryConfigurationFence(_ changeConfiguration: Bool) async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.otherUser,
                                                       "organizationUuid": PartialRotationFixture.otherOrganization])
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        try await fixture.vault.save(fixture.source, accountID: fixture.accountID)
        fixture.keychain.failNextWrite(service: KeychainSecretStore.service, account: fixture.accountID.uuidString)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                             verifiedNative: verifiedNative(fixture), requiresVerifiedNative: true) { _ in successor }
        }
        let config: Data
        if changeConfiguration {
            var changed = try ProviderJSON.object(fixture.configData)
            changed["fixtureSharedSetting"] = false
            config = try ProviderJSON.data(changed)
            try AtomicAuthFileAccess().write(config, to: fixture.configURL)
            let before = fixture.keychain.mutationCount()
            await #expect(throws: AgentSwapError.self) { try await fixture.store.recoverInterruptedSwitch() }
            #expect(fixture.keychain.mutationCount() == before)
            #expect(try await fixture.vault.load(accountID: fixture.accountID) == fixture.source)
            try fixture.assertNative(fixture.source, config: config)
            #expect(fixture.keychain.journalCount() == 1)
        } else {
            try await fixture.store.recoverInterruptedSwitch()
            #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
            try fixture.assertNative(successor)
            #expect(fixture.keychain.journalCount() == 0)
        }
    }

    @Test("A verified absent configuration remains distinct from a legacy rotation marker")
    func profileProofRecoveryWithAbsentConfiguration() async throws {
        let fixture = try PartialRotationFixture(cache: [:])
        defer { fixture.cleanup() }
        try AtomicAuthFileAccess().delete(fixture.configURL)
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        fixture.keychain.failNextWrite(service: KeychainSecretStore.service, account: fixture.accountID.uuidString)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                             verifiedNative: verifiedNative(fixture), requiresVerifiedNative: true) { _ in successor }
        }
        try await fixture.store.recoverInterruptedSwitch()
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        #expect(fixture.keychain.read(service: fixture.store.keychainService, account: fixture.store.keychainAccount) == successor.rawAuth)
        #expect(try AtomicAuthFileAccess().read(fixture.authURL) == successor.rawAuth)
        #expect(try AtomicAuthFileAccess().read(fixture.configURL) == nil)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A restarted verified rotation requires its original authenticated grant binding", arguments: ["missing", "digest", "identity"])
    func invalidStoredProfileProofStopsRecovery(_ change: String) async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.otherUser,
                                                       "organizationUuid": PartialRotationFixture.otherOrganization])
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        fixture.keychain.failNextWrite(service: KeychainSecretStore.service, account: fixture.accountID.uuidString)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                             verifiedNative: verifiedNative(fixture), requiresVerifiedNative: true) { _ in successor }
        }
        let markerKey = "claude|" + storageDigest(fixture.store.configDirectory.path, prefix: 32) + "|rotation"
        var marker = try ProviderJSON.object(#require(fixture.keychain.read(service: AuthTransaction.service, account: markerKey)))
        var config = try #require(marker["verifiedConfiguration"] as? [String: Any])
        var binding = try #require(config["sourceBinding"] as? [String: Any])
        if change == "missing" { config.removeValue(forKey: "sourceBinding") }
        else if change == "digest" { binding["grantDigest"] = "fixture-unverified-digest"; config["sourceBinding"] = binding }
        else {
            var identity = try #require(binding["identity"] as? [String: Any])
            identity["userID"] = PartialRotationFixture.otherUser
            binding["identity"] = identity; config["sourceBinding"] = binding
        }
        marker["verifiedConfiguration"] = config
        try fixture.keychain.write(ProviderJSON.data(marker), service: AuthTransaction.service, account: markerKey)
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) { try await fixture.store.recoverInterruptedSwitch() }
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(fixture.source)
        #expect(fixture.keychain.journalCount() == 1)
    }

    @Test("Absent, changed, or internally inconsistent native profile proof never consumes a refresh grant", arguments: ["absent", "raw", "token", "identity", "unverified"])
    func invalidNativeProofStopsRefresh(_ shape: String) async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.user,
                                                       "organizationUuid": PartialRotationFixture.organization]), probe = PartialRotationProbe()
        defer { fixture.cleanup() }
        var proof = try verifiedNative(fixture)
        if shape == "raw" { proof.credential.rawAuth = try PartialRotationFixture.credential(token: "fixture-third").rawAuth }
        if shape == "token" { proof.credential.accessToken = "fixture-third" }
        if shape == "identity" { proof.account.identity.userID = PartialRotationFixture.otherUser }
        if shape == "unverified" { proof.credential.claudeIdentityBinding = nil }
        let suppliedProof = shape == "absent" ? nil : proof
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                             verifiedNative: suppliedProof, requiresVerifiedNative: true) { input in await probe.rotate(input) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(fixture.source)
    }

    @Test("A verified owner conflict is a local binding error rather than a revoked login")
    func verifiedSameGrantOwnerConflict() async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.user,
                                                       "organizationUuid": PartialRotationFixture.organization]), probe = PartialRotationProbe()
        defer { fixture.cleanup() }
        let otherOwner = try PartialRotationFixture.credential(token: "fixture-source", user: PartialRotationFixture.otherUser)
        let identity = try ProviderAccountParser.claude(otherOwner).account.identity
        let proof = try ProviderAccountParser.claude(otherOwner.withVerifiedClaudeIdentity(identity))
        let before = fixture.keychain.mutationCount()
        do {
            _ = try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                                 verifiedNative: proof, requiresVerifiedNative: true) { input in await probe.rotate(input) }
            Issue.record("A profile-proven owner conflict must stop before consuming the grant")
        } catch let error as AgentSwapError {
            guard case .storage = error else { Issue.record("A verified owner conflict must preserve authentication state"); return }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(fixture.source)
    }

    @Test("A configuration change during verified token refresh preserves its successor without native overwrite")
    func verifiedConfigurationChangesDuringRefresh() async throws {
        let fixture = try PartialRotationFixture(cache: ["accountUuid": PartialRotationFixture.otherUser,
                                                       "organizationUuid": PartialRotationFixture.otherOrganization])
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        var config = try ProviderJSON.object(fixture.configData)
        config["fixtureSharedSetting"] = false
        let changed = try ProviderJSON.data(config)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID,
                                             verifiedNative: verifiedNative(fixture), requiresVerifiedNative: true) { _ in
                try AtomicAuthFileAccess().write(changed, to: fixture.configURL)
                return successor
            }
        }
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        try fixture.assertNative(fixture.source, config: changed)
        #expect(fixture.keychain.journalCount() == 1)
        await #expect(throws: AgentSwapError.self) { try await fixture.store.recoverInterruptedSwitch() }
        try fixture.assertNative(fixture.source, config: changed)
    }

    @Test("Profile-identified active grants rotate native storage and vault despite incomplete cached fields", arguments: ["organizationAbsent", "organizationEmpty", "userAbsent", "userEmpty", "bothAbsent", "bothEmpty"])
    func activePartialCache(_ shape: String) async throws {
        let fixture = try PartialRotationFixture(cache: PartialRotationFixture.partialCache(shape))
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        let directory = fixture.store.configDirectory
        let result = try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { input in
            #expect(input.accountMetadata == fixture.source.accountMetadata)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
            return successor
        }
        #expect(result == successor)
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        try fixture.assertNative(successor)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A known different account refreshes its backup without touching the partial native profile")
    func inactiveOtherAccount() async throws {
        let fixture = try PartialRotationFixture(cache: ["organizationUuid": PartialRotationFixture.organization])
        defer { fixture.cleanup() }
        let inactive = try PartialRotationFixture.credential(token: "fixture-inactive", user: PartialRotationFixture.otherUser, organization: PartialRotationFixture.otherOrganization)
        let successor = try PartialRotationFixture.credential(token: "fixture-inactive-successor", user: PartialRotationFixture.otherUser, organization: PartialRotationFixture.otherOrganization)
        let directory = fixture.store.configDirectory
        _ = try await fixture.store.refresh(inactive, accountID: fixture.accountID) { input in
            #expect(input == inactive)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
            return successor
        }
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        try fixture.assertNative(fixture.source)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("A failed partial-cache vault save retains its durable successor for explicit recovery", arguments: ["organizationAbsent", "userAbsent", "bothEmpty"])
    func partialCacheForwardRecovery(_ shape: String) async throws {
        let fixture = try PartialRotationFixture(cache: PartialRotationFixture.partialCache(shape))
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        try await fixture.vault.save(fixture.source, accountID: fixture.accountID)
        fixture.keychain.failNextWrite(service: KeychainSecretStore.service, account: fixture.accountID.uuidString)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { _ in successor }
        }
        try fixture.assertNative(fixture.source)
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == fixture.source)
        #expect(fixture.keychain.journalCount() == 1)
        try await fixture.store.recoverInterruptedSwitch()
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == successor)
        try fixture.assertNative(successor)
        #expect(fixture.keychain.journalCount() == 0)
    }

    @Test("Malformed cached identity fails before consuming or saving any grant", arguments: ["accountUuid", "organizationUuid"])
    func malformedCacheStopsRefresh(_ key: String) async throws {
        var cached: [String: Any] = ["accountUuid": PartialRotationFixture.user, "organizationUuid": PartialRotationFixture.organization]
        cached[key] = 7
        let fixture = try PartialRotationFixture(cache: cached), probe = PartialRotationProbe()
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { _ in await probe.rotate(successor) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(fixture.source)
    }

    @Test("The same native grant cannot be refreshed as inactive to bypass a conflicting cached identity", arguments: [false, true])
    func conflictingKnownFieldStopsRefresh(_ complete: Bool) async throws {
        var cached: [String: Any] = ["accountUuid": PartialRotationFixture.otherUser]
        if complete { cached["organizationUuid"] = PartialRotationFixture.organization }
        let fixture = try PartialRotationFixture(cache: cached), probe = PartialRotationProbe()
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { _ in await probe.rotate(successor) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(fixture.source)
    }

    @Test("An ambiguous different native grant with incomplete identity is preserved without refreshing a stale backup")
    func partialIdentityWithDifferentGrant() async throws {
        let fixture = try PartialRotationFixture(cache: ["organizationUuid": PartialRotationFixture.organization]), probe = PartialRotationProbe()
        defer { fixture.cleanup() }
        let external = try PartialRotationFixture.credential(token: "fixture-external")
        try fixture.keychain.write(external.rawAuth, service: fixture.store.keychainService, account: fixture.store.keychainAccount)
        try AtomicAuthFileAccess().write(external.rawAuth, to: fixture.authURL)
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { _ in await probe.rotate(external) }
        }
        #expect(await probe.calls == 0)
        #expect(fixture.keychain.mutationCount() == before)
        try fixture.assertNative(external)
    }

    @Test("Recovery preserves the durable successor when cached identity becomes conflicting or malformed", arguments: ["account", "organization", "type"])
    func changedCacheStopsRecovery(_ change: String) async throws {
        let fixture = try PartialRotationFixture(cache: ["organizationUuid": PartialRotationFixture.organization])
        defer { fixture.cleanup() }
        let successor = try PartialRotationFixture.credential(token: "fixture-successor")
        try await fixture.vault.save(fixture.source, accountID: fixture.accountID)
        fixture.keychain.failNextWrite(service: KeychainSecretStore.service, account: fixture.accountID.uuidString)
        await #expect(throws: AgentSwapError.self) {
            try await fixture.store.refresh(fixture.source, accountID: fixture.accountID) { _ in successor }
        }
        var cached: [String: Any] = ["organizationUuid": PartialRotationFixture.organization]
        if change == "account" { cached["accountUuid"] = PartialRotationFixture.otherUser }
        else if change == "organization" { cached["organizationUuid"] = PartialRotationFixture.otherOrganization }
        else { cached["accountUuid"] = 7 }
        let modified = try ProviderJSON.data(["oauthAccount": cached, "fixtureSharedSetting": true])
        try AtomicAuthFileAccess().write(modified, to: fixture.configURL)
        let before = fixture.keychain.mutationCount()
        await #expect(throws: AgentSwapError.self) { try await fixture.store.recoverInterruptedSwitch() }
        #expect(fixture.keychain.mutationCount() == before)
        #expect(try await fixture.vault.load(accountID: fixture.accountID) == fixture.source)
        try fixture.assertNative(fixture.source, config: modified)
        #expect(fixture.keychain.journalCount() == 1)
    }
}
