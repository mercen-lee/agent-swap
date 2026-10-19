import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Claude Desktop Code transfer planning")
struct ClaudeDesktopCodeTransferTests {
    @Test("unknown Desktop fields are copied byte-for-byte without reading foreign buckets")
    func copiesUnknownFieldsAndLeavesOriginalsUntouched() throws {
        let fixture = try Fixture()
        let record = fixture.record(activity: 20, extra: ["subagentsTruncatedFor": "new-desktop-field"])
        let source = try fixture.writeSource(record)
        try fixture.writeTranscript(for: fixture.cliID)
        try fixture.write(Data("finder metadata".utf8), to: fixture.home.appendingPathComponent(".claude/projects/.DS_Store"))
        let foreignData = fixture.record(activity: 99)
        let foreign = try fixture.writeForeign(foreignData)
        let prepared = try fixture.transfer.prepare(source: fixture.source, target: fixture.target)
        let plan = prepared.mutations

        #expect(plan.count == 1)
        #expect(plan[0].before == nil)
        #expect(plan[0].after == source)
        #expect(try Data(contentsOf: fixture.sourceURL) == source)
        #expect(try Data(contentsOf: foreign) == foreignData)
        try prepared.verifyOriginals()
    }

    @Test("new imports retain preferences but do not inherit another account's bridge bindings")
    func preservesInactiveRemotePreferences() throws {
        let fixture = try Fixture()
        let data = fixture.record(activity: 20, extra: ["remoteControlUserEnabled": true,
            "remoteControlAvailable": true, "remoteControlAutoEligible": true, "remoteControlEnabled": false,
            "bridgeSessionIds": ["historical-bridge"]])
        try fixture.writeSource(data)
        try fixture.writeTranscript(for: fixture.cliID)
        let plan = try fixture.transfer.plan(source: fixture.source, target: fixture.target)
        #expect(plan.count == 1)
        let transferred = try #require(plan[0].after)
        let object = try #require(try JSONSerialization.jsonObject(with: transferred) as? [String: Any])
        #expect(object["bridgeSessionIds"] == nil)
        #expect(object["remoteControlUserEnabled"] as? Bool == true)
        #expect(object["remoteControlAvailable"] as? Bool == true)
        #expect(object["remoteControlAutoEligible"] as? Bool == true)
        #expect(try Data(contentsOf: fixture.sourceURL) == data)
    }

    @Test("updates preserve the target account's exact bridge history or its absence")
    func preservesTargetBridgeBindings() throws {
        for targetExtra: [String: Any] in [["bridgeSessionIds": ["target-bridge-2", "target-bridge-1"]], [:]] {
            let fixture = try Fixture()
            try fixture.writeSource(fixture.record(activity: 30, extra: ["bridgeSessionIds": ["source-bridge"]]))
            try fixture.writeTarget(fixture.record(activity: 10, extra: targetExtra))
            try fixture.writeTranscript(for: fixture.cliID)
            let plan = try fixture.transfer.plan(source: fixture.source, target: fixture.target)
            let mutation = try #require(plan.first)
            let transferred = try #require(mutation.after)
            let object = try #require(try JSONSerialization.jsonObject(with: transferred) as? [String: Any])
            #expect(object["bridgeSessionIds"] as? [String] == targetExtra["bridgeSessionIds"] as? [String])
        }
    }

    @Test("malformed bridge history in either account is refused")
    func rejectsMalformedBridgeHistory() throws {
        let malformed: [Any] = [NSNull(), ["unexpected": "value"], ["bridge", 4], [""]]
        for value in malformed {
            for badSource in [true, false] {
                let fixture = try Fixture()
                try fixture.writeSource(fixture.record(activity: 30, extra: badSource ? ["bridgeSessionIds": value] : [:]))
                try fixture.writeTarget(fixture.record(activity: 10, extra: badSource ? [:] : ["bridgeSessionIds": value]))
                try fixture.writeTranscript(for: fixture.cliID)
                #expect(throws: AgentSwapError.self) { try fixture.transfer.plan(source: fixture.source, target: fixture.target) }
            }
        }
    }

    @Test("rewriting account-bound metadata cannot publish an oversized index")
    func rejectsOversizedAdaptedRecord() throws {
        let fixture = try Fixture()
        let base = fixture.record(activity: 10, extra: ["bridgeSessionIds": ["source-bridge"]])
        var object = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        object["unknownPresentation"] = String(repeating: "/", count: 600_000)
        let compact = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        #expect(compact.count < 1_024 * 1_024)
        try fixture.writeSource(compact)
        try fixture.writeTranscript(for: fixture.cliID)
        #expect(throws: AgentSwapError.self) { try fixture.transfer.plan(source: fixture.source, target: fixture.target) }
        #expect(try Data(contentsOf: fixture.sourceURL) == compact)
    }

    @Test("newer source retains target title and user flags")
    func newerSourcePreservesTargetAnnotations() throws {
        let fixture = try Fixture()
        let source = fixture.record(activity: 30, title: "source", archived: false, starred: false)
        let target = fixture.record(activity: 10, title: "target title", archived: true, starred: true)
        try fixture.writeSource(source)
        try fixture.writeTarget(target)
        try fixture.writeTranscript(for: fixture.cliID)

        let plan = try fixture.transfer.plan(source: fixture.source, target: fixture.target)
        #expect(plan.count == 1)
        let transferred = try #require(plan[0].after)
        let object = try #require(try JSONSerialization.jsonObject(with: transferred) as? [String: Any])
        #expect(object["title"] as? String == "target title")
        #expect((object["isArchived"] as? NSNumber)?.boolValue == true)
        #expect((object["isStarred"] as? NSNumber)?.boolValue == true)
        #expect(plan[0].before == target)
    }

    @Test("tombstones suppress deleted IDs and existing newer target is retained")
    func honorsTombstonesAndNewerTarget() throws {
        let fixture = try Fixture()
        let source = fixture.record(activity: 10)
        let target = fixture.record(activity: 40, title: "newer target")
        try fixture.writeSource(source)
        try fixture.writeTarget(target)
        try fixture.writeTranscript(for: fixture.cliID)
        #expect(try fixture.transfer.plan(source: fixture.source, target: fixture.target).isEmpty)

        try fixture.writeTombstone("deleted_\(fixture.localID).json", in: fixture.targetBucket)
        #expect(try fixture.transfer.plan(source: fixture.source, target: fixture.target).isEmpty)
    }

    @Test("persisted original fingerprints reject a changed source or transcript")
    func persistedFingerprintsFenceOriginals() throws {
        let fixture = try Fixture()
        try fixture.writeSource(fixture.record(activity: 10))
        try fixture.writeTranscript(for: fixture.cliID)
        let prepared = try fixture.transfer.prepare(source: fixture.source, target: fixture.target)
        let restored = try JSONDecoder().decode([ClaudeDesktopCodeFingerprint].self,
                                                from: JSONEncoder().encode(prepared.fingerprints))
        try fixture.transfer.verifyOriginals(restored, source: fixture.source)

        try fixture.writeSource(fixture.record(activity: 11))
        #expect(throws: AgentSwapError.self) { try fixture.transfer.verifyOriginals(restored, source: fixture.source) }
    }

    @Test("aggregate mutation bytes and an inventory change are fenced")
    func boundsPlanAndFencesInventory() throws {
        let fixture = try Fixture()
        let source = fixture.record(activity: 10)
        try fixture.writeSource(source)
        try fixture.writeTranscript(for: fixture.cliID)
        let limited = ClaudeDesktopCodeTransfer(home: fixture.home, maximumPlanBytes: source.count - 1)
        #expect(throws: AgentSwapError.self) { try limited.prepare(source: fixture.source, target: fixture.target) }

        let prepared = try fixture.transfer.prepare(source: fixture.source, target: fixture.target)
        try fixture.writeTombstone("deleted_\(UUID().uuidString).json", in: fixture.sourceBucket)
        #expect(throws: AgentSwapError.self) { try prepared.verifyOriginals() }
    }

    @Test("case variants collide by canonical session IDs")
    func rejectsCanonicalCaseCollisions() throws {
        let fixture = try Fixture()
        try fixture.writeSource(fixture.record(activity: 10))
        try fixture.writeTranscript(for: fixture.cliID)
        var object = try #require(try JSONSerialization.jsonObject(with: fixture.record(activity: 5)) as? [String: Any])
        object["sessionId"] = "local_\(fixture.localID.uppercased())"
        let uppercase = try JSONSerialization.data(withJSONObject: object)
        try fixture.write(uppercase, to: fixture.targetBucket.appendingPathComponent("local_\(fixture.localID.uppercased()).json"))
        #expect(throws: AgentSwapError.self) { try fixture.transfer.prepare(source: fixture.source, target: fixture.target) }
    }

    @Test("refuses links, mismatched IDs, and a missing transcript")
    func refusesUnsafeOrIncompleteRecords() throws {
        let missing = try Fixture()
        try missing.writeSource(missing.record(activity: 10))
        #expect(throws: AgentSwapError.self) { try missing.transfer.plan(source: missing.source, target: missing.target) }

        let wrong = try Fixture()
        var object = try #require(try JSONSerialization.jsonObject(with: wrong.record(activity: 10)) as? [String: Any])
        object["sessionId"] = "local_\(UUID().uuidString)"
        try wrong.writeSource(JSONSerialization.data(withJSONObject: object))
        try wrong.writeTranscript(for: wrong.cliID)
        #expect(throws: AgentSwapError.self) { try wrong.transfer.plan(source: wrong.source, target: wrong.target) }

        let linked = try Fixture()
        try linked.writeSource(linked.record(activity: 10))
        try linked.writeTranscript(for: linked.cliID)
        try FileManager.default.removeItem(at: linked.sourceURL)
        try FileManager.default.createSymbolicLink(at: linked.sourceURL, withDestinationURL: linked.home.appendingPathComponent("elsewhere.json"))
        #expect(throws: AgentSwapError.self) { try linked.transfer.plan(source: linked.source, target: linked.target) }

        let remote = try Fixture()
        try remote.writeSource(remote.record(activity: 10, extra: ["bridgeSessionId": "active-bridge"]))
        try remote.writeTranscript(for: remote.cliID)
        #expect(throws: AgentSwapError.self) { try remote.transfer.plan(source: remote.source, target: remote.target) }
    }
}

private final class Fixture {
    let home: URL
    let source: AccountIdentity
    let target: AccountIdentity
    let localID = UUID().uuidString.lowercased()
    let cliID = UUID().uuidString.lowercased()
    let transfer: ClaudeDesktopCodeTransfer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentswap-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        source = .init(provider: .claude, userID: UUID().uuidString, workspaceID: UUID().uuidString)
        target = .init(provider: .claude, userID: UUID().uuidString, workspaceID: UUID().uuidString)
        transfer = .init(home: home)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    var root: URL { home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true) }
    var sourceBucket: URL { bucket(source) }
    var targetBucket: URL { bucket(target) }
    var sourceURL: URL { sourceBucket.appendingPathComponent("local_\(localID).json") }

    func bucket(_ identity: AccountIdentity) -> URL {
        root.appendingPathComponent(identity.userID, isDirectory: true).appendingPathComponent(identity.workspaceID, isDirectory: true)
    }

    func record(activity: Double, title: String = "source", archived: Bool = false, starred: Bool = false,
                extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "sessionId": "local_\(localID)", "cliSessionId": cliID, "cwd": "/tmp/project",
            "createdAt": 1.0, "lastActivityAt": activity, "title": title,
            "isArchived": archived, "isStarred": starred
        ]
        extra.forEach { object[$0.key] = $0.value }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @discardableResult
    func writeSource(_ data: Data) throws -> Data { try write(data, to: sourceURL); return data }
    func writeTarget(_ data: Data) throws { try write(data, to: targetBucket.appendingPathComponent("local_\(localID).json")) }
    func writeForeign(_ data: Data) throws -> URL {
        let foreign = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("local_\(UUID().uuidString).json")
        try write(data, to: foreign); return foreign
    }
    func writeTombstone(_ name: String, in bucket: URL) throws { try write(Data(), to: bucket.appendingPathComponent(name)) }
    func writeTranscript(for cliID: String) throws {
        try write(Data("synthetic transcript".utf8), to: home.appendingPathComponent(".claude/projects/project/\(cliID).jsonl"))
    }
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
    }
}
