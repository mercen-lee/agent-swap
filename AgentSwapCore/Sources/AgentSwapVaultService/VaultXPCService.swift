import Foundation
import Security
import Darwin
import AgentSwapVaultProtocol

final class VaultConnectionHandler: NSObject, AgentSwapVaultRPC, @unchecked Sendable {
    let state: VaultConnectionState
    private let processor: VaultRequestProcessor

    init(processor: VaultRequestProcessor, state: VaultConnectionState = VaultConnectionState()) {
        self.processor = processor
        self.state = state
    }

    func ping(_ nonce: Data, withReply reply: @escaping @Sendable (Int, Data) -> Void) {
        guard state.ping(nonce) else { reply(0, Data()); return }
        reply(AgentSwapVaultWire.version, nonce)
    }

    func execute(version: Int, service: String = AgentSwapVaultWire.service, operation: String,
                 account: String, data: Data?, interactionAllowed: Bool,
                 withReply reply: @escaping @Sendable (Int32, Data?) -> Void) {
        guard state.mayExecute() else { reply(errSecAuthFailed, nil); return }
        // Do not block the connection's delivery queue while another request shows
        // approval UI: its invalidation callback must remain able to retire this state.
        DispatchQueue.global(qos: .userInitiated).async { [processor, state] in
            let result = processor.execute(version: version, service: service, operation: operation, account: account, data: data,
                                           interactionAllowed: interactionAllowed, isActive: { state.mayExecute() })
            reply(result.status, result.data)
        }
    }
}

private final class VaultBrokerHandler: NSObject, AgentSwapVaultBroker, @unchecked Sendable {
    private let endpoint: NSXPCListenerEndpoint
    init(endpoint: NSXPCListenerEndpoint) { self.endpoint = endpoint }
    func connect(withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void) { reply(endpoint) }
}

/// The named service is a harmless broker. Credentials travel only over a connection
/// to this process's anonymous endpoint, which cannot relaunch/rebind after its death.
final class VaultXPCService: NSObject, NSXPCListenerDelegate {
    private let brokerListener: NSXPCListener
    private let credentialListener: NSXPCListener
    private let processor: VaultRequestProcessor
    private let applicationRequirement: String

    /// The production main passes the fixed compiled requirement. Synthetic security
    /// fixtures can compile this class with their own ephemeral signing requirement.
    /// There is no command-line, environment, RPC or persisted requirement override.
    init(processor: VaultRequestProcessor = VaultRequestProcessor(), applicationRequirement: String) {
        brokerListener = .service()
        credentialListener = .anonymous()
        self.processor = processor
        self.applicationRequirement = applicationRequirement
        super.init()
        brokerListener.delegate = self
        credentialListener.delegate = self
    }

    func run() {
        withExtendedLifetime(self) {
            credentialListener.resume()
            brokerListener.resume()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard listener === brokerListener || listener === credentialListener,
              connection.effectiveUserIdentifier == geteuid(), getuid() == geteuid() else { return false }
        // Parse the immutable requirement before Foundation consumes it. Invalid
        // configuration must fail closed rather than raise an Objective-C exception.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(applicationRequirement as CFString,
                                             SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              requirement != nil else { return false }
        connection.setCodeSigningRequirement(applicationRequirement)
        if listener === brokerListener {
            connection.exportedInterface = NSXPCInterface(with: AgentSwapVaultBroker.self)
            connection.exportedObject = VaultBrokerHandler(endpoint: credentialListener.endpoint)
        } else {
            let handler = VaultConnectionHandler(processor: processor)
            connection.exportedInterface = NSXPCInterface(with: AgentSwapVaultRPC.self)
            connection.exportedObject = handler
            connection.invalidationHandler = { [state = handler.state] in state.invalidate() }
            connection.interruptionHandler = { [state = handler.state] in state.invalidate() }
        }
        connection.resume()
        return true
    }
}
