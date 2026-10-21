import AgentSwapCore
import AppKit
import Combine
import Sparkle

/// One updater belongs to the application, independently of window and menu lifetimes.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    let isAvailable: Bool
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var startupTask: Task<Void, Never>?
    private var scheduledDiscovery: Task<Void, Never>?
    private var started = false
    private var feedURL: URL?
    private let includePrereleases: Bool
    private let discovery = GitHubReleaseDiscovery()

    init(isDemo: Bool = false) {
        let bundle = Bundle.main
        let tag = bundle.object(forInfoDictionaryKey: "AgentSwapReleaseTag") as? String
        includePrereleases = GitHubReleaseFeed.includesPrereleases(installedTag: tag)
        let expectedFeed = tag.flatMap(GitHubReleaseFeed.url(for:))
        let configuredFeed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isAvailable = !isDemo && expectedFeed != nil && expectedFeed?.absoluteString == configuredFeed &&
            key.flatMap { Data(base64Encoded: $0) }?.count == 32
        feedURL = expectedFeed
        super.init()
        guard isAvailable else {
            statusMessage = isDemo ? "데모에서는 업데이트를 확인하지 않습니다." : "업데이트는 정식 릴리즈 빌드에서 사용할 수 있습니다."
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        if let updater = controller?.updater {
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        }
    }

    func start() {
        guard isAvailable, !started, startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            // Start with a fresh discovery before Sparkle's first scheduled check. Respect
            // Sparkle's existing user preference when background checks are disabled.
            if automaticallyChecksForUpdates { _ = await refreshFeed(reportFailure: false) }
            guard !Task.isCancelled else { return }
            controller?.startUpdater()
            started = true
            observeUpdater()
            startupTask = nil
        }
    }

    func checkForUpdates() {
        guard isAvailable, started, !isDiscovering,
              controller?.updater.canCheckForUpdates == true else { return }
        Task { [weak self] in
            guard let self, await refreshFeed(reportFailure: true) else { return }
            controller?.checkForUpdates(nil)
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL?.absoluteString
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        scheduledDiscovery?.cancel()
        // Sparkle owns the update schedule. Resolve the newest GitHub-hosted feed
        // shortly before its check instead of adding a second update scheduler.
        let wait = min(max(delay - 60, 0), 31_536_000)
        scheduledDiscovery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) }
            catch { return }
            guard let self, updater.automaticallyChecksForUpdates else { return }
            _ = await refreshFeed(reportFailure: false)
        }
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        scheduledDiscovery?.cancel()
        scheduledDiscovery = nil
    }

    private func refreshFeed(reportFailure: Bool) async -> Bool {
        guard !isDiscovering else { return false }
        isDiscovering = true
        updateCheckAvailability()
        defer {
            isDiscovering = false
            updateCheckAvailability()
        }
        do {
            feedURL = try await discovery.latestFeed(includePrereleases: includePrereleases).url
            statusMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if reportFailure {
                statusMessage = (error as? GitHubReleaseDiscoveryError)?.message ?? "GitHub 업데이트를 확인하지 못했습니다. 네트워크 연결을 확인하고 다시 시도하세요."
            }
            return false
        }
    }

    private func observeUpdater() {
        guard let updater = controller?.updater else { return }
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateCheckAvailability() }
            }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = value }
            }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.automaticallyDownloadsUpdates = value }
            }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.lastUpdateCheckDate = value }
            }.store(in: &subscriptions)
        updateCheckAvailability()
    }

    private func updateCheckAvailability() {
        canCheckForUpdates = started && !isDiscovering && controller?.updater.canCheckForUpdates == true
    }
}

private actor GitHubReleaseDiscovery {
    private let session: URLSession
    private var retryAfter: Date?
    private var etag: String?
    private var cachedFeed: GitHubReleaseFeed?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func latestFeed(includePrereleases: Bool) async throws -> GitHubReleaseFeed {
        if let retryAfter, retryAfter > Date() { throw GitHubReleaseDiscoveryError.rateLimited }
        var request = URLRequest(url: GitHubReleaseFeed.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AgentSwap-Updater", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubReleaseDiscoveryError.invalidResponse }
        if response.statusCode == 304, let cachedFeed { return cachedFeed }
        guard response.statusCode == 200 else {
            if response.statusCode == 403 || response.statusCode == 429 {
                let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                retryAfter = max(Date().addingTimeInterval(max(seconds ?? 60, 60)), reset.map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
                throw GitHubReleaseDiscoveryError.rateLimited
            }
            throw GitHubReleaseDiscoveryError.invalidResponse
        }
        guard response.expectedContentLength <= GitHubReleaseFeed.maximumResponseSize else {
            throw GitHubReleaseFeedError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < GitHubReleaseFeed.maximumResponseSize else { throw GitHubReleaseFeedError.responseTooLarge }
            data.append(byte)
        }
        guard let feed = try GitHubReleaseFeed.select(from: data, includePrereleases: includePrereleases) else {
            throw GitHubReleaseDiscoveryError.noPublishedFeed
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        cachedFeed = feed
        retryAfter = nil
        return feed
    }
}

private enum GitHubReleaseDiscoveryError: Error {
    case invalidResponse, noPublishedFeed, rateLimited

    var message: String {
        switch self {
        case .invalidResponse: "GitHub 업데이트 정보를 읽지 못했습니다. 잠시 후 다시 시도하세요."
        case .noPublishedFeed: "게시된 업데이트 피드를 찾지 못했습니다. 잠시 후 다시 시도하세요."
        case .rateLimited: "GitHub 요청 한도에 도달했습니다. 제공자의 재시도 시각 이후 다시 시도하세요."
        }
    }
}
