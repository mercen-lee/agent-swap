import Foundation
import Security
import Testing
@testable import AgentSwapCore

// These isolated transport fixtures test byte preservation and transaction boundaries. Actual
// native consumer acceptance is verified separately in an owned temporary Keychain experiment.
private final class LargeNativeFixture: KeychainWritePreflighting, NativeSecurityRunning,
    NativeSwiftKeychainWriting, NativeKeychainLockChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var native: Data?
    private var vault: [String: Data] = [:]
    private var events: [String] = []
    private var contexts: [(Bool, TimeInterval, Bool)] = []
    let unavailable: Bool
    let cancelAfterWrite: Bool
    let corruptReadback: Bool
    init(_ native: Data? = nil, unavailable: Bool = false, cancelAfterWrite: Bool = false,
         corruptReadback: Bool = false) {
        self.native = native; self.unavailable = unavailable; self.cancelAfterWrite = cancelAfterWrite
        self.corruptReadback = corruptReadback
    }
    func read(service: String, account: String) -> Data? { lock.withLock { vault[service + account] } }
    func write(_ data: Data, service: String, account: String) { lock.withLock { vault[service + account] = data } }
    func delete(service: String, account: String) { lock.withLock { vault.removeValue(forKey: service + account); return () } }
    func validateWrite(_ data: Data, service: String, account: String) {}
    func validateAvailability() throws {
        try lock.withLock {
            events.append("availability")
            if unavailable { throw AgentSwapError.unsupported("fixture: interpreter unavailable") }
        }
    }
    func isUnlocked() -> Bool { true }
    func write(_ data: Data, service: String, account: String,
               interactionAllowed: Bool, timeout: TimeInterval) throws -> OSStatus {
        if Task.isCancelled && !NativeSecurityCancellation.permitsRecovery { throw CancellationError() }
        lock.withLock {
            native = data; events.append("swift-write")
            contexts.append((interactionAllowed, timeout, NativeSecurityCancellation.permitsRecovery))
        }
        if cancelAfterWrite && !NativeSecurityCancellation.permitsRecovery { withUnsafeCurrentTask { $0?.cancel() } }
        return errSecSuccess
    }
    func run(input: Data, timeout: TimeInterval) throws -> NativeSecurityOutput {
        if Task.isCancelled && !NativeSecurityCancellation.permitsRecovery { throw CancellationError() }
        return try lock.withLock {
            let command = String(decoding: input, as: UTF8.self)
            if command.contains("-s \"Claude Code\"") { return .init(exitStatus: 44) }
            if command.hasPrefix("add-generic-password"), let range = command.range(of: " -X ") {
                let hex = command[range.upperBound...].prefix { $0 != "\n" }
                native = try NativeSecurityCommand.passwordData(Data((hex + "\n").utf8))
                events.append("security-write")
            } else if command.hasPrefix("delete-generic-password") {
                native = nil; events.append("security-delete")
            } else { events.append("security-read") }
            contexts.append((KeychainInteraction.mode == .interactive, timeout, NativeSecurityCancellation.permitsRecovery))
            guard let native else { return .init(exitStatus: 44) }
            return .init(exitStatus: 0, stdout: (corruptReadback ? Data("{}".utf8) : native) + Data([10]))
        }
    }
    func current() -> Data? { lock.withLock { native } }
    func history() -> [String] { lock.withLock { events } }
    func observedContexts() -> [(Bool, TimeInterval, Bool)] { lock.withLock { contexts } }
}

private final class LargeNativeInteraction: KeychainInteractionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func isAllowed() -> Bool { lock.withLock { value } }
    func setAllowed(_ value: Bool) { lock.withLock { self.value = value } }
}

private final class LargeNativeFiles: AuthFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data("original config".utf8)
    func read(_ url: URL) -> Data? { lock.withLock { data } }
    func write(_ data: Data, to url: URL) throws { throw AgentSwapError.storage("fixture: config write failed") }
    func delete(_ url: URL) {}
}

private func largeAccess(_ fixture: LargeNativeFixture) -> ClaudeKeychainAccess {
    .init(fallback: fixture, runner: fixture, lockStatus: fixture,
          interactionGate: KeychainInteractionGate(controller: LargeNativeInteraction()), swiftWriter: fixture)
}

private func largeAuth(_ grant: String, padding: Int = 65_536) -> Data {
    Data(("{\"claudeAiOauth\":{\"accessToken\":\"" + grant + "\"},\"mcpOAuth\":{\"fixture\":\"" +
          String(repeating: "m", count: padding) + "\"},\"pluginSecrets\":{\"fixture\":\"\\ud55c\\uae00\\ud83d\\ude00\"}}").utf8)
}

@Suite("Large Claude native credentials")
struct ClaudeLargeKeychainTests {
    @Test("Both literal and hex native data fit the CLI reader at their exact supported boundaries", arguments: [
        (UInt8(97), 999_999), (UInt8(255), 499_999)
    ])
    func cliReaderBoundaryAccepted(byte: UInt8, count: Int) throws {
        let data = Data(repeating: byte, count: count)
        #expect(try NativeSecurityCommand.requiresSwiftWriter(data, service: "Claude Code-credentials", account: "fixture"))
        let fixture = LargeNativeFixture(), access = largeAccess(fixture)
        try access.validateWrite(data, service: "Claude Code-credentials", account: "fixture")
        #expect(fixture.history() == ["availability"])
        #expect(fixture.current() == nil)
    }

    @Test("CLI output above maxBuffer is rejected before any interpreter or native mutation", arguments: [
        (UInt8(97), 1_000_000), (UInt8(255), 500_000)
    ])
    func cliReaderBoundaryRejected(byte: UInt8, count: Int) {
        let data = Data(repeating: byte, count: count), before = largeAuth("before")
        let fixture = LargeNativeFixture(before), access = largeAccess(fixture)
        #expect(throws: AgentSwapError.self) { try access.validateWrite(data, service: "Claude Code-credentials", account: "fixture") }
        #expect(throws: AgentSwapError.self) { try access.write(data, service: "Claude Code-credentials", account: "fixture") }
        #expect(fixture.history().isEmpty)
        #expect(fixture.current() == before)
    }

    @Test("Unreadable forward or rollback images stop a transaction before its private journal", arguments: [true, false])
    func cliReaderLimitPrecedesTransactionJournal(oversizeSource: Bool) throws {
        let tooLarge = Data(repeating: 97, count: 1_000_000), valid = largeAuth("fixture")
        let before = oversizeSource ? tooLarge : valid, after = oversizeSource ? valid : tooLarge
        let fixture = LargeNativeFixture(before), access = largeAccess(fixture)
        let transaction = AuthTransaction(identifier: "reader-cap", keychain: access, files: LargeNativeFiles())
        #expect(throws: AgentSwapError.self) {
            try transaction.perform([.init(location: .keychain(service: "Claude Code-credentials", account: "fixture"), before: before, after: after)], verifyLock: {})
        }
        #expect(fixture.current() == before)
        #expect(fixture.history().allSatisfy { $0 == "availability" })
        #expect(try transaction.hasPendingRecovery() == false)
    }

    @Test("Large active A stays writable and switching to small B retains live MCP/plugin fields")
    func actualAuthStoreUsesLargeWriterAndPreservesSharedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapLargeAuth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = largeAuth("fixture-A"), fixture = LargeNativeFixture(before)
        let access = largeAccess(fixture), files = AtomicAuthFileAccess()
        let store = ClaudeAuthStore(home: directory, keychain: access, files: files, environmentUser: "fixture", systemUser: "fixture")
        let sourceMetadata: [String: Any] = ["accountUuid": "fixture-A-user", "organizationUuid": "fixture-A-workspace"]
        let targetMetadata: [String: Any] = ["accountUuid": "fixture-B-user", "organizationUuid": "fixture-B-workspace"]
        try files.write(authData(["oauthAccount": sourceMetadata, "sharedSetting": "preserved"]), to: store.configURL)
        #expect(await store.compatibility().canWrite)
        let target = try CredentialParser.claude(rawAuth: authData([
            "claudeAiOauth": ["accessToken": "fixture-B", "refreshToken": "fixture-B-refresh", "expiresAt": 1_900_000_000_000],
            "mcpOAuth": ["stale target grant": "discard"], "pluginSecrets": ["stale target plugin": "discard"]
        ]), accountMetadata: authData(targetMetadata))
        try await store.activate(target,
                                 expectedSourceIdentity: .init(provider: .claude, userID: "fixture-A-user", workspaceID: "fixture-A-workspace"),
                                 expectedSourceAuth: before)
        let after = try #require(fixture.current())
        let original = try authObject(before, name: "fixture")
        let changed = try authObject(after, name: "fixture")
        #expect((changed["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "fixture-B")
        #expect((original["mcpOAuth"] as? NSDictionary) == (changed["mcpOAuth"] as? NSDictionary))
        #expect((original["pluginSecrets"] as? NSDictionary) == (changed["pluginSecrets"] as? NSDictionary))
        #expect(after.count > 65_536 && fixture.history().contains("swift-write"))
        let config = try authObject(#require(try files.read(store.configURL)), name: "fixture")
        #expect(config["sharedSetting"] as? String == "preserved")
        #expect((config["oauthAccount"] as? NSDictionary) == (targetMetadata as NSDictionary))
        #expect(await store.compatibility().canWrite)
    }

    @Test("Credential receiver resource is checked against the compiled digest")
    func helperResourceMustMatchCompiledCode() throws {
        let url = try SystemNativeSwiftKeychainWriter.helperURL()
        let source = try Data(contentsOf: url)
        try SystemNativeSwiftKeychainWriter.verifyHelperData(source)
        #expect(throws: AgentSwapError.self) { try SystemNativeSwiftKeychainWriter.verifyHelperData(source + Data("\n// changed".utf8)) }
    }

    @Test("64 KiB shared fields use Swift stdin and the CLI consumer verifies exact bytes")
    func largeDataAndSharedFieldsRemainExact() throws {
        let before = largeAuth("before"), after = largeAuth("after")
        let fixture = LargeNativeFixture(before), access = largeAccess(fixture)
        try access.validateWrite(before, service: "Claude Code-credentials", account: "fixture")
        try access.validateWrite(after, service: "Claude Code-credentials", account: "fixture")
        try KeychainInteraction.$mode.withValue(.interactive) {
            try access.write(after, service: "Claude Code-credentials", account: "fixture")
        }
        #expect(fixture.current() == after)
        #expect(fixture.history().suffix(2) == ["swift-write", "security-read"])
        #expect(fixture.observedContexts().allSatisfy { $0.0 && $0.1 == 120 })
        let old = try JSONSerialization.jsonObject(with: before) as? [String: Any]
        let new = try JSONSerialization.jsonObject(with: after) as? [String: Any]
        #expect((old?["mcpOAuth"] as? NSDictionary) == (new?["mcpOAuth"] as? NSDictionary))
        #expect((old?["pluginSecrets"] as? NSDictionary) == (new?["pluginSecrets"] as? NSDictionary))
    }

    @Test("Background Swift writer gets a process-local no-UI request and bounded compile time")
    func backgroundPolicyAndDeadlines() throws {
        let fixture = LargeNativeFixture(), access = largeAccess(fixture)
        try KeychainInteraction.$mode.withValue(.noninteractive) {
            try access.write(largeAuth("new"), service: "Claude Code-credentials-1234abcd", account: "fixture")
        }
        let contexts = fixture.observedContexts()
        #expect(contexts.count == 2)
        #expect(contexts[0].0 == false && contexts[0].1 == 30)
        #expect(contexts[1].0 == false && contexts[1].1 == 2)
    }

    @Test("Unavailable interpreter and over-1MiB data fail before native or private mutation")
    func failClosedPreflight() {
        let before = largeAuth("before")
        let unavailable = LargeNativeFixture(before, unavailable: true), access = largeAccess(unavailable)
        #expect(throws: AgentSwapError.self) { try access.validateWrite(largeAuth("after"), service: "Claude Code-credentials", account: "fixture") }
        #expect(throws: AgentSwapError.self) { try access.write(largeAuth("after"), service: "Claude Code-credentials", account: "fixture") }
        #expect(unavailable.current() == before)
        #expect(!unavailable.history().contains("swift-write"))
        let overCap = LargeNativeFixture(before), capped = largeAccess(overCap)
        #expect(throws: AgentSwapError.self) { try capped.write(Data(repeating: 97, count: 1_048_577), service: "Claude Code-credentials", account: "fixture") }
        #expect(overCap.history().isEmpty && overCap.current() == before)
    }

    @Test("A successful SDK write with a different CLI readback is not accepted")
    func externalConsumerMustReadExactData() {
        let fixture = LargeNativeFixture(corruptReadback: true), access = largeAccess(fixture)
        #expect(throws: AgentSwapError.self) { try access.write(largeAuth("after"), service: "Claude Code-credentials", account: "fixture") }
        #expect(fixture.history().suffix(2) == ["swift-write", "security-read"])
    }

    @Test("Partial config failure restores large before-image including MCP/plugin bytes")
    func partialFailureRollsBackLargeBeforeImage() throws {
        let before = largeAuth("before"), after = Data("{\"claudeAiOauth\":{\"accessToken\":\"after\"}}".utf8)
        let fixture = LargeNativeFixture(before), access = largeAccess(fixture), files = LargeNativeFiles()
        let transaction = AuthTransaction(identifier: "large-fixture", keychain: access, files: files)
        #expect(throws: AgentSwapError.self) {
            try transaction.perform([
                .init(location: .keychain(service: "Claude Code-credentials", account: "fixture"), before: before, after: after),
                .init(location: .file("/fixture/config"), before: Data("original config".utf8), after: Data("new config".utf8))
            ], verifyLock: {})
        }
        #expect(fixture.current() == before)
        #expect(try transaction.hasPendingRecovery() == false)
        #expect(fixture.history().contains("security-write") && fixture.history().contains("swift-write"))
        #expect(fixture.observedContexts().contains { $0.2 })
    }

    @Test("Cancellation after a large native write still restores its exact predecessor")
    func cancellationAfterWriteRollsBack() async throws {
        let before = largeAuth("before"), after = largeAuth("after")
        let fixture = LargeNativeFixture(before, cancelAfterWrite: true), access = largeAccess(fixture)
        let transaction = AuthTransaction(identifier: "large-cancellation", keychain: access, files: LargeNativeFiles())
        let task = Task {
            do {
                try transaction.perform([.init(location: .keychain(service: "Claude Code-credentials", account: "fixture"), before: before, after: after)],
                                        checkCancellation: { try Task.checkCancellation() }, verifyLock: {})
                return false
            } catch {
                #expect(Task.isCancelled)
                #expect(!NativeSecurityCancellation.permitsRecovery)
                return true
            }
        }
        #expect(await task.value)
        #expect(fixture.current() == before)
        #expect(try transaction.hasPendingRecovery() == false)
        #expect(fixture.observedContexts().contains { $0.2 })
    }

    @Test("Interpreter request has only scoped metadata, opaque Data and explicit UI policy")
    func requestOnlyCarriesStdinData() throws {
        let data = largeAuth("fixture-private-grant")
        let request = try JSONEncoder().encode(NativeSwiftKeychainRequest(service: "Claude Code-credentials", account: "fixture", data: data, interactionAllowed: false))
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(Set(object.keys) == ["service", "account", "data", "interactionAllowed"])
        #expect((object["data"] as? String).flatMap { Data(base64Encoded: $0) } == data)
        #expect(object["interactionAllowed"] as? Bool == false)
        #expect(!String(decoding: request, as: UTF8.self).contains("fixture-private-grant"))
    }

    @Test("The CLI-supported ASCII maximum fits stdin even when base64 needs many slashes")
    func maximumDataStillFitsRequest() throws {
        let data = Data(repeating: 0x3f, count: 999_999)
        let input = try SystemNativeSwiftKeychainWriter.requestData(data, service: "Claude Code-credentials", account: "fixture", interactionAllowed: false)
        #expect(input.count <= 1_500_000)
        let object = try #require(try JSONSerialization.jsonObject(with: input) as? [String: Any])
        #expect((object["data"] as? String).flatMap { Data(base64Encoded: $0) } == data)
    }
}
