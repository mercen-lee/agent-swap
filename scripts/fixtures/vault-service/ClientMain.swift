import Foundation
import Security
import Darwin
import AgentSwapVaultProtocol

private enum FixtureFailure: Error {
    case invalidArguments, handshake, status(Int32), bytes, unexpectedSuccess
}
#if FIXTURE_PARENT_B
private let parentGeneration = 2
#else
private let parentGeneration = 1
#endif
private let account = "11111111-2222-4333-8444-555555555555"
private let records = [
    (AgentSwapVaultWire.service, account),
    (AgentSwapVaultWire.recoveryService, "claude|" + String(repeating: "a", count: 32)),
    (AgentSwapVaultWire.desktopService, "desktop-profile-" + account),
    (AgentSwapVaultWire.recoveryService, "codex|" + String(repeating: "a", count: 32)),
    (AgentSwapVaultWire.recoveryService, "claude|" + String(repeating: "a", count: 32) + "|rotation"),
    (AgentSwapVaultWire.recoveryService, "claude|" + String(repeating: "a", count: 32) + "|preserved-index|" + account),
    (AgentSwapVaultWire.recoveryService, "claude-desktop-account-switch"),
    (AgentSwapVaultWire.recoveryService, "claude-desktop-files-" + account),
]

@main
struct FixtureClientMain {
    static func main() {
        var stage = "arguments"
        do {
            guard CommandLine.arguments.count == 3 else { throw FixtureFailure.invalidArguments }
            let requirement = CommandLine.arguments[1]
            let mode = CommandLine.arguments[2]
            let deadline = ProcessInfo.processInfo.systemUptime + (mode == "large" ? 120 : 12)
            stage = "opening"
            let session = try XPCVaultSessionFactory().open(peerRequirement: requirement, deadline: deadline)
            defer { session.invalidate() }
            stage = "opened"
            if mode == "no-ping" {
                let result = try session.execute(service: AgentSwapVaultWire.service, operation: "read", account: account,
                                                 data: nil, interactionAllowed: false, deadline: deadline)
                guard result.status == errSecAuthFailed else { throw FixtureFailure.status(result.status) }
            } else {
                var random = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw FixtureFailure.handshake }
                let nonce = Data(random)
                stage = "ping"
                let handshake = try session.ping(nonce, deadline: deadline)
                guard handshake.version == AgentSwapVaultWire.version, handshake.nonce == nonce,
                      handshake.peerUserID == getuid() else { throw FixtureFailure.handshake }
                stage = "executing"
                func request(_ operation: String, service: String, account: String, data: Data? = nil) throws -> Data? {
                    let result = try session.execute(service: service, operation: operation, account: account, data: data,
                                                     interactionAllowed: false, deadline: deadline)
                    guard result.status == errSecSuccess else { throw FixtureFailure.status(result.status) }
                    return result.data
                }
                if mode == "invalid-service" || mode == "invalid-account" {
                    let result = try session.execute(service: mode == "invalid-service" ? "synthetic.unowned.service" : AgentSwapVaultWire.service,
                                                     operation: "write", account: mode == "invalid-account" ? "invalid" : account,
                                                     data: Data("synthetic-denied".utf8), interactionAllowed: false, deadline: deadline)
                    guard result.status == errSecParam else { throw FixtureFailure.status(result.status) }
                } else if mode == "large" {
                    let largeAccount = "claude|" + String(repeating: "b", count: 32) + "|rotation|preserved|" + String(repeating: "c", count: 64)
                    let bytes = Data(repeating: 0xa7, count: 128 * 1_024 * 1_024)
                    guard try request("write", service: AgentSwapVaultWire.recoveryService, account: largeAccount, data: bytes) == bytes,
                          try request("read", service: AgentSwapVaultWire.recoveryService, account: largeAccount) == bytes else { throw FixtureFailure.bytes }
                    guard try request("delete", service: AgentSwapVaultWire.recoveryService, account: largeAccount) == nil else { throw FixtureFailure.bytes }
                } else {
                    for (service, key) in records {
                        if mode == "continue" {
                            guard try request("read", service: service, account: key) == Data("synthetic-generation-one".utf8) else { throw FixtureFailure.bytes }
                        }
                        let bytes = Data((mode == "continue" ? "synthetic-generation-two" : "synthetic-generation-one").utf8)
                        guard try request("write", service: service, account: key, data: bytes) == bytes,
                              try request("read", service: service, account: key) == bytes else { throw FixtureFailure.bytes }
                    }
                }
            }
            print("{\"parent_generation\":\(parentGeneration),\"passed\":true,\"pid\":\(getpid()),\"mode\":\"\(mode)\"}")
        } catch {
            // Synthetic errors contain no credentials; keep logs bounded and do
            // not print dynamic requirement strings, paths, or data.
            if case let FixtureFailure.status(status) = error { FileHandle.standardError.write(Data("Synthetic RPC status \(status)\n".utf8)) }
            else { FileHandle.standardError.write(Data("Synthetic RPC fixture failed at \(stage).\n".utf8)) }
            exit(1)
        }
    }
}
