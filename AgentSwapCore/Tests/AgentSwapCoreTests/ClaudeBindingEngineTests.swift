import Foundation
import Testing
@testable import AgentSwapCore

private actor BindingEngineAdapter: ProviderAdapter {
    nonisolated let provider = Provider.claude
    let imported: ImportedAccount
    private var restored: Credential?
    init(_ imported: ImportedAccount) { self.imported = imported }
    func registerStoredCredential(_ credential: Credential, account: AccountRecord) {
        if credential.verifiedClaudeAccountIdentity == account.identity, account.id == imported.account.id { restored = credential }
    }
    func compatibility() -> CompatibilityStatus { .supported("fixture") }
    func importCurrent() throws -> ImportedAccount {
        guard restored != nil else { throw AgentSwapError.storage("Fixture authenticated identity not restored") }
        return imported
    }
    func login() throws -> ImportedAccount { throw AgentSwapError.cancelled }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot { .init(windows: []) }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult { .failed(message: "Unexpected fixture activation") }
    func hasRunningConsumers() -> Bool { false }
}

private actor BindingEngineSecrets: SecretStore {
    var values: [UUID: Credential]
    let unreadableID: UUID
    init(values: [UUID: Credential], unreadableID: UUID) { self.values = values; self.unreadableID = unreadableID }
    func load(accountID: UUID) throws -> Credential? {
        guard accountID != unreadableID else { throw AgentSwapError.storage("Fixture unrelated unreadable item") }
        return values[accountID]
    }
    func save(_ credential: Credential, accountID: UUID) { values[accountID] = credential }
    func delete(accountID: UUID) { values.removeValue(forKey: accountID) }
}

@Suite("Claude private identity evidence restoration")
struct ClaudeBindingEngineTests {
    @MainActor @Test("Startup restores the actual owner's proof before native import despite an unreadable unrelated item")
    func startupRestoresOwnerBeforeImport() async throws {
        let owner = AccountRecord(identity: .init(provider: .claude, userID: "fixture-owner", workspaceID: "fixture-organization"))
        let unrelated = AccountRecord(identity: .init(provider: .claude, userID: "fixture-unrelated", workspaceID: "fixture-other-organization"))
        let credential = try CredentialParser.claude(
            rawAuth: ProviderJSON.data(["claudeAiOauth": ["accessToken": "fixture-expired-access", "refreshToken": "fixture-refresh"]]),
            accountMetadata: ProviderJSON.data(["accountUuid": owner.identity.userID, "organizationUuid": owner.identity.workspaceID]))
            .withVerifiedClaudeIdentity(owner.identity)
        let imported = ImportedAccount(account: owner, credential: credential)
        let adapter = BindingEngineAdapter(imported)
        let secrets = BindingEngineSecrets(values: [owner.id: credential], unreadableID: unrelated.id)
        var state = PersistedState()
        state.accounts = [unrelated, owner]; state.activeAccounts[.claude] = unrelated.id
        let model = AppModel(adapters: [adapter], secrets: secrets, store: MemoryState(state))
        await model.start(); model.stop()
        #expect(model.state.activeAccounts[.claude] == owner.id)
        #expect(try await secrets.load(accountID: owner.id)?.verifiedClaudeAccountIdentity == owner.identity)
    }
}
