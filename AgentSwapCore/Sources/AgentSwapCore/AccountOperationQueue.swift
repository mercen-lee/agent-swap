import Foundation

/// Async mutex: serialization spans adapter suspensions. Actor isolation alone does not.
public actor AccountOperationQueue {
    private var occupied: Set<Provider> = []
    private var waiters: [Provider: [CheckedContinuation<Void, Never>]] = [:]
    public init() {}
    public func acquire(_ provider: Provider) async {
        if occupied.insert(provider).inserted { return }
        await withCheckedContinuation { waiters[provider, default: []].append($0) }
    }
    public func release(_ provider: Provider) {
        if var queue = waiters[provider], !queue.isEmpty {
            let next = queue.removeFirst(); waiters[provider] = queue; next.resume()
        } else { occupied.remove(provider) }
    }
}
