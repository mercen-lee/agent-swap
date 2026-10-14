import Foundation
import AppKit
import Darwin

public protocol ProviderLoginRunner: Sendable {
    func login(provider: Provider) async throws -> Credential
    func cancel() async
    func submitCode(_ code: String) async throws
    func canOpenLoginPage() async -> Bool
    func openLoginPage() async throws
}

public extension ProviderLoginRunner {
    func submitCode(_ code: String) async throws {
        throw AgentSwapError.unsupported("이 로그인 방식은 인증 코드 입력을 지원하지 않습니다.")
    }
    func canOpenLoginPage() async -> Bool { false }
    func openLoginPage() async throws {
        throw AgentSwapError.unsupported("이 로그인 방식은 로그인 페이지를 직접 열 수 없습니다.")
    }
}

public protocol ProviderLoginURLOpening: Sendable {
    func open(_ url: URL) async throws
}

public struct SystemProviderLoginURLOpener: ProviderLoginURLOpening {
    public init() {}
    public func open(_ url: URL) async throws {
        try Task.checkCancellation()
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw AgentSwapError.authentication("로그인 페이지를 열지 못했습니다. 기본 브라우저 설정을 확인해 주세요.")
        }
    }
}

/// Official CLIs are used only for the browser login flow, in a private temporary profile.
public actor OfficialCLILoginRunner: ProviderLoginRunner {
    private let claudeExecutable: URL?
    private let codexExecutable: URL?
    private let keychain: any KeychainAccess
    private let urlOpener: any ProviderLoginURLOpening
    private var process: Process?
    private var inputWriter: FileHandle?
    private var cancelled = false
    private var fallbackLoginURL: URL?
    private var loginGeneration: UUID?
    private var openingLoginPage = false
    public init(claudeExecutable: URL? = nil, codexExecutable: URL? = nil, keychain: any KeychainAccess = ClaudeKeychainAccess(),
                urlOpener: any ProviderLoginURLOpening = SystemProviderLoginURLOpener()) {
        self.claudeExecutable = claudeExecutable; self.codexExecutable = codexExecutable
        self.keychain = keychain
        self.urlOpener = urlOpener
    }
    public func login(provider: Provider) async throws -> Credential {
        guard process == nil else { throw AgentSwapError.authentication("이미 로그인 창이 열려 있습니다.") }
        cancelled = false
        fallbackLoginURL = nil
        openingLoginPage = false
        loginGeneration = UUID()
        defer { fallbackLoginURL = nil; loginGeneration = nil; openingLoginPage = false }
        let executable = try Self.findExecutable(provider, override: provider == .claude ? claudeExecutable : codexExecutable)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwap-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cli = Process()
        cli.executableURL = executable
        cli.currentDirectoryURL = profile
        cli.arguments = provider == .claude ? ["auth", "login", "--claudeai"] : ["login", "-c", "cli_auth_credentials_store=\"file\"", "-c", "features.secret_auth_storage=false"]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key.hasPrefix("CODEX_") || key.hasPrefix("OPENAI_") {
            environment.removeValue(forKey: key)
        }
        environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = profile.path
        // Neither project hooks nor inherited external credential commands participate in login.
        environment["PWD"] = profile.path
        cli.environment = environment
        let input = Pipe()
        cli.standardInput = input
        // Only this actor owns the input writer. Suppress SIGPIPE if the CLI exits between
        // validation and a submitted code write; FileHandle reports the failed write instead.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let outputURL = profile.appendingPathComponent("login-output")
        FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        cli.standardOutput = output
        cli.standardError = output
        process = cli
        inputWriter = input.fileHandleForWriting
        defer { closeInput() }
        do {
            try cli.run()
            let deadline = Date().addingTimeInterval(600)
            while cli.isRunning {
                if cancelled || Task.isCancelled { cli.terminate(); throw AgentSwapError.cancelled }
                guard Date() < deadline else { cli.terminate(); throw AgentSwapError.authentication("로그인 대기 시간이 만료되었습니다. 다시 시도하세요.") }
                // Claude 2.1.296 opens the localhost-callback URL itself, while printing
                // a different manual-code URL. Keep the printed fallback only for an
                // explicit user action; opening it automatically starts a second flow.
                if let data = try? Data(contentsOf: outputURL), data.count < 1_048_576,
                   let text = String(data: data, encoding: .utf8) {
                    fallbackLoginURL = Self.loginPageURL(text, provider: provider)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard !cancelled else { throw AgentSwapError.cancelled }
            guard cli.terminationStatus == 0 else { throw AgentSwapError.authentication("공식 CLI의 브라우저 로그인이 완료되지 않았습니다. 다시 시도하세요.") }
            let credential: Credential
            if provider == .claude { credential = try await ClaudeAuthStore(configDirectory: profile, keychain: keychain).read() }
            else { credential = try await CodexAuthStore(home: profile, keychain: keychain).read() }
            try await cleanup(profile: profile, provider: provider, cli: cli)
            process = nil
            return credential
        } catch {
            fallbackLoginURL = nil
            if cli.isRunning { cli.terminate() }
            // An independent task intentionally finishes cleanup even if the caller was cancelled.
            // All Process state remains owned by this actor; no user authentication process is touched.
            do {
                try await Task {
                    try await KeychainInteraction.$mode.withValue(.noninteractive) {
                        try await self.cleanup(profile: profile, provider: provider, cli: cli)
                    }
                }.value
            } catch {
                process = nil
                throw AgentSwapError.storage("임시 인증 정리를 완료하지 못해 이 프로필의 인증 자료를 보존했습니다. 보호된 임시 자료 위치: \(profile.path). Keychain 접근 권한을 확인한 뒤 정리가 필요합니다.")
            }
            process = nil
            if error is CancellationError { throw AgentSwapError.cancelled }
            throw error
        }
    }
    public func cancel() async {
        cancelled = true
        fallbackLoginURL = nil
        closeInput()
        if let process, process.isRunning { process.terminate() }
    }
    public func submitCode(_ code: String) async throws {
        guard !code.contains("\n"), !code.contains("\r"), !code.contains("\0"), code.utf8.count <= 16_384 else {
            throw AgentSwapError.authentication("인증 코드는 줄바꿈 없이 한 줄로 입력해 주세요.")
        }
        let value = code.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw AgentSwapError.authentication("브라우저에 표시된 인증 코드를 입력해 주세요.") }
        guard !cancelled, let process, process.isRunning, let writer = inputWriter else {
            throw AgentSwapError.authentication("진행 중인 로그인이 없습니다. 새 로그인을 시작해 주세요.")
        }
        do { try writer.write(contentsOf: Data((value + "\n").utf8)) }
        catch { throw AgentSwapError.authentication("인증 코드를 로그인 프로세스에 전달하지 못했습니다. 다시 로그인해 주세요.") }
    }
    public func canOpenLoginPage() async -> Bool { hasLoginPage() }
    private func hasLoginPage() -> Bool {
        !cancelled && process?.isRunning == true && fallbackLoginURL != nil
    }
    public func openLoginPage() async throws {
        guard !openingLoginPage else {
            throw AgentSwapError.authentication("로그인 페이지를 여는 중입니다.")
        }
        guard hasLoginPage(), let url = fallbackLoginURL, let generation = loginGeneration else {
            throw AgentSwapError.authentication("열 수 있는 로그인 페이지가 없습니다. 새 로그인을 시작해 주세요.")
        }
        openingLoginPage = true
        defer { if loginGeneration == generation { openingLoginPage = false } }
        do { try await urlOpener.open(url) }
        catch is CancellationError { throw AgentSwapError.cancelled }
        catch {
            // Browser errors must not include the authorization URL or its state.
            throw AgentSwapError.authentication("로그인 페이지를 열지 못했습니다. 기본 브라우저 설정을 확인해 주세요.")
        }
        guard loginGeneration == generation, hasLoginPage() else { throw AgentSwapError.cancelled }
    }
    private func closeInput() {
        try? inputWriter?.close()
        inputWriter = nil
    }
    private func cleanup(profile: URL, provider: Provider, cli: Process) async throws {
        let deadline = Date().addingTimeInterval(2)
        while cli.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if cli.isRunning { _ = Darwin.kill(cli.processIdentifier, SIGKILL) }
        let forceDeadline = Date().addingTimeInterval(3)
        while cli.isRunning && Date() < forceDeadline { try await Task.sleep(for: .milliseconds(100)) }
        guard !cli.isRunning else { throw AgentSwapError.storage("로그인 프로세스가 아직 종료되지 않아 정리를 보류했습니다.") }
        if provider == .claude { try await ClaudeAuthStore(configDirectory: profile, keychain: keychain).cleanupIsolatedAuthentication() }
        if FileManager.default.fileExists(atPath: profile.path) { try FileManager.default.removeItem(at: profile) }
    }
    static func loginURLs(_ text: String, provider: Provider) -> [URL] {
        guard let expression = try? NSRegularExpression(pattern: "https://[^\\s\\u001B<>\\\"]+") else { return [] }
        let allowed: Set<String> = provider == .claude ? ["claude.ai", "claude.com", "platform.claude.com", "console.anthropic.com"] : ["auth.openai.com", "chatgpt.com"]
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                  url.scheme == "https", let host = url.host?.lowercased(), allowed.contains(host),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  url.path.contains("authorize") || url.path.contains("device") else { return nil }
            return url
        }
    }
    static func loginPageURL(_ text: String, provider: Provider) -> URL? {
        // Prefer the CLI's explicitly labeled manual fallback over unrelated or
        // repeated authorization URLs in diagnostics. Choose one destination only.
        let marker = "If the browser didn't open, visit:"
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: marker) else { continue }
            let remainder = String(line[range.upperBound...])
            if let url = loginURLs(remainder, provider: provider).first { return url }
            if remainder.trimmingCharacters(in: .whitespaces).isEmpty, index + 1 < lines.count,
               let url = loginURLs(lines[index + 1], provider: provider).first { return url }
        }
        return loginURLs(text, provider: provider).first
    }
    private static func findExecutable(_ provider: Provider, override: URL?) throws -> URL {
        if let override, FileManager.default.isExecutableFile(atPath: override.path) { return override }
        let name = provider.rawValue
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if provider == .codex {
            let candidate = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw AgentSwapError.unsupported("공식 \(provider.title) CLI를 찾지 못했습니다. CLI를 설치한 뒤 다시 로그인하세요.")
    }
}
