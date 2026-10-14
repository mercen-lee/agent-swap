import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Claude native credential encoding and preflight")
struct ClaudeNativeEncodingTests {
    @Test("Native JSON is printable ASCII and preserves Unicode and integration values")
    func printableJSON() throws {
        let value = "한국어 🎉 \u{7f} \u{0} \n \' \" \\"
        let object: [String: Any] = [
            "claudeAiOauth": ["accessToken": "fixture", "expiresAt": 12345],
            "mcpOAuth": ["fixture": ["label": value]],
            "pluginSecrets": ["fixture": ["enabled": true, "values": [value]]]
        ]
        let data = try claudeCLIAuthData(object)
        #expect(data.allSatisfy { (0x20...0x7E).contains($0) })
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(NSDictionary(dictionary: decoded).isEqual(to: object))
    }

    @Test("Unwritable target or rollback image stops before any credential or journal write", arguments: [true, false])
    func preflightEveryImage(beforeIsLarge: Bool) throws {
        let keychain = PreflightFixtureKeychain()
        let small = Data("small".utf8), large = Data(repeating: 0x61, count: 17)
        let initial = beforeIsLarge ? large : small
        keychain.seed(initial, service: "fixture-two")
        let transaction = AuthTransaction(identifier: "fixture", keychain: keychain, files: AtomicAuthFileAccess())
        #expect(throws: AgentSwapError.self) {
            try transaction.perform([
                .init(location: .keychain(service: "fixture-one", account: "fixture"), before: nil, after: small),
                .init(location: .keychain(service: "fixture-two", account: "fixture"), before: initial,
                      after: beforeIsLarge ? small : large)
            ]) {}
        }
        #expect(keychain.writeCount == 0)
        #expect(keychain.read(service: "fixture-one", account: "fixture") == nil)
        #expect(keychain.read(service: "fixture-two", account: "fixture") == initial)
        #expect(try !transaction.hasPendingRecovery())
    }
}

// Synchronous test storage serializes mutable values and counts with one lock.
private final class PreflightFixtureKeychain: KeychainWritePreflighting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }
    func seed(_ data: Data, service: String) { lock.withLock { values[service] = data } }
    func read(service: String, account: String) -> Data? { lock.withLock { values[service] } }
    func validateWrite(_ data: Data, service: String, account: String) throws {
        if service.hasPrefix("fixture-"), data.count > 16 { throw AgentSwapError.unsupported("Fixture size limit") }
    }
    func write(_ data: Data, service: String, account: String) {
        lock.withLock { writes += 1; values[service] = data }
    }
    func delete(service: String, account: String) { lock.withLock { values[service] = nil } }
}
