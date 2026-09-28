# Claude Usage Monitor

一个极简的 macOS 菜单栏应用，常驻后台，点一下就能看到 Claude / Claude Code 的用量：5 小时与每周限额、本期账单与 Token 明细。

- 原生 Swift / SwiftUI + AppKit，无 Dock 图标
- 限额百分比与重置时间来自 **Claude 官方用量接口**（与 Claude Code `/usage` 相同）
- 费用与 Token 明细来自本机 Claude Code 会话日志，按官方 API 价格折算
- 全部矢量绘制：官方 Claude 标志、Claude Code 吉祥物 Clawd、自绘 SVG 图标

## 下载安装

在 [Releases](https://github.com/kittors/claude-usage-monitor/releases) 下载最新的 `ClaudeUsageMonitor-<版本>-macOS.zip`，解压后把 **Claude Usage Monitor.app** 拖进「应用程序」。需要 macOS 15 或更高版本。

发布包没有经过 Apple 公证，第一次打开时系统可能会拦截：到「系统设置 › 隐私与安全性」中点「仍要打开」，或者执行：

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Usage Monitor.app"
```

## 功能

| 区块 | 内容 |
| --- | --- |
| 用量限额 | 5 小时、本周（全部模型）、本周 · Fable 等官方百分比与重置倒计时，以及对应窗口内的本机费用；悬停查看近 1 小时消耗速率与重置前预测 |
| 本期消耗 | 按扣费日划分的计费周期：API 等价费用、请求数、总 Tokens、四类 Token 明细、缓存命中率与节省金额、模型分布、近 14 天趋势 |
| 菜单栏 | Clawd 或 Claude 标志 + 百分比 / 圆环 / 双条；超过预警线变琥珀色，接近上限变红色；有新数据时 Clawd 会举一下手 |
| 提醒 | 5 小时或每周用量超过预警线、以及达到 95% 时各通知一次 |

## 数据从哪里来，准不准

**限额百分比（精确）**：读取 Claude Code 保存在钥匙串中的登录凭据，请求 `GET https://api.anthropic.com/api/oauth/usage`（Claude Code `/usage` 使用的同一接口），得到 5 小时、每周以及按模型划分的周额度的真实百分比与重置时间。

该接口有频率限制，App 每 5 分钟同步一次（被限流时按指数退避）；两次同步之间，用「官方百分比 + 同步之后的本机新增费用 ÷ 预算」实时推算，下次同步时再以官方值校正，菜单栏的数字不会停在几分钟前。

**费用与 Token（本机）**：增量解析 `~/.claude/projects/**/*.jsonl`（包括子 Agent 日志）：

- 同一条消息在流式写入时会落多行，中间行的 `output_tokens` 只是部分值；按 `message.id + requestId` 全局去重并取最终值（只取首条会严重低估输出量）
- 按官方价目折算：缓存写入 5 分钟 1.25×、1 小时 2×，缓存读取按各模型单价（Fable 5.1 为 $0.25、Opus 5.5 为 $0.20）
- 已用 Claude Code 自身记录的会话费用（`cost-state`）核对，结果一致

**周额度的中途重置**：官方偶尔会把周额度提前清零，但例行重置时间不变。此时如果本机费用仍从周期起点算起就会偏大，由此反推的周预算也会失真。App 会持续记录官方周百分比（持久化保存）：

- 同一周期内百分比连续两次明显下降，判定发生了中途重置，本机费用从重置之后算起
- 重置发生时 App 没在运行也能识别：对「本机累计费用 ↔ 官方百分比」做线性回归，同时得出真实周预算和重置时刻（界面标注「约」，随使用持续修正）
- 也可以在「设置 › 套餐 › 本周额度」中手动指定，只对本周期有效
- 周预算的自动校准只使用回归结果，不再用会被重置污染的「本周费用 ÷ 百分比」

**离线兜底**：官方数据不可用时（未登录、凭据过期、网络问题），5 小时 / 每周改为「本机费用 ÷ 预算」估算，并在界面上标注「估算值」。连上官方数据后，预算会根据官方百分比自动校准，离线估算也会更接近真实值。

> 本机日志只包含这台电脑上 Claude Code 的用量，网页版、手机端或其他电脑的用量不会出现在费用明细里，但会体现在官方百分比中。

## 隐私与凭据安全

- 登录凭据只在内存中使用，只发送给 `api.anthropic.com`，不落盘、不写日志
- **绝不刷新或修改凭据**：刷新会轮换 refresh token，可能让 Claude Code 掉登录。凭据过期时只会降级为估算，在终端运行一次 Claude Code（CLI）刷新凭据后自动恢复。注意：Claude 桌面端里的 Claude Code 使用自己的登录信息，不会刷新钥匙串中的这份凭据
- 首次连接时系统会询问是否允许读取「Claude Code-credentials」，选择「始终允许」即可
- 会话日志只在本机读取，不会上传任何内容

## 构建与运行

需要 macOS 15+ 与 Xcode 16+（Swift 6 工具链）。

```bash
make app       # 构建 build/Claude Usage Monitor.app（release）
make install   # 构建并安装到 /Applications
make run       # 构建并启动
make dev       # 调试运行，并自动打开面板
make test      # 单元测试
make dist      # 打包发布用的 zip
```

构建脚本会优先使用本机的 Apple Development 证书签名（签名标识稳定，钥匙串授权在重新构建后仍然有效），没有证书时使用 ad-hoc 签名；也可以通过 `CODESIGN_IDENTITY` 指定。

「登录时自动启动」使用 `SMAppService`，建议先 `make install` 再开启。

## 发版

1. 在 `CHANGELOG.md` 顶部新增 `## [x.y.z] - 日期` 一节（英文）
2. 执行 `make release VERSION=x.y.z`：跑测试、更新版本号、打 tag 并推送
3. GitHub Actions（`.github/workflows/release.yml`）收到 tag 后构建、打包，并用 CHANGELOG 中对应的一节作为说明发布 Release

## 性能

首次启动会并行扫描全部日志并建立索引（约 5GB / 84 万行日志约 5 秒），之后：

- 索引以紧凑二进制格式缓存在 `~/Library/Application Support/ClaudeUsageMonitor/`，启动加载约 20ms
- FSEvents 监听日志目录，只读取文件新增的部分，一次增量更新约 40ms
- 统计计算约 60ms；索引会保留已被 Claude Code 自动清理的历史记录

## 项目结构

```
Sources/
  UsageCore/                 数据层（无 UI，可单元测试）
    TokenParser.swift        JSONL 增量解析、ISO 8601 快速解析
    UsageIndex.swift         全局去重、会话元数据、文件游标、二进制缓存
    UsageCalculator.swift    5 小时窗口、每周窗口（含中途重置推算）、计费周期、每日趋势
    WeeklyObservationLog.swift  官方周百分比观测记录，识别中途重置
    OfficialUsage.swift      官方用量接口的响应模型
    Pricing.swift            模型价目表
    Formatting.swift         中文数字单位、货币、倒计时
  ClaudeUsageMonitor/        菜单栏 App
    App/                     NSStatusItem、弹出面板、菜单栏图标绘制、设置窗口
    Services/                偏好设置、数据仓库、官方用量、FSEvents、通知
    Design/                  配色、SVG 渲染引擎、图标库、Claude 标志与 Clawd
    Views/                   弹窗与设置页
Tests/UsageCoreTests/        解析、去重、定价、窗口计算、中途重置推算、官方响应解码
Scripts/build-app.sh         打包 .app
Scripts/release.sh           发版（打 tag 并推送，由 GitHub Actions 构建发布）
.github/workflows/           CI 与发版流程
```

## 许可

代码以 [MIT](LICENSE) 许可发布。Claude 标志与 Clawd 吉祥物为 Anthropic 的商标，不在该许可范围内；本项目与 Anthropic 无关。
