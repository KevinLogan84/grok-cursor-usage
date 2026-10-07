import Foundation

struct QuotaRefreshSources: Sendable {
    var periodUsage: @Sendable () async -> Data?
    var sandUsage: @Sendable () async -> Data?
    var grokBilling: @Sendable () async -> Data?
    var hasGrokSession: @Sendable () -> Bool

    init(
        periodUsage: @escaping @Sendable () async -> Data?,
        sandUsage: @escaping @Sendable () async -> Data?,
        grokBilling: @escaping @Sendable () async -> Data?,
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

    private let defaults: UserDefaults
    private let notifier: QuotaAlertNotifier
    private let sources: QuotaRefreshSources
    private let fetchTimeout: Duration
    private var timer: Timer?

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
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
        var sand: Data?
        var grok: Data?
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
                    let first = await QuotaFetchTimeout.race(timeout: timeout, work: sources.sandUsage)
                    if case .finished(let data) = first, let data {
                        return QuotaFetch.sand(data)
                    }
                    if case .timedOut = first {
                        return QuotaFetch.sand(nil)
                    }
                    switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.sandUsage) {
                    case .finished(let data):
                        return QuotaFetch.sand(data)
                    case .timedOut:
                        return QuotaFetch.sand(nil)
                    }
                }.value
            }
            group.addTask {
                await Task.detached {
                    switch await QuotaFetchTimeout.race(timeout: timeout, work: sources.grokBilling) {
                    case .finished(let data):
                        return QuotaFetch.grok(data, hasSession: sources.hasGrokSession())
                    case .timedOut:
                        return QuotaFetch.grok(nil, hasSession: sources.hasGrokSession())
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
        sand: Data?,
        haveSand: Bool,
        grok: Data?,
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
        if haveGrok {
            if let bar = grok.flatMap({ QuotaParsing.superGrokBar(from: $0) }) {
                included[.superGrok] = bar
            } else if grokSession {
                included[.superGrok] = .unavailable(
                    .superGrok,
                    message: QuotaUnavailableCopy.grokUnavailable,
                    title: "Grok"
                )
            } else {
                included[.superGrok] = nil
            }
        }
        if haveSand {
            included[.grokBot] = sand.flatMap { QuotaParsing.grokBotBar(from: $0) }
        }

        bars = QuotaKind.subscriptionCases.compactMap { included[$0] }
        lastUpdated = .now
        evaluateBurns()
    }

    private func evaluateBurns() {
        let dayKey = ChicagoDay.dateKey(for: .now)
        for bar in bars {
            guard bar.state == .ready else { continue }
            let prefix = "com.grokcursorusage.quota.\(bar.kind.rawValue)"
            let storedDay = defaults.string(forKey: "\(prefix).day")
            let storedStart = defaults.object(forKey: "\(prefix).startUsed") as? Double
            let notified = defaults.bool(forKey: "\(prefix).notified")
            let decision = QuotaBurnEvaluator.evaluate(
                dayKey: dayKey,
                usedFraction: bar.usedPercent / 100,
                storedDayKey: storedDay,
                storedStartUsed: storedStart,
                alreadyNotified: notified
            )
            defaults.set(dayKey, forKey: "\(prefix).day")
            defaults.set(decision.startUsed, forKey: "\(prefix).startUsed")
            defaults.set(decision.notified, forKey: "\(prefix).notified")
            if decision.shouldNotify {
                notifier.postQuotaBurn(bar: bar, dayKey: dayKey)
            }
        }
    }
}

private enum QuotaFetch: Sendable {
    case period(Data?)
    case sand(Data?)
    case grok(Data?, hasSession: Bool)
}
