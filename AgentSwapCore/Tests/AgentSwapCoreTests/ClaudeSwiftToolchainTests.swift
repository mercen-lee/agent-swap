import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Claude Apple Swift interpreter boundary")
struct ClaudeSwiftToolchainTests {
    @Test("An Apple-signed program that is not the Swift interpreter is rejected")
    func rejectsDifferentAppleTool() {
        #expect(!ClaudeSwiftToolchain.isTrustedInterpreter(URL(fileURLWithPath: "/usr/bin/true")))
    }

    @Test("An unsigned executable and missing executable are rejected")
    func rejectsUnsignedOrMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwap-unsigned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("swift-frontend")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(!ClaudeSwiftToolchain.isTrustedInterpreter(executable))
        #expect(!ClaudeSwiftToolchain.isTrustedInterpreter(directory.appendingPathComponent("missing")))
    }
}
