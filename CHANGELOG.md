# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0] - 2026-10-07

### Added

- Developer ID–signed, Apple-notarized Mac downloads on [GitHub Releases](https://github.com/KevinLogan84/grok-cursor-usage/releases/latest). The asset is [Grok-Cursor-Usage-macOS.zip](https://github.com/KevinLogan84/grok-cursor-usage/releases/latest/download/Grok-Cursor-Usage-macOS.zip).

### Fixed

- Grok Bot stays on screen when Cursor is signed out, and the row says to open Cursor and sign in, then Refresh. It is hidden only when Cursor is signed in and your account has no Grok Bot allowance.
- Spike Alerts start over when a pool resets during the day. A drop in usage, or a new billing period, becomes the new baseline, so later climbs are not measured against the reading from before the reset.
- Grok usage reads the installed grok CLI version when it can, and falls back to the built-in version when it cannot. If xAI rejects that version as outdated, the app tries once more with a newer version, or the Grok row tells you to run `grok update` and then Refresh.

[Unreleased]: https://github.com/KevinLogan84/grok-cursor-usage/compare/v1.0...HEAD
[1.0]: https://github.com/KevinLogan84/grok-cursor-usage/releases/tag/v1.0
