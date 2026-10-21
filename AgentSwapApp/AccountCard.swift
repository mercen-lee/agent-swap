import AgentSwapCore
import SwiftUI

struct AccountRow: View {
    let account: AccountRecord
    let cache: UsageCache?
    let isActive: Bool
    let isPending: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                ProviderBrandIcon(provider: account.provider, isSelected: isSelected)
                Text(account.displayName).font(.headline).lineLimit(1)
                if isActive {
                    Label("현재", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isPending {
                    Label(account.provider == .codex ? "재실행 대기" : "전환 대기", systemImage: "clock")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(cache?.snapshot?.plan ?? account.plan)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text([account.provider.title, account.email, account.workspaceName.isEmpty ? account.identity.workspaceID : account.workspaceName]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let snapshot = cache?.snapshot, !snapshot.commonWindows.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        ForEach(snapshot.commonWindows) { window in
                            UsageProgress(window: window, compact: true, isSelected: isSelected).frame(minWidth: 115)
                        }
                    }
                    VStack(spacing: 8) {
                        ForEach(snapshot.commonWindows) { window in UsageProgress(window: window, compact: true, isSelected: isSelected) }
                    }
                }
            } else if cache?.snapshot != nil {
                Text("공통 한도가 반환되지 않았습니다.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("사용량 조회 대기").font(.caption).foregroundStyle(.secondary)
            }
            if cache?.error != nil {
                Label(cache?.snapshot == nil ? "조회 실패" : "조회 실패 · 마지막 정상 값", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if account.authenticationState != .valid {
                Label(UsagePresentation.authenticationLabel(account.authenticationState), systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
    }
}

struct AccountDetailView: View {
    let account: AccountRecord
    let cache: UsageCache?
    let isActive: Bool
    let isPending: Bool
    let needsSessionRecovery: Bool
    let needsDesktopRecovery: Bool
    let compatibility: CompatibilityStatus?
    let isBusy: Bool
    let switchOperationBlockReason: String?
    let onSwitch: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onEligibility: @MainActor @Sendable (Bool) -> Void
    let onRecover: () -> Void
    let onRecoverKeepingCurrent: () -> Void
    let onRecoverSessions: () -> Void
    let onCaptureDesktop: () -> Void
    let onSwitchDesktop: () -> Void
    let onRecoverDesktop: () -> Void
    let onRecheckCompatibility: () -> Void
    let onAuthorizeSavedCredential: () -> Void

    private var switchPresentation: AccountSwitchPresentation {
        AccountSwitchPresentation(account: account, isActive: isActive, isPending: isPending, compatibility: compatibility, isBusy: isBusy, operationBlockReason: switchOperationBlockReason)
    }

    var body: some View {
        Form {
            Section(account.displayName) {
                LabeledContent("제공자") {
                    Label {
                        Text(account.provider.title)
                    } icon: {
                        ProviderBrandIcon(provider: account.provider)
                    }
                }
                if !account.email.isEmpty { LabeledContent("이메일", value: account.email).textSelection(.enabled) }
                LabeledContent("워크스페이스", value: account.workspaceName.isEmpty ? account.identity.workspaceID : account.workspaceName)
                    .textSelection(.enabled)
                let plan = cache?.snapshot?.plan ?? account.plan
                if !plan.isEmpty { LabeledContent("플랜", value: plan) }
                LabeledContent("인증", value: UsagePresentation.authenticationLabel(account.authenticationState))
                if isActive { Label("현재 활성 계정", systemImage: "checkmark.circle") }
                Toggle("자동 전환 후보", isOn: Binding(get: { account.automaticSwitchEligible }, set: onEligibility))
            }
            if let snapshot = cache?.snapshot {
                if !snapshot.commonWindows.isEmpty {
                    Section("공통 사용량") {
                        ForEach(snapshot.commonWindows) { window in UsageProgress(window: window) }
                    }
                }
                let modelWindows = snapshot.windows.filter { $0.kind == .model }
                if !modelWindows.isEmpty {
                    Section("모델별 사용량") {
                        ForEach(modelWindows) { window in UsageProgress(window: window) }
                        Text("자동 전환 판단에는 사용하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                let additionalWindows = snapshot.windows.filter { $0.kind == .additional }
                if !additionalWindows.isEmpty {
                    Section("추가 한도") {
                        ForEach(additionalWindows) { window in UsageProgress(window: window) }
                    }
                }
                if !snapshot.extras.isEmpty {
                    Section("추가 사용 정보") {
                        ForEach(snapshot.extras) { extra in LabeledContent(extra.title, value: extra.value) }
                    }
                }
            } else {
                Section("사용량") {
                    Text("조회가 완료되면 사용률과 초기화 시각을 표시합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("조회 상태") {
                if let fetchedAt = cache?.snapshot?.fetchedAt {
                    LabeledContent("최근 정상 조회") {
                        Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                if let attemptedAt = cache?.attemptedAt, cache?.error != nil {
                    LabeledContent("최근 시도") { Text(attemptedAt, format: .dateTime.month().day().hour().minute()) }
                }
                if let error = cache?.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    if cache?.snapshot != nil {
                        Text("마지막 정상 조회값을 유지합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let retry = cache?.retryAfter, retry > .now {
                    LabeledContent("재시도 시각") { Text(retry, format: .dateTime.hour().minute()) }
                }
                if cache == nil { Text("조회 대기").foregroundStyle(.secondary) }
                Button("저장된 인증 접근 허용", systemImage: "key", action: onAuthorizeSavedCredential)
                    .disabled(isBusy)
                Text("이 계정의 저장된 인증만 읽습니다. 허용 후 새로고침하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("전환 호환성") {
                if let compatibility {
                    if !switchPresentation.displaysCompatibilityReason {
                        Label(compatibility.message, systemImage: compatibility.canWrite ? "checkmark.shield" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !compatibility.canWrite && compatibility.message.contains("복원") {
                        Button("중단된 전환 복구", systemImage: "arrow.uturn.backward", action: onRecover).disabled(isBusy)
                        if account.provider == .claude && isActive {
                            Button("현재 로그인 유지하고 복구", systemImage: "person.crop.circle.badge.checkmark", action: onRecoverKeepingCurrent)
                                .disabled(isBusy)
                        }
                    }
                } else { Text("확인 중…").foregroundStyle(.secondary) }
                if compatibility?.canWrite != true {
                    Button("전환 호환성 다시 확인", systemImage: "arrow.clockwise", action: onRecheckCompatibility)
                        .disabled(isBusy)
                        .help("현재 인증 저장소의 전환 가능 여부를 다시 확인합니다.")
                }
                if isPending {
                    if account.provider == .codex {
                        Text("별도 CLI·IDE를 종료해주세요. 전환 및 재실행을 누르면 Codex를 정상 종료하고 인증을 교체한 뒤 데스크톱 앱을 다시 엽니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("현재 인증 상태를 다시 확인한 뒤 전환하세요. 기존 대화 파일과 목록은 변경하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if account.provider == .claude {
                Section("Desktop 연동") {
                    Text("처음 한 번, 각 계정으로 Claude Desktop에 로그인한 뒤 이 계정의 로그인을 저장하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("이 계정의 Desktop 로그인 저장", systemImage: "person.crop.circle.badge.checkmark", action: onCaptureDesktop)
                        .disabled(isBusy)
                    Button("Desktop과 CLI 함께 전환", systemImage: "arrow.triangle.swap", action: onSwitchDesktop)
                        .disabled(isBusy || compatibility?.canWrite != true || account.authenticationState != .valid)
                    Text("Desktop을 정상 종료한 뒤 선택한 로그인과 기존 Code 대화 목록을 적용하고 다시 엽니다. 대화 원본은 유지합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if needsDesktopRecovery {
                        Button("중단된 Desktop 전환 복구", systemImage: "arrow.uturn.backward", action: onRecoverDesktop)
                            .disabled(isBusy)
                    }
                }
                Section("대화 이어가기") {
                    if needsSessionRecovery {
                        Button("중단된 대화 목록 복구", systemImage: "arrow.uturn.backward", action: onRecoverSessions)
                            .disabled(isBusy)
                    }
                    Text("기본 계정 전환은 Claude Code CLI 인증만 바꿉니다. Desktop까지 바꾸려면 위의 함께 전환을 사용하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("터미널에서 대화 선택") {
                        Text("claude --resume").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Text("Desktop Code 탭에서 /resume로 CLI 대화를 선택할 수도 있습니다. 일반 계정 전환과 자동 전환은 Desktop 대화 목록을 변경하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("공식 대화 재개 안내", destination: ClaudeConversationHelp.url)
                }
            }
            Section {
                Button("계정 삭제", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            AccountActionBar(
                presentation: switchPresentation,
                onSwitch: { onSwitch(switchPresentation.requiresRelaunch) },
                onEdit: onEdit
            )
            .padding(12)
        }
    }
}

private struct AccountActionBar: View {
    let presentation: AccountSwitchPresentation
    let onSwitch: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = presentation.disabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .help(presentation.help)
    }

    @ViewBuilder
    private var controls: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("별명", systemImage: "pencil", action: onEdit).buttonStyle(.glass)
                    Spacer(minLength: 0)
                    Button(presentation.title, systemImage: "arrow.left.arrow.right", action: onSwitch)
                        .buttonStyle(.glassProminent)
                        .disabled(!presentation.canSwitch)
                        .accessibilityHint(presentation.help)
                }
            }
        } else {
            HStack(spacing: 8) {
                Button("별명", systemImage: "pencil", action: onEdit)
                Spacer(minLength: 0)
                Button(presentation.title, systemImage: "arrow.left.arrow.right", action: onSwitch)
                    .buttonStyle(.borderedProminent)
                    .disabled(!presentation.canSwitch)
                    .accessibilityHint(presentation.help)
            }
        }
    }
}

private enum AddAccountMethod: String, CaseIterable, Identifiable {
    case browser, current
    var id: String { rawValue }
    var title: String { self == .browser ? "새 계정에 로그인" : "현재 CLI 로그인 가져오기" }
}

struct AddAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var method: AddAccountMethod = .browser

    init(model: AppModel, initialProvider: Provider) {
        self.model = model
        _provider = State(initialValue: initialProvider)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("계정 추가") {
                    Picker("제공자", selection: $provider) {
                        ForEach(Provider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    Picker("추가 방법", selection: $method) {
                        ForEach(AddAccountMethod.allCases) { method in Text(method.title).tag(method) }
                    }
                    .pickerStyle(.radioGroup)
                }
                Section {
                    if method == .browser {
                        Text("공식 CLI와 브라우저로 로그인합니다. 격리된 임시 프로필을 사용하고 완료한 인증은 Keychain에 저장합니다.")
                    } else {
                        Text("이 Mac의 기본 프로필에 로그인된 계정을 가져옵니다. 이미 등록된 계정은 인증을 갱신합니다.")
                    }
                    Text("기본 로컬 프로필의 구독 로그인만 지원합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let compatibility = model.compatibility[provider], !compatibility.canWrite {
                    Section("호환성") {
                        Label(compatibility.message, systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button(method == .browser ? "로그인" : "가져오기", action: addAccount)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.isLoggingIn)
            }
            .padding()
        }
        .frame(width: 430, height: 340)
    }

    private func addAccount() {
        let selectedProvider = provider
        let selectedMethod = method
        dismiss()
        Task {
            if selectedMethod == .browser { await model.login(selectedProvider) }
            else { await model.importCurrent(selectedProvider) }
        }
    }
}

struct EditAccountSheet: View {
    let account: AccountRecord
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String

    init(account: AccountRecord, onSave: @escaping (String) -> Void) {
        self.account = account
        self.onSave = onSave
        _nickname = State(initialValue: account.nickname)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("계정 별명").font(.headline)
            Text(account.email.isEmpty ? account.provider.title : account.email)
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("별명", text: $nickname).textFieldStyle(.roundedBorder)
            Text("비워두면 이메일을 계정 이름으로 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") {
                    onSave(nickname.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
