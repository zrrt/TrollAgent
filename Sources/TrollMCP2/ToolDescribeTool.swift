import Foundation

// MARK: - 工具分级（唯一权威来源）
//
// 三级工具模型（清晰、不分散）：
// 1) BIG WRAPPED TOOLS（大工具）：子命令多、有前置条件、容易调错——初始 schema 只给一句话用途
//    （省上下文），AI 调用前必须 tool.describe 加载完整说明（子命令枚举 + 参数 + 前置）。
// 2) SMALL TOOLS（小工具）：有少量子命令（command/action 选择器），但参数简单、无复杂前置——
//    保留完整说明直接调，内部子命令照常封装调用，不必 describe。
// 3) SIMPLE TOOLS（简单工具）：单命令、无选择器——完整说明直接调。
//
// 分级只看"是否值得 describe"，不看"有没有选择器"：web.search / wifi / location / macro /
// db / file / server / ssh / remind / package 等虽有小工具子命令，但说明短、不依赖前置，
// 归小工具直接调；app / inject / control / browser / device / memory / network.capture /
// vpn.capture / automation / project / container / github 归大工具，必须先 describe。

/// 大工具白名单：初始 schema 精简 + 调用前必须 tool.describe 的工具。
/// 这是唯一权威列表——MCPCore 的 schema 生成与 tool.describe 共用。
enum BigToolCatalog {
    static let wrappedNames: Set<String> = [
        "app", "inject", "control", "browser", "device", "memory",
        "network.capture", "vpn.capture", "automation", "project", "github",
    ]

    static func isWrapped(_ name: String) -> Bool {
        wrappedNames.contains(name)
    }
}

final class ToolDescribeTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.describe",
        summary: "Load the FULL description of ANY tool before calling it — all tool schemas are slimmed to one line, so describe returns the complete subcommand list, every parameter, and prerequisites. Use for: ALWAYS call this first when about to use a tool you have not loaded — esp. BIG tools (app / inject / control / browser / device / memory / network.capture / vpn.capture / automation / project / github), and any small/simple tool when unsure about its exact params (wifi / location / ssh / reminder / artifact / assistant_memory / knowledge / diagnose / rescue / shell.exec / system.exec_root / web.search / web.fetch / tool.install / skills.* / subagent.* / bind_app / app_write_file …). Don't use for: list what tools exist (use tools.audit). Example: before injecting a dylib → tool.describe name:\"inject\".",
        parameters: [
            "name": "Tool name to describe (required), exactly as shown in the schema — e.g. \"inject\", \"app\", \"control\", \"shell.exec\", \"web.search\"."
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw MCPError.invalidParams("name required — the tool name from the schema, e.g. \"inject\"")
        }
        let reg = ToolRegistry.shared

        // 1) 原始 name 精确匹配
        var resolved = reg.tool(named: name)
        // 2) dotted / ghost 别名（如 "control.tap" → control）
        if resolved == nil, let (real, _) = ToolRegistry.ghostAlias(name) {
            resolved = reg.tool(named: real)
        }
        // 3) apiName（sanitized 名）匹配
        if resolved == nil {
            for n in reg.allToolNames() {
                if let t = reg.tool(named: n), t.definition.apiName == name {
                    resolved = t
                    break
                }
            }
        }
        guard let tool = resolved else {
            throw MCPError.invalidParams("tool not found: \(name). Call system.overview to see the exact tool names.")
        }

        let d = tool.definition

        // 是否大工具：查权威白名单 BigToolCatalog（BIG 复杂、有前置，必须 describe；
        // 其余工具初始 schema 已全量精简，同样建议 describe 加载完整说明后再调）。
        let isWrapped = BigToolCatalog.isWrapped(d.name)
        // 小工具/简单工具如果有 command/action 选择器，也解析出来供参考
        let selKey = d.parameters.keys.first { $0 == "command" || $0 == "action" }
        let selDesc = selKey.flatMap { d.parameters[$0] } ?? ""
        let subcommands: [String] = {
            guard selKey != nil else { return [] }
            // 从 command/action 参数的描述里解析子命令枚举："Subcommand: a / b / c" 或 "current | list | create"
            var s = selDesc
            if let colon = s.range(of: ":") { s = String(s[colon.upperBound...]) }
            // 去掉引号（如 reminder: 'create' / 'schedule'）
            s = s.replacingOccurrences(of: "'", with: "")
            let parts = s.contains("|") ? s.components(separatedBy: "|") : s.components(separatedBy: "/")
            return parts.map {
                // 每段取 "(" 前的子命令名——描述可能带说明（如 memory: "attach (confirms injected and connected…) / search (first scan)…"），
                // 若按整段过滤会丢掉 attach/search/refine/write/freeze/frozen 等核心子命令（只留无括号的项）。
                // 取括号前单词即可同时兼容纯枚举（control: "inject / status / …"）与带说明枚举（memory 式）。
                $0.split(separator: "(").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }.filter { !$0.isEmpty && !$0.contains("(") && !$0.contains(")") }
        }()

        var out: [String: Any] = [
            "name": d.name,
            "category": d.category,
            "summary": d.summary,
            "parameters": d.parameters,
            "prerequisites": d.prerequisites,
            "requires_jailbreak": d.requiresJailbreak,
            "requires_trollstore": d.requiresTrollStore,
        ]
        if !d.prerequisites.isEmpty {
            // 前置条件是硬约束：缺任何一步调用都会失败（工具返回带 next-step 指引）。
            // 显式标 MANDATORY 并按编号列出，避免 AI 把前置当可选项跳过。
            out["prerequisites"] = ["MANDATORY — complete in order or the call FAILS:"] + d.prerequisites.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        }
        if isWrapped {
            out["type"] = "BIG wrapped tool (must describe before calling)"
            out["subcommands"] = subcommands
            out["usage"] = "Call with name:\"\(d.name)\" + command:<one of subcommands> + that subcommand's required params (see parameters). If the subcommand has its own prerequisites (see prerequisites), satisfy them first."
            out["hint"] = d.prerequisites.isEmpty
                ? "Pick the subcommand from `subcommands`, include it in `command`, fill its required params, then call."
                : "Complete the prerequisites first (" + d.prerequisites.joined(separator: "; ") + "), then call with the right subcommand + params."
        } else if !subcommands.isEmpty {
            out["type"] = "small tool (subcommands included, call directly)"
            out["subcommands"] = subcommands
            out["hint"] = "Small tool — initial schema is slimmed; this is the full description. Call directly with name:\"\(d.name)\" + command:<subcommand> + params."
        } else {
            out["type"] = "simple tool (call directly)"
            out["hint"] = d.prerequisites.isEmpty
                ? "Initial schema is slimmed; this is the full description. Call the tool directly using the parameters above."
                : "Complete the prerequisites first (" + d.prerequisites.joined(separator: "; ") + "), then call the tool with the parameters above."
        }
        out["slimmed"] = true
        return out
    }
}
