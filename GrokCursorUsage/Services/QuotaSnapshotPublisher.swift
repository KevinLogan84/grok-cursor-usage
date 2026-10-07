import Foundation

/// Writes the subscription bars to this app’s iCloud key-value store for the iPhone.
@MainActor
final class QuotaSnapshotPublisher {
    private let quotas: QuotaMonitor
    private let cloudStore: NSUbiquitousKeyValueStore
    private var debounceTask: Task<Void, Never>?
    private var lastWritten: QuotaSnapshot?
    private var isObserving = false
    private var startedAt = Date()
    private let debounceNanoseconds: UInt64 = 2_000_000_000

    init(
        quotas: QuotaMonitor,
        cloudStore: NSUbiquitousKeyValueStore = .default
    ) {
        self.quotas = quotas
        self.cloudStore = cloudStore
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        startedAt = Date()
        lastWritten = QuotaSnapshotCloud.read(store: cloudStore)
        observe()
        publishSoon()
    }

    func stop() {
        isObserving = false
        debounceTask?.cancel()
        debounceTask = nil
    }

    func flush() {
        debounceTask?.cancel()
        debounceTask = nil
        publishNow(ignoreFirstWriteCap: true)
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = quotas.bars
            _ = quotas.lastUpdated
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publishSoon()
                self?.observe()
            }
        }
    }

    private func publishSoon() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            publishNow()
        }
    }

    private func publishNow(ignoreFirstWriteCap: Bool = false) {
        let raw = QuotaSnapshot(
            version: 1,
            lastUpdated: .now,
            bars: quotas.bars.map(SnapshotQuotaBar.init)
        )
        if !ignoreFirstWriteCap,
           QuotaSnapshotPublishPolicy.shouldWaitForFirstRefresh(
            previous: lastWritten,
            quotasLastUpdated: quotas.lastUpdated,
            elapsed: Date().timeIntervalSince(startedAt)
           ) {
            scheduleFirstWriteCap()
            return
        }
        let snapshot = QuotaSnapshotPublishPolicy.prepared(previous: lastWritten, next: raw)
        guard QuotaSnapshotPublishPolicy.shouldWrite(previous: lastWritten, next: snapshot) else {
            return
        }
        QuotaSnapshotCloud.write(snapshot, store: cloudStore)
        lastWritten = snapshot
    }

    private func scheduleFirstWriteCap() {
        let remaining = QuotaSnapshotPublishPolicy.firstWriteCap - Date().timeIntervalSince(startedAt)
        let nanos = UInt64(max(0.05, remaining) * 1_000_000_000)
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            publishNow()
        }
    }
}
