import Foundation
import Darwin
import CryptoKit
import CoreFoundation

/// Produces a bounded, data-only transfer plan for Claude Desktop's local Code index.
/// It deliberately has no process, credential, or write authority.  Callers must fence the
/// returned before-images immediately before applying the mutations.
struct ClaudeDesktopCodeTransfer {
    private static let maximumRecords = 1_000
    private static let maximumRecordBytes = 1_024 * 1_024
    private static let maximumTranscriptBytes = 256 * 1_024 * 1_024
    private static let defaultMaximumPlanBytes = 8 * 1_024 * 1_024

    private let home: URL
    private let files: any AuthFileAccess
    private let maximumPlanBytes: Int

    init(home: URL, files: any AuthFileAccess = AtomicAuthFileAccess(), maximumPlanBytes: Int = defaultMaximumPlanBytes) {
        self.home = home.standardizedFileURL
        self.files = files
        self.maximumPlanBytes = max(0, maximumPlanBytes)
    }

    func plan(source: AccountIdentity, target: AccountIdentity) throws -> [AuthMutation] {
        try prepare(source: source, target: target).mutations
    }

    /// `verifyOriginals()` must run after every await between planning and publishing a mutation.
    /// The plan keeps only hashes and filesystem identities; no conversation contents leave this
    /// component or become persistent recovery data.
    func prepare(source: AccountIdentity, target: AccountIdentity) throws -> ClaudeDesktopCodeTransferPlan {
        try validate(source)
        try validate(target)
        guard source != target else { return .init(mutations: [], verify: {}) }

        let sourceBucket = bucket(for: source)
        let targetBucket = bucket(for: target)
        let initialSourceManifest = try sourceDirectoryFingerprint(sourceBucket)
        let sourceNames = try names(in: sourceBucket)
        let targetNames = try names(in: targetBucket)
        guard sourceNames.count <= Self.maximumRecords, targetNames.count <= Self.maximumRecords else {
            throw failure("로컬 Code 대화 목록이 안전한 개수 한도를 넘었습니다.")
        }

        let deleted = try tombstones(in: sourceNames).union(tombstones(in: targetNames))
        let targetRecords = try records(in: targetBucket, names: targetNames)
        var targetIDs: [String: String] = [:], targetCLIIDs: [String: String] = [:]
        for record in targetRecords.values {
            guard targetIDs.updateValue(record.filename, forKey: record.sessionID) == nil,
                  targetCLIIDs.updateValue(record.filename, forKey: record.cliSessionID) == nil else {
                throw failure("대상 계정의 로컬 Code 대화 ID가 충돌합니다.")
            }
        }

        var mutations: [AuthMutation] = []
        var planBytes = 0
        var originals: [ClaudeDesktopCodeFingerprint] = []
        var transferableSource: [LocalRecord] = []
        var sourceSessionIDs = Set<String>(), sourceCLIIDs = Set<String>()
        for name in sourceNames.sorted() where isRecordName(name) {
            let sourceURL = sourceBucket.appendingPathComponent(name)
            let sourceData = try safeRead(sourceURL, maximum: Self.maximumRecordBytes)
            let sourceRecord = try record(sourceData, filename: name)
            if deleted.contains(sourceRecord.localID) || deleted.contains(sourceRecord.cliSessionID.lowercased()) { continue }
            guard sourceSessionIDs.insert(sourceRecord.sessionID).inserted,
                  sourceCLIIDs.insert(sourceRecord.cliSessionID).inserted else {
                throw failure("원본 계정의 로컬 Code 대화 ID가 충돌합니다.")
            }
            transferableSource.append(sourceRecord)

            // A transcript is shared between the two account indexes.  It is never copied or
            // changed, but it must exist as exactly one safe, stable local file before its index
            // entry can be published.
            let transcript = try sharedTranscript(cliID: sourceRecord.cliSessionID)
            let sourceFingerprint = try fingerprint(sourceURL, kind: .sourceIndex, cliSessionID: sourceRecord.cliSessionID)
            guard sourceFingerprint.digest == Data(SHA256.hash(data: sourceData)) else {
                throw failure("대화 원본 파일이 목록을 준비하는 중 변경되었습니다.")
            }
            originals.append(sourceFingerprint)
            originals.append(transcript)

            if let present = targetRecords[name] {
                guard present.sessionID == sourceRecord.sessionID, present.cliSessionID == sourceRecord.cliSessionID else {
                    throw failure("대상 계정에 같은 파일 이름의 다른 로컬 Code 대화가 있습니다.")
                }
                guard sourceRecord.lastActivityAt > present.lastActivityAt else { continue }
                let adapted = try sourceRecord.dataPreservingTargetState(from: present)
                try append(.init(location: .file(targetBucket.appendingPathComponent(name).path), before: present.data, after: adapted),
                           to: &mutations, bytes: &planBytes)
                continue
            }
            if targetIDs[sourceRecord.sessionID] != nil || targetCLIIDs[sourceRecord.cliSessionID] != nil {
                throw failure("대상 계정의 로컬 Code 대화 ID가 다른 파일과 충돌합니다.")
            }
            try append(.init(location: .file(targetBucket.appendingPathComponent(name).path), before: nil, after: sourceRecord.dataForNewTarget()),
                       to: &mutations, bytes: &planBytes)
        }
        let available = Set(targetRecords.values.map(\.sessionID)).union(transferableSource.map(\.sessionID))
        for sourceRecord in transferableSource {
            if let parent = sourceRecord.object["forkedFromSessionId"] as? String {
                guard parent.hasPrefix("local_"), UUID(uuidString: String(parent.dropFirst("local_".count))) != nil,
                      !deleted.contains(String(parent.dropFirst("local_".count)).lowercased()),
                      available.contains("local_" + String(parent.dropFirst("local_".count)).lowercased()) else {
                    throw failure("로컬 Code 대화의 부모 기록을 확인하지 못했습니다.")
                }
            }
        }
        var originalsByPath: [String: ClaudeDesktopCodeFingerprint] = [:]
        for original in originals {
            if let current = originalsByPath[original.relativePath], current != original {
                throw failure("공유 대화 기록의 확인 결과가 일치하지 않습니다.")
            }
            originalsByPath[original.relativePath] = original
        }
        guard try sourceDirectoryFingerprint(sourceBucket) == initialSourceManifest else {
            throw failure("대화 원본 목록이 준비하는 중 변경되었습니다.")
        }
        let uniqueOriginals = ([initialSourceManifest] + originalsByPath.values).sorted { $0.relativePath < $1.relativePath }
        return .init(mutations: mutations, fingerprints: uniqueOriginals) { try self.verifyOriginals(uniqueOriginals, source: source) }
    }

    private func append(_ mutation: AuthMutation, to mutations: inout [AuthMutation], bytes: inout Int) throws {
        guard (mutation.before?.count ?? 0) <= Self.maximumRecordBytes,
              (mutation.after?.count ?? 0) <= Self.maximumRecordBytes else {
            throw failure("변환한 로컬 Code 대화 목록이 안전한 파일 크기를 넘었습니다.")
        }
        let addition = (mutation.before?.count ?? 0) + (mutation.after?.count ?? 0)
        guard addition <= maximumPlanBytes - bytes else { throw failure("대화 이전 계획이 안전한 크기 한도를 넘었습니다.") }
        bytes += addition; mutations.append(mutation)
    }

    private func validate(_ identity: AccountIdentity) throws {
        guard identity.provider == .claude,
              UUID(uuidString: identity.userID) != nil,
              UUID(uuidString: identity.workspaceID) != nil else {
            throw failure("Claude 계정과 워크스페이스의 형식을 확인하지 못했습니다.")
        }
    }

    private var recordsRoot: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    private func bucket(for identity: AccountIdentity) -> URL {
        recordsRoot.appendingPathComponent(identity.userID, isDirectory: true)
            .appendingPathComponent(identity.workspaceID, isDirectory: true)
    }

    private func names(in directory: URL) throws -> [String] {
        guard try safeDirectory(directory, allowMissing: true) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func records(in directory: URL, names: [String]) throws -> [String: LocalRecord] {
        var result: [String: LocalRecord] = [:]
        for name in names where isRecordName(name) {
            let url = directory.appendingPathComponent(name)
            result[name] = try record(try safeRead(url, maximum: Self.maximumRecordBytes), filename: name)
        }
        return result
    }

    private func tombstones(in names: [String]) throws -> Set<String> {
        var result = Set<String>()
        for name in names where name.hasPrefix("deleted_") {
            var value = String(name.dropFirst("deleted_".count))
            if value.hasSuffix(".json") { value.removeLast(5) }
            if value.hasPrefix("local_") { value.removeFirst("local_".count) }
            guard UUID(uuidString: value) != nil else {
                throw failure("로컬 Code 대화 삭제 표시의 형식을 확인하지 못했습니다.")
            }
            result.insert(value.lowercased())
        }
        return result
    }

    private func isRecordName(_ name: String) -> Bool {
        name.hasPrefix("local_") && name.hasSuffix(".json") && !name.contains("/")
    }

    private func record(_ data: Data, filename: String) throws -> LocalRecord {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String,
              sessionID.hasPrefix("local_"),
              let localUUID = UUID(uuidString: String(sessionID.dropFirst("local_".count))),
              filename == sessionID + ".json",
              let cliID = object["cliSessionId"] as? String,
              UUID(uuidString: cliID) != nil,
              let cwd = object["cwd"] as? String,
              cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let created = timestamp(object["createdAt"]),
              let activity = timestamp(object["lastActivityAt"]),
              validAnnotations(object) else {
            throw failure("로컬 Code 대화의 기본 식별자 또는 시각을 확인하지 못했습니다.")
        }
        try rejectLiveRemoteExecution(in: object)
        return .init(filename: filename, localID: localUUID.uuidString.lowercased(), sessionID: "local_" + localUUID.uuidString.lowercased(),
                     cliSessionID: cliID.lowercased(), createdAt: created, lastActivityAt: activity,
                     data: data, object: object)
    }

    private func timestamp(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private func validAnnotations(_ object: [String: Any]) -> Bool {
        if let title = object["title"], !(title is String) { return false }
        if let history = object["bridgeSessionIds"] {
            guard let ids = history as? [String], ids.allSatisfy({ !$0.isEmpty }) else { return false }
        }
        for key in ["isArchived", "isStarred"] {
            guard let value = object[key] else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        }
        return true
    }

    private func rejectLiveRemoteExecution(in object: [String: Any]) throws {
        // These are source-account execution attachments. Persisted user-enabled, available,
        // and auto-eligible flags are preferences/capabilities, not a live bridge attachment.
        let markers = ["cloudSessionId", "outboundCCRRemoteId", "remoteControlSpawn", "remoteControlDescendant",
                       "remoteControlConnecting", "remoteControlStarted", "startedViaRemoteControl",
                       "remoteControlEnabled", "remoteControlLiveAtUpdateQuit",
                       "remoteControlUserRequested", "remoteControlAutoEnabled",
                       "interruptedAwaitingPerson", "steeredByRemoteClient", "bridgeSessionId", "bridgeSessionUrl"]
        for key in markers where isActiveRemoteValue(object[key]) {
            throw failure("원격 실행에 연결된 로컬 Code 대화는 다른 계정으로 이전할 수 없습니다.")
        }
        // Disconnected bridge history is allowed, but its cloud-to-local bindings belong
        // to the account partition. Import/merge below must retain only target-owned IDs.
    }

    private func isActiveRemoteValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    private func sharedTranscript(cliID: String) throws -> ClaudeDesktopCodeFingerprint {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard try safeDirectory(root, allowMissing: true) else {
            throw failure("로컬 Code 대화의 공유 기록을 찾지 못했습니다.")
        }
        var matches: [URL] = []
        let projectNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard projectNames.count <= Self.maximumRecords else { throw failure("공유 대화 폴더가 안전한 개수 한도를 넘었습니다.") }
        for name in projectNames where !name.hasPrefix("ssh-") && !name.contains("/") {
            let project = root.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            if lstat(project.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw failure("공유 대화 폴더의 항목을 확인하지 못했습니다.")
            }
            // Finder and other tools may leave regular metadata files beside project folders.
            // They cannot contain a session transcript; do not treat them as project buckets.
            if (info.st_mode & S_IFMT) == S_IFREG { continue }
            guard try safeDirectory(project, allowMissing: true) else { continue }
            let candidate = project.appendingPathComponent(cliID + ".jsonl")
            if try safeRegularFileExists(candidate, maximum: Self.maximumTranscriptBytes) { matches.append(candidate) }
        }
        guard matches.count == 1, let transcript = matches.first else {
            throw failure("로컬 Code 대화의 공유 기록을 하나로 확인하지 못했습니다.")
        }
        return try fingerprint(transcript, kind: .sharedTranscript, cliSessionID: cliID)
    }

    private func safeDirectory(_ directory: URL, allowMissing: Bool) throws -> Bool {
        guard directory.path == home.path || directory.path.hasPrefix(home.path + "/") else {
            throw failure("로컬 Code 대화 경로가 사용자 홈 밖을 가리킵니다.")
        }
        var homeInfo = stat()
        guard lstat(home.path, &homeInfo) == 0, (homeInfo.st_mode & S_IFMT) == S_IFDIR,
              homeInfo.st_uid == geteuid(), homeInfo.st_mode & 0o022 == 0 else {
            throw failure("사용자 홈 폴더의 소유권 또는 링크가 안전하지 않습니다.")
        }
        var current = home
        let suffix = directory.path.dropFirst(home.path.count)
        for part in suffix.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT, allowMissing else { throw failure("로컬 Code 대화 폴더를 확인하지 못했습니다.") }
                return false
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), info.st_nlink >= 1,
                  info.st_mode & 0o022 == 0 else {
                throw failure("로컬 Code 대화 폴더의 소유권 또는 링크가 안전하지 않습니다.")
            }
        }
        return true
    }

    private func safeRegularFileExists(_ url: URL, maximum: Int) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("로컬 Code 대화 파일을 확인하지 못했습니다.") }
            return false
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum else {
            throw failure("로컬 Code 대화 파일의 소유권 또는 링크가 안전하지 않습니다.")
        }
        return true
    }

    private func safeRead(_ url: URL, maximum: Int) throws -> Data {
        guard try safeRegularFileExists(url, maximum: maximum) else { throw failure("로컬 Code 대화 파일이 변경되었습니다.") }
        var before = stat(); guard lstat(url.path, &before) == 0 else { throw failure("로컬 Code 대화 파일을 확인하지 못했습니다.") }
        guard let data = try files.read(url), data.count == before.st_size else { throw failure("로컬 Code 대화 파일을 안전하게 읽지 못했습니다.") }
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, sameModificationTime(before, after) else {
            throw failure("로컬 Code 대화 파일이 읽는 중 변경되었습니다.")
        }
        return data
    }

    private func transcriptDigest(_ url: URL) throws -> SHA256.Digest {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("공유 대화 기록을 안전하게 열지 못했습니다.") }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_size <= Self.maximumTranscriptBytes else {
            throw failure("공유 대화 기록의 소유권 또는 링크가 안전하지 않습니다.")
        }
        var hasher = SHA256(), total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { throw failure("공유 대화 기록을 읽지 못했습니다.") }
            total += count
            guard total <= Self.maximumTranscriptBytes else { throw failure("공유 대화 기록이 안전한 크기 한도를 넘었습니다.") }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, sameModificationTime(before, after) else {
            throw failure("공유 대화 기록이 읽는 중 변경되었습니다.")
        }
        return hasher.finalize()
    }

    func verifyOriginals(_ fingerprints: [ClaudeDesktopCodeFingerprint], source: AccountIdentity) throws {
        try validate(source)
        if fingerprints.isEmpty { return }
        guard fingerprints.count <= Self.maximumRecords * 2 + 1,
              Set(fingerprints.map(\.relativePath)).count == fingerprints.count else {
            throw failure("대화 원본 확인 기록의 형식을 지원하지 않습니다.")
        }
        let sourceRelativePath = try relativePath(of: bucket(for: source))
        guard let manifest = fingerprints.first(where: { $0.kind == .sourceDirectory }),
              manifest.relativePath == sourceRelativePath,
              fingerprints.filter({ $0.kind == .sourceDirectory }).count == 1 else {
            throw failure("대화 원본 목록 확인 기록이 현재 계정과 일치하지 않습니다.")
        }
        var indexCLIIDs = Set<String>(), transcriptCLIIDs = Set<String>()
        for expected in fingerprints {
            let url = try url(for: expected)
            let current: ClaudeDesktopCodeFingerprint
            if expected.kind == .sourceDirectory { current = try sourceDirectoryFingerprint(url) }
            else {
                let cliID = try requiredCLI(expected)
                if expected.kind == .sourceIndex {
                    guard expected.relativePath.hasPrefix(sourceRelativePath + "/"),
                          try record(safeRead(url, maximum: Self.maximumRecordBytes), filename: url.lastPathComponent).cliSessionID == cliID else {
                        throw failure("대화 원본 확인 기록이 원본 계정 또는 공유 기록과 일치하지 않습니다.")
                    }
                } else {
                    guard transcriptName(url.lastPathComponent) == cliID else { throw failure("공유 기록의 대화 식별자가 일치하지 않습니다.") }
                }
                current = try fingerprint(url, kind: expected.kind, cliSessionID: expected.cliSessionID)
            }
            guard current == expected else {
                throw failure("대화 원본 또는 공유 기록이 변경되어 이전을 중단했습니다.")
            }
            if expected.kind == .sourceIndex { indexCLIIDs.insert(try requiredCLI(expected)) }
            if expected.kind == .sharedTranscript { transcriptCLIIDs.insert(try requiredCLI(expected)) }
        }
        guard indexCLIIDs == transcriptCLIIDs else { throw failure("대화 목록과 공유 기록의 연결을 확인하지 못했습니다.") }
    }

    private func fingerprint(_ url: URL, kind: ClaudeDesktopCodeFingerprint.Kind, cliSessionID: String?) throws -> ClaudeDesktopCodeFingerprint {
        guard try safeDirectory(url.deletingLastPathComponent(), allowMissing: false) else {
            throw failure("대화 원본 폴더를 확인하지 못했습니다.")
        }
        let maximum = kind == .sourceIndex ? Self.maximumRecordBytes : Self.maximumTranscriptBytes
        guard try safeRegularFileExists(url, maximum: maximum) else { throw failure("대화 원본 파일을 확인하지 못했습니다.") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure("대화 원본 파일을 확인하지 못했습니다.") }
        let digest = try transcriptDigest(url)
        var after = stat()
        guard lstat(url.path, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_size == after.st_size, sameModificationTime(info, after) else {
            throw failure("대화 원본 파일이 확인 중 변경되었습니다.")
        }
        return .init(kind: kind, relativePath: try relativePath(of: url), cliSessionID: cliSessionID, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                     bytes: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                     modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), digest: Data(digest))
    }

    private func directoryFingerprint(_ url: URL) throws -> ClaudeDesktopCodeFingerprint {
        guard try safeDirectory(url, allowMissing: false) else { throw failure("대화 원본 목록 폴더를 확인하지 못했습니다.") }
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw failure("대화 원본 목록 폴더를 확인하지 못했습니다.") }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        guard names.count <= Self.maximumRecords else { throw failure("로컬 Code 대화 목록이 안전한 개수 한도를 넘었습니다.") }
        var manifest = Data()
        for name in names {
            let bytes = Data(name.utf8)
            guard bytes.count <= UInt16.max else { throw failure("로컬 Code 대화 파일 이름이 너무 깁니다.") }
            var length = UInt16(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { manifest.append(contentsOf: $0) }; manifest.append(bytes)
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              sameModificationTime(info, after) else { throw failure("대화 원본 목록이 확인 중 변경되었습니다.") }
        return .init(kind: .sourceDirectory, relativePath: try relativePath(of: url), cliSessionID: nil,
                     device: UInt64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size),
                     modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                     digest: Data(SHA256.hash(data: manifest)))
    }

    private func sourceDirectoryFingerprint(_ url: URL) throws -> ClaudeDesktopCodeFingerprint {
        if try safeDirectory(url, allowMissing: true) { return try directoryFingerprint(url) }
        return .init(kind: .sourceDirectory, relativePath: try relativePath(of: url), cliSessionID: nil,
                     device: 0, inode: 0, bytes: 0, modifiedSeconds: 0, modifiedNanoseconds: 0,
                     digest: Data(SHA256.hash(data: Data("absent source bucket".utf8))))
    }

    private func requiredCLI(_ fingerprint: ClaudeDesktopCodeFingerprint) throws -> String {
        guard let value = fingerprint.cliSessionID, UUID(uuidString: value) != nil else { throw failure("대화 원본 연결 기록의 형식을 지원하지 않습니다.") }
        return value.lowercased()
    }

    private func relativePath(of url: URL) throws -> String {
        guard url.path.hasPrefix(home.path + "/") else { throw failure("대화 원본 경로가 사용자 홈 밖을 가리킵니다.") }
        return String(url.path.dropFirst(home.path.count + 1))
    }

    private func url(for fingerprint: ClaudeDesktopCodeFingerprint) throws -> URL {
        let parts = fingerprint.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !fingerprint.relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("대화 원본 확인 경로의 형식을 지원하지 않습니다.")
        }
        switch fingerprint.kind {
        case .sourceIndex:
            guard parts.count == 7, parts[0] == "Library", parts[1] == "Application Support", parts[2] == "Claude", parts[3] == "claude-code-sessions",
                  UUID(uuidString: String(parts[4])) != nil, UUID(uuidString: String(parts[5])) != nil,
                  recordName(String(parts[6])) != nil, fingerprint.cliSessionID != nil else {
                throw failure("대화 원본 확인 경로의 형식을 지원하지 않습니다.")
            }
        case .sharedTranscript:
            guard parts.count == 4, parts[0] == ".claude", parts[1] == "projects", !parts[2].hasPrefix("ssh-"),
                  transcriptName(String(parts[3])) != nil, fingerprint.cliSessionID != nil else {
                throw failure("공유 대화 기록 확인 경로의 형식을 지원하지 않습니다.")
            }
        case .sourceDirectory:
            guard parts.count == 6, parts[0] == "Library", parts[1] == "Application Support", parts[2] == "Claude", parts[3] == "claude-code-sessions",
                  UUID(uuidString: String(parts[4])) != nil, UUID(uuidString: String(parts[5])) != nil, fingerprint.cliSessionID == nil else {
                throw failure("대화 원본 목록 확인 경로의 형식을 지원하지 않습니다 (directory).")
            }
        }
        guard fingerprint.relativePath.utf8.count <= 4_096, fingerprint.digest.count == SHA256.byteCount else { throw failure("대화 원본 확인 기록의 크기를 지원하지 않습니다.") }
        return parts.reduce(home) { $0.appendingPathComponent(String($1)) }
    }

    private func recordName(_ name: String) -> String? {
        guard name.hasPrefix("local_"), name.hasSuffix(".json"), UUID(uuidString: String(name.dropFirst(6).dropLast(5))) != nil else { return nil }
        return String(name.dropFirst(6).dropLast(5)).lowercased()
    }

    private func transcriptName(_ name: String) -> String? {
        guard name.hasSuffix(".jsonl"), UUID(uuidString: String(name.dropLast(6))) != nil else { return nil }
        return String(name.dropLast(6)).lowercased()
    }

    private func failure(_ message: String) -> AgentSwapError { .unsupported(message) }

    private func sameModificationTime(_ left: stat, _ right: stat) -> Bool {
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
            left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }
}

struct ClaudeDesktopCodeTransferPlan {
    let mutations: [AuthMutation]
    let fingerprints: [ClaudeDesktopCodeFingerprint]
    private let verify: () throws -> Void

    fileprivate init(mutations: [AuthMutation], fingerprints: [ClaudeDesktopCodeFingerprint] = [], verify: @escaping () throws -> Void) {
        self.mutations = mutations; self.fingerprints = fingerprints
        self.verify = verify
    }

    func verifyOriginals() throws { try verify() }
}

struct ClaudeDesktopCodeFingerprint: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case sourceDirectory, sourceIndex, sharedTranscript }
    let kind: Kind
    /// Relative to the caller-provided home directory; never persists a user-specific absolute path.
    let relativePath: String
    let cliSessionID: String?
    let device: UInt64
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let digest: Data
}

private struct LocalRecord {
    let filename: String
    let localID: String
    let sessionID: String
    let cliSessionID: String
    let createdAt: Double
    let lastActivityAt: Double
    let data: Data
    let object: [String: Any]

    func dataForNewTarget() throws -> Data {
        guard object["bridgeSessionIds"] != nil else { return data }
        var adapted = object
        adapted.removeValue(forKey: "bridgeSessionIds")
        return try JSONSerialization.data(withJSONObject: adapted, options: [.sortedKeys])
    }

    func dataPreservingTargetState(from target: LocalRecord) throws -> Data {
        var adapted = object
        for key in ["title", "isArchived", "isStarred", "bridgeSessionIds"] {
            if let value = target.object[key] { adapted[key] = value } else { adapted.removeValue(forKey: key) }
        }
        return try JSONSerialization.data(withJSONObject: adapted, options: [.sortedKeys])
    }
}
