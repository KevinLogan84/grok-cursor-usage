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

    var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: Self.storageKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = AppearancePreference.resolved(
            stored: defaults.string(forKey: Self.storageKey)
        )
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
