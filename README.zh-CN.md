# Claude Usage Monitor

[English](README.md) | [中文](README.zh-CN.md)

macOS 菜单栏应用，看 Claude 和 Claude Code 的用量。没有 Dock 图标。点一下状态栏，能看到 5 小时限额、每周限额，以及这台 Mac 上 Claude Code 会话按 API 价格折算的费用。

- Swift 与 SwiftUI，状态栏图标用 AppKit
- 限额百分比和重置时间来自与 Claude Code `/usage` 相同的接口
- 费用和 Token 明细来自本机 Claude Code 会话日志，按官方 API 价目折算
- Claude 标志、Clawd 吉祥物和小图标都是矢量绘制

## 安装

到 [Releases](https://github.com/kittors/claude-usage-monitor/releases) 下载最新的 `ClaudeUsageMonitor-<版本>-macOS.zip`，解压后把 **Claude Usage Monitor.app** 放进「应用程序」。需要 macOS 15 或更高版本。

发布包没有公证，第一次打开时系统可能会拦住。到「系统设置 > 隐私与安全性」点「仍要打开」，或执行：

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"
```

## 面板里有什么

| 区块 | 内容 |
| --- | --- |
| 用量限额 | 5 小时、本周（全部模型）、按模型的周额度（例如 Fable）的官方百分比和重置时间，显示方式与 `/usage` 一致。Claude Code 的登录缺失或过期时，面板会说明原因，并可以在终端运行 `claude auth login`。 |
| 本期消耗 | 默认统计当前每周额度窗口内的 API 等价费用。标签可以改到本月周期或当天。区间精确到秒，结束时间是该窗口的最后一秒。另外有请求数、Token 总量、输入 / 输出 / 缓存创建 / 缓存命中、缓存命中率与节省金额、按模型的费用，以及近 14 天趋势。 |
| 菜单栏 | Clawd 或 Claude 标志，加上百分比、圆环或双条。颜色随占用从绿色过渡到琥珀，再到红色。数值旁的盾牌表示 Claude 出口是否在中国大陆、香港、澳门之外。有新数据时 Clawd 会举一下手。 |
| 提醒 | 5 小时或每周用量超过预警线时通知一次，达到 95% 时再通知一次。 |

## 数字从哪来

**限额。** 应用从钥匙串读取 Claude Code 的登录，请求 `GET https://api.anthropic.com/api/oauth/usage`。百分比向下取整，与 `/usage` 相同：71.9% 显示为 71%。

这个接口大约每分钟允许一次请求，之后返回 HTTP 429。Claude Code 正在使用时才会查询官方用量：进程在运行，或会话日志刚刚写入。两次请求至少间隔一分钟。打开面板、立即刷新，以及已知窗口到达重置时间，也会按同样的间隔查询。Claude Code 闲置时不请求这个接口。遇到 429 会退避。同步失败时，继续显示上次拿到的官方数值，并标出获取时间。还从未成功同步时，面板显示原因，百分比留空。

每次请求前，应用会检查 `api.anthropic.com` 实际看到的出口。检查失败，或出口在中国大陆、香港、澳门，这次请求不会发出。IPv6 默认仍可用。面板会提示它仍是风险点，并提供按钮，让本应用的官方请求只走 IPv4。如果连到 Claude 的 IPv6 是从中国大陆、香港或澳门直连出去的，会显示严重警告。

**登录续期。** Claude Code 的 access token 大约 8 小时过期，由 Claude Code CLI 续期。桌面端用的是另一套登录，所以如果一直不跑 CLI，钥匙串里的这份登录会失效。「设置 > 用量 > 自动续期登录」默认关闭。开关打开时，过期前大约 5 分钟，应用按 Claude Code 相同的方式续期：

- 使用相同的锁（`~/.claude/.oauth_refresh.lock`、`~/.claude.lock`、`~/.claude/.storage-write.lock`），因此不会和正在续期的 Claude Code 同时进行。
- 续期会使旧的 refresh token 失效。应用先确认钥匙串条目能写回，写完再读回来核对。
- 只替换 `claudeAiOauth` 里的令牌。条目里的其他内容，包括 MCP 服务器的登录，保持原样。
- 如果这时 Claude Code 已经续期或重新登录，应用保留它的结果。

Claude Code 的登录本身也有有效期，设置页会显示这个日期。到期或在别处退出后，续期会被拒绝，Claude Code 会清空这份登录。面板这时提供「在终端中登录 Claude Code」，运行 `claude auth login`。在浏览器里完成后，应用会用上新的登录。

**费用与 Token。** 增量解析 `~/.claude/projects/**/*.jsonl`，包括子 Agent 日志。

- 一条流式消息会写成多行，中间行的 `output_tokens` 只是部分值。按 `message.id` 和 `requestId` 去重，保留最终的输出量。若只保留第一行，输出会被算少。
- 价格按公开价目：缓存写入 5 分钟为 1.25 倍，1 小时为 2 倍，缓存读取按各模型单价（Fable 5.1 为 $0.25，Opus 5.5 为 $0.20）。
- 合计与 Claude Code 自己的 `cost-state` 记录一致。

这些日志只覆盖这台 Mac 上的 Claude Code。claude.ai、手机端和其他电脑上的用量，会计入官方百分比。

**统计窗口。** 本周期按官方每周限额的 `resets_at`，每 7 天重复，精确到秒。本月周期用你设置的扣费日，时刻与这次重置相同。当天是本地自然日，从 `00:00:00` 到 `23:59:59`。

## 隐私

- 登录凭据只留在内存里。只发给 Anthropic：`api.anthropic.com` 用来取用量，`platform.claude.com` 用来续期。不写入日志。
- 钥匙串条目 `Claude Code-credentials` 通过 `/usr/bin/security` 读写，与 Claude Code 相同。这个条目信任 `security`。Claude Code 每次改写条目，都会清掉其他 App 的钥匙串授权；若改用钥匙串 API 读取，每次续期后都会再弹出一次密码框。
- 续期写回的格式与 Claude Code 写入的相同。关掉自动续期后，应用只读。
- 会话日志只在本机读取。

## 构建

需要 macOS 15 或更高版本，以及 Xcode 16 或更高版本（Swift 6 工具链）。

```bash
make app       # 构建 build/Claude Usage Monitor.app（release）
make install   # 构建并复制到 /Applications
make run       # 构建并启动
make dev       # 调试构建，并打开面板
make test      # 单元测试
make dist      # 打发布用的 zip
```

有 Apple Development 证书时用它签名，否则使用 ad-hoc 签名。可以用 `CODESIGN_IDENTITY` 指定。登录时启动使用 `SMAppService`，先执行 `make install` 再打开这项。

## 发版

1. 在 `CHANGELOG.md` 顶部写上 `## [x.y.z] - YYYY-MM-DD`，正文用英文。
2. 执行 `make release VERSION=x.y.z`。它会跑测试、写入版本号、打 tag 并推送。
3. `.github/workflows/release.yml` 在 tag 上构建 zip，并用 CHANGELOG 里对应的一节发布 GitHub Release。

## 性能

第一次启动会扫描日志并建立索引：大约 5 GB、84 万行日志需要 5 秒左右。之后：

- 索引是放在 `~/Library/Application Support/ClaudeUsageMonitor/` 的紧凑二进制文件，加载大约 20 ms。
- FSEvents 监听日志目录，只读新增的字节。一次增量更新大约 40 ms。
- 计算费用大约 60 ms。Claude Code 删掉旧日志后，索引里仍保留这些记录。

## 目录

```
Sources/
  UsageCore/                 数据层，无 UI，有单元测试
    TokenParser.swift        JSONL 增量解析，ISO 8601
    UsageIndex.swift         去重、会话元数据、文件游标、二进制缓存
    UsageCalculator.swift    本周、计费月、当天、每日趋势
    OfficialUsage.swift      用量接口模型
    ClaudeOAuth.swift        凭据解析、续期请求、写回合并
    CredentialRenewal.swift  加锁、复查、写回预检、读回核对
    DirectoryLock.swift      与 Claude Code 兼容的目录锁
    Pricing.swift            模型价目
    Formatting.swift         数字单位、货币、倒计时
  ClaudeUsageMonitor/        菜单栏应用
    App/                     状态栏、面板、图标绘制、设置窗口
    Services/                偏好、索引、官方用量、钥匙串、登录、FSEvents、提醒
    Design/                  配色、SVG、图标、Claude 标志、Clawd
    Views/                   面板与设置
Tests/UsageCoreTests/        解析、去重、定价、窗口、用量 JSON、登录续期
Scripts/build-app.sh         组装 .app
Scripts/release.sh           打 tag 并推送，由 GitHub Actions 发布
.github/workflows/           CI 与发版
```

## 许可

代码以 [MIT](LICENSE) 许可发布。Claude 标志和 Clawd 吉祥物是 Anthropic 的商标，不在该许可范围内。本项目与 Anthropic 无关。
