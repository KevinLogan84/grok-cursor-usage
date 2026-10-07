import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Posts the once-a-day spike alert when a subscription bar climbs 15 points.
@MainActor
final class QuotaAlertNotifier {
    static let enabledKey = "com.grokcursorusage.alerts.enabled"

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let poster: any NotificationRequestPosting

    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    var alertsEnabled: Bool {
        didSet {
            guard alertsEnabled != oldValue else { return }
            defaults.set(alertsEnabled, forKey: Self.enabledKey)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current(),
        poster: (any NotificationRequestPosting)? = nil
    ) {
        self.defaults = defaults
        self.center = center
        self.poster = poster ?? center
        if defaults.object(forKey: Self.enabledKey) == nil {
            alertsEnabled = true
        } else {
            alertsEnabled = defaults.bool(forKey: Self.enabledKey)
        }
    }

    func refreshAuthorizationStatus() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        guard !AppDelegate.isRunningTests else { return }
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
        guard settings.authorizationStatus == .notDetermined else { return }

        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let after = await center.notificationSettings()
        authorization = after.authorizationStatus
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }
        if after.authorizationStatus == .notDetermined {
            Self.openNotificationSettings()
        }
    }

    static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.grokcursorusage.app"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func postQuotaBurn(bar: QuotaBar, dayKey: String) {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(bar.kind.title) usage spike"
        content.body =
            "\(ChicagoDay.dayLabel(for: dayKey)): \(bar.kind.title) used more than \(QuotaBurnEvaluator.dailyPercentText) of its allowance today (\(bar.usedText))."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quota-burn-\(bar.kind.rawValue)-\(dayKey)",
            content: content,
            trigger: nil
        )
        poster.post(request)
    }
}

@MainActor
protocol NotificationRequestPosting: AnyObject {
    func post(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: NotificationRequestPosting {
    func post(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }
}
