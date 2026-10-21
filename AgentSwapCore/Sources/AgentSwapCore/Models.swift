import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public var provider: Provider
    public var userID: String
    public var workspaceID: String
    public init(provider: Provider, userID: String, workspaceID: String) {
        self.provider = provider; self.userID = userID; self.workspaceID = workspaceID
    }
}

public enum AuthenticationState: String, Codable, Sendable { case valid, expired, needsLogin, unsupported }
public struct AccountRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var identity: AccountIdentity
    public var nickname: String
    public var email: String
    public var workspaceName: String
    public var plan: String
    public var createdAt: Date
    public var automaticSwitchEligible: Bool
    public var authenticationState: AuthenticationState
    public var provider: Provider { identity.provider }
    public init(id: UUID = UUID(), identity: AccountIdentity, nickname: String = "", email: String = "", workspaceName: String = "", plan: String = "", createdAt: Date = Date(), automaticSwitchEligible: Bool = false, authenticationState: AuthenticationState = .valid) {
        self.id = id; self.identity = identity; self.nickname = nickname; self.email = email
        self.workspaceName = workspaceName; self.plan = plan; self.createdAt = createdAt
        self.automaticSwitchEligible = automaticSwitchEligible; self.authenticationState = authenticationState
    }
    public var displayName: String { nickname.isEmpty ? (email.isEmpty ? provider.title : email) : nickname }
}

public enum UsageWindowKind: String, Codable, Sendable { case common, model, additional }
public struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var kind: UsageWindowKind
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var duration: TimeInterval?
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    public init(id: String, title: String, kind: UsageWindowKind = .common, usedPercent: Double?, resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.duration = duration
    }
}
public struct UsageExtra: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public init(id: String, title: String, value: String) { self.id = id; self.title = title; self.value = value }
}
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var windows: [UsageWindow]
    public var extras: [UsageExtra]
    public var plan: String?
    public init(fetchedAt: Date = Date(), windows: [UsageWindow], extras: [UsageExtra] = [], plan: String? = nil) {
        self.fetchedAt = fetchedAt; self.windows = windows; self.extras = extras; self.plan = plan
    }
    public var commonWindows: [UsageWindow] { windows.filter { $0.kind == .common } }
    public var minimumRemaining: Double? {
        let values = commonWindows.compactMap(\.remainingPercent)
        return !commonWindows.isEmpty && values.count == commonWindows.count ? values.min() : nil
    }
}
/// The reason for a retry delay is separate from its user-facing error. Older caches
/// have no reason, so their delay cannot safely be treated as a local access failure.
public enum UsageRetryReason: String, Codable, Sendable {
    case serverRateLimit, localFailure, transientFailure
}
public struct UsageCache: Codable, Equatable, Sendable {
    public var snapshot: UsageSnapshot?
    public var attemptedAt: Date?
    public var error: String?
    public var retryAfter: Date?
    public var retryReason: UsageRetryReason?
    public init(snapshot: UsageSnapshot? = nil, attemptedAt: Date? = nil, error: String? = nil, retryAfter: Date? = nil,
                retryReason: UsageRetryReason? = nil) {
        self.snapshot = snapshot; self.attemptedAt = attemptedAt; self.error = error; self.retryAfter = retryAfter
        self.retryReason = retryReason
    }
}
public struct Credential: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var rawAuth: Data
    public var accountMetadata: Data?
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, rawAuth: Data, accountMetadata: Data? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.rawAuth = rawAuth; self.accountMetadata = accountMetadata
    }
}
public struct ImportedAccount: Sendable {
    public var account: AccountRecord
    public var credential: Credential
    public init(account: AccountRecord, credential: Credential) { self.account = account; self.credential = credential }
}
public enum CompatibilityStatus: Equatable, Sendable {
    case supported(String), readOnly(String), unavailable(String)
    public var message: String {
        switch self { case .supported(let s), .readOnly(let s), .unavailable(let s): s }
    }
    public var canWrite: Bool { if case .supported = self { true } else { false } }
}
public enum SwitchResult: Equatable, Sendable {
    case applied(message: String)
    case pendingRelaunch(message: String)
    case failed(message: String)
}
public struct AutomationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var threshold: Double = 90
    public var minimumImprovement: Double = 5
    public var cooldown: TimeInterval = 300
    public var maximumAge: TimeInterval = 660
    public init() {}
}
public struct AppSettings: Codable, Equatable, Sendable {
    public var activePollInterval: TimeInterval = 180
    public var inactivePollInterval: TimeInterval = 600
    public var automation: [Provider: AutomationSettings] = [.claude: .init(), .codex: .init()]
    public init() {}
}
public struct PersistedState: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var accounts: [AccountRecord] = []
    public var activeAccounts: [Provider: UUID] = [:]
    public var usage: [UUID: UsageCache] = [:]
    public var lastSwitch: [Provider: Date] = [:]
    /// Non-secret before-image hashes keep a rotated grant from being overwritten by stale native auth.
    public var pendingNativeRefreshPredecessor: [UUID: String]? = nil
    public var settings: AppSettings = .init()
    public init() {}
}
public enum AgentSwapError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String), authentication(String), storage(String), network(String), rateLimited(Date), cancelled
    public var errorDescription: String? {
        switch self {
        case .unsupported(let s), .authentication(let s), .storage(let s), .network(let s): s
        case .rateLimited: "요청 한도에 도달했습니다. 재시도 시각까지 기다립니다."
        case .cancelled: "로그인이 취소되었습니다."
        }
    }
}
