import Foundation

// v2.9.73：项目上下文 + 任务模板框架
// 1. ProjectContext — 统一项目状态 (目标 App、dylib、配置、历史运行）
// 2. TaskTemplate — 固化常见流程，AI 可一键执行
// 3. 注入自动验证 + 回滚

// MARK: - items目上下文

final class ProjectContext: ObservableObject {
    static let shared = ProjectContext()

    struct Project: Codable, Identifiable {
        let id: String
        var name: String
        var targetBundleId: String
        var targetAppName: String
        var dylibPath: String
        var dylibName: String
        var createdAt: String
        var lastRunAt: String?
        var runCount: Int
        var successCount: Int
        var notes: String

        init(name: String, targetBundleId: String, targetAppName: String, dylibPath: String = "") {
            self.id = UUID().uuidString
            self.name = name
            self.targetBundleId = targetBundleId
            self.targetAppName = targetAppName
            self.dylibPath = dylibPath
            self.dylibName = URL(fileURLWithPath: dylibPath).lastPathComponent
            self.createdAt = ISO8601DateFormatter().string(from: Date())
            self.lastRunAt = nil
            self.runCount = 0
            self.successCount = 0
            self.notes = ""
        }
    }

    struct RunRecord: Codable, Identifiable {
        let id: String
        let projectId: String
        let timestamp: String
        let taskType: String
        let success: Bool
        let summary: String
        let reportPath: String?
        let durationMs: Int
    }

    @Published private(set) var projects: [Project] = []
    @Published private(set) var currentProjectId: String?
    @Published private(set) var runHistory: [RunRecord] = []

    private let projectsFile: String
    private let historyFile: String

    init() {
        let workspace = NSHomeDirectory().appending("/Documents/Workspace")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        projectsFile = workspace.appending("/projects.json")
        historyFile = workspace.appending("/run_history.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: projectsFile)),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: historyFile)),
           let decoded = try? JSONDecoder().decode([RunRecord].self, from: data) {
            runHistory = decoded
        }
        // 恢复当前项目
        currentProjectId = UserDefaults.standard.string(forKey: "current_project_id")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: URL(fileURLWithPath: projectsFile))
        }
        if let data = try? JSONEncoder().encode(runHistory) {
            try? data.write(to: URL(fileURLWithPath: historyFile))
        }
    }

    var currentProject: Project? {
        projects.first { $0.id == currentProjectId }
    }

    func createProject(name: String, bundleId: String, appName: String, dylibPath: String = "") -> Project {
        let project = Project(name: name, targetBundleId: bundleId, targetAppName: appName, dylibPath: dylibPath)
        projects.append(project)
        currentProjectId = project.id
        UserDefaults.standard.set(project.id, forKey: "current_project_id")
        save()
        return project
    }

    func selectProject(_ id: String) {
        currentProjectId = id
        UserDefaults.standard.set(id, forKey: "current_project_id")
    }

    func deleteProject(_ id: String) {
        projects.removeAll { $0.id == id }
        if currentProjectId == id { currentProjectId = nil }
        save()
    }

    func updateProject(_ id: String, dylibPath: String, notes: String) {
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].dylibPath = dylibPath
            projects[idx].dylibName = URL(fileURLWithPath: dylibPath).lastPathComponent
            projects[idx].notes = notes
            save()
        }
    }

    func recordRun(projectId: String, taskType: String, success: Bool, summary: String, reportPath: String? = nil, durationMs: Int) {
        let record = RunRecord(
            id: UUID().uuidString,
            projectId: projectId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            taskType: taskType,
            success: success,
            summary: summary,
            reportPath: reportPath,
            durationMs: durationMs
        )
        runHistory.insert(record, at: 0)
        if runHistory.count > 500 { runHistory = Array(runHistory.prefix(500)) }

        if let idx = projects.firstIndex(where: { $0.id == projectId }) {
            projects[idx].runCount += 1
            if success { projects[idx].successCount += 1 }
            projects[idx].lastRunAt = record.timestamp
        }
        save()
    }

    func historyFor(projectId: String, limit: Int = 20) -> [RunRecord] {
        Array(runHistory.filter { $0.projectId == projectId }.prefix(limit))
    }
}

// MARK: - items目上下文工具

final class ProjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "project",
        summary: "Manage project context via action. Actions: current/list/create/select/delete/history/generate_tweak. Params: action, name/bundle_id/app_name/dylib_path(create), project_id(select/delete/history). Use for switch between projects (different target app/dylib), save project state, generate tweak template.",
        parameters: [
            "action": "current | list | create | select | delete | history | generate_tweak",
            "name": "Project name (for create/select/generate_tweak)",
            "bundle_id": "Target app bundle ID (for create/generate_tweak)",
            "app_name": "Target app name (for create)",
            "dylib_path": "Dylib path (for create/update)",
            "project_id": "Project id (for select/delete/history)"
        ], verified: true, category: "build")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "current"

        switch action {
        case "current":
            if let p = ProjectContext.shared.currentProject {
                return [
                    "project": [
                        "id": p.id, "name": p.name,
                        "target_bundle_id": p.targetBundleId,
                        "target_app_name": p.targetAppName,
                        "dylib": p.dylibName,
                        "run_count": p.runCount,
                        "success_count": p.successCount,
                        "success_rate": p.runCount > 0 ? "\(Int(Double(p.successCount) / Double(p.runCount) * 100))%" : "N/A",
                        "last_run": p.lastRunAt ?? "never run"
                    ],
                    "hint": "AI should use this project's target App and dylib; no need for user to repeat"
                ]
            }
            return ["current": "none", "hint": "no current project, use action=create or action=list"]

        case "list":
            return [
                "projects": ProjectContext.shared.projects.map { [
                    "id": $0.id, "name": $0.name,
                    "target": $0.targetAppName,
                    "runs": $0.runCount,
                    "success": "\($0.successCount)/\($0.runCount)"
                ]},
                "count": ProjectContext.shared.projects.count
            ]

        case "create":
            guard let name = params["name"] as? String,
                  let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("create requires name and bundle_id")
            }
            let appName = params["app_name"] as? String ?? bundleId
            let dylibPath = params["dylib_path"] as? String ?? ""
            let p = ProjectContext.shared.createProject(name: name, bundleId: bundleId, appName: appName, dylibPath: dylibPath)
            return ["created": true, "project_id": p.id, "name": p.name]

        case "select":
            guard let id = params["project_id"] as? String else {
                throw MCPError.invalidParams("select requires project_id")
            }
            ProjectContext.shared.selectProject(id)
            return ["selected": id]

        case "delete":
            guard let id = params["project_id"] as? String else {
                throw MCPError.invalidParams("delete requires project_id")
            }
            ProjectContext.shared.deleteProject(id)
            return ["deleted": id]

        case "history":
            let projectId = params["project_id"] as? String ?? ProjectContext.shared.currentProjectId ?? ""
            let history = ProjectContext.shared.historyFor(projectId: projectId)
            return [
                "project_id": projectId,
                "runs": history.map { [
                    "time": $0.timestamp,
                    "task": $0.taskType,
                    "success": $0.success,
                    "summary": $0.summary,
                    "duration_ms": $0.durationMs
                ]},
                "count": history.count
            ]

        case "generate_tweak":
            return try ProjectGenerateTweakTool().invoke(params)

        default:
            return ["error": "unknown action: \(action)"]
        }
    }
}

// MARK: - 任务模板

final class TaskTemplateRunner {
    static let shared = TaskTemplateRunner()

    enum TemplateType: String {
        case diagnoseInjection = "diagnose_injection"
        case captureCrash = "capture_crash"
        case injectVerify = "inject_verify"
        case ipaHealth = "ipa_health"
        case performanceRegression = "perf_regression"
        case emergencyRecover = "emergency_recover"
        case networkProbe = "network_probe"
        case crashTriage = "crash_triage"
    }

    struct TemplateResult {
        let success: Bool
        let summary: String
        let steps: [[String: Any]]
        let reportPath: String?
        let durationMs: Int
    }

    func listTemplates() -> [[String: Any]] {
        return [
            ["id": "diagnose_injection", "name": "diagnose injection failed", "desc": "auto-check permission, arch, signature, dependencies, process state; give cause and fix"],
            ["id": "capture_crash", "name": "capture crash scene", "desc": "stop App -> collect logs -> analyze crash -> generate repro hook template"],
            ["id": "inject_verify", "name": "injection verify loop", "desc": "inject -> launch -> check load -> verify hook -> auto rollback on failure"],
            ["id": "ipa_health", "name": "IPA health check", "desc": "parse arch/signature/dependencies/encryption, output injection feasibility report"],
            ["id": "perf_regression", "name": "performance regression test", "desc": "launch -> sample 30s -> compare history -> output regression verdict"],
            ["id": "emergency_recover", "name": "Emergency Recovery", "desc": "Scan injection state → restore all backups → verify launch (life-saver flow when the app won't open)"],
            ["id": "network_probe", "name": "Packet Capture Analysis", "desc": "inject NetworkTweak → open the app and collect → stop → request list → statistical analysis"],
            ["id": "crash_triage", "name": "Crash Triage", "desc": "Startup diagnosis → crash analysis → log collection → cause + fix suggestions"]
        ]
    }

    func run(_ type: TemplateType, bundleId: String, dylibPath: String? = nil,
             options: [String: Any] = [:]) -> TemplateResult {
        let start = Date()
        var steps: [[String: Any]] = []
        var success = false
        var summary = ""
        var reportPath: String?

        switch type {
        case .diagnoseInjection:
            // 1. Device environment check
            let probe = DeviceProbe.shared.run()
            steps.append(["step": "Device environment check", "success": probe.ready, "detail": probe.ready ? "ready" : "not ready"])

            // 2. Injection diagnosis
            let diagnose = InjectionDiagnoseTool()
            if let result = try? diagnose.invoke(["bundle_id": bundleId]) {
                let issues = result["issues"] as? [String] ?? []
                steps.append(["step": "Injection diagnosis", "success": issues.isEmpty, "detail": issues.isEmpty ? "no issues" : issues.joined(separator: "; ")])

                // 3. 知识库匹配
                if !issues.isEmpty {
                    let kb = KnowledgeBaseTool()
                    if let kbResult = try? kb.invoke(["error": issues.joined(separator: " ")]) {
                        let matches = kbResult["matches"] as? [[String: String]] ?? []
                        if !matches.isEmpty {
                            summary = "Found \(issues.count) issues:\n" + matches.map { "\($0["keyword"] ?? ""): \($0["fix"] ?? "")" }.joined(separator: "\n")
                        } else {
                            summary = "Found \(issues.count) issues, no known fix in the knowledge base:\n" + issues.joined(separator: "\n")
                        }
                    }
                } else {
                    summary = "Injection environment OK, no issues found"
                    success = true
                }
            }

        case .injectVerify:
            guard let dylib = dylibPath else {
                return TemplateResult(success: false, summary: "dylib_path required", steps: [], reportPath: nil, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            }

            // 1. 预检
            let dylibInspect = DylibInspectTool()
            if let dylibResult = try? dylibInspect.invoke(["path": dylib]) {
                let compatible = (dylibResult["compatibility"] as? String)?.contains("✅") ?? false
                steps.append(["step": "dylib precheck", "success": compatible, "detail": dylibResult["compatibility"] as? String ?? ""])
                if !compatible {
                    summary = "dylib incompatible: \(dylibResult["compatibility"] ?? "")"
                    break
                }
            }

            // 2. 杀进程
            let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(findPid(by: bundleId))"])
            Thread.sleep(forTimeInterval: 1)
            steps.append(["step": "Stop target app", "success": true])

            // 3. 注入
            do {
                let injectResult = try InjectionManager.shared.enable(
                    bundleId: bundleId,
                    dylibName: "@rpath/\(URL(fileURLWithPath: dylib).lastPathComponent)",
                    dylibSourcePath: dylib
                )
                let injected = injectResult["injected"] as? Bool ?? false
                steps.append(["step": "Run injection", "success": injected, "detail": injected ? "OK" : "failed"])

                if injected {
                    // 4. Launch verify
                    let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
                    Thread.sleep(forTimeInterval: 5)
                    let pid = findPid(by: bundleId)
                    let started = pid > 0
                    steps.append(["step": "Launch verify", "success": started, "detail": started ? "PID=\(pid)" : "crashed after launch"])

                    if started {
                        // 5. 检查 dylib 加载
                        let inspect = InjectionManager.shared.inspect(bundleId)
                        let loaded = inspect["injected"] as? Bool ?? false
                        steps.append(["step": "dylib load check", "success": loaded])
                        success = loaded
                        summary = loaded ? "Injection OK and verified, app runs normally" : "Injection OK but dylib not loaded"
                    } else {
                        // 启动failed，Auto rollback
                        let apps = AppCatalog.list()
                        if let target = apps.first(where: { $0.bundleId == bundleId }) {
                            let exec = (NSDictionary(contentsOfFile: target.path.appending("/Info.plist"))?["CFBundleExecutable"] as? String) ?? ""
                            let backup = target.path.appending("/\(exec).bak_macho")
                            if FileManager.default.fileExists(atPath: backup) {
                                let _ = InjectionManager.shared.spawnRoot("/bin/cp", args: [backup, target.path.appending("/\(exec)")])
                                steps.append(["step": "Auto rollback", "success": true, "detail": "backup restored"])
                            }
                        }
                        // 采集崩溃
                        let crashTool = DiagnoseCrashTool()
                        if let crashResult = try? crashTool.invoke(["bundle_id": bundleId]) {
                            let analyses = crashResult["analyses"] as? [[String: Any]] ?? []
                            if let first = analyses.first, let cause = first["root_cause"] as? String {
                                summary = "Crash on launch after injection, auto-rolled back. Cause: \(cause)"
                            } else {
                                summary = "Crash on launch after injection, auto-rolled back"
                            }
                        }
                    }
                } else {
                    summary = "Injection failed"
                }
            } catch {
                summary = "Injection error: \(error.localizedDescription)"
                steps.append(["step": "Run injection", "success": false, "detail": error.localizedDescription])
            }

        case .captureCrash:
            // 1. 停止 App
            let pid = findPid(by: bundleId)
            if pid > 0 { let _ = InjectionManager.shared.spawnRoot("/bin/kill", args: ["-9", "\(pid)"]) }
            steps.append(["step": "Stop app", "success": true])

            // 2. Collect logs
            let logTool = LogCollectTool()
            if let logResult = try? logTool.invoke(["bundle_id": bundleId, "type": "all"]) {
                steps.append(["step": "Collect logs", "success": true, "detail": "collected \(logResult["count"] ?? 0) files"])
            }

            // 3. 分析崩溃
            let crashTool = DiagnoseCrashTool()
            if let crashResult = try? crashTool.invoke(["bundle_id": bundleId]) {
                let analyses = crashResult["analyses"] as? [[String: Any]] ?? []
                if let first = analyses.first {
                    let cause = first["root_cause"] as? String ?? "unknown"
                    let fix = first["fix"] as? String ?? ""
                    steps.append(["step": "crash analysis", "success": true, "detail": cause])
                    summary = "Crash cause: \(cause)\nFix suggestion: \(fix)"
                    success = true

                    // 4. 生成复现模板
                    if let crashLog = first["stack_top10"] as? [String] {
                        let reproTool = CrashReproTool()
                        if let reproResult = try? reproTool.invoke(["crash_log": crashLog.joined(separator: "\n"), "bundle_id": bundleId]) {
                            steps.append(["step": "generate repro template", "success": true, "detail": reproResult["template_path"] as? String ?? ""])
                        }
                    }
                } else {
                    summary = "no crash log found"
                }
            }

        case .ipaHealth:
            // 用 ipa.inspect
            let apps = AppCatalog.list()
            if let target = apps.first(where: { $0.bundleId == bundleId }) {
                let ipaTool = IPAInspectTool()
                if let result = try? ipaTool.invoke(["path": target.path, "detail": "basic"]) {
                    let feasibility = result["inject_feasibility"] as? [String] ?? []
                    steps.append(["step": "IPA parse", "success": true])
                    summary = feasibility.joined(separator: "\n")
                    success = !feasibility.contains(where: { $0.contains("⚠️") })
                }
            }

        case .performanceRegression:
            // 启动 + 采样
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            Thread.sleep(forTimeInterval: 3)
            let statsTool = AppStatsTool()
            if let result = try? statsTool.invoke(["bundle_id": bundleId, "duration": 30]) {
                steps.append(["step": "Performance sampling 30s", "success": true])
                if let cpu = result["cpu"] as? [String: String],
                   let mem = result["memory"] as? [String: Any] {
                    summary = "CPU avg \(cpu["avg"] ?? "")%, peak \(cpu["max"] ?? "")%\nMemory peak \(mem["max_kb"] ?? "") KB, \(mem["leak_suspect"] ?? "")"
                    success = true
                }
            }

        case .emergencyRecover:
            // 1. 扫描注入/备份状态
            let scanTool = RescueScanTool()
            if let scanResult = try? scanTool.invoke([:]) {
                let injected = scanResult["injected_apps"] as? [[String: Any]] ?? []
                let backups = scanResult["backups"] as? [[String: Any]] ?? []
                steps.append(["step": "Scan injection state", "success": true,
                              "detail": "injected \(injected.count), backups \(backups.count)"])
            }
            // 2. 恢复全部备份
            let recoverTool = RescueRecoverAllTool()
            if let recoverResult = try? recoverTool.invoke([:]) {
                let restored = recoverResult["restored_count"] as? Int ?? 0
                let failed = recoverResult["failed_count"] as? Int ?? 0
                steps.append(["step": "Restore all backups", "success": failed == 0,
                              "detail": "restored \(restored), failed \(failed)"])
                success = failed == 0
            }
            // 3. 验证目标 App 启动
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            Thread.sleep(forTimeInterval: 4)
            let pid = findPid(by: bundleId)
            steps.append(["step": "Verify launch", "success": pid > 0, "detail": pid > 0 ? "PID=\(pid)" : "not running"])
            summary = success ? "All injection backups restored, target app launches normally" : "Restore done but some items failed, see the report"

        case .networkProbe:
            // 1. 停旧抓包
            let capTool = NetworkCaptureTool()
            let _ = try? capTool.invoke(["action": "stop"])
            // 2. 确认 NetworkTweak 已注入
            let injected = (InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false
            if !injected {
                let dylib = ProcessHelper.tweakPath("NetworkTweak.dylib") ?? ""
                if dylib.isEmpty {
                    return TemplateResult(success: false, summary: "Built-in NetworkTweak.dylib not found", steps: [], reportPath: nil, durationMs: 0)
                }
                let r = try? InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
                if (r?["status"] as? String) != "injected" {
                    return TemplateResult(success: false, summary: "NetworkTweak injection failed", steps: [], reportPath: nil, durationMs: 0)
                }
            }
            steps.append(["step": "NetworkTweak ready", "success": true])
            // 3. 开始抓包
            let startResult = try? capTool.invoke(["action": "start", "bundle_id": bundleId])
            steps.append(["step": "Start capture", "success": startResult != nil])
            // 4. 打开 App 并等待采集
            let _ = InjectionManager.shared.spawnRoot("/usr/bin/open", args: [bundleId])
            let waitSec = (options["duration"] as? Int) ?? 8
            Thread.sleep(forTimeInterval: TimeInterval(waitSec))
            // 5. 停止
            let _ = try? capTool.invoke(["action": "stop"])
            // 6. Request list
            let limit = (options["limit"] as? Int) ?? 50
            var reqCount = 0
            if let listResult = try? capTool.invoke(["action": "requests", "limit": limit]) {
                let reqs = listResult["requests"] as? [[String: Any]] ?? []
                reqCount = reqs.count
                steps.append(["step": "Request list", "success": true, "detail": "captured \(reqCount) entries"])
            }
            // 7. Statistical analysis
            if let anaResult = try? capTool.invoke(["action": "analyze"]) {
                steps.append(["step": "Statistical analysis", "success": true, "detail": "done"])
                summary = "Capture done: \(reqCount) request entries.\n" + ((anaResult["summary"] as? String) ?? "")
                success = reqCount > 0
            }

        case .crashTriage:
            // 1. 启动诊断 (自动拉起 App 判断是否闪退）
            let startupTool = DiagnoseStartupTool()
            var startedOK = false
            if let sr = try? startupTool.invoke(["bundle_id": bundleId]) {
                startedOK = (sr["started"] as? Bool) ?? false
                steps.append(["step": "Startup diagnosis", "success": startedOK,
                              "detail": startedOK ? "launches normally" : "launch failed/crashed"])
            }
            // 2. 崩溃分析
            let crashTool = DiagnoseCrashTool()
            if let cr = try? crashTool.invoke(["bundle_id": bundleId]) {
                let analyses = cr["analyses"] as? [[String: Any]] ?? []
                if let first = analyses.first {
                    let cause = first["root_cause"] as? String ?? "unknown"
                    let fix = first["fix"] as? String ?? ""
                    steps.append(["step": "crash analysis", "success": true, "detail": cause])
                    summary = "Cause: \(cause)\nFix suggestion: \(fix)"
                    success = !startedOK
                } else {
                    steps.append(["step": "crash analysis", "success": false, "detail": "no crash log found"])
                    summary = startedOK ? "App launched normally, no crash records" : "Launch failed but no crash log found (may be injection-related, try emergency_recover)"
                    success = startedOK
                }
            }
            // 3. Collect logs兜底
            let logTool = LogCollectTool()
            if let lr = try? logTool.invoke(["bundle_id": bundleId, "type": "all"]) {
                steps.append(["step": "Log collection", "success": true, "detail": "collected \(lr["count"] ?? 0) files"])
            }
        }

        // 生成报告
        let workspace = NSHomeDirectory().appending("/Documents/Workspace/reports")
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let reportId = UUID().uuidString.prefix(8).description
        let report: [String: Any] = [
            "task_type": type.rawValue,
            "bundle_id": bundleId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "success": success,
            "summary": summary,
            "steps": steps,
            "duration_ms": Int(Date().timeIntervalSince(start) * 1000)
        ]
        reportPath = workspace.appending("/\(type.rawValue)_\(reportId).json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: reportPath!))
        }

        // 记录到项目历史
        if let project = ProjectContext.shared.currentProject {
            ProjectContext.shared.recordRun(
                projectId: project.id,
                taskType: type.rawValue,
                success: success,
                summary: summary,
                reportPath: reportPath,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
        }

        return TemplateResult(success: success, summary: summary, steps: steps, reportPath: reportPath, durationMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
