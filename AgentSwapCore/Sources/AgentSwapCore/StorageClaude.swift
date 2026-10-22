import Foundation
import CryptoKit

private struct ClaudeRotationConfigurationSnapshot: Codable, Sendable {
    let data: Data?
    let sourceBinding: ClaudeCredentialIdentityBinding
}

private struct PendingClaudeRotation: Codable, Sendable {
    var credential: Credential
    var expectedRaw: Data?
    /// The exact canonical provider-store image, including authoritative shared integration values.
    var nativeAfter: Data
    var accountID: UUID
    /// Only authenticated profile proofs may fence a stale cache by its exact bytes.
    /// Missing means a legacy marker, which still requires the cached-identity checks.
    var verifiedConfiguration: ClaudeRotationConfigurationSnapshot? = nil
}

/// The archive is deliberately content-addressed by the original marker.  It never becomes a
/// rollback instruction: it records the live third generation which the explicit recovery kept.
private struct PreservedClaudeRotationArchive: Codable, Sendable {
    let version: Int
    let originalRotationMarker: Data
    let originalTransactionJournal: Data?
    let vaultBefore: Data?
    let currentVaultData: Data
    let nativeKeychainDigest: String?
    let nativeFileDigest: String?
    let configDigest: String?

    init(originalRotationMarker: Data, originalTransactionJournal: Data?, vaultBefore: Data?, currentVaultData: Data,
         nativeKeychainDigest: String?, nativeFileDigest: String?, configDigest: String?) {
        version = 1
        self.originalRotationMarker = originalRotationMarker
        self.originalTransactionJournal = originalTransactionJournal
        self.vaultBefore = vaultBefore
        self.currentVaultData = currentVaultData
        self.nativeKeychainDigest = nativeKeychainDigest
        self.nativeFileDigest = nativeFileDigest
        self.configDigest = configDigest
    }
}

private struct PreservedClaudeRecoveryIndex: Codable, Sendable {
    let version: Int
    let markerHashes: [String]
    init(markerHashes: [String]) {
        version = 1
        self.markerHashes = markerHashes
    }
}

/// A validated response remains owned by the actor until its first exact durable copy exists.
/// Encoded bytes are retained too: a failed readback must retry the same marker, not a newly
/// encoded representation whose object-key order may differ.
private struct RetainedClaudeCredential: Sendable {
    let predecessorAuth: Data
    let credential: Credential
    let vaultData: Data
    let rotationData: Data?
}

public actor ClaudeAuthStore {
    public nonisolated let configDirectory: URL
    public nonisolated let configURL: URL
    public nonisolated let keychainService: String
    public nonisolated let keychainAccount: String
    private let isolated: Bool
    private let keychain: any KeychainAccess
    private let files: any AuthFileAccess
    private let lockTimeout: TimeInterval
    private var refreshing = false
    private var retainedCredentials: [UUID: RetainedClaudeCredential] = [:]
    private var persistedInactiveCredentials: [UUID: RetainedClaudeCredential] = [:]
    private var persistedGenerations: [UUID: PersistedCredentialGeneration] = [:]
    private var authURL: URL { configDirectory.appendingPathComponent(".credentials.json") }
    private var transaction: AuthTransaction {
        .init(identifier: "claude|" + storageDigest(configDirectory.path, prefix: 32), keychain: keychain, files: files)
    }
    private var authLocation: AuthMutation.Location { .keychain(service: keychainService, account: keychainAccount) }
    private var allowedLocations: Set<AuthMutation.Location> {
        [authLocation, .file(authURL.path), .file(configURL.path)]
    }
    private var nativeAuthLocations: Set<AuthMutation.Location> {
        [authLocation, .file(authURL.path)]
    }
    private var rotationKey: String { transaction.identifier + "|rotation" }
    private func preservedRotationIndexKey(accountID: UUID) -> String {
        transaction.identifier + "|preserved-index|" + accountID.uuidString
    }
    private func preservedRotationHash(_ marker: Data) -> String { Self.authDigest(marker) }
    private func preservedRotationKey(_ marker: Data) -> String {
        rotationKey + "|preserved|" + preservedRotationHash(marker)
    }
    private func sortedArchiveData(_ archive: PreservedClaudeRotationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }
    private func sortedCredentialData(_ credential: Credential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(credential)
    }
    private func sortedIndexData(_ index: PreservedClaudeRecoveryIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(index)
    }
    private func pendingRecovery() throws -> Bool {
        try retainedCredentials.values.contains { $0.rotationData != nil }
            || transaction.hasPendingRecovery() || keychain.read(service: AuthTransaction.service, account: rotationKey) != nil
    }
    public func hasPendingCredentialPersistence() -> Bool { !retainedCredentials.isEmpty }
    public func takePersistedCredentialGenerations() -> [PersistedCredentialGeneration] {
        let receipts = persistedGenerations.values.sorted { $0.accountID.uuidString < $1.accountID.uuidString }
        persistedGenerations.removeAll()
        return receipts
    }
    /// Saves the successor without applying native authentication. This is also the bounded
    /// shutdown path: a durable rotation marker is enough to resume explicit recovery later.
    public func flushPendingCredentialPersistence() throws {
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 진행 중입니다.") }
        try persistRetainedCredentials()
    }
    /// A caller may discard an undurable response only after saving a fresh login or deleting
    /// its account. Durable markers remain owned by the existing explicit recovery procedure.
    public func discardPendingCredentialPersistence(accountID: UUID) {
        retainedCredentials.removeValue(forKey: accountID)
        persistedInactiveCredentials.removeValue(forKey: accountID)
        persistedGenerations.removeValue(forKey: accountID)
    }
    private func persistRetainedCredentials() throws {
        for accountID in retainedCredentials.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let retained = retainedCredentials[accountID] else { continue }
            do {
                if let marker = retained.rotationData {
                    let existing = try keychain.read(service: AuthTransaction.service, account: rotationKey)
                    guard existing == nil || existing == marker else {
                        throw AgentSwapError.storage("다른 Claude 토큰 갱신 복원 자료가 있어 새 인증을 메모리에 보존했습니다.")
                    }
                    if existing == nil { try keychain.write(marker, service: AuthTransaction.service, account: rotationKey) }
                    guard try keychain.read(service: AuthTransaction.service, account: rotationKey) == marker else {
                        throw AgentSwapError.storage("Claude 토큰 갱신 복원 자료의 저장 결과를 확인하지 못했습니다.")
                    }
                } else {
                    try keychain.write(retained.vaultData, service: KeychainSecretStore.service, account: accountID.uuidString)
                    guard try keychain.read(service: KeychainSecretStore.service, account: accountID.uuidString) == retained.vaultData else {
                        throw AgentSwapError.storage("Claude 갱신 인증의 저장 결과를 확인하지 못했습니다.")
                    }
                    persistedInactiveCredentials[accountID] = retained
                    persistedGenerations[accountID] = .init(accountID: accountID,
                        predecessorDigest: Self.authDigest(retained.predecessorAuth),
                        successorDigest: Self.authDigest(retained.credential.rawAuth))
                }
                retainedCredentials.removeValue(forKey: accountID)
            } catch {
                throw AgentSwapError.storage("갱신된 Claude 인증을 메모리에 보존했습니다. Keychain 접근을 허용한 뒤 다시 시도해 주세요. 저장을 완료할 때까지 종료를 보류합니다. \(error.localizedDescription)")
            }
        }
    }
    private nonisolated static func authDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func optionalDigest(_ data: Data?) -> String? {
        data.map(authDigest)
    }
    private static let sharedKeys: Set<String> = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]
    private static let knownKeys = sharedKeys.union(["claudeAiOauth", "trustedDeviceToken", "organizationUuid"])

    /// `home` is the user HOME. An explicit `configDirectory` is the exact CLAUDE_CONFIG_DIR path exported to the login CLI.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                configDirectory: URL? = nil, keychain: any KeychainAccess = ClaudeKeychainAccess(),
                files: any AuthFileAccess = AtomicAuthFileAccess(), lockTimeout: TimeInterval = 9,
                environmentUser: String? = ProcessInfo.processInfo.environment["USER"], systemUser: String? = NSUserName()) {
        let directory = configDirectory ?? home.appendingPathComponent(".claude", isDirectory: true)
        self.configDirectory = directory
        configURL = configDirectory == nil ? home.appendingPathComponent(".claude.json") : directory.appendingPathComponent(".claude.json")
        isolated = configDirectory != nil
        keychainService = configDirectory == nil ? "Claude Code-credentials" : Self.isolatedKeychainService(configDirectory: directory.path)
        keychainAccount = Self.keychainAccountName(environmentUser: environmentUser, systemUser: systemUser)
        self.keychain = keychain; self.files = files; self.lockTimeout = lockTimeout
    }
    public nonisolated static func isolatedKeychainService(configDirectory: String) -> String {
        "Claude Code-credentials-" + storageDigest(configDirectory.precomposedStringWithCanonicalMapping, prefix: 8)
    }
    /// Mirrors Claude Code 2.1.296: USER || OS username, followed by its ASCII username allowlist.
    /// Invalid selected usernames use the literal fallback, including macOS account names containing @.
    public nonisolated static func keychainAccountName(environmentUser: String?, systemUser: String?) -> String {
        let candidate = environmentUser.flatMap { $0.isEmpty ? nil : $0 } ?? systemUser ?? ""
        let valid = !candidate.isEmpty && candidate.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
                || value == 46 || value == 95 || value == 45
        }
        return valid ? candidate : "claude-code-user"
    }
    private func locks() throws -> [ProviderDirectoryLock] {
        [try ProviderDirectoryLock(url: configDirectory.appendingPathComponent(".oauth_refresh.lock"), staleAfter: 60, timeout: lockTimeout),
         try ProviderDirectoryLock(url: URL(fileURLWithPath: configDirectory.path + ".lock"), staleAfter: 60, timeout: lockTimeout),
         try ProviderDirectoryLock(url: URL(fileURLWithPath: configURL.path + ".lock"), staleAfter: 10, timeout: lockTimeout)]
    }
    private func validate(_ data: Data) throws -> [String: Any] {
        let object = try authObject(data, name: "Claude")
        guard Set(object.keys).isSubset(of: Self.knownKeys), let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw AgentSwapError.unsupported("알 수 없는 Claude 인증 형식을 발견해 쓰기를 중단했습니다.")
        }
        if let organization = object["organizationUuid"] {
            guard let value = organization as? String, !value.isEmpty else {
                throw AgentSwapError.unsupported("Claude 워크스페이스 인증 필드의 형식을 지원하지 않습니다.")
            }
        }
        _ = try CredentialParser.claude(rawAuth: data, accountMetadata: nil)
        return object
    }
    private func config() throws -> [String: Any] {
        try config(try files.read(configURL))
    }
    private func config(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let object = try authObject(data, name: "Claude 설정")
        if let oauth = object["oauthAccount"], !(oauth is [String: Any]) {
            throw AgentSwapError.unsupported("Claude oauthAccount 형식을 지원하지 않습니다.")
        }
        guard object["primaryApiKey"] == nil || object["primaryApiKey"] is NSNull else {
            throw AgentSwapError.unsupported("API 키를 사용하는 Claude 프로필은 v1에서 전환할 수 없습니다.")
        }
        return object
    }
    private func currentRawAuth() throws -> Data? {
        // Keychain errors must remain errors: the fallback file may contain a consumed refresh token.
        try keychain.read(service: keychainService, account: keychainAccount) ?? files.read(authURL)
    }
    public func read() throws -> Credential {
        guard let credential = try readIfPresent() else { throw AgentSwapError.authentication("Claude Code에 로그인한 계정이 없습니다.") }
        return credential
    }
    /// Nil means a genuinely absent native credential; malformed data and read failures still throw.
    public func readIfPresent() throws -> Credential? {
        guard !(try pendingRecovery()) else {
            throw AgentSwapError.storage("중단된 Claude 전환의 복원이 필요합니다.")
        }
        let config = try config()
        guard let raw = try currentRawAuth() else { return nil }
        let auth = try validate(raw), cachedAccount = config["oauthAccount"] as? [String: Any]
        try validateSourceOrganization(auth, cachedAccount: cachedAccount)
        let metadata = try cachedAccount.map(authData)
        return try CredentialParser.claude(rawAuth: raw, accountMetadata: metadata)
    }
    /// This read supplies an unbound grant for authenticated profile identification.
    /// The cache remains format-checked, but its user and workspace are not identity proof.
    func readForIdentificationIfPresent() throws -> Credential? {
        guard !(try pendingRecovery()) else {
            throw AgentSwapError.storage("중단된 Claude 전환의 복원이 필요합니다.")
        }
        let config = try config()
        guard let raw = try currentRawAuth() else { return nil }
        _ = try validate(raw)
        let cached = config["oauthAccount"] as? [String: Any]
        for key in ["accountUuid", "organizationUuid"] {
            if let value = cached?[key], !(value is String) {
                throw AgentSwapError.unsupported("Claude 현재 계정의 식별 정보 형식을 확인하지 못했습니다.")
            }
        }
        return try CredentialParser.claude(rawAuth: raw, accountMetadata: cached.map(authData))
    }
    private func validateSourceOrganization(_ auth: [String: Any], cachedAccount: [String: Any]?) throws {
        // Native login and its metadata cache are separate writes. Do not label a new workspace's
        // grant as the old cached account when an import lands between those writes.
        for key in ["accountUuid", "organizationUuid"] {
            if let value = cachedAccount?[key], !(value is String) {
                throw AgentSwapError.unsupported("Claude 현재 계정의 식별 정보 형식을 확인하지 못했습니다.")
            }
        }
        guard let organization = auth["organizationUuid"] as? String,
              let cached = cachedAccount?["organizationUuid"] as? String, !cached.isEmpty else { return }
        guard cached == organization else {
            throw AgentSwapError.authentication("Claude 인증과 현재 계정의 워크스페이스가 일치하지 않습니다. CLI 로그인을 확인한 뒤 다시 가져오세요.")
        }
    }
    public func compatibility() -> CompatibilityStatus {
        do {
            if try pendingRecovery() { return .readOnly("중단된 Claude 전환 또는 토큰 갱신의 복원이 필요합니다.") }
            let config = try config()
            if let raw = try currentRawAuth() {
                let auth = try validate(raw)
                try validateSourceOrganization(auth, cachedAccount: config["oauthAccount"] as? [String: Any])
                if let preflight = keychain as? any KeychainWritePreflighting {
                    // A switch must be able to restore this exact before-image as well as
                    // encode the shared integration values for Claude's CLI reader.
                    try preflight.validateWrite(raw, service: keychainService, account: keychainAccount)
                    try preflight.validateWrite(claudeCLIAuthData(auth), service: keychainService, account: keychainAccount)
                }
            }
            if !isolated, try keychain.read(service: "Claude Code", account: keychainAccount) != nil {
                return .readOnly("Claude의 API 키 인증이 감지되었습니다. 기본 구독 로그인만 지원합니다.")
            }
            return .supported("Claude Code 기본 구독 로그인과 호환됩니다.")
        } catch { return .readOnly(error.localizedDescription) }
    }
    public func recoverInterruptedSwitch() throws {
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 진행 중입니다.") }
        try persistRetainedCredentials()
        let locks = try locks()
        defer { withExtendedLifetime(locks) {} }
        try locks.forEach { try $0.verify() }
        let pendingRotation: PendingClaudeRotation?
        if let data = try keychain.read(service: AuthTransaction.service, account: rotationKey) {
            if try keychain.read(service: AuthTransaction.service, account: preservedRotationKey(data)) != nil {
                throw AgentSwapError.storage("현재 로그인을 유지하는 Claude 복구를 다시 시도하세요.")
            }
            let pending: PendingClaudeRotation
            do { pending = try JSONDecoder().decode(PendingClaudeRotation.self, from: data) }
            catch { throw AgentSwapError.storage("토큰 갱신 복원 자료를 읽지 못했습니다.") }
            if try hasPreservedIntent(marker: data, accountID: pending.accountID) {
                throw AgentSwapError.storage("현재 로그인을 유지하는 Claude 복구를 다시 시도하세요.")
            }
            // Refuse malformed or conflicting metadata before even a native transaction rollback.
            _ = try validateRotationSource(pending)
            pendingRotation = pending
        } else { pendingRotation = nil }
        try transaction.recover(allowedLocations: allowedLocations) {
            if let snapshot = pendingRotation?.verifiedConfiguration { try verifyConfiguration(snapshot) }
        }
        if let pending = pendingRotation {
            let rotated = pending.credential
            let live = try validateRotationSource(pending)
            try keychain.write(JSONEncoder().encode(rotated), service: KeychainSecretStore.service, account: pending.accountID.uuidString)
            try persistNativeRotation(rotated, expectedRaw: live, nativeAfter: pending.nativeAfter, locks: locks,
                                      verifiedConfiguration: pending.verifiedConfiguration)
            try keychain.delete(service: AuthTransaction.service, account: rotationKey)
        }
    }
    /// Explicitly resolves the one supported third-generation case: Claude has already rotated
    /// the native login beyond both the interrupted predecessor and successor.  It records that
    /// live login and only removes the marker after the verified current credential is durable.
    func recoverKeepingCurrentLogin(account: AccountRecord,
                                    verify: @Sendable (Credential) async throws -> ImportedAccount) async throws -> ImportedAccount {
        guard KeychainInteraction.mode == .interactive else {
            throw AgentSwapError.storage("현재 로그인을 유지하는 Claude 복구는 사용자 작업에서만 실행할 수 있습니다.")
        }
        guard account.provider == .claude else { throw AgentSwapError.authentication("Claude 계정만 복구할 수 있습니다.") }
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 진행 중입니다.") }
        try persistRetainedCredentials()
        guard retainedCredentials.isEmpty else { throw AgentSwapError.storage("보존한 Claude 인증을 먼저 저장해야 합니다.") }
        refreshing = true
        defer { refreshing = false }

        var locks = try locks()
        defer { withExtendedLifetime(locks) {} }
        try locks.forEach { try $0.verify() }
        _ = try transaction.discardCommittedRecoveryIfPresent(allowedLocations: allowedLocations)
        guard let marker = try keychain.read(service: AuthTransaction.service, account: rotationKey) else {
            throw AgentSwapError.storage("보존할 Claude 토큰 갱신 복원 자료가 없습니다.")
        }
        let pending: PendingClaudeRotation
        do { pending = try JSONDecoder().decode(PendingClaudeRotation.self, from: marker) }
        catch { throw AgentSwapError.storage("토큰 갱신 복원 자료를 읽지 못했습니다.") }
        guard pending.accountID == account.id else {
            throw AgentSwapError.storage("다른 Claude 계정의 토큰 갱신 복원 자료가 있어 복구를 중단했습니다.")
        }
        guard pending.expectedRaw != nil,
              try plannedNativeRotation(pending.credential, sourceRaw: pending.expectedRaw) == pending.nativeAfter else {
            throw AgentSwapError.unsupported("토큰 갱신 복원 자료의 네이티브 인증 이미지가 일치하지 않습니다.")
        }
        guard try ProviderAccountParser.claude(pending.credential).account.identity == account.identity else {
            throw AgentSwapError.authentication("토큰 갱신 복원 자료의 Claude 계정이 선택한 계정과 다릅니다.")
        }
        let originalJournal = try transaction.uncommittedNativeJournalSnapshot(
            allowedLocations: nativeAuthLocations,
            expectedMutations: nativeRotationJournalMutations(expectedRaw: try requiredExpectedRaw(pending), nativeAfter: pending.nativeAfter))

        let beforeKeychain = try keychain.read(service: keychainService, account: keychainAccount)
        let beforeFile = try files.read(authURL)
        guard beforeKeychain == nil || beforeFile == nil || beforeKeychain == beforeFile else {
            throw AgentSwapError.storage("Claude Keychain과 파일 인증이 달라 현재 로그인을 보존할 수 없습니다.")
        }
        guard let liveRaw = beforeKeychain ?? beforeFile else {
            throw AgentSwapError.storage("현재 Claude 로그인이 없어 복구를 중단했습니다.")
        }
        guard liveRaw != pending.expectedRaw, liveRaw != pending.nativeAfter else {
            throw AgentSwapError.storage("현재 Claude 인증은 중단된 갱신 세대입니다. 기존 토큰 갱신 복구를 사용하세요.")
        }
        let configSnapshot = try files.read(configURL)
        let liveConfig = try config()
        let liveAuth = try validate(liveRaw)
        let cached = liveConfig["oauthAccount"] as? [String: Any]
        try validateSourceOrganization(liveAuth, cachedAccount: cached)
        let metadata = try cached.map(authData)
        let identity = try cachedIdentityStatus(expectedMetadata: pending.credential.accountMetadata, cachedMetadata: metadata)
        guard identity.complete, identity.matches else {
            throw AgentSwapError.storage("현재 Claude 로그인 계정 식별 정보를 완전히 확인하지 못했습니다.")
        }
        let liveCredential = try CredentialParser.claude(rawAuth: liveRaw, accountMetadata: metadata)
        guard try ProviderAccountParser.claude(liveCredential).account.identity == account.identity else {
            throw AgentSwapError.authentication("현재 Claude 로그인 계정이 선택한 계정과 다릅니다.")
        }
        let vaultBefore = try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString)
        try validateRecoveryVault(vaultBefore, pending: pending, liveRaw: liveRaw, account: account)

        let preservedKey = preservedRotationKey(marker)
        let markerHash = preservedRotationHash(marker)
        let indexKey = preservedRotationIndexKey(accountID: account.id)
        let existingArchive = try keychain.read(service: AuthTransaction.service, account: preservedKey)
        let archive: PreservedClaudeRotationArchive
        let activeJournal: Data?
        if let existingArchive {
            do { archive = try JSONDecoder().decode(PreservedClaudeRotationArchive.self, from: existingArchive) }
            catch { throw AgentSwapError.storage("현재 로그인 보존 복구 기록을 읽지 못했습니다.") }
            guard archive.version == 1, archive.originalRotationMarker == marker,
                  archive.nativeKeychainDigest == Self.optionalDigest(beforeKeychain),
                  archive.nativeFileDigest == Self.optionalDigest(beforeFile),
                  archive.configDigest == Self.optionalDigest(configSnapshot) else {
                throw AgentSwapError.storage("현재 Claude 로그인 또는 보존 복구 기록이 외부에서 변경되었습니다.")
            }
            guard vaultBefore == archive.vaultBefore || vaultBefore == archive.currentVaultData else {
                throw AgentSwapError.storage("Claude 계정 보관함 인증이 외부에서 변경되어 복구를 중단했습니다.")
            }
            _ = try recoveryVaultCredential(archive.currentVaultData, account: account)
            if let archivedJournal = archive.originalTransactionJournal {
                try transaction.validateUncommittedNativeJournal(archivedJournal, allowedLocations: nativeAuthLocations,
                                                                 expectedMutations: nativeRotationJournalMutations(expectedRaw: try requiredExpectedRaw(pending), nativeAfter: pending.nativeAfter))
                guard originalJournal == archivedJournal || originalJournal == nil else {
                    throw AgentSwapError.storage("Claude 인증 복원 기록이 보존 복구 이후 변경되었습니다.")
                }
            } else {
                guard originalJournal == nil else {
                    throw AgentSwapError.storage("새 Claude 인증 복원 기록이 있어 현재 로그인을 보존할 수 없습니다.")
                }
            }
            activeJournal = originalJournal
        } else {
            // This payload is only written after the profile proof below.  Its stable marker hash
            // permits a failed marker deletion to resume without creating another archive slot.
            archive = PreservedClaudeRotationArchive(originalRotationMarker: marker, originalTransactionJournal: originalJournal, vaultBefore: vaultBefore,
                                                      currentVaultData: Data(), nativeKeychainDigest: Self.optionalDigest(beforeKeychain),
                                                      nativeFileDigest: Self.optionalDigest(beforeFile), configDigest: Self.optionalDigest(configSnapshot))
            activeJournal = originalJournal
        }

        // Do not hold Claude's provider locks while the profile request is in flight. The exact
        // snapshots below fence every source again after reacquiring fresh locks.
        locks.removeAll()
        try Task.checkCancellation()
        let verified = try await verify(liveCredential)
        guard verified.account.identity == account.identity,
              try ProviderAccountParser.claude(verified.credential).account.identity == account.identity,
              verified.credential.rawAuth == liveCredential.rawAuth,
              verified.credential.accessToken == liveCredential.accessToken,
              verified.credential.refreshToken == liveCredential.refreshToken else {
            throw AgentSwapError.authentication("현재 Claude 로그인 확인 결과가 인증 세대와 일치하지 않습니다.")
        }
        let currentVaultData: Data
        let committedArchive: PreservedClaudeRotationArchive
        if existingArchive != nil {
            let archived = try recoveryVaultCredential(archive.currentVaultData, account: account)
            guard archived.rawAuth == verified.credential.rawAuth,
                  archived.accessToken == verified.credential.accessToken,
                  archived.refreshToken == verified.credential.refreshToken else {
                throw AgentSwapError.storage("현재 Claude 로그인 확인 결과가 보존 복구 기록과 다릅니다.")
            }
            currentVaultData = archive.currentVaultData
            committedArchive = archive
        } else {
            currentVaultData = try sortedCredentialData(verified.credential)
            committedArchive = PreservedClaudeRotationArchive(originalRotationMarker: marker, originalTransactionJournal: activeJournal, vaultBefore: vaultBefore,
                                                               currentVaultData: currentVaultData,
                                                               nativeKeychainDigest: Self.optionalDigest(beforeKeychain),
                                                               nativeFileDigest: Self.optionalDigest(beforeFile),
                                                               configDigest: Self.optionalDigest(configSnapshot))
        }
        try Task.checkCancellation()
        locks = try self.locks()
        try locks.forEach { try $0.verify() }
        guard try transaction.recoveryJournalData() == activeJournal,
              try keychain.read(service: AuthTransaction.service, account: rotationKey) == marker,
              try keychain.read(service: keychainService, account: keychainAccount) == beforeKeychain,
              try files.read(authURL) == beforeFile, try files.read(configURL) == configSnapshot,
              try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString) == vaultBefore else {
            throw AgentSwapError.storage("현재 Claude 로그인 또는 복구 자료가 확인 중 변경되었습니다.")
        }

        // From here onward this is a synchronous, durable commit. Do not observe cancellation:
        // the marker remains until both the archive and current vault generation are confirmed.
        let archiveData = try sortedArchiveData(committedArchive)
        try registerPreservedArchive(markerHash, indexKey: indexKey)
        if let existingArchive {
            guard existingArchive == archiveData else {
                throw AgentSwapError.storage("현재 로그인 보존 복구 기록이 예상과 다릅니다.")
            }
        } else {
            try keychain.write(archiveData, service: AuthTransaction.service, account: preservedKey)
        }
        guard try keychain.read(service: AuthTransaction.service, account: preservedKey) == archiveData else {
            throw AgentSwapError.storage("현재 로그인 보존 복구 기록의 저장 결과를 확인하지 못했습니다.")
        }
        try locks.forEach { try $0.verify() }
        guard try keychain.read(service: AuthTransaction.service, account: rotationKey) == marker,
              try keychain.read(service: keychainService, account: keychainAccount) == beforeKeychain,
              try files.read(authURL) == beforeFile, try files.read(configURL) == configSnapshot,
              try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString) == vaultBefore,
              try transaction.recoveryJournalData() == activeJournal else {
            throw AgentSwapError.storage("현재 Claude 로그인 또는 복구 자료가 저장 중 변경되었습니다.")
        }
        try keychain.write(currentVaultData, service: KeychainSecretStore.service, account: account.id.uuidString)
        guard try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString) == currentVaultData else {
            throw AgentSwapError.storage("현재 Claude 인증 보관함 저장 결과를 확인하지 못했습니다.")
        }
        try locks.forEach { try $0.verify() }
        guard try transaction.recoveryJournalData() == activeJournal,
              try keychain.read(service: AuthTransaction.service, account: rotationKey) == marker,
              try keychain.read(service: AuthTransaction.service, account: preservedKey) == archiveData,
              try keychain.read(service: keychainService, account: keychainAccount) == beforeKeychain,
              try files.read(authURL) == beforeFile, try files.read(configURL) == configSnapshot,
              try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString) == currentVaultData else {
            throw AgentSwapError.storage("현재 Claude 로그인 또는 복구 자료가 삭제 직전 변경되었습니다.")
        }
        if let activeJournal {
            try transaction.deleteUncommittedNativeJournal(activeJournal, allowedLocations: nativeAuthLocations,
                                                           expectedMutations: nativeRotationJournalMutations(expectedRaw: try requiredExpectedRaw(pending), nativeAfter: pending.nativeAfter))
        }
        guard try transaction.recoveryJournalData() == nil else {
            throw AgentSwapError.storage("Claude 인증 복원 기록 삭제 결과를 확인하지 못했습니다.")
        }
        try locks.forEach { try $0.verify() }
        guard try keychain.read(service: AuthTransaction.service, account: rotationKey) == marker,
              try keychain.read(service: AuthTransaction.service, account: preservedKey) == archiveData,
              try keychain.read(service: keychainService, account: keychainAccount) == beforeKeychain,
              try files.read(authURL) == beforeFile, try files.read(configURL) == configSnapshot,
              try keychain.read(service: KeychainSecretStore.service, account: account.id.uuidString) == currentVaultData else {
            throw AgentSwapError.storage("현재 Claude 로그인 또는 복구 자료가 마지막 정리 중 변경되었습니다.")
        }
        try keychain.delete(service: AuthTransaction.service, account: rotationKey)
        guard try keychain.read(service: AuthTransaction.service, account: rotationKey) == nil else {
            throw AgentSwapError.storage("Claude 토큰 갱신 복원 자료 삭제 결과를 확인하지 못했습니다.")
        }
        retainedCredentials.removeValue(forKey: account.id)
        persistedInactiveCredentials.removeValue(forKey: account.id)
        persistedGenerations.removeValue(forKey: account.id)
        return .init(account: account, credential: verified.credential)
    }
    /// Deletes only archives explicitly registered for this account. A marker or transaction may
    /// still be the sole durable recovery material, so account deletion must leave it untouched.
    func deletePreservedRecoveryCredentials(accountID: UUID) throws {
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 진행 중입니다.") }
        guard !(try pendingRecovery()) else {
            throw AgentSwapError.storage("진행 중인 Claude 인증 복구가 있어 계정을 삭제할 수 없습니다.")
        }
        let indexKey = preservedRotationIndexKey(accountID: accountID)
        guard let data = try keychain.read(service: AuthTransaction.service, account: indexKey) else { return }
        let index = try decodePreservedIndex(data)
        // An index is an ownership hint, never deletion authority by itself. Validate every
        // present archive before deleting anything so a corrupted/cross-account index cannot
        // erase recovery material belonging to another account. A missing archive is the safe
        // crash window between index persistence and archive creation and remains retryable.
        for hash in index.markerHashes {
            let archiveKey = rotationKey + "|preserved|" + hash
            guard let archiveData = try keychain.read(service: AuthTransaction.service, account: archiveKey) else { continue }
            let archive: PreservedClaudeRotationArchive
            do { archive = try JSONDecoder().decode(PreservedClaudeRotationArchive.self, from: archiveData) }
            catch { throw AgentSwapError.storage("Claude 보존 복구 자료를 읽지 못했습니다.") }
            guard archive.version == 1, preservedRotationHash(archive.originalRotationMarker) == hash,
                  let pending = try? JSONDecoder().decode(PendingClaudeRotation.self, from: archive.originalRotationMarker),
                  pending.accountID == accountID else {
                throw AgentSwapError.unsupported("다른 Claude 계정의 보존 복구 자료가 있어 삭제를 중단했습니다.")
            }
        }
        for hash in index.markerHashes {
            let archiveKey = rotationKey + "|preserved|" + hash
            try keychain.delete(service: AuthTransaction.service, account: archiveKey)
            guard try keychain.read(service: AuthTransaction.service, account: archiveKey) == nil else {
                throw AgentSwapError.storage("Claude 보존 복구 자료 삭제 결과를 확인하지 못했습니다.")
            }
        }
        try keychain.delete(service: AuthTransaction.service, account: indexKey)
        guard try keychain.read(service: AuthTransaction.service, account: indexKey) == nil else {
            throw AgentSwapError.storage("Claude 보존 복구 목록 삭제 결과를 확인하지 못했습니다.")
        }
    }
    private func registerPreservedArchive(_ markerHash: String, indexKey: String) throws {
        let existing = try keychain.read(service: AuthTransaction.service, account: indexKey)
        let hashes: [String]
        if let existing { hashes = try decodePreservedIndex(existing).markerHashes }
        else { hashes = [] }
        guard hashes.contains(markerHash) || markerHashIsValid(markerHash) else {
            throw AgentSwapError.storage("Claude 보존 복구 자료 식별자를 확인하지 못했습니다.")
        }
        let updated = hashes.contains(markerHash) ? hashes : (hashes + [markerHash]).sorted()
        let data = try sortedIndexData(.init(markerHashes: updated))
        if existing != data { try keychain.write(data, service: AuthTransaction.service, account: indexKey) }
        guard try keychain.read(service: AuthTransaction.service, account: indexKey) == data else {
            throw AgentSwapError.storage("Claude 보존 복구 목록의 저장 결과를 확인하지 못했습니다.")
        }
    }
    private func hasPreservedIntent(marker: Data, accountID: UUID) throws -> Bool {
        guard let data = try keychain.read(service: AuthTransaction.service,
                                           account: preservedRotationIndexKey(accountID: accountID)) else { return false }
        return try decodePreservedIndex(data).markerHashes.contains(preservedRotationHash(marker))
    }
    private func decodePreservedIndex(_ data: Data) throws -> PreservedClaudeRecoveryIndex {
        let index: PreservedClaudeRecoveryIndex
        do { index = try JSONDecoder().decode(PreservedClaudeRecoveryIndex.self, from: data) }
        catch { throw AgentSwapError.storage("Claude 보존 복구 목록을 읽지 못했습니다.") }
        guard index.version == 1, !index.markerHashes.isEmpty,
              Set(index.markerHashes).count == index.markerHashes.count,
              index.markerHashes.allSatisfy(markerHashIsValid) else {
            throw AgentSwapError.unsupported("지원하지 않는 Claude 보존 복구 목록입니다.")
        }
        return index
    }
    private func markerHashIsValid(_ hash: String) -> Bool {
        hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func validateRecoveryVault(_ vaultData: Data?, pending: PendingClaudeRotation, liveRaw: Data,
                                       account: AccountRecord) throws {
        guard let vaultData else { return }
        let vault = try recoveryVaultCredential(vaultData, account: account)
        guard vault.rawAuth == pending.expectedRaw || vault.rawAuth == pending.credential.rawAuth || vault.rawAuth == liveRaw else {
            throw AgentSwapError.storage("Claude 계정 보관함 인증이 더 새로운 알 수 없는 세대여서 복구를 중단했습니다.")
        }
    }
    private func requiredExpectedRaw(_ pending: PendingClaudeRotation) throws -> Data {
        guard let raw = pending.expectedRaw else {
            throw AgentSwapError.unsupported("토큰 갱신 복원 자료의 원본 인증 이미지가 없습니다.")
        }
        return raw
    }
    private func recoveryVaultCredential(_ vaultData: Data, account: AccountRecord) throws -> Credential {
        let vault: Credential
        do { vault = try JSONDecoder().decode(Credential.self, from: vaultData) }
        catch { throw AgentSwapError.storage("Claude 계정 보관함 인증 형식을 확인하지 못했습니다.") }
        let parsed = try CredentialParser.claude(rawAuth: vault.rawAuth, accountMetadata: vault.accountMetadata)
        guard parsed.accessToken == vault.accessToken, parsed.refreshToken == vault.refreshToken,
              try ProviderAccountParser.claude(vault).account.identity == account.identity else {
            throw AgentSwapError.storage("Claude 계정 보관함 인증이 더 새로운 알 수 없는 세대여서 복구를 중단했습니다.")
        }
        return vault
    }
    private func cachedIdentityStatus(expectedMetadata: Data?, cachedMetadata: Data?) throws -> (complete: Bool, matches: Bool) {
        guard let expectedMetadata else { throw AgentSwapError.authentication("Claude 계정을 프로필로 확인한 뒤 다시 시도하세요.") }
        let expected = try authObject(expectedMetadata, name: "Claude 계정")
        guard let user = expected["accountUuid"] as? String, !user.isEmpty,
              let organization = expected["organizationUuid"] as? String, !organization.isEmpty else {
            throw AgentSwapError.authentication("Claude 계정 식별 정보를 확인한 뒤 다시 시도하세요.")
        }
        let cached = try cachedMetadata.map { try authObject($0, name: "Claude 현재 계정") } ?? [:]
        var complete = true, matches = true
        for (key, value) in [("accountUuid", user), ("organizationUuid", organization)] {
            guard let present = cached[key] else { complete = false; continue }
            guard let field = present as? String else { throw AgentSwapError.unsupported("Claude 현재 계정의 식별 정보 형식을 확인하지 못했습니다.") }
            if field.isEmpty { complete = false } else if field != value { matches = false }
        }
        return (complete, matches)
    }
    private func validateRotationSource(_ pending: PendingClaudeRotation) throws -> Data? {
        // Only an active, present native grant creates a rotation marker. An absent or missing
        // predecessor is not a supported repair instruction and cannot resurrect a logged-out profile.
        guard pending.expectedRaw != nil else {
            throw AgentSwapError.unsupported("토큰 갱신 복원 자료의 원본 인증 이미지가 없습니다.")
        }
        guard try plannedNativeRotation(pending.credential, sourceRaw: pending.expectedRaw) == pending.nativeAfter else {
            throw AgentSwapError.unsupported("토큰 갱신 복원 자료의 네이티브 인증 이미지가 일치하지 않습니다.")
        }
        let live = try currentRawAuth()
        if let snapshot = pending.verifiedConfiguration {
            var source = try CredentialParser.claude(rawAuth: requiredExpectedRaw(pending), accountMetadata: pending.credential.accountMetadata)
            source.claudeIdentityBinding = snapshot.sourceBinding
            guard source.verifiedClaudeAccountIdentity == (try ProviderAccountParser.claude(pending.credential).account.identity) else {
                throw AgentSwapError.storage("Claude 갱신 복원 자료의 프로필 확인 정보가 원본 인증과 일치하지 않습니다.")
            }
            try verifyConfiguration(snapshot)
            _ = try config(snapshot.data)
            let metadata = try pending.credential.accountMetadata.map { try authObject($0, name: "Claude 확인된 계정") }
            if let live { try validateSourceOrganization(validate(live), cachedAccount: metadata) }
        } else {
            let cached = try config()["oauthAccount"] as? [String: Any]
            if let live { try validateSourceOrganization(validate(live), cachedAccount: cached) }
            let metadata = try cached.map(authData)
            let identity = try cachedIdentityStatus(expectedMetadata: pending.credential.accountMetadata, cachedMetadata: metadata)
            guard identity.matches else { throw AgentSwapError.storage("다른 Claude 계정이 활성화되어 토큰 갱신 복원을 중단했습니다.") }
        }
        guard live == pending.expectedRaw || live == pending.nativeAfter else {
            throw AgentSwapError.storage("토큰 갱신 중단 후 Claude 인증이 외부에서 변경되었습니다. 최신 인증과 복원 자료를 보존했습니다.")
        }
        return live
    }
    public func activate(_ credential: Credential, expectedSourceIdentity: AccountIdentity? = nil,
                         expectedSourceAuth: Data? = nil, expectedSourceAbsent: Bool = false) throws {
        try Task.checkCancellation()
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 진행 중입니다. 완료 후 다시 전환해 주세요.") }
        guard retainedCredentials.isEmpty else {
            throw AgentSwapError.storage("갱신된 Claude 인증을 먼저 저장한 뒤 전환해 주세요.")
        }
        // The marker may be the only durable copy if the vault write failed after token rotation.
        // Only explicit recovery may save/apply that successor and clear the marker.
        guard try keychain.read(service: AuthTransaction.service, account: rotationKey) == nil else {
            throw AgentSwapError.storage("중단된 Claude 토큰 갱신의 복원을 완료한 뒤 전환해 주세요.")
        }
        var target = try validate(credential.rawAuth)
        guard let metadata = credential.accountMetadata else { throw AgentSwapError.unsupported("Claude 계정 메타데이터가 없어 인증 변경을 중단했습니다.") }
        let oauthAccount = try authObject(metadata, name: "Claude 계정")
        guard let user = oauthAccount["accountUuid"] as? String, !user.isEmpty,
              let organization = oauthAccount["organizationUuid"] as? String, !organization.isEmpty else {
            throw AgentSwapError.unsupported("Claude 사용자와 워크스페이스 ID를 확인하지 못했습니다.")
        }
        if let boundOrganization = target["organizationUuid"] as? String, boundOrganization != organization {
            throw AgentSwapError.authentication("Claude 인증의 워크스페이스와 계정 메타데이터가 일치하지 않습니다.")
        }
        let locks = try locks()
        defer { withExtendedLifetime(locks) {} }
        try transaction.recover(allowedLocations: allowedLocations)
        var currentConfig = try config()
        if !isolated, try keychain.read(service: "Claude Code", account: keychainAccount) != nil {
            throw AgentSwapError.unsupported("API 키를 사용하는 Claude 프로필은 v1에서 전환할 수 없습니다.")
        }
        let beforeKeychain = try keychain.read(service: keychainService, account: keychainAccount)
        let beforeFile = try files.read(authURL)
        if expectedSourceAbsent, beforeKeychain != nil || beforeFile != nil {
            throw AgentSwapError.storage("새 Claude 인증이 외부에서 생성되어 먼저 현재 계정을 확인해야 합니다.")
        }
        if let expectedSourceAuth, (beforeKeychain ?? beforeFile) != expectedSourceAuth {
            throw AgentSwapError.storage("Claude 인증이 세션 보존 이후 변경되어 전환을 중단했습니다.")
        }
        if let expectedSourceIdentity {
            guard expectedSourceIdentity.provider == .claude else {
                throw AgentSwapError.storage("Claude 계정이 세션 보존 이후 변경되어 전환을 중단했습니다.")
            }
            let currentAccount = currentConfig["oauthAccount"] as? [String: Any] ?? [:]
            for (key, expected) in [("accountUuid", expectedSourceIdentity.userID), ("organizationUuid", expectedSourceIdentity.workspaceID)] {
                if let value = currentAccount[key] {
                    guard let cached = value as? String else {
                        throw AgentSwapError.storage("Claude 현재 계정의 식별 정보 형식이 변경되어 전환을 중단했습니다.")
                    }
                    if !cached.isEmpty {
                        guard cached == expected else { throw AgentSwapError.storage("Claude 계정이 세션 보존 이후 변경되어 전환을 중단했습니다.") }
                        continue
                    }
                }
                // An authenticated profile can fill an incomplete native metadata cache only
                // while its exact source grant generation still matches under these locks.
                guard expectedSourceAuth != nil else {
                    throw AgentSwapError.storage("Claude 현재 계정과 인증 세대를 함께 확인하지 못해 전환을 중단했습니다.")
                }
            }
        }
        if let raw = beforeKeychain ?? beforeFile {
            let live = try validate(raw)
            // Presence and absence of each integration field are authoritative in the live store.
            for key in Self.sharedKeys { target[key] = live[key] }
        } else {
            for key in Self.sharedKeys { target.removeValue(forKey: key) }
        }
        if let beforeFile { _ = try validate(beforeFile) }
        let targetData = try claudeCLIAuthData(target)
        currentConfig["oauthAccount"] = oauthAccount
        var mutations = [AuthMutation(location: authLocation, before: beforeKeychain, after: targetData)]
        // Keep a pre-existing file mirror current; a Keychain-only profile never gains a secret file.
        if beforeFile != nil { mutations.append(.init(location: .file(authURL.path), before: beforeFile, after: targetData)) }
        mutations.append(.init(location: .file(configURL.path), before: try files.read(configURL), after: try authData(currentConfig)))
        try Task.checkCancellation()
        try transaction.perform(mutations, checkCancellation: { try Task.checkCancellation() }) {
            // Rollback must verify the lock even after cancellation, so cancellation is a separate
            // forward-write check rather than part of the lock verifier used for restoration.
            try locks.forEach { try $0.verify() }
        }
    }
    private func sameIdentity(_ lhs: Data?, _ rhs: Data?) throws -> Bool {
        guard let lhs, let rhs else { return false }
        let left = try authObject(lhs, name: "Claude 계정"), right = try authObject(rhs, name: "Claude 계정")
        guard let user = left["accountUuid"] as? String, !user.isEmpty,
              let workspace = left["organizationUuid"] as? String, !workspace.isEmpty else { return false }
        return user == right["accountUuid"] as? String && workspace == right["organizationUuid"] as? String
    }
    private func plannedNativeRotation(_ credential: Credential, sourceRaw: Data?) throws -> Data {
        var target = try validate(credential.rawAuth)
        let parsed = try CredentialParser.claude(rawAuth: credential.rawAuth, accountMetadata: credential.accountMetadata)
        guard parsed.accessToken == credential.accessToken, parsed.refreshToken == credential.refreshToken else {
            throw AgentSwapError.unsupported("Claude 갱신 인증의 토큰 필드가 저장 이미지와 일치하지 않습니다.")
        }
        _ = try cachedIdentityStatus(expectedMetadata: credential.accountMetadata, cachedMetadata: nil)
        let metadata = try credential.accountMetadata.map { try authObject($0, name: "Claude 계정") }
        try validateSourceOrganization(target, cachedAccount: metadata)
        if let sourceRaw {
            let source = try validate(sourceRaw)
            try validateSourceOrganization(source, cachedAccount: metadata)
            // Refresh responses cannot replace MCP/plugin grants. The exact source image is
            // authoritative for both presence and absence of these shared fields.
            for key in Self.sharedKeys { target[key] = source[key] }
        } else {
            for key in Self.sharedKeys { target.removeValue(forKey: key) }
        }
        return try claudeCLIAuthData(target)
    }
    private func verifyConfiguration(_ snapshot: ClaudeRotationConfigurationSnapshot) throws {
        guard try files.read(configURL) == snapshot.data else {
            throw AgentSwapError.storage("Claude 계정 설정이 확인 이후 변경되어 인증 적용을 중단했습니다.")
        }
    }
    private func persistNativeRotation(_ credential: Credential, expectedRaw: Data?, nativeAfter: Data,
                                       locks: [ProviderDirectoryLock],
                                       verifiedConfiguration: ClaudeRotationConfigurationSnapshot? = nil) throws {
        guard try plannedNativeRotation(credential, sourceRaw: expectedRaw) == nativeAfter else {
            throw AgentSwapError.unsupported("Claude 갱신 인증의 네이티브 저장 이미지가 일치하지 않습니다.")
        }
        let beforeKeychain = try keychain.read(service: keychainService, account: keychainAccount)
        let beforeFile = try files.read(authURL)
        guard (beforeKeychain ?? beforeFile) == expectedRaw else { throw AgentSwapError.storage("Claude 인증이 갱신 중 외부에서 변경되었습니다.") }
        if let verifiedConfiguration { try verifyConfiguration(verifiedConfiguration) }
        var mutations = [AuthMutation(location: authLocation, before: beforeKeychain, after: nativeAfter)]
        if beforeFile != nil { mutations.append(.init(location: .file(authURL.path), before: beforeFile, after: nativeAfter)) }
        try transaction.perform(mutations) {
            try locks.forEach { try $0.verify() }
            if let verifiedConfiguration { try verifyConfiguration(verifiedConfiguration) }
        }
    }
    /// Only the native writer's three source layouts are recoverable: Keychain-only,
    /// Keychain plus mirror, or a file-only mirror. Their location-specific before-images
    /// make an absent Keychain distinct from an absent file.
    private func nativeRotationJournalMutations(expectedRaw: Data, nativeAfter: Data) -> [[AuthMutation]] {
        let fileLocation = AuthMutation.Location.file(authURL.path)
        let keychainMutation = AuthMutation(location: authLocation, before: expectedRaw, after: nativeAfter)
        let fileMutation = AuthMutation(location: fileLocation, before: expectedRaw, after: nativeAfter)
        return [
            [keychainMutation],
            [keychainMutation, fileMutation],
            [
                .init(location: authLocation, before: nil, after: nativeAfter),
                fileMutation
            ]
        ]
    }
    /// Active refresh holds Claude's own refresh locks across the HTTP exchange; inactive refresh never writes live auth.
    /// The successor is saved immediately to the same injected application Keychain before updating provider stores.
    public func refresh(_ credential: Credential, accountID: UUID, verifiedNative: ImportedAccount? = nil,
                        requiresVerifiedNative: Bool = false, requiresInactive: Bool = false,
                        operation: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 이미 진행 중입니다.") }
        try persistRetainedCredentials()
        _ = try validate(credential.rawAuth)
        refreshing = true; defer { refreshing = false }
        var locks: [ProviderDirectoryLock]? = try self.locks()
        defer { withExtendedLifetime(locks) {} }
        guard !(try pendingRecovery()) else { throw AgentSwapError.storage("Claude 인증 복원을 완료한 뒤 갱신해 주세요.") }
        let raw = try currentRawAuth()
        let configSnapshot = try files.read(configURL)
        let cached = try config(configSnapshot)["oauthAccount"] as? [String: Any]
        let identity: (complete: Bool, matches: Bool)
        let current: Credential?
        let verifiedConfiguration: ClaudeRotationConfigurationSnapshot?
        if let verifiedNative {
            guard let raw, verifiedNative.account.provider == .claude,
                  verifiedNative.credential.rawAuth == raw else {
                throw AgentSwapError.storage("확인한 Claude 인증 세대가 변경되어 갱신을 보류했습니다.")
            }
            let parsed = try CredentialParser.claude(rawAuth: raw, accountMetadata: verifiedNative.credential.accountMetadata)
            guard parsed.accessToken == verifiedNative.credential.accessToken,
                  parsed.refreshToken == verifiedNative.credential.refreshToken,
                  let sourceBinding = verifiedNative.credential.claudeIdentityBinding,
                  verifiedNative.credential.verifiedClaudeAccountIdentity == verifiedNative.account.identity,
                  try ProviderAccountParser.claude(parsed).account.identity == verifiedNative.account.identity else {
                throw AgentSwapError.authentication("확인한 Claude 프로필과 인증 세대가 일치하지 않습니다.")
            }
            let metadata = try parsed.accountMetadata.map { try authObject($0, name: "Claude 확인된 계정") }
            try validateSourceOrganization(validate(raw), cachedAccount: metadata)
            // Even an authenticated profile cannot turn a malformed cache into writable state.
            for key in ["accountUuid", "organizationUuid"] {
                if let value = cached?[key], !(value is String) {
                    throw AgentSwapError.unsupported("Claude 현재 계정의 식별 정보 형식을 확인하지 못했습니다.")
                }
            }
            identity = (true, try sameIdentity(credential.accountMetadata, parsed.accountMetadata))
            current = verifiedNative.credential
            verifiedConfiguration = .init(data: configSnapshot, sourceBinding: sourceBinding)
        } else {
            guard !requiresVerifiedNative || raw == nil else {
                throw AgentSwapError.storage("현재 Claude 인증의 프로필을 확인하지 못해 갱신을 보류했습니다.")
            }
            // Legacy direct-store callers retain the existing cache and exact-grant fence.
            try validateSourceOrganization(raw.map { try validate($0) } ?? [:], cachedAccount: cached)
            let metadata = try cached.map(authData)
            identity = try cachedIdentityStatus(expectedMetadata: credential.accountMetadata, cachedMetadata: metadata)
            current = try raw.map { try CredentialParser.claude(rawAuth: $0, accountMetadata: identity.complete ? metadata : credential.accountMetadata) }
            verifiedConfiguration = nil
        }
        let sameGrant = current.map { $0.accessToken == credential.accessToken && $0.refreshToken == credential.refreshToken } ?? false
        if sameGrant && !identity.matches {
            if verifiedNative != nil {
                throw AgentSwapError.storage("Claude 프로필로 확인한 인증이 저장된 계정과 달라 갱신을 중단했습니다. 두 인증을 보존했으므로 현재 로그인을 다시 확인해 주세요.")
            }
            throw AgentSwapError.authentication("현재 Claude 인증과 계정 식별 정보가 일치하지 않아 갱신을 중단했습니다.")
        }
        if raw != nil, !identity.complete, identity.matches, !sameGrant {
            throw AgentSwapError.storage("현재 Claude 인증 세대와 불완전한 계정 정보를 확인하지 못했습니다. 현재 로그인을 다시 가져오세요.")
        }
        let active = raw != nil && identity.matches && (identity.complete || sameGrant)
        if requiresInactive, verifiedNative == nil || active {
            throw IndependentCredentialRefreshBlocked(message: "현재 CLI 로그인과 다른 계정인지 확인할 때까지 재로그인한 인증의 갱신을 보류합니다. 인증을 적용하려면 별도로 계정을 전환해 주세요.")
        }
        if let completed = persistedInactiveCredentials[accountID] {
            guard try sameIdentity(completed.credential.accountMetadata, credential.accountMetadata) else {
                throw AgentSwapError.authentication("보존한 Claude 갱신 인증과 요청한 계정이 일치하지 않습니다.")
            }
            if active, let raw, raw != completed.predecessorAuth, raw != completed.credential.rawAuth {
                // A distinct native generation owns current authentication. Do not resurrect the
                // private retry response over that consumer's successor.
                persistedInactiveCredentials.removeValue(forKey: accountID)
                persistedGenerations.removeValue(forKey: accountID)
            } else if credential.rawAuth == completed.predecessorAuth {
                // Taking the nonsecret receipt must never permit replay of the consumed grant.
                return completed.credential
            } else if credential.rawAuth != completed.credential.rawAuth {
                persistedInactiveCredentials.removeValue(forKey: accountID)
                persistedGenerations.removeValue(forKey: accountID)
            }
        }
        if active, let raw, let preflight = keychain as? any KeychainWritePreflighting {
            // Reject an unwritable live profile before consuming its refresh grant.
            try preflight.validateWrite(raw, service: keychainService, account: keychainAccount)
            try preflight.validateWrite(claudeCLIAuthData(validate(raw)), service: keychainService, account: keychainAccount)
        }
        var input = credential
        if active, let verifiedConfiguration {
            try verifyConfiguration(verifiedConfiguration)
            guard try currentRawAuth() == raw else {
                throw AgentSwapError.storage("확인한 Claude 인증 세대가 변경되어 갱신을 보류했습니다.")
            }
        }
        if active, let current {
            if current.accessToken != credential.accessToken || current.refreshToken != credential.refreshToken {
                // Adopt a native rotation rather than consume the obsolete backup grant again.
                input = current
                try keychain.write(JSONEncoder().encode(input), service: KeychainSecretStore.service, account: accountID.uuidString)
                return input
            }
            input = current
        } else {
            locks = nil // Release provider locks before refreshing an inactive backup.
        }
        try Task.checkCancellation()
        if active, let verifiedConfiguration {
            try verifyConfiguration(verifiedConfiguration)
            guard try currentRawAuth() == raw else {
                throw AgentSwapError.storage("확인한 Claude 인증 세대가 변경되어 갱신을 보류했습니다.")
            }
        }
        let rotated = try await operation(input)
        _ = try validate(rotated.rawAuth)
        guard try sameIdentity(rotated.accountMetadata, credential.accountMetadata) else {
            throw AgentSwapError.authentication("갱신된 Claude 계정 식별 정보가 일치하지 않습니다.")
        }
        let parsed = try CredentialParser.claude(rawAuth: rotated.rawAuth, accountMetadata: rotated.accountMetadata)
        guard parsed.accessToken == rotated.accessToken, parsed.refreshToken == rotated.refreshToken else {
            throw AgentSwapError.unsupported("Claude 갱신 인증의 토큰 필드가 저장 이미지와 일치하지 않습니다.")
        }
        let vaultData = try JSONEncoder().encode(rotated)
        if active, let locks {
            // A forward-repair marker survives native partial failures without losing the consumed token's successor.
            let nativeAfter = try plannedNativeRotation(rotated, sourceRaw: raw)
            let pending = PendingClaudeRotation(credential: rotated, expectedRaw: raw, nativeAfter: nativeAfter,
                                                accountID: accountID, verifiedConfiguration: verifiedConfiguration)
            retainedCredentials[accountID] = .init(predecessorAuth: input.rawAuth, credential: rotated, vaultData: vaultData, rotationData: try JSONEncoder().encode(pending))
            try persistRetainedCredentials()
            try keychain.write(vaultData, service: KeychainSecretStore.service, account: accountID.uuidString)
            try persistNativeRotation(rotated, expectedRaw: raw, nativeAfter: nativeAfter, locks: locks,
                                      verifiedConfiguration: verifiedConfiguration)
            try? keychain.delete(service: AuthTransaction.service, account: rotationKey)
        } else {
            retainedCredentials[accountID] = .init(predecessorAuth: input.rawAuth, credential: rotated, vaultData: vaultData, rotationData: nil)
            try persistRetainedCredentials()
        }
        return rotated
    }
    public func cleanupIsolatedAuthentication() throws {
        guard isolated else { throw AgentSwapError.unsupported("기본 Claude 프로필은 로그인 정리 대상으로 사용할 수 없습니다.") }
        try keychain.delete(service: keychainService, account: keychainAccount)
        try files.delete(authURL)
    }
}

/// `security find-generic-password -w` hex-encodes non-printable password bytes, while
/// Claude Code parses its output directly as JSON. Escape Unicode in native auth JSON
/// so MCP/plugin values keep their meaning and the CLI receives printable JSON bytes.
func claudeCLIAuthData(_ object: [String: Any]) throws -> Data {
    let encoded = try authData(object)
    guard let json = String(data: encoded, encoding: .utf8) else {
        throw AgentSwapError.unsupported("Claude 인증 JSON을 안전하게 저장하지 못했습니다.")
    }
    var ascii = ""
    ascii.reserveCapacity(json.utf8.count)
    for scalar in json.unicodeScalars {
        let value = scalar.value
        if (0x20...0x7E).contains(value) { ascii.unicodeScalars.append(scalar) }
        else if value <= 0xFFFF { ascii += String(format: "\\u%04x", value) }
        else {
            let surrogate = value - 0x10000
            ascii += String(format: "\\u%04x\\u%04x", 0xD800 + (surrogate >> 10), 0xDC00 + (surrogate & 0x3FF))
        }
    }
    return Data(ascii.utf8)
}
