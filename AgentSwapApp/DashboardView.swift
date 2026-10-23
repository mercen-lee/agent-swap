import AgentSwapCore
import SwiftUI

private enum AccountFilter: String, CaseIterable, Identifiable {
    case desktop, all, claude, codex
    var id: String { rawValue }
    var provider: Provider? {
        switch self { case .desktop, .all: nil; case .claude: .claude; case .codex: .codex }
    }
    var title: String { self == .desktop ? "Claude Desktop" : provider?.title ?? "전체 계정" }
}

private struct StatusMessage: Identifiable {
    let id = UUID()
    let text: String
}

struct DashboardView: View {
    let model: AppModel
    @State private var filter: AccountFilter? = .desktop
    @State private var search = ""
    @State private var selectedID: UUID?
    @State private var showsInspector = true
    @State private var isAddingAccount = false
    @State private var editingAccount: AccountRecord?
    @State private var reauthenticatingAccount: AccountRecord?
    @State private var deletingAccount: AccountRecord?
    @State private var statusDetails: StatusMessage?
    @State private var keepingCurrentRecoveryAccount: AccountRecord?

    private var filteredAccounts: [AccountRecord] {
        model.displayAccounts.filter { account in
            (filter?.provider == nil || account.provider == filter?.provider) &&
            (search.isEmpty || [account.displayName, account.email, account.workspaceName, account.plan]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    private var selectedAccount: AccountRecord? {
        filteredAccounts.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detailContent
                    .navigationTitle(filter?.title ?? "전체 계정")
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            if filter != .desktop { accountListFooter }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "계정 검색")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if filter != .desktop {
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                    .help("모든 계정 새로고침 (⌘R)")
                    Menu {
                        Button("위로 이동", systemImage: "arrow.up") { moveSelectedAccount(up: true) }
                            .disabled(!canMoveSelectedAccount(up: true))
                        Button("아래로 이동", systemImage: "arrow.down") { moveSelectedAccount(up: false) }
                            .disabled(!canMoveSelectedAccount(up: false))
                    } label: {
                        Label("계정 순서", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(model.isBusy || selectedAccount == nil)
                    .help("선택한 계정을 위아래로 이동합니다. 목록에서 드래그해도 순서를 바꿀 수 있습니다.")
                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("계정 추가", systemImage: "plus")
                    }
                    .disabled(model.isLoggingIn)
                }
            }
            ToolbarItem(placement: .automatic) {
                if filter != .desktop {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("계정 상세", systemImage: "sidebar.trailing")
                    }
                    .help("계정 상세 보기")
                }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AddAccountSheet(model: model, initialProvider: filter?.provider ?? .claude)
        }
        .sheet(item: $editingAccount) { account in
            EditAccountSheet(account: account) { name in
                Task { await model.updateAccount(account.id, nickname: name, automaticSwitchEligible: nil) }
            }
        }
        .sheet(item: $reauthenticatingAccount) { account in
            ReauthenticateAccountSheet(model: model, account: account)
        }
        .alert("계정을 삭제할까요?", isPresented: Binding(
            get: { deletingAccount != nil },
            set: { if !$0 { deletingAccount = nil } }
        )) {
            Button("취소", role: .cancel) { deletingAccount = nil }
            Button("삭제", role: .destructive) {
                guard let account = deletingAccount else { return }
                Task { await model.deleteAccount(account.id) }
                deletingAccount = nil
            }
        } message: {
            Text("\(deletingAccount?.displayName ?? "계정")의 저장된 인증과 사용량 캐시를 삭제합니다. 제공자의 구독은 유지됩니다.")
        }
        .alert("현재 Claude 로그인을 유지하고 복구할까요?", isPresented: Binding(
            get: { keepingCurrentRecoveryAccount != nil },
            set: { if !$0 { keepingCurrentRecoveryAccount = nil } }
        )) {
            Button("취소", role: .cancel) { keepingCurrentRecoveryAccount = nil }
            Button("현재 로그인으로 복구") {
                guard let account = keepingCurrentRecoveryAccount else { return }
                Task { await model.recoverClaudeKeepingCurrentLogin(account.id) }
                keepingCurrentRecoveryAccount = nil
            }
        } message: {
            Text("현재 CLI 로그인을 유지합니다. 보류된 갱신 인증은 Keychain에 별도로 보관하고, 현재 계정을 확인한 뒤 조회를 다시 시작합니다.")
        }
        .onChange(of: filteredAccounts.map(\.id), initial: true) {
            if !filteredAccounts.contains(where: { $0.id == selectedID }) {
                selectedID = filteredAccounts.first?.id
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if filter == .desktop {
            ClaudeDesktopProfilesView(model: model.claudeDesktopProfiles, search: search)
        } else {
            accountListContent
                .inspector(isPresented: $showsInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
                }
        }
    }

    private var sidebar: some View {
        List(selection: $filter) {
            Section("데스크톱") {
                Label {
                    Text("Claude Desktop")
                } icon: {
                    ProviderBrandIcon(provider: .claude, isSelected: filter == .desktop)
                }
                .tag(AccountFilter.desktop)
            }
            Section("CLI·Codex 계정") {
                ForEach(AccountFilter.allCases.filter { $0 != .desktop }) { item in
                    HStack {
                        Label {
                            Text(item.title)
                        } icon: {
                            if let provider = item.provider {
                                ProviderBrandIcon(provider: provider, isSelected: filter == item)
                            } else {
                                Image(systemName: "person.2")
                            }
                        }
                        Spacer()
                        Text("\(model.state.accounts.filter { item.provider == nil || $0.provider == item.provider }.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(item)
                }
            }
            Section("자동 전환") {
                ForEach(Provider.allCases) { provider in
                    HStack {
                        Label {
                            Text(provider.title)
                        } icon: {
                            ProviderBrandIcon(provider: provider)
                        }
                        Spacer()
                        Text(model.state.settings.automation[provider]?.enabled == true ? "켜짐" : "꺼짐")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("AgentSwap")
        .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 240)
        .safeAreaInset(edge: .bottom) {
            SettingsLink {
                Label("설정", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding()
        }
    }

    private var accountListContent: some View {
        let visibleAccounts = filteredAccounts
        let visibleIDs = visibleAccounts.map(\.id)
        return List(selection: $selectedID) {
            Section("현재 계정") {
                ForEach(Provider.allCases.filter { filter?.provider == nil || $0 == filter?.provider }) { provider in
                    CurrentAccountRow(
                        provider: provider,
                        account: model.state.accounts.first { $0.id == model.state.activeAccounts[provider] },
                        cache: model.state.activeAccounts[provider].flatMap { model.state.usage[$0] }
                    )
                }
            }
            Section("저장된 계정") {
                ForEach(visibleAccounts) { account in
                    AccountRow(
                        account: account,
                        cache: model.state.usage[account.id],
                        providerRetryAfter: model.state.providerRetryAfter?[account.provider],
                        isActive: model.state.activeAccounts[account.provider] == account.id,
                        isPending: model.pendingSwitch[account.provider] == account.id,
                        isSelected: selectedID == account.id
                    )
                    .tag(account.id)
                    .contextMenu {
                        let presentation = switchPresentation(for: account)
                        Button(presentation.requiresRelaunch ? presentation.title : "이 계정으로 전환", systemImage: "arrow.left.arrow.right") {
                            Task { await model.switchAccount(account.id, relaunch: presentation.requiresRelaunch) }
                        }
                        .disabled(!presentation.canSwitch)
                        .help(presentation.help)
                        .accessibilityHint(presentation.help)
                        Button("재로그인…", systemImage: "arrow.clockwise.circle") { reauthenticatingAccount = account }
                            .disabled(model.isBusy || model.isLoggingIn)
                        Button("별명 변경", systemImage: "pencil") { editingAccount = account }
                        Toggle("자동 전환 후보", isOn: Binding(
                            get: { account.automaticSwitchEligible },
                            set: { value in
                                Task { await model.updateAccount(account.id, nickname: nil, automaticSwitchEligible: value) }
                            }
                        ))
                        Divider()
                        Button("위로 이동", systemImage: "arrow.up") { moveAccount(account.id, up: true) }
                            .disabled(model.isBusy || !canMoveAccount(account.id, up: true))
                        Button("아래로 이동", systemImage: "arrow.down") { moveAccount(account.id, up: false) }
                            .disabled(model.isBusy || !canMoveAccount(account.id, up: false))
                        Divider()
                        Button("계정 삭제", systemImage: "trash", role: .destructive) { deletingAccount = account }
                    }
                    .moveDisabled(model.isBusy)
                }
                .onMove { offsets, destination in
                    Task { await model.moveAccounts(fromOffsets: offsets, toOffset: destination, visibleAccountIDs: visibleIDs) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredAccounts.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "저장된 계정 없음" : "검색 결과 없음", systemImage: search.isEmpty ? "person.crop.circle.badge.plus" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty ? "현재 CLI 로그인을 가져오거나 새 계정에 로그인하세요." : "다른 이름이나 이메일로 검색해보세요.")
                } actions: {
                    if search.isEmpty {
                        Button("계정 추가") { isAddingAccount = true }
                            .disabled(model.isLoggingIn)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isLoggingIn {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loginTitle).lineLimit(1)
                            Text(model.loginStatus ?? "브라우저에서 로그인을 완료해주세요.")
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("취소") { Task { await model.cancelLogin() } }
                    }
                    Button("로그인 페이지 다시 열기", systemImage: "arrow.up.right.square") {
                        Task { await model.openLoginPage() }
                    }
                    .controlSize(.small)
                    .disabled(!model.canOpenLoginPage || model.isOpeningLoginPage)
                    if model.loggingInProvider == .claude {
                        AuthCodeEntry(model: model)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    private var accountListFooter: some View {
        HStack(spacing: 10) {
            Text("\(filteredAccounts.count)개 계정")
                .foregroundStyle(.secondary)
            if model.isBusy {
                ProgressView().controlSize(.mini)
                Text("처리 중").foregroundStyle(.secondary)
            }
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Button {
                    statusDetails = StatusMessage(text: message)
                } label: {
                    Label("상태 메시지 전체 보기", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("상태 메시지 전체 보기")
                .accessibilityHint("전체 내용을 열어 읽고 복사합니다.")
                .popover(item: $statusDetails, arrowEdge: .bottom) { details in
                    ScrollView {
                        Text(details.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(width: 440, height: 240)
                }
            } else { Spacer(minLength: 0) }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var inspector: some View {
        if let account = selectedAccount {
            AccountDetailView(
                account: account,
                cache: model.state.usage[account.id],
                providerRetryAfter: model.state.providerRetryAfter?[account.provider],
                isActive: model.state.activeAccounts[account.provider] == account.id,
                isPending: model.pendingSwitch[account.provider] == account.id,
                needsSessionRecovery: model.claudeSessionRecoveryRequired,
                needsDesktopRecovery: model.claudeDesktopRecoveryRequired,
                compatibility: model.compatibility[account.provider],
                isBusy: model.isBusy,
                switchOperationBlockReason: model.switchOperationBlockReason(for: account.id),
                requiresExplicitApplication: model.state.requiresExplicitCredentialApplication?.contains(account.id) == true,
                onSwitch: { relaunch in Task { await model.switchAccount(account.id, relaunch: relaunch) } },
                onEdit: { editingAccount = account },
                onReauthenticate: { reauthenticatingAccount = account },
                onDelete: { deletingAccount = account },
                onEligibility: { value in Task { await model.updateAccount(account.id, nickname: nil, automaticSwitchEligible: value) } },
                onRecover: { Task { await model.recoverInterruptedSwitch(account.provider) } },
                onRecoverKeepingCurrent: { keepingCurrentRecoveryAccount = account },
                onRecoverSessions: { Task { await model.recoverInterruptedClaudeSessions() } },
                onCaptureDesktop: { Task { await model.captureClaudeDesktopLogin(account.id) } },
                onSwitchDesktop: { Task { await model.switchClaudeDesktopAccount(account.id) } },
                onRecoverDesktop: { Task { await model.recoverClaudeDesktopSwitch() } },
                onRecheckCompatibility: { Task { await model.recheckCompatibility(account.provider) } },
                onAuthorizeSavedCredential: { Task { await model.authorizeSavedCredential(account.id) } }
            )
        } else {
            ContentUnavailableView("계정 선택", systemImage: "person.crop.circle", description: Text("목록에서 계정을 선택하면 사용량과 인증 상태를 확인할 수 있습니다."))
        }
    }

    private func switchPresentation(for account: AccountRecord) -> AccountSwitchPresentation {
        AccountSwitchPresentation(
            account: account,
            isActive: model.state.activeAccounts[account.provider] == account.id,
            isPending: model.pendingSwitch[account.provider] == account.id,
            compatibility: model.compatibility[account.provider],
            isBusy: model.isBusy,
            operationBlockReason: model.switchOperationBlockReason(for: account.id)
        )
    }

    private func canMoveAccount(_ id: UUID, up: Bool) -> Bool {
        guard let index = filteredAccounts.firstIndex(where: { $0.id == id }) else { return false }
        return up ? index > 0 : index + 1 < filteredAccounts.count
    }

    private var loginTitle: String {
        if let id = model.reauthenticatingAccountID,
           let account = model.state.accounts.first(where: { $0.id == id }) {
            return "\(account.displayName) 재로그인 중"
        }
        return "\(model.loggingInProvider?.title ?? "계정") 로그인 중"
    }

    private func canMoveSelectedAccount(up: Bool) -> Bool {
        selectedID.map { canMoveAccount($0, up: up) } ?? false
    }

    private func moveSelectedAccount(up: Bool) {
        guard let selectedID else { return }
        moveAccount(selectedID, up: up)
    }

    private func moveAccount(_ id: UUID, up: Bool) {
        let visibleIDs = filteredAccounts.map(\.id)
        guard let index = visibleIDs.firstIndex(of: id), canMoveAccount(id, up: up) else { return }
        Task { await model.moveAccounts(fromOffsets: IndexSet(integer: index), toOffset: up ? index - 1 : index + 2,
                                       visibleAccountIDs: visibleIDs) }
    }
}

private struct AuthCodeEntry: View {
    let model: AppModel
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("브라우저 인증 코드", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("브라우저 인증 코드")
                    .disabled(model.isSubmittingLoginCode)
                    .onSubmit(submitCode)
                Button("코드 제출", action: submitCode)
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSubmittingLoginCode)
            }
            Text("브라우저에 표시된 전체 코드(# 뒤의 문자열 포함)를 붙여넣으세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onDisappear { code = "" }
    }

    private func submitCode() {
        let submittedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedCode.isEmpty, !model.isSubmittingLoginCode else { return }
        code = ""
        Task { await model.submitLoginCode(submittedCode) }
    }
}

private struct CurrentAccountRow: View {
    let provider: Provider
    let account: AccountRecord?
    let cache: UsageCache?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(provider.title)
            } icon: {
                ProviderBrandIcon(provider: provider)
            }
            .font(.subheadline)
            Spacer()
            Text(account?.displayName ?? "활성 계정 없음")
                .font(.subheadline)
                .lineLimit(1)
            if let remaining = cache?.snapshot?.minimumRemaining {
                Text("\(UsagePresentation.percent(remaining)) 남음")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
