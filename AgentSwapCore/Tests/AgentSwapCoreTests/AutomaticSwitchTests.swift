import Foundation
import Testing
@testable import AgentSwapCore

@Suite("자동 전환 정책")
struct AutomaticSwitchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func setup() -> (PersistedState, UUID, UUID, UUID) {
        var state = PersistedState()
        let accounts = (0..<3).map { index in
            AccountRecord(identity: .init(provider: .codex, userID: "u\(index)", workspaceID: "w"), createdAt: now.addingTimeInterval(Double(index)), automaticSwitchEligible: true)
        }
        state.accounts = accounts; state.activeAccounts[.codex] = accounts[0].id
        state.settings.automation[.codex]?.enabled = true
        state.usage[accounts[0].id] = cache(95, 40)
        state.usage[accounts[1].id] = cache(20, 50)
        state.usage[accounts[2].id] = cache(40, 60)
        return (state, accounts[0].id, accounts[1].id, accounts[2].id)
    }
    func cache(_ short: Double?, _ long: Double?, fetchedAt: Date? = nil, error: String? = nil) -> UsageCache {
        .init(snapshot: .init(fetchedAt: fetchedAt ?? now, windows: [
            .init(id: "short", title: "5시간", usedPercent: short, resetsAt: now.addingTimeInterval(100)),
            .init(id: "long", title: "주간", usedPercent: long, resetsAt: now.addingTimeInterval(500))
        ]), error: error)
    }
    @Test func defaultsAreDisabled() {
        #expect(PersistedState().settings.automation.values.allSatisfy { !$0.enabled })
    }
    @Test func selectsBestWorstWindow() {
        let (state, _, first, _) = setup()
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .switchTo(first))
    }
    @Test("One known exhausted current window can trigger a guaranteed improvement despite another unknown window")
    func knownThresholdDoesNotRequireEveryCurrentValue() {
        var (state, current, first, _) = setup()
        state.usage[current] = cache(95, nil)
        #expect(state.usage[current]?.snapshot?.minimumRemaining == nil)
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .switchTo(first))
    }
    @Test("The known headroom bound still enforces the full minimum improvement", arguments: [false, true])
    func incompleteCurrentEnforcesMinimumImprovement(inclusive: Bool) {
        var (state, current, first, second) = setup()
        state.accounts.removeAll { $0.id == second }
        state.usage[current] = cache(90, nil)
        state.usage[first] = cache(inclusive ? 85 : 85.1, 20)
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == (inclusive ? .switchTo(first) : .noCandidate))
    }
    @Test("Unknown current values never manufacture a threshold trigger", arguments: [true, false])
    func unknownCurrentDoesNotTrigger(allUnknown: Bool) {
        var (state, current, _, _) = setup()
        state.usage[current] = cache(allUnknown ? nil : 20, nil)
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .keepCurrent)
    }
    @Test("Invalid current percentages remain ineligible", arguments: [-1.0, 101.0, Double.infinity, Double.nan])
    func invalidCurrentValueDoesNotSwitch(value: Double) {
        var (state, current, _, _) = setup(); state.usage[current] = cache(95, value)
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .keepCurrent)
    }
    @Test func tieUsesRegistrationOrder() {
        var (state, _, first, second) = setup(); state.usage[second] = state.usage[first]
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .switchTo(first))
    }
    @Test func equalTimestampsStillUseRegistrationOrder() throws {
        var (state, _, originalFirst, _) = setup()
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        state.accounts[1].id = first; state.accounts[2].id = second
        state.accounts[1].createdAt = now; state.accounts[2].createdAt = now
        state.usage[first] = state.usage[originalFirst]; state.usage[second] = state.usage[originalFirst]
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .switchTo(first))
    }
    @Test(arguments: [false, true]) func thresholdAndMinimumImprovement(inclusive: Bool) {
        var (state, current, first, second) = setup()
        state.usage[current] = cache(90, 30); state.usage[first] = cache(inclusive ? 85 : 85.1, 20)
        state.accounts.removeAll { $0.id == second }
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == (inclusive ? .switchTo(first) : .noCandidate))
    }
    @Test(arguments: [0, 299, 300]) func cooldownBoundary(seconds: Int) {
        var (state, _, first, _) = setup(); state.lastSwitch[.codex] = now.addingTimeInterval(-Double(seconds))
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == (seconds < 300 ? .coolingDown : .switchTo(first)))
    }
    @Test(arguments: ["stale", "failure", "missing", "unchecked", "invalid", "unknownWindow", "exhausted", "reset"])
    func rejectsUnsafeCandidates(reason: String) {
        var (state, _, first, second) = setup(); state.accounts.removeAll { $0.id == second }
        switch reason {
        case "stale": state.usage[first] = cache(20, 30, fetchedAt: now.addingTimeInterval(-661))
        case "failure": state.usage[first] = cache(20, 30, error: "Network")
        case "missing": state.usage[first] = cache(nil, 30)
        case "unchecked": state.accounts[1].automaticSwitchEligible = false
        case "invalid": state.accounts[1].authenticationState = .expired
        case "unknownWindow": state.usage[first]?.snapshot?.windows.append(.init(id: "future", title: "새 공통 한도", usedPercent: nil))
        case "exhausted": state.usage[first] = cache(20, 90)
        case "reset": state.usage[first]?.snapshot?.windows[0].resetsAt = now
        default: break
        }
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .noCandidate)
    }
    @Test func ignoresModelSpecificLimits() {
        var (state, current, _, _) = setup(); state.usage[current] = cache(30, 40)
        state.usage[current]?.snapshot?.windows.append(.init(id: "model", title: "모델", kind: .model, usedPercent: 100))
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .keepCurrent)
    }
    @Test func differentPlansCompareTheirOwnCompleteCommonWindows() {
        var (state, _, first, _) = setup()
        state.usage[first] = .init(snapshot: .init(fetchedAt: now, windows: [
            .init(id: "weekly_only", title: "주간", usedPercent: 15, resetsAt: now.addingTimeInterval(604800))
        ]))
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: state, now: now) == .switchTo(first))
    }
    @Test func clampsRemainingWithoutTreatingMissingAsZero() {
        #expect(UsageWindow(id: "a", title: "", usedPercent: nil).remainingPercent == nil)
        #expect(UsageWindow(id: "a", title: "", usedPercent: 120).remainingPercent == 0)
    }
}
