import Foundation
import CoreFoundation

public protocol CodexConfigurationGuard: Sendable {
    func validateDefaultProfile() throws
}

/// Codex 0.162.0 also loads administrator files and forced com.openai.codex preferences.
/// Their precedence and cloud requirements are outside the v1 local-profile parser, so detection blocks auth access.
public struct SystemCodexConfigurationGuard: CodexConfigurationGuard {
    private let configurationURLs: [URL]
    private let checkManagedPreferences: Bool
    private let files: any AuthFileAccess
    public init(configurationURLs: [URL] = ["/etc/codex/config.toml", "/etc/codex/requirements.toml", "/etc/codex/managed_config.toml"].map { URL(fileURLWithPath: $0) },
                checkManagedPreferences: Bool = true, files: any AuthFileAccess = AtomicAuthFileAccess()) {
        self.configurationURLs = configurationURLs; self.checkManagedPreferences = checkManagedPreferences; self.files = files
    }
    public func validateDefaultProfile() throws {
        for url in configurationURLs {
            if try files.read(url) != nil {
                throw AgentSwapError.unsupported("Codex의 시스템 또는 관리자 설정이 감지되었습니다. v1은 기본 로컬 프로필의 인증만 변경합니다.")
            }
        }
        if checkManagedPreferences {
            let domain = "com.openai.codex" as CFString
            for key in ["config_toml_base64", "requirements_toml_base64"] {
                if CFPreferencesAppValueIsForced(key as CFString, domain) {
                    throw AgentSwapError.unsupported("MDM으로 관리되는 Codex 설정이 감지되어 인증 변경을 중단했습니다.")
                }
            }
        }
    }
}
