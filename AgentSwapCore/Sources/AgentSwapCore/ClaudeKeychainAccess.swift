import Foundation
import Security
import Darwin
import CryptoKit

/// Transactions check both the forward and rollback representations before changing any store.
protocol KeychainWritePreflighting: KeychainAccess {
    func validateWrite(_ data: Data, service: String, account: String) throws
}

struct NativeSecurityOutput: Sendable {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data
    init(exitStatus: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitStatus = exitStatus; self.stdout = stdout; self.stderr = stderr
    }
}

protocol NativeSecurityRunning: Sendable {
    func run(input: Data, timeout: TimeInterval) throws -> NativeSecurityOutput
}

protocol NativeSwiftKeychainWriting: Sendable {
    func validateAvailability() throws
    func write(_ data: Data, service: String, account: String,
               interactionAllowed: Bool, timeout: TimeInterval) throws -> OSStatus
}

protocol NativeKeychainLockChecking: Sendable {
    func isUnlocked() throws -> Bool
}

/// Byte-journal recovery must remain possible after cancellation of a forward operation.
enum NativeSecurityCancellation {
    @TaskLocal static var permitsRecovery = false
}

private struct DefaultNativeKeychainLockStatus: NativeKeychainLockChecking {
    func isUnlocked() throws -> Bool {
        var keychain: SecKeychain?
        let copied = SecKeychainCopyDefault(&keychain)
        guard copied == errSecSuccess, let keychain else { throw nativeSecurityPermissionError() }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { throw nativeSecurityPermissionError() }
        return status & UInt32(kSecUnlockStateStatus) != 0
    }
}

/// Only Claude's native credential service uses Apple's reader/writer identity.
/// Application records delegate to their fixed service; Codex native credentials
/// retain the native Swift Security store.
public struct ClaudeKeychainAccess: KeychainAccess, KeychainWritePreflighting {
    private let fallback: any KeychainAccess
    private let runner: any NativeSecurityRunning
    private let swiftWriter: any NativeSwiftKeychainWriting
    private let lockStatus: any NativeKeychainLockChecking
    private let interactionGate: KeychainInteractionGate

    public init() {
        self.init(fallback: AppVaultKeychainAccess(), runner: SystemNativeSecurityRunner(),
                  lockStatus: DefaultNativeKeychainLockStatus())
    }
    init(fallback: any KeychainAccess, runner: any NativeSecurityRunning,
         lockStatus: any NativeKeychainLockChecking, interactionGate: KeychainInteractionGate = .system,
         swiftWriter: any NativeSwiftKeychainWriting = SystemNativeSwiftKeychainWriter()) {
        self.fallback = fallback; self.runner = runner; self.lockStatus = lockStatus
        self.interactionGate = interactionGate
        self.swiftWriter = swiftWriter
    }

    public func read(service: String, account: String) throws -> Data? {
        guard try NativeSecurityCommand.isNativeService(service) else {
            return try fallback.read(service: service, account: account)
        }
        let input = try NativeSecurityCommand.read(service: service, account: account)
        return try perform(input: input) { output in
            if output.exitStatus == 44, output.stdout.isEmpty { return nil }
            guard output.exitStatus == 0, output.stderr.isEmpty else { throw nativeSecurityPermissionError() }
            // A hexadecimal API key is still a literal string. Only credential JSON has an
            // unambiguous structured representation; this legacy service is detection-only.
            return try NativeSecurityCommand.passwordData(output.stdout, interpretHex: service != "Claude Code")
        }
    }

    func validateWrite(_ data: Data, service: String, account: String) throws {
        guard try NativeSecurityCommand.isNativeService(service) else {
            if let preflight = fallback as? any KeychainWritePreflighting {
                try preflight.validateWrite(data, service: service, account: account)
            }
            return
        }
        if try NativeSecurityCommand.requiresSwiftWriter(data, service: service, account: account) {
            try swiftWriter.validateAvailability()
        } else {
            _ = try NativeSecurityCommand.write(data, service: service, account: account)
        }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        guard try NativeSecurityCommand.isNativeService(service) else {
            try fallback.write(data, service: service, account: account); return
        }
        // Both images are preflighted by the transaction before mutation. Large records use
        // binary stdin to an Apple-signed Swift interpreter, with the same CLI reader verifying
        // the result; no shared OAuth/MCP/plugin fields need to be removed to fit a command line.
        if try NativeSecurityCommand.requiresSwiftWriter(data, service: service, account: account) {
            try swiftWriter.validateAvailability()
            try interactionGate.perform {
                let interactive = KeychainInteraction.mode == .interactive
                if !interactive, !(try lockStatus.isUnlocked()) { throw nativeSecurityPermissionError() }
                let status = try swiftWriter.write(data, service: service, account: account,
                                                   interactionAllowed: interactive,
                                                   timeout: interactive ? 120 : 30)
                guard status == errSecSuccess else { throw nativeSecurityPermissionError() }
                let output = try runner.run(input: NativeSecurityCommand.read(service: service, account: account),
                                            timeout: interactive ? 120 : 2)
                try verifyWrite(data, output: output)
            }
            return
        }
        let input = try NativeSecurityCommand.write(data, service: service, account: account)
        try perform(input: input) { output in
            // Interactive security exits with the LAST command's status. A successful final
            // find cannot hide a failed update; stderr and exact data readback are also checked.
            try verifyWrite(data, output: output)
        }
    }

    public func delete(service: String, account: String) throws {
        guard try NativeSecurityCommand.isNativeService(service) else {
            try fallback.delete(service: service, account: account); return
        }
        let input = try NativeSecurityCommand.delete(service: service, account: account)
        try perform(input: input) { output in
            // The final find deliberately returns errSecItemNotFound (exit code 44).
            // The preceding delete always prints item attributes even with -q. They stay in
            // the bounded private capture; their presence is not evidence that the item remains.
            guard output.exitStatus == 44 else { throw nativeSecurityPermissionError() }
        }
    }

    private func perform<T>(input: Data, operation: (NativeSecurityOutput) throws -> T) throws -> T {
        try interactionGate.perform {
            if KeychainInteraction.mode == .noninteractive, !(try lockStatus.isUnlocked()) {
                throw nativeSecurityPermissionError()
            }
            // SecurityTool has no public interaction-off switch. The parent's legacy policy
            // does NOT propagate across exec; background operations are bounded, not prompt-free.
            let timeout: TimeInterval = KeychainInteraction.mode == .interactive ? 120 : 2
            return try operation(runner.run(input: input, timeout: timeout))
        }
    }

    private func verifyWrite(_ data: Data, output: NativeSecurityOutput) throws {
        var literal = data; literal.append(10)
        guard output.exitStatus == 0, output.stderr.isEmpty else { throw nativeSecurityPermissionError() }
        if output.stdout != literal,
           try NativeSecurityCommand.passwordData(output.stdout) != data { throw nativeSecurityPermissionError() }
    }
}

enum NativeSecurityCommand {
    static let maximumCredentialBytes = 1_024 * 1_024
    static let maximumCLIReaderOutputBytes = 1_000_000
    private static let credentialsService = "Claude Code-credentials"

    static func isNativeService(_ service: String) throws -> Bool {
        if service == "Claude Code" || service == credentialsService { return true }
        if service.hasPrefix(credentialsService) {
            let prefix = credentialsService + "-"
            guard service.hasPrefix(prefix) else { throw unsupported() }
            let suffix = service.dropFirst(prefix.count)
            guard suffix.count == 8, suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw unsupported()
            }
            return true
        }
        return false
    }

    static func read(service: String, account: String) throws -> Data {
        try validate(service: service, account: account, writing: false)
        return try line("find-generic-password -a \(quote(account)) -s \(quote(service)) -w")
    }
    static func write(_ data: Data, service: String, account: String) throws -> Data {
        try validate(service: service, account: account, writing: true)
        guard !data.isEmpty else { throw unsupported() }
        let prefix = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X "
        guard data.count <= (4_094 - prefix.utf8.count) / 2 else { throw oversized() }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        var input = try line(prefix + hex)
        input.append(try read(service: service, account: account))
        return input
    }
    static func requiresSwiftWriter(_ data: Data, service: String, account: String) throws -> Bool {
        try validate(service: service, account: account, writing: true)
        guard !data.isEmpty else { throw unsupported() }
        guard data.count <= maximumCredentialBytes else {
            throw AgentSwapError.unsupported("Claude 인증 자료가 지원하는 1 MiB 저장 크기를 초과합니다. 원본을 변경하지 않았습니다.")
        }
        // Claude Code's synchronous security reader sets maxBuffer: 1e6. SecurityTool emits
        // printable ASCII literally, but ANY nonprintable byte makes the whole password hex.
        // Include its final LF so forward and rollback images remain readable by the CLI.
        let printable = data.allSatisfy { (32...126).contains($0) }
        let outputBytes = (printable ? data.count : 2 * data.count) + 1
        guard outputBytes <= maximumCLIReaderOutputBytes else {
            throw AgentSwapError.unsupported("Claude 인증 자료가 Claude CLI의 인증 읽기 한도를 초과합니다. 원본을 변경하지 않았습니다.")
        }
        let prefix = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X "
        return data.count > (4_094 - prefix.utf8.count) / 2
    }

    static func delete(service: String, account: String) throws -> Data {
        try validate(service: service, account: account, writing: true)
        var input = try line("delete-generic-password -a \(quote(account)) -s \(quote(service))")
        input.append(try read(service: service, account: account))
        return input
    }
    private static func validate(service: String, account: String, writing: Bool) throws {
        guard try isNativeService(service), !writing || service != "Claude Code",
              !account.isEmpty, account.utf8.count <= 256,
              account.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || $0 == 46 || $0 == 95 || $0 == 45 }) else { throw unsupported() }
    }
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func line(_ command: String) throws -> Data {
        guard command.utf8.count <= 4_094, command.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw oversized()
        }
        return Data((command + "\n").utf8)
    }

    static func passwordData(_ output: Data, interpretHex: Bool = true) throws -> Data {
        // security -w emits precisely the password plus LF. Any nonprintable byte changes the
        // representation to lowercase hex. Keep the original bytes for schema validation.
        guard output.last == 10 else { throw nativeSecurityPermissionError() }
        let value = output.dropLast()
        guard !value.isEmpty, !value.contains(10), !value.contains(13), !value.contains(0) else {
            throw nativeSecurityPermissionError()
        }
        if interpretHex, value.count.isMultiple(of: 2), value.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            var data = Data(); data.reserveCapacity(value.count / 2)
            var iterator = value.makeIterator()
            while let high = iterator.next(), let low = iterator.next() {
                func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
                data.append(nibble(high) << 4 | nibble(low))
            }
            return data
        }
        guard value.allSatisfy({ (32...126).contains($0) }) else { throw nativeSecurityPermissionError() }
        return Data(value)
    }
    private static func unsupported() -> AgentSwapError {
        .unsupported("지원하지 않는 Claude Keychain 항목이므로 변경을 중단했습니다.")
    }
    private static func oversized() -> AgentSwapError {
        .unsupported("Claude 인증 자료가 운영체제 저장 도구의 안전한 입력 길이를 초과합니다. 원본을 변경하지 않았습니다.")
    }
}

struct SystemNativeSecurityRunner: NativeSecurityRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/security")
    static let arguments = ["-i", "-q"]
    func run(input: Data, timeout: TimeInterval) throws -> NativeSecurityOutput {
        guard input.count <= 8_192, timeout > 0, timeout <= 120 else { throw nativeSecurityPermissionError() }
        return try Self.execute(executableURL: Self.executableURL, arguments: Self.arguments,
                                input: input, timeout: timeout)
    }

    static func execute(executableURL: URL, arguments: [String], input: Data,
                        timeout: TimeInterval) throws -> NativeSecurityOutput {
        guard input.count <= 1_500_000, timeout > 0, timeout <= 120 else { throw nativeSecurityPermissionError() }
        if !NativeSecurityCancellation.permitsRecovery { try Task.checkCancellation() }
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executableURL; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let capture = NativeSecurityCapture(), drained = DispatchGroup()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do { try process.run() } catch { throw nativeSecurityPermissionError() }
        for (handle, stream) in [(stdout.fileHandleForReading, NativeSecurityCapture.Stream.stdout),
                                  (stderr.fileHandleForReading, .stderr)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { drained.leave() }
                capture.drain(handle, stream: stream)
            }
        }
        do {
            try writeInput(input, to: stdin.fileHandleForWriting, deadline: deadline, capture: capture)
            try stdin.fileHandleForWriting.close()
        } catch {
            try? stdin.fileHandleForWriting.close()
            terminate(process)
            _ = drained.wait(timeout: .now() + 1)
            if !NativeSecurityCancellation.permitsRecovery && Task.isCancelled { throw CancellationError() }
            throw nativeSecurityPermissionError()
        }
        while process.isRunning {
            if (!NativeSecurityCancellation.permitsRecovery && Task.isCancelled) || capture.hasFailed || ProcessInfo.processInfo.systemUptime >= deadline {
                terminate(process)
                _ = drained.wait(timeout: .now() + 1)
                if !NativeSecurityCancellation.permitsRecovery && Task.isCancelled { throw CancellationError() }
                throw nativeSecurityPermissionError()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // isRunning became false only after Foundation reaped the child. Drain both pipes before
        // examining any output; never include captured diagnostic text in an error or log.
        guard drained.wait(timeout: .now() + 1) == .success, !capture.hasFailed else {
            throw nativeSecurityPermissionError()
        }
        return capture.output(exitStatus: process.terminationStatus)
    }
    private static func writeInput(_ input: Data, to handle: FileHandle, deadline: TimeInterval,
                            capture: NativeSecurityCapture) throws {
        let fd = handle.fileDescriptor, flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw nativeSecurityPermissionError() }
        try input.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                if !NativeSecurityCancellation.permitsRecovery { try Task.checkCancellation() }
                guard !capture.hasFailed, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw nativeSecurityPermissionError()
                }
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count == -1, errno == EINTR { continue }
                if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.005); continue
                }
                throw nativeSecurityPermissionError()
            }
        }
    }
    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
    }
}

struct NativeSwiftKeychainRequest: Encodable {
    let service: String
    let account: String
    let data: Data
    let interactionAllowed: Bool
}

struct SystemNativeSwiftKeychainWriter: NativeSwiftKeychainWriting {
    func validateAvailability() throws {
        _ = try ClaudeSwiftToolchain.resolve()
        _ = try Self.helperURL()
    }

    func write(_ data: Data, service: String, account: String,
               interactionAllowed: Bool, timeout: TimeInterval) throws -> OSStatus {
        _ = try NativeSecurityCommand.requiresSwiftWriter(data, service: service, account: account)
        let toolchain = try ClaudeSwiftToolchain.resolve()
        let helper = try Self.helperURL()
        let input = try Self.requestData(data, service: service, account: account, interactionAllowed: interactionAllowed)
        let arguments = ["-interpret", "-sdk", toolchain.sdkURL.path,
                         "-module-cache-path", try Self.moduleCacheDirectory().path, helper.path]
        let result = try SystemNativeSecurityRunner.execute(executableURL: toolchain.executableURL,
                                                           arguments: arguments, input: input, timeout: timeout)
        // Swift emits compiler deprecation diagnostics for legacy public Keychain APIs. These
        // remain private, bounded capture. The helper's only stdout is one numeric OSStatus.
        guard result.exitStatus == 0, result.stdout.count <= 16,
              let line = String(data: result.stdout, encoding: .utf8), line.last == "\n",
              let status = OSStatus(line.dropLast()), String(status) + "\n" == line else {
            throw nativeSecurityPermissionError()
        }
        return status
    }

    static func requestData(_ data: Data, service: String, account: String, interactionAllowed: Bool) throws -> Data {
        _ = try NativeSecurityCommand.requiresSwiftWriter(data, service: service, account: account)
        let encoder = JSONEncoder()
        // Base64 can contain '/'. Escaping every slash would nearly double its size and violate
        // the preflighted 1 MiB Data contract for an otherwise supported rollback image.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let input = try encoder.encode(NativeSwiftKeychainRequest(service: service, account: account,
                                                                 data: data, interactionAllowed: interactionAllowed))
        guard input.count <= 1_500_000 else { throw nativeSecurityPermissionError() }
        return input
    }

    // Update together with the immutable resource. The toolchain's Apple signature alone does
    // not authenticate the Swift source that will receive credential stdin.
    static let helperResourceDigest = "388cda818ce853e4ea2f573f47f3cf6b2d34562d9733fec33e6b8b0af7b68f15"
    static func verifyHelperData(_ data: Data) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == helperResourceDigest else {
            throw AgentSwapError.unsupported("Claude 인증 저장 helper가 배포된 코드와 달라 원본 변경을 중단했습니다.")
        }
    }

    static func helperURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "ClaudeKeychainWriter", withExtension: "swift") else {
            throw AgentSwapError.unsupported("Claude 인증 저장 helper가 없어 원본 변경을 중단했습니다.")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size < 32_768 else { throw nativeSecurityPermissionError() }
        try verifyHelperData(Data(contentsOf: url))
        return url
    }

    private static func moduleCacheDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw nativeSecurityPermissionError()
        }
        var directory = caches
        for component in ["net.mercen.agentswap", "ClaudeSwiftModules"] {
            directory.appendPathComponent(component, isDirectory: true)
            if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw nativeSecurityPermissionError() }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw nativeSecurityPermissionError() }
        }
        // The Swift compiler caches only this immutable source's imported system modules;
        // stdin is read at execution time and never becomes a compiler input or a file.
        return directory
    }
}

/// Each pipe has one reader. This lock protects the shared size budget and captured buffers only;
/// no Security API, actor suspension or process wait occurs under it.
private final class NativeSecurityCapture: @unchecked Sendable {
    enum Stream: Sendable { case stdout, stderr }
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data(), failed = false
    var hasFailed: Bool { lock.withLock { failed } }
    func drain(_ handle: FileHandle, stream: Stream) {
        defer { try? handle.close() }
        do {
            while let data = try handle.read(upToCount: 16_384), !data.isEmpty {
                lock.withLock {
                    guard !failed, stdout.count + stderr.count + data.count <= 8 * 1_024 * 1_024 else {
                        failed = true; return
                    }
                    switch stream { case .stdout: stdout.append(data); case .stderr: stderr.append(data) }
                }
            }
        } catch { lock.withLock { failed = true } }
    }
    func output(exitStatus: Int32) -> NativeSecurityOutput {
        lock.withLock { .init(exitStatus: exitStatus, stdout: stdout, stderr: stderr) }
    }
}

private func nativeSecurityPermissionError() -> AgentSwapError {
    .storage("Claude Keychain 접근을 완료하지 못했습니다. 현재 로그인 가져오기를 눌러 접근을 허용하거나 Keychain 잠금을 해제해 주세요.")
}
