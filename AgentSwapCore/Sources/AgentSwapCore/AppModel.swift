import Foundation
import Observation
import CryptoKit

@MainActor @Observable
public final class AppModel {
    public let claudeDesktopProfiles: ClaudeDesktopProfileModel
    public private(set) var state = PersistedState()
    public private(set) var compatibility: [Provider: CompatibilityStatus] = [:]
    public private(set) var isBusy = false
    public var message: String?
    public private(set) var pendingSwitch: [Provider: UUID] = [:]
    public private(set) var attentionProviders: Set<Provider> = []
    public private(set) var isLoggingIn = false
    public private(set) var loggingInProvider: Provider?
    public private(set) var loginStatus: String?
    public private(set) var isSubmittingLoginCode = false
    public private(set) var canOpenLoginPage = false
    public private(set) var isOpeningLoginPage = false
    /// A legacy Desktop-session transaction exists and requires an explicit recovery action.
    /// Normal authentication switches never inspect or modify Desktop conversation records.
    public private(set) var claudeSessionRecoveryRequired = false
    public private(set) var claudeDesktopRecoveryRequired = false

    /// UI and the engine share the lifecycle/storage blockers; a rejected operation must be explainable.
    public var switchOperationBlockReason: String? {
        if isPreparingForTermination { return "갱신된 인증을 저장하고 종료하는 중입니다." }
        if !storageHealthy { return "저장 오류로 계정 변경을 중단했습니다. 앱을 다시 실행해 주세요." }
        if isStarting { return "현재 로그인과 전환 호환성을 확인하고 있습니다." }
        if isBusy { return "다른 작업이 진행 중입니다. 완료 후 전환하세요." }
        return nil
    }

    @ObservationIgnored private let adapters: [Provider: any ProviderAdapter]
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let store: any StateStore
    @ObservationIgnored private let operations = AccountOperationQueue()
    @ObservationIgnored private let claudeSessions: (any ClaudeDesktopSessionPreserving)?
    @ObservationIgnored private let claudeDesktop: (any ClaudeDesktopAccountManaging)?
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginGeneration: UUID?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var busyCount = 0
    @ObservationIgnored private var storageHealthy = true
    @ObservationIgnored private var lastNotices: [Provider: Date] = [:]
    @ObservationIgnored private var pendingCredentialWrites: [UUID: Credential] = [:]
    @ObservationIgnored private var pendingCredentialGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private var retainedNativeGenerations: [UUID: (before: String, after: String)] = [:]
    @ObservationIgnored private var pendingGenerationMarkerWrites: [UUID: String] = [:]
    @ObservationIgnored private var isPreparingForTermination = false
    @ObservationIgnored private var operationWaiters: [(limit: Int, continuation: CheckedContinuation<Void, Never>)] = []
    public init(adapters: [any ProviderAdapter], secrets: any SecretStore, store: any StateStore,
                claudeSessions: (any ClaudeDesktopSessionPreserving)? = nil,
                claudeDesktop: (any ClaudeDesktopAccountManaging)? = nil,
                claudeDesktopProfiles: ClaudeDesktopProfileModel? = nil) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        self.secrets = secrets; self.store = store; self.claudeSessions = claudeSessions; self.claudeDesktop = claudeDesktop
        self.claudeDesktopProfiles = claudeDesktopProfiles ?? .preview()
        self.claudeDesktopProfiles.connectOperationQueue(operations) {
            try await claudeSessions?.verifyCanOpenDesktop()
            try await claudeDesktop?.verifyCanSwitchCLI(allowing: nil)
        }
    }

    deinit { scheduler?.cancel(); loginTask?.cancel() }

    public func start() async {
        guard !isPreparingForTermination else { return }
        await KeychainInteraction.$mode.withValue(.noninteractive) { await startWithCurrentInteraction() }
    }
    private func startWithCurrentInteraction() async {
        guard !started, !isPreparingForTermination else { return }; started = true; isStarting = true; beginOperation()
        await claudeDesktopProfiles.load()
        do { state = try await store.load() }
        catch { storageHealthy = false; message = "저장 데이터를 읽지 못했습니다. 원본을 보존합니다: \(error.localizedDescription)" }
        for provider in Provider.allCases {
            guard let adapter = adapters[provider] else { continue }
            await operations.acquire(provider)
            compatibility[provider] = await adapter.compatibility()
            // Detect external CLI account changes without implicitly adding accounts.
            do {
                try await flushPendingCredentials(provider)
                let imported = try await adapter.importCurrent()
                if let id = state.accounts.first(where: { $0.identity == imported.account.identity })?.id {
                    do {
                        _ = try await reconcileNative(imported, accountID: id)
                        if let index = state.accounts.firstIndex(where: { $0.id == id }) { state.accounts[index].authenticationState = .valid }
                        state.activeAccounts[provider] = id
                    } catch { message = error.localizedDescription }
                } else { state.activeAccounts.removeValue(forKey: provider) }
            } catch {
                // Missing permission is not evidence that a cached active account logged out.
                if let error = error as? AgentSwapError, case .authentication = error {
                    state.activeAccounts.removeValue(forKey: provider)
                    if state.accounts.contains(where: { $0.provider == provider }) { message = error.localizedDescription }
                } else { message = error.localizedDescription }
            }
            if provider == .claude, storageHealthy, let claudeDesktop {
                do {
                    try await claudeDesktop.verifyCanSwitchCLI(allowing: nil)
                    claudeDesktopRecoveryRequired = false
                } catch {
                    claudeDesktopRecoveryRequired = true
                    message = error.localizedDescription
                }
            }
            await operations.release(provider)
        }
        await persist()
        isStarting = false; busyCount -= 1; isBusy = busyCount > 0; resumeOperationWaiters()
        startScheduler()
    }
    private func startScheduler() {
        guard started, scheduler == nil, !isPreparingForTermination else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
    public func stop() { scheduler?.cancel(); scheduler = nil }

    public func refreshAll() async {
        await refreshDue(force: true)
    }
    /// Explicitly retries provider-store access without changing credentials or invoking a switch.
    public func recheckCompatibility(_ provider: Provider) async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard !self.isStarting, !self.isPreparingForTermination, let adapter = self.adapters[provider] else { return }
            await self.operations.acquire(provider); self.beginOperation()
            guard !self.isPreparingForTermination else { await self.finishOperation(provider); return }
            self.compatibility[provider] = await adapter.compatibility()
            self.message = self.compatibility[provider]?.message
            await self.finishOperation(provider)
        }
    }
    @discardableResult
    public func authorizeSavedCredential(_ id: UUID) async -> Bool {
        guard !isStarting, !isPreparingForTermination, let account = state.accounts.first(where: { $0.id == id }) else { return false }
        await operations.acquire(account.provider)
        beginOperation()
        guard !isPreparingForTermination, state.accounts.contains(where: { $0.id == id && $0.identity == account.identity }) else {
            await finishOperation(account.provider)
            return false
        }
        var approved = false
        do {
            try Task.checkCancellation()
            let exists = try await KeychainInteraction.$mode.withValue(.interactive) {
                try await secrets.load(accountID: id) != nil
            }
            guard exists else { throw AgentSwapError.authentication("저장된 인증이 없습니다. 이 계정에 다시 로그인해 주세요.") }
            approved = true
            if !storageHealthy {
                message = "저장된 인증에 접근할 수 있습니다. 저장 데이터 오류로 조회는 중단된 상태입니다. 앱을 다시 실행해 주세요."
            } else if var cache = state.usage[id], cache.retryReason == .localFailure {
                // Access approval concerns only this vault entry. It must not forgive
                // a provider's rate limit or infer the cause of a legacy retry delay.
                cache.retryAfter = nil; cache.retryReason = nil; cache.attemptedAt = nil
                state.usage[id] = cache
                message = "저장된 인증에 접근할 수 있습니다. 이 계정의 저장소 오류 재시도 대기를 해제했습니다. 새로고침하거나 다음 조회를 기다려 주세요."
                await persist()
            } else if let cache = state.usage[id], let retry = cache.retryAfter, retry > Date() {
                if cache.retryReason == .serverRateLimit {
                    message = "저장된 인증에 접근할 수 있습니다. 서버가 지정한 재시도 시각까지 조회를 기다립니다."
                } else {
                    message = "저장된 인증에 접근할 수 있습니다. 기존 재시도 대기는 유지합니다. 재시도 시각 이후 다시 조회해 주세요."
                }
            } else {
                message = "저장된 인증에 접근할 수 있습니다. 새로고침하거나 다음 조회를 기다려 주세요."
            }
        } catch is CancellationError {
            message = "저장된 인증 접근 확인을 취소했습니다."
        } catch { message = error.localizedDescription }
        await finishOperation(account.provider)
        return approved
    }
    public func refreshDue(force: Bool = false, now: Date = Date()) async {
        await KeychainInteraction.$mode.withValue(.noninteractive) { await refreshDueWithCurrentInteraction(force: force, now: now) }
    }
    private func refreshDueWithCurrentInteraction(force: Bool, now: Date) async {
        guard storageHealthy, !isPreparingForTermination else { return }
        for account in state.accounts {
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            let cache = state.usage[account.id] ?? .init()
            if let retry = cache.retryAfter, retry > now { continue }
            let interval = state.activeAccounts[account.provider] == account.id ? state.settings.activePollInterval : state.settings.inactivePollInterval
            if !force, let attempted = cache.attemptedAt, now.timeIntervalSince(attempted) < interval { continue }
            await refreshAccount(account.id, now: now)
        }
        for provider in Provider.allCases { await evaluateAutomaticSwitch(provider, now: now) }
    }
    private func refreshAccount(_ id: UUID, now: Date) async {
        guard let account = state.accounts.first(where: { $0.id == id }), let adapter = adapters[account.provider] else { return }
        await operations.acquire(account.provider)
        beginOperation()
        if Task.isCancelled || isPreparingForTermination { await finishOperation(account.provider); return }
        var cache = state.usage[id] ?? .init(); cache.attemptedAt = now
        do {
            try await flushPendingCredentials(account.provider)
            guard var credential = try await secrets.load(accountID: id) else { throw AgentSwapError.authentication("저장된 인증이 없습니다. 다시 로그인해 주세요.") }
            var isActive = state.activeAccounts[account.provider] == id
            let running = await adapter.hasRunningConsumers()
            var nativeIdentityUnknown = false
            // The native login can change independently of the cached active account. In
            // particular, a registered Codex account must not rotate a grant now owned by
            // a running consumer just because its account row is encountered first.
            if isActive || account.provider == .codex {
                let imported: ImportedAccount?
                do { imported = try await adapter.importCurrentIfPresent() }
                catch {
                    if account.provider == .codex {
                        throw AgentSwapError.storage("현재 Codex 인증을 확인하지 못해 토큰 갱신을 보류했습니다. \(error.localizedDescription)")
                    }
                    throw error
                }
                if let imported, imported.account.identity == account.identity {
                    credential = try await reconcileNative(imported, accountID: id)
                    state.activeAccounts[account.provider] = id
                    isActive = true
                } else if let imported {
                    let actualID = state.accounts.first(where: { $0.identity == imported.account.identity })?.id
                    state.activeAccounts[account.provider] = actualID
                    if let actualID { _ = try await reconcileNative(imported, accountID: actualID) }
                    isActive = false
                } else {
                    state.activeAccounts.removeValue(forKey: account.provider)
                    isActive = false
                    // A live process can still hold a grant after its native entry was
                    // removed. Usage reads remain possible; refreshing it is not safe.
                    nativeIdentityUnknown = true
                }
            }
            let consumersRunning = account.provider == .codex && running && (isActive || nativeIdentityUnknown)
            if isActive, account.provider == .claude || !running, state.pendingNativeRefreshPredecessor?[id] != nil {
                let result = await applyToConfirmedCurrent(credential, account: account, adapter: adapter)
                guard case .applied = result else { throw AgentSwapError.storage("저장된 새 \(account.provider.title) 인증의 적용을 기다립니다. 현재 계정을 확인한 뒤 다시 전환해 주세요.") }
                clearPendingRefresh(id)
            }
            if consumersRunning {
                // Codex owns rotation while consumers are running; the latest token was re-collected above.
            } else if credential.expiresAt.map({ $0.timeIntervalSince(now) < 120 }) ?? false {
                try await markNativeRefreshIfNeeded(credential, account: account, isActive: isActive)
                let predecessor = credential
                credential = try await adapter.refresh(credential, account: account)
                // Save rotation before the next API call, including calls which can fail.
                try await saveRotatedCredential(credential, predecessor: predecessor, accountID: id)
                if isActive && account.provider == .codex {
                    let result = await applyToConfirmedCurrent(credential, account: account, adapter: adapter)
                    if case .failed(let reason) = result { throw AgentSwapError.storage(reason) }
                    if case .pendingRelaunch(let reason) = result { pendingSwitch[.codex] = id; throw AgentSwapError.storage("새 토큰을 저장했지만 현재 Codex 인증 적용을 기다립니다: \(reason)") }
                    clearPendingRefresh(id)
                }
            }
            var snapshot: UsageSnapshot
            do { snapshot = try await adapter.fetchUsage(credential, account: account) }
            catch let error as AgentSwapError {
                if case .authentication = error, consumersRunning {
                    snapshot = try await retryConsumerOwnedUsage(credential, account: account, adapter: adapter)
                } else if case .authentication = error {
                    try await markNativeRefreshIfNeeded(credential, account: account, isActive: isActive)
                    let predecessor = credential
                    credential = try await adapter.refresh(credential, account: account)
                    try await saveRotatedCredential(credential, predecessor: predecessor, accountID: id)
                    if isActive && account.provider == .codex {
                        let result = await applyToConfirmedCurrent(credential, account: account, adapter: adapter)
                        if case .failed(let reason) = result { throw AgentSwapError.storage(reason) }
                        if case .pendingRelaunch(let reason) = result { pendingSwitch[.codex] = id; throw AgentSwapError.storage("새 토큰을 저장했지만 현재 Codex 인증 적용을 기다립니다: \(reason)") }
                        clearPendingRefresh(id)
                    }
                    snapshot = try await adapter.fetchUsage(credential, account: account)
                } else { throw error }
            }
            snapshot.fetchedAt = Date(); cache.snapshot = snapshot; cache.error = nil; cache.retryAfter = nil; cache.retryReason = nil
            if let index = state.accounts.firstIndex(where: { $0.id == id }) {
                state.accounts[index].authenticationState = .valid
                if let plan = snapshot.plan { state.accounts[index].plan = plan }
            }
        } catch {
            cache.error = error.localizedDescription
            if let typed = error as? AgentSwapError {
                switch typed {
                case .rateLimited(let retry): cache.retryAfter = retry; cache.retryReason = .serverRateLimit
                case .authentication:
                    cache.retryAfter = nil; cache.retryReason = nil
                    if let index = state.accounts.firstIndex(where: { $0.id == id }) { state.accounts[index].authenticationState = .needsLogin }
                case .storage: cache.retryAfter = now.addingTimeInterval(60); cache.retryReason = .localFailure
                default: cache.retryAfter = now.addingTimeInterval(60); cache.retryReason = .transientFailure
                }
            } else { cache.retryAfter = now.addingTimeInterval(60); cache.retryReason = .transientFailure }
        }
        if state.accounts.contains(where: { $0.id == id }) { state.usage[id] = cache }
        // A successful retry or failed native update can change write compatibility. Do not
        // leave all target accounts blocked by an obsolete startup inspection.
        compatibility[account.provider] = await adapter.compatibility()
        await persist(); await finishOperation(account.provider)
    }

    private func retryConsumerOwnedUsage(_ credential: Credential, account: AccountRecord,
                                         adapter: any ProviderAdapter) async throws -> UsageSnapshot {
        let current: ImportedAccount?
        do { current = try await adapter.importCurrentIfPresent() }
        catch { throw AgentSwapError.storage("Codex가 관리하는 최신 인증을 확인하지 못했습니다. 마지막 정상 사용량을 유지합니다. \(error.localizedDescription)") }
        let actualID = current.flatMap { native in state.accounts.first(where: { $0.identity == native.account.identity })?.id }
        state.activeAccounts[account.provider] = actualID
        let retryMessage = "Codex가 실행 중인 인증을 갱신할 때까지 사용량 조회를 기다립니다. 마지막 정상 값을 유지합니다."
        guard let current else { throw AgentSwapError.network(retryMessage) }
        guard current.account.identity == account.identity else {
            if let actualID { _ = try await reconcileNative(current, accountID: actualID) }
            throw AgentSwapError.network("현재 Codex 계정이 변경되었습니다. 다음 조회에서 최신 인증을 확인합니다.")
        }
        let latest = try await reconcileNative(current, accountID: account.id)
        guard latest.accessToken != credential.accessToken else { throw AgentSwapError.network(retryMessage) }
        do { return try await adapter.fetchUsage(latest, account: account) }
        catch let error as AgentSwapError {
            if case .authentication = error { throw AgentSwapError.network(retryMessage) }
            throw error
        }
    }

    public func importCurrent(_ provider: Provider) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await importCurrentWithInteraction(provider) }
    }
    private func importCurrentWithInteraction(_ provider: Provider) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let adapter = adapters[provider] else { return }
        await operations.acquire(provider); beginOperation()
        guard !isPreparingForTermination else { await finishOperation(provider); return }
        do {
            try await flushPendingCredentials(provider)
            let imported = try await adapter.importCurrent()
            let id = try await upsert(imported, acceptExternalNative: true)
            state.activeAccounts[provider] = id
            message = "현재 \(provider.title) 계정을 가져왔습니다."
            await persist()
        } catch { message = error.localizedDescription }
        compatibility[provider] = await adapter.compatibility()
        await finishOperation(provider)
        await refreshDue(force: true)
    }
    public func login(_ provider: Provider) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await loginWithInteraction(provider) }
    }
    private func loginWithInteraction(_ provider: Provider) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, !isLoggingIn, let adapter = adapters[provider] else { return }
        isLoggingIn = true; loggingInProvider = provider
        let generation = UUID(); loginGeneration = generation
        canOpenLoginPage = false; isOpeningLoginPage = false
        loginStatus = "브라우저에서 \(provider.title) 로그인을 완료해 주세요. 기존 계정과 분리된 임시 프로필을 사용합니다."
        loginTask = Task { [weak self] in
            guard let self else { return }
            await self.operations.acquire(provider); self.beginOperation()
            let pageMonitor = Task { [weak self] in
                guard self?.isLoggingIn == true else { return }
                while !Task.isCancelled {
                    let available = await adapter.canOpenLoginPage()
                    guard !Task.isCancelled, let self, self.isLoggingIn, self.loggingInProvider == provider else { return }
                    self.canOpenLoginPage = available
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
            do {
                try Task.checkCancellation()
                guard !self.isPreparingForTermination else { throw CancellationError() }
                let imported = try await adapter.login()
                try Task.checkCancellation()
                let id = try await self.upsert(imported, origin: .isolated)
                self.message = "\(provider.title) 계정을 등록했습니다."
                await self.persist()
                try Task.checkCancellation()
                if self.storageHealthy, self.state.pendingNativeRefreshPredecessor?[id] != nil,
                   let account = self.state.accounts.first(where: { $0.id == id }),
                   let current = try? await adapter.importCurrent(), current.account.identity == account.identity {
                    let credential = try await self.secrets.load(accountID: id) ?? imported.credential
                    let result = await self.applyToConfirmedCurrent(credential, account: account, adapter: adapter)
                    if case .applied(let text) = result { self.clearPendingRefresh(id); self.message = text }
                    else {
                        self.pendingSwitch[provider] = id
                        switch result {
                        case .pendingRelaunch(let text), .failed(let text): self.message = "새 인증을 저장했습니다. \(text)"
                        case .applied: break
                        }
                    }
                    await self.persist()
                }
            } catch { self.message = error.localizedDescription }
            pageMonitor.cancel()
            await pageMonitor.value
            self.compatibility[provider] = await adapter.compatibility()
            self.canOpenLoginPage = false; self.isOpeningLoginPage = false
            if self.loginGeneration == generation { self.loginGeneration = nil }
            self.isLoggingIn = false; self.loggingInProvider = nil; self.loginStatus = nil; self.loginTask = nil
            await self.finishOperation(provider)
            await self.refreshDue(force: true)
        }
    }
    public func openLoginPage() async {
        guard !isPreparingForTermination, isLoggingIn, canOpenLoginPage, !isOpeningLoginPage,
              let generation = loginGeneration, let provider = loggingInProvider, let adapter = adapters[provider] else { return }
        isOpeningLoginPage = true
        defer { if loginGeneration == generation { isOpeningLoginPage = false } }
        do { try await adapter.openLoginPage() }
        catch { if loginGeneration == generation { message = error.localizedDescription } }
    }
    public func cancelLogin() async {
        await KeychainInteraction.$mode.withValue(.interactive) { await cancelLoginWithInteraction() }
    }
    private func cancelLoginWithInteraction() async {
        let task = loginTask
        task?.cancel()
        if let provider = loggingInProvider { await adapters[provider]?.cancelLogin() }
        await task?.value
    }
    public func submitLoginCode(_ code: String) async {
        guard !isPreparingForTermination, isLoggingIn, !isSubmittingLoginCode, let provider = loggingInProvider, let adapter = adapters[provider] else {
            message = "진행 중인 로그인에서 인증 코드를 제출해 주세요."
            return
        }
        isSubmittingLoginCode = true
        defer { isSubmittingLoginCode = false }
        do {
            // Login owns the provider operation queue. The input bridge must remain reentrant.
            try await adapter.submitLoginCode(code)
            loginStatus = "인증 코드를 전달했습니다. 로그인이 완료될 때까지 기다려 주세요."
        } catch { loginStatus = error.localizedDescription }
    }
    private enum AccountImportOrigin { case native, isolated }
    private func upsert(_ imported: ImportedAccount, origin: AccountImportOrigin = .native, acceptExternalNative: Bool = false) async throws -> UUID {
        if let index = state.accounts.firstIndex(where: { $0.identity == imported.account.identity }) {
            let old = state.accounts[index]
            if origin == .isolated {
                // A fresh GUI login is independent auth, not a native token rotation. Confirm
                // the actual active identity before scheduling same-account application.
                if let adapter = adapters[old.provider], let current = try? await adapter.importCurrent() {
                    if current.account.identity == old.identity {
                        try await markNativePredecessor(current.credential, accountID: old.id)
                        state.activeAccounts[old.provider] = old.id
                    } else {
                        state.activeAccounts[old.provider] = state.accounts.first(where: { $0.identity == current.account.identity })?.id
                    }
                }
                try await secrets.save(imported.credential, accountID: old.id)
                await adapters[old.provider]?.discardPendingCredentialPersistence(accountID: old.id)
                discardRetainedCredential(old.id)
            } else if state.pendingNativeRefreshPredecessor?[old.id] != nil {
                _ = try await reconcileNative(imported, accountID: old.id, acceptExternalNative: acceptExternalNative)
            } else { _ = try await reconcileNative(imported, accountID: old.id, acceptExternalNative: acceptExternalNative) }
            // Other providers and preference edits can mutate the array while auth I/O suspends.
            guard let latestIndex = state.accounts.firstIndex(where: { $0.id == old.id }) else {
                throw AgentSwapError.storage("등록 중 계정이 변경되었습니다. 다시 등록해 주세요.")
            }
            let latest = state.accounts[latestIndex]
            var updated = imported.account; updated.id = old.id; updated.createdAt = latest.createdAt
            updated.nickname = latest.nickname; updated.automaticSwitchEligible = latest.automaticSwitchEligible
            state.accounts[latestIndex] = updated
            return old.id
        }
        try await secrets.save(imported.credential, accountID: imported.account.id)
        state.accounts.append(imported.account)
        return imported.account.id
    }
    public func switchAccount(_ id: UUID, relaunch: Bool = false) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await switchAccountWithCurrentInteraction(id, relaunch: relaunch) }
    }
    @discardableResult
    private func switchAccountWithCurrentInteraction(_ id: UUID, relaunch: Bool, queueAlreadyHeld: Bool = false,
                                                     desktopPreparation: UUID? = nil) async -> Bool {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let account = state.accounts.first(where: { $0.id == id }), let adapter = adapters[account.provider] else { return false }
        if !queueAlreadyHeld { await operations.acquire(account.provider); beginOperation() }
        guard !isPreparingForTermination else {
            if !queueAlreadyHeld { await finishOperation(account.provider) }
            return false
        }
        var applied = false
        do {
            try Task.checkCancellation()
            try await flushPendingCredentials(account.provider)
            guard var credential = try await secrets.load(accountID: id) else { throw AgentSwapError.authentication("저장된 인증이 없습니다.") }
            let status = await adapter.compatibility(); compatibility[account.provider] = status
            guard status.canWrite else { throw AgentSwapError.unsupported(status.message) }
            let running = await adapter.hasRunningConsumers()
            let current: ImportedAccount?
            current = try await adapter.importCurrentIfPresent()
            if account.provider == .claude {
                try await verifyClaudeSessionSwitchBoundary(source: current?.account, target: account, desktopPreparation: desktopPreparation)
                try validateClaudeSwitchState(account)
            }
            if let current {
                // The CLI can switch outside AgentSwap between polls. Only the newly read
                // identity determines which running consumer owns its one-time refresh grant.
                state.activeAccounts[account.provider] = state.accounts.first(where: { $0.identity == current.account.identity })?.id
            }
            let isActive = current?.account.identity == account.identity
            // An absent native store cannot prove that a saved target is inactive in a
            // running consumer's memory. Leave its grant to Codex; activation still verifies
            // graceful termination, the latest backup, and the exact native generation.
            let activeAndRunning = account.provider == .codex && running && (current == nil || isActive)
            if let current, current.account.identity == account.identity {
                credential = try await reconcileNative(current, accountID: id)
            }
            if !activeAndRunning, credential.expiresAt.map({ $0.timeIntervalSinceNow < 120 }) ?? false {
                try await markNativeRefreshIfNeeded(credential, account: account, isActive: state.activeAccounts[account.provider] == id)
                let predecessor = credential
                credential = try await adapter.refresh(credential, account: account)
                try await saveRotatedCredential(credential, predecessor: predecessor, accountID: id)
            }
            if account.provider == .claude {
                try await verifyClaudeSessionSwitchBoundary(source: current?.account, target: account, desktopPreparation: desktopPreparation)
                try validateClaudeSwitchState(account)
            }
            let expectedSourceIdentity = account.provider == .claude ? current?.account.identity : nil
            let result = await adapter.activatePreservingSource(credential, account: account, relaunch: relaunch,
                                                                allowMissingSource: current == nil) { [weak self] current in
                try Task.checkCancellation()
                if let expectedSourceIdentity, current.account.identity != expectedSourceIdentity {
                    guard let self else { throw CancellationError() }
                    try await self.rejectChangedClaudeSource(current)
                }
                try await self?.saveLatestSource(current)
                try Task.checkCancellation()
                if account.provider == .claude {
                    try await self?.verifyClaudeSessionSwitchBoundary(source: current.account, target: account, desktopPreparation: desktopPreparation)
                    guard let self else { throw CancellationError() }
                    try await self.validateClaudeSwitchState(account)
                }
            }
            switch result {
            case .applied(let text):
                applied = true
                clearPendingRefresh(id)
                attentionProviders.remove(account.provider)
                state.activeAccounts[account.provider] = id; state.lastSwitch[account.provider] = Date()
                pendingSwitch.removeValue(forKey: account.provider); message = text
                if account.provider == .claude {
                    message = "CLI 계정을 전환했습니다. 기존 대화 파일과 목록은 변경하지 않았습니다. Claude 데스크톱 로그인은 별도로 전환해 주세요."
                }
            case .pendingRelaunch(let text): pendingSwitch[account.provider] = id; attentionProviders.insert(account.provider); message = text
            case .failed(let text): attentionProviders.insert(account.provider); message = text
            }
            await persist()
        } catch { message = error.localizedDescription }
        if !queueAlreadyHeld { await finishOperation(account.provider) }
        return applied
    }
    /// Blocks authentication writes while an older Desktop-session transaction is unresolved.
    /// It intentionally examines only the AgentSwap recovery journal, not Desktop conversations.
    private func verifyClaudeSessionSwitchBoundary(source: AccountRecord?, target: AccountRecord, desktopPreparation: UUID? = nil) async throws {
        if let claudeSessions {
            do {
                try await claudeSessions.verifyCanSwitchWithoutPreservingSessions(source: source, target: target)
                claudeSessionRecoveryRequired = false
            } catch is CancellationError { throw CancellationError() }
            catch { claudeSessionRecoveryRequired = true; throw error }
        }
        if let claudeDesktop {
            do {
                try await claudeDesktop.verifyCanSwitchCLI(allowing: desktopPreparation)
                claudeDesktopRecoveryRequired = false
            } catch is CancellationError { throw CancellationError() }
            catch { claudeDesktopRecoveryRequired = true; throw error }
        }
    }
    private func validateClaudeSwitchState(_ account: AccountRecord) throws {
        try Task.checkCancellation()
        guard storageHealthy, !isPreparingForTermination,
              state.accounts.contains(where: { $0.id == account.id && $0.identity == account.identity && $0.authenticationState == .valid }) else {
            throw AgentSwapError.storage("Claude 계정 전환 조건이 바뀌어 전환을 중단했습니다.")
        }
    }
    /// Captures only a Desktop login that independently matches the selected account.
    public func captureClaudeDesktopLogin(_ id: UUID) async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard storageHealthy, !isStarting, !isPreparingForTermination, let claudeDesktop,
                  let account = state.accounts.first(where: { $0.id == id && $0.provider == .claude }) else { return }
            await operations.acquire(.claude); beginOperation()
            do {
                try Task.checkCancellation()
                guard storageHealthy, !isPreparingForTermination,
                      state.accounts.contains(where: { $0.id == id && $0.identity == account.identity }) else { throw CancellationError() }
                try await verifyClaudeSessionSwitchBoundary(source: nil, target: account)
                try Task.checkCancellation()
                try await claudeDesktop.captureCurrent(for: account)
                message = "이 계정의 Desktop 로그인을 Keychain에 저장했습니다."
            } catch { message = error.localizedDescription }
            await finishOperation(.claude)
        }
    }
    /// An explicit manual operation: the regular and automatic switch paths stay CLI-only.
    public func switchClaudeDesktopAccount(_ id: UUID) async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard storageHealthy, !isStarting, !isPreparingForTermination, let claudeDesktop,
                  let adapter = adapters[.claude],
                  let account = state.accounts.first(where: { $0.id == id && $0.provider == .claude }) else { return }
            await operations.acquire(.claude); beginOperation()
            var preparation: UUID?
            var needsAbort = false
            var cliApplied = false
            do {
                try validateClaudeSwitchState(account)
                let status = await adapter.compatibility(); compatibility[.claude] = status
                guard status.canWrite else { throw AgentSwapError.unsupported(status.message) }
                let currentCLI: AccountIdentity?
                do { currentCLI = try await adapter.importCurrent().account.identity }
                catch let error as AgentSwapError {
                    guard case .authentication = error else { throw error }
                    currentCLI = nil
                }
                try await verifyClaudeSessionSwitchBoundary(source: state.accounts.first { $0.identity == currentCLI }, target: account)
                try validateClaudeSwitchState(account)
                let transactionID = try await claudeDesktop.prepareSwitch(target: account,
                    registered: state.accounts.filter { $0.provider == .claude }, currentCLI: currentCLI)
                preparation = transactionID; needsAbort = true
                try validateClaudeSwitchState(account)
                cliApplied = await switchAccountWithCurrentInteraction(id, relaunch: false, queueAlreadyHeld: true,
                                                                       desktopPreparation: transactionID)
                let cliMessage = message
                needsAbort = false
                let detail = try await claudeDesktop.finish(transactionID: transactionID, cliApplied: cliApplied)
                claudeDesktopRecoveryRequired = false
                message = cliApplied ? "CLI와 Desktop 전환을 적용했습니다. \(detail)" : "\(cliMessage ?? "CLI 전환을 완료하지 못했습니다.") \(detail)"
            } catch {
                var detail = error.localizedDescription
                if needsAbort, let preparation {
                    do { _ = try await claudeDesktop.finish(transactionID: preparation, cliApplied: false) }
                    catch { claudeDesktopRecoveryRequired = true; detail += " Desktop 준비 복구가 필요합니다: \(error.localizedDescription)" }
                } else if preparation != nil { claudeDesktopRecoveryRequired = true }
                message = cliApplied ? "CLI는 선택한 계정으로 전환됐습니다. Desktop 전환은 완료하지 못했습니다: \(detail)" : detail
            }
            await finishOperation(.claude)
        }
    }
    public func recoverClaudeDesktopSwitch() async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard storageHealthy, !isStarting, !isPreparingForTermination, let claudeDesktop,
                  let adapter = adapters[.claude] else { return }
            await operations.acquire(.claude); beginOperation()
            do {
                try Task.checkCancellation()
                guard !isPreparingForTermination else { throw CancellationError() }
                let currentCLI: AccountIdentity?
                do { currentCLI = try await adapter.importCurrent().account.identity }
                catch let error as AgentSwapError {
                    guard case .authentication = error else { throw error }
                    currentCLI = nil
                }
                message = try await claudeDesktop.recover(registered: state.accounts.filter { $0.provider == .claude }, currentCLI: currentCLI)
                claudeDesktopRecoveryRequired = false
            } catch { claudeDesktopRecoveryRequired = true; message = error.localizedDescription }
            await finishOperation(.claude)
        }
    }
    /// The adapter re-read a different Claude identity after source backup began. Reflect that
    /// observation in active metadata, but never save it or continue the target auth write.
    private func rejectChangedClaudeSource(_ current: ImportedAccount) throws {
        let registeredID = state.accounts.first(where: { $0.identity == current.account.identity })?.id
        if let registeredID { state.activeAccounts[.claude] = registeredID }
        else { state.activeAccounts.removeValue(forKey: .claude) }
        guard registeredID != nil else {
            throw AgentSwapError.storage("현재 Claude 계정이 앱에 등록되어 있지 않아 인증을 보존하고 전환을 보류했습니다. 현재 로그인 가져오기로 등록한 뒤 다시 전환해 주세요.")
        }
        throw AgentSwapError.storage("현재 Claude 계정이 외부에서 변경되어 전환을 중단했습니다.")
    }
    /// Explicitly resumes only a previously-created legacy Desktop-session recovery journal.
    /// Same source/target identity makes `prepareForSwitch` run its recovery check before it can
    /// inventory, publish, stop, or relaunch Claude Desktop.
    public func recoverInterruptedClaudeSessions() async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard storageHealthy, !isStarting, !isPreparingForTermination,
                  let adapter = adapters[.claude], let claudeSessions else { return }
            await operations.acquire(.claude); beginOperation()
            guard !isPreparingForTermination else { await finishOperation(.claude); return }
            do {
                let current = try await adapter.importCurrent()
                guard state.accounts.contains(where: { $0.provider == .claude && $0.identity == current.account.identity }) else {
                    throw AgentSwapError.storage("현재 Claude 계정을 가져온 뒤 중단된 대화 목록 복구를 다시 시도해 주세요.")
                }
                let recovery = try await claudeSessions.prepareForSwitch(source: current.account, target: current.account, relaunch: false)
                switch recovery {
                case .notNeeded:
                    claudeSessionRecoveryRequired = false
                    message = "중단된 Claude 대화 목록 복구를 완료했습니다. CLI 인증은 변경하지 않았습니다."
                case .pendingRelaunch(let detail):
                    claudeSessionRecoveryRequired = true
                    message = "Claude를 직접 정상 종료한 뒤 대화 목록 복구를 다시 시도해 주세요. \(detail)"
                case .prepared:
                    claudeSessionRecoveryRequired = true
                    throw AgentSwapError.storage("중단된 대화 목록 복구 상태를 확인하지 못했습니다. 인증 변경을 중단했습니다.")
                }
            } catch {
                claudeSessionRecoveryRequired = true
                message = error.localizedDescription
            }
            await finishOperation(.claude)
        }
    }
    private func evaluateAutomaticSwitch(_ provider: Provider, now: Date) async {
        guard pendingSwitch[provider] == nil else { return }
        switch AutomaticSwitchPolicy.decide(provider: provider, state: state, now: now) {
        case .switchTo(let id): await switchAccountWithCurrentInteraction(id, relaunch: false)
        case .noCandidate:
            attentionProviders.insert(provider)
            if lastNotices[provider].map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                message = "\(provider.title)의 사용 한도가 임계치에 도달했지만 전환할 계정이 없습니다. 현재 계정을 유지합니다."
                lastNotices[provider] = now
            }
        default: attentionProviders.remove(provider)
        }
    }
    private func saveLatestSource(_ current: ImportedAccount) async throws {
        guard let oldID = state.accounts.first(where: { $0.identity == current.account.identity })?.id else {
            // A successful callback promises a durable backup. An external login that has
            // never been registered has no vault slot; require import before replacing it.
            state.activeAccounts.removeValue(forKey: current.account.provider)
            throw AgentSwapError.storage("현재 \(current.account.provider.title) 계정이 앱에 등록되어 있지 않아 인증을 보존하고 전환을 보류했습니다. 현재 로그인 가져오기로 등록한 뒤 다시 전환해 주세요.")
        }
        _ = try await reconcileNative(current, accountID: oldID)
    }
    private func markNativeRefreshIfNeeded(_ credential: Credential, account: AccountRecord, isActive: Bool) async throws {
        guard account.provider == .codex, isActive else { return }
        try await markNativePredecessor(credential, accountID: account.id)
    }
    private func markNativePredecessor(_ credential: Credential, accountID: UUID) async throws {
        // Keep the earliest native generation until a saved successor is applied. A second
        // refresh of a pending successor must not make its original native predecessor unknown.
        guard state.pendingNativeRefreshPredecessor?[accountID] == nil else { return }
        if state.pendingNativeRefreshPredecessor == nil { state.pendingNativeRefreshPredecessor = [:] }
        state.pendingNativeRefreshPredecessor?[accountID] = Self.digest(credential.rawAuth)
        // Persist the marker before consuming a one-time refresh grant.
        try await store.save(state)
    }
    private func clearPendingRefresh(_ id: UUID) {
        state.pendingNativeRefreshPredecessor?.removeValue(forKey: id)
        pendingGenerationMarkerWrites.removeValue(forKey: id)
        for provider in Provider.allCases where pendingSwitch[provider] == id { pendingSwitch.removeValue(forKey: provider) }
    }
    private func reconcileNative(_ current: ImportedAccount, accountID: UUID, acceptExternalNative: Bool = false) async throws -> Credential {
        try await flushPendingCredentialWrite(accountID)
        let native = current.credential
        let provider = current.account.provider
        if let retained = retainedNativeGenerations[accountID] {
            let nativeDigest = Self.digest(native.rawAuth)
            if nativeDigest == retained.before, nativeDigest != retained.after,
               state.pendingNativeRefreshPredecessor?[accountID] == nil {
                guard let vault = try await secrets.load(accountID: accountID), Self.digest(vault.rawAuth) == retained.after else {
                    throw AgentSwapError.storage("갱신된 인증의 저장 상태를 확인하지 못해 이전 인증 적용을 보류했습니다.")
                }
                return vault
            }
            if nativeDigest != retained.before { retainedNativeGenerations.removeValue(forKey: accountID) }
        }
        if let predecessor = state.pendingNativeRefreshPredecessor?[accountID] {
            guard let vault = try await secrets.load(accountID: accountID) else {
                guard acceptExternalNative else {
                    throw AgentSwapError.authentication("저장된 새 인증이 없습니다. 현재 로그인 가져오기 또는 새 로그인을 진행해 주세요.")
                }
                clearPendingRefresh(accountID)
                try await secrets.save(native, accountID: accountID)
                return native
            }
            if provider == .claude, Self.sameClaudeGrant(native, vault, identity: current.account.identity) {
                try await secrets.save(native, accountID: accountID)
                clearPendingRefresh(accountID)
                retainedNativeGenerations.removeValue(forKey: accountID)
                return native
            }
            let nativeDigest = Self.digest(native.rawAuth), vaultDigest = Self.digest(vault.rawAuth)
            if nativeDigest == vaultDigest { clearPendingRefresh(accountID) }
            else if nativeDigest == predecessor {
                pendingSwitch[provider] = accountID
                message = "갱신된 \(provider.title) 인증을 보존했습니다. 현재 계정을 확인한 뒤 전환을 진행해 주세요."
                return vault
            } else if acceptExternalNative { clearPendingRefresh(accountID) }
            else {
                pendingSwitch[provider] = accountID
                throw AgentSwapError.storage("\(provider.title) 인증이 외부에서 변경되어 두 인증을 보존했습니다. 현재 로그인 가져오기로 다시 확인해 주세요.")
            }
        }
        try await secrets.save(native, accountID: accountID)
        return native
    }
    private func applyToConfirmedCurrent(_ credential: Credential, account: AccountRecord, adapter: any ProviderAdapter) async -> SwitchResult {
        await adapter.activatePreservingSource(credential, account: account, relaunch: false) { [weak self] current in
            try Task.checkCancellation()
            guard current.account.identity == account.identity else {
                throw AgentSwapError.storage("현재 계정이 외부에서 변경되어 새 인증의 자동 적용을 중단했습니다.")
            }
            try await self?.saveLatestSource(current)
        }
    }
    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func sameClaudeGrant(_ native: Credential, _ vault: Credential, identity: AccountIdentity) -> Bool {
        guard native.accessToken == vault.accessToken, native.refreshToken == vault.refreshToken,
              let parsedNative = try? CredentialParser.claude(rawAuth: native.rawAuth, accountMetadata: native.accountMetadata),
              let parsedVault = try? CredentialParser.claude(rawAuth: vault.rawAuth, accountMetadata: vault.accountMetadata),
              parsedNative.accessToken == native.accessToken, parsedNative.refreshToken == native.refreshToken,
              parsedVault.accessToken == vault.accessToken, parsedVault.refreshToken == vault.refreshToken,
              let nativeAccount = try? ProviderAccountParser.claude(parsedNative).account,
              let vaultAccount = try? ProviderAccountParser.claude(parsedVault).account else { return false }
        return nativeAccount.identity == identity && vaultAccount.identity == identity
    }
    public func updateAccount(_ id: UUID, nickname: String? = nil, automaticSwitchEligible: Bool? = nil) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let index = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        if let nickname { state.accounts[index].nickname = nickname }
        if let automaticSwitchEligible { state.accounts[index].automaticSwitchEligible = automaticSwitchEligible }
        await persist()
    }
    public func deleteAccount(_ id: UUID) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await deleteAccountWithInteraction(id) }
    }
    private func deleteAccountWithInteraction(_ id: UUID) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let account = state.accounts.first(where: { $0.id == id }) else { return }
        await operations.acquire(account.provider)
        guard !isPreparingForTermination else { await operations.release(account.provider); return }
        do {
            try await adapters[account.provider]?.deletePreservedRecoveryCredentials(accountID: id)
            if account.provider == .claude { try await claudeDesktop?.deleteSnapshot(accountID: id) }
            try await secrets.delete(accountID: id)
            await adapters[account.provider]?.discardPendingCredentialPersistence(accountID: id)
            discardRetainedCredential(id)
            state.accounts.removeAll { $0.id == id }; state.usage.removeValue(forKey: id)
            state.pendingNativeRefreshPredecessor?.removeValue(forKey: id)
            if state.activeAccounts[account.provider] == id { state.activeAccounts.removeValue(forKey: account.provider) }
            if pendingSwitch[account.provider] == id { pendingSwitch.removeValue(forKey: account.provider) }
            await persist()
        } catch { message = error.localizedDescription }
        await operations.release(account.provider)
    }
    public func updateSettings(_ settings: AppSettings) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination else { return }
        var validated = settings
        validated.activePollInterval = max(30, settings.activePollInterval)
        validated.inactivePollInterval = max(60, settings.inactivePollInterval)
        for provider in Provider.allCases {
            var automation = validated.automation[provider] ?? .init()
            automation.threshold = max(1, min(100, automation.threshold))
            automation.minimumImprovement = max(5, min(100, automation.minimumImprovement))
            automation.cooldown = max(300, automation.cooldown)
            validated.automation[provider] = automation
        }
        state.settings = validated; await persist()
    }
    public func recoverInterruptedSwitch(_ provider: Provider) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await recoverInterruptedSwitchWithInteraction(provider) }
    }
    /// Explicitly accepts a verified external generation while retaining all interrupted evidence.
    /// The adapter durably saves that generation before releasing its recovery marker.
    public func recoverClaudeKeepingCurrentLogin(_ id: UUID) async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard storageHealthy, !isStarting, !isPreparingForTermination,
                  let adapter = adapters[.claude] else { return }
            await operations.acquire(.claude); beginOperation()
            guard !isPreparingForTermination, state.activeAccounts[.claude] == id,
                  let account = state.accounts.first(where: { $0.id == id && $0.provider == .claude }) else {
                await finishOperation(.claude); return
            }
            do {
                try await flushPendingCredentials(.claude)
                let imported = try await adapter.recoverKeepingCurrentLogin(account: account)
                guard imported.account.id == id, imported.account.identity == account.identity,
                      let index = state.accounts.firstIndex(where: { $0.id == id && $0.identity == account.identity }) else {
                    throw AgentSwapError.storage("복구 중 계정 정보가 변경되었습니다. 현재 로그인을 다시 가져와 주세요.")
                }
                let latest = state.accounts[index]
                var updated = imported.account
                updated.nickname = latest.nickname; updated.createdAt = latest.createdAt
                updated.automaticSwitchEligible = latest.automaticSwitchEligible
                if updated.plan.isEmpty { updated.plan = latest.plan }
                updated.authenticationState = .valid
                state.accounts[index] = updated
                discardRetainedCredential(id); clearPendingRefresh(id)
                pendingSwitch.removeValue(forKey: .claude)
                for record in state.accounts where record.provider == .claude {
                    if var cache = state.usage[record.id],
                       ["중단된 Claude 전환의 복원이 필요합니다.", "Claude 인증 복원을 완료한 뒤 갱신해 주세요."].contains(cache.error ?? "") {
                        cache.retryAfter = nil
                        cache.retryReason = nil
                        state.usage[record.id] = cache
                    }
                }
                message = "현재 Claude 로그인을 유지해 복구했습니다. 보류된 갱신 인증은 Keychain에 별도로 보관했습니다."
                await persist()
            } catch { message = error.localizedDescription }
            compatibility[.claude] = await adapter.compatibility()
            await finishOperation(.claude)
            await refreshDue(force: true)
        }
    }
    private func recoverInterruptedSwitchWithInteraction(_ provider: Provider) async {
        guard !isPreparingForTermination, let adapter = adapters[provider] else { return }
        await operations.acquire(provider); beginOperation()
        guard !isPreparingForTermination else { await finishOperation(provider); return }
        do {
            try await adapter.recoverInterruptedSwitch()
            compatibility[provider] = await adapter.compatibility()
            message = "\(provider.title)의 중단된 전환을 복구했습니다. 현재 로그인을 다시 가져와 주세요."
        } catch { message = error.localizedDescription }
        await finishOperation(provider)
    }
    private func persist() async {
        guard storageHealthy else { return }
        do { try await store.save(state) }
        catch {
            storageHealthy = false
            message = "저장 실패로 계정 변경과 자동 전환을 중단했습니다. 앱을 다시 실행해 주세요: \(error.localizedDescription)"
        }
    }
    private func beginOperation() { busyCount += 1; isBusy = true }
    private func finishOperation(_ provider: Provider) async {
        busyCount -= 1; isBusy = busyCount > 0; resumeOperationWaiters(); await operations.release(provider)
    }
    private func resumeOperationWaiters() {
        let ready = operationWaiters.filter { busyCount <= $0.limit }
        operationWaiters.removeAll { busyCount <= $0.limit }
        ready.forEach { $0.continuation.resume() }
    }
    private func waitForOperations(limit: Int) async {
        guard busyCount > limit else { return }
        await withCheckedContinuation { operationWaiters.append((limit, $0)) }
    }
    public func prepareForTermination() async -> Bool {
        guard !isPreparingForTermination else { return false }
        isPreparingForTermination = true; beginOperation()
        claudeDesktopProfiles.beginTermination()
        let polling = scheduler
        stop()
        await cancelLogin()
        await polling?.value
        await claudeDesktopProfiles.prepareForTermination()
        // Startup spans several provider queues while its busy count stays raised. Let it
        // finish before holding any queue it still needs for its next provider.
        await waitForOperations(limit: 1)
        // Hold all provider queues until every earlier operation has finished. New UI actions
        // are blocked above, and queued actions recheck the termination flag after acquisition.
        for provider in Provider.allCases { await operations.acquire(provider) }
        await waitForOperations(limit: 1)
        var failure: String?
        await KeychainInteraction.$mode.withValue(.noninteractive) {
            for provider in Provider.allCases {
                do { try await flushPendingCredentials(provider) }
                catch { failure = error.localizedDescription }
            }
        }
        if failure == nil, !pendingCredentialWrites.isEmpty {
            failure = "저장할 계정을 확인하지 못한 갱신 인증을 메모리에 보존하고 있습니다."
        }
        for provider in Provider.allCases { await operations.release(provider) }
        busyCount -= 1; isBusy = busyCount > 0; resumeOperationWaiters()
        if let failure {
            isPreparingForTermination = false
            claudeDesktopProfiles.resumeAfterTerminationFailure()
            message = "갱신된 인증과 복구 상태의 저장을 마치지 못해 종료를 보류했습니다. \(failure)"
            startScheduler()
            return false
        }
        return true
    }
    private func flushPendingCredentials(_ provider: Provider) async throws {
        if let adapter = adapters[provider] {
            if await adapter.hasPendingCredentialPersistence() {
                try await adapter.flushPendingCredentialPersistence()
                compatibility[provider] = await adapter.compatibility()
                guard !(await adapter.hasPendingCredentialPersistence()) else {
                    throw AgentSwapError.storage("제공자의 갱신된 인증을 아직 저장하지 못했습니다.")
                }
            }
            for receipt in await adapter.takePersistedCredentialGenerations() {
                guard state.accounts.contains(where: { $0.id == receipt.accountID && $0.provider == provider }) else { continue }
                retainGenerationMarker(receipt)
            }
        }
        for account in state.accounts where account.provider == provider {
            try await flushPendingCredentialWrite(account.id)
        }
        try await flushPendingGenerationMarkers(provider)
    }
    private func saveRotatedCredential(_ credential: Credential, predecessor: Credential, accountID: UUID) async throws {
        pendingCredentialWrites[accountID] = credential
        pendingCredentialGenerations[accountID] = UUID()
        let before = state.pendingNativeRefreshPredecessor?[accountID] ?? Self.digest(predecessor.rawAuth)
        retainedNativeGenerations[accountID] = (before, Self.digest(credential.rawAuth))
        do { try await flushPendingCredentialWrite(accountID) }
        catch {
            retainGenerationMarker(.init(accountID: accountID, predecessorDigest: before, successorDigest: Self.digest(credential.rawAuth)))
            throw error
        }
    }
    private func flushPendingCredentialWrite(_ id: UUID) async throws {
        guard let credential = pendingCredentialWrites[id], let generation = pendingCredentialGenerations[id] else { return }
        do { try await secrets.save(credential, accountID: id) }
        catch {
            throw AgentSwapError.storage("갱신된 인증을 메모리에 보존했습니다. Keychain 잠금을 해제하고 이 계정의 저장된 인증 접근을 허용한 뒤 다시 조회해 주세요. 저장을 완료할 때까지 종료를 보류합니다. \(error.localizedDescription)")
        }
        if pendingCredentialGenerations[id] == generation {
            pendingCredentialWrites.removeValue(forKey: id); pendingCredentialGenerations.removeValue(forKey: id)
        }
    }
    private func discardRetainedCredential(_ id: UUID) {
        pendingCredentialWrites.removeValue(forKey: id); pendingCredentialGenerations.removeValue(forKey: id)
        retainedNativeGenerations.removeValue(forKey: id)
        pendingGenerationMarkerWrites.removeValue(forKey: id)
    }
    private func retainGenerationMarker(_ receipt: PersistedCredentialGeneration) {
        let earliest = state.pendingNativeRefreshPredecessor?[receipt.accountID]
            ?? pendingGenerationMarkerWrites[receipt.accountID] ?? receipt.predecessorDigest
        retainedNativeGenerations[receipt.accountID] = (earliest, receipt.successorDigest)
        pendingGenerationMarkerWrites[receipt.accountID] = earliest
    }
    private func flushPendingGenerationMarkers(_ provider: Provider) async throws {
        let pending = pendingGenerationMarkerWrites.filter { id, _ in
            state.accounts.contains { $0.id == id && $0.provider == provider }
        }
        guard !pending.isEmpty else { return }
        if state.pendingNativeRefreshPredecessor == nil { state.pendingNativeRefreshPredecessor = [:] }
        for (id, digest) in pending where state.pendingNativeRefreshPredecessor?[id] == nil {
            state.pendingNativeRefreshPredecessor?[id] = digest
        }
        let snapshot = state
        do { try await store.save(snapshot) }
        catch { throw AgentSwapError.storage("갱신 인증의 복구 상태를 저장하지 못했습니다. 저장 위치를 확인한 뒤 다시 시도해 주세요. \(error.localizedDescription)") }
        for (id, digest) in pending where pendingGenerationMarkerWrites[id] == digest {
            pendingGenerationMarkerWrites.removeValue(forKey: id)
        }
    }
}
