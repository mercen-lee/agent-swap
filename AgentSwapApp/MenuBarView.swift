import AppKit
import AgentSwapCore
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AgentSwap").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.mini) }
                Button {
                    Task { await model.refreshAll() }
                } label: { Label("새로고침", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help("모든 계정 새로고침")
            }
            if model.isLoggingIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(model.loggingInProvider?.title ?? "계정") 로그인 중")
                        .font(.subheadline)
                    Spacer()
                    Button("취소") { Task { await model.cancelLogin() } }
                        .controlSize(.small)
                }
                Text(model.loggingInProvider == .claude ? "브라우저 인증 코드 입력은 대시보드에서 진행하세요." : "브라우저에서 로그인을 완료해주세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("로그인 페이지 다시 열기", systemImage: "arrow.up.right.square") {
                    Task { await model.openLoginPage() }
                }
                .controlSize(.small)
                .disabled(!model.canOpenLoginPage || model.isOpeningLoginPage)
            }
            Divider()
            HStack {
                Label {
                    Text("Claude Desktop")
                } icon: {
                    ProviderBrandIcon(provider: .claude)
                }
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu("프로필 열기") {
                    Button("기존 Desktop 열기") { Task { await model.claudeDesktopProfiles.openDefault() } }
                    ForEach(model.claudeDesktopProfiles.profiles) { profile in
                        Button(profile.name) { Task { await model.claudeDesktopProfiles.openProfile(profile.id) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.claudeDesktopProfiles.isBusy)
            }
            if model.claudeDesktopProfiles.profiles.isEmpty {
                Text("대시보드의 Claude Desktop에서 프로필을 추가하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.claudeDesktopProfiles.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(Provider.allCases) { provider in
                Divider()
                providerSection(provider)
            }
            if let message = model.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.claudeSessionRecoveryRequired {
                Button("중단된 대화 목록 복구", systemImage: "arrow.uturn.backward") {
                    Task { await model.recoverInterruptedClaudeSessions() }
                }
                .disabled(model.isBusy)
            }
            if model.claudeDesktopRecoveryRequired {
                Button("중단된 Desktop 전환 복구", systemImage: "arrow.uturn.backward") {
                    Task { await model.recoverClaudeDesktopSwitch() }
                }
                .disabled(model.isBusy)
            }
            Divider()
            HStack {
                Button("대시보드 열기", systemImage: "rectangle.on.rectangle") {
                    openWindow(id: "dashboard")
                    NSApplication.shared.activate()
                }
                Spacer()
                Menu {
                    Button("업데이트 확인…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Button("설정…") {
                        openSettings()
                        NSApplication.shared.activate()
                    }
                    Divider()
                    Button("AgentSwap 종료") { NSApplication.shared.terminate(nil) }
                } label: { Label("앱 메뉴", systemImage: "ellipsis") }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let accounts = model.state.accounts.filter { $0.provider == provider }
        let active = accounts.first { $0.id == model.state.activeAccounts[provider] }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(provider.title)
                } icon: {
                    ProviderBrandIcon(provider: provider)
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                if !accounts.isEmpty {
                    Menu("전환") {
                        ForEach(accounts) { account in
                            let presentation = switchPresentation(for: account)
                            Button {
                                Task { await model.switchAccount(account.id, relaunch: presentation.requiresRelaunch) }
                            } label: {
                                if presentation.requiresRelaunch { Text("\(account.displayName) · \(presentation.title)") }
                                else if account.id == active?.id { Label(account.displayName, systemImage: "checkmark") }
                                else { Text(account.displayName) }
                            }
                            .disabled(!presentation.canSwitch)
                            .help(presentation.help)
                            .accessibilityHint(presentation.help)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Text(active?.displayName ?? "활성 계정 없음")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if let active, let snapshot = model.state.usage[active.id]?.snapshot {
                if snapshot.commonWindows.isEmpty {
                    Text("공통 한도가 반환되지 않았습니다.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.commonWindows) { window in UsageProgress(window: window, compact: true) }
                }
                if model.state.usage[active.id]?.error != nil {
                    Label("조회 실패 · 마지막 정상 값", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                if let active, let error = model.state.usage[active.id]?.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(accounts.isEmpty ? "대시보드에서 계정을 추가하세요." : "사용량 조회 대기")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let pendingID = model.pendingSwitch[provider], let pending = accounts.first(where: { $0.id == pendingID }) {
                let presentation = switchPresentation(for: pending)
                Label("\(pending.displayName) 전환 대기", systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange)
                Text(provider == .codex ? "별도 CLI·IDE를 종료한 뒤 진행해주세요." : "현재 인증 상태를 다시 확인한 뒤 전환하세요. 기존 대화 파일과 목록은 변경하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(presentation.title) {
                    Task { await model.switchAccount(pendingID, relaunch: true) }
                }
                .disabled(!presentation.canSwitch)
                .help(presentation.help)
                .accessibilityHint(presentation.help)
                if let reason = presentation.disabledReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func switchPresentation(for account: AccountRecord) -> AccountSwitchPresentation {
        AccountSwitchPresentation(
            account: account,
            isActive: model.state.activeAccounts[account.provider] == account.id,
            isPending: model.pendingSwitch[account.provider] == account.id,
            compatibility: model.compatibility[account.provider],
            isBusy: model.isBusy,
            operationBlockReason: model.switchOperationBlockReason
        )
    }
}
