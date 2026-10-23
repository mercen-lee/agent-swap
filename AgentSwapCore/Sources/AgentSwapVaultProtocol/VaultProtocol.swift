import Foundation

/// The named service carries no credential messages. Its only reply is an
/// endpoint whose connection cannot reconnect through a mutable service path.
@objc(AgentSwapVaultBrokerV1)
public protocol AgentSwapVaultBroker {
    func connect(withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void)
}

/// This interface is also linked into the immutable credential service. Change its
/// version deliberately rather than rebuilding that service with every app update.
@objc(AgentSwapVaultRPCV1)
public protocol AgentSwapVaultRPC {
    /// A verified reply on the same connection must precede any credential message.
    func ping(_ nonce: Data, withReply reply: @escaping @Sendable (Int, Data) -> Void)
    func execute(version: Int, service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool,
                 withReply reply: @escaping @Sendable (Int32, Data?) -> Void)
}

public enum AgentSwapVaultWire {
    public static let version = 1
    public static let service = "net.mercen.agentswap"
    public static let recoveryService = "net.mercen.agentswap.recovery"
    public static let desktopService = "net.mercen.agentswap.desktop"
    public static let ownedServices: Set<String> = [service, recoveryService, desktopService]
    public static let serviceIdentifier = "net.mercen.agentswap.vault"
    public static let applicationIdentifier = "net.mercen.agentswap"
    public static let certificateSHA1 = "F2C0BAD9B46BFED4130397D727F47370050DCCDB"
    public static let applicationRequirement = "identifier \"\(applicationIdentifier)\" and certificate leaf = H\"\(certificateSHA1)\""
    public static let serviceRequirement = "identifier \"\(serviceIdentifier)\" and certificate leaf = H\"\(certificateSHA1)\""

    public static func isCanonicalAccount(_ value: String) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString == value
    }

    public static func isAllowed(service requestedService: String, account: String) -> Bool {
        if requestedService == service { return isCanonicalAccount(account) }
        if requestedService == desktopService {
            let prefix = "desktop-profile-"
            return account.hasPrefix(prefix) && isCanonicalAccount(String(account.dropFirst(prefix.count)))
        }
        guard requestedService == recoveryService else { return false }
        if account == "claude-desktop-account-switch" { return true }
        let filesPrefix = "claude-desktop-files-"
        if account.hasPrefix(filesPrefix) { return isCanonicalAccount(String(account.dropFirst(filesPrefix.count))) }
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let parts = account.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, hex(parts[1], count: 32) else { return false }
        if parts[0] == "codex" { return parts.count == 2 }
        guard parts[0] == "claude" else { return false }
        switch parts.count {
        case 2: return true
        case 3: return parts[2] == "rotation"
        case 4: return parts[2] == "preserved-index" && isCanonicalAccount(parts[3])
        case 5: return parts[2] == "rotation" && parts[3] == "preserved" && hex(parts[4], count: 64)
        default: return false
        }
    }
}
