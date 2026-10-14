import Foundation
import Testing
import Darwin
@testable import AgentSwapCore

@Suite("Application instance ownership")
struct AppInstanceLockTests {
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapInstanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    @Test("A second app copy cannot own the shared engine; release allows a new owner")
    func lifetimeOwnership() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("instance.lock")
        var first: AppInstanceLock? = try AppInstanceLock.acquire(directory: directory)
        #expect(AppInstanceLock.ownerProcessID(directory: directory) == getpid())
        #expect(throws: AppInstanceLockError.alreadyRunning) { try AppInstanceLock.acquire(directory: directory) }
        #expect(AppInstanceLock.ownerProcessID(directory: directory) == getpid())
        withExtendedLifetime(first) {}
        first = nil
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(AppInstanceLock.ownerProcessID(directory: directory) == nil)
        let next = try AppInstanceLock.acquire(directory: directory)
        #expect(AppInstanceLock.ownerProcessID(directory: directory) == getpid())
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        withExtendedLifetime(next) {}
    }

    @Test("Symlink and hard-link lock files are refused without changing their target", arguments: [false, true])
    func unsafeFileLink(hardLink: Bool) throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("instance.lock"), target = directory.appendingPathComponent("target")
        let original = Data("Fixture original".utf8)
        try AtomicAuthFileAccess().write(original, to: target)
        if hardLink { try FileManager.default.linkItem(at: target, to: file) }
        else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
        #expect(throws: AppInstanceLockError.self) { try AppInstanceLock.acquire(directory: directory) }
        #expect(try AtomicAuthFileAccess().read(target) == original)
        #expect(AppInstanceLock.ownerProcessID(directory: directory) == nil)
    }

    @Test("A substituted support-directory symlink cannot create a lock in the redirected location")
    func unsafeDirectoryLink() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true), link = directory.appendingPathComponent("redirect")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: AppInstanceLockError.unsafePath) { try AppInstanceLock.acquire(directory: link) }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("instance.lock").path))
    }
}
