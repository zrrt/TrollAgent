import Foundation
import UIKit

// MARK: - GitHub 线上编译工具 (v2.9.9）
// 让 AI 感知 App 内 GitHub 账号登录状态，并可触发线上编译、查进度、下载产物到本地工作区。
// 账号/仓库配置与 GitHubAccountStore (UI 层）共享同一份 UserDefaults 持久化。

private enum GHStoreKeys {
    static let owner = "trollmcp2.github_repo_owner"
    static let repo = "trollmcp2.github_repo_name"
    static let workflow = "trollmcp2.github_workflow_id"
    static let branch = "trollmcp2.github_branch"
    static let accounts = "trollmcp2.github_accounts"
    static let active = "trollmcp2.github_active"
    static let clientID = "trollmcp2.github_client_id"
}

/// 轻量读取 GitHub 账号配置 (不依赖 UI 层 ObservableObject，可在工具线程安全读取）
/// v4.3.66：由 private 改为 internal（InstallTools.swift 跨文件引用）
struct GHConfig {
    static var repoOwner: String { UserDefaults.standard.string(forKey: GHStoreKeys.owner) ?? "zrrt" }
    static var repoName: String {
        let n = UserDefaults.standard.string(forKey: GHStoreKeys.repo) ?? "TrollAgent"
        return n == "trollmcp2" ? "TrollAgent" : n  // v7.1.285：旧仓库名迁移（trollmcp2 → TrollAgent）
    }
    static var workflowId: String { UserDefaults.standard.string(forKey: GHStoreKeys.workflow) ?? "build-trollmcp2.yml" }
    static var branch: String { UserDefaults.standard.string(forKey: GHStoreKeys.branch) ?? "main" }
    static var clientID: String { UserDefaults.standard.string(forKey: GHStoreKeys.clientID) ?? "Ov23li890n3hM15edlcw" }
    static var apiBase: String { "https://api.github.com" }

    /// 当前激活账号 token (与 UI 层同源）
    static var activeToken: String? {
        let active = UserDefaults.standard.string(forKey: GHStoreKeys.active)
        guard let data = UserDefaults.standard.data(forKey: GHStoreKeys.accounts),
              let accounts = try? JSONDecoder().decode([GitHubAccount].self, from: data) else { return nil }
        return accounts.first { $0.login == active }?.token
    }
    static var activeLogin: String? {
        UserDefaults.standard.string(forKey: GHStoreKeys.active)
    }
}

/// GitHub 同步请求辅助：semaphore 桥接 URLSession
/// v4.3.66：由 private 改为 internal（InstallTools.swift 跨文件引用）
enum GHAPI {
    static func get(_ urlString: String, token: String?) -> (Int, [String: Any]?, Data?) {
        var result: (Int, [String: Any]?, Data?) = (0, nil, nil)
        guard let url = URL(string: urlString) else { return (0, nil, nil) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json, data)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }

    static func post(_ urlString: String, token: String?, body: [String: Any]) -> (Int, [String: Any]?) {
        var result: (Int, [String: Any]?) = (0, nil)
        guard let url = URL(string: urlString) else { return result }
        var req = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &req)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }
}

/// 查看 GitHub 账号登录状态 + 最近编译 run (AI 感知）
final class GitHubAccountStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.account_status",
        summary: "Check in-app GitHub account login status, repos, recent CI build records",
        parameters: [:],
        verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let login = GHConfig.activeLogin
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        var out: [String: Any] = [
            "logged_in": login != nil,
            "active_login": login ?? "",
            "repo": "\(owner)/\(repo)",
            "workflow": GHConfig.workflowId,
            "branch": GHConfig.branch,
        ]
        // 尝试拉最近 run (有 token 才拉）
        if let token = GHConfig.activeToken {
            let (code, json, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=5&event=workflow_dispatch", token: token)
            if code == 200, let arr = json?["workflow_runs"] as? [[String: Any]] {
                out["http_status"] = code
                out["runs"] = arr.map { d -> [String: Any] in
                    [
                        "id": d["id"] as? Int ?? 0,
                        "status": d["status"] as? String ?? "unknown",
                        "conclusion": d["conclusion"] as? String ?? "",
                        "display_title": d["display_title"] as? String ?? "run",
                    ]
                }
            } else {
                out["http_status"] = code
                out["runs_error"] = "cannot read build runs (HTTP \(code)), check token permission"
            }
        }
        return out
    }
}

/// 触发线上编译 (build-trollmcp2 或 build-tweak）
final class GitHubTriggerBuildTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.trigger_build",
        summary: "Trigger GitHub Actions CI build (compile TrollAgent IPA or tweak). Use for: build new version of TrollAgent, compile a tweak dylib. Don't use for: run local shell commands (use shell.exec), download files (use fs tools). Prerequisite: GitHub account must be logged in. Example: user says 'build new version' → trigger build-trollmcp2.yml workflow.",
        parameters: ["workflow": "Workflow file: build-trollmcp2.yml (default, build IPA) or build-tweak.yml (build tweak dylib)", "tweak": "Only for tweak builds: tweak project name (e.g. CompileProbe / ProbeAgent)", "ref": "Git branch to build (default main)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub, log in first in Settings - GitHub Account")
        }
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        let workflow = params["workflow"] as? String ?? GHConfig.workflowId
        let ref = params["ref"] as? String ?? GHConfig.branch
        var body: [String: Any] = ["ref": ref]
        if let tweak = params["tweak"] as? String, !tweak.isEmpty {
            body["inputs"] = ["tweak": tweak]
        }
        let (code, json) = GHAPI.post(
            "\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/workflows/\(workflow)/dispatches",
            token: token, body: body)
        if code == 204 {
            return ["triggered": true, "workflow": workflow, "ref": ref, "note": "triggered, wait a few seconds then check progress with github.fetch_runs"]
        }
        return ["triggered": false, "http_status": code, "message": (json?["message"] as? String) ?? "trigger failed"]
    }
}

/// 查询最近线上编译进度
final class GitHubFetchRunsTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.fetch_runs",
        summary: "Query recent CI build run status and conclusion",
        parameters: ["limit": "Max results (default 5)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub")
        }
        let limit = params["limit"] as? Int ?? 5
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        let (code, json, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=\(limit)&event=workflow_dispatch", token: token)
        guard code == 200, let arr = json?["workflow_runs"] as? [[String: Any]] else {
            return ["http_status": code, "error": (json?["message"] as? String) ?? "query failed"]
        }
        return ["runs": arr.map { d -> [String: Any] in
            [
                "id": d["id"] as? Int ?? 0,
                "status": d["status"] as? String ?? "unknown",
                "conclusion": d["conclusion"] as? String ?? "",
                "display_title": d["display_title"] as? String ?? "run",
            ]
        }]
    }
}

/// 下载最近OK编译的 artifact 到本地工作区 (注入测试闭环的关键）
final class GitHubDownloadArtifactTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.download_artifact",
        summary: "Download CI build artifact from GitHub Actions. Use for: download the built IPA/dylib after CI finishes. Don't use for: trigger CI build (use github.trigger_build), check build status (use github.account_status). Example: user says 'download the IPA just built' → download artifact.",
        parameters: ["run_id": "Specific run ID (optional, uses latest successful)", "artifact_name": "Artifact name (optional, auto-detects)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub")
        }
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName

        // 1. 确定 run_id
        var runID = params["run_id"] as? Int
        if runID == nil {
            let (rc, rj, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=10&event=workflow_dispatch", token: token)
            guard rc == 200, let arr = rj?["workflow_runs"] as? [[String: Any]] else {
                return ["downloaded": false, "error": "cannot read run list (HTTP \(rc))"]
            }
            guard let latest = arr.first(where: { ($0["conclusion"] as? String) == "success" }) else {
                return ["downloaded": false, "error": "no recent successful build run"]
            }
            runID = latest["id"] as? Int
        }
        guard let rid = runID else { throw MCPError.failed("cannot determine run id") }

        // 2. 查该 run 的 artifacts
        let (ac, aj, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs/\(rid)/artifacts", token: token)
        guard ac == 200, let arts = aj?["artifacts"] as? [[String: Any]], let first = arts.first else {
            return ["downloaded": false, "error": "this run has no artifact (HTTP \(ac))"]
        }
        let artID = first["id"] as? Int ?? 0
        let artName = (params["artifact_name"] as? String) ?? (first["name"] as? String ?? "artifact")

        // 3. 下载 zip
        var data: Data?
        var status = 0
        guard let url = URL(string: "\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/artifacts/\(artID)/zip") else {
            throw MCPError.failed("invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            data = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 65)

        guard status == 200, let zipData = data else {
            return ["downloaded": false, "error": "download failed (HTTP \(status), artifact may be expired or deleted"]
        }

        // 4. 写入工作区 downloads 并解压
        let outDir = try Workspace.resolve("downloads")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let zipPath = outDir.appendingPathComponent("\(artName)_\(rid).zip")
        try zipData.write(to: zipPath)
        let unzipDir = outDir.appendingPathComponent("run_\(rid)")
        try? FileManager.default.removeItem(at: unzipDir)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try? ZipExtractor.unzip(zipPath, to: unzipDir)

        var entries: [String] = []
        if let en = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                    entries.append(u.path.replacingOccurrences(of: unzipDir.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                }
            }
        }
        let dylibs = entries.filter { $0.hasSuffix(".dylib") }
        let debs = entries.filter { $0.hasSuffix(".deb") }
        return [
            "downloaded": true,
            "run_id": rid,
            "artifact_name": artName,
            "zip_path": zipPath.path,
            "unzip_dir": unzipDir.path,
            "bytes": zipData.count,
            "entries": entries,
            "dylibs": dylibs,
            "debs": debs,
            "note": "artifacts extracted to the directory above. Use .dylib with injection.enable into target App; .deb contains tweak package.",
        ]
    }
}
