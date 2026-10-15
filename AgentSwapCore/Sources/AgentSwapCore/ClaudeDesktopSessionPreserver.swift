import Foundation
import Darwin
import CryptoKit
import CoreFoundation

public enum ClaudeDesktopSessionPreparation: Sendable, Equatable {
    case notNeeded
    case pendingRelaunch(String)
    case prepared(transactionID: UUID, count: Int)
}

public protocol ClaudeDesktopSessionPreserving: Sendable {
    func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation
    func finish(_ preparation: ClaudeDesktopSessionPreparation, applied: Bool) async throws -> String?
    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws
}

public extension ClaudeDesktopSessionPreserving {
    func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {
        throw AgentSwapError.unsupported("대화 보존 없이 전환하는 안전 조건을 확인하지 못했습니다.")
    }
}

/// This error is offered only from the fresh, read-only planning stage. Recovery, filesystem
/// safety and any failure after Desktop termination or publication remain fatal errors.
public struct ClaudeDesktopSessionPreservationUnavailable: Error, Sendable, LocalizedError, Equatable {
    public enum Reason: Sendable, Equatable {
        case oversizedRecord, invalidRecordJSON, unsupportedRecordFields, invalidSessionIdentity
        case missingCLIIdentity, invalidWorkingDirectory, invalidTimestamps, unsupportedRecordMetadata
        case unsupportedPermissions, activeExecutionAssociation, unconfirmedImport
        case unsupportedSpawnSettings, unsupportedPromptSettings, unsupportedToolSettings
        case missingSharedTranscript, unsupportedDesktopVersion
    }
    public let reason: Reason
    public init(reason: Reason) { self.reason = reason }
    public var errorDescription: String? {
        switch reason {
        case .oversizedRecord: "로컬 Code 대화 목록이 지원하는 크기를 초과해 자동 보존을 사용할 수 없습니다."
        case .invalidRecordJSON: "로컬 Code 대화 목록의 JSON 형식을 확인하지 못해 자동 보존을 사용할 수 없습니다."
        case .unsupportedRecordFields: "지원하지 않는 로컬 Code 대화 필드가 있어 자동 보존을 사용할 수 없습니다."
        case .invalidSessionIdentity: "로컬 Code 대화 ID와 파일 연결을 확인하지 못해 자동 보존을 사용할 수 없습니다."
        case .missingCLIIdentity: "로컬 Code 대화의 CLI 기록 ID를 확인하지 못해 자동 보존을 사용할 수 없습니다."
        case .invalidWorkingDirectory: "로컬 Code 대화의 작업 폴더 형식을 확인하지 못해 자동 보존을 사용할 수 없습니다."
        case .invalidTimestamps: "로컬 Code 대화의 생성·활동 시각 형식을 확인하지 못해 자동 보존을 사용할 수 없습니다."
        case .unsupportedRecordMetadata: "로컬 Code 대화 메타데이터의 형식을 지원하지 않아 자동 보존을 사용할 수 없습니다."
        case .unsupportedPermissions: "로컬 Code 대화의 승인 설정 형식을 지원하지 않아 자동 보존을 사용할 수 없습니다."
        case .activeExecutionAssociation: "로컬 Code 대화에 중단된 실행 또는 원격 제어 연결이 남아 자동 보존을 사용할 수 없습니다."
        case .unconfirmedImport: "로컬 기록으로 확인되지 않은 가져오기 대화라 자동 보존을 사용할 수 없습니다."
        case .unsupportedSpawnSettings: "로컬 Code 대화의 시작 설정 형식을 지원하지 않아 자동 보존을 사용할 수 없습니다."
        case .unsupportedPromptSettings: "로컬 Code 대화의 프롬프트 설정 형식을 지원하지 않아 자동 보존을 사용할 수 없습니다."
        case .unsupportedToolSettings: "로컬 Code 대화의 도구 설정 형식을 지원하지 않아 자동 보존을 사용할 수 없습니다."
        case .missingSharedTranscript: "로컬 Code 대화의 공유 기록을 찾지 못해 자동 보존을 사용할 수 없습니다."
        case .unsupportedDesktopVersion: "Claude 데스크톱 2.37337.1의 로컬 Code 대화 보존만 지원합니다."
        }
    }
}

private struct SessionRecordCompatibilityIssue: Error {
    let reason: ClaudeDesktopSessionPreservationUnavailable.Reason
}

private struct SessionPreservationEntry: Codable {
    var filename: String
    var sourceData: Data
    var targetData: Data
}
private struct SessionPreservationJournal: Codable {
    var version = 1
    var id: UUID
    var source: AccountIdentity
    var target: AccountIdentity
    var applicationPath: String
    var restartAfterFinish: Bool
    var committed = false
    var entries: [SessionPreservationEntry]
}
private struct SharedSessionTranscript: Equatable {
    var url: URL
    var device: dev_t
    var inode: ino_t
    var bytes: off_t
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
}

/// Prefills an account's Desktop Code index from normal local records, retaining the source and
/// shared transcript identities. This does not sign Claude Desktop in or migrate Remote Control.
public actor ClaudeDesktopSessionPreserver: ClaudeDesktopSessionPreserving {
    public static let supportedVersion = "2.37337.1"
    private let home: URL
    private let applicationURL: URL?
    private let files: any AuthFileAccess
    private let injectedFiles: Bool
    private let processes: any ClaudeDesktopConversationProcessControlling
    private let timeout: TimeInterval
    private var operating = false
    private var recordsRoot: URL { home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true) }
    private var stateRoot: URL { home.appendingPathComponent("Library/Application Support/AgentSwap/claude-session-preservation", isDirectory: true) }
    private var journalURL: URL { stateRoot.appendingPathComponent("pending.json") }
    public init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser, applicationURL: URL? = nil,
                files: (any AuthFileAccess)? = nil,
                processController: any ClaudeDesktopConversationProcessControlling = SystemClaudeDesktopConversationProcessController(),
                terminationTimeout: TimeInterval = 15) {
        home = homeURL.standardizedFileURL; self.applicationURL = applicationURL
        self.files = files ?? AtomicAuthFileAccess(); injectedFiles = files != nil
        processes = processController; timeout = max(0, terminationTimeout)
    }
    public func prepareForSwitch(source: AccountRecord?, target: AccountRecord, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation {
        guard !operating else { throw failure("다른 Claude 대화 보존 작업이 진행 중입니다.") }
        operating = true; defer { operating = false }
        try validateIdentity(target.identity)
        if let source { try validateIdentity(source.identity) }
        if let recovery = try await recoverPending(actual: source?.identity, relaunch: relaunch) { return recovery }
        guard let source, source.identity != target.identity else { return .notNeeded }
        var plan: (entries: [SessionPreservationEntry], cliIDs: Set<String>, transcripts: [SharedSessionTranscript])
        do { plan = try inventory(source: source.identity, target: target.identity) }
        catch let issue as SessionRecordCompatibilityIssue {
            throw ClaudeDesktopSessionPreservationUnavailable(reason: issue.reason)
        }
        guard !plan.entries.isEmpty else { return .notNeeded }
        guard let installation = await processes.installation(at: applicationURL), installation.version == Self.supportedVersion else {
            throw ClaudeDesktopSessionPreservationUnavailable(reason: .unsupportedDesktopVersion)
        }
        let initial = await processes.scan(applicationURL: installation.url)
        guard initial.reliable else { throw failure("Claude 프로세스를 확인하지 못해 대화와 계정 전환을 보류했습니다.") }
        if try hasExternalWriter(ids: plan.cliIDs, scan: initial) {
            return .pendingRelaunch("이 대화를 사용하는 별도 CLI·IDE를 종료한 뒤 다시 전환해 주세요.")
        }
        let wasRunning = !initial.desktop.isEmpty || !initial.related.isEmpty
        if wasRunning && !relaunch { return .pendingRelaunch("Claude Code 대화를 보존하려면 Claude 데스크톱을 정상 종료해야 합니다. 전환 및 재실행을 눌러 주세요.") }
        let tracked = try await stopIfNeeded(initial: initial, applicationURL: installation.url)
        var preparedJournal: SessionPreservationJournal?
        do {
            plan = try inventory(source: source.identity, target: target.identity)
            guard !plan.entries.isEmpty else {
                if wasRunning { try await processes.relaunch(at: installation.url) }
                return .notNeeded
            }
            try await verifyStopped(applicationURL: installation.url, tracked: tracked)
            let journal = SessionPreservationJournal(id: UUID(), source: source.identity, target: target.identity,
                applicationPath: installation.url.path, restartAfterFinish: wasRunning, entries: plan.entries)
            preparedJournal = journal
            let journalData = try JSONEncoder().encode(journal)
            guard journalData.count <= 8 * 1_024 * 1_024 else { throw failure("대화 보존 기록이 안전한 크기 한도를 넘었습니다. 원본을 변경하지 않았습니다.") }
            try directory(stateRoot, create: true)
            try files.write(journalData, to: journalURL)
            guard try read(journalURL, maximum: 8 * 1_024 * 1_024) == journalData else { throw failure("대화 보존 기록을 확인하지 못했습니다.") }
            try directory(bucket(target.identity), create: true)
            for entry in plan.entries {
                try Task.checkCancellation()
                let sourceURL = bucket(source.identity).appendingPathComponent(entry.filename)
                guard try read(sourceURL) == entry.sourceData else { throw failure("원래 대화 목록이 변경되어 전환을 보류했습니다.") }
                try publish(entry.targetData, to: bucket(target.identity).appendingPathComponent(entry.filename))
            }
            guard try plan.transcripts.allSatisfy({ try fingerprint($0.url) == $0 }) else { throw failure("공유 대화 기록이 변경되어 전환을 보류했습니다.") }
            try await verifyStopped(applicationURL: installation.url, tracked: tracked)
            return .prepared(transactionID: journal.id, count: journal.entries.count)
        } catch {
            var recovered = true
            if let journal = preparedJournal {
                do {
                    try await verifyStopped(applicationURL: installation.url, tracked: tracked)
                    if let persisted = try pending() {
                        guard persisted.id == journal.id else { throw failure("대화 보존 기록이 변경되었습니다.") }
                        try resolve(persisted, applied: false)
                    }
                } catch { recovered = false }
            }
            if wasRunning { try? await processes.relaunch(at: installation.url) }
            if !recovered { throw failure("대화 보존이 중단되어 복구 기록을 남겼습니다. 계정 전환을 진행하지 않았습니다.") }
            if let issue = error as? SessionRecordCompatibilityIssue { throw fatalRecordIssue(issue) }
            throw error
        }
    }
    public func verifyCanSwitchWithoutPreservingSessions(source: AccountRecord?, target: AccountRecord) async throws {
        try Task.checkCancellation()
        guard !operating else { throw failure("다른 Claude 대화 보존 작업이 진행 중입니다.") }
        guard let source else { throw failure("현재 Claude 계정을 확인한 뒤 다시 전환해 주세요.") }
        try validateIdentity(source.identity); try validateIdentity(target.identity)
        try directory(stateRoot, create: false)
        var journalInfo = stat()
        if lstat(journalURL.path, &journalInfo) == 0 {
            // Existence is sufficient: do not reinterpret unknown, committed or partial recovery
            // as permission to bypass it, and do not read any embedded conversation data.
            throw failure("대화 보존 복구 기록이 남아 CLI 계정만 전환할 수 없습니다. 먼저 복구를 완료해 주세요.")
        }
        guard errno == ENOENT else { throw failure("대화 보존 복구 기록의 상태를 확인하지 못했습니다.") }
        for identity in [source.identity, target.identity] {
            let url = bucket(identity)
            for name in try names(url) where name.hasPrefix("local_") && name.hasSuffix(".json") {
                var info = stat()
                let path = url.appendingPathComponent(name)
                guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid(), info.st_nlink == 1, info.st_size >= 0 else {
                    throw failure("대화 파일의 링크와 소유권을 확인하지 못해 CLI 계정만 전환할 수 없습니다.")
                }
            }
        }
        try directory(home.appendingPathComponent(".claude/projects", isDirectory: true), create: false)
        // No record contents, source transcripts, process scan/quit or files are changed here.
    }
    public func finish(_ preparation: ClaudeDesktopSessionPreparation, applied: Bool) async throws -> String? {
        guard case .prepared(let id, _) = preparation else { return nil }
        guard !operating else { throw failure("다른 Claude 대화 보존 작업이 진행 중입니다.") }
        operating = true; defer { operating = false }
        guard let journal = try pending(), journal.id == id else { throw failure("대화 보존 작업의 복구 기록이 일치하지 않습니다.") }
        let applicationPath = journal.applicationPath, restart = journal.restartAfterFinish
        if !journal.committed {
            let scan = await processes.scan(applicationURL: URL(fileURLWithPath: applicationPath))
            guard scan.reliable, scan.desktop.isEmpty, scan.related.isEmpty else { throw failure("Claude가 다시 실행되어 대화 보존 완료 또는 복원을 보류했습니다.") }
        }
        try resolve(journal, applied: applied)
        var opened = true
        if restart {
            guard let installation = await processes.installation(at: applicationURL), installation.version == Self.supportedVersion,
                  installation.url.standardizedFileURL.path == URL(fileURLWithPath: applicationPath).standardizedFileURL.path else {
                return "로컬 대화 목록을 보존했습니다. Claude 설치가 변경되어 자동 재실행을 보류했습니다."
            }
            do { try await processes.relaunch(at: installation.url) } catch { opened = false }
        }
        if !applied { return opened ? nil : "새 대상 대화 목록을 복원했습니다. Claude 데스크톱을 직접 열어 주세요." }
        return opened ? "기존 로컬 Code 대화 목록을 보존했습니다. Claude 데스크톱 로그인은 CLI 로그인과 별개입니다." : "로컬 Code 대화 목록을 보존했습니다. Claude 데스크톱을 직접 열어 주세요."
    }
    private func recoverPending(actual: AccountIdentity?, relaunch: Bool) async throws -> ClaudeDesktopSessionPreparation? {
        guard let journal = try pending() else { return nil }
        guard let actual else { throw failure("중단된 대화 보존의 현재 계정을 확인해야 합니다.") }
        if journal.committed { try resolve(journal, applied: true) }
        else if actual == journal.target { try resolve(journal, applied: true) }
        else if actual == journal.source {
            let url = URL(fileURLWithPath: journal.applicationPath)
            let scan = await processes.scan(applicationURL: url)
            guard scan.reliable else { throw failure("중단된 대화 보존의 프로세스 상태를 확인하지 못했습니다.") }
            let wasRunning = !scan.desktop.isEmpty || !scan.related.isEmpty
            if wasRunning {
                guard relaunch else { return .pendingRelaunch("중단된 대화 보존을 복원하려면 Claude 데스크톱을 정상 종료해야 합니다.") }
                _ = try await stopIfNeeded(initial: scan, applicationURL: url)
            }
            do { try resolve(journal, applied: false) }
            catch {
                if wasRunning { try? await processes.relaunch(at: url) }
                throw error
            }
            if wasRunning { try await processes.relaunch(at: url) }
        }
        else { throw failure("중단된 대화 보존 이후 다른 계정이 활성화되어 복구를 보류했습니다.") }
        return nil
    }
    private func pending() throws -> SessionPreservationJournal? {
        guard let data = try read(journalURL, maximum: 8 * 1_024 * 1_024) else { return nil }
        let journal: SessionPreservationJournal
        do { journal = try JSONDecoder().decode(SessionPreservationJournal.self, from: data) }
        catch { throw failure("알 수 없는 대화 보존 기록을 발견해 변경을 중단했습니다.") }
        try validateIdentity(journal.source); try validateIdentity(journal.target)
        guard journal.version == 1, journal.source != journal.target, !journal.entries.isEmpty,
              Set(journal.entries.map(\.filename)).count == journal.entries.count else { throw failure("대화 보존 기록의 형식을 지원하지 않습니다.") }
        for entry in journal.entries {
            do {
                _ = try record(entry.sourceData, filename: entry.filename)
                _ = try record(entry.targetData, filename: entry.filename)
            } catch let issue as SessionRecordCompatibilityIssue { throw fatalRecordIssue(issue) }
        }
        return journal
    }
    private func resolve(_ journal: SessionPreservationJournal, applied: Bool) throws {
        if journal.committed {
            try files.delete(journalURL)
            guard try read(journalURL, maximum: 8 * 1_024 * 1_024) == nil else { throw failure("완료된 대화 보존 기록의 정리를 확인하지 못했습니다.") }
            return // A proven commit never rolls back later legitimate destination edits or deletion.
        }
        for entry in journal.entries {
            let current = try read(bucket(journal.target).appendingPathComponent(entry.filename))
            guard current == nil || current == entry.targetData else { throw failure("준비한 대상 대화가 변경되어 복원을 보류했습니다.") }
            if applied && current != entry.targetData { throw failure("계정은 전환됐지만 준비한 대화 목록이 없어 복구를 보류했습니다.") }
        }
        if applied {
            var committed = journal; committed.committed = true
            try files.write(JSONEncoder().encode(committed), to: journalURL)
        } else {
            for entry in journal.entries.reversed() {
                let url = bucket(journal.target).appendingPathComponent(entry.filename)
                if try read(url) == entry.targetData { try files.delete(url) }
                guard try read(url) == nil else { throw failure("새 대상 대화 목록의 정리를 확인하지 못했습니다.") }
            }
        }
        try files.delete(journalURL)
        guard try read(journalURL, maximum: 8 * 1_024 * 1_024) == nil else { throw failure("대화 보존 기록의 정리를 확인하지 못했습니다.") }
    }
    private func inventory(source: AccountIdentity, target: AccountIdentity) throws -> (entries: [SessionPreservationEntry], cliIDs: Set<String>, transcripts: [SharedSessionTranscript]) {
        let sourceBucket = bucket(source), targetBucket = bucket(target)
        let sourceFiles = try names(sourceBucket), targetFiles = try names(targetBucket)
        let deleted = try tombstones(sourceFiles + targetFiles)
        var targets: [String: (String, String)] = [:]
        for name in targetFiles where name.hasPrefix("local_") && name.hasSuffix(".json") {
            guard let data = try read(targetBucket.appendingPathComponent(name), reportOversizedRecord: true) else { throw failure("대상 대화 목록이 변경되었습니다.") }
            let object = try record(data, filename: name)
            targets[name] = (object["sessionId"] as! String, object["cliSessionId"] as! String)
        }
        var entries: [SessionPreservationEntry] = [], ids = Set<String>(), transcripts: [SharedSessionTranscript] = []
        for name in sourceFiles.sorted() where name.hasPrefix("local_") && name.hasSuffix(".json") {
            guard let data = try read(sourceBucket.appendingPathComponent(name), reportOversizedRecord: true) else { throw failure("원래 대화 목록이 변경되었습니다.") }
            var object = try record(data, filename: name)
            let cardID = object["sessionId"] as! String, cliID = object["cliSessionId"] as! String
            if deleted.contains(String(cardID.dropFirst(6)).lowercased()) || deleted.contains(cliID.lowercased()) { continue }
            if let present = targets[name] {
                guard present.0 == cardID, present.1 == cliID else { throw failure("대상 계정에 같은 이름의 다른 대화가 있어 보존을 중단했습니다.") }
                continue // Preserve user title/archive edits and timestamps in an existing destination.
            }
            guard !targets.values.contains(where: { $0.0 == cardID || $0.1 == cliID }) else { throw failure("대상 대화 ID가 충돌해 보존을 중단했습니다.") }
            guard let transcript = try sharedTranscript(cliID: cliID, record: object) else { throw incompatible(.missingSharedTranscript) }
            object["bridgeSessionIds"] = []
            for key in Self.detachedKeys { object.removeValue(forKey: key) }
            object["permissionMode"] = "default"
            object.removeValue(forKey: "alwaysAllowedReasons"); object.removeValue(forKey: "sessionPermissionUpdates")
            object.removeValue(forKey: "bypassChosenInApp"); object.removeValue(forKey: "autoChosenInApp")
            object.removeValue(forKey: "lastSpawnRootDetected")
            if object["chromePermissionMode"] != nil { object["chromePermissionMode"] = "ask" }
            object.removeValue(forKey: "chromeAllowedDomains")
            entries.append(.init(filename: name, sourceData: data, targetData: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
            ids.insert(cliID); transcripts.append(transcript)
        }
        let available = Set(targets.values.map { $0.0 }).union(entries.compactMap { try? record($0.targetData, filename: $0.filename)["sessionId"] as? String })
        for entry in entries {
            let object = try record(entry.targetData, filename: entry.filename)
            if let parent = object["forkedFromSessionId"] as? String, !available.contains(parent) { throw failure("원래 대화의 부모 기록이 없어 보존을 중단했습니다.") }
        }
        return (entries, ids, transcripts)
    }
    private static let detachedKeys: Set<String> = ["cloudSessionId", "outboundCCRRemoteId", "remoteControlSpawn", "remoteControlDescendant", "remoteControlAutoEligible", "remoteControlUserEnabled", "remoteControlLiveAtUpdateQuit", "remoteControlUserToggled", "remoteControlUserRequested", "remoteControlConnecting", "remoteControlAvailable", "remoteControlStarted", "startedViaRemoteControl", "remoteControlEnabled", "remoteControlAutoEnabled", "remoteControlAutoSource", "bridgeSessionId", "bridgeSessionUrl", "bridgeEpoch", "emailAddress", "envScopeId", "startedFromEnvironmentId"]
    private static let normalKeys: Set<String> = ["sessionId", "cliSessionId", "cwd", "originCwd", "title", "titleSource", "createdAt", "lastActivityAt", "lastFocusedAt", "indexedAt", "isArchived", "isStarred", "model", "effort", "branch", "sourceBranch", "worktreePath", "worktreeName", "worktreeLazy", "gitAnchors", "gitAnchorsLookupOnly", "gitAnchorsFolderRealpath", "prs", "completedTurns", "permissionMode", "alwaysAllowedReasons", "sessionPermissionUpdates", "forkedFromSessionId", "forkedAtMessageUuid", "rewindEdges", "transcriptModelStates", "transcriptCuts", "contextWindow", "bridgeSessionIds", "cliBinaryPin", "importedFrom", "resumeConfirmed", "interruptedAwaitingPerson", "steeredByRemoteClient", "spawnSeed", "lastSpawnRootDetected", "bypassChosenInApp", "autoChosenInApp", "chromePermissionMode", "chromeAllowedDomains", "promptAppendSnapshot", "toolSurfaceSnapshot", "previousTitles", "lastAssistantUuid", "titleTurn", "titleCheck", "titleSuggestionsOff"]
    private func record(_ data: Data, filename: String) throws -> [String: Any] {
        guard data.count <= 1_024 * 1_024 else { throw incompatible(.oversizedRecord) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw incompatible(.invalidRecordJSON) }
        guard Set(object.keys).isSubset(of: Self.normalKeys.union(Self.detachedKeys)) else { throw incompatible(.unsupportedRecordFields) }
        guard let id = object["sessionId"] as? String, id.hasPrefix("local_"), UUID(uuidString: String(id.dropFirst(6))) != nil,
              filename == id + ".json" else { throw incompatible(.invalidSessionIdentity) }
        guard let cliID = object["cliSessionId"] as? String, UUID(uuidString: cliID) != nil else { throw incompatible(.missingCLIIdentity) }
        guard let cwd = object["cwd"] as? String, cwd.hasPrefix("/"),
              !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw incompatible(.invalidWorkingDirectory) }
        guard validTimestamp(object["createdAt"]), validTimestamp(object["lastActivityAt"]) else { throw incompatible(.invalidTimestamps) }
        if let title = object["title"], !(title is String) { throw incompatible(.unsupportedRecordMetadata) }
        // Claude 2.37337.1 serializer CA / readers xD, Kk, gO and hO. These are title/history
        // metadata; they carry no permission grants, process ownership or execution resume state.
        if let titles = object["previousTitles"] {
            guard let values = titles as? [String], values.count <= 10,
                  values.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 2_000 }) else { throw incompatible(.unsupportedRecordMetadata) }
        }
        if let value = object["lastAssistantUuid"] {
            guard value is String else { throw incompatible(.unsupportedRecordMetadata) }
        }
        if let value = object["titleTurn"], !validTimestamp(value) { throw incompatible(.unsupportedRecordMetadata) }
        if let value = object["titleCheck"] {
            guard let check = value as? [String: Any], Set(check.keys) == ["count", "lastAt", "lastTurn"],
                  check.values.allSatisfy(validTimestamp) else { throw incompatible(.unsupportedRecordMetadata) }
        }
        if let value = object["titleSuggestionsOff"], !isBoolean(value) { throw incompatible(.unsupportedRecordMetadata) }
        if let archive = object["isArchived"] {
            guard let value = archive as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw incompatible(.unsupportedRecordMetadata) }
        }
        if let permission = object["permissionMode"] {
            guard let mode = permission as? String, Self.permissionModes.contains(mode) else { throw incompatible(.unsupportedPermissions) }
        }
        if let reasons = object["alwaysAllowedReasons"], !(reasons is [String]) { throw incompatible(.unsupportedPermissions) }
        if let updates = object["sessionPermissionUpdates"] {
            guard let values = updates as? [[String: Any]], values.allSatisfy({ value in
                guard let type = value["type"] as? String else { return false }
                return ["addDirectories", "removeDirectories", "addRules", "removeRules", "replaceRules", "setMode"].contains(type)
            }) else { throw incompatible(.unsupportedPermissions) }
        }
        if let bridge = object["bridgeSessionIds"], !(bridge is [String]) { throw incompatible(.unsupportedRecordMetadata) }
        for key in ["interruptedAwaitingPerson", "steeredByRemoteClient"] {
            if let value = object[key], !(value is NSNull) { throw incompatible(.activeExecutionAssociation) }
        }
        if let value = object["resumeConfirmed"] {
            guard let confirmed = value as? NSNumber, CFGetTypeID(confirmed) == CFBooleanGetTypeID() else { throw incompatible(.unconfirmedImport) }
        }
        if let value = object["importedFrom"] {
            guard let origin = value as? String, ["local-1p-code", "terminal-cli"].contains(origin),
                  (object["resumeConfirmed"] as? NSNumber)?.boolValue == true else {
                throw incompatible(.unconfirmedImport)
            }
        }
        for key in ["lastSpawnRootDetected", "bypassChosenInApp"] {
            if let value = object[key], !isBoolean(value) { throw incompatible(.unsupportedRecordMetadata) }
        }
        if let value = object["autoChosenInApp"], !isBoolean(value), (value as? String) != "adopted" {
            throw incompatible(.unsupportedRecordMetadata)
        }
        if let value = object["chromePermissionMode"] {
            guard let mode = value as? String, ["ask", "skip_all_permission_checks", "follow_a_plan"].contains(mode) else { throw incompatible(.unsupportedPermissions) }
        }
        if let domains = object["chromeAllowedDomains"], !(domains is [String]) { throw incompatible(.unsupportedPermissions) }
        if let value = object["spawnSeed"] {
            guard let seed = value as? [String: Any], Set(seed.keys).isSubset(of: ["systemPrompt", "systemPromptAppend", "worktreeHookBased"]),
                  seed["systemPrompt"] == nil || seed["systemPrompt"] is String,
                  seed["systemPromptAppend"] == nil || seed["systemPromptAppend"] is String,
                  seed["worktreeHookBased"].map(isBoolean) ?? true else {
                throw incompatible(.unsupportedSpawnSettings)
            }
        }
        if let value = object["promptAppendSnapshot"] {
            guard let snapshot = value as? [String: Any], Set(snapshot.keys) == ["append", "cliVersion", "settingsKey", "toolSets"],
                  let append = snapshot["append"] as? String, append.utf8.count <= 524_288,
                  snapshot["cliVersion"] is String || snapshot["cliVersion"] is NSNull,
                  snapshot["settingsKey"] is String, let tools = snapshot["toolSets"] as? [String: Any],
                  Set(tools.keys).isSubset(of: ["turnBox", "sideSessions"]), tools.values.allSatisfy(isBoolean) else {
                throw incompatible(.unsupportedPromptSettings)
            }
        }
        if let value = object["toolSurfaceSnapshot"] {
            guard let snapshot = value as? [String: Any],
                  Set(snapshot.keys).isSubset(of: ["familyHashes", "deferredHash", "disallowedToolsKey", "appVersion", "cliVersion", "appRunId", "recordedAt"]),
                  let families = snapshot["familyHashes"] as? [String: Any],
                  Set(families.keys) == ["builtin", "internal_inline", "internal_deferred", "connector", "extension", "plugin_or_user"],
                  families.values.allSatisfy(isSurfaceHash), let deferred = snapshot["deferredHash"], isSurfaceHash(deferred),
                  snapshot["disallowedToolsKey"].map(isSurfaceHash) ?? true,
                  validShortString(snapshot["appVersion"]), validShortString(snapshot["appRunId"]),
                  snapshot["cliVersion"].map(validShortString) ?? true,
                  let time = snapshot["recordedAt"] as? NSNumber, !isBoolean(time),
                  time.doubleValue > 0, time.doubleValue.rounded() == time.doubleValue,
                  time.doubleValue <= 9_007_199_254_740_991,
                  time.doubleValue <= Date.now.timeIntervalSince1970 * 1_000 + 86_400_000 else {
                throw incompatible(.unsupportedToolSettings)
            }
        }
        return object
    }
    private func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    private func isSurfaceHash(_ value: Any) -> Bool {
        guard let string = value as? String else { return false }
        return string.utf8.count == 16 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func validShortString(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return string.utf16.count <= 64
    }
    private static let permissionModes: Set<String> = ["default", "acceptEdits", "plan", "bypassPermissions", "auto", "dontAsk"]
    private func validTimestamp(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }
    private func tombstones(_ names: [String]) throws -> Set<String> {
        var deleted = Set<String>()
        for name in names where name.hasPrefix("deleted_") {
            var id = String(name.dropFirst(8))
            if id.hasSuffix(".json") { id = String(id.dropLast(5)) }
            if id.hasPrefix("local_") { id = String(id.dropFirst(6)) }
            guard UUID(uuidString: id) != nil else { throw failure("알 수 없는 대화 삭제 표시를 발견해 보존을 중단했습니다.") }
            deleted.insert(id.lowercased())
        }
        return deleted
    }
    private func sharedTranscript(cliID: String, record: [String: Any]) throws -> SharedSessionTranscript? {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try directory(root, create: false)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        // Desktop 2.37337.1 resolves normal main transcripts directly inside one project bucket.
        // It probes cwd/worktree/origin hints, then immediate children, excluding ssh-* buckets.
        var candidates: [String] = []
        for key in ["cwd", "worktreePath", "originCwd"] {
            if let path = record[key] as? String, let name = normalProjectBucketName(path), !candidates.contains(name) {
                candidates.append(name)
            }
        }
        for name in try names(root).sorted() where !candidates.contains(name) { candidates.append(name) }
        var match: SharedSessionTranscript?
        for name in candidates where !name.hasPrefix("ssh-") {
            let project = root.appendingPathComponent(name, isDirectory: true)
            var projectInfo = stat()
            if lstat(project.path, &projectInfo) != 0 {
                guard errno == ENOENT else { throw failure("공유 대화 저장소가 변경되었습니다.") }
                continue
            }
            guard (projectInfo.st_mode & S_IFMT) == S_IFDIR else { continue }
            let url = project.appendingPathComponent(cliID + ".jsonl")
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else { throw failure("공유 대화 저장소가 변경되었습니다.") }
                continue
            }
            guard match == nil else { throw failure("같은 ID의 공유 대화가 여러 곳에 있어 보존을 중단했습니다.") }
            match = try fingerprint(url)
        }
        return match
    }
    private func normalProjectBucketName(_ path: String) -> String? {
        let units = path.precomposedStringWithCanonicalMapping.utf16
        guard !units.isEmpty, units.count <= 200 else { return nil }
        let slug = units.map { unit -> UInt16 in
            (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) ? unit : 45
        }
        return String(decoding: slug, as: UTF16.self)
    }
    private func fingerprint(_ url: URL) throws -> SharedSessionTranscript {
        try directory(url.deletingLastPathComponent(), create: false)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else { throw failure("공유 대화 파일을 안전하게 확인하지 못했습니다.") }
        return .init(url: url, device: info.st_dev, inode: info.st_ino, bytes: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
    private func hasExternalWriter(ids: Set<String>, scan: ClaudeDesktopConversationProcessSnapshot) throws -> Bool {
        let root = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        for name in try names(root) where name.hasSuffix(".json") {
            guard let pid = Int32(String(name.dropLast(5))), let live = scan.live.first(where: { $0.pid == pid }) else { continue }
            guard let data = try read(root.appendingPathComponent(name)), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String else { throw failure("실행 중인 CLI의 대화 소유권을 확인하지 못했습니다.") }
            if ids.contains(id), !scan.related.contains(live) { return true }
        }
        return false
    }
    private func stopIfNeeded(initial: ClaudeDesktopConversationProcessSnapshot, applicationURL: URL) async throws -> Set<ClaudeDesktopConversationProcessIdentity> {
        var tracked = initial.desktop.union(initial.related)
        if !initial.desktop.isEmpty, !(await processes.requestNormalTermination()) { throw failure("Claude가 정상 종료를 거부해 대화와 계정 전환을 보류했습니다.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            try Task.checkCancellation()
            let current = await processes.scan(applicationURL: applicationURL)
            guard current.reliable else { throw failure("Claude 종료 확인에 실패했습니다.") }
            tracked.formUnion(current.related); tracked.formUnion(current.desktop)
            if current.desktop.isEmpty, current.related.isEmpty, tracked.isDisjoint(with: current.live) { return tracked }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
        } while true
        throw failure("Claude의 관련 프로세스가 남아 계정 전환을 보류했습니다.")
    }
    private func verifyStopped(applicationURL: URL, tracked: Set<ClaudeDesktopConversationProcessIdentity>) async throws {
        let current = await processes.scan(applicationURL: applicationURL)
        guard current.reliable, current.desktop.isEmpty, current.related.isEmpty, tracked.isDisjoint(with: current.live) else { throw failure("Claude가 다시 실행되어 보존을 중단했습니다.") }
    }
    private func validateIdentity(_ identity: AccountIdentity) throws {
        guard identity.provider == .claude, UUID(uuidString: identity.userID) != nil, UUID(uuidString: identity.workspaceID) != nil else { throw failure("Claude 계정과 워크스페이스의 형식을 확인하지 못했습니다.") }
    }
    private func bucket(_ identity: AccountIdentity) -> URL { recordsRoot.appendingPathComponent(identity.userID, isDirectory: true).appendingPathComponent(identity.workspaceID, isDirectory: true) }
    private func names(_ url: URL) throws -> [String] {
        try directory(url, create: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
    private func directory(_ url: URL, create: Bool) throws {
        guard url.path == home.path || url.path.hasPrefix(home.path + "/") else { throw failure("대화 보존 경로를 확인하지 못했습니다.") }
        var current = home
        for part in [""] + url.path.dropFirst(home.path.count).split(separator: "/").map(String.init) {
            if !part.isEmpty { current.appendPathComponent(part, isDirectory: true) }
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else { throw failure("대화 폴더를 확인하지 못했습니다.") }
                if !create { return }
                guard mkdir(current.path, 0o700) == 0, lstat(current.path, &info) == 0 else { throw failure("대화 보존 폴더를 만들지 못했습니다.") }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw failure("대화 보존 폴더의 소유권 또는 링크가 안전하지 않습니다.") }
        }
    }
    private func read(_ url: URL, maximum: Int = 1_024 * 1_024, reportOversizedRecord: Bool = false) throws -> Data? {
        try directory(url.deletingLastPathComponent(), create: false)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw failure("대화 기록을 확인하지 못했습니다.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_size >= 0 else { throw failure("대화 파일의 링크와 소유권을 확인하지 못했습니다.") }
        if info.st_size > maximum {
            if reportOversizedRecord { throw incompatible(.oversizedRecord) }
            throw failure("대화 파일의 크기를 확인하지 못했습니다.")
        }
        guard let data = try files.read(url) else { throw failure("대화 파일을 안전하게 읽지 못했습니다.") }
        if data.count > maximum {
            if reportOversizedRecord { throw incompatible(.oversizedRecord) }
            throw failure("대화 파일의 크기를 확인하지 못했습니다.")
        }
        return data
    }
    private func publish(_ data: Data, to url: URL) throws {
        guard try read(url) == nil else { throw failure("대상 대화가 먼저 생성되어 보존을 중단했습니다.") }
        if injectedFiles { try files.write(data, to: url) }
        else {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".agentswap-session-\(UUID().uuidString).tmp")
            defer { _ = unlink(temporary.path) }
            try files.write(data, to: temporary)
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw failure("새 대화 목록을 안전하게 게시하지 못했습니다.") }
            let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw failure("게시한 대화 폴더를 확인하지 못했습니다.") }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else { throw failure("게시한 대화 목록을 디스크에 확정하지 못했습니다.") }
        }
        guard try read(url) == data else { throw failure("게시한 대화 목록을 확인하지 못했습니다.") }
    }
    private func failure(_ message: String) -> AgentSwapError { .storage(message) }
    private func incompatible(_ reason: ClaudeDesktopSessionPreservationUnavailable.Reason) -> SessionRecordCompatibilityIssue {
        .init(reason: reason)
    }
    private func fatalRecordIssue(_ issue: SessionRecordCompatibilityIssue) -> AgentSwapError {
        failure("대화 보존의 완료 또는 복구를 중단했습니다. " +
                (ClaudeDesktopSessionPreservationUnavailable(reason: issue.reason).errorDescription ?? "대화 형식을 지원하지 않습니다."))
    }
}
