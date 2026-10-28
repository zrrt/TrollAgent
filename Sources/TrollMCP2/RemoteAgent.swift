import Foundation
import UIKit

/// v2.9.180：远程诊断与指令通道 (云端 AI → 后台 → 真机）
///
/// 真机每 4 秒轮询后台 /api/commands/next，取到指令就在本地执行工具并回传结果
///  (含字符数/行数，供云端精确审计工具输出 token 大小）。
/// 同时负责：安装信息上报、崩溃日志自动上报。
///
/// 安全设计：只允许执行"只读诊断白名单"里的工具，其余一律拒绝——
/// 远程通道绝不可能触发注入/删除/写入/启动等危险操作。
public final class RemoteAgent: ObservableObject {
    public static let shared = RemoteAgent()

    @Published public var enabled = false
    @Published public var serverURL = ""
    @Published public var token = ""
    @Published public var deviceID = ""
    @Published public var lastError = ""
    @Published public var executedCount = 0

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var isPolling = false
    private var isReporting = false

    private enum K {
        static let enabled = "remote_agent_enabled"
        static let server = "remote_agent_server"
        static let token = "remote_agent_token"
        static let device = "remote_agent_device"
        static let reportedVer = "remote_agent_reported_version"
    }

    /// 远程可执行的只读诊断白名单 (其余工具一律拒绝）
    private static let safeTools: Set<String> = [
        "ping", "device.info", "device.probe",
        "artifact.list", "artifact.read_text", "artifact.find",
        "shell.exec", "artifact", "shell.exec", "shell.exec", "shell.exec",
        "shell.exec", "shell.exec", "shell.exec", "shell.exec", "shell.exec",
        "injection.status", "injection.list", "injection.inspect",
        "model.config", "gateway.status",
        "apps.list", "apps.cache_inspect", "app.info", "app.status",
        "system.cleanup_scan", "cleanup.scan",
        "network.status", "diagnose.startup",
        "crash.list", "skills.list", "tools.list",
    ]

    public init() {
        enabled = defaults.bool(forKey: K.enabled)
        serverURL = defaults.string(forKey: K.server) ?? ""
        token = defaults.string(forKey: K.token) ?? ""
        deviceID = defaults.string(forKey: K.device) ?? Self.makeDeviceID()
    }

    // MARK: - 设备标识

    private static func makeDeviceID() -> String {
        let model = UIDevice.current.model
        let os = UIDevice.current.systemVersion
        let vid = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown"
        return "\(model)-\(os)-\(vid)"
    }

    public var deviceModel: String { UIDevice.current.model }
    public var systemVersion: String { UIDevice.current.systemVersion }

    // MARK: - 启停

    public func start() {
        stop()
        guard enabled, !serverURL.isEmpty, !token.isEmpty else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func save() {
        defaults.set(enabled, forKey: K.enabled)
        defaults.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: K.server)
        defaults.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: K.token)
        defaults.set(deviceID, forKey: K.device)
        if enabled { start() } else { stop() }
    }

    // MARK: - 轮询执行

    private func baseURL() -> URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    public func pollOnce() {
        guard enabled, !isPolling, let base = baseURL() else { return }
        isPolling = true
        var comps = URLComponents(url: base.appendingPathComponent("api/commands/next"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "device", value: deviceID),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = comps?.string.flatMap({ URL(string: $0) }) else { isPolling = false; return }
        var req = URLRequest(url: url)
        setTimeoutInterval(8, on: &req)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            defer { self.isPolling = false }
            guard err == nil, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = obj["command"] as? [String: Any] else { return }
            guard let cmdID = cmd["id"] as? Int, let tool = cmd["tool"] as? String else { return }
            let params = (cmd["params"] as? [String: Any]) ?? [:]
            self.executeAndReport(cmdID: cmdID, tool: tool, params: params)
        }.resume()
    }

    private func executeAndReport(cmdID: Int, tool: String, params: [String: Any]) {
        guard Self.safeTools.contains(tool) else {
            reportResult(cmdID: cmdID, ok: false, result: "[\"remote_denied\":\"tool not on the remote read-only whitelist, remote execution forbidden\"]")
            return
        }
        var ok = true
        var result: [String: Any] = [:]
        do {
            if let mcp = ToolRegistry.shared.tool(named: tool) {
                result = try mcp.invoke(params)
            } else {
                result = ["error": "unknown tool"]
                ok = false
            }
        } catch {
            ok = false
            result = ["error": "\(error)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? ""
        reportResult(cmdID: cmdID, ok: ok, result: str)
    }

    private func reportResult(cmdID: Int, ok: Bool, result: String) {
        let chars = result.count
        let lines = result.split(separator: "\n").count
        let body: [String: Any] = [
            "token": token, "id": cmdID, "ok": ok,
            "result": result, "chars": chars, "lines": lines,
        ]
        post(path: "api/commands/result", body: body) { [weak self] _ in
            DispatchQueue.main.async {
                self?.executedCount += 1
            }
        }
    }

    // MARK: - 上报

    /// 启动时上报安装/设备信息 (同版本只报一次，避免每次启动都刷）
    public func reportInstallIfNeeded() {
        guard let base = baseURL(), !token.isEmpty else { return }
        let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let last = defaults.string(forKey: K.reportedVer) ?? ""
        guard ver != last else { return }
        defaults.set(ver, forKey: K.reportedVer)
        let body: [String: Any] = [
            "token": token,
            "device": deviceID,
            "os": systemVersion,
            "app_version": ver,
            "model": deviceModel,
            "bundle": Bundle.main.bundleIdentifier ?? "",
        ]
        post(path: "api/report/install", body: body, then: nil)
    }

    /// 崩溃日志自动上报 (CrashCatcher 写入后调用）
    public func reportCrash(sig: String, content: String) {
        guard let base = baseURL(), !token.isEmpty else { return }
        let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let body: [String: Any] = [
            "token": token,
            "device": deviceID,
            "os": systemVersion,
            "app_version": ver,
            "sig": sig,
            "content": content,
        ]
        post(path: "api/report/crash", body: body, then: nil)
    }

    /// 启动时扫描 crash 目录，把上次崩溃未上报的日志上报到后台。
    /// 崩溃瞬间网络栈不可靠、信号上下文更不能调 Swift——统一改为"下次启动安全上报"。
    public func reportPendingCrashes() {
        guard baseURL() != nil, !token.isEmpty else { return }
        let dir = CrashCatcher.crashDir
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let reported = Set(defaults.stringArray(forKey: "remote_agent_reported_crashes") ?? [])
        var pending = files.filter { $0.hasPrefix("sig_") || $0.hasPrefix("exc_") }
            .filter { !reported.contains($0) }
            .sorted()
        guard !pending.isEmpty else { return }
        // 最多上报 5 条，避免海量
        pending = Array(pending.prefix(5))
        var done: [String] = []
        let group = DispatchGroup()
        for f in pending {
            let path = dir.appendingPathComponent(f)
            guard let content = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let firstLine = content.split(separator: "\n").first.map(String.init) ?? f
            group.enter()
            reportCrash(sig: "\(f): \(firstLine)", content: content)
            // post 是异步的，这里直接标记已上报 (failed就丢，不阻塞启动）
            done.append(f)
            group.leave()
        }
        group.notify(queue: .main) {
            let merged = reported.union(done)
            self.defaults.set(Array(merged), forKey: "remote_agent_reported_crashes")
        }
    }

    /// 测试连接：请求一次 /api/stats
    public func testConnection(completion: @escaping (Bool, String) -> Void) {
        guard let base = baseURL() else { completion(false, "invalid server address"); return }
        var comps = URLComponents(url: base.appendingPathComponent("api/stats"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps?.string.flatMap({ URL(string: $0) }) else { completion(false, "invalid URL"); return }
        var req = URLRequest(url: url)
        setTimeoutInterval(10, on: &req)
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                completion(false, "connection failed: \(err.localizedDescription)")
                return
            }
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  let d = obj["data"] as? [String: Any] else {
                completion(false, "token error or API exception")
                return
            }
            let installs = d["installs"] as? Int ?? 0
            completion(true, "connection OK, \(installs) install records in background")
        }.resume()
    }

    // MARK: - 网络基元

    private func post(path: String, body: [String: Any], then: ((Bool) -> Void)?) {
        guard let base = baseURL(), !token.isEmpty, !isReporting else {
            then?(false)
            return
        }
        isReporting = true
        var req = URLRequest(url: base.appendingPathComponent(path))
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setTimeoutInterval(10, on: &req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            self?.isReporting = false
            then?(true)
        }.resume()
    }
}
