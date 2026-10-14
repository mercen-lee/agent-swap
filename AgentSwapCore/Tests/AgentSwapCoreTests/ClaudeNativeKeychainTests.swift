import Foundation
import Testing
@testable import AgentSwapCore

// These fixtures validate transport and delegation boundaries. They do not establish that a
// real Keychain item's ACL or an independently running Claude CLI's access is preserved.
private struct NativeFixtureRequest: Sendable {
    let input: Data
    let timeout: TimeInterval
}

// Safety invariant: every simulated output and captured request is guarded by this one lock.
private final class NativeFixtureRunner: NativeSecurityRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let output: NativeSecurityOutput
    private var requests: [NativeFixtureRequest] = []
    init(_ output: NativeSecurityOutput) { self.output = output }
    func run(input: Data, timeout: TimeInterval) -> NativeSecurityOutput {
        lock.withLock {
            requests.append(.init(input: input, timeout: timeout))
            return output
        }
    }
    func history() -> [NativeFixtureRequest] { lock.withLock { requests } }
}

private final class NativeFixtureLockStatus: NativeKeychainLockChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let unlocked: Bool
    private var checks = 0
    init(unlocked: Bool = true) { self.unlocked = unlocked }
    func isUnlocked() -> Bool { lock.withLock { checks += 1; return unlocked } }
    func checkCount() -> Int { lock.withLock { checks } }
}

private final class NativeFixtureInteraction: KeychainInteractionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func isAllowed() -> Bool { lock.withLock { allowed } }
    func setAllowed(_ value: Bool) { lock.withLock { allowed = value } }
}

private final class NativeFixtureVault: KeychainWritePreflighting, @unchecked Sendable {
    private struct Item: Hashable { let service: String; let account: String }
    private let lock = NSLock()
    private var items: [Item: Data] = [:]
    private var operations: [String] = []
    func read(service: String, account: String) -> Data? {
        lock.withLock { operations.append("read"); return items[.init(service: service, account: account)] }
    }
    func write(_ data: Data, service: String, account: String) {
        lock.withLock { operations.append("write"); items[.init(service: service, account: account)] = data }
    }
    func delete(service: String, account: String) {
        lock.withLock { operations.append("delete"); items.removeValue(forKey: .init(service: service, account: account)); return () }
    }
    func validateWrite(_ data: Data, service: String, account: String) {
        lock.withLock { operations.append("validate") }
    }
    func history() -> [String] { lock.withLock { operations } }
}

private func nativeFixtureAccess(runner: any NativeSecurityRunning, vault: NativeFixtureVault = .init(),
                                 lockStatus: NativeFixtureLockStatus = .init()) -> ClaudeKeychainAccess {
    .init(fallback: vault, runner: runner, lockStatus: lockStatus,
          interactionGate: KeychainInteractionGate(controller: NativeFixtureInteraction()))
}

private struct NativeFixtureCancellationCall: Sendable {
    let mutation: Bool
    let cancelled: Bool
    let recoveryAllowed: Bool
    let timeout: TimeInterval
}

// Safety invariant: simulated password changes and cancellation history share one NSLock.
private final class NativeFixtureCancellationRunner: NativeSecurityRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let original: Data
    private let target: Data
    private var password: Data
    private var writeCount = 0
    private var calls: [NativeFixtureCancellationCall] = []
    init(original: Data, target: Data) {
        self.original = original; self.target = target; self.password = original
    }
    func run(input: Data, timeout: TimeInterval) throws -> NativeSecurityOutput {
        try lock.withLock {
            let mutation = String(decoding: input, as: UTF8.self).hasPrefix("add-generic-password ")
            calls.append(.init(mutation: mutation, cancelled: Task.isCancelled,
                               recoveryAllowed: NativeSecurityCancellation.permitsRecovery, timeout: timeout))
            if Task.isCancelled && !NativeSecurityCancellation.permitsRecovery { throw CancellationError() }
            if mutation {
                writeCount += 1
                password = writeCount == 1 ? target : original
                if writeCount == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return .init(exitStatus: 0, stdout: password + Data([10]))
        }
    }
    func currentPassword() -> Data { lock.withLock { password } }
    func history() -> [NativeFixtureCancellationCall] { lock.withLock { calls } }
}

@Suite("Claude native Keychain wire boundaries")
struct ClaudeNativeKeychainTests {
    @Test("SecurityTool receives only fixed interactive arguments; secrets remain in hex stdin")
    func secretDoesNotEnterArguments() throws {
        let secret = Data("fixture-private-password".utf8)
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: secret + Data([10])))
        let access = nativeFixtureAccess(runner: runner)
        try access.write(secret, service: "Claude Code-credentials", account: "fixture-user")

        #expect(SystemNativeSecurityRunner.executableURL.path == "/usr/bin/security")
        #expect(SystemNativeSecurityRunner.arguments == ["-i", "-q"])
        let request = try #require(runner.history().first)
        let command = String(decoding: request.input, as: UTF8.self)
        #expect(!command.contains("fixture-private-password"))
        #expect(command.contains("-X 666978747572652d707269766174652d70617373776f7264"))
        #expect(command.contains("-a \"fixture-user\""))
        #expect(command.contains("-s \"Claude Code-credentials\""))
        #expect(command.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
    }

    @Test("Payload controls and non-ASCII bytes cannot introduce an interactive command")
    func binaryPayloadUsesLowercaseHex() throws {
        let bytes = Data([0, 10, 13, 255])
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data("000a0dff\n".utf8)))
        try nativeFixtureAccess(runner: runner).write(bytes, service: "Claude Code-credentials", account: "fixture-user")
        let input = try #require(runner.history().first).input
        let command = String(decoding: input, as: UTF8.self)
        #expect(command.contains("-X 000a0dff\n"))
        #expect(input.allSatisfy { (32...126).contains($0) || $0 == 10 })
        #expect(!input.contains(0) && !input.contains(13) && !input.contains(255))
        #expect(input.filter { $0 == 10 }.count == 2)
    }

    @Test("Every accepted stdin command fits the native fixed line buffer")
    func acceptedWriteIsBounded() throws {
        let bytes = Data(repeating: 97, count: 1_800)
        let input = try NativeSecurityCommand.write(bytes, service: "Claude Code-credentials", account: "fixture-user")
        #expect(input.count <= 8_192)
        let lines = String(decoding: input, as: UTF8.self).split(separator: "\n")
        try #require(lines.count == 2)
        #expect(lines.allSatisfy { $0.utf8.count <= 4_094 })
    }

    @Test("Oversize native authentication is refused before any command or fallback mutation")
    func oversizeFailsBeforeTransport() {
        let runner = NativeFixtureRunner(.init(exitStatus: 0)), vault = NativeFixtureVault()
        let access = nativeFixtureAccess(runner: runner, vault: vault)
        let bytes = Data(repeating: 97, count: 3_000)
        #expect(throws: AgentSwapError.self) {
            try access.validateWrite(bytes, service: "Claude Code-credentials", account: "fixture-user")
        }
        #expect(throws: AgentSwapError.self) {
            try access.write(bytes, service: "Claude Code-credentials", account: "fixture-user")
        }
        #expect(runner.history().isEmpty)
        #expect(vault.history().isEmpty)
    }

    @Test("Account command injection is rejected before the transport", arguments: [
        "fixture\nquit", "fixture\rquit", "fixture\u{0}quit", "fixture\"quit", "fixture\\quit", "사용자", ""
    ])
    func unsafeAccountRejected(account: String) {
        let runner = NativeFixtureRunner(.init(exitStatus: 0))
        let access = nativeFixtureAccess(runner: runner)
        #expect(throws: AgentSwapError.self) {
            try access.write(Data("fixture".utf8), service: "Claude Code-credentials", account: account)
        }
        #expect(runner.history().isEmpty)
    }

    @Test("An unknown isolated Claude service cannot silently use the vault fallback", arguments: [
        "Claude Code-credentials-invalid", "Claude Code-credentials-DEADBEEF", "Claude Code-credentialsSuffix"
    ])
    func unknownNativeServiceRejected(service: String) {
        let runner = NativeFixtureRunner(.init(exitStatus: 0)), vault = NativeFixtureVault()
        let access = nativeFixtureAccess(runner: runner, vault: vault)
        #expect(throws: AgentSwapError.self) { try access.read(service: service, account: "fixture-user") }
        #expect(runner.history().isEmpty)
        #expect(vault.history().isEmpty)
    }

    @Test("Default and validated isolated Claude services use native reads", arguments: [
        "Claude Code-credentials", "Claude Code-credentials-deadbeef"
    ])
    func nativeServiceRouting(service: String) throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data("{\"fixture\":true}\n".utf8)))
        let vault = NativeFixtureVault(), access = nativeFixtureAccess(runner: runner, vault: vault)
        #expect(try access.read(service: service, account: "fixture-user") == Data("{\"fixture\":true}".utf8))
        #expect(runner.history().count == 1)
        #expect(vault.history().isEmpty)
    }

    @Test("Vault credentials, recovery secrets and Codex stay in the injected private store", arguments: [
        KeychainSecretStore.service, AuthTransaction.service, CodexAuthStore.keychainService
    ])
    func privateSecretsDelegate(service: String) throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 0)), vault = NativeFixtureVault()
        let access = nativeFixtureAccess(runner: runner, vault: vault)
        let secret = Data(repeating: 119, count: 10_000)
        try access.validateWrite(secret, service: service, account: "fixture-recovery-key")
        try access.write(secret, service: service, account: "fixture-recovery-key")
        #expect(try access.read(service: service, account: "fixture-recovery-key") == secret)
        try access.delete(service: service, account: "fixture-recovery-key")
        #expect(try access.read(service: service, account: "fixture-recovery-key") == nil)
        #expect(vault.history() == ["validate", "write", "read", "delete", "read"])
        #expect(runner.history().isEmpty)
    }

    @Test("Native hex and printable reads reconstruct the exact password bytes", arguments: [
        ("7b2276223a22eab080227d\n", Data("{\"v\":\"가\"}".utf8)),
        ("000a0dff\n", Data([0, 10, 13, 255])),
        ("{\"v\":\"fixture\"}\n", Data("{\"v\":\"fixture\"}".utf8))
    ])
    func passwordReadback(output: String, expected: Data) throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data(output.utf8)))
        #expect(try nativeFixtureAccess(runner: runner).read(service: "Claude Code-credentials", account: "fixture-user") == expected)
    }

    @Test("Malformed or incomplete read output is not treated as a missing item", arguments: [
        "{}", "{}\n\n", "{}\r\n", "\n", "{\"v\":\"가\"}\n"
    ])
    func malformedOutputRefused(output: String) {
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data(output.utf8)))
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: runner).read(service: "Claude Code-credentials", account: "fixture-user")
        }
    }

    @Test("Only an empty item-not-found result becomes nil")
    func absentItemDistinctFromPermission() throws {
        let absent = NativeFixtureRunner(.init(exitStatus: 44, stderr: Data("Fixture item missing".utf8)))
        #expect(try nativeFixtureAccess(runner: absent).read(service: "Claude Code-credentials", account: "fixture-user") == nil)
        let denied = NativeFixtureRunner(.init(exitStatus: 43, stderr: Data("fixture-private-value".utf8)))
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: denied).read(service: "Claude Code-credentials", account: "fixture-user")
        }
        let ambiguous = NativeFixtureRunner(.init(exitStatus: 44, stdout: Data("fixture-private-value".utf8)))
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: ambiguous).read(service: "Claude Code-credentials", account: "fixture-user")
        }
    }

    @Test("A failed update cannot be hidden by a successful final readback")
    func stderrFailureIsSanitized() throws {
        let secret = Data("{\"v\":\"fixture-private-value\"}".utf8)
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: secret + Data([10]),
                                               stderr: Data("failed command contains fixture-private-value".utf8)))
        do {
            try nativeFixtureAccess(runner: runner).write(secret, service: "Claude Code-credentials", account: "fixture-user")
            Issue.record("An update diagnostic must make the operation fail.")
        } catch {
            #expect(error is AgentSwapError)
            #expect(!error.localizedDescription.contains("fixture-private-value"))
            #expect(!error.localizedDescription.contains("failed command"))
        }
    }

    @Test("A different native readback cannot confirm an update")
    func exactReadbackRequired() {
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data("{\"v\":\"different\"}\n".utf8)))
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: runner).write(Data("{\"v\":\"expected\"}".utf8), service: "Claude Code-credentials", account: "fixture-user")
        }
    }

    @Test("Deletion includes a subsequent missing-item read without exposing a password")
    func deleteVerifiesAbsence() throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 44, stderr: Data("Fixture item missing".utf8)))
        try nativeFixtureAccess(runner: runner).delete(service: "Claude Code-credentials", account: "fixture-user")
        let command = String(decoding: try #require(runner.history().first).input, as: UTF8.self)
        #expect(command.hasPrefix("delete-generic-password "))
        #expect(command.contains("\nfind-generic-password "))
        let attributes = NativeFixtureRunner(.init(exitStatus: 44, stdout: Data("class: \"genp\"\nattributes: fixture item\n".utf8)))
        try nativeFixtureAccess(runner: attributes).delete(service: "Claude Code-credentials", account: "fixture-user")
        #expect(attributes.history().count == 1)
        let present = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data("{}\n".utf8)))
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: present).delete(service: "Claude Code-credentials", account: "fixture-user")
        }
    }

    @Test("The Claude API-key service preserves printable keys and cannot be written or deleted", arguments: ["fixture-key", "deadbeef"])
    func apiKeyReadOnly(password: String) throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 0, stdout: Data((password + "\n").utf8)))
        let access = nativeFixtureAccess(runner: runner)
        #expect(try access.read(service: "Claude Code", account: "fixture-user") == Data(password.utf8))
        #expect(throws: AgentSwapError.self) { try access.write(Data("fixture".utf8), service: "Claude Code", account: "fixture-user") }
        #expect(throws: AgentSwapError.self) { try access.delete(service: "Claude Code", account: "fixture-user") }
        #expect(runner.history().count == 1)
    }

    @Test("Background transport receives a short timeout and a locked Keychain stops before launch")
    func boundedBackgroundAccess() throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 44))
        #expect(try nativeFixtureAccess(runner: runner).read(service: "Claude Code-credentials", account: "fixture-user") == nil)
        let request = try #require(runner.history().first)
        #expect(request.timeout == 2)
        let lockedRunner = NativeFixtureRunner(.init(exitStatus: 0)), status = NativeFixtureLockStatus(unlocked: false)
        #expect(throws: AgentSwapError.self) {
            try nativeFixtureAccess(runner: lockedRunner, lockStatus: status).read(service: "Claude Code-credentials", account: "fixture-user")
        }
        #expect(lockedRunner.history().isEmpty)
        #expect(status.checkCount() == 1)
    }

    @Test("Explicit foreground access allows a longer bound without assuming an unlocked Keychain")
    func foregroundBound() throws {
        let runner = NativeFixtureRunner(.init(exitStatus: 44)), status = NativeFixtureLockStatus(unlocked: false)
        let result = try KeychainInteraction.$mode.withValue(.interactive) {
            try nativeFixtureAccess(runner: runner, lockStatus: status).read(service: "Claude Code-credentials", account: "fixture-user")
        }
        #expect(result == nil)
        let request = try #require(runner.history().first)
        #expect(request.timeout == 120)
        #expect(status.checkCount() == 0)
    }

    @Test("Cancellation after a native write still allows bounded journal rollback")
    func cancelledForwardWriteRecovers() async throws {
        let original = Data("{\"fixture\":\"original\"}".utf8)
        let target = Data("{\"fixture\":\"target\"}".utf8)
        let runner = NativeFixtureCancellationRunner(original: original, target: target)
        let vault = NativeFixtureVault(), access = nativeFixtureAccess(runner: runner, vault: vault)
        let identifier = "fixture-native-cancellation"
        let transaction = AuthTransaction(identifier: identifier, keychain: access, files: AtomicAuthFileAccess())
        let location = AuthMutation.Location.keychain(service: "Claude Code-credentials", account: "fixture-user")
        let operation = Task {
            do {
                try transaction.perform([.init(location: location, before: original, after: target)],
                                        checkCancellation: { try Task.checkCancellation() }, verifyLock: {})
                Issue.record("The cancelled forward operation must fail after restoring the previous password.")
                return false
            } catch {
                #expect(Task.isCancelled)
                #expect(!NativeSecurityCancellation.permitsRecovery)
                return true
            }
        }
        #expect(await operation.value)
        #expect(runner.currentPassword() == original)
        #expect(vault.read(service: AuthTransaction.service, account: identifier) == nil)
        let writes = runner.history().filter(\.mutation)
        try #require(writes.count == 2)
        #expect(!writes[0].cancelled && !writes[0].recoveryAllowed)
        #expect(writes[1].cancelled && writes[1].recoveryAllowed)
        #expect(writes.allSatisfy { $0.timeout == 2 })
    }

    @Test("Invalid process frame and timeout limits fail before invoking the real tool", arguments: [
        (Data(repeating: 97, count: 8_193), TimeInterval(2)),
        (Data("fixture\n".utf8), TimeInterval(0)),
        (Data("fixture\n".utf8), TimeInterval(121))
    ])
    func invalidRunnerBounds(input: Data, timeout: TimeInterval) {
        #expect(throws: AgentSwapError.self) { try SystemNativeSecurityRunner().run(input: input, timeout: timeout) }
    }
}
