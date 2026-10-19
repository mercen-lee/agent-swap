import Foundation
import Testing
@testable import AgentSwapCore

private final class DesktopManagerKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]; private var failNextWrite = false
    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[key(service, account)] } }
    func write(_ data: Data, service: String, account: String) throws { try lock.withLock { if failNextWrite { failNextWrite = false; throw AgentSwapError.storage("fixture keychain write") }; values[key(service, account)] = data } }
    func delete(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: key(service, account)) } }
    func failOnce() { lock.withLock { failNextWrite = true } }
}

private actor DesktopManagerProcesses: ClaudeDesktopConversationProcessControlling {
    let app: URL; var running = false; var acceptsQuit = true; var survivor = false; var relaunches = 0; var failRelaunch = false; var version = "2.42304.0"; var terminations = 0
    init(_ app: URL) { self.app = app }
    func installation(at: URL?) -> ClaudeDesktopConversationInstallation? { .init(url: app, version: version) }
    func scan(applicationURL: URL) -> ClaudeDesktopConversationProcessSnapshot {
        let identity = ClaudeDesktopConversationProcessIdentity(pid: 42, startedAt: 1)
        return running ? .init(desktop: [identity], related: survivor ? [identity] : [], live: survivor ? [identity] : []) : .init()
    }
    func requestNormalTermination() -> Bool { terminations += 1; guard acceptsQuit else { return false }; running = survivor; return true }
    func relaunch(at: URL) throws { relaunches += 1; if failRelaunch { throw AgentSwapError.storage("fixture relaunch failed") } }
    func setRunning(_ value: Bool) { running = value }
    func setRelaunchFailure(_ value: Bool) { failRelaunch = value }
    func setVersion(_ value: String) { version = value }
}

private final class DesktopManagerLoginVerifier: ClaudeDesktopLoginVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var mutation: (() throws -> Void)?

    func fail(_ error: Error = AgentSwapError.authentication("fixture Desktop login verification")) {
        lock.withLock { failure = error }
    }

    func mutateDuringVerification(_ action: @escaping () throws -> Void) {
        lock.withLock { mutation = action }
    }

    func verify(tokenCacheV1: String, tokenCacheV2: String, expected: AccountIdentity) async throws {
        let action = lock.withLock { () -> (() throws -> Void)? in
            defer { mutation = nil }
            return mutation
        }
        try action?()
        if let failure = lock.withLock({ failure }) { throw failure }
    }
}

private final class DesktopManagerFaultFiles: ClaudeDesktopAuthFileAccess, @unchecked Sendable {
    private let base: SecureClaudeDesktopAuthFileAccess; private let lock = NSLock(); private var failWriteNumber: Int?
    private var writes = 0
    private var mutation: (() throws -> Void)?
    init(home: URL) { base = .init(home: home) }
    func fail(onWrite number: Int) { lock.withLock { failWriteNumber = number; writes = 0 } }
    func mutate(onWrite number: Int, _ body: @escaping () throws -> Void) { lock.withLock { failWriteNumber = nil; writes = 0; mutation = body } }
    func read(_ url: URL, maximumBytes: Int) throws -> Data? { try base.read(url, maximumBytes: maximumBytes) }
    func write(_ data: Data, to url: URL) throws {
        let action = lock.withLock { writes += 1; return (failWriteNumber == writes, writes == 2 ? mutation : nil) }
        try action.1?()
        let fail = action.0
        if fail { throw AgentSwapError.storage("fixture native write failure") }
        try base.write(data, to: url)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func children(of directory: URL) throws -> [URL] { try base.children(of: directory) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
}

@Suite("Claude Desktop 인증 관리자")
struct ClaudeDesktopAccountManagerTests {
    private struct Fixture {
        let home: URL; let source: AccountRecord; let target: AccountRecord; let keychain = DesktopManagerKeychain(); let processes: DesktopManagerProcesses; let loginVerifier = DesktopManagerLoginVerifier()
        var config: URL { home.appendingPathComponent("Library/Application Support/Claude/config.json") }
        var cookie: URL { home.appendingPathComponent("Library/Application Support/Claude/Cookies") }
        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSwapDesktopManager-\(UUID().uuidString)")
            let sourceID = UUID(), targetID = UUID()
            source = .init(identity: .init(provider: .claude, userID: sourceID.uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased()))
            target = .init(identity: .init(provider: .claude, userID: targetID.uuidString.lowercased(), workspaceID: UUID().uuidString.lowercased()))
            processes = DesktopManagerProcesses(home.appendingPathComponent("Claude.app"))
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
            for account in [source, target] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/\(account.identity.userID)/\(account.identity.workspaceID)"), withIntermediateDirectories: true)
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
        func writeDesktop(_ account: AccountRecord, token: String, extra: [String: Any] = [:], cookie: Data = Data("cookie".utf8)) throws {
            var object = extra; object["lastKnownAccountUuid"] = account.identity.userID; object["oauth:tokenCache"] = token; object["oauth:tokenCacheV2"] = token + "v2"
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: config)
            try cookie.write(to: self.cookie)
        }
        func manager(files: (any ClaudeDesktopAuthFileAccess)? = nil, loginVerifier: (any ClaudeDesktopLoginVerifying)? = nil) -> ClaudeDesktopAccountManager {
            .init(home: home, keychain: keychain, processes: processes,
                  files: files ?? SecureClaudeDesktopAuthFileAccess(home: home),
                  loginVerifier: loginVerifier ?? self.loginVerifier)
        }
    }

    @Test("다른 Desktop 사용자는 캡처하지 않고 인증 파일을 보존한다")
    func wrongDesktopUserDoesNotCapture() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.target, token: "target", extra: ["mcp": "keep"])
        let before = try Data(contentsOf: f.config)
        await #expect(throws: AgentSwapError.self) { try await manager.captureCurrent(for: f.source) }
        #expect(try Data(contentsOf: f.config) == before)
    }

    @Test("검증 실패는 Desktop 인증과 Keychain 스냅샷을 변경하지 않는다")
    func loginVerificationFailureDoesNotCapture() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.writeDesktop(f.source, token: "source")
        let before = try Data(contentsOf: f.config)
        f.loginVerifier.fail()

        await #expect(throws: AgentSwapError.self) { try await f.manager().captureCurrent(for: f.source) }

        #expect(try Data(contentsOf: f.config) == before)
        #expect(try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: "desktop-profile-\(f.source.id.uuidString)") == nil)
    }

    @Test("검증 중 외부 Desktop 인증 변경은 스냅샷으로 저장하지 않는다")
    func loginChangeDuringVerificationDoesNotCapture() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.writeDesktop(f.source, token: "source")
        f.loginVerifier.mutateDuringVerification { try f.writeDesktop(f.source, token: "external-newer") }

        await #expect(throws: AgentSwapError.self) { try await f.manager().captureCurrent(for: f.source) }

        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config)) as? [String: Any]
        #expect(config?["oauth:tokenCache"] as? String == "external-newer")
        #expect(try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: "desktop-profile-\(f.source.id.uuidString)") == nil)
    }

    @Test("캡처는 완료된 Desktop을 재실행하고 스냅샷만 Keychain에 남긴다")
    func captureStopsAndRelaunches() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source")
        await f.processes.setRunning(true)
        try await manager.captureCurrent(for: f.source)
        #expect(await f.processes.relaunches == 1)
        #expect(try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: "desktop-profile-\(f.source.id.uuidString)") != nil)
    }

    @Test("Desktop 소스와 CLI 상태가 달라도 저장된 대상 스냅샷을 적용한다")
    func savedTargetAppliesIndependentlyOfCLI() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        _ = try await manager.finish(transactionID: id, cliApplied: true)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config)) as! [String: Any]
        #expect(object["lastKnownAccountUuid"] as? String == f.target.identity.userID)
    }

    @Test("준비 중 Keychain 저널 쓰기 실패는 Desktop 인증을 변경하지 않는다")
    func journalWriteFailurePreservesNativeAuth() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let before = try Data(contentsOf: f.config); f.keychain.failOnce()
        await #expect(throws: AgentSwapError.self) { try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity) }
        #expect(try Data(contentsOf: f.config) == before)
    }

    @Test("준비 중 대상 Desktop 스냅샷이 바뀌면 CLI 전환 기록을 만들지 않는다")
    func changedSavedTargetDuringVerificationBlocksPrepare() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let nativeBefore = try Data(contentsOf: f.config)
        let account = "desktop-profile-\(f.target.id.uuidString)"
        f.loginVerifier.mutateDuringVerification {
            guard let raw = try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: account),
                  var snapshot = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
                  var browser = snapshot["browserFiles"] as? [[String: Any]],
                  let cookie = browser.firstIndex(where: { $0["relativePath"] as? String == "Cookies" }) else {
                throw AgentSwapError.storage("fixture target snapshot")
            }
            browser[cookie]["contents"] = Data("externally-updated-cookie".utf8)
            snapshot["browserFiles"] = browser
            let changed = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
            try f.keychain.write(changed, service: ClaudeDesktopAccountManager.service, account: account)
        }

        await #expect(throws: AgentSwapError.self) {
            try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        }

        #expect(try Data(contentsOf: f.config) == nativeBefore)
        let saved = try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: account)
        let raw = try #require(saved)
        let snapshot = try #require(try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])
        let browser = try #require(snapshot["browserFiles"] as? [[String: Any]])
        let cookie = try #require(browser.first(where: { $0["relativePath"] as? String == "Cookies" }))
        #expect(cookie["contents"] as? Data == Data("externally-updated-cookie".utf8))
        #expect(try f.keychain.read(service: "net.mercen.agentswap.recovery", account: "claude-desktop-account-switch") == nil)
    }

    @Test("CLI 실패 완료는 Desktop 인증을 바꾸지 않는다")
    func cliFailureLeavesDesktopUntouched() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source"); let before = try Data(contentsOf: f.config)
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        _ = try await manager.finish(transactionID: id, cliApplied: false)
        #expect(try Data(contentsOf: f.config) == before)
    }

    @Test("CLI가 이미 대상이어도 현재 Desktop 원본에서 저장된 대상 인증으로 전환한다")
    func alreadyTargetCLIStillSwitchesDifferentDesktopLogin() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.target.identity)
        _ = try await manager.finish(transactionID: id, cliApplied: true)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config)) as! [String: Any]
        #expect(object["lastKnownAccountUuid"] as? String == f.target.identity.userID)
    }

    @Test("이미 대상인 Desktop의 최신 네이티브 캐시는 오래된 저장 스냅샷으로 되돌리지 않는다")
    func currentDesktopTargetUsesFreshNativeCache() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.target, token: "old-target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.target, token: "fresh-target")
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.target.identity)
        _ = try await manager.finish(transactionID: id, cliApplied: true)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.config)) as! [String: Any]
        #expect(object["oauth:tokenCache"] as? String == "fresh-target")
    }

    @Test("적용 후 재실행 실패의 커밋 기록은 새 관리자 복구에서 외부 최신 인증을 되돌리지 않는다")
    func committedRelaunchFailureNeverRollsBackLaterExternalAuth() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.target.identity)
        await f.processes.setRelaunchFailure(true)
        await #expect(throws: AgentSwapError.self) { try await manager.finish(transactionID: id, cliApplied: true) }
        try f.writeDesktop(f.target, token: "external-newer")
        let external = try Data(contentsOf: f.config)
        await f.processes.setRelaunchFailure(false)
        _ = try await f.manager().recover(registered: [f.source, f.target], currentCLI: f.target.identity)
        #expect(try Data(contentsOf: f.config) == external)
    }

    @Test("준비 뒤 외부 Desktop 세대가 생기면 덮어쓰지 않고 복구 기록을 보존한다")
    func externalGenerationAfterPrepareIsPreserved() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        try f.writeDesktop(f.source, token: "external-third", extra: ["unrelated": "preserve"])
        let external = try Data(contentsOf: f.config)
        await #expect(throws: AgentSwapError.self) { try await manager.finish(transactionID: id, cliApplied: true) }
        #expect(try Data(contentsOf: f.config) == external)
        #expect(try f.keychain.read(service: "net.mercen.agentswap.recovery", account: "claude-desktop-account-switch") != nil)
    }

    @Test("두 번째 Desktop 인증 쓰기 실패는 config와 Cookies를 정확히 복원하고 재복구할 수 있다")
    func partialNativeWriteRestoresExactBeforeImages() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.writeDesktop(f.source, token: "source", cookie: Data("source-cookie".utf8)); try await f.manager().captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target", cookie: Data("target-cookie".utf8)); try await f.manager().captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source", cookie: Data("source-cookie".utf8))
        let configBefore = try Data(contentsOf: f.config), cookieBefore = try Data(contentsOf: f.cookie)
        let faults = DesktopManagerFaultFiles(home: f.home); let manager = f.manager(files: faults)
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        faults.fail(onWrite: 2)
        await #expect(throws: AgentSwapError.self) { try await manager.finish(transactionID: id, cliApplied: true) }
        #expect(try Data(contentsOf: f.config) == configBefore)
        #expect(try Data(contentsOf: f.cookie) == cookieBefore)
        _ = try await f.manager().recover(registered: [f.source, f.target], currentCLI: f.source.identity)
        #expect(try Data(contentsOf: f.config) == configBefore)
    }

    @Test("후속 Cookies 쓰기 중 config가 원본으로 되돌아가면 완료로 표시하지 않고 전체를 복구한다")
    func earlierMutationRevertDuringLaterWriteFailsCompletion() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.writeDesktop(f.source, token: "source", cookie: Data("source-cookie".utf8)); try await f.manager().captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target", cookie: Data("target-cookie".utf8)); try await f.manager().captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source", cookie: Data("source-cookie".utf8))
        let configBefore = try Data(contentsOf: f.config), cookieBefore = try Data(contentsOf: f.cookie)
        let faults = DesktopManagerFaultFiles(home: f.home); let manager = f.manager(files: faults)
        let id = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        faults.mutate(onWrite: 2) { try configBefore.write(to: f.config) }
        await #expect(throws: AgentSwapError.self) { try await manager.finish(transactionID: id, cliApplied: true) }
        #expect(try Data(contentsOf: f.config) == configBefore)
        #expect(try Data(contentsOf: f.cookie) == cookieBefore)
    }

    @Test("지원하지 않는 Desktop 버전은 종료하거나 인증을 저장하지 않는다")
    func unsupportedDesktopVersionStopsBeforeQuitOrSnapshot() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source")
        await f.processes.setRunning(true); await f.processes.setVersion("2.99999.0")
        let before = try Data(contentsOf: f.config)
        await #expect(throws: AgentSwapError.self) { try await manager.captureCurrent(for: f.source) }
        #expect(await f.processes.terminations == 0)
        #expect(try Data(contentsOf: f.config) == before)
        #expect(try f.keychain.read(service: ClaudeDesktopAccountManager.service, account: "desktop-profile-\(f.source.id.uuidString)") == nil)
    }

    @Test("지원하지 않는 새 oauth 키는 쓰기 전에 차단한다")
    func unknownOAuthFieldBlocksBeforeWrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source", extra: ["oauth:newFormat": "opaque"])
        let before = try Data(contentsOf: f.config)
        await #expect(throws: AgentSwapError.self) { try await manager.captureCurrent(for: f.source) }
        #expect(try Data(contentsOf: f.config) == before)
    }

    @Test("진행 중 전환이 참조하는 Desktop 프로필 삭제는 차단한다")
    func pendingTransactionBlocksSnapshotDelete() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let manager = f.manager()
        try f.writeDesktop(f.source, token: "source"); try await manager.captureCurrent(for: f.source)
        try f.writeDesktop(f.target, token: "target"); try await manager.captureCurrent(for: f.target)
        try f.writeDesktop(f.source, token: "source")
        _ = try await manager.prepareSwitch(target: f.target, registered: [f.source, f.target], currentCLI: f.source.identity)
        await #expect(throws: AgentSwapError.self) { try await manager.deleteSnapshot(accountID: f.source.id) }
    }
}
