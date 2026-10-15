import Foundation
import Observation
import CryptoKit

@MainActor @Observable
public final class AppModel {
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
    public private(set) var claudeCLIOnlySwitchTarget: UUID?

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
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginGeneration: UUID?
    @ObservationIgnored private var claudeCLIOnlySwitchRequest: ClaudeCLIOnlySwitchRequest?
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
                claudeSessions: (any ClaudeDesktopSessionPreserving)? = nil) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        self.secrets = secrets; self.store = store; self.claudeSessions = claudeSessions
    }

    deinit { scheduler?.cancel(); loginTask?.cancel() }

    public func start() async {
        guard !isPreparingForTermination else { return }
        await KeychainInteraction.$mode.withValue(.noninteractive) { await startWithCurrentInteraction() }
    }
    private func startWithCurrentInteraction() async {
        guard !started, !isPreparingForTermination else { return }; started = true; isStarting = true; beginOperation()
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
    public func authorizeSavedCredential(_ id: UUID) async {
        guard !isStarting, !isPreparingForTermination, let account = state.accounts.first(where: { $0.id == id }) else { return }
        await operations.acquire(account.provider)
        beginOperation()
        guard !isPreparingForTermination, state.accounts.contains(where: { $0.id == id && $0.identity == account.identity }) else {
            await finishOperation(account.provider)
            return
        }
        do {
            try Task.checkCancellation()
            let exists = try await KeychainInteraction.$mode.withValue(.interactive) {
                try await secrets.load(accountID: id) != nil
            }
            guard exists else { throw AgentSwapError.authentication("저장된 인증이 없습니다. 이 계정에 다시 로그인해 주세요.") }
            message = "저장된 인증에 접근할 수 있습니다. 새로고침하거나 다음 조회를 기다려 주세요."
        } catch is CancellationError {
            message = "저장된 인증 접근 확인을 취소했습니다."
        } catch { message = error.localizedDescription }
        await finishOperation(account.provider)
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
            if isActive {
                let imported = try await adapter.importCurrent()
                if imported.account.identity == account.identity {
                    credential = try await reconcileNative(imported, accountID: id)
                } else {
                    let actualID = state.accounts.first(where: { $0.identity == imported.account.identity })?.id
                    state.activeAccounts[account.provider] = actualID
                    if let actualID { _ = try await reconcileNative(imported, accountID: actualID) }
                    isActive = false
                }
            }
            let running = await adapter.hasRunningConsumers()
            let consumersRunning = account.provider == .codex && isActive && running
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
                if case .authentication = error, !consumersRunning {
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
            snapshot.fetchedAt = Date(); cache.snapshot = snapshot; cache.error = nil; cache.retryAfter = nil
            if let index = state.accounts.firstIndex(where: { $0.id == id }) {
                state.accounts[index].authenticationState = .valid
                if let plan = snapshot.plan { state.accounts[index].plan = plan }
            }
        } catch {
            cache.error = error.localizedDescription
            if let typed = error as? AgentSwapError {
                switch typed {
                case .rateLimited(let retry): cache.retryAfter = retry
                case .authentication:
                    if let index = state.accounts.firstIndex(where: { $0.id == id }) { state.accounts[index].authenticationState = .needsLogin }
                default: cache.retryAfter = now.addingTimeInterval(60)
                }
            } else { cache.retryAfter = now.addingTimeInterval(60) }
        }
        if state.accounts.contains(where: { $0.id == id }) { state.usage[id] = cache }
        // A successful retry or failed native update can change write compatibility. Do not
        // leave all target accounts blocked by an obsolete startup inspection.
        compatibility[account.provider] = await adapter.compatibility()
        await persist(); await finishOperation(account.provider)
    }

    public func importCurrent(_ provider: Provider) async {
        await KeychainInteraction.$mode.withValue(.interactive) { await importCurrentWithInteraction(provider) }
    }
    private func importCurrentWithInteraction(_ provider: Provider) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let adapter = adapters[provider] else { return }
        dismissClaudeCLIOnlySwitch()
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
        dismissClaudeCLIOnlySwitch()
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
    private struct ClaudeCLIOnlySwitchRequest: Equatable {
        let nonce = UUID()
        let targetID: UUID
        let targetIdentity: AccountIdentity
        let sourceIdentity: AccountIdentity
    }
    private enum ClaudeSessionSwitchMode {
        case preserving
        case cliOnly(ClaudeCLIOnlySwitchRequest)
    }
    public func dismissClaudeCLIOnlySwitch() {
        claudeCLIOnlySwitchRequest = nil; claudeCLIOnlySwitchTarget = nil
    }
    /// A CLI-only switch requires a prior typed, pre-mutation preservation failure and an
    /// explicit user action. Automatic and ordinary switches always retain preservation.
    public func switchClaudeCLIOnly(_ id: UUID) async {
        await KeychainInteraction.$mode.withValue(.interactive) {
            guard let request = self.claudeCLIOnlySwitchRequest, request.targetID == id else { return }
            await self.switchAccountWithCurrentInteraction(id, relaunch: false, sessionMode: .cliOnly(request))
        }
    }
    private func switchAccountWithCurrentInteraction(_ id: UUID, relaunch: Bool,
                                                    sessionMode: ClaudeSessionSwitchMode = .preserving) async {
        guard storageHealthy, !isStarting, !isPreparingForTermination, let account = state.accounts.first(where: { $0.id == id }), let adapter = adapters[account.provider] else { return }
        await operations.acquire(account.provider); beginOperation()
        guard !isPreparingForTermination else { await finishOperation(account.provider); return }
        var fallbackSource: AccountIdentity?
        if case .cliOnly(let request) = sessionMode {
            guard claudeCLIOnlySwitchRequest == request else {
                await finishOperation(account.provider); return
            }
            guard storageHealthy, !Task.isCancelled, account.provider == .claude,
                  let selected = state.accounts.first(where: { $0.id == id }),
                  selected.identity == request.targetIdentity, selected.authenticationState == .valid else {
                dismissClaudeCLIOnlySwitch()
                message = "전환 조건이 바뀌었습니다. 대상 계정을 선택하고 대화 보존을 다시 확인해 주세요."
                await finishOperation(account.provider); return
            }
            fallbackSource = request.sourceIdentity
        }
        // Consume the offer once the queued action begins. Dismissed/replaced queued requests
        // cannot reuse an earlier error to bypass the preservation step.
        dismissClaudeCLIOnlySwitch()
        do {
            try Task.checkCancellation()
            try await flushPendingCredentials(account.provider)
            guard var credential = try await secrets.load(accountID: id) else { throw AgentSwapError.authentication("저장된 인증이 없습니다.") }
            let status = await adapter.compatibility(); compatibility[account.provider] = status
            guard status.canWrite else { throw AgentSwapError.unsupported(status.message) }
            let running = await adapter.hasRunningConsumers()
            let activeAndRunning = account.provider == .codex && state.activeAccounts[account.provider] == id && running
            let current: ImportedAccount?
            if let fallbackSource {
                guard let claudeSessions else { throw AgentSwapError.unsupported("로컬 대화 보존의 복구 상태를 확인할 수 없어 전환을 중단했습니다.") }
                let source = try await adapter.importCurrent()
                guard source.account.identity == fallbackSource else {
                    throw AgentSwapError.storage("현재 Claude 계정이 바뀌었습니다. 대상 계정을 선택하고 대화 보존을 다시 확인해 주세요.")
                }
                try Task.checkCancellation()
                try await claudeSessions.verifyCanSwitchWithoutPreservingSessions(source: source.account, target: account)
                try validateCLIOnlySwitchState(account)
                current = source
            } else { current = try? await adapter.importCurrent() }
            if let current, current.account.identity == account.identity {
                credential = try await reconcileNative(current, accountID: id)
            }
            if !activeAndRunning, credential.expiresAt.map({ $0.timeIntervalSinceNow < 120 }) ?? false {
                try await markNativeRefreshIfNeeded(credential, account: account, isActive: state.activeAccounts[account.provider] == id)
                let predecessor = credential
                credential = try await adapter.refresh(credential, account: account)
                try await saveRotatedCredential(credential, predecessor: predecessor, accountID: id)
            }
            var sessionPreparation = ClaudeDesktopSessionPreparation.notNeeded
            if fallbackSource == nil, account.provider == .claude, let claudeSessions {
                // The actual CLI source selects the source bucket. Desktop login remains independent;
                // source records are retained, so preparing the target never empties its current sidebar.
                do {
                    sessionPreparation = try await claudeSessions.prepareForSwitch(source: current?.account, target: account, relaunch: relaunch)
                } catch let error as ClaudeDesktopSessionPreservationUnavailable {
                    try Task.checkCancellation()
                    if storageHealthy, !isPreparingForTermination, let current,
                       state.accounts.contains(where: { $0.id == id && $0.identity == account.identity }) {
                        claudeCLIOnlySwitchRequest = .init(targetID: id, targetIdentity: account.identity, sourceIdentity: current.account.identity)
                        claudeCLIOnlySwitchTarget = id
                    }
                    throw error
                }
                if case .pendingRelaunch(let text) = sessionPreparation {
                    pendingSwitch[.claude] = id; attentionProviders.insert(.claude); message = text
                    await persist(); await finishOperation(.claude); return
                }
                do { try Task.checkCancellation() }
                catch {
                    _ = try await claudeSessions.finish(sessionPreparation, applied: false)
                    throw error
                }
            }
            let expectedSessionSource = fallbackSource ?? (account.provider == .claude && claudeSessions != nil ? current?.account.identity : nil)
            let fallbackSessionVerifier = fallbackSource == nil ? nil : claudeSessions
            let result = await adapter.activatePreservingSource(credential, account: account, relaunch: relaunch,
                                                                allowMissingSource: current == nil) { [weak self] current in
                try Task.checkCancellation()
                if let expectedSessionSource, current.account.identity != expectedSessionSource {
                    throw AgentSwapError.storage("세션 보존 중 현재 Claude 계정이 외부에서 바뀌어 전환을 중단했습니다.")
                }
                try await self?.saveLatestSource(current)
                try Task.checkCancellation()
                // Target refresh and source backup can suspend. Recheck the independent Code
                // recovery boundary at the final callback before native authentication writes.
                if let fallbackSessionVerifier {
                    try await fallbackSessionVerifier.verifyCanSwitchWithoutPreservingSessions(source: current.account, target: account)
                    guard let self else { throw CancellationError() }
                    try await self.validateCLIOnlySwitchState(account)
                }
            }
            var sessionNotice: String?
            if fallbackSource == nil, account.provider == .claude, let claudeSessions {
                let applied: Bool
                if case .applied = result { applied = true } else { applied = false }
                do { sessionNotice = try await claudeSessions.finish(sessionPreparation, applied: applied) }
                catch { sessionNotice = "Code 세션 보존 상태를 확인하지 못했습니다: \(error.localizedDescription)" }
            }
            switch result {
            case .applied(let text):
                clearPendingRefresh(id)
                attentionProviders.remove(account.provider)
                state.activeAccounts[account.provider] = id; state.lastSwitch[account.provider] = Date()
                pendingSwitch.removeValue(forKey: account.provider); message = text
                if fallbackSource != nil {
                    message = [text, "CLI 계정만 전환했습니다. 기존 Code 대화 파일과 목록은 변경하지 않았습니다. Claude 데스크톱 로그인은 CLI 로그인과 별개입니다."].joined(separator: "\n")
                }
            case .pendingRelaunch(let text): pendingSwitch[account.provider] = id; attentionProviders.insert(account.provider); message = text
            case .failed(let text): attentionProviders.insert(account.provider); message = text
            }
            if let sessionNotice { message = [message, sessionNotice].compactMap { $0 }.joined(separator: "\n") }
            await persist()
        } catch { message = error.localizedDescription }
        await finishOperation(account.provider)
    }
    private func validateCLIOnlySwitchState(_ account: AccountRecord) throws {
        try Task.checkCancellation()
        guard storageHealthy, !isPreparingForTermination,
              state.accounts.contains(where: { $0.id == account.id && $0.identity == account.identity && $0.authenticationState == .valid }) else {
            throw AgentSwapError.storage("전환 조건이 바뀌어 Claude 계정 변경을 중단했습니다.")
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
        dismissClaudeCLIOnlySwitch()
        await operations.acquire(account.provider)
        guard !isPreparingForTermination else { await operations.release(account.provider); return }
        do {
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
            storageHealthy = false; dismissClaudeCLIOnlySwitch()
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
        dismissClaudeCLIOnlySwitch()
        isPreparingForTermination = true; beginOperation()
        let polling = scheduler
        stop()
        await cancelLogin()
        await polling?.value
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
