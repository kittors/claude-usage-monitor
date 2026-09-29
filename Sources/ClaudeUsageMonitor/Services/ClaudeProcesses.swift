import Darwin
import Foundation
import Observation

struct ClaudeTask: Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    /// 补充说明：Claude Code 显示它的工作目录，多个会话时容易分辨
    var detail: String?
    var bytes: Int64
}

/// 本机正在运行的 Claude 与 Claude Code 进程。不含这个菜单栏应用自己。
@MainActor
@Observable
final class ClaudeProcesses {
    static let shared = ClaudeProcesses()

    private(set) var tasks: [ClaudeTask] = []
    @ObservationIgnored private var scanning = false
    /// 父进程下面的全部后代，强制退出父进程时一起停掉。
    @ObservationIgnored private var descendants: [Int32: [Int32]] = [:]

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let selfPid = Int32(ProcessInfo.processInfo.processIdentifier)
        Task.detached {
            let found = Self.list(excluding: selfPid)
            await MainActor.run {
                ClaudeProcesses.shared.tasks = found.parents
                ClaudeProcesses.shared.descendants = found.descendants
                ClaudeProcesses.shared.scanning = false
            }
        }
    }

    func forceQuit(_ pid: Int32) {
        let selfPid = Int32(ProcessInfo.processInfo.processIdentifier)
        var victims = descendants[pid] ?? []
        victims.append(pid)
        for id in victims where id != selfPid {
            kill(id, SIGKILL)
        }
        scanning = false
        refresh()
    }

    nonisolated private static func list(excluding selfPid: Int32) -> (parents: [ClaudeTask], descendants: [Int32: [Int32]]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // 只用短名字。完整命令行里有大段启动参数，输出太大。
        process.arguments = ["-axo", "pid=,ppid=,rss=,ucomm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ([], [:]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return ([], [:]) }
        var raw: [RawTask] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let rss = Int64(parts[2]),
                  pid != selfPid else { continue }
            let ucomm = String(parts[3]).trimmingCharacters(in: .whitespaces)
            guard let kind = classify(pid: pid, ucomm: ucomm) else { continue }
            raw.append(RawTask(pid: pid, ppid: ppid, kind: kind, bytes: rss * 1024))
        }
        return group(raw)
    }

    private enum Kind: Equatable {
        /// Claude 桌面端及其 Helper（桌面端自带的 Claude Code 是它的子进程，算在桌面端里）
        case desktop(main: Bool)
        /// 在终端等地方运行的 Claude Code 命令行
        case code
    }

    private struct RawTask {
        var pid: Int32
        var ppid: Int32
        var kind: Kind
        var bytes: Int64
    }

    /// 每个会话一行，内存是它和全部子进程加在一起。
    /// 桌面端的崩溃上报等进程不在它的进程树下（父进程是 launchd），也并到桌面端这一行。
    nonisolated private static func group(_ items: [RawTask]) -> (parents: [ClaudeTask], descendants: [Int32: [Int32]]) {
        let ids = Set(items.map(\.pid))
        var children: [Int32: [RawTask]] = [:]
        var roots: [RawTask] = []
        for item in items {
            if item.ppid != item.pid, ids.contains(item.ppid) {
                children[item.ppid, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        func tree(_ item: RawTask) -> [RawTask] {
            [item] + (children[item.pid] ?? []).flatMap(tree)
        }

        var parents: [ClaudeTask] = []
        var descendants: [Int32: [Int32]] = [:]
        func add(_ head: RawTask, name: String, detail: String?, members: [RawTask]) {
            parents.append(ClaudeTask(pid: head.pid, name: name, detail: detail, bytes: members.reduce(0) { $0 + $1.bytes }))
            descendants[head.pid] = members.map(\.pid).filter { $0 != head.pid }
        }

        // 桌面端：主进程作为这一行，其余散落的根进程一并计入
        let desktop = roots.filter { if case .desktop = $0.kind { true } else { false } }
        if let head = desktop.first(where: { $0.kind == .desktop(main: true) }) ?? desktop.max(by: { tree($0).count < tree($1).count }) {
            add(head, name: "Claude", detail: nil, members: desktop.flatMap(tree))
        }
        // Claude Code：每个会话一行，按启动先后排列，刷新时顺序不变
        for root in roots.filter({ $0.kind == .code }).sorted(by: { $0.pid < $1.pid }) {
            add(root, name: "Claude Code", detail: workingDirectory(root.pid), members: tree(root))
        }
        return (parents, descendants)
    }

    /// 有没有 Claude Code 会话在运行：终端里的命令行（任何装法），或 Claude 桌面版里的 Claude Code。
    /// 直接枚举进程，不启动 ps。
    nonisolated static func isClaudeCodeRunning() -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return false }
        let selfPid = getpid()
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != selfPid {
            let length = proc_name(pid, &name, UInt32(name.count))
            if classify(pid: pid, ucomm: length > 0 ? String(cString: name) : "") == .code { return true }
        }
        return false
    }

    /// 认 Claude 桌面端与它的 Helper，以及各种方式安装的 Claude Code。这个用量应用自己除外。
    nonisolated private static func classify(pid: Int32, ucomm: String) -> Kind? {
        let lower = ucomm.lowercased()
        if lower.hasPrefix("claudeusage") { return nil }
        guard let path = executablePath(pid) else {
            if lower == "claude" { return .code }
            return lower.hasPrefix("claude helper") ? .desktop(main: false) : nil
        }
        let pathLower = path.lowercased()
        if pathLower.contains("claudeusagemonitor") || pathLower.contains("claude usage monitor") { return nil }
        let base = URL(fileURLWithPath: path).lastPathComponent
        // 官方安装脚本装在 ~/.local/share/claude/versions/<版本号>，进程名就是版本号；
        // 桌面端自带的、Homebrew 装的都放在 claude-code 目录里，或者可执行文件直接叫 claude
        if pathLower.contains("/claude/versions/") || pathLower.contains("/claude-code/") || base == "claude" {
            return .code
        }
        if pathLower.contains("/claude.app/") {
            return .desktop(main: pathLower.hasSuffix("/claude.app/contents/macos/claude"))
        }
        // npm 安装：由 node / bun 运行 @anthropic-ai/claude-code
        if ["node", "bun"].contains(base.lowercased()),
           arguments(pid).prefix(3).contains(where: { $0.contains("claude-code") || URL(fileURLWithPath: $0).lastPathComponent == "claude" }) {
            return .code
        }
        return nil
    }

    nonisolated private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 进程的工作目录，显示最后一级；在主目录时显示「~」
    nonisolated private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !path.isEmpty else { return nil }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// 进程的启动参数（`KERN_PROCARGS2`）：argc、可执行文件路径、填充，然后是各个参数
    nonisolated private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
