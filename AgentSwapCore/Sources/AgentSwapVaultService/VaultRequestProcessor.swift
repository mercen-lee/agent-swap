import Foundation
import Security
import AgentSwapVaultProtocol

struct VaultServiceReply: Sendable {
    let status: OSStatus
    let data: Data?

    static func failure(_ status: OSStatus) -> Self { .init(status: status, data: nil) }
}

struct VaultServiceFailure: Error {
    let status: OSStatus
}

protocol VaultKeychainBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String, isActive: @Sendable () -> Bool) throws
    func delete(service: String, account: String, isActive: @Sendable () -> Bool) throws
}

protocol VaultInteractionControlling: Sendable {
    func isAllowed() throws -> Bool
    func setAllowed(_ allowed: Bool) throws
}

struct SystemVaultInteractionControl: VaultInteractionControlling {
    func isAllowed() throws -> Bool {
        var allowed = DarwinBoolean(false)
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
        return allowed.boolValue
    }

    func setAllowed(_ allowed: Bool) throws {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
    }
}

/// Legacy Keychain interaction policy belongs to the whole helper process. One gate
/// covers every connection and the complete synchronous SDK operation and restoration.
final class VaultInteractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: any VaultInteractionControlling

    init(controller: any VaultInteractionControlling = SystemVaultInteractionControl()) {
        self.controller = controller
    }

    func perform(interactionAllowed: Bool, operation: () throws -> VaultServiceReply) -> VaultServiceReply {
        if interactionAllowed { lock.lock() }
        else if !lock.try() { return .failure(errSecInteractionNotAllowed) }
        defer { lock.unlock() }

        do {
            let previous = try controller.isAllowed()
            if previous != interactionAllowed { try controller.setAllowed(interactionAllowed) }
            let result: Result<VaultServiceReply, any Error>
            do { result = .success(try operation()) }
            catch { result = .failure(error) }
            // Even a failed read or write must restore the previous process policy.
            if previous != interactionAllowed { try controller.setAllowed(previous) }
            return try result.get()
        } catch let error as VaultServiceFailure {
            return .failure(error.status)
        } catch {
            return .failure(errSecInternalComponent)
        }
    }
}

/// A connection cannot execute credential requests until its harmless nonce exchange.
/// Invalidation remains independent of the operation gate, so queued requests can stop.
final class VaultConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var handshaken = false

    func ping(_ nonce: Data) -> Bool {
        lock.withLock {
            guard active, nonce.count == 32 else { return false }
            handshaken = true
            return true
        }
    }

    func mayExecute() -> Bool { lock.withLock { active && handshaken } }
    func invalidate() { lock.withLock { active = false; handshaken = false } }
}

final class VaultRequestProcessor: Sendable {
    private let backend: any VaultKeychainBackend
    private let gate: VaultInteractionGate

    init(backend: any VaultKeychainBackend = SystemVaultKeychainBackend(),
         gate: VaultInteractionGate = VaultInteractionGate()) {
        self.backend = backend
        self.gate = gate
    }

    func execute(version: Int, service: String = AgentSwapVaultWire.service, operation: String,
                 account: String, data: Data?, interactionAllowed: Bool,
                 isActive: @Sendable () -> Bool) -> VaultServiceReply {
        guard version == AgentSwapVaultWire.version, AgentSwapVaultWire.isAllowed(service: service, account: account),
              ["read", "write", "delete", "validate"].contains(operation),
              operation != "write" || data != nil,
              operation == "write" || data == nil else {
            return .failure(errSecParam)
        }
        guard isActive() else { return .failure(errSecNotAvailable) }
        return gate.perform(interactionAllowed: interactionAllowed) {
            guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
            // This read authorizes an existing item before any SDK mutation. It also
            // rejects duplicate or nonlegacy entries in the concrete backend.
            let previous = try backend.read(service: service, account: account)
            guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
            switch operation {
            case "read":
                guard let previous else { return .failure(errSecItemNotFound) }
                return .init(status: errSecSuccess, data: previous)
            case "validate":
                return .init(status: errSecSuccess, data: nil)
            case "write":
                guard let data else { throw VaultServiceFailure(status: errSecParam) }
                try backend.write(data, service: service, account: account, isActive: isActive)
                let readback = try backend.read(service: service, account: account)
                guard readback == data else { throw VaultServiceFailure(status: errSecIO) }
                guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
                return .init(status: errSecSuccess, data: readback)
            case "delete":
                if previous != nil {
                    try backend.delete(service: service, account: account, isActive: isActive)
                    guard try backend.read(service: service, account: account) == nil else { throw VaultServiceFailure(status: errSecIO) }
                }
                guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
                return .init(status: errSecSuccess, data: nil)
            default:
                throw VaultServiceFailure(status: errSecParam)
            }
        }
    }
}
