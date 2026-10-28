import Foundation

// v2.9.262：就地替换已安装 App 的加密主二进制为砸壳版 (不重装、不丢数据）
// 流程：找工作区 decrypted/ 下砸壳 ipa → ZipExtractor 解压 → 取 Payload 内主二进制
//     → 备份已安装主二进制(.troll-fools.bak) → root cp 替换 → ct_bypass 重签 + chown
//     → 返回可注入状态 (cryptID 应为 0，之后 control.inject allowMain 可注入主二进制）
final class AppReplaceDecryptedTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.replace_decrypted",
        summary: "Replace app's main binary with decrypted version. Use for: after app.decrypt, replace the encrypted binary so injection works. Don't use for: decrypt IPA (use app.decrypt), inject dylib (use injection.enable). Auto-backup enabled. Example: user says 'replace decrypted main binary' → replace decrypted.",
        parameters: [
            "bundle_id": "Target app bundle ID",
            "ipa_path": "Decrypted IPA path (optional, auto-finds if not specified)"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        let im = InjectionManager.shared
        let workspace = "/var/mobile/Documents/Workspace"

        // 1. 定位砸壳 ipa
        var ipaPath = params["ipa_path"] as? String ?? ""
        if ipaPath.isEmpty {
            let decDir = workspace + "/decrypted"
            let files = (try? FileManager.default.contentsOfDirectory(atPath: decDir)) ?? []
            let cands = files.filter { $0.contains(bundleId) && $0.hasSuffix(".ipa") }.sorted()
            guard let hit = cands.last else {
                return ["ok": false, "error": "no decrypted ipa for \(bundleId) found under workspace decrypted/", "next_step": "run app.decrypt \(bundleId)"]
            }
            ipaPath = decDir + "/" + hit
        }
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            return ["ok": false, "error": "ipa does not exist: \(ipaPath)"]
        }

        // 2. 优先：直接解密主二进制到工作区 (跳过 ipa 解压——ZipStorer 对大 ipa 有写坏 bug）
        // v2.9.262：decryptMainBinaryToFile 复用启动+task_for_pid+decryptBinary，直出解密主二进制
        // v2.9.264：若 .bin 已存在且 >50MB (上次解密已OK产出），直接复用——
        // 不重新启动目标 App (启动小红书会抢前台把 TrollAgent 顶到后台被杀，实测两次中断）
        let mainOut = workspace + "/replace_main_" + bundleId.replacingOccurrences(of: ".", with: "_") + ".bin"
        var decryptedMain = ""
        if FileManager.default.fileExists(atPath: mainOut),
           let attr = try? FileManager.default.attributesOfItem(atPath: mainOut),
           (attr[.size] as? NSNumber)?.int64Value ?? 0 > 50 * 1024 * 1024 {
            decryptedMain = mainOut
        } else {
            let decRes = DecryptEngine.decryptMainBinaryToFile(bundleId: bundleId, outputPath: mainOut)
            if decRes.ok, FileManager.default.fileExists(atPath: mainOut) {
                decryptedMain = mainOut
            } else {
                // 3. 降级：解压 ipa
                let workDir = workspace + "/replace_tmp_" + bundleId.replacingOccurrences(of: ".", with: "_")
                _ = im.runAsRoot("rm", args: ["-rf", workDir])
                _ = im.runAsRoot("mkdir", args: ["-p", workDir])
                do {
                    try ZipExtractor.unzip(URL(fileURLWithPath: ipaPath), to: URL(fileURLWithPath: workDir, isDirectory: true))
                } catch {
                    return ["ok": false, "error": "direct decrypt failed: \(decRes.errorReason) and unzip ipa failed: \(error.localizedDescription)", "next_step": "keep target App in foreground then retry"]
                }
                let payloadRoot = workDir + "/Payload"
                let appDirs = (try? FileManager.default.contentsOfDirectory(atPath: payloadRoot)) ?? []
                guard let appDirName = appDirs.first(where: { $0.hasSuffix(".app") }) else {
                    return ["ok": false, "error": "no Payload/*.app after unzip", "payload": payloadRoot]
                }
                let execName2 = (NSDictionary(contentsOfFile: payloadRoot + "/" + appDirName + "/Info.plist")?["CFBundleExecutable"] as? String)
                decryptedMain = payloadRoot + "/" + appDirName + "/" + (execName2 ?? "")
            }
        }
        guard FileManager.default.fileExists(atPath: decryptedMain) else {
            return ["ok": false, "error": "decrypted main binary does not exist: \(decryptedMain)"]
        }

        // 4. 已安装主二进制 + 备份
        let exec = (NSDictionary(contentsOfFile: app.path + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
        guard !exec.isEmpty else {
            return ["ok": false, "error": "installed App Info.plist has no CFBundleExecutable"]
        }
        let installedMain = app.path + "/" + exec
        let backup = installedMain + ".troll-fools.bak"
        if !FileManager.default.fileExists(atPath: backup) {
            let (c0, o0) = im.runAsRoot("cp", args: ["-p", installedMain, backup])
            if c0 != 0 { return ["ok": false, "error": "backup main binary failed (\(c0)): \(o0)"] }
        }

        // 4.5 删除 SC_Info (对齐 TrollDecrypt：砸壳后旧 App Store 签名目录与解密二进制不匹配，
        // 残留会导致就地替换后目标 App 启动闪退——实测小红书 cryptID=0 后重启闪退无崩溃日志）
        let scInfo = app.path + "/SC_Info"
        if FileManager.default.fileExists(atPath: scInfo) {
            _ = im.runAsRoot("rm", args: ["-rf", scInfo])
        }

        // 5. 替换 + 重签
        let (c1, o1) = im.runAsRoot("cp", args: ["-p", decryptedMain, installedMain])
        if c1 != 0 { return ["ok": false, "error": "replace main binary failed (\(c1)): \(o1)"] }
        _ = im.coreTrustBypass(installedMain, teamID: im.realTeamID(for: bundleId, appPath: app.path))

        // v4.3.17 修复：完整重签整个 bundle——只重签主二进制+删 SC_Info 仍让部分 App 就地替换后启动失败
        // (-109：_CodeSignature 里其它文件 hash 与替换后主二进制不匹配)。策略：
        //   1. 从原密文主二进制 backup 提取 entitlements (保留 get-task-allow / platform 等)
        //   2. 删旧 _CodeSignature + SC_Info (签名目录与砸壳二进制不匹配)
        //   3. 对 bundle 内所有 mach-o 可执行 (主二进制 + .dylib + .framework 内二进制 + PlugIns) 用原 entitlements ldid -S 重签
        //   4. 重新 chown 33:33
        let entPath = workspace + "/replace_ent_\(bundleId.replacingOccurrences(of: ".", with: "_")).plist"
        _ = im.runAsRoot("rm", args: ["-f", entPath])
        let (ec, eo) = im.runAsRoot("ldid", args: ["-e", backup], timeout: 20)
        var entArgs = ["-S"]
        if ec == 0, !eo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? eo.data(using: .utf8)?.write(to: URL(fileURLWithPath: entPath))
            entArgs = ["-S" + entPath]
        }
        let csDir = app.path + "/_CodeSignature"
        if FileManager.default.fileExists(atPath: csDir) {
            _ = im.runAsRoot("rm", args: ["-rf", csDir])
        }
        // 枚举所有可执行文件并重签
        let (fc, fo) = im.runAsRoot("find", args: [app.path, "-type", "f"], timeout: 40)
        if fc == 0 {
            for f in fo.split(separator: "\n").map(String.init) {
                let ext = (f as NSString).pathExtension
                let isMachO = f == installedMain || ext == "dylib" || ext == "framework" ||
                              f.contains("/PlugIns/") || f.hasSuffix(".appex/") || ext == "appex" ||
                              (f.contains("/Frameworks/"))
                if isMachO {
                    _ = im.runAsRoot("ldid", args: entArgs + [f], timeout: 20)
                }
            }
        }
        _ = im.runAsRoot("chown", args: ["33:33", installedMain])

        // 6. 验证 cryptID
        let mo = MachOAnalyzer.analyze(installedMain)
        AppCatalog.invalidateCache()
        return [
            "ok": true,
            "message": "main binary replaced in place with decrypted version (data container kept, no reinstall)",
            "data": [
                "bundle_id": bundleId,
                "installed_main": installedMain,
                "backup": backup,
                "cryptID": (mo?.cryptID).map { Int($0) } ?? -1,
                "valid": mo?.valid ?? false,
                "arch": mo?.arch ?? "",
                "injectable": (mo?.cryptID ?? 1) == 0,
                "next_step": (mo?.cryptID ?? 1) == 0 ? "inject main binary with control.inject -> app.restart -> verify 4789" : "cryptID still non-zero, replacement may have failed"
            ]
        ]
    }
}

// v2.9.128：应用解密 (砸壳）工具 —— 引擎实现在 DecryptEngine.swift
// 原理 (对齐 TrollDecrypt 全量算法）：
//   启动目标 App → task_for_pid → task_info(TASK_DYLD_INFO) 遍历 dyld 镜像
//   → 找主二进制加载地址 → 读 LC_ENCRYPTION_INFO_64 → mach_vm_read_overwrite
//   从进程内存读解密段 → 重建镜像并清 cryptid → 处理 Frameworks → 打包 IPA
// failed四分类 (CLI 协议）：env (权限/环境）/ target (App/进程/启动）/ param / tool (解析/打包）

final class AppDecryptTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.decrypt",
        summary: "Decrypt/dump an encrypted app to get decrypted IPA. Use for: get decrypted IPA for main binary injection. Don't use for: check if encrypted (use app.encrypt_info), inject dylib (use injection.enable). Prerequisite: app must be running. Example: user says '小红书 is encrypted, decrypt it first' → dump decrypted IPA.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "output_name": "Output file name (optional, default: app name)"
        ],
        verified: true, category: "app_control", prerequisites: ["App installed (confirm bundle_id with app status)", "App launched (app.launch first, then decrypt)"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let outputName = params["output_name"] as? String

        AuditLog.shared.log("app.decrypt", detail: bundleId)
        let r = DecryptEngine.decryptApp(bundleId: bundleId, outputName: outputName)

        guard r.ok else {
            return [
                "ok": false,
                "error": [
                    "code": r.errorCode,
                    "reason": r.errorReason,
                    "next_step": r.nextStep
                ],
                "bundle_id": bundleId,
                "pid": r.pid,
                "launch_errors": r.launchErrors
            ]
        }

        return [
            "ok": true,
            "message": "decrypt done: \(r.outputName)",
            "data": [
                "bundle_id": bundleId,
                "pid": r.pid,
                "output_path": r.outputPath,
                "output_name": r.outputName,
                "decrypted_binaries": r.decryptedBinaries,
                "crypt_info": r.cryptInfo,
                "launch_errors": r.launchErrors,
                "diag": r.diag
            ]
        ]
    }
}

// v2.9.128：查看 App 加密状态工具 (增强）
// 目标 App 正在运行时：直接进进程读 LC_ENCRYPTION_INFO_64，返回精确 cryptid/cryptoff/cryptsize
// 未运行时：otool -l 解析，且区分"解析failed (加密/特殊 mach-o）"vs"确实未加密"
final class AppEncryptInfoTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.encrypt_info",
        summary: "Check if app is encrypted / DRM protected. Use for: before injecting dylib into app, check if main binary is encrypted (FairPlay). If encrypted, need app.decrypt first. If not encrypted, can inject directly. Don't use for: decrypting app (use app.decrypt), listing apps (use injection.list).",
        parameters: [
            "bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover"
        ],
        verified: true, category: "app_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }

        let apps = AppCatalog.list()
        guard let target = apps.first(where: { $0.bundleId == bundleId }) else {
            return ["ok": false, "error": ["code": "target", "reason": "app not found: \(bundleId)",
                    "next_step": "use injection.list to find target App bundle_id"]]
        }

        let plistPath = target.path.appending("/Info.plist")
        let plist = NSDictionary(contentsOfFile: plistPath)
        let executable = (plist?["CFBundleExecutable"] as? String) ?? target.name
        let binaryPath = target.path.appending("/\(executable)")

        // 方式 A：进程内精确解析 (App 正在运行）
        var pid = findPidFor(by: bundleId)
        var processInfo: [String: Any] = [:]
        if pid > 0 {
            var task: UInt32 = 0
            let kr = DeviceProbe.shared.tm_task_for_pid(DeviceProbe.shared.tm_mach_task_self(), pid, &task)
            if kr == 0, task != 0 {
                defer { DeviceProbe.shared.tm_mach_port_deallocate(DeviceProbe.shared.tm_mach_task_self(), task) }
                if let loadAddr = DecryptEngine.findImageLoadAddress(task: task, pid: pid, binaryPath: binaryPath) {
                    if let enc = DecryptEngine.readEncryptionInfo(task: task, loadAddress: loadAddr) {
                        processInfo = [
                            "pid": pid,
                            "load_address": String(format: "0x%llx", loadAddr),
                            "cryptid": enc.cryptid,
                            "cryptoff": enc.cryptoff,
                            "cryptsize": enc.cryptsize,
                            "encrypted": enc.cryptid != 0
                        ]
                    } else {
                        processInfo = ["pid": pid, "parse_error": "failed to read Mach-O load commands"]
                    }
                } else {
                    processInfo = ["pid": pid, "parse_error": "dyld image table did not find main binary"]
                }
            } else {
                processInfo = ["pid": pid, "task_for_pid_error": "kern_return=\(Int(kr))"]
            }
        }

        // 方式 B：otool 静态解析 (未运行或需要二次确认）
        let otoolPath = Bundle.main.path(forResource: "otool", ofType: nil, inDirectory: "bin") ?? "/usr/bin/otool"
        var staticInfo: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: otoolPath) {
            // v2.9.126：只取 stdout——otool 警告/错误在 stderr，不混入解析结果
            let out = InjectionManager.shared.spawnRootDetailed(otoolPath, args: ["-l", binaryPath], timeout: 60).stdout
            if out.contains("LC_ENCRYPTION_INFO") {
                // 提取 cryptid/cryptoff/cryptsize 具体值
                var cryptid: Int32 = -1
                var cryptoff: Int32 = -1
                var cryptsize: Int32 = -1
                let lines = out.components(separatedBy: .newlines)
                for i in 0..<lines.count {
                    let line = lines[i]
                    if line.contains("cryptid") {
                        cryptid = extractInt(line, "cryptid")
                    } else if line.contains("cryptoff") {
                        cryptoff = extractInt(line, "cryptoff")
                    } else if line.contains("cryptsize") {
                        cryptsize = extractInt(line, "cryptsize")
                    }
                }
                staticInfo = ["has_encryption_cmd": true, "cryptid": cryptid,
                              "cryptoff": cryptoff, "cryptsize": cryptsize,
                              "encrypted": cryptid == 1]
            } else if out.contains("LC_ENCRYPTION") {
                staticInfo = ["has_encryption_cmd": true, "parse_error": "encryption command present but otool output format abnormal"]
            } else {
                staticInfo = ["has_encryption_cmd": false, "cryptid": 0, "encrypted": false]
            }
        } else {
            staticInfo = ["otool": "not_found"]
        }

        // 签名检查
        let ldidPath = InjectionManager.shared.binaryPath("ldid") ?? ""
        var signInfo = "unknown"
        if !ldidPath.isEmpty {
            // v2.9.126：只取 stdout——ldid 的 plist 解析错误在 stderr，不再误判"无签名"
            let output = InjectionManager.shared.spawnRootDetailed(ldidPath, args: ["-e", binaryPath], timeout: 30).stdout
            signInfo = output.isEmpty ? "no signature info" : "signed"
        }

        return [
            "ok": true,
            "data": [
                "bundle_id": bundleId,
                "app_name": target.name,
                "bundle_path": target.path,
                "binary_path": binaryPath,
                "version": plist?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": plist?["CFBundleVersion"] as? String ?? "unknown",
                "signature_status": signInfo,
                "process_info": processInfo,
                "static_info": staticInfo,
                "conclusion": conclusion(processInfo: processInfo, staticInfo: staticInfo)
            ]
        ]
    }

    private func conclusion(processInfo: [String: Any], staticInfo: [String: Any]) -> String {
        if let pid = processInfo["pid"] as? Int32, pid > 0 {
            if let enc = processInfo["encrypted"] as? Bool {
                return enc ? "Running process detected as encrypted (cryptid=1), use app.decrypt to decrypt" : "Running process confirmed unencrypted (cryptid=0), no decryption needed"
            }
            if let _ = processInfo["parse_error"] {
                return "Process parsing failed (may be encrypted + anti-debug interception), static result in static_info"
            }
        }
        if let enc = staticInfo["encrypted"] as? Bool {
            return enc ? "Static check: encrypted (cryptid=1), launch the target app and use app.decrypt" : "Static check: unencrypted (already decrypted or sideloaded)"
        }
        if let _ = staticInfo["parse_error"] {
            return "Static parsing error (may be an encrypted binary or special Mach-O), launch the app and try app.decrypt in-process"
        }
        return "otool unavailable, can't judge statically; recheck with app.encrypt_info after launching the app (in-process parsing)"
    }

    private func extractInt(_ line: String, _ key: String) -> Int32 {
        let parts = line.components(separatedBy: key)
        guard parts.count > 1 else { return -1 }
        let rest = parts[1]
        // 跳过非数字，取第一个数字串
        var digits = ""
        for ch in rest {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Int32(digits) ?? -1
    }

    /// v2.9.184：改 libproc 枚举 (TrollStore 无 shell 环境 ps 不可用，实测 running 恒 false）
    private func findPidFor(by bundleId: String) -> Int32 {
        if let entry = AppCatalog.find(bundleId) {
            let exePath = entry.path + "/" + entry.execName
            let pid = findPidByExecutable(bundlePath: exePath)
            if pid > 0 { return pid }
            let pid2 = findPidByExecutable(bundlePath: entry.path)
            if pid2 > 0 { return pid2 }
        }
        let output = InjectionManager.shared.spawnRootDetailed("/bin/ps", args: ["-ax"], timeout: 30).stdout
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
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

// MARK: - v4.3.19: 改包名 + 注入 dylib + TrollStore 静默安装为独立新 App
/// 适用 App Store 原装 App：iOS 只加载加密原版，就地替换无效。
/// 方案：解压砸壳 ipa → 改 CFBundleIdentifier/Name → insert_dylib 给主二进制加 dylib
/// load command → 拷 dylib → 打包 ipa → trollstorehelper 安装成新 bundle_id 的独立 App。
final class AppInjectPackageTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.inject_package",
        summary: "Rename bundle + inject dylib + repack + silent TrollStore install into a separate new app (doesn't touch the original). For App Store original apps (in-place replacement won't work). Flow: unpack decrypted ipa → change CFBundleIdentifier→new_bundle_id → insert_dylib adds a dylib load command to the main binary → copy dylib → repack ipa → trollstorehelper install. Params: ipa_path(source decrypted ipa), dylib_path (your dylib's absolute path, e.g. MyHook.dylib), new_bundle_id (new bundle id, e.g. com.trollagent.mypatched), new_name (display name, optional), auto_install (default true).Example: app inject_package ipa_path:/var/mobile/Documents/Workspace/decrypted/xxx.ipa dylib_path:/var/mobile/Documents/Workspace/MyHook.dylib new_bundle_id:com.trollagent.mypatched",
        parameters: [
            "ipa_path": "Absolute path of the source decrypted ipa (required)",
            "dylib_path": "Absolute path of the dylib to inject (required)",
            "new_bundle_id": "New bundle id (required, e.g. com.trollagent.jinx)",
            "new_name": "Display name (optional)",
            "auto_install": "Whether to install via TrollStore (default true)"
        ], verified: true, category: "app_control", prerequisites: ["ipa and dylib paths must exist (confirm with shell.exec ls first)", "new_bundle_id must not conflict with an installed app", "TrollStore installed (trollstorehelper available)"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let ipaPath = params["ipa_path"] as? String, !ipaPath.isEmpty else { throw MCPError.invalidParams("ipa_path required") }
        guard let dylibPath = params["dylib_path"] as? String, !dylibPath.isEmpty else { throw MCPError.invalidParams("dylib_path required") }
        guard let newBid = params["new_bundle_id"] as? String, !newBid.isEmpty else { throw MCPError.invalidParams("new_bundle_id required") }
        guard FileManager.default.fileExists(atPath: ipaPath) else { return ["ok": false, "error": "ipa not found: \(ipaPath)"] }
        guard FileManager.default.fileExists(atPath: dylibPath) else { return ["ok": false, "error": "dylib not found: \(dylibPath)"] }
        let newName = params["new_name"] as? String
        let autoInstall = (params["auto_install"] as? Bool) ?? true
        let im = InjectionManager.shared
        let ws = "/var/mobile/Documents/Workspace"
        var workDir = ws + "/inject_pkg_" + String(Int(Date().timeIntervalSince1970))

        // 1. 解压砸壳 ipa (优先 App 内置 python3 真解压大 ipa, 失败回退 ZipExtractor)
        //    若 ipa_path 已是一个含 Payload 的解压目录则直接复用 (跳过解压)
        if FileManager.default.fileExists(atPath: ipaPath + "/Payload") {
            workDir = ipaPath
        } else {
            try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
            let py = "import zipfile,os; zipfile.ZipFile('\(ipaPath)').extractall('\(workDir)')"
            let (pc, po) = InjectionManager.shared.spawn("/usr/bin/python3", args: ["-c", py], timeout: 180)
            let payloadOK = FileManager.default.fileExists(atPath: workDir + "/Payload")
            if pc != 0 || !payloadOK {
                do { try ZipExtractor.unzip(URL(fileURLWithPath: ipaPath), to: URL(fileURLWithPath: workDir, isDirectory: true)) }
                catch { return ["ok": false, "error": "unzip failed: \(error.localizedDescription)", "python_unzip": String(po.prefix(200))] }
            }
        }
        let payload = workDir + "/Payload"
        guard let apps = try? FileManager.default.contentsOfDirectory(atPath: payload),
              let appDirName = apps.first(where: { $0.hasSuffix(".app") }) else {
            return ["ok": false, "error": "no Payload/*.app after unzip", "payload": payload]
        }
        let appPath = payload + "/" + appDirName

        // 2. 改 Info.plist (CFBundleIdentifier → new_bundle_id)
        guard let plist = NSMutableDictionary(contentsOfFile: appPath + "/Info.plist") else {
            return ["ok": false, "error": "Info.plist unreadable"]
        }
        plist["CFBundleIdentifier"] = newBid
        if let n = newName, !n.isEmpty { plist["CFBundleName"] = n; plist["CFBundleDisplayName"] = n }
        guard plist.write(toFile: appPath + "/Info.plist", atomically: true) else {
            return ["ok": false, "error": "Info.plist write failed"]
        }
        let exec = (plist["CFBundleExecutable"] as? String) ?? ""
        guard !exec.isEmpty else { return ["ok": false, "error": "no CFBundleExecutable in Info.plist"] }
        let mainBin = appPath + "/" + exec

        // 3. insert_dylib 给主二进制加 dylib load command (幂等：已含同名则跳过)
        let dylibName = (dylibPath as NSString).lastPathComponent
        let iname = "@executable_path/" + dylibName
        let preLoads = MachOAnalyzer.analyze(mainBin)?.dylibs ?? []
        var insertMsg = "skip (load command already present)"
        if !preLoads.contains(iname) {
            let (c1, o1) = im.runAsRoot("insert_dylib", args: [iname, mainBin, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"])
            if c1 != 0 { return ["ok": false, "error": "insert_dylib failed(\(c1)): \(o1)", "next": "check dylib arch/签名"] }
            insertMsg = "injected"
        }
        // v4.3.23：insert_dylib 后真实验证 load command (报 injected 但可能没写入 → 立即暴露)
        let postLoads = MachOAnalyzer.analyze(mainBin)?.dylibs ?? []
        let injectedOK = postLoads.contains(iname)
        insertMsg = injectedOK ? "injected" : "injected_verify_failed"
        if !injectedOK {
            return ["ok": false, "error": "insert_dylib did not add load command",
                    "pre_loads": preLoads, "post_loads": postLoads, "insert_out": "exit0"]
        }

        // 4. 拷 dylib 到 app 根目录 (幂等: 目标已存在同大小则跳过, 避免 runAsRoot cp 对已注入目录失败)
        let destDylib = appPath + "/" + dylibName
        let srcSize = (try? FileManager.default.attributesOfItem(atPath: dylibPath)[.size] as? Int) ?? -1
        let dstSize = (try? FileManager.default.attributesOfItem(atPath: destDylib)[.size] as? Int) ?? -2
        if srcSize != dstSize {
            let (c2, o2) = im.runAsRoot("cp", args: ["-p", dylibPath, destDylib])
            if c2 != 0 {
                // spawnRoot 失败兜底: 用 TrollRuntimeEngine(Alpine cp, 工作区内路径) 
                let altR = TrollRuntimeEngine.exec("cp -f '\(dylibPath)' '\(destDylib)'", timeout: 90)
                if !FileManager.default.fileExists(atPath: destDylib) {
                    return ["ok": false, "error": "copy dylib failed(\(c2)): \(o2)", "alt": String(altR.output.prefix(200))]
                }
            }
        }

        // 5. 打包 ipa (含 Payload/ 顶层) —— ZipStorer Swift 原生 (iOS 路径, 不依赖系统 zip / guest 挂载)
        let outIpa = ws + "/" + newBid + ".ipa"
        _ = try? FileManager.default.removeItem(atPath: outIpa)
        guard ZipStorer.createZip(at: outIpa, fromDirectory: workDir),
              FileManager.default.fileExists(atPath: outIpa),
              (try? FileManager.default.attributesOfItem(atPath: outIpa)[.size] as? Int) ?? 0 > 0 else {
            return ["ok": false, "error": "repack ipa failed", "workdir": workDir, "ipa": outIpa]
        }
        let diag: [String: Any] = ["new_bundle_id": newBid, "app": appDirName,
                                   "load_command": iname, "dylib": dylibName,
                                   "insert": insertMsg, "ipa": outIpa, "workdir": workDir]

        // 6. TrollStore 静默安装
        if autoInstall {
            let tsPath = AppCatalog.list().first { $0.bundleId == "com.opa334.TrollStore" }?.path ?? ""
            var helper = tsPath.isEmpty ? "/var/usr/bin/trollstorehelper" : tsPath + "/trollstorehelper"
            if !FileManager.default.fileExists(atPath: helper) {
                let candidates = [tsPath + "/trollstorehelper", tsPath + "/TrollStore.app/trollstorehelper",
                                  (tsPath as NSString).deletingLastPathComponent + "/trollstorehelper"]
                helper = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? helper
            }
            let (c, out) = im.spawnRoot(helper, args: ["install", "installd", "force", outIpa], timeout: 240)
            // v4.3.24: 184=app has additional encrypted binaries (子 framework 加密由系统解密, 非致命, 安装成功) 182=developer mode
            if c != 0 && c != 184 && c != 182 { return ["ok": false, "message": "install failed(\(c)): \(String(out.prefix(400)))", "data": diag] }
            return ["ok": true, "message": c == 0 ? "install OK, independent new App \(newBid)" : "installed \(newBid) (exit=\(c): \(c == 184 ? "sub-binary encrypted, decrypted by system, non-fatal" : "developer mode"))",
                    "data": diag, "install_output": String(out.prefix(600))]
        }
        return ["ok": true, "message": "ipa ready (auto_install=false, not installed)", "data": diag]
    }
}
