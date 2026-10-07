import Foundation

enum QuotaSnapshotRefreshResult: Equatable, Sendable {
    case updated
    case unchanged
    case empty

    var stampFeedback: String {
        switch self {
        case .updated: "Updated"
        case .unchanged: "No newer snapshot from the Mac"
        case .empty: "Waiting for the Mac"
        }
    }

    var nearbyStampFeedback: String? {
        switch self {
        case .updated, .unchanged: stampFeedback
        case .empty: nil
        }
    }
}

enum QuotaSnapshotRefreshPolicy {
    static let timeout: Duration = .seconds(9)
    static let pollInterval: Duration = .milliseconds(400)
    static let feedbackDuration: Duration = .seconds(3)

    static func result(
        previousLastUpdated: Date?,
        snapshot: QuotaSnapshot?
    ) -> QuotaSnapshotRefreshResult {
        guard let snapshot else { return .empty }
        guard let previousLastUpdated else { return .updated }
        return snapshot.lastUpdated > previousLastUpdated ? .updated : .unchanged
    }

    static func hasNewerSnapshot(
        previousLastUpdated: Date?,
        snapshot: QuotaSnapshot?
    ) -> Bool {
        result(previousLastUpdated: previousLastUpdated, snapshot: snapshot) == .updated
    }
}

@MainActor
protocol QuotaSnapshotCloudSource: AnyObject {
    func synchronize()
    func readSnapshot() -> QuotaSnapshot?
}

@MainActor
protocol QuotaSnapshotRefreshTiming: AnyObject {
    var elapsed: TimeInterval { get }
    func sleep(for duration: Duration) async
}

@MainActor
final class UbiquitousQuotaSnapshotCloudSource: QuotaSnapshotCloudSource {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore) {
        self.store = store
    }

    func synchronize() {
        store.synchronize()
    }

    func readSnapshot() -> QuotaSnapshot? {
        QuotaSnapshotCloud.read(store: store)
    }
}

@MainActor
final class SystemQuotaSnapshotRefreshTiming: QuotaSnapshotRefreshTiming {
    private let origin = ContinuousClock.now

    var elapsed: TimeInterval {
        (ContinuousClock.now - origin).timeInterval
    }

    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

@MainActor
struct QuotaSnapshotRefresh {
    let source: any QuotaSnapshotCloudSource
    let timing: any QuotaSnapshotRefreshTiming
    var timeout: Duration = QuotaSnapshotRefreshPolicy.timeout
    var pollInterval: Duration = QuotaSnapshotRefreshPolicy.pollInterval

    func run(
        previousLastUpdated: Date?,
        apply: (QuotaSnapshot?) -> Void
    ) async -> QuotaSnapshotRefreshResult {
        source.synchronize()
        if hasNewer(previousLastUpdated, reloadAndApply(apply)) {
            return .updated
        }

        let limit = timeout.timeInterval
        let interval = max(pollInterval.timeInterval, 0.001)
        while timing.elapsed + 0.000_5 < limit {
            let remaining = limit - timing.elapsed
            await timing.sleep(for: .seconds(min(interval, remaining)))
            source.synchronize()
            if hasNewer(previousLastUpdated, reloadAndApply(apply)) {
                return .updated
            }
        }

        source.synchronize()
        return QuotaSnapshotRefreshPolicy.result(
            previousLastUpdated: previousLastUpdated,
            snapshot: reloadAndApply(apply)
        )
    }

    private func hasNewer(_ previousLastUpdated: Date?, _ snapshot: QuotaSnapshot?) -> Bool {
        QuotaSnapshotRefreshPolicy.hasNewerSnapshot(
            previousLastUpdated: previousLastUpdated,
            snapshot: snapshot
        )
    }

    private func reloadAndApply(_ apply: (QuotaSnapshot?) -> Void) -> QuotaSnapshot? {
        let snapshot = source.readSnapshot()
        apply(snapshot)
        return snapshot
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
