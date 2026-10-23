import Foundation

public extension AppModel {
    static func live() -> AppModel {
        AppModel(adapters: [ClaudeProviderAdapter(), CodexProviderAdapter()], secrets: KeychainSecretStore(), store: JSONStateStore(),
                 claudeSessions: ClaudeDesktopSessionPreserver(), claudeDesktop: ClaudeDesktopAccountManager(), claudeDesktopProfiles: .live())
    }

    /// In-memory, deterministic fixture mode. Never reads or writes provider authentication.
    static func preview(claudeSessionIncompatible: Bool = false, claudeRecoveryConflict: Bool = false,
                        rateLimited: Bool = false, scopedRateLimited: Bool = false) -> AppModel {
        let now = Date()
        var state = PersistedState()
        let claudePersonal = AccountRecord(identity: .init(provider: .claude, userID: "demo-claude-1", workspaceID: "personal"), nickname: "개인 계정", email: "personal@example.com", workspaceName: "개인 워크스페이스", plan: "Max", createdAt: now.addingTimeInterval(-300), automaticSwitchEligible: true)
        let claudeTeam = AccountRecord(identity: .init(provider: .claude, userID: "demo-claude-2", workspaceID: "team"), nickname: "팀 계정", email: "team@example.com", workspaceName: "디자인 팀", plan: "Team", createdAt: now.addingTimeInterval(-200), automaticSwitchEligible: true)
        let codexPersonal = AccountRecord(identity: .init(provider: .codex, userID: "demo-codex-1", workspaceID: "personal"), nickname: "개인 계정", email: "personal@example.com", workspaceName: "개인 워크스페이스", plan: "Pro", createdAt: now.addingTimeInterval(-100), automaticSwitchEligible: true)
        let codexTeam = AccountRecord(identity: .init(provider: .codex, userID: "demo-codex-2", workspaceID: "team"), nickname: "개발 팀", email: "developer@example.com", workspaceName: "엔지니어링", plan: "Business", createdAt: now, automaticSwitchEligible: true)
        state.accounts = [claudePersonal, claudeTeam, codexPersonal, codexTeam]
        state.activeAccounts = [.claude: claudePersonal.id, .codex: codexPersonal.id]
        let values: [UUID: UsageSnapshot] = [
            claudePersonal.id: .init(windows: [
                .init(id: "five_hour", title: "5시간", usedPercent: 72, resetsAt: now.addingTimeInterval(7800)),
                .init(id: "seven_day", title: "주간", usedPercent: 38, resetsAt: now.addingTimeInterval(350000)),
                .init(id: "sonnet", title: "Sonnet 주간", kind: .model, usedPercent: 24, resetsAt: now.addingTimeInterval(350000))
            ], extras: [.init(id: "extra", title: "추가 사용", value: "꺼짐")]),
            claudeTeam.id: .init(windows: [.init(id: "five_hour", title: "5시간", usedPercent: 18, resetsAt: now.addingTimeInterval(15000)), .init(id: "seven_day", title: "주간", usedPercent: 12, resetsAt: now.addingTimeInterval(420000))]),
            codexPersonal.id: .init(windows: [.init(id: "short", title: "5시간", usedPercent: 91, resetsAt: now.addingTimeInterval(3000)), .init(id: "long", title: "주간", usedPercent: 56, resetsAt: now.addingTimeInterval(200000))], extras: [.init(id: "credits", title: "크레딧", value: "125"), .init(id: "resets", title: "사용 가능한 초기화", value: "2")]),
            codexTeam.id: .init(windows: [.init(id: "short", title: "5시간", usedPercent: 26, resetsAt: now.addingTimeInterval(16000)), .init(id: "long", title: "주간", usedPercent: 43, resetsAt: now.addingTimeInterval(300000))])
        ]
        state.usage = values.mapValues { .init(snapshot: $0, attemptedAt: now) }
        if rateLimited {
            let retry = now.addingTimeInterval(3600)
            state.providerRetryAfter = [.claude: retry]
            state.usage[claudePersonal.id]?.error = AgentSwapError.rateLimited(retry).localizedDescription
            state.usage[claudePersonal.id]?.retryAfter = retry
            state.usage[claudePersonal.id]?.retryReason = .serverRateLimit
        }
        if scopedRateLimited {
            let limit = ProviderRequestRateLimit(key: .credential(provider: .claude, kind: .profile, token: "demo-only-profile"),
                                                 retryAfter: now.addingTimeInterval(300), source: .fallback)
            state.requestRateLimits = [limit]
            state.usage[claudePersonal.id]?.error = AgentSwapError.requestRateLimited(limit).localizedDescription
            state.usage[claudePersonal.id]?.retryAfter = limit.retryAfter
            state.usage[claudePersonal.id]?.retryReason = .serverRateLimit
            state.usage[claudePersonal.id]?.requestRateLimit = limit
        }
        let credential = Credential(accessToken: "demo-only", expiresAt: now.addingTimeInterval(3600), rawAuth: Data())
        let credentials = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, credential) })
        let adapters = Provider.allCases.map { provider in
            DemoProvider(provider: provider, current: state.accounts.first { $0.provider == provider }!, credential: credential, snapshots: values,
                         recoveryConflict: provider == .claude && claudeRecoveryConflict)
        }
        // The legacy session fixture stays attached for journal-recovery UI coverage. Normal
        // Claude switches no longer prepare or inspect Desktop conversations.
        let sessions: (any ClaudeDesktopSessionPreserving)? = claudeSessionIncompatible ? DemoSessionPreserver() : nil
        return AppModel(adapters: adapters, secrets: DemoSecrets(values: credentials), store: DemoState(value: state),
                        claudeSessions: sessions, claudeDesktop: DemoDesktopAccounts(current: claudePersonal))
    }
}

private actor DemoDesktopAccounts: ClaudeDesktopAccountManaging {
    var current: AccountRecord
    var pending: (UUID, AccountRecord)?
    init(current: AccountRecord) { self.current = current }
    func captureCurrent(for account: AccountRecord) throws {
        guard current.identity == account.identity else {
            throw AgentSwapError.authentication("선택한 계정으로 Desktop에 로그인한 뒤 저장해 주세요.")
        }
    }
    func prepareSwitch(target: AccountRecord, registered: [AccountRecord], currentCLI: AccountIdentity?) throws -> UUID {
        guard pending == nil else { throw AgentSwapError.storage("중단된 Desktop 전환을 먼저 복구해 주세요.") }
        let id = UUID(); pending = (id, target); return id
    }
    func verifyCanSwitchCLI(allowing transactionID: UUID?) throws {
        if let pending, pending.0 != transactionID { throw AgentSwapError.storage("중단된 Desktop 전환을 먼저 복구해 주세요.") }
    }
    func finish(transactionID: UUID, cliApplied: Bool) throws -> String {
        guard let pending, pending.0 == transactionID else { throw AgentSwapError.storage("Desktop 준비 기록을 찾지 못했습니다.") }
        if cliApplied { current = pending.1 }
        self.pending = nil
        return cliApplied ? "Desktop 계정과 기존 Code 대화를 연결했습니다. 데모 모드 · 임시 데이터" : "원래 Desktop 계정을 유지했습니다."
    }
    func recover(registered: [AccountRecord], currentCLI: AccountIdentity?) -> String {
        pending = nil; return "Desktop 전환 복구를 완료했습니다. 데모 모드 · 임시 데이터"
    }
    func deleteSnapshot(accountID: UUID) throws {
        guard pending == nil else { throw AgentSwapError.storage("중단된 Desktop 전환을 먼저 복구해 주세요.") }
    }
}

/// Inert legacy session fixture. Authentication-only switching must never call its preparation APIs.
private actor DemoSessionPreserver: ClaudeDesktopSessionPreserving {
    func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation {
        throw ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields)
    }
    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {}
    func verifyCanOpenDesktop() async throws {}
    func finish(_ preparation: ClaudeDesktopSessionPreparation, applied: Bool) async throws -> String? { nil }
}

private actor DemoSecrets: SecretStore {
    var values: [UUID: Credential]
    init(values: [UUID: Credential]) { self.values = values }
    func load(accountID: UUID) -> Credential? { values[accountID] }
    func save(_ credential: Credential, accountID: UUID) { values[accountID] = credential }
    func delete(accountID: UUID) { values.removeValue(forKey: accountID) }
}
private actor DemoState: StateStore {
    var value: PersistedState
    init(value: PersistedState) { self.value = value }
    func load() -> PersistedState { value }
    func save(_ state: PersistedState) { value = state }
}
private actor DemoProvider: ProviderAdapter {
    nonisolated let provider: Provider
    var current: AccountRecord
    let credential: Credential
    let snapshots: [UUID: UsageSnapshot]
    var recoveryConflict: Bool
    init(provider: Provider, current: AccountRecord, credential: Credential, snapshots: [UUID: UsageSnapshot], recoveryConflict: Bool = false) {
        self.provider = provider; self.current = current; self.credential = credential; self.snapshots = snapshots
        self.recoveryConflict = recoveryConflict
    }
    func compatibility() -> CompatibilityStatus {
        recoveryConflict ? .readOnly("중단된 Claude 전환 또는 토큰 갱신의 복원이 필요합니다.") : .supported("데모 모드 · 임시 데이터")
    }
    func importCurrent() throws -> ImportedAccount {
        guard !recoveryConflict else { throw AgentSwapError.storage("중단된 Claude 전환의 복원이 필요합니다.") }
        return .init(account: current, credential: credential)
    }
    func recoverKeepingCurrentLogin(account: AccountRecord) throws -> ImportedAccount {
        guard recoveryConflict, account.id == current.id, account.identity == current.identity,
              KeychainInteraction.mode == .interactive else { throw AgentSwapError.storage("데모 복구 조건이 바뀌었습니다.") }
        recoveryConflict = false
        return .init(account: current, credential: credential)
    }
    func login() throws -> ImportedAccount { throw AgentSwapError.unsupported("데모 모드에서는 실제 로그인을 진행하지 않습니다.") }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) throws -> UsageSnapshot {
        guard !recoveryConflict else { throw AgentSwapError.storage("Claude 인증 복원을 완료한 뒤 갱신해 주세요.") }
        return snapshots[account.id] ?? .init(windows: [])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        current = account; return .applied(message: "데모 계정을 전환했습니다.")
    }
    func hasRunningConsumers() -> Bool { false }
}
