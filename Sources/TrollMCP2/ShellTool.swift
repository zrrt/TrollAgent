import Foundation
import UIKit
import Darwin
import CommonCrypto
import SQLite3

/// 终端会话管理 (单例，v3.0.93: 已废弃 - TrollRuntime 自己管理 cwd，这个类是死代码）
final class ShellSession {
    static let shared = ShellSession()
    private init() {}
}


/// v3.0.36：shell 诊断日志 (Documents/Workspace/shell-diag.log），追查超时/卡死真相
enum ShellDiag {
    private static let lock = NSLock()
    private static var path: String = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workspace/shell-diag.log").path
    }()
    static func log(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 内置终端工具：执行 shell 命令（TrollRuntime 统一环境）
final class ShellExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.exec",
        summary: "Run shell command (terminal/CLI) in unified Alpine environment (TrollRuntime). Params: command(required), timeout(default 20s/max 120), background, limit, full, offset. Use for: file ops, system info, network, text processing. Unified env details & iOS path binding: see the shell.exec section in the system prompt.",
        parameters: [
            "command": "Shell command to execute (required)",
            "timeout": "Timeout seconds (default 20, max 120; commands past 20s are killed, exit 15/137). Download/installer commands (curl -o, wget, apk/pip/npm) cap 300s, other commands 120s. Jobs >60s prefer background=true.",
            "background": "Optional Bool: true=launch command in background, returns immediately with background_pid (no 20s kill). You must redirect the job's output yourself: `cmd > /ios_workspace/job.log 2>&1`. Then poll progress via short shell.exec (e.g. `tail -5 /ios_workspace/job.log`) and stop it with shell.stop pid=<pid> when you judge it stalled. Use for: installs/downloads/builds (>20s). Avoid reading big iOS files inside background commands (bridge stdin not usable).",
            "reset_cwd": "Optional Bool: reset working dir to default (default false)",
            "limit": "Optional Int: result string truncation cap (default 16000 chars, covers most analysis output; if not enough use full=true). If diagnostics output is trimmed and the body is invisible, pass limit=20000 or higher; full=true returns the complete untruncated result",
            "full": "Optional Bool: true=return the complete untruncated result (use with care — large output fills the context)",
            "offset": "Optional Int: skip first N chars of output before showing (default 0), combine with limit to read a middle slice",
        ],
        verified: true
    )
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String, !command.isEmpty else {
            throw MCPError.invalidParams("command required")
        }
        
        // 危险命令检测
        let dangerousPatterns = [
            "^rm\\s+-rf\\s+/$",
            "^rm\\s+-rf\\s+~",
            "^dd\\s+if=",
            "mkfs",
            "^chmod\\s+-R\\s+777\\s+/",
        ]
        for pattern in dangerousPatterns {
            if command.range(of: pattern, options: .regularExpression) != nil {
                return [
                    "error": "dangerous command blocked",
                    "command": command,
                    "hint": "this command could break the system and was blocked by the safety policy."
                ]
            }
        }

        // 重置工作目录
        if params["reset_cwd"] as? Bool == true {
            TrollRuntimeEngine.resetCwd()
        }
        
        // v4.3.13: 默认超时 30→20s（收紧）。解释器 CPU 开销高，长命令/死循环触发 watchdog 有风险；
        // v6.6.0: 统一环境 Asbestos（无 x86 模拟）。收紧默认超时 + kill 兜底。
        // v4.5.x: 下载命令（curl -o/-O/--output、wget 拉 URL）放宽到 300s——大文件下载超过 120s 会被 SIGKILL 掐断。
        // v7.1.79: timeout 解析容错——AI 可能传数字(120)或字符串("120")，统一解析；
        // 之前只认 Double，字符串会静默回落默认 20s（用户实测 timeout=60/120 无效的根因）。
        // 结果回显 timeout_used，让 AI/用户直接看到真实生效值，消除"以为传了其实没有"的黑盒。
        let rawCmd = (params["command"] as? String) ?? ""
        let isDownloadCmd = Self.isDownloadCommand(rawCmd)
        var timeoutVal = 20.0
        if let d = params["timeout"] as? Double {
            timeoutVal = d
        } else if let s = params["timeout"] as? String, let d = Double(s) {
            timeoutVal = d
        }
        let timeout = min(max(timeoutVal, 1), isDownloadCmd ? 300 : 120)
        
        // v6.6.0: 统一环境——移除 runtime 参数（auto/ios/alpine 路由废除）。
        // 全部命令默认走 Alpine Linux 完整工具链（Asbestos）；iOS 特有命令自动原生兜底（内部）。
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // v3.3.4: Native Offload —— `ta <tool> <key:value...>` 统一路由到全部原生 MCP 工具。
        // AI 只需学一个入口 (ta list / ta help <tool>)，无需记忆 40+ 工具的参数 schema。
        if trimmed == "ta" || trimmed.hasPrefix("ta ") {
            let result = OffloadRouter.run(trimmed)
            AuditLog.shared.log("shell.exec (ta offload)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.1.33: env 探针命令——一键返回当前执行环境 (后端/cwd/路径可见性），
        // 任何"时灵时不灵"异常第一步用它定位 (AI 诊断 P4）
        if trimmed == "env" || trimmed == "env " || trimmed.hasPrefix("env ") && trimmed.count <= 5 {
            let home = NSHomeDirectory()
            let docs = home + "/Documents"
            var iosContainers = false
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: "/var/containers", isDirectory: &isDir), isDir.boolValue {
                iosContainers = true
            }
            return [
                "command": command,
                "exit_code": 0,
                "stdout": [
                    "Execution env: unified env (TrollRuntime)",
                    "HOME: \(home)",
                    "Documents: \(docs)",
                    "cwd: \(TrollRuntimeEngine.cwd)",
                    "iOS system paths visible (/var/containers): \(iosContainers)",
                    "Default: full Alpine Linux aarch64 toolchain (native ARM64 — apk/pipes/dynamic ELF fully supported)",
                    "iOS paths auto-bind to /ios_* for direct read/write (only Workspace/Containers/System; no iOS-native fallback)",
                    "Note: no env selection needed — unified. Compound commands (| ; && >) compose normally; missing tools need explicit apk add"
                ].joined(separator: "\n"),
                "hint": "env probe: diagnose execution environment issues"
            ]
        }
        
        // v3.3.4: limit/full/offset —— 输出截断可动态控制 (AI 实测：limit/full 参数不生效）
        //  limit  = 截断上限字符数 (默认 16000；0 = 不截断——截断会附 spill 完整文件路径，先读完整再下结论）
        //  full   = true 时返回全量 (等效 limit:0），不 spill 不截断
        //  offset = 跳过前 N 字符再展示 (配合 limit 取中间段，等价 sed 取中段）
        let limitParam = (params["limit"] as? Int) ?? 0
        let fullOutput = params["full"] as? Bool == true
        let offsetParam = max(0, (params["offset"] as? Int) ?? 0)
        let outLimit = fullOutput ? 0 : (limitParam > 0 ? limitParam : 16000)
        
        // v6.1.5-14bp2：工具探测拦截——在任何路由之前先识别"版本/存在性检查类"命令
        // （git/vim/curl/wget --version、command -v git、which git 等）→ 原生文件系统探测，
        // 不触发 iSH。根因：git 等未装 → 自动 apk add → iSH x86 模拟高 CPU → iOS watchdog 杀 App=闪退。
        // python3 有原生执行器走原生；其余探测不执行任何 Alpine 二进制。
        if let probe = ShellExecTool.nativeToolProbe(trimmed) {
            AuditLog.shared.log("shell.exec (native tool probe)", detail: String(trimmed.prefix(100)))
            return probe
        }

        // v7.1.45: df 磁盘查询原生执行——Asbestos 解释器里 busybox df 读 /proc/mounts 不稳，
        // 触发解释器段错误（guest 崩 = App 进程被杀，用户实测 `df -h / | tail -1; ... apk search` 直接闪退）。
        // 纯 df → 原生 statfs；复合命令含 df → 拦截提示拆分（df 单独跑，其余命令分开跑）。
        if trimmed.hasPrefix("df") || trimmed.contains(" df ") || trimmed.hasSuffix(" df") {
            if trimmed.contains(";") || trimmed.contains("&&") || trimmed.contains("|") {
                return ["command": command, "exit_code": 1,
                        "stdout": "df now runs natively (container df crashes the app — Asbestos /proc unstable). Run it alone: `df -h /` for disk space. Then run the other part separately.",
                        "hint": "split compound commands containing df — disk queries via native df, everything else stays in the unified env"]
            }
            AuditLog.shared.log("shell.exec (native df)", detail: String(trimmed.prefix(100)))
            return ShellExecTool.nativeDf(command)
        }

        // v6.6.0: 统一环境——移除 runtime/auto 路由。默认全部命令走 TrollRuntime
        // （Alpine Linux 完整工具链——Asbestos 解释器）；iOS 特有命令（plutil 等 Alpine 无）
        // 内部自动原生兜底（不暴露参数，AI 无感）。
        let needsAlpine = !ShellExecTool.iosOnlyCommand(trimmed)
        if needsAlpine {
            // v3.3.4: ta (Native Offload）是宿主能力，与 Alpine 沙盒无关——
            // 即使判定 Alpine，ta 也走宿主路由，杜绝"环境漂移"。
            if trimmed == "ta" || trimmed.hasPrefix("ta ") {
                return OffloadRouter.run(trimmed)
            }
            // v6.6.0-fix15: py3-native 原生入口——App bin/python3（Python.xcframework + PythonCLI），iPhone 芯片直跑
            // numpy/pandas 深度运算。构建未集成时 runNativePython 内部报"未内置"并提示降级 python3。
            if trimmed == "py3-native" || trimmed.hasPrefix("py3-native ") {
                return ShellExecTool.runNativePython(String(trimmed.dropFirst("py3-native".count)).trimmingCharacters(in: .whitespaces))
            }
            // v6.6.0-fix15: node-native 原生入口——App bin/node（nodejs-mobile），V8 芯片直跑重负载。
            // 构建未集成时 runNativeNode 内部报"未内置"并提示降级 node。
            if trimmed == "node-native" || trimmed.hasPrefix("node-native ") {
                return ShellExecTool.runNativeNode(String(trimmed.dropFirst("node-native".count)).trimmingCharacters(in: .whitespaces))
            }
            // v3.7.7: 自动 bind——Alpine 命令引用 iOS 路径时自动挂载顶层 + 改写路径，
            // 让 Alpine 直接读写 iOS 文件（消灭环境漂移，替代单向字节桥接）。
            // bind 后 iOS 路径不可见的旧约束不再成立。
            let boundCmd = TrollRuntimeEngine.autoBind(trimmed)
            // v3.6.19l: Alpine 执行前保护护栏——凡命令要进 Alpine 却引用了"桥接不了"的 iOS 文件
            // (>2MB 超限 / 不存在)，Alpine 必然读不到 → 执行前直接拦截并给出明确下一步，
            // 而不是放进去跑出空结果让 AI 反复瞎试（根治 jinx 会话 40 次工具调用绕圈的根因）。
            if let guardMsg = ShellExecTool.alpineIOSPathGuard(boundCmd) {
                return ["command": trimmed, "exit_code": 1,
                        "stdout": guardMsg,
                        "hint": "This command runs in the unified env (TrollRuntime) but the iOS path isn't readable (only Workspace/Containers/System three dirs are bound, files have no 2MB limit). Fix: ① copy to Workspace first: `cp <file> /var/mobile/Documents/Workspace/`, then read it via Alpine /ios_workspace; ② for app data containers use bind_app bundle_id:<id> (read-only) → /ios_data_<app>; ③ for binaries use file analyze / binary.symbols."]
            }
            // v7.1.80: background 模式——命令后台启动立即返回 pid，绕开默认 20s 上限。
            // AI 轮询日志文件判断进度，卡死时 shell.stop pid=<pid> 主动中断。
            let background = (params["background"] as? Bool) ?? false
            let execCmd = background ? "( \(boundCmd) & echo __BG_PID=$! )" : boundCmd
            // 背景模式命令本身立即返回（sh 等 echo 就退），timeout 只影响 echo 输出，给足余量
            let execTimeout = background ? max(timeout, 30) : timeout
            let (output, exitCode, timedOut) = TrollRuntimeEngine.exec(execCmd, timeout: execTimeout)
            // v6.6.0: Alpine 工具裁剪（幂等）——统一后原生覆盖极少，不影响主环境工具链
            _ = ShellExecTool.shrinkAlpineRootfs()            // P3 按需补给：Alpine 输出显示缺工具(command not found)且命中白名单 → 自动 apk add 并重跑一次，
            // 免 agent 反复探测缺什么、也避免"先探测→再装→再跑"的多轮试探。
            let (finalOut, finalExit, finalTimed, provisionNote) = ShellExecTool.provisionAndRerun(boundCmd, output: output, exitCode: exitCode, timedOut: timedOut, timeout: timeout)
            var stdout = ShellExecTool.filterNoise(finalOut)
            if outLimit > 0 && stdout.count > outLimit {
                let spillPath = ToolRegistry.spillLarge("runtime", stdout)
                stdout = String(stdout.prefix(outLimit / 2)) + "\n…[output too long: \(stdout.count) chars, truncated; full output: \(spillPath)]…\n" + String(stdout.suffix(outLimit / 2))
            }
            var result: [String: Any] = [
                "command": trimmed,
                "exit_code": finalExit,
                "stdout": stdout,
                "cwd": TrollRuntimeEngine.cwd,
                "timeout_used": timeout,
                "hint": (provisionNote.isEmpty ? "" : provisionNote) + "Unified environment (Alpine Linux — TrollRuntime). Missing tools auto-install via apk add and retry once."
            ]
            if finalTimed { result["timed_out"] = true }
            // v7.1.80: background 模式回显 pid——AI 用 shell.stop pid=<pid> 主动中断
            if background {
                let nsStdout = stdout as NSString
                let r = nsStdout.range(of: "__BG_PID=(\\d+)", options: .regularExpression)
                if r.location != NSNotFound {
                    let pidStr = nsStdout.substring(with: r).replacingOccurrences(of: "__BG_PID=", with: "")
                    if let pid = Int(pidStr) {
                        result["background_pid"] = pid
                        result["hint"] = "Background job pid=\(pid) running (not subject to 20s cap). Poll progress via `tail /ios_workspace/job.log`; stop it via shell.stop pid=\(pid)."
                    }
                }
            }
            AuditLog.shared.log("shell.exec (alpine auto)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // v3.1.33: shell 语法识别——含管道/分号/重定向/逻辑符的命令不再裸前缀匹配 (iOS 原生朴素分词会把 | ; 当参数），
        // 统一走 iOS 原生管道执行器：首段 iOS 原生执行 + Swift 过滤器 + 顺序拼接。
        // 这修复了"同一命令有时跑 iOS 有时跑 Alpine、结果随机"的病根。
        // v3.1.71：先做变量展开 (P=/xxx 赋值 + $P 引用），否则 "$P" 被当字面路径报 No such file (AI 实测）
        let expanded = ShellExecTool.expandVars(trimmed)
        if ShellExecTool.containsShellSyntax(expanded) {
            let result = ShellExecTool.runIOSPipeline(ShellExecTool.alpineToIOSPath(expanded), limit: outLimit, offset: offsetParam, timeout: timeout)
            AuditLog.shared.log("shell.exec (ios pipeline)", detail: String(expanded.prefix(100)))
            return result
        }
        
        // v6.0.30: 兼容 cd 路径 && 命令 组合：自动提取cd的路径，后面的相对路径自动补全，不用切Alpine
        var workingDir = ""
        var finalCmd = trimmed
        let cdRegex = try? NSRegularExpression(pattern: #"^\s*cd\s+([^\s&]+)\s*&&\s*(.+)$"#, options: [])
        if let re = cdRegex {
            let nsStr = trimmed as NSString
            if let match = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsStr.length)) {
                let cdPath = nsStr.substring(with: match.range(at: 1))
                let restCmd = nsStr.substring(with: match.range(at: 2))
                workingDir = (cdPath as NSString).expandingTildeInPath
                finalCmd = restCmd
                // 简单处理：如果命令是echo，不做路径替换
                if !finalCmd.hasPrefix("echo ") && !finalCmd.hasPrefix("echo\t") {
                    // 把命令分割成token，逐个判断是不是相对路径，补全
                    let tokens = finalCmd.components(separatedBy: .whitespaces)
                    var newTokens: [String] = []
                    for t in tokens {
                        // 跳过选项、绝对路径、命令本身、空
                        if t.hasPrefix("-") || t.hasPrefix("/") || t == "python3" || t == "python" || t == "ls" || t == "cat" || t == "grep" || t == "rm" || t == "mv" || t == "cp" || t == "touch" || t == "find" || t == "echo" || t.isEmpty {
                            newTokens.append(t)
                            continue
                        }
                        // find . 替换成workingDir
                        if t == "." {
                            newTokens.append(workingDir)
                            continue
                        }
                        // python -m 后面的模块名不补全
                        if let prev = newTokens.last, prev == "-m" && t.contains(".") && !t.contains("/") {
                            newTokens.append(t)
                            continue
                        }
                        // 其他相对路径补全
                        newTokens.append("\(workingDir)/\(t)")
                    }
                    finalCmd = newTokens.joined(separator: " ")
                }
            }
        }
        // v4.3.9: 反向路径翻译——原生命令收到 Alpine 挂载路径(/ios_workspace 等)时翻译回 iOS 真实路径,
        // 消除 grep/cat/ls 收到 /ios_workspace 找不到文件的割裂(AI 不必手动换路径)。
        let iosCmd = ShellExecTool.alpineToIOSPath(finalCmd)
        
        // 21. plutil 命令——iOS 原生实现 (读 plist）
        if trimmed.hasPrefix("plutil ") {
            let result = ShellExecTool.runIOSPlutil(iosCmd)
            AuditLog.shared.log("shell.exec (ios plutil)", detail: String(trimmed.prefix(100)))
            return result
        }
        
        // 22. sqlite3 命令——iOS 原生实现 (查询 SQLite）
        if trimmed.hasPrefix("sqlite3 ") {
            let result = ShellExecTool.runIOSSqlite(iosCmd)
            AuditLog.shared.log("shell.exec (ios sqlite)", detail: String(trimmed.prefix(100)))
            return result
        }
        

        // fix3cl4: 通用单段原生路由——命令名在 App bin/ 存在即可执行即走原生（覆盖 jtool2 等 bin/ 内置；v6.6.0 起 llvm-* 已清）
        // readelf/size/strings 等全部内置工具）。之前只枚举 lua/node/r2/cstool，llvm 家族单段落 Alpine
        // not found。放 python3/470 分支之后，互不冲突；含 / 或 .. 的路径不匹配（防误判）。
        // fix3cl5: 排除"文件操作/签名/管理"类——这些 bin/ 原生版处理 iOS 路径，而 AI 惯用 Alpine
        // 路径（/root/... 等，经 iSH bind 映射）。误切原生会让 cp/mv/rm /root/x 回归失败。
        // 它们继续走原 Alpine/默认路由；通用路由只对分析/脚本类生效。
        // fix3cu: 判断改为基于命令名(firstWord)而非整个命令——原 !iosCmd.contains("/") 会误伤所有
        // 带路径参数的命令(如 kfd_helper /private/var/... 整条含 / → 跳过原生路由 → 落 Alpine
        // Permission denied, iSH 跑不了 arm64 iOS 二进制)。命令名本身不含 / 且 bin 存在 → 原生直跑。
        let genRouteExcludes: Set<String> = ["cp", "mv", "rm", "mkdir", "chown", "install_name_tool",
                                              "ldid", "optool", "insert_dylib", "jtool2"]
        let firstWord = iosCmd.split(separator: " ").first.map(String.init) ?? ""
        if !firstWord.isEmpty, !firstWord.contains("/"), !firstWord.contains(".."), !genRouteExcludes.contains(firstWord) {
            let bundledRoots = [Bundle.main.bundlePath + "/bin", Bundle.main.bundlePath + "/Resources/bin"]
            if bundledRoots.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + firstWord) }) {
                let result = ShellExecTool.runIOSNativeSegment(iosCmd, timeout: timeout)
                AuditLog.shared.log("shell.exec (ios bundled gen)", detail: String(trimmed.prefix(100)))
                return result
            }
        }
        
        // v3.0.41：iSH 为唯一引擎 (ios_system 已删除）。初始化failed直接报错，不再回退。
        let (output, exitCode, timedOut) = TrollRuntimeEngine.exec(command, timeout: timeout)

        // v4.3.76：单命令 Alpine 兜底同样享受"缺工具自动装"——objdump/jq/xxd/readelf/rabin2 等
        // v6.6.0: 统一环境——命令 not found 时白名单自动装并重跑一次（autoRoute 已删）。
        // 统一环境工具链：缺工具自动装——装了就能直接调。
        var provNote = ""
        var rOut = output, rExit = exitCode, rTimed = timedOut
        (rOut, rExit, rTimed, provNote) = ShellExecTool.provisionAndRerun(command, output: output, exitCode: exitCode, timedOut: timedOut, timeout: timeout)

        // 过滤杂散调试噪音
        var stdout = ShellExecTool.filterNoise(rOut)
        if outLimit > 0 && stdout.count > outLimit {
            let spillPath = ToolRegistry.spillLarge("shell", stdout)
            stdout = String(stdout.prefix(outLimit / 2)) + "\n…[output too long: \(stdout.count) chars, truncated; full output: \(spillPath)]…\n" + String(stdout.suffix(outLimit / 2))
        }

        // 会话目录：TrollRuntime 路径
        var newPwd = TrollRuntimeEngine.cwd

        AuditLog.shared.log("shell.exec", detail: String(command.prefix(100)))

        var result: [String: Any] = [
            "command": command,
            "exit_code": rExit,
            "stdout": stdout,
            "cwd": newPwd,
            "hint": provNote + "Alpine Linux environment: full command set (ls/cat/grep/find/tar/curl/python...), apk add to install packages. iOS paths auto-bind for direct reads. cd remembers the directory."
        ]
        if rTimed {
            result["timed_out"] = true
            result["hint"] = (provNote.isEmpty ? "" : provNote + " ") + "command did not finish within \(Int(timeout))s, process group SIGKILLed"
        }
        return result
    }
    
    // MARK: - v3.1.33 shell 语法识别 + iOS 原生管道执行器
    // 修复"同一命令路由随机 (iOS vs Alpine）"和"iOS 原生不支持 | ; && >"两个根因：
    // 含 shell 语法的命令统一在此处理：首段是 iOS 原生命令 → iOS 原生执行 + Swift 过滤器；
    // 首段非 iOS 命令 (python 等）→ 交给 Alpine 全功能 shell。路由从此确定。
    
    /// 检测命令是否含 shell 元字符 (管道/分号/逻辑符/重定向/命令替换），跳过引号内内容
    /// v4.3.76：统一"缺工具自动装包"逻辑（135 主 Alpine 路由 与 单命令 Alpine 兜底共用）。
    /// not found 且白名单命中 → 自动 apk add（进度条 + 结构化诊断）并重跑一次；
    /// 非白名单 → 跳过安装并返回明确提示（jtool2 这类非 Alpine 工具名）。
    static func provisionAndRerun(_ body: String, output: String, exitCode: Int32, timedOut: Bool, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool, note: String) {
        var note = ""
        let prov = TrollRuntimeEngine.autoProvision(output)
        guard let pkg = prov.pkg else { return (output, exitCode, timedOut, note) }
        if !prov.known {
            // v6.1.5-14bp：区分"白名单外"与"重包禁自动装"（git 等重包 apk add 高 CPU 触发 iOS watchdog 杀 App=闪退）
            let heavy: Set<String> = ["git", "wget", "make", "cmake", "build-base", "clang", "gcc", "openssl", "radare2"]
            if heavy.contains(pkg) {
                note = "Tool \(pkg) is a heavy package: auto-install could trigger high interpreter CPU and get killed by iOS (app crash). Skipped auto-install. Use tool.install to install manually (Alpine: apk add \(pkg)), then re-run the command."
            } else {
                note = "Tool \(pkg) isn't on the auto-install whitelist (may not be an Alpine package); skipped auto-install; confirm the tool name, or use tool.install with name/source."
            }
            return (output, exitCode, timedOut, note)
        }
        ShellDiag.log("provision auto: apk add \(pkg) (missing in Alpine)")
        let provisionTimeout = min(max(timeout, 60), 90)  // v6.1.5-14bs: 240→90s(用户实测"执行中…"挂起=装包慢无反馈, 收紧等待上限)
        let provisionStart = Date()
        InstallationRegistry.shared.start(key: pkg)
        let apkResult = TrollRuntimeEngine.apkAdd([pkg], timeout: provisionTimeout) { line in
            InstallationRegistry.shared.appendLine(line)
        }
        let elapsed = Int(Date().timeIntervalSince(provisionStart))
        if apkResult.exitCode == 0 {
            InstallationRegistry.shared.finish(ok: true, summary: "Installed \(pkg) (\(elapsed)s)")
            note = "Missing tool \(pkg) auto-installed on first run (\(elapsed)s)."
        } else {
            let diag = TrollRuntimeEngine.installDiagnose(apkResult.output, timedOut: apkResult.timedOut, exitCode: apkResult.exitCode)
            InstallationRegistry.shared.finish(ok: false, summary: diag)
            note = "Auto-install \(pkg) failed: \(diag)"
        }
        let (rout, rexit, rtimed) = TrollRuntimeEngine.exec(body, timeout: timeout)
        return (rout, rexit, rtimed, note)
    }

    /// v4.5.x：下载命令检测——curl 带 -o/-O/--output 输出到文件，或 wget 拉 URL。
    /// 命中则 shell.exec 超时上限放宽到 300s（大文件下载不被 120s SIGKILL 掐断）。
    /// v7.1.76：加安装/包管理类（pip/npm/apk/git clone/make）——这些命令天然 >20s（用户实测
    /// 默认 20s 掐死 npm install/venv/pip download），统一放宽到 300s，AI 不传 timeout 也不撞墙。
    static func isDownloadCommand(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let isCurlOut = c.contains("curl") && (c.contains(" -o ") || c.contains(" -O ") || c.contains(" --output ") || c.contains("--output="))
        let isWgetUrl = c.contains("wget") && (c.contains("http://") || c.contains("https://"))
        let isInstaller = c.contains("pip install") || c.contains("pip download") || c.contains("pip3 install")
            || c.contains("npm install") || c.contains("npm i ") || c.contains("npm ci")
            || c.contains("apk add") || c.contains("apk update") || c.contains("git clone")
            || c.contains(" make") || c.contains("make ") || c.contains("venv")
        return isCurlOut || isWgetUrl || isInstaller
    }

    static func containsShellSyntax(_ command: String) -> Bool {
        var inSingle = false
        var inDouble = false
        var chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if !inSingle && !inDouble {
                switch c {
                case "|", ";", "&", ">", "<", "`":
                    return true
                case "$":
                    // $() 命令替换或 ${} 参数展开也算 shell 语法
                    if i + 1 < chars.count, chars[i+1] == "(" || chars[i+1] == "{" { return true }
                default:
                    break
                }
            }
            i += 1
        }
        return false
    }

    /// 14c3 P1原生化: 原生已覆盖的"AI 用户命令"集合——Alpine 中同名工具将被裁剪删除。
    /// 【铁律】系统命令(rm/mv/cp/mkdir/chmod/chown/ln/sh/ash/busybox/install/sed/awk/grep/find/
    /// head/tail)【必须保留】——Alpine apk 装包脚本(post-install)依赖它们，删了装任何包都会挂。
    /// 这里只删"AI 高频用户命令 + 原生功能对等"的（AI 走原生即可，Alpine 同名属重复）。
    private static let nativeCoverage: Set<String> = [
        // v6.6.0 精简：仅真实原生覆盖（统一环境主执行——Alpine 工具不裁剪）。
        // iOS 特有/注入工具链（Alpine 无——shrink 对它们无影响；其余命令统一走 Alpine 完整工具链）
        "plutil", "sqlite3",
        "ldid", "optool", "insert_dylib", "install_name_tool", "cp-15", "mv-15", "ct_bypass", "opainject"
    ]

    /// v6.6.0: 统一环境后原生覆盖极少（plutil/sqlite3 + iOS 注入工具）——裁剪不再删主环境工具；
    /// 保留历史逻辑（幂等标记；只删 symlink/普通文件；busybox 本体保留）。
    static func shrinkAlpineRootfs() -> String {
        let fm = FileManager.default
        let rootfs = NSHomeDirectory() + "/Documents/alpine-rootfs"
        let mark = rootfs + "/.native-shrunk-14c3"
        guard fm.fileExists(atPath: rootfs + "/bin/busybox") else { return "" }
        if fm.fileExists(atPath: mark) { return "" }
        let dirs = ["usr/bin", "bin", "usr/sbin", "sbin", "usr/local/bin"]
        var removed = 0
        var kept = 0
        for d in dirs {
            let dirPath = rootfs + "/" + d
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for e in entries where nativeCoverage.contains(e) {
                if e == "busybox" { kept += 1; continue }
                let p = dirPath + "/" + e
                var isSymlink = false
                if let dest = try? fm.destinationOfSymbolicLink(atPath: p) { _ = dest; isSymlink = true }
                var isReg = false
                var st = stat()
                if stat(p, &st) == 0 { isReg = (st.st_mode & S_IFMT) == S_IFREG }
                if isSymlink || isReg {
                    if (try? fm.removeItem(atPath: p)) != nil { removed += 1 }
                }
            }
        }
        try? fm.createDirectory(atPath: rootfs, withIntermediateDirectories: true)
        fm.createFile(atPath: mark, contents: nil)
        return removed > 0 ? "Alpine pruned \(removed) duplicate native tools (system commands/busybox kept)" : ""
    }

    /// v6.6.0 统一环境辅助：判定命令是否需要 TrollRuntime 工具链（Alpine 完整版）。
    /// 供 provisionAndRerun 白名单装包用——命令
    /// (装包/解包 deb/完整 shell 脚本/需要 python 等) 自动进 Alpine；
    /// 其余(文件操作/系统信息/网络/分析)默认走 iOS 原生。
    /// v6.6.0: iOS 特有命令检测——Alpine/TrollRuntime 无此命令，内部自动原生兜底
    /// （不暴露参数、AI 无感）。命中则跳过 TrollRuntime，走 iOS 原生分支执行。
    static func iosOnlyCommand(_ command: String) -> Bool {
        let first = command.split(separator: " ").first.map(String.init) ?? ""
        let iosOnly: Set<String> = ["plutil", "notifyutil", "sbreload", "uicache", "idevice_id", "swift"]
        return iosOnly.contains(first)
    }

    /// v3.6.19l: Alpine 执行前保护护栏。
    /// v3.7.7: 命令会先经 autoBind（自动 bind 主流 iOS 目录并改写为 /ios_*）——改写后 iOS 路径消失，
    /// guard 扫描不到即放行；仅当 autoBind 未覆盖的 iOS 路径（非 /var/mobile、/var/containers、/System 顶层）
    /// 或 bind 失败时，guard 才检查其能否被 autoBridge 桥接(>2MB/不存在)并拦截。
    /// v6.0.28: 修复假零结果——增加 autoBind 范围检查：路径在 iOS 存在但不在 autoBind 范围内，
    /// 直接拦截报错（原来放行导致 Alpine 读不到文件返回空，AI 误判为 0 字节）。
    /// 复用与 autoBridge 同一套 iOS 路径识别正则，保证护栏与桥接兜底判定一致。
    static func alpineIOSPathGuard(_ command: String) -> String? {
        let fm = FileManager.default
        let prefixes = ["/var/mobile/", "/private/var/mobile/", "/System/", "/var/containers/"]
        let alt = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(^|[\\s\"'=>(])((?:" + alt + ")[^\\s\"'<>\\);|&,=:\\[\\]{}`]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        let maxBytes = 2 * 1024 * 1024
        // v6.0.28: autoBind 实际绑定的范围（与 TrollRuntimeEngine.autoBind 保持一致）
        let bindableRoots = [
            "/var/mobile/Documents/Workspace",
            "/var/containers",
            "/System"
        ]
        var seen = Set<String>()
        var blocked: [String] = []
        for m in re.matches(in: command, options: [], range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let raw = ns.substring(with: m.range(at: 2))
            if seen.contains(raw) { continue }
            seen.insert(raw)
            let norm = ShellExecTool.normalizePath(raw)
            if norm.contains("/alpine-rootfs/") { continue }
            // 已桥接成功的路径(出现在 /tmp/_bridge_ 下)不受此护栏约束
            if norm.hasPrefix("/tmp/_bridge_") { continue }
            // v6.0.28: 先检查路径在 iOS 里存不存在
            guard fm.fileExists(atPath: norm) else {
                blocked.append("\(norm) doesn't exist"); continue
            }
            // v6.0.28: 关键检查——这个路径是不是在 autoBind 范围内？
            var isBindable = false
            for root in bindableRoots {
                if norm.hasPrefix(root) {
                    isBindable = true
                    break
                }
            }
            if !isBindable {
                blocked.append("\(norm) not in Alpine's auto-bind scope (Alpine can't read it, returns empty/false zero)")
                continue
            }
            guard (try? fm.attributesOfItem(atPath: norm)[.type]) as? FileAttributeType == .typeRegular else {
                blocked.append("\(norm) not a regular file"); continue
            }
            let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int ?? 0
            if size <= 0 || size > maxBytes {
                blocked.append("\(norm) \(size)B (over the 2MB bridge cap)")
            }
        }
        guard !blocked.isEmpty else { return nil }
        return "This command runs in Alpine but references iOS files Alpine can't read (check added to prevent false-zero results):\n" + blocked.joined(separator: "\n") +
               "\nFix: ① confirm the path is within auto-bind scope (/var/mobile/Documents/Workspace, /var/containers, /System); ② app data container paths (/var/mobile/Containers/...) — don't use Alpine, use native iOS commands directly (ls/cat/du/df); ③ for other paths cp to Workspace first, then analyze in Alpine." +
               // v7.2.1：媒体库/相册目录（PhotoData 等）任何桥接都读不到——直接告知用户走系统相册/PhotoKit，
               // 避免 AI 反复拿 Alpine/exec_root 试路径死循环
               "\nNote: /var/mobile/Media (photo library / PhotoData thumbnails) is NEVER bridgeable — not via Alpine, not via cp. Use PhotoKit/PhotosPicker in the app, or tell the user this path is protected and cannot be read from the sandbox."
    }
    
    /// 按管道/分号/逻辑符拆分命令 (尊重引号），返回 [(命令段, 连接符)]，连接符: | ; && ||
    private static func splitShellSegments(_ command: String) -> [(cmd: String, sep: String)] {
        var segments: [(String, String)] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); current.append(c); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); current.append(c); i += 1; continue }
            if !inSingle && !inDouble {
                if c == "|" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "|"))
                    current = ""
                    i += 1
                    continue
                }
                if c == ";" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), ";"))
                    current = ""
                    i += 1
                    continue
                }
                if c == "&" && i + 1 < chars.count && chars[i+1] == "&" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "&&"))
                    current = ""
                    i += 2
                    continue
                }
                if c == "|" && i + 1 < chars.count && chars[i+1] == "|" {
                    segments.append((current.trimmingCharacters(in: .whitespaces), "||"))
                    current = ""
                    i += 2
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || segments.isEmpty {
            segments.append((last, ""))
        }
        return segments
    }
    
    /// v3.1.71：iOS 原生模式的变量展开预处理。
    /// 收集段首 VAR=value 赋值 (去引号），把后续命令中的 $VAR / ${VAR} 替换为实际值。
    /// 赋值段转成 echo (无输出、exit 0），保持链式语义。解决"$P 变量拼路径报 No such file" (AI 实测）。
    static func expandVars(_ command: String) -> String {
        let segments = splitShellSegments(command)
        guard segments.count > 1 || command.contains("=") else { return command }
        var vars: [String: String] = [:]
        var out: [String] = []
        for (cmd, sep) in segments {
            let t = cmd.trimmingCharacters(in: .whitespaces)
            if t.contains("=") {
                let eqIndex = t.firstIndex(of: "=")!
                let name = String(t[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                // 只认纯标识符的赋值 (A-Za-z0-9_），避免把命令参数里的 = 误判
                if !name.isEmpty && name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    var value = String(t[t.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                    // 去引号 ("..." / '...'）
                    if value.count >= 2,
                       (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                       (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    vars[name] = value
                    out.append("echo")
                    out.append(sep)
                    continue
                }
            }
            var replaced = t
            for (name, value) in vars {
                replaced = replaced.replacingOccurrences(of: "${\(name)}", with: value)
                replaced = replaced.replacingOccurrences(of: "$\(name)", with: value)
            }
            out.append(replaced)
            out.append(sep)
        }
        var joined = ""
        for i in stride(from: 0, to: out.count, by: 2) {
            joined += out[i]
            if i + 1 < out.count, !out[i + 1].isEmpty {
                joined += " \(out[i + 1]) "
            } else if i + 2 < out.count {
                joined += " "
            }
        }
        return joined
    }

    /// 提取命令首词 (跳过引号），用于判断是否 iOS 原生命令
    private static func firstWord(_ segment: String) -> String {        let t = segment.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        var word = ""
        for c in t {
            if c == " " || c == "\t" { break }
            if c == "'" || c == "\"" { continue }
            word.append(c)
        }
        return word
    }
    
    /// iOS 原生命令集合（v6.6.0 精简：5 个——plutil/sqlite3/ta/python3 + bin/ jtool2）
    private static let iosNativeCommands: Set<String> = [
        // v6.6.0: 精简——仅真实原生实现（plutil/sqlite3/ta）+ bin/ 内置二进制。
        // 其余命令统一环境（Alpine）执行——python3 统一走 Alpine（完整 CPython+pip）。
        "plutil", "sqlite3", "ta",
        // bin/ 内置：jtool2（Mach-O 解析专长）+ py3-native（原生 Python）+ node-native（原生 node——重负载场景）
        "jtool2", "py3-native", "node-native"
    ]
    
    /// v4.3.9: 反向路径翻译——iOS 原生命令收到 Alpine 挂载路径时翻译回 iOS 真实路径。
    /// 正向(iOS→Alpine)已由 TrollRuntimeEngine.autoBind 完成; 原生侧缺反向, 导致 grep/cat/ls
    /// 收到 /ios_workspace 等挂载路径时找不到文件(AI 被迫手动换"真实 iOS 路径")。
    /// 这里统一反向: /ios_workspace→/var/mobile/Documents/Workspace, /ios_containers→/var/containers,
    /// /ios_system→/System。原生命令处理前调用, 让 AI 任意写挂载路径都能被原生读到。
    static func alpineToIOSPath(_ command: String) -> String {
        var result = command
        let reverse: [(String, String)] = [
            ("/ios_workspace/", "/var/mobile/Documents/Workspace/"),
            ("/ios_workspace", "/var/mobile/Documents/Workspace"),
            ("/ios_containers/", "/var/containers/"),
            ("/ios_containers", "/var/containers"),
            ("/ios_system/", "/System/"),
            ("/ios_system", "/System"),
            ("/ios_appdata/", "/var/mobile/Containers/Data/Application/"),
            ("/ios_appdata", "/var/mobile/Containers/Data/Application"),
            ("/ios_appgroups/", "/var/mobile/Containers/Shared/AppGroup/"),
            ("/ios_appgroups", "/var/mobile/Containers/Shared/AppGroup"),
        ]
        for (alpine, ios) in reverse {
            result = result.replacingOccurrences(of: alpine, with: ios)
        }
        return result
    }
    
    /// 执行单段 iOS 原生命令 (首段），返回 [String: Any]
    private static func runIOSNativeSegment(_ segment: String, timeout: TimeInterval = 30) -> [String: Any] {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        // v4.3.9: 反向路径翻译——原生单段命令也统一应用(消除 /ios_workspace 等挂载路径找不到)
        let iosCmd = ShellExecTool.alpineToIOSPath(trimmed)
        let word = firstWord(trimmed)
        switch word {
        case "ta": return OffloadRouter.run(trimmed)
        default:
            // fix3s: 内置 bin 兜底——命令名在 App bin/ 或 Resources/bin/ 存在可执行 → 原生直跑。
            // 覆盖：AI 下载放置的 arm64 iOS 工具、未列白名单的内置注入工具(ldid/optool/insert_dylib/
            // install_name_tool/chown/mkdir/mv/rm/cp 等)。Alpine(iSH x86) 跑不了 arm64 原生二进制，
            // 此兜底让"下载→ldid 签名→放置→调用"闭环。路径含 / 或 .. 的不匹配(防误判)。
            if !word.contains("/"), !word.contains("..") {
                // 14c8: TrollStore 覆盖/重装不替换 bin/（实证：新包 efaa847 装后 bin/elf-runner 仍旧 92611，
                // 行为=旧 bug：mmap 0x400000 失败后覆盖 g_load_vaddr→段拷贝 SIGSEGV，无 svc patched 日志）。
                // → 可写区优先：Documents/Workspace/linux/<word> 若存在(用户/App 放置的更新版)优先使用，
                //   绕开 TrollStore 不替换 bundle bin 的死结。工具更新直接放 Documents 即生效。
                let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
                              ?? (NSHomeDirectory() + "/Documents")
                let docsOverride = docsDir + "/Workspace/linux/" + word
                var resolved: String? = nil
                if FileManager.default.fileExists(atPath: docsOverride) {
                    resolved = docsOverride
                } else {
                    let bundledRoots = [Bundle.main.bundlePath + "/bin", Bundle.main.bundlePath + "/Resources/bin"]
                    for root in bundledRoots {
                        let p = root + "/" + word
                        if FileManager.default.fileExists(atPath: p) { resolved = p; break }
                    }
                }
                if let p = resolved {
                    let body = segment.dropFirst(word.count)
                    let args = shellSplitArgs(String(body))
                    var env = ["PYTHONIOENCODING": "utf-8"]
                    // 14c6: file 命令依赖 libmagic 数据文件（编死路径 /usr/share/misc 不可用）→ 注入 MAGIC
                    if word == "file" {
                        let magic = Bundle.main.bundlePath + "/bin/magic.mgc"
                        if FileManager.default.fileExists(atPath: magic) { env["MAGIC"] = magic }
                    }
                    // v6.6.0: elf-runner（CELF）退役——统一环境由 TrollRuntime（Asbestos）提供。
                    // 原解释器模式/dup 重定向逻辑已删除（git 历史保留）。
                    let res = BuildRunner.shared.run(executable: p, args: args,
                                                     env: env, timeout: timeout)
                    var out = res.stdout
                    if res.timedOut { out += "\n[execution timed out at \(Int(timeout))s, terminated]" }
                    return ["command": segment, "exit_code": res.exitCode, "stdout": out,
                            "stderr": res.stderr]
                }
            }
            return [
                "command": segment,
                "exit_code": 1,
                "stdout": "Command not supported in the unified env: \(word) (use an available command or tool.install to install)"
            ]
        }
    }
    
    /// 主执行器：处理整条含 shell 语法的命令
    /// 结构：先按非管道分隔符 (; && ||）切分成"链"，每条链内按 | 分生产段+过滤段；
    /// 逐链执行：生产段输出 → 过滤段逐个过滤 → 追加到 stdoutChunks；&& / || 按上链 exit 短路。
    static func runIOSPipeline(_ command: String, limit: Int = 16000, offset: Int = 0, timeout: TimeInterval = 30) -> [String: Any] {
        let segments = splitShellSegments(command)
        guard !segments.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "empty command"]
        }
        
        // 切链：[(链内段列表, 本链进入前的分隔符)]
        var chains: [(cmds: [String], enterSep: String)] = []
        var currentChain: [String] = []
        var currentEnterSep = ""
        var prevSep = ""
        for seg in segments {
            let cmd = seg.cmd.trimmingCharacters(in: .whitespaces)
            if cmd.isEmpty { continue }
            currentChain.append(cmd)
            currentEnterSep = prevSep
            prevSep = seg.sep
            if seg.sep != "|" {
                chains.append((currentChain, currentEnterSep))
                currentChain = []
            }
        }
        if !currentChain.isEmpty { chains.append((currentChain, currentEnterSep)) }
        
        var stdoutChunks: [String] = []
        var lastExit = 0
        
        for chain in chains {
            // && / || 短路：上一条链的 exit 决定本链是否执行
            if chain.enterSep == "&&" && lastExit != 0 { continue }
            if chain.enterSep == "||" && lastExit == 0 { continue }
            
            var text = ""
            var exit = 0
            for (cidx, c) in chain.cmds.enumerated() {
                var word = firstWord(c)
                var (body, redirect0, append, outFile) = extractRedirect(c)
                // v4.4.9-fix3ca: App bin 绝对路径自动纠正——AI 从 tool.install 拿 path 直接用会走 Alpine→
                // Permission denied(Alpine 跑不了 arm64 iOS 二进制)。识别 <bundle>/bin/<name> 重写为命令名，
                // 让原生路由/白名单/bin 兜底都认；bin 兜底工具(ldid/optool 等)同样原生直跑。
                let binPrefix = Bundle.main.bundlePath + "/bin/"
                if word.hasPrefix(binPrefix), word.count > binPrefix.count {
                    let n = String(word.dropFirst(binPrefix.count))
                    if !n.isEmpty, !n.contains("/") {
                        body = n + String(body.dropFirst(word.count))
                        word = n
                    }
                }
                let isIOSCmd = iosNativeCommands.contains(word) ||
                    (!word.contains("/") && !word.contains("..") &&
                     (FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/bin/" + word)))
                // v4.3.13: base64 -d 带重定向时改为 var，特判后置 false 跳过文本重定向
                var redirect = redirect0
                
                if cidx == 0 {
                    // 生产段：iOS 原生执行 或 Alpine
                    var result: [String: Any]
                    if isIOSCmd {
                        // v4.3.13: base64 -d <in> > outFile —— 解码写二进制目标文件。
                        // 旧实现把解码硬写 .decoded + pipeline 把提示文本重定向到 outFile，目标被写成提示串(损坏)。
                        if word == "base64", redirect, body.contains("-d"),
                           let msg = ShellExecTool.base64DecodeRedirect(body, outFile: outFile) {
                            result = ["command": body, "exit_code": 0, "stdout": msg]
                            redirect = false  // 已直接写二进制，跳过下方文本 writeRedirected
                        } else {
                            result = runIOSNativeSegment(body, timeout: timeout)
                        }
                    } else {
                        var (output, outputExit, timedOut) = TrollRuntimeEngine.exec(body, timeout: timeout)
                        // P3 按需补给（v4.3.76 统一走公共函数）：白名单已知包自动装+重跑，非白名单给明确提示
                        var provNote = ""
                        (output, outputExit, timedOut, provNote) = ShellExecTool.provisionAndRerun(body, output: output, exitCode: outputExit, timedOut: timedOut, timeout: timeout)
                        var out = ShellExecTool.filterNoise(output)
                        if limit > 0 && out.count > limit {
                            let spillPath = ToolRegistry.spillLarge("runtime", out)
                            out = String(out.prefix(limit / 2)) + "\n…[output too long: \(out.count) chars, truncated; full output: \(spillPath)]…\n" + String(out.suffix(limit / 2))
                        }
                        result = [
                            "command": body, "exit_code": Int(outputExit), "stdout": out,
                            "cwd": TrollRuntimeEngine.cwd,
                            "hint": provNote + "Alpine Linux environment (non-iOS segment of compound command): full command support; missing tools auto apk add"
                        ]
                        if timedOut { result["timed_out"] = true }
                    }
                    text = result["stdout"] as? String ?? ""
                    exit = result["exit_code"] as? Int ?? 0
                } else {
                    // 过滤段：Swift 过滤器作用于前段输出
                    text = applySwiftFilter(body, to: text)
                }
                
                // 重定向 (段内 > / >>）：写文件并把输出改为提示
                if redirect {
                    text = ShellExecTool.writeRedirected(text, append: append, outFile: outFile)
                }
            }
            
            stdoutChunks.append(text)
            lastExit = exit
        }
        
        let joined = stdoutChunks.joined(separator: "\n")
        // v3.3.4：管道最终输出统一截断 (head+tail+spill）——长管道输出不再占满上下文；
        // limit/offset 可动态控制：limit:0 或 full:true = 全量；offset 跳过前 N 字符取中段
        var finalOut = joined
        if offset > 0 {
            finalOut = String(finalOut.dropFirst(min(offset, finalOut.count)))
        }
        if limit > 0 && finalOut.count > limit {
            let spillPath = ToolRegistry.spillLarge("pipeline", joined)
            finalOut = String(finalOut.prefix(limit / 2)) + "\n…[output too long: total \(joined.count) chars, truncated; full output: \(spillPath)]…\n" + String(finalOut.suffix(limit / 2))
        }
        return [
            "command": command,
            "exit_code": lastExit,
            "stdout": finalOut,
            "hint": "Compound command (unified env): pipes/semicolons/redirection parsed correctly"
        ]
    }
    
    /// 重定向写文件辅助：把输出写入目标文件 (覆盖/追加），返回提示文本
    private static func writeRedirected(_ out: String, append: Bool, outFile: String) -> String {
        do {
            if append {
                if FileManager.default.fileExists(atPath: outFile) {
                    let existing = try String(contentsOfFile: outFile, encoding: .utf8)
                    try (existing + "\n" + out).write(toFile: outFile, atomically: true, encoding: .utf8)
                } else {
                    try out.write(toFile: outFile, atomically: true, encoding: .utf8)
                }
            } else {
                try out.write(toFile: outFile, atomically: true, encoding: .utf8)
            }
            return "Written to \(outFile)"
        } catch {
            return "Error writing \(outFile): \(error.localizedDescription)"
        }
    }
    
    
    /// 从段内提取重定向：cmd > file / cmd >> file (支持引号路径），返回 (主体, 是否重定向, 是否追加, 目标文件)
    private static func extractRedirect(_ segment: String) -> (body: String, redirect: Bool, append: Bool, outFile: String) {
        var inSingle = false
        var inDouble = false
        var chars = Array(segment)
        var i = 0
        var redirectIdx: Int? = nil
        var isAppend = false
        // v3.1.68: stderr 重定向 (2>&1 合并 / 2>/dev/null 丢弃）——从命令里剥掉，不写文件不报错。
        // iOS 原生执行时 stderr 已经混入 stdout 文本，所以 2>&1 等效于去掉；2>/dev/null 也剥掉
        //  (真实 stderr 捕获需更大改造，剥掉至少不再报 "Error writing &1"）
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); i += 1; continue }
            if !inSingle && !inDouble && c == ">" {
                if i + 1 < chars.count && chars[i+1] == ">" {
                    isAppend = true
                    redirectIdx = i
                    i += 2
                    continue
                }
                redirectIdx = i
                i += 1
                continue
            }
            i += 1
        }
        guard let idx = redirectIdx else {
            return (segment, false, false, "")
        }
        let body = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
        var filePart = String(chars[(idx + (isAppend ? 2 : 1))..<chars.count]).trimmingCharacters(in: .whitespaces)
        filePart = filePart.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        
        // v3.1.68: stderr 重定向识别——body 以 "2" 结尾 (如 "ls /x 2"）且目标是 &1 或 /dev/null
        let bodyHasStderrFd = body.hasSuffix("2")
        let isStderrToNull = bodyHasStderrFd && (filePart == "/dev/null")
        let isStderrToStdout = bodyHasStderrFd && (filePart == "&1" || filePart == "1")
        if isStderrToNull || isStderrToStdout {
            // 剥掉末尾的 "2"，把 stderr 重定向吞掉，命令主体继续执行
            let trimmedBody = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            return (trimmedBody, false, false, "")
        }
        
        filePart = ShellExecTool.normalizePath((filePart as NSString).expandingTildeInPath)
        return (body, true, isAppend, filePart)
    }
    
    /// v3.1.33：路径归一——/private/var → /var (iOS 软链，访问等价），
    /// 让同一目录无论用户/AI 写哪个前缀，输出都统一显示为 /var/...。
    /// 只做前缀归一，不解析软链 (保持速度与确定性）；相对路径原样返回。
    static func normalizePath(_ p: String) -> String {
        if p.hasPrefix("/private/var") {
            return "/var" + p.dropFirst("/private/var".count)
        }
        return p
    }
    
    /// v4.3.13: base64 -d <input> > outFile 辅助——解码后直接以二进制写入目标文件。
    /// 修复旧实现缺陷：runIOSBase64 decode 硬编码写 `.decoded` 文件并返回提示文本，
    /// 而 pipeline 又把提示文本当 stdout 重定向到 `> outFile`，导致目标被写成提示串而非解码数据。
    /// 此辅助解析 body 取输入文件，解码后二进制写入 outFile（走文本 writeRedirected 会损坏二进制）。
    /// 返回成功提示；输入缺失/无效返回 nil（交由正常路径报错）。
    static func base64DecodeRedirect(_ body: String, outFile: String) -> String? {
        var parts = body.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        // 剥掉命令名/选项/stdin 重定向符，只留输入文件路径
        parts = parts.filter { $0 != "base64" && $0 != "-d" && $0 != "<" && $0 != ">" && $0 != ">>" }
        guard let raw = parts.first(where: { !$0.hasPrefix("-") }), !raw.isEmpty else { return nil }
        let input = normalizePath((raw as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: input) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: input)),
              let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else { return nil }
        do {
            try decoded.write(to: URL(fileURLWithPath: outFile))
            return "Decoded \(data.count) b64 → \(outFile) (\(decoded.count) bytes)"
        } catch {
            return nil
        }
    }
    
    // MARK: - Swift 管道过滤器 (iOS 原生管道右侧）
    
    /// 对 stdout 应用过滤器命令 (head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/cat），返回过滤后文本
    private static func applySwiftFilter(_ filterCmd: String, to input: String) -> String {
        let parts = filterCmd.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let word = parts.first else { return input }
        var lines = input.components(separatedBy: .newlines)
        if lines.last == "" { lines.removeLast() }
        
        switch word {
        case "head":
            var n = 10
            if let idx = parts.firstIndex(of: "-n"), idx + 1 < parts.count, let v = Int(parts[idx+1]) { n = v }
            return lines.prefix(n).joined(separator: "\n")
        case "tail":
            var n = 10
            if let idx = parts.firstIndex(of: "-n"), idx + 1 < parts.count, let v = Int(parts[idx+1]) { n = v }
            return lines.suffix(n).joined(separator: "\n")
        case "grep":
            var invert = false
            var ignoreCase = false
            var pattern = ""
            for p in parts.dropFirst() {
                if p == "-v" { invert = true; continue }
                if p == "-i" { ignoreCase = true; continue }
                pattern = p.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                break
            }
            guard !pattern.isEmpty else { return input }
            // v3.6.19e: 管道 grep 与 runIOSGrep 一致——默认字面量匹配，-i 才忽略大小写。
            // 原来强制 .regularExpression + 强制 .caseInsensitive，搜 cdhash 等含.的字面量会被正则误伤、
            // 且不传 -i 也忽略大小写（误匹配）。
            let matched = lines.filter { line in
                let hit = ignoreCase ? line.range(of: pattern, options: .caseInsensitive) != nil
                                     : line.range(of: pattern) != nil
                return invert ? !hit : hit
            }
            return matched.joined(separator: "\n")
        case "echo":
            // v3.3.4：管道里 echo —— 输出替换为 echo 的文本 (支持 -n、剥引号）
            var t = filterCmd
            if t.hasPrefix("echo") { t = String(t.dropFirst("echo".count)) }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-n ") { t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if t.count >= 2,
               (t.first == "\"" && t.last == "\"") || (t.first == "'" && t.last == "'") {
                t = String(t.dropFirst().dropLast())
            }
            return t
        case "wc":
            let opts = Set(parts.dropFirst())
            var result: [String] = []
            if opts.contains("-l") || !opts.contains("-w") && !opts.contains("-c") {
                result.append(String(lines.count))
            }
            if opts.contains("-w") {
                let words = lines.reduce(0) { $0 + $1.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count }
                result.append(String(words))
            }
            if opts.contains("-c") {
                result.append(String(input.utf8.count))
            }
            return result.joined(separator: " ")
        case "sed":
            // 支持 sed 's/from/to/g' (简化）
            if parts.count >= 2 {
                let expr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if expr.hasPrefix("s") {
                    var e = expr
                    if e.hasPrefix("s") { e.removeFirst() }
                    // e 形如 /from/to/g 或 s/from/to/
                    if e.hasPrefix("/") { e.removeFirst() }
                    let comps = e.components(separatedBy: "/")
                    if comps.count >= 2 {
                        let from = comps[0]
                        let to = comps.count >= 2 ? comps[1] : ""
                        let global = comps.count > 2 && comps[2].contains("g")
                        let replaced = lines.map { line -> String in
                            if global {
                                return line.replacingOccurrences(of: from, with: to)
                            } else {
                                guard let r = line.range(of: from) else { return line }
                                return line.replacingCharacters(in: r, with: to)
                            }
                        }
                        return replaced.joined(separator: "\n")
                    }
                }
            }
            return input
        case "awk":
            // 支持 awk '{print $1}' / $NF / $0 (简化）
            if parts.count >= 2 {
                let prog = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if prog.contains("print") {
                    var field: Int? = nil
                    var isNF = false
                    // 提取 $数字 或 $NF
                    var scan = Array(prog)
                    var k = 0
                    while k < scan.count {
                        if scan[k] == "$", k + 1 < scan.count {
                            let next = scan[k+1]
                            if next.isNumber {
                                var num = ""
                                var j = k + 1
                                while j < scan.count, scan[j].isNumber { num.append(scan[j]); j += 1 }
                                field = Int(num)
                                k = j
                                continue
                            }
                            if next == "N" && k + 2 < scan.count && scan[k+2] == "F" {
                                isNF = true
                            }
                        }
                        k += 1
                    }
                    let out = lines.map { line -> String in
                        if isNF {
                            let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            return cols.last ?? ""
                        }
                        if let f = field {
                            let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                            return f <= cols.count ? cols[f-1] : ""
                        }
                        return line
                    }
                    return out.joined(separator: "\n")
                }
            }
            return input
        case "sort":
            return lines.sorted().joined(separator: "\n")
        case "uniq":
            var out: [String] = []
            var prev: String? = nil
            for line in lines {
                if line != prev { out.append(line) }
                prev = line
            }
            return out.joined(separator: "\n")
        case "cut":
            // cut -d' ' -f2 / cut -d: -f1 / cut -f1 / cut -c1-5 (支持紧凑写法 -d: -f2）
            var delim: Character = "\t"
            var field = 0
            var chars: (Int, Int)? = nil
            for p in parts.dropFirst() {
                if p.hasPrefix("-d") && p.count > 2 {
                    delim = p.dropFirst(2).first ?? "\t"
                } else if p.hasPrefix("-f") && p.count > 2, let v = Int(p.dropFirst(2)) {
                    field = v
                } else if p.hasPrefix("-c") && p.count > 2 {
                    let spec = String(p.dropFirst(2))
                    let cs = spec.components(separatedBy: "-")
                    if cs.count == 2, let a = Int(cs[0]), let b = Int(cs[1]) {
                        chars = (a, b)
                    }
                }
            }
            let out = lines.map { line -> String in
                if let (a, b) = chars {
                    let arr = Array(line)
                    guard a >= 1, a <= arr.count else { return "" }
                    let end = min(b, arr.count)
                    return String(arr[a-1..<end])
                }
                if field > 0 {
                    let cols = line.split(separator: delim, omittingEmptySubsequences: true)
                    return field <= cols.count ? String(cols[field-1]) : ""
                }
                return line
            }
            return out.joined(separator: "\n")
        case "tr":
            if parts.count >= 3 {
                let from = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let to = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                var mapping: [Character: Character] = [:]
                for (idx, c) in from.enumerated() {
                    if idx < to.count { mapping[c] = to[to.index(to.startIndex, offsetBy: idx)] }
                }
                let mapped = input.map { c -> Character in mapping[c] ?? c }
                return String(mapped)
            }
            return input
        case "rev":
            return lines.map { String($0.reversed()) }.joined(separator: "\n")
        case "cat":
            return input
        case "base64":
            // v3.6.10: cat x | base64 —— 编码输入为单行 base64；base64 -d —— 解码输入
            var opts = Set(parts.dropFirst())
            let joined = input.replacingOccurrences(of: "\n", with: "")
            if opts.contains("-d") {
                guard let decoded = Data(base64Encoded: joined, options: .ignoreUnknownCharacters) else {
                    return "base64: invalid input\nOriginal output:\n\(input)"
                }
                return String(decoding: decoded, as: UTF8.self)
            }
            return Data(input.utf8).base64EncodedString()
        default:
            return "Compound-command filter doesn't support \(word) (available: head/tail/grep/wc/sed/awk/sort/uniq/cut/tr/rev/echo/cat/base64)\nOriginal output:\n\(input)"
        }
    }
    
    
    



    /// 基础 ARM64 指令解码（常见指令；未识别输出 dc=unrecognized）
    private static func decodeA64(_ w: UInt32) -> String {
        // RET / BR / BLR
        if (w & 0xFFFFFC1F) == 0xD65F0000 { return "ret" }
        if (w & 0xFFFFFC1F) == 0xD61F0000 { return "br" }
        if (w & 0xFFFFFC1F) == 0xD63F0000 { return "blr" }
        if w == 0xD503201F { return "nop" }
        // B / BL (imm26)
        if (w & 0xFC000000) == 0x14000000 {
            let imm = Int32(bitPattern: (w & 0x03FFFFFF) << 6) >> 6
            return (w & 0x80000000) != 0 ? "bl 0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4 + 0))" : "b  0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4))"
        }
        // CBZ/CBNZ (imm19)
        if (w & 0x7E000000) == 0x34000000 || (w & 0x7E000000) == 0x35000000 {
            let imm = Int32(bitPattern: (w & 0x00FFFFE0) << 8) >> 11
            return ((w & 0x7E000000) == 0x34000000 ? "cbz" : "cbnz") + " w\( (w >> 5) & 0x1F), 0x\(String(format:"%llx", UInt64(bitPattern: Int64(imm))*4))"
        }
        // ADRP (immhi:immlo)
        if (w & 0x9F000000) == 0x90000000 {
            return "adrp x\((w >> 5) & 0x1F)"
        }
        // ADD/SUB immediate
        if (w & 0x9F000000) == 0x91000000 { return "add x\((w >> 5) & 0x1F), x\(w & 0x1F), #\((w >> 10) & 0xFFF)" }
        if (w & 0x9F000000) == 0xD1000000 { return "sub x\((w >> 5) & 0x1F), x\(w & 0x1F), #\((w >> 10) & 0xFFF)" }
        // LDR/STR unsigned imm
        if (w & 0xFFC00000) == 0xF9400000 { return "ldr x\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xF9000000 { return "str x\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xB9400000 { return "ldr w\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        if (w & 0xFFC00000) == 0xB9000000 { return "str w\((w >> 5) & 0x1F), [x\(w & 0x1F), #\((w >> 10) & 0xFFF)]" }
        // MOVZ/MOVK/MOVN
        if (w & 0xFF800000) == 0xD2800000 { return "movz x\((w >> 5) & 0x1F), #\((w >> 5) & 0xFFFF)" }
        if (w & 0xFF800000) == 0xF2800000 { return "movk x\((w >> 5) & 0x1F), #\((w >> 5) & 0xFFFF)" }
        // STP/LDP
        if (w & 0xFFC00000) == 0xA9000000 { return "stp x\((w >> 10) & 0x1F), x\((w >> 5) & 0x1F), [x\(w & 0x1F)]" }
        if (w & 0xFFC00000) == 0xA9400000 { return "ldp x\((w >> 10) & 0x1F), x\((w >> 5) & 0x1F), [x\(w & 0x1F)]" }
        // 未识别
        return "dc\t\(String(format:"0x%08x", w))"
    }


    /// v3.6.19b: iOS 原生 kfd_diag —— 只读解析 Mach-O 的代码签名结构（LC_CODE_SIGNATURE →
    /// superblob → CodeDirectory），输出每个字段。用于真机诊断 TrollStore 重签后
    /// VpnTunnel 为何无法提取 cdhash。**纯只读、不注入、不 spawn 任何 helper**（绝对安全，不会触发 kfd/panic）。
    /// 语法: kfd_diag <path>
    /// v4.4.4: 引号感知拆参（支持 -c "code with spaces" 等）
    private static func shellSplitArgs(_ s: String) -> [String] {
        var args: [String] = []
        var cur = ""
        var inS = false, inD = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "'" && !inD { inS.toggle(); i = s.index(after: i); continue }
            if c == "\"" && !inS { inD.toggle(); i = s.index(after: i); continue }
            if !inS && !inD && c == " " {
                if !cur.isEmpty { args.append(cur); cur = "" }
            } else { cur.append(c) }
            i = s.index(after: i)
        }
        if !cur.isEmpty { args.append(cur) }
        return args
    }

    /// v6.6.0-fix15: py3-native 执行器——原生 Python（App bin/python3，iPhone 芯片直跑深度运算）。
    /// 显式命令专用（AI 重计算场景选择）；日常 python3 走统一环境 Alpine。
    private static func runNativePython(_ args: String) -> [String: Any] {
        let pythonPath = Bundle.main.bundlePath + "/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return ["command": "py3-native " + args, "exit_code": 1,
                    "stdout": "py3-native: native Python not bundled (this build lacks Python.xcframework) — use python3 (unified env Alpine, apk install py3-numpy)"]
        }
        let split = shellSplitArgs(args)
        var env = ["PYTHONIOENCODING": "utf-8"]
        let wsBase = "/var/mobile/Documents/Workspace"
        try? FileManager.default.createDirectory(atPath: wsBase, withIntermediateDirectories: true)
        let pyOutPath = wsBase + "/troll_py_out.txt"
        try? FileManager.default.removeItem(atPath: pyOutPath)
        env["TROLL_PY_OUT"] = pyOutPath
        let res = BuildRunner.shared.run(executable: pythonPath, args: split, env: env, timeout: 120)
        var out = res.stdout
        if let d = try? String(contentsOfFile: pyOutPath, encoding: .utf8), !d.isEmpty { out += d }
        try? FileManager.default.removeItem(atPath: pyOutPath)
        if res.timedOut { out += "\n[py3-native execution timed out, terminated]" }
        return ["command": "py3-native " + args, "exit_code": res.exitCode, "stdout": out,
                "hint": "py3-native: native Python (runs numpy/pandas heavy compute directly on the iPhone chip). Daily use/packages/ecosystem: python3 (unified env Alpine)"]
    }

    /// v6.6.0-fix15: node-native 执行器——原生 node（App bin/node，V8 芯片直跑重负载）。
    /// 显式命令专用（AI 重 node 任务选择）；轻量 JS 用统一环境 Alpine nodejs。
    private static func runNativeNode(_ args: String) -> [String: Any] {
        let nodePath = Bundle.main.bundlePath + "/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            return ["command": "node-native " + args, "exit_code": 1,
                    "stdout": "node-native: native node not bundled (this build lacks nodejs-mobile) — use node (unified env Alpine nodejs)"]
        }
        let split = shellSplitArgs(args)
        let res = BuildRunner.shared.run(executable: nodePath, args: split, env: ["PATH": Bundle.main.bundlePath + "/bin"], timeout: 120)
        var out = res.stdout
        if !res.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + res.stderr }
        if res.timedOut { out += "\n[node-native execution timed out, terminated]" }
        return ["command": "node-native " + args, "exit_code": res.exitCode, "stdout": out,
                "hint": "node-native: native node (V8 runs directly on the chip — heavy node tasks/build tools). Light JS/daily use: node (unified env Alpine nodejs)"]
    }

    /// 工具探测集合（command -v/which/type 判定用）——统一环境（Alpine）已有工具。
    /// fix7 误删此定义导致编译错——probeTargetOfSegment 仍依赖它。
    private static let probeNames: Set<String> = ["git", "vim", "vi", "curl", "wget", "make", "cmake", "gcc", "clang", "tar", "unzip", "zip", "gdb", "jq", "r2", "radare2", "python3", "python", "cd"]

    private static func probeTargetOfSegment(_ seg: String) -> String? {
        let t = seg.trimmingCharacters(in: .whitespaces)
        let word = firstWord(t)
        guard !word.isEmpty else { return nil }
        let body = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        // v6.6.0：重包检测命令放行真实执行——git/vim/curl/wget/make/cmake/gcc/clang/openssl/r2/radare2
        // 已在 heavyPackages 禁自动装（走统一环境 Alpine 未装也只报错不装包）；git/curl/wget 已 rootfs 预装。
        // 版本/裸命令形态直接放行真实执行；只有 command -v/which/type 仍走探测。
        let passthrough: Set<String> = ["git", "vim", "vi", "curl", "wget", "make", "cmake", "gcc", "clang", "openssl", "r2", "radare2"]
        if probeNames.contains(word) {
            // 工具名 + 版本/无参数 = 探测；工具名 + 其他参数 = 真实执行（git status 等不得吞）
            if body.isEmpty || body == "--version" || body == "-v" || body == "-V" || body == "--help"
                || body.hasPrefix("--version ") || body.hasPrefix("-v ") || body.hasPrefix("-V ") || body.hasPrefix("--help ") {
                if passthrough.contains(word) { return nil }   // 放行：真实执行（rootfs 预装/原生可用，不闪退）
                return word
            }
            return nil
        }
        // command -v X / which X / type X
        let probeRegex = [
            #"^\s*command\s+-[vV]\s+([A-Za-z0-9_.-]+)"#,
            #"^\s*which\s+([A-Za-z0-9_.-]+)"#,
            #"^\s*type\s+([A-Za-z0-9_.-]+)"#,
        ]
        for rx in probeRegex {
            if let m = t.range(of: rx, options: .regularExpression) {
                let s = String(t[m])
                let words = s.split(separator: " ").map(String.init)
                if let last = words.last, probeNames.contains(last) { return last }
            }
        }
        return nil
    }

    /// 单工具探测：cd 回 cwd；原生命令表/App bin/统一环境 rootfs 直读；否则报未装+安装提示。
    /// 探测只查询不装包（避免探测触发安装副作用）。
    private static func probeSingleTool(_ target: String, command seg: String) -> [String: Any] {
        let t = seg.trimmingCharacters(in: .whitespaces)
        let word = firstWord(t)
        let body = t.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        // cd 纯状态查询 → 返回当前 cwd（原生，无副作用）
        if target == "cd" && body.isEmpty {
            return ["command": seg, "exit_code": 0, "stdout": "Current working directory: \(TrollRuntimeEngine.cwd)"]
        }
        // 原生命令表：plutil/sqlite3（iOS 特有）+ ta（宿主直调）+ bin/ jtool2（Mach-O 专长）
        if iosNativeCommands.contains(target) {
            var note = "Probe result from the native command table (\(target) iOS-specific/host-direct/app-bin builtin)"
            return ["command": seg, "exit_code": 0,
                    "stdout": "\(target): ✅ installed (\(target) ... directly runnable)", "note": note]
        }
        // v6.6.0：git 探测（command -v git / which git）——真实可用性：
        // ①统一环境 Alpine rootfs 预装 git（v6.5.2 起）②App 内置 bin/git.py(dulwich) 兜底。
        // git 命令本体统一走 Alpine（rootfs 预装）；git.py 仅作 rootfs 缺失时的备用路径。
        if target == "git" {
            // v6.6.0: 主路径 = 统一环境 Alpine rootfs 预装 git；bin/git.py(dulwich) 仅作 rootfs 缺失兜底
            let fm = FileManager.default
            let rootfs = NSHomeDirectory() + "/Documents/alpine-rootfs"
            for sub in ["/usr/bin/", "/bin/"] {
                let p = rootfs + sub + "git"
                if fm.isExecutableFile(atPath: p) {
                    return ["command": seg, "exit_code": 0,
                            "stdout": "git: ✅ installed (preinstalled in the unified env rootfs, run git ... directly)\nUsage: git clone/add/commit/push/log/status ... (in the unified env, bundled with rootfs, no apk needed)", "note": "Probe result from the unified env rootfs preinstalled git"]
                }
            }
            let gitPy = Bundle.main.bundlePath + "/bin/git.py"
            if fm.fileExists(atPath: gitPy) {
                return ["command": seg, "exit_code": 0,
                        "stdout": "git: ✅ installed (app-bundled pure-Python git fallback: git.py/dulwich)\nUsage: git clone/add/commit/push/log/status ... (fallback path; prefer unified-env rootfs git)", "note": "Probe result from bin/git.py (fallback when rootfs git is missing)"]
            }
            return ["command": seg, "exit_code": 1,
                    "stdout": "git: ❌ unavailable (no rootfs git, no bin/git.py)\nNote: the unified-env rootfs should ship git; git.py is the fallback — if both are missing, report a packaging issue", "note": "Probe result from the filesystem (command body not executed)"]
        }
        let fm = FileManager.default
        // 1) App 原生 bin
        let nativePath = Bundle.main.bundlePath + "/bin/" + target
        var foundAt: String? = nil
        if fm.isExecutableFile(atPath: nativePath) { foundAt = nativePath }
        // 2) Alpine rootfs
        if foundAt == nil {
            let rootfs = NSHomeDirectory() + "/Documents/alpine-rootfs"
            for sub in ["/usr/bin/", "/bin/", "/usr/local/bin/"] {
                let p = rootfs + sub + target
                if fm.isExecutableFile(atPath: p) { foundAt = p; break }
            }
        }
        let runHint = "Run in the unified env (TrollRuntime): sh -c \"\(target) ...\"; or if natively bundled, run \(target) ... directly"
        if let found = foundAt {
            var out = "\(target): ✅ installed (\(found.replacingOccurrences(of: NSHomeDirectory(), with: "~")))"
            if found.hasPrefix(Bundle.main.bundlePath) {
                out += "\nHow to run: directly \(target) ... (native ARM64, no Alpine needed)"
            } else {
                out += "\nHow to run: \(runHint)"
            }
            return ["command": seg, "exit_code": 0, "stdout": out, "note": "Probe result from the filesystem (command body not executed, avoiding interpreter high-CPU kills by the system）"]
        }
        var out = "\(target): ❌ not installed (no native \(target) on iOS)"
        if target == "git" || target == "vim" || target == "curl" || target == "wget" {
            out += "\nInstall hint: use tool.install to install manually (unified env apk add \(target) — v6.5.2 ships ca-certificates in rootfs/curl/git; if missing, apk add)."
        } else {
            out += "\nInstall hint: use tool.install, or apk add \(target) in the unified env."
        }
        return ["command": seg, "exit_code": 1, "stdout": out, "note": "Probe result from the filesystem (command body not executed, avoiding interpreter high-CPU kills by the system）"]
    }

    /// 工具探测——版本/存在性查询类命令（git/vim/curl/wget 等 --version/-v/-V/纯命令/
    /// command -v X / which X / type X）不触发解释器执行，改用 FileManager 直读探测：
    ///   ① App 内置原生 bin/（jtool2）  ② 统一环境 rootfs  ③ 原生命令表（plutil/sqlite3/ta）
    /// 支持批量：一条命令探测多个工具（command -v git; command -v curl; python3 --version）逐个合并返回。
    /// 任一段是真实执行（git status / curl 实际请求）→ 整条不拦截，走原路由。
    /// v7.1.45：原生 df——iOS 宿主 statfs 取磁盘空间，格式化 df -h 风格（替代容器内 df：Asbestos /proc 不稳会段错误崩 App）
    private static func nativeDf(_ command: String) -> [String: Any] {
        let path = "/"
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path)
        let total = (attrs?[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = max(total - free, 0)
        let pct = total > 0 ? Int((Double(used) / Double(total)) * 100) : 0
        func h(_ b: Int64) -> String {
            let gb = Double(b) / 1_073_741_824
            if gb >= 1 { return String(format: "%.1fG", gb) }
            return String(format: "%.0fM", Double(b) / 1_048_576)
        }
        let line = String(format: "Filesystem  Size  Used Avail Use%% Mounted on\n/  %@  %@  %@  %d%%  / (iOS host)", h(total), h(used), h(free), pct)
        return [
            "command": command,
            "exit_code": 0,
            "stdout": line,
            "hint": "Native df (iOS host filesystem). Container df skipped — Asbestos /proc is unstable and crashes the app."
        ]
    }

    private static func nativeToolProbe(_ command: String) -> [String: Any]? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 按 ; 与连续 &&/|| 分段（v6.1.5-14bw：修复 14br 引入的编译错——Character 不能 == "&&"；
        // 扫描实现：连续两个同符号才分段，单个 &/|（含管道）不拆分，保真原意"| 段不介入探测"）
        var segs: [String] = []
        var cur = ""
        for c in trimmed {
            if c == ";" {
                segs.append(cur); cur = ""; continue
            }
            if c == "&" || c == "|" {
                if let prev = cur.last, prev == c {
                    // 连续第二个 &&/||：第一个已在 cur 中，去掉它作为分段点
                    segs.append(String(cur.dropLast())); cur = ""; continue
                }
                cur.append(c); continue
            }
            cur.append(c)
        }
        segs.append(cur)
        segs = segs.map { $0.trimmingCharacters(in: .whitespaces) }
        if segs.count > 1 {
            // 批量链：全部非跳过段都必须是探测形态，否则整条不拦截（保留真实执行意图）
            var items: [(seg: String, target: String)] = []
            for seg in segs {
                if seg.isEmpty || seg.hasPrefix("echo") || seg.hasPrefix("#") { continue }
                guard let tg = probeTargetOfSegment(seg) else { return nil }
                items.append((seg, tg))
            }
            guard !items.isEmpty else { return nil }
            var stdout = ""
            var exitCode = 0
            for item in items {
                let r = probeSingleTool(item.target, command: item.seg)
                stdout += (r["stdout"] as? String ?? "") + "\n"
                if (r["exit_code"] as? Int ?? 0) != 0 { exitCode = 1 }
            }
            return ["command": trimmed, "exit_code": exitCode, "stdout": stdout,
                    "note": "Batch probe results from filesystem/native command table (command body not executed, avoiding interpreter high-CPU kills by the system)"]
        }
        guard let target = probeTargetOfSegment(trimmed) else { return nil }
        return probeSingleTool(target, command: trimmed)
    }




    
    /// v3.1.32: iOS 原生 grep 命令——搜文本
    /// v3.1.68: 支持 flags (-i 忽略大小写 / -r 递归 / -l 只列文件名 / -c 计数 / -n 带行号 / -v 反选），
    /// 修复"任何 flag 把模式当文件" (C3 根因，2026-09-23 实测确认）
    private static func runIOSGrep(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // 解析 flags 与位置参数
        var flags = Set<Character>()
        var positional: [String] = []
        for p in parts.dropFirst() {
            if p.hasPrefix("-") && p.count > 1 && !p.hasPrefix("-e") {
                for ch in p.dropFirst() { flags.insert(ch) }
            } else {
                positional.append(p)
            }
        }
        let ignoreCase = flags.contains("i")
        let recursive = flags.contains("r")
        let filesOnly = flags.contains("l")
        let countOnly = flags.contains("c")
        let lineNumbers = flags.contains("n")
        let invert = flags.contains("v")
        
        guard positional.count >= 2 else {
            return [
                "command": command,
                "exit_code": 1,
                "stdout": "Usage: grep [-i] [-r] [-l] [-c] [-n] [-v] '<pattern>' <file|dir>..."
            ]
        }
        
        let pattern = positional[0].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let targets = positional.dropFirst().map { ShellExecTool.normalizePath(($0 as NSString).expandingTildeInPath) }
        
        // 收集要搜索的文件 (支持 -r 递归目录）
        var files: [String] = []
        for t in targets {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: t, isDirectory: &isDir) {
                if isDir.boolValue {
                    if recursive {
                        if let enumerator = fm.enumerator(atPath: t) {
                            while let f = enumerator.nextObject() as? String {
                                let full = (t as NSString).appendingPathComponent(f)
                                var fIsDir: ObjCBool = false
                                if fm.fileExists(atPath: full, isDirectory: &fIsDir), !fIsDir.boolValue {
                                    files.append(full)
                                }
                            }
                        }
                    } else {
                        return [
                            "command": command,
                            "exit_code": 1,
                            "stdout": "grep: \(t): Is a directory (use -r to recurse)"
                        ]
                    }
                } else {
                    files.append(t)
                }
            } else {
                return [
                    "command": command,
                    "exit_code": 1,
                    "stdout": "grep: \(t): No such file or directory"
                ]
            }
        }
        
        guard !files.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "grep: no files matched"]
        }
        
        // v3.6.19d: 修复 grep 对二进制失效的根因——原来用 String(contentsOfFile:encoding:.utf8) 读文件，
        // 二进制 UTF-8 解码必 nil → 静默跳过 → 输出空。改为 Data 字节读取 + 按 0x0A 拆字节行；
        // 匹配默认按【字面字节序列】(pattern 转 UTF-8 Data)，不再强制正则(原 .regularExpression 会把
        // 用户想搜的 "cdhash"/"CodeDirectory" 里的 . 当通配符误伤)；-E 才启用正则(用可打印化文本)。
        let useRegex = flags.contains("E")
        func printableLine(_ line: Data) -> String {
            var s = ""
            for byte in line {
                if byte == 0x09 { s += "\t" }
                else if byte >= 0x20 && byte <= 0x7e { s += String(UnicodeScalar(byte)) }
                else { s += "." }
            }
            return s
        }
        let patternBytes = Data(pattern.utf8)
        let patternBytesLower = Data(pattern.lowercased().utf8)

        var matchedFiles: [String] = []
        var matchedLines: [String] = []
        var totalCount = 0
        for file in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { continue }
            // 按 0x0A 拆成字节行（二进制也按字节行处理）
            var byteLines: [Data] = []
            var lineStart = data.startIndex
            for i in data.indices where data[i] == 0x0A {
                byteLines.append(Data(data[lineStart..<i])); lineStart = data.index(after: i)
            }
            byteLines.append(Data(data[lineStart...]))
            var fileMatched = false
            var fileCount = 0
            for (idx, line) in byteLines.enumerated() {
                let found: Bool
                if useRegex {
                    let text = printableLine(line)
                    found = ignoreCase ? text.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil
                                       : text.range(of: pattern, options: .regularExpression) != nil
                } else if ignoreCase {
                    // 字节级忽略大小写：ASCII A-Z 转小写后匹配
                    let lowered = Data(line.map { ($0 >= 0x41 && $0 <= 0x5a) ? ($0 + 0x20) : $0 })
                    found = lowered.range(of: patternBytesLower) != nil
                } else {
                    found = line.range(of: patternBytes) != nil
                }
                let hit = invert ? !found : found
                if hit {
                    fileMatched = true
                    fileCount += 1
                    totalCount += 1
                    if !filesOnly && !countOnly {
                        let prefix = files.count > 1 ? "\(file):" : ""
                        let num = lineNumbers ? "\(idx + 1):" : ""
                        matchedLines.append("\(prefix)\(num)\(printableLine(line))")
                    }
                }
            }
            if fileMatched { matchedFiles.append(file) }
            if countOnly && fileMatched {
                let prefix = files.count > 1 || targets.count > 1 ? "\(file):" : ""
                matchedLines.append("\(prefix)\(fileCount)")
            }
        }
        
        var out: String
        if filesOnly {
            out = matchedFiles.joined(separator: "\n")
        } else if countOnly {
            out = matchedLines.joined(separator: "\n")
            if files.count == 1 && targets.count == 1 && matchedLines.isEmpty && totalCount == 0 {
                out = "0"
            }
        } else {
            let truncated = matchedLines.count > 200 ? Array(matchedLines.prefix(200)) + ["... (total \(totalCount) lines matched, truncated)"] : matchedLines
            out = truncated.joined(separator: "\n")
        }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": out,
            "hint": "iOS native grep: -i/-r/-l/-c/-n/-v as standard; default matches literal bytes (can search binaries like cdhash/CodeDirectory), -E enables regex; -a automatic (binary printable). No longer silently fails with empty output on binary UTF-8 decode."
        ]
    }
    
    
    

    
    
    /// v3.1.32: iOS 原生 cp 命令——复制
    private static func runIOCp(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        let options = parts.dropFirst().filter { $0.hasPrefix("-") }
        let force = options.contains("-f")
        _ = options.contains("-r")  // copyItem 天然递归目录，-r 仅语义兼容
        
        // v4.0.0: 支持选项(如 -r/-f)，跳过选项取源/目标路径
        let args = parts.dropFirst().filter { !$0.hasPrefix("-") }
        guard args.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: cp [-r] [-f] <source> <destination>"]
        }
        
        let src = ShellExecTool.normalizePath((args[0] as NSString).expandingTildeInPath)
        let dst = ShellExecTool.normalizePath((args[1] as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: src) else {
            return ["command": command, "exit_code": 1, "stdout": "cp: \(src): No such file or directory"]
        }
        
        // v4.3.13: 目标若是已存在目录 → 复制到 dst/(basename)。旧实现 dst=目录且含同名文件时报"同名项目"。
        var dstIsDir: ObjCBool = false
        fm.fileExists(atPath: dst, isDirectory: &dstIsDir)
        let target = dstIsDir.boolValue
            ? (dst as NSString).appendingPathComponent((src as NSString).lastPathComponent)
            : dst
        
        if fm.fileExists(atPath: target), !force {
            return ["command": command, "exit_code": 1, "stdout": "cp: \(target) already exists (use cp -f to overwrite)"]
        }
        if fm.fileExists(atPath: target) {
            // -f 覆盖：先删已存在目标再复制
            do { try fm.removeItem(atPath: target) }
            catch {
                return ["command": command, "exit_code": 1, "stdout": "cp: failed to remove \(target): \(error.localizedDescription)"]
            }
        }
        do {
            try fm.copyItem(atPath: src, toPath: target)
            return ["command": command, "exit_code": 0, "stdout": "Copied: \(src) -> \(target)"]
        } catch {
            return ["command": command, "exit_code": 1, "stdout": "cp failed: \(error.localizedDescription)"]
        }
    }
    
    
    
    
    
    
    
    

    
    
    
    /// v4.4.6: 下载进度委托——URLSessionDownloadDelegate 把字节进度映射到 InstallationRegistry。
    /// onProgress: 0..1；onComplete(location, error)；totalBytes 记录已下载字节数（完成摘要用）。
    final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Double) -> Void)?
        var onComplete: ((URL?, Error?) -> Void)?
        var totalBytes: Int64 = 0

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteTo location: URL, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            totalBytes = totalBytesWritten
            let f: Double
            if totalBytesExpectedToWrite > 0 {
                f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            } else {
                // 服务端未给 Content-Length：按 100MB 基准粗估（至少显示"进行中"）
                f = Double(totalBytesWritten) / 104_857_600
            }
            onProgress?(f)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            onComplete?(location, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let e = error { onComplete?(nil, e) }
        }
    }

    /// v3.1.32: iOS 原生 plutil 命令——读 plist 文件
    private static func runIOSPlutil(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        let parts = command.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: plutil -p <file.plist>  or  plutil -convert xml1 [-o out.xml] <file.plist>"]
        }
        
        // 解析参数：-convert xml1 / -o <out> / -p；文件路径=首个非 - 参数
        var convertXML = false
        var outPath: String? = nil
        var filePath = ""
        var i = 1
        while i < parts.count {
            let p = parts[i]
            if p == "-convert" || p == "-c" {
                convertXML = true
                if i + 1 < parts.count && (parts[i+1] == "xml1" || parts[i+1] == "xml") { i += 1 }
            } else if p == "-o", i + 1 < parts.count {
                outPath = parts[i+1]
                i += 1
            } else if !p.hasPrefix("-") && filePath.isEmpty {
                filePath = p
            }
            i += 1
        }
        
        guard !filePath.isEmpty else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: no file specified"]
        }
        
        let path = ShellExecTool.normalizePath((filePath as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: path) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: \(path): No such file or directory"]
        }
        
        // v4.3.13: 改用 PropertyListSerialization 全类型解析——支持二进制 plist、嵌套 Data/Date/数字/布尔。
        // 旧实现用 NSDictionary(contentsOfFile:)+JSONSerialization，遇 Data/Date 抛错、二进制 plist 读取失败 → 空输出。
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return ["command": command, "exit_code": 1, "stdout": "plutil: Failed to read plist (binary/xml parse)"]
        }
        
        if convertXML {
            guard let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return ["command": command, "exit_code": 1, "stdout": "plutil: Failed to convert to xml1"]
            }
            if let out = outPath {
                let dest = ShellExecTool.normalizePath((out as NSString).expandingTildeInPath)
                do {
                    try xml.write(to: URL(fileURLWithPath: dest))
                    return ["command": command, "exit_code": 0, "stdout": "Converted plist to XML: \(dest)"]
                } catch {
                    return ["command": command, "exit_code": 1, "stdout": "plutil: failed to write \(dest): \(error.localizedDescription)"]
                }
            }
            return ["command": command, "exit_code": 0, "stdout": String(data: xml, encoding: .utf8) ?? ""]
        }
        
        // -p 打印：递归序列化为可读文本（全类型）
        return ["command": command, "exit_code": 0, "stdout": plutilPrint(plist, indent: 0)]
    }
    
    /// v4.3.13: plutil -p 打印辅助——递归把 plist 全类型(字典/数组/Data/Date/数字/布尔/字符串)转为可读文本
    private static func plutilPrint(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let d as [String: Any]:
            if d.isEmpty { return pad + "{}" }
            var lines: [String] = []
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                let child = plutilPrint(v, indent: indent + 1)
                lines.append(pad + "\(k) => \(child.trimmingCharacters(in: .newlines))")
            }
            return lines.joined(separator: "\n")
        case let a as [Any]:
            if a.isEmpty { return pad + "()" }
            return a.map { plutilPrint($0, indent: indent).trimmingCharacters(in: .newlines) }.joined(separator: "\n")
        case let s as String:
            return "\"\(s)\""
        case let b as Bool:
            // v4.3.13: Bool 须在 NSNumber 之前匹配（__NSCFBoolean 是 NSNumber 子类，否则输出 0/1）
            return b ? "true" : "false"
        case let n as NSNumber:
            return "\(n)"
        case let data as Data:
            let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            let tail = data.count > 64 ? " ... (\(data.count) bytes)" : ""
            return "<data: \(hex)\(tail)>"
        case let date as Date:
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; f.locale = Locale(identifier: "en_US_POSIX")
            return "<date: \(f.string(from: date))>"
        case let b as Bool:
            return b ? "true" : "false"
        case is NSNull:
            return "<null>"
        default:
            return "\(value)"
        }
    }
    
    /// v3.1.32: iOS 原生 sqlite3 命令——查询 SQLite 数据库
    private static func runIOSSqlite(_ command: String) -> [String: Any] {
        let fm = FileManager.default
        
        // 解析：sqlite3 <db_path> "<query>" 或 'query'
        // v3.6.19d: 原来只认双引号，AI/用户发单引号 SQL 会 usage 误报；改为自动识别单/双引号包裹，
        // 并剥掉 db 路径自身可能带的引号。
        let dq = command.firstIndex(of: "\"")
        let sq = command.firstIndex(of: "'")
        let openQuote: Character
        if let d = dq, let s = sq { openQuote = d < s ? "\"" : "'" }
        else if dq != nil { openQuote = "\"" }
        else if sq != nil { openQuote = "'" }
        else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\""]
        }
        guard let qStart = command.firstIndex(of: openQuote) else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\""]
        }
        let qRest = command[command.index(after: qStart)...]
        guard let qEnd = qRest.firstIndex(of: openQuote) else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\""]
        }
        let query = String(qRest[..<qEnd])

        // 提取 db 路径 (在引号之前），并剥掉路径自身可能带的引号
        let beforeQuote = command[..<qStart].trimmingCharacters(in: .whitespaces)
        let parts = beforeQuote.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return ["command": command, "exit_code": 1, "stdout": "Usage: sqlite3 <db_file> \"SELECT * FROM table\""]
        }
        var dbArg = parts[1]
        if dbArg.hasPrefix("\""), dbArg.hasSuffix("\"") { dbArg = String(dbArg.dropFirst().dropLast()) }
        if dbArg.hasPrefix("'"), dbArg.hasSuffix("'") { dbArg = String(dbArg.dropFirst().dropLast()) }
        let dbPath = ShellExecTool.normalizePath((dbArg as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: dbPath) else {
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: \(dbPath): No such file"]
        }
        
        var db: OpaquePointer? = nil
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: Failed to open database"]
        }
        defer { sqlite3_close(db) }

        // 小工具：在已打开的 db 上执行一条 SQL，返回文本行（无表头）
        func execSQL(_ sql: String) -> ([String], String?) {
            var st: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                let e = sqlite3_errmsg(db).map { String(cString: $0) }
                return ([], e ?? "prepare failed")
            }
            defer { sqlite3_finalize(st) }
            var rows: [String] = []
            while sqlite3_step(st) == SQLITE_ROW {
                var vals: [String] = []
                for i in 0..<sqlite3_column_count(st) {
                    if let p = sqlite3_column_text(st, Int32(i)) { vals.append(String(cString: p)) }
                    else { vals.append("NULL") }
                }
                rows.append(vals.joined(separator: " | "))
            }
            return (rows, nil)
        }

        // v3.5.0：支持 sqlite3 点命令——之前直接 prepare 必失败（.tables/.schema/.databases/.indexes 不是 SQL）
        if query.hasPrefix(".") {
            let comps = query.split(separator: " ").map(String.init)
            let cmd = comps.first ?? ""
            switch cmd {
            case ".tables":
                let (r, e) = execSQL("SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)"] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no tables)" : r.joined(separator: "\n")]
            case ".databases":
                return ["command": command, "exit_code": 0, "stdout": dbPath]
            case ".schema":
                let tbl = comps.count > 1 ? comps[1] : ""
                let sql = tbl.isEmpty
                    ? "SELECT sql FROM sqlite_master WHERE type IN ('table','view','index') ORDER BY name"
                    : "SELECT sql FROM sqlite_master WHERE type IN ('table','view','index') AND tbl_name='\(tbl)' ORDER BY name"
                let (r, e) = execSQL(sql)
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)"] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no schema)" : r.joined(separator: "\n")]
            case ".indexes":
                let tbl = comps.count > 1 ? comps[1] : ""
                let sql = tbl.isEmpty
                    ? "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name"
                    : "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='\(tbl)' ORDER BY name"
                let (r, e) = execSQL(sql)
                if let e = e { return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(e)"] }
                return ["command": command, "exit_code": 0, "stdout": r.isEmpty ? "(no indexes)" : r.joined(separator: "\n")]
            default:
                return ["command": command, "exit_code": 1, "stdout": "sqlite3: unsupported dot command '\(cmd)'. Supported: .tables .schema [tbl] .databases .indexes [tbl]. For arbitrary queries use: sqlite3 \(dbPath) \"SELECT ...\""]
            }
        }

        var statement: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            if let err = sqlite3_errmsg(db) {
                let msg = String(cString: err)
                return ["command": command, "exit_code": 1, "stdout": "sqlite3 error: \(msg)"]
            }
            return ["command": command, "exit_code": 1, "stdout": "sqlite3: Failed to prepare query"]
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        let columnCount = sqlite3_column_count(statement)

        // 表头
        var headers: [String] = []
        for i in 0..<columnCount {
            if let name = sqlite3_column_name(statement, Int32(i)) {
                headers.append(String(cString: name))
            }
        }
        rows.append("| " + headers.joined(separator: " | ") + " |")
        rows.append(String(repeating: "-", count: rows[0].count))

        // 数据行
        while sqlite3_step(statement) == SQLITE_ROW {
            var values: [String] = []
            for i in 0..<columnCount {
                if let ptr = sqlite3_column_text(statement, Int32(i)) {
                    values.append(String(cString: ptr))
                } else {
                    values.append("NULL")
                }
            }
            rows.append("| " + values.joined(separator: " | ") + " |")
        }

        // v3.5.0：截断时写入完整 spill 并提示 limit——避免模型反复裸调重试
        if rows.count > 200 {
            let full = rows.joined(separator: "\n")
            let spill = ToolRegistry.spillLarge("sqlite3", full)
            rows = Array(rows.prefix(200)) + ["... (\(rows.count - 2) result rows total, truncated to 200)", "Full result: \(spill)", "Tip: add LIMIT to control row count, e.g. SELECT ... LIMIT 5000"]
        }

        return [
            "command": command,
            "exit_code": 0,
            "stdout": rows.joined(separator: "\n")
        ]
    }
    
    
    
    
    
    
    
    /// v3.1.33: iOS 原生 ps 命令——进程列表
    /// v3.1.68: 真实进程表 (sysctl KERN_PROC_ALL），替换此前假数据桩 (AI 诊断 5："ps 是桩"属实）
    private static func runIOSPs(_ command: String) -> [String: Any] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: cannot read process list (sysctl size)"]
        }
        let count = size / MemoryLayout<kinfo_proc>.size
        guard count > 0, count < 2000 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: abnormal process count (\(count))"]
        }
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procList, &size, nil, 0) == 0 else {
            return ["command": command, "exit_code": 1, "stdout": "ps: cannot read process list (sysctl read)"]
        }
        
        var lines = ["PID   PPID  NAME"]
        let n = min(count, 200)
        for i in 0..<n {
            let p = procList[i]
            let pid = p.kp_proc.p_pid
            let ppid = p.kp_eproc.e_ppid
            let comm = withUnsafePointer(to: p.kp_proc.p_comm) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }
            lines.append(String(format: "%5d  %5d  %@", pid, ppid, comm))
        }
        if count > n {
            lines.append("... (total \(count) processes, showing first \(n)")
        }
        return [
            "command": command,
            "exit_code": 0,
            "stdout": lines.joined(separator: "\n"),
            "hint": "iOS native ps: real process table (sysctl), max 200 entries"
        ]
    }
    
    
    
    
    
    
    
    
    /// 过滤杂散调试噪音行
    static func filterNoise(_ output: String) -> String {
        let noisePattern = "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3} \\S+\\[\\d+:\\d+\\]|Num file descriptors opened = )"
        let lines = output.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            line.range(of: noisePattern, options: .regularExpression) == nil
        }
        return filtered.joined(separator: "\n")
    }
}

/// v7.1.80：主动中断工具——AI 发觉命令卡死时调用（配合 shell.exec background 模式）。
/// 参数 pid 可选：传 = 杀指定后台任务；缺省 = 中断当前正在执行的命令。
final class ShellStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "shell.stop",
        summary: "Stop a running command. Params: pid (optional Int). Use for: cancelling a long-running background job you started with shell.exec background=true when you judge it stalled (poll its log first: no progress for a while = stalled). Without pid, interrupts the currently executing command. Sends SIGTERM then SIGKILL to the guest process group.",
        parameters: [
            "pid": "Optional Int: guest process id returned as background_pid from shell.exec background=true. Omit to interrupt the current running command.",
        ],
        verified: true
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        if let pid = params["pid"] as? Int, pid > 0 {
            TrollRuntimeEngine.stopPid(pid)
            return ["stopped": true, "pid": pid,
                    "hint": "Sent SIGTERM/SIGKILL to guest pid \(pid). Verify it's gone: `ps | grep <cmd>` or check its log stopped advancing."]
        }
        TrollRuntimeEngine.interruptCurrent()
        return ["stopped": true, "current": true,
                "hint": "Interrupted the current running command."]
    }
}

/// v7.2.0：系统侧 spawn 执行 Mach-O（jroot / 越狱二进制）——shell.exec 的互补通道。
/// 背景：shell.exec 跑在 TrollRuntime Alpine 容器（Linux ELF 内核），执行 Apple Mach-O
/// （越狱版 clang/ldid/dpkg-deb/Theos 产物）报 ENOEXEC「格式错误」——容器内核不认。
/// 系统侧 posix_spawn（InjectionManager.spawnRootDetailed，App 内部跑 ldid//bin/ps 同机制）
/// 在 iOS 系统侧执行 Mach-O，stdout/stderr 经管道拿回，完全可用。
/// 规则：容器工具（apk 装的 ELF）用 shell.exec；越狱/Mach-O 工具用 system.exec_root。
final class SystemExecRootTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.exec_root",
        summary: "Execute a binary on the iOS system side (root posix_spawn, NOT the Linux container). Use for: run jailbreak-native Mach-O tools from jroot — /var/jb/usr/bin/ldid, clang, dpkg-deb, theos binaries — which the container shell.exec CANNOT execute (TrollRuntime Alpine kernel is Linux/ELF, rejects Apple Mach-O with ENOEXEC format error). Also fine for /bin/ps, /usr/bin/otool, bundled ldid. IMPORTANT for non-jailbroken (TrollStore-only) devices: /var/jb does NOT exist there — locate the app-bundled tools first with shell.exec \"find /ios_containers -name ldid\" (also try /ios_system and /ios_workspace), then pass that real path. On jailbroken devices use /var/jb/usr/bin/ldid directly. Only execute known trusted tool binaries (system/jroot tools or your own built Mach-O), never arbitrary files from /var/mobile. Don't use for: normal commands (use shell.exec), apk-installed Linux tools (they are ELF, run in shell.exec), scripts or ELF files (will be rejected — they belong in shell.exec). Example: jailbroken sign → system.exec_root path:/var/jb/usr/bin/ldid args:[\"-S\",\"/path/file\"]; TrollStore sign → first find the bundled ldid (shell.exec find), then system.exec_root path:<that path> args:[\"-S\",\"/path/file\"]. exit=0 means success, nonzero means the tool itself failed (read its error). stdout/stderr returned separately; binary stdout (ldid -e bplist) → raw_base64.",
        parameters: [
            "path": "Absolute path of the Mach-O binary to execute (required). Must exist and be a real Mach-O (elf/script → rejected with a hint to use shell.exec)",
            "args": "Optional array of argument strings (default empty)",
            "timeout": "Optional timeout seconds (default 60, max 600)",
            "limit": "Optional Int: result string truncation cap (default 16000 chars)",
            "env": "Optional dict of extra environment variables (default: PATH=/usr/bin:/bin:/usr/sbin:/sbin; pass {\"PATH\":\"/var/jb/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin\"} for jroot toolchains that need their own bin dir)",
        ],
        verified: true
    )

    /// 与 shell.exec 一致的危险命令模式——root 权限下更严格，直接拒绝。
    private static let dangerousArgsPatterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            ("(^|[/ ])rm\\s+(-[a-z]*r[a-z]*)?\\s*\\s-?/?$|(^|[/ ])rm\\s+(-[a-z]*r[a-z]*)?\\s*/(\\s|$)", "rm -rf / (root wipe)"),
            ("(^|[/ ])rm\\s+(-[a-z]*r[a-z]*)?\\s*~", "rm -rf ~"),
            ("(^|[/ ])dd\\s+if=(/dev/|of=/dev/)", "dd raw device write"),
            ("(^|[/ ])mkfs\\.", "mkfs filesystem format"),
            ("(^|[/ ]):\\(\\)\\{", "fork bomb"),
            ("(^|[/ ])shutdown\\b|(^|[/ ])reboot\\b|(^|[/ ])halt\\b", "system shutdown"),
        ]
        return raw.map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }
    }()

    /// 读文件头判断是否 Mach-O
    private static func machOType(of path: String) -> String? {
        guard let h = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe).prefix(4) else { return nil }
        let b = [UInt8](h)
        if b.count == 4 {
            if b == [0xCF, 0xFA, 0xED, 0xFE] || b == [0xFE, 0xED, 0xFA, 0xCF] ||
               b == [0xCA, 0xFE, 0xBA, 0xBE] { return "macho" }
            if b == [0x7F, 0x45, 0x4C, 0x46] { return "elf" }
        }
        return "other"
    }

    // MARK: - v7.1.42 签名自动化——AMFI 代码签名强制：Mach-O 必须有效签名（越狱也走 trust cache/签名，下载的裸二进制无 LC_CODE_SIGNATURE 会被系统拒绝执行）。exec_root 执行前自动检测、缺失自动 ldid -S 补签。

    /// v7.2.1：系统路径白名单——沙箱 FileManager 不可见但 root posix_spawn 可执行的目录；
    /// 这些目录内的工具必为 iOS Mach-O（跳过存在性/Mach-O 头沙箱校验，走 root 视角探测）
    private static func isSystemPath(_ path: String) -> Bool {
        let prefixes = ["/bin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/sbin/", "/var/jb/", "/System/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    /// 是否在沙箱可写区（只对这些路径自动补签——系统路径 /usr/bin、/var/jb 不动，那些要么已签、要么越狱 trust cache 管）
    private static func isAutoSignablePath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let roots = [home + "/", home + "/Documents/", "/var/mobile/Documents/"]
        return roots.contains { path.hasPrefix($0) }
    }

    /// 解析 Mach-O 找 LC_CODE_SIGNATURE（load command 0x1D）——支持 64 位 thin 与 fat 多 slice（iOS arm64 为 LE）
    private static func hasCodeSignature(of path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return false }
        return hasCodeSignature(in: data, offset: 0)
    }

    private static func hasCodeSignature(in data: Data, offset: Int) -> Bool {
        let b = [UInt8](data)
        guard offset + 4 <= b.count else { return false }
        func u32(_ i: Int, le: Bool) -> UInt32 {
            if le { return UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
            return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
        }
        let mb = [b[offset], b[offset+1], b[offset+2], b[offset+3]]
        let le: Bool
        switch mb {
        case [0xCF, 0xFA, 0xED, 0xFE]: le = true        // MH_MAGIC_64 (LE on disk)
        case [0xFE, 0xED, 0xFA, 0xCF]: le = false       // MH_MAGIC_64 BE
        case [0xBE, 0xBA, 0xFE, 0xCA]: le = true        // FAT_MAGIC LE
        case [0xCA, 0xFE, 0xBA, 0xBE]: le = false       // FAT_MAGIC BE
        default: return false
        }
        if mb == [0xCF, 0xFA, 0xED, 0xFE] || mb == [0xFE, 0xED, 0xFA, 0xCF] {
            // 64 位 thin：header 32 字节，load commands 从 32 开始
            guard offset + 32 <= b.count else { return false }   // 防短文件越界（魔数匹配但 header 不完整）
            let ncmds = Int(u32(offset + 16, le: le))
            let sizeofcmds = Int(u32(offset + 20, le: le))
            guard ncmds > 0, sizeofcmds > 0, offset + 32 + sizeofcmds <= b.count else { return false }
            var off = offset + 32
            for _ in 0..<ncmds {
                guard off + 8 <= b.count else { break }
                let cmd = u32(off, le: le)
                let cmdsize = Int(u32(off + 4, le: le))
                if cmdsize < 8 { break }
                if cmd == 0x1D { return true }          // LC_CODE_SIGNATURE
                off += cmdsize
            }
            return false
        }
        // fat：每个 slice 各自检查（全部有签名才算已签）
        guard offset + 8 <= b.count else { return false }   // 防短文件越界
        let nfat = Int(u32(offset + 4, le: le))
        guard nfat > 0 else { return false }
        for i in 0..<min(nfat, 64) {
            let base = offset + 8 + i * 20
            guard base + 16 <= b.count else { return false }
            let sliceOff = Int(u32(base + 8, le: le))
            if !hasCodeSignature(in: data, offset: sliceOff) { return false }
        }
        return true
    }

    /// 自动补签：找内置 ldid（bundle bin/ 优先，/var/jb 兜底），ldid -S（可带 entitlements）签名目标文件
    private static func autoSign(_ path: String, entitlements: String?) throws {
        let candidates = [
            Bundle.main.bundlePath + "/bin/ldid",
            Bundle.main.bundlePath + "/Resources/bin/ldid",
            "/var/jb/usr/bin/ldid",
        ]
        guard let ldid = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw MCPError.invalidParams("auto-sign failed: no bundled ldid found (looked in bin/, Resources/bin/, /var/jb/usr/bin) — sign manually with ldid -S then retry")
        }
        let flag = entitlements.flatMap { "-S\($0)" } ?? "-S"
        let r = InjectionManager.shared.spawnRootDetailed(ldid, args: [flag, path], timeout: 30)
        if r.code != 0 {
            let detail = r.stderr.isEmpty ? r.stdout : r.stderr
            throw MCPError.invalidParams("auto-sign failed (ldid exit \(r.code)): \(String(detail.prefix(500))) — file unchanged, fix signature issues and retry")
        }
    }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let args = params["args"] as? [String] ?? []
        let timeout = (params["timeout"] as? Double) ?? 60
        let outLimit = (params["limit"] as? Int) ?? 16000
        let extraEnv = params["env"] as? [String: String]
        let signEntitlements = params["signEntitlements"] as? String   // v7.1.42：可选，ldid -S<file> 用

        // v7.2.1：系统路径（/bin、/usr/bin 等）沙箱 FileManager 不可见但 root posix_spawn 可执行——
        // 之前一律 PARAM_INVALID 死循环（用户实测 system.exec_root 传 /bin/ls、/usr/bin/find
        // 连败 3 次）。系统路径走 root 视角 /bin/sh test 探测 + 跳过 Mach-O 头检查（系统目录必为 Mach-O）。
        let sysPath = SystemExecRootTool.isSystemPath(path)
        var isDir = false
        if sysPath {
            let probe = InjectionManager.shared.spawnRootDetailed("/bin/sh",
                args: ["-c", "if test -d \"$1\"; then echo DIR; elif test -x \"$1\"; then echo EXEC; else echo NO; fi", "probe", path],
                timeout: 8)
            let kind = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "DIR" {
                throw MCPError.invalidParams("path is a directory: \(path) — pass the binary file path")
            }
            guard kind == "EXEC" else {
                throw MCPError.invalidParams("path not found: \(path) — if this device is non-jailbroken (TrollStore only), /var/jb does not exist; locate the app-bundled tool first with shell.exec \"find /ios_containers -name ldid\" (try /ios_system, /ios_workspace too) and pass the real path. If jailbroken, confirm the path with shell.exec \"ls\".")
            }
        } else {
            // 1) 文件必须存在（沙箱可见区，FileManager 视角正确）
            var isDirCB: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirCB) else {
                throw MCPError.invalidParams("path not found: \(path) — if this device is non-jailbroken (TrollStore only), /var/jb does not exist; locate the app-bundled tool first with shell.exec \"find /ios_containers -name ldid\" (try /ios_system, /ios_workspace too) and pass the real path. If jailbroken, confirm the path with shell.exec \"ls\".")
            }
            isDir = isDirCB.boolValue
            if isDir {
                throw MCPError.invalidParams("path is a directory: \(path) — pass the binary file path")
            }
            // 2) 必须真是 Mach-O（ELF/脚本 → 指回 shell.exec，防误用）
            let kind = SystemExecRootTool.machOType(of: path)
            if kind == "elf" {
                throw MCPError.invalidParams("\(path) is a Linux ELF binary — run it with shell.exec, NOT system.exec_root (system.exec_root only executes Apple Mach-O)")
            }
            if kind != "macho" {
                throw MCPError.invalidParams("\(path) is not a Mach-O binary (script/unknown format) — system.exec_root executes Mach-O only; scripts go through shell.exec")
            }
        }
        // 3) 危险参数检测（root 权限直接拒绝）
        let joinedArgs = args.joined(separator: " ")
        for (re, why) in SystemExecRootTool.dangerousArgsPatterns {
            if re.firstMatch(in: joinedArgs, options: [], range: NSRange(location: 0, length: (joinedArgs as NSString).length)) != nil {
                throw MCPError.invalidParams("refused: \(why) — system.exec_root runs as root; destructive ops are blocked. Use a safe operation instead.")
            }
        }
        // 3.5) v7.1.42：签名自动化——沙箱可写区的 Mach-O 若缺 LC_CODE_SIGNATURE 先自动 ldid -S 补签
        //（AMFI 强制：无签名/无效签名的 Mach-O 即使越狱也会被拒绝执行；系统路径不自动签）
        if SystemExecRootTool.isAutoSignablePath(path), !SystemExecRootTool.hasCodeSignature(of: path) {
            try SystemExecRootTool.autoSign(path, entitlements: signEntitlements)
        }

        let r = InjectionManager.shared.spawnRootDetailed(path, args: args, timeout: min(timeout, 600), extraEnv: extraEnv)
        var output = r.stdout
        if !r.stderr.isEmpty {
            output += output.isEmpty ? r.stderr : "\n" + r.stderr
        }
        if outLimit > 0 && output.count > outLimit {
            output = String(output.prefix(outLimit)) + "\n…[truncated]"
        }
        AuditLog.shared.log("system.exec_root", detail: "path=\(path) exit=\(r.code) sig=\(r.signaled ? r.signal : 0) out=\(String(output.prefix(200)))")
        var result: [String: Any] = [
            "exit": Int(r.code),
            "output": output,
        ]
        // 分开返回，供解析（ldid -e 等取 stdout；二进制输出用 raw_base64）
        if !r.stdout.isEmpty { result["stdout"] = r.stdout }
        if !r.stderr.isEmpty { result["stderr"] = r.stderr }
        if !r.rawStdout.isEmpty {
            result["raw_base64"] = r.rawStdout.base64EncodedString()
        }
        if r.timedOut { result["timed_out"] = true }
        if r.signaled { result["signal"] = Int(r.signal) }
        return result
    }
}
