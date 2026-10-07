# Grok & Cursor Usage

Menu bar app for the Cursor and Grok usage pools on your Mac. It shows only the pools that account has, and each title is the plan name those services report. The app has no account of its own. It reads the Cursor and Grok sign-in already on that Mac.

The menu bar shows the pool you used most recently, plus its percent. It switches when another pool’s usage moves. Open it for every bar, the pace line, and the reset line.

There is no downloadable build. Clone this repo and run it from Xcode:

[github.com/KevinLogan84/grok-cursor-usage](https://github.com/KevinLogan84/grok-cursor-usage)

The **Guide** item in the menu is the same usage guide as the “While it is running” section below. Signing and the iPhone target are covered here, because those steps happen in Xcode before the app is open.

## What you need

- A Mac on macOS 14 or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) from the Mac App Store
- An Apple ID added in Xcode (**Xcode → Settings → Accounts**)

A free Apple ID can run the menu bar app on your own Mac. The iPhone app needs a paid [Apple Developer Program](https://developer.apple.com/programs/) membership, because it uses iCloud.

## Run it

1. Clone the repo and open `GrokCursorUsage.xcodeproj`.
2. Select the **GrokCursorUsage** scheme.
3. Select the **GrokCursorUsage** target, then **Signing & Capabilities**.
4. Set **Team** to your Apple ID. The project is checked in with team `KVVL57G45T` so the author can build. That team is not on your Mac. Switch it before you run.
5. If Xcode says the bundle ID `com.grokcursorusage.app` is unavailable, change it to one your team owns, such as `com.yourname.grokcursorusage`.
6. Press ⌘R.
7. Look in the menu bar for a two-line item such as `CUR` / `11%`. There is no Dock icon. Quit is inside the menu.

The Mac target’s entitlements ask for the iCloud container `iCloud.com.grokcursorusage`. That container belongs to the author’s developer account. A free Personal Team also cannot sign iCloud capabilities.

For the menu bar app alone, remove these three keys from `GrokCursorUsage/GrokCursorUsage.entitlements`:

- `com.apple.developer.icloud-container-identifiers`
- `com.apple.developer.icloud-services`
- `com.apple.developer.ubiquity-kvstore-identifier`

The bars still work. Skip the iPhone target. To keep iCloud and build the iPhone app, use the [iPhone](#iphone) steps and your own container.

To keep the app running after you close Xcode, choose **Product → Show Build Folder in Finder**, copy `Build/Products/Debug/Grok & Cursor Usage.app` into `/Applications`, and launch that copy. Turn on **Open at Login** from the menu after it lives in `/Applications`. Login items need that stable copy.

## What has to be signed in

| Pool | When it appears |
| --- | --- |
| Cursor Auto and Cursor API | After Cursor is signed in on your Mac. The title becomes the plan, such as Cursor Pro or Cursor Ultra. A pool Cursor does not report is left off. |
| Grok | After the grok CLI (`~/.grok/auth.json`, or `GROK_HOME` / `GROK_AUTH_JSON`) or Grok.app is signed in. The title is the plan name, such as SuperGrok or SuperGrok Heavy. |
| Grok Bot | Only when Cursor reports a Grok Bot allowance. |

Cursor’s token is read from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. Open Cursor once if that row says to.

If Grok stays blank after Grok.app is signed in, open **System Settings → Privacy & Security → Full Disk Access** and enable **Grok & Cursor Usage**. Grok.app keeps its grok.com session in a cookie file other apps cannot read until that is on.

## While it is running

- It reloads at launch, every minute, and when you click **Refresh**. The menu bar stays on the pool whose percent rose most recently, and switches when a different pool moves.
- Pace compares percent used with how much of that pool’s period has elapsed. The line reads over, under, or on pace.
- **Spike alerts** posts once per Chicago day when a bar climbs 15 points from the first reading that day. Turn the toggle off to skip it. If macOS never shows the permission sheet, use **Open Notification Settings**.
- **Guide** in the menu matches this section, plus the sign-in steps above.
- Quit is in the menu. There is no Dock icon.

A Cursor or Grok change can blank a bar until this app is updated. The line under the title is the next step.

## iPhone

Optional. The **GrokCursorUsageIOS** target is read-only. It does not sign in to Cursor or Grok. It shows the last snapshot the Mac app wrote to iCloud. Your usage stays in your iCloud account.

Building it takes a paid Apple Developer Program membership, your own bundle IDs, and your own iCloud container. The IDs in this repo are the author’s.

1. Sign the Mac and the iPhone into the same Apple ID.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources), create an iCloud container you own, such as `iCloud.com.yourname.grokcursorusage`.
3. Replace `iCloud.com.grokcursorusage` with that container in all three of these files:
   - `GrokCursorUsage/GrokCursorUsage.entitlements`
   - `GrokCursorUsageIOS/GrokCursorUsageIOS.entitlements`
   - `Shared/QuotaSnapshot.swift` (`QuotaSnapshotCodec.iCloudContainerID`)
4. Leave the key-value store identifier as `$(TeamIdentifierPrefix)com.grokcursorusage` in both entitlements files, so the Mac and the iPhone share one store under your team.
5. If Xcode says a bundle ID is unavailable, change `com.grokcursorusage.app` and `com.grokcursorusage.ios` to IDs your team owns. Use the same team on both targets.
6. On each App ID, enable **iCloud** with Key-value storage and the container from step 2.
7. Select the **GrokCursorUsageIOS** scheme, choose your iPhone, and press ⌘R. The iPhone target requires iOS 26.
8. Run the Mac app once so it publishes, then open the iPhone app.
9. **REFRESH** asks iCloud for a newer snapshot. The stamp under the title is how old the Mac’s last write is.

## Tests

In Xcode, with the **GrokCursorUsage** scheme selected, press ⌘U.

```bash
xcodebuild test -project GrokCursorUsage.xcodeproj -scheme GrokCursorUsage -destination 'platform=macOS' \
  -only-testing:GrokCursorUsageTests CODE_SIGNING_ALLOWED=NO
```

## License

[MIT](LICENSE). Copyright (c) 2026 Kevin Logan.
