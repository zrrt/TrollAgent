import Foundation

// v2.9.69：质量与诊断工具集
// 1. IPA/dylib 检查器 — 解析架构、签名、entitlements、依赖、注入可行性
// 2. Injection diagnosis器 — 细分加载failed原因
// 3. Log collection器 — collected App 日志、崩溃日志
// 4. HTTP 抓包 — 网络请求分析

// MARK: - IPA / dylib 检查器

final class IPAInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "ipa.inspect",
        summary: "Inspect an IPA or installed app: architecture, signature, entitlements, dylib dependencies, Info.plist. Use for: analyze an IPA file, check app details before injection. Don't use for: inject dylib (use injection.enable), list installed apps (use injection.list). Example: user says 'what architecture is this IPA' → inspect IPA.",
        parameters: [
            "path": "IPA file path or App Bundle path (required)",
            "detail": "basic (quick overview) or full (all dependencies + entitlements)"
        ],
    verified: true, category: "analysis")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let detail = (params["detail"] as? String) ?? "basic"

        var result: [String: Any] = ["path": path]

        // 判断是 IPA 还是 App Bundle
        let isIPA = path.hasSuffix(".ipa")
        var bundlePath = path
        var tempDir: String?

        if isIPA {
            // 解压 IPA 到临时目录
            let tmp = NSTemporaryDirectory().appending("ipa_inspect_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/unzip", args: ["-o", path, "-d", tmp])
            // 找到 Payload/*.app
            let payloadDir = tmp.appending("/Payload")
            if let apps = try? FileManager.default.contentsOfDirectory(atPath: payloadDir),
               let appDir = apps.first(where: { $0.hasSuffix(".app") }) {
                bundlePath = payloadDir.appending("/\(appDir)")
                tempDir = tmp
            }
        }

        // 读取 Info.plist
        let plistPath = bundlePath.appending("/Info.plist")
        if let plist = NSDictionary(contentsOfFile: plistPath) {
            let name = plist["CFBundleName"] as? String ?? ""
            let displayName = plist["CFBundleDisplayName"] as? String ?? ""
            let bundleId = plist["CFBundleIdentifier"] as? String ?? ""
            let version = plist["CFBundleShortVersionString"] as? String ?? ""
            let build = plist["CFBundleVersion"] as? String ?? ""
            let exec = plist["CFBundleExecutable"] as? String ?? ""
            let minOS = plist["MinimumOSVersion"] as? String ?? ""
            let platform = plist["DTPlatformName"] as? String ?? ""
            let urlTypes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.count ?? 0
            let bgModes = (plist["UIBackgroundModes"] as? [String]) ?? []
            result["info"] = [
                "CFBundleName": name,
                "CFBundleDisplayName": displayName,
                "CFBundleIdentifier": bundleId,
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "CFBundleExecutable": exec,
                "MinimumOSVersion": minOS,
                "DTPlatformName": platform,
                "CFBundleURLTypes": urlTypes,
                "UIBackgroundModes": bgModes
            ]
        }

        // 找到主二进制
        let executable = ((NSDictionary(contentsOfFile: plistPath))?["CFBundleExecutable"] as? String) ?? "App"
        let binaryPath = bundlePath.appending("/\(executable)")

        // v2.9.116：arch 改用 MachOAnalyzer 解析 (旧版依赖 /usr/bin/file，iOS 上不存在 → 永远 unknown 误判不可注入）
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) {
            let (_, entOutput) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", binaryPath])
            let macho = MachOAnalyzer.analyze(binaryPath)

            result["binary"] = [
                "path": binaryPath,
                "arch": macho?.arch ?? "unknown",
                "cryptid": macho.map { Int($0.cryptID) } ?? -1,
                "arch_parse_error": macho == nil ? "Mach-O parse failed (may be encrypted/special header), can't judge injectability from this" : "",
                "arch_note": macho?.cryptID ?? 0 > 0 ? "Encrypted (cryptid>0), symbol/class structure needs app.decrypt first" : "",
                "entitlements": detail == "full" ? String(entOutput.prefix(3000)) : "Signed (use detail=full for the full text)",
                "has_entitlements": !entOutput.isEmpty
            ]

            // 用 otool 检查依赖 (如果有 otool）
            let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
            if FileManager.default.fileExists(atPath: otoolPath) {
                let (_, libOutput) = InjectionManager.shared.spawnRoot(otoolPath, args: ["-L", binaryPath])
                let libs = libOutput.components(separatedBy: .newlines)
                    .filter { $0.contains("dylib") || $0.contains("framework") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                result["dependencies"] = detail == "full" ? Array(libs.prefix(30)) : "\(libs.count) dependency libraries (use detail=full for the list)"
            }

            // 检查加密段
            let otoolPath2 = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
            if FileManager.default.fileExists(atPath: otoolPath2) {
                let (_, lcOutput) = InjectionManager.shared.spawnRoot(otoolPath2, args: ["-l", binaryPath])
                result["encrypted"] = lcOutput.contains("LC_ENCRYPTION_INFO")
                result["load_commands"] = lcOutput.components(separatedBy: .newlines).filter { $0.contains("LC_") }.count
            }
        }

        // 清理临时目录
        if let tmp = tempDir {
            try? FileManager.default.removeItem(atPath: tmp)
        }

        // 注入可行性评估
        var injectNotes: [String] = []
        if let bin = result["binary"] as? [String: Any],
           let arch = bin["arch"] as? String {
            // v2.9.132：arch=unknown 是"解析failed" (可能加密/特殊头），不是"非 arm64"——
            // 不再误判不可injected (旧版 unknown 也触发此警告）
            if arch == "unknown" {
                injectNotes.append("⚠️ Mach-O parse failed (may be encrypted/obfuscated); check encryption with app.encrypt_info first, re-inspect after decrypting")
            } else if arch != "arm64" {
                injectNotes.append("⚠️ Arch \(arch), current dylib may be incompatible")
            }
        }
        if let encrypted = result["encrypted"] as? Bool, encrypted {
            injectNotes.append("⚠️ App is encrypted (App Store download), decrypt before injection")
        }
        if injectNotes.isEmpty {
            injectNotes.append("✅ Arch and signature OK, can try injection")
        }
        result["inject_feasibility"] = injectNotes

        return result
    }
}

final class DylibInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "dylib.inspect",
        summary: "Inspect a dylib file (architecture, signature, dependencies). Use for: check if a dylib is compatible before injecting. Don't use for: inject dylib (use injection.enable), inspect IPA (use ipa.inspect). Example: user says 'does this dylib work' → inspect dylib.",
        parameters: [
            "path": "Dylib file path (required)"
        ], verified: true, category: "analysis")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }

        var result: [String: Any] = ["path": path]

        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "file does not exist", "path": path]
        }

        // 文件大小
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            result["size"] = "\(size) bytes"
        }

        // 架构
        let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [path])
        result["arch"] = fileOutput.contains("arm64") ? "arm64" : (fileOutput.contains("armv7") ? "armv7" : "unknown")

        // 签名
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        if !ldidPath.isEmpty {
            let (_, entOutput) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", path])
            result["signed"] = !entOutput.isEmpty
            result["entitlements"] = String(entOutput.prefix(1000))
        }

        // 依赖
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        if FileManager.default.fileExists(atPath: otoolPath) {
            let (_, libOutput) = InjectionManager.shared.spawnRoot(otoolPath, args: ["-L", path])
            let libs = libOutput.components(separatedBy: .newlines)
                .filter { $0.contains("dylib") || $0.contains("framework") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            result["dependencies"] = Array(libs.prefix(20))
        }

        // 兼容性检查
        var issues: [String] = []
        if result["arch"] as? String != "arm64" {
            issues.append("Not arm64 arch")
        }
        if result["signed"] as? Bool == false {
            issues.append("Unsigned (ct_bypass can bypass under TrollStore)")
        }
        result["compatibility"] = issues.isEmpty ? "✅ Suitable for injection" : "⚠️ \(issues.joined(separator: "; "))"

        return result
    }
}

// MARK: - Injection diagnosis器

/// v2.9.88：读取 Mach-O 架构 (支持 thin + fat）。返回 arm64 / arm64e / armv7 / x86_64 / unknown。
private func machOArch(_ path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe), data.count >= 8 else { return "unknown" }
    let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    // 小端
    let magicLE = magic.byteSwapped
    switch magic {
    case 0xFEEDFACE:   // thin 32
        let cpu = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        return cpu == 12 ? "armv7" : (cpu == 7 ? "x86" : "cpu\(cpu)")
    case 0xFEEDFACF:   // thin 64
        let cpu = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        return cpu == 0x0100000C ? "arm64" : (cpu == 0x01000007 ? "x86_64" : "cpu\(cpu)")
    case 0xCAFEBABE, 0xBEBAFECA:  // fat (magic 大端）
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.byteSwapped
        var arches: [String] = []
        for i in 0..<min(count, 8) {
            let off = 8 + Int(i) * 20
            guard data.count >= off + 8 else { break }
            let cpu = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }.byteSwapped
            switch cpu {
            case 12: arches.append("armv7")
            case 0x0100000C: arches.append("arm64")
            case 0x0100000C | 1: arches.append("arm64e")
            case 0x01000007: arches.append("x86_64")
            default: arches.append("cpu\(cpu)")
            }
        }
        return arches.isEmpty ? "fat(?)" : "fat:" + arches.joined(separator: ",")
    default:
        return magicLE == 0xFEEDFACE || magicLE == 0xFEEDFACF ? "unknown(be)" : "unknown(\(String(magic, radix: 16)))"
    }
}

final class InjectionDiagnoseTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.diagnose",
        summary: "Diagnose why injection failed (troubleshoot). Use for: injection didn't work, find out why (app crashed, dylib not loaded, etc.). Don't use for: actually inject (use injection.enable), check status (use injection.status). Example: user says '小红书 injection failed, why' → diagnose injection failure.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "dylib_path": "Dylib path to check (optional, check existing injected)"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let dylibPath = params["dylib_path"] as? String

        var diagnosis: [String: Any] = ["bundle_id": bundleId]
        var issues: [String] = []
        var fixes: [String] = []

        // 1. 检查目标 App 是否存在
        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["error": "app not found: \(bundleId)", "hint": "use injection.list to find the target App"]
        }
        diagnosis["app_name"] = target.name
        diagnosis["bundle_path"] = target.path

        // 2. 检查 root 权限
        let probe = DeviceProbe.shared.run()
        diagnosis["root_ready"] = probe.ready
        if !probe.ready {
            issues.append("Root injection env not ready")
            fixes.append("In TrollStore, enable 'Edit Entitlements' then uninstall/reinstall")
        }

        // v2.9.88：2b. Bundle 目录真实可写性 (cp EPERM 的直接判据）——
        // 注入要把 dylib 写进 /private/var/containers/Bundle/Application/.../xxx.app，
        // 该目录归 root 所有，mobile 用户写必报 "Operation not permitted"。
        // 用内置 mkdir 以 root 身份建探针目录来验证 (包内无 touch，mkdir+rm 即可闭环）。
        let probeDir = (target.path as NSString).appendingPathComponent(".diag_probe_\(UUID().uuidString)")
        let (tCode, tOut) = InjectionManager.shared.runAsRoot("mkdir", args: ["-p", probeDir])
        let bundleWritable = (tCode == 0) && FileManager.default.fileExists(atPath: probeDir)
        if bundleWritable {
            _ = InjectionManager.shared.runAsRoot("rm", args: ["-rf", probeDir])
        }
        diagnosis["bundle_write_test"] = bundleWritable
        diagnosis["bundle_write_detail"] = bundleWritable ? "root can write the target app's Bundle directory" : "root write failed(\(tCode)): \(String(tOut.prefix(120)))"
        if !bundleWritable {
            issues.append("Target app Bundle dir not writable (injected cp will report Operation not permitted)")
            fixes.append("In TrollStore, enable 'Edit Entitlements' then uninstall/reinstall this app (over-install won't reapply permissions); or check whether the app is system-protected")
        }

        // 3. 检查目标进程是否在运行
        let pid = findPid(by: bundleId)
        diagnosis["target_pid"] = pid
        diagnosis["process_running"] = pid > 0
        if pid == 0 {
            issues.append("Target app not running (restart the app after injection to load the dylib)")
            fixes.append("Open the target app first, then run injection")
        }

        // 4. 检查 dylib
        if let dylib = dylibPath {
            diagnosis["dylib_exists"] = FileManager.default.fileExists(atPath: dylib)
            if !FileManager.default.fileExists(atPath: dylib) {
                issues.append("dylib file not found: \(dylib)")
                fixes.append("Locate the correct dylib path with artifact.find")
            } else {
                // 检查架构
                let (_, fileOutput) = InjectionManager.shared.spawnRoot("/usr/bin/file", args: [dylib])
                let isArm64 = fileOutput.contains("arm64")
                diagnosis["dylib_arch"] = isArm64 ? "arm64" : "unknown"
                if !isArm64 {
                    issues.append("dylib isn't arm64")
                    fixes.append("Recompile the dylib as arm64")
                }
            }
        }

        // 5. 检查已注入状态
        let inspect = InjectionManager.shared.inspect(bundleId)
        diagnosis["already_injected"] = inspect["injected"] as? Bool ?? false
        diagnosis["has_backup"] = inspect["hasBackup"] as? Bool ?? false
        if let injected = inspect["injected"] as? Bool, injected {
            // 检查 dylib 是否真的在 Frameworks 目录
            let frameworksDir = target.path.appending("/Frameworks")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
                diagnosis["frameworks_files"] = files.filter { $0.hasSuffix(".dylib") }
            }
        }

        // 6. 检查 Mach-O 完整性 (主二进制存在 + 备份，兼容新旧格式）
        let mainBinary = target.path.appending("/\((NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? "")")
        let mainExists = FileManager.default.fileExists(atPath: mainBinary)
        diagnosis["main_binary"] = mainBinary
        diagnosis["main_binary_exists"] = mainExists
        if !mainExists {
            issues.append("Main binary doesn't exist: \(mainBinary)")
            fixes.append("The target app is corrupted or tampered with; uninstall/reinstall it first")
        }
        // v2.9.88：主二进制架构 (与 dylib 架构做匹配校验）
        let mainArch = machOArch(mainBinary)
        diagnosis["main_binary_arch"] = mainArch
        if let dylib = dylibPath, FileManager.default.fileExists(atPath: dylib) {
            let dylibArch = machOArch(dylib)
            diagnosis["dylib_arch"] = dylibArch
            if !dylibArch.contains("arm64") {
                issues.append("dylib arch \(dylibArch) doesn't match the device (arm64 needed)")
                fixes.append("Recompile the dylib as arm64 with Theos")
            } else if mainArch.contains("arm64") && !mainArch.contains("fat") && mainArch != dylibArch {
                issues.append("dylib arch \(dylibArch) doesn't match the main binary \(mainArch)")
                fixes.append("Recompile a matching-arch dylib, or merge both archs with lipo")
            }
        }
        // v2.9.89：备份检查兼容 .troll-fools.bak (TrollFools 同款）与旧 .bak_macho
        let backupNew = mainBinary + ".troll-fools.bak"
        let backupLegacy = mainBinary + ".bak_macho"
        let hasBackup = FileManager.default.fileExists(atPath: backupNew) || FileManager.default.fileExists(atPath: backupLegacy)
        diagnosis["backup_exists"] = hasBackup
        diagnosis["backup_format"] = FileManager.default.fileExists(atPath: backupNew) ? "troll-fools.bak" : (FileManager.default.fileExists(atPath: backupLegacy) ? "bak_macho (legacy)" : "none")

        // 6b. v2.9.89：可注入目标 Mach-O 列表 (对齐 TrollFools 策略——Frameworks 内未加密优先）
        let injectable = InjectionManager.shared.collectInjectableMachOs(target)
        let fwFiles = (try? FileManager.default.contentsOfDirectory(atPath: target.path + "/Frameworks")) ?? []
        let allMachOs = [mainBinary] + fwFiles.map { target.path + "/Frameworks/\($0)" }
        var protectedCount = 0
        var totalMachOs = 0
        for m in allMachOs {
            if MachOAnalyzer.analyze(m)?.valid == true {
                totalMachOs += 1
                if MachOAnalyzer.isProtected(m) { protectedCount += 1 }
            }
        }
        diagnosis["injectable_targets"] = injectable
        diagnosis["injectable_targets_count"] = injectable.count
        diagnosis["macho_scan"] = ["total": totalMachOs, "encrypted": protectedCount, "skipped": allMachOs.count - totalMachOs]
        if injectable.isEmpty {
            issues.append("No injectable Mach-O (\(protectedCount)/\(totalMachOs) encrypted or unreadable)")
            fixes.append("Encrypted App Store apps can't be injected directly; decrypt with app.decrypt first, or use a supported target app")
        }
        if protectedCount > 0 {
            diagnosis["note"] = "⚠️ \(protectedCount) Mach-O files have encrypted segments (cryptid=1), injection would break them, auto-skipped; injection targets the unencrypted \(injectable.first.map { ($0 as NSString).lastPathComponent } ?? "none")"
        }

        // 7. 检查注入工具链
        let binaries = ["ldid", "optool", "insert_dylib", "ct_bypass"]
        var binStatus: [String: Bool] = [:]
        for bin in binaries {
            if let path = InjectionManager.shared.binaryPath(bin) {
                binStatus[bin] = FileManager.default.fileExists(atPath: path) && access(path, X_OK) == 0
            } else {
                binStatus[bin] = false
            }
        }
        diagnosis["injection_tools"] = binStatus

        // 总结
        diagnosis["issues"] = issues
        diagnosis["fixes"] = fixes
        diagnosis["verdict"] = issues.isEmpty ? "✅ Injection prerequisites OK; if still failing, check dylib dependencies" : "❌ Found \(issues.count) issues"

        return diagnosis
    }

    private func findPid(by bundleId: String) -> Int32 {
        let (_, output) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-ax"])
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
}

// MARK: - Log collection器

final class LogCollectTool: MCPTool {
    let definition = ToolDefinition(
        name: "log.collect",
        summary: "Collect app logs and crash reports for debugging. Use for: find out why app crashed, debug injection issues, see error messages. Don't use for: just checking app status (use app.launch to test), packet capture (use network.capture). Example: user says 'why does 小红书 crash' → collect crash logs and analyze.",
        parameters: [
            "bundle_id": "Target App bundle_id (optional, default TrollAgent's own logs)",
            "type": "Log type: system / crash / injection / all (default all)",
            "lines": "Max number of lines to return (default 200)"
        ],
    verified: true, category: "diagnose")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = params["bundle_id"] as? String ?? Bundle.main.bundleIdentifier ?? ""
        let type = (params["type"] as? String) ?? "all"
        let lines = (params["lines"] as? Int) ?? 200

        let workspace = NSHomeDirectory().appending("/Documents/Workspace/logs")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var collected: [String: String] = [:]

        // 系统日志
        if type == "all" || type == "system" {
            let (_, output) = InjectionManager.shared.spawnRoot("/usr/bin/log", args: ["show", "--last", "\(lines)m", "--predicate", "process == '\(bundleId)'"])
            let path = workspace.appending("/system_\(timestamp).log")
            try? output.write(toFile: path, atomically: true, encoding: .utf8)
            collected["system"] = path
        }

        // 崩溃报告
        if type == "all" || type == "crash" {
            let crashDir = NSHomeDirectory().appending("/Library/Logs/CrashReporter")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: crashDir) {
                let relevant = files.filter { $0.contains(bundleId) || $0.contains("TrollAgent") }
                for file in relevant.prefix(5) {
                    let src = crashDir.appending("/\(file)")
                    let dst = workspace.appending("/crash_\(file)")
                    try? FileManager.default.copyItem(atPath: src, toPath: dst)
                    collected["crash_\(file)"] = dst
                }
            }
        }

        // 注入日志
        if type == "all" || type == "injection" {
            let injectionLog = NSHomeDirectory().appending("/Documents/Workspace/injection.log")
            if FileManager.default.fileExists(atPath: injectionLog) {
                if let content = try? String(contentsOfFile: injectionLog) {
                    let tail = String(content.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n"))
                    let path = workspace.appending("/injection_\(timestamp).log")
                    try? tail.write(toFile: path, atomically: true, encoding: .utf8)
                    collected["injection"] = path
                }
            }
        }

        // 工具审计日志
        let auditPath = workspace.appending("/audit_\(timestamp).json")
        if let auditData = try? JSONEncoder().encode(AuditLog.shared.entries) {
            try? auditData.write(to: URL(fileURLWithPath: auditPath))
            collected["audit"] = auditPath
        }

        return [
            "bundle_id": bundleId,
            "type": type,
            "collected_files": collected,
            "output_dir": workspace,
            "count": collected.count
        ]
    }
}

// MARK: - HTTP 抓包工具

final class NetworkCaptureTool: MCPTool {
    let definition = ToolDefinition(
        name: "network.capture",
        summary: "HTTP/HTTPS packet capture (hooks NSURLSession stack). Commands: status / start / stop / requests / analyze. Params: action, bundle_id(required for start), limit. Use for: see app's network requests, analyze API calls, inspect req/resp headers, debug networking. start injects NetworkTweak into app, then use app normally and query requests. 0 hits expected for custom-network-stack apps (protobuf/gRPC/QUIC/HTTP3/TLS pinning, e.g. 小红书/抖音) — not a tool failure. Binary req/resp bodies base64-encoded.",
        parameters: [
            "action": "Action (default status): status / start / stop / requests / analyze",
            "bundle_id": "Target App bundle_id — REQUIRED for start. e.g. com.xingin.discover",
            "limit": "Max requests to show (default 50)"
        ],
        verified: true, category: "diagnose", prerequisites: ["inject enable NetworkTweak into target App before start", "start first and let the App generate network traffic before requests/analyze; 0-hits recovery + TLSHook usage come back in the result hint when needed"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "status"
        let bundleId = params["bundle_id"] as? String ?? ""
        let limit = (params["limit"] as? Int) ?? 50

        let captureDir = NSHomeDirectory().appending("/Documents/Workspace/network_capture")
        try? FileManager.default.createDirectory(atPath: captureDir, withIntermediateDirectories: true)
        // v3.1.71：抓包会话标记——start OK写入、stop 删除，用于区分"没开抓包"vs"开了没流量"
        let activeMarker = captureDir.appending("/active_session.txt")
        _ = activeMarker

        switch action {
        case "status":
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            let requestFiles = files.filter { $0.hasSuffix(".json") }
            return [
                "capture_dir": captureDir,
                "captured_sessions": requestFiles.count,
                "network_tweak_builtin": FileManager.default.fileExists(atPath: Bundle.main.path(forResource: "NetworkTweak", ofType: "dylib", inDirectory: "tweaks") ?? ""),
                "hint": "use action=start to begin capture, must inject NetworkTweak.dylib first"
            ]

        case "start":
            guard !bundleId.isEmpty else {
                return ["error": "bundle_id required for start. Usage: network.capture action:start bundle_id:com.xingin.discover"]
            }
            // 检查 NetworkTweak.dylib 是否内置
            let tweakPath = Bundle.main.path(forResource: "NetworkTweak", ofType: "dylib", inDirectory: "tweaks")
            guard let tweakPath = tweakPath, FileManager.default.fileExists(atPath: tweakPath) else {
                return [
                    "error": "NetworkTweak.dylib not bundled",
                    "hint": "will be added in a later version; for now inject another capture dylib with injection.enable"
                ]
            }
            // v2.9.116：注入前查加密 + 注入后自检
            if let app = AppCatalog.find(bundleId) {
                let exec = (NSDictionary(contentsOfFile: app.path + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
                if !exec.isEmpty, let mo = MachOAnalyzer.analyze(app.path + "/" + exec), mo.cryptID > 0 {
                    return ["action": "start", "error": "target App is encrypted (cryptid=\(mo.cryptID)), NetworkTweak cannot inject",
                            "next_step": "run app.decrypt first, then retry capture"]
                }
            }
            // injected NetworkTweak
            let result = try InjectionManager.shared.enable(bundleId: bundleId, dylibName: "@executable_path/NetworkTweak.dylib", dylibSourcePath: tweakPath)
            let injected = (result["injected"] as? Bool) ?? false
            if !injected {
                return ["action": "start", "bundle_id": bundleId, "injection_result": false,
                        "error": "NetworkTweak injection not effective (auto-rollback: see injection.disable)",
                        "next_step": "check app.encrypt_info (decrypt if encrypted) -> app.status to confirm process alive -> retry"]
            }
            // v3.1.71：注入OK——写抓包会话标记 (requests 查询靠它区分"未开始"vs"开了没流量"）
            try? "\(Date().timeIntervalSince1970) \(bundleId)".write(toFile: activeMarker, atomically: true, encoding: .utf8)
            return [
                "action": "start",
                "bundle_id": bundleId,
                "injection_result": true,
                "note": "injects into the framework carrier inside target App (does not touch encrypted main binary, compliant)",
                "hint": "after restarting target App, requests are recorded to \(captureDir). If 0 hits: target may use QUIC/private protocol or TLS encryption, NSURLSession hook misses, need a TLS hook plan"
            ]

        case "stop":
            // v3.1.71：停止——删除会话标记
            try? FileManager.default.removeItem(atPath: activeMarker)
            return [
                "action": "stop",
                "hint": "stop capture: remove NetworkTweak.dylib with injection.disable, or kill target App process"
            ]

        case "requests":
            // 读取捕获的请求
            var allRequests: [[String: Any]] = []
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            for file in files.sorted().suffix(3) {
                let path = captureDir.appending("/\(file)")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    allRequests.append(contentsOf: json)
                }
            }
            let limited = Array(allRequests.suffix(limit))
            var out: [String: Any] = [
                "action": "requests",
                "total": allRequests.count,
                "returned": limited.count,
                "requests": limited
            ]
            // v3.1.71：区分"没开抓包"vs"开了没流量" (AI 实测：未 start 时平静返回 0 条，误以为工具坏）
            if allRequests.isEmpty {
                let hasSession = FileManager.default.fileExists(atPath: activeMarker)
                if !hasSession {
                    out["warning"] = "capture not started: run network.capture action:start bundle_id:<target App> first, restart the App to generate traffic, then query"
                } else {
                    out["no_requests_reason"] = "started but 0 hits. Possible: target App not restarted / no HTTP traffic / QUIC or private protocol / TLS encryption (NSURLSession hook misses)"
                    out["next_step"] = "confirm App restarted and generating traffic; if still 0 (custom-stack apps 小红书/抖音: QUIC/protobuf/private networking): TLS layer — inject enable TLSHook (decrypts SSL_read/SSL_write to Workspace/network_capture/tls/*.log, read with artifact read), or switch to vpn.capture; not a tool fault"
                }
            }
            return out

        case "analyze":
            // Statistical analysis
            var allRequests: [[String: Any]] = []
            let files = (try? FileManager.default.contentsOfDirectory(atPath: captureDir)) ?? []
            for file in files.sorted().suffix(3) {
                let path = captureDir.appending("/\(file)")
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    allRequests.append(contentsOf: json)
                }
            }
            var methodCount: [String: Int] = [:]
            var statusCount: [String: Int] = [:]
            var hostCount: [String: Int] = [:]
            var errorRequests: [[String: Any]] = []
            for req in allRequests {
                let method = req["method"] as? String ?? "UNKNOWN"
                methodCount[method, default: 0] += 1
                if let status = req["status"] as? Int {
                    statusCount["\(status)", default: 0] += 1
                    if status >= 400 { errorRequests.append(req) }
                }
                if let url = req["url"] as? String,
                   let host = URL(string: url)?.host {
                    hostCount[host, default: 0] += 1
                }
            }
            return [
                "action": "analyze",
                "total_requests": allRequests.count,
                "methods": methodCount,
                "status_codes": statusCount,
                "top_hosts": Array(hostCount.sorted { $0.value > $1.value }.prefix(10)),
                "error_count": errorRequests.count,
                "error_requests": Array(errorRequests.prefix(20))
            ]

        default:
            return ["error": "unknown action: \(action)", "supported": ["status", "start", "stop", "requests", "analyze"]]
        }
    }
}
