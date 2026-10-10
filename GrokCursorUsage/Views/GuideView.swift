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
                        bullet("Grok Bot", "Shown when Cursor reports a Grok Bot allowance. If Cursor is signed out, the row tells you to open Cursor and sign in. It is left off only when Cursor is signed in and your account has no Grok Bot allowance.")
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
                        bullet("Spike Alerts", "Notifies you when a pool climbs from its first reading today. If the pool resets during the day, the count starts over from the reading after that reset. Once sends a single notification at the amount you set. Every sends another each time the pool climbs by that amount again. The amount moves in steps of 5%, from 5% to 50%, and starts at 15%. “Day” follows this Mac’s time zone. Turn Spike Alerts off in Settings to skip it.")
                        bullet("Text Size and Appearance", "Settings has a text size slider and a System, Light, or Dark choice. System follows this Mac.")
                        bullet("Open at Login", "In Settings, after Grok & Cursor Usage.app is in /Applications. Download Grok-Cursor-Usage-macOS.zip from GitHub Releases, unzip it, and drag the app there, then open it. macOS does not show a Gatekeeper warning, because the app is notarized. Login items need that copy. A build still sitting in Xcode’s DerivedData folder will not start at login.")
                    }
                    section("On your iPhone") {
                        Text("The iPhone app is optional, and it is not in the Mac download. Build it from source. It only shows the snapshot this Mac last wrote to iCloud. It never signs in to Cursor or Grok. Building it is covered in the README: use your own Apple team, your own bundle IDs, and an iCloud container your developer account owns. The container checked into the repo belongs to the author.")
                        bullet("Same iCloud account", "Sign the Mac and the iPhone into the same Apple ID.")
                        bullet("Same signing team", "Sign the Mac app and the GrokCursorUsageIOS scheme with your Apple team. Enable iCloud Key-value storage and your container on both App IDs.")
                        bullet("Run the Mac app", "Leave Grok & Cursor Usage running once so it can publish a snapshot.")
                        bullet("Refresh", "The phone updates when iCloud delivers a new snapshot. Refresh asks iCloud again. The iPhone target requires iOS 26.")
                    }
                    section("If a bar stays blank") {
                        Text("The row says what to do next, such as opening Cursor, running grok login, or running grok update. A Cursor or Grok change can also blank a bar until this app is updated: quit from the menu header, download the new release, and replace Grok & Cursor Usage.app in /Applications. If the menu shows Update, that is the new copy. There is no Dock icon.")
                    }
                    section("Updates") {
                        Text("When a newer version is published, the top of the menu says Update available. Update opens what’s new in that version. Download opens the new copy. Quit the app, then replace Grok & Cursor Usage.app in /Applications. The check runs when you open the app, and then at most once a day. It asks GitHub whether a public release is newer. It sends no usage, sign-in, or account name, and it stays quiet if you are offline. The app does not install the update for you.")
                    }
                    section("Feedback") {
                        Text("Send Feedback opens a draft in your mail app. The subject is already filled in. The draft includes this app’s version and build, and this Mac’s macOS version. Usage, sign-ins, and account names are left out. Nothing is sent until you send the draft yourself. If this Mac’s default email app is a browser, Send Feedback shows the address so you can copy it, instead of opening a browser tab. Open Mail Draft Anyway still opens a draft. To use a mail app next time, set Mail > Settings > General > Default email reader.")
                    }
                    SendFeedbackButton(presentsAsSheet: true)
                        .glassPlainButton(compact: true)
                    section("Privacy") {
                        Text("The app reads the Cursor and grok CLI sign-ins already on this Mac, plus Grok.app’s if you opt in. It never changes them, and uses them only to ask Cursor and xAI for your usage. If iCloud is enabled, the latest usage numbers, never your sign-ins, go to your own iCloud for the iPhone app. The project runs no server and includes no analytics or tracking. Send Feedback only opens a draft in your mail app, or shows the address to copy if a browser would open instead. The update check only asks GitHub if a newer public release exists.")
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
