import Foundation

public enum AutomaticSwitchDecision: Equatable, Sendable {
    case disabled, coolingDown, keepCurrent, noCandidate, switchTo(UUID)
}

public enum AutomaticSwitchPolicy {
    public static func decide(provider: Provider, state: PersistedState, now: Date = Date()) -> AutomaticSwitchDecision {
        let settings = state.settings.automation[provider] ?? .init()
        guard settings.enabled else { return .disabled }
        guard let currentID = state.activeAccounts[provider],
              let current = state.accounts.first(where: { $0.id == currentID }),
              current.authenticationState == .valid,
              let cache = state.usage[currentID], cache.error == nil,
              let usage = cache.snapshot, fresh(usage, now: now, maximumAge: settings.maximumAge),
              usage.commonWindows.allSatisfy({ $0.usedPercent.map { $0.isFinite && (0...100).contains($0) } ?? true }),
              let currentRemainingUpperBound = usage.commonWindows.compactMap(\.usedPercent).map({ 100 - $0 }).min() else { return .keepCurrent }
        if let lastSwitch = state.lastSwitch[provider], now.timeIntervalSince(lastSwitch) < settings.cooldown {
            return .coolingDown
        }
        guard usage.commonWindows.contains(where: { ($0.usedPercent ?? -1) >= settings.threshold }) else { return .keepCurrent }
        let candidates = state.accounts.filter {
            $0.provider == provider && $0.id != currentID && $0.automaticSwitchEligible && $0.authenticationState == .valid
        } // Persisted array order is the registration order, including equal timestamps.
        var bestID: UUID?
        var bestRemaining = -Double.infinity
        for account in candidates {
            guard let candidateCache = state.usage[account.id], candidateCache.error == nil,
                  let candidate = candidateCache.snapshot,
                  fresh(candidate, now: now, maximumAge: settings.maximumAge),
                  candidate.commonWindows.allSatisfy({ window in
                      guard let used = window.usedPercent else { return false }
                      return used.isFinite && used >= 0 && used < settings.threshold
                  }), let remaining = candidate.minimumRemaining,
                  // Missing usage in another current window cannot increase its worst headroom.
                  // Improving the known upper bound by 5 points therefore guarantees the required
                  // improvement without displaying or treating an unknown value as zero.
                  remaining - currentRemainingUpperBound >= settings.minimumImprovement else { continue }
            if remaining > bestRemaining { bestID = account.id; bestRemaining = remaining }
        }
        return bestID.map(AutomaticSwitchDecision.switchTo) ?? .noCandidate
    }
    private static func fresh(_ snapshot: UsageSnapshot, now: Date, maximumAge: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        guard age >= -30 && age <= maximumAge else { return false }
        return !snapshot.commonWindows.contains { window in
            if let reset = window.resetsAt { return reset <= now }
            return false
        }
    }
}
