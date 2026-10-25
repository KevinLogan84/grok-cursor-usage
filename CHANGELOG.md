# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4] - 2026-10-25

### Fixed

- After the weekly reset, a missed Grok or Grok Bot reading no longer keeps last week's percent. The previous bar stays only while its reset is still ahead. Once that reset has passed and the new reading is missing, Grok says "Week reset, sign in to grok CLI" and Grok Bot says "Week reset, open Cursor to refresh". A missed reading before the reset still shows the last percent. The macOS log records when the grok CLI auth file is missing, and when grok.com returns a non-success status or an HTML challenge. Tokens, cookies, and the auth file are not logged.

## [1.3] - 2026-10-23

### Fixed

- An expired Cursor sign-in no longer looks like a missing one. When Cursor rejects the sign-in, Cursor Auto, Cursor API, and Grok Bot say "Cursor sign-in expired — open Cursor to refresh". "Open Cursor once so this Mac can read usage" appears only when this Mac has no Cursor token. If Cursor’s state database does not answer in time, those rows say the app couldn’t read Cursor state. The token is kept in memory and read from disk again only after a rejection, or when that database file changes.
- Cursor usage matches the request Cursor 3.27.6 sends from its always-local client. The methods stay `GetCurrentPeriodUsage` and `GetSandUsageStatus` on `api2.cursor.sh`. The body is empty protobuf (`application/proto`) over HTTP/1.1, with `User-Agent: connect-es/1.6.1`, `traceparent`, `x-client-key`, `Accept-Encoding: gzip,br`, device memory, and a lowercase `x-request-id`. `x-cursor-checksum` is unchanged. The machine id prefers sha256 of this Mac's IOPlatformUUID, and the mac id prefers sha256 of the first eligible MAC; `storage.json` is the fallback. When Cursor rejects the call, the row keeps "Cursor sign-in expired — open Cursor to refresh" and adds the HTTP status and Cursor's error text. The token is not shown. The refresh token is still not read.
- When Cursor stores the access token with safe storage, macOS asks once to allow reading the "Cursor Safe Storage" Keychain item. The decrypted token stays in memory and is not written to disk or the log. A plaintext token does not ask. If the prompt is denied, Cursor Auto, Cursor API, and Grok Bot say "Allow Keychain access to read Cursor usage" until you click Refresh and allow it. A missing Keychain item is a different message. The app does not refresh the sign-in itself.

## [1.2] - 2026-10-10

### Fixed

- Send Feedback no longer opens a browser tab when this Mac’s default email app is a browser. It shows kevinlogan@mail.grokbot.com, with Copy Address and Open Mail Draft Anyway, and explains how to choose a mail app: Mail > Settings > General > Default email reader. If a mail app is already the default, it still opens a draft. Nothing is sent until you send it yourself. On iPhone, if a draft cannot be opened, the address is shown so you can copy it.

## [1.1] - 2026-10-10

### Added

- Send Feedback, in Settings and at the end of the Guide, opens a draft in your mail app. The subject is "Grok & Cursor Usage feedback". The draft includes the app version, the build, and the macOS version. It does not include usage, sign-ins, or account names. Nothing is sent until you send it yourself. The iPhone viewer has the same button at the bottom of the screen.
- When a newer version is published, the top of the menu says Update available. Update opens what's new in that version. Download opens the new copy. Quit the app and replace Grok & Cursor Usage.app in /Applications. The app checks when you open it, and then at most once a day. The check sends no personal data, stays quiet when you are offline, and does not install the update for you.

## [1.0] - 2026-10-07

### Added

- Developer ID–signed, Apple-notarized Mac downloads on [GitHub Releases](https://github.com/KevinLogan84/grok-cursor-usage/releases/latest). The asset is [Grok-Cursor-Usage-macOS.zip](https://github.com/KevinLogan84/grok-cursor-usage/releases/latest/download/Grok-Cursor-Usage-macOS.zip).

### Fixed

- Grok Bot stays on screen when Cursor is signed out, and the row says to open Cursor and sign in, then Refresh. It is hidden only when Cursor is signed in and your account has no Grok Bot allowance.
- Spike Alerts start over when a pool resets during the day. A drop in usage, or a new billing period, becomes the new baseline, so later climbs are not measured against the reading from before the reset.
- Grok usage reads the installed grok CLI version when it can, and falls back to the built-in version when it cannot. If xAI rejects that version as outdated, the app tries once more with a newer version, or the Grok row tells you to run `grok update` and then Refresh.

[Unreleased]: https://github.com/KevinLogan84/grok-cursor-usage/compare/v1.4...HEAD
[1.4]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.4
[1.3]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.3
[1.2]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.2
[1.1]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.1
[1.0]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.0
