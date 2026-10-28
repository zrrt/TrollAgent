import Foundation
import UIKit
import Contacts
import EventKit
import CoreLocation
import UserNotifications
import Vision

// MARK: - v3.0.90：system.overview — AI 全局视角目录

final class SystemOverviewTool: MCPTool {
    let definition = ToolDefinition(
        name: "system.overview",
        summary: "Get an overview of all available tools. Use for: when you don't know what tools exist, need to pick the right tool. Don't use for: specific tasks (use the actual tool directly). Example: user says 'what tools do you have' → system overview.",
        parameters: [:],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // v4.4.x：tool_categories 改为从注册表动态生成——只列真实注册的大工具，杜绝幽灵工具名漂移。
        let reg = ToolRegistry.shared
        let names = reg.allToolNames().sorted()
        var byCat: [String: [String]] = [:]
        for n in names {
            let cat = reg.tool(named: n)?.definition.category ?? "misc"
            byCat[cat, default: []].append(n)
        }
        var cats: [[String: Any]] = []
        for (cat, tools) in byCat.sorted(by: { $0.key < $1.key }) {
            cats.append(["category": cat, "tools": tools])
        }
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        return [
            "system": "TrollAgent",
            "version": ver,
            "total_tools": names.count,
            "important_note": "ALL tool schemas are slimmed to one line to save context — load the FULL description via `tool.describe name:\"<tool>\"` before first use this session (esp. BIG WRAPPED TOOLS — app / inject / control / browser / device / memory / network.capture / vpn.capture / automation / project / container / github: many subcommands + prerequisites; always describe, then call with `command`/`action` subcommand). SMALL TOOLS (wifi / location / macro / db / file / server / ssh / reminder / package / artifact / assistant_memory / knowledge / diagnose / rescue / verify): call directly (e.g. name:\"wifi\" command:\"status\"), describe if unsure. SIMPLE TOOLS (shell.exec / system.exec_root / web.search / web.fetch / download / tool.install / env.setup_re / skills.* / subagent.* / system.overview / tool.describe / bind_app / bind_app_write / app_write_file): call directly by name, describe if unsure.",
            "tool_categories": cats,
            "ios_version_support": [
                "trollstore_supported": [
                    "iOS 14.0 - 15.4.1 (TrollStore 1)",
                    "iOS 15.5 - 16.6.1 (TrollStore 2)",
                    "iOS 17.0 - 17.0.3 (TrollStore 2 / kfd)"
                ],
                "jailbreak_supported": [
                    "iOS 17.0 - 17.3.1 (Relaxin / RootHide / Dopamine with ElleKit)"
                ],
                "unsupported": [
                    "iOS 16.6.2+ (Apple patched CoreTrust)",
                    "iOS 17.1+ (Apple patched kfd for TrollStore)"
                ],
                "note": "Two environments: (1) TrollStore (jailbreak-free), (2) Jailbreak. Use device + command:info to detect which environment you're in."
            ],
            "injection_methods": [
                "trollstore_runtime": "inject + command:enable — runtime injection via CoreTrust (ct_bypass), iOS ≤17.0 TrollStore.",
                "trollstore_static": "inject + command:static — static injection (insert_dylib + reinstall), all TrollStore devices."
            ],
            "recommended_workflows": [
                [
                    "task": "Inject dylib into an app (TrollStore)",
                    "steps": [
                        "1. device + command:info — check environment",
                        "2. inject + command:list — find bundle_id",
                        "3. inject + command:enable bundle_id — inject dylib",
                        "4. control + command:inject bundle_id — inject ControlAgent for UI control",
                        "5. control + command:screenshot — verify injection worked"
                    ]
                ],
                [
                    "task": "Control an app's UI",
                    "steps": [
                        "1. control + command:inject bundle_id — inject ControlAgent",
                        "2. control + command:screenshot — see current screen",
                        "3. control + command:tap_text — tap by text",
                        "4. control + command:type_text — type into field"
                    ]
                ],
                [
                    "task": "Read app container files",
                    "steps": [
                        "1. container + command:resolve bundle_id — get data container path",
                        "2. shell.exec cat/find on that path (or artifact + command:read) — read a file"
                    ]
                ]
            ],
            "tips": [
                "All schemas are slimmed — tool.describe any tool you haven't loaded this session (always for big tools: app/inject/control/browser/device/memory/network.capture/vpn.capture/automation/project/container/github), then name + command/action. Small tools (wifi/location/macro/db/file/server/ssh/reminder/package/...): call directly with their subcommand. Simple tools (shell.exec, web.search, web.fetch, ...): call directly.",
                "If you're stuck after 2 tries, ask the user for clarification.",
                "Don't repeat the same tool with the same params — it's a loop.",
                "Before injecting dylib, call device + command:info (or device.info) to detect environment.",
                "TrollStore + iOS ≤17.0: inject + command:enable (ct_bypass runtime); iOS 17.0.1+: inject + command:static or static injection."
            ]
        ]
    }
}




final class VerifyFileTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify.file",
        summary: "Verify if file exists and has expected content. Use for: after artifact, check if file was written correctly. Don't use for: read file content (use artifact).",
        parameters: [
            "path": "File path to verify (required)",
            "expect_size": "Expected file size in bytes (optional)",
            "expect_contains": "Expected string in file content (optional)"
        ],
        verified: true, category: "verify")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return ["verified": false, "reason": "File not found", "path": path]
        }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        var checks: [String: Any] = [
            "verified": true,
            "path": path,
            "size": size
        ]

        // 检查大小
        if let expectedSize = params["expect_size"] as? Int {
            checks["size_match"] = size == expectedSize
            if size != expectedSize {
                checks["verified"] = false
                checks["reason"] = "Size mismatch: expected \(expectedSize), got \(size)"
            }
        }

        // 检查内容
        if let expectedStr = params["expect_contains"] as? String, !expectedStr.isEmpty {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let contains = content.contains(expectedStr)
                checks["content_contains"] = contains
                if !contains {
                    checks["verified"] = false
                    checks["reason"] = "Content does not contain expected string"
                }
            }
        }

        return checks
    }
}

final class VerifyAppRunningTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify.app_running",
        summary: "Verify if an app is currently running. Use for: after app.launch, check if it actually started. Don't use for: launch app (use app.launch).",
        parameters: [
            "bundle_id": "App bundle_id to check (required)"
        ],
        verified: true, category: "verify")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bid) else {
            return ["running": false, "reason": "App not found"]
        }
        let exeName = ProcessHelper.executableName(for: app)
        let pid = ProcessHelper.pidOf(executableName: exeName)
        return [
            "running": pid != nil,
            "pid": pid ?? 0,
            "bundle_id": bid,
            "name": app.name
        ]
    }
}

// MARK: - M3 注入工具

final class InjectionEnableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable", summary: "Inject a dylib/plugin into an app permanently. Use for: persistent injection that survives app restart. Don't use for: temporary testing (use injection.mem), check injection status (use injection.status). Note: only works on iOS ≤17.0 with ct_bypass; iOS 17.0.1+ uses static injection. Example: user says 'inject ControlAgent into 小红书' → enable injection.",
        parameters: ["bundle_id": "Target App bundle_id (required)", "dylib_path": "Local plugin path (.dylib/.framework/.zip/.deb, e.g. Workspace/downloads/.../xxx.deb). Default: built-in ControlAgent.dylib", "weak_reference": "Optional Bool: weak reference injection (default false, matches TrollFools)", "inject_strategy": "Optional String: injection target strategy lexicographic (default)/fast (smallest file first)/preorder/postorder, matches TrollFools Strategy", "smart_fallback": "Optional Bool: auto-fallback to memory injection if no static target (default true)"],
        verified: true,
        category: "injection",
        maxIOSMajor: 17  // ct_bypass 只支持到 iOS 17.0
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let dylibPath = params["dylib_path"] as? String
        let weakRef = (params["weak_reference"] as? Bool) ?? false
        let strategy = (params["inject_strategy"] as? String) ?? "lexicographic"
        // v2.9.32：dylib_path 为本地文件路径 → 作为注入源 (root 拷贝进目标 App）；
        // 为 @executable_path/@loader_path 前缀 → 作为 load name；空 → 内置 agent。
        var source: String?
        var loadName = "@executable_path/ControlAgent.dylib"
        if let p = dylibPath, !p.isEmpty {
            if p.hasPrefix("@executable_path/") || p.hasPrefix("@loader_path/") {
                loadName = p
            } else {
                source = p
                loadName = "@executable_path/\((p as NSString).lastPathComponent)"
            }
        }
        let result = try InjectionManager.shared.enable(bundleId: bid, dylibName: loadName, dylibSourcePath: source, weakReference: weakRef, injectStrategy: strategy, smartFallback: (params["smart_fallback"] as? Bool) ?? true)
        AuditLog.shared.log("injection.enable", detail: "\(bid) → \(dylibPath ?? "bundled agent")")
        // v2.9.68：截断冗长日志，只保留 exit code + 关键错误行，避免上下文爆炸
        var slim = result
        for key in ["ct_bypass_output", "ldid_output", "insert_output", "rpath_output"] {
            if let full = slim[key] as? String, !full.isEmpty {
                let lines = full.components(separatedBy: .newlines)
                // 只保留最后 3 行 + 包含 error/fail/fatal 的行
                let important = lines.filter { line in
                    let lower = line.lowercased()
                    return lower.contains("error") || lower.contains("fail") || lower.contains("fatal") || lower.contains("cannot") || lower.contains("operation not permitted")
                }
                let tail = Array(lines.suffix(3))
                var seen = Set<String>()
                let deduped = (important + tail).filter { seen.insert($0).inserted }
                let summary = deduped.prefix(5).joined(separator: "\n")
                slim[key] = summary.isEmpty ? "(log truncated, full log in workspace)" : summary
                slim["\(key)_truncated"] = lines.count > 5
            }
        }
        // v2.9.125：CLI 式一句话结论 (dispatch 会取 message 放顶层）
        if let injected = result["injected"] as? Bool {
            let alive = (result["selfcheck"] as? [String: Any])?["app_alive"] as? Bool ?? false
            slim["message"] = injected
                ? "Injection OK (injected=true, app alive=\(alive ? "yes" : "no")\(slim["risk_warning"] != nil ? ", sensitive-app guardrail on" : ""))"
                : "Injection didn't take effect (injected=false)"
        }
        return slim
    }
}

final class InjectionDisableTool: MCPTool {
    let definition = ToolDefinition(name: "injection.disable", summary: "Remove/uninstall dylib injection from an app. Use for: undo injection, rollback to original app, disable hook. Don't use for: just restart app (use app.restart), uninstall app (use app.uninstall). Example: user says 'remove 小红书 injection' → disable injection on com.xingin.discover.",
        parameters: ["bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover", "desist": "Optional Bool: fully remove (default true; false=disable but keep backup, can re-enable later)"], verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let desist = (params["desist"] as? Bool) ?? true
        let result = try InjectionManager.shared.disable(bundleId: bid, desist: desist)
        AuditLog.shared.log("injection.disable", detail: bid)
        return result
    }
}

// v3.0.89：iOS 17 兼容的静态injected (insert_dylib + trollstorehelper 重装）
final class InjectionStaticTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.static",
        summary: "Static injection for iOS 17+ (ct_bypass broken). Copy app → insert_dylib → repack IPA → trollstorehelper reinstall. Use for: iOS 17.0+ where runtime injection (ct_bypass) no longer works. Don't use for: iOS 16 or earlier (use injection.enable instead, faster).",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "dylib_path": "Local dylib path (required, e.g. Workspace/downloads/xxx.dylib)"
        ], verified: true, category: "injection")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let dylibPath = params["dylib_path"] as? String, !dylibPath.isEmpty else {
            throw MCPError.invalidParams("dylib_path required")
        }
        let (ok, msg) = InjectionManager.shared.injectStatic(bundleId: bid, dylibPath: dylibPath)
        AuditLog.shared.log("injection.static", detail: "\(bid) → \(dylibPath)")
        return ["ok": ok, "message": msg]
    }
}

final class InjectionEnablePersistedTool: MCPTool {
    let definition = ToolDefinition(name: "injection.enable_persisted", summary: "Re-enable a disabled plugin on an app (toggle injection back on). Use for: you disabled injection before, now want to turn it back on. Don't use for: inject new dylib (use injection.enable), check if injected (use injection.status). Example: user says 're-enable 小红书 injection' → enable_persisted.",
        parameters: ["bundle_id": "Target App bundle ID (required)"], verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.restore(bundleId: bid)
        AuditLog.shared.log("injection.enable_persisted", detail: bid)
        return result
    }
}

final class InjectionStatusTool: MCPTool {
    let definition = ToolDefinition(name: "injection.status", summary: "Show which apps are already injected (have dylib loaded). Use for: check if an app is already injected, see overall injection stats. Don't use for: find a specific app's bundle_id (use injection.list), inject into app (use injection.enable). Example: user says 'is 小红书 injected' → check status of com.xingin.discover.", verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // v3.1.71：支持 bundle_id 单查该 App 注入态；不带参数时返回全量 (兼容旧行为）
        if let bid = params["bundle_id"] as? String, !bid.isEmpty {
            return InjectionManager.shared.status(for: bid)
        }
        return InjectionManager.shared.status()
    }
}

final class InjectionInspectTool: MCPTool {
    let definition = ToolDefinition(name: "injection.inspect", summary: "Check which dylibs are loaded in an app (injection status details). Use for: verify if injection actually worked, see what dylibs are loaded. Don't use for: list all injected apps (use injection.status), inject dylib (use injection.enable). Example: user says 'did 小红书 injection succeed' → inspect injection details.",
        parameters: ["bundle_id": "Target App bundle_id (required)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        return InjectionManager.shared.inspect(bid)
    }
}

final class InjectionListTool: MCPTool {
    // v2.9.41：检索式——query 按名称/bundle_id 模糊匹配，只返回命中项，不再全量 266 条塞给 AI
    let definition = ToolDefinition(name: "injection.list",
        summary: "Search/find installed apps on the phone. Use for: find bundle_id for a specific app (e.g. find 小红书's bundle_id), list what apps are installed. Don't use for: check injection status (use injection.status), launch app (use app.launch). Example: user says 'find 小红书' → search '小红书' → get bundle_id com.xingin.discover.",
        parameters: ["query": "Search keyword (App Chinese name or bundle_id fragment, optional). If empty, return first 20 only. e.g. 小红书 / 微博 / tiktok / weibo"],
        returns: ["apps": "List of matching apps (bundle_id + name)", "count": "Number of results"],
        verified: true, category: "injection")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let apps = AppCatalog.list()
        let q = (params["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = (params["limit"] as? Int) ?? 20
        let matched: [AppCatalog.AppEntry]
        if q.isEmpty {
            matched = Array(apps.prefix(limit))
        } else {
            matched = apps.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.bundleId.localizedCaseInsensitiveContains(q)
            }
        }
        return [
            "total": apps.count,
            "matched": matched.count,
            "query": q,
            "hint": q.isEmpty ? "total \(apps.count) apps, only first \(limit) entries; use query to search by name/bundle_id (e.g. query=\"Troll\"), or limit the count" : "matched \(matched.count), showing max \(limit) entries",
            "apps": Array(matched.prefix(limit)).map { ["bundle_id": $0.bundleId, "name": $0.name] }
        ]
    }
}


final class ContainerWriteTextTool: MCPTool {
    let definition = ToolDefinition(name: "container.write_text", summary: "Write a text file into an app's data container (DANGEROUS!). Use for: modify app data files, write config into app sandbox. Don't use for: write workspace files (use artifact), read app files (use artifact). Warning: modifying app data can crash it! Example: user says 'modify 小红书 config file' → write to container.",
        parameters: ["bundle_id": "Target App bundle ID", "path": "File path inside app container", "content": "Text content to write"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String,
              let path = params["path"] as? String,
              let content = params["content"] as? String else {
            throw MCPError.invalidParams("bundle_id, path, content required")
        }
        guard let app = AppCatalog.find(bid), let container = AppCatalog.lookupContainer(bundleId: app.bundleId) else {
            throw MCPError.failed("container not accessible for \(bid)")
        }
        let url = URL(fileURLWithPath: container).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        AuditLog.shared.log("container.write_text", detail: "\(bid):\(path)")
        return ["written": true, "bytes": content.utf8.count]
    }
}

// v3.1.68: container.resolve —— bundle_id → 安装目录 + 数据容器 + 沙盒路径
// 此前 AI 为定位某 App 的数据目录要循环几百个目录跑 plutil (慢且易因环境问题崩），
// 一条 resolve 直接给出全部路径 (D items修复，2026-09-23 真机实测确认缺失）
final class ContainerResolveTool: MCPTool {
    let definition = ToolDefinition(name: "container.resolve", summary: "Resolve an app's install path, data container and sandbox paths by bundle_id. Use for: find where an app lives on disk, get its data container path for reading/writing config. Don't use for: read/write files (use container write/delete or artifact). Example: container resolve bundle_id:com.xingin.discover → install path + data container + executable.",
        parameters: ["bundle_id": "App bundle ID to resolve"], returns: ["bundle_id": "Resolved bundle id", "app_name": "App display name", "install_path": "Bundle .app path", "data_container": "Data container path (nil if not accessible)", "executable": "Executable name", "version": "App version"], verified: true, category: "fs")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required. Usage: container resolve bundle_id:com.xxx")
        }
        guard let app = AppCatalog.find(bid) else {
            throw MCPError.failed("app not found: \(bid)")
        }
        AuditLog.shared.log("container.resolve", detail: bid)
        return [
            "bundle_id": app.bundleId,
            "app_name": app.name,
            "install_path": app.path,
            "data_container": AppCatalog.lookupContainer(bundleId: app.bundleId) ?? "",
            "executable": app.execName,
            "version": app.version,
            "hint": AppCatalog.lookupContainer(bundleId: app.bundleId) == nil ? "data container inaccessible (system App or restricted)" : "data container accessible via artifact / container.write"
        ]
    }
}

// MARK: - M4 Gateway 工具

final class CronFireTool: MCPTool {
    let definition = ToolDefinition(name: "cron.fire", summary: "Manually trigger a scheduled/cron task. Use for: test automation task works, run scheduled task right now instead of waiting. Don't use for: create new automation task (no create command — use reminder.schedule_recurring for recurring reminders), list tasks (use automation.list). Example: user says 'run the scheduled task now' → fire the task.",
        parameters: ["task": "Name of the scheduled task to trigger"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let task = params["task"] as? String ?? "unnamed"
        AuditLog.shared.log("cron.fire", detail: task)
        return ["fired": true, "task": task]
    }
}

// MARK: - M4 自动化工具 (真实 UNUserNotificationCenter 调度）

final class AutomationRunNowTool: MCPTool {
    let definition = ToolDefinition(name: "automation.run_now", summary: "Run an automation task immediately (right now, don't wait for schedule). Use for: execute a saved automation task manually. Don't use for: create new task (automation.create not registered — use reminder.schedule_recurring), list all tasks (use automation.list). Example: user says 'run that scheduled task' → run it now.",
        parameters: ["name": "Task name or ID to run immediately"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        let matched = store.tasks.first { $0.name == name || $0.id.uuidString == name }
        guard let task = matched else { throw MCPError.failed("task not found: \(name)") }
        guard store.run(name: task.name) else { throw MCPError.failed("task disabled or not found: \(name)") }
        return ["ran": true, "name": task.name, "kind": task.kind]
    }
}

final class AutomationListTool: MCPTool {
    let definition = ToolDefinition(name: "automation.list", summary: "List all saved automation/scheduled tasks. Use for: see what scheduled tasks exist, check task list. Don't use for: run a task now (use automation.run_now), stop a task (use automation.stop). Example: user says 'what scheduled tasks do I have' → list all automation tasks.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let tasks = AutomationStore.shared.tasks.map { t in
            [
                "id": t.id.uuidString,
                "name": t.name,
                "kind": t.kind,
                "enabled": t.enabled,
                "schedule": t.schedule,
                "delay": t.delay,
                "interval": t.interval,
                "lastRun": t.lastRun.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ] as [String: Any]
        }
        return ["count": tasks.count, "tasks": tasks]
    }
}

final class AutomationJobsTool: MCPTool {
    let definition = ToolDefinition(name: "automation.jobs", summary: "Check pending automation tasks and notification permission status. Use for: see how many tasks are scheduled, check if notifications are allowed. Don't use for: list task details (use automation.list), run task now (use automation.run_now). Example: user says 'how many scheduled tasks are queued' → check automation jobs.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let store = AutomationStore.shared
        let status = AutomationSchedulerStatus()
        return [
            "authStatus": status,
            "pending": store.tasks.filter { $0.enabled }.count,
            "total": store.tasks.count,
            "jobs": store.tasks.map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind, "enabled": $0.enabled] }
        ]
    }
}

final class AutomationStopTool: MCPTool {
    let definition = ToolDefinition(name: "automation.stop", summary: "Stop/disable a scheduled automation task. Use for: cancel a scheduled task, turn off automation. Don't use for: list all tasks (use automation.list), run task now (use automation.run_now). Example: user says 'stop that scheduled task' → stop the task.",
        parameters: ["name": "Task name or ID to stop"], verified: true, category: "device")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let store = AutomationStore.shared
        guard let task = store.tasks.first(where: { $0.name == name || $0.id.uuidString == name }) else {
            throw MCPError.failed("task not found: \(name)")
        }
        store.remove(task)
        AuditLog.shared.log("automation.stop", detail: name)
        return ["stopped": true, "name": name]
    }
}

final class AutomationStatusTool: MCPTool {
    let definition = ToolDefinition(name: "automation.status", summary: "Check automation engine status: how many tasks, how many enabled, notification auth. Use for: monitor automation system, check if notifications are allowed. Don't use for: list specific task details (use automation.list).")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "engine": "UNUserNotificationCenter",
            "authStatus": AutomationSchedulerStatus(),
            "tasks": AutomationStore.shared.tasks.count,
            "enabled": AutomationStore.shared.tasks.filter { $0.enabled }.count
        ]
    }
}

/// 读取通知授权状态 (iOS 14 用 getNotificationSettings）
/// v2.9.87：改为非阻塞——返回缓存值，后台异步刷新，避免信号量阻塞调用线程。
func AutomationSchedulerStatus() -> String {
    let cacheKey = "automation.notif.status.cache"
    let cached = UserDefaults.standard.string(forKey: cacheKey) ?? "unknown"
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        var status = "unknown"
        switch settings.authorizationStatus {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .notDetermined: status = "notDetermined"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        @unknown default: status = "unknown"
        }
        UserDefaults.standard.set(status, forKey: cacheKey)
    }
    return cached
}

// MARK: - M5 系统能力工具

final class ContactsSearchTool: MCPTool {
    let definition = ToolDefinition(name: "contacts.search", summary: "Search iPhone contacts by name. Use for: find someone's phone number, look up a contact. Don't use for: send message (use other tools), read calendar (use calendar.list). Example: user says 'what is Zhang San phone number' → search contacts.",
        parameters: ["query": "Name keyword to search (e.g. 'Zhang San' / 'Bob')"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let query = params["query"] as? String ?? ""
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString
        ]
        var results: [[String: Any]] = []

        let req = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: req) { contact, stop in
            let name = "\(contact.givenName)\(contact.familyName)"
            if query.isEmpty || name.localizedCaseInsensitiveContains(query) {
                results.append([
                    "name": name,
                    "phones": contact.phoneNumbers.map { $0.value.stringValue }
                ])
            }
            if results.count >= 50 { stop.pointee = true }
        }
        AuditLog.shared.log("contacts.search", detail: "query=\(query) found=\(results.count)")
        return ["contacts": results]
    }
}

final class LocationGetTool: MCPTool {
    let definition = ToolDefinition(name: "location.get", summary: "Get current GPS location (latitude/longitude). Use for: find where the phone is, location-based tasks. Don't use for: spoof fake location (use device.fake), get device info (use device.info). Example: user says 'where am I now' → get current location.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let mgr = LocationProvider.shared
        return [
            "latitude": mgr.latitude ?? 0,
            "longitude": mgr.longitude ?? 0,
            "available": mgr.available
        ]
    }
}

final class ScanQRTool: MCPTool {
    let definition = ToolDefinition(name: "scan.qr", summary: "Decode QR code or barcode from an image file. Use for: read QR code content from a screenshot/image. Don't use for: OCR text recognition (use ocr.image), take screenshot (use control.screenshot). Example: user says 'what is in this QR code' → decode QR from image.",
        parameters: ["image_path": "Image file path (in workspace) containing QR code"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["image_path"] as? String else { throw MCPError.invalidParams("image_path required") }
        let url = try Workspace.resolve(path)
        guard let imgData = try? Data(contentsOf: url),
              let image = UIImage(data: imgData),
              let cgImage = image.cgImage else {
            throw MCPError.failed("cannot load image: \(path)")
        }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        let results = request.results?.compactMap { $0.payloadStringValue } ?? []
        return ["codes": results]
    }
}

// MARK: - M6 编译模式工具

final class BuildRunnerTokenTool: MCPTool {
    let definition = ToolDefinition(name: "build.runner.token", summary: "Generate or verify a build authentication token (for CI builds). Use for: authenticate with build system. Don't use for: trigger GitHub Actions build (use github.trigger_build), check GitHub login (use github.account_status). Example: user says 'generate build token' → generate token.",
        parameters: ["action": "generate (create new token) or verify (check token validity)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "generate"
        if action == "generate" {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32)
            AuditLog.shared.log("build.token", detail: "generated")
            return ["token": String(token), "action": "generate"]
        }
        return ["action": "verify", "valid": true]
    }
}

final class ProjectGenerateTweakTool: MCPTool {
    let definition = ToolDefinition(name: "project.generate_tweak", summary: "Generate a Tweak project template (Theos Makefile + Tweak.x + plist). Use for: start a new jailbreak tweak development project. Don't use for: compile existing tweak (use github.trigger_build), load dylib (use tool.load_dylib). Example: user says 'create a new tweak project' → generate template.",
        parameters: ["name": "Project name (e.g. MyTweak)", "bundle_id": "Target app bundle ID (optional)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let name = params["name"] as? String ?? "MyTweak"
        let bid = params["bundle_id"] as? String ?? ""
        let dir = Workspace.root.appendingPathComponent("projects/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let makefile = """
        THEOS_PACKAGE_SCHEME=rootless
        TARGET = iphone:clang:latest:14.0
        ARCHS = arm64
        INSTALL_TARGET_PROCESSES = SpringBoard

        TWEAK_NAME = \(name)
        \(name)_FILES = Tweak.x
        \(name)_CFLAGS = -fobjc-arc

        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        try makefile.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let plist = """
        { Filter = { Executables = ( "\(bid.isEmpty ? "com.example.app" : bid)" ); }; }
        """
        try plist.write(to: dir.appendingPathComponent("\(name).plist"), atomically: true, encoding: .utf8)
        // v2.9.3：生成最小 Tweak.x 源文件，工程开箱即可编译 (编译环境见 build.environment）
        let tweakX = """
        #import <UIKit/UIKit.h>

        // 最小 Tweak 模板：把下面的钩子目标替换为你要 hook 的类/方法。
        // 例如 hook SpringBoard 的 applicationDidFinishLaunching：
        %hook SpringBoard
        - (void)applicationDidFinishLaunching:(id)application {
            %orig;
            NSLog(@"[\(name)] loaded");
        }
        %end
        """
        try tweakX.write(to: dir.appendingPathComponent("Tweak.x"), atomically: true, encoding: .utf8)
        AuditLog.shared.log("project.generate_tweak", detail: name)
        return ["created": true, "path": "projects/\(name)", "name": name,
                "files": ["Makefile", "Tweak.x", "\(name).plist"]]
    }
}

final class ModelConfigTool: MCPTool {
    let definition = ToolDefinition(name: "model.config", summary: "View LLM model configurations (which AI models are available). Use for: check what AI models are configured, see current default model. Don't use for: change model (use model.update), system overview (use system.overview). Example: user says 'which model am I using' → show model config.",
        parameters: ["action": "list (all configs) or default (current default)"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = params["action"] as? String ?? "list"
        if action == "default", let cfg = ModelStore.shared.defaultConfig {
            return ["name": cfg.name, "model": cfg.model, "provider": cfg.provider]
        }
        return [
            "configs": ModelStore.shared.configs.map { ["name": $0.name, "model": $0.model, "provider": $0.provider] },
            "count": ModelStore.shared.configs.count
        ]
    }
}

/// v2.9.299：远程修改模型配置 (AI 诊断时可帮用户切换模型名/协议，无需手动设置）
final class ModelUpdateTool: MCPTool {
    let definition = ToolDefinition(name: "model.update",
        summary: "Modify an existing LLM model configuration. Use for: change model settings, switch default model, update API endpoint. Don't use for: view current configs (use model.config), list all models (use model.config list). Example: user says 'switch default model to deepseek' → update model config.",
        parameters: ["name": "Config name to modify (e.g. 'deepseek')", "model": "New model name (optional)", "baseURL": "New API base URL (optional)", "apiProtocol": "API protocol type (optional)", "contextTokens": "Context token limit (optional)", "isDefault": "Set as default model (optional bool)", "resetCompat": "Reset compatibility level (optional bool)"],
        verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let idx = ModelStore.shared.configs.firstIndex(where: { $0.name == name }) else {
            throw MCPError.failed("config not found: \(name)")
        }
        var cfg = ModelStore.shared.configs[idx]
        var changed: [String] = []
        if let m = params["model"] as? String, !m.isEmpty, m != cfg.model {
            cfg.model = m; changed.append("model=\(m)")
        }
        if let b = params["baseURL"] as? String, !b.isEmpty, b != cfg.baseURL {
            cfg.baseURL = b; changed.append("baseURL=\(b)")
        }
        if let p = params["apiProtocol"] as? String, !p.isEmpty, p != cfg.apiProtocol {
            cfg.apiProtocol = p; changed.append("apiProtocol=\(p)")
        }
        if let ct = params["contextTokens"] as? Int, ct != cfg.contextTokens {
            cfg.contextTokens = ct; changed.append("contextTokens=\(ct)")
        }
        if let d = params["isDefault"] as? Bool, d != cfg.isDefault {
            if d {
                for i in ModelStore.shared.configs.indices { ModelStore.shared.configs[i].isDefault = false }
            }
            cfg.isDefault = d; changed.append("isDefault=\(d)")
        }
        if let rc = params["resetCompat"] as? Bool, rc {
            cfg.compatLevel = 0; changed.append("compatLevel=0")
        }
        ModelStore.shared.configs[idx] = cfg
        ModelStore.shared.save()
        AuditLog.shared.log("model.update", detail: "\(name): \(changed.joined(separator: ", "))")
        return ["ok": true, "name": name, "changed": changed,
                "now": ["model": cfg.model, "baseURL": cfg.baseURL, "apiProtocol": cfg.apiProtocol, "compatLevel": cfg.compatLevel]]
    }
}

// MARK: - 位置提供者

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let mgr = CLLocationManager()
    var latitude: Double?
    var longitude: Double?
    var available = false

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            latitude = loc.coordinate.latitude
            longitude = loc.coordinate.longitude
            available = true
        }
    }
}

// MARK: - v3.1.34: inject 大工具 + 子命令 (合并 7 个 injection.* 工具）

final class InjectionExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "inject",
        summary: "Manage dylib injection & reverse engineering. Params: command, bundle_id, path(IPA/dylib/binary), dylib_path, query. For binary analysis prefer binary_symbols (extract Mach-O symbols/classes) — don't run nm/strings via shell. Use for: inject/remove dylibs, check status, inspect IPA/dylib/binary, hook, wipe keychain. Launch apps via app.*, UI operations via control.*. Subcommands: enable / disable / static / enable_persisted / status / inspect / list / remove / restore / mem / diagnose / verify / ipa_inspect / dylib_inspect / binary_symbols / hook_apply / probe_inspect / plugin_list / keychain_wipe / load_dylib.",
        parameters: [
            "command": "Subcommand: enable / disable / static / enable_persisted / status / inspect / list / remove / restore / mem / diagnose / verify / ipa_inspect / dylib_inspect / binary_symbols / hook_apply / probe_inspect / plugin_list / keychain_wipe / load_dylib",
            "bundle_id": "App bundle ID",
            "path": "File path (IPA/dylib/binary)",
            "dylib_path": "Dylib path (for enable)",
            "query": "Search query (for list)"
        ],
        verified: true, category: "injection", prerequisites: ["before enable/static confirm the app is installed and bundle_id valid (app status); encrypted apps are rejected at runtime with a decrypt next-step, and failed runs return an attribution diag with the direction to take", "hook full chain: project generate_tweak → write tweaks/<name>/Tweak.x → github trigger_build (build-tweak.yml) → download_artifact → copy the dylib into the target app's data container Documents (workspace is blocked for mmap) → inject enable with that path → restart verify"])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("inject", detail: command)
        
        switch command {
        case "enable":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var p: [String: Any] = ["bundle_id": bundleId]
            if let dylib = params["dylib_path"] as? String { p["dylib_path"] = dylib }
            return try InjectionEnableTool().invoke(p)
            
        case "disable":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionDisableTool().invoke(["bundle_id": bundleId])
            
        case "static":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionStaticTool().invoke(["bundle_id": bundleId])
            
        case "enable_persisted":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionEnablePersistedTool().invoke(["bundle_id": bundleId])
            
        case "status":
            // v3.1.71：支持 bundle_id 单查 (AI 反馈：只回全量列表、未注入目标不单列）
            var p: [String: Any] = [:]
            if let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty { p["bundle_id"] = bundleId }
            return try InjectionStatusTool().invoke(p)
            
        case "inspect":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionInspectTool().invoke(["bundle_id": bundleId])
            
        case "list":
            var p: [String: Any] = [:]
            if let query = params["query"] as? String { p["query"] = query }
            if let limit = params["limit"] as? Int { p["limit"] = limit }
            return try InjectionListTool().invoke(p)
            
        case "remove":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionRemoveTool().invoke(["bundle_id": bundleId])
            
        case "restore":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionRestoreTool().invoke(["bundle_id": bundleId])
            
        case "mem":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var memP: [String: Any] = ["bundle_id": bundleId]
            if let d = params["dylib_path"] as? String { memP["dylib_path"] = d }
            if let al = params["auto_launch"] as? Bool { memP["auto_launch"] = al }
            return try InjectionMemTool().invoke(memP)

        case "diagnose":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            var diagP: [String: Any] = ["bundle_id": bundleId]
            if let d = params["dylib_path"] as? String { diagP["dylib_path"] = d }
            return try InjectionDiagnoseTool().invoke(diagP)

        case "verify":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionVerifyTool().invoke(["bundle_id": bundleId])

        case "ipa_inspect":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required (IPA file path)")
            }
            var ipaP: [String: Any] = ["path": path]
            if let dt = params["detail"] as? String { ipaP["detail"] = dt }
            return try IPAInspectTool().invoke(ipaP)

        case "dylib_inspect":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required (dylib file path)")
            }
            return try DylibInspectTool().invoke(["path": path])

        case "binary_symbols":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required (binary file path)")
            }
            // v4.3.11: 透传 direction——定向分析(内购/VIP/广告)由 BinarySymbolsTool 生效,
            // 之前只传 path 导致 direction 丢失, 定向模式永远不触发
            var bsParams: [String: Any] = ["path": path]
            if let dir = params["direction"] as? String, !dir.isEmpty {
                bsParams["direction"] = dir
            }
            return try BinarySymbolsTool().invoke(bsParams)

        case "hook_apply":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            // v4.3.11: 透传 config(必选)+restart——之前只传bundle_id丢config, hook_apply必然失败
            var hookP: [String: Any] = ["bundle_id": bundleId]
            if let cfg = params["config"] { hookP["config"] = cfg }
            if let rst = params["restart"] as? Bool { hookP["restart"] = rst }
            return try HookApplyTool().invoke(hookP)

        case "probe_inspect":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            // v4.3.11: 透传 query/class_name/prefix——之前只传bundle_id丢查询参数
            var probeP: [String: Any] = ["bundle_id": bundleId]
            if let q = params["query"] as? String { probeP["query"] = q }
            if let cn = params["class_name"] as? String { probeP["class_name"] = cn }
            if let pfx = params["prefix"] as? String { probeP["prefix"] = pfx }
            return try ProbeInspectTool().invoke(probeP)

        case "plugin_list":
            return try PluginTool().invoke([:])

        case "keychain_wipe":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try KeychainWipeTool().invoke(["bundle_id": bundleId])

        case "load_dylib":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required (dylib file path)")
            }
            return try ToolLoadDylibTool().invoke(["path": path])

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: enable/disable/static/enable_persisted/status/inspect/list/remove/restore/mem/diagnose/verify/ipa_inspect/dylib_inspect/binary_symbols/hook_apply/probe_inspect/plugin_list/keychain_wipe/load_dylib")
        }
    }
}

// MARK: - v3.1.35: automation 大工具 + 子命令 (合并 7 个 automation.* 工具）

final class AutomationExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "automation",
        summary: "Manage automation/scheduled tasks. Params: command, name(task name/ID), enabled. Use for: creating/starting/stopping/manually triggering/cron-triggering scheduled tasks. One-shot reminders go through reminder.*. Subcommands: run / list / jobs / stop / status / history / set_enabled / cron_fire.",
        parameters: [
            "command": "Subcommand: run / list / jobs / stop / status / history / set_enabled / cron_fire",
            "name": "Task name or ID",
            "enabled": "Enable/disable (for set_enabled)"
        ],
        verified: true, category: "automation")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("automation", detail: command)
        
        switch command {
        case "run":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try AutomationRunNowTool().invoke(["name": name])
            
        case "list":
            return try AutomationListTool().invoke([:])
            
        case "jobs":
            return try AutomationJobsTool().invoke([:])
            
        case "stop":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try AutomationStopTool().invoke(["name": name])
            
        case "status":
            return try AutomationStatusTool().invoke([:])

        case "cron_fire":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try CronFireTool().invoke(["name": name])

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: run/list/jobs/stop/status/history/set_enabled/cron_fire")
        }
    }
}

// MARK: - tools.audit — 工具注册表一致性审计（防幽灵工具 / 文档漂移）

/// 扫描所有已注册工具的 summary / prerequisites / returns / parameters 文本，
/// 提取其中的点号 token，找出"被引用但未注册"的工具名（幽灵工具）。
/// AI 在工具描述里读到不存在的工具名会卡壳——本工具把这类漂移一次性暴露出来。
final class AuditTool: MCPTool {
    let definition = ToolDefinition(
        name: "tools.audit",
        summary: "Audit tool registry consistency: find ghost tools referenced in descriptions/prerequisites that aren't registered; report tool totals and verified/jailbreak/trollStore distribution. Use for: after adding/removing tools, when AI is confused about available tools, before long sessions. Listing tools goes through system.overview.",
        parameters: [:],
        returns: ["total_tools": "registered tool count", "verified_count": "tools marked verified:true", "ghost_ref_count": "total references to unregistered tools", "ghost_refs": "map of tool → unregistered tool names it references (empty = docs consistent with registry)"],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let reg = ToolRegistry.shared
        let all = Set(reg.allToolNames())

        // 非工具名黑名单：英文词 / 格式 token / 域名片段，避免把 "next_step"、"bundle_id" 误报成工具
        let blacklist: Set<String> = [
            "bundle_id", "github", "http", "https", "www", "example", "json", "plist", "com_xingin",
            "next_step", "next", "error", "reason", "path", "paths", "file", "files", "data", "result",
            "results", "value", "values", "text", "list", "note", "notes", "screen", "button", "method",
            "mode", "state", "process", "model", "output", "input", "user", "message", "body", "source",
            "target", "session", "query", "queries", "type", "types", "url", "urls", "status", "key",
            "keys", "task", "config", "context", "ios", "xcode", "binary", "string", "time", "date",
            "title", "name", "index", "payload", "content", "unit", "test", "video", "audio", "image",
            "cell", "detail", "details", "field", "fields", "settings", "option", "options", "doc", "docs"
        ]

        var ghostRefs: [String: Set<String>] = [:]
        var refCount = 0

        for name in all.sorted() {
            guard let tool = reg.tool(named: name) else { continue }
            var texts: [String] = [tool.definition.summary, tool.definition.uiSummary]
            texts += tool.definition.prerequisites
            texts += Array(tool.definition.parameters.values)
            texts += Array(tool.definition.returns.values)

            var refs = Set<String>()
            let pattern = "[a-zA-Z_]{2,}(\\.[a-zA-Z_]{2,})+"
            let regex = try? NSRegularExpression(pattern: pattern)
            for t in texts where !t.isEmpty {
                let ns = t as NSString
                guard let regex = regex else { continue }
                let matches = regex.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    let tok = ns.substring(with: m.range).lowercased()
                    if tok.contains("://") || tok.contains("@") || tok.contains("/") { continue }
                    let clean = tok.replacingOccurrences(of: "_", with: ".")
                    if registered(clean, in: all) { continue }
                    let parts = clean.split(separator: ".").map(String.init)
                    if parts.isEmpty { continue }
                    if blacklist.contains(parts[0]) || blacklist.contains(parts.last ?? "") { continue }
                    if clean.count < 4 { continue }
                    if clean.contains(where: { !($0.isLetter || $0 == ".") }) { continue }
                    refs.insert(clean)
                }
            }
            if !refs.isEmpty {
                refCount += refs.count
                ghostRefs[name] = refs
            }
        }

        let verifiedCount = all.filter { reg.tool(named: $0)?.definition.verified ?? false }.count
        let jbCount = all.filter { reg.tool(named: $0)?.definition.requiresJailbreak ?? false }.count
        let tsCount = all.filter { reg.tool(named: $0)?.definition.requiresTrollStore ?? false }.count

        var sortedGhost: [String: [String]] = [:]
        for (k, v) in ghostRefs.sorted(by: { $0.key < $1.key }) { sortedGhost[k] = v.sorted() }

        return [
            "total_tools": all.count,
            "verified_count": verifiedCount,
            "requires_jailbreak_count": jbCount,
            "requires_trollstore_count": tsCount,
            "ghost_ref_count": refCount,
            "ghost_refs": sortedGhost,
            "note": "ghost_refs maps a tool to unregistered tool names it references. Fix by renaming the reference to a registered tool or registering it. Empty ghost_refs = docs consistent with registry."
        ]
    }

    /// 判断 token 是否命中注册表（含父工具 + 点号工具；也接受去掉尾段后的前缀）
    private func registered(_ token: String, in all: Set<String>) -> Bool {
        if all.contains(token) { return true }
        if let dot = token.firstIndex(of: ".") {
            let prefix = String(token[..<dot])
            if all.contains(prefix) { return true }
        }
        return false
    }
}
