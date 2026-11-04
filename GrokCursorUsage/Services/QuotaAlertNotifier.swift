import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UserNotifications)
@preconcurrency import UserNotifications
#else
/// Stand-ins so the spike-alert model compiles where UserNotifications is absent.
/// This process does not post a notification there.
struct UNAuthorizationOptions: OptionSet, Sendable {
    var rawValue: Int
    static let alert = UNAuthorizationOptions(rawValue: 1)
    static let sound = UNAuthorizationOptions(rawValue: 2)
}

enum UNAuthorizationStatus: Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

struct UNNotificationSettings: Sendable {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
}

final class UNUserNotificationCenter: @unchecked Sendable {
    static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }

    func notificationSettings() async -> UNNotificationSettings {
        UNNotificationSettings()
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        _ = options
        return false
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?) {
        _ = request
        handler?(nil)
    }
}

final class UNMutableNotificationContent: @unchecked Sendable {
    var title = ""
    var body = ""
    var sound: UNNotificationSound?
}

struct UNNotificationSound: Sendable {
    static let `default` = UNNotificationSound()
}

struct UNNotificationRequest: Sendable {
    var identifier: String
    var content: UNMutableNotificationContent

    init(identifier: String, content: UNMutableNotificationContent, trigger: Any?) {
        _ = trigger
        self.identifier = identifier
        self.content = content
    }
}
#endif

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

        #if canImport(AppKit)
        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        #endif
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let after = await center.notificationSettings()
        authorization = after.authorizationStatus
        #if canImport(AppKit)
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }
        #endif
        if after.authorizationStatus == .notDetermined {
            Self.openNotificationSettings()
        }
    }

    static func openNotificationSettings() {
        #if canImport(AppKit)
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
        #endif
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
