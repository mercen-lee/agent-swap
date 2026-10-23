import Foundation
import Security
import Testing
import AgentSwapVaultProtocol
@testable import AgentSwapVaultService

private let fixtureAccount = "00000000-0000-4000-8000-0000000000AB"

private final class FixtureInteraction: VaultInteractionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool
    private var changes: [Bool] = []
    private var failureOnChange: Int?

    init(allowed: Bool = true) { self.allowed = allowed }
    func isAllowed() -> Bool { lock.withLock { allowed } }
    func setAllowed(_ value: Bool) throws {
        try lock.withLock {
            changes.append(value)
            if changes.count == failureOnChange { throw VaultServiceFailure(status: errSecAuthFailed) }
            allowed = value
        }
    }
    func fail(change: Int) { lock.withLock { failureOnChange = change } }
    func history() -> [Bool] { lock.withLock { changes } }
}

private final class FixtureBackend: VaultKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var calls: [String] = []
    private var modes: [Bool] = []
    private var readFailure: OSStatus?
    private var failedReadNumber: Int?
    private var readCount = 0
    private var writeFailure: OSStatus?
    private var failAfterWriting = false
    private var alteredReadback: Data?
    private var readCheckpoint: (@Sendable () -> Void)?
    private var mutationCheckpoint: (@Sendable () -> Void)?
    let interaction: FixtureInteraction

    init(_ stored: Data? = nil, interaction: FixtureInteraction = FixtureInteraction()) {
        self.stored = stored
        self.interaction = interaction
    }
    func read(service: String, account: String) throws -> Data? {
        let checkpoint = lock.withLock { readCheckpoint }
        checkpoint?()
        return try lock.withLock {
            calls.append("read")
            readCount += 1
            modes.append(interaction.isAllowed())
            if let readFailure, failedReadNumber == nil || failedReadNumber == readCount { throw VaultServiceFailure(status: readFailure) }
            return stored
        }
    }
    func write(_ data: Data, service: String, account: String, isActive: @Sendable () -> Bool) throws {
        let checkpoint = lock.withLock { mutationCheckpoint }
        checkpoint?()
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        try lock.withLock {
            calls.append("write")
            modes.append(interaction.isAllowed())
            if let writeFailure, !failAfterWriting { throw VaultServiceFailure(status: writeFailure) }
            stored = alteredReadback ?? data
            if let writeFailure { throw VaultServiceFailure(status: writeFailure) }
        }
    }
    func delete(service: String, account: String, isActive: @Sendable () -> Bool) throws {
        let checkpoint = lock.withLock { mutationCheckpoint }
        checkpoint?()
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        lock.withLock {
            calls.append("delete")
            modes.append(interaction.isAllowed())
            stored = nil
        }
    }
    func failReads(_ status: OSStatus?) { lock.withLock { readFailure = status } }
    func failRead(number: Int, status: OSStatus) { lock.withLock { failedReadNumber = number; readFailure = status } }
    func failWrites(_ status: OSStatus, afterCommit: Bool) {
        lock.withLock { writeFailure = status; failAfterWriting = afterCommit }
    }
    func changeWriteReadback(_ data: Data) { lock.withLock { alteredReadback = data } }
    func beforeRead(_ action: @escaping @Sendable () -> Void) { lock.withLock { readCheckpoint = action } }
    func beforeMutation(_ action: @escaping @Sendable () -> Void) { lock.withLock { mutationCheckpoint = action } }
    func value() -> Data? { lock.withLock { stored } }
    func history() -> [String] { lock.withLock { calls } }
    func interactionHistory() -> [Bool] { lock.withLock { modes } }
}

private func processor(_ backend: FixtureBackend) -> VaultRequestProcessor {
    .init(backend: backend, gate: VaultInteractionGate(controller: backend.interaction))
}

private func request(_ processor: VaultRequestProcessor, operation: String = "read", data: Data? = nil,
                     version: Int = AgentSwapVaultWire.version, service: String = AgentSwapVaultWire.service, account: String = fixtureAccount,
                     interactive: Bool = false, isActive: @escaping @Sendable () -> Bool = { true }) -> VaultServiceReply {
    processor.execute(version: version, service: service, operation: operation, account: account, data: data,
                      interactionAllowed: interactive, isActive: isActive)
}

private final class ServiceRoutingBackend: VaultKeychainBackend, @unchecked Sendable {
    struct Key: Hashable { let service: String; let account: String }
    private let lock = NSLock()
    private var records: [Key: Data] = [:]
    private var calls: [Key] = []

    func read(service: String, account: String) -> Data? {
        lock.withLock {
            let key = Key(service: service, account: account)
            calls.append(key)
            return records[key]
        }
    }
    func write(_ data: Data, service: String, account: String, isActive: @Sendable () -> Bool) throws {
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        lock.withLock { records[Key(service: service, account: account)] = data }
    }
    func delete(service: String, account: String, isActive: @Sendable () -> Bool) throws {
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        _ = lock.withLock { records.removeValue(forKey: Key(service: service, account: account)) }
    }
    func history() -> [Key] { lock.withLock { calls } }
}

@Suite("Private vault service request and policy boundaries")
struct VaultRequestProcessorTests {
    @Test("Invalid wire versions, operations, UUIDs and payload shapes cannot reach Keychain", arguments: [
        "version", "operation", "lowercase", "non-uuid", "native-service", "recovery-key", "missing-write", "read-payload", "delete-payload", "validate-payload", "foreign-service", "service-prefix", "desktop-account-on-vault"
    ])
    func malformedRequestNeverTouchesBackend(_ mode: String) {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        let account: String
        switch mode {
        case "lowercase": account = fixtureAccount.lowercased()
        case "non-uuid": account = fixtureAccount + "\n"
        case "native-service": account = "Claude Code-credentials"
        case "recovery-key": account = "claude|fixture-digest|rotation"
        case "desktop-account-on-vault": account = "desktop-profile-" + fixtureAccount
        default: account = fixtureAccount
        }
        let operation = mode == "operation" ? "export" : mode == "missing-write" ? "write" : mode == "delete-payload" ? "delete" : mode == "validate-payload" ? "validate" : "read"
        let data = ["read-payload", "delete-payload", "validate-payload"].contains(mode) ? Data("fixture-payload".utf8) : nil
        let result = request(processor(backend), operation: operation, data: data,
                             version: mode == "version" ? AgentSwapVaultWire.version + 1 : AgentSwapVaultWire.version,
                             service: mode == "foreign-service" ? "Claude Code-credentials" : mode == "service-prefix" ? AgentSwapVaultWire.service + ".other" : AgentSwapVaultWire.service,
                             account: account)
        #expect(result.status == errSecParam)
        #expect(result.data == nil)
        #expect(backend.history().isEmpty)
        #expect(backend.interaction.history().isEmpty)
    }

    @Test("All three app services route exact bytes to their own allowed account namespace")
    func threeOwnedServicesRemainSeparated() {
        let backend = ServiceRoutingBackend()
        let processor = VaultRequestProcessor(backend: backend, gate: VaultInteractionGate(controller: FixtureInteraction()))
        let keys: [ServiceRoutingBackend.Key] = [
            .init(service: AgentSwapVaultWire.service, account: fixtureAccount),
            .init(service: AgentSwapVaultWire.desktopService, account: "desktop-profile-" + fixtureAccount),
            .init(service: AgentSwapVaultWire.recoveryService, account: "claude|" + String(repeating: "a", count: 32) + "|rotation")
        ]
        func call(_ key: ServiceRoutingBackend.Key, operation: String, data: Data? = nil) -> VaultServiceReply {
            processor.execute(version: 1, service: key.service, operation: operation, account: key.account,
                              data: data, interactionAllowed: false, isActive: { true })
        }
        for (index, key) in keys.enumerated() {
            let bytes = Data([UInt8(index), 0, 255])
            #expect(call(key, operation: "write", data: bytes).data == bytes)
        }
        for (index, key) in keys.enumerated() {
            #expect(call(key, operation: "read").data == Data([UInt8(index), 0, 255]))
            #expect(call(key, operation: "validate").status == errSecSuccess)
        }
        let beforeInvalid = backend.history()
        for source in keys {
            for destination in keys where source.service != destination.service {
                let wrongNamespace = ServiceRoutingBackend.Key(service: destination.service, account: source.account)
                let denied = call(wrongNamespace, operation: "write", data: Data("fixture-invalid".utf8))
                #expect(denied.status == errSecParam && denied.data == nil)
            }
        }
        #expect(backend.history() == beforeInvalid)
        for key in keys { #expect(call(key, operation: "delete").status == errSecSuccess) }
        #expect(Set(backend.history()) == Set(keys))
    }

    @Test("An absent item is distinguished from denial and malformed storage", arguments: [
        errSecSuccess, errSecAuthFailed, errSecInteractionNotAllowed, errSecDuplicateItem, errSecParam
    ])
    func absenceIsNotAnAccessFailure(_ status: OSStatus) {
        let backend = FixtureBackend()
        if status != errSecSuccess { backend.failReads(status) }
        let result = request(processor(backend))
        #expect(result.status == (status == errSecSuccess ? errSecItemNotFound : status))
        #expect(result.data == nil)
        #expect(backend.history() == ["read"])
    }

    @Test("Validation checks existing read permission or real absence without changing data", arguments: [false, true])
    func validationHasNoMutation(_ exists: Bool) {
        let original = exists ? Data("fixture-original".utf8) : nil
        let backend = FixtureBackend(original)
        let result = request(processor(backend), operation: "validate")
        #expect(result.status == errSecSuccess && result.data == nil)
        #expect(backend.history() == ["read"])
        #expect(backend.value() == original)
    }

    @Test("Read denial prevents write and delete before any mutation", arguments: ["write", "delete"])
    func existingItemMustBeReadableBeforeMutation(_ operation: String) {
        let original = Data("fixture-original".utf8)
        let backend = FixtureBackend(original)
        backend.failReads(errSecAuthFailed)
        let result = request(processor(backend), operation: operation, data: operation == "write" ? Data("fixture-new".utf8) : nil)
        #expect(result.status == errSecAuthFailed && result.data == nil)
        #expect(backend.history() == ["read"])
        #expect(backend.value() == original)
    }

    @Test("Large opaque and empty records return exact durable readback without a native CLI size limit", arguments: [0, 3 * 1_024 * 1_024])
    func writesReturnActualReadback(_ count: Int) {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        let data = Data(repeating: 0xFF, count: count)
        let result = request(processor(backend), operation: "write", data: data)
        #expect(result.status == errSecSuccess && result.data == data)
        #expect(backend.history() == ["read", "write", "read"])
        #expect(backend.value() == data)
    }

    @Test("A successful SDK update with different readback never reports durable success")
    func differentReadbackFails() {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        backend.changeWriteReadback(Data("fixture-other-image".utf8))
        let result = request(processor(backend), operation: "write", data: Data("fixture-new".utf8))
        #expect(result.status == errSecIO && result.data == nil)
        #expect(backend.history() == ["read", "write", "read"])
    }

    @Test("Readback denial after a committed write remains an ambiguous failure")
    func deniedReadbackCannotReportSuccess() {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        backend.failRead(number: 2, status: errSecAuthFailed)
        let data = Data("fixture-new".utf8)
        let result = request(processor(backend), operation: "write", data: data)
        #expect(result.status == errSecAuthFailed && result.data == nil)
        #expect(backend.value() == data)
        #expect(backend.history() == ["read", "write", "read"])
    }

    @Test("Ambiguous write failures are returned without rollback, retries or payload disclosure", arguments: [false, true])
    func ambiguousWriteDoesNotInventSuccess(_ committed: Bool) {
        let original = Data("fixture-original".utf8), new = Data("fixture-new".utf8)
        let backend = FixtureBackend(original)
        backend.failWrites(errSecAuthFailed, afterCommit: committed)
        let result = request(processor(backend), operation: "write", data: new)
        #expect(result.status == errSecAuthFailed && result.data == nil)
        #expect(backend.history() == ["read", "write"])
        #expect(backend.value() == (committed ? new : original))
    }

    @Test("Delete is authorized, verified and idempotent", arguments: [false, true])
    func deleteVerifiesAbsence(_ exists: Bool) {
        let backend = FixtureBackend(exists ? Data("fixture-original".utf8) : nil)
        let result = request(processor(backend), operation: "delete")
        #expect(result.status == errSecSuccess && result.data == nil)
        #expect(backend.value() == nil)
        #expect(backend.history() == (exists ? ["read", "delete", "read"] : ["read"]))
    }

    @Test("Process UI policy is scoped to the SDK call and restored", arguments: [false, true], [false, true])
    func policyIsRestored(_ initial: Bool, _ requested: Bool) {
        let controller = FixtureInteraction(allowed: initial)
        let backend = FixtureBackend(Data("fixture-original".utf8), interaction: controller)
        let result = request(processor(backend), interactive: requested)
        #expect(result.status == errSecSuccess)
        #expect(backend.interactionHistory() == [requested])
        #expect(controller.isAllowed() == initial)
        #expect(controller.history() == (initial == requested ? [] : [requested, initial]))
    }

    @Test("Failed reads also restore UI policy and restoration failure suppresses data")
    func failureRestoresOrReportsPolicy() {
        let denied = FixtureBackend(Data("fixture-original".utf8))
        denied.failReads(errSecAuthFailed)
        #expect(request(processor(denied)).status == errSecAuthFailed)
        #expect(denied.interaction.isAllowed())
        #expect(denied.interaction.history() == [false, true])

        let failedRestoration = FixtureBackend(Data("fixture-original".utf8))
        failedRestoration.interaction.fail(change: 2)
        let result = request(processor(failedRestoration))
        #expect(result.status == errSecAuthFailed && result.data == nil)
    }

    @Test("Failure to establish the requested process UI policy prevents all SDK calls")
    func policyFailurePreventsAccess() {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        backend.interaction.fail(change: 1)
        let result = request(processor(backend))
        #expect(result.status == errSecAuthFailed && result.data == nil)
        #expect(backend.history().isEmpty)
    }

    @Test("A background request never waits behind an interactive SDK operation")
    func backgroundFailsImmediatelyWhenBusy() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let backend = FixtureBackend(Data("fixture-original".utf8))
        backend.beforeRead { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        let processor = processor(backend)
        DispatchQueue.global().async {
            _ = request(processor, interactive: true)
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let result = request(processor)
        #expect(result.status == errSecInteractionNotAllowed && result.data == nil)
        release.signal()
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(backend.history() == ["read"])
        #expect(backend.interactionHistory() == [true])
    }

    @Test("Invalidation observed after the authorization read drops the pending mutation")
    func invalidatedRequestCannotMutate() {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        let state = VaultConnectionState()
        #expect(state.ping(Data(repeating: 7, count: 32)))
        backend.beforeRead { state.invalidate() }
        let result = request(processor(backend), operation: "write", data: Data("fixture-new".utf8), isActive: { state.mayExecute() })
        #expect(result.status == errSecNotAvailable && result.data == nil)
        #expect(backend.history() == ["read"])
        #expect(backend.value() == Data("fixture-original".utf8))
    }

    @Test("Invalidation during the backend's final authorization step also drops mutation", arguments: ["write", "delete"])
    func invalidatedDuringFinalAuthorizationCannotMutate(_ operation: String) {
        let original = Data("fixture-original".utf8)
        let backend = FixtureBackend(original)
        let state = VaultConnectionState()
        #expect(state.ping(Data(repeating: 7, count: 32)))
        backend.beforeMutation { state.invalidate() }
        let result = request(processor(backend), operation: operation,
                             data: operation == "write" ? Data("fixture-new".utf8) : nil,
                             isActive: { state.mayExecute() })
        #expect(result.status == errSecNotAvailable && result.data == nil)
        #expect(backend.history() == ["read"])
        #expect(backend.value() == original)
    }

    @Test("A credential RPC requires a valid nonce exchange on its still-active connection")
    func connectionHandshakeIsRequired() async {
        let backend = FixtureBackend(Data("fixture-original".utf8))
        let handler = VaultConnectionHandler(processor: processor(backend))
        func call() async -> VaultServiceReply {
            await withCheckedContinuation { continuation in
                handler.execute(version: AgentSwapVaultWire.version, operation: "read", account: fixtureAccount,
                                data: nil, interactionAllowed: false) { status, data in
                    continuation.resume(returning: .init(status: status, data: data))
                }
            }
        }
        #expect(await call().status == errSecAuthFailed)
        #expect(backend.history().isEmpty)
        let invalidPing = await withCheckedContinuation { continuation in
            handler.ping(Data(repeating: 1, count: 31)) { version, nonce in continuation.resume(returning: (version, nonce)) }
        }
        #expect(invalidPing.0 == 0 && invalidPing.1.isEmpty)
        #expect(await call().status == errSecAuthFailed)
        let nonce = Data(repeating: 7, count: 32)
        let validPing = await withCheckedContinuation { continuation in
            handler.ping(nonce) { version, echoed in continuation.resume(returning: (version, echoed)) }
        }
        #expect(validPing.0 == AgentSwapVaultWire.version && validPing.1 == nonce)
        #expect(await call().data == Data("fixture-original".utf8))
        handler.state.invalidate()
        #expect(await call().status == errSecAuthFailed)
        #expect(backend.history() == ["read"])
    }
}
