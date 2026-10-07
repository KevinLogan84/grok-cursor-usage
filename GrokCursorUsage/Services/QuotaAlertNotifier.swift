import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Posts a spike alert when a subscription bar climbs by the amount set in Settings.
@MainActor
@Observable
final class QuotaAlertNotifier {
    static let enabledKey = "com.grokcursorusage.alerts.enabled"
    static let repeatKey = "com.grokcursorusage.alerts.repeat"
    static let stepPercentKey = "com.grokcursorusage.alerts.stepPercent"

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

    var repeatMode: SpikeAlertRepeat {
        didSet {
            guard repeatMode != oldValue else { return }
            defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
        }
    }

    var stepPercent: Int {
        didSet {
            let clamped = QuotaBurnEvaluator.clampPercent(stepPercent)
            if clamped != stepPercent {
                stepPercent = clamped
                return
            }
            guard stepPercent != oldValue else { return }
            defaults.set(stepPercent, forKey: Self.stepPercentKey)
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
        repeatMode = defaults.string(forKey: Self.repeatKey).flatMap(SpikeAlertRepeat.init(rawValue:)) ?? .once
        let storedPercent = defaults.object(forKey: Self.stepPercentKey) as? Int
        stepPercent = QuotaBurnEvaluator.clampPercent(storedPercent ?? QuotaBurnEvaluator.defaultPercent)
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

    func postQuotaBurn(bar: QuotaBar, dayKey: String, climbedPercent: Int) {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(bar.title) usage spike"
        let day = LocalDay.dayLabel(for: dayKey)
        content.body = "\(day): \(bar.title) climbed \(climbedPercent)% since today's baseline (\(bar.usedText))."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "quota-burn-\(bar.kind.rawValue)-\(dayKey)-\(climbedPercent)",
            content: content,
            trigger: nil
        )
        poster.post(request)
    }

    var spikeHint: String {
        let amount = stepPercent
        let reset = " If a pool resets during the day, the count starts over."
        switch repeatMode {
        case .once:
            return "One notification per pool when it climbs \(amount)% from the first reading today." + reset
        case .every:
            return "Another notification each further \(amount)% that pool uses today." + reset
        }
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
