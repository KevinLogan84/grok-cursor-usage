import Foundation
import Observation

/// A newer public release, if GitHub has one. Notes are the release body unchanged.
struct AppUpdateNotice: Equatable, Codable, Sendable {
    var tagName: String
    var notes: String
    var downloadURL: URL

    var versionLabel: String {
        AppUpdate.versionLabel(for: tagName)
    }
}

enum AppUpdateCheckResult: Equatable, Sendable {
    case failed
    case upToDate
    case available(AppUpdateNotice)
}

/// Pure check against GitHub's latest-release JSON. No network, no user data.
enum AppUpdate {
    static let owner = "KevinLogan84"
    static let repo = "grok-cursor-usage"
    static let zipAssetName = "Grok-Cursor-Usage-macOS.zip"
    static let userAgent = "GrokCursorUsage"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
    )!

    /// True when a check is allowed. A missing stamp, a full day, or a clock
    /// moved backwards all count as due. Anything newer than a day ago waits.
    static func shouldCheck(
        lastCheckedAt: Date?,
        now: Date,
        interval: TimeInterval = checkInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        if lastCheckedAt > now { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    static func waitInterval(
        lastCheckedAt: Date?,
        now: Date,
        interval: TimeInterval = checkInterval
    ) -> TimeInterval {
        guard let lastCheckedAt,
              !shouldCheck(lastCheckedAt: lastCheckedAt, now: now, interval: interval)
        else { return 0 }
        return interval - now.timeIntervalSince(lastCheckedAt)
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latestVersion = SemanticVersion(latest),
              let currentVersion = SemanticVersion(current)
        else { return false }
        return latestVersion > currentVersion
    }

    static func versionLabel(for tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" {
            text.removeFirst()
        }
        return "v\(text)"
    }

    static func marketingVersion(bundle: Bundle = .main) -> String {
        let value = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let value, !value.isEmpty else { return "0" }
        return value
    }

    /// Unauthenticated GET. No body, no token, no account, no usage.
    static func makeRequest() -> URLRequest {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return config
    }

    /// Parses a latest-release payload. Nil for malformed JSON, a missing tag,
    /// or a tag that is not a version. The download URL prefers the macOS zip,
    /// then the release page.
    static func parseRelease(_ data: Data) -> AppUpdateNotice? {
        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
            return nil
        }
        let tag = payload.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SemanticVersion(tag) != nil else { return nil }
        return AppUpdateNotice(
            tagName: tag,
            notes: payload.body ?? "",
            downloadURL: downloadURL(htmlURL: payload.htmlURL, assets: payload.assets ?? [], tag: tag)
        )
    }

    static func interpret(currentVersion: String, statusCode: Int, data: Data) -> AppUpdateCheckResult {
        guard (200..<300).contains(statusCode) else { return .failed }
        guard SemanticVersion(currentVersion) != nil else { return .failed }
        guard let release = parseRelease(data) else { return .failed }
        guard isNewer(release.tagName, than: currentVersion) else { return .upToDate }
        return .available(release)
    }

    /// A failed check keeps the notice already on screen. Up to date clears it.
    static func nextNotice(previous: AppUpdateNotice?, result: AppUpdateCheckResult) -> AppUpdateNotice? {
        switch result {
        case .failed:
            return previous
        case .upToDate:
            return nil
        case .available(let notice):
            return notice
        }
    }

    /// Drops a cached notice once this copy of the app is that version or newer.
    static func noticeToShow(cached: AppUpdateNotice?, currentVersion: String) -> AppUpdateNotice? {
        guard let cached, isNewer(cached.tagName, than: currentVersion) else { return nil }
        return cached
    }

    private static func downloadURL(htmlURL: String?, assets: [ReleaseAsset], tag: String) -> URL {
        if let zip = assets.first(where: { $0.name == zipAssetName }),
           let url = webURL(zip.browserDownloadURL) {
            return url
        }
        if let url = webURL(htmlURL) {
            return url
        }
        return releasePageURL(tag: tag)
    }

    private static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    private static func releasePageURL(tag: String) -> URL {
        let encoded = escapeTag(tag)
        let releases = "https://github.com/\(owner)/\(repo)/releases/latest"
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(encoded)")
            ?? URL(string: releases)!
    }

    private static func escapeTag(_ tag: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return tag.addingPercentEncoding(withAllowedCharacters: allowed) ?? tag
    }

    private struct ReleasePayload: Decodable {
        var tagName: String
        var body: String?
        var htmlURL: String?
        var assets: [ReleaseAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct ReleaseAsset: Decodable {
        var name: String?
        var browserDownloadURL: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// Numeric dot-separated version. A leading "v" is ignored. "1.1" and "1.1.0" match.
    private struct SemanticVersion: Comparable {
        var parts: [Int]

        init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let first = text.first, first == "v" || first == "V" {
                text.removeFirst()
            }
            guard !text.isEmpty else { return nil }
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty else { return nil }
            var numbers: [Int] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else {
                    return nil
                }
                numbers.append(number)
            }
            parts = numbers
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            !(lhs < rhs) && !(rhs < lhs)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            let count = max(lhs.parts.count, rhs.parts.count)
            for index in 0..<count {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}

/// Asks GitHub once a day. Offline and error responses change nothing on screen.
@MainActor
@Observable
final class AppUpdateChecker {
    static let lastCheckedKey = "com.grokcursorusage.update.lastCheckedAt"
    static let noticeKey = "com.grokcursorusage.update.notice"

    private(set) var notice: AppUpdateNotice?
    private let defaults: UserDefaults
    private let currentVersion: String
    private let session: URLSession
    private var checkTask: Task<Void, Never>?
    private var started = false

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = AppUpdate.marketingVersion()
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.session = URLSession(configuration: AppUpdate.ephemeralConfiguration())
    }

    func start() {
        guard !AppDelegate.isRunningTests else { return }
        guard !started else { return }
        started = true
        let cached = Self.loadNotice(from: defaults)
        let visible = AppUpdate.noticeToShow(cached: cached, currentVersion: currentVersion)
        notice = visible
        if cached != nil && visible == nil {
            storeNotice(nil)
        }
        scheduleNextCheck(afterCheck: false)
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    private func scheduleNextCheck(afterCheck: Bool) {
        let previous = checkTask
        let last = defaults.object(forKey: Self.lastCheckedKey) as? Date
        var wait = AppUpdate.waitInterval(lastCheckedAt: last, now: Date())
        if afterCheck && wait < 1 {
            wait = AppUpdate.checkInterval
        }
        let task = Task { [weak self] in
            if wait > 0 {
                let nanos = UInt64(min(wait, AppUpdate.checkInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard let self, !Task.isCancelled else { return }
            await self.performCheck()
        }
        checkTask = task
        previous?.cancel()
    }

    private func performCheck() async {
        defaults.set(Date(), forKey: Self.lastCheckedKey)
        let result = await fetchLatest()
        guard !Task.isCancelled else { return }
        notice = AppUpdate.nextNotice(previous: notice, result: result)
        storeNotice(notice)
        scheduleNextCheck(afterCheck: true)
    }

    private func fetchLatest() async -> AppUpdateCheckResult {
        guard let (data, response) = try? await session.data(for: AppUpdate.makeRequest()),
              let http = response as? HTTPURLResponse
        else { return .failed }
        return AppUpdate.interpret(
            currentVersion: currentVersion,
            statusCode: http.statusCode,
            data: data
        )
    }

    private func storeNotice(_ notice: AppUpdateNotice?) {
        guard let notice, let data = try? JSONEncoder().encode(notice) else {
            defaults.removeObject(forKey: Self.noticeKey)
            return
        }
        defaults.set(data, forKey: Self.noticeKey)
    }

    private static func loadNotice(from defaults: UserDefaults) -> AppUpdateNotice? {
        guard let data = defaults.data(forKey: noticeKey) else { return nil }
        return try? JSONDecoder().decode(AppUpdateNotice.self, from: data)
    }
}
