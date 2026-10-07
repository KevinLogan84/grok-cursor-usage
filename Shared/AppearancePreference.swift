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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = AppearancePreference.resolved(
            stored: defaults.string(forKey: Self.storageKey)
        )
        let stored = defaults.object(forKey: Self.scaleKey) as? Double
        interfaceScale = MenuMetrics.clamp(stored ?? MenuMetrics.defaultScale)
    }
}

/// Sizes for the Mac menu. `defaultScale` is a quarter larger than the original layout.
enum MenuMetrics {
    static let defaultScale = 1.25
    static let minimumScale = 1.0
    static let maximumScale = 1.6
    static let baseWidth: CGFloat = 360

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
