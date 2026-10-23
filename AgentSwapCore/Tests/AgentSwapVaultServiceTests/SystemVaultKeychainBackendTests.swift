import Foundation
import Security
import Testing
import AgentSwapVaultProtocol
@testable import AgentSwapVaultService

private let isolatedFixtureLock = NSLock()

private struct KeychainConfigurationSnapshot {
    let searchList: CFArray
    let defaultPath: Data

    init() throws {
        var list: CFArray?, keychain: SecKeychain?
        let listed = SecKeychainCopySearchList(&list)
        let copied = SecKeychainCopyDefault(&keychain)
        guard listed == errSecSuccess, let list, copied == errSecSuccess, let keychain else {
            throw VaultServiceFailure(status: listed == errSecSuccess ? copied : listed)
        }
        var size: UInt32 = 4_096
        var path = [CChar](repeating: 0, count: Int(size))
        let status = SecKeychainGetPath(keychain, &size, &path)
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
        searchList = list
        defaultPath = Data(path.prefix(Int(size)).map { UInt8(bitPattern: $0) })
    }

    func stillMatches() -> Bool {
        guard let current = try? Self() else { return false }
        return CFEqual(searchList, current.searchList) && defaultPath == current.defaultPath
    }
}

/// This fixture only adds/deletes its own temporary Keychain. SecKeychainCreate can
/// temporarily add it to the user's search list; deleting that exact Keychain removes
/// that entry. We never replace the user's complete search list or default Keychain.
private final class IsolatedVaultKeychainFixture {
    let keychain: SecKeychain
    let directory: URL
    let before: KeychainConfigurationSnapshot
    private let previousInteraction: Bool
    private var closed = false

    init() throws {
        isolatedFixtureLock.lock()
        let control = SystemVaultInteractionControl()
        let previous: Bool
        do {
            previous = try control.isAllowed()
            try control.setAllowed(false)
        } catch {
            isolatedFixtureLock.unlock()
            throw error
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapVaultBackend-\(UUID().uuidString)")
        do {
            let before = try KeychainConfigurationSnapshot()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("fixture.keychain-db").path
            let password = Array("fixture-only-private-keychain".utf8)
            var result: SecKeychain?
            let status = password.withUnsafeBytes {
                SecKeychainCreate(path, UInt32(password.count), $0.baseAddress, false, nil, &result)
            }
            guard status == errSecSuccess, let result else {
                if let result { _ = SecKeychainDelete(result) }
                throw VaultServiceFailure(status: status == errSecSuccess ? errSecInvalidKeychain : status)
            }
            self.keychain = result
            self.directory = directory
            self.before = before
            previousInteraction = previous
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try? control.setAllowed(previous)
            isolatedFixtureLock.unlock()
            throw error
        }
    }

    func close() -> Bool {
        guard !closed else { return true }
        closed = true
        let deleted = SecKeychainDelete(keychain)
        let configurationUnchanged = before.stillMatches()
        let restored = (try? SystemVaultInteractionControl().setAllowed(previousInteraction)) != nil
        try? FileManager.default.removeItem(at: directory)
        let removed = !FileManager.default.fileExists(atPath: directory.path)
        isolatedFixtureLock.unlock()
        return deleted == errSecSuccess && configurationUnchanged && restored && removed
    }

    deinit { _ = close() }
}

@Suite("Isolated legacy vault SDK backend", .serialized)
struct SystemVaultKeychainBackendTests {
    @Test("The actual backend creates, reads, updates and deletes 3 MiB private records in all three app services without UI")
    func isolatedLargeRecordRoundTrip() throws {
        let fixture = try IsolatedVaultKeychainFixture()
        defer { #expect(fixture.close(), "Only the fixture's temporary Keychain is removed and the original configuration is preserved") }
        let backend = SystemVaultKeychainBackend(isolatedKeychain: fixture.keychain)
        let processor = VaultRequestProcessor(backend: backend)
        let identifier = UUID().uuidString
        let records = [
            (AgentSwapVaultWire.service, identifier),
            (AgentSwapVaultWire.desktopService, "desktop-profile-" + identifier),
            (AgentSwapVaultWire.recoveryService, "claude|" + String(repeating: "a", count: 32) + "|rotation")
        ]
        func call(_ record: (String, String), _ operation: String, _ data: Data? = nil) -> VaultServiceReply {
            processor.execute(version: 1, service: record.0, operation: operation, account: record.1, data: data,
                              interactionAllowed: false, isActive: { true })
        }
        let first = Data(repeating: 0xFF, count: 3 * 1_024 * 1_024)
        let second = Data(repeating: 0x42, count: first.count)
        for record in records {
            #expect(call(record, "read").status == errSecItemNotFound)
            #expect(call(record, "validate").status == errSecSuccess)
            let created = call(record, "write", first)
            #expect(created.status == errSecSuccess && created.data == first)
            let read = call(record, "read")
            #expect(read.status == errSecSuccess && read.data == first)
            // Exercise the concrete guard after its final exact-item authorization
            // read, independently of the processor's earlier active-state checks.
            do {
                try backend.write(second, service: record.0, account: record.1, isActive: { false })
                Issue.record("An inactive connection must not update a real Keychain item")
            } catch let failure as VaultServiceFailure { #expect(failure.status == errSecNotAvailable) }
            do {
                try backend.delete(service: record.0, account: record.1, isActive: { false })
                Issue.record("An inactive connection must not delete a real Keychain item")
            } catch let failure as VaultServiceFailure { #expect(failure.status == errSecNotAvailable) }
            #expect(call(record, "read").data == first)
            let updated = call(record, "write", second)
            #expect(updated.status == errSecSuccess && updated.data == second)
            #expect(call(record, "read").data == second)
        }
        for record in records {
            #expect(call(record, "read").data == second)
            #expect(call(record, "delete").status == errSecSuccess)
            #expect(call(record, "read").status == errSecItemNotFound)
            #expect(call(record, "delete").status == errSecSuccess)
        }
        #expect(!(try SystemVaultInteractionControl().isAllowed()))
    }
}
