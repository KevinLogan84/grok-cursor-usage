import AppKit
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let launchAtLogin = LaunchAtLoginManager()
    let appearance = AppearancePreferenceStore()
    let grokSource = GrokSignInSourceStore()
    let notifier: QuotaAlertNotifier
    let quotas: QuotaMonitor
    let snapshots: QuotaSnapshotPublisher
    let updates = AppUpdateChecker()

    init() {
        let notifier = QuotaAlertNotifier()
        self.notifier = notifier
        quotas = QuotaMonitor(notifier: notifier)
        snapshots = QuotaSnapshotPublisher(quotas: quotas)
        quotas.start()
        snapshots.start()
        updates.start()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?

    nonisolated static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil
            || environment.keys.contains { $0.hasPrefix("XCTest") }
            || environment["SWIFT_TESTING_ENABLED"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        let model = AppModel()
        model.appearance.startObservingSystemAppearance()
        self.model = model
        statusBar = StatusBarController(model: model)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await model.notifier.requestAuthorizationIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.snapshots.flush()
        model?.quotas.stop()
        model?.snapshots.stop()
        model?.updates.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct GrokCursorUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
