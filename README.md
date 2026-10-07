# Grok & Cursor Usage

Menu bar app for the four subscription pools from Usage Meter: Cursor Models, Other Models, SuperGrok Heavy, and Grok Bot. Usage Meter is unchanged. This app does not meter hotspot data, and it does not have an account of its own.

The menu bar shows whichever pool is furthest along, plus its percent used. Open it for every bar, pace, and the reset line.

## Run it

1. Open `GrokCursorUsage.xcodeproj` in Xcode.
2. Select the **GrokCursorUsage** scheme and team **KVVL57G45T**.
3. Press ⌘R.
4. Look in the menu bar for a two-line item such as `CUR` / `11%`. There is no Dock icon. Quit is inside the menu.

To keep it running after you close Xcode, copy `Grok & Cursor Usage.app` into `/Applications` and launch that copy. Turn on **Open at Login** from the menu after it lives in `/Applications`.

## What has to be signed in

| Bar | What it reads |
| --- | --- |
| Cursor Models | Cursor on this Mac, already signed in. Includes Cursor Grok. |
| Other Models | The same Cursor sign-in. Monthly named-model pool. |
| Grok Bot | The same Cursor sign-in. Weekly Grok Bot allowance. |
| SuperGrok Heavy | The grok CLI (`~/.grok/auth.json`, or `GROK_HOME` / `GROK_AUTH_JSON`), or Grok.app signed in to grok.com. |

Cursor’s token is read from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. Open Cursor once if that bar says to.

If SuperGrok still says to sign in after Grok.app is signed in, open System Settings → Privacy & Security → Full Disk Access and enable **Grok & Cursor Usage**. Grok.app keeps its grok.com session in a cookie file other apps cannot read until that is on.

## While it is running

- It reloads at launch, every 5 minutes, and when you click **Refresh**.
- Pace compares percent used with how much of that pool’s period has elapsed.
- **Spike alerts** posts once per Chicago day when a bar climbs 15 points from the first reading that day. Turn the toggle off to skip it. If macOS never shows the permission sheet, use **Open Notification Settings**.
- **Guide** in the menu is the same instruction set as this file.
- You can leave Usage Meter running. This app stores its own alert memory, so both apps can notify you about the same spike while you test.

## iPhone

The **GrokCursorUsageIOS** target is read-only. It does not sign in to Cursor or Grok. It shows the last snapshot the Mac wrote to this app’s iCloud key-value store. That store is not Usage Meter’s, so the two phone apps do not overwrite each other.

1. Sign the Mac and the iPhone into the same iCloud account.
2. In Xcode, select the **GrokCursorUsageIOS** scheme, team **KVVL57G45T**, and your iPhone.
3. If signing asks, enable **iCloud** (Key-value storage and CloudKit container `iCloud.com.grokcursorusage`) for both App IDs: `com.grokcursorusage.app` and `com.grokcursorusage.ios`.
4. Run the Mac app once so it publishes, then run the iPhone app.
5. **REFRESH** asks iCloud for a newer snapshot. The stamp under the title is how old the Mac’s last write is.

Shared iCloud:

- CloudKit container: `iCloud.com.grokcursorusage`
- Key-value store: `$(TeamIdentifierPrefix)com.grokcursorusage`

## Tests

In Xcode, with the **GrokCursorUsage** scheme selected, press ⌘U.

```bash
xcodebuild test -project GrokCursorUsage.xcodeproj -scheme GrokCursorUsage -destination 'platform=macOS' \
  -only-testing:GrokCursorUsageTests CODE_SIGNING_ALLOWED=NO
```
