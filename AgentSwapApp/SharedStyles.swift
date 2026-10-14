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

enum UsagePresentation {
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
    static func resetCountdown(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds == 0 { return "초기화 시각 지남" }
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
                if let resetsAt = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(UsagePresentation.resetCountdown(resetsAt, now: context.date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("초기화 \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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
