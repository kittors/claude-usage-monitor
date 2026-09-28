APP := build/Claude Usage Monitor.app
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ZIP := ClaudeUsageMonitor-$(VERSION)-macOS.zip

.PHONY: app run dev test install dist release clean

## 构建 .app（release）
app:
	@./Scripts/build-app.sh

## 构建并启动 .app
run: app
	@pkill -x ClaudeUsageMonitor 2>/dev/null || true
	@open "$(APP)"

## 调试运行并自动打开面板
dev:
	@swift build
	@"$$(swift build --show-bin-path)/ClaudeUsageMonitor" --open

## 运行单元测试
test:
	@swift test

## 安装到 /Applications
install: app
	@pkill -x ClaudeUsageMonitor 2>/dev/null || true
	@rm -rf "/Applications/Claude Usage Monitor.app"
	@cp -R "$(APP)" /Applications/
	@echo "✓ 已安装到 /Applications/Claude Usage Monitor.app"

## 打包发布用的 zip：build/ClaudeUsageMonitor-<版本>-macOS.zip
dist:
	@VERSION=$(VERSION) ./Scripts/build-app.sh
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "build/$(ZIP)"
	@cd build && shasum -a 256 "$(ZIP)" > "$(ZIP).sha256"
	@echo "✓ build/$(ZIP)"

## 发版：make release VERSION=1.0.1（先在 CHANGELOG.md 写好该版本的英文说明）
release:
	@./Scripts/release.sh $(VERSION)

clean:
	@rm -rf .build build
