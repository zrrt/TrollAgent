//
//  InstallTools.swift
//  v4.3.65：统一工具安装入口 —— AI 自动搜索并安装工具/依赖的闭环
//
//  tool.install：AI 想要某个工具时一键安装：
//    1. 已就绪？—— 内置原生 iOS bin（Resources/bin）/ Alpine 已有
//    2. Alpine 包（apk add，即装即用，可 bind 直读 iOS 文件）
//    3. 原生 iOS 二进制 → 触发 CI 交叉编译（build-tool.yml）→ github.download_artifact 取产物
//  env.setup_re：一键逆向工具链（逆向 iOS/App/IPA 常用 Alpine 工具批装）
//

import Foundation

final class ToolInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.install",
        summary: "Unified tool installation entry. Params: name(tool name) / profile(re=reverse-eng, dev=development, network=batch) / source(native iOS binary GitHub repo URL, triggers CI build-tool.yml). Install chain: Alpine apk (install-and-use) → pip → CI. Use for: one-click install when AI lacks a tool. Tweaks via github.trigger_build; dylibs via inject.",
        parameters: [
            "name": "Tool name to install (e.g. jq / jtool2 / class-dump)",
            "profile": "Optional curated batch: re(reverse-eng toolchain) / dev(dev environment) / network(networking tools)",
            "source": "Optional GitHub repo URL for native iOS CI build (e.g. https://github.com/Neurotycho/jtool2)"
        ],
        verified: true, category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // 1. profile 批量安装
        if let profile = params["profile"] as? String {
            let p = profile.lowercased().trimmingCharacters(in: .whitespaces)
            if let batch = Self.profiles[p] {
                return installBatch(batch, profile: p)
            }
            // 未知 profile：不直接报错——AI 可能把 pandas 这类包名误传成 profile，
            // 把它当作普通工具名继续走 name 安装流程。
            var sub = params
            sub["profile"] = nil
            sub["name"] = p
            return installByName(p, params: sub)
        }
        guard let rawName = params["name"] as? String else {
            throw MCPError.invalidParams("name or profile required")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw MCPError.invalidParams("name required") }
        return installByName(name, params: params)
    }

    // MARK: - 按名单个安装（内置 → Alpine apk → pip → CI）

    private func installByName(_ name: String, params: [String: Any]) -> [String: Any] {
        // 1. 已就绪？——内置原生 bin / Alpine 已有
        // v4.4.9-fix3bv: 就绪≠可用——二进制存在/apk exit 0 都可能是"装了但调不动/输出不可见"
        // (pandas 误报、python3/r2 空输出、BusyBox tree 缺参数)。统一冒烟：命令名调 --version/-v/--help/-h，
        // 验证 exit 0 且输出可见；异常则在 hint 里明确提示（不静默报 ready）。
        if let bundled = bundledBinPath(name) {
            let (ok, note) = smokeTest(name)
            return ["ok": true, "tool": name, "status": "ready", "source": "builtin_native", "path": bundled,
                    "hint": "App-bundled native iOS binary; " + note]
        }
        let which = TrollRuntimeEngine.exec("which \(name) 2>/dev/null", timeout: 30)
        if which.exitCode == 0 {
            let path = which.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? name
            let (ok, note) = smokeTest(name)
            return ["ok": true, "tool": name, "status": ok ? "ready" : "unverified", "source": "alpine", "path": path,
                    "hint": "Already present in the unified env; commands referencing iOS paths auto-bind for direct read (/ios_workspace, /ios_containers, /ios_system read-only). " + note]
        }

        // 2. Alpine apk 安装：依次尝试候选包名（映射名 / 原名 / py3-xxx）。
        //    v4.3.69：统一走 TrollRuntimeEngine.apkAdd（自动切国内镜像源 + 补 ca-certificates，修官方源
        //    在手机网络被断导致索引拉不下→误报 no such package；大包 240s 超时，避免 20s 被掐）
        var lastApkErr = ""
        for pkg in apkCandidates(for: name) {
            // v4.3.75：进度条 + 失败结构化诊断
            InstallationRegistry.shared.start(key: pkg)
            let apk = TrollRuntimeEngine.apkAdd([pkg], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if apk.exitCode == 0 {
                InstallationRegistry.shared.finish(ok: true, summary: "Installed \(pkg)")
                let isPy = pkg.hasPrefix("py3-") || Self.pythonHints.contains(name)
                let (ok, note) = smokeTest(name, importMode: isPy)
                return ["ok": true, "tool": name, "status": ok ? "installed" : "installed_unverified", "source": "alpine_apk", "package": pkg,
                        "hint": "apk add \(pkg) done (" + note + "). Just call `\(name) <args>` — runs in the unified env (TrollRuntime) with auto-bind direct read of iOS paths (e.g. \(name) /var/mobile/xxx auto-rewritten to /ios_mobile/xxx); missing deps auto-filled on first call. If the smoke test fails: first `\(name) --help` for usage; still no output, verify with file redirection (`\(name) ... > /tmp/x; cat /tmp/x`)"]
            }
            InstallationRegistry.shared.finish(ok: false, summary: TrollRuntimeEngine.installDiagnose(apk.output, timedOut: apk.timedOut, exitCode: apk.exitCode))
            lastApkErr = apk.output
            // 「找不到包」才继续试下一个候选；网络/磁盘等错误也继续，最终由兜底提示
        }
        let pkgNotFound = lastApkErr.contains("unable to select package") || lastApkErr.contains("No such package")

        // 3. Python 包回退：确保 python3 + pip，再 pip install
        if Self.pythonHints.contains(name) || name.hasPrefix("py-") {
            InstallationRegistry.shared.start(key: "python3 py3-pip")
            let apkPy = TrollRuntimeEngine.apkAdd(["python3", "py3-pip"], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if apkPy.exitCode != 0 {
                let diag = TrollRuntimeEngine.installDiagnose(apkPy.output, timedOut: apkPy.timedOut, exitCode: apkPy.exitCode)
                InstallationRegistry.shared.finish(ok: false, summary: diag)
                return ["ok": false, "tool": name, "status": "failed", "source": "alpine_apk",
                        "error": "python3/pip install failed", "hint": diag]
            }
            let pipName = name.hasPrefix("py-") ? String(name.dropFirst(3)) : name
            InstallationRegistry.shared.start(key: "pip install \(pipName)")
            // v4.4.9-fix3ca: pip 换清华镜像(国内快/稳，官方源慢断)+内部超时——Alpine pip 装包不再卡
            let pip = TrollRuntimeEngine.exec("pip install --break-system-packages --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple --timeout 60 \(pipName)", timeout: 480) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            if pip.exitCode == 0 {
                InstallationRegistry.shared.finish(ok: true, summary: "pip installed \(pipName)")
                let (ok, note) = smokeTest(pipName, importMode: true)
                return ["ok": true, "tool": name, "status": ok ? "installed" : "installed_unverified", "source": "pip",
                        "hint": "pip install \(pipName) done (" + note + "). Unified-env python3 (Alpine) — apk/pip packages directly visible and usable; for C-extension packages prefer apk's py3- prebuilt (better performance)"]
            }
            InstallationRegistry.shared.finish(ok: false, summary: TrollRuntimeEngine.installDiagnose(pip.output, timedOut: pip.timedOut, exitCode: pip.exitCode))
            lastApkErr = pip.output
        }

        // 4. 原生 iOS 二进制 → CI 交叉编译（build-tool.yml）
        if pkgNotFound || Self.nativeRegistry.keys.contains(name) || params["source"] != nil {
            let source = (params["source"] as? String) ?? Self.nativeRegistry[name]?.source
            if let src = source, !src.isEmpty {
                guard let token = GHConfig.activeToken else {
                    return ["ok": false, "tool": name, "status": "ci_blocked",
                            "error": "Not an Alpine package and not logged into GitHub (can't trigger CI cross-compile)",
                            "hint": "Native iOS binaries only come through three channels: bundled bin / CI cross-compile (github.trigger_build) / custom dylib (inject load_dylib). Log in under Settings-GitHub account first, then retry"]
                }
                var body: [String: Any] = ["ref": GHConfig.branch]
                body["inputs"] = ["name": name, "source": src]
                let (code, json) = GHAPI.post(
                    "\(GHConfig.apiBase)/repos/\(GHConfig.repoOwner)/\(GHConfig.repoName)/actions/workflows/build-tool.yml/dispatches",
                    token: token, body: body)
                if code == 204 {
                    return ["ok": true, "tool": name, "status": "ci_triggered", "workflow": "build-tool.yml", "source": src,
                            "next": "Check progress with github.fetch_runs after tens of seconds; on success fetch the artifact with github.download_artifact (unpacked at Workspace/downloads/run_<id>/）",
                            "note": "best-effort: Makefile-type projects can be cross-compiled directly; if artifact is empty, cross-compile on a PC or write a custom dylib"]
                }
                return ["ok": false, "tool": name, "status": "ci_failed", "http_status": code,
                        "message": (json?["message"] as? String) ?? "trigger failed"]
            }
        }

        // 5. 兜底指引
        return ["ok": false, "tool": name, "status": "not_found",
                "hint": "Not an apk package (tried \(apkCandidates(for: name).joined(separator: "/"))). Options: ① tool.install profile:re (reverse-eng toolchain batch); ② provide a source repo URL for CI cross-compile (native iOS binaries); ③ shell.exec('apk search \(name)') to find similar package names; ④ write a custom tool with inject load_dylib"]
    }

    /// Alpine 候选包名：映射名 → 原名 → py3-xxx（Python 包在 Alpine 多为 py3- 前缀）
    /// v4.4.9-fix3bv: 冒烟测试——命令名调用 --version/-v/--help/-h，验证 exit 0 且输出可见。
    /// 治"装了但不可用"：apk exit 0 但包没进当前环境（pandas 误报）、stdout 缓冲空输出（python3/r2）、
    /// 精简版缺参数（BusyBox tree -L）。返回 (ok, 可读说明)。
    private func smokeTest(_ name: String, importMode: Bool = false) -> (ok: Bool, note: String) {
        // python 包（pip/apk py3- 装的）：包只在统一环境 python3（Alpine）可见——import 验证；
        // 重计算（numpy/pandas 深度运算）显式 py3-native（原生芯片直跑）——两者共享 Workspace 文件流转
        if importMode {
            let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
            do {
                let r = try ShellExecTool().invoke(["command": "sh -c 'python3 -c \"import \(safe); print(\"IMPORT_OK \" + \(safe).__name__)\"'", "timeout": 30])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = r["exit_code"] as? Int ?? 1
                if exit == 0 && out.contains("IMPORT_OK") {
                    return (true, "Alpine python smoke `import \(safe)` OK (" + String(out.prefix(60)) + ") — unified-env python3 (Alpine) — apk packages directly visible and usable")
                }
                let errNote = out.isEmpty ? "no output" : String(out.prefix(80))
                return (false, "Alpine python `import \(safe)` failed (exit \(exit): " + errNote + ") — the package may not be installed into unified-env python3, or a C extension doesn't run in the interpreter — for heavy compute use explicit py3-native (native numpy/pandas bundled), for light packages use apk py3-xxx")
            } catch {
                return (false, "Alpine python `import \(safe)` smoke-test error: \(error)")
            }
        }
        for flag in ["--version", "-v", "--help", "-h"] {
            do {
                let r = try ShellExecTool().invoke(["command": "\(name) \(flag)", "timeout": 20])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = r["exit_code"] as? Int ?? 1
                if exit == 0 && !out.isEmpty {
                    let first = out.split(separator: "\n").first.map(String.init) ?? ""
                    return (true, "Smoke `\(name) \(flag)` OK (" + String(first.prefix(90)) + ")")
                }
                if exit == 0 && out.isEmpty {
                    return (false, "Smoke `\(name) \(flag)` exited 0 but no output — stdout buffering/capture issue, the tool may be installed but results invisible; if output is empty after the call, verify with `> /tmp/x; cat /tmp/x` redirection")
                }
            } catch { }
        }
        return (false, "Smoke `\(name) --version/-v/--help/-h` all failed — the tool may be installed but not invocable, or has no version/help flag; first try `\(name) --help` for the real usage")
    }

    private func apkCandidates(for name: String) -> [String] {
        var out: [String] = []
        if let mapped = Self.alpineNameMap[name] { out.append(mapped) }
        out.append(name)
        if name != "python" && name != "python3" && !name.hasPrefix("py3-") {
            out.append("py3-\(name)")
        }
        var seen = Set<String>(); return out.filter { seen.insert($0).inserted }
    }

    // MARK: - 批量安装（profile）

    private func installBatch(_ pkgs: [String], profile: String) -> [String: Any] {
        var results: [[String: Any]] = []
        var okCount = 0
        for pkg in pkgs {
            // v4.3.77：用户已停止 → 跳出，不再装剩余包
            if ConversationStore.shared.stopRequested { break }
            // v4.3.77：批量安装也走进度条（每包独立进度），不再静默
            InstallationRegistry.shared.start(key: pkg)
            let r = TrollRuntimeEngine.apkAdd([pkg], timeout: 240) { line in
                InstallationRegistry.shared.appendLine(line)
            }
            let ok = r.exitCode == 0
            if ok { okCount += 1 }
            InstallationRegistry.shared.finish(ok: ok,
                summary: ok ? "Installed \(pkg)" : TrollRuntimeEngine.installDiagnose(r.output, timedOut: r.timedOut, exitCode: r.exitCode))
            let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(2).joined(separator: "\n")
            results.append(["package": pkg, "ok": ok, "detail": detail])
        }
        return ["ok": okCount == pkgs.count, "profile": profile,
                "installed": okCount, "total": pkgs.count, "results": results,
                "hint": "Installed an Alpine (Linux) tool: can bind-read iOS files, but can't compile/inject native iOS binaries (those go through tool.install name:jtool2 triggering CI)"]
    }

    // MARK: - 查找内置原生 bin

    /// v4.3.69：修复 pandas 等包被误判"内置已就绪"的 bug——实测 isExecutableFile 对【目录】
    /// 也返回 true，会把 bin 目录误当内置二进制而短路安装流程。修复：①必须存在且非目录才命中；
    /// ②Python 包（pythonHints / py3- 映射）根本不走内置检查（内置 bin 只有 iOS 原生工具，无 Python 包）。
    private func bundledBinPath(_ name: String) -> String? {
        if Self.pythonHints.contains(name)
            || Self.alpineNameMap[name]?.hasPrefix("py3-") == true {
            return nil
        }
        let roots = [
            Bundle.main.bundlePath + "/Resources/bin",
            Bundle.main.bundlePath + "/bin"
        ]
        for root in roots {
            let candidates = [
                root + "/" + name,
                root + "/" + name + "_ios",
                root + "/" + name + "-ios"
            ]
            for c in candidates {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir),
                      !isDir.boolValue,
                      FileManager.default.isExecutableFile(atPath: c) else { continue }
                return c
            }
        }
        return nil
    }

    // MARK: - 静态数据

    /// 常用工具名 → Alpine 包名映射（nm/strings 等常见名在 Alpine 里归属 binutils）
    private static let alpineNameMap: [String: String] = [
        "nm": "binutils", "strings": "binutils", "objdump": "binutils", "readelf": "binutils",
        "python": "python3", "sqlite3": "sqlite", "7z": "7zip",  // v4.3.77: Alpine 包名 7zip
        "node": "nodejs", "make": "make", "cmake": "cmake",
        "nc": "netcat-openbsd", "dig": "bind-tools", "nslookup": "bind-tools",
        "tcpdump": "tcpdump", "nmap": "nmap", "wget": "wget",
        "xxd": "xxd", "tree": "tree", "vim": "vim", "gawk": "gawk",
        "zip": "zip", "unzip": "unzip", "xz": "xz", "file": "file",
        "curl": "curl", "git": "git", "jq": "jq", "openssl": "openssl",
        "gcc": "gcc", "clang": "clang", "gdb": "gdb",
        // 常见 Python 包（Alpine 预编译，py3- 前缀）
        "pandas": "py3-pandas", "numpy": "py3-numpy", "scipy": "py3-scipy",
        "requests": "py3-requests", "matplotlib": "py3-matplotlib", "pillow": "py3-pillow",
        "flask": "py3-flask", "django": "py3-django", "pip": "py3-pip",
        "bs4": "py3-beautifulsoup4", "beautifulsoup4": "py3-beautifulsoup4",
        "openpyxl": "py3-openpyxl", "pytest": "py3-pytest", "yaml": "py3-yaml",
        "sqlalchemy": "py3-sqlalchemy", "cryptography": "py3-cryptography"
    ]

    /// 常见 Python 包名：apk 无对应 py3- 包时，回退到 pip install
    private static let pythonHints: Set<String> = [
        "pandas", "numpy", "scipy", "requests", "matplotlib", "pillow", "flask",
        "django", "bs4", "beautifulsoup4", "openpyxl", "pytest", "sqlalchemy",
        "cryptography", "pyyaml", "aiohttp", "tornado", "click", "six"
    ]

    /// 逆向/开发/网络 三档 curated 批量（Alpine 包）
    private static let profiles: [String: [String]] = [
        "re": ["binutils", "file", "python3", "sqlite", "openssl", "curl", "git", "jq",
               "zip", "unzip", "xz", "7zip", "tree", "gawk", "coreutils", "findutils", "vim",
               "tcpdump", "netcat-openbsd"],
        "dev": ["build-base", "git", "python3", "vim", "curl", "jq", "cmake", "nodejs"],
        "network": ["curl", "wget", "jq", "openssl", "ca-certificates", "bind-tools", "tcpdump"]
    ]

    /// 原生 iOS 二进制注册表（Alpine 没有，走 CI 交叉编译；note 说明真实可行性）
    private static let nativeRegistry: [String: (source: String, note: String)] = [
        "jtool2": ("https://github.com/Neurotycho/jtool2",
                   "Makefile project, best-effort cross-compile; outputs jtool (deep Mach-O analysis), standard iOS reverse tool"),
        "class-dump": ("https://github.com/stevemacarthur/class-dump",
                       "macOS Makefile, iOS cross-compile needs SDK target changes; if artifact is empty, compile on a PC then wrap with a custom dylib"),
        "frida-server": ("https://github.com/frida/frida",
                         "Needs jailbreak/kernel trust, usually unavailable under TrollStore; not recommended, listed only to state the boundary")
    ]
}

/// v4.3.65：一键逆向工具链（env.setup_re = tool.install profile:re）
final class EnvSetupRETool: MCPTool {
    let definition = ToolDefinition(
        name: "env.setup_re",
        summary: "One-click reverse-engineering toolchain for iOS/App/IPA analysis (Alpine batch install). Use for: AI needs RE tools (strings/file/nm/python3/sqlite/tcpdump/7z...). Don't use for: native iOS binaries (jtool2 → use tool.install name:jtool2). Example: 'setup reverse engineering tools' → install curated RE batch.",
        parameters: [:],
        verified: true, category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        return try ToolInstallTool().invoke(["profile": "re"])
    }
}
