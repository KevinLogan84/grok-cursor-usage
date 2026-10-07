import SwiftUI

@main
struct GrokCursorUsageIOSApp: App {
    @State private var reader = QuotaSnapshotReader()
    @State private var appearance = AppearancePreferenceStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneScreen(reader: reader, appearance: appearance)
                .preferredColorScheme(appearance.preference.colorScheme)
                .onAppear { reader.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        reader.reload()
                    }
                }
        }
    }
}
