import Foundation

public struct ProviderHTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data; self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

public protocol ProviderHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

/// No disk URL cache or cookie store; bearer credentials never follow redirects.
public struct URLSessionProviderTransport: ProviderHTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: ProviderRedirectGuard(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AgentSwapError.network("HTTP 응답을 읽지 못했습니다.") }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String { result[key.lowercased()] = String(describing: item.value) }
            }
            return .init(data: data, statusCode: response.statusCode, headers: headers)
        } catch is CancellationError { throw AgentSwapError.cancelled }
        catch let error as AgentSwapError { throw error }
        catch let error as URLError where error.code == .cancelled { throw AgentSwapError.cancelled }
        catch { throw AgentSwapError.network("서버에 연결하지 못했습니다. 마지막 정상 사용량을 유지합니다.") }
    }
}

private final class ProviderRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderHTTP {
    static func request(_ url: String, token: String? = nil, body: Data? = nil) -> URLRequest {
        // URLs are adapter-owned constants; authentication payloads cannot supply request destinations.
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentSwap/1.0", forHTTPHeaderField: "User-Agent")
        if let body, !body.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    static func checked(_ response: ProviderHTTPResponse, now: Date = Date(), rateLimitKey: ProviderRequestKey? = nil) throws -> Data {
        switch response.statusCode {
        case 200..<300: return response.data
        case 400:
            let object = try? ProviderJSON.object(response.data)
            let details = object?["error"] as? [String: Any]
            // Claude uses both OAuth's string error and its API-style nested type;
            // Codex returns a nested code. Neither body's message is safe to display.
            let code = object?["error"] as? String ?? details?["code"] as? String ?? details?["type"] as? String
            if ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalid"].contains(code ?? "") {
                throw AgentSwapError.authentication("갱신 토큰이 만료되었거나 이미 사용되었습니다. 다시 로그인하세요.")
            }
            throw AgentSwapError.network("서버가 요청을 거부했습니다 (HTTP 400).")
        case 401: throw AgentSwapError.authentication("인증이 만료되었거나 유효하지 않습니다. 다시 로그인하세요.")
        case 403:
            // A valid token may lack a scope, subscription entitlement or organization
            // permission. Refreshing it cannot resolve that denial and needlessly
            // consumes a rotating refresh grant in the engine's authentication retry.
            throw AgentSwapError.network("서버가 이 계정의 요청을 허용하지 않았습니다 (HTTP 403). 계정 권한이나 서비스 이용 상태를 확인해 주세요.")
        case 429:
            let retry: Date
            let source: ProviderRequestRateLimit.Source
            let header = response.headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let header, let seconds = Double(header), seconds.isFinite, seconds > 0,
               now.addingTimeInterval(seconds).timeIntervalSinceReferenceDate.isFinite {
                retry = now.addingTimeInterval(seconds); source = .serverHeader
            } else if let header, let date = httpDate(header), date > now {
                retry = date; source = .serverHeader
            } else {
                retry = now.addingTimeInterval(300); source = .fallback
            }
            if let rateLimitKey {
                throw AgentSwapError.requestRateLimited(.init(key: rateLimitKey, retryAfter: retry, source: source))
            }
            throw AgentSwapError.rateLimited(retry)
        default: throw AgentSwapError.network("사용량 서버가 HTTP \(response.statusCode)를 반환했습니다. 마지막 정상 값을 유지합니다.")
        }
    }
    static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}

/// Actor-owned value state. Each adapter checks this immediately before sending a request;
/// no endpoint or account can clear another request's deadline.
struct ProviderRequestRateLimitGate {
    private var limits: [ProviderRequestKey: ProviderRequestRateLimit] = [:]

    mutating func restore(_ restored: [ProviderRequestRateLimit], provider: Provider, now: Date = Date()) {
        purgeExpired(now: now)
        for limit in restored where limit.key.provider == provider && limit.retryAfter > now {
            retain(limit)
        }
    }

    mutating func active(now: Date = Date()) -> [ProviderRequestRateLimit] {
        purgeExpired(now: now)
        return Array(limits.values)
    }

    mutating func check(_ key: ProviderRequestKey, now: Date = Date()) throws {
        purgeExpired(now: now)
        if let limit = limits[key] { throw AgentSwapError.requestRateLimited(limit) }
    }

    mutating func retain(_ limit: ProviderRequestRateLimit) {
        guard limits[limit.key].map({ $0.retryAfter >= limit.retryAfter }) != true else { return }
        limits[limit.key] = limit
    }

    private mutating func purgeExpired(now: Date) {
        limits = limits.filter { $0.value.retryAfter > now }
    }
}
