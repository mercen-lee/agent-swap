import AppKit
import AgentSwapCore
import Darwin
import SwiftUI

@main
struct AgentSwapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AgentSwapApp.isDemo
        ? AppModel.preview(claudeSessionIncompatible: AgentSwapApp.demoSessionIncompatible)
        : AppModel.live()

    fileprivate static var isDemo: Bool {
        CommandLine.arguments.contains("--demo") ||
        (Bundle.main.object(forInfoDictionaryKey: "AgentSwapDemoMode") as? Bool == true)
    }

    private static var demoSessionIncompatible: Bool {
        isDemo && (CommandLine.arguments.contains("--demo-session-incompatible") ||
                   Bundle.main.object(forInfoDictionaryKey: "AgentSwapDemoSessionIncompatible") as? Bool == true)
    }

    private static var demoAppearance: ColorScheme? {
        guard isDemo else { return nil }
        switch Bundle.main.object(forInfoDictionaryKey: "AgentSwapDemoAppearance") as? String {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private static var initialWindowSize: CGSize {
        demoNarrow ? CGSize(width: 760, height: 520) : CGSize(width: 960, height: 680)
    }

    fileprivate static var demoNarrow: Bool {
        isDemo && (CommandLine.arguments.contains("--demo-narrow") ||
                   Bundle.main.object(forInfoDictionaryKey: "AgentSwapDemoNarrow") as? Bool == true)
    }

    private var needsAttention: Bool {
        !model.attentionProviders.isEmpty || !model.pendingSwitch.isEmpty
    }

    var body: some Scene {
        WindowGroup("AgentSwap", id: "dashboard") {
            DashboardView(model: model)
                .preferredColorScheme(AgentSwapApp.demoAppearance)
                .frame(minWidth: 760, minHeight: 520)
                .disabled(!appDelegate.canStartModel)
                .task { await appDelegate.start(model: model) }
        }
        .defaultSize(AgentSwapApp.initialWindowSize)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("모든 계정 새로고침") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!appDelegate.canStartModel || model.isBusy)
            }
        }

        MenuBarExtra(needsAttention ? "AgentSwap · 확인 필요" : "AgentSwap", systemImage: needsAttention ? "exclamationmark.circle" : "arrow.triangle.swap") {
            MenuBarView(model: model)
                .preferredColorScheme(AgentSwapApp.demoAppearance)
                .disabled(!appDelegate.canStartModel)
                .task { await appDelegate.start(model: model) }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(AgentSwapApp.demoAppearance)
                .disabled(!appDelegate.canStartModel)
                .task { await appDelegate.start(model: model) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var canStartModel = false
    private var model: AppModel?
    private var instanceLock: AppInstanceLock?
    private var hasPreparedLaunch = false
    private var isWaitingForTermination = false
    private var hasSizedDemoWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        prepareLaunch()
    }

    func start(model: AppModel) async {
        prepareLaunch()
        guard canStartModel else { return }
        self.model = model
        await model.start()
        // A restored window frame otherwise overrides defaultSize, making --demo-narrow
        // silently reuse the previous large window during layout verification.
        if AgentSwapApp.demoNarrow, !hasSizedDemoWindow,
           let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.resizable) }) {
            window.setContentSize(NSSize(width: 760, height: 520))
            hasSizedDemoWindow = true
        }
    }

    private func prepareLaunch() {
        guard !hasPreparedLaunch else { return }
        hasPreparedLaunch = true
        // Fixture instances use memory-only stores and never join the live engine's lock.
        guard !AgentSwapApp.isDemo else { canStartModel = true; return }

        do {
            instanceLock = try AppInstanceLock.acquire()
            // Local development copies may lack the guard. Yield before starting another engine.
            if let existing = existingLiveApplications().first(where: { application in
                guard let url = application.bundleURL else { return true }
                return Bundle(url: url)?.object(forInfoDictionaryKey: "AgentSwapSingleInstanceGuard") as? Bool != true
            }) {
                instanceLock = nil
                finishSecondaryLaunch(activating: existing)
                return
            }
            canStartModel = true
        } catch AppInstanceLockError.alreadyRunning {
            let owner = AppInstanceLock.ownerProcessID().flatMap { NSRunningApplication(processIdentifier: $0) }
            let existing = owner.flatMap { isLiveAgentSwap($0) ? $0 : nil } ?? existingLiveApplications().first
            finishSecondaryLaunch(activating: existing)
        } catch {
            // A lock failure must never fall through to shared metadata or credential writes.
            Task { @MainActor in
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "AgentSwap을 시작하지 못했습니다"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "종료")
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func finishSecondaryLaunch(activating existing: NSRunningApplication?) {
        Task { @MainActor in
            existing?.activate(options: [])
            NSApplication.shared.terminate(nil)
        }
    }

    private func existingLiveApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isLiveAgentSwap).sorted {
            let first = $0.launchDate ?? .distantPast
            let second = $1.launchDate ?? .distantPast
            return first == second ? $0.processIdentifier < $1.processIdentifier : first < second
        }
    }

    private func isLiveAgentSwap(_ application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != getpid(), !application.isTerminated,
              let identifier = application.bundleIdentifier,
              identifier == "net.mercen.agentswap" else { return false }
        if let url = application.bundleURL,
           Bundle(url: url)?.object(forInfoDictionaryKey: "AgentSwapDemoMode") as? Bool == true { return false }
        return !hasDemoArgument(processID: application.processIdentifier)
    }

    /// Read only the demo flag; never log or retain another process's arguments.
    private func hasDemoArgument(processID: pid_t) -> Bool {
        var query = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &bytes, &size, nil, 0) == 0 else { return false }
        return bytes.withUnsafeBytes { buffer in
            let count = Int(buffer.loadUnaligned(as: Int32.self))
            guard count > 0, count <= 1_024 else { return false }
            var offset = MemoryLayout<Int32>.size
            while offset < size, bytes[offset] != 0 { offset += 1 } // Executable path.
            while offset < size, bytes[offset] == 0 { offset += 1 }
            let flag = Array("--demo".utf8)
            for _ in 0..<count {
                let start = offset
                while offset < size, bytes[offset] != 0 { offset += 1 }
                if bytes[start..<offset].elementsEqual(flag) { return true }
                guard offset < size else { return false }
                offset += 1
            }
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !isWaitingForTermination else { return .terminateLater }
        isWaitingForTermination = true
        Task {
            let mayTerminate = await model.prepareForTermination()
            isWaitingForTermination = false
            sender.reply(toApplicationShouldTerminate: mayTerminate)
        }
        return .terminateLater
    }
}
