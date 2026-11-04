import Foundation

/// Mac → iPhone snapshot of the subscription readings. The phone only displays this.
struct QuotaSnapshot: Codable, Equatable, Sendable {
    var version: Int
    var lastUpdated: Date
    var bars: [SnapshotQuotaBar]
    /// Named shares of the weekly pool. Empty when the Mac had no such split.
    var poolShares: [QuotaParsing.PoolShare]

    init(
        version: Int,
        lastUpdated: Date,
        bars: [SnapshotQuotaBar],
        poolShares: [QuotaParsing.PoolShare] = []
    ) {
        self.version = version
        self.lastUpdated = lastUpdated
        self.bars = bars
        self.poolShares = poolShares
    }

    static let staleAfter: TimeInterval = 30 * 60

    static func isStale(lastUpdated: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastUpdated) >= staleAfter
    }

    func statusLine(now: Date) -> String {
        QuotaSnapshotStamp.statusLine(lastUpdated: lastUpdated, now: now)
    }

    private enum CodingKeys: String, CodingKey {
        case version, lastUpdated, bars, poolShares
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        bars = try container.decode([SnapshotQuotaBar].self, forKey: .bars)
        poolShares = try container.decodeIfPresent([QuotaParsing.PoolShare].self, forKey: .poolShares) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(bars, forKey: .bars)
        if !poolShares.isEmpty {
            try container.encode(poolShares, forKey: .poolShares)
        }
    }
}

struct SnapshotQuotaBar: Codable, Equatable, Sendable, Identifiable {
    var kind: QuotaKind
    var usedFraction: Double
    var limitFraction: Double
    var usedText: String
    var label: String
    var subtitle: String
    var detail: String
    var pace: QuotaPace?
    var unavailableMessage: String?
    /// Provider period. Nil on snapshots published before the combined bar.
    var periodStart: Date?
    var periodEnd: Date?
    /// This pool's own percent, including values above 100. Nil on older snapshots.
    var rawUsedPercent: Double?

    var id: QuotaKind { kind }

    var isReady: Bool { unavailableMessage == nil }

    /// Percent for the combined allowance. Prefers the raw provider value.
    var allowanceUsedPercent: Double {
        if let rawUsedPercent { return rawUsedPercent }
        if let parsed = Self.percent(in: usedText) { return parsed }
        return min(1, max(0, usedFraction)) * 100
    }

    private static func percent(in text: String) -> Double? {
        let number = text.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard !number.isEmpty, number != "-" else { return nil }
        return Double(number)
    }

    var isLoadingPlaceholder: Bool {
        unavailableMessage == QuotaBar.loadingMessage
    }

    init(
        kind: QuotaKind,
        usedFraction: Double,
        limitFraction: Double = 1,
        usedText: String,
        label: String,
        subtitle: String,
        detail: String,
        pace: QuotaPace? = nil,
        unavailableMessage: String? = nil,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        rawUsedPercent: Double? = nil
    ) {
        self.kind = kind
        self.usedFraction = usedFraction
        self.limitFraction = limitFraction
        self.usedText = usedText
        self.label = label
        self.subtitle = subtitle
        self.detail = detail
        self.pace = pace
        self.unavailableMessage = unavailableMessage
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.rawUsedPercent = rawUsedPercent
    }

    init(_ bar: QuotaBar) {
        kind = bar.kind
        usedFraction = bar.usedFraction
        limitFraction = 1
        usedText = bar.usedText
        label = bar.title
        subtitle = bar.subtitle
        detail = bar.detail
        pace = bar.pace
        periodStart = bar.periodStart
        periodEnd = bar.periodEnd
        if case .unavailable(let message) = bar.state {
            unavailableMessage = message
            rawUsedPercent = nil
        } else {
            unavailableMessage = nil
            rawUsedPercent = bar.usedPercent
        }
    }
}

enum QuotaSnapshotCodec {
    static let key = "com.grokcursorusage.quotaSnapshot.v1"
    /// Author's container. Anyone else building the iPhone app replaces this
    /// and the same ID in both entitlements files. See the README.
    static let iCloudContainerID = "iCloud.com.grokcursorusage"
    static let kvStoreIdentifier = "$(TeamIdentifierPrefix)com.grokcursorusage"

    static func encode(_ snapshot: QuotaSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> QuotaSnapshot {
        try decoder.decode(QuotaSnapshot.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum QuotaSnapshotPublishPolicy {
    static let heartbeat: TimeInterval = 300
    static let firstWriteCap: TimeInterval = 3

    static func shouldWrite(previous: QuotaSnapshot?, next: QuotaSnapshot) -> Bool {
        if hasOnlyLoadingBars(next), hasReadyBars(previous) {
            return false
        }
        guard let previous else { return true }
        var comparable = previous
        comparable.lastUpdated = next.lastUpdated
        if comparable != next { return true }
        return next.lastUpdated.timeIntervalSince(previous.lastUpdated) >= heartbeat
    }

    static func shouldWaitForFirstRefresh(
        previous: QuotaSnapshot?,
        quotasLastUpdated: Date?,
        elapsed: TimeInterval,
        cap: TimeInterval = firstWriteCap
    ) -> Bool {
        previous == nil && quotasLastUpdated == nil && elapsed < cap
    }

    static func prepared(previous: QuotaSnapshot?, next: QuotaSnapshot) -> QuotaSnapshot {
        var outgoing = next
        outgoing.bars = mergeBars(
            previous: previous?.bars ?? [],
            next: next.bars,
            order: QuotaKind.subscriptionCases
        )
        return outgoing
    }

    /// A plan missing from `next` is gone. A loading placeholder keeps the last ready bar for that same plan.
    static func mergeBars(
        previous: [SnapshotQuotaBar],
        next: [SnapshotQuotaBar],
        order: [QuotaKind]
    ) -> [SnapshotQuotaBar] {
        order.compactMap { kind in
            guard let incoming = next.first(where: { $0.kind == kind }) else { return nil }
            if incoming.isLoadingPlaceholder,
               let prior = previous.first(where: { $0.kind == kind && !$0.isLoadingPlaceholder }) {
                return prior
            }
            if incoming.isLoadingPlaceholder { return nil }
            return incoming
        }
    }

    static func hasOnlyLoadingBars(_ snapshot: QuotaSnapshot) -> Bool {
        guard !snapshot.bars.isEmpty else { return false }
        return snapshot.bars.allSatisfy(\.isLoadingPlaceholder)
    }

    static func hasReadyBars(_ snapshot: QuotaSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.bars.contains(where: \.isReady)
    }
}

enum QuotaSnapshotStamp {
    static func ageAbbreviation(lastUpdated: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    static func statusLine(lastUpdated: Date, now: Date) -> String {
        let age = ageAbbreviation(lastUpdated: lastUpdated, now: now)
        if QuotaSnapshot.isStale(lastUpdated: lastUpdated, now: now) {
            return "Stale. Last updated \(age) ago"
        }
        return "Updated last \(age) ago"
    }
}

enum QuotaSnapshotCloud {
    static func write(
        _ snapshot: QuotaSnapshot,
        store: NSUbiquitousKeyValueStore = .default
    ) {
        guard let data = try? QuotaSnapshotCodec.encode(snapshot) else { return }
        store.set(data, forKey: QuotaSnapshotCodec.key)
        store.synchronize()
    }

    static func read(
        store: NSUbiquitousKeyValueStore = .default
    ) -> QuotaSnapshot? {
        guard let data = store.data(forKey: QuotaSnapshotCodec.key) else { return nil }
        return try? QuotaSnapshotCodec.decode(data)
    }
}
