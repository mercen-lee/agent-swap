import Foundation

public enum CodexStorageMode: String, Sendable, Codable { case file, keychain = "keyring", auto, ephemeral }

/// Supports the direct OS Keychain and default local profile from Codex 0.162.0.
/// Configuration, session databases and histories are never rewritten.
public actor CodexAuthStore {
    public nonisolated let home: URL
    public nonisolated let keychainAccount: String
    public nonisolated static let keychainService = "Codex Auth"
    private let keychain: any KeychainAccess
    private let files: any AuthFileAccess
    private let lockTimeout: TimeInterval
    private let configurationGuard: any CodexConfigurationGuard
    private var authURL: URL { home.appendingPathComponent("auth.json") }
    private var configURL: URL { home.appendingPathComponent("config.toml") }
    private var authLocation: AuthMutation.Location { .keychain(service: Self.keychainService, account: keychainAccount) }
    private var allowedLocations: Set<AuthMutation.Location> { [authLocation, .file(authURL.path)] }
    private var transaction: AuthTransaction {
        .init(identifier: "codex|" + storageDigest(home.path, prefix: 32), keychain: keychain, files: files)
    }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
                keychain: any KeychainAccess = AppVaultKeychainAccess(), files: any AuthFileAccess = AtomicAuthFileAccess(),
                lockTimeout: TimeInterval = 9, configurationGuard: any CodexConfigurationGuard = SystemCodexConfigurationGuard()) {
        self.home = home
        let canonical = FileManager.default.fileExists(atPath: home.path) ? home.resolvingSymlinksInPath().path : home.path
        keychainAccount = "cli|" + storageDigest(canonical, prefix: 16)
        self.keychain = keychain; self.files = files; self.lockTimeout = lockTimeout
        self.configurationGuard = configurationGuard
    }
    public func storageMode() throws -> CodexStorageMode { try configuration().mode }
    private func configuration() throws -> (mode: CodexStorageMode, secrets: Bool) {
        try configurationGuard.validateDefaultProfile()
        guard let data = try files.read(configURL) else { return (.file, false) }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentSwapError.unsupported("Codex 설정 인코딩을 지원하지 않습니다.") }
        var section: [String] = [], arraySection = false
        var mode: CodexStorageMode = .file, secrets = false
        var seenMode = false, seenSecrets = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = try uncomment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                arraySection = line.hasPrefix("[[")
                let brackets = arraySection ? 2 : 1
                let suffix = arraySection ? "]]" : "]"
                guard line.hasSuffix(suffix) else { throw AgentSwapError.unsupported("Codex 설정 테이블의 형식을 확인하지 못했습니다.") }
                section = try settingPath(String(line.dropFirst(brackets).dropLast(brackets)))
                if arraySection, section == ["features"] { throw AgentSwapError.unsupported("Codex features 설정 형식을 지원하지 않습니다.") }
                continue
            }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = try settingPath(String(line[..<equal]))
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key.contains("cli_auth_credentials_store") {
                guard section.isEmpty, key == ["cli_auth_credentials_store"], !seenMode, value.count >= 2,
                      (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'"),
                      let parsed = CodexStorageMode(rawValue: String(value.dropFirst().dropLast())) else {
                    throw AgentSwapError.unsupported("Codex 인증 저장소 설정을 안전하게 해석하지 못했습니다.")
                }
                mode = parsed; seenMode = true
            }
            if key.contains("secret_auth_storage") {
                guard !seenSecrets, !arraySection,
                      (section == ["features"] && key == ["secret_auth_storage"]) || (section.isEmpty && key == ["features", "secret_auth_storage"]),
                      value == "true" || value == "false" else {
                    throw AgentSwapError.unsupported("Codex secrets 저장소 설정을 안전하게 해석하지 못했습니다.")
                }
                secrets = value == "true"; seenSecrets = true
            }
            // A profile can override features; resolving arbitrary TOML/profile layers needs the official loader.
            if section.isEmpty && (key == ["profile"] || key == ["features"] || key == ["auth_keyring_backend"]) {
                throw AgentSwapError.unsupported("별도 Codex 프로필 또는 인증 저장 설정은 v1에서 변경하지 않습니다.")
            }
        }
        if mode == .ephemeral { throw AgentSwapError.unsupported("Codex ephemeral 인증은 메모리 전용이므로 전환할 수 없습니다.") }
        if secrets { throw AgentSwapError.unsupported("Codex의 별도 secrets 인증 저장 방식이 감지되어 쓰기를 중단했습니다.") }
        return (mode, secrets)
    }
    /// Parse bare or quoted TOML key segments without treating a dot inside quotes as a separator.
    /// Auth-sensitive paths accept every TOML whitespace separator; unsupported escaped keys fail closed.
    private func settingPath(_ source: String) throws -> [String] {
        let characters = Array(source)
        var index = 0, result: [String] = []
        func invalid() -> AgentSwapError { .unsupported("Codex 설정 키의 형식을 안전하게 해석하지 못했습니다.") }
        while true {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { throw invalid() }
            var segment = ""
            if characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]; index += 1
                while index < characters.count, characters[index] != quote {
                    guard characters[index] != "\\", !characters[index].isNewline else { throw invalid() }
                    segment.append(characters[index]); index += 1
                }
                guard index < characters.count, characters[index] == quote else { throw invalid() }
                index += 1
            } else {
                while index < characters.count, !characters[index].isWhitespace, characters[index] != "." {
                    let character = characters[index]
                    guard character.isASCII, character.isLetter || character.isNumber || character == "_" || character == "-" else { throw invalid() }
                    segment.append(character); index += 1
                }
                guard !segment.isEmpty else { throw invalid() }
            }
            result.append(segment)
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            if index == characters.count { return result }
            guard characters[index] == "." else { throw invalid() }
            index += 1
        }
    }
    /// Only removes comments outside strings; quoted # characters remain part of configuration values.
    private func uncomment(_ line: String) throws -> String {
        var quote: Character?, escaped = false, result = ""
        for character in line {
            if escaped { result.append(character); escaped = false; continue }
            if quote == "\"", character == "\\" { result.append(character); escaped = true; continue }
            if let current = quote {
                result.append(character)
                if current == character { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; result.append(character)
            } else if character == "#" { break }
            else { result.append(character) }
        }
        return result
    }
    private func validate(_ data: Data) throws {
        let object = try authObject(data, name: "Codex")
        let known: Set<String> = ["auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"]
        guard Set(object.keys).isSubset(of: known),
              object["OPENAI_API_KEY"] == nil || object["OPENAI_API_KEY"] is NSNull,
              let tokens = object["tokens"] as? [String: Any],
              Set(tokens.keys).isSubset(of: ["id_token", "access_token", "refresh_token", "account_id"]) else {
            throw AgentSwapError.unsupported("알 수 없는 Codex 인증 형식 또는 구독 외 인증을 발견해 쓰기를 중단했습니다.")
        }
        if let mode = object["auth_mode"] as? String, mode != "chatgpt" {
            throw AgentSwapError.unsupported("Codex의 구독 로그인만 전환할 수 있습니다.")
        }
        _ = try CredentialParser.codex(rawAuth: data)
    }
    private func currentRawAuth(mode: CodexStorageMode) throws -> Data? {
        switch mode {
        case .file: return try files.read(authURL)
        case .keychain: return try keychain.read(service: Self.keychainService, account: keychainAccount)
        case .auto:
            // An unreadable Keychain may shadow an obsolete file credential. Only confirmed
            // absence permits fallback; an access error cannot establish refresh ownership.
            let stored = try keychain.read(service: Self.keychainService, account: keychainAccount)
            return try stored ?? files.read(authURL)
        case .ephemeral: throw AgentSwapError.unsupported("Codex ephemeral 인증은 지원하지 않습니다.")
        }
    }
    public func read() throws -> Credential {
        guard let credential = try readIfPresent() else { throw AgentSwapError.authentication("Codex에 로그인한 계정이 없습니다.") }
        return credential
    }
    /// Only a genuinely absent authoritative credential is nil; malformed data and access errors throw.
    public func readIfPresent() throws -> Credential? {
        let mode = try configuration().mode
        guard !(try transaction.hasPendingRecovery()) else { throw AgentSwapError.storage("중단된 Codex 전환의 복원이 필요합니다.") }
        guard let raw = try currentRawAuth(mode: mode) else { return nil }
        try validate(raw)
        return try CredentialParser.codex(rawAuth: raw)
    }
    public func compatibility() -> CompatibilityStatus {
        do {
            let mode = try configuration().mode
            if try transaction.hasPendingRecovery() { return .readOnly("중단된 Codex 전환의 복원이 필요합니다.") }
            if let raw = try currentRawAuth(mode: mode) { try validate(raw) }
            return .supported("Codex \(mode == .keychain ? "Keychain" : mode.rawValue) 구독 로그인과 호환됩니다.")
        } catch { return .readOnly(error.localizedDescription) }
    }
    private func lock() throws -> ProviderDirectoryLock {
        // Codex has no external auth write lock. This lock excludes other AgentSwap instances;
        // the provider must confirm all CLI/desktop/IDE consumers have exited before calling activate.
        try ProviderDirectoryLock(url: home.appendingPathComponent(".agentswap-auth.lock"), staleAfter: 60, timeout: lockTimeout)
    }
    public func recoverInterruptedSwitch() throws {
        let lock = try lock(); defer { withExtendedLifetime(lock) {} }
        _ = try configuration()
        try transaction.recover(allowedLocations: allowedLocations)
    }
    public func activate(_ credential: Credential, expectedSourceAuth: Data? = nil, expectedSourceAbsent: Bool = false) throws {
        try Task.checkCancellation()
        guard !(expectedSourceAbsent && expectedSourceAuth != nil) else {
            throw AgentSwapError.storage("Codex 전환의 이전 인증 조건이 일치하지 않습니다.")
        }
        try validate(credential.rawAuth)
        let mode = try configuration().mode
        let lock = try lock(); defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()
        try transaction.recover(allowedLocations: allowedLocations)
        let beforeFile = try files.read(authURL)
        if let beforeFile { try validate(beforeFile) }
        var mutations: [AuthMutation]
        var safeAutoFallback = false
        if mode == .file {
            try verifySource(beforeFile, expected: expectedSourceAuth, absent: expectedSourceAbsent)
            mutations = [.init(location: .file(authURL.path), before: beforeFile, after: credential.rawAuth)]
        } else {
            // A Keychain access error is indeterminate: fail closed rather than leave a shadowing old login.
            let beforeKeychain = try keychain.read(service: Self.keychainService, account: keychainAccount)
            if let beforeKeychain { try validate(beforeKeychain) }
            let authoritative = mode == .auto ? beforeKeychain ?? beforeFile : beforeKeychain
            try verifySource(authoritative, expected: expectedSourceAuth, absent: expectedSourceAbsent)
            safeAutoFallback = mode == .auto && beforeKeychain == nil
            mutations = [.init(location: authLocation, before: beforeKeychain, after: credential.rawAuth)]
            if beforeFile != nil { mutations.append(.init(location: .file(authURL.path), before: beforeFile, after: nil)) }
        }
        try Task.checkCancellation()
        do { try transaction.perform(mutations, checkCancellation: { try Task.checkCancellation() }) { try lock.verify() } }
        catch {
            // A file fallback is safe only after a verified full rollback and an absent shadowing Keychain item.
            try Task.checkCancellation()
            guard safeAutoFallback, !(try transaction.hasPendingRecovery()),
                  try keychain.read(service: Self.keychainService, account: keychainAccount) == nil else { throw error }
            let fallbackSource = try files.read(authURL)
            if let fallbackSource { try validate(fallbackSource) }
            guard fallbackSource == beforeFile else { throw AgentSwapError.storage("Codex 인증이 복원 이후 변경되어 파일 전환을 중단했습니다.") }
            try verifySource(fallbackSource, expected: expectedSourceAuth, absent: expectedSourceAbsent)
            try Task.checkCancellation()
            try transaction.perform([.init(location: .file(authURL.path), before: fallbackSource, after: credential.rawAuth)],
                                    checkCancellation: {
                try Task.checkCancellation()
                // A new Keychain credential would shadow this file. This is a forward check only;
                // rollback must remain able to restore our file while preserving that new item.
                guard try keychain.read(service: Self.keychainService, account: keychainAccount) == nil else {
                    throw AgentSwapError.storage("Codex Keychain 인증이 새로 생성되어 파일 전환을 중단했습니다.")
                }
            }) {
                try lock.verify()
            }
        }
    }
    private func verifySource(_ source: Data?, expected: Data?, absent: Bool) throws {
        if absent, source != nil { throw AgentSwapError.storage("새 Codex 인증이 외부에서 생성되어 전환을 중단했습니다.") }
        if let expected, source != expected { throw AgentSwapError.storage("Codex 인증이 최신 백업 이후 변경되어 전환을 중단했습니다.") }
    }
    public func cleanupIsolatedAuthentication() throws {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard home.standardizedFileURL != defaultHome.standardizedFileURL else {
            throw AgentSwapError.unsupported("기본 Codex 프로필은 로그인 정리 대상으로 사용할 수 없습니다.")
        }
        try keychain.delete(service: Self.keychainService, account: keychainAccount)
        try files.delete(authURL)
    }
}
