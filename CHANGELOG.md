# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
