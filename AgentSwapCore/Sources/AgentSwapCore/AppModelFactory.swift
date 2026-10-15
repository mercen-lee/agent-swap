import Foundation

public extension AppModel {
    static func live() -> AppModel {
        AppModel(adapters: [ClaudeProviderAdapter(), CodexProviderAdapter()], secrets: KeychainSecretStore(), store: JSONStateStore(),
                 claudeSessions: ClaudeDesktopSessionPreserver())
    }

    /// In-memory, deterministic fixture mode. Never reads or writes provider authentication.
    static func preview(claudeSessionIncompatible: Bool = false) -> AppModel {
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
        let credential = Credential(accessToken: "demo-only", expiresAt: now.addingTimeInterval(3600), rawAuth: Data())
        let credentials = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, credential) })
        let adapters = Provider.allCases.map { provider in
            DemoProvider(provider: provider, current: state.accounts.first { $0.provider == provider }!, credential: credential, snapshots: values)
        }
        let sessions: (any ClaudeDesktopSessionPreserving)? = claudeSessionIncompatible ? DemoSessionPreserver() : nil
        return AppModel(adapters: adapters, secrets: DemoSecrets(values: credentials), store: DemoState(value: state),
                        claudeSessions: sessions)
    }
}

/// Reproduces the preflight-unavailable UI without inspecting Desktop records or processes.
private actor DemoSessionPreserver: ClaudeDesktopSessionPreserving {
    func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation {
        throw ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedRecordFields)
    }
    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {}
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
    init(provider: Provider, current: AccountRecord, credential: Credential, snapshots: [UUID: UsageSnapshot]) {
        self.provider = provider; self.current = current; self.credential = credential; self.snapshots = snapshots
    }
    func compatibility() -> CompatibilityStatus { .supported("데모 모드 · 임시 데이터") }
    func importCurrent() -> ImportedAccount { .init(account: current, credential: credential) }
    func login() throws -> ImportedAccount { throw AgentSwapError.unsupported("데모 모드에서는 실제 로그인을 진행하지 않습니다.") }
    func cancelLogin() {}
    func refresh(_ credential: Credential, account: AccountRecord) -> Credential { credential }
    func fetchUsage(_ credential: Credential, account: AccountRecord) -> UsageSnapshot {
        snapshots[account.id] ?? .init(windows: [])
    }
    func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) -> SwitchResult {
        current = account; return .applied(message: "데모 계정을 전환했습니다.")
    }
    func hasRunningConsumers() -> Bool { false }
}
