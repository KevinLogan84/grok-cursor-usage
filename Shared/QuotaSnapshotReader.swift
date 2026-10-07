import Foundation
import Observation

/// Reads the last Mac snapshot from this app’s iCloud key-value store.
/// The phone never signs in to Cursor or Grok.
@MainActor
@Observable
final class QuotaSnapshotReader {
    private(set) var snapshot: QuotaSnapshot?
    private let cloudStore: NSUbiquitousKeyValueStore
    private let source: any QuotaSnapshotCloudSource
    private let makeTiming: @MainActor () -> any QuotaSnapshotRefreshTiming
    private var observer: (any NSObjectProtocol)?
    private var isStarted = false

    init(
        cloudStore: NSUbiquitousKeyValueStore = .default,
        source: (any QuotaSnapshotCloudSource)? = nil,
        makeTiming: @escaping @MainActor () -> any QuotaSnapshotRefreshTiming = {
            SystemQuotaSnapshotRefreshTiming()
        }
    ) {
        self.cloudStore = cloudStore
        self.source = source ?? UbiquitousQuotaSnapshotCloudSource(store: cloudStore)
        self.makeTiming = makeTiming
    }

    func start() {
        guard !isStarted else {
            reload()
            return
        }
        isStarted = true
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
    }

    func reload() {
        source.synchronize()
        snapshot = source.readSnapshot()
    }

    func refresh() async -> QuotaSnapshotRefreshResult {
        let previousLastUpdated = snapshot?.lastUpdated
        return await QuotaSnapshotRefresh(
            source: source,
            timing: makeTiming()
        ).run(
            previousLastUpdated: previousLastUpdated,
            apply: { snapshot = $0 }
        )
    }
}
