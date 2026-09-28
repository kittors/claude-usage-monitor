#!/usr/bin/env bash
# 生成 GitHub Release 的说明（英文）：CHANGELOG.md 中对应版本的一节 + 安装说明
# 用法：Scripts/release-notes.sh 1.0.0 [sha256]
set -euo pipefail
VERSION="${1:?usage: Scripts/release-notes.sh <version> [sha256]}"
SHA="${2:-}"
cd "$(dirname "$0")/.."

section="$(awk -v v="$VERSION" '
  /^## / { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  found { print }
' CHANGELOG.md)"
if [ -z "$section" ]; then
  echo "CHANGELOG.md has no section for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$section" | sed -e '/./,$!d'
cat <<NOTES

## Install

1. Download \`ClaudeUsageMonitor-$VERSION-macOS.zip\` below and unzip it.
2. Move **Claude Usage Monitor.app** to \`/Applications\` and open it. It lives in the menu bar (no Dock icon).
3. The app is ad-hoc signed and not notarized, so macOS may refuse to open it the first time. Go to **System Settings › Privacy & Security** and click **Open Anyway**, or run:

   \`\`\`bash
   xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"
   \`\`\`

4. To get exact limits, allow access to the \`Claude Code-credentials\` keychain item when asked (choose **Always Allow**). You need to have signed in to Claude Code on this Mac.

Requires macOS 15 or later. The app UI is in Simplified Chinese.
NOTES
if [ -n "$SHA" ]; then
  printf '\nSHA-256: `%s`\n' "$SHA"
fi
