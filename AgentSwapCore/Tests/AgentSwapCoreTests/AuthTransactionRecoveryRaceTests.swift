import Foundation
import Testing
@testable import AgentSwapCore

private struct RecoveryRaceJournal: Encodable {
    let version = 1
    let committed = false
    let mutations: [AuthMutation]
}

// The dictionary, one-shot external change, and mutation count share one lock. Preflight
// simulates a consumer changing its own native grant while the restore helper is prepared.
private final class RecoveryRaceKeychain: KeychainAccess, KeychainWritePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var preflightChange: (key: String, value: Data?)?
    private var writes = 0
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }

    func read(service: String, account: String) -> Data? { lock.withLock { values[key(service, account)] } }
    func write(_ data: Data, service: String, account: String) {
        lock.withLock { values[key(service, account)] = data; writes += 1 }
    }
    func delete(service: String, account: String) {
        lock.withLock { values.removeValue(forKey: key(service, account)); writes += 1 }
    }
    func validateWrite(_ data: Data, service: String, account: String) {
        lock.withLock {
            guard let change = preflightChange, change.key == key(service, account) else { return }
            values[change.key] = change.value
            preflightChange = nil
        }
    }
    func changeDuringPreflight(_ data: Data?, service: String, account: String) {
        lock.withLock { preflightChange = (key(service, account), data) }
    }
    func mutationCount() -> Int { lock.withLock { writes } }
}

@Suite("Recovery keeps external generations created during restore preparation")
struct AuthTransactionRecoveryRaceTests {
    @Test("A native login change or logout during preflight is never restored over", arguments: [false, true])
    func externalChangeDuringPreflight(logout: Bool) throws {
        let keychain = RecoveryRaceKeychain()
        let service = "fixture-native", account = "fixture-user", identifier = "fixture-recovery-race"
        let before = Data("fixture-before".utf8), after = Data("fixture-after".utf8)
        let external = logout ? nil : Data("fixture-external-successor".utf8)
        let location = AuthMutation.Location.keychain(service: service, account: account)
        let marker = try JSONEncoder().encode(RecoveryRaceJournal(mutations: [.init(location: location, before: before, after: after)]))
        keychain.write(after, service: service, account: account)
        keychain.write(marker, service: AuthTransaction.service, account: identifier)
        keychain.changeDuringPreflight(external, service: service, account: account)
        let writes = keychain.mutationCount()
        let transaction = AuthTransaction(identifier: identifier, keychain: keychain, files: AtomicAuthFileAccess())

        #expect(throws: AgentSwapError.self) { try transaction.recover(allowedLocations: [location]) }

        #expect(keychain.read(service: service, account: account) == external)
        #expect(keychain.read(service: AuthTransaction.service, account: identifier) == marker)
        #expect(keychain.mutationCount() == writes)
    }
}
