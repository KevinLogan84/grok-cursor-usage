# Grok & Cursor Usage

A macOS menu bar app that shows how much of your Cursor and Grok plan you have used. A small read-only iPhone viewer is included.

![The Grok & Cursor Usage menu, showing Cursor and Grok usage bars](docs/screenshot.png)

- **Menu bar at a glance.** Shows the pool you used most recently and its percent, such as `CUR` / `11%`. It switches when a different pool moves.
- **Every pool in one menu.** Cursor Auto, Cursor API, Grok, and Grok Bot. When a service reports your plan name, such as Cursor Pro or SuperGrok, that becomes the title. Pools your account does not have are left off. Grok Bot still appears, with what to do, when Cursor is signed out.
- **Pace.** Each bar says whether you are over, under, or on pace for its billing period, and when it resets.
- **Spike Alerts.** An optional notification when a pool climbs during the day. Choose once or at every step, and set the step from 5% to 50%.
- **Settings.** Text size from 75% to 125%, System, Light, or Dark appearance, and Open at Login.
- **No account of its own.** It uses the Cursor and Grok sign-ins already on your Mac.

Changes are recorded in the [changelog](CHANGELOG.md).

There is no downloadable build. Clone this repo and run it from Xcode.

## Requirements

- macOS 14 or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) from the Mac App Store
- An Apple ID added in Xcode (**Xcode → Settings → Accounts**)
- Cursor, the grok CLI, or both signed in on the same Mac (Grok.app is optional)

A free Apple ID can run the menu bar app on your own Mac. The iPhone app needs a paid [Apple Developer Program](https://developer.apple.com/programs/) membership, because it uses iCloud.

## Build and run

1. Clone the repo and open `GrokCursorUsage.xcodeproj`.

   ```bash
   git clone https://github.com/KevinLogan84/grok-cursor-usage.git
   cd grok-cursor-usage
   open GrokCursorUsage.xcodeproj
   ```

2. Select the **GrokCursorUsage** scheme.
3. Select the **GrokCursorUsage** target, then **Signing & Capabilities**.
4. Set **Team** to your Apple ID. The project is checked in with the author’s team (`KVVL57G45T`), which is not on your Mac.
5. If Xcode says the bundle ID `com.grokcursorusage.app` is unavailable, change it to one your team owns, such as `com.yourname.grokcursorusage`.
6. Press ⌘R.
7. Look in the menu bar for a two-line item such as `CUR` / `11%`. There is no Dock icon. Click it to open the menu.

### Free Apple ID (Personal Team)

A Personal Team cannot sign iCloud, and the container in this repo belongs to the author. For the menu bar app alone, remove these three keys from `GrokCursorUsage/GrokCursorUsage.entitlements`:

- `com.apple.developer.icloud-container-identifiers`
- `com.apple.developer.icloud-services`
- `com.apple.developer.ubiquity-kvstore-identifier`

Everything on the Mac still works. Skip the iPhone target.

### Keep it running

To keep the app after you close Xcode, choose **Product → Show Build Folder in Finder**, copy `Build/Products/Debug/Grok & Cursor Usage.app` into `/Applications`, and open that copy. Then turn on **Open at Login** in the menu’s **Settings** tab. Login items need the copy in `/Applications`.

## Sign-ins it uses

| Pool | Shows up when |
| --- | --- |
| Cursor Auto and Cursor API | Cursor is signed in on this Mac. |
| Grok | The grok CLI is signed in (`grok login`, which writes `~/.grok/auth.json`). Grok.app works too if you turn it on, as described below. |
| Grok Bot | Cursor reports a Grok Bot allowance for your account. If Cursor is signed out, the row says to open Cursor and sign in. It is left off only when Cursor is signed in and the account has no Grok Bot allowance. |

Cursor’s token is read from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.

By default, Grok uses only the grok CLI login, and the app needs no special permissions. To use Grok.app’s sign-in instead, choose **CLI + Grok.app** under **Grok Sign-In** in the **Settings** tab, then turn on **Full Disk Access** for Grok & Cursor Usage in **System Settings → Privacy & Security**. Grok.app keeps its grok.com session in a cookie file that other apps cannot read without that permission. In that mode, the CLI is still tried first.

The `GROK_HOME` and `GROK_AUTH_JSON` environment variables are honored, but an app opened from Finder does not see variables set in your shell profile. To use them, add them under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**. They apply only when Xcode launches the app.

## Using it

- Usage reloads at launch, every minute, and when you click **Refresh**.
- The **Usage** tab lists every pool with its reset date. If a pool cannot be read, its row says what to do next.
- Pace compares percent used with how much of that pool’s period has passed.
- **Spike Alerts** watches each pool against its first reading today. If a pool resets during the day, the count starts over from the reading after that reset. **Once** notifies a single time when a pool climbs by the amount you set. **Every** notifies again at each further step. The amount moves in steps of 5%, from 5% to 50%, and starts at 15%. The day follows your Mac’s time zone. macOS asks for notification permission when you turn it on. If you declined, the **Settings** tab shows **Open Notification Settings**.
- The **Settings** tab holds Text Size, Appearance, Grok Sign-In, Open at Login, Spike Alerts, and the in-app **Guide**.
- **Quit** is in the menu header.

## Troubleshooting

**Grok says to run grok login.** The grok CLI login is missing or expired. Run `grok login` in Terminal, then click **Refresh**. Or switch **Grok Sign-In** to **CLI + Grok.app** and grant Full Disk Access.

**Grok.app is signed in, but Grok is blank.** Choose **CLI + Grok.app** under **Grok Sign-In**, then turn on **Grok & Cursor Usage** in **System Settings → Privacy & Security → Full Disk Access**. The **Open Full Disk Access Settings** button in Settings goes straight there.

**Cursor says to open Cursor.** Open Cursor once and stay signed in, then click **Refresh**.

**Grok Bot says to open Cursor.** Cursor is signed out, or its sign-in has expired. Open Cursor and sign in, then click **Refresh**. Grok Bot is hidden only when Cursor is signed in and your account has no Grok Bot allowance.

**Grok says to update the CLI.** xAI rejected the grok CLI version. Run `grok update` in Terminal, then click **Refresh**.

**A bar went blank after it used to work.** Cursor and xAI do not publish these usage endpoints, so a change on their side can break a bar. Pull the latest code, or [open an issue](https://github.com/KevinLogan84/grok-cursor-usage/issues).

**Xcode signing errors.** Make sure **Team** is set on the target you are building and the bundle ID is one your team owns. On a free Apple ID, remove the iCloud keys listed above.

## Privacy

The project runs no server and includes no analytics or tracking.

- **What it reads:** Cursor’s local database (`state.vscdb`), the grok CLI’s `auth.json`, and the installed grok CLI version when that metadata or the `grok` command is available. Grok.app’s cookie file is read only if you choose **CLI + Grok.app** and grant Full Disk Access. It does not change any of these files.
- **Where it connects:** Cursor (`api2.cursor.sh`) and xAI (`grok.com`, `auth.x.ai`), using those sign-ins to request your usage.
- **What it stores:** Settings and alert state in the app’s preferences. If iCloud is enabled, the latest usage numbers go to your own iCloud key-value store for the iPhone viewer. Sign-in tokens are never written to iCloud.

## iPhone viewer (optional)

The **GrokCursorUsageIOS** target is read-only. It never signs in to Cursor or Grok. It shows the last snapshot the Mac app wrote to your iCloud.

Building it takes a paid Apple Developer Program membership, your own bundle IDs, and your own iCloud container.

1. Sign the Mac and the iPhone into the same Apple ID.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources), create an iCloud container you own, such as `iCloud.com.yourname.grokcursorusage`.
3. Replace `iCloud.com.grokcursorusage` with that container in all three of these files:
   - `GrokCursorUsage/GrokCursorUsage.entitlements`
   - `GrokCursorUsageIOS/GrokCursorUsageIOS.entitlements`
   - `Shared/QuotaSnapshot.swift` (`QuotaSnapshotCodec.iCloudContainerID`)
4. Leave the key-value store identifier as `$(TeamIdentifierPrefix)com.grokcursorusage` in both entitlements files, so the Mac and the iPhone share one store under your team.
5. If a bundle ID is unavailable, change `com.grokcursorusage.app` and `com.grokcursorusage.ios` to IDs your team owns. Use the same team on both targets.
6. On each App ID, enable **iCloud** with Key-value storage and the container from step 2.
7. Select the **GrokCursorUsageIOS** scheme, choose your iPhone, and press ⌘R. The iPhone target requires iOS 26.
8. Run the Mac app once so it publishes, then open the iPhone app. **Refresh** asks iCloud for a newer snapshot.

## Tests

In Xcode, with the **GrokCursorUsage** scheme selected, press ⌘U. From Terminal:

```bash
xcodebuild test -project GrokCursorUsage.xcodeproj -scheme GrokCursorUsage -destination 'platform=macOS' \
  -only-testing:GrokCursorUsageTests CODE_SIGNING_ALLOWED=NO
```

## Contributing

Issues and pull requests are welcome. Please run the tests before opening a pull request. Leave your own team, bundle ID, and iCloud container changes out of it, and never commit tokens or cookies.

## License

[MIT](LICENSE). Copyright (c) 2026 Kevin Logan.

Not affiliated with, endorsed by, or sponsored by Anysphere (Cursor) or xAI (Grok). Cursor and Grok are trademarks of their owners.
