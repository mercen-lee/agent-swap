import Foundation
import Security
import CryptoKit
import Darwin
import AgentSwapVaultProtocol

struct VaultServiceIdentity: Sendable {
    let executableSHA256: String
    let cdHashes: [String]

    init(executableSHA256: String, cdHashes: [String]) throws {
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard hex(executableSHA256, count: 64), cdHashes.count == 2,
              cdHashes.allSatisfy({ hex($0, count: 40) }) else { throw vaultComponentFailure() }
        self.executableSHA256 = executableSHA256
        self.cdHashes = cdHashes
    }

    var peerRequirement: String {
        AgentSwapVaultWire.serviceRequirement + " and (" + cdHashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ")"
    }
}

enum FrozenVaultServiceRelease {
    // Signed from b30507a1d0d3c28a3bc64863c91c796a5a4f48c1 in CI 39943718806.
    // App updates reuse these exact signed bytes; service replacement requires a
    // separately reviewed migration rather than a normal application rebuild.
    static let identity: VaultServiceIdentity? = try? .init(
        executableSHA256: "567ac39089e13fa71811182af55544b6c83d3546888de3f59f9a7bf92438639f",
        cdHashes: ["dbc8d2693c9ace571fa818c0d159decee5bf00c6", "083ad9b12c2e7b5dcfa4e3a8cab08740dc60ba96"]
    )
}

protocol VaultServiceChecking: Sendable {
    func validate() throws -> VaultServiceIdentity
}

struct FrozenVaultServiceChecker: VaultServiceChecking {
    let applicationURL: URL
    init(applicationURL: URL = Bundle.main.bundleURL) { self.applicationURL = applicationURL }

    func validate() throws -> VaultServiceIdentity {
        guard let identity = FrozenVaultServiceRelease.identity else { throw vaultComponentFailure() }
        let root = applicationURL.appendingPathComponent("Contents/XPCServices/AgentSwapVaultService.xpc", isDirectory: true)
        let executable = root.appendingPathComponent("Contents/MacOS/AgentSwapVaultService")
        for directory in [root, root.appendingPathComponent("Contents"), root.appendingPathComponent("Contents/MacOS")] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw vaultComponentFailure() }
        }
        var info = stat()
        guard lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 64 * 1_024 * 1_024 else { throw vaultComponentFailure() }
        guard let bytes = try? Data(contentsOf: executable) else { throw vaultComponentFailure() }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == identity.executableSHA256 else {
            throw vaultComponentFailure()
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(identity.peerRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCreateWithPath(root as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw vaultComponentFailure()
        }
        return identity
    }
}

struct VaultHandshake: Sendable {
    let version: Int
    let nonce: Data
    let peerUserID: uid_t
}

protocol VaultCredentialSession: Sendable {
    func ping(_ nonce: Data, deadline: TimeInterval) throws -> VaultHandshake
    func execute(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool, deadline: TimeInterval) throws -> AppVaultReply
    func invalidate()
}

protocol VaultSessionCreating: Sendable {
    func open(peerRequirement: String, deadline: TimeInterval) throws -> any VaultCredentialSession
}

struct AuthenticatedAppVaultTransport: AppVaultTransport {
    private let checker: any VaultServiceChecking
    private let sessions: any VaultSessionCreating
    init(checker: any VaultServiceChecking = FrozenVaultServiceChecker(), sessions: any VaultSessionCreating = XPCVaultSessionFactory()) {
        self.checker = checker
        self.sessions = sessions
    }

    func perform(service: String = AgentSwapVaultWire.service, operation: String, account: String, data: Data?, interactionAllowed: Bool) throws -> AppVaultReply {
        let deadline = ProcessInfo.processInfo.systemUptime + (interactionAllowed ? 120 : 30)
        let identity = try checkedVaultIdentity(checker)
        let session = try withVaultStage(.connect) {
            try sessions.open(peerRequirement: identity.peerRequirement, deadline: deadline)
        }
        defer { session.invalidate() }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw appVaultFailure(.handshake) }
        let nonce = Data(random)
        let handshake = try withVaultStage(.handshake) { try session.ping(nonce, deadline: deadline) }
        // XPC authenticates incoming messages, not the first outgoing request.
        // Only a verified harmless reply permits sending a credential payload.
        guard handshake.version == AgentSwapVaultWire.version, handshake.nonce == nonce,
              handshake.peerUserID == getuid() else { throw appVaultFailure(.handshake) }
        try checkVaultRequest(deadline: deadline)
        return try withVaultStage(.request) {
            try session.execute(service: service, operation: operation, account: account, data: data,
                                interactionAllowed: interactionAllowed, deadline: deadline)
        }
    }
}

struct XPCVaultSessionFactory: VaultSessionCreating {
    func open(peerRequirement: String, deadline: TimeInterval) throws -> any VaultCredentialSession {
        try validateRequirement(peerRequirement)
        let broker = NSXPCConnection(serviceName: AgentSwapVaultWire.serviceIdentifier)
        broker.remoteObjectInterface = NSXPCInterface(with: AgentSwapVaultBroker.self)
        broker.setCodeSigningRequirement(peerRequirement)
        broker.resume()
        var completed = false
        defer { if !completed { broker.invalidate() } }
        let waiter = VaultXPCWaiter<NSXPCListenerEndpoint>(stage: .connect)
        installFailures(broker, waiter: waiter)
        guard let proxy = broker.remoteObjectProxyWithErrorHandler({ _ in waiter.reject() }) as? any AgentSwapVaultBroker else {
            throw appVaultFailure(.connect)
        }
        proxy.connect { waiter.accept($0) }
        let endpoint = try waiter.wait(deadline: deadline)
        guard broker.effectiveUserIdentifier == getuid() else { throw appVaultFailure(.connect) }
        // Named services may reconnect automatically. They NEVER carry secrets.
        // The credential endpoint is bound to this particular service process;
        // process death leaves a dead endpoint, not a new service-name lookup.
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentSwapVaultRPC.self)
        connection.setCodeSigningRequirement(peerRequirement)
        connection.resume()
        completed = true
        return XPCVaultCredentialSession(broker: broker, connection: connection)
    }
}

/// Connection configuration is immutable after construction. Foundation dispatches
/// replies on its own queues; per-request mutable results live in locked waiters.
private final class XPCVaultCredentialSession: VaultCredentialSession, @unchecked Sendable {
    private let broker: NSXPCConnection
    private let connection: NSXPCConnection
    init(broker: NSXPCConnection, connection: NSXPCConnection) { self.broker = broker; self.connection = connection }
    func invalidate() { connection.invalidate(); broker.invalidate() }
    deinit { invalidate() }

    func ping(_ nonce: Data, deadline: TimeInterval) throws -> VaultHandshake {
        let waiter = VaultXPCWaiter<VaultHandshake>(stage: .handshake)
        installFailures(connection, waiter: waiter)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in waiter.reject() }) as? any AgentSwapVaultRPC else {
            throw appVaultFailure(.handshake)
        }
        proxy.ping(nonce) { [self] version, echo in
            waiter.accept(.init(version: version, nonce: echo, peerUserID: self.connection.effectiveUserIdentifier))
        }
        return try waiter.wait(deadline: deadline)
    }

    func execute(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool, deadline: TimeInterval) throws -> AppVaultReply {
        try checkVaultRequest(deadline: deadline)
        let waiter = VaultXPCWaiter<AppVaultReply>(stage: .request)
        installFailures(connection, waiter: waiter)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in waiter.reject() }) as? any AgentSwapVaultRPC else {
            throw appVaultFailure()
        }
        try checkVaultRequest(deadline: deadline)
        proxy.execute(version: AgentSwapVaultWire.version, service: service, operation: operation, account: account, data: data,
                      interactionAllowed: interactionAllowed) { status, result in
            waiter.accept(.init(status: status, data: result))
        }
        return try waiter.wait(deadline: deadline)
    }
}

private func validateRequirement(_ text: String) throws {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, requirement != nil else {
        throw vaultComponentFailure()
    }
}

private func installFailures<Value>(_ connection: NSXPCConnection, waiter: VaultXPCWaiter<Value>) {
    connection.invalidationHandler = { waiter.reject() }
    connection.interruptionHandler = { [weak connection] in
        connection?.invalidate()
        waiter.reject()
    }
}

/// A callback owns its value until the synchronous Keychain boundary resumes.
/// All mutable state is protected and late/double replies are ignored.
private final class VaultXPCWaiter<Value>: @unchecked Sendable {
    private let stage: AppVaultFailureStage
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var completed = false
    private var value: Value?
    init(stage: AppVaultFailureStage) { self.stage = stage }
    func accept(_ value: Value) { finish(value) }
    func reject() { finish(nil) }
    private func finish(_ result: Value?) {
        let signal = lock.withLock {
            guard !completed else { return false }
            completed = true
            value = result
            return true
        }
        if signal { ready.signal() }
    }
    func wait(deadline: TimeInterval) throws -> Value {
        while true {
            try checkVaultRequest(deadline: deadline, stage: stage)
            if ready.wait(timeout: .now() + 0.025) == .success {
                try checkVaultRequest(deadline: deadline, stage: stage)
                guard let result = lock.withLock({ value }) else { throw appVaultFailure(stage) }
                return result
            }
        }
    }
}

func checkVaultRequest(deadline: TimeInterval, stage: AppVaultFailureStage = .request) throws {
    if !NativeSecurityCancellation.permitsRecovery { try Task.checkCancellation() }
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw appVaultFailure(stage) }
}

private func withVaultStage<Value>(_ stage: AppVaultFailureStage, operation: () throws -> Value) throws -> Value {
    do { return try operation() }
    catch is CancellationError { throw CancellationError() }
    catch let error as AgentSwapError {
        if case .cancelled = error { throw error }
        throw appVaultFailure(stage)
    } catch { throw appVaultFailure(stage) }
}

private func checkedVaultIdentity(_ checker: any VaultServiceChecking) throws -> VaultServiceIdentity {
    do { return try checker.validate() }
    catch is CancellationError { throw CancellationError() }
    catch let error as AgentSwapError {
        switch error {
        case .unsupported, .cancelled: throw error
        default: throw vaultComponentFailure()
        }
    } catch { throw vaultComponentFailure() }
}

private func vaultComponentFailure() -> AgentSwapError {
    .unsupported("앱의 인증 구성 요소를 확인하지 못했습니다. 검증된 설치 파일을 확인해 주세요.")
}
