import Foundation
import Security
import AgentSwapVaultProtocol

/// Only the three compiled application-owned services are exposed. Provider-native
/// credentials and arbitrary service/account combinations never reach the SDK.
final class SystemVaultKeychainBackend: VaultKeychainBackend, @unchecked Sendable {
    private let isolatedKeychain: SecKeychain?

    init() { isolatedKeychain = nil }

    /// Tests create a separate Keychain and pin every query and insertion to it.
    /// Production construction has no path, search-list or service override.
    init(isolatedKeychain: SecKeychain) { self.isolatedKeychain = isolatedKeychain }

    private struct Item {
        let reference: SecKeychainItem
        let keychain: SecKeychain
    }

    private func query(service: String, account: String) throws -> [String: Any] {
        guard AgentSwapVaultWire.isAllowed(service: service, account: account) else { throw VaultServiceFailure(status: errSecParam) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecAttrSynchronizable as String: false]
        if let isolatedKeychain { query[kSecMatchSearchList as String] = [isolatedKeychain] }
        return query
    }

    private func item(service: String, account: String) throws -> Item? {
        var lookup = try query(service: service, account: account)
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        lookup[kSecReturnRef as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
        guard let references = output as? [Any], references.count == 1 else {
            throw VaultServiceFailure(status: errSecDuplicateItem)
        }
        let reference = references[0] as CFTypeRef
        guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else {
            throw VaultServiceFailure(status: errSecParam)
        }
        let item = unsafeBitCast(reference, to: SecKeychainItem.self)
        var keychain: SecKeychain?
        let copied = SecKeychainItemCopyKeychain(item, &keychain)
        guard copied == errSecSuccess, let keychain else {
            throw VaultServiceFailure(status: copied == errSecSuccess ? errSecParam : copied)
        }
        return .init(reference: item, keychain: keychain)
    }

    private func pinnedQuery(service: String, account: String, item: Item) throws -> [String: Any] {
        var query = try query(service: service, account: account)
        query[kSecMatchSearchList as String] = [item.keychain]
        query[kSecMatchItemList as String] = [item.reference]
        return query
    }

    func read(service: String = AgentSwapVaultWire.service, account: String) throws -> Data? {
        guard let item = try item(service: service, account: account) else { return nil }
        return try read(service: service, account: account, item: item)
    }

    private func read(service: String, account: String, item: Item) throws -> Data {
        var query = try pinnedQuery(service: service, account: account, item: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        guard status == errSecSuccess, let data = output as? Data else {
            throw VaultServiceFailure(status: status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    func write(_ data: Data, service: String = AgentSwapVaultWire.service, account: String,
               isActive: @Sendable () -> Bool = { true }) throws {
        if let item = try item(service: service, account: account) {
            // A ref lookup does not prove permission to decrypt. Require that read
            // before updating, including callers which use this backend directly.
            _ = try read(service: service, account: account, item: item)
            guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
            let status = SecItemUpdate(try pinnedQuery(service: service, account: account, item: item) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
            return
        }
        let keychain: SecKeychain
        if let isolatedKeychain { keychain = isolatedKeychain }
        else {
            var result: SecKeychain?
            let status = SecKeychainCopyDefault(&result)
            guard status == errSecSuccess, let result else {
                throw VaultServiceFailure(status: status == errSecSuccess ? errSecNoDefaultKeychain : status)
            }
            keychain = result
        }
        var trusted: SecTrustedApplication?
        let trustStatus = SecTrustedApplicationCreateFromPath(nil, &trusted)
        guard trustStatus == errSecSuccess, let trusted else {
            throw VaultServiceFailure(status: trustStatus == errSecSuccess ? errSecParam : trustStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("AgentSwap Vault" as CFString, [trusted] as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw VaultServiceFailure(status: accessStatus == errSecSuccess ? errSecParam : accessStatus)
        }
        var add = try query(service: service, account: account)
        add.removeValue(forKey: kSecMatchSearchList as String)
        add[kSecUseKeychain as String] = keychain
        add[kSecAttrAccess as String] = access
        add[kSecValueData as String] = data
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
    }

    func delete(service: String = AgentSwapVaultWire.service, account: String,
                isActive: @Sendable () -> Bool = { true }) throws {
        guard let item = try item(service: service, account: account) else { return }
        _ = try read(service: service, account: account, item: item)
        guard isActive() else { throw VaultServiceFailure(status: errSecNotAvailable) }
        let status = SecItemDelete(try pinnedQuery(service: service, account: account, item: item) as CFDictionary)
        guard status == errSecSuccess else { throw VaultServiceFailure(status: status) }
    }
}
