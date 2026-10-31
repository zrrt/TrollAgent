import Foundation
import UIKit
import Network

/// v2.9.181：远程终端服务器——TrollAgent 自身暴露公网 HTTP API
///
/// 监听 0.0.0.0:8790 (可配置），N1 公网 IPv4 端口转发到手机局域网 IP 即可由云端 AI 直连：
///   - GET  /api/status     设备/版本/工具数/服务状态
///   - POST /api/tool       调用工具 (只读白名单 + 危险工具需设置授权）
///   - GET  /api/audit      工具执行审计链路 (OK/failed/耗时/错误码）
///   - GET  /api/crash      崩溃日志列表 + 全文
///   - GET  /api/tools      工具清单
///
/// 安全：Bearer token 鉴权；危险工具 (注入/删除/写入/启动/抓包等）默认拒绝，
/// 需在 设置 → 远程终端 显式开启"允许危险工具"。
/// 保活：开启服务后建议同时开启"后台常驻"，否则 App 被杀/深度挂起时服务不可达。
final class RemoteTerminalServer {
    static let shared = RemoteTerminalServer()
    private(set) var isRunning = false
    private var serverSocket: Int32 = -1
    private var acceptThread: Thread?

    private let defaultPort = 8790
    private let maxBody = 64 * 1024

    var port: Int {
        get {
            let p = UserDefaults.standard.integer(forKey: "remote_terminal_port")
            return p == 0 ? defaultPort : p
        }
        set { UserDefaults.standard.set(newValue, forKey: "remote_terminal_port") }
    }
    var token: String {
        get { UserDefaults.standard.string(forKey: "remote_terminal_token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "remote_terminal_token") }
    }
    var allowDangerous: Bool {
        get { UserDefaults.standard.bool(forKey: "remote_terminal_allow_dangerous") }
        set { UserDefaults.standard.set(newValue, forKey: "remote_terminal_allow_dangerous") }
    }

    /// 危险工具：默认拒绝 (前缀模糊匹配也生效）
    private let dangerousPrefixes = [
        "injection.", "hook.", "cleanup.execute", "workspace.cleanup", "system.cleanup_execute",
        "artifact", "artifact", "shell.exec", "shell.exec", "shell.exec", "shell.exec", "shell.exec",
        "fs.container", "container.", "app.decrypt", "app.reinstall", "app.install", "app.uninstall",
        "device.fake.", "device.restore", "memory.write", "network.capture", "network.redirect",
        "automation.run", "cron.", "webhooks.", "github.trigger_build",
        "ui.tap", "ui.swipe", "ui.long_press", "control.",
    ]
    private func isDangerous(_ name: String) -> Bool {
        for p in dangerousPrefixes where name.hasPrefix(p) { return true }
        return false
    }

    // MARK: - 生命周期

    func start() -> Bool {
        guard !isRunning else { return true }
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return false }
        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian   // 0.0.0.0：局域网/公网可达
        let br = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard br == 0 else { close(serverSocket); serverSocket = -1; return false }
        guard listen(serverSocket, 16) == 0 else { close(serverSocket); serverSocket = -1; return false }
        isRunning = true
        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.start()
        // v2.9.183：远程终端开启即自动启动后台保活 (静音音频），
        // 目标 App 在前台时 TrollAgent 退后台仍保持服务在线，避免 iOS 挂起断线。
        BackgroundKeepAlive.shared.start()
        // fix73k-3：iOS 14+ 本地网络权限主动触发——App 监听 0.0.0.0 端口但从未发起过
        // 局域网访问时，iOS 不弹"允许访问本地网络"授权窗 → 权限未授权 → 其他设备（N1/云端）
        // 连不上监听端口（本机 127.0.0.1 不受影响，实测症状）。start NWBrowser（Bonjour 服务
        // 发现）是 iOS 标准触发方式：首次 browse 即弹授权窗，用户允许后入站监听同步放行。
        if #available(iOS 14.0, *) {
            let browser = NWBrowser(for: .bonjour(type: "_trollagent._tcp"), using: .tcp)
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { browser.cancel() }
        }
        return true
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
        acceptThread = nil
        // v2.9.183：服务关闭同步停止保活
        BackgroundKeepAlive.shared.stop()
    }

    private func acceptLoop() {
        // v6.1.5-14bz：请求处理串行化——原 DispatchQueue.global 并发执行 handleClient，
        // shell.exec 内共享状态（TrollRuntimeEngine.cwd、guestCwd 等）无锁并发修改 → 数据竞争 →
        // Segmentation fault 11（真机 CrashCatcher 记录 20+ 次）。改单串行队列，每次只处理一个
        // 连接，杜绝并发竞争；远程测试是逐条串行调用，串行处理无吞吐损失。
        var handlerQueue = DispatchQueue(label: "trollagent.remote-terminal.handler")
        while isRunning && serverSocket >= 0 {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { continue }
            // fix17: 单连接看门狗——串行队列 + 30s 处理超时。
            // 即使命令卡死在无法被 timeout 中断的系统调用（网络出站挂起等），
            // 看门狗也强制 close 释放队列：后续请求不再被永久排队，服务端最多堵 30s 自动恢复。
            let sem = DispatchSemaphore(value: 0)
            handlerQueue.async {
                self.handleClient(client)
                sem.signal()
            }
            let waitResult = sem.wait(timeout: .now() + 30)
            if waitResult == .timedOut {
                // 强制关闭：handleClient 内的 recv/send 立即返回错误 → 函数尽快退出 → 队列释放
                close(client)
                _ = sem.wait(timeout: .now() + 5)
                // fix22: 卡死在工具执行（posix_spawn/waitpid 卡内核不可中断状态）时 close 无效——
                // 旧 async 块仍占着 handlerQueue → 后续所有请求（含 health/echo）永久排队假死。
                // 重建队列丢弃卡死块：新连接立即进入新队列处理，服务端从假死自动恢复（最多堵 35s）。
                // 旧块若真卡在 waitpid 则无共享状态写入，重建后竞争风险可接受；若它后续又恢复写
                // 共享状态，重启 App 清理（卡死是异常路径，优先保服务可用）。
                handlerQueue = DispatchQueue(label: "trollagent.remote-terminal.handler")
            }
        }
    }

    // MARK: - HTTP 基础

    private struct HTTPRequest {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = ""
        var bearer = ""
    }

    private func readRequest(_ client: Int32) -> HTTPRequest? {
        var buf = [UInt8](repeating: 0, count: 8192)
        var raw = Data()
        // 读头部直到 \r\n\r\n (最多 32KB）
        var headerEnd = -1
        while raw.count < 32 * 1024 {
            let n = recv(client, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            raw.append(contentsOf: buf[0..<n])
            if let range = raw.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.lowerBound
                break
            }
        }
        guard headerEnd >= 0 else { return nil }
        let headerData = raw.subdata(in: 0..<headerEnd)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var req = HTTPRequest()
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        req.method = String(parts[0])
        let urlPart = String(parts[1])
        let urlSplit = urlPart.split(separator: "?", maxSplits: 1)
        req.path = String(urlSplit[0])
        if urlSplit.count > 1 {
            for kv in String(urlSplit[1]).split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1)
                if p.count == 2 {
                    let k = String(p[0]).removingPercentEncoding ?? String(p[0])
                    let v = String(p[1]).removingPercentEncoding ?? String(p[1])
                    req.query[k] = v
                }
            }
        }
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0]).lowercased()
                let v = String(kv[1]).trimmingCharacters(in: .whitespaces)
                req.headers[k] = v
                if k == "authorization", v.hasPrefix("Bearer ") {
                    req.bearer = String(v.dropFirst(7))
                }
            }
        }
        // body
        if let cl = req.headers["content-length"], let n = Int(cl), n > 0 {
            let need = min(n, maxBody)
            while raw.count < headerEnd + 4 + need {
                let n2 = recv(client, &buf, buf.count, 0)
                guard n2 > 0 else { break }
                raw.append(contentsOf: buf[0..<n2])
            }
            let start = headerEnd + 4
            let end = min(raw.count, start + need)
            if end > start {
                req.body = String(data: raw.subdata(in: start..<end), encoding: .utf8) ?? ""
            }
        }
        return req
    }

    private func sendResponse(_ client: Int32, status: Int, body: String) {
        let data = Data(body.utf8)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Error"))
        var resp = "HTTP/1.1 \(status) \(reason)\r\n"
        resp += "Content-Type: application/json; charset=utf-8\r\n"
        resp += "Content-Length: \(data.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        let head = Data(resp.utf8)
        _ = head.withUnsafeBytes { send(client, $0.baseAddress, head.count, 0) }
        if data.count > 0 {
            _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
        }
    }

    private func json(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"serialize\"}"
    }

    // MARK: - 路由

    private func handleClient(_ client: Int32) {
        defer { close(client) }
        // fix15: recv 超时保护（10s）——客户端连上不发数据 / 只发半截请求 / 恶意占连接时，
        // recv 10s 后返回 EAGAIN → readRequest 返回 nil → 连接关闭 → 串行 acceptLoop 不被永久阻塞
        // （否则单连接 DoS 会让整个远程终端服务假死：端口在听但 HTTP 无响应）
        var rcvTimeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
        guard let req = readRequest(client) else { return }
        let authOK = !token.isEmpty && (req.bearer == token || req.query["token"] == token)
        let path = req.path

        if path == "/health" {
            // fix3ci: /health 返回 build（CFBundleVersion=git commit 短哈希）——AI 测试前一眼确认装机版本，
            // 根治"凭二进制大小猜新旧包"的误判。
            let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
            sendResponse(client, status: 200, body: json(["ok": true, "service": "trollagent-remote-terminal", "version": appVersion(), "build": build]))
            return
        }
        guard authOK else {
            sendResponse(client, status: 401, body: json(["ok": false, "error": "unauthorized"]))
            return
        }

        switch (req.method, path) {
        case ("GET", "/api/status"):
            sendResponse(client, status: 200, body: statusJSON())
        case ("GET", "/api/tools"):
            sendResponse(client, status: 200, body: json(["ok": true, "count": ToolRegistry.shared.allToolNames().count, "tools": ToolRegistry.shared.allToolNames()]))
        case ("POST", "/api/tool"):
            handleTool(client, req)
        case ("GET", "/api/audit"):
            handleAudit(client, req)
        case ("GET", "/api/crash"):
            handleCrash(client, req)
        case ("GET", "/api/file"):
            // v2.9.258: 文件下载端点——AI 远程调试拉取截图/日志/ipa/文本
            // 白名单目录：工作区(Documents/Workspace)、文档(Documents)、临时
            handleFile(client, req)
        case ("GET", "/api/conversations"):
            // v3.1.77：远程终端专用会话列表——走 ConversationStore (App 内读 UserDefaults），
            // 避免外部 shell 读 plist 导致 App 闪退 (用户实测：每次远程读会话都闪退）
            handleConversations(client, req)
        case ("GET", "/api/conversation"):
            // v3.1.77：远程终端专用单会话完整导出 (含 thinking/toolName/toolArgs），同走 App 内读取
            handleConversation(client, req)
        default:
            sendResponse(client, status: 404, body: json(["ok": false, "error": "no_route"]))
        }
    }

    /// v3.1.77：会话列表 (远程终端专用）
    private func handleConversations(_ client: Int32, _ req: HTTPRequest) {
        let limit = Int(req.query["limit"] ?? "10") ?? 10
        do {
            let r = try DebugDumpConversationsTool().invoke(["limit": limit])
            sendResponse(client, status: 200, body: json(["ok": true, "tool": "debug.dump_conversations", "result": r]))
        } catch {
            sendResponse(client, status: 200, body: json(["ok": false, "error": "\(error)"]))
        }
    }

    /// v3.1.77：单会话完整导出 (远程终端专用）
    private func handleConversation(_ client: Int32, _ req: HTTPRequest) {
        guard let title = req.query["title"], !title.isEmpty else {
            sendResponse(client, status: 400, body: json(["ok": false, "error": "title_required", "hint": "?title=<conversation title>"]))
            return
        }
        let limit = Int(req.query["limit"] ?? "50") ?? 50
        do {
            let r = try DebugDumpConversationTool().invoke(["title": title, "limit": limit])
            sendResponse(client, status: 200, body: json(["ok": true, "tool": "debug.dump_conversation", "result": r]))
        } catch {
            sendResponse(client, status: 200, body: json(["ok": false, "error": "\(error)"]))
        }
    }

    /// v2.9.258: GET /api/file?path=<绝对路径>——白名单目录内文件直接返回字节
    private func handleFile(_ client: Int32, _ req: HTTPRequest) {
        guard let p = req.query["path"], !p.isEmpty else {
            sendResponse(client, status: 400, body: json(["ok": false, "error": "path_required"]))
            return
        }
        let allowedPrefixes: [String] = [
            NSHomeDirectory() + "/Documents/Workspace/",
            NSHomeDirectory() + "/Documents/",
        ]
        let expanded = (p as NSString).expandingTildeInPath
        guard allowedPrefixes.contains(where: { expanded.hasPrefix($0) }) else {
            sendResponse(client, status: 403, body: json(["ok": false, "error": "path_denied", "hint": "only Documents/Workspace and Documents are allowed"]))
            return
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            sendResponse(client, status: 404, body: json(["ok": false, "error": "not_found", "path": expanded]))
            return
        }
        let ext = (expanded as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "json": mime = "application/json"
        case "log", "txt", "md": mime = "text/plain; charset=utf-8"
        case "ipa", "tipa": mime = "application/octet-stream"
        case "zip": mime = "application/zip"
        default: mime = "application/octet-stream"
        }
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let headData = Data(head.utf8)
        _ = headData.withUnsafeBytes { send(client, $0.baseAddress, headData.count, 0) }
        if data.count > 0 {
            _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
        }
    }

    private func appVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    private func statusJSON() -> String {
        let d = UIDevice.current
        var status: [String: Any] = [
            "ok": true,
            "service": "trollagent-remote-terminal",
            "app_version": appVersion(),
            "device_model": DeviceReporter.deviceModelIdentifier(),
            "device_name": d.model,
            "ios_version": d.systemVersion,
            "tools_count": ToolRegistry.shared.allToolNames().count,
            "port": port,
            "allow_dangerous": allowDangerous,
        ]
        // 注入状态摘要 (尽力而为）
        status["trollstore_detected"] = (try? FileManager.default.fileExists(atPath: "/var/containers/Bundle/Application")) ?? false
        return json(status)
    }

    private func handleTool(_ client: Int32, _ req: HTTPRequest) {
        guard let data = req.body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendResponse(client, status: 400, body: json(["ok": false, "error": "bad_json"]))
            return
        }
        guard let name = obj["name"] as? String else {
            sendResponse(client, status: 400, body: json(["ok": false, "error": "name_required"]))
            return
        }
        if isDangerous(name) && !allowDangerous {
            sendResponse(client, status: 200, body: json(["ok": false, "error": "remote_denied_dangerous", "hint": "dangerous tools require authorization in Settings -> Remote Terminal"]))
            return
        }
        let params = (obj["params"] as? [String: Any]) ?? [:]
        let t0 = Date()
        do {
            guard let mcp = ToolRegistry.shared.tool(named: name) else {
                sendResponse(client, status: 200, body: json(["ok": false, "error": "unknown_tool", "name": name]))
                return
            }
            let r = try mcp.invoke(params)
            var out = r
            out["_elapsed_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
            let body = json(["ok": true, "tool": name, "result": out])
            sendResponse(client, status: 200, body: body)
        } catch {
            let body = json(["ok": false, "tool": name, "error": "\(error)"])
            sendResponse(client, status: 200, body: body)
        }
    }

    private func handleAudit(_ client: Int32, _ req: HTTPRequest) {
        let limit = Int(req.query["limit"] ?? "50") ?? 50
        let entries = AuditLog.shared.entries.prefix(max(1, min(limit, 200)))
        let out = entries.map { e -> [String: Any] in
            var d: [String: Any] = [
                "ts": Int(e.timestamp.timeIntervalSince1970),
                "category": e.category,
                "detail": String(e.detail.prefix(300)),
                "level": e.level.rawValue,
            ]
            if let s = e.status { d["status"] = s.rawValue }
            if let ms = e.elapsedMs { d["elapsed_ms"] = ms }
            if let ec = e.errorCode { d["error_code"] = ec }
            if let er = e.errorReason { d["error_reason"] = String(er.prefix(300)) }
            if let ns = e.nextStep { d["next_step"] = String(ns.prefix(200)) }
            return d
        }
        sendResponse(client, status: 200, body: json(["ok": true, "count": out.count, "entries": out]))
    }

    private func handleCrash(_ client: Int32, _ req: HTTPRequest) {
        let files = CrashCatcher.list()
        if let file = req.query["file"] {
            let full = CrashCatcher.crashDir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: full.path) else {
                sendResponse(client, status: 404, body: json(["ok": false, "error": "not_found"]))
                return
            }
            sendResponse(client, status: 200, body: json(["ok": true, "file": file, "content": CrashCatcher.content(full.path)]))
            return
        }
        let limit = Int(req.query["limit"] ?? "20") ?? 20
        let list = files.prefix(max(1, min(limit, 50))).map { p -> [String: Any] in
            let name = URL(fileURLWithPath: p).lastPathComponent
            let content = CrashCatcher.content(p)
            let firstLine = content.split(separator: "\n").first.map(String.init) ?? ""
            return ["file": name, "head": String(firstLine.prefix(200)), "size": content.count]
        }
        sendResponse(client, status: 200, body: json(["ok": true, "count": list.count, "crashes": list]))
    }
}
