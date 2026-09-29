#!/usr/bin/env bash
# 发版：校验 → 更新版本号 → 提交 → 打 tag → 推送。GitHub Actions 收到 tag 后构建、打包并发布 Release。
# 用法：Scripts/release.sh 1.0.1（先在 CHANGELOG.md 写好 "## [1.0.1] - 日期" 一节，内容用英文）
set -euo pipefail
VERSION="${1:?用法：Scripts/release.sh <x.y.z>}"
TAG="v$VERSION"
cd "$(dirname "$0")/.."

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "版本号格式应为 x.y.z" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "工作区有未提交的改动，请先提交" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "$TAG 已存在" >&2; exit 1; fi
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md 中缺少 \"## [$VERSION]\" 一节" >&2; exit 1; }

echo "▸ 运行测试"
swift test

current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
if [ "$current" != "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
  git commit -q -m "Release $VERSION" Resources/Info.plist
fi

git tag -a "$TAG" -m "Claude Usage Monitor $VERSION"
git push origin HEAD "$TAG"
echo "✓ 已推送 ${TAG}，GitHub Actions 会构建并发布 Release"
