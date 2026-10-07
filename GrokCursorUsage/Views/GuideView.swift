import SwiftUI

struct GuideView: View {
    var appearance: AppearancePreferenceStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How to Use")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .glassPlainButton(compact: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("What you see") {
                        Text("The menu bar shows the pool that is furthest along, and its percent used. Open it for every pool on this Mac. A plan you do not have is left off, and each title is the plan name Cursor or Grok reported.")
                        bullet("Cursor", "Auto and API models are separate rows. The title is the plan, such as Cursor Pro or Cursor Ultra. Sign in to Cursor on this Mac.")
                        bullet("Grok", "The grok.com pool, titled SuperGrok, SuperGrok Heavy, or whatever plan is on the account. Sign in with the grok CLI or Grok.app.")
                        bullet("Grok Bot", "Shown only when Cursor reports a Grok Bot allowance.")
                    }
                    section("Before the bars fill in") {
                        Text("This app has no account of its own. It reads sessions that are already on this Mac, then asks Cursor and Grok for usage.")
                        bullet("Cursor", "Open Cursor once and stay signed in. The token lives in ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.")
                        bullet("SuperGrok via the CLI", "Sign in with the grok CLI so ~/.grok/auth.json exists. GROK_HOME and GROK_AUTH_JSON are honored.")
                        bullet("SuperGrok via Grok.app", "Sign in to grok.com in Grok.app. If the bar still asks you to sign in, turn on Full Disk Access for Grok & Cursor Usage so it can read Grok.app’s cookie file.")
                    }
                    section("While you test") {
                        bullet("Refresh", "Usage reloads when you open the app, every 5 minutes, and when you click Refresh.")
                        bullet("Pace", "“Over”, “under”, and “on pace” compare percent used with how much of the billing period has elapsed.")
                        bullet("Spike alerts", "Once a Chicago day, a bar that climbs 15 points from its first reading that day posts a notification. Turn Spike alerts off to skip that.")
                        bullet("Open at Login", "Turn this on after you copy the app into /Applications. Login items need a stable copy, not a build still sitting in Xcode’s DerivedData.")
                        bullet("Alongside Usage Meter", "Leave Usage Meter running. This app does not change it. Both can notify you about the same spike while you test.")
                    }
                    section("On your iPhone") {
                        Text("The iPhone app only shows these four bars. It never signs in to Cursor or Grok. The Mac writes the card to iCloud, and the phone reads it. This iCloud store is not Usage Meter’s, so the two phone apps do not overwrite each other.")
                        bullet("Same iCloud account", "Sign the Mac and the iPhone into the same Apple ID.")
                        bullet("Run the Mac app", "Leave Grok & Cursor Usage running once so it can publish a snapshot.")
                        bullet("Run the iPhone app", "In Xcode, select the GrokCursorUsageIOS scheme, team KVVL57G45T, and your iPhone. If signing asks, enable iCloud Key-value storage and the CloudKit container iCloud.com.grokcursorusage for both App IDs.")
                        bullet("Refresh", "The phone updates when iCloud delivers a new snapshot. REFRESH asks iCloud again.")
                    }
                    section("If a bar stays blank") {
                        Text("The line under the title is the next step: open Cursor, or sign in to grok.com in Grok.app. A Cursor or Grok change can also blank a bar until this app is updated. Quit is in the menu. There is no Dock icon.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 440, minHeight: 520)
        .liquidGlassBackground(preference: appearance.preference)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .font(.callout)
                .foregroundStyle(LiquidGlass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(LiquidGlass.textPrimary)
            Text(body)
                .font(.callout)
                .foregroundStyle(LiquidGlass.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
