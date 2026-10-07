import SwiftUI
#if os(macOS)
import AppKit
#endif

enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

#if os(macOS)
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
#endif

    static func resolved(stored rawValue: String?) -> AppearancePreference {
        rawValue.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}

@MainActor
@Observable
final class AppearancePreferenceStore {
    static let storageKey = "com.grokcursorusage.appearancePreference"
    static let scaleKey = "com.grokcursorusage.interfaceScale"

    var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.storageKey)
        }
    }

    /// What the system is using right now. The menu follows this when Appearance is System.
    private(set) var systemScheme: ColorScheme

    var resolvedScheme: ColorScheme {
        preference.colorScheme ?? systemScheme
    }

    /// 1.25 is a quarter larger than the original menu. The slider moves around that.
    var interfaceScale: Double {
        didSet {
            let clamped = MenuMetrics.clamp(interfaceScale)
            if clamped != interfaceScale {
                interfaceScale = clamped
                return
            }
            guard interfaceScale != oldValue else { return }
            defaults.set(interfaceScale, forKey: Self.scaleKey)
        }
    }

    private let defaults: UserDefaults
    private var isObservingSystem = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = AppearancePreference.resolved(
            stored: defaults.string(forKey: Self.storageKey)
        )
        let stored = defaults.object(forKey: Self.scaleKey) as? Double
        interfaceScale = MenuMetrics.clamp(stored ?? MenuMetrics.defaultScale)
        systemScheme = Self.currentSystemScheme()
    }

#if os(macOS)
    var resolvedNSAppearance: NSAppearance {
        switch resolvedScheme {
        case .dark: NSAppearance(named: .darkAqua)!
        case .light: NSAppearance(named: .aqua)!
        @unknown default: NSAppearance(named: .aqua)!
        }
    }

    func startObservingSystemAppearance() {
        guard !isObservingSystem else { return }
        isObservingSystem = true
        refreshSystemScheme()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSystemScheme()
            }
        }
    }

    func refreshSystemScheme() {
        let next = Self.currentSystemScheme()
        if next != systemScheme {
            systemScheme = next
        }
    }

    private static func currentSystemScheme() -> ColorScheme {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }
#else
    private static func currentSystemScheme() -> ColorScheme { .light }
#endif
}

/// Sizes for the Mac menu. `defaultScale` is a quarter larger than the original
/// layout and is shown as 100%. Text Size runs from 75% to 125% of it.
enum MenuMetrics {
    static let defaultScale = 1.25
    static let minimumPercent = 75.0
    static let maximumPercent = 125.0
    static let percentStep = 5.0
    static let minimumScale = defaultScale * minimumPercent / 100
    static let maximumScale = defaultScale * maximumPercent / 100
    static let baseWidth: CGFloat = 360

    static func percent(for scale: Double) -> Double {
        scale / defaultScale * 100
    }

    static func scale(forPercent percent: Double) -> Double {
        clamp(defaultScale * percent / 100)
    }

    static func clamp(_ scale: Double) -> Double {
        min(max(scale, minimumScale), maximumScale)
    }

    static func width(for scale: Double) -> CGFloat {
        baseWidth * clamp(scale)
    }

    static func points(_ original: CGFloat, scale: Double) -> CGFloat {
        original * clamp(scale)
    }

    static func font(
        _ original: CGFloat,
        scale: Double,
        weight: Font.Weight = .regular,
        monospaced: Bool = false
    ) -> Font {
        let size = points(original, scale: scale)
        if monospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .system(size: size, weight: weight)
    }
}

private struct MenuScaleKey: EnvironmentKey {
    static let defaultValue = MenuMetrics.defaultScale
}

extension EnvironmentValues {
    var menuScale: Double {
        get { self[MenuScaleKey.self] }
        set { self[MenuScaleKey.self] = newValue }
    }
}

struct AppearancePicker: View {
    @Binding var preference: AppearancePreference

    var body: some View {
        Picker("Appearance", selection: $preference) {
            ForEach(AppearancePreference.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Appearance")
    }
}
