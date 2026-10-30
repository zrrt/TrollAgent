import Foundation
import UIKit

// MARK: - v2.9.141 AI 操作宏录制/回放
// 录制：录制开启后，ui.tap/swipe/long_press/clipboard 调用自动入宏 (含截图验证点）
// 回放：MacroRunner 用控制中心实时展示进度 (计划=宏步骤），纯执行+每步截图存证 (不耗 token 调 AI）

enum MacroStore {
    static var dir: URL { Workspace.root.appendingPathComponent("macros", isDirectory: true) }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func save(name: String, steps: [[String: Any]]) throws {
        ensureDir()
        let safe = sanitize(name)
        var payload: [String: Any] = [
            "name": safe,
            "created": Int(Date().timeIntervalSince1970),
            "steps": steps
        ]
        if let old = load(safe), let oc = old["created"] as? Int { payload["created"] = oc }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(safe).appendingPathExtension("json"))
    }

    static func load(_ name: String) -> [String: Any]? {
        ensureDir()
        let url = dir.appendingPathComponent(sanitize(name)).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func list() -> [[String: Any]] {
        ensureDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [[String: Any]] = []
        for f in files where f.pathExtension == "json" {
            guard let obj = load(f.deletingPathExtension().lastPathComponent) else { continue }
            let steps = obj["steps"] as? [[String: Any]] ?? []
            out.append([
                "name": f.deletingPathExtension().lastPathComponent,
                "steps": steps.count,
                "created": obj["created"] as? Int ?? 0
            ])
        }
        out.sort { ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0) }
        return out
    }

    static func delete(_ name: String) -> Bool {
        ensureDir()
        let url = dir.appendingPathComponent(sanitize(name)).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return false
    }

    private static func sanitize(_ name: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: disallowed).joined(separator: "")
        return cleaned.isEmpty ? "macro\(Int(Date().timeIntervalSince1970))" : cleaned
    }
}

// 录制器：全局开关，ui.* 工具调用时 capture
final class MacroRecorder {
    static let shared = MacroRecorder()
    private(set) var isRecording = false
    private(set) var currentName = ""
    private var steps: [[String: Any]] = []

    func start(name: String) {
        currentName = name
        steps = []
        isRecording = true
    }

    /// ui 工具调用钩子：录制中则记录 (裁剪大参数）
    func capture(tool: String, params: [String: Any]) {
        guard isRecording else { return }
        var clean = params
        // reason 保留 (回放说明），大文本裁剪
        if let t = clean["text"] as? String, t.count > 200 { clean["text"] = String(t.prefix(200)) }
        steps.append(["tool": tool, "params": clean])
    }

    @discardableResult
    func stop() -> (ok: Bool, message: String) {
        guard isRecording else { return (false, "not currently recording") }
        isRecording = false
        let name = currentName
        let count = steps.count
        currentName = ""
        steps = []
        guard count > 0 else { return (false, "macro is empty (no actions recorded)") }
        do {
            try MacroStore.save(name: name, steps: steps)
            return (true, "macro \"\(name)\" saved, total \(count) steps")
        } catch {
            return (false, "save failed: \(error.localizedDescription)")
        }
    }

    func cancel() {
        isRecording = false
        currentName = ""
        steps = []
    }
}

// 回放执行器
final class MacroRunner {
    static func run(name: String, loop: Int, stepDelayMs: Int, completion: @escaping (Bool, String) -> Void) {
        guard let macro = MacroStore.load(name) else {
            completion(false, "macro \"\(name)\" does not exist")
            return
        }
        let steps = macro["steps"] as? [[String: Any]] ?? []
        guard !steps.isEmpty else { completion(false, "macro is empty"); return }

        let loops = max(1, min(loop, 100))
        let plan = steps.map { step -> String in
            let tool = step["tool"] as? String ?? "?"
            let p = step["params"] as? [String: Any] ?? [:]
            let reason = p["reason"] as? String ?? ""
            let xy = (p["x"] as? Double).map { " (\(Int($0)),\(Int(p["y"] as? Double ?? 0)))" } ?? ""
            return reason.isEmpty ? "\(tool)\(xy)" : "\(tool)\(xy) — \(reason)"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            ControlSession.shared.begin(target: "macro replay · \(name)", plan: plan)
            var done = 0
            var failed = 0
            for _ in 0..<loops {
                for (i, step) in steps.enumerated() {
                    guard let tool = step["tool"] as? String else { continue }
                    let p = step["params"] as? [String: Any] ?? [:]
                    ControlSession.shared.updateStep(index: i, status: .running, detail: tool)
                    let ok = execute(tool: tool, params: p)
                    if ok {
                        done += 1
                        ControlSession.shared.updateStep(index: i, status: .done, detail: tool)
                    } else {
                        failed += 1
                        ControlSession.shared.updateStep(index: i, status: .failed, detail: "execution failed (replay aborted)")
                        ControlSession.shared.addResult("❌ \(tool) replay failed, aborted")
                        ControlSession.shared.finish(result: "macro \"\(name)\" replay failed at step \(i + 1) (\(tool) execution failed). Check target App state and retry.")
                        DispatchQueue.main.async { completion(false, "step \(i + 1) failed") }
                        return
                    }
                    Thread.sleep(forTimeInterval: Double(max(stepDelayMs, 50)) / 1000.0)
                }
            }
            // 每步截图存证 (最后一步额外留证）
            let sem = DispatchSemaphore(value: 0)
            ScreenCapture.take { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 8)
            ControlSession.shared.addResult("📸 scene screenshot kept")
            ControlSession.shared.finish(result: "macro \"\(name)\" replay done: \(loops) times x \(steps.count) steps, OK \(done), failed \(failed).")
            DispatchQueue.main.async { completion(true, "replay done (\(done) steps OK)") }
        }
    }

    private static func execute(tool: String, params: [String: Any]) -> Bool {
        let x = Float(params["x"] as? Double ?? 0)
        let y = Float(params["y"] as? Double ?? 0)
        switch tool {
        case "ui.tap":
            return HIDTouchInjector.shared.tap(x: x, y: y)
        case "ui.long_press":
            return HIDTouchInjector.shared.longPress(x: x, y: y, durationMs: params["duration_ms"] as? Int ?? 800)
        case "ui.swipe":
            return HIDTouchInjector.shared.swipe(
                x1: x, y1: y,
                x2: Float(params["x2"] as? Double ?? 0), y2: Float(params["y2"] as? Double ?? 0),
                durationMs: params["duration_ms"] as? Int ?? 300)
        case "ui.clipboard":
            UIThreadBridge.paste(params["text"] as? String ?? "")
            return true
        default:
            return false
        }
    }
}

// MARK: - MCP 工具






