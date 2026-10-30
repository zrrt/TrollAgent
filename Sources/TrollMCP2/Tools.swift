import Foundation
import UIKit

// MARK: - 已内联进大工具的历史独立工具（保留类供引用/兼容）：
//   artifact.* → ArtifactExecTool（read/write/list 内联，见 v4.0.0）
//   device.* → DeviceExecTool（委托调用 DeviceInfoTool/DeviceProbeTool 等）

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "Get device info: iOS version, iPhone model, memory/storage, battery, TrollAgent version, workspace path. Use for: check what iOS version, know device specs, find workspace path. Don't use for: spoof/change device info (use device.fake), wipe keychain (use device.keychain_wipe). Example: user says 'what model is my phone' → get device info.", verified: true, category: "device")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "system": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "workspace": Workspace.root.path,
        ]
    }
}

final class DeviceProbeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.probe",
        summary: "Probe/check device environment: TrollStore installed, can we inject, what permissions available. Use for: check if device supports injection, see what capabilities are available. Don't use for: get device specs (use device.info), check battery/memory (use device snapshot subcommand). Example: user says 'can my phone inject, how is the environment' → probe device.",
        verified: true, category: "device")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = DeviceProbe.shared.run()
        // v2.9.125：CLI 式一句话结论 (dispatch 取 message 放顶层）
        let failedChecks = r.checks.filter { !$0.passed }
        let message: String
        if r.ready {
            message = "environment ready (TrollStore OK, permissions OK, toolchain OK)"
        } else {
            let labels = failedChecks.prefix(3).map { $0.label }.joined(separator: "、")
            message = "environment not ready: \(labels.isEmpty ? "unknown reason" : labels)"
        }
        return [
            "message": message,
            "device": [
                "name": r.deviceName,
                "model": r.model,
                "systemVersion": r.systemVersion,
                "vendorID": r.vendorID,
            ],
            "trollStore": r.trollStore,
            "trollFools": r.trollFools,
            "task_for_pid": r.taskForPid,
            "appContainerWrite": r.containerWrite,
            "injectionBinaries": r.injectionBinaries,
            "amfidBypassInferred": r.amfidBypassInferred,
            "entitlementsOK": r.entitlementsOK,
            "rootDiagnosis": r.rootDiagnosis ?? [:],
            "ready": r.ready,
            "issues": failedChecks.map { $0.label },
            "checks": r.checks.map { ["label": $0.label, "passed": $0.passed, "detail": $0.detail] },
        ]
    }
}

// MARK: - MemoryTweak (H5GG 式内存修改，通过注入的 dylib HTTP API 通信）

final class MemoryTweakTool: MCPTool {
    let definition = ToolDefinition(
        name: "memory",
        summary: "Game memory modification (GameGuardian/H5GG style). Actions: attach / search / refine / write / freeze / unfreeze / status / frozen / results. Params: value (search/refine/write/freeze), type (int/int64/float/double/byte/short), address (0x hex, required for write/freeze/unfreeze). Requires MemoryTweak.dylib injected into target game. Search strategy: exact → changed → unknown → increased/decreased; too many results → play more and refine to 1-10 candidates; 0 results → value may be encrypted/hashed, try float type / search -1 / ± offsets.",
        parameters: [
            "action": "attach (confirms injected and connected; after dylib injection the service is attached, equivalent to status) / search (first scan) / refine (filter results) / write (set new value) / freeze (lock value) / unfreeze / status / frozen (list locked values)",
            "value": "Value to search/write/freeze. e.g. 1000 coins, 50 HP",
            "type": "Data type: int (integer, default) / int64 / float (decimal) / double / byte / short",
            "address": "Memory address (0x hex format, required for write/freeze)"
        ],
        prerequisites: ["Target game must have MemoryTweak.dylib injected (inject enable MemoryTweak to the target app first)", "attach/status confirm the connection works (HTTP 127.0.0.1:8765 reachable) before search/refine/write/freeze"]
    )

    private let port = 8765

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required")
        }

        let method: String
        let path: String
        var body: [String: Any] = [:]

        switch action {
        // v3.1.69: attach —— 指引里反复提 "memory attach"，但此前无此动作 (AI 反馈属实）。
        // MemoryTweak.dylib 被注入目标进程后 HTTP 服务即已 attach (无独立 attach 端点），
        // attach 动作等价确认服务在线/进程已注入，转发 /status。
        case "attach":
            method = "GET"; path = "/status"
        case "search":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for search") }
            method = "POST"; path = "/search"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "refine":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for refine") }
            method = "POST"; path = "/refine"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "write":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for write")
            }
            method = "POST"; path = "/write"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "freeze":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for freeze")
            }
            method = "POST"; path = "/freeze"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "unfreeze":
            guard let addr = params["address"] as? String else { throw MCPError.invalidParams("address required for unfreeze") }
            method = "POST"; path = "/unfreeze"
            body = ["address": addr]
        case "status":
            method = "GET"; path = "/status"
        case "frozen":
            method = "GET"; path = "/frozen"
        case "results":
            method = "GET"; path = "/results"
        default:
            throw MCPError.invalidParams("unknown action: \(action)")
        }

        return try httpRequest(method: method, path: path, body: body)
    }

    private func httpRequest(method: String, path: String, body: [String: Any]) throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        setHTTPMethod(method, on: &request)
        setTimeoutInterval(30, on: &request)

        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 35)

        if let error = resultError {
            return ["error": "failed to connect MemoryTweak (\(error.localizedDescription). Confirm MemoryTweak.dylib injected into target App and target App is running.", "connected": false]
        }
        guard let data = resultData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "failed to parse response", "connected": false]
        }
        return json
    }
}



// MARK: - v3.1.39: artifact 大工具 + 子命令 (合并 3 个 artifact.* 工具）

final class ArtifactExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact",
        summary: "Manage workspace files. Subcommands: read / write / list / output_name_get / output_name_set / output_bookmark. Params: filename (read/write), text (write), name (output_name_set). App container files use container.*, system files use shell.exec.",
        parameters: [
            "command": "Subcommand (required): read / write / list / output_name_get / output_name_set / output_bookmark",
            "filename": "File name — REQUIRED for read/write",
            "text": "Text to write — REQUIRED for write",
            "name": "Output name — REQUIRED for output_name_set"
        ],
        verified: true, category: "fs")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("artifact", detail: command)
        
        switch command {
        case "read":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required. Usage: artifact read filename:report.txt")
            }
            // v4.0.0: 内联自 ArtifactReadTextTool（修复原委托调用传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            let text = try String(contentsOf: url, encoding: .utf8)
            return ["content": text]
            
        case "write":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required. Usage: artifact write filename:notes.txt text:<content>")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: artifact write filename:notes.txt text:<content>")
            }
            // v4.0.0: 内联自 ArtifactWriteTextTool（修复委托传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ["written": true, "bytes": text.utf8.count]
            
        case "list":
            // v4.0.0: 内联自 ArtifactListTool（subpath 可选；文件返回单条，目录返回前 50 条）
            let sub = params["subpath"] as? String ?? ""
            let dir = try Workspace.resolve(sub)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
                return ["entries": [], "error": "path does not exist: \(sub)"]
            }
            if !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return ["entries": [
                    ["name": dir.lastPathComponent,
                     "path": dir.path,
                     "isDirectory": false,
                     "size": size,
                     "hint": "this is a file not a directory; to read it use artifact read (text) or shell.exec for the raw file"]
                ]]
            }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let entries = items.map { name -> [String: Any] in
                var isD: ObjCBool = false
                let p = (dir.path as NSString).appendingPathComponent(name)
                _ = FileManager.default.fileExists(atPath: p, isDirectory: &isD)
                return ["name": name, "path": p, "isDirectory": isD.boolValue]
            }
            let limited = Array(entries.prefix(50))
            return ["entries": limited, "total": entries.count, "truncated": entries.count > 50, "hint": entries.count > 50 ? "directory has \(entries.count) items, only first 50 returned; use shell.exec find for precise search" : ""]

        case "output_name_get":
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            return ["name": UserDefaults.standard.string(forKey: "trollmcp2.output_name") ?? "artifact"]

        case "output_name_set":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required. Usage: artifact output_name_set name:<output name>")
            }
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            UserDefaults.standard.set(name, forKey: "trollmcp2.output_name")
            return ["set": name]

        case "output_bookmark":
            // v4.0.0: 内联自 WorkspaceOutputBookmarkTool（返回当前输出书签路径，默认工作区根）
            let key = "trollmcp2.output_bookmark"
            return ["bookmark": UserDefaults.standard.string(forKey: key) ?? "/var/mobile/Documents/Workspace"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: read/write/list/output_name_get/output_name_set/output_bookmark")
        }
    }
}

// MARK: - v3.1.40: device 大工具 + 子命令 (合并 4 个 device.* 工具）

final class DeviceExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "device",
        summary: "Device info & identity spoofing. Subcommands: info / probe / fake / restore / advertising / idfv / snapshot. fake spoofs device identity, restore reverts, snapshot captures state. App management use app.*.",
        parameters: [
            "command": "Subcommand: info / probe / fake / restore / advertising / idfv / snapshot"
        ],
        verified: true, category: "device")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("device", detail: command)
        
        switch command {
        case "info":
            return try DeviceInfoTool().invoke([:])
            
        case "probe":
            return try DeviceProbeTool().invoke([:])
            
        case "fake":
            return try DeviceFakeTool().invoke([:])
            
        case "restore":
            return try DeviceRestoreTool().invoke([:])

        case "advertising":
            return try AdvertisingTool().invoke([:])

        case "idfv":
            return try IdfvTool().invoke([:])

        case "snapshot":
            return try DeviceSnapshotTool().invoke([:])

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: info/probe/fake/restore/advertising/idfv/snapshot")
        }
    }
}

// MARK: - v3.1.41: container 大工具 + 子命令 (合并 3 个 container.* 工具）


// MARK: - v3.1.42: diagnose 大工具 + 子命令 (合并 2 个 diagnose.* 工具）

final class DiagnoseExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose",
        summary: "Diagnose app/injection issues (startup/injection). Use subcommand to specify action. Use for: diagnose why app won't launch, why injection failed. Don't use for: fix issues (use inject.*), restart app (use app restart). Example: startup → diagnose startup bundle_id:com.xxx; injection → diagnose injection bundle_id:com.xxx. Subcommands: startup / injection.",
        parameters: [
            "command": "Subcommand: startup / injection",
            "bundle_id": "App bundle ID"
        ],
        verified: true, category: "diagnose", prerequisites: ["App installed and bundle_id valid (confirm with app status first)", "startup diagnosis needs the app to have been launched (crash logs only exist then)"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("diagnose", detail: command)
        
        switch command {
        case "startup":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try DiagnoseStartupTool().invoke(["bundle_id": bundleId])
            
        case "injection":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionDiagnoseTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: startup/injection")
        }
    }
}

// MARK: - v3.1.43: memory 大工具 + 子命令 (合并 3 个 assistant.memory.* 工具）

final class MemoryExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant_memory",
        summary: "Manage assistant memory (set/list/delete). Use subcommand to specify action. Use for: save/list/delete memory notes. Don't use for: game memory modification (use memory action:search). Example: set → assistant_memory set key:user name value:xxx; list → assistant_memory list. Subcommands: set / list / delete.",
        parameters: [
            "command": "Subcommand: set / list / delete",
            "key": "Memory key (for set/delete)",
            "value": "Memory value (for set)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("assistant_memory", detail: command)
        
        switch command {
        case "set":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            guard let value = params["value"] as? String else {
                throw MCPError.invalidParams("value required")
            }
            return try AssistantMemorySetTool().invoke(["key": key, "value": value])
            
        case "list":
            return try AssistantMemoryListTool().invoke([:])
            
        case "delete":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            return try AssistantMemoryDeleteTool().invoke(["key": key])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: set/list/delete")
        }
    }
}

// MARK: - v3.1.44: verify 大工具 + 子命令 (合并 2 个 verify.* 工具）


// MARK: - v3.1.45: ssh 大工具 + 子命令 (合并 2 个 ssh.* 工具）

final class SshExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "ssh",
        summary: "SSH remote connection (exec/scp). Use subcommand to specify action. Use for: run commands on remote server, transfer files. Don't use for: local shell (use shell.exec). Example: exec → ssh exec command:ls -la; scp → ssh scp local:xxx remote:/xxx. Subcommands: exec / scp.",
        parameters: [
            "command": "Subcommand: exec / scp",
            "cmd": "Command to run (for exec)",
            "local": "Local file path (for scp)",
            "remote": "Remote file path (for scp)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("ssh", detail: command)
        
        switch command {
        case "exec":
            guard let cmd = params["cmd"] as? String else {
                throw MCPError.invalidParams("cmd required")
            }
            return try SSHTool().invoke(["command": cmd])
            
        case "scp":
            guard let local = params["local"] as? String else {
                throw MCPError.invalidParams("local required")
            }
            guard let remote = params["remote"] as? String else {
                throw MCPError.invalidParams("remote required")
            }
            return try SCPTool().invoke(["local": local, "remote": remote])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: exec/scp")
        }
    }
}

// MARK: - v3.1.48: macro 大工具 + 子命令 (合并 6 个 macro.* 工具）


// MARK: - v3.1.50: knowledge 大工具 + 子命令 (合并 4 个 knowledge.* 工具）

final class KnowledgeExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "knowledge",
        summary: "Persistent knowledge base. Commands: import_text / import_file / search / delete / clear. Params: text (import_text), name (import_text/delete), path (import_file), query (search). Chat memory use memory.*.",
        parameters: [
            "command": "Subcommand: import_text / import_file / search / delete / clear",
            "text": "Text to import (for import_text)",
            "name": "Entry name (optional for import_text, required for delete)",
            "path": "File path (for import_file)",
            "query": "Search query (for search)",
            "id": "Knowledge entry name (alias for name, for delete)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("knowledge", detail: command)
        
        switch command {
        case "import_text":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required")
            }
            // v4.3.66：子工具要求 name+content（此前只传 text 必崩）；name 缺省自动生成
            let name = params["name"] as? String ?? "Note-\(Int(Date().timeIntervalSince1970))"
            return try KnowledgeImportTextTool().invoke(["name": name, "content": text])
            
        case "import_file":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try KnowledgeImportFileTool().invoke(["path": path])
            
        case "search":
            guard let query = params["query"] as? String else {
                throw MCPError.invalidParams("query required")
            }
            return try KnowledgeSearchTool().invoke(["query": query])
            
        case "delete":
            // v4.3.66：子工具要求 name（此前传 id 必崩）；兼容 name/id 两种入参
            guard let name = params["name"] as? String ?? params["id"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try KnowledgeDeleteTool().invoke(["name": name])

        case "clear":
            let removed = KnowledgeStore.shared.clearAll()
            return ["cleared": true, "removed": removed, "note": "Knowledge base cleared (incl. session_memory.md, will auto-rebuild)"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: import_text/import_file/search/delete/clear")
        }
    }
}

// MARK: - v3.1.51: location 大工具 + 子命令 (合并 4 个 location.* 工具）

final class LocationExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "location",
        summary: "Manage location (get/fake/status/clear). Use subcommand to specify action. Use for: get current location, fake location. Don't use for: device info (use device info). Example: get → location get; fake → location fake lat:39.9 lng:116.4. Subcommands: get / fake / status / clear.",
        parameters: [
            "command": "Subcommand: get / fake / status / clear",
            "lat": "Latitude (for fake)",
            "lng": "Longitude (for fake)"
        ],
        verified: true, category: "device")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("location", detail: command)
        
        switch command {
        case "get":
            return try LocationGetTool().invoke([:])
            
        case "fake":
            guard let lat = params["lat"] as? Double else {
                throw MCPError.invalidParams("lat required")
            }
            guard let lng = params["lng"] as? Double else {
                throw MCPError.invalidParams("lng required")
            }
            return try LocationFakeTool().invoke(["lat": lat, "lng": lng])
            
        case "status":
            return try LocationFakeStatusTool().invoke([:])
            
        case "clear":
            return try LocationFakeClearTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: get/fake/status/clear")
        }
    }
}

// MARK: - v3.1.52: github 大工具 + 子命令 (合并 4 个 github.* 工具）

final class GitHubExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "github",
        summary: "GitHub CI automation. Commands: account_status / trigger_build / fetch_runs / download_artifact. Params: workflow (build-trollmcp2.yml or build-tweak.yml), tweak, ref (default main), run_id (for download_artifact).",
        parameters: [
            "command": "Subcommand: account_status / trigger_build / fetch_runs / download_artifact",
            "workflow": "Workflow file for trigger_build: build-trollmcp2.yml (default, build IPA) or build-tweak.yml (build tweak dylib)",
            "tweak": "Only for tweak trigger_build: tweak project name (e.g. ProbeAgent / ConfigHook / NetworkTweak)",
            "ref": "Git branch to build (default main)",
            "run_id": "Run ID (for download_artifact)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("github", detail: command)
        
        switch command {
        case "account_status":
            return try GitHubAccountStatusTool().invoke([:])
            
        case "trigger_build":
            return try GitHubTriggerBuildTool().invoke(params)
            
        case "fetch_runs":
            return try GitHubFetchRunsTool().invoke(params)
            
        case "download_artifact":
            guard let runId = params["run_id"] as? Int else {
                throw MCPError.invalidParams("run_id required")
            }
            return try GitHubDownloadArtifactTool().invoke(["run_id": runId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: account_status/trigger_build/fetch_runs/download_artifact")
        }
    }
}

// MARK: - v4.5.x: DownloadTool —— 大文件下载（URLSession + 实时进度条）

/// 大文件下载工具。shell.exec 的 curl 受 120s 上限限制，大文件（>20MB）会超时被 SIGKILL；
/// 本工具走 URLSessionDownloadTask（无 120s 限制），进度经 InstallationRegistry.setFraction
/// 实时渲染到 UI（"下载中 N/100"），用户与 AI 都能看到。
