import Foundation
import Testing
import Darwin
@testable import AgentSwapCore

private actor DesktopProfileMemoryStore: ClaudeDesktopProfileStoring {
    var profiles: [ClaudeDesktopProfile]
    private(set) var saves = 0
    private(set) var prepared: [UUID] = []
    var saveFails = false
    var loadFails = false
    init(_ profiles: [ClaudeDesktopProfile] = []) { self.profiles = profiles }
    func load() throws -> [ClaudeDesktopProfile] {
        if loadFails { throw AgentSwapError.storage("Fixture metadata read failure") }
        return profiles
    }
    func save(_ profiles: [ClaudeDesktopProfile]) throws {
        if saveFails { throw AgentSwapError.storage("Fixture metadata save failure") }
        self.profiles = profiles; saves += 1
    }
    func prepareDirectory(profileID: UUID) -> URL {
        prepared.append(profileID)
        return URL(fileURLWithPath: "/Fixture/DesktopProfiles/\(profileID.uuidString)", isDirectory: true)
    }
    func failSave() { saveFails = true }
    func failLoad() { loadFails = true }
}

private actor DesktopProfileProcesses: ClaudeDesktopConversationProcessControlling {
    private var snapshots: [ClaudeDesktopConversationProcessSnapshot]
    private(set) var scans = 0
    private(set) var terminations = 0
    private let acceptsTermination: Bool
    private let version: String
    init(_ snapshots: [ClaudeDesktopConversationProcessSnapshot] = [.init()], acceptsTermination: Bool = true, version: String = "3.1623.0") {
        self.snapshots = snapshots; self.acceptsTermination = acceptsTermination; self.version = version
    }
    func installation(at applicationURL: URL?) -> ClaudeDesktopConversationInstallation? {
        .init(url: URL(fileURLWithPath: "/Fixture/Claude.app"), version: version)
    }
    func scan(applicationURL: URL) -> ClaudeDesktopConversationProcessSnapshot {
        defer { scans += 1 }
        return snapshots[min(scans, snapshots.count - 1)]
    }
    func requestNormalTermination() -> Bool { terminations += 1; return acceptsTermination }
    func relaunch(at applicationURL: URL) { Issue.record("The old relaunch path must not bypass the selected profile") }
}

private actor DesktopProfileLauncher: ClaudeDesktopProfileLaunching {
    private(set) var configurations: [ClaudeDesktopProfileLaunchConfiguration] = []
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func launch(applicationURL: URL, configuration: ClaudeDesktopProfileLaunchConfiguration) throws {
        configurations.append(configuration)
        if fails { throw AgentSwapError.storage("Fixture launch failure") }
    }
}

private struct DesktopProfileFileFixture {
    let home: URL
    var root: URL { home.appendingPathComponent("DesktopProfiles", isDirectory: true) }
    var metadata: URL { root.appendingPathComponent("profiles.json") }
    init() throws {
        // Foundation normalizes /private/var back to the /var system symlink;
        // use the kernel's canonical spelling to test strict no-symlink parents.
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        home = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("AgentSwapDesktopProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite("Claude Desktop native profile isolation")
struct ClaudeDesktopProfileTests {
    @Test("A selected profile uses only Electron's native directory flag and removes inherited auth or runtime overrides")
    func launchConfiguration() {
        let unsafeKeys = ["CLAUDE_USER_DATA_DIR", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CODEX_HOME",
                          "OPENAI_API_KEY", "ELECTRON_RUN_AS_NODE", "ELECTRON_EXTRA_LAUNCH_ARGS", "NODE_OPTIONS", "NODE_PATH", "claude_custom"]
        var inherited = Dictionary(uniqueKeysWithValues: unsafeKeys.map { ($0, "fixture-private") })
        inherited["HOME"] = "/Fixture/Home"; inherited["PATH"] = "/usr/bin:/bin"
        let directory = URL(fileURLWithPath: "/Fixture/Profile With Spaces", isDirectory: true)
        let selected = ClaudeDesktopProfileLaunchConfiguration(profileDirectory: directory, inheritedEnvironment: inherited)
        #expect(selected.arguments == ["--user-data-dir=/Fixture/Profile With Spaces"])
        #expect(selected.environment == ["HOME": "/Fixture/Home", "PATH": "/usr/bin:/bin"])
        let original = ClaudeDesktopProfileLaunchConfiguration(profileDirectory: nil, inheritedEnvironment: inherited)
        #expect(original.arguments.isEmpty)
        #expect(original.profileDirectory == nil)
        #expect(original.environment == selected.environment)
    }

    @Test("Profile metadata contains only names and UUIDs and native directories stay private")
    func metadataAndDirectories() async throws {
        let fixture = try DesktopProfileFileFixture(); defer { fixture.cleanup() }
        let profiles = [ClaudeDesktopProfile(name: "개인용"), ClaudeDesktopProfile(name: "업무용")]
        let store = FileClaudeDesktopProfileStore(directory: fixture.root)
        #expect(try await store.load().isEmpty)
        try await store.save(profiles)
        #expect(try await store.load() == profiles)
        let first = try await store.prepareDirectory(profileID: profiles[0].id)
        let second = try await store.prepareDirectory(profileID: profiles[1].id)
        #expect(first != second)
        #expect(first.lastPathComponent == profiles[0].id.uuidString)
        let document = try ProviderJSON.object(Data(contentsOf: fixture.metadata))
        #expect(Set(document.keys) == ["schemaVersion", "profiles"])
        let items = try #require(document["profiles"] as? [[String: Any]])
        #expect(items.allSatisfy { Set($0.keys) == ["id", "name"] })
        for url in [fixture.root, first, second, fixture.metadata] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
            #expect(mode == (url == fixture.metadata ? 0o600 : 0o700))
        }
        // Arbitrary native content is left to Desktop; the store never decodes or copies it.
        let nativeContent = first.appendingPathComponent("Cookies")
        let sentinel = Data("fixture-native-private-data".utf8)
        try sentinel.write(to: nativeContent)
        #expect(try await store.prepareDirectory(profileID: profiles[0].id) == first)
        #expect(try Data(contentsOf: nativeContent) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("Cookies").path))
    }

    @Test("Unknown metadata is preserved instead of being replaced by a new profile", arguments: [
        Data(#"{"schemaVersion":2,"profiles":[]}"#.utf8), Data("fixture-corrupt-metadata".utf8)
    ])
    func preserveUnknownMetadata(_ original: Data) async throws {
        let fixture = try DesktopProfileFileFixture(); defer { fixture.cleanup() }
        try AtomicAuthFileAccess().write(original, to: fixture.metadata)
        let store = FileClaudeDesktopProfileStore(directory: fixture.root)
        await #expect(throws: AgentSwapError.self) { try await store.save([.init(name: "새 프로필")]) }
        #expect(try Data(contentsOf: fixture.metadata) == original)
    }

    @Test("A symlink or public profile directory cannot redirect native login storage", arguments: ["rootSymlink", "profileSymlink", "publicProfile", "metadataSymlink"])
    func unsafePaths(_ kind: String) async throws {
        let fixture = try DesktopProfileFileFixture(); defer { fixture.cleanup() }
        let profile = ClaudeDesktopProfile(name: "합성 프로필")
        let store = FileClaudeDesktopProfileStore(directory: fixture.root)
        if kind == "rootSymlink" {
            let target = fixture.home.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: target)
            await #expect(throws: AgentSwapError.self) { try await store.save([profile]) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            return
        }
        try await store.save([profile])
        let original = try Data(contentsOf: fixture.metadata)
        if kind == "metadataSymlink" {
            let moved = fixture.home.appendingPathComponent("OriginalMetadata.json")
            try FileManager.default.moveItem(at: fixture.metadata, to: moved)
            try FileManager.default.createSymbolicLink(at: fixture.metadata, withDestinationURL: moved)
        } else {
            let directory = fixture.root.appendingPathComponent(profile.id.uuidString)
            if kind == "profileSymlink" {
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.home)
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            }
        }
        await #expect(throws: AgentSwapError.self) { try await store.prepareDirectory(profileID: profile.id) }
        #expect(try Data(contentsOf: fixture.metadata) == original)
    }

    @MainActor @Test("Profile creation persists only metadata; explicit open and original default use distinct launch configurations")
    func explicitOpenAndDefault() async throws {
        let store = DesktopProfileMemoryStore(), processes = DesktopProfileProcesses(), launcher = DesktopProfileLauncher()
        let model = ClaudeDesktopProfileModel(store: store, processes: processes, launcher: launcher, timeout: 0)
        await model.load(); await model.addProfile(name: "  업무용  ")
        let profile = try #require(model.profiles.first)
        #expect(profile.name == "업무용")
        #expect(await launcher.configurations.isEmpty)
        #expect(await store.prepared.isEmpty)
        await model.openProfile(profile.id)
        #expect(await launcher.configurations.first?.profileDirectory?.lastPathComponent == profile.id.uuidString)
        #expect(model.lastOpenedProfileID == profile.id)
        #expect(model.message?.contains("로그인해 주세요") == true)
        await model.openDefault()
        #expect(await launcher.configurations.count == 2)
        #expect(await launcher.configurations.last?.arguments.isEmpty == true)
        #expect(model.lastOpenedProfileID == nil)
        #expect(await processes.terminations == 0)
    }

    @MainActor @Test("A refused quit, surviving descendant, unreliable scan or last-moment relaunch blocks profile launch", arguments: ["refused", "descendant", "unreliable", "race"])
    func unsafeProcessBoundary(_ kind: String) async throws {
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 100, startedAt: 1)
        let child = ClaudeDesktopConversationProcessIdentity(pid: 101, startedAt: 2)
        let initial = ClaudeDesktopConversationProcessSnapshot(desktop: [desktop], related: [desktop, child], live: [desktop, child])
        let snapshots: [ClaudeDesktopConversationProcessSnapshot]
        switch kind {
        case "unreliable": snapshots = [.init(reliable: false)]
        case "descendant": snapshots = [initial, .init(live: [child])]
        case "race": snapshots = [initial, .init(), initial]
        default: snapshots = [initial]
        }
        let profile = ClaudeDesktopProfile(name: "합성 프로필")
        let store = DesktopProfileMemoryStore([profile]), launcher = DesktopProfileLauncher()
        let processes = DesktopProfileProcesses(snapshots, acceptsTermination: kind != "refused")
        let model = ClaudeDesktopProfileModel(store: store, processes: processes, launcher: launcher, timeout: 0)
        await model.openProfile(profile.id)
        #expect(await launcher.configurations.isEmpty)
        #expect(model.message != nil)
        #expect(model.lastOpenedProfileID == nil)
        #expect(try await store.load() == [profile])
    }

    @MainActor @Test("Normal termination and a stopped descendant generation permit profile launch")
    func gracefulSwitch() async throws {
        let desktop = ClaudeDesktopConversationProcessIdentity(pid: 100, startedAt: 1)
        let oldChild = ClaudeDesktopConversationProcessIdentity(pid: 101, startedAt: 2)
        let reusedPID = ClaudeDesktopConversationProcessIdentity(pid: 101, startedAt: 3)
        let initial = ClaudeDesktopConversationProcessSnapshot(desktop: [desktop], related: [desktop, oldChild], live: [desktop, oldChild])
        let stopped = ClaudeDesktopConversationProcessSnapshot(live: [reusedPID])
        let processes = DesktopProfileProcesses([initial, stopped, stopped]), launcher = DesktopProfileLauncher()
        let profile = ClaudeDesktopProfile(name: "합성 프로필"), store = DesktopProfileMemoryStore()
        try await store.save([profile])
        let model = ClaudeDesktopProfileModel(store: store, processes: processes, launcher: launcher, timeout: 0)
        await model.openProfile(profile.id)
        #expect(await processes.terminations == 1)
        #expect(await launcher.configurations.count == 1)
        #expect(model.lastOpenedProfileID == profile.id)
    }

    @MainActor @Test("Launch failure keeps metadata and never claims the selected profile opened")
    func failureKeepsMetadata() async throws {
        let profile = ClaudeDesktopProfile(name: "합성 프로필"), launcher = DesktopProfileLauncher(fails: true)
        let store = DesktopProfileMemoryStore([profile])
        let model = ClaudeDesktopProfileModel(store: store, processes: DesktopProfileProcesses(), launcher: launcher, timeout: 0)
        await model.openProfile(profile.id)
        #expect(model.profiles == [profile])
        #expect(try await store.load() == [profile])
        #expect(model.lastOpenedProfileID == nil)
        #expect(model.message == "Fixture launch failure")
    }

    @MainActor @Test("Returning to the original Desktop remains available when profile metadata cannot be read")
    func originalDoesNotRequireMetadata() async {
        let store = DesktopProfileMemoryStore(), launcher = DesktopProfileLauncher()
        await store.failLoad()
        let model = ClaudeDesktopProfileModel(store: store, processes: DesktopProfileProcesses(), launcher: launcher)
        await model.load()
        #expect(model.message == "Fixture metadata read failure")
        await model.openDefault()
        #expect(await launcher.configurations.count == 1)
        #expect(await launcher.configurations.first?.arguments.isEmpty == true)
        #expect(await store.prepared.isEmpty)
        #expect(await store.saves == 0)
    }

    @MainActor @Test("Shutdown rejects new profile work until a failed app termination is resumed")
    func shutdownGate() async {
        let store = DesktopProfileMemoryStore(), launcher = DesktopProfileLauncher()
        let model = ClaudeDesktopProfileModel(store: store, processes: DesktopProfileProcesses(), launcher: launcher)
        await model.prepareForTermination()
        await model.addProfile(name: "보류")
        await model.openDefault()
        #expect(await store.saves == 0)
        #expect(await launcher.configurations.isEmpty)
        model.resumeAfterTerminationFailure()
        await model.addProfile(name: "재개")
        #expect(await store.saves == 1)
    }

    @MainActor @Test("Unknown Desktop versions cannot silently open the default account as an isolated profile")
    func versionBoundary() async {
        let profile = ClaudeDesktopProfile(name: "합성 프로필"), launcher = DesktopProfileLauncher()
        let processes = DesktopProfileProcesses(version: "fixture-unknown")
        let model = ClaudeDesktopProfileModel(store: DesktopProfileMemoryStore([profile]), processes: processes, launcher: launcher)
        await model.openProfile(profile.id)
        #expect(await launcher.configurations.isEmpty)
        #expect(await processes.scans == 0)
        #expect(model.message?.contains("아직 확인하지 못했습니다") == true)
        await model.openDefault()
        #expect(await launcher.configurations.count == 1)
        #expect(await launcher.configurations.first?.arguments.isEmpty == true)
    }

    @MainActor @Test("A profile action queued behind CLI work drains without quitting or launching during app shutdown", .timeLimit(.minutes(1)))
    func queuedShutdown() async {
        let profile = ClaudeDesktopProfile(name: "합성 프로필"), launcher = DesktopProfileLauncher()
        let processes = DesktopProfileProcesses(), queue = AccountOperationQueue()
        let model = ClaudeDesktopProfileModel(store: DesktopProfileMemoryStore([profile]), processes: processes, launcher: launcher)
        model.connectOperationQueue(queue)
        await queue.acquire(.claude)
        let opening = Task { await model.openProfile(profile.id) }
        while !model.isBusy { await Task.yield() }
        model.beginTermination()
        let draining = Task { await model.prepareForTermination() }
        await queue.release(.claude)
        await opening.value; await draining.value
        #expect(await processes.terminations == 0)
        #expect(await launcher.configurations.isEmpty)
        #expect(!model.isBusy)
        model.resumeAfterTerminationFailure()
        await model.openProfile(profile.id)
        #expect(await launcher.configurations.count == 1)
    }
}
