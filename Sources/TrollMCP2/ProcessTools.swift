import Foundation

// v2.9.184：libproc 进程枚举 (proc_listallpids / proc_pidpath，纯 C API，
// 不依赖 shell/ps/task_for_pid——TrollStore 无 shell 环境 /bin/ps 不可用，
// 导致 app.status / app.decrypt 的进程检测永远 false (实测证实）。
// Darwin 模块不暴露 libproc 符号，用 @_silgen_name 直接绑定系统符号 (iOS 6+ 均存在）。

// v2.9.70：进程管理 + 测试编排器
// 1. 进程管理 — 目标 App 启停、重启、前台状态、CPU/内存/线程采样
// 2. 测试编排器 — 注入→启动→采集→验证→报告，一键闭环

// MARK: - 进程管理工具

final class AppStartTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.start",
        summary: "Launch/open an app. Use for: start an app, open it from home screen. Don't use for: restart app (use app.restart), check if running (use app.status). Example: user says 'open 小红书' → launch app.",
        parameters: [
            "bundle_id": "Target app bundle ID",
            "wait_seconds": "Wait after launch to confirm it started (default: 3s)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = max((params["wait_seconds"] as? Int) ?? 3, 1)
        let start = Date()
        var errors: [[String: Any]] = []
        func find() -> Int32 { findPid(by: bundleId) }

        // 方法 1：open -b (正确带 -b 标志；旧版漏了 -b 导致 exit 2 误报 Bundle ID 错误）
        let (c1, o1) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["-b", bundleId])
        Thread.sleep(forTimeInterval: TimeInterval(wait))
        var pid = find()
        if pid > 0 {
            return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "open -b",
                    "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
        }
        errors.append(["step": "open -b", "exit": Int(c1), "stderr": String(o1.prefix(400))])

        // 方法 1.5 (v2.9.185）：LSApplicationWorkspace 私有 API 拉起 (TrollStore 可用，不依赖 shell）
        if let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           ws.responds(to: NSSelectorFromString("openApplicationWithBundleID:")) {
            _ = ws.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleId)
            Thread.sleep(forTimeInterval: TimeInterval(wait))
            pid = find()
            if pid > 0 {
                return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "ls_workspace_open",
                        "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
            }
            errors.append(["step": "ls_workspace_open", "exit": 0, "stderr": "openApplicationWithBundleID didn't launch"])
        }

        // 方法 2：注册表路径 → 直接执行主二进制 (绕过 open 依赖）
        if let app = AppCatalog.find(bundleId) {
            let plistPath = app.path + "/Info.plist"
            let plist = NSDictionary(contentsOfFile: plistPath)
            let exec = (plist?["CFBundleExecutable"] as? String) ?? ""
            if !app.path.isEmpty, !exec.isEmpty {
                let bin = app.path + "/" + exec
                if FileManager.default.fileExists(atPath: bin) {
                    let (c2, o2) = InjectionManager.shared.spawnRoot(bin, args: [])
                    Thread.sleep(forTimeInterval: TimeInterval(wait))
                    pid = find()
                    if pid > 0 {
                        return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "direct_exec",
                                "executable": bin, "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
                    }
                    errors.append(["step": "direct_exec", "exit": Int(c2), "stderr": String(o2.prefix(400))])
                }
            }
            // 方法 3：URL scheme
            if let types = plist?["CFBundleURLTypes"] as? [[String: Any]],
               let schemes = types.first?["CFBundleURLSchemes"] as? [String],
               let scheme = schemes.first {
                let (c3, o3) = InjectionManager.shared.spawnRoot("/usr/bin/open", args: ["\(scheme)://"])
                Thread.sleep(forTimeInterval: TimeInterval(wait))
                pid = find()
                if pid > 0 {
                    return ["bundle_id": bundleId, "started": true, "pid": pid, "method_used": "url_scheme",
                            "scheme": scheme, "launch_ms": Int(Date().timeIntervalSince(start) * 1000)]
                }
                errors.append(["step": "url_scheme", "exit": Int(c3), "stderr": String(o3.prefix(400))])
            }
        }

        return ["bundle_id": bundleId, "started": false, "pid": 0,
                "launch_ms": Int(Date().timeIntervalSince(start) * 1000),
                "errors": errors,
                "next_step": "check app.encrypt_info (decrypt if encrypted) -> app.status to confirm process; consider injection.mem memory injection when anti-debug blocks",
                "hint": "all three launch methods failed, see errors detail (no longer a Bundle ID false report)"]
    }
}

final class AppStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.stop",
        summary: "Kill/stop an app (force close it). Use for: close an app that's running, force quit. Don't use for: restart app (use app.restart), uninstall app (use app.uninstall). Example: user says 'close 小红书' → stop app.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "stopped": false, "reason": "process not running"]
        }

        let (exitCode, _) = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"])
        Thread.sleep(forTimeInterval: 1)
        let stillRunning = findPid(by: bundleId) > 0

        return [
            "bundle_id": bundleId,
            "original_pid": pid,
            "stopped": !stillRunning,
            "kill_exit": exitCode
        ]
    }
}

final class AppRestartTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.restart",
        summary: "Restart/kill then relaunch an app. Use for: restart app after injection, clear app state, force close and reopen. Don't use for: just opening app (use app.launch), uninstall app (use app.uninstall). Example: user says 'restart 小红书' → restart com.xingin.discover.",
        parameters: [
            "bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover",
            "wait_seconds": "Wait seconds after launch (default 3)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let wait = (params["wait_seconds"] as? Int) ?? 3

        let start = Date()
        // 杀掉旧进程——v2.9.251: spawnRoot 在 TrollStore 无 root shell(/bin/sh not found)下 kill 不执行,
        // App 没真正重启导致 ControlAgent.dylib 不重新加载、4789 服务器起不来;改普通 spawn(用户态可杀自己进程)
        // v2.9.256: 实测 app.restart 返回 old_pid==new_pid (PID 未变=假重启）——
        // 普通 spawn /bin/kill 在 TrollStore 沙盒无 task_for_pid 杀不掉其他 App 进程。
        // 改调 SpringBoardServices 私有 API SBTerminateApplication (platform-application entitlement 可调，
        // iOS 全版本存在），failed再兜底 /bin/kill。
        // v2.9.257: SBTerminateApplication 实测也无效(需 springboard.debug entitlement)。对齐 TrollFools
        // TFUtilKillAll——直接进程内调 kill() 系统调用(platform-application 权限足够),这才是验证过的可靠方式。
        let oldPid = findPid(by: bundleId)
        if oldPid > 0 {
            let killRet = kill(oldPid, SIGKILL)
            if killRet != 0 {
                NSLog("[app.restart] kill(\(oldPid),SIGKILL) errno=\(errno)")
                let terminated = Self.terminateApplication(bundleId: bundleId)
                if !terminated {
                    let (kexit, kout) = InjectionManager.shared.spawn("/bin/kill", args: ["-9", "\(oldPid)"])
                    if kexit != 0 { NSLog("[app.restart] fallback kill pid \(oldPid) exit=\(kexit) \(kout)") }
                }
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        // 启动——v2.9.251: /usr/bin/open 在 TrollStore 不可靠,改 SBSLaunch(验证可用)
        let (launched, launchMsg) = ProcessHelper.launchApp(bundleId: bundleId)
        if !launched { NSLog("[app.restart] launch failed: \(launchMsg)") }
        Thread.sleep(forTimeInterval: TimeInterval(wait))

        let newPid = findPid(by: bundleId)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        return [
            "bundle_id": bundleId,
            "old_pid": oldPid,
            "new_pid": newPid,
            "restarted": newPid > 0,
            "restart_ms": elapsed
        ]
    }

    /// v2.9.256: 真终止 App——SpringBoardServices 私有 API SBTerminateApplication。
    /// TrollStore 的 App 带 platform-application entitlement，可调该符号终止任意前台 App；
    /// 比 /bin/kill 可靠 (kill 需 task_for_pid/root，TrollStore 非越狱下不可用）。
    static func terminateApplication(bundleId: String) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SBTerminateApplication") else {
            NSLog("[app.restart] SBTerminateApplication symbol not found")
            return false
        }
        typealias TermFn = @convention(c) (CFString) -> Int32
        let fn = unsafeBitCast(sym, to: TermFn.self)
        let ret = fn(bundleId as CFString)
        if ret != 0 { NSLog("[app.restart] SBTerminateApplication ret=\(ret)") }
        return ret == 0
    }
}

final class AppStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.status",
        summary: "Check if an app is running + its resource usage (CPU, memory, PID). Use for: see if app is alive, check how much memory it uses. Don't use for: stop app (use app.stop). Example: user says 'is 小红书 running, how much memory' → check app status.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "running": false]
        }

        // 用 ps 拿详细信息
        let (_, psOutput) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-p", "\(pid)", "-o", "pid,%cpu,%mem,rss,etime,comm"])
        let lines = psOutput.components(separatedBy: .newlines)
        var cpu = "", mem = "", rss = "", etime = "", comm = ""
        if lines.count >= 2 {
            let parts = lines[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 6 {
                cpu = parts[1]; mem = parts[2]; rss = parts[3]; etime = parts[4]; comm = parts[5]
            }
        }

        // 线程数
        let (_, threadOutput) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-M", "\(pid)"])
        let threadCount = threadOutput.components(separatedBy: .newlines).count - 1

        return [
            "bundle_id": bundleId,
            "running": true,
            "pid": pid,
            "cpu_percent": cpu,
            "memory_percent": mem,
            "rss_kb": rss,
            "elapsed": etime,
            "thread_count": threadCount,
            "process_name": comm
        ]
    }
}

final class AppStatsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.stats",
        summary: "Profile CPU/memory usage of an app. Use for: performance analysis, detect memory leaks. Don't use for: check if app is running (use app.status). Example: user says 'measure 小红书 memory usage' → profile stats.",
        parameters: [
            "bundle_id": "Target app bundle ID",
            "duration": "How long to sample (default: 10s)",
            "interval": "Sample interval (default: 1s)"
        ],
    verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let duration = (params["duration"] as? Int) ?? 10
        let interval = (params["interval"] as? Int) ?? 1

        var samples: [[String: Any]] = []
        var cpuValues: [Double] = []
        var memValues: [Int] = []

        let pid = findPid(by: bundleId)
        guard pid > 0 else {
            return ["bundle_id": bundleId, "error": "App not running"]
        }

        let steps = max(1, duration / interval)
        for i in 0..<steps {
            let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-p", "\(pid)", "-o", "%cpu,rss"])
            let lines = output.components(separatedBy: .newlines)
            if lines.count >= 2 {
                let parts = lines[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let cpu = Double(parts[0]) ?? 0
                    let rss = Int(parts[1]) ?? 0
                    cpuValues.append(cpu)
                    memValues.append(rss)
                    samples.append(["t": i * interval, "cpu": cpu, "rss_kb": rss])
                }
            }
            if i < steps - 1 { Thread.sleep(forTimeInterval: TimeInterval(interval)) }
        }

        let avgCpu = cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)
        let maxCpu = cpuValues.max() ?? 0
        let avgMem = memValues.isEmpty ? 0 : memValues.reduce(0, +) / memValues.count
        let maxMem = memValues.max() ?? 0
        let minMem = memValues.min() ?? 0
        let memGrowth = maxMem - minMem

        return [
            "bundle_id": bundleId,
            "pid": pid,
            "duration_s": duration,
            "samples": samples.count,
            "cpu": ["avg": String(format: "%.1f", avgCpu), "max": String(format: "%.1f", maxCpu), "unit": "%"],
            "memory": ["avg_kb": avgMem, "max_kb": maxMem, "min_kb": minMem, "growth_kb": memGrowth],
            "trend": samples,
            "leak_suspect": memGrowth > 1024 ? "⚠️ memory grew \(memGrowth)KB, possible leak" : "memory stable"
        ]
    }
}

// MARK: - 辅助函数

// libproc 系统符号直绑 (iOS 6+；macOS CI 交叉编译 iOS target 也可链接）
@_silgen_name("proc_listallpids")
func sys_proc_listallpids(_ buffer: UnsafeMutablePointer<pid_t>?, _ bufferSize: Int32) -> Int32

@_silgen_name("proc_pidpath")
func sys_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ buffersize: UInt32) -> Int32

/// v2.9.184：libproc 枚举进程，按可执行文件路径前缀匹配 (xxx.app 目录）。
/// 纯 C API，TrollStore 无 shell 环境可用；非越狱可能受进程可见性限制，实测确认。
/// v3.1.71：路径归一化——libproc 返回真实路径 /private/var/...，而 AppCatalog 记录可能是
/// /var/... (软链），前缀匹配会failed (AI 实测 app.status 与 encrypt_info 打架的根因之一）。
func findPidByExecutable(bundlePath: String) -> Int32 {
    let normBundle = normalizeIOPath(bundlePath)
    var pids = [pid_t](repeating: 0, count: 2048)
    let count = sys_proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return 0 }
    for i in 0..<Int(count) {
        let pid = pids[i]
        var buf = [CChar](repeating: 0, count: 4096)
        let len = sys_proc_pidpath(pid, &buf, UInt32(buf.count))
        if len > 0 {
            let path = String(cString: buf)
            // v2.9.186：排除扩展进程 (.appex）——扩展在 bundle 目录内但非主 App 进程，
            // 此前误把 NotificationServiceExtension 当主进程 (真机实测 pid 11718 假阳性，
            // 导致 app.start 误报启动OK、app.decrypt 拿扩展进程 task 读镜像表全空）
            if path.contains(".appex") { continue }
            // 可执行文件在 .app 目录内，路径以 bundlePath 开头即matched (归一化后比较）
            if normalizeIOPath(path).hasPrefix(normBundle) {
                return pid
            }
        }
    }
    return 0
}

/// v3.1.71：/var ↔ /private/var 软链归一 (/var/xxx → /private/var/xxx；反之还原）
func normalizeIOPath(_ p: String) -> String {
    if p.hasPrefix("/private/var/") {
        return "/var" + String(p.dropFirst("/private/var".count))
    }
    if p.hasPrefix("/var/") {
        return "/private" + p
    }
    return p
}

func findPid(by bundleId: String) -> Int32 {
    // v2.9.184：主用 libproc (不依赖 shell）。AppCatalog 拿 bundle 可执行路径。
    if let entry = AppCatalog.find(bundleId) {
        let exePath = entry.path + "/" + entry.execName
        let pid = findPidByExecutable(bundlePath: exePath)
        if pid > 0 { return pid }
        // 某些进程的可执行路径与 LSApplicationProxy 记录不完全一致，
        // 用 .app 目录前缀再试一次
        let pid2 = findPidByExecutable(bundlePath: entry.path)
        if pid2 > 0 { return pid2 }
        // v3.1.71：libproc 命中failed时先按可执行名精确匹配 (ps 输出 comm 列）
        let pid3 = findPidByPsName(entry.execName)
        if pid3 > 0 { return pid3 }
    }
    // 兜底：旧 ps 方式 (无 shell 环境会failed，保留仅作兼容）
    // v3.1.71：改用 spawnRootDetailed (30s 超时）——spawnRoot 无超时在慢设备上
    // 可能拿不到 ps 输出导致漏报 (真机实测 app.status 与 app.encrypt_info 打架）
    let output = InjectionManager.shared.spawnRootDetailed("/bin/ps", args: ["-ax"], timeout: 30).stdout
    for line in output.components(separatedBy: .newlines) {
        if line.contains(bundleId) || line.contains(bundleId.replacingOccurrences(of: ".", with: "")) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                return pid
            }
        }
    }
    return 0
}

/// v3.1.71：按进程名 (comm 列）匹配 pid——app.status 与 encrypt_info 打架的补丁：
/// libproc 匹配可执行路径failed时，ps 里 comm 列 (可执行文件名）仍可命中。
func findPidByPsName(_ execName: String) -> Int32 {
    guard !execName.isEmpty else { return 0 }
    let output = InjectionManager.shared.spawnRootDetailed("/bin/ps", args: ["-ax"], timeout: 30).stdout
    for line in output.components(separatedBy: .newlines) {
        if line.contains(execName) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
            if let pidStr = parts.first, let pid = Int32(pidStr) {
                return pid
            }
        }
    }
    return 0
}

// MARK: - v3.1.34: app 大工具 + 子命令 (合并 5 个 app.* 工具）

final class AppExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "app",
        summary: "Manage apps & analyze app internals (launch/stop/install/uninstall/diagnose/decrypt/entitlements). Subcommands: launch / stop / restart / status / stats / cache_inspect / cache_clear / open_and_input / deps / install / uninstall / duplicate / diagnose / encrypt_info / entitlements / decrypt / replace_decrypted / restore_binary / launch_options / inject_package. Encrypted apps (cryptid=1) must be decrypted first: decrypt → replace_decrypted → restore_binary (recoverable on failure); App Store originals can't be replaced in place → inject_package with a renamed bundle.",
        parameters: [
            "command": "Subcommand: launch / stop / restart / status / stats / cache_inspect / cache_clear / open_and_input / deps / install / uninstall / duplicate / diagnose / encrypt_info / entitlements / decrypt / replace_decrypted / restore_binary / launch_options / inject_package",
            "bundle_id": "App bundle ID (e.g. com.xingin.discover)",
            "path": "IPA file path (for install)",
            "ipa_path": "Decrypted IPA path (for replace_decrypted)",
            "output_name": "Output name for decrypted IPA (for decrypt, optional)",
            "duration": "Duration seconds (for stats)",
            "text": "Text to input (for open_and_input)"
        ],
        verified: true, category: "app_control", requiresTrollStore: true, prerequisites: ["install/uninstall needs TrollStore entitlements; on failure see diagnose"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("app", detail: command)
        
        switch command {
        case "launch":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppStartTool().invoke(["bundle_id": bundleId])
            
        case "stop":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppStopTool().invoke(["bundle_id": bundleId])
            
        case "restart":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppRestartTool().invoke(["bundle_id": bundleId])
            
        case "status":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppStatusTool().invoke(["bundle_id": bundleId])
            
        case "stats":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            let duration = (params["duration"] as? Double) ?? 5.0
            return try AppStatsTool().invoke(["bundle_id": bundleId, "duration": duration])
            
        case "cache_inspect":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppCacheInspectTool().invoke(["bundle_id": bundleId])
            
        case "cache_clear":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppCacheClearTool().invoke(["bundle_id": bundleId])
            
        case "open_and_input":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var p: [String: Any] = ["bundle_id": bundleId]
            if let text = params["text"] as? String { p["text"] = text }
            return try AppOpenAndInputTool().invoke(p)
            
        case "deps":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppDepsTool().invoke(["bundle_id": bundleId])

        case "install":
            guard let path = params["ipa_path"] as? String ?? params["path"] as? String else {
                throw MCPError.invalidParams("ipa_path required (IPA file path)")
            }
            return try AppInstallTool().invoke(["ipa_path": path])

        case "uninstall":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppUninstallTool().invoke(["bundle_id": bundleId])

        case "duplicate":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppDuplicateTool().invoke(["bundle_id": bundleId])

        case "diagnose":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppDiagnoseTool().invoke(["bundle_id": bundleId])

        case "encrypt_info":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppEncryptInfoTool().invoke(["bundle_id": bundleId])

        case "entitlements":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppEntitlementsTool().invoke(["bundle_id": bundleId])

        case "decrypt":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppDecryptTool().invoke(["bundle_id": bundleId])

        case "launch_options":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try AppLaunchOptionsTool().invoke(["bundle_id": bundleId])

        case "replace_decrypted":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var p: [String: Any] = ["bundle_id": bundleId]
            if let ipa = params["ipa_path"] as? String { p["ipa_path"] = ipa }
            return try AppReplaceDecryptedTool().invoke(p)

        case "inject_package":
            // v4.3.19: 改包名+注入 dylib+打包+TrollStore 静默安装成独立新 App
            var ip: [String: Any] = [:]
            if let v = params["ipa_path"] as? String { ip["ipa_path"] = v }
            if let v = params["dylib_path"] as? String { ip["dylib_path"] = v }
            if let v = params["new_bundle_id"] as? String { ip["new_bundle_id"] = v }
            if let v = params["new_name"] as? String { ip["new_name"] = v }
            if let v = params["auto_install"] as? Bool { ip["auto_install"] = v }
            return try AppInjectPackageTool().invoke(ip)

        case "restore_binary":
            // v4.3.16：就地替换后若目标 App 无法启动，用 runAsRoot 把 .troll-fools.bak 恢复回主二进制
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            guard let app = AppCatalog.find(bundleId) else {
                throw MCPError.failed("app not found: \(bundleId)")
            }
            let exec = (NSDictionary(contentsOfFile: app.path + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
            guard !exec.isEmpty else { throw MCPError.failed("no CFBundleExecutable in \(bundleId)") }
            let installedMain = app.path + "/" + exec
            let backup = installedMain + ".troll-fools.bak"
            guard FileManager.default.fileExists(atPath: backup) else {
                throw MCPError.failed("no backup at \(backup)")
            }
            let im = InjectionManager.shared
            let (c0, o0) = im.runAsRoot("cp", args: ["-p", backup, installedMain])
            if c0 != 0 { throw MCPError.failed("restore failed (\(c0)): \(o0)") }
            _ = im.runAsRoot("chown", args: ["33:33", installedMain])
            let mo = MachOAnalyzer.analyze(installedMain)
            AppCatalog.invalidateCache()
            return ["ok": true, "message": "restored original main binary from backup",
                    "data": ["bundle_id": bundleId, "installed_main": installedMain,
                             "cryptID": (mo?.cryptID).map { Int($0) } ?? -1,
                             "restored": true]]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: launch/stop/restart/status/stats/cache_inspect/cache_clear/open_and_input/deps/install/uninstall/duplicate/diagnose/encrypt_info/entitlements/decrypt/replace_decrypted/restore_binary/launch_options")
        }
    }
}
