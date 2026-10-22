import Foundation
import Testing
@testable import AgentSwapCore

private actor AccountOrderSecrets: SecretStore {
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var deletes = 0
    func load(accountID: UUID) -> Credential? { loads += 1; return nil }
    func save(_ credential: Credential, accountID: UUID) { saves += 1 }
    func delete(accountID: UUID) { deletes += 1 }
    func activity() -> [Int] { [loads, saves, deletes] }
}

private actor AccountOrderState: StateStore {
    private(set) var value: PersistedState
    private(set) var saveAttempts = 0
    private var refusesSave = false
    init(_ value: PersistedState) { self.value = value }
    func load() -> PersistedState { value }
    func save(_ state: PersistedState) throws {
        saveAttempts += 1
        guard !refusesSave else { throw AgentSwapError.storage("Fixture metadata save failure") }
        value = state
    }
    func refuseSaving() { refusesSave = true }
}

@Suite("계정 표시 순서")
@MainActor
struct AccountOrderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> PersistedState {
        var state = PersistedState()
        state.accounts = [Provider.claude, .codex, .claude, .codex, .claude].enumerated().map { index, provider in
            AccountRecord(identity: .init(provider: provider, userID: "fixture-order-user-\(index)", workspaceID: "fixture-order-workspace"),
                          nickname: "합성 계정 \(index)", createdAt: now.addingTimeInterval(Double(index)), automaticSwitchEligible: true)
        }
        state.activeAccounts = [.claude: state.accounts[0].id, .codex: state.accounts[1].id]
        state.lastSwitch = [.claude: now, .codex: now]
        state.pendingNativeRefreshPredecessor = [state.accounts[0].id: String(repeating: "a", count: 64)]
        state.requiresExplicitCredentialApplication = [state.accounts[2].id]
        state.usage[state.accounts[0].id] = .init(snapshot: .init(fetchedAt: now, windows: [
            .init(id: "five_hour", title: "5시간", usedPercent: 23)
        ]))
        return state
    }

    private func model(_ state: PersistedState) async -> (AppModel, AccountOrderState, AccountOrderSecrets) {
        let store = AccountOrderState(state), secrets = AccountOrderSecrets()
        let model = AppModel(adapters: [], secrets: secrets, store: store)
        await model.start()
        model.stop()
        return (model, store, secrets)
    }

    @Test("Legacy state without display order preserves registration order")
    func legacyState() async throws {
        let initial = fixture()
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        document.removeValue(forKey: "accountDisplayOrder")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: document))
        let (model, _, secrets) = await model(decoded)
        #expect(decoded.accountDisplayOrder == nil)
        #expect(model.displayAccounts == initial.accounts)
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("Duplicate and deleted IDs are ignored while unlisted accounts append in registration order")
    func normalizedDisplayOrder() async {
        var initial = fixture()
        let ids = initial.accounts.map(\.id)
        initial.accountDisplayOrder = [ids[3], UUID(), ids[3], ids[0]]
        let (model, _, secrets) = await model(initial)
        #expect(model.displayAccounts.map(\.id) == [ids[3], ids[0], ids[1], ids[2], ids[4]])
        #expect(model.state.accounts == initial.accounts)
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("Moving multiple rows saves presentation order without touching authentication or registration metadata")
    func multipleRowsAndReload() async throws {
        let initial = fixture()
        let ids = initial.accounts.map(\.id)
        let (model, store, secrets) = await model(initial)
        await model.moveAccounts(fromOffsets: IndexSet([1, 3]), toOffset: 5, visibleAccountIDs: ids)
        var expected = initial
        expected.accountDisplayOrder = [ids[0], ids[2], ids[4], ids[1], ids[3]]
        #expect(model.state == expected)
        #expect(await store.value == expected)
        #expect(await secrets.activity() == [0, 0, 0])
        let encoded = try JSONEncoder().encode(await store.value)
        let (reloaded, _, _) = await self.model(try JSONDecoder().decode(PersistedState.self, from: encoded))
        #expect(reloaded.displayAccounts.map(\.id) == expected.accountDisplayOrder)
        #expect(reloaded.state.accounts == initial.accounts)
    }

    @Test("Filtered moves retain every other provider or search-hidden account in its original slot", arguments: ["provider", "search"])
    func filteredSubset(_ filter: String) async {
        let initial = fixture()
        let ids = initial.accounts.map(\.id)
        let visible = filter == "provider" ? [ids[0], ids[2], ids[4]] : [ids[0], ids[4]]
        let expected = filter == "provider" ? [ids[2], ids[1], ids[4], ids[3], ids[0]] : [ids[4], ids[1], ids[2], ids[3], ids[0]]
        let (model, _, secrets) = await model(initial)
        await model.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: visible.count, visibleAccountIDs: visible)
        #expect(model.displayAccounts.map(\.id) == expected)
        #expect(model.state.accounts == initial.accounts)
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("Stale snapshots, invalid offsets and unchanged positions never mutate or save order", arguments: [
        "staleSequence", "missingID", "duplicateID", "sourceBounds", "negativeDestination", "destinationBounds", "emptySource", "samePosition", "sameSlot"
    ])
    func invalidOrUnchangedMove(_ mode: String) async {
        let initial = fixture()
        let ids = initial.accounts.map(\.id)
        var visible = ids, source = IndexSet(integer: 0), destination = 2
        switch mode {
        case "staleSequence": visible.swapAt(1, 2)
        case "missingID": visible[2] = UUID()
        case "duplicateID": visible[2] = visible[0]
        case "sourceBounds": source = IndexSet([0, ids.count])
        case "negativeDestination": destination = -1
        case "destinationBounds": destination = ids.count + 1
        case "emptySource": source = []
        case "samePosition": destination = 0
        default: destination = 1
        }
        let (model, store, secrets) = await model(initial)
        let savedBefore = await store.saveAttempts
        await model.moveAccounts(fromOffsets: source, toOffset: destination, visibleAccountIDs: visible)
        #expect(model.state == initial)
        #expect(await store.value == initial)
        #expect(await store.saveAttempts == savedBefore)
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("Account deletion removes its presentation ID while keeping the remaining order")
    func deletedAccountOrder() async {
        var initial = fixture()
        let ids = initial.accounts.map(\.id)
        initial.accountDisplayOrder = [ids[4], ids[0], ids[3], ids[1], ids[2]]
        let (model, store, secrets) = await model(initial)
        await model.deleteAccount(ids[0])
        #expect(model.displayAccounts.map(\.id) == [ids[4], ids[3], ids[1], ids[2]])
        #expect(model.state.accountDisplayOrder == [ids[4], ids[3], ids[1], ids[2]])
        #expect(await store.value == model.state)
        #expect(await secrets.activity() == [0, 0, 1])
    }

    @Test("Presentation order never changes registration-order automatic-switch ties")
    func automaticSwitchTies() async {
        var initial = PersistedState()
        initial.accounts = (0..<3).map { index in
            AccountRecord(identity: .init(provider: .codex, userID: "fixture-tie-user-\(index)", workspaceID: "fixture-tie-workspace"),
                          createdAt: now, automaticSwitchEligible: true)
        }
        let ids = initial.accounts.map(\.id)
        initial.activeAccounts[.codex] = ids[0]
        initial.settings.automation[.codex]?.enabled = true
        for (index, id) in ids.enumerated() {
            initial.usage[id] = .init(snapshot: .init(fetchedAt: now, windows: [
                .init(id: "five_hour", title: "5시간", usedPercent: index == 0 ? 95 : 20, resetsAt: now.addingTimeInterval(3600))
            ]))
        }
        let (model, _, secrets) = await model(initial)
        await model.moveAccounts(fromOffsets: IndexSet(integer: 2), toOffset: 1, visibleAccountIDs: ids)
        #expect(model.displayAccounts.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(model.state.accounts == initial.accounts)
        #expect(AutomaticSwitchPolicy.decide(provider: .codex, state: model.state, now: now) == .switchTo(ids[1]))
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("A metadata save failure blocks subsequent reorders")
    func storageFailureStopsChanges() async {
        let (model, store, secrets) = await model(fixture())
        await store.refuseSaving()
        let ids = model.displayAccounts.map(\.id)
        await model.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: ids.count, visibleAccountIDs: ids)
        let afterFailure = model.state
        let attempts = await store.saveAttempts
        await model.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: ids.count, visibleAccountIDs: model.displayAccounts.map(\.id))
        #expect(model.state == afterFailure)
        #expect(await store.saveAttempts == attempts)
        #expect(await secrets.activity() == [0, 0, 0])
    }

    @Test("Termination prevents order changes and extra persistence")
    func terminationStopsChanges() async {
        let (model, store, secrets) = await model(fixture())
        #expect(await model.prepareForTermination())
        let before = model.state
        let attempts = await store.saveAttempts
        await model.moveAccounts(fromOffsets: IndexSet(integer: 0), toOffset: before.accounts.count, visibleAccountIDs: before.accounts.map(\.id))
        #expect(model.state == before)
        #expect(await store.saveAttempts == attempts)
        #expect(await secrets.activity() == [0, 0, 0])
    }
}
