import Foundation
import CoreFoundation

/// Provider wire formats live here so an unexpected authentication format never reaches a writer.
public enum CredentialParser {
    public static func claude(rawAuth: Data, accountMetadata: Data? = nil) throws -> Credential {
        let root = try ProviderJSON.object(rawAuth)
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = ProviderJSON.nonempty(oauth["accessToken"]) else {
            throw AgentSwapError.unsupported("지원하는 Claude 구독 인증 형식이 아닙니다.")
        }
        return Credential(accessToken: token, refreshToken: ProviderJSON.nonempty(oauth["refreshToken"]),
                          expiresAt: ProviderJSON.date(oauth["expiresAt"], milliseconds: true),
                          rawAuth: rawAuth, accountMetadata: accountMetadata)
    }

    public static func codex(rawAuth: Data) throws -> Credential {
        let root = try ProviderJSON.object(rawAuth)
        guard root["OPENAI_API_KEY"] == nil || root["OPENAI_API_KEY"] is NSNull,
              root["auth_mode"] == nil || root["auth_mode"] as? String == "chatgpt",
              let tokens = root["tokens"] as? [String: Any],
              let access = ProviderJSON.nonempty(tokens["access_token"]),
              ProviderJSON.nonempty(tokens["id_token"]) != nil else {
            throw AgentSwapError.unsupported("지원하는 Codex 구독 인증 형식이 아닙니다. API 키·외부 인증은 제외됩니다.")
        }
        let claims = try? ProviderJSON.jwt(access)
        return Credential(accessToken: access, refreshToken: ProviderJSON.nonempty(tokens["refresh_token"]),
                          expiresAt: claims.flatMap { ProviderJSON.date($0["exp"]) }, rawAuth: rawAuth)
    }
}

public enum ProviderAccountParser {
    public static func claude(_ credential: Credential) throws -> ImportedAccount {
        guard let metadata = credential.accountMetadata else {
            throw AgentSwapError.authentication("Claude 계정 식별 정보가 없습니다. 현재 로그인 가져오기를 다시 실행하세요.")
        }
        let value = try ProviderJSON.object(metadata)
        guard let user = ProviderJSON.nonempty(value["accountUuid"]),
              let workspace = ProviderJSON.nonempty(value["organizationUuid"]) else {
            throw AgentSwapError.unsupported("Claude 계정 및 워크스페이스 ID를 확인할 수 없습니다.")
        }
        let auth = try ProviderJSON.object(credential.rawAuth)["claudeAiOauth"] as? [String: Any]
        let account = AccountRecord(identity: .init(provider: .claude, userID: user, workspaceID: workspace),
                                    email: value["emailAddress"] as? String ?? "",
                                    workspaceName: value["organizationName"] as? String ?? "",
                                    plan: auth?["subscriptionType"] as? String ?? "")
        return ImportedAccount(account: account, credential: credential)
    }

    public static func codex(_ credential: Credential) throws -> ImportedAccount {
        let root = try ProviderJSON.object(credential.rawAuth)
        guard let tokens = root["tokens"] as? [String: Any], let idToken = tokens["id_token"] as? String else {
            throw AgentSwapError.unsupported("Codex 계정 식별 정보가 없습니다.")
        }
        // JWT claims are display/identity metadata from an already imported login, never signature verification.
        let claims = try ProviderJSON.jwt(idToken)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let user = ProviderJSON.nonempty(auth["chatgpt_user_id"]) ?? ProviderJSON.nonempty(auth["user_id"]) ?? ProviderJSON.nonempty(claims["sub"]),
              let workspace = ProviderJSON.nonempty(tokens["account_id"]) ?? ProviderJSON.nonempty(auth["chatgpt_account_id"]) else {
            throw AgentSwapError.unsupported("Codex 사용자 및 워크스페이스 ID를 확인할 수 없습니다.")
        }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let account = AccountRecord(identity: .init(provider: .codex, userID: user, workspaceID: workspace),
                                    email: claims["email"] as? String ?? profile["email"] as? String ?? "",
                                    workspaceName: auth["organization_name"] as? String ?? "",
                                    plan: auth["chatgpt_plan_type"] as? String ?? "")
        return ImportedAccount(account: account, credential: credential)
    }
}

public enum ProviderUsageParser {
    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ProviderJSON.object(data)
        var windows: [UsageWindow] = []
        for key in root.keys.sorted() {
            guard key != "extra_usage" else { continue }
            guard let item = root[key] as? [String: Any], ["five_hour", "seven_day"].contains(key) || item["utilization"] != nil || item["resets_at"] != nil else { continue }
            let kind: UsageWindowKind = ["five_hour", "seven_day"].contains(key) ? .common : .model
            let title = ["five_hour": "5시간", "seven_day": "주간", "seven_day_opus": "Opus 주간", "seven_day_sonnet": "Sonnet 주간"][key] ?? key
            windows.append(.init(id: key, title: title, kind: kind, usedPercent: ProviderJSON.percent(item["utilization"]),
                                 resetsAt: ProviderJSON.date(item["resets_at"]),
                                 duration: key == "five_hour" ? 18_000 : (key.hasPrefix("seven_day") ? 604_800 : nil)))
        }
        // Claude 2.1.296 meters identify common/scoped rows by kind, not their display labels.
        // Recognized modern rows replace their legacy projection, so a common window appears once.
        if let limits = root["limits"] as? [[String: Any]] {
            var modernCommon = Set<String>()
            for (index, item) in limits.enumerated() {
                let meterKind = item["kind"] as? String
                let canonical: String? = meterKind == "session" ? "five_hour" : (meterKind == "weekly_all" ? "seven_day" : nil)
                let percent = ProviderJSON.percent(item["percent"] ?? item["utilization"])
                let reset = ProviderJSON.date(item["resets_at"])
                if let canonical {
                    guard modernCommon.insert(canonical).inserted else {
                        throw AgentSwapError.unsupported("Claude 응답에 중복된 공통 사용 창이 있어 사용량 형식을 확인할 수 없습니다.")
                    }
                    let window = UsageWindow(id: canonical, title: canonical == "five_hour" ? "5시간" : "주간", kind: .common,
                                             usedPercent: percent, resetsAt: reset, duration: canonical == "five_hour" ? 18_000 : 604_800)
                    if let slot = windows.firstIndex(where: { $0.id == canonical }) { windows[slot] = window }
                    else { windows.append(window) }
                    continue
                }
                let id = item["id"] as? String ?? item["kind"] as? String ?? "limit-\(index)"
                let scope = item["scope"] as? [String: Any]
                let modelName = (scope?["model"] as? [String: Any]).flatMap { ProviderJSON.nonempty($0["display_name"]) }
                let surfaceName = (scope?["surface"] as? [String: Any]).flatMap { ProviderJSON.nonempty($0["display_name"]) }
                let kind: UsageWindowKind = meterKind == "weekly_scoped" && modelName != nil ? .model : .additional
                let scopeName = kind == .model ? modelName : surfaceName
                let scopeTitle = scopeName.map { $0 + (meterKind == "weekly_scoped" ? " 주간" : "") }
                windows.append(.init(id: "limits.\(id).\(index)", title: item["display_name"] as? String ?? scopeTitle ?? id, kind: kind,
                                     usedPercent: percent, resetsAt: reset))
            }
        }
        var extras: [UsageExtra] = []
        if let extra = root["extra_usage"] as? [String: Any] {
            for (key, title) in [("is_enabled", "추가 사용"), ("monthly_limit", "추가 사용 월 한도"), ("used_credits", "추가 사용 크레딧"), ("utilization", "추가 사용률")] {
                if let value = ProviderJSON.display(extra[key]) { extras.append(.init(id: key, title: title, value: value)) }
            }
        }
        guard !windows.isEmpty else { throw AgentSwapError.unsupported("Claude 사용량 응답에서 사용 창을 찾지 못했습니다.") }
        return UsageSnapshot(fetchedAt: now, windows: windows, extras: extras)
    }

    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try ProviderJSON.object(data)
        var windows: [UsageWindow] = []
        func append(_ limits: [String: Any], prefix: String, title: String, kind: UsageWindowKind) {
            for key in limits.keys.sorted() {
                guard let item = limits[key] as? [String: Any], key.hasSuffix("_window") || item["used_percent"] != nil || item["reset_at"] != nil else { continue }
                let duration = ProviderJSON.number(item["limit_window_seconds"])
                let label = duration.map { $0 >= 86_400 ? "\(Int($0 / 86_400))일" : "\(Int($0 / 3_600))시간" } ?? key
                windows.append(.init(id: "\(prefix).\(key)", title: "\(title) \(label)", kind: kind,
                                     usedPercent: ProviderJSON.percent(item["used_percent"]),
                                     resetsAt: ProviderJSON.date(item["reset_at"]) ?? ProviderJSON.number(item["reset_after_seconds"]).map { now.addingTimeInterval($0) }, duration: duration))
            }
        }
        if let rate = root["rate_limit"] as? [String: Any] { append(rate, prefix: "rate_limit", title: "구독", kind: .common) }
        // The installed Codex desktop tracks this separately from subscription/feature meters.
        // It is display-only and must never contribute to automatic account selection.
        if let review = root["code_review_rate_limit"] as? [String: Any] {
            append(review, prefix: "code_review_rate_limit", title: "코드 검토", kind: .additional)
        }
        if let additional = root["additional_rate_limits"] as? [[String: Any]] {
            for (index, limit) in additional.enumerated() {
                let name = limit["limit_name"] as? String ?? limit["metered_feature"] as? String ?? "추가 한도"
                if let rate = limit["rate_limit"] as? [String: Any] { append(rate, prefix: "additional.\(index)", title: name, kind: .additional) }
            }
        }
        var extras: [UsageExtra] = []
        for (container, labels) in [("credits", [("balance", "크레딧"), ("unlimited", "무제한 크레딧"), ("has_credits", "크레딧 사용 가능")]),
                                    ("rate_limit_reset_credits", [("available", "사용 가능한 초기화"), ("remaining", "남은 초기화"), ("available_count", "사용 가능한 초기화"), ("count", "초기화 횟수")])] {
            if let values = root[container] as? [String: Any] {
                for (key, title) in labels { if let value = ProviderJSON.display(values[key]) { extras.append(.init(id: "\(container).\(key)", title: title, value: value)) } }
            } else if let value = ProviderJSON.display(root[container]) { extras.append(.init(id: container, title: container == "credits" ? "크레딧" : "사용 가능한 초기화", value: value)) }
        }
        guard !windows.isEmpty else { throw AgentSwapError.unsupported("Codex 사용량 응답에서 사용 창을 찾지 못했습니다.") }
        return UsageSnapshot(fetchedAt: now, windows: windows, extras: extras, plan: root["plan_type"] as? String)
    }
}

enum ProviderJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentSwapError.unsupported("알 수 없는 JSON 형식입니다. 인증 변경을 중단합니다.")
        }
        return object
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func nonempty(_ value: Any?) -> String? { guard let s = value as? String, !s.isEmpty else { return nil }; return s }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func percent(_ value: Any?) -> Double? { guard let n = number(value), (0...100).contains(n) else { return nil }; return n }
    static func date(_ value: Any?, milliseconds: Bool = false) -> Date? {
        if let n = number(value) { return Date(timeIntervalSince1970: milliseconds ? n / 1_000 : n) }
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]; return iso.date(from: s)
    }
    static func jwt(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AgentSwapError.unsupported("Codex ID 토큰 형식을 확인할 수 없습니다.") }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw AgentSwapError.unsupported("Codex ID 토큰을 읽을 수 없습니다.") }
        return try object(data)
    }
    static func display(_ value: Any?) -> String? {
        if let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() { return bool.boolValue ? "사용 가능" : "꺼짐" }
        if let value = value as? String { return value }
        if let value = number(value) { return value.formatted(.number.precision(.fractionLength(0...2))) }
        return nil
    }
}
