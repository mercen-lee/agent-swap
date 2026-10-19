import Testing
import Darwin
@testable import AgentSwapCore

@Suite("Claude Desktop 프로세스 세대 추적")
struct ClaudeDesktopProcessTrackingTests {
    @Test("정확한 크기로 확인된 sysctl 좀비 상태만 종료로 인정한다")
    func requiresPositiveZombieSnapshot() {
        var info = kinfo_proc()
        info.kp_proc.p_stat = Int8(SZOMB)
        let size = MemoryLayout<kinfo_proc>.size
        #expect(ClaudeDesktopProcessTracking.confirmsZombie(info: info, result: 0, returnedBytes: size))
        #expect(!ClaudeDesktopProcessTracking.confirmsZombie(info: info, result: -1, returnedBytes: size))
        #expect(!ClaudeDesktopProcessTracking.confirmsZombie(info: info, result: 0, returnedBytes: 0))
        #expect(!ClaudeDesktopProcessTracking.confirmsZombie(info: info, result: 0, returnedBytes: size - 1))
        info.kp_proc.p_stat = Int8(SRUN)
        #expect(!ClaudeDesktopProcessTracking.confirmsZombie(info: info, result: 0, returnedBytes: size))
    }

    private func identity(_ pid: Int32, _ startedAt: UInt64) -> ClaudeDesktopConversationProcessIdentity {
        .init(pid: pid, startedAt: startedAt)
    }

    @Test("고아 helper는 재시도에서도 관련 프로세스로 유지된다")
    func orphanSurvivesRetry() throws {
        let orphan = identity(100, 10)
        var previous = [orphan.pid: orphan]
        var current: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]

        let related = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &current,
            directRelated: [],
            parents: [:],
            missingInventory: [orphan.pid: .live(orphan)]
        )

        #expect(related == [orphan.pid])
        #expect(previous == [orphan.pid: orphan])
    }

    @Test("고아 helper의 새 자식도 관련 프로세스로 포함한다")
    func orphanIncludesNewChild() throws {
        let orphan = identity(100, 10)
        let child = identity(101, 11)
        var previous = [orphan.pid: orphan]
        var current = [child.pid: child]

        let related = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &current,
            directRelated: [],
            parents: [child.pid: orphan.pid],
            missingInventory: [orphan.pid: .live(orphan)]
        )

        #expect(related == [orphan.pid, child.pid])
        #expect(previous == [orphan.pid: orphan, child.pid: child])
    }

    @Test("현재 목록에 남은 고아 helper는 다음 재시도의 새 자식까지 추적한다")
    func currentInventoryOrphanSurvivesRepeatedRetry() throws {
        let desktop = identity(10, 10)
        let orphan = identity(11, 11)
        var previous: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]
        var initial = [desktop.pid: desktop, orphan.pid: orphan]
        _ = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &initial,
            directRelated: [desktop.pid],
            parents: [orphan.pid: desktop.pid],
            missingInventory: [:]
        )

        var firstRetry = [orphan.pid: orphan]
        let firstRelated = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &firstRetry,
            directRelated: [],
            parents: [orphan.pid: 1],
            missingInventory: [desktop.pid: .absent]
        )
        #expect(firstRelated == [orphan.pid])

        let newChild = identity(12, 12)
        var secondRetry = [orphan.pid: orphan, newChild.pid: newChild]
        let secondRelated = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &secondRetry,
            directRelated: [],
            parents: [orphan.pid: 1, newChild.pid: orphan.pid],
            missingInventory: [:]
        )

        #expect(secondRelated == [orphan.pid, newChild.pid])
        #expect(previous == [orphan.pid: orphan, newChild.pid: newChild])
    }

    @Test("재사용된 PID는 이전 Desktop 세대로 추적하지 않는다")
    func pidReuseIsDiscarded() throws {
        let old = identity(100, 10)
        let reused = identity(100, 20)
        var previous = [old.pid: old]
        var current = [reused.pid: reused]

        let related = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &current,
            directRelated: [],
            parents: [:],
            missingInventory: [:]
        )

        #expect(related.isEmpty)
        #expect(previous.isEmpty)
    }

    @Test("종료된 이전 프로세스는 캐시에서 제거한다")
    func exitedProcessIsDiscarded() throws {
        let old = identity(100, 10)
        var previous = [old.pid: old]
        var current: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]

        let related = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &current,
            directRelated: [],
            parents: [:],
            missingInventory: [old.pid: .absent]
        )

        #expect(related.isEmpty)
        #expect(previous.isEmpty)
    }

    @Test("확인할 수 없는 고아 프로세스는 안전하게 거부한다")
    func unknownOrphanFailsClosed() {
        let old = identity(100, 10)
        var previous = [old.pid: old]
        var current: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]

        #expect(throws: AgentSwapError.self) {
            _ = try ClaudeDesktopProcessTracking.reconcile(
                previouslyRelated: &previous,
                currentIdentities: &current,
                directRelated: [],
                parents: [:],
                missingInventory: [old.pid: .unavailable]
            )
        }
    }

    @Test("좀비 프로세스는 Desktop 관련 프로세스로 취급하지 않는다")
    func zombieIdentityIsDiscardedFromCache() throws {
        let old = identity(100, 10)
        var zombie = proc_bsdinfo()
        zombie.pbi_status = UInt32(SZOMB)
        zombie.pbi_start_tvsec = 10
        #expect(ClaudeDesktopProcessTracking.identity(for: old.pid, info: zombie) == nil)

        var previous = [old.pid: old]
        var current: [Int32: ClaudeDesktopConversationProcessIdentity] = [:]
        let related = try ClaudeDesktopProcessTracking.reconcile(
            previouslyRelated: &previous,
            currentIdentities: &current,
            directRelated: [],
            parents: [:],
            missingInventory: [old.pid: .absent]
        )

        #expect(related.isEmpty)
        #expect(previous.isEmpty)
    }

    @Test("좀비 이외 상태는 보수적으로 live identity를 유지한다")
    func nonZombieIdentityRemainsLive() {
        var info = proc_bsdinfo()
        info.pbi_status = 0
        info.pbi_start_tvsec = 2
        info.pbi_start_tvusec = 3

        #expect(ClaudeDesktopProcessTracking.identity(for: 100, info: info) == identity(100, 2_000_003))
    }

    @Test("종료 판정은 ESRCH 또는 확인된 zombie에만 의존한다")
    func exitProofRequiresPositiveEvidence() {
        #expect(ClaudeDesktopProcessTracking.hasExited(pid: 100, killResult: -1, killErrno: ESRCH, confirmedZombie: false))
        #expect(ClaudeDesktopProcessTracking.hasExited(pid: 100, killResult: 0, killErrno: 0, confirmedZombie: true))
        #expect(!ClaudeDesktopProcessTracking.hasExited(pid: 100, killResult: -1, killErrno: EPERM, confirmedZombie: false))
        #expect(!ClaudeDesktopProcessTracking.hasExited(pid: 100, killResult: 0, killErrno: 0, confirmedZombie: false))
        #expect(!ClaudeDesktopProcessTracking.hasExited(pid: 0, killResult: -1, killErrno: ESRCH, confirmedZombie: true))
    }
}
