import Foundation
import Darwin

public enum AppInstanceLockError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRunning, unsafePath, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "AgentSwap이 이미 실행 중입니다. 기존 앱에서 계속 진행해 주세요."
        case .unsafePath: "AgentSwap 실행 잠금의 파일 위치 또는 소유권을 확인하지 못했습니다."
        case .system(let code): "AgentSwap 실행 잠금을 확보하지 못했습니다 (\(code))."
        }
    }
}

/// One shared engine per user's Application Support directory, across installed copies and bundle versions.
/// Retain this immutable descriptor owner until application termination; closing it releases the flock.
public final class AppInstanceLock: Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(directory: URL? = nil) throws -> AppInstanceLock {
        let directory = supportDirectory(directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw AppInstanceLockError.system(errno) }
        try verifyDirectory(directory)
        let file = directory.appendingPathComponent("instance.lock")
        let fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP { throw AppInstanceLockError.unsafePath }
            throw AppInstanceLockError.system(errno)
        }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        try verifyFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw AppInstanceLockError.alreadyRunning }
            throw AppInstanceLockError.system(errno)
        }
        // Metadata only. Write after acquiring the lock, so a rejected instance cannot replace the owner's PID.
        let bytes = Data("\(getpid())\n".utf8)
        guard ftruncate(fd, 0) == 0 else { throw AppInstanceLockError.system(errno) }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count == -1 && errno == EINTR { continue }
                guard count > 0 else { throw AppInstanceLockError.system(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw AppInstanceLockError.system(errno) }
        retained = true
        return AppInstanceLock(descriptor: fd)
    }

    /// Advisory activation hint, only when another open file description currently holds the lock.
    /// Callers should still verify the PID belongs to a running AgentSwap before activating its app.
    public static func ownerProcessID(directory: URL? = nil) -> Int32? {
        let directory = supportDirectory(directory)
        guard (try? verifyDirectory(directory)) != nil else { return nil }
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard (try? verifyFile(fd)) != nil else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return nil // The PID left by an exited owner is stale.
        }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count < bytes.count,
              let value = Int32(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    private static func supportDirectory(_ directory: URL?) -> URL {
        directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentSwap", isDirectory: true)
    }
    private static func verifyDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else { throw AppInstanceLockError.unsafePath }
    }
    private static func verifyFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else { throw AppInstanceLockError.unsafePath }
    }
    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
