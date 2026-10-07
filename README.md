# Grok & Cursor Usage

A macOS menu bar app that shows how much of your Cursor and Grok plan you have used. A small read-only iPhone viewer is included.

![The Grok & Cursor Usage menu, showing Cursor and Grok usage bars](docs/screenshot.png)

- **Menu bar at a glance.** Shows the pool you used most recently and its percent, such as `CUR` / `11%`. It switches when a different pool moves.
- **Every pool in one menu.** Cursor Auto, Cursor API, Grok, and Grok Bot, each titled with the plan name the service reports. Pools your account does not have are left off.
- **Pace.** Each bar says whether you are over, under, or on pace for its billing period, and when it resets.
- **Spike Alerts.** An optional notification when a pool climbs 15 points in one day.
- **Settings.** Text size from 75% to 125%, System, Light, or Dark appearance, and Open at Login.
- **No account of its own.** It uses the Cursor and Grok sign-ins already on your Mac.

There is no downloadable build. Clone this repo and run it from Xcode.

## Requirements

- macOS 14 or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) from the Mac App Store
- An Apple ID added in Xcode (**Xcode → Settings → Accounts**)
- Cursor, the grok CLI, or Grok.app signed in on the same Mac

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
| Cursor Auto and Cursor API | Cursor is signed in on this Mac. The title is the plan, such as Cursor Pro or Cursor Ultra. |
| Grok | The grok CLI (`~/.grok/auth.json`, or `GROK_HOME` / `GROK_AUTH_JSON`) or Grok.app is signed in. The title is the plan, such as SuperGrok or SuperGrok Heavy. |
| Grok Bot | Cursor reports a Grok Bot allowance. |

Cursor’s token is read from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.

## Using it

- Usage reloads at launch, every minute, and when you click **Refresh**.
- The **Usage** tab lists every pool. The line under each title is the reset date, or the next step if a pool cannot be read.
- Pace compares percent used with how much of that pool’s period has passed.
- **Spike Alerts** posts once per day when a pool climbs 15 points from its first reading that day. The day follows your Mac’s time zone. If macOS never asks for permission, use **Open Notification Settings** in the **Settings** tab.
- The **Settings** tab holds Text Size, Appearance, Open at Login, Spike Alerts, and the in-app **Guide**.
- **Quit** is in the menu header.

## Troubleshooting

**Grok says to sign in, but Grok.app is signed in.** Open **System Settings → Privacy & Security → Full Disk Access** and turn on **Grok & Cursor Usage**. Grok.app keeps its grok.com session in a cookie file that other apps cannot read without that permission. Or run `grok login` in Terminal.

**Cursor says to open Cursor.** Open Cursor once and stay signed in, then click **Refresh**.

**A bar went blank after it used to work.** Cursor or Grok may have changed their usage response. Pull the latest code, or open an issue.

**Xcode signing errors.** Make sure **Team** is set on the target you are building and the bundle ID is one your team owns. On a free Apple ID, remove the iCloud keys listed above.

## Privacy

The app has no server, analytics, or tracking. It reads the Cursor and Grok sign-ins already on your Mac and sends them only to Cursor (`api2.cursor.sh`) and xAI (`grok.com`, `x.ai`) to request your usage. If iCloud is enabled, the latest usage numbers are written to your own iCloud key-value store so the iPhone viewer can show them. No tokens are written to iCloud.

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

Issues and pull requests are welcome. Please run the tests before opening a pull request, and never commit tokens, cookies, or your own team ID.

## License

[MIT](LICENSE). Copyright (c) 2026 Kevin Logan.

Not affiliated with, endorsed by, or sponsored by Anysphere (Cursor) or xAI (Grok). Cursor and Grok are trademarks of their owners.
