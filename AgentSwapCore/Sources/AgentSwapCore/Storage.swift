import Foundation
import Security
import CryptoKit
import Darwin
import LocalAuthentication

public enum KeychainInteractionMode: Sendable { case noninteractive, interactive }
public enum KeychainInteraction {
    /// Explicit user actions opt in. Actor hops inherit the task-local value; unattended work does not prompt.
    @TaskLocal public static var mode: KeychainInteractionMode = .noninteractive
}

protocol KeychainInteractionControlling: Sendable {
    func isAllowed() throws -> Bool
    func setAllowed(_ allowed: Bool) throws
}

private struct LegacyKeychainInteractionControl: KeychainInteractionControlling {
    func isAllowed() throws -> Bool {
        var allowed = DarwinBoolean(false)
        // Required for legacy macOS Keychain ACLs: SecItem.h explicitly excludes them from modern UI suppression flags.
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        guard status == errSecSuccess else { throw AgentSwapError.storage("Keychain 상호작용 상태를 확인하지 못했습니다 (\(status)).") }
        return allowed.boolValue
    }
    func setAllowed(_ allowed: Bool) throws {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        guard status == errSecSuccess else { throw AgentSwapError.storage("Keychain 상호작용 정책을 적용하지 못했습니다 (\(status)).") }
    }
}

/// Safety invariant: every SystemKeychainAccess Security call and process-global interaction change
/// runs synchronously under this one recursive lock. No task can suspend while holding it.
final class KeychainInteractionGate: @unchecked Sendable {
    static let system = KeychainInteractionGate(controller: LegacyKeychainInteractionControl())
    private let lock = NSRecursiveLock()
    private let controller: any KeychainInteractionControlling
    init(controller: any KeychainInteractionControlling) { self.controller = controller }
    func perform<T>(_ operation: () throws -> T) throws -> T {
        if KeychainInteraction.mode == .noninteractive {
            guard lock.try() else { throw AgentSwapError.storage("다른 Keychain 인증 요청이 진행 중입니다. 현재 로그인 가져오기를 완료한 뒤 다시 조회해 주세요.") }
        } else { lock.lock() }
        defer { lock.unlock() }
        let previous = try controller.isAllowed()
        let desired = KeychainInteraction.mode == .interactive
        if previous != desired { try controller.setAllowed(desired) }
        let result: Result<T, any Error>
        do { result = .success(try operation()) } catch { result = .failure(error) }
        // Restoration is checked even when the Security operation throws; never leave a silent policy change.
        if previous != desired { try controller.setAllowed(previous) }
        return try result.get()
    }
}

/// A synchronous boundary keeps each local read/modify/write transaction free of actor suspension.
/// Implementations must serialize any mutable state internally; tests inject an in-memory implementation.
public protocol KeychainAccess: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct SystemKeychainAccess: KeychainAccess {
    public init() {}
    private func query(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = KeychainInteraction.mode == .noninteractive
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }
    public func read(service: String, account: String) throws -> Data? {
        try KeychainInteractionGate.system.perform { try readWithoutInteractionChange(service: service, account: account) }
    }
    private func readWithoutInteractionChange(service: String, account: String) throws -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    public func write(_ data: Data, service: String, account: String) throws {
        try KeychainInteractionGate.system.perform { try writeWithoutInteractionChange(data, service: service, account: account) }
    }
    private func writeWithoutInteractionChange(_ data: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
        guard try readWithoutInteractionChange(service: service, account: account) == data else {
            throw AgentSwapError.storage("Keychain 저장 결과를 확인하지 못했습니다.")
        }
    }
    public func delete(service: String, account: String) throws {
        try KeychainInteractionGate.system.perform {
            let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        }
    }
    private func failure(_ status: OSStatus) -> AgentSwapError {
        if status == errSecInteractionNotAllowed || (status == errSecAuthFailed && KeychainInteraction.mode == .noninteractive) {
            return .storage("Keychain 접근 허용 또는 잠금 해제가 필요합니다. 계정 상세에서 저장된 인증 접근 허용을 누르거나 현재 로그인 가져오기를 진행해 주세요.")
        }
        return .storage("Keychain 접근에 실패했습니다 (\(status)). 접근 권한과 잠금 상태를 확인해 주세요.")
    }
}

public actor KeychainSecretStore: SecretStore {
    public static let service = "net.mercen.agentswap"
    private let keychain: any KeychainAccess
    public init(keychain: any KeychainAccess = SystemKeychainAccess()) { self.keychain = keychain }
    public func load(accountID: UUID) throws -> Credential? {
        guard let data = try keychain.read(service: Self.service, account: accountID.uuidString) else { return nil }
        do { return try JSONDecoder().decode(Credential.self, from: data) }
        catch { throw AgentSwapError.storage("저장된 인증 자료의 형식을 읽지 못했습니다.") }
    }
    public func save(_ credential: Credential, accountID: UUID) throws {
        try keychain.write(JSONEncoder().encode(credential), service: Self.service, account: accountID.uuidString)
    }
    public func delete(accountID: UUID) throws {
        try keychain.delete(service: Self.service, account: accountID.uuidString)
    }
}

public protocol AuthFileAccess: Sendable {
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    func delete(_ url: URL) throws
}

/// Atomic, private file replacement. Auth files and temporary files are never made world-readable.
public struct AtomicAuthFileAccess: AuthFileAccess {
    public init() {}
    public func read(_ url: URL) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd == -1 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw fileError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 8 * 1_024 * 1_024 else { throw fileError() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { throw fileError() }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    public func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try refuseSymlink(url)
        let temporary = parent.appendingPathComponent(".agentswap-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fileError() }
        defer { Darwin.close(fd); _ = Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count == -1 && errno == EINTR { continue }
                guard count > 0 else { throw fileError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw fileError() }
        try refuseSymlink(url)
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw fileError() }
        try synchronizeDirectory(parent)
    }
    public func delete(_ url: URL) throws {
        try refuseSymlink(url)
        if Darwin.unlink(url.path) == -1 {
            if errno == ENOENT { return }
            throw fileError()
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }
    private func refuseSymlink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw AgentSwapError.unsupported("인증 파일이 일반 파일이 아니므로 변경을 중단했습니다.")
            }
        } else if errno != ENOENT { throw fileError() }
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw fileError() }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw fileError() }
    }
    private func fileError() -> AgentSwapError { .storage("파일을 안전하게 읽거나 저장하지 못했습니다 (\(errno)).") }
}

public actor JSONStateStore: StateStore {
    public let url: URL
    private let files: any AuthFileAccess
    public init(directory: URL? = nil, files: any AuthFileAccess = AtomicAuthFileAccess()) {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentSwap", isDirectory: true)
        url = directory.appendingPathComponent("state.json")
        self.files = files
    }
    public func load() throws -> PersistedState {
        guard let data = try files.read(url) else { return .init() }
        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard state.schemaVersion == 1 else { throw AgentSwapError.unsupported("새로운 설정 형식을 발견해 변경을 중단했습니다.") }
            return state
        } catch let error as AgentSwapError { throw error }
        catch { throw AgentSwapError.storage("계정 설정을 읽지 못했습니다. 원본 파일을 보존했습니다.") }
    }
    public func save(_ state: PersistedState) throws {
        guard state.schemaVersion == 1 else { throw AgentSwapError.unsupported("지원하지 않는 설정 형식입니다.") }
        // Refuse overwriting an existing newer/corrupt document.
        if try files.read(url) != nil { _ = try load() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(encoder.encode(state), to: url)
    }
}

func storageDigest(_ value: String, prefix: Int) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(prefix).description
}

func authObject(_ data: Data, name: String) throws -> [String: Any] {
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentSwapError.unsupported("\(name) 인증 형식을 지원하지 않습니다.") }
        return object
    } catch let error as AgentSwapError { throw error }
    catch { throw AgentSwapError.unsupported("\(name) 인증 JSON 형식을 지원하지 않습니다.") }
}

func authData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
