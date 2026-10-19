import AgentSwapCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var isChangingLogin = false

    private var appVersionTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "AgentSwap" }
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "AgentSwap \(version)" }
        return "AgentSwap \(version) · 빌드 \(build)"
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("일반", systemImage: "gearshape") }
            automation
                .tabItem { Label("자동 전환", systemImage: "bolt") }
            compatibility
                .tabItem { Label("호환성", systemImage: "checkmark.shield") }
        }
        .padding(20)
        .frame(width: 590, height: 530)
        .tint(AppPalette.accent)
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                loginStatus = SMAppService.mainApp.status
            }
        }
    }

    private var general: some View {
        Form {
            Section("시작") {
                Toggle("로그인 시 AgentSwap 실행", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                .disabled(isChangingLogin)
                if loginStatus == .requiresApproval {
                    Text("시스템 설정에서 로그인 항목을 승인해주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("로그인 항목 설정 열기") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Text("창을 닫으면 메뉴바에서 계속 실행됩니다. 완전히 종료하려면 메뉴바의 앱 메뉴에서 종료하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("사용량 조회") {
                Picker("활성 계정", selection: intervalBinding(active: true)) {
                    Text("1분마다").tag(TimeInterval(60))
                    Text("3분마다 · 기본").tag(TimeInterval(180))
                    Text("5분마다").tag(TimeInterval(300))
                    Text("10분마다").tag(TimeInterval(600))
                }
                Picker("비활성 계정", selection: intervalBinding(active: false)) {
                    Text("5분마다").tag(TimeInterval(300))
                    Text("10분마다 · 기본").tag(TimeInterval(600))
                    Text("15분마다").tag(TimeInterval(900))
                    Text("30분마다").tag(TimeInterval(1800))
                }
                Text("요청 한도에 도달하면 제공자의 재시도 시각을 따릅니다. 조회에 실패해도 마지막 정상 값을 유지합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("보관") {
                LabeledContent("인증", value: "앱 전용 macOS Keychain")
                LabeledContent("설정 · 사용량", value: "이 Mac의 Application Support")
                LabeledContent("초기화 시각", value: "시스템 시간대")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var automation: some View {
        Form {
            ForEach(Provider.allCases) { provider in
                Section(provider.title) {
                    Toggle("자동 계정 전환", isOn: automationBinding(provider, keyPath: \.enabled))
                    HStack {
                        Text("사용률 임계치")
                        Spacer()
                        Slider(value: automationBinding(provider, keyPath: \.threshold), in: 50...100, step: 1)
                            .frame(width: 180)
                            .accessibilityLabel("\(provider.title) 사용률 임계치")
                            .disabled(model.state.settings.automation[provider]?.enabled != true)
                        Text("\(Int(model.state.settings.automation[provider]?.threshold ?? 90))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    Text("후보로 체크한 계정 중 모든 공통 창이 임계치 미만인 계정을 사용합니다. 최소 5%p 더 여유가 있을 때 전환하며, 전환 후 5분 동안은 다시 전환하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if provider == .codex {
                        Label("Codex가 실행 중이면 전환을 대기하고 사용자에게 알립니다.", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Label("자동 전환은 기본적으로 꺼져 있습니다.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                Text("모델별 부가 한도는 표시만 하며 자동 전환 판단에는 사용하지 않습니다. 오래되거나 조회에 실패한 계정은 후보에서 제외합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var compatibility: some View {
        Form {
            ForEach(Provider.allCases) { provider in
                Section(provider.title) {
                    if let status = model.compatibility[provider] {
                        Label(status.canWrite ? "인증 전환 지원" : "인증 전환 제한", systemImage: status.canWrite ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(status.canWrite ? AppPalette.accent : .orange)
                        Text(status.message).font(.caption).foregroundStyle(.secondary)
                        if !status.canWrite && status.message.contains("복원") {
                            Button("중단된 전환 복구", systemImage: "arrow.uturn.backward") {
                                Task { await model.recoverInterruptedSwitch(provider) }
                            }
                            .disabled(model.isBusy)
                        }
                    } else {
                        Text("확인 중…").foregroundStyle(.secondary)
                    }
                    if provider == .claude {
                        Text("기본 전환은 CLI 인증과 계정 정보만 교체합니다. 계정 상세에서 Desktop 로그인을 저장하면 Desktop과 CLI를 함께 전환할 수 있습니다. MCP·플러그인 인증과 계정 외 설정, 대화 원본은 보존합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("file·Keychain·auto 저장소를 지원합니다. 실행 중인 데스크톱·CLI·IDE·데몬이 종료됐는지 확인한 뒤 인증을 교체합니다. ephemeral·별도 secrets·알 수 없는 형식은 자동 변경하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section(appVersionTitle) {
                Text("기본 로컬 프로필의 구독 계정을 관리합니다. API 키, 프로젝트별 계정 실행, 클라우드 동기화와 인증 내보내기는 지원 범위에 포함되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func intervalBinding(active: Bool) -> Binding<TimeInterval> {
        Binding(
            get: { active ? model.state.settings.activePollInterval : model.state.settings.inactivePollInterval },
            set: { value in
                var settings = model.state.settings
                if active { settings.activePollInterval = value } else { settings.inactivePollInterval = value }
                Task { await model.updateSettings(settings) }
            }
        )
    }

    private func automationBinding<Value>(_ provider: Provider, keyPath: WritableKeyPath<AutomationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (model.state.settings.automation[provider] ?? AutomationSettings())[keyPath: keyPath] },
            set: { value in
                var settings = model.state.settings
                var automation = settings.automation[provider] ?? AutomationSettings()
                automation[keyPath: keyPath] = value
                settings.automation[provider] = automation
                Task { await model.updateSettings(settings) }
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        isChangingLogin = true
        loginError = nil
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                loginError = error.localizedDescription
            }
            loginStatus = SMAppService.mainApp.status
            isChangingLogin = false
        }
    }
}
