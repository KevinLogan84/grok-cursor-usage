import SwiftUI

struct GuideView: View {
    var appearance: AppearancePreferenceStore
    var onClose: () -> Void

    private var scale: Double { appearance.interfaceScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How to Use")
                    .font(MenuMetrics.font(22, scale: scale, weight: .semibold))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .glassPlainButton(compact: true)
            }
            .padding(.horizontal, MenuMetrics.points(20, scale: scale))
            .padding(.top, MenuMetrics.points(18, scale: scale))
            .padding(.bottom, MenuMetrics.points(8, scale: scale))

            ScrollView {
                VStack(alignment: .leading, spacing: MenuMetrics.points(18, scale: scale)) {
                    section("What you see") {
                        Text("The menu bar shows the pool you used most recently, and its percent. It switches when another pool’s usage moves. Open it for every pool on this Mac. A pool your account does not have is left off. When Cursor or Grok reports your plan name, that becomes the title.")
                        bullet("Cursor", "Auto and API models are separate rows, titled with your plan, such as Cursor Pro, when Cursor reports it. Sign in to Cursor on this Mac.")
                        bullet("Grok", "The grok.com pool, titled with your plan, such as SuperGrok, when Grok reports it. Sign in with the grok CLI, or opt in to Grok.app in Settings.")
                        bullet("Grok Bot", "Shown only when Cursor reports a Grok Bot allowance.")
                    }
                    section("Before the bars fill in") {
                        Text("This app has no account of its own. It reads sessions that are already on this Mac, then asks Cursor and Grok for usage.")
                        bullet("Cursor", "Open Cursor once and stay signed in. The token lives in ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.")
                        bullet("Grok via the CLI (default)", "Run grok login in Terminal so ~/.grok/auth.json exists. No extra permissions are needed.")
                        bullet("Grok via Grok.app (optional)", "In Settings, set Grok Sign-In to CLI + Grok.app, then turn on Full Disk Access for Grok & Cursor Usage so it can read Grok.app’s cookie file. The CLI is still tried first.")
                    }
                    section("While it is running") {
                        bullet("Refresh", "Usage reloads when you open the app, every minute, and when you click Refresh. The menu bar name follows whichever pool rose.")
                        bullet("Pace", "“Over”, “under”, and “on pace” compare percent used with how much of the billing period has elapsed.")
                        bullet("Spike Alerts", "At most once per pool each day, a pool that climbs 15 points from its first reading that day posts a notification. “Day” follows this Mac’s time zone. Turn Spike Alerts off in Settings to skip it.")
                        bullet("Text Size and Appearance", "Settings has a text size slider and a System, Light, or Dark choice. System follows this Mac.")
                        bullet("Open at Login", "In Settings. Turn this on after you copy the app into /Applications. In Xcode, use Product → Show Build Folder in Finder and copy Build/Products/Debug/Grok & Cursor Usage.app. Login items need that copy, not a build still sitting in DerivedData.")
                    }
                    section("On your iPhone") {
                        Text("The iPhone app is optional. It only shows the snapshot this Mac last wrote to iCloud. It never signs in to Cursor or Grok. Building it is covered in the README: use your own Apple team, your own bundle IDs, and an iCloud container your developer account owns. The container checked into the repo belongs to the author.")
                        bullet("Same iCloud account", "Sign the Mac and the iPhone into the same Apple ID.")
                        bullet("Same signing team", "Sign the Mac app and the GrokCursorUsageIOS scheme with your Apple team. Enable iCloud Key-value storage and your container on both App IDs.")
                        bullet("Run the Mac app", "Leave Grok & Cursor Usage running once so it can publish a snapshot.")
                        bullet("Refresh", "The phone updates when iCloud delivers a new snapshot. Refresh asks iCloud again. The iPhone target requires iOS 26.")
                    }
                    section("If a bar stays blank") {
                        Text("The row says what to do next, such as opening Cursor or running grok login. A Cursor or Grok change can also blank a bar until this app is updated. Quit is in the menu header. There is no Dock icon.")
                    }
                    section("Privacy") {
                        Text("The app reads the Cursor and grok CLI sign-ins already on this Mac without changing them, and Grok.app’s only if you opt in, and uses them only to ask Cursor and xAI for your usage. If iCloud is enabled, the latest usage numbers, never your sign-ins, go to your own iCloud for the iPhone app. The project runs no server and includes no analytics or tracking.")
                    }
                }
                .padding(.horizontal, MenuMetrics.points(20, scale: scale))
                .padding(.bottom, MenuMetrics.points(20, scale: scale))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            minWidth: MenuMetrics.points(440, scale: scale),
            minHeight: MenuMetrics.points(520, scale: scale)
        )
        .environment(\.menuScale, scale)
        .liquidGlassBackground(scheme: appearance.resolvedScheme)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MenuMetrics.points(8, scale: scale)) {
            Text(title)
                .font(MenuMetrics.font(17, scale: scale, weight: .semibold))
            content()
                .font(MenuMetrics.font(15, scale: scale))
                .foregroundStyle(LiquidGlass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: MenuMetrics.points(2, scale: scale)) {
            Text(title)
                .font(MenuMetrics.font(15, scale: scale, weight: .semibold))
                .foregroundStyle(LiquidGlass.textPrimary)
            Text(body)
                .font(MenuMetrics.font(15, scale: scale))
                .foregroundStyle(LiquidGlass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
