import Foundation
import Security
import Darwin
import AgentSwapVaultProtocol

/// Records only method names, process IDs, service kinds, and synthetic sizes.
/// Every actual credential operation is delegated to the production SDK backend.
final class RecordingBackend: VaultKeychainBackend, @unchecked Sendable {
    private let backend: SystemVaultKeychainBackend
    private let lock = NSLock()
    init(keychain: SecKeychain) { backend = SystemVaultKeychainBackend(isolatedKeychain: keychain) }

    private func record(_ operation: String, service: String, size: Int = 0) throws {
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, !allowed.boolValue else {
            throw VaultServiceFailure(status: errSecInteractionNotAllowed)
        }
        let kind = service == AgentSwapVaultWire.service ? "vault" : service == AgentSwapVaultWire.recoveryService ? "recovery" : "desktop"
        let row: [String: Any] = ["operation": operation, "service": kind, "size": size, "helper": getpid()]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0a)
        try lock.withLock {
            let descriptor = open(FixtureConfiguration.eventPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw VaultServiceFailure(status: errSecIO) }
            defer { close(descriptor) }
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard count == data.count else { throw VaultServiceFailure(status: errSecIO) }
        }
    }
    func read(service: String, account: String) throws -> Data? {
        try record("read", service: service)
        return try backend.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, isActive: @Sendable () -> Bool) throws {
        try record("write", service: service, size: data.count)
        try backend.write(data, service: service, account: account, isActive: isActive)
    }
    func delete(service: String, account: String, isActive: @Sendable () -> Bool) throws {
        try record("delete", service: service)
        try backend.delete(service: service, account: account, isActive: isActive)
    }
}

@main
struct FixtureServerMain {
    static func main() {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(2) }
        var securitySession: SecuritySessionId = noSecuritySession
        var sessionAttributes: SessionAttributeBits = []
        let sessionStatus = SessionGetInfo(callerSecuritySession, &securitySession, &sessionAttributes)
        func startup(_ stage: String, status: OSStatus = errSecSuccess) {
            let row: [String: Any] = ["stage": stage, "status": status, "pid": getpid(),
                                      "securitySessionID": securitySession,
                                      "securitySessionAttributes": sessionAttributes.rawValue]
            var data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data()
            data.append(0x0a)
            let path = FixtureConfiguration.eventPath + ".startup"
            let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            if descriptor >= 0 { _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }; close(descriptor) }
        }
        startup("launch")
        startup("security-session", status: sessionStatus)
        guard sessionStatus == errSecSuccess, securitySession != noSecuritySession else { exit(3) }
        var keychain: SecKeychain?
        let status: OSStatus
        if FileManager.default.fileExists(atPath: FixtureConfiguration.keychainPath) {
            status = SecKeychainOpen(FixtureConfiguration.keychainPath, &keychain)
        } else {
            // The random synthetic password exists only in this private fixture's
            // generated configuration. It never travels in argv or environment.
            status = FixtureConfiguration.keychainPassword.withCString {
                SecKeychainCreate(FixtureConfiguration.keychainPath, UInt32(FixtureConfiguration.keychainPassword.utf8.count), $0, false, nil, &keychain)
            }
        }
        startup("opened-keychain", status: status)
        guard status == errSecSuccess, let keychain else { exit(3) }
        let unlocked = FixtureConfiguration.keychainPassword.withCString {
            SecKeychainUnlock(keychain, UInt32(FixtureConfiguration.keychainPassword.utf8.count), $0, true)
        }
        startup("unlocked-keychain", status: unlocked)
        guard unlocked == errSecSuccess else { exit(3) }
        // This kills only the disposable fixture if its client disappears.
        DispatchQueue.global().asyncAfter(deadline: .now() + 150) { exit(0) }
        let processor = VaultRequestProcessor(backend: RecordingBackend(keychain: keychain))
        let service = VaultXPCService(processor: processor, applicationRequirement: FixtureConfiguration.applicationRequirement)
        service.run()
        withExtendedLifetime(service) { dispatchMain() }
    }
}
