import Foundation
import CryptoKit

public enum ProviderRequestKind: String, Codable, Sendable {
    case profile, usage, tokenRefresh

    var title: String {
        switch self {
        case .profile: "계정 확인"
        case .usage: "사용량 조회"
        case .tokenRefresh: "인증 갱신"
        }
    }
}

/// The request that observed a limit, not a claim about the server's internal quota scope.
/// Profile ownership is initially unknown; its subject is a one-way token fingerprint.
public struct ProviderRequestKey: Codable, Hashable, Sendable {
    public let provider: Provider
    public let kind: ProviderRequestKind
    public let subject: String

    private init(provider: Provider, kind: ProviderRequestKind, subject: String) {
        self.provider = provider; self.kind = kind; self.subject = subject
    }

    public static func account(provider: Provider, kind: ProviderRequestKind, accountID: UUID) -> Self {
        .init(provider: provider, kind: kind, subject: "account:" + accountID.uuidString.lowercased())
    }

    public static func credential(provider: Provider, kind: ProviderRequestKind, token: String) -> Self {
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(provider: provider, kind: kind, subject: "credential:" + digest)
    }

    private enum CodingKeys: String, CodingKey { case provider, kind, subject }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(Provider.self, forKey: .provider)
        let kind = try container.decode(ProviderRequestKind.self, forKey: .kind)
        let subject = try container.decode(String.self, forKey: .subject)
        let valid: Bool
        if kind == .profile, subject.hasPrefix("credential:") {
            let digest = subject.dropFirst("credential:".count)
            valid = digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        } else if kind != .profile, subject.hasPrefix("account:") {
            let value = String(subject.dropFirst("account:".count))
            valid = UUID(uuidString: value).map { $0.uuidString.lowercased() == value } ?? false
        } else { valid = false }
        guard valid else {
            throw DecodingError.dataCorruptedError(forKey: .subject, in: container, debugDescription: "Invalid request limit subject")
        }
        self.init(provider: provider, kind: kind, subject: subject)
    }
}

public struct ProviderRequestRateLimit: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case serverHeader, fallback }
    public let key: ProviderRequestKey
    public let retryAfter: Date
    public let source: Source

    public init(key: ProviderRequestKey, retryAfter: Date, source: Source = .serverHeader) {
        self.key = key; self.retryAfter = retryAfter; self.source = source
    }

    var message: String {
        let deadline = retryAfter.formatted(date: .omitted, time: .standard)
        let reason = source == .serverHeader ? "서버가 지정한" : "재시도 시각이 없어 앱이 설정한"
        return "\(key.provider.title) \(key.kind.title) 요청이 제한되었습니다. \(reason) \(deadline)까지 이 요청을 기다립니다."
    }
}
