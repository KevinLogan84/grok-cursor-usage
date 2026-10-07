import Foundation

struct QuotaRefreshSources: Sendable {
    var periodUsage: @Sendable () async -> Data?
    var sandUsage: @Sendable () async -> SandUsageFetch
    var grokBilling: @Sendable () async -> GrokBillingFetch
    var hasGrokSession: @Sendable () -> Bool

    init(
        periodUsage: @escaping @Sendable () async -> Data?,
        sandUsage: @escaping @Sendable () async -> SandUsageFetch,
        grokBilling: @escaping @Sendable () async -> GrokBillingFetch,
        hasGrokSession: @escaping @Sendable () -> Bool
    ) {
        self.periodUsage = periodUsage
        self.sandUsage = sandUsage
        self.grokBilling = grokBilling
        self.hasGrokSession = hasGrokSession
    }

    static let live = QuotaRefreshSources(
        periodUsage: { await CursorQuotaClient.fetchPeriodUsage() },
        sandUsage: { await CursorQuotaClient.fetchSandUsage() },
        grokBilling: { await GrokQuotaClient.fetchBilling() },
        hasGrokSession: { GrokQuotaClient.hasSignedInSession() }
    )
}

enum QuotaFetchTimeout {
    enum Race<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    static func race<T: Sendable>(
        timeout: Duration,
        work: @escaping @Sendable () async -> T
    ) async -> Race<T> {
        await withTaskGroup(of: Race<T>.self) { group in
            group.addTask {
                .finished(await work())
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}

@MainActor
@Observable
final class QuotaMonitor {
    private(set) var bars: [QuotaBar]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    /// Pool the menu bar names: the one whose percent rose most recently.
    private(set) var menuBarKind: QuotaKind?

    /// How often a running app looks again, so the menu bar can follow the pool in use.
    static let refreshInterval: TimeInterval = 60

    private let defaults: UserDefaults
    private let notifier: QuotaAlertNotifier
    private let sources: QuotaRefreshSources
    private let fetchTimeout: Duration
    private var timer: Timer?
    private var menuBarFocus: QuotaMenuBarFocus

    init(
        defaults: UserDefaults = .standard,
        notifier: QuotaAlertNotifier,
        sources: QuotaRefreshSources = .live,
        fetchTimeout: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.notifier = notifier
        self.sources = sources
        self.fetchTimeout = fetchTimeout
        bars = []
        let stored = Self.loadFocus(from: defaults)
        menuBarFocus = stored
        menuBarKind = stored.kind
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sources = self.sources
        let timeout = fetchTimeout
        var period: Data?
        var sand: SandUsageFetch?
        var grok: GrokBillingFetch?
        var havePeriod = false
        var haveSand = false
        var haveGrok = false
        var grokSession = false

        await withTaskGroup(of: QuotaFetch.self) { group in
            group.addTask {
                await Task.detached {
                    switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.periodUsage) {
                    case .finished(let data):
                        return QuotaFetch.period(data)
                    case .timedOut:
                        return QuotaFetch.period(nil)
                    }
                }.value
            }
            group.addTask {
                await Task.detached {
                    switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.sandUsage) {
                    case .finished(let fetch):
                        if case .failed = fetch {
                            switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.sandUsage) {
                            case .finished(let retry):
                                return QuotaFetch.sand(retry)
                            case .timedOut:
                                return QuotaFetch.sand(.failed)
                            }
                        }
                        return QuotaFetch.sand(fetch)
                    case .timedOut:
                        return QuotaFetch.sand(.failed)
                    }
                }.value
            }
            group.addTask {
                await Task.detached {
                    switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.grokBilling) {
                    case .finished(let fetch):
                        return QuotaFetch.grok(fetch, hasSession: sources.hasGrokSession())
                    case .timedOut:
                        return QuotaFetch.grok(.unavailable, hasSession: sources.hasGrokSession())
                    }
                }.value
            }
            for await fetch in group {
                switch fetch {
                case .period(let data):
                    period = data
                    havePeriod = true
                case .sand(let data):
                    sand = data
                    haveSand = true
                case .grok(let data, let hasSession):
                    grok = data
                    grokSession = hasSession
                    haveGrok = true
                }
                applyFetched(
                    period: period,
                    havePeriod: havePeriod,
                    sand: sand,
                    haveSand: haveSand,
                    grok: grok,
                    haveGrok: haveGrok,
                    grokSession: grokSession
                )
            }
        }
    }

    private var included: [QuotaKind: QuotaBar] = [:]

    private func applyFetched(
        period: Data?,
        havePeriod: Bool,
        sand: SandUsageFetch?,
        haveSand: Bool,
        grok: GrokBillingFetch?,
        haveGrok: Bool,
        grokSession: Bool
    ) {
        if havePeriod {
            included[.cursorModels] = nil
            included[.otherModels] = nil
            let models = period.flatMap { QuotaParsing.cursorBars(from: $0) } ?? []
            if models.isEmpty {
                included[.cursorModels] = .unavailable(
                    .cursorModels,
                    message: period == nil
                        ? "Open Cursor once so this Mac can read usage"
                        : "Cursor usage didn't include a pool",
                    title: "Cursor"
                )
            } else {
                for bar in models {
                    included[bar.kind] = bar
                }
            }
        }
        if haveGrok, let grok {
            switch grok {
            case .usage(let data):
                if let bar = QuotaParsing.superGrokBar(from: data) {
                    included[.superGrok] = bar
                } else if grokSession {
                    included[.superGrok] = .unavailable(
                        .superGrok,
                        message: GrokSignInSource.current(defaults).usesGrokApp
                            ? QuotaUnavailableCopy.grokUnavailable
                            : QuotaUnavailableCopy.grokCLISignInAgain,
                        title: "Grok"
                    )
                } else {
                    included[.superGrok] = nil
                }
            case .outdatedClient:
                included[.superGrok] = .unavailable(
                    .superGrok,
                    message: QuotaUnavailableCopy.grokCLIOutdated,
                    title: "Grok"
                )
            case .unavailable:
                if grokSession {
                    included[.superGrok] = .unavailable(
                        .superGrok,
                        message: GrokSignInSource.current(defaults).usesGrokApp
                            ? QuotaUnavailableCopy.grokUnavailable
                            : QuotaUnavailableCopy.grokCLISignInAgain,
                        title: "Grok"
                    )
                } else {
                    included[.superGrok] = nil
                }
            }
        }
        if haveSand, let sand {
            switch sand {
            case .needsSignIn:
                included[.grokBot] = .unavailable(
                    .grokBot,
                    message: QuotaUnavailableCopy.grokBotNeedsCursorSignIn,
                    title: "Grok Bot"
                )
            case .failed:
                included[.grokBot] = .unavailable(
                    .grokBot,
                    message: QuotaUnavailableCopy.grokBotUnavailable,
                    title: "Grok Bot"
                )
            case .payload(let data):
                // A signed-in payload with no Grok Bot allowance omits the row.
                // Anything else that still carries usage is shown.
                included[.grokBot] = QuotaParsing.grokBotBar(from: data)
            }
        }

        bars = QuotaKind.subscriptionCases.compactMap { included[$0] }
        lastUpdated = .now
        if havePeriod, haveSand, haveGrok {
            let next = menuBarFocus.advanced(by: bars)
            menuBarFocus = next
            menuBarKind = next.kind
            saveFocus(next)
        }
        evaluateBurns()
    }

    private static let menuBarKindKey = "com.grokcursorusage.menuBar.kind"

    private static func menuBarPercentKey(_ kind: QuotaKind) -> String {
        "com.grokcursorusage.menuBar.percent.\(kind.rawValue)"
    }

    private static func loadFocus(from defaults: UserDefaults) -> QuotaMenuBarFocus {
        var percents: [QuotaKind: Double] = [:]
        for kind in QuotaKind.allCases {
            guard defaults.object(forKey: menuBarPercentKey(kind)) != nil else { continue }
            percents[kind] = defaults.double(forKey: menuBarPercentKey(kind))
        }
        let kind = defaults.string(forKey: menuBarKindKey).flatMap(QuotaKind.init(rawValue:))
        return QuotaMenuBarFocus(kind: kind, percents: percents)
    }

    private func saveFocus(_ focus: QuotaMenuBarFocus) {
        if let kind = focus.kind {
            defaults.set(kind.rawValue, forKey: Self.menuBarKindKey)
        } else {
            defaults.removeObject(forKey: Self.menuBarKindKey)
        }
        for kind in QuotaKind.allCases {
            let key = Self.menuBarPercentKey(kind)
            if let percent = focus.percents[kind] {
                defaults.set(percent, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func evaluateBurns() {
        let dayKey = LocalDay.dateKey(for: .now)
        for bar in bars {
            guard bar.state == .ready else { continue }
            let prefix = "com.grokcursorusage.quota.\(bar.kind.rawValue)"
            let storedDay = defaults.string(forKey: "\(prefix).day")
            let storedStart = defaults.object(forKey: "\(prefix).startUsed") as? Double
            let storedSteps = defaults.object(forKey: "\(prefix).steps") as? Int
            let notifiedSteps = storedSteps ?? (defaults.bool(forKey: "\(prefix).notified") ? 1 : 0)
            let decision = QuotaBurnEvaluator.evaluate(
                dayKey: dayKey,
                usedFraction: bar.usedPercent / 100,
                storedDayKey: storedDay,
                storedStartUsed: storedStart,
                notifiedSteps: notifiedSteps,
                mode: notifier.repeatMode,
                stepPercent: notifier.stepPercent,
                periodStart: bar.periodStart,
                periodEnd: bar.periodEnd,
                storedPeriodStart: storedDate("\(prefix).periodStart"),
                storedPeriodEnd: storedDate("\(prefix).periodEnd")
            )
            defaults.set(dayKey, forKey: "\(prefix).day")
            defaults.set(decision.startUsed, forKey: "\(prefix).startUsed")
            defaults.set(decision.notifiedSteps, forKey: "\(prefix).steps")
            defaults.removeObject(forKey: "\(prefix).notified")
            if let start = bar.periodStart {
                defaults.set(start.timeIntervalSince1970, forKey: "\(prefix).periodStart")
            }
            if let end = bar.periodEnd {
                defaults.set(end.timeIntervalSince1970, forKey: "\(prefix).periodEnd")
            }
            if decision.shouldNotify {
                notifier.postQuotaBurn(
                    bar: bar,
                    dayKey: dayKey,
                    climbedPercent: decision.notifiedSteps * notifier.stepPercent
                )
            }
        }
    }

    private func storedDate(_ key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }
}

private enum QuotaFetch: Sendable {
    case period(Data?)
    case sand(SandUsageFetch)
    case grok(GrokBillingFetch, hasSession: Bool)
}
