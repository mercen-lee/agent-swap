// Executed by a verified Apple-signed Swift interpreter. Credential bytes arrive only on stdin;
// they are never embedded in this resource, command arguments, diagnostics, or compiler caches.
import Foundation
import Security

private struct Request: Decodable {
    let service: String
    let account: String
    let data: Data
    let interactionAllowed: Bool
}

private let maximumDataBytes = 1_024 * 1_024
private let maximumRequestBytes = 1_500_000

private func execute() -> OSStatus {
    var input = Data()
    do {
        while let bytes = try FileHandle.standardInput.read(upToCount: 16_384), !bytes.isEmpty {
            guard input.count + bytes.count <= maximumRequestBytes else { return errSecParam }
            input.append(bytes)
        }
    } catch { return errSecParam }
    guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          Set(object.keys) == ["service", "account", "data", "interactionAllowed"],
          let request = try? JSONDecoder().decode(Request.self, from: input),
          !request.data.isEmpty, request.data.count <= maximumDataBytes,
          !request.account.isEmpty, request.account.utf8.count <= 256,
          request.account.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
              || (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 }) else { return errSecParam }
    let prefix = "Claude Code-credentials-"
    if request.service != "Claude Code-credentials" {
        guard request.service.hasPrefix(prefix) else { return errSecParam }
        let suffix = request.service.dropFirst(prefix.count)
        guard suffix.count == 8, suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return errSecParam
        }
    }
    // This policy belongs to the interpreter process itself. Parent process policy does not
    // propagate across exec. Background writes cannot wait for an authorization dialog.
    let policy = SecKeychainSetUserInteractionAllowed(request.interactionAllowed)
    guard policy == errSecSuccess else { return policy }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: request.service,
                               kSecAttrAccount as String: request.account]
    var lookup = query
    lookup[kSecReturnRef as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitAll
    var output: CFTypeRef?
    let found = SecItemCopyMatching(lookup as CFDictionary, &output)
    if found == errSecSuccess {
        // A data-protection reference or duplicate items across keychains have no supported
        // Claude CLI authority. Pin the single existing legacy item to its owning keychain.
        guard let references = output as? [Any], references.count == 1 else { return errSecDuplicateItem }
        let reference = references[0] as CFTypeRef
        guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else { return errSecParam }
        let item = unsafeBitCast(reference, to: SecKeychainItem.self)
        var keychain: SecKeychain?
        let copied = SecKeychainItemCopyKeychain(item, &keychain)
        guard copied == errSecSuccess, let keychain else { return copied == errSecSuccess ? errSecParam : copied }
        var update = query
        update[kSecMatchSearchList as String] = [keychain]
        return SecItemUpdate(update as CFDictionary, [kSecValueData as String: request.data] as CFDictionary)
    }
    guard found == errSecItemNotFound else { return found }
    // A new item is created in one operation, so the transaction journal still describes only
    // absence and the exact planned data. Trust only the native consumer, never all applications.
    var trusted: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath("/usr/bin/security", &trusted)
    guard trustedStatus == errSecSuccess, let trusted else { return trustedStatus }
    var access: SecAccess?
    let accessStatus = SecAccessCreate(request.service as CFString, [trusted] as CFArray, &access)
    guard accessStatus == errSecSuccess, let access else { return accessStatus }
    var add = query
    add[kSecAttrAccess as String] = access
    add[kSecValueData as String] = request.data
    return SecItemAdd(add as CFDictionary, nil)
}

// Only a numeric Security status leaves the interpreter. In particular, no caught error or
// Keychain attribute description can reveal authentication or account metadata.
FileHandle.standardOutput.write(Data("\(execute())\n".utf8))
