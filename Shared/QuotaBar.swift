import Foundation

enum QuotaKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cursorModels
    case otherModels
    case superGrok
    case grokBot
    case onDemand
    case xaiCredits

    var id: String { rawValue }

    static var subscriptionCases: [QuotaKind] {
        [.cursorModels, .otherModels, .superGrok, .grokBot]
    }

    /// Retired cards (#34). The cases stay so an older iCloud snapshot that still
    /// carries them decodes; nothing fetches or displays them anymore.
    static var creditCases: [QuotaKind] {
        [.onDemand, .xaiCredits]
    }

    /// Fallback label. A ready bar uses the plan name from the provider instead.
    var title: String {
        switch self {
        case .cursorModels: return "Cursor Auto"
        case .otherModels: return "Cursor API"
        case .superGrok: return "Grok"
        case .grokBot: return "Grok Bot"
        case .onDemand: return "On Demand"
        case .xaiCredits: return "X Credits"
        }
    }

    /// Extra caption under the credit title. X plugin credits only.
    var identitySubtitle: String? {
        switch self {
        case .xaiCredits: return "Plugin"
        default: return nil
        }
    }
}

enum QuotaBarState: Equatable, Codable, Sendable {
    case ready
    case unavailable(String)
}

enum QuotaPace: Equatable, Codable, Sendable {
    case over(Int)
    case under(Int)
    case onPace

    var text: String {
        switch self {
        case .over(let points): return "\(points)% over"
        case .under(let points): return "\(points)% under"
        case .onPace: return "on pace"
        }
    }

    /// Color for the pace label only. Pace math is unchanged.
    /// Green when under. Yellow when on pace, or over by fewer than
    /// `PaceColorBand.slightOverPoints` (5). Red when over by 5 or more.
    var colorBand: PaceColorBand {
        switch self {
        case .under: return .green
        case .onPace: return .yellow
        case .over(let points):
            return points >= PaceColorBand.slightOverPoints ? .red : .yellow
        }
    }
}

enum PaceColorBand: Equatable, Sendable {
    case green
    case yellow
    case red

    /// Over by fewer than this many points stays yellow. 5 or more is red.
    static let slightOverPoints = 5
}

/// Color for a "% used" label from the rounded percent that label shows.
/// Below 50 stays the caller's existing color. Yellow at 50. Red at 80.
enum UsageTextLevel: Equatable, Sendable {
    case unchanged
    case yellow
    case red

    static func level(displayedPercent: Int) -> UsageTextLevel {
        if displayedPercent >= 80 { return .red }
        if displayedPercent >= 50 { return .yellow }
        return .unchanged
    }
}

/// Single Ultra Usage bar and the total "% used" label.
/// Green below 50. Yellow at 50. Red at 80. From the rounded percent shown.
enum UsageFillLevel: Equatable, Sendable {
    case green
    case yellow
    case red

    static func level(displayedPercent: Int) -> UsageFillLevel {
        if displayedPercent >= 80 { return .red }
        if displayedPercent >= 50 { return .yellow }
        return .green
    }
}

struct QuotaBar: Equatable, Identifiable {
    var kind: QuotaKind
    /// Plan name to show, such as "Cursor Ultra" or "SuperGrok". Not the pool's fallback title.
    var title: String
    /// 0…1 fill of the drawn bar.
    var usedFraction: Double
    /// Raw percent from the provider; exceeds 100 while over quota.
    var usedPercent: Double
    var usedText: String
    var pace: QuotaPace?
    var subtitle: String
    var detail: String
    /// Provider-reported period bounds. Spike Alerts treats a change in either
    /// date as a mid-day reset. Nil when the payload omitted that date.
    var periodStart: Date?
    var periodEnd: Date?
    var state: QuotaBarState

    var id: QuotaKind { kind }

    static let loadingMessage = "Loading…"

    var isReady: Bool {
        state == .ready
    }

    var isLoadingPlaceholder: Bool {
        if case .unavailable(let message) = state {
            return message == Self.loadingMessage
        }
        return false
    }

    static func loading(_ kind: QuotaKind) -> QuotaBar {
        unavailable(kind, message: loadingMessage)
    }

    static func unavailable(
        _ kind: QuotaKind,
        message: String,
        title: String? = nil,
        reset: Date? = nil
    ) -> QuotaBar {
        QuotaBar(
            kind: kind,
            title: title ?? kind.title,
            usedFraction: 0,
            usedPercent: 0,
            usedText: "—",
            pace: nil,
            subtitle: "",
            detail: message,
            periodStart: nil,
            periodEnd: reset,
            state: .unavailable(message)
        )
    }
}

/// Which pool the menu bar names. A rise in percent means that pool was just used.
/// Until another pool rises, the menu bar stays on the last one that moved.
struct QuotaMenuBarFocus: Equatable, Sendable {
    var kind: QuotaKind?
    var percents: [QuotaKind: Double]

    static let empty = QuotaMenuBarFocus(kind: nil, percents: [:])

    /// Ignores float noise. A real tick from Cursor or Grok is larger than this.
    static let usageTick = 0.01

    func advanced(by bars: [QuotaBar]) -> QuotaMenuBarFocus {
        let ready = bars.filter(\.isReady)
        let present = Set(bars.map(\.kind))
        var increases: [(kind: QuotaKind, delta: Double, percent: Double)] = []
        for bar in ready {
            guard let before = percents[bar.kind] else { continue }
            let delta = bar.usedPercent - before
            guard delta > Self.usageTick else { continue }
            increases.append((bar.kind, delta, bar.usedPercent))
        }

        let active: QuotaKind?
        if let winner = increases.max(by: { lhs, rhs in
            if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
            if lhs.kind == kind { return false }
            if rhs.kind == kind { return true }
            return lhs.percent < rhs.percent
        }) {
            active = winner.kind
        } else if let kind, ready.contains(where: { $0.kind == kind }) {
            active = kind
        } else {
            active = ready.max(by: { $0.usedPercent < $1.usedPercent })?.kind
        }

        var nextPercents = percents.filter { present.contains($0.key) }
        for bar in ready {
            nextPercents[bar.kind] = bar.usedPercent
        }
        return QuotaMenuBarFocus(kind: active, percents: nextPercents)
    }
}

enum QuotaParsing {
    /// One bar per Cursor pool that this account actually reports. Auto and API
    /// are separate. A missing percent means that pool is not on the plan.
    static func cursorBars(from data: Data, now: Date = .now) -> [QuotaBar]? {
        guard let root = jsonObject(from: data) else { return nil }
        let plan = root["planUsage"] as? [String: Any] ?? [:]
        let auto = firstNumber(plan, keys: ["autoPercentUsed"])
            ?? percentInMessage(root["autoModelSelectedDisplayMessage"] as? String)
        let api = firstNumber(plan, keys: ["apiPercentUsed"])
            ?? percentInMessage(root["namedModelSelectedDisplayMessage"] as? String)
        let planTitle = SubscriptionPlanName.cursor(from: root)
        let reset = parseResetValue(root["billingCycleEnd"])
        let start = parseResetValue(root["billingCycleStart"])
        let caption = resetCaption(reset: reset, now: now)
        var bars: [QuotaBar] = []
        if let auto {
            bars.append(
                percentBar(
                    kind: .cursorModels,
                    title: planTitle ?? "Cursor Auto",
                    usedPercent: auto,
                    subtitle: "Auto",
                    detail: caption,
                    start: start,
                    reset: reset,
                    now: now
                )
            )
        }
        if let api {
            bars.append(
                percentBar(
                    kind: .otherModels,
                    title: planTitle ?? "Cursor API",
                    usedPercent: api,
                    subtitle: "API models",
                    detail: caption,
                    start: start,
                    reset: reset,
                    now: now
                )
            )
        }
        return bars
    }

    static func looksLikeBillingJSON(_ data: Data) -> Bool {
        billingConfig(from: data) != nil
    }

    /// Turn a grok.com `GetGrokCreditsConfig` protobuf (raw or gRPC-web framed)
    /// into the same `{ "config": … }` JSON the CLI billing parser already reads.
    static func billingJSON(fromCreditsProtobuf data: Data) -> Data? {
        let frames = grpcWebDataFrames(from: data)
        let payloads = frames.isEmpty && looksLikeProtobuf(data) ? [data] : frames
        guard !payloads.isEmpty else { return nil }

        var percent: Double?
        var periodStart: String?
        var periodEnd: String?
        var prepaid: Double?

        for payload in payloads {
            if let parsed = parseCreditsConfigMessage(payload) {
                if percent == nil { percent = parsed.percent }
                if periodStart == nil { periodStart = parsed.start }
                if periodEnd == nil { periodEnd = parsed.end }
                if prepaid == nil { prepaid = parsed.prepaid }
            }
        }

        guard percent != nil || periodStart != nil || periodEnd != nil || prepaid != nil else {
            return nil
        }

        var config: [String: Any] = [:]
        if let percent { config["creditUsagePercent"] = percent }
        if periodStart != nil || periodEnd != nil {
            var period: [String: Any] = [:]
            if let periodStart { period["start"] = periodStart }
            if let periodEnd { period["end"] = periodEnd }
            config["currentPeriod"] = period
        }
        if let prepaid {
            config["prepaidBalance"] = ["val": prepaid]
        }
        return try? JSONSerialization.data(withJSONObject: ["config": config])
    }

    static func parseCreditsConfigMessage(_ data: Data) -> (
        percent: Double?,
        start: String?,
        end: String?,
        prepaid: Double?
    )? {
        let root = protobufFields(data)
        let configBytes = root.lengthDelimited[1] ?? data
        let config = protobufFields(configBytes)

        var percent: Double?
        if let bits = config.fixed32[1] {
            let value = Double(Float(bitPattern: bits))
            if value.isFinite, value >= 0, value <= 200 {
                percent = value
            }
        }

        let periodBytes = config.lengthDelimited[8] ?? config.lengthDelimited[5]
        var start: String?
        var end: String?
        if let periodBytes {
            let period = protobufFields(periodBytes)
            start = timestampString(period.lengthDelimited[2])
                ?? timestampString(period.lengthDelimited[1])
                ?? isoString(period.varints[2] ?? period.varints[1])
            end = timestampString(period.lengthDelimited[3])
                ?? timestampString(period.lengthDelimited[2])
                ?? isoString(period.varints[3] ?? period.varints[2])
            if start == end {
                start = timestampString(period.lengthDelimited[1]) ?? isoString(period.varints[1])
            }
        }

        var prepaid: Double?
        if let cent = config.lengthDelimited[12] {
            prepaid = Double(protobufFields(cent).varints[1] ?? 0)
        }

        guard percent != nil || start != nil || end != nil || prepaid != nil else {
            return nil
        }
        return (percent, start, end, prepaid)
    }

    static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length =
                (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private struct ProtobufFields {
        var varints: [UInt64: UInt64] = [:]
        var fixed32: [UInt64: UInt32] = [:]
        var lengthDelimited: [UInt64: Data] = [:]
    }

    private static func protobufFields(_ data: Data) -> ProtobufFields {
        let bytes = [UInt8](data)
        var fields = ProtobufFields()
        var index = 0
        while index < bytes.count {
            let start = index
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                index = start + 1
                continue
            }
            let field = key >> 3
            let wire = key & 0x07
            switch wire {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    fields.varints[field] = value
                } else {
                    index = start + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return fields }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = start + 1
                    continue
                }
                let end = index + Int(length)
                fields.lengthDelimited[field] = Data(bytes[index..<end])
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return fields }
                let bits = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                fields.fixed32[field] = bits
                index += 4
            default:
                index = start + 1
            }
        }
        return fields
    }

    private static func timestampString(_ data: Data?) -> String? {
        guard let data else { return nil }
        return isoString(protobufFields(data).varints[1])
    }

    private static func isoString(_ seconds: UInt64?) -> String? {
        guard let seconds, seconds >= 1_000_000_000, seconds <= 2_100_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    static func billingConfig(from data: Data) -> [String: Any]? {
        guard let root = jsonObject(from: data) else { return nil }
        if let config = root["config"] as? [String: Any] {
            return config
        }
        if root["onDemandCap"] != nil || root["onDemandUsed"] != nil
            || root["prepaidBalance"] != nil || root["creditUsagePercent"] != nil
            || root["productUsage"] != nil || root["currentPeriod"] != nil
        {
            return root
        }
        return nil
    }

    /// Grok 4.7 unified billing can omit `creditUsagePercent` and send only
    /// `productUsage` rows. Those rows are slices of the same weekly pool
    /// (Build + Chat + …), so they sum to the headline percent.
    static func productUsagePercent(_ config: [String: Any]) -> Double? {
        guard let rows = config["productUsage"] as? [[String: Any]], !rows.isEmpty else {
            return nil
        }
        var sum = 0.0
        var found = false
        for row in rows {
            guard let value = firstNumber(row, keys: ["usagePercent", "percentUsed", "usedPercent"]) else {
                continue
            }
            sum += value
            found = true
        }
        return found ? sum : nil
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Cursor sent `enabled`, `hasAccess`, or `entitled` as false. That account
    /// has no Grok Bot allowance, which is not a failed or empty reading.
    static func grokBotHasNoAllowance(_ data: Data) -> Bool {
        guard let root = jsonObject(from: data) else { return false }
        if root["enabled"] as? Bool == false { return true }
        if root["hasAccess"] as? Bool == false { return true }
        if root["entitled"] as? Bool == false { return true }
        return false
    }

    static func grokBotBar(from data: Data, now: Date = .now) -> QuotaBar? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let usedPercent = firstNumber(root, keys: [
            "usagePercent",
            "creditUsagePercent",
            "percentUsed",
            "usedPercent",
        ]) ?? productUsagePercent(root)
        guard let usedPercent else { return nil }

        if root["enabled"] as? Bool == false
            || root["hasAccess"] as? Bool == false
            || root["entitled"] as? Bool == false
        {
            return nil
        }
        let reset = parseISODate(root["nextResetTimestampUtc"] as? String)
        let start = parseISODate(root["currentPeriodStart"] as? String)
            ?? parseISODate(root["periodStartTimestampUtc"] as? String)
            ?? parseISODate(root["currentPeriodStartUtc"] as? String)
        let title = SubscriptionPlanName.namedString(
            in: root,
            keys: ["displayName", "featureName", "planName", "name"]
        ).map(SubscriptionPlanName.grokBotDisplay) ?? "Grok Bot"
        return percentBar(
            kind: .grokBot,
            title: title,
            usedPercent: usedPercent,
            subtitle: "Weekly usage",
            detail: resetCaption(reset: reset, now: now),
            start: start,
            reset: reset,
            now: now
        )
    }

    /// Accepts the same payload shapes as `looksLikeBillingJSON`, so a response the
    /// fetcher kept is never thrown away here.
    static func superGrokBar(from data: Data, now: Date = .now) -> QuotaBar? {
        guard let config = billingConfig(from: data) else { return nil }

        let usedPercent = firstNumber(config, keys: [
            "creditUsagePercent",
            "usagePercent",
            "percentUsed",
            "usedPercent",
        ]) ?? productUsagePercent(config)
            ?? ratioPercent(config, usedKeys: ["used", "onDemandUsed"], limitKeys: ["monthlyLimit", "onDemandCap"])

        let period = config["currentPeriod"] as? [String: Any]
        let reset = parseISODate(
            (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        )
        let start = parseISODate(
            (period?["start"] as? String) ?? (config["billingPeriodStart"] as? String)
        )
        let subscribed = config["hasSubscription"] as? Bool
            ?? config["subscribed"] as? Bool
            ?? config["isSubscriber"] as? Bool
        if subscribed == false, usedPercent == nil {
            return nil
        }
        // Unified-billing payloads drop creditUsagePercent after a weekly reset.
        // A period with no percent is 0% used, not a sign-in failure.
        guard usedPercent != nil || start != nil || reset != nil else { return nil }
        return percentBar(
            kind: .superGrok,
            title: SubscriptionPlanName.grok(from: config),
            usedPercent: usedPercent ?? 0,
            subtitle: "Weekly usage",
            detail: resetCaption(reset: reset, now: now),
            start: start,
            reset: reset,
            now: now
        )
    }

    static func percentBar(
        kind: QuotaKind,
        title: String? = nil,
        usedPercent: Double,
        subtitle: String,
        detail: String,
        start: Date? = nil,
        reset: Date? = nil,
        now: Date = .now
    ) -> QuotaBar {
        let used = min(max(usedPercent, 0), 999)
        let periodStart = start ?? inferredPeriodStart(for: kind, reset: reset)
        return QuotaBar(
            kind: kind,
            title: title ?? kind.title,
            usedFraction: min(1, used / 100),
            usedPercent: used,
            usedText: "\(wholePercent(used))% used",
            pace: pace(usedPercent: used, start: periodStart, end: reset, now: now),
            subtitle: subtitle,
            detail: detail,
            periodStart: start,
            periodEnd: reset,
            state: .ready
        )
    }

    /// One ready pool. `usedPercent` is that pool's own usage, not a share of
    /// a combined allowance. `start`/`end` are that pool's period, when known.
    struct AllowanceSample: Equatable, Sendable {
        var usedPercent: Double
        var start: Date?
        var end: Date?
    }

    /// The subscription APIs each report a percent of that reading's own meter.
    /// They do not send additive shares of one pool.
    ///
    /// On the shared weekly plan, Grok, Grok Bot, and Cursor can each report
    /// the same total, and Cursor's API meter can be a separate reading.
    /// The card total is the max of the ready readings, never the average,
    /// and never less than any one of them. Two readings at 2% total 2%.
    /// A reading that failed to load is not a sample, so it stays out of the
    /// max and the card can still say why that pool is missing.
    ///
    /// Pace compares that max with the average elapsed percent of the ready
    /// periods, including the first 2% of the window as on pace. Pace is
    /// omitted unless every sample has a real start and end longer than a
    /// minute. A sample with no dates still counts in the max; it only drops
    /// the pace.
    ///
    /// Pace label color is separate. Green when under. Yellow when on pace,
    /// or over by fewer than `PaceColorBand.slightOverPoints` (5). Red when
    /// over by 5 or more.
    static func combinedAllowance(
        _ samples: [AllowanceSample],
        now: Date
    ) -> (usedPercent: Double, pace: QuotaPace?)? {
        guard !samples.isEmpty else { return nil }
        let used = samples.map(\.usedPercent).max() ?? 0
        return (used, combinedPace(samples, usedPercent: used, now: now))
    }

    /// One app's share of the weekly pool, only when a payload named that share.
    struct PoolShare: Codable, Equatable, Sendable, Identifiable {
        var kind: QuotaKind
        var percent: Double
        var id: QuotaKind { kind }
    }

    /// Width of each mark on the 0…1 track.
    ///
    /// `shares` are percents of one pool. They are drawn only when they are a
    /// real split: two or more, each at least 0, and they add up to
    /// `totalPercent`. Their widths then add up to that total's fraction of
    /// the track (capped at the whole track once the total passes 100).
    ///
    /// Nil, an empty list, or readings that do not add up to the total are
    /// not a split. The track is one mark at the total. Meter readings such
    /// as 21.1, 21.1, and 0 are that case: they repeat the total, they are
    /// not shares of it.
    static func sharedPoolTrackFractions(totalPercent: Double?, shares: [Double]?) -> [Double] {
        guard let totalPercent, totalPercent.isFinite else { return [] }
        let total = max(0, totalPercent)
        if let shares, isAdditiveSplit(shares, totalPercent: total) {
            let sum = shares.reduce(0, +)
            let budget = min(1, total / 100)
            guard sum > 0 else { return shares.map { _ in 0 } }
            return shares.map { max(0, $0) / sum * budget }
        }
        return [min(1, total / 100)]
    }

    /// True when `shares` are pieces of `totalPercent` and not a second copy of it.
    static func isAdditiveSplit(_ shares: [Double], totalPercent: Double) -> Bool {
        guard shares.count >= 2, totalPercent.isFinite else { return false }
        guard shares.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        let total = max(0, totalPercent)
        guard total + 0.000_001 >= (shares.max() ?? 0) else { return false }
        let sum = shares.reduce(0, +)
        let tolerance = max(0.25, total * 0.01)
        return abs(sum - total) <= tolerance
    }

    /// Point widths for `fractions` along a track of `usable` points.
    /// A fraction of 0.21 is 21% of the track. Nothing is stretched to a
    /// minimum, so the marks cannot draw wider than the percent they name.
    static func exactSegmentWidths(fractions: [Double], usable: Double) -> [Double] {
        guard usable > 0 else { return Array(repeating: 0, count: fractions.count) }
        return fractions.map { fraction in
            guard fraction.isFinite, fraction > 0 else { return 0 }
            return fraction * usable
        }
    }

    static func sharedPoolSegmentWidths(
        totalPercent: Double?,
        shares: [Double]?,
        usable: Double
    ) -> [Double] {
        exactSegmentWidths(
            fractions: sharedPoolTrackFractions(totalPercent: totalPercent, shares: shares),
            usable: usable
        )
    }

    /// App shares of the weekly pool, or nil when no source named them.
    ///
    /// Fields this app already reads, and what they are:
    /// - GetCurrentPeriodUsage `planUsage.autoPercentUsed`, `apiPercentUsed`,
    ///   and JSON `totalPercentUsed`: each is one meter's percent. The first
    ///   two are not additive, and `totalPercentUsed` is not their sum.
    /// - GetSandUsageStatus `usagePercent`: one allowance percent. `isUnified`
    ///   and `billingBrand`, when a JSON body includes them, name the plan;
    ///   they are not a breakdown.
    /// - grok billing `creditUsagePercent`: one weekly headline.
    ///   `productUsage` rows (`product`, `usagePercent`) are slices of that
    ///   headline and do add up. They are drawn here only when every row is
    ///   named Grok Bot, Cursor, or Other. Build, Chat, and the other grok
    ///   product names are not relabeled into those three apps.
    static func explicitPoolShares(
        periodJSON: Data?,
        sandJSON: Data?,
        billingJSON: Data?
    ) -> [PoolShare]? {
        _ = periodJSON
        _ = sandJSON
        guard let config = billingJSON.flatMap({ billingConfig(from: $0) }),
              let rows = config["productUsage"] as? [[String: Any]],
              !rows.isEmpty
        else { return nil }

        var sums: [QuotaKind: Double] = [:]
        for row in rows {
            guard let name = row["product"] as? String,
                  let percent = firstNumber(row, keys: ["usagePercent", "percentUsed", "usedPercent"]),
                  percent.isFinite, percent >= 0,
                  let kind = subscriptionKind(forProductName: name)
            else { return nil }
            sums[kind, default: 0] += percent
        }
        let ordered = QuotaKind.subscriptionCases.compactMap { kind -> PoolShare? in
            guard let percent = sums[kind] else { return nil }
            return PoolShare(kind: kind, percent: percent)
        }
        guard ordered.count == sums.count, ordered.count >= 2 else { return nil }
        return ordered
    }

    static func subscriptionKind(forProductName name: String) -> QuotaKind? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "grok bot", "grokbot":
            return .grokBot
        case "cursor", "cursor models":
            return .cursorModels
        case "other", "other models":
            return .otherModels
        default:
            return nil
        }
    }

    /// A non-zero segment is at least this many points on the 0–100% track
    /// when the track can hold that floor for every non-zero segment.
    /// The Ultra Usage track uses `exactSegmentWidths` instead, so a printed
    /// percent is never drawn wider than that percent of the track.
    static let visibleSegmentMinimum = 4.0

    /// Point widths for `fractions` along a track of `usable` points.
    /// Zero fractions stay at 0. A positive fraction is at least `minimum`
    /// points, then shrunk only if those floors would overflow the track.
    /// Does not change the percents printed next to the bar.
    static func visibleSegmentWidths(
        fractions: [Double],
        usable: Double,
        minimum: Double = visibleSegmentMinimum
    ) -> [Double] {
        guard usable > 0 else { return Array(repeating: 0, count: fractions.count) }
        let positiveCount = fractions.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        guard positiveCount > 0 else { return Array(repeating: 0, count: fractions.count) }
        let floor = min(max(0, minimum), usable / Double(positiveCount))
        let widths = fractions.map { fraction -> Double in
            guard fraction > 0 else { return 0 }
            return max(floor, usable * fraction)
        }
        let sum = widths.reduce(0, +)
        guard sum > usable + 0.000_001 else { return widths }

        let protected = widths.map { $0 > 0 ? min($0, floor) : 0.0 }
        let protectedSum = protected.reduce(0, +)
        let flexible = zip(widths, protected).map { max(0, $0 - $1) }
        let flexibleSum = flexible.reduce(0, +)
        let flexibleBudget = max(0, usable - protectedSum)
        guard flexibleSum > 0, flexibleBudget > 0 else {
            let scale = usable / sum
            return widths.map { $0 * scale }
        }
        let scale = flexibleBudget / flexibleSum
        return zip(protected, flexible).map { $0 + $1 * scale }
    }

    private static func combinedPace(
        _ samples: [AllowanceSample],
        usedPercent: Double,
        now: Date
    ) -> QuotaPace? {
        var expectedSum = 0.0
        var dated = 0
        for sample in samples {
            guard let start = sample.start, let end = sample.end else { return nil }
            let duration = end.timeIntervalSince(start)
            guard duration > 60 else { return nil }
            let elapsed = min(1, max(0, now.timeIntervalSince(start) / duration))
            expectedSum += elapsed * 100
            dated += 1
        }
        guard dated == samples.count, dated > 0 else { return nil }
        let expected = expectedSum / Double(dated)
        // Same early-period rule as `pace`: the first 2% of the window is on pace.
        if expected < 2 { return .onPace }
        let delta = Int((usedPercent - expected).rounded())
        if delta >= 1 { return .over(delta) }
        if delta <= -1 { return .under(abs(delta)) }
        return .onPace
    }

    /// Linear pace: used % versus how much of the period has elapsed.
    static func pace(usedPercent: Double, start: Date?, end: Date?, now: Date) -> QuotaPace? {
        guard let start, let end else { return nil }
        let total = end.timeIntervalSince(start)
        guard total > 60 else { return nil }
        let elapsed = min(1, max(0, now.timeIntervalSince(start) / total))
        guard elapsed >= 0.02 else { return .onPace }
        let delta = Int((usedPercent - (elapsed * 100)).rounded())
        if delta >= 1 { return .over(delta) }
        if delta <= -1 { return .under(abs(delta)) }
        return .onPace
    }

    static func inferredPeriodStart(for kind: QuotaKind, reset: Date?) -> Date? {
        guard let reset else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        switch kind {
        case .cursorModels, .otherModels, .onDemand:
            return calendar.date(byAdding: .month, value: -1, to: reset)
        case .superGrok, .grokBot:
            return reset.addingTimeInterval(-7 * 24 * 60 * 60)
        case .xaiCredits:
            return nil
        }
    }

    static func resetCaption(reset: Date?, now: Date) -> String {
        guard let reset else { return "" }
        let day = monthDay.string(from: reset)
        let remaining = remainingPhrase(until: reset, now: now)
        if remaining.isEmpty {
            return "Resets \(day)"
        }
        return "Resets \(day) (\(remaining) left)"
    }

    /// One line for pools that reset together. Clock time is America/Chicago,
    /// to the minute, labeled CT. Days include leftover hours and minutes:
    /// "Resets Nov 3, 2:49 PM CT · 6d 23h 9m left"
    static func subscriptionResetLine(reset: Date, now: Date) -> String {
        let clock = subscriptionResetClock.string(from: reset)
        let remaining = subscriptionRemainingPhrase(until: reset, now: now)
        if remaining.isEmpty {
            return "Resets \(clock) CT"
        }
        return "Resets \(clock) CT · \(remaining) left"
    }

    /// Subscription reset countdown. A day or more is always "Nd Hh Mm",
    /// including a zero hour or minute. Shorter windows match `remainingPhrase`.
    static func subscriptionRemainingPhrase(until end: Date, now: Date) -> String {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return "" }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes >= 24 * 60 {
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            return "\(days)d \(hours)h \(minutes)m"
        }
        return remainingPhrase(until: end, now: now)
    }

    /// True when every date prints as the same Chicago minute. An empty list
    /// does not share a line. Callers pass only the ready pools' resets.
    static func subscriptionResetsShareOneLine(_ resets: [Date]) -> Bool {
        guard let first = resets.first else { return false }
        let clock = subscriptionResetClock.string(from: first)
        return resets.dropFirst().allSatisfy { subscriptionResetClock.string(from: $0) == clock }
    }

    static func remainingPhrase(until end: Date, now: Date) -> String {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return "" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours >= 24 {
            let days = hours / 24
            let leftoverHours = hours % 24
            if leftoverHours == 0 {
                return days == 1 ? "1 day" : "\(days) days"
            }
            return "\(days)d \(leftoverHours)h"
        }
        if hours == 0 {
            if minutes == 0 { return "under a minute" }
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let hourWord = hours == 1 ? "1 hour" : "\(hours) hours"
        if minutes == 0 { return hourWord }
        let minuteWord = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return "\(hourWord) and \(minuteWord)"
    }

    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    static func parseResetValue(_ value: Any?) -> Date? {
        if let text = value as? String {
            if let iso = parseISODate(text) { return iso }
            return Double(text).flatMap(epochDate)
        }
        if let number = value as? NSNumber {
            return epochDate(number.doubleValue)
        }
        return nil
    }

    /// Epoch milliseconds or seconds; anything before 2001 is not a reset date.
    private static func epochDate(_ raw: Double) -> Date? {
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        if raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: raw)
        }
        return nil
    }

    static func percentInMessage(_ message: String?) -> Double? {
        guard let message, let percentIndex = message.firstIndex(of: "%") else { return nil }
        let before = message[..<percentIndex]
        let start = before.lastIndex(where: { !$0.isNumber && $0 != "." })
        let numberStart = start.map { before.index(after: $0) } ?? before.startIndex
        return Double(before[numberStart...])
    }

    static func ratioPercent(_ dict: [String: Any], usedKeys: [String], limitKeys: [String]) -> Double? {
        guard let used = firstNumber(dict, keys: usedKeys),
              let limit = firstNumber(dict, keys: limitKeys),
              limit > 0
        else { return nil }
        return (used / limit) * 100
    }

    static func firstNumber(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let parsed = number(from: dict[key]) {
                return parsed
            }
        }
        return nil
    }

    static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String, let parsed = Double(text) {
            return parsed
        }
        if let nested = value as? [String: Any] {
            if let inner = firstNumber(nested, keys: ["val", "value", "cents"]) {
                return inner
            }
            if let units = number(from: nested["units"]) {
                let nanos = number(from: nested["nanos"]) ?? 0
                return units * 100 + nanos / 10_000_000
            }
        }
        return nil
    }

    private static func wholePercent(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static var monthDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }

    private static let chicago: TimeZone = {
        if let zone = TimeZone(identifier: "America/Chicago") {
            return zone
        }
        return TimeZone(secondsFromGMT: 0) ?? .current
    }()

    private static var subscriptionResetClock: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = chicago
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }
}

enum SubscriptionPlanName {
    static func cursor(from root: [String: Any]) -> String? {
        guard let raw = namedString(in: root, keys: [
            "membershipType",
            "individualMembershipType",
            "stripeMembershipType",
            "teamMembershipType",
            "membership",
            "planName",
            "subscriptionName",
        ]) else { return nil }
        return cursorDisplay(raw)
    }

    static func cursorDisplay(_ raw: String) -> String {
        let key = normalized(raw)
        switch key {
        case "ultra": return "Cursor Ultra"
        case "pro": return "Cursor Pro"
        case "proplus", "pro+": return "Cursor Pro+"
        case "free", "hobby", "freetrial": return "Cursor Free"
        case "business", "team": return "Cursor Business"
        case "enterprise": return "Cursor Enterprise"
        default:
            let pretty = prettify(raw)
            if pretty.lowercased().hasPrefix("cursor") { return pretty }
            return "Cursor \(pretty)"
        }
    }

    static func grok(from config: [String: Any]) -> String {
        if let raw = namedString(in: config, keys: [
            "planName",
            "planDisplayName",
            "subscriptionName",
            "tierName",
            "membershipName",
            "subscriptionTier",
            "tier",
            "grokPlan",
            "productName",
        ]), let display = grokDisplay(raw) {
            return display
        }
        return "Grok"
    }

    static func grokDisplay(_ raw: String) -> String? {
        let key = normalized(raw)
        if key.isEmpty || key.contains("usageperiod") || key == "weekly" || key == "monthly" || key == "credits" {
            return nil
        }
        if key.contains("supergrok"), key.contains("heavy") { return "SuperGrok Heavy" }
        if key.contains("supergrok") { return "SuperGrok" }
        if key.contains("grok"), key.contains("heavy") { return "SuperGrok Heavy" }
        let pretty = prettify(raw)
        return pretty.isEmpty ? nil : pretty
    }

    static func grokBotDisplay(_ raw: String) -> String {
        let pretty = prettify(raw)
        return pretty.isEmpty ? "Grok Bot" : pretty
    }

    static func namedString(in root: [String: Any], keys: [String]) -> String? {
        var sources: [[String: Any]] = [root]
        for nest in ["plan", "subscription", "membership", "billing"] {
            if let child = root[nest] as? [String: Any] {
                sources.append(child)
            }
        }
        for source in sources {
            for key in keys {
                guard let text = source[key] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func normalized(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }

    private static func prettify(_ raw: String) -> String {
        let words = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let word = String(part)
                if word.count <= 3, word == word.uppercased() { return word }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        return words.joined(separator: " ")
    }
}

/// HTTP status and a redacted server message. Never holds the access token.
struct CursorServerRejection: Sendable, Equatable {
    var statusCode: Int
    var serverMessage: String
}

enum QuotaUnavailableCopy {
    static let grokUnavailable = "Grok usage is unavailable"
    static let grokNeedsSignIn = "Sign in with the grok CLI or Grok.app"
    static let grokCLISignInAgain = "Run grok login in Terminal, or turn on Grok.app in Settings"
    static let grokCLIOutdated = "Update the grok CLI (run grok update), then Refresh"
    /// The last ready week has ended and billing did not return a new sample.
    static let grokWeekReset = "Week reset, sign in to grok CLI"

    /// This Mac has no Cursor access token. Not used for an expired sign-in.
    static let cursorNoToken = "Open Cursor once so this Mac can read usage"
    /// JWT `exp` has passed, or Cursor returned 401/403. Opaque tokens take this path.
    static let cursorSignInExpired = "Cursor sign-in expired — open Cursor to refresh"
    /// `state.vscdb` did not answer before the read timed out.
    static let cursorStateUnreadable = "Couldn't read Cursor state. Quit Cursor if it is open, then Refresh."
    static let cursorUnreachable = "Couldn't reach Cursor. Check your connection, then Refresh."
    static let cursorPoolMissing = "Cursor usage didn't include a pool"
    /// The macOS Allow sheet was cancelled or refused. Not a missing token.
    static let cursorKeychainDenied = "Allow Keychain access to read Cursor usage"
    /// The safe-storage item is not in the login Keychain.
    static let cursorKeychainMissing = "Cursor's Keychain item was not found. Open Cursor, then Refresh."
    /// The item was found, but the stored access token did not decrypt.
    static let cursorKeychainLocked = "Cursor's saved sign-in could not be unlocked."

    static let grokBotNoToken = cursorNoToken
    static let grokBotSignInExpired = cursorSignInExpired
    static let grokBotStateUnreadable = cursorStateUnreadable
    static let grokBotUnreachable = "Couldn't reach Cursor for Grok Bot usage. Check your connection, then Refresh."
    /// The last ready week has ended and Cursor did not return a new Grok Bot sample.
    static let grokBotWeekReset = "Week reset, open Cursor to refresh"

    /// Keeps the sentence above, and appends the HTTP status when Cursor answered.
    /// A nil rejection (a local JWT expiry, a timeout with no response) stays exact.
    static func explained(_ base: String, _ rejection: CursorServerRejection?) -> String {
        guard let rejection else { return base }
        let detail = rejection.serverMessage
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty
            ? " (HTTP \(rejection.statusCode))"
            : " (HTTP \(rejection.statusCode): \(detail))"
        let combined = base + suffix
        let limit = 180
        guard combined.count > limit else { return combined }
        return String(combined.prefix(limit - 3)) + "..."
    }

    static func superGrok(hasGrokBilling: Bool, hasGrokSession: Bool) -> String {
        if !hasGrokBilling && !hasGrokSession {
            return grokNeedsSignIn
        }
        return grokUnavailable
    }
}

/// How often a pool can post a spike alert during one local day.
enum SpikeAlertRepeat: String, CaseIterable, Identifiable, Sendable {
    case once
    case every

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: "Once"
        case .every: "Every"
        }
    }
}

enum QuotaBurnEvaluator {
    static let defaultPercent = 15
    static let minimumPercent = 5
    static let maximumPercent = 50
    static let percentStep = 5

    struct Decision: Equatable {
        var shouldNotify: Bool
        var startUsed: Double
        /// How many steps of `stepPercent` have already been announced today.
        var notifiedSteps: Int
    }

    static func clampPercent(_ percent: Int) -> Int {
        let snapped = Int((Double(percent) / Double(percentStep)).rounded()) * percentStep
        return min(maximumPercent, max(minimumPercent, snapped))
    }

    /// A drop of at least this much (on the 0…1 scale, so 0.05 is 5 percentage
    /// points) below today's baseline means the pool reset. Smaller dips are noise.
    static let resetDropFraction = 0.05

    /// True when the provider's period start or reset date moved. A date that
    /// was missing on one side is not a change — learning it later is not a reset.
    static func periodDidReset(
        storedStart: Date?,
        storedEnd: Date?,
        start: Date?,
        end: Date?
    ) -> Bool {
        func changed(_ old: Date?, _ new: Date?) -> Bool {
            guard let old, let new else { return false }
            return abs(old.timeIntervalSince(new)) > 1
        }
        return changed(storedStart, start) || changed(storedEnd, end)
    }

    /// First sample of a local calendar day becomes the baseline. `usedFraction` is the raw
    /// provider value (1.2 = 120%), not the capped bar fill, so overage still counts.
    /// If the pool resets later that day — usage drops by at least `resetDropFraction`,
    /// or the period start or reset date changes — the post-reset reading becomes the
    /// baseline and the step count goes back to zero.
    /// Once notifies a single time when the climb reaches one step. Every notifies again
    /// at each further step.
    static func evaluate(
        dayKey: String,
        usedFraction: Double,
        storedDayKey: String?,
        storedStartUsed: Double?,
        notifiedSteps: Int,
        mode: SpikeAlertRepeat = .once,
        stepPercent: Int = defaultPercent,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        storedPeriodStart: Date? = nil,
        storedPeriodEnd: Date? = nil
    ) -> Decision {
        let used = max(0, usedFraction)
        guard storedDayKey == dayKey, let start = storedStartUsed else {
            return Decision(shouldNotify: false, startUsed: used, notifiedSteps: 0)
        }
        let dropped = start - used >= resetDropFraction - 0.000_001
        if dropped || periodDidReset(
            storedStart: storedPeriodStart,
            storedEnd: storedPeriodEnd,
            start: periodStart,
            end: periodEnd
        ) {
            return Decision(shouldNotify: false, startUsed: used, notifiedSteps: 0)
        }
        let step = Double(clampPercent(stepPercent)) / 100
        let reached = max(0, Int(((used - start) / step + 0.000_001).rounded(.down)))
        switch mode {
        case .once:
            if notifiedSteps > 0 {
                return Decision(shouldNotify: false, startUsed: start, notifiedSteps: notifiedSteps)
            }
            if reached >= 1 {
                return Decision(shouldNotify: true, startUsed: start, notifiedSteps: 1)
            }
            return Decision(shouldNotify: false, startUsed: start, notifiedSteps: 0)
        case .every:
            if reached > notifiedSteps {
                return Decision(shouldNotify: true, startUsed: start, notifiedSteps: reached)
            }
            return Decision(shouldNotify: false, startUsed: start, notifiedSteps: notifiedSteps)
        }
    }
}
