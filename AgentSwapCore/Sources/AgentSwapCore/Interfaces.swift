import Foundation

/// A private-vault successor that was saved after an earlier first-save failure.
/// Digests let the engine reject its stale native predecessor without exposing credential bytes.
public struct PersistedCredentialGeneration: Sendable {
    public let accountID: UUID
    public let predecessorDigest: String
    public let successorDigest: String
    public init(accountID: UUID, predecessorDigest: String, successorDigest: String) {
        self.accountID = accountID
        self.predecessorDigest = predecessorDigest
        self.successorDigest = successorDigest
    }
}

public protocol SecretStore: Sendable {
    func load(accountID: UUID) async throws -> Credential?
    func save(_ credential: Credential, accountID: UUID) async throws
    func delete(accountID: UUID) async throws
}
public protocol StateStore: Sendable {
    func load() async throws -> PersistedState
    func save(_ state: PersistedState) async throws
}
public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    func compatibility() async -> CompatibilityStatus
    func importCurrent() async throws -> ImportedAccount
    /// Nil means authoritative native auth is absent; access and format errors must still throw.
    func importCurrentIfPresent() async throws -> ImportedAccount?
    /// Restores only authenticated, grant-bound identity evidence from the private vault.
    func registerStoredCredential(_ credential: Credential, account: AccountRecord) async
    func login() async throws -> ImportedAccount
    func cancelLogin() async
    /// A validated CLI fallback URL stays private to the runner and opens only on explicit request.
    func canOpenLoginPage() async -> Bool
    func openLoginPage() async throws
    func submitLoginCode(_ code: String) async throws
    func refresh(_ credential: Credential, account: AccountRecord) async throws -> Credential
    /// Validates account ownership without exchanging a grant. Returned evidence is saved before usage.
    func verifyCredential(_ credential: Credential, account: AccountRecord) async throws -> Credential
    func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) async -> SwitchResult
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool, saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool, allowMissingSource: Bool,
                                  saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult
    func hasRunningConsumers() async -> Bool
    func recoverInterruptedSwitch() async throws
    /// Preserves a verified, externally rotated Claude login while retaining the interrupted
    /// rotation marker as an auditable recovery record.
    func recoverKeepingCurrentLogin(account: AccountRecord) async throws -> ImportedAccount
    func deletePreservedRecoveryCredentials(accountID: UUID) async throws
    /// Retained validated OAuth successors awaiting their first durable save. No new grant is exchanged.
    func hasPendingCredentialPersistence() async -> Bool
    func flushPendingCredentialPersistence() async throws
    func takePersistedCredentialGenerations() async -> [PersistedCredentialGeneration]
    /// Explicit fresh login or successful deletion supersedes only undurable in-memory successors.
    func discardPendingCredentialPersistence(accountID: UUID) async
}

public extension ProviderAdapter {
    func registerStoredCredential(_ credential: Credential, account: AccountRecord) async {}
    func verifyCredential(_ credential: Credential, account: AccountRecord) async throws -> Credential { credential }
    func importCurrentIfPresent() async throws -> ImportedAccount? { try await importCurrent() }
    func canOpenLoginPage() async -> Bool { false }
    func openLoginPage() async throws { throw AgentSwapError.unsupported("진행 중인 로그인 페이지가 없습니다.") }
    func submitLoginCode(_ code: String) async throws { throw AgentSwapError.unsupported("이 로그인에는 인증 코드 입력이 지원되지 않습니다.") }
    func recoverInterruptedSwitch() async throws { throw AgentSwapError.unsupported("이 제공자에는 복구할 전환이 없습니다.") }
    func recoverKeepingCurrentLogin(account: AccountRecord) async throws -> ImportedAccount {
        throw AgentSwapError.unsupported("이 제공자에는 현재 로그인을 보존하는 복구가 없습니다.")
    }
    func deletePreservedRecoveryCredentials(accountID: UUID) async throws {}
    func hasPendingCredentialPersistence() async -> Bool { false }
    func flushPendingCredentialPersistence() async throws {}
    func takePersistedCredentialGenerations() async -> [PersistedCredentialGeneration] { [] }
    func discardPendingCredentialPersistence(accountID: UUID) async {}
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool, allowMissingSource: Bool,
                                  saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        await activatePreservingSource(credential, account: account, relaunch: relaunch, saveLatest: saveLatest)
    }
    func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool, saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        do {
            guard let current = try await importCurrentIfPresent() else {
                throw AgentSwapError.storage("현재 인증이 없어 원본 백업을 확인하지 못했습니다.")
            }
            try await saveLatest(current)
            return await activate(credential, account: account, relaunch: relaunch)
        } catch { return .failed(message: "현재 인증 백업 실패: \(error.localizedDescription)") }
    }
}
