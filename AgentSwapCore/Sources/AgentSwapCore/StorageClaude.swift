import Foundation
import CryptoKit

private struct PendingClaudeRotation: Codable, Sendable {
    var credential: Credential
    var expectedRaw: Data?
    /// The exact canonical provider-store image, including authoritative shared integration values.
    var nativeAfter: Data
    var accountID: UUID
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
    private var rotationKey: String { transaction.identifier + "|rotation" }
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
        guard let data = try files.read(configURL) else { return [:] }
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
            let pending: PendingClaudeRotation
            do { pending = try JSONDecoder().decode(PendingClaudeRotation.self, from: data) }
            catch { throw AgentSwapError.storage("토큰 갱신 복원 자료를 읽지 못했습니다.") }
            // Refuse malformed or conflicting metadata before even a native transaction rollback.
            _ = try validateRotationSource(pending)
            pendingRotation = pending
        } else { pendingRotation = nil }
        try transaction.recover(allowedLocations: allowedLocations)
        if let pending = pendingRotation {
            let rotated = pending.credential
            let live = try validateRotationSource(pending)
            try keychain.write(JSONEncoder().encode(rotated), service: KeychainSecretStore.service, account: pending.accountID.uuidString)
            try persistNativeRotation(rotated, expectedRaw: live, nativeAfter: pending.nativeAfter, locks: locks)
            try keychain.delete(service: AuthTransaction.service, account: rotationKey)
        }
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
        let live = try currentRawAuth(), cached = try config()["oauthAccount"] as? [String: Any]
        if let live { try validateSourceOrganization(validate(live), cachedAccount: cached) }
        let metadata = try cached.map(authData)
        let identity = try cachedIdentityStatus(expectedMetadata: pending.credential.accountMetadata, cachedMetadata: metadata)
        guard identity.matches else { throw AgentSwapError.storage("다른 Claude 계정이 활성화되어 토큰 갱신 복원을 중단했습니다.") }
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
    private func persistNativeRotation(_ credential: Credential, expectedRaw: Data?, nativeAfter: Data,
                                       locks: [ProviderDirectoryLock]) throws {
        guard try plannedNativeRotation(credential, sourceRaw: expectedRaw) == nativeAfter else {
            throw AgentSwapError.unsupported("Claude 갱신 인증의 네이티브 저장 이미지가 일치하지 않습니다.")
        }
        let beforeKeychain = try keychain.read(service: keychainService, account: keychainAccount)
        let beforeFile = try files.read(authURL)
        guard (beforeKeychain ?? beforeFile) == expectedRaw else { throw AgentSwapError.storage("Claude 인증이 갱신 중 외부에서 변경되었습니다.") }
        var mutations = [AuthMutation(location: authLocation, before: beforeKeychain, after: nativeAfter)]
        if beforeFile != nil { mutations.append(.init(location: .file(authURL.path), before: beforeFile, after: nativeAfter)) }
        try transaction.perform(mutations) { try locks.forEach { try $0.verify() } }
    }
    /// Active refresh holds Claude's own refresh locks across the HTTP exchange; inactive refresh never writes live auth.
    /// The successor is saved immediately to the same injected application Keychain before updating provider stores.
    public func refresh(_ credential: Credential, accountID: UUID,
                        operation: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        guard !refreshing else { throw AgentSwapError.storage("Claude 토큰 갱신이 이미 진행 중입니다.") }
        try persistRetainedCredentials()
        _ = try validate(credential.rawAuth)
        refreshing = true; defer { refreshing = false }
        var locks: [ProviderDirectoryLock]? = try self.locks()
        defer { withExtendedLifetime(locks) {} }
        guard !(try pendingRecovery()) else { throw AgentSwapError.storage("Claude 인증 복원을 완료한 뒤 갱신해 주세요.") }
        let raw = try currentRawAuth()
        let cached = try config()["oauthAccount"] as? [String: Any]
        // Validation must precede grant consumption even when this may be an inactive backup.
        try validateSourceOrganization(raw.map { try validate($0) } ?? [:], cachedAccount: cached)
        let metadata = try cached.map(authData)
        let identity = try cachedIdentityStatus(expectedMetadata: credential.accountMetadata, cachedMetadata: metadata)
        let current = try raw.map { try CredentialParser.claude(rawAuth: $0, accountMetadata: identity.complete ? metadata : credential.accountMetadata) }
        let sameGrant = current.map { $0.accessToken == credential.accessToken && $0.refreshToken == credential.refreshToken } ?? false
        if sameGrant && !identity.matches {
            throw AgentSwapError.authentication("현재 Claude 인증과 계정 식별 정보가 일치하지 않아 갱신을 중단했습니다.")
        }
        if raw != nil, !identity.complete, identity.matches, !sameGrant {
            throw AgentSwapError.storage("현재 Claude 인증 세대와 불완전한 계정 정보를 확인하지 못했습니다. 현재 로그인을 다시 가져오세요.")
        }
        let active = raw != nil && identity.matches && (identity.complete || sameGrant)
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
            let pending = PendingClaudeRotation(credential: rotated, expectedRaw: raw, nativeAfter: nativeAfter, accountID: accountID)
            retainedCredentials[accountID] = .init(predecessorAuth: input.rawAuth, credential: rotated, vaultData: vaultData, rotationData: try JSONEncoder().encode(pending))
            try persistRetainedCredentials()
            try keychain.write(vaultData, service: KeychainSecretStore.service, account: accountID.uuidString)
            try persistNativeRotation(rotated, expectedRaw: raw, nativeAfter: nativeAfter, locks: locks)
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
