import Foundation

public actor ClaudeProviderAdapter: ProviderAdapter {
    public nonisolated let provider = Provider.claude
    private let authStore: ClaudeAuthStore
    private let transport: any ProviderHTTPTransport
    private let loginRunner: any ProviderLoginRunner
    public init(authStore: ClaudeAuthStore = .init(), transport: any ProviderHTTPTransport = URLSessionProviderTransport(),
                loginRunner: any ProviderLoginRunner = OfficialCLILoginRunner()) {
        self.authStore = authStore; self.transport = transport; self.loginRunner = loginRunner
    }
    public func compatibility() async -> CompatibilityStatus { await authStore.compatibility() }
    public func recoverInterruptedSwitch() async throws { try await authStore.recoverInterruptedSwitch() }
    public func recoverKeepingCurrentLogin(account: AccountRecord) async throws -> ImportedAccount {
        try await authStore.recoverKeepingCurrentLogin(account: account) { credential in
            try await self.identify(credential, forceProfile: true)
        }
    }
    public func deletePreservedRecoveryCredentials(accountID: UUID) async throws {
        try await authStore.deletePreservedRecoveryCredentials(accountID: accountID)
    }
    public func importCurrent() async throws -> ImportedAccount { try await identify(await authStore.read()) }
    public func importCurrentIfPresent() async throws -> ImportedAccount? {
        guard let credential = try await authStore.readIfPresent() else { return nil }
        return try await identify(credential)
    }
    public func login() async throws -> ImportedAccount { try await identify(await loginRunner.login(provider: provider)) }
    public func cancelLogin() async { await loginRunner.cancel() }
    public func canOpenLoginPage() async -> Bool { await loginRunner.canOpenLoginPage() }
    public func openLoginPage() async throws { try await loginRunner.openLoginPage() }
    public func submitLoginCode(_ code: String) async throws { try await loginRunner.submitCode(code) }
    private func identify(_ input: Credential, forceProfile: Bool = false) async throws -> ImportedAccount {
        if !forceProfile, let account = try? ProviderAccountParser.claude(input) { return account }
        var credential = input
        let request = ProviderHTTP.request("https://api.anthropic.com/api/oauth/profile", token: credential.accessToken)
        let profile = try ProviderJSON.object(ProviderHTTP.checked(await transport.send(request)))
        guard let user = profile["account"] as? [String: Any], let org = profile["organization"] as? [String: Any],
              let userID = ProviderJSON.nonempty(user["uuid"]), let orgID = ProviderJSON.nonempty(org["uuid"]) else {
            throw AgentSwapError.unsupported("Claude 프로필 응답에서 계정 식별 정보를 찾지 못했습니다.")
        }
        credential.accountMetadata = try ProviderJSON.data(["accountUuid": userID, "organizationUuid": orgID,
                                                          "emailAddress": user["email"] as? String ?? user["email_address"] as? String ?? "",
                                                          "organizationName": org["name"] as? String ?? ""])
        return try ProviderAccountParser.claude(credential)
    }
    public func refresh(_ credential: Credential, account: AccountRecord) async throws -> Credential {
        try await authStore.refresh(credential, accountID: account.id) { input in
            try await self.refreshToken(input, account: account)
        }
    }
    private func refreshToken(_ credential: Credential, account: AccountRecord) async throws -> Credential {
        guard let refresh = credential.refreshToken else { throw AgentSwapError.authentication("Claude 갱신 토큰이 없습니다. 다시 로그인하세요.") }
        var root = try ProviderJSON.object(credential.rawAuth)
        guard var oauth = root["claudeAiOauth"] as? [String: Any] else { throw AgentSwapError.unsupported("Claude 인증 형식이 변경되었습니다.") }
        let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let clientID: String
        if let stored = oauth["clientId"] {
            guard let value = ProviderJSON.nonempty(stored), !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }) else {
                throw AgentSwapError.unsupported("Claude 로그인 클라이언트의 형식을 확인하지 못했습니다. 다시 로그인하세요.")
            }
            clientID = value
        } else { clientID = defaultClientID }
        let recordedScopes: [String]
        if let stored = oauth["scopes"] {
            guard let values = stored as? [String], values.allSatisfy({ value in
                // OAuth scope tokens are printable ASCII without spaces, quotes or backslashes.
                !value.isEmpty && value.utf8.allSatisfy { $0 == 0x21 || (0x23...0x5B).contains($0) || (0x5D...0x7E).contains($0) }
            }) else { throw AgentSwapError.unsupported("Claude 로그인 권한의 형식을 확인하지 못했습니다. 다시 로그인하세요.") }
            recordedScopes = values
        } else { recordedScopes = [] }
        let scopes: [String]
        if !recordedScopes.isEmpty { scopes = recordedScopes }
        else {
            guard clientID == defaultClientID else {
                throw AgentSwapError.authentication("별도 Claude 로그인 클라이언트의 기존 권한을 확인할 수 없습니다. 다시 로그인하세요.")
            }
            // Claude Code 2.1.296's production client registers the plugins scope as well.
            scopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload", "user:plugins"]
        }
        let body = try ProviderJSON.data(["grant_type": "refresh_token", "refresh_token": refresh,
                                         "client_id": clientID, "scope": scopes.joined(separator: " ")])
        let response = try ProviderJSON.object(ProviderHTTP.checked(await transport.send(ProviderHTTP.request("https://platform.claude.com/v1/oauth/token", body: body))))
        guard let access = ProviderJSON.nonempty(response["access_token"]), let lifetime = ProviderJSON.number(response["expires_in"]), lifetime > 0 else {
            throw AgentSwapError.authentication("Claude 토큰 갱신 응답을 읽지 못했습니다.")
        }
        oauth["accessToken"] = access
        oauth["refreshToken"] = ProviderJSON.nonempty(response["refresh_token"]) ?? refresh
        oauth["expiresAt"] = Date().addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000
        if let scope = response["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        if let lifetime = ProviderJSON.number(response["refresh_token_expires_in"]) { oauth["refreshTokenExpiresAt"] = Date().addingTimeInterval(lifetime).timeIntervalSince1970 * 1_000 }
        root["claudeAiOauth"] = oauth
        return try CredentialParser.claude(rawAuth: ProviderJSON.data(root), accountMetadata: credential.accountMetadata)
    }
    public func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot {
        var request = ProviderHTTP.request("https://api.anthropic.com/api/oauth/usage", token: credential.accessToken)
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try ProviderUsageParser.claude(ProviderHTTP.checked(await transport.send(request)))
    }
    public func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) async -> SwitchResult {
        await apply(credential, account: account, expectedSourceIdentity: nil, expectedSourceAuth: nil)
    }
    public func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool,
                                         saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        do {
            try Task.checkCancellation()
            // A prepared preservation transaction requires a readable, known source.
            // Never silently skip its identity fence when login disappears or a read fails.
            let current = try await importCurrent()
            try Task.checkCancellation()
            try await saveLatest(current)
            try Task.checkCancellation()
            return await apply(credential, account: account, expectedSourceIdentity: current.account.identity,
                               expectedSourceAuth: current.credential.rawAuth)
        } catch { return .failed(message: error.localizedDescription) }
    }
    public func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool,
                                         allowMissingSource: Bool, saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        guard allowMissingSource else {
            return await activatePreservingSource(credential, account: account, relaunch: relaunch, saveLatest: saveLatest)
        }
        do {
            try Task.checkCancellation()
            guard try await authStore.readIfPresent() == nil else {
                throw AgentSwapError.storage("현재 Claude 인증이 존재하거나 조회 이후 생성되었습니다. 현재 계정을 다시 확인한 뒤 전환해 주세요.")
            }
            try Task.checkCancellation()
            return await apply(credential, account: account, expectedSourceIdentity: nil,
                               expectedSourceAuth: nil, expectedSourceAbsent: true)
        } catch { return .failed(message: error.localizedDescription) }
    }
    private func apply(_ credential: Credential, account: AccountRecord,
                       expectedSourceIdentity: AccountIdentity?, expectedSourceAuth: Data?, expectedSourceAbsent: Bool = false) async -> SwitchResult {
        do {
            guard try ProviderAccountParser.claude(credential).account.identity == account.identity else { throw AgentSwapError.authentication("대상 Claude 계정의 인증 정보가 일치하지 않습니다.") }
            try Task.checkCancellation()
            try await authStore.activate(credential, expectedSourceIdentity: expectedSourceIdentity,
                                         expectedSourceAuth: expectedSourceAuth, expectedSourceAbsent: expectedSourceAbsent)
            return .applied(message: "Claude Code CLI 계정을 전환했습니다. Claude 데스크톱 로그인은 별도로 유지됩니다.")
        } catch { return .failed(message: error.localizedDescription) }
    }
    public func hasRunningConsumers() async -> Bool { false }
    public func hasPendingCredentialPersistence() async -> Bool { await authStore.hasPendingCredentialPersistence() }
    public func flushPendingCredentialPersistence() async throws { try await authStore.flushPendingCredentialPersistence() }
    public func takePersistedCredentialGenerations() async -> [PersistedCredentialGeneration] {
        await authStore.takePersistedCredentialGenerations()
    }
    public func discardPendingCredentialPersistence(accountID: UUID) async {
        await authStore.discardPendingCredentialPersistence(accountID: accountID)
    }
}

public actor CodexProviderAdapter: ProviderAdapter {
    public nonisolated let provider = Provider.codex
    private let authStore: CodexAuthStore
    private let transport: any ProviderHTTPTransport
    private let loginRunner: any ProviderLoginRunner
    private let processController: any CodexProcessControlling
    private let terminationTimeout: TimeInterval
    public init(authStore: CodexAuthStore = .init(), transport: any ProviderHTTPTransport = URLSessionProviderTransport(),
                loginRunner: any ProviderLoginRunner = OfficialCLILoginRunner(),
                processController: any CodexProcessControlling = SystemCodexProcessController(), terminationTimeout: TimeInterval = 15) {
        self.authStore = authStore; self.transport = transport; self.loginRunner = loginRunner
        self.processController = processController; self.terminationTimeout = terminationTimeout
    }
    public func compatibility() async -> CompatibilityStatus {
        let status = await authStore.compatibility()
        guard status.canWrite else { return status }
        if let installation = await processController.installation() { return .supported("\(status.message) · 데스크톱 \(installation.version)") }
        return .supported(status.message + " · 데스크톱 앱 미설치")
    }
    public func importCurrent() async throws -> ImportedAccount { try ProviderAccountParser.codex(await authStore.read()) }
    public func importCurrentIfPresent() async throws -> ImportedAccount? {
        try await authStore.readIfPresent().map(ProviderAccountParser.codex)
    }
    public func login() async throws -> ImportedAccount { try ProviderAccountParser.codex(await loginRunner.login(provider: provider)) }
    public func cancelLogin() async { await loginRunner.cancel() }
    public func canOpenLoginPage() async -> Bool { await loginRunner.canOpenLoginPage() }
    public func openLoginPage() async throws { try await loginRunner.openLoginPage() }
    public func submitLoginCode(_ code: String) async throws { try await loginRunner.submitCode(code) }
    public func refresh(_ credential: Credential, account: AccountRecord) async throws -> Credential {
        guard let refresh = credential.refreshToken else { throw AgentSwapError.authentication("Codex 갱신 토큰이 없습니다. 다시 로그인하세요.") }
        let body = try ProviderJSON.data(["grant_type": "refresh_token", "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "refresh_token": refresh])
        let response = try ProviderJSON.object(ProviderHTTP.checked(await transport.send(ProviderHTTP.request("https://auth.openai.com/oauth/token", body: body))))
        guard let access = ProviderJSON.nonempty(response["access_token"]) else { throw AgentSwapError.authentication("Codex 토큰 갱신 응답을 읽지 못했습니다.") }
        var root = try ProviderJSON.object(credential.rawAuth)
        guard var tokens = root["tokens"] as? [String: Any] else { throw AgentSwapError.unsupported("Codex 인증 형식이 변경되었습니다.") }
        tokens["access_token"] = access
        tokens["refresh_token"] = ProviderJSON.nonempty(response["refresh_token"]) ?? refresh
        if let id = ProviderJSON.nonempty(response["id_token"]) { tokens["id_token"] = id }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        var rotated = try CredentialParser.codex(rawAuth: ProviderJSON.data(root))
        if rotated.expiresAt == nil, let lifetime = ProviderJSON.number(response["expires_in"]), lifetime > 0 { rotated.expiresAt = Date().addingTimeInterval(lifetime) }
        guard try ProviderAccountParser.codex(rotated).account.identity == account.identity else { throw AgentSwapError.authentication("갱신된 Codex 토큰의 계정이 일치하지 않아 저장을 중단했습니다.") }
        return rotated
    }
    public func fetchUsage(_ credential: Credential, account: AccountRecord) async throws -> UsageSnapshot {
        var request = ProviderHTTP.request("https://chatgpt.com/backend-api/wham/usage", token: credential.accessToken)
        request.setValue(account.identity.workspaceID, forHTTPHeaderField: "ChatGPT-Account-Id")
        return try ProviderUsageParser.codex(ProviderHTTP.checked(await transport.send(request)))
    }
    public func hasRunningConsumers() async -> Bool {
        let scan = await processController.scan()
        return !scan.reliable || scan.hasConsumers
    }
    public func recoverInterruptedSwitch() async throws {
        guard !(await processController.scan().hasConsumers) else { throw AgentSwapError.storage("Codex CLI·IDE·데스크톱을 모두 종료한 뒤 인증 복원을 다시 시도하세요.") }
        try await authStore.recoverInterruptedSwitch()
    }
    public func activate(_ credential: Credential, account: AccountRecord, relaunch: Bool) async -> SwitchResult {
        await activatePreservingSource(credential, account: account, relaunch: relaunch, saveLatest: { _ in })
    }
    public func activatePreservingSource(_ credential: Credential, account: AccountRecord, relaunch: Bool,
                                         saveLatest: @Sendable (ImportedAccount) async throws -> Void) async -> SwitchResult {
        var desktopStoppedByOperation = false
        var authApplied = false
        do {
            guard try ProviderAccountParser.codex(credential).account.identity == account.identity else { throw AgentSwapError.authentication("대상 Codex 계정의 인증 정보가 일치하지 않습니다.") }
            let status = await authStore.compatibility()
            guard status.canWrite else { throw AgentSwapError.unsupported(status.message) }
            let scan = await processController.scan()
            guard scan.reliable else { return .pendingRelaunch(message: "Codex 프로세스 종료를 확인할 수 없어 전환을 보류했습니다.") }
            var retainPostQuitIdentity: AccountIdentity?
            if scan.hasConsumers {
                guard relaunch else { return .pendingRelaunch(message: "Codex가 실행 중입니다. 전환 및 재실행을 누르거나 CLI·IDE를 종료하세요.") }
                guard scan.consumers.allSatisfy({ $0.kind == .desktop }) else { return .pendingRelaunch(message: "별도로 실행 중인 Codex CLI·IDE·서버를 먼저 종료하세요. 인증은 변경하지 않았습니다.") }
                try Task.checkCancellation()
                let preQuitSource = try await authStore.readIfPresent().map(ProviderAccountParser.codex)
                // An exact match means the caller requested the current native generation. A
                // different same-account credential can be a deliberate pending vault successor.
                if let preQuitSource, preQuitSource.account.identity == account.identity,
                   preQuitSource.credential.rawAuth == credential.rawAuth {
                    retainPostQuitIdentity = preQuitSource.account.identity
                }
                try Task.checkCancellation()
                guard await processController.requestDesktopTermination() else { return .pendingRelaunch(message: "Codex가 정상 종료 요청을 거부했습니다. 인증은 변경하지 않았습니다.") }
                let deadline = Date().addingTimeInterval(terminationTimeout)
                var stopped = false
                repeat {
                    try Task.checkCancellation()
                    let current = await processController.scan()
                    if current.reliable && current.consumers.isEmpty { stopped = true; break }
                    try await Task.sleep(for: .milliseconds(200))
                } while Date() < deadline
                guard stopped else { return .pendingRelaunch(message: "Codex 관련 프로세스 종료를 확인하지 못해 전환을 보류했습니다.") }
                desktopStoppedByOperation = true
            }
            let beforeBackup = await processController.scan()
            guard beforeBackup.reliable, beforeBackup.consumers.isEmpty else {
                return await reopenAfterUnappliedSwitch(.pendingRelaunch(message: "Codex 프로세스가 다시 실행되어 전환을 보류했습니다."),
                                                       stoppedByOperation: desktopStoppedByOperation)
            }
            // This read happens AFTER confirmed graceful shutdown, capturing its last token rotation.
            let source = try await authStore.readIfPresent().map(ProviderAccountParser.codex)
            if let source { try await saveLatest(source) }
            var targetCredential = credential
            if let retainPostQuitIdentity {
                guard let source, source.account.identity == retainPostQuitIdentity else {
                    throw AgentSwapError.storage("Codex 종료 중 현재 로그인 계정이 변경되어 이전 인증의 적용을 중단했습니다.")
                }
                targetCredential = source.credential
            }
            let immediatelyBeforeWrite = await processController.scan()
            guard immediatelyBeforeWrite.reliable, immediatelyBeforeWrite.consumers.isEmpty else {
                return await reopenAfterUnappliedSwitch(.pendingRelaunch(message: "Codex 프로세스가 다시 실행되어 전환을 보류했습니다."),
                                                       stoppedByOperation: desktopStoppedByOperation)
            }
            try Task.checkCancellation()
            try await authStore.activate(targetCredential, expectedSourceAuth: source?.credential.rawAuth,
                                         expectedSourceAbsent: source == nil)
            authApplied = true
            if relaunch {
                do { try await processController.relaunchDesktop() }
                catch { return .applied(message: "Codex 인증을 전환했습니다. 데스크톱 재실행 실패: \(error.localizedDescription)") }
            }
            return .applied(message: relaunch ? "Codex 인증을 전환하고 데스크톱을 재실행했습니다." : "Codex 인증을 전환했습니다.")
        } catch {
            return await reopenAfterUnappliedSwitch(.failed(message: error.localizedDescription),
                                                   stoppedByOperation: desktopStoppedByOperation && !authApplied)
        }
    }
    /// Reopening completes the explicitly requested desktop lifecycle; it never repairs or writes auth.
    private func reopenAfterUnappliedSwitch(_ result: SwitchResult, stoppedByOperation: Bool) async -> SwitchResult {
        guard stoppedByOperation else { return result }
        if case .applied = result { return result }
        // Pending transaction recovery, unsupported storage, and indeterminate Keychain access all block reopening.
        guard await authStore.compatibility().canWrite else { return result }
        let scan = await processController.scan()
        guard scan.reliable, !scan.consumers.contains(where: { $0.kind == .desktop }) else { return result }
        let notice: String
        do {
            try await processController.relaunchDesktop()
            notice = "인증 전환을 적용하지 않고 Codex 데스크톱을 다시 열었습니다."
        } catch {
            notice = "Codex 데스크톱 다시 열기에 실패했습니다: \(error.localizedDescription)"
        }
        switch result {
        case .failed(let message): return .failed(message: message + "\n" + notice)
        case .pendingRelaunch(let message): return .pendingRelaunch(message: message + "\n" + notice)
        case .applied: return result
        }
    }
}
