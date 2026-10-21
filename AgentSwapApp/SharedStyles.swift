import AgentSwapCore
import SwiftUI

enum AppPalette {
    static let accent = Color.accentColor
    static func usageColor(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .accentColor
    }
}

/// Bundled vector artwork; it never requires a network request to draw a provider.
struct ProviderBrandIcon: View {
    let provider: Provider
    var size: CGFloat = 16
    var isSelected = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var controlActiveState

    private var usesSelectionForeground: Bool { isSelected && controlActiveState != .inactive }

    var body: some View {
        Group {
            switch provider {
            case .claude:
                Image("ClaudeBrand")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(usesSelectionForeground ? Color.primary : claudeColor)
            case .codex:
                Image("OpenAIBrand")
                    .resizable()
                    .renderingMode(usesSelectionForeground ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    // The official artwork includes its clear space in the SVG canvas.
                    .frame(width: size * 1.5, height: size * 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var claudeColor: Color {
        // Keep the canonical terracotta normally; use semantic text contrast when requested.
        contrast == .increased ? .primary : Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    }
}

enum UsagePresentation {
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
    static func resetCountdown(_ date: Date, now: Date) -> String {
        if date <= now { return "초기화 시각 지남" }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)일 \(hours)시간 후" }
        if hours > 0 { return "\(hours)시간 \(minutes)분 후" }
        if minutes > 0 { return "\(minutes)분 후" }
        return "1분 이내"
    }
    static func authenticationLabel(_ state: AuthenticationState) -> String {
        switch state {
        case .valid: "정상"
        case .expired: "토큰 만료"
        case .needsLogin: "다시 로그인 필요"
        case .unsupported: "지원하지 않는 인증"
        }
    }
}

struct AccountSwitchPresentation {
    enum BlockReason {
        case currentAccount
        case busy
        case operation(String)
        case authentication(AuthenticationState)
        case checkingCompatibility
        case compatibility(String)

        var message: String {
            switch self {
            case .currentAccount:
                "이미 현재 계정입니다."
            case .busy:
                "다른 작업이 진행 중입니다. 완료 후 전환하세요."
            case .operation(let message):
                message
            case .authentication(.expired):
                "인증이 만료되었습니다. 새로고침하거나 다시 로그인한 뒤 전환하세요."
            case .authentication(.needsLogin):
                "다시 로그인해야 합니다. 계정 추가에서 이 계정에 로그인하세요."
            case .authentication(.unsupported):
                "지원하지 않는 인증 형식으로 전환할 수 없습니다."
            case .authentication(.valid):
                "인증 상태를 다시 확인하세요."
            case .checkingCompatibility:
                "전환 호환성을 확인 중입니다. 잠시 후 다시 시도하세요."
            case .compatibility(let message):
                "전환할 수 없습니다. \(message)"
            }
        }
    }

    let title: String
    let requiresRelaunch: Bool
    let blockReason: BlockReason?

    init(account: AccountRecord, isActive: Bool, isPending: Bool, compatibility: CompatibilityStatus?, isBusy: Bool, operationBlockReason: String?) {
        requiresRelaunch = isPending && account.provider == .codex
        title = isPending ? (account.provider == .codex ? "전환 및 재실행" : "다시 전환") : (isActive ? "현재 계정" : "계정 전환")
        if isActive && !isPending {
            blockReason = .currentAccount
        } else if let operationBlockReason {
            blockReason = .operation(operationBlockReason)
        } else if isBusy {
            blockReason = .busy
        } else if account.authenticationState != .valid {
            blockReason = .authentication(account.authenticationState)
        } else if let compatibility {
            blockReason = compatibility.canWrite ? nil : .compatibility(compatibility.message)
        } else {
            blockReason = .checkingCompatibility
        }
    }

    var canSwitch: Bool {
        if case nil = blockReason { true } else { false }
    }
    var disabledReason: String? { blockReason?.message }
    var help: String { disabledReason ?? (requiresRelaunch ? title : "선택한 계정으로 전환합니다.") }
    var displaysCompatibilityReason: Bool {
        if case .compatibility(_)? = blockReason { true } else { false }
    }
}

enum ClaudeConversationHelp {
    static let url = URL(string: "https://code.claude.com/docs/en/desktop#coming-from-the-cli")!
}

struct UsageProgress: View {
    let window: UsageWindow
    var compact = false
    var isSelected = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(window.usedPercent.map(UsagePresentation.percent) ?? "확인 불가")
                    .monospacedDigit()
            }
            .font(.caption)
            if let used = window.usedPercent {
                ProgressView(value: max(0, min(100, used)), total: 100)
                    .progressViewStyle(UsageMeterStyle(
                        color: isSelected && controlActiveState != .inactive ? .white : AppPalette.usageColor(used)
                    ))
                    .accessibilityLabel("\(window.title) 사용률")
                    .accessibilityValue(UsagePresentation.percent(used))
            } else {
                Text("사용률이 반환되지 않았습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact {
                if let remaining = window.remainingPercent {
                    Text("\(UsagePresentation.percent(remaining)) 남음")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            UsageResetInfo(resetsAt: window.resetsAt, compact: compact)
        }
    }
}

private struct UsageResetInfo: View {
    let resetsAt: Date?
    let compact: Bool

    var body: some View {
        Group {
            if let resetsAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(resetsAt > context.date
                         ? "\(UsagePresentation.resetCountdown(resetsAt, now: context.date)) 초기화"
                         : "초기화 시각 지남 · 갱신 대기")
                }
                Text(compact
                     ? resetsAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                     : "초기화 \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .help(resetsAt.formatted(.dateTime.year().month().day().hour().minute().timeZone(.specificName(.short))))
            } else {
                Text("초기화 시각 미제공")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Keep the semantic ProgressView while drawing its meter entirely in SwiftUI.
/// The AppKit-backed linear style can synchronously reenter a List's accessibility
/// tree from updateNSView on macOS 27, creating an AttributeGraph cycle.
private struct UsageMeterStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * max(0, min(1, configuration.fractionCompleted ?? 0)))
            }
        }
        .frame(height: 6)
    }
}
