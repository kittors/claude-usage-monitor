# Claude Usage Monitor

[English](README.md) | [中文](README.zh-CN.md)

A macOS menu bar app for Claude and Claude Code usage. It has no Dock icon. Click it for the 5-hour limit, the weekly limit, and what this Mac's Claude Code sessions would have cost at API prices.

- Swift and SwiftUI, with the status item in AppKit
- Limit percentages and reset times come from the same endpoint as Claude Code `/usage`
- Cost and token detail come from local Claude Code session logs, priced from the official API list
- The Claude logo, the Clawd mascot, and the small icons are drawn as vectors

## Install

Download the latest `ClaudeUsageMonitor-<version>-macOS.zip` from [Releases](https://github.com/kittors/claude-usage-monitor/releases). Unzip it and move **Claude Usage Monitor.app** into Applications. Requires macOS 15 or later.

The build is not notarized, so the first open can be blocked. In **System Settings > Privacy & Security**, choose **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"
```

## What you see

| Section | Contents |
| --- | --- |
| Limits | 5-hour, weekly (all models), and per-model weekly percentages (for example Fable), with reset times, shown the same way as `/usage`. If the Claude Code login is missing or expired, the panel says so and can run `claude auth login` in Terminal. |
| Spend | API-equivalent cost for the current weekly quota window. Tabs switch that view to the billing month or to today. The range is printed to the second and ends on the last second of the window. Also requests, token totals, input / output / cache write / cache read, cache hit rate and the amount caching saved, cost by model, and a 14-day trend. |
| Menu bar | Clawd or the Claude logo, plus a percentage, a ring, or two bars. Past your warning line it turns amber. Near the cap it turns red. Clawd raises a hand when new data arrives. |
| Alerts | A notification when 5-hour or weekly usage crosses your warning line, and another at 95%. |

## Where the numbers come from

**Limits.** The app reads the Claude Code login from the keychain and calls `GET https://api.anthropic.com/api/oauth/usage`. Percentages are rounded down, as in `/usage`: 71.9% is shown as 71%.

The endpoint allows roughly one request a minute and then returns HTTP 429. The app syncs every 5 minutes, again when you open the panel if the last sync is older than a minute, and again when a window reaches its reset time. After a 429 it backs off. A failed sync keeps the last official values and shows when they were fetched. With no successful sync yet, the panel shows the reason and leaves the percentages blank.

**Login renewal.** A Claude Code access token lasts about 8 hours, and the Claude Code CLI is what refreshes it. The desktop app uses a different login, so this keychain item goes stale if you never run the CLI. **Settings > Usage > Renew login automatically** is on by default. About 5 minutes before expiry the app renews the token the same way Claude Code does:

- It takes the same locks (`~/.claude/.oauth_refresh.lock`, `~/.claude.lock`, `~/.claude/.storage-write.lock`), so it does not refresh at the same time as Claude Code.
- Refreshing invalidates the previous refresh token. The app checks that the keychain item can be written, writes it, then reads it back.
- Only the `claudeAiOauth` tokens are replaced. Everything else in the item, including MCP server logins, is left as it was.
- If Claude Code refreshes or signs in during the attempt, the app keeps that result.

The Claude Code login has its own expiry, shown in Settings. Once that date passes, or you sign out elsewhere, renewal is rejected and Claude Code clears the item. The panel then offers **Sign in with Claude Code in Terminal**, which runs `claude auth login`. After you finish in the browser, the app picks up the new login.

**Cost and tokens.** Session logs under `~/.claude/projects/**/*.jsonl` are parsed incrementally, including sub-agent logs.

- A streaming message is written as several lines, and the middle lines only have a partial `output_tokens`. Rows are deduplicated on `message.id` plus `requestId`, and the final output count is the one that is kept. Keeping the first line undercounts output.
- Prices follow the published list: 5-minute cache writes at 1.25x, 1-hour cache writes at 2x, cache reads at the per-model rate (Fable 5.1 at $0.25, Opus 5.5 at $0.20).
- The totals match Claude Code's own `cost-state` records.

These logs are Claude Code on this Mac. claude.ai, the mobile apps, and other computers still count in the official percentages.

**Spend windows.** The week follows the official weekly `resets_at`, every 7 days, to the second. The billing month uses the day you set and that same clock. Today is the local calendar day, `00:00:00` through `23:59:59`.

## Privacy

- Credentials stay in memory. They go only to Anthropic: `api.anthropic.com` for usage, `platform.claude.com` to renew the login. They are not written to the log.
- The keychain item `Claude Code-credentials` is read and written with `/usr/bin/security`, which is how Claude Code itself does it. The item trusts `security`. Each time Claude Code rewrites it, other apps lose keychain access, and reading through the Keychain API asks for your password again after every renewal.
- The renewal write uses the same shape Claude Code writes. With automatic renewal off, the app only reads.
- Session logs stay on this Mac.

## Build

macOS 15 or later, and Xcode 16 or later (the Swift 6 toolchain).

```bash
make app       # build/Claude Usage Monitor.app (release)
make install   # build and copy to /Applications
make run       # build and launch
make dev       # debug build, and open the panel
make test      # unit tests
make dist      # zip for a release
```

The script signs with an Apple Development certificate when you have one, and uses ad-hoc signing otherwise. `CODESIGN_IDENTITY` overrides that. Launch at login uses `SMAppService`. Run `make install` before turning it on.

## Release

1. Add `## [x.y.z] - YYYY-MM-DD` at the top of `CHANGELOG.md`, in English.
2. Run `make release VERSION=x.y.z`. It runs the tests, sets the version, tags, and pushes.
3. `.github/workflows/release.yml` builds the zip from that tag and publishes the GitHub Release from the matching changelog section.

## Performance

The first launch scans the logs and builds an index: about 5 seconds for 5 GB and roughly 840,000 lines. After that:

- The index is a compact binary in `~/Library/Application Support/ClaudeUsageMonitor/`, and loads in about 20 ms.
- FSEvents watches the log directories and reads only new bytes. An incremental update is about 40 ms.
- Computing the spend figures is about 60 ms. The index keeps rows after Claude Code deletes old logs.

## Layout

```
Sources/
  UsageCore/                 data layer, no UI, unit-tested
    TokenParser.swift        incremental JSONL parsing, fast ISO 8601
    UsageIndex.swift         dedup, session metadata, file cursors, binary cache
    UsageCalculator.swift    week, billing month, today, daily trend
    OfficialUsage.swift      usage endpoint model
    ClaudeOAuth.swift        credential parse, refresh request, write-back merge
    CredentialRenewal.swift  lock, re-check, write preflight, read-back
    DirectoryLock.swift      directory lock compatible with Claude Code
    Pricing.swift            model price list
    Formatting.swift         number units, currency, countdown
  ClaudeUsageMonitor/        menu bar app
    App/                     status item, panel, icon drawing, settings window
    Services/                preferences, index, official usage, keychain, login, FSEvents, alerts
    Design/                  color, SVG renderer, icons, Claude logo, Clawd
    Views/                   panel and settings
Tests/UsageCoreTests/        parse, dedup, pricing, windows, usage JSON, login renewal
Scripts/build-app.sh         assemble the .app
Scripts/release.sh           tag and push; GitHub Actions publishes
.github/workflows/           CI and release
```

## License

Code is [MIT](LICENSE). The Claude logo and the Clawd mascot are trademarks of Anthropic and are not covered by that license. This project is not affiliated with Anthropic.
