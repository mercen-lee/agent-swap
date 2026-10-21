import AgentSwapCore
import SwiftUI

struct ClaudeDesktopProfilesView: View {
    let model: ClaudeDesktopProfileModel
    let search: String
    @State private var isAddingProfile = false
    @State private var showsMessage = false

    private var profiles: [ClaudeDesktopProfile] {
        model.profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("계정마다 Desktop 프로필을 하나씩 만들고, 열린 Claude Desktop에서 처음 한 번 로그인하세요. 다음부터는 프로필을 선택해 전환합니다.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("전환하면 Claude Desktop을 정상 종료한 뒤 선택한 프로필로 다시 엽니다. 로그인 갱신은 Desktop이 처리합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("기존 Code 대화는 원래 프로필에 유지됩니다. 새 프로필은 별도 대화 목록을 사용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                Section("기존 Claude Desktop") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("원래 프로필").font(.headline)
                            Text("기존 로그인과 대화가 있는 Desktop으로 돌아갑니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("기존 Desktop 열기") { Task { await model.openDefault() } }
                    }
                    .padding(.vertical, 4)
                }
                Section("계정별 Desktop 프로필") {
                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.square").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.headline)
                                Text(model.lastOpenedProfileID == profile.id ? "마지막으로 연 프로필" : "이 프로필의 로그인과 대화를 유지합니다.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("전환 및 재실행") { Task { await model.openProfile(profile.id) } }
                                .help("Claude Desktop을 정상 종료한 뒤 \(profile.name) 프로필로 엽니다.")
                        }
                        .padding(.vertical, 6)
                    }
                    if profiles.isEmpty {
                        Text(search.isEmpty ? "Desktop 프로필을 추가하세요." : "일치하는 프로필이 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .disabled(model.isBusy)
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.mini) }
                Text(model.message ?? "프로필의 로그인과 대화는 Claude Desktop이 저장합니다.")
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if model.message != nil {
                    Button { showsMessage = true } label: {
                        Label("상태 메시지 전체 보기", systemImage: "info.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showsMessage) {
                        ScrollView {
                            Text(model.message ?? "")
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .frame(width: 440, height: 240)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Desktop 프로필 추가", systemImage: "plus") { isAddingProfile = true }
                    .disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $isAddingProfile) {
            AddDesktopProfileSheet(model: model)
        }
    }
}

private struct AddDesktopProfileSheet: View {
    let model: ClaudeDesktopProfileModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Desktop 프로필 추가").font(.headline)
            TextField("프로필 이름 (예: 개인, 업무)", text: $name)
            Text("추가한 프로필에서 전환 및 재실행을 누르고, Claude Desktop에서 사용할 계정으로 로그인하세요.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("추가") {
                    let submittedName = name
                    dismiss()
                    Task { await model.addProfile(name: submittedName) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
