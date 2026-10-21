import Foundation
import Darwin

/// File access for Claude Desktop's small, account-scoped authentication stores.  This type is
/// deliberately rooted at one home directory; callers must still restrict which descendants are
/// meaningful Desktop auth locations.
public struct SecureClaudeDesktopAuthFileAccess: ClaudeDesktopAuthFileAccess {
    public static let maximumFileBytes = 32 * 1_024 * 1_024

    private let home: URL
    private let homePath: String
    private let uid: uid_t

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        self.homePath = self.home.path
        self.uid = geteuid()
    }

    public func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        let limit = try checkedLimit(maximumBytes)
        let path = try checkedPath(url)
        guard try parentExistsAndIsSafe(for: path) else { return nil }
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd == -1, errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("Claude 데스크톱 인증 파일을 안전하게 열지 못했습니다.") }
        defer { Darwin.close(fd) }

        let before = try checkedOpenFile(fd, limit: limit)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, max(1, limit)))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count == -1, errno == EINTR { continue }
            guard count > 0, bytes.count + count <= limit else {
                throw failure("Claude 데스크톱 인증 파일 크기를 지원하지 않습니다.")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let after = try checkedOpenFile(fd, limit: limit)
        guard before == after, bytes.count == Int(before.size) else {
            throw failure("Claude 데스크톱 인증 파일이 읽는 중 변경되었습니다.")
        }
        return bytes
    }

    public func write(_ data: Data, to url: URL) throws {
        guard data.count <= Self.maximumFileBytes else { throw failure("Claude 데스크톱 인증 파일 크기를 지원하지 않습니다.") }
        let path = try checkedPath(url)
        guard try parentExistsAndIsSafe(for: path) else {
            throw failure("Claude 데스크톱 인증 폴더를 먼저 안전하게 만들어야 합니다.")
        }
        let parent = path.deletingLastPathComponent()
        let previous = try leafFingerprint(path, limit: Self.maximumFileBytes)
        let temporary = parent.appendingPathComponent(".agentswap-desktop-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Claude 데스크톱 인증 임시 파일을 만들지 못했습니다.") }
        var temporaryFingerprint: Fingerprint?
        defer {
            Darwin.close(fd)
            if let temporaryFingerprint,
               (try? leafFingerprint(temporary, limit: Self.maximumFileBytes)) == temporaryFingerprint {
                _ = Darwin.unlink(temporary.path)
            }
        }
        guard Darwin.fchmod(fd, 0o600) == 0 else { throw failure("Claude 데스크톱 인증 파일 권한을 설정하지 못했습니다.") }
        try writeAll(data, fd: fd)
        guard Darwin.fsync(fd) == 0 else { throw failure("Claude 데스크톱 인증 파일을 저장하지 못했습니다.") }
        temporaryFingerprint = try checkedOpenFile(fd, limit: Self.maximumFileBytes)
        guard temporaryFingerprint?.size == off_t(data.count),
              try parentExistsAndIsSafe(for: path),
              try leafFingerprint(path, limit: Self.maximumFileBytes) == previous,
              try leafFingerprint(temporary, limit: Self.maximumFileBytes) == temporaryFingerprint else {
            throw failure("Claude 데스크톱 인증 파일이 저장 중 변경되었습니다.")
        }
        guard Darwin.rename(temporary.path, path.path) == 0 else { throw failure("Claude 데스크톱 인증 파일을 교체하지 못했습니다.") }
        temporaryFingerprint = nil
        guard let stored = try leafFingerprint(path, limit: Self.maximumFileBytes), stored.size == off_t(data.count) else {
            throw failure("Claude 데스크톱 인증 파일 저장 결과를 확인하지 못했습니다.")
        }
        try synchronizeDirectory(parent)
    }

    public func remove(_ url: URL) throws {
        let path = try checkedPath(url)
        guard try parentExistsAndIsSafe(for: path) else { return }
        guard let before = try leafFingerprint(path, limit: Self.maximumFileBytes) else { return }
        guard try leafFingerprint(path, limit: Self.maximumFileBytes) == before else {
            throw failure("Claude 데스크톱 인증 파일이 삭제 중 변경되었습니다.")
        }
        guard Darwin.unlink(path.path) == 0 else {
            if errno == ENOENT { return }
            throw failure("Claude 데스크톱 인증 파일을 삭제하지 못했습니다.")
        }
        try synchronizeDirectory(path.deletingLastPathComponent())
    }

    public func children(of directory: URL) throws -> [URL] {
        let path = try checkedPath(directory)
        guard try directoryExistsAndIsSafe(path) else { return [] }
        guard let stream = Darwin.opendir(path.path) else { throw failure("Claude 데스크톱 인증 폴더를 읽지 못했습니다.") }
        defer { Darwin.closedir(stream) }
        var result: [URL] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < 10_000 else { throw failure("Claude 데스크톱 인증 폴더 항목이 너무 많습니다.") }
            let child = path.appendingPathComponent(name)
            var info = stat()
            guard lstat(child.path, &info) == 0 else { throw failure("Claude 데스크톱 인증 폴더 항목을 확인하지 못했습니다.") }
            if (info.st_mode & S_IFMT) == S_IFDIR { try validateDirectory(info) }
            else { _ = try validateRegular(info, limit: Self.maximumFileBytes) }
            result.append(child)
        }
        if errno != 0 { throw failure("Claude 데스크톱 인증 폴더를 끝까지 읽지 못했습니다.") }
        return result
    }

    public func createDirectory(_ url: URL) throws {
        let path = try checkedPath(url)
        let components = try relativeComponents(of: path)
        try validateHome()
        var current = home
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                try validateDirectory(info)
                continue
            }
            guard errno == ENOENT else { throw failure("Claude 데스크톱 인증 폴더를 확인하지 못했습니다.") }
            guard Darwin.mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
                throw failure("Claude 데스크톱 인증 폴더를 만들지 못했습니다.")
            }
            guard lstat(current.path, &info) == 0 else { throw failure("Claude 데스크톱 인증 폴더 생성 결과를 확인하지 못했습니다.") }
            try validateDirectory(info)
        }
    }

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t
        let links: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private func checkedLimit(_ maximumBytes: Int) throws -> Int {
        guard maximumBytes >= 0, maximumBytes <= Self.maximumFileBytes else {
            throw failure("Claude 데스크톱 인증 파일 크기 한도를 지원하지 않습니다.")
        }
        return maximumBytes
    }

    private func checkedPath(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        _ = try relativeComponents(of: path)
        return path
    }

    private func relativeComponents(of path: URL) throws -> [String] {
        let value = path.path
        guard value == homePath || value.hasPrefix(homePath + "/") else {
            throw failure("Claude 데스크톱 인증 경로가 홈 폴더 밖에 있습니다.")
        }
        let suffix = value.dropFirst(homePath.count)
        return suffix.split(separator: "/").map(String.init)
    }

    private func validateHome() throws {
        var info = stat()
        guard lstat(home.path, &info) == 0 else { throw failure("홈 폴더를 확인하지 못했습니다.") }
        try validateDirectory(info)
    }

    /// Returns false only when an ancestor does not yet exist. Existing ancestors are all checked.
    private func parentExistsAndIsSafe(for path: URL) throws -> Bool {
        let components = try relativeComponents(of: path.deletingLastPathComponent())
        try validateHome()
        var current = home
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw failure("Claude 데스크톱 인증 폴더를 확인하지 못했습니다.")
            }
            try validateDirectory(info)
        }
        return true
    }

    private func directoryExistsAndIsSafe(_ path: URL) throws -> Bool {
        guard try parentExistsAndIsSafe(for: path) else { return false }
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw failure("Claude 데스크톱 인증 폴더를 확인하지 못했습니다.")
        }
        try validateDirectory(info)
        return true
    }

    private func validateDirectory(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid,
              info.st_nlink >= 1, info.st_mode & 0o022 == 0 else {
            throw failure("Claude 데스크톱 인증 폴더의 소유권 또는 권한을 확인하지 못했습니다.")
        }
    }

    private func validateRegular(_ info: stat, limit: Int) throws -> Fingerprint {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= off_t(limit), info.st_mode & 0o022 == 0 else {
            throw failure("Claude 데스크톱 인증 파일의 소유권, 링크 또는 크기를 확인하지 못했습니다.")
        }
        return .init(device: info.st_dev, inode: info.st_ino, mode: info.st_mode, owner: info.st_uid,
                     links: info.st_nlink, size: info.st_size, modifiedSeconds: Int(info.st_mtimespec.tv_sec),
                     modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec))
    }

    private func checkedOpenFile(_ fd: Int32, limit: Int) throws -> Fingerprint {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("Claude 데스크톱 인증 파일을 확인하지 못했습니다.") }
        return try validateRegular(info, limit: limit)
    }

    private func leafFingerprint(_ path: URL, limit: Int) throws -> Fingerprint? {
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw failure("Claude 데스크톱 인증 파일을 확인하지 못했습니다.")
        }
        return try validateRegular(info, limit: limit)
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count == -1, errno == EINTR { continue }
                guard count > 0 else { throw failure("Claude 데스크톱 인증 파일을 저장하지 못했습니다.") }
                offset += count
            }
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Claude 데스크톱 인증 폴더를 동기화하지 못했습니다.") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw failure("Claude 데스크톱 인증 폴더를 동기화하지 못했습니다.") }
    }

    private func failure(_ text: String) -> AgentSwapError { .storage(text) }
}
