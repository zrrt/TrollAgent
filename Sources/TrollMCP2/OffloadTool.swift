// OffloadTool：Native Offload 统一入口（v3.3.4）
// 把全部原生 MCP 工具暴露为 Alpine/shell 里的 `ta <tool> <key:value...>` 命令，
// AI 只需学一个入口即可调用任何原生能力，无需记忆 40+ 工具的参数 schema。
// 用法：
//   ta list                     —— 列出全部可用工具
//   ta help <tool>              —— 查看某工具的参数说明
//   ta <tool> <key:value> ...   —— 调用工具（值带空格用引号："..." 或 '...'）
//   ta <tool> {json}            —— 参数整体用 JSON 传入
// 示例：ta app launch bundle_id:com.appstudio.Jinx
//       ta vpn.capture command:start
//       ta artifact path:/var/mobile/Documents/a.txt content:"hello world"

import Foundation

enum OffloadRouter {

    /// 引号感知分词：拆出命令 + 参数，保留引号内空格
    static func splitArgs(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inS = false
        var inD = false
        for c in raw {
            if c == "'" && !inD { inS.toggle(); cur.append(c); continue }
            if c == "\"" && !inS { inD.toggle(); cur.append(c); continue }
            if c == " " && !inS && !inD {
                if !cur.isEmpty { out.append(cur); cur = "" }
                continue
            }
            cur.append(c)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func run(_ raw: String) -> [String: Any] {
        let parts = splitArgs(raw)
        guard parts.count >= 2 else {
            return listHelp(raw)
        }
        let head = parts[0] // "ta"
        let first = parts[1]

        if first == "list" || first == "-l" {
            return listTools(raw)
        }
        if first == "help" {
            if parts.count >= 3 { return toolHelp(parts[2]) }
            return listHelp(raw)
        }
        if first == "version" || first == "--version" {
            return ["command": raw, "exit_code": 0, "stdout": "ta offload 1.0 (TrollAgent)", "hint": "ta list / ta help <tool> / ta <tool> <key:value...>"]
        }
        // 其它：当成工具名
        let toolName = first
        var params: [String: Any] = [:]
        for p in parts.dropFirst(2) {
            if p.hasPrefix("{") {
                // JSON 整体参数
                if let data = p.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    params = obj
                } else {
                    return ["command": raw, "tool": toolName, "exit_code": 1,
                            "stdout": "ta: invalid JSON params: \(p)",
                            "hint": "use key:value pairs or a JSON object: ta <tool> {json}"]
                }
                continue
            }
            if let colon = p.firstIndex(of: ":") {
                let key = String(p[..<colon])
                var value = String(p[p.index(after: colon)...])
                // 去成对引号
                if value.count >= 2,
                   (value.first == "\"" && value.last == "\"") ||
                   (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
                params[key] = value
            } else {
                // 裸词（无冒号）：大工具以 command 驱动 —— 自动映射到 command
                // (ta app status → app command:status）
                if params["command"] == nil {
                    params["command"] = p
                } else {
                    return ["command": raw, "tool": toolName, "exit_code": 1,
                            "stdout": "ta: invalid param '\(p)' (expected key:value)",
                            "hint": "example: ta app launch bundle_id:com.appstudio.Jinx"]
                }
            }
        }

        do {
            let result = try ToolRegistry.shared.dispatch(name: toolName, params: params)
            var out = ["command": raw, "tool": toolName, "exit_code": 0, "result": result] as [String: Any]
            // 若工具返回 stdout，扁平化为可直接读的文本
            if let s = result["stdout"] as? String {
                out["stdout"] = s
                out["result_type"] = "tool_stdout"
            }
            return out
        } catch {
            let msg = (error as? MCPError)?.description ?? error.localizedDescription
            return ["command": raw, "tool": toolName, "exit_code": 1,
                    "stdout": "ta: \(msg)",
                    "hint": "use 'ta list' to see available tools, 'ta help \(toolName)' for its params"]
        }
    }

    private static func listTools(_ raw: String) -> [String: Any] {
        let names = ToolRegistry.shared.allToolNames().sorted()
        var lines: [String] = []
        lines.append("TrollAgent native offload — \(names.count) tools")
        lines.append("usage: ta <tool> <key:value...>  |  ta help <tool>")
        lines.append("")
        for n in names {
            if let t = ToolRegistry.shared.tool(named: n) {
                let s = t.definition.summary
                let short = s.components(separatedBy: "\n").first ?? s
                let head = String(short.prefix(90))
                lines.append("  \(n.padding(toLength: 28, withPad: " ", startingAt: 0))\(head)")
            } else {
                lines.append("  \(n)")
            }
        }
        return ["command": raw, "exit_code": 0, "stdout": lines.joined(separator: "\n"),
                "tool_count": names.count,
                "hint": "ta help <tool> for a specific tool's params"]
    }

    private static func toolHelp(_ toolName: String) -> [String: Any] {
        guard let t = ToolRegistry.shared.tool(named: toolName) else {
            return ["command": "ta help \(toolName)", "exit_code": 1,
                    "stdout": "ta: unknown tool '\(toolName)'",
                    "hint": "use 'ta list' to see available tools"]
        }
        let def = t.definition
        var lines: [String] = []
        lines.append("TOOL: \(def.name)  (category: \(def.category))")
        lines.append("")
        lines.append(def.summary)
        lines.append("")
        if !def.parameters.isEmpty {
            lines.append("PARAMS (key:value):")
            for (k, v) in def.parameters.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(k): \(v)")
            }
        } else {
            lines.append("PARAMS: none (no parameters required)")
        }
        if !def.prerequisites.isEmpty {
            lines.append("")
            lines.append("PREREQUISITES:")
            for p in def.prerequisites { lines.append("  - \(p)") }
        }
        return ["command": "ta help \(toolName)", "exit_code": 0, "tool": toolName,
                "stdout": lines.joined(separator: "\n"),
                "hint": "call it with: ta \(toolName) <key:value...>"]
    }

    private static func listHelp(_ raw: String) -> [String: Any] {
        return ["command": raw, "exit_code": 0,
                "stdout": "ta — TrollAgent native offload\nusage:\n  ta list\n  ta help <tool>\n  ta <tool> <key:value> [key:value...]\n  ta <tool> {json}\nexample:\n  ta app launch bundle_id:com.appstudio.Jinx\n  ta vpn.capture command:start\n  ta shell.exec path:/var/mobile/Documents",
                "hint": "start with 'ta list'"]
    }
}
