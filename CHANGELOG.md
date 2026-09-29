# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.4] - 2026-09-29

### Added

- **Settings > Display > Reset times** can show each reset as a full date, such as Oct 3, 2026 22:00, instead of Sat 22:00, in the system time zone. A countdown to the second can sit beside it and ticks every second. Hovering a reset shows the full date and the time zone.

### Changed

- Opening the panel checks official usage only when tokens were used since the last sync. With no new usage the numbers cannot change, so it shows the last ones without sending a request. Refresh still checks every time.
- Automatic checks follow the same rule at every interval, including the checks at launch, after wake, and at a window reset. Settings > Usage explains this under each option.

### Fixed

- A pinned interface language now stays after the app restarts. Before, it fell back to the system language on the next launch.

## [1.2.3] - 2026-09-29

### Added

- Opening the menu bar panel checks official usage right away, on by default. **Settings > Usage > Check when the panel opens** turns it off. Like Refresh, it only needs an allowed exit.
- The menu bar can show several values at once: 5-hour, week (all models), per-model weekly limits such as Fable, and today's, this week's, or this month's cost. Pick them in **Settings > Display > Menu bar values**. The default is 5-hour only. With more than one, each value sits in a narrow column under a small label, so it stays compact and says what it is. Hovering lists the full names.
- When a newer version is out, a small dot appears on **Settings…** in the panel footer. Clicking it opens **Settings > General** with the update row highlighted and the release notes open. **Skip** there hides the dot for that version only. A newer version shows it again, and Settings can still update at any time.

### Changed

- The refresh icon keeps turning until the new numbers arrive. While a check is in flight, the status next to Limits reads Syncing.
- New numbers roll into place and bars ease to their new length. When a limit rises, the increase shows beside it for a few seconds.
- Release notes in Settings are rendered as formatted Markdown: headings, nested lists, inline code, and code blocks. The notes fade out at the top and bottom edges when there is more to scroll.

## [1.2.2] - 2026-09-29

### Added

- **Settings > Usage > Check automatically** sets how often official usage is checked while Claude Code is in use:
  - **By token use** is the default. A check runs when new usage since the last check reaches $0.50 at API prices, at least every 2 minutes while tokens keep being used, and once more 15 seconds after they stop.
  - Fixed intervals of 10 seconds, 30 seconds, 1 minute, 2 minutes, and 5 minutes are also available.
- The panel lists running Claude processes. Each Claude Code session gets its own row with its working directory and memory, and hovering shows Force Quit. Claude Code in Terminal is recognized however it was installed: the install script, Homebrew, npm, or the copy inside the desktop app. Helper processes of the desktop app are counted under Claude.

### Changed

- Automatic checks run only while Claude Code is in use and the exit is allowed. In use means a Claude Code session is running, in Terminal or in the desktop app, and it used tokens in the last 5 minutes. Refresh only needs an allowed exit.
- Any two official requests are at least 10 seconds apart, down from a minute. Refresh says why when it does not send a request: it just checked, the rate limit is active, or the exit is not allowed.
- Renew login automatically is on by default again. Existing installs have it turned back on once. After that, your choice is kept.
- The app reads the login before it checks the exit, so it makes no network requests while signed out.
- Official requests always use IPv4. The panel no longer has a button to block IPv6. A direct IPv6 connection from mainland China, Hong Kong, or Macau shows a severe warning in the panel and the menu bar.
- Expanding and collapsing the process list moves the whole panel in one smooth animation. Content below no longer jumps ahead of the list or overlaps it. Pressing the row no longer dims it.
- While the exit is being checked, the panel shows placeholders in the same layout as the result, then fades the result in.
- The hidden part of the exit address is replaced digit for digit with dots, so showing the full address changes only the digits.

## [1.2.1] - 2026-09-29

### Changed

- The Claude exit address keeps a fixed width. Showing the full IP no longer shifts the row.
- Settings > General > App update opens the notes for that version. A download shows a progress bar and a percentage, in Settings and in the menu bar panel.

## [1.2.0] - 2026-09-29

### Added

- The interface follows the system language. Simplified Chinese is used when the system language is Chinese. Otherwise it is English. Settings can pin either language.
- Amounts can be shown in USD, CNY, JPY, GBP, EUR, HKD, SGD, AUD, CAD, CHF, or KRW. Rates are fetched from Frankfurter about once an hour and apply to the panel, the menu bar, and Settings.
- The app can install a newer GitHub release after checking the zip against its SHA-256 file.
- Settings can set a proxy for official usage and login renewal. Leave it empty to use the system proxy.
- The panel shows the Claude exit: the address `api.anthropic.com` sees, with the country. The address is shortened until the pointer is over it.
- A shield beside the menu bar value shows whether that exit is outside mainland China, Hong Kong, and Macau. It is on by default. Settings > Display can turn it off.
- Usage color follows how full the limit is: green, yellow-green, amber, orange, then red.

### Changed

- Official usage is requested while Claude Code is in use, at least a minute apart. Opening the panel, Refresh, and a known window reset also fetch, with that same spacing. While Claude Code is idle, the app does not call `api.anthropic.com`.
- Before each official usage request, the app checks the Claude exit. If the check fails, or the exit is in mainland China, Hong Kong, or Macau, the request is not sent.
- IPv6 stays available. The panel notes that it is still a risk, and has a button to keep this app's official requests on IPv4. If an IPv6 connection to Claude is direct from mainland China, Hong Kong, or Macau, the panel and the shield show a severe warning. That warning does not stop the usage request.
- Automatic login renewal is off by default. This version turns it off once, even if it was on before. You can turn it back on. Renewal uses the same proxy as usage.
- Requests to Anthropic no longer use a `claude-usage-monitor` user agent.

### Removed

- The manual exchange-rate field.

## [1.1.0] - 2026-09-29

### Added

- **Automatic login renewal** (on by default, Settings > Usage). Claude Code's access token expires after about 8 hours, and only the CLI renews it. The app renews it about 5 minutes before it expires, the same way Claude Code does:
  - it uses the same lock files, so it does not renew at the same time as Claude Code;
  - it checks that the keychain item can be written, writes, then reads the result back;
  - it replaces only the `claudeAiOauth` tokens and leaves the rest of the item untouched;
  - if Claude Code renewed or signed in during the attempt, the app keeps that result.

  With renewal off, the app does not write to the keychain.
- **Sign-in detection.** When the Claude Code login has expired or was cleared, the panel and Settings say so and offer Sign in with Claude Code in Terminal. That runs `claude auth login`. After you finish in the browser, the app picks up the new login.
- Settings shows when the Claude Code login expires.

### Changed

- **Official numbers only.** 5-hour and weekly percentages come from the official usage endpoint and are shown like Claude Code `/usage` (rounded down). Local estimates are gone: no extrapolation between syncs, no local-cost budgets, no inferred mid-cycle weekly reset. If the endpoint is unavailable, the app keeps the last official values and shows when they were fetched. If it has never synced, it shows the reason and leaves the percentages blank.
- The panel syncs when opened if the data is older than a minute, and again when a window resets.
- Credentials are read the way Claude Code reads them, through `/usr/bin/security`. Claude Code clears other apps' keychain access each time it rewrites the item, so the Keychain API asked for a password after every token refresh.
- **Spend follows the weekly quota.** The default window is the official weekly reset, to the second, and usage before that instant stays in the previous week. Tabs on the section switch to the billing month or to today. The month uses your billing day and the same clock. Each range ends on the last second of the window.
- The warning slider tracks the pointer in 1% steps.

### Removed

- The Plan settings page (budgets and the weekly start override). The plan comes from the account profile.

## [1.0.0] - 2026-09-29

The first public release: a minimal macOS menu bar app that shows your Claude / Claude Code usage at a glance.

### Features

- **Official limits** – 5-hour, weekly (all models) and per-model weekly (e.g. Fable) utilization with reset times, from the same endpoint Claude Code's `/usage` uses.
- **Live between syncs** – the official endpoint is polled every 5 minutes with exponential backoff on rate limits; in between, percentages are extrapolated from local usage and corrected on the next sync.
- **Mid-cycle weekly resets** – when the weekly quota is reset early (while the regular reset time stays the same), local cost is counted from the reset instead of the start of the cycle. The reset is detected from a drop in the official percentage, inferred by fitting local cost against the official percentages if the app was not running at the time, or can be set manually.
- **Billing cycle** – API-equivalent cost, requests, total tokens, input / output / cache write / cache read breakdown, cache hit rate and savings, cost per model and a 14-day trend, anchored to your billing day.
- **Accurate local accounting** – incremental parsing of `~/.claude/projects/**/*.jsonl` including sub-agent logs, de-duplicated by message and request ID (keeping the final output count), priced at official API rates (5-minute and 1-hour cache writes, per-model cache reads, fast mode).
- **Menu bar** – Clawd or the Claude logo with a percentage, a ring or dual bars; turns amber past your warning threshold and red near the limit.
- **Notifications** – when 5-hour or weekly usage crosses your warning threshold, and again at 95%.
- **Settings** – plan, billing day, data directory, currency (USD or CNY with a custom rate), menu bar style, warning threshold and launch at login.
- **Fast** – the first scan of about 5 GB of logs takes around 5 seconds; after that a compact binary index loads in about 20 ms and incremental updates driven by FSEvents take about 40 ms.

### Privacy

- Claude Code's credentials are read from the keychain, kept in memory only and sent only to `api.anthropic.com`. They are never written to disk, logged, refreshed or modified, so Claude Code's own sign-in is never affected.
- Session logs are read locally and never uploaded.

### Notes

- The app UI is in Simplified Chinese.
- Local cost only covers Claude Code on this Mac. Usage from claude.ai, the mobile apps or other computers shows up in the official percentages only.
- If Claude Code's credentials have expired, the app falls back to local estimates until Claude Code (the CLI) refreshes them.
