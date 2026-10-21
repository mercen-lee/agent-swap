import Foundation
import Observation
import AppKit
import Darwin

/// A name for a native Desktop data directory, never a copy of CLI authentication.
public struct ClaudeDesktopProfile: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public protocol ClaudeDesktopProfileStoring: Sendable {
    func load() async throws -> [ClaudeDesktopProfile]
    func save(_ profiles: [ClaudeDesktopProfile]) async throws
    func prepareDirectory(profileID: UUID) async throws -> URL
}

/// Only the official Desktop app reads and writes the login and sessions in this directory.
public struct ClaudeDesktopProfileLaunchConfiguration: Sendable, Equatable {
    public var profileDirectory: URL?
    public var arguments: [String]
    public var environment: [String: String]
    public init(profileDirectory: URL?, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.profileDirectory = profileDirectory
        arguments = profileDirectory.map { ["--user-data-dir=\($0.path)"] } ?? []
        environment = inheritedEnvironment.filter { key, _ in
            let key = key.uppercased()
            return !["CLAUDE_", "ANTHROPIC_", "CODEX_", "OPENAI_", "ELECTRON_"].contains(where: key.hasPrefix)
                && key != "NODE_OPTIONS" && key != "NODE_PATH"
        }
    }
}

public protocol ClaudeDesktopProfileLaunching: Sendable {
    func launch(applicationURL: URL, configuration: ClaudeDesktopProfileLaunchConfiguration) async throws
}

public struct SystemClaudeDesktopProfileLauncher: ClaudeDesktopProfileLaunching {
    public init() {}
    @MainActor public func launch(applicationURL: URL, configuration: ClaudeDesktopProfileLaunchConfiguration) async throws {
        if let directory = configuration.profileDirectory { try validateDesktopProfileDirectory(directory, privateDirectory: true) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            options.createsNewApplicationInstance = true
            options.allowsRunningApplicationSubstitution = false
            options.arguments = configuration.arguments
            options.environment = configuration.environment
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: options) { application, error in
                guard error == nil, application != nil else {
                    continuation.resume(throwing: AgentSwapError.storage("Claude 데스크톱 프로필을 열지 못했습니다. 저장된 프로필은 유지됩니다."))
                    return
                }
                continuation.resume()
            }
        }
    }
}

public actor FileClaudeDesktopProfileStore: ClaudeDesktopProfileStoring {
    public nonisolated let directory: URL
    private let files: any AuthFileAccess
    private var metadataURL: URL { directory.appendingPathComponent("profiles.json") }
    private struct Document: Codable { var schemaVersion = 1; var profiles: [ClaudeDesktopProfile] }
    public init(directory: URL? = nil, files: any AuthFileAccess = AtomicAuthFileAccess()) {
        self.directory = (directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentSwap/ClaudeDesktopProfiles", isDirectory: true))
        self.files = files
    }
    public func load() throws -> [ClaudeDesktopProfile] {
        try validateRoot(create: false)
        try validateMetadataIfPresent()
        guard let data = try files.read(metadataURL) else { return [] }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw AgentSwapError.storage("Claude 데스크톱 프로필 목록을 읽지 못했습니다. 원본을 보존합니다.") }
        guard document.schemaVersion == 1 else { throw AgentSwapError.unsupported("새로운 Claude 데스크톱 프로필 형식을 발견해 변경을 중단했습니다.") }
        try validateDesktopProfiles(document.profiles)
        return document.profiles
    }
    public func save(_ profiles: [ClaudeDesktopProfile]) throws {
        try validateDesktopProfiles(profiles)
        _ = try load() // Refuse overwriting a corrupt or newer metadata document.
        try validateRoot(create: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(encoder.encode(Document(profiles: profiles)), to: metadataURL)
        try validateMetadataIfPresent()
        guard try load() == profiles else { throw AgentSwapError.storage("Claude 데스크톱 프로필 목록의 저장 결과를 확인하지 못했습니다.") }
    }
    public func prepareDirectory(profileID: UUID) throws -> URL {
        guard try load().contains(where: { $0.id == profileID }) else { throw AgentSwapError.storage("저장된 Claude 데스크톱 프로필을 찾지 못했습니다.") }
        try validateRoot(create: true)
        let profile = directory.appendingPathComponent(profileID.uuidString, isDirectory: true)
        if Darwin.mkdir(profile.path, 0o700) != 0, errno != EEXIST { throw desktopProfileStorageError() }
        try validateDesktopProfileDirectory(profile, privateDirectory: true)
        return profile
    }
    private func validateRoot(create: Bool) throws {
        let components = directory.pathComponents
        guard directory.isFileURL, directory.path.hasPrefix("/"), components.count > 2,
              !components.contains(".."), !components.contains(".") else { throw desktopProfileStorageError() }
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            candidate.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(candidate.path, &info) != 0 {
                guard errno == ENOENT else { throw desktopProfileStorageError() }
                if !create { return }
                guard Darwin.mkdir(candidate.path, 0o700) == 0 || errno == EEXIST else { throw desktopProfileStorageError() }
            }
            try validateDesktopProfileDirectory(candidate, privateDirectory: candidate == directory, checkAncestors: false)
        }
    }
    private func validateMetadataIfPresent() throws {
        var info = stat()
        if lstat(metadataURL.path, &info) != 0 {
            guard errno == ENOENT else { throw desktopProfileStorageError() }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_nlink == 1 else { throw desktopProfileStorageError() }
    }
}

private func desktopProfileStorageError() -> AgentSwapError {
    .storage("Claude 데스크톱 프로필 경로의 소유권·권한·연결을 확인하지 못해 변경을 중단했습니다.")
}

private func validateDesktopProfileDirectory(_ directory: URL, privateDirectory: Bool, checkAncestors: Bool = true) throws {
    guard directory.isFileURL else { throw desktopProfileStorageError() }
    if checkAncestors {
        var ancestor = directory.deletingLastPathComponent()
        while ancestor.path != "/" {
            try validateDesktopProfileDirectory(ancestor, privateDirectory: false, checkAncestors: false)
            ancestor.deleteLastPathComponent()
        }
    }
    var info = stat()
    guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw desktopProfileStorageError() }
    if privateDirectory {
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw desktopProfileStorageError() }
    } else {
        // Root-owned system ancestors are allowed; symlinks and writable foreign paths are not.
        guard info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw desktopProfileStorageError() }
    }
}

private func validateDesktopProfiles(_ profiles: [ClaudeDesktopProfile]) throws {
    guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count,
          profiles.allSatisfy({ profile in
              let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
              return !name.isEmpty && name == profile.name && name.count <= 80
                  && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
          }) else { throw AgentSwapError.storage("Claude 데스크톱 프로필 이름이나 목록 형식을 확인해 주세요.") }
}

@MainActor @Observable
public final class ClaudeDesktopProfileModel {
    /// Recheck the installed launch path before extending this compatibility boundary.
    public static let supportedDesktopVersion = "3.1623.0"
    public private(set) var profiles: [ClaudeDesktopProfile] = []
    public private(set) var isBusy = false
    public var message: String?
    /// Informational launch receipt; this does not identify the signed-in account.
    public private(set) var lastOpenedProfileID: UUID?
    @ObservationIgnored private let store: any ClaudeDesktopProfileStoring
    @ObservationIgnored private let processes: any ClaudeDesktopConversationProcessControlling
    @ObservationIgnored private let launcher: any ClaudeDesktopProfileLaunching
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var operations = AccountOperationQueue()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(store: any ClaudeDesktopProfileStoring = FileClaudeDesktopProfileStore(),
                processes: any ClaudeDesktopConversationProcessControlling = SystemClaudeDesktopConversationProcessController(),
                launcher: any ClaudeDesktopProfileLaunching = SystemClaudeDesktopProfileLauncher(), timeout: TimeInterval = 15) {
        self.store = store; self.processes = processes; self.launcher = launcher; self.timeout = timeout
    }
    public static func live() -> ClaudeDesktopProfileModel { .init() }
    public static func preview() -> ClaudeDesktopProfileModel {
        let profiles = [ClaudeDesktopProfile(name: "개인용"), ClaudeDesktopProfile(name: "업무용")]
        let model = ClaudeDesktopProfileModel(store: PreviewDesktopProfileStore(profiles: profiles),
                                              processes: PreviewDesktopProfileProcesses(), launcher: PreviewDesktopProfileLauncher())
        model.profiles = profiles; model.loaded = true
        return model
    }
    func connectOperationQueue(_ queue: AccountOperationQueue) { operations = queue }
    public func load() async {
        await perform {
            let profiles = try await self.store.load(); try validateDesktopProfiles(profiles)
            self.profiles = profiles
            self.loaded = true
        }
    }
    /// Creation persists only a name and UUID. Opening, and then native login, are explicit actions.
    public func addProfile(name: String) async {
        await perform {
            try await self.ensureLoaded()
            let profile = ClaudeDesktopProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            let updated = self.profiles + [profile]; try validateDesktopProfiles(updated)
            try await self.store.save(updated)
            self.profiles = updated
            self.message = "프로필을 만들었습니다. 전환 및 재실행을 누른 뒤 Claude 데스크톱에서 로그인해 주세요."
        }
    }
    public func openProfile(_ id: UUID) async { await open(profileID: id) }
    public func openDefault() async { await open(profileID: nil) }
    public func beginTermination() { terminating = true }
    public func prepareForTermination() async {
        beginTermination()
        if isBusy { await withCheckedContinuation { waiters.append($0) } }
    }
    public func resumeAfterTerminationFailure() { terminating = false }
    private func ensureLoaded() async throws {
        if !loaded {
            let profiles = try await store.load(); try validateDesktopProfiles(profiles)
            self.profiles = profiles; loaded = true
        }
    }
    private func checkCanContinue() throws {
        try Task.checkCancellation()
        guard !terminating else { throw AgentSwapError.cancelled }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy, !terminating else { return }
        isBusy = true
        let queue = operations
        await queue.acquire(.claude)
        do {
            guard !terminating else { throw AgentSwapError.cancelled }
            try Task.checkCancellation()
            try await operation()
        } catch { message = error.localizedDescription }
        await queue.release(.claude)
        isBusy = false
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    private func open(profileID: UUID?) async {
        await perform {
            var directory: URL?
            if let profileID {
                try await self.ensureLoaded()
                guard self.profiles.contains(where: { $0.id == profileID }) else { throw AgentSwapError.storage("선택한 Claude 데스크톱 프로필이 없습니다.") }
                directory = try await self.store.prepareDirectory(profileID: profileID)
            }
            guard let installation = await self.processes.installation(at: nil) else {
                throw AgentSwapError.unsupported("Claude 데스크톱 앱을 찾지 못했습니다. 공식 macOS 앱을 설치해 주세요.")
            }
            try self.checkCanContinue()
            guard profileID == nil || installation.version == Self.supportedDesktopVersion else {
                throw AgentSwapError.unsupported("설치된 Claude 데스크톱 \(installation.version)의 프로필 실행 형식을 아직 확인하지 못했습니다. 기본 데스크톱 열기는 사용할 수 있습니다.")
            }
            let initial = await self.processes.scan(applicationURL: installation.url)
            try self.checkCanContinue()
            guard initial.reliable else { throw AgentSwapError.storage("Claude 실행 상태를 확인하지 못해 프로필 전환을 보류했습니다.") }
            var tracked = initial.desktop.union(initial.related)
            if !initial.desktop.isEmpty {
                try self.checkCanContinue()
                guard await self.processes.requestNormalTermination() else {
                    throw AgentSwapError.storage("Claude가 정상 종료를 거부했습니다. 작업을 저장하고 다시 전환해 주세요.")
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(self.timeout))
            while true {
                try self.checkCanContinue()
                let current = await self.processes.scan(applicationURL: installation.url)
                try self.checkCanContinue()
                guard current.reliable else { throw AgentSwapError.storage("Claude 종료 상태를 확인하지 못해 프로필 전환을 보류했습니다.") }
                tracked.formUnion(current.desktop); tracked.formUnion(current.related)
                if current.desktop.isEmpty, current.related.isEmpty, tracked.isDisjoint(with: current.live) { break }
                guard ContinuousClock.now < deadline else { throw AgentSwapError.storage("Claude 관련 프로세스가 남아 있습니다. 정상 종료를 확인한 뒤 다시 전환해 주세요.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            // Recheck both the data path and process generations after every preparation await.
            if let profileID { directory = try await self.store.prepareDirectory(profileID: profileID) }
            let final = await self.processes.scan(applicationURL: installation.url)
            guard final.reliable, final.desktop.isEmpty, final.related.isEmpty, tracked.isDisjoint(with: final.live) else {
                throw AgentSwapError.storage("Claude가 다시 실행되어 프로필 전환을 보류했습니다.")
            }
            try self.checkCanContinue()
            try await self.launcher.launch(applicationURL: installation.url, configuration: .init(profileDirectory: directory))
            self.lastOpenedProfileID = profileID
            self.message = profileID == nil ? "기본 Claude 데스크톱을 열었습니다." : "Claude 데스크톱 프로필을 열었습니다. 처음 사용하는 프로필은 데스크톱에서 로그인해 주세요."
        }
    }
}

private actor PreviewDesktopProfileStore: ClaudeDesktopProfileStoring {
    private var profiles: [ClaudeDesktopProfile]
    init(profiles: [ClaudeDesktopProfile]) { self.profiles = profiles }
    func load() -> [ClaudeDesktopProfile] { profiles }
    func save(_ profiles: [ClaudeDesktopProfile]) { self.profiles = profiles }
    func prepareDirectory(profileID: UUID) -> URL { URL(fileURLWithPath: "/AgentSwapDemo/ClaudeDesktopProfiles/\(profileID.uuidString)", isDirectory: true) }
}
private struct PreviewDesktopProfileProcesses: ClaudeDesktopConversationProcessControlling {
    func installation(at applicationURL: URL?) -> ClaudeDesktopConversationInstallation? { .init(url: URL(fileURLWithPath: "/AgentSwapDemo/Claude.app"), version: "3.1623.0") }
    func scan(applicationURL: URL) -> ClaudeDesktopConversationProcessSnapshot { .init() }
    func requestNormalTermination() -> Bool { true }
    func relaunch(at applicationURL: URL) {}
}
private struct PreviewDesktopProfileLauncher: ClaudeDesktopProfileLaunching {
    func launch(applicationURL: URL, configuration: ClaudeDesktopProfileLaunchConfiguration) {}
}
