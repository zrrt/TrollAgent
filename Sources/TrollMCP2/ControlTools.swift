import Foundation
import UserNotifications

// v2.9.75：ControlAgent 通用 UI 控制工具
// injected ControlAgent.dylib 到任意 App 后，通过 localhost HTTP 控制目标 App UI
// 端口固定 4789，API: /status /ui_tree /screenshot /tap /swipe /type /key

final class ControlAgentTools {
    static let shared = ControlAgentTools()
    private let port = 4789
    private let timeout: TimeInterval = 5

    // MARK: - 通用 HTTP 请求

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil) -> (Int, Data?, String?) {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        setHTTPMethod(method, on: &request)
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var resultData: Data?
        var resultError: String?
        var statusCode = 0
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                resultError = error.localizedDescription
            } else if let httpResponse = response as? HTTPURLResponse {
                statusCode = httpResponse.statusCode
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        return (statusCode, resultData, resultError)
    }

    private func parseJSON(_ data: Data?) -> [String: Any] {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - injected ControlAgent.dylib

    func inject(bundleId: String, target: String? = nil, skipProbe: Bool = false) -> [String: Any] {
        // 找到内置的 ControlAgent.dylib
        let dylibPath = Bundle.main.path(forResource: "ControlAgent", ofType: "dylib", inDirectory: "tweaks")
        guard dylibPath != nil else {
            // 尝试工作区路径
            let workspacePath = "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path)/Workspace/tweaks/ControlAgent.dylib"
            guard FileManager.default.fileExists(atPath: workspacePath) else {
                return ["error": "ControlAgent.dylib not bundled, compile it into Resources/tweaks/ first", "hint": "use the build-tweak workflow to compile online"]
            }
            return doInject(bundleId: bundleId, dylibPath: workspacePath, target: target, skipProbe: skipProbe)
        }
        return doInject(bundleId: bundleId, dylibPath: dylibPath!, target: target, skipProbe: skipProbe)
    }

    private func doInject(bundleId: String, dylibPath: String, target: String? = nil, skipProbe: Bool = false) -> [String: Any] {
        do {
            // v2.9.260：控制代理必须注入主二进制 (启动必加载）——懒加载 framework 实测
            // ControlAgent constructor 不执行、4789 不监听 (小红书 AppsFlyerLib 实锤）。
            // 主二进制加密的 load commands 不加密，insert_dylib+伪签+ct_bypass 可改。
            let result = try InjectionManager.shared.enable(
                bundleId: bundleId,
                dylibName: "@executable_path/ControlAgent.dylib",
                dylibSourcePath: dylibPath,
                preferredTarget: target,
                skipProbe: skipProbe,
                allowMain: true
            )
            // v2.9.109：注入OK自动开启真后台保活 (目标 App + TrollAgent 自身），
            // 防止目标 App 切后台被系统挂起导致 4789 断连
            postKeepAliveNotification(true)
            BackgroundKeepAlive.shared.start()
            return [
                "injected": true,
                "bundle_id": bundleId,
                "dylib": dylibPath,
                "detail": result,
                "keepalive": true,
                "next_step": "after launching target App call control.status to confirm connection, then use control.ui_tree / control.tap etc.; real background keep-alive is on, target App won't suspend in background"
            ]
        } catch {
            // v2.9.189：用 \(error) 而非 localizedDescription——纯 Swift Error 的
            // localizedDescription 会被 NSError bridge 抹成"未能done操作。"，真实原因丢失
            return ["error": "injection failed: \(error)", "bundle_id": bundleId]
        }
    }

    // MARK: - 状态检查
    // v2.9.128：自动重试 (ControlAgent 服务器在 App 启动后 ~1.5s 才监听 4789，
    // 刚注入/刚启动立刻查会连接拒绝）——status 最多试 4 次，间隔 0.6s

    func status(retries: Int = 4) -> [String: Any] {
        var lastErr: String? = nil
        var lastCode = 0
        for attempt in 0..<max(1, retries) {
            let (code, data, error) = request(path: "/status")
            if code == 200 {
                var result = parseJSON(data)
                result["connected"] = true
                if attempt > 0 { result["retries"] = attempt }
                return result
            }
            lastErr = error
            lastCode = code
            Thread.sleep(forTimeInterval: 0.6)
        }
        return [
            "connected": false,
            "error": lastErr ?? "HTTP \(lastCode)",
            "hint": "confirm: 1. ControlAgent.dylib injected 2. target App running 3. target App restarted after injection (server ready ~1.5s after launch)"
        ]
    }

    // MARK: - v2.9.186 进程内砸壳
    // 调 ControlAgent /decrypt：目标进程内遍历 dyld 镜像，从内存读已解密段写副本
    // 绕开 TrollStore 无 task_for_pid 的限制。返回各镜像解密结果 (output 为容器内副本路径）。

    func decrypt() -> [String: Any] {
        var lastErr: String? = nil
        for attempt in 0..<4 {
            let (code, data, error) = request(path: "/decrypt")
            if code == 200 {
                var json = parseJSON(data)
                json["connected"] = true
                if attempt > 0 { json["retries"] = attempt }
                return json
            }
            lastErr = error
            Thread.sleep(forTimeInterval: 0.8)
        }
        return [
            "connected": false,
            "error": lastErr ?? "decrypt endpoint unreachable",
            "hint": "confirm ControlAgent injected and target App running (server ready ~1.5s after launch)"
        ]
    }

    // MARK: - UI 树
    // v2.9.128：服务器刚ready时首帧可能超时，轻量重试 2 次

    func uiTree() -> [String: Any] {
        var lastErr: String? = nil
        var lastCode = 0
        for attempt in 0..<3 {
            let (code, data, error) = request(path: "/ui_tree")
            if code == 200 {
                var result = parseJSON(data)
                if attempt > 0 { result["retries"] = attempt }
                return result
            }
            lastErr = error; lastCode = code
            Thread.sleep(forTimeInterval: 0.5)
        }
        return ["error": lastErr ?? "HTTP \(lastCode)", "hint": "confirm target App running and ControlAgent injected and restarted"]
    }

    // MARK: - 截图

    func screenshot() -> [String: Any] {
        let (code, data, error) = request(path: "/screenshot")
        if code == 200, let data = data {
            // 保存到工作区
            let workspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = workspace.appendingPathComponent("Workspace/screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let filename = "control_\(Int(Date().timeIntervalSince1970)).png"
            let path = dir.appendingPathComponent(filename)
            try? data.write(to: path)
            // v3.0.22：自动清理旧截图，只保留最近 10 张
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
                let sorted = files.filter { $0.pathExtension == "png" }.sorted {
                    let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return d1 > d2
                }
                if sorted.count > 10 {
                    for old in sorted[10...] {
                        try? fm.removeItem(at: old)
                    }
                }
            }
            // v3.0.65：同时返回 base64 (AI 直接看图，不用读文件）
            let base64 = data.base64EncodedString()
            return [
                "screenshot": true,
                "path": path.path,
                "size": data.count,
                "base64": base64,
                "hint": "base64 field is the image; path is the file path fallback"
            ]
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 点击

    func tap(x: Double, y: Double) -> [String: Any] {
        let (code, data, error) = request(path: "/tap", method: "POST", body: ["x": x, "y": y])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 滑动

    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double = 0.3) -> [String: Any] {
        let (code, data, error) = request(path: "/swipe", method: "POST", body: [
            "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": duration
        ])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 输入文字

    func type(text: String) -> [String: Any] {
        let (code, data, error) = request(path: "/type", method: "POST", body: ["text": text])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }

    // MARK: - 按键

    func key(_ key: String) -> [String: Any] {
        let (code, data, error) = request(path: "/key", method: "POST", body: ["key": key])
        if code == 200 {
            return parseJSON(data)
        }
        return ["error": error ?? "HTTP \(code)"]
    }
}

// MARK: - MCP 工具注册

final class ControlInjectTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.inject",
        summary: "Inject ControlAgent into an app to enable UI control (tap/swipe/type/screenshot). Use for: start controlling an app's UI, before using other control.* tools. Don't use for: inject other dylibs (use injection.enable), memory injection (use injection.mem). Example: user says 'I want to control 小红书' → inject ControlAgent first.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "target": "Specific framework to inject (optional, auto)",
            "skip_probe": "Skip startup check (optional, default false)"
        ],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String else {
            throw MCPError.invalidParams("bundle_id required")
        }
        AuditLog.shared.log("control.inject", detail: bundleId)
        return ControlAgentTools.shared.inject(bundleId: bundleId,
                                               target: params["target"] as? String,
                                               skipProbe: params["skip_probe"] as? Bool ?? false)
    }
}

final class ControlScreenshotTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.screenshot",
        summary: "PREREQUISITE: call control.inject first. Screenshot target app screen. Use for: capture screen, see what's on screen. Don't use for: recognize text in screenshot (use ocr.image), tap by coordinates (use control.tap).",
        parameters: [:],
        verified: true, category: "ui_control")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        AuditLog.shared.log("control.screenshot", detail: "capture")
        return ControlAgentTools.shared.screenshot()
    }
}

// MARK: - v3.0.72：control.tap_text — 语义化点击 (传文字，自动找元素点）

final class ControlTapTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap_text",
        summary: "PREREQUISITE: call control.inject first. Tap an element by its visible text label. Use for: tap a button/link by its text (e.g. \"搜索\", \"登录\"). Don't use for: tap by coordinates (use control.tap), swipe gesture (use control.swipe).",
        parameters: [
            "text": "Visible text label of the element to tap (REQUIRED)",
            "partial": "If true, match partial text (default true) (optional)"
        ],
        verified: true, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw MCPError.invalidParams("text required")
        }
        let partial = (params["partial"] as? Bool) ?? true

        // 拿 UI 树
        let tree = ControlAgentTools.shared.uiTree()
        if let nodes = tree["nodes"] as? [[String: Any]] {
            return try findAndTap(nodes: nodes, text: text, partial: partial)
        }
        if let nodes = tree["elements"] as? [[String: Any]] {
            return try findAndTap(nodes: nodes, text: text, partial: partial)
        }
        if let nodes = tree["tree"] as? [[String: Any]] {
            return try findAndTap(nodes: nodes, text: text, partial: partial)
        }
        throw MCPError.failed("cannot parse UI tree")
    }

    private func findAndTap(nodes: [[String: Any]], text: String, partial: Bool) throws -> [String: Any] {
        // 递归遍历 UI 树找匹配的元素
        var bestNode: [String: Any]?
        var bestFrame: [Double] = [0, 0, 0, 0]

        func search(_ node: [String: Any]) {
            // 检查 text/label/accessibilityLabel
            let nodeText = (node["text"] as? String) ?? (node["label"] as? String) ?? (node["accessibilityLabel"] as? String) ?? ""
            var match = false
            if partial {
                match = nodeText.localizedCaseInsensitiveContains(text)
            } else {
                match = nodeText == text
            }

            if match {
                // 优先用 visible/hittable 的
                let visible = (node["isVisible"] as? Bool) ?? true
                let hittable = (node["isHittable"] as? Bool) ?? true
                if visible && hittable {
                    bestNode = node
                    if let frame = node["frame"] as? [String: Any],
                       let x = frame["x"] as? Double,
                       let y = frame["y"] as? Double,
                       let w = frame["width"] as? Double,
                       let h = frame["height"] as? Double {
                        bestFrame = [x, y, w, h]
                    }
                    return
                }
            }

            // 递归子节点
            if let children = node["children"] as? [[String: Any]] {
                for child in children { search(child) }
            }
        }

        for node in nodes { search(node) }

        guard bestNode != nil else {
            throw MCPError.failed("no element matching \"\(text)\" found in UI tree")
        }

        // 算中心点
        let cx = bestFrame[0] + bestFrame[2] / 2
        let cy = bestFrame[1] + bestFrame[3] / 2

        AuditLog.shared.log("control.tap_text", detail: "\"\(text)\" at (\(cx),\(cy))")
        var result = ControlAgentTools.shared.tap(x: cx, y: cy)
        result["matched_text"] = text
        result["tap_x"] = cx
        result["tap_y"] = cy
        return result
    }
}

// MARK: - v3.0.72：control.type_text — 语义化输入 (找到输入框，输入文字）

final class ControlTypeTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.type_text",
        summary: "PREREQUISITE: call control.inject first. Find an input field by its placeholder text, tap it, then type. Use for: fill a form field by its label (e.g. \"搜索框\", \"手机号\"). Don't use for: type into already-focused field (use control.type), tap a button by text (use control.tap_text).",
        parameters: [
            "placeholder": "Placeholder or label of the input field (e.g. \"搜索\", \"请输入手机号\") (REQUIRED)",
            "text": "Text to type into the field (REQUIRED)",
            "enter": "If true, press Enter after typing (default false) (optional)"
        ],
        verified: true, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let placeholder = params["placeholder"] as? String else {
            throw MCPError.invalidParams("placeholder required")
        }
        guard let text = params["text"] as? String else {
            throw MCPError.invalidParams("text required")
        }
        let enter = (params["enter"] as? Bool) ?? false

        // 1. 先点输入框 (用 tap_text 找 placeholder）
        let tapResult = try ControlTapTextTool().invoke(["text": placeholder])

        // 2. 等一下让键盘弹出来
        Thread.sleep(forTimeInterval: 0.3)

        // 3. 输入文字
        let typeResult = ControlAgentTools.shared.type(text: text)

        // 4. 如果要按回车
        if enter {
            Thread.sleep(forTimeInterval: 0.2)
            _ = ControlAgentTools.shared.key("enter")
        }

        return [
            "ok": true,
            "field": placeholder,
            "text": text,
            "tap": tapResult,
            "type": typeResult,
            "pressed_enter": enter
        ]
    }
}

// MARK: - v7.1.283: control 进度通知
// AI 控制目标 App 时，把每步结果镜像为系统通知——用户在前台 App 也能看到控制进度
enum ControlNotifier {
    private static var permissionChecked = false

    static func ensurePermission() {
        guard !permissionChecked else { return }
        permissionChecked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(command: String, ok: Bool, detail: String) {
        ensurePermission()
        let content = UNMutableNotificationContent()
        content.title = (ok ? "✓ " : "✗ ") + "control " + command
        content.body = detail
        content.sound = ok ? nil : .default
        let req = UNNotificationRequest(identifier: "control-" + UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 从子命令结果提取通知文案：error 字段 → 失败；否则按命令给成功摘要
    static func describe(command: String, result: [String: Any], extra: String? = nil) -> (ok: Bool, detail: String) {
        if let err = result["error"] as? String {
            return (false, "失败: \(err)")
        }
        if let extra = extra {
            return (true, extra)
        }
        switch command {
        case "ui_tree":   return (true, "已读取 UI 树（可按语义定位元素）")
        case "screenshot": return (true, "已截图并保存")
        case "inject":    return (true, "注入完成")
        case "status":    return (true, "ControlAgent 状态正常")
        default:          return (true, "执行完成")
        }
    }
}

// MARK: - v3.1.34: control 大工具 + 子命令 (合并 10 个 control.* 工具）

final class ControlExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "control",
        summary: "Control target app UI. Subcommands: inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text. Params per subcommand: tap→x,y(Number); swipe→x1,y1,x2,y2(Number); type→text; tap_text→text; type_text→placeholder+text; key→key(home/back/enter); inject→bundle_id; others none. Use for: UI automation / app screen control. Semantic UI tree (v7.1.281+): ui_tree nodes carry accessibility_role (button/link/text_field/switch/image/...), accessibility_label (human name), accessibility_value, is_accessibility_element and frame — locate an element by role+label, then tap its frame center; do NOT hardcode coordinates when labels are available. First `inject` to install ControlAgent, then call other subcommands.",
        parameters: [
            "command": "Subcommand (required): inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text",
            "bundle_id": "App bundle ID — REQUIRED for inject only",
            "x": "X coordinate Number — REQUIRED for tap",
            "y": "Y coordinate Number — REQUIRED for tap",
            "x1": "Start X Number — REQUIRED for swipe",
            "y1": "Start Y Number — REQUIRED for swipe",
            "x2": "End X Number — REQUIRED for swipe",
            "y2": "End Y Number — REQUIRED for swipe",
            "text": "Text string — REQUIRED for type / tap_text",
            "key": "Key name: home/back/enter — REQUIRED for key",
            "placeholder": "Field placeholder (for type_text)"
        ],
        verified: true, category: "ui_control",
        prerequisites: ["inject ControlAgent into target App and launch it (control inject) before UI control", "read control.ui_tree first to locate elements by accessibility_role+label, then tap their frame centers; take a screenshot only when coordinates are ambiguous"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("control", detail: command)
        
        switch command {
        case "inject":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            let result = try ControlInjectTool().invoke(["bundle_id": bundleId])
            let d = ControlNotifier.describe(command: "inject", result: result, extra: "已注入 \(bundleId)")
            ControlNotifier.post(command: "inject", ok: d.ok, detail: d.detail)
            return result

        case "status":
            let result = ControlAgentTools.shared.status()
            let d = ControlNotifier.describe(command: "status", result: result)
            ControlNotifier.post(command: "status", ok: d.ok, detail: d.detail)
            return result

        case "ui_tree":
            let result = ControlAgentTools.shared.uiTree()
            let d = ControlNotifier.describe(command: "ui_tree", result: result)
            ControlNotifier.post(command: "ui_tree", ok: d.ok, detail: d.detail)
            return result

        case "screenshot":
            let result = ControlAgentTools.shared.screenshot()
            let d = ControlNotifier.describe(command: "screenshot", result: result)
            ControlNotifier.post(command: "screenshot", ok: d.ok, detail: d.detail)
            return result

        case "tap":
            guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
                throw MCPError.invalidParams("x and y required. Usage: control tap x:100 y:200 (both Numbers)")
            }
            let result = ControlAgentTools.shared.tap(x: x, y: y)
            let d = ControlNotifier.describe(command: "tap", result: result, extra: "已点击 (\(Int(x)), \(Int(y)))")
            ControlNotifier.post(command: "tap", ok: d.ok, detail: d.detail)
            return result

        case "swipe":
            guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
                  let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
                throw MCPError.invalidParams("x1,y1,x2,y2 required. Usage: control swipe x1:100 y1:200 x2:300 y2:400 (all Numbers)")
            }
            let result = ControlAgentTools.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: 0.3)
            let d = ControlNotifier.describe(command: "swipe", result: result, extra: "已滑动 (\(Int(x1)),\(Int(y1))) → (\(Int(x2)),\(Int(y2)))")
            ControlNotifier.post(command: "swipe", ok: d.ok, detail: d.detail)
            return result

        case "type":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: control type text:'hello'")
            }
            let result = ControlAgentTools.shared.type(text: text)
            let d = ControlNotifier.describe(command: "type", result: result, extra: "已输入 \(text.count) 字符")
            ControlNotifier.post(command: "type", ok: d.ok, detail: d.detail)
            return result

        case "key":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required. Usage: control key key:home (home/back/enter)")
            }
            let result = ControlAgentTools.shared.key(key)
            let d = ControlNotifier.describe(command: "key", result: result, extra: "已按键 \(key)")
            ControlNotifier.post(command: "key", ok: d.ok, detail: d.detail)
            return result

        case "tap_text":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: control tap_text text:'login'")
            }
            let result = try ControlTapTextTool().invoke(["text": text])
            let d = ControlNotifier.describe(command: "tap_text", result: result, extra: "已点击文本：\(text.prefix(20))")
            ControlNotifier.post(command: "tap_text", ok: d.ok, detail: d.detail)
            return result

        case "type_text":
            guard let placeholder = params["placeholder"] as? String,
                  let text = params["text"] as? String else {
                throw MCPError.invalidParams("placeholder and text required")
            }
            let result = try ControlTypeTextTool().invoke(["placeholder": placeholder, "text": text])
            let d = ControlNotifier.describe(command: "type_text", result: result, extra: "已在「\(placeholder)」输入 \(text.count) 字符")
            ControlNotifier.post(command: "type_text", ok: d.ok, detail: d.detail)
            return result

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: inject/status/ui_tree/screenshot/tap/swipe/type/key/tap_text/type_text")
        }
    }
}
