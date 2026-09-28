# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
