import Foundation
import Darwin

/// Mirrors npm proper-lockfile: atomic mkdir, mtime heartbeat, and provider-specific stale limits.
/// The synchronous transaction runs on the auth-store actor, never the UI actor.
final class ProviderDirectoryLock {
    private let url: URL
    private let inode: ino_t
    private let device: dev_t
    private let timer: DispatchSourceTimer
    init(url: URL, staleAfter: TimeInterval, timeout: TimeInterval = 9) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while Darwin.mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST else { throw AgentSwapError.storage("제공자 인증 잠금을 만들지 못했습니다.") }
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AgentSwapError.unsupported("제공자 인증 잠금 형식을 지원하지 않습니다.") }
                let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
                if Date().timeIntervalSince1970 - modified > staleAfter {
                    if Darwin.rmdir(url.path) == 0 { continue }
                }
            }
            guard ContinuousClock.now < deadline else { throw AgentSwapError.storage("제공자가 인증을 갱신 중입니다. 잠시 후 다시 전환해 주세요.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { _ = Darwin.rmdir(url.path); throw AgentSwapError.storage("인증 잠금을 확인하지 못했습니다.") }
        inode = info.st_ino; device = info.st_dev
        let expectedInode = inode, expectedDevice = device
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler {
            var current = stat()
            if lstat(url.path, &current) == 0, current.st_ino == expectedInode, current.st_dev == expectedDevice {
                _ = Darwin.utimes(url.path, nil)
            }
        }
        timer.resume()
    }
    func verify() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_ino == inode, info.st_dev == device else {
            throw AgentSwapError.storage("인증 잠금이 변경되어 전환을 중단했습니다.")
        }
    }
    deinit {
        timer.cancel()
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_ino == inode, info.st_dev == device { _ = Darwin.rmdir(url.path) }
    }
}

struct AuthMutation: Codable, Sendable {
    enum Location: Codable, Sendable, Equatable { case file(String), keychain(service: String, account: String) }
    var location: Location
    var before: Data?
    var after: Data?
}

private struct AuthJournal: Codable {
    var version = 1
    var committed = false
    var mutations: [AuthMutation]
}

/// Before-images and target auth stay in the application Keychain, including interrupted transactions.
struct AuthTransaction {
    static let service = "net.mercen.agentswap.recovery"
    let identifier: String
    let keychain: any KeychainAccess
    let files: any AuthFileAccess

    func read(_ location: AuthMutation.Location) throws -> Data? {
        switch location {
        case .file(let path): try files.read(URL(fileURLWithPath: path))
        case .keychain(let service, let account): try keychain.read(service: service, account: account)
        }
    }
    private func apply(_ data: Data?, to location: AuthMutation.Location) throws {
        switch location {
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            if let data { try files.write(data, to: url) } else { try files.delete(url) }
        case .keychain(let service, let account):
            if let data { try keychain.write(data, service: service, account: account) }
            else { try keychain.delete(service: service, account: account) }
        }
        guard try read(location) == data else { throw AgentSwapError.storage("인증 저장 결과가 예상과 달라 복원을 시도합니다.") }
    }
    private func validateWrite(_ data: Data?, to location: AuthMutation.Location) throws {
        guard let data, case .keychain(let service, let account) = location,
              let preflight = keychain as? any KeychainWritePreflighting else { return }
        try preflight.validateWrite(data, service: service, account: account)
    }
    func hasPendingRecovery() throws -> Bool {
        try keychain.read(service: Self.service, account: identifier) != nil
    }
    func recover(allowedLocations: Set<AuthMutation.Location>) throws {
        // Once a native write has started, cancellation must not stop its durable rollback.
        // The native subprocess still retains its permission and elapsed-time bounds.
        try NativeSecurityCancellation.$permitsRecovery.withValue(true) {
            try recoverIgnoringCancellation(allowedLocations: allowedLocations)
        }
    }
    private func recoverIgnoringCancellation(allowedLocations: Set<AuthMutation.Location>) throws {
        guard let data = try keychain.read(service: Self.service, account: identifier) else { return }
        let journal: AuthJournal
        do { journal = try JSONDecoder().decode(AuthJournal.self, from: data) }
        catch { throw AgentSwapError.storage("복원 기록의 형식을 읽지 못했습니다. 인증을 변경하지 않았습니다.") }
        guard journal.version == 1, !journal.mutations.isEmpty,
              Set(journal.mutations.map(\.location)).count == journal.mutations.count,
              journal.mutations.allSatisfy({ allowedLocations.contains($0.location) }) else {
            throw AgentSwapError.unsupported("지원하지 않는 인증 복원 기록입니다.")
        }
        // The durable commit records successful verification of every location. Later CLI
        // rotation or an external account change cannot turn it back into a rollback obligation.
        // Clean only our private journal; do not read, validate, or modify current provider state.
        if journal.committed {
            try keychain.delete(service: Self.service, account: identifier)
            return
        }
        // Never overwrite a token rotated by another process after the interruption.
        for mutation in journal.mutations {
            let current = try read(mutation.location)
            guard current == mutation.before || current == mutation.after else {
                throw AgentSwapError.storage("중단 후 인증이 외부에서 변경되었습니다. 복원 자료를 Keychain에 보존했습니다.")
            }
        }
        // Validate every restore before changing any location: a bounded native transport
        // must never begin a rollback whose later before-image cannot be written.
        for mutation in journal.mutations { try validateWrite(mutation.before, to: mutation.location) }
        for mutation in journal.mutations.reversed() {
            if try read(mutation.location) != mutation.before { try apply(mutation.before, to: mutation.location) }
        }
        try keychain.delete(service: Self.service, account: identifier)
    }
    func perform(_ mutations: [AuthMutation], checkCancellation: () throws -> Void = {}, verifyLock: () throws -> Void) throws {
        guard !mutations.isEmpty else { return }
        guard !(try hasPendingRecovery()) else { throw AgentSwapError.storage("이전 전환의 복원 처리가 필요합니다.") }
        // Check targets AND rollback images before the journal or any provider write.
        for mutation in mutations {
            try validateWrite(mutation.before, to: mutation.location)
            try validateWrite(mutation.after, to: mutation.location)
        }
        var journal = AuthJournal(mutations: mutations)
        try keychain.write(JSONEncoder().encode(journal), service: Self.service, account: identifier)
        do {
            for mutation in mutations {
                try checkCancellation()
                try verifyLock()
                guard try read(mutation.location) == mutation.before else {
                    throw AgentSwapError.storage("인증이 외부에서 변경되어 전환을 중단했습니다.")
                }
                try checkCancellation()
                try apply(mutation.after, to: mutation.location)
            }
            try checkCancellation()
            try verifyLock()
            journal.committed = true
            try keychain.write(JSONEncoder().encode(journal), service: Self.service, account: identifier)
        } catch {
            // Security can apply an update and then fail its verification read. Confirm a committed
            // journal and every target before deciding that such an ambiguous result is a failure.
            if journal.committed,
               let saved = try? keychain.read(service: Self.service, account: identifier),
               let persisted = try? JSONDecoder().decode(AuthJournal.self, from: saved), persisted.committed,
               (try? mutations.allSatisfy { try read($0.location) == $0.after }) == true {
                try? keychain.delete(service: Self.service, account: identifier)
                return
            }
            // Leave the journal intact if any restore fails. Future writes stay blocked.
            do {
                try verifyLock()
                try recover(allowedLocations: Set(mutations.map(\.location)))
            } catch {
                throw AgentSwapError.storage("전환을 완료하지 못했고 자동 복원이 보류되었습니다. 복원 자료를 Keychain에 보존했습니다.")
            }
            throw AgentSwapError.storage("전환에 실패하여 이전 인증으로 복원했습니다.")
        }
        // A committed journal is safe to clean at the next access if Keychain temporarily rejects deletion.
        try? keychain.delete(service: Self.service, account: identifier)
    }
}

extension AuthMutation.Location: Hashable {}
