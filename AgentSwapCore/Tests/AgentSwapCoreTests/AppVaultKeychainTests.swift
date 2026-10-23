import Foundation
import Security
import Testing
@testable import AgentSwapCore
import AgentSwapVaultProtocol

private let vaultSecretMarker = "SYNTHETIC_VAULT_PRIVATE_MARKER"
private func arbitraryVaultError() -> NSError {
    NSError(domain: vaultSecretMarker + ".domain", code: 123,
            userInfo: [NSLocalizedDescriptionKey: vaultSecretMarker + ".description",
                       "account": vaultSecretMarker + ".account", "service": vaultSecretMarker + ".service",
                       "data": Data(vaultSecretMarker.utf8)])
}

private func vaultFailureMessage(_ operation: () throws -> Void) -> String {
    do {
        try operation()
        Issue.record("Expected a bounded vault failure")
        return ""
    } catch let error as AgentSwapError {
        return error.localizedDescription
    } catch {
        Issue.record("Unexpected vault error type")
        return ""
    }
}

private final class VaultTransportFixture: AppVaultTransport, @unchecked Sendable {
    struct Call { let service: String; let operation: String; let account: String; let data: Data?; let interactive: Bool }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var storedResult = AppVaultReply(status: errSecSuccess, data: nil)
    private var storedEchoWrites = true
    private var storedFailure: NSError?
    var failure: NSError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    var result: AppVaultReply {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }
    var echoWrites: Bool {
        get { lock.withLock { storedEchoWrites } }
        set { lock.withLock { storedEchoWrites = newValue } }
    }
    var calls: [Call] { lock.withLock { recorded } }
    func perform(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool) throws -> AppVaultReply {
        try lock.withLock {
            recorded.append(.init(service: service, operation: operation, account: account, data: data, interactive: interactionAllowed))
            if let storedFailure { throw storedFailure }
            if operation == "write", storedEchoWrites, storedResult.status == errSecSuccess { return .init(status: errSecSuccess, data: data) }
            return storedResult
        }
    }
}

private final class VaultFallbackFixture: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var recorded = 0
    var calls: Int { lock.withLock { recorded } }
    func read(service: String, account: String) -> Data? { lock.withLock { recorded += 1; return values[service + account] } }
    func write(_ data: Data, service: String, account: String) { lock.withLock { recorded += 1; values[service + account] = data } }
    func delete(service: String, account: String) { lock.withLock { recorded += 1; _ = values.removeValue(forKey: service + account) } }
}

private struct VaultCheckerFixture: VaultServiceChecking {
    var fails = false
    var arbitraryFailure = false
    func validate() throws -> VaultServiceIdentity {
        if fails { throw AgentSwapError.unsupported("Synthetic modified component") }
        if arbitraryFailure { throw arbitraryVaultError() }
        return try .init(executableSHA256: String(repeating: "a", count: 64),
                         cdHashes: [String(repeating: "b", count: 40), String(repeating: "c", count: 40)])
    }
}

private final class VaultSessionFixture: VaultCredentialSession, @unchecked Sendable {
    enum Mode: Sendable { case good, nonce, version, user, disconnected, cancelled, requestFailure, pingCancellation, requestCancellation }
    let mode: Mode
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.withLock { recorded } }
    init(_ mode: Mode = .good) { self.mode = mode }
    func ping(_ nonce: Data, deadline: TimeInterval) throws -> VaultHandshake {
        lock.withLock { recorded.append("ping") }
        if mode == .disconnected { throw arbitraryVaultError() }
        if mode == .pingCancellation { throw CancellationError() }
        if mode == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(version: mode == .version ? 99 : AgentSwapVaultWire.version,
                     nonce: mode == .nonce ? Data(repeating: 0, count: 1) : nonce,
                     peerUserID: mode == .user ? getuid() + 1 : getuid())
    }
    func execute(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool, deadline: TimeInterval) throws -> AppVaultReply {
        lock.withLock { recorded.append("execute") }
        if mode == .requestFailure { throw arbitraryVaultError() }
        if mode == .requestCancellation { throw CancellationError() }
        return .init(status: errSecSuccess, data: data)
    }
    func invalidate() { lock.withLock { recorded.append("invalidate") } }
}

private final class VaultSessionFactoryFixture: VaultSessionCreating, @unchecked Sendable {
    enum Failure { case none, arbitrary, cancelled }
    let session: VaultSessionFixture
    let failure: Failure
    private let lock = NSLock()
    private var requirements: [String] = []
    var opens: Int { lock.withLock { requirements.count } }
    init(_ session: VaultSessionFixture = .init(), failure: Failure = .none) { self.session = session; self.failure = failure }
    func open(peerRequirement: String, deadline: TimeInterval) throws -> any VaultCredentialSession {
        lock.withLock { requirements.append(peerRequirement) }
        if failure == .arbitrary { throw arbitraryVaultError() }
        if failure == .cancelled { throw CancellationError() }
        return session
    }
}

@Suite("고정 앱 인증 저장소 경계")
struct AppVaultKeychainTests {
    @Test("Transport diagnostics identify only a static stage and never copy NSError contents",
          arguments: [AppVaultFailureStage.connect, .handshake, .request])
    func boundedTransportStage(_ stage: AppVaultFailureStage) {
        let session = VaultSessionFixture(stage == .handshake ? .disconnected : stage == .request ? .requestFailure : .good)
        let factory = VaultSessionFactoryFixture(session, failure: stage == .connect ? .arbitrary : .none)
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(), sessions: factory)
        let message = vaultFailureMessage {
            _ = try transport.perform(operation: "write", account: UUID().uuidString,
                                      data: Data(vaultSecretMarker.utf8), interactionAllowed: false)
        }
        #expect(message.contains("vault.\(stage.rawValue)"))
        #expect(!message.contains(vaultSecretMarker))
        #expect(!message.contains("저장된 인증 접근 허용"))
        #expect(session.calls == (stage == .connect ? [] : stage == .handshake ? ["ping", "invalidate"] : ["ping", "execute", "invalidate"]))
    }

    @Test("Cancellation remains cancellation at every transport stage",
          arguments: [AppVaultFailureStage.connect, .handshake, .request])
    func stageCancellation(_ stage: AppVaultFailureStage) {
        let session = VaultSessionFixture(stage == .handshake ? .pingCancellation : stage == .request ? .requestCancellation : .good)
        let factory = VaultSessionFactoryFixture(session, failure: stage == .connect ? .cancelled : .none)
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(), sessions: factory)
        #expect(throws: CancellationError.self) {
            _ = try transport.perform(operation: "read", account: UUID().uuidString, data: nil, interactionAllowed: false)
        }
        #expect(session.calls.last == (stage == .connect ? nil : "invalidate"))
    }

    @Test("Only permission-related OSStatus values suggest access approval",
          arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam, errSecIO, errSecDuplicateItem, errSecNotAvailable])
    func boundedSDKStatus(_ status: OSStatus) {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        transport.result = .init(status: status, data: Data(vaultSecretMarker.utf8))
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let message = vaultFailureMessage {
            _ = try access.read(service: KeychainSecretStore.service, account: UUID().uuidString)
        }
        #expect(message.contains("vault.request"))
        #expect(message.contains("OSStatus \(status)"))
        #expect(message.contains("저장된 인증 접근 허용") == (status == errSecAuthFailed || status == errSecInteractionNotAllowed))
        #expect(!message.contains(vaultSecretMarker))
        #expect(fallback.calls == 0)
    }

    @Test("Malformed successful replies do not suggest Keychain permission approval",
          arguments: ["read", "write", "delete", "validate"])
    func malformedReplyDiagnostic(_ operation: String) {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        transport.echoWrites = false
        transport.result = .init(status: errSecSuccess, data: operation == "read" ? nil : Data(vaultSecretMarker.utf8))
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let account = UUID().uuidString, bytes = Data("Synthetic planned successor".utf8)
        let message = vaultFailureMessage {
            switch operation {
            case "read": _ = try access.read(service: KeychainSecretStore.service, account: account)
            case "write": try access.write(bytes, service: KeychainSecretStore.service, account: account)
            case "delete": try access.delete(service: KeychainSecretStore.service, account: account)
            default: try access.validateWrite(bytes, service: KeychainSecretStore.service, account: account)
            }
        }
        #expect(message.contains("vault.request"))
        #expect(!message.contains("저장된 인증 접근 허용"))
        #expect(!message.contains(vaultSecretMarker))
        #expect(fallback.calls == 0)
    }

    @Test("Raw transport errors are bounded at the Keychain boundary")
    func rawTransportDiagnostic() {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        transport.failure = arbitraryVaultError()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let message = vaultFailureMessage {
            _ = try access.read(service: KeychainSecretStore.service, account: UUID().uuidString)
        }
        #expect(message.contains("vault.request"))
        #expect(!message.contains(vaultSecretMarker))
        #expect(!message.contains("저장된 인증 접근 허용"))
        #expect(fallback.calls == 0)
    }

    @Test("Unknown checker failures cannot expose NSError metadata or open a channel")
    func boundedCheckerFailure() {
        let factory = VaultSessionFactoryFixture()
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(arbitraryFailure: true), sessions: factory)
        let message = vaultFailureMessage {
            _ = try transport.perform(operation: "read", account: UUID().uuidString, data: nil, interactionAllowed: false)
        }
        #expect(!message.contains(vaultSecretMarker))
        #expect(!message.contains("저장된 인증 접근 허용"))
        #expect(factory.opens == 0)
    }

    @Test("Credentials are sent only after authenticating a same-channel nonce, version, and UID")
    func authenticatedBeforePayload() throws {
        let factory = VaultSessionFactoryFixture()
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(), sessions: factory)
        let data = Data("Synthetic credential".utf8)
        let result = try transport.perform(operation: "write", account: UUID().uuidString, data: data, interactionAllowed: false)
        #expect(result.data == data)
        #expect(factory.session.calls == ["ping", "execute", "invalidate"])
    }

    @Test("An untrusted or interrupted handshake never receives credential payload", arguments: [VaultSessionFixture.Mode.nonce, .version, .user, .disconnected])
    private func failedHandshake(_ mode: VaultSessionFixture.Mode) {
        let factory = VaultSessionFactoryFixture(.init(mode))
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(), sessions: factory)
        #expect(throws: AgentSwapError.self) {
            try transport.perform(operation: "write", account: UUID().uuidString, data: Data("Synthetic successor".utf8), interactionAllowed: false)
        }
        #expect(factory.session.calls == ["ping", "invalidate"])
    }

    @Test("Cancellation during a successful ping prevents credential RPC")
    func cancelledAfterPing() async {
        let factory = VaultSessionFactoryFixture(.init(.cancelled))
        let task = Task {
            let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(), sessions: factory)
            do {
                _ = try transport.perform(operation: "write", account: UUID().uuidString,
                                          data: Data("Synthetic successor".utf8), interactionAllowed: false)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
        #expect(factory.session.calls == ["ping", "invalidate"])
    }

    @Test("An expired request budget fails before credential enqueue")
    func expiredRequest() {
        #expect(throws: AgentSwapError.self) {
            try checkVaultRequest(deadline: ProcessInfo.processInfo.systemUptime - 1)
        }
    }

    @Test("A modified component is rejected before opening a channel")
    func modifiedComponent() {
        let factory = VaultSessionFactoryFixture()
        let transport = AuthenticatedAppVaultTransport(checker: VaultCheckerFixture(fails: true), sessions: factory)
        let message = vaultFailureMessage {
            _ = try transport.perform(operation: "read", account: UUID().uuidString, data: nil, interactionAllowed: false)
        }
        #expect(message == "Synthetic modified component")
        #expect(factory.opens == 0)
        #expect(factory.session.calls.isEmpty)
    }

    @Test("Denied vault reads never fall back to SDK access or reinterpret denial as absence")
    func deniedRead() {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        transport.result = .init(status: errSecAuthFailed, data: nil)
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        #expect(throws: AgentSwapError.self) { try access.read(service: KeychainSecretStore.service, account: UUID().uuidString) }
        #expect(fallback.calls == 0)
        #expect(transport.calls.count == 1)
    }

    @Test("Only explicit item-not-found without a payload is absence")
    func explicitAbsence() throws {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        transport.result = .init(status: errSecItemNotFound, data: nil)
        #expect(try access.read(service: KeychainSecretStore.service, account: UUID().uuidString) == nil)
        transport.result = .init(status: errSecItemNotFound, data: Data("Synthetic malformed reply".utf8))
        #expect(throws: AgentSwapError.self) { try access.read(service: KeychainSecretStore.service, account: UUID().uuidString) }
        #expect(fallback.calls == 0)
    }

    @Test("Large credential bytes survive exactly and successful writes require exact durable readback")
    func exactWrite() throws {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let data = Data(repeating: 0xa5, count: 3 * 1_024 * 1_024)
        try access.write(data, service: KeychainSecretStore.service, account: UUID().uuidString)
        #expect(transport.calls.first?.data == data)
        transport.echoWrites = false
        transport.result = .init(status: errSecSuccess, data: Data("Synthetic stale readback".utf8))
        #expect(throws: AgentSwapError.self) { try access.write(data, service: KeychainSecretStore.service, account: UUID().uuidString) }
        #expect(fallback.calls == 0)
    }

    @Test("Provider native stores retain their existing compatibility boundaries", arguments: ["Claude Code-credentials", "Codex Auth"])
    func otherStores(_ service: String) throws {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let data = Data("Synthetic independent record".utf8)
        try access.write(data, service: service, account: "synthetic|journal|rotation")
        #expect(try access.read(service: service, account: "synthetic|journal|rotation") == data)
        try access.delete(service: service, account: "synthetic|journal|rotation")
        #expect(fallback.calls == 3)
        #expect(transport.calls.isEmpty)
    }

    @Test("Unknown app service names cannot silently return to SDK access")
    func unknownAppService() {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let service = "net.mercen.agentswap.unknown", account = UUID().uuidString
        let data = Data("Synthetic credential".utf8)
        #expect(throws: AgentSwapError.self) { try access.read(service: service, account: account) }
        #expect(throws: AgentSwapError.self) { try access.write(data, service: service, account: account) }
        #expect(throws: AgentSwapError.self) { try access.delete(service: service, account: account) }
        #expect(throws: AgentSwapError.self) { try access.validateWrite(data, service: service, account: account) }
        #expect(transport.calls.isEmpty)
        #expect(fallback.calls == 0)
    }

    @Test("Every app-owned secret service uses the fixed boundary and exact record bytes", arguments: [AgentSwapVaultWire.service, AgentSwapVaultWire.recoveryService, AgentSwapVaultWire.desktopService])
    func appOwnedServices(_ service: String) throws {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let id = UUID().uuidString
        let account = service == AgentSwapVaultWire.service ? id : service == AgentSwapVaultWire.desktopService
            ? "desktop-profile-" + id : "claude|" + String(repeating: "a", count: 32) + "|rotation"
        let data = Data(repeating: 0x7f, count: 3 * 1_024 * 1_024)
        try access.write(data, service: service, account: account)
        transport.result = .init(status: errSecSuccess, data: data)
        #expect(try access.read(service: service, account: account) == data)
        transport.result = .init(status: errSecSuccess, data: nil)
        try access.delete(service: service, account: account)
        #expect(transport.calls.allSatisfy { $0.service == service && $0.account == account })
        #expect(fallback.calls == 0)
    }

    @Test("Unknown app-owned record formats are rejected before IPC", arguments: ["claude|invalid|rotation", "codex|../native", "claude-desktop-files-invalid", "unknown-journal"])
    func invalidRecoveryAccount(_ account: String) {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        #expect(throws: AgentSwapError.self) { try access.read(service: AgentSwapVaultWire.recoveryService, account: account) }
        #expect(transport.calls.isEmpty)
        #expect(fallback.calls == 0)
    }

    @Test("Malformed vault account names cannot reach either storage backend", arguments: ["", "../../account", "synthetic|rotation", "00000000-0000-0000-0000-00000000000a"])
    func invalidAccount(_ account: String) {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        #expect(throws: AgentSwapError.self) { try access.read(service: KeychainSecretStore.service, account: account) }
        #expect(transport.calls.isEmpty)
        #expect(fallback.calls == 0)
    }

    @Test("The permission action opts in only the chosen request and preflight never sends a credential")
    func explicitInteraction() throws {
        let transport = VaultTransportFixture(), fallback = VaultFallbackFixture()
        let access = AppVaultKeychainAccess(transport: transport, fallback: fallback)
        let account = UUID().uuidString
        try KeychainInteraction.$mode.withValue(.interactive) {
            try access.validateWrite(Data("Synthetic planned credential".utf8), service: KeychainSecretStore.service, account: account)
        }
        try access.delete(service: KeychainSecretStore.service, account: account)
        #expect(transport.calls.map(\.interactive) == [true, false])
        #expect(transport.calls.map(\.operation) == ["validate", "delete"])
        #expect(transport.calls.allSatisfy { $0.account == account && $0.data == nil })
    }
}
