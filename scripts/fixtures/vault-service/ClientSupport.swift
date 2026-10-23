// Minimal fixture-only declarations needed to compile the unchanged production
// transport file. No authentication, session, waiter, or IPC behavior is mirrored.
import Foundation
import Security

struct AppVaultReply: Sendable {
    let status: OSStatus
    let data: Data?
}
protocol AppVaultTransport: Sendable {
    func perform(service: String, operation: String, account: String, data: Data?, interactionAllowed: Bool) throws -> AppVaultReply
}
enum AgentSwapError: Error {
    case unsupported(String), cancelled
}
enum AppVaultFailureStage: String, Sendable { case connect, handshake, request }
enum NativeSecurityCancellation {
    static let permitsRecovery = false
}
func appVaultFailure(_ stage: AppVaultFailureStage = .request, status: OSStatus? = nil) -> AgentSwapError {
    .unsupported("Synthetic vault fixture operation failed (vault.\(stage.rawValue)).")
}
