<div align="center">

<img src="docs/images/icon.png" width="112" alt="Claude Usage Monitor icon">

# Claude Usage Monitor

**Your exact Claude limits, right in the menu bar.**

The same 5-hour and weekly numbers as Claude Code `/usage`, kept current while you work,<br>
plus what your Claude Code sessions would cost at API prices. Native, private, and quiet.

[![Release](https://img.shields.io/github/v/release/kittors/claude-usage-monitor?style=flat-square&color=D97757&label=release)](https://github.com/kittors/claude-usage-monitor/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-2b2b2b?style=flat-square&logo=apple&logoColor=white)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-4a4a4a?style=flat-square)](LICENSE)

[**Download**](https://github.com/kittors/claude-usage-monitor/releases/latest) · [中文说明](README.zh-CN.md) · [Changelog](CHANGELOG.md)

<br>

<img src="docs/images/en/hero.png" width="880" alt="The Claude Usage Monitor panel under the menu bar, next to its Display settings">

</div>

<br>

## Highlights

<table>
<tr>
<td width="50%" valign="top">

**Official numbers, never estimates**<br>
5-hour, weekly, and per-model limits come straight from the endpoint behind Claude Code `/usage`, rounded the same way.

</td>
<td width="50%" valign="top">

**A menu bar that says what it shows**<br>
5-hour by default. Add the week, Fable, or cost, and each value gets its own compact column with a small label, colored by how full it is.

</td>
</tr>
<tr>
<td valign="top">

**Checks when it matters**<br>
Only while Claude Code is in use, paced by how fast tokens go, and never within 10 seconds of the last check. Opening the panel refreshes right away when there is new usage.

</td>
<td valign="top">

**Knows its way out**<br>
Confirms the exit Anthropic sees before every request, pauses in mainland China, Hong Kong, or Macau, and warns if IPv6 goes out directly.

</td>
</tr>
<tr>
<td valign="top">

**Spend you can read**<br>
API-equivalent cost for this week, the billing month, or today, with the token mix, cache savings, a per-model split, and a 14-day trend.

</td>
<td valign="top">

**Stays signed in**<br>
Renews the Claude Code login the way Claude Code does, with the same locks, so the numbers never go stale. Shows running Claude sessions too.

</td>
</tr>
</table>

## Screenshots

<table>
<tr>
<td width="40%" align="center" valign="top">
<img src="docs/images/en/panel.png" alt="Menu bar panel"><br>
<sub><b>The panel</b> · limits, spend, and processes</sub>
</td>
<td width="60%" align="center" valign="top">
<img src="docs/images/en/settings-display.png" alt="Settings, Display"><br>
<sub><b>Settings › Display</b> · pick what the menu bar shows</sub>
</td>
</tr>
<tr>
<td colspan="2" align="center">
<img src="docs/images/en/settings-usage.png" width="560" alt="Settings, Usage"><br>
<sub><b>Settings › Usage</b> · when to check, proxy, login renewal</sub>
</td>
</tr>
</table>

## Install

Download `ClaudeUsageMonitor-<version>-macOS.zip` from the [latest release](https://github.com/kittors/claude-usage-monitor/releases/latest), unzip it, and move **Claude Usage Monitor.app** to Applications. macOS 15 or later.

The build is not notarized, so macOS may block the first open. Choose **Open Anyway** in **System Settings › Privacy & Security**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"
```

For the limits, sign in to Claude Code on this Mac once (`claude auth login`). After that the app finds the login by itself, and updates install from **Settings › General**.

## How it works

<details>
<summary><b>Limits come from Claude, not from a guess</b></summary>
<br>

The app reads the Claude Code login from the keychain and calls `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code `/usage`. Percentages are rounded down the same way: 71.9% shows as 71%. A failed sync keeps the last official values and says when they were fetched. With no successful sync yet, the panel explains why and leaves the percentages blank.

</details>

<details>
<summary><b>When it checks</b></summary>
<br>

The endpoint is rate-limited: at one request a minute it starts returning HTTP 429 after a dozen or so. Automatic checks run only while Claude Code is in use, meaning a session is running in Terminal or in the desktop app and it used tokens in the last 5 minutes. They also need tokens used since the last sync: with no new tokens the numbers cannot change, so no request is sent at any interval. **Settings › Usage › Check automatically** sets how often:

- **By token use** (default). Check once new usage since the last check reaches $0.50 at API prices, at least every 2 minutes while tokens keep going, and once more 15 seconds after they stop.
- **A fixed interval** of 10 seconds, 30 seconds, 1 minute, 2 minutes, or 5 minutes, checking only if tokens were used. Shorter intervals hit the rate limit sooner.

While Claude Code is in use, the app also checks when a window resets, at launch, after wake, and when the exit becomes allowed again. Opening the panel checks right away when tokens were used since the last sync (**Check when the panel opens**, on by default). With no new usage the numbers cannot change, so no request is sent. Like **Refresh**, it only needs an allowed exit, and the refresh icon keeps turning until the new numbers arrive. Any two requests are at least 10 seconds apart. After a 429 it backs off for 5 to 30 minutes.

</details>

<details>
<summary><b>The exit check</b></summary>
<br>

Before each request the app asks `api.anthropic.com` which exit it sees, over the same connection the request will use. If that check fails, or the exit is in mainland China, Hong Kong, or Macau, nothing is sent. Official requests use IPv4 only. If an IPv6 connection to Claude goes out directly from one of those regions, the panel and the menu bar show a severe warning. The panel checks again when the route, a network interface, or the system proxy changes, and does not poll in between. While a safe exit is checked again, the menu bar shield turns red and a short arc spins inside it. A risky exit keeps its warning until the result arrives.

</details>

<details>
<summary><b>Login renewal</b></summary>
<br>

A Claude Code access token lasts about 8 hours, and only the Claude Code CLI refreshes it. The desktop app uses a different login, so this keychain item goes stale if you never run the CLI. With **Renew login automatically** (on by default), the app renews it about 5 minutes before expiry, exactly as Claude Code does:

- It takes the same locks (`~/.claude/.oauth_refresh.lock`, `~/.claude.lock`, `~/.claude/.storage-write.lock`), so it never refreshes at the same time as Claude Code.
- Refreshing invalidates the previous refresh token, so the app first checks that the keychain item can be written, then writes it and reads it back.
- Only the `claudeAiOauth` tokens are replaced. Everything else in the item, including MCP server logins, stays as it was.
- If Claude Code refreshes or signs in during the attempt, the app keeps that result.

The login itself also expires, on the date shown in Settings. After that, or after you sign out elsewhere, the panel offers **Sign in with Claude Code in Terminal**, which runs `claude auth login`.

</details>

<details>
<summary><b>Cost and tokens</b></summary>
<br>

Session logs under `~/.claude/projects/**/*.jsonl`, including sub-agent logs, are parsed incrementally.

- A streaming message is written as several lines, and the middle lines only carry a partial `output_tokens`. Rows are deduplicated on `message.id` plus `requestId`, keeping the final count.
- Prices follow the published list: 5-minute cache writes at 1.25x, 1-hour cache writes at 2x, and cache reads at each model's rate.
- The totals match Claude Code's own `cost-state` records.

The week follows the official weekly `resets_at`, to the second. The billing month uses your billing day on the same clock. Today is the local calendar day. These logs cover Claude Code on this Mac only, while claude.ai, the mobile apps, and other computers still count in the official percentages.

</details>

## Privacy

- Credentials stay in memory and go only to Anthropic: `api.anthropic.com` for usage, `platform.claude.com` to renew the login. They are never logged.
- The keychain item `Claude Code-credentials` is read and written with `/usr/bin/security`, the same way Claude Code does it. That item trusts `security`, and each rewrite by Claude Code resets other apps' access, so going through the Keychain API would ask for your password after every renewal.
- With automatic renewal off, the app only reads the login.
- Session logs never leave this Mac.

## Build from source

macOS 15 or later and Xcode 16 or later (Swift 6 toolchain).

```bash
make app       # build/Claude Usage Monitor.app (release)
make install   # build and copy to /Applications
make run       # build and launch
make dev       # debug build, and open the panel
make test      # unit tests
make dist      # zip for a release
```

The build script signs with an Apple Development certificate when one is available and falls back to ad-hoc signing. `CODESIGN_IDENTITY` overrides it. **Launch at login** uses `SMAppService`, so run `make install` before turning it on.

<details>
<summary><b>Releasing</b></summary>
<br>

1. Add `## [x.y.z] - YYYY-MM-DD` at the top of `CHANGELOG.md`, in English.
2. Run `make release VERSION=x.y.z`. It runs the tests, sets the version, tags, and pushes.
3. `.github/workflows/release.yml` builds the zip from the tag and publishes the release with the matching changelog section.

</details>

<details>
<summary><b>Performance</b></summary>
<br>

The first launch indexes every log, about 5 seconds for 5 GB and roughly 840,000 lines. After that:

- The index is a compact binary in `~/Library/Application Support/ClaudeUsageMonitor/` that loads in about 20 ms.
- FSEvents watches the log folders and only new bytes are read, about 40 ms per update.
- Spend figures take about 60 ms to compute, and the index keeps history after Claude Code deletes old logs.

</details>

<details>
<summary><b>Project layout</b></summary>
<br>

```
Sources/
  UsageCore/                 data layer, no UI, unit-tested
    TokenParser.swift        incremental JSONL parsing, fast ISO 8601
    UsageIndex.swift         dedup, session metadata, file cursors, binary cache
    UsageCalculator.swift    week, billing month, today, daily trend
    OfficialUsage.swift      usage endpoint model
    AutoSync.swift           when to check official usage
    ClaudeOAuth.swift        credential parse, refresh request, write-back merge
    CredentialRenewal.swift  lock, re-check, write preflight, read-back
    DirectoryLock.swift      directory lock compatible with Claude Code
    Pricing.swift            model price list
    Formatting.swift         number units, currency, countdown
  ClaudeUsageMonitor/        menu bar app
    App/                     status item, panel, icon drawing, settings window
    Services/                preferences, index, official usage, keychain, login, processes, updates
    Design/                  color, SVG renderer, icons, Claude logo, Clawd
    Views/                   panel and settings
Tests/UsageCoreTests/        parsing, dedup, pricing, windows, usage JSON, login renewal, check timing
Scripts/                     build the .app, tag a release
.github/workflows/           CI and release
```

</details>

## License

Code is [MIT](LICENSE). The Claude logo and the Clawd mascot are trademarks of Anthropic and are not covered by that license. This project is not affiliated with Anthropic.
