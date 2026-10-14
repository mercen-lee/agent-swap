import Foundation
import Testing
@testable import AgentSwapCore

private enum SessionPreserverFixtureError: Error { case expectedPrepared }

private actor SessionPreserverProcesses: ClaudeDesktopConversationProcessControlling {
    let url: URL
    private var snapshots: [ClaudeDesktopConversationProcessSnapshot]
    private var scanCount = 0
    private var acceptsTermination = true
    private var terminationHook: (@Sendable () throws -> Void)?
    private(set) var terminationCount = 0
    private(set) var relaunchCount = 0

    init(url: URL, snapshots: [ClaudeDesktopConversationProcessSnapshot] = [.init()]) {
        self.url = url
        self.snapshots = snapshots
    }

    func installation(at applicationURL: URL?) -> ClaudeDesktopConversationInstallation? {
        .init(url: url, version: ClaudeDesktopSessionPreserver.supportedVersion)
    }

    func scan(applicationURL: URL) -> ClaudeDesktopConversationProcessSnapshot {
        defer { scanCount += 1 }
        return snapshots[min(scanCount, snapshots.count - 1)]
    }

    func requestNormalTermination() -> Bool {
        terminationCount += 1
        do { try terminationHook?() } catch { return false }
        return acceptsTermination
    }

    func relaunch(at applicationURL: URL) { relaunchCount += 1 }
    func rejectTermination() { acceptsTermination = false }
    func onTermination(_ hook: @escaping @Sendable () throws -> Void) { terminationHook = hook }
    func useSnapshots(_ values: [ClaudeDesktopConversationProcessSnapshot]) {
        snapshots = values
        scanCount = 0
    }
}

// All mutable fault and access-log state is guarded by this lock; every test owns a separate home.
private final class SessionPreserverFiles: AuthFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let underlying = AtomicAuthFileAccess()
    private var readURLs: [URL] = []
    private var writeURLs: [URL] = []
    private var deleteURLs: [URL] = []
    private var failureBucket: URL?
    private var successfulIndexWritesBeforeFailure = 0
    private var failsNextDeletion = false
    private var failsNextWrite = false
    private var failsNextReadAt: URL?
    private var readFailureCount = 0

    func read(_ url: URL) throws -> Data? {
        let fail = lock.withLock {
            readURLs.append(url.standardizedFileURL)
            if failsNextReadAt == url.standardizedFileURL {
                failsNextReadAt = nil
                readFailureCount += 1
                return true
            }
            return false
        }
        if fail { throw AgentSwapError.storage("Fixture failure reading a prepared target index") }
        return try underlying.read(url)
    }

    func write(_ data: Data, to url: URL) throws {
        let failBeforeWrite = lock.withLock {
            if failsNextWrite {
                writeURLs.append(url.standardizedFileURL)
                failsNextWrite = false
                return true
            }
            return false
        }
        if failBeforeWrite { throw AgentSwapError.storage("Fixture failure before writing preservation state") }
        let fail = lock.withLock {
            writeURLs.append(url.standardizedFileURL)
            guard url.deletingLastPathComponent().standardizedFileURL == failureBucket,
                  url.lastPathComponent.hasPrefix("local_") else { return false }
            if successfulIndexWritesBeforeFailure > 0 {
                successfulIndexWritesBeforeFailure -= 1
                return false
            }
            failureBucket = nil
            return true
        }
        try underlying.write(data, to: url)
        if fail { throw AgentSwapError.storage("Fixture failure after publishing a new target index") }
    }

    func delete(_ url: URL) throws {
        let fail = lock.withLock {
            deleteURLs.append(url.standardizedFileURL)
            if failsNextDeletion { failsNextDeletion = false; return true }
            return false
        }
        if fail { throw AgentSwapError.storage("Fixture failure before deleting preservation state") }
        try underlying.delete(url)
    }

    func failIndexWrite(in bucket: URL, afterSuccesses: Int) {
        lock.withLock {
            failureBucket = bucket.standardizedFileURL
            successfulIndexWritesBeforeFailure = afterSuccesses
        }
    }

    func reads() -> [URL] { lock.withLock { readURLs } }
    func writes() -> [URL] { lock.withLock { writeURLs } }
    func deletions() -> [URL] { lock.withLock { deleteURLs } }
    func failNextDeletion() { lock.withLock { failsNextDeletion = true } }
    func failNextWrite() { lock.withLock { failsNextWrite = true } }
    func failNextRead(at url: URL) { lock.withLock { failsNextReadAt = url.standardizedFileURL } }
    func readFailures() -> Int { lock.withLock { readFailureCount } }
}

private struct PreservedSessionFixture: Sendable {
    let localID: String
    let cliID: String
    let sourceURL: URL
    let transcriptURL: URL
    let sourceBytes: Data
    let transcriptBytes: Data
}

private struct SessionPreserverFixture: Sendable {
    let home: URL
    let project: URL
    let app: URL
    let source: AccountRecord
    let target: AccountRecord
    let disk = AtomicAuthFileAccess()
    var userData: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    var configURL: URL { userData.appendingPathComponent("config.json") }

    init() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AgentSwapSessionPreserverTests-\(UUID().uuidString)")
        project = home.appendingPathComponent("project")
        app = home.appendingPathComponent("Claude.app")
        source = .init(identity: .init(provider: .claude, userID: UUID().uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased()))
        target = .init(identity: .init(provider: .claude, userID: UUID().uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased()))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try disk.write(authData(["lastKnownAccountUuid": source.identity.userID, "otherSetting": "preserve"]), to: configURL)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    func bucket(_ account: AccountRecord) -> URL {
        userData.appendingPathComponent("claude-code-sessions")
            .appendingPathComponent(account.identity.userID).appendingPathComponent(account.identity.workspaceID)
    }

    func indexURL(_ localID: String, account: AccountRecord) -> URL {
        bucket(account).appendingPathComponent(localID + ".json")
    }

    func record(localID: String, cliID: String, title: String = "Source conversation", archived: Bool = false,
                extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["sessionId": localID, "cliSessionId": cliID, "cwd": project.path,
                                     "createdAt": 1_700_000_000_001, "lastActivityAt": 1_700_000_999_123,
                                     "isArchived": archived, "title": title,
                                     "interruptedAwaitingPerson": NSNull(), "steeredByRemoteClient": NSNull(),
                                     "spawnSeed": [String: Any](), "lastSpawnRootDetected": false, "autoChosenInApp": false]
        for (key, value) in extra { object[key] = value }
        return try authData(object)
    }

    func addSession(title: String = "Source conversation", archived: Bool = false,
                    extra: [String: Any] = [:]) throws -> PreservedSessionFixture {
        let localID = "local_" + UUID().uuidString.lowercased(), cliID = UUID().uuidString.lowercased()
        let sourceURL = indexURL(localID, account: source)
        let sourceBytes = try record(localID: localID, cliID: cliID, title: title, archived: archived, extra: extra)
        let slug = project.path.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? String(character) : "-"
        }.joined()
        let transcriptURL = home.appendingPathComponent(".claude/projects").appendingPathComponent(slug).appendingPathComponent(cliID + ".jsonl")
        var transcriptBytes = try authData(["type": "user", "uuid": UUID().uuidString.lowercased(), "parentUuid": NSNull(),
                                            "sessionId": cliID, "cwd": project.path, "isSidechain": false,
                                            "timestamp": "2026-10-14T03:00:00.000Z",
                                            "message": ["role": "user", "content": "Keep this transcript byte for byte"]])
        transcriptBytes.append(10)
        try disk.write(sourceBytes, to: sourceURL)
        try disk.write(transcriptBytes, to: transcriptURL)
        return .init(localID: localID, cliID: cliID, sourceURL: sourceURL, transcriptURL: transcriptURL,
                     sourceBytes: sourceBytes, transcriptBytes: transcriptBytes)
    }

    func addTombstone(for session: PreservedSessionFixture, account: AccountRecord) throws -> URL {
        let id = String(session.localID.dropFirst("local_".count))
        let url = bucket(account).appendingPathComponent("deleted_" + id + ".json")
        try disk.write(authData(["sessionId": session.localID]), to: url)
        return url
    }

    func indexFiles(_ account: AccountRecord) throws -> [URL] {
        let directory = bucket(account)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
    }

    func assertSourceUnchanged(_ session: PreservedSessionFixture) throws {
        #expect(try disk.read(session.sourceURL) == session.sourceBytes)
        #expect(try disk.read(session.transcriptURL) == session.transcriptBytes)
    }
}

private func requirePrepared(_ preparation: ClaudeDesktopSessionPreparation) throws -> (transactionID: UUID, count: Int) {
    guard case .prepared(let transactionID, let count) = preparation else {
        Issue.record("Expected a prepared session transaction")
        throw SessionPreserverFixtureError.expectedPrepared
    }
    return (transactionID, count)
}

private func expectNotNeeded(_ preparation: ClaudeDesktopSessionPreparation) {
    guard case .notNeeded = preparation else {
        Issue.record("Expected no session preservation work")
        return
    }
}

private func nativeFeatureSnapshotFixture() -> [String: Any] {
    [
        "promptAppendSnapshot": [
            "append": "Preserve this native prompt context",
            "cliVersion": "2.1.99",
            "settingsKey": "fixture-settings-key",
            "toolSets": ["turnBox": true, "sideSessions": false]
        ],
        "toolSurfaceSnapshot": [
            "familyHashes": [
                "builtin": "0123456789abcdef", "internal_inline": "0123456789abcdef",
                "internal_deferred": "0123456789abcdef", "connector": "0123456789abcdef",
                "extension": "0123456789abcdef", "plugin_or_user": "0123456789abcdef"
            ],
            "deferredHash": "fedcba9876543210",
            "disallowedToolsKey": "0123456789abcdef",
            "appVersion": "2.37337.1",
            "appRunId": UUID().uuidString.lowercased(),
            "cliVersion": "2.1.99",
            "recordedAt": Int(Date().timeIntervalSince1970 * 1_000)
        ]
    ]
}

@Suite("Automatic Claude Desktop local session preservation")
struct ClaudeDesktopSessionPreserverTests {
    @Test("The current account and an account without source indices need no quit", arguments: [true, false])
    func noWorkDoesNotQuit(sameAccount: Bool) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        if sameAccount { _ = try fixture.addSession() }
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let files = SessionPreserverFiles()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        let result = try await store.prepareForSwitch(source: fixture.source, target: sameAccount ? fixture.source : fixture.target, relaunch: false)
        expectNotNeeded(result)
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        #expect(files.writes().isEmpty)
        #expect(files.deletions().isEmpty)
    }

    @Test("Normal local indices retain their IDs, title, timestamps and archive status without changing source data")
    func copiesNormalIndicesWithoutMovingSource() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let first = try fixture.addSession(title: "Keep my title", archived: true)
        let second = try fixture.addSession(title: "Another conversation")
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        let config = try fixture.disk.read(fixture.configURL)
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 2)
        for session in [first, second] {
            let targetURL = fixture.indexURL(session.localID, account: fixture.target)
            let index = try authObject(Data(contentsOf: targetURL), name: "Preserved index")
            let source = try authObject(session.sourceBytes, name: "Source index")
            for key in ["sessionId", "cliSessionId", "cwd", "title"] { #expect(index[key] as? String == source[key] as? String) }
            for key in ["createdAt", "lastActivityAt"] { #expect(index[key] as? Int == source[key] as? Int) }
            #expect(index["isArchived"] as? Bool == source["isArchived"] as? Bool)
            #expect(index["stagedTranscriptPath"] == nil)
            #expect((try FileManager.default.attributesOfItem(atPath: targetURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try fixture.assertSourceUnchanged(session)
        }
        #expect(try fixture.disk.read(fixture.configURL) == config)
        #expect(await controller.terminationCount == 0)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Copied indices detach stale cloud and bridge state while keeping source attachment bytes intact")
    func detachesOnlyTargetCloudAndBridgeState() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: [
            "cloudSessionId": "session_fixture_cloud",
            "outboundCCRRemoteId": "session_fixture_remote",
            "bridgeSessionIds": ["session_fixture_bridge"],
            "bridgeSessionId": "session_fixture_bridge",
            "bridgeSessionUrl": "https://example.invalid/fixture",
            "remoteControlEnabled": true,
            "remoteControlUserEnabled": true,
            "startedViaRemoteControl": true,
            "envScopeId": "fixture-old-scope"
        ])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Detached target index")
        #expect(target["bridgeSessionIds"] as? [String] == [])
        for key in ["cloudSessionId", "outboundCCRRemoteId", "bridgeSessionId", "bridgeSessionUrl", "remoteControlEnabled", "remoteControlUserEnabled", "startedViaRemoteControl", "envScopeId"] {
            #expect(target[key] == nil)
        }
        #expect(target["sessionId"] as? String == session.localID)
        #expect(target["cliSessionId"] as? String == session.cliID)
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Known native permission modes are reset only in the copied target", arguments: ["default", "acceptEdits", "plan", "bypassPermissions", "auto", "dontAsk"])
    func resetsTargetPermissions(mode: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: [
            "permissionMode": mode,
            "alwaysAllowedReasons": ["fixture-previous-grant"],
            "sessionPermissionUpdates": [["type": "setMode", "mode": mode, "destination": "session"]]
        ])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Reset target permissions")
        #expect(target["permissionMode"] as? String == "default")
        #expect(target["alwaysAllowedReasons"] == nil)
        #expect(target["sessionPermissionUpdates"] == nil)
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Known native seed context is copied while old root and execution choices are removed only from target")
    func preservesSeedContextAndResetsExecutionChoices() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: [
            "spawnSeed": ["systemPrompt": "Fixture system context", "systemPromptAppend": "Fixture appended context", "worktreeHookBased": true],
            "lastSpawnRootDetected": true,
            "bypassChosenInApp": true,
            "autoChosenInApp": "adopted"
        ])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Seeded target index")
        let seed = try #require(target["spawnSeed"] as? [String: Any])
        #expect(seed.count == 3)
        #expect(seed["systemPrompt"] as? String == "Fixture system context")
        #expect(seed["systemPromptAppend"] as? String == "Fixture appended context")
        #expect(seed["worktreeHookBased"] as? Bool == true)
        for key in ["lastSpawnRootDetected", "bypassChosenInApp", "autoChosenInApp"] { #expect(target[key] == nil) }
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Unknown or malformed native seed and execution-choice fields refuse before quitting", arguments: ["seed-string", "seed-prompt-number", "seed-hook-string", "seed-unknown-key", "root-string", "bypass-string", "auto-number", "auto-unknown-string"])
    func malformedSeedAndExecutionChoicesFailClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let extra: [String: Any]
        switch reason {
        case "seed-string": extra = ["spawnSeed": "unknown seed shape"]
        case "seed-prompt-number": extra = ["spawnSeed": ["systemPrompt": 5]]
        case "seed-hook-string": extra = ["spawnSeed": ["worktreeHookBased": "true"]]
        case "seed-unknown-key": extra = ["spawnSeed": ["futureExecutionState": true]]
        case "root-string": extra = ["lastSpawnRootDetected": "false"]
        case "bypass-string": extra = ["bypassChosenInApp": "false"]
        case "auto-number": extra = ["autoChosenInApp": 2]
        default: extra = ["autoChosenInApp": "future-choice"]
        }
        let session = try fixture.addSession(extra: extra)
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Native prompt and tool-surface snapshots retain their complete context in the copied target")
    func preservesNativeFeatureSnapshots() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let snapshots = nativeFeatureSnapshotFixture()
        let session = try fixture.addSession(extra: snapshots)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Target feature snapshots")
        for key in ["promptAppendSnapshot", "toolSurfaceSnapshot"] {
            let copied = try #require(target[key] as? [String: Any])
            let original = try #require(snapshots[key] as? [String: Any])
            #expect(try JSONSerialization.data(withJSONObject: copied, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]))
        }
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Native browser permission modes reset to asking and previous domains are removed only in target", arguments: ["ask", "skip_all_permission_checks", "follow_a_plan"])
    func resetsBrowserPermissions(mode: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: ["chromePermissionMode": mode, "chromeAllowedDomains": ["docs.example.invalid"]])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Reset browser permissions")
        #expect(target["chromePermissionMode"] as? String == "ask")
        #expect(target["chromeAllowedDomains"] == nil)
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Malformed feature snapshots and unknown browser permissions refuse before quitting", arguments: ["tool-hash", "tool-timestamp", "prompt-tool", "prompt-cli-version", "browser-mode", "browser-domains"])
    func malformedFeatureFieldsFailClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        var extra = nativeFeatureSnapshotFixture()
        switch reason {
        case "tool-hash":
            var tools = try #require(extra["toolSurfaceSnapshot"] as? [String: Any])
            var hashes = try #require(tools["familyHashes"] as? [String: String])
            hashes["builtin"] = "not-a-lowercase-hash"
            tools["familyHashes"] = hashes
            extra["toolSurfaceSnapshot"] = tools
        case "tool-timestamp":
            var tools = try #require(extra["toolSurfaceSnapshot"] as? [String: Any])
            tools["recordedAt"] = true
            extra["toolSurfaceSnapshot"] = tools
        case "prompt-tool":
            var prompt = try #require(extra["promptAppendSnapshot"] as? [String: Any])
            prompt["toolSets"] = ["futureTool": true]
            extra["promptAppendSnapshot"] = prompt
        case "prompt-cli-version":
            var prompt = try #require(extra["promptAppendSnapshot"] as? [String: Any])
            prompt["cliVersion"] = false
            extra["promptAppendSnapshot"] = prompt
        case "browser-mode": extra["chromePermissionMode"] = "future-browser-mode"
        default: extra["chromeAllowedDomains"] = [1]
        }
        let session = try fixture.addSession(extra: extra)
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("A confirmed normal import backed by the shared transcript is copied without changing source metadata")
    func confirmedNormalImportIsPreserved() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: ["importedFrom": "local-1p-code", "resumeConfirmed": true])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Confirmed import target")
        #expect(target["sessionId"] as? String == session.localID)
        #expect(target["cliSessionId"] as? String == session.cliID)
        #expect(target["stagedTranscriptPath"] == nil)
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("An imported record without a valid native resume confirmation refuses before quitting", arguments: ["false", "absent", "string", "number", "unknown-origin"])
    func unconfirmedImportFailsClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        var extra: [String: Any] = ["importedFrom": "local-1p-code"]
        switch reason {
        case "false": extra["resumeConfirmed"] = false
        case "string": extra["resumeConfirmed"] = "true"
        case "number": extra["resumeConfirmed"] = 1
        case "unknown-origin": extra = ["importedFrom": "future-provider", "resumeConfirmed": true]
        default: break
        }
        let session = try fixture.addSession(extra: extra)
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("A target that already has the same IDs requires no writes or normal quit")
    func compatibleTargetWithoutMissingCopiesNeedsNoWork() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let edited = try fixture.record(localID: session.localID, cliID: session.cliID, title: "Keep my target edit", archived: true)
        try fixture.disk.write(edited, to: targetURL)
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let files = SessionPreserverFiles()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        expectNotNeeded(try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false))
        #expect(try fixture.disk.read(targetURL) == edited)
        #expect(files.writes().isEmpty)
        #expect(files.deletions().isEmpty)
        #expect(await controller.terminationCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("An existing compatible target keeps its user edits while another missing index is copied")
    func keepsCompatibleTargetEdits() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let existing = try fixture.addSession(), fresh = try fixture.addSession()
        let targetURL = fixture.indexURL(existing.localID, account: fixture.target)
        let edited = try fixture.record(localID: existing.localID, cliID: existing.cliID, title: "Target title I edited", archived: true)
        try fixture.disk.write(edited, to: targetURL)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        #expect(try fixture.disk.read(targetURL) == edited)
        #expect(try fixture.disk.read(fixture.indexURL(fresh.localID, account: fixture.target)) != nil)
        _ = try await store.finish(result, applied: false)
        #expect(try fixture.disk.read(targetURL) == edited)
        #expect(try fixture.disk.read(fixture.indexURL(fresh.localID, account: fixture.target)) == nil)
        try fixture.assertSourceUnchanged(existing)
        try fixture.assertSourceUnchanged(fresh)
    }

    @Test("Conflicting local or CLI IDs refuse before changing either account", arguments: ["local", "cli"])
    func conflictingTargetFailsClosed(conflict: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let localID = conflict == "local" ? session.localID : "local_" + UUID().uuidString.lowercased()
        let cliID = conflict == "local" ? UUID().uuidString.lowercased() : session.cliID
        let targetURL = fixture.indexURL(localID, account: fixture.target)
        let targetBytes = try fixture.record(localID: localID, cliID: cliID, title: "Conflicting target")
        try fixture.disk.write(targetBytes, to: targetURL)
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        #expect(try fixture.indexFiles(fixture.target).count == 1)
        #expect(await controller.terminationCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Deletion markers in the source or target suppress that conversation without removing its source index", arguments: ["source", "target"])
    func tombstonesSuppressCopy(location: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let suppressed = try fixture.addSession(), kept = try fixture.addSession()
        let tombstone = try fixture.addTombstone(for: suppressed, account: location == "source" ? fixture.source : fixture.target)
        let tombstoneBytes = try fixture.disk.read(tombstone)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        #expect(try fixture.disk.read(fixture.indexURL(suppressed.localID, account: fixture.target)) == nil)
        #expect(try fixture.disk.read(fixture.indexURL(kept.localID, account: fixture.target)) != nil)
        #expect(try fixture.disk.read(tombstone) == tombstoneBytes)
        try fixture.assertSourceUnchanged(suppressed)
        try fixture.assertSourceUnchanged(kept)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Unsafe or unknown index schemas refuse before publication", arguments: ["stagedTranscriptPath", "remoteTarget", "sshConnection", "wslDistribution", "executionState", "permissionMode", "futureExecutionState"])
    func unsafeSchemaFailsClosed(field: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession(extra: [field: "untrusted fixture state"])
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Native interruption and remote-steering defaults must remain null", arguments: ["interrupted-string", "interrupted-object", "steered-string", "steered-object"])
    func nonnullExecutionAssociationFailsClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let field = reason.hasPrefix("interrupted") ? "interruptedAwaitingPerson" : "steeredByRemoteClient"
        let value: Any = reason.hasSuffix("object") ? ["type": "fixture-active-execution"] : "fixture-active-execution"
        let session = try fixture.addSession(extra: [field: value])
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Archive flags and timestamps must have their normal local record types", arguments: ["archive-string", "archive-number", "creation-boolean", "activity-boolean", "creation-negative"])
    func malformedNormalMetadataFailsClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let extra: [String: Any]
        switch reason {
        case "archive-string": extra = ["isArchived": "false"]
        case "archive-number": extra = ["isArchived": 2]
        case "creation-boolean": extra = ["createdAt": true]
        case "activity-boolean": extra = ["lastActivityAt": false]
        default: extra = ["createdAt": -1]
        }
        let session = try fixture.addSession(extra: extra)
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.terminationCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Missing, ambiguous or symlinked backing transcripts refuse before copying", arguments: ["missing", "ambiguous", "symlink"])
    func unsafeBackingTranscriptFailsClosed(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        if reason == "ambiguous" {
            let duplicate = fixture.home.appendingPathComponent(".claude/projects/another-project").appendingPathComponent(session.cliID + ".jsonl")
            try fixture.disk.write(session.transcriptBytes, to: duplicate)
        } else {
            try fixture.disk.delete(session.transcriptURL)
            if reason == "symlink" {
                let actual = fixture.home.appendingPathComponent("original-transcript.jsonl")
                try fixture.disk.write(session.transcriptBytes, to: actual)
                try FileManager.default.createSymbolicLink(at: session.transcriptURL, withDestinationURL: actual)
            }
        }
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(try fixture.disk.read(session.sourceURL) == session.sourceBytes)
        #expect(await controller.terminationCount == 0)
    }

    @Test("Only a direct normal project-bucket transcript can back a copied Desktop session", arguments: ["cwd", "worktreePath", "originCwd", "fallback"])
    func nativeDirectBackingIsAccepted(location: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let alternatePath = fixture.home.appendingPathComponent("alternate-project").path
        let extra: [String: Any] = location == "worktreePath" || location == "originCwd" ? [location: alternatePath] : [:]
        let session = try fixture.addSession(extra: extra)
        var backing = session.transcriptURL
        if location != "cwd" {
            let bucketName = location == "fallback" ? "fixture-immediate-fallback" : alternatePath.map {
                $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-"
            }.joined()
            backing = fixture.home.appendingPathComponent(".claude/projects").appendingPathComponent(bucketName).appendingPathComponent(session.cliID + ".jsonl")
            try fixture.disk.write(session.transcriptBytes, to: backing)
            try fixture.disk.delete(session.transcriptURL)
        }
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let target = try authObject(Data(contentsOf: fixture.indexURL(session.localID, account: fixture.target)), name: "Direct-backed target index")
        #expect(target["sessionId"] as? String == session.localID)
        #expect(target["cliSessionId"] as? String == session.cliID)
        #expect(try fixture.disk.read(session.sourceURL) == session.sourceBytes)
        #expect(try fixture.disk.read(backing) == session.transcriptBytes)
        _ = try await store.finish(result, applied: true)
    }

    @Test("A nested subagent or SSH-only transcript cannot back a normal Desktop index", arguments: ["nested-subagent", "ssh-session", "ssh-shared"])
    func nativeUnresolvableBackingFailsClosed(location: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let directory: URL
        switch location {
        case "nested-subagent": directory = session.transcriptURL.deletingLastPathComponent().appendingPathComponent(session.cliID + "/subagents")
        case "ssh-session": directory = fixture.home.appendingPathComponent(".claude/projects/ssh-" + session.cliID)
        default: directory = fixture.home.appendingPathComponent(".claude/projects/ssh-sessions")
        }
        let inaccessibleBacking = directory.appendingPathComponent(session.cliID + ".jsonl")
        try fixture.disk.write(session.transcriptBytes, to: inaccessibleBacking)
        try fixture.disk.delete(session.transcriptURL)
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(await controller.terminationCount == 0)
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(try fixture.disk.read(session.sourceURL) == session.sourceBytes)
        #expect(try fixture.disk.read(inaccessibleBacking) == session.transcriptBytes)
    }

    @Test("A running Desktop without relaunch authorization remains pending without changes")
    func runningDesktopNeedsRelaunch() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop])])
        let files = SessionPreserverFiles()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        if case .pendingRelaunch(let message) = result { #expect(!message.isEmpty) }
        else { Issue.record("Expected pending relaunch for running Claude Desktop") }
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        #expect(files.writes().isEmpty)
        #expect(files.deletions().isEmpty)
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("An external CLI using the same transcript keeps preservation pending without quitting Desktop")
    func activeExternalCLIRequiresExit() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let external = ClaudeDesktopConversationProcessIdentity(pid: 99, startedAt: 1)
        let registryURL = fixture.home.appendingPathComponent(".claude/sessions/99.json")
        let registryBytes = try authData(["sessionId": session.cliID])
        try fixture.disk.write(registryBytes, to: registryURL)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop, external])])
        let files = SessionPreserverFiles()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        if case .pendingRelaunch(let message) = result { #expect(!message.isEmpty) }
        else { Issue.record("Expected pending preservation while another CLI writes the same session") }
        #expect(await controller.terminationCount == 0)
        #expect(await controller.relaunchCount == 0)
        #expect(files.writes().isEmpty)
        #expect(files.deletions().isEmpty)
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(try fixture.disk.read(registryURL) == registryBytes)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Approved normal quit waits for tracked descendants while unrelated CLI and reused PIDs remain independent")
    func normalQuitTracksDescendants() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let child = ClaudeDesktopConversationProcessIdentity(pid: 11, startedAt: 1)
        let unrelated = ClaudeDesktopConversationProcessIdentity(pid: 12, startedAt: 1)
        let reused = ClaudeDesktopConversationProcessIdentity(pid: 11, startedAt: 2)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [
            .init(desktop: [desktop], related: [desktop, child], live: [desktop, child, unrelated]),
            .init(live: [unrelated, reused])
        ])
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller, terminationTimeout: 0)
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        #expect(try requirePrepared(result).count == 1)
        #expect(await controller.terminationCount == 1)
        #expect(try fixture.disk.read(fixture.indexURL(session.localID, account: fixture.target)) != nil)
        try fixture.assertSourceUnchanged(session)
        _ = try await store.finish(result, applied: true)
    }

    @Test("Refused normal quit, surviving descendants and unreliable scans leave target indices unchanged", arguments: ["refused", "descendant", "unreliable"])
    func failedQuitIsUnchanged(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1), child = ClaudeDesktopConversationProcessIdentity(pid: 11, startedAt: 1)
        let initial = ClaudeDesktopConversationProcessSnapshot(desktop: [desktop], related: [desktop, child], live: [desktop, child])
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: reason == "unreliable" ? [.init(reliable: false)] : [initial, .init(live: [child])])
        if reason == "refused" { await controller.rejectTermination() }
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller, terminationTimeout: 0)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(await controller.relaunchCount == 0)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("A post-quit source schema change relaunches Desktop and leaves the external change intact")
    func inventoryFailureAfterQuitRelaunchesDesktop() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let externalChange = try fixture.record(localID: session.localID, cliID: session.cliID, extra: ["futureExecutionState": "External change"])
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop]), .init()])
        await controller.onTermination { try fixture.disk.write(externalChange, to: session.sourceURL) }
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(await controller.terminationCount == 1)
        #expect(await controller.relaunchCount == 1)
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        #expect(try fixture.disk.read(session.sourceURL) == externalChange)
        #expect(try fixture.disk.read(session.transcriptURL) == session.transcriptBytes)
    }

    @Test("A preservation journal write failure after normal quit relaunches Desktop without copying indices")
    func journalWriteFailureAfterQuitRelaunchesDesktop() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 1)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop]), .init()])
        let files = SessionPreserverFiles()
        files.failNextWrite()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: true)
        }
        #expect(await controller.terminationCount == 1)
        #expect(await controller.relaunchCount == 1)
        #expect(files.writes().count == 1)
        #expect(try fixture.indexFiles(fixture.target).isEmpty)
        try fixture.assertSourceUnchanged(session)
        expectNotNeeded(try await store.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false))
    }

    @Test("Failed authentication rolls back only the newly prepared target indices")
    func failedAuthenticationRollsBackNewCopies() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let existingID = "local_" + UUID().uuidString.lowercased()
        let existingURL = fixture.indexURL(existingID, account: fixture.target)
        let existingBytes = try fixture.record(localID: existingID, cliID: UUID().uuidString.lowercased(), title: "Target-only conversation")
        try fixture.disk.write(existingBytes, to: existingURL)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        _ = try await store.finish(result, applied: false)
        #expect(try fixture.disk.read(fixture.indexURL(session.localID, account: fixture.target)) == nil)
        #expect(try fixture.disk.read(existingURL) == existingBytes)
        try fixture.assertSourceUnchanged(session)
        expectNotNeeded(try await store.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false))
    }

    @Test("Rollback retains a newly copied target that another writer has edited")
    func rollbackDoesNotRemoveConcurrentTargetEdits() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let edited = try fixture.record(localID: session.localID, cliID: session.cliID, title: "Edited after preparation", archived: true)
        try fixture.disk.write(edited, to: targetURL)
        await #expect(throws: (any Error).self) { try await store.finish(result, applied: false) }
        #expect(try fixture.disk.read(targetURL) == edited)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Rollback refuses to remove target indices while Desktop has restarted")
    func rollbackWaitsForDesktopExit() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let controller = SessionPreserverProcesses(url: fixture.app)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: controller)
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let targetBytes = try fixture.disk.read(targetURL)
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 2)
        await controller.useSnapshots([.init(desktop: [desktop], related: [desktop], live: [desktop])])
        await #expect(throws: (any Error).self) { try await store.finish(result, applied: false) }
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        #expect(targetBytes != nil)
        try fixture.assertSourceUnchanged(session)
        await controller.useSnapshots([.init()])
        _ = try await store.finish(result, applied: false)
        #expect(try fixture.disk.read(targetURL) == nil)
    }

    @Test("Applied authentication commits the copies and preserves shared transcripts")
    func appliedAuthenticationCommitsCopies() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let targetBytes = try fixture.disk.read(targetURL)
        _ = try await store.finish(result, applied: true)
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        #expect(targetBytes != nil)
        try fixture.assertSourceUnchanged(session)
        expectNotNeeded(try await store.prepareForSwitch(source: fixture.target, target: fixture.target, relaunch: false))
    }

    @Test("A partial target publication failure removes only this operation's new indices")
    func partialWriteRollsBackNewFiles() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let first = try fixture.addSession(), second = try fixture.addSession()
        let existingID = "local_" + UUID().uuidString.lowercased()
        let existingURL = fixture.indexURL(existingID, account: fixture.target)
        let existingBytes = try fixture.record(localID: existingID, cliID: UUID().uuidString.lowercased(), title: "Keep existing target")
        try fixture.disk.write(existingBytes, to: existingURL)
        let files = SessionPreserverFiles()
        files.failIndexWrite(in: fixture.bucket(fixture.target), afterSuccesses: 1)
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: SessionPreserverProcesses(url: fixture.app))
        await #expect(throws: (any Error).self) {
            try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        }
        let targetWrites = files.writes().filter {
            $0.deletingLastPathComponent().standardizedFileURL == fixture.bucket(fixture.target).standardizedFileURL && $0.lastPathComponent.hasPrefix("local_")
        }
        #expect(targetWrites.count == 2)
        #expect(try fixture.indexFiles(fixture.target).map(\.lastPathComponent) == [existingURL.lastPathComponent])
        #expect(try fixture.disk.read(existingURL) == existingBytes)
        try fixture.assertSourceUnchanged(first)
        try fixture.assertSourceUnchanged(second)
    }

    @Test("A recreated preserver recovers an unfinished journal by the actual current account", arguments: [false, true])
    func journalRecoveryUsesActualIdentity(applied: Bool) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let initial = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await initial.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let targetBytes = try fixture.disk.read(targetURL)
        let actual = applied ? fixture.target : fixture.source
        let recovered = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        expectNotNeeded(try await recovered.prepareForSwitch(source: actual, target: actual, relaunch: false))
        #expect(try fixture.disk.read(targetURL) == (applied ? targetBytes : nil))
        try fixture.assertSourceUnchanged(session)
    }

    @Test("A failed journal rollback after normal quit relaunches Desktop and retains recovery evidence", arguments: ["changed-target", "target-read-failure"])
    func recoveryFailureAfterQuitRelaunchesDesktop(reason: String) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let files = SessionPreserverFiles()
        let initial = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: SessionPreserverProcesses(url: fixture.app))
        let prepared = try await initial.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(prepared).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let preparedBytes = try #require(try fixture.disk.read(targetURL))
        let externalEdit = try fixture.record(localID: session.localID, cliID: session.cliID, title: "Edited before journal recovery")
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 10, startedAt: 2)
        let controller = SessionPreserverProcesses(url: fixture.app, snapshots: [.init(desktop: [desktop], related: [desktop], live: [desktop]), .init()])
        await controller.onTermination {
            if reason == "changed-target" { try fixture.disk.write(externalEdit, to: targetURL) }
            else { files.failNextRead(at: targetURL) }
        }
        let recovering = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: controller)
        await #expect(throws: (any Error).self) {
            try await recovering.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: true)
        }
        #expect(await controller.terminationCount == 1)
        #expect(await controller.relaunchCount == 1)
        #expect(try fixture.disk.read(targetURL) == (reason == "changed-target" ? externalEdit : preparedBytes))
        try fixture.assertSourceUnchanged(session)
        let retry = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: SessionPreserverProcesses(url: fixture.app))
        if reason == "changed-target" {
            await #expect(throws: (any Error).self) { try await retry.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false) }
            #expect(try fixture.disk.read(targetURL) == externalEdit)
        } else {
            #expect(files.readFailures() == 1)
            expectNotNeeded(try await retry.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false))
            #expect(try fixture.disk.read(targetURL) == nil)
        }
        try fixture.assertSourceUnchanged(session)
    }

    @Test("A durably committed journal keeps copies even when its cleanup failed")
    func committedJournalRecoveryKeepsCopies() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let files = SessionPreserverFiles()
        let initial = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await initial.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let targetBytes = try fixture.disk.read(targetURL)
        files.failNextDeletion()
        await #expect(throws: (any Error).self) { try await initial.finish(result, applied: true) }
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        let recovered = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        expectNotNeeded(try await recovered.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false))
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        #expect(targetBytes != nil)
        try fixture.assertSourceUnchanged(session)
    }

    @Test("Unknown or absent current identity leaves an unfinished transaction intact and fails closed", arguments: [true, false])
    func journalRecoveryUnknownIdentityFailsClosed(useThirdAccount: Bool) async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let initial = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await initial.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        let targetURL = fixture.indexURL(session.localID, account: fixture.target)
        let targetBytes = try fixture.disk.read(targetURL)
        let third = AccountRecord(identity: .init(provider: .claude, userID: UUID().uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased()))
        let recovered = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        await #expect(throws: (any Error).self) {
            try await recovered.prepareForSwitch(source: useThirdAccount ? third : nil, target: third, relaunch: false)
        }
        #expect(try fixture.disk.read(targetURL) == targetBytes)
        #expect(targetBytes != nil)
        try fixture.assertSourceUnchanged(session)
        let knownIdentity = ClaudeDesktopSessionPreserver(homeURL: fixture.home, processController: SessionPreserverProcesses(url: fixture.app))
        expectNotNeeded(try await knownIdentity.prepareForSwitch(source: fixture.source, target: fixture.source, relaunch: false))
        #expect(try fixture.disk.read(targetURL) == nil)
    }

    @Test("Preservation does not read or modify authentication, cookie or private-key files")
    func avoidsSensitiveFiles() async throws {
        let fixture = try SessionPreserverFixture(); defer { fixture.cleanup() }
        let session = try fixture.addSession()
        let sensitiveURLs = [fixture.home.appendingPathComponent(".claude/.credentials.json"),
                             fixture.home.appendingPathComponent(".claude.json"),
                             fixture.userData.appendingPathComponent("Cookies"),
                             fixture.home.appendingPathComponent(".ssh/id_ed25519")]
        let sentinel = Data("Private fixture bytes must stay untouched".utf8)
        for url in sensitiveURLs { try fixture.disk.write(sentinel, to: url) }
        let files = SessionPreserverFiles()
        let store = ClaudeDesktopSessionPreserver(homeURL: fixture.home, files: files, processController: SessionPreserverProcesses(url: fixture.app))
        let result = try await store.prepareForSwitch(source: fixture.source, target: fixture.target, relaunch: false)
        #expect(try requirePrepared(result).count == 1)
        _ = try await store.finish(result, applied: true)
        for url in sensitiveURLs {
            #expect(!files.reads().contains(url.standardizedFileURL))
            #expect(!files.writes().contains(url.standardizedFileURL))
            #expect(!files.deletions().contains(url.standardizedFileURL))
            #expect(try fixture.disk.read(url) == sentinel)
        }
        try fixture.assertSourceUnchanged(session)
    }
}
