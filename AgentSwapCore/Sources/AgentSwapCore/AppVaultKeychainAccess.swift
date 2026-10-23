import Foundation
import Security
import AgentSwapVaultProtocol

struct AppVaultReply: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol AppVaultTransport: Sendable {
    func perform(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool) throws -> AppVaultReply
}

/// App credentials always cross the same immutable, authenticated service boundary.
/// Native provider stores keep their existing compatibility boundaries. Recovery
/// and Desktop records retain their exact formats and use the same fixed identity.
public struct AppVaultKeychainAccess: KeychainAccess, KeychainWritePreflighting {
    private let transport: any AppVaultTransport
    private let fallback: any KeychainAccess

    public init() {
        self.init(transport: AuthenticatedAppVaultTransport(), fallback: SystemKeychainAccess())
    }

    init(transport: any AppVaultTransport, fallback: any KeychainAccess) {
        self.transport = transport
        self.fallback = fallback
    }

    public func read(service: String, account: String) throws -> Data? {
        guard try usesAppVault(service) else { return try fallback.read(service: service, account: account) }
        let result = try request("read", service: service, account: account)
        if result.status == errSecItemNotFound, result.data == nil { return nil }
        try requireSuccess(result)
        guard let data = result.data else { throw appVaultFailure() }
        return data
    }

    public func write(_ data: Data, service: String, account: String) throws {
        guard try usesAppVault(service) else {
            try fallback.write(data, service: service, account: account)
            return
        }
        let result = try request("write", service: service, account: account, data: data)
        try requireSuccess(result)
        // Service success includes its durable SDK readback. Verify the returned
        // bytes too; an IPC acknowledgement alone cannot satisfy SecretStore.save.
        guard result.data == data else { throw appVaultFailure() }
    }

    public func delete(service: String, account: String) throws {
        guard try usesAppVault(service) else {
            try fallback.delete(service: service, account: account)
            return
        }
        let result = try request("delete", service: service, account: account)
        guard result.data == nil else { throw appVaultFailure() }
        if result.status == errSecItemNotFound { return }
        try requireSuccess(result)
    }

    func validateWrite(_ data: Data, service: String, account: String) throws {
        guard try usesAppVault(service) else {
            if let checked = fallback as? any KeychainWritePreflighting {
                try checked.validateWrite(data, service: service, account: account)
            }
            return
        }
        let result = try request("validate", service: service, account: account)
        try requireSuccess(result)
        guard result.data == nil else { throw appVaultFailure() }
    }

    private func request(_ operation: String, service: String, account: String, data: Data? = nil) throws -> AppVaultReply {
        guard AgentSwapVaultWire.isAllowed(service: service, account: account) else {
            throw AgentSwapError.unsupported("지원하지 않는 앱 인증 항목이므로 변경을 중단했습니다.")
        }
        if !NativeSecurityCancellation.permitsRecovery { try Task.checkCancellation() }
        // There is deliberately no SDK or SecurityTool fallback after a denied,
        // interrupted, missing, or untrusted service request.
        return try transport.perform(service: service, operation: operation, account: account, data: data,
                                     interactionAllowed: KeychainInteraction.mode == .interactive)
    }

    private func usesAppVault(_ service: String) throws -> Bool {
        if AgentSwapVaultWire.ownedServices.contains(service) { return true }
        // A newly introduced app service must gain an explicit protocol format;
        // silently sending it to the app's SDK would restore the update problem.
        guard !service.hasPrefix(AgentSwapVaultWire.service + ".") else {
            throw AgentSwapError.unsupported("지원하지 않는 앱 인증 저장소이므로 변경을 중단했습니다.")
        }
        return false
    }

    private func requireSuccess(_ result: AppVaultReply) throws {
        guard result.status == errSecSuccess else {
            if result.status == errSecDuplicateItem {
                throw AgentSwapError.storage("같은 계정의 인증 항목이 여러 저장소에 있어 변경을 중단했습니다.")
            }
            throw appVaultFailure()
        }
    }
}

func appVaultFailure() -> AgentSwapError {
    .storage("저장된 인증에 접근하지 못했습니다. 계정 상세의 저장된 인증 접근 허용으로 이 계정의 권한을 확인해 주세요.")
}
