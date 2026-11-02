import Foundation
import UserNotifications
import UIKit

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
            // v7.1.284：base64 给压缩 JPEG（最长边 640px、质量 0.6）——全分辨率 PNG 只存文件；
            //   AI 读图 token 成本从 ~600 降到 ~80-120，传输也更快；path 仍指向原始全分辨率 PNG
            var aiBase64 = ""
            var aiSmall = false
            if let img = UIImage(data: data) {
                let maxSide: CGFloat = 640
                let w = img.size.width, h = img.size.height
                let scale = min(1.0, maxSide / max(w, h))
                UIGraphicsBeginImageContextWithOptions(CGSize(width: w * scale, height: h * scale), false, 1.0)
                img.draw(in: CGRect(x: 0, y: 0, width: w * scale, height: h * scale))
                let small = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                if let jpeg = small?.jpegData(compressionQuality: 0.6) {
                    aiBase64 = jpeg.base64EncodedString()
                    aiSmall = true
                }
            }
            let base64 = aiSmall ? aiBase64 : data.base64EncodedString()
            return [
                "screenshot": true,
                "path": path.path,
                "size": data.count,
                "base64": base64,
                "small": aiSmall,
                "full_size": data.count,
                "hint": "base64 is a compressed JPEG (max edge 640px) for AI reading; path is the original full-res PNG file; full_size = original bytes"
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

// MARK: - v7.1.287：系统级引擎A（免注入）——与注入式 ControlAgent 结合成统一 control 接口
// 复用已有：HIDTouchInjector(IOHID 系统级触摸) + LSApplicationWorkspace(系统启动) + UIThreadBridge(剪贴板)。
// 目标 app 未注入时，control.tap/swipe 自动回退到本引擎；sys_launch 免注入启动任意 app。
// verified:false——需真机验证 entitlement 生效（TrollStore 无沙箱 + com.apple.private.hid.client.event-dispatch）。

final class SystemUIEngine {
    static let shared = SystemUIEngine()

    /// 系统级启动 app（TrollStore 可用：LSApplicationWorkspace 私有 API，不依赖 shell/注入）
    func launch(bundleId: String) -> [String: Any] {
        if let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           ws.responds(to: NSSelectorFromString("openApplicationWithBundleID:")) {
            _ = ws.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleId)
            return ["ok": true, "engine": "system", "method": "LSApplicationWorkspace", "bundle_id": bundleId,
                    "hint": "launched via system (no injection). Then use control.sys_tap / sys_swipe to control it, or control.screenshot / control.ui_tree (if injected) to read screen."]
        }
        return ["ok": false, "engine": "system", "error": "LSApplicationWorkspace unavailable",
                "hint": "fallback: control.inject the target app then use injected control"]
    }

    /// 系统级 HID 点击当前前台 app（无需注入目标 app）
    func tap(x: Double, y: Double) -> [String: Any] {
        let ok = HIDTouchInjector.shared.tap(x: Float(x), y: Float(y))
        return ["ok": ok, "engine": "system_hid", "tap_x": x, "tap_y": y,
                "hint": ok ? "system HID tap (no injection)" : "HID unavailable: needs com.apple.private.hid.client.event-dispatch entitlement (TrollStore ok)"]
    }

    /// 系统级 HID 滑动当前前台 app
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, durationMs: Int = 300) -> [String: Any] {
        let ok = HIDTouchInjector.shared.swipe(x1: Float(x1), y1: Float(y1), x2: Float(x2), y2: Float(y2), durationMs: durationMs)
        return ["ok": ok, "engine": "system_hid",
                "hint": ok ? "system HID swipe" : "HID unavailable (entitlement?)"]
    }

    /// 剪贴板写入（输入文字兜底：未注入时把搜索词 paste 到搜索框）
    func paste(_ text: String) -> [String: Any] {
        UIThreadBridge.paste(text)
        return ["ok": true, "engine": "system", "clipboard": text,
                "hint": "text copied to clipboard. In the target app long-press the input field and choose Paste."]
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

// MARK: - v7.1.287：语义控制辅助（番茄小说/通用 App 闭环：role+name → 唯一节点 → 点中心）
// 解决根因：书名/书城文字在子 UILabel，可点的是父 cell/button；把子树文本聚合到可点父，并做唯一性匹配。
// 适配 v7.1.281+ 的节点字段：accessibility_role / accessibility_label / is_accessibility_element / frame。

enum ControlSemantics {
    /// 可点击角色白名单（小写）。UILabel/static_text 本身通常不可点，可点父多为 cell/button/tab。
    static let actionableRoles: Set<String> = [
        "button", "link", "tab", "cell", "collection_view_cell", "table_view_cell",
        "collectionviewcell", "tableviewcell", "image_button", "switch", "tabbar",
        "scrollview", "text_view", "slider", "text_field", "image"
    ]

    /// 提取节点 role（accessibility_role / role / type，小写）
    static func role(of node: [String: Any]) -> String? {
        if let r = node["accessibility_role"] as? String { return r.lowercased() }
        if let r = node["role"] as? String { return r.lowercased() }
        if let r = node["type"] as? String { return r.lowercased() }
        return nil
    }

    /// 节点自身文本（text / label / accessibilityLabel / accessibility_label）
    /// 借鉴 Appium：accessibilityIdentifier 是最稳定位锚（与 UI 文本解耦），纳入定位
    static func nodeText(_ node: [String: Any]) -> String {
        (node["text"] as? String) ?? (node["label"] as? String)
            ?? (node["accessibilityLabel"] as? String) ?? (node["accessibility_label"] as? String)
            ?? (node["accessibilityIdentifier"] as? String) ?? (node["identifier"] as? String) ?? ""
    }

    /// 聚合子树全部文本（自身+后代，去空去重保序）——让"书城/书名"落到可点父
    static func subtreeText(_ node: [String: Any]) -> String {
        var parts: [String] = []
        collectText(node, into: &parts)
        var seen = Set<String>()
        var out: [String] = []
        for p in parts where !p.isEmpty {
            if !seen.contains(p) { seen.insert(p); out.append(p) }
        }
        return out.joined(separator: " ")
    }

    private static func collectText(_ node: [String: Any], into parts: inout [String]) {
        let t = nodeText(node)
        if !t.isEmpty { parts.append(t) }
        if let ch = node["children"] as? [[String: Any]] {
            for c in ch { collectText(c, into: &parts) }
        }
    }

    /// 是否可点击：enabled 显式 false 先拦截（借鉴 WebDriverAgent predicate enabled==true）；
    /// 其次 isHittable / is_accessibility_element；再可点角色；缺省（leaf+有 frame）保守视为可点
    static func isActionable(_ node: [String: Any]) -> Bool {
        if let en = node["enabled"] as? Bool, !en { return false }
        if let en = node["isEnabled"] as? Bool, !en { return false }
        if let h = node["isHittable"] as? Bool { return h }
        if let h = node["hittable"] as? Bool { return h }
        if let a = node["is_accessibility_element"] as? Bool { return a }
        if let r = role(of: node), actionableRoles.contains(r) { return true }
        let hasChildren = (node["children"] as? [[String: Any]])?.isEmpty == false
        let hasFrame = node["frame"] != nil
        return !hasChildren && hasFrame
    }

    /// 提取 frame -> [x, y, width, height]，缺省 [0,0,0,0]
    static func frame(_ node: [String: Any]) -> [Double] {
        guard let f = node["frame"] as? [String: Any],
              let x = f["x"] as? Double, let y = f["y"] as? Double,
              let w = f["width"] as? Double, let h = f["height"] as? Double else { return [0, 0, 0, 0] }
        return [x, y, w, h]
    }

    static func isVisible(_ node: [String: Any]) -> Bool {
        (node["isVisible"] as? Bool) ?? (node["visible"] as? Bool) ?? true
    }

    /// 从树里取节点数组（兼容 nodes / elements / tree 三种容器）
    static func nodeList(_ tree: [String: Any]) -> [[String: Any]] {
        if let n = tree["nodes"] as? [[String: Any]] { return n }
        if let e = tree["elements"] as? [[String: Any]] { return e }
        if let t = tree["tree"] as? [[String: Any]] { return t }
        return []
    }

    /// 从所有节点 frame 的边界推断屏幕尺寸 [width, height]（近似，供滚动幅度估算）
    static func screenSize(of nodes: [[String: Any]]) -> [Double] {
        var maxX = 0.0, maxY = 0.0
        func scan(_ n: [String: Any]) {
            let f = frame(n)
            maxX = max(maxX, f[0] + f[2]); maxY = max(maxY, f[1] + f[3])
            if let ch = n["children"] as? [[String: Any]] { for c in ch { scan(c) } }
        }
        for n in nodes { scan(n) }
        return maxX > 10 && maxY > 10 ? [maxX, maxY] : [390, 844]
    }

    // FNV-1a 64 位，输出稳定十六进制指纹（无需 CryptoKit）
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// 语义指纹：role + 子树文本 + 自身文本 + 最近 2 层父语义。
    /// 同一控件（同 role/文本/父链）每次读树得到相同指纹 → 可安全"锁"复用；树变后查不到 → 安全失效。
    static func semanticFingerprint(_ node: [String: Any], ancestors: [[String: Any]]) -> String {
        let nodeRole = role(of: node) ?? ""
        let subtree = subtreeText(node)
        let own = nodeText(node)
        var parents: [String] = []
        for p in ancestors.prefix(2) {
            let pr = role(of: p) ?? ""
            let pt = nodeText(p)
            parents.append("\(pr):\(pt.prefix(12))")
        }
        let sig = nodeRole + "|" + subtree + "|" + own + "|" + parents.joined(separator: ">")
        return String(format: "fp_%016llx", fnv1a(sig))
    }

    /// 验证闭环（借鉴 Maestro assertVisible）：整树是否包含期望文本
    static func treeContainsText(_ text: String, partial: Bool = false) -> Bool {
        let tree = ControlAgentTools.shared.uiTree()
        let nodes = nodeList(tree)
        var found = false
        func walk(_ n: [String: Any]) {
            if found { return }
            if partial ? subtreeText(n).localizedCaseInsensitiveContains(text) : (subtreeText(n) == text) {
                found = true; return
            }
            if let ch = n["children"] as? [[String: Any]] { for c in ch { walk(c) } }
        }
        for n in nodes { walk(n) }
        return found
    }

    /// 点击后验证期望元素是否出现；未出现给明确提示（点击可能未生效）
    static func attachExpect(_ result: [String: Any], expect: String?, partial: Bool) -> [String: Any] {
        var out = result
        if let e = expect, !e.isEmpty {
            Thread.sleep(forTimeInterval: 0.4)   // 等页面跳转/渲染
            out["verified"] = treeContainsText(e, partial: partial)
            out["expect"] = e
            if out["verified"] as? Bool != true {
                out["expect_hint"] = "期待元素\"\(e)\"未出现——点击可能未生效，请重读 control.ui_tree / control.find"
            }
        }
        return out
    }
}

// MARK: - v3.0.72：control.tap_text — 语义化点击 (传文字，自动找元素点）

final class ControlTapTextTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap_text",
        summary: "PREREQUISITE: call control.inject first. Tap an element by its visible text label. Use for: tap a button/link by its text (e.g. \"搜索\", \"登录\"). Don't use for: tap by coordinates (use control.tap), swipe gesture (use control.swipe).",
        parameters: [
            "text": "Visible text label of the element to tap (REQUIRED)",
            "partial": "If true, match partial text (default false; exact match by default) (optional)",
            "role": "Optional accessibility role filter to disambiguate, e.g. button/cell/tab/link (optional)",
            "expect": "After tapping, verify this text appears on screen (e.g. target page title). Optional."
        ],
        verified: true, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw MCPError.invalidParams("text required")
        }
        let partial = (params["partial"] as? Bool) ?? false
        let role = params["role"] as? String

        // 借鉴 Maestro/Appium：找不到时短暂重试（加载/动画场景），最多 3 次
        var lastError: Error = MCPError.failed("no element matching \"\(text)\" found in UI tree")
        for attempt in 0..<3 {
            do {
                let tree = ControlAgentTools.shared.uiTree()
                let nodes = ControlSemantics.nodeList(tree)
                guard !nodes.isEmpty else { throw MCPError.failed("cannot parse UI tree") }
                return ControlSemantics.attachExpect(try findAndTap(nodes: nodes, text: text, partial: partial, role: role),
                                                     expect: params["expect"] as? String, partial: partial)
            } catch {
                lastError = error
                let m = "\(error)"
                let retryable = m.contains("no element") || m.contains("cannot parse") || m.contains("not found")
                if retryable && attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.4)
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private struct Candidate {
        let frame: [Double]
        let area: Double
        let hittable: Bool
    }

    private func findAndTap(nodes: [[String: Any]], text: String, partial: Bool, role: String?) throws -> [String: Any] {
        // 语义闭环：匹配文字 → 向上找最近可点击祖先（书城/书名在子 UILabel，可点父是 button/cell）→ 唯一性排序 → 点中心
        var candidates: [Candidate] = []

        func walk(_ node: [String: Any], _ ancestors: [[String: Any]]) {
            let t = ControlSemantics.nodeText(node)
            var matched = partial ? t.localizedCaseInsensitiveContains(text) : (t == text)
            if matched, let r = role {
                matched = (ControlSemantics.role(of: node) == r.lowercased())
            }
            if matched {
                var chain = [node] + ancestors   // 近→远：node 在前，ancestors[0] 是最近父
                var targetFrame = [0.0, 0.0, 0.0, 0.0]
                var targetHittable = false
                for n in chain {
                    if ControlSemantics.isActionable(n) {
                        targetFrame = ControlSemantics.frame(n)
                        targetHittable = true
                        break
                    }
                }
                if targetFrame == [0.0, 0.0, 0.0, 0.0] {
                    targetFrame = ControlSemantics.frame(node)
                }
                let area = targetFrame[2] * targetFrame[3]
                candidates.append(Candidate(frame: targetFrame, area: area, hittable: targetHittable))
            }
            if let ch = node["children"] as? [[String: Any]] {
                var newAnc = ancestors
                newAnc.insert(node, at: 0)
                for c in ch { walk(c, newAnc) }
            }
        }
        for n in nodes { walk(n, []) }

        guard !candidates.isEmpty else {
            throw MCPError.failed("no element matching \"\(text)\" found in UI tree")
        }
        // 排序：可点优先；同可点按可视面积大优先
        candidates.sort { a, b in
            if a.hittable != b.hittable { return a.hittable && !b.hittable }
            return a.area > b.area
        }
        let best = candidates[0]
        let cx = best.frame[0] + best.frame[2] / 2
        let cy = best.frame[1] + best.frame[3] / 2

        AuditLog.shared.log("control.tap_text", detail: "\"\(text)\" at (\(cx),\(cy)) matches=\(candidates.count)")
        var result = ControlAgentTools.shared.tap(x: cx, y: cy)
        result["matched_text"] = text
        result["match_count"] = candidates.count
        result["tap_x"] = cx
        result["tap_y"] = cy
        if candidates.count > 1 {
            result["hint"] = "\(candidates.count) matches; tapped the largest hittable target. To disambiguate pass exact role, or list first with control.find."
        }
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

// MARK: - v7.1.287：control.find — 查询式精简 UI 树（只回匹配节点，不烧 token）

final class ControlFindTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.find",
        summary: "PREREQUISITE: control.inject first. Query the UI tree and return only matching actionable/visible nodes (role/name/text/frame), NOT the whole tree. Use for: locate a book/tab/button before tapping, or check what's on screen without a huge tree. Don't use for: actual tapping (use control.tap_selector / tap_text).",
        parameters: [
            "text": "Optional text to match (exact unless partial=true) (optional)",
            "role": "Optional role to filter, e.g. button/cell/tab/link (optional)",
            "partial": "If true match partial text (default false) (optional)",
            "visible_only": "Only return visible nodes (default true) (optional)",
            "actionable_only": "Only return actionable (clickable) nodes (default true) (optional)",
            "limit": "Max results returned (default 20) (optional)"
        ],
        verified: false, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let text = params["text"] as? String
        let role = params["role"] as? String
        let partial = (params["partial"] as? Bool) ?? false
        let visibleOnly = (params["visible_only"] as? Bool) ?? true
        let actionableOnly = (params["actionable_only"] as? Bool) ?? true
        let limit = (params["limit"] as? Int) ?? 20

        let tree = ControlAgentTools.shared.uiTree()
        let nodes = ControlSemantics.nodeList(tree)
        guard !nodes.isEmpty else {
            throw MCPError.failed("cannot parse UI tree")
        }

        var out: [[String: Any]] = []
        func walk(_ node: [String: Any], _ ancestors: [[String: Any]]) {
            if out.count >= limit { return }
            let t = ControlSemantics.nodeText(node)
            var ok = true
            if let text = text {
                let direct = partial ? t.localizedCaseInsensitiveContains(text) : (t == text)
                let agg = ControlSemantics.subtreeText(node)
                let viaAgg = partial ? agg.localizedCaseInsensitiveContains(text) : (agg == text)
                ok = direct || viaAgg
            }
            if let r = role, ok {
                ok = (ControlSemantics.role(of: node) == r.lowercased())
            }
            if visibleOnly && ok {
                ok = ControlSemantics.isVisible(node)
            }
            if actionableOnly && ok {
                ok = ControlSemantics.isActionable(node)
            }
            if ok {
                out.append([
                    "role": ControlSemantics.role(of: node) ?? "",
                    "name": ControlSemantics.subtreeText(node),
                    "text": t,
                    "frame": ControlSemantics.frame(node),
                    "fingerprint": ControlSemantics.semanticFingerprint(node, ancestors: ancestors)
                ])
            }
            if let ch = node["children"] as? [[String: Any]] {
                var newAnc = ancestors
                newAnc.insert(node, at: 0)
                for c in ch { walk(c, newAnc) }
            }
        }
        for n in nodes { walk(n, []) }

        return ["ok": true, "count": out.count, "results": out,
                "hint": "use control.tap_selector role:... name:... to tap, or control.tap_node fingerprint:<fp> to reuse a stable node, or control.scroll_find_tap text:... to scroll-and-tap"]
    }
}

// MARK: - v7.1.287：control.tap_selector — 语义直点 (role + name → 唯一节点 → 点中心，不传坐标)

final class ControlTapSelectorTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap_selector",
        summary: "PREREQUISITE: control.inject first. Tap the single actionable element matching role+name (subtree text aggregated). e.g. tap_selector role:'button' name:'书城'. No coordinates needed — device-side match. Don't use for: coordinate taps (control.tap), pure text tap (control.tap_text).",
        parameters: [
            "name": "Subtree text (name) of the element to tap — REQUIRED. Use aggregated text, e.g. '书城' for the tab button",
            "role": "Optional role to filter, e.g. button/cell/tab/link (optional)",
            "partial": "If true match partial name (default false) (optional)",
            "expect": "After tapping, verify this text appears on screen (e.g. target page title). Optional."
        ],
        verified: false, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required. Use aggregated text like '书城'.")
        }
        let role = params["role"] as? String
        let partial = (params["partial"] as? Bool) ?? false

        var frames: [[Double]] = []
        // 借鉴 Maestro/Appium：找不到时短暂重试（加载/动画），最多 3 次
        for attempt in 0..<3 {
            let tree = ControlAgentTools.shared.uiTree()
            let nodes = ControlSemantics.nodeList(tree)
            guard !nodes.isEmpty else {
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.4); continue }
                throw MCPError.failed("cannot parse UI tree")
            }
            frames = []
            func walk(_ node: [String: Any]) {
                if ControlSemantics.isActionable(node) {
                    let agg = ControlSemantics.subtreeText(node)
                    var ok = partial ? agg.localizedCaseInsensitiveContains(name) : (agg == name)
                    if let r = role, ok {
                        ok = (ControlSemantics.role(of: node) == r.lowercased())
                    }
                    if ok {
                        frames.append(ControlSemantics.frame(node))
                    }
                }
                if let ch = node["children"] as? [[String: Any]] {
                    for c in ch { walk(c) }
                }
            }
            for n in nodes { walk(n) }
            if !frames.isEmpty { break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
        }

        guard !frames.isEmpty else {
            throw MCPError.failed("no actionable element matching role:\(role ?? "any") name:\"\(name)\" found")
        }
        frames.sort { ($0[2] * $0[3]) > ($1[2] * $1[3]) }
        let best = frames[0]
        let cx = best[0] + best[2] / 2
        let cy = best[1] + best[3] / 2

        AuditLog.shared.log("control.tap_selector", detail: "role:\(role ?? "any") name:\"\(name)\" matches=\(frames.count)")
        var result = ControlAgentTools.shared.tap(x: cx, y: cy)
        result["matched_name"] = name
        result["match_count"] = frames.count
        result["tap_x"] = cx
        result["tap_y"] = cy
        if frames.count > 1 {
            result["hint"] = "\(frames.count) actionable nodes matched; tapped the largest. Add exact role or use control.find to inspect."
        }
        return ControlSemantics.attachExpect(result, expect: params["expect"] as? String, partial: partial)
    }
}

// MARK: - v7.1.287：control.tap_node — 语义指纹直点 (通用锁 ID：同屏内可复用、树变即失效)

final class ControlTapNodeTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.tap_node",
        summary: "PREREQUISITE: control.inject first. Tap the single actionable element by its semantic fingerprint (returned by control.find). Reuse the same fingerprint within one screen — it is stable across reads. If the tree changed (scrolled/navigated) the fingerprint won't be found and this reports it. Use for: tap an already-located node fast without re-searching. Don't use for: first-time locate (use control.find then tap_node, or tap_selector/tap_text directly).",
        parameters: [
            "fingerprint": "Semantic fingerprint from control.find results — REQUIRED (e.g. fp_...)",
            "name": "Optional human-readable name for logging (optional)",
            "expect": "After tapping, verify this text appears on screen (e.g. target page title). Optional."
        ],
        verified: false, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let fp = params["fingerprint"] as? String, !fp.isEmpty else {
            throw MCPError.invalidParams("fingerprint required. Get it from control.find / ui_tree results.")
        }

        var frames: [[Double]] = []
        // 借鉴 Maestro/Appium：页面加载/滚动中短暂重试，最多 3 次
        for attempt in 0..<3 {
            let tree = ControlAgentTools.shared.uiTree()
            let nodes = ControlSemantics.nodeList(tree)
            guard !nodes.isEmpty else {
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.4); continue }
                throw MCPError.failed("cannot parse UI tree")
            }
            frames = []
            func walk(_ node: [String: Any], _ ancestors: [[String: Any]]) {
                if ControlSemantics.isActionable(node),
                   ControlSemantics.semanticFingerprint(node, ancestors: ancestors) == fp {
                    frames.append(ControlSemantics.frame(node))
                }
                if let ch = node["children"] as? [[String: Any]] {
                    var newAnc = ancestors
                    newAnc.insert(node, at: 0)
                    for c in ch { walk(c, newAnc) }
                }
            }
            for n in nodes { walk(n, []) }
            if !frames.isEmpty { break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
        }

        guard !frames.isEmpty else {
            throw MCPError.failed("fingerprint \(fp) not found — the UI tree changed (scrolled/navigated). Re-run control.find and take a fresh fingerprint.")
        }
        frames.sort { ($0[2] * $0[3]) > ($1[2] * $1[3]) }
        let best = frames[0]
        let cx = best[0] + best[2] / 2
        let cy = best[1] + best[3] / 2
        var result = ControlAgentTools.shared.tap(x: cx, y: cy)
        result["fingerprint"] = fp
        result["tap_x"] = cx
        result["tap_y"] = cy
        return ControlSemantics.attachExpect(result, expect: params["expect"] as? String, partial: false)
    }
}

// MARK: - v7.1.287：control.scroll_find_tap — 滚动查找并点击 (一次调用完成，长列表通用)

final class ControlScrollFindTapTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.scroll_find_tap",
        summary: "PREREQUISITE: control.inject first. Scroll the list and tap the first matching actionable element — all on the device side, in ONE call. Use for: locate & tap a book/tab far down a long list (e.g. 番茄小说). Returns what was tapped + fingerprint. Don't use for: tap something already visible (use tap_selector/tap_text — faster).",
        parameters: [
            "text": "Text to find while scrolling (REQUIRED)",
            "role": "Optional role filter, e.g. cell/button/link (optional)",
            "partial": "If true match partial text (default false) (optional)",
            "direction": "Scroll direction: 'up' = swipe up to reveal later content (default, finds items further down), 'down' = swipe down toward the top (optional)",
            "max_swipes": "Max scroll swipes before giving up (default 6) (optional)",
            "expect": "After tapping, verify this text appears on screen (e.g. target page title). Optional."
        ],
        verified: false, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let text = params["text"] as? String, !text.isEmpty else {
            throw MCPError.invalidParams("text required")
        }
        let role = params["role"] as? String
        let partial = (params["partial"] as? Bool) ?? false
        let direction = (params["direction"] as? String) ?? "up"
        let maxSwipes = max(1, (params["max_swipes"] as? Int) ?? 6)

        // 1) 先看当前屏有没有
        var tree = ControlAgentTools.shared.uiTree()
        var nodes = ControlSemantics.nodeList(tree)
        guard !nodes.isEmpty else {
            throw MCPError.failed("cannot parse UI tree")
        }
        if let hit = findMatch(nodes: nodes, text: text, partial: partial, role: role) {
            return ControlSemantics.attachExpect(tapHit(hit, text: text, swipes: 0),
                                                 expect: params["expect"] as? String, partial: partial)
        }

        let screen = ControlSemantics.screenSize(of: nodes)
        let midX = screen[0] / 2
        let upper = screen[1] * 0.8
        let lower = screen[1] * 0.2
        // 2) 滚动查找（最多 maxSwipes 次）
        for s in 1...maxSwipes {
            let swipeResult: [String: Any]
            if direction == "down" {
                swipeResult = ControlAgentTools.shared.swipe(x1: midX, y1: upper, x2: midX, y2: lower, duration: 0.3)
            } else {
                swipeResult = ControlAgentTools.shared.swipe(x1: midX, y1: lower, x2: midX, y2: upper, duration: 0.3)
            }
            if let err = swipeResult["error"] as? String {
                throw MCPError.failed("swipe failed: \(err)")
            }
            Thread.sleep(forTimeInterval: 0.25)   // 等滚动/渲染稳定
            tree = ControlAgentTools.shared.uiTree()
            nodes = ControlSemantics.nodeList(tree)
            guard !nodes.isEmpty else { throw MCPError.failed("ui_tree empty after swipe") }
            if let hit = findMatch(nodes: nodes, text: text, partial: partial, role: role) {
                return ControlSemantics.attachExpect(tapHit(hit, text: text, swipes: s),
                                                     expect: params["expect"] as? String, partial: partial)
            }
        }
        throw MCPError.failed("\(text) not found after scrolling \(maxSwipes) times \(direction). It may be off-list or the list ended.")
    }

    private func tapHit(_ hit: (cx: Double, cy: Double, fp: String), text: String, swipes: Int) -> [String: Any] {
        var r = ControlAgentTools.shared.tap(x: hit.cx, y: hit.cy)
        r["matched_text"] = text
        r["fingerprint"] = hit.fp
        r["tap_x"] = hit.cx
        r["tap_y"] = hit.cy
        r["swipes"] = swipes
        return r
    }

    /// 匹配文本（子树聚合）+ 向上找可点祖先，选面积最大的命中
    private func findMatch(nodes: [[String: Any]], text: String, partial: Bool, role: String?) -> (cx: Double, cy: Double, fp: String)? {
        var best: (cx: Double, cy: Double, fp: String)?
        var bestArea = -1.0
        func walk(_ node: [String: Any], _ ancestors: [[String: Any]]) {
            let agg = ControlSemantics.subtreeText(node)
            var ok = partial ? agg.localizedCaseInsensitiveContains(text) : (agg == text)
            if ok, let r = role { ok = (ControlSemantics.role(of: node) == r.lowercased()) }
            if ok {
                var target = [0.0, 0.0, 0.0, 0.0]
                var chain = [node] + ancestors
                for n in chain where ControlSemantics.isActionable(n) {
                    target = ControlSemantics.frame(n)
                    break
                }
                if target == [0.0, 0.0, 0.0, 0.0] { target = ControlSemantics.frame(node) }
                let area = target[2] * target[3]
                if area > bestArea {
                    bestArea = area
                    let cx = target[0] + target[2] / 2
                    let cy = target[1] + target[3] / 2
                    best = (cx, cy, ControlSemantics.semanticFingerprint(node, ancestors: ancestors))
                }
            }
            if let ch = node["children"] as? [[String: Any]] {
                var newAnc = ancestors
                newAnc.insert(node, at: 0)
                for c in ch { walk(c, newAnc) }
            }
        }
        for n in nodes { walk(n, []) }
        return best
    }
}

// MARK: - v7.1.287：control.actions — 多步动作批处理
// 一次决策、设备端连续执行（借鉴 Apelin agent 会话连续 uiAction，砍掉中间重读树/回传往返）。
// AI 输出动作串 + 策略；默认连续执行，某步失败即停并报告失败点；失败可回退逐步。

final class ControlActionsTool: MCPTool {
    let definition = ToolDefinition(
        name: "control.actions",
        summary: "PREREQUISITE: control.inject first. Execute a sequence of control actions on the device in ONE call — the AI decides the action chain, the device runs it back-to-back (fast, like Apelin's agent session). Use for: a known multi-step flow (e.g. open 抖音 then swipe up 5 times) without re-reading the tree between steps. Don't use for: first-time discovery of what's on screen (use control.find / control.ui_tree).",
        parameters: [
            "actions": "Array of action dicts, each {op, ...}. op: tap_text(text,partial?,role?,expect?) / tap_selector(name,role?,partial?,expect?) / tap_node(fingerprint,expect?) / swipe(direction,count?,expect?) / scroll_find_tap(text,role?,partial?,direction?,max_swipes?,expect?) / wait(seconds). (REQUIRED)",
            "strategy": "'continuous' (default) runs all actions back-to-back without re-reading the tree; stops and reports the failed step if one fails. 'stepwise' keeps per-step expect/verification (slower, safer). Optional",
            "expect": "Optional final text to verify after the whole sequence (optional)"
        ],
        verified: false, category: "ui_control")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let actions = params["actions"] as? [[String: Any]], !actions.isEmpty else {
            throw MCPError.invalidParams("actions: non-empty array of {op,...} required")
        }
        let strategy = (params["strategy"] as? String) ?? "continuous"
        var results: [[String: Any]] = []

        for (i, action) in actions.enumerated() {
            guard let op = action["op"] as? String, !op.isEmpty else {
                throw MCPError.invalidParams("actions[\(i)].op required: tap_text/tap_selector/tap_node/swipe/scroll_find_tap/wait/sys_launch/sys_tap/sys_swipe/sys_paste")
            }
            var inner = action
            inner.removeValue(forKey: "op")
            do {
                results.append(try Self.run(op: op, params: inner))
            } catch {
                results.append(["ok": false, "op": op, "error": "\(error)"])
                return [
                    "ok": false,
                    "strategy": strategy,
                    "step_failed": i,
                    "failed_op": op,
                    "done": results,
                    "hint": "Sequence stopped at step \(i) (\(op)). Re-read the tree (control.ui_tree / control.find) and retry, or set strategy:'stepwise' for per-step verified execution."
                ]
            }
        }

        var out: [String: Any] = ["ok": true, "strategy": strategy, "results": results, "steps": results.count]
        if let exp = params["expect"] as? String, !exp.isEmpty {
            out = ControlSemantics.attachExpect(out, expect: exp, partial: false)
        }
        return out
    }

    private static func run(op: String, params: [String: Any]) throws -> [String: Any] {
        switch op {
        case "tap_text":
            return try ControlTapTextTool().invoke(params)
        case "tap_selector":
            return try ControlTapSelectorTool().invoke(params)
        case "tap_node":
            return try ControlTapNodeTool().invoke(params)
        case "scroll_find_tap":
            return try ControlScrollFindTapTool().invoke(params)
        case "swipe":
            // 屏幕级滑动：方向 + 可选次数（连续 N 次上划/下划），设备端本地连续注入
            // v7.1.287：注入式优先，未注入自动回退系统级 HID（引擎A）
            let direction = (params["direction"] as? String) ?? "up"
            let count = max(1, (params["count"] as? Int) ?? 1)
            let tree = ControlAgentTools.shared.uiTree()
            let nodes = ControlSemantics.nodeList(tree)
            let screen = ControlSemantics.screenSize(of: nodes)
            let midX = screen[0] > 0 ? screen[0] / 2 : Double(UIScreen.main.bounds.width) / 2
            let upper = screen[1] > 0 ? screen[1] * 0.8 : Double(UIScreen.main.bounds.height) * 0.8
            let lower = screen[1] > 0 ? screen[1] * 0.2 : Double(UIScreen.main.bounds.height) * 0.2
            var last: [String: Any] = [:]
            var usedSystem = false
            for _ in 0..<count {
                if direction == "down" {
                    last = ControlAgentTools.shared.swipe(x1: midX, y1: upper, x2: midX, y2: lower, duration: 0.3)
                    if last["error"] != nil { usedSystem = true; last = SystemUIEngine.shared.swipe(x1: midX, y1: upper, x2: midX, y2: lower) }
                } else {
                    last = ControlAgentTools.shared.swipe(x1: midX, y1: lower, x2: midX, y2: upper, duration: 0.3)
                    if last["error"] != nil { usedSystem = true; last = SystemUIEngine.shared.swipe(x1: midX, y1: lower, x2: midX, y2: upper) }
                }
                if last["error"] != nil { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            var r = last
            r["direction"] = direction
            r["count"] = count
            r["engine"] = usedSystem ? "system_hid" : "injected"
            if r["error"] == nil { r["ok"] = true }
            if let exp = params["expect"] as? String, !exp.isEmpty {
                r = ControlSemantics.attachExpect(r, expect: exp, partial: (params["partial"] as? Bool) ?? false)
            }
            return r
        case "wait":
            let secs = (params["seconds"] as? Double) ?? 0.5
            Thread.sleep(forTimeInterval: max(0, secs))
            return ["ok": true, "waited_seconds": secs]
        // v7.1.287：引擎A（系统级免注入）动作，可在 actions 批处理内混合使用
        case "sys_launch":
            guard let bundleId = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required for sys_launch") }
            return SystemUIEngine.shared.launch(bundleId: bundleId)
        case "sys_tap":
            guard let x = params["x"] as? Double, let y = params["y"] as? Double else { throw MCPError.invalidParams("x,y required for sys_tap") }
            return SystemUIEngine.shared.tap(x: x, y: y)
        case "sys_swipe":
            guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
                  let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else { throw MCPError.invalidParams("x1,y1,x2,y2 required for sys_swipe") }
            return SystemUIEngine.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: (params["duration_ms"] as? Int) ?? 300)
        case "sys_paste":
            guard let text = params["text"] as? String else { throw MCPError.invalidParams("text required for sys_paste") }
            return SystemUIEngine.shared.paste(text)
        default:
            throw MCPError.invalidParams("unknown op: \(op)")
        }
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
        summary: "Control target app UI. Subcommands: inject / status / ui_tree / find / screenshot / tap / swipe / type / key / tap_text / tap_selector / tap_node / scroll_find_tap / actions / sys_launch / sys_tap / sys_swipe / sys_paste / type_text. Params per subcommand: tap→x,y(Number); swipe→x1,y1,x2,y2(Number); type→text; tap_text→text,partial?,role?; tap_selector→name,role?,partial?; tap_node→fingerprint; scroll_find_tap→text,role?,partial?,direction?,max_swipes?; actions→actions(array of {op,...}),strategy?; find→text?,role?,partial?,visible_only?,actionable_only?,limit?; type_text→placeholder+text; key→key(home/back/enter); inject→bundle_id; sys_launch→bundle_id; sys_tap→x,y; sys_swipe→x1,y1,x2,y2,duration_ms?; sys_paste→text; others none. Use for: UI automation / app screen control. DUAL ENGINE (v7.1.287): tap/swipe auto-route — if the target app is injected (ControlAgent 4789 online) they run in-process; if not, they automatically fall back to SYSTEM HID (no injection, works on the current foreground app). Use sys_launch to launch any app without injecting; use sys_tap/sys_swipe for no-injection HID touch; use sys_paste to put text into the clipboard (for search boxes when not injected). Semantic UI tree (v7.1.281+): ui_tree nodes carry accessibility_role (button/link/text_field/switch/image/...), accessibility_label (human name), accessibility_value, is_accessibility_element and frame — locate an element by role+label, then tap its frame center; do NOT hardcode coordinates when labels are available. PREFER semantic taps: tap_selector(role,name), tap_text(text), or tap_node(fingerprint) — no coordinates; use find to list matches cheaply; use scroll_find_tap(text) to scroll-and-tap a long list in one call; use actions([...]) to run a known multi-step flow in one fast call. First `inject` to install ControlAgent, then call other subcommands.",
        parameters: [
            "command": "Subcommand (required): inject / status / ui_tree / find / screenshot / tap / swipe / type / key / tap_text / tap_selector / tap_node / scroll_find_tap / actions / sys_launch / sys_tap / sys_swipe / sys_paste / type_text",
            "duration_ms": "Swipe duration ms — for sys_swipe (optional)",
            "actions": "Action array — REQUIRED for actions. Each {op,...}: tap_text/tap_selector/tap_node/swipe(direction,count?)/scroll_find_tap/wait(seconds)",
            "strategy": "'continuous' or 'stepwise' — for actions",
            "bundle_id": "App bundle ID — REQUIRED for inject only",
            "x": "X coordinate Number — REQUIRED for tap",
            "y": "Y coordinate Number — REQUIRED for tap",
            "x1": "Start X Number — REQUIRED for swipe",
            "y1": "Start Y Number — REQUIRED for swipe",
            "x2": "End X Number — REQUIRED for swipe",
            "y2": "End Y Number — REQUIRED for swipe",
            "text": "Text string — REQUIRED for type / tap_text",
            "name": "Aggregated name — REQUIRED for tap_selector",
            "role": "Role filter — optional for tap_text/tap_selector/find",
            "partial": "Partial text match (default false) — optional",
            "visible_only": "Only visible (default true) — for find",
            "actionable_only": "Only clickable (default true) — for find",
            "limit": "Max find results (default 20) — for find",
            "fingerprint": "Semantic fingerprint — REQUIRED for tap_node",
            "direction": "Scroll direction up/down (default up) — for scroll_find_tap",
            "max_swipes": "Max swipes before giving up (default 6) — for scroll_find_tap",
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
            let injected = ControlAgentTools.shared.tap(x: x, y: y)
            if injected["error"] == nil {
                injected["engine"] = "injected"
                let d = ControlNotifier.describe(command: "tap", result: injected, extra: "已点击 (\(Int(x)), \(Int(y))) [注入式]")
                ControlNotifier.post(command: "tap", ok: d.ok, detail: d.detail)
                return injected
            }
            // 未注入 → 自动回退系统级 HID（引擎A，免注入）
            var sys = SystemUIEngine.shared.tap(x: x, y: y)
            sys["fallback_reason"] = injected["error"] ?? "injected unreachable"
            let sd = ControlNotifier.describe(command: "tap", result: sys, extra: "已点击 (\(Int(x)), \(Int(y))) [系统HID]")
            ControlNotifier.post(command: "tap", ok: sd.ok, detail: sd.detail)
            return sys

        case "swipe":
            guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
                  let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
                throw MCPError.invalidParams("x1,y1,x2,y2 required. Usage: control swipe x1:100 y1:200 x2:300 y2:400 (all Numbers)")
            }
            let injected = ControlAgentTools.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: 0.3)
            if injected["error"] == nil {
                injected["engine"] = "injected"
                let d = ControlNotifier.describe(command: "swipe", result: injected, extra: "已滑动 (\(Int(x1)),\(Int(y1))) → (\(Int(x2)),\(Int(y2))) [注入式]")
                ControlNotifier.post(command: "swipe", ok: d.ok, detail: d.detail)
                return injected
            }
            // 未注入 → 自动回退系统级 HID（引擎A，免注入）
            var sys = SystemUIEngine.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2)
            sys["fallback_reason"] = injected["error"] ?? "injected unreachable"
            let sd = ControlNotifier.describe(command: "swipe", result: sys, extra: "已滑动 [系统HID]")
            ControlNotifier.post(command: "swipe", ok: sd.ok, detail: sd.detail)
            return sys

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

        // v7.1.287：系统级引擎A子命令（免注入）——启动任意 app / HID 触摸 / 剪贴板
        case "sys_launch":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: control sys_launch bundle_id:'com.ss.iphone.ugc.Aweme'")
            }
            return SystemUIEngine.shared.launch(bundleId: bundleId)

        case "sys_tap":
            guard let x = params["x"] as? Double, let y = params["y"] as? Double else {
                throw MCPError.invalidParams("x and y required. Usage: control sys_tap x:100 y:200")
            }
            return SystemUIEngine.shared.tap(x: x, y: y)

        case "sys_swipe":
            guard let x1 = params["x1"] as? Double, let y1 = params["y1"] as? Double,
                  let x2 = params["x2"] as? Double, let y2 = params["y2"] as? Double else {
                throw MCPError.invalidParams("x1,y1,x2,y2 required. Usage: control sys_swipe x1:100 y1:200 x2:300 y2:400")
            }
            return SystemUIEngine.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2,
                                               durationMs: (params["duration_ms"] as? Int) ?? 300)

        case "sys_paste":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: control sys_paste text:'iphone4'")
            }
            return SystemUIEngine.shared.paste(text)

        case "tap_text":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: control tap_text text:'login'")
            }
            let tapText = try ControlTapTextTool().invoke(params)
            let td = ControlNotifier.describe(command: "tap_text", result: tapText, extra: "已点击文本：\(text.prefix(20))")
            ControlNotifier.post(command: "tap_text", ok: td.ok, detail: td.detail)
            return tapText

        case "tap_selector":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required. Usage: control tap_selector name:'书城' role:'button'")
            }
            let sel = try ControlTapSelectorTool().invoke(params)
            let sd = ControlNotifier.describe(command: "tap_selector", result: sel, extra: "已语义点击：\(name.prefix(20))")
            ControlNotifier.post(command: "tap_selector", ok: sd.ok, detail: sd.detail)
            return sel

        case "find":
            let findResult = try ControlFindTool().invoke(params)
            let fd = ControlNotifier.describe(command: "find", result: findResult)
            ControlNotifier.post(command: "find", ok: fd.ok, detail: fd.detail)
            return findResult

        case "tap_node":
            guard let fp = params["fingerprint"] as? String else {
                throw MCPError.invalidParams("fingerprint required. Usage: control tap_node fingerprint:'fp_...'")
            }
            let nodeRes = try ControlTapNodeTool().invoke(params)
            let nd = ControlNotifier.describe(command: "tap_node", result: nodeRes, extra: "已按指纹点击：\(fp.prefix(20))")
            ControlNotifier.post(command: "tap_node", ok: nd.ok, detail: nd.detail)
            return nodeRes

        case "scroll_find_tap":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: control scroll_find_tap text:'某小说' direction:'up'")
            }
            let scrollRes = try ControlScrollFindTapTool().invoke(params)
            let sd2 = ControlNotifier.describe(command: "scroll_find_tap", result: scrollRes, extra: "滚动查找并点击：\(text.prefix(20))")
            ControlNotifier.post(command: "scroll_find_tap", ok: sd2.ok, detail: sd2.detail)
            return scrollRes

        case "actions":
            let actionsRes = try ControlActionsTool().invoke(params)
            let ad = ControlNotifier.describe(command: "actions", result: actionsRes, extra: "批量动作执行完成")
            ControlNotifier.post(command: "actions", ok: ad.ok, detail: ad.detail)
            return actionsRes

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
            throw MCPError.invalidParams("Unknown command: \(command). Available: inject/status/ui_tree/find/screenshot/tap/swipe/type/key/tap_text/tap_selector/tap_node/scroll_find_tap/actions/type_text")
        }
    }
}
