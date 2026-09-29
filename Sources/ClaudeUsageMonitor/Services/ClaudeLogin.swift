import AppKit

/// 在终端中运行 `claude auth login`：登录完全由 Claude Code 完成（在浏览器中授权），App 不接触账号与密码。
enum ClaudeLogin {
    /// Claude Code 的常见安装位置；都找不到时交给终端自己的 PATH
    private static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 生成一个 `.command` 脚本并交给终端打开（不需要「自动化」权限）
    @discardableResult
    static func openInTerminal() -> Bool {
        let claude = executable.map { "'\($0)'" } ?? "claude"
        let script = """
        #!/bin/zsh
        # 由 Claude Usage Monitor 生成：登录 Claude Code
        clear
        echo "\(L10n.tNow("登录 Claude Code：请在打开的浏览器页面中完成授权。", "Sign in to Claude Code in the browser window that opens."))"
        echo
        if \(claude) auth login; then
          echo
          echo "\(L10n.tNow("登录完成，可以关闭这个窗口。Claude Usage Monitor 会自动恢复官方用量。", "Signed in. You can close this window. Claude Usage Monitor will pick up official usage."))"
        fi
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-login.command")
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
