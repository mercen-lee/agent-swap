import Foundation
import Darwin
import Testing
@testable import AgentSwapCore

@Suite("Secure Claude Desktop auth files")
struct ClaudeDesktopAuthFilesTests {
    @Test("Reads and atomically writes a 13 MiB account file")
    func largeExactReadWrite() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let access = SecureClaudeDesktopAuthFileAccess(home: fixture.home)
        let directory = fixture.home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try access.createDirectory(directory)
        let file = directory.appendingPathComponent("auth.json")
        let data = Data(repeating: 0x6a, count: 13 * 1_024 * 1_024)
        try access.write(data, to: file)
        let read = try #require(try access.read(file, maximumBytes: SecureClaudeDesktopAuthFileAccess.maximumFileBytes))
        #expect(read == data)
        #expect(throws: (any Error).self) { try access.read(file, maximumBytes: data.count - 1) }
    }

    @Test("Rejects paths outside home and symlink or hard-link indirection")
    func rejectsUnsafePaths() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let access = SecureClaudeDesktopAuthFileAccess(home: fixture.home)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        #expect(throws: (any Error).self) { try access.read(outside, maximumBytes: 128) }

        let linkedDirectory = fixture.home.appendingPathComponent("linked")
        #expect(Darwin.symlink(fixture.root.path, linkedDirectory.path) == 0)
        #expect(throws: (any Error).self) { try access.createDirectory(linkedDirectory.appendingPathComponent("child")) }

        let regular = fixture.home.appendingPathComponent("regular.json")
        try Data("safe".utf8).write(to: regular)
        try fixture.chmod(regular, 0o600)
        let hardLink = fixture.home.appendingPathComponent("hard.json")
        #expect(Darwin.link(regular.path, hardLink.path) == 0)
        #expect(throws: (any Error).self) { try access.read(hardLink, maximumBytes: 128) }

        let leafLink = fixture.home.appendingPathComponent("leaf.json")
        #expect(Darwin.symlink(outside.path, leafLink.path) == 0)
        #expect(throws: (any Error).self) { try access.remove(leafLink) }
    }

    @Test("Bounds reads, includes hidden children, and refuses unsafe directories")
    func boundsChildrenAndPermissions() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let access = SecureClaudeDesktopAuthFileAccess(home: fixture.home)
        let directory = fixture.home.appendingPathComponent("browser", isDirectory: true)
        try access.createDirectory(directory)
        let oversized = directory.appendingPathComponent("oversized")
        try Data(repeating: 0x42, count: 129).write(to: oversized)
        try fixture.chmod(oversized, 0o600)
        #expect(throws: (any Error).self) { try access.read(oversized, maximumBytes: 128) }

        let hidden = directory.appendingPathComponent(".hidden")
        try Data("hidden".utf8).write(to: hidden)
        try fixture.chmod(hidden, 0o600)
        #expect(try access.children(of: directory).map(\.lastPathComponent).contains(".hidden"))

        let unsafe = fixture.home.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        try fixture.chmod(unsafe, 0o777)
        #expect(throws: (any Error).self) { try access.createDirectory(unsafe.appendingPathComponent("nested")) }
    }

    @Test("Creates nested private directories and removes only regular files")
    func nestedCreationAndRegularRemoval() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let access = SecureClaudeDesktopAuthFileAccess(home: fixture.home)
        let nested = fixture.home.appendingPathComponent("one/two/three", isDirectory: true)
        try access.createDirectory(nested)
        var info = stat()
        #expect(lstat(nested.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o700)

        let file = nested.appendingPathComponent("token")
        try access.write(Data("token".utf8), to: file)
        try access.remove(file)
        #expect(try access.read(file, maximumBytes: 128) == nil)
        #expect(throws: (any Error).self) { try access.remove(nested) }
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }
}

private final class Fixture {
    let root: URL
    let home: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentswap-desktop-files-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try chmod(home, 0o700)
    }

    func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else { throw POSIXError(.EPERM) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
