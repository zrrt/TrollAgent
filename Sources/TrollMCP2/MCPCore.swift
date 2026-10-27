import Foundation

// MARK: - 工具定义

public struct ToolDefinition {
    public let name: String
    public let summary: String
    public let parameters: [String: String]
    /// v3.0.65：返回值说明——AI 知道工具返回什么字段
    public let returns: [String: String]
    /// v2.9.184：真机实测标记——true 表示该工具已在真机远程终端验证过 (OK或明确报错分类），
    /// 未验证的工具保持 false，避免"看起来能用"的假象。
    public let verified: Bool
    /// 工具分类 (用于 UI 分组显示）：injection / app_control / ui_control / device / filesystem / shell / browser / build / backup / cleanup / macro / knowledge / system / diagnose / analysis / automation / skills / debug / misc
    public let category: String
    /// 给 UI 看的中文描述 (为空则 fallback 到 summary）
    public let uiSummary: String
    /// v3.1.1：最低支持的 iOS 主版本 (如 16 表示 iOS 16+）。nil 表示所有版本都支持。
    public let minIOSMajor: Int?
    /// v3.1.1：最高支持的 iOS 主版本 (如 17 表示只支持到 iOS 17）。nil 表示无上限。
    public let maxIOSMajor: Int?
    /// v3.1.1：是否仅在越狱环境下可用 (true = 需要越狱）
    public let requiresJailbreak: Bool
    /// v3.1.1：是否仅在 TrollStore 环境下可用 (true = 需要 TrollStore）
    public let requiresTrollStore: Bool
    /// v3.1.26：是否仅远程终端可用 (true = 内置 AI 看不到，只在远程 API 可用）
    public let remoteOnly: Bool
    /// v3.2.0：前置条件/依赖顺序——调用本工具前必须先done的操作或必须满足的条件。
    /// 例：network.capture start 前置 "inject enable NetworkTweak"；memory search 前置 "attach 已injected MemoryTweak"。
    /// AI 规划任务时按此顺序执行，避免前置不满足就调用导致报错。
    public let prerequisites: [String]

    public init(name: String, summary: String, parameters: [String: String] = [:], returns: [String: String] = [:], verified: Bool = false, category: String = "misc", uiSummary: String = "", minIOSMajor: Int? = nil, maxIOSMajor: Int? = nil, requiresJailbreak: Bool = false, requiresTrollStore: Bool = false, remoteOnly: Bool = false, prerequisites: [String] = []) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.verified = verified
        self.category = category
        self.uiSummary = uiSummary
        self.minIOSMajor = minIOSMajor
        self.maxIOSMajor = maxIOSMajor
        self.requiresJailbreak = requiresJailbreak
        self.requiresTrollStore = requiresTrollStore
        self.remoteOnly = remoteOnly
        self.prerequisites = prerequisites
    }

    /// UI 显示用：优先 uiSummary (中文），否则 fallback 到 summary
    public var displaySummary: String {
        uiSummary.isEmpty ? summary : uiSummary
    }

    /// 展示用标记：已验证的工具前缀 ✅已检验
    public var verifiedMark: String {
        verified ? "✅ verified " : ""
    }

    /// v2.9.1：OpenAI / Responses API 要求工具名只能包含 a-zA-Z0-9_-，
    /// 而原版图中的工具名可能含中文、点、空格。转换为合法的 API 名。
    public var apiName: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var sanitized = name.components(separatedBy: allowed.inverted).joined(separator: "_")
        if sanitized.isEmpty { sanitized = "tool" }
        if sanitized.first?.isNumber ?? false { sanitized = "t_\(sanitized)" }
        return sanitized
    }
}

// MARK: - 工具协议

public protocol MCPTool {
    var definition: ToolDefinition { get }
    func invoke(_ params: [String: Any]) throws -> [String: Any]
}

public enum MCPError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidParams(String)
    case failed(String)
    /// v2.9.125：CLI 式failed分类——code + 四分类原因 + 下一步建议。
    /// description 输出为一行：tool failed: [CODE] 原因 (分类）下一步：xxx
    case classified(String, code: String, reason: String, nextStep: String)

    public var description: String {
        switch self {
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .failed(let m): return "tool failed: \(m)"
        case .classified(let m, let code, let reason, let nextStep):
            return "tool failed: [\(code)] \(m) (category: \(reason)) next: \(nextStep)"
        }
    }
}

// MARK: - CLI 式返回协议 (v2.9.125）

/// failed四分类 (对齐 Linux exit code 语义）：环境 / 目标 / 参数 / 工具自身 / 未知。
/// 放 dispatch 统一分类，工具层无需逐个改 throw 点。
enum FailureKind {
    static func classify(_ message: String) -> (code: String, reason: String, nextStep: String) {
        let m = message.lowercased()
        // 0) opainject 内存注入专项：被拒 (反调试/架构/权限）→ 明确降级路径
        if m.contains("opainject") || m.contains("dlopen") || m.contains("memory injection") {
            return ("INJECT_MEM_FAILED", "target",
                    "memory injection rejected (anti-debug/arch/permission). Try injection.enable file injection (auto backup, rollback OK), manual injection with TrollFools, or run app.decrypt for big-company Apps")
        }
        // 1) 环境：权限 / Entitlements / setuid / 容器写 / 未开权限
        if m.contains("operation not permitted") || m.contains("entitlement")
            || m.contains("setuid") || m.contains("denied") || m.contains("permission")
            || m.contains("未开启") || m.contains("未生效") {
            return ("ENV_PERMISSION", "environment",
                    "enable \"Edit Entitlements\" in TrollStore, reinstall TrollAgent, then retry")
        }
        // 2) 目标：加密 / 架构 / 兼容 / 闪退 / 无法启动 / 不可注入
        if m.contains("加密") || m.contains("cryptid") || m.contains("encrypted")
            || m.contains("架构") || m.contains("arch") || m.contains("闪退")
            || m.contains("兼容") || m.contains("无法启动") || m.contains("不可注入")
            || m.contains("没有可注入") {
            return ("TARGET_INCOMPATIBLE", "target",
                    "target App incompatible with dylib (encryption/arch/dependency); switch to a matching target, decrypt first, or check plugin compatibility")
        }
        // 3) 参数：not found / 不存在 / 参数 / bundle_id 等
        if m.contains("not found") || m.contains("不存在") || m.contains("未找到")
            || m.contains("参数") || m.contains("invalid") || m.contains("bundle") {
            return ("PARAM_INVALID", "parameter",
                    "check param name/value against the tool description (bundle_id / path / name) and retry; missing required params are listed in the error message with usage example")
        }
        // 4) 工具自身：缺组件 / 执行failed / 超时
        if m.contains("未内置") || m.contains("missing") || m.contains("超时")
            || m.contains("timeout") || m.contains("failed") || m.contains("failed") {
            return ("TOOL_FAILED", "tool",
                    "tool execution failed, inspect detail/logs or retry once")
        }
        return ("UNKNOWN", "unknown", "inspect full logs then retry")
    }

    /// 判断这个错误能不能自动重试
    static func retryable(_ message: String) -> Bool {
        let m = message.lowercased()
        // 网络错误/超时：可以重试
        if m.contains("timeout") || m.contains("超时")
            || m.contains("network") || m.contains("网络")
            || m.contains("connection") || m.contains("连接")
            || m.contains("unreachable") || m.contains("不可达") {
            return true
        }
        // 临时错误：可以重试
        if m.contains("temporary") || m.contains("临时")
            || m.contains("busy") || m.contains("忙") {
            return true
        }
        // 参数错误/权限错误/目标不兼容：不能重试
        return false
    }

    /// 兜底OK一句话 (工具未提供 message 时生成）。
    /// v2.9.125：智能提取器——按 布尔状态 → 数量 → status/summary → 首字段 顺序
    /// 从返回里提取最有信息量的一句，让全部 162 个工具都有可读结论 (而非"xx执行OK"）。
    static func defaultSuccessMessage(name: String, result: [String: Any]) -> String {
        // ① 布尔状态类 (按词义生成"动作+OK/failed"）
        let boolVerb: [String: String] = [
            "injected": "injected", "ready": "ready", "started": "started", "running": "running",
            "success": "done", "found": "found", "deleted": "deleted", "created": "created",
            "updated": "updated", "removed": "removed", "connected": "connected", "loaded": "loaded",
            "installed": "installed", "enabled": "enabled", "disabled": "disabled", "restored": "restored",
            "cleaned": "cleaned", "written": "written", "saved": "saved", "downloaded": "downloaded",
            "sent": "sent", "completed": "completed", "active": "active", "available": "available",
            "canceled": "canceled", "killed": "killed", "resumed": "resumed", "paused": "paused",
            "exists": "exists", "is_core": "resident", "valid": "valid", "compatible": "compatible"
        ]
        for (key, verb) in boolVerb {
            if let v = result[key] as? Bool {
                return "\(verb)\(v ? "OK" : "failed")"
            }
        }
        // ② 数量类 (total/count/matched 等用"条"，size/bytes 用"字节"）
        let countKeys = ["total", "count", "matched", "found",
                         "apps", "tools", "files", "records", "items"]
        for key in countKeys {
            if let n = result[key] as? Int {
                return "total \(n)"
            }
        }
        for key in ["size", "bytes"] {
            if let n = result[key] as? Int {
                return n >= 1048576 ? "\(String(format: "%.1f", Double(n) / 1048576)) MB"
                    : n >= 1024 ? "\(String(format: "%.1f", Double(n) / 1024)) KB"
                    : "\(n) bytes"
            }
        }
        // ③ 状态/结论类字段
        for key in ["status", "verdict", "summary", "result", "state", "conclusion"] {
            if let s = result[key] as? String, !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "…" : s
            }
        }
        // ④ 首个有值的简短字段 (排除大对象/长文本）
        for (k, v) in result {
            if k == "ok" || k == "message" || k == "data" || k == "error" { continue }
            if let s = v as? String, !s.isEmpty, s.count <= 40 {
                return "\(k)=\(s)"
            }
            if let n = v as? NSNumber {
                return "\(k)=\(n)"
            }
        }
        // ⑤ 终极兜底
        return "\(name) OK"
    }
}

// MARK: - 注册表

public final class ToolRegistry: ObservableObject {
    public static let shared = ToolRegistry()

    private var tools: [String: MCPTool] = [:]
    /// v3.1.8：公开工具总数
    public var toolCount: Int { tools.count }
    private var apiNameToOriginal: [String: String] = [:]
    private let lock = NSLock()
    /// v7.1.106：并发执行状态锁——recentCalls/resultCache/cacheHitCounts 三个可变字典
    /// 在真并行工具执行（isParallelSafeTool 批次 DispatchGroup 并发调用 dispatch）下会被
    /// 多线程同时读写，必须串行化。锁粒度小（只锁字典操作，不锁 t.invoke 工具本体），
    /// 保证工具真正并行执行、记账线程安全。
    private let stateLock = NSLock()
    private let disabledKey = "trollmcp2.disabled_tools"
    /// v2.9.22：会话内已授权工具 (AI 调用即自动放行，无需用户手动开 Toggle）。新会话时清空。
    private var sessionApproved: Set<String> = []
    /// v2.9.26：策略版本号。setEnabled 时递增，通过 @Published 可靠触发
    /// 工具权限策略页刷新 (修复 iOS16 List 内 Toggle 只靠 objectWillChange.send()
    /// 刷新不可靠、开关点了没反应/弹回的问题）。
    @Published private(set) var policyRevision = 0

    // v3.0.90：循环提示——记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
    // 不硬拦截，AI 有全局视角，自己决定要不要继续
    private var recentCalls: [String: [Date]] = [:]
    private let loopWindow: TimeInterval = 60.0  // 1 分钟窗口
    private let loopThreshold = 3  // 调 3 次以上就提示

    // v3.0.90：工具结果缓存——5 分钟内同样的调用直接返回缓存，省时间
    private var resultCache: [String: (result: [String: Any], time: Date)] = [:]
    // v4.3.26：缓存命中计数——同一调用连续第 2 次命中缓存时强制重取（防"同内容反复返回"，
    // 典型场景：浏览器页面已变化但 text/snapshot 因参数没变一直喂旧缓存）。
    private var cacheHitCounts: [String: Int] = [:]
    // v4.3.26：缓存绕过工具——有状态工具（浏览器页面内容随时可变）绝不能喂缓存。
    // browser.* 全部绕过：URL 变了 params 不变，旧缓存必错 (BUG-1/BUG-2 根因)。
    private var cacheBypassPrefixes: [String] = ["browser", "control", "device.fake", "injection.mem"]
    private let defaultCacheWindow: TimeInterval = 300.0  // 默认 5 分钟缓存窗口
    private let longCacheWindow: TimeInterval = 1800.0  // 30 分钟缓存窗口 (静态数据）

    /// 哪些工具应该用长缓存 (静态数据，不常变）
    private let longCacheTools: Set<String> = [
        "fs_tree", "fs.list", "fs.ls",  // 文件列表
        "device.info", "device.probe",  // 设备信息
        "injection.list", "process.list",  // 进程列表
        "artifact.list", "macro.list",  // 列表类
        "skill.list", "skill.read",  // 技能列表
    ]

    private func callKey(name: String, params: [String: Any]) -> String {
        let sortedParams = params.sorted { $0.key < $1.key }
        let paramStr = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(name):\(paramStr)"
    }

    /// 根据工具名决定缓存窗口
    private func cacheWindow(for toolName: String) -> TimeInterval {
        if longCacheTools.contains(toolName) {
            return longCacheWindow
        }
        return defaultCacheWindow
    }

    private func recordCall(name: String, params: [String: Any]) -> Int {
        let key = callKey(name: name, params: params)
        let now = Date()
        // v7.1.106：加锁——并发工具执行时 recentCalls 被多线程写，字典无锁会数据竞争
        stateLock.lock()
        // 清理过期记录
        recentCalls[key] = (recentCalls[key] ?? []).filter { now.timeIntervalSince($0) < loopWindow }
        recentCalls[key]?.append(now)
        if recentCalls[key] == nil { recentCalls[key] = [now] }
        let count = recentCalls[key]?.count ?? 1
        stateLock.unlock()
        return count
    }

    /// v3.0.90：查缓存——5 分钟内同样的调用直接返回缓存结果
    private func getCachedResult(name: String, params: [String: Any]) -> [String: Any]? {
        let key = callKey(name: name, params: params)
        // v7.1.106：加锁——并发下 resultCache 读写互斥
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let cached = resultCache[key] else { return nil }
        // 过期了
        let window = cacheWindow(for: name)
        if Date().timeIntervalSince(cached.time) > window {
            resultCache.removeValue(forKey: key)
            return nil
        }
        return cached.result
    }

    /// v3.0.90：存缓存
    private func cacheResult(name: String, params: [String: Any], result: [String: Any]) {
        let key = callKey(name: name, params: params)
        // v7.1.106：加锁——并发下 resultCache 写互斥
        stateLock.lock()
        resultCache[key] = (result, Date())
        // 清理过期缓存
        let now = Date()
        for (k, v) in resultCache {
            let window = cacheWindow(for: k.components(separatedBy: ":").first ?? "")
            if now.timeIntervalSince(v.time) > window {
                resultCache.removeValue(forKey: k)
            }
        }
        stateLock.unlock()
    }

    /// v7.1.106：并发下 cacheHitCounts/resultCache 的原子小操作（各自持锁，不嵌套调用）
    private func bumpHitCount(_ key: String) -> Int {
        stateLock.lock()
        let hits = (cacheHitCounts[key] ?? 0) + 1
        cacheHitCounts[key] = hits
        stateLock.unlock()
        return hits
    }
    private func readHitCount(_ key: String) -> Int {
        stateLock.lock()
        let hits = cacheHitCounts[key] ?? 0
        stateLock.unlock()
        return hits
    }
    private func resetHitAndCache(_ key: String) {
        stateLock.lock()
        resultCache.removeValue(forKey: key)
        cacheHitCounts[key] = 0
        stateLock.unlock()
    }
    private func resetHit(_ key: String) {
        stateLock.lock()
        cacheHitCounts[key] = 0
        stateLock.unlock()
    }

    public func register(_ tool: MCPTool) {
        lock.lock()
        tools[tool.definition.name] = tool
        lock.unlock()
    }

    /// v7.1.75：按前缀移除工具（MCP 客户端注销服务器时用）。
    /// 同时清掉 apiNameToOriginal 里指向这些工具名的映射，避免 openAISchema 撞残留。
    public func removeTools(prefix: String) {
        lock.lock()
        let matched = tools.keys.filter { $0.hasPrefix(prefix) }
        for name in matched {
            tools.removeValue(forKey: name)
        }
        apiNameToOriginal = apiNameToOriginal.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }

    /// v3.0.71：外部 dylib 注册工具 (AI 自我进化——AI 写 dylib 注入自己，注册新工具）
    public func registerExternalTool(_ def: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        // v3.0.90：安全检查——AI 自写工具的规则
        let name = def.name.lowercased()

        // 1. 不能覆盖内置工具
        if !name.hasPrefix("custom.") && !name.hasPrefix("user.") {
            print("[TA] ❌ external tool rejected: name must start with 'custom.' or 'user.' (got \(def.name))")
            return
        }

        // 2. 不能包含危险关键词
        let dangerousKeywords = ["shell", "exec", "root", "inject", "download", "upload", "delete", "rm", "sudo", "privileged"]
        for kw in dangerousKeywords {
            if name.contains(kw) {
                print("[TA] ❌ external tool rejected: name contains dangerous keyword '\(kw)'")
                return
            }
        }

        // 3. 不能和现有工具冲突
        if tools[def.name] != nil {
            print("[TA] ❌ external tool rejected: name already exists \(def.name)")
            return
        }

        // 通过检查，注册
        let wrapper = ExternalMCPTool(definition: def, handler: handler)
        register(wrapper)
        print("[TA] ✅ external tool registered: \(def.name)")
    }

    public var definitions: [ToolDefinition] {
        // v3.0.90：去掉锁——只读操作
        return tools.values.map { $0.definition }.sorted { $0.name < $1.name }
    }

    // v2.9.71：本地 HTTP 服务需要的工具查询接口
    public func allToolNames() -> [String] {
        // v3.0.90：去掉锁——只读操作
        return tools.keys.sorted()
    }

    public func tool(named name: String) -> MCPTool? {
        // v3.0.90：去掉锁——只读操作
        return tools[name]
    }

    /// v2.9.15：聊天默认工具白名单。
    /// v3.1.66：工具已精简为 22 个大工具，全部默认启用 (shell.exec / app / inject / control 等），
    /// 新装用户开箱即用；用户手动开/关过的仍以显式状态为准。
    private static let defaultEnabledTools: Set<String> = [
        // v3.1.66：全量注册工具默认启用
        "artifact", "device", "memory", "assistant_memory", "verify", "container",
        "ssh", "diagnose", "knowledge", "location", "macro", "app", "control",
        "inject", "automation", "network.capture", "server", "project", "browser",
        "shell.exec", "shell.stop", "reminder", "rescue",
        // v7.2.0：系统侧 Mach-O 执行（jroot 越狱工具）——默认启用，AI 可直接调
        "system.exec_root",
        // v4.3.65：统一工具安装闭环
        "tool.install", "env.setup_re",
        // v4.3.65：补齐"已注册但漏在白名单外"的分析工具——否则 AI 看不到 db/file/package，
        // 无法用原生 sqlite3 直读 App 数据容器、无法解包分析；vpn.capture 随 VPN 抓包恢复一并默认启用；
        // skills.* 让技能系统真正按需加载生效
        "file", "db", "package", "vpn.capture",
        "skills.list", "skills.read", "skills.set_enabled",
        // v4.3.65：恢复注册的联网检索工具（多引擎回退 + 多 query 并行 + 正文抽取）
        "web.search", "web.fetch",
        // v4.3.66：按需绑定 App 数据容器（bind_app 只读安全，bind_app_write 可写先备份，
        // app_write_file 原生直写先备份）——否则"小白一句话分析/改 App 数据"时 AI 看不到这些工具
        "bind_app", "bind_app_write", "app_write_file",
        // v4.3.66：GitHub CI 工具（tool.install 触发 CI 后的查进度/取产物闭环）
        "github",
        // v4.5.x：大文件下载（URLSession + 进度条）
        "download"
    ]

    /// v2.9.31：常驻核心工具名集合 (UI 用只读访问）
    public static var coreToolNames: Set<String> { Self._coreToolNames }

    /// v2.9.31：判断工具是否常驻核心 (初始请求自动加载，无需搜索）
    /// v3.0.73：根据当前系统指令模式智能叠加常驻工具
    public func isCore(_ name: String) -> Bool {
        if Self.coreToolNames.contains(name) { return true }
        // 叠加当前模式的额外常驻工具
        let extra = SystemPrompts.shared.currentExtraCoreTools
        return extra.contains(name)
    }

    /// v2.9.31：常驻核心工具 (历史渐进披露设计，tool_search 已删，现仅作 UI 参考）。
    private static let _coreToolNames: Set<String> = [
        // 最常用：终端 (代替了 artifact）
        "shell.exec",
        // 最常用：截图
        "control.screenshot"
    ]

    public func isEnabled(name: String) -> Bool {
        // v2.9.24：改用显式状态字典。用户手动开/关过的工具以显式值为准；
        // 未设置过的工具按白名单决定默认启用。修复"非白名单工具手动开启无效"bug。
        let states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        if let v = states[name] { return v }
        return Self.defaultEnabledTools.contains(name)
    }

    /// v2.9.22：授权某工具在本会话内可调用 (绕过策略禁用）。
    /// v2.9.31：AI 调用即自动授权，无弹窗。
    public func approveForSession(_ name: String) {
        lock.lock()
        sessionApproved.insert(name)
        lock.unlock()
    }

    /// v2.9.175：本会话已授权工具名 (原名，仅返回已注册的），
    /// 供跨消息持久注入——AI 每轮新消息都能看到调用过的工具 schema，
    /// 根治"调用过 app.decrypt 但下一轮够不到"。
    public func approvedToolNames() -> [String] {
        // v3.0.90：去掉锁——只读操作
        return Array(sessionApproved).filter { tools[$0] != nil }
    }

    /// v2.9.22：清空会话授权 (新会话时调用）。
    public func clearSessionApproval() {
        lock.lock()
        sessionApproved.removeAll()
        lock.unlock()
    }

    public func isSessionApproved(_ name: String) -> Bool {
        // v3.0.90：去掉锁——只读操作
        return sessionApproved.contains(name)
    }

    public func setEnabled(name: String, enabled: Bool) {
        // v2.9.24：直接写显式状态 (true=启用，false=禁用），而非删除 key。
        // 修复"非白名单工具手动开启后开关弹回"bug (旧实现 removeValue 后回落白名单）。
        var states = UserDefaults.standard.object(forKey: disabledKey) as? [String: Bool] ?? [:]
        states[name] = enabled
        UserDefaults.standard.set(states, forKey: disabledKey)
        // v2.9.26：@Published 递增 + objectWillChange 双保险，确保 UI 立即刷新
        policyRevision += 1
        objectWillChange.send()
        AuditLog.shared.log("policy", detail: "\(name) \(enabled ? "enabled" : "disabled")")
    }

    public var enabledDefinitions: [ToolDefinition] {
        // v3.1.26: 过滤掉 remoteOnly 工具——内置 AI 看不到，只在远程 API 可用
        definitions.filter { isEnabled(name: $0.name) && !$0.remoteOnly }
    }

    /// v2.9.1：生成给 OpenAI API 用的工具 schema，同时建立 apiName → 原名映射，
    /// 供 dispatch 把模型返回的安全名转回真实工具名。
    /// v3.1.66：全量加载所有已启用工具 (tool_search 已删除，不再按 isCore 渐进披露）。
    /// 工具已精简为约 23 个大工具，全量 schema token 占用可控，AI 一次即可看到全部工具。
    public func enabledOpenAIToolSchema() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let defs = tools.values.map { $0.definition }.filter { isEnabled(name: $0.name) }
        var used = Set<String>()
        var map = [String: String]()
        var result: [[String: Any]] = []
        for def in defs {
            var safe = def.apiName
            var suffix = 1
            while used.contains(safe) {
                safe = "\(def.apiName)_\(suffix)"
                suffix += 1
            }
            used.insert(safe)
            map[safe] = def.name

            var props: [String: [String: String]] = [:]
            for (k, v) in def.parameters {
                props[k] = ["type": "string", "description": v]
            }
            // v7.2.3-fix19：全工具统一注入 tool_title（对齐 OpenMinis）——模型每次调用
            // 输出 5-10 字行为摘要，工具卡主标题用它（AI 传，不带工具名）。
            // 不加 required：多供应商（deepseek 等）不遵守必填会触发参数校验纠正循环。
            props["tool_title"] = ["type": "string",
                "description": "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Test network connectivity', 'List files in home directory'). Use the same language as the user. MUST always output this field."]
            // v3.1.66：required 只保留子命令选择器 (command/action），其余参数按子命令按需提供。
            // v3.1.69：显式找 command/action 键——Dictionary.keys 是哈希顺序，prefix(1) 可能
            // 落到任意参数 (如 artifact 的 name），导致 AI 被迫填无关参数 (AI 反馈实锤）。
            let selectorKey = def.parameters.keys.first { $0 == "command" || $0 == "action" }
            // v3.2.0：description 追加前置条件——AI 看到工具定义即知依赖顺序，不用撞错误才知道
            var desc = def.summary
            if !def.prerequisites.isEmpty {
                desc += " Prerequisites: " + def.prerequisites.joined(separator: "; ") + ". Run the prerequisite steps first, then call this tool — don't call it directly."
            }
            result.append([
                "type": "function",
                "function": [
                    "name": safe,
                    "description": desc,
                    "parameters": [
                        "type": "object",
                        "properties": props,
                        "required": selectorKey.map { [$0] } ?? []
                    ]
                ]
            ])
        }
        apiNameToOriginal = map
        return result
    }

    /// v3.1.3：向量语义搜索缓存——工具描述的词袋向量 (简化版，不需要 embedding 模型）
    private var toolVectors: [String: [String: Double]] = [:]
    private var toolVectorsLoaded = false

    /// v3.1.3：预计算所有工具的词袋向量 (简化版语义搜索）
    private func loadToolVectors() {
        guard !toolVectorsLoaded else { return }
        toolVectorsLoaded = true
        for (_, tool) in tools {
            let text = (tool.definition.name + " " + tool.definition.summary).lowercased()
            var vector: [String: Double] = [:]
            // 简单分词：按空格和标点分词
            let words = text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in words {
                vector[word, default: 0] += 1
            }
            toolVectors[tool.definition.name] = vector
        }
    }

    /// v3.1.3：计算两个词袋向量的余弦相似度
    private func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dotProduct: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for (key, valA) in a {
            normA += valA * valA
            if let valB = b[key] {
                dotProduct += valA * valB
            }
        }
        for valB in b.values {
            normB += valB * valB
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dotProduct / (normA.squareRoot() * normB.squareRoot())
    }

    /// 按关键词搜索工具名/摘要，返回紧凑清单 (供 UI 搜索，历史 API 保留）
    /// v3.0.90：去重——已会话授权的工具不再重复返回，避免 AI 反复搜以为能找到新工具
    public func searchTools(query: String, limit: Int = 0) -> [[String: String]] {
        // v3.0.90：去掉锁——只读操作，不需要锁，避免死锁
        // v3.1.1：iOS 版本过滤——不支持当前 iOS 版本的工具不返回
        let iosMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let jbStatus = InjectionManager.shared.jailbreakStatus()
        let isJailbroken = jbStatus["is_jailbroken"] as? Bool ?? false

        // v3.0.99: 同义词映射——用户说中文，工具描述是英文，做个映射
        let synonyms: [String: [String]] = [
            "截图": ["screenshot", "screen"],
            "抓包": ["network.capture", "network", "packet", "proxy", "http"],
            "网络抓包": ["network.capture", "network", "packet", "proxy"],
            "网络分析": ["network.capture", "network", "http", "request"],
            "请求": ["network.capture", "http", "request", "api"],
            "请求清单": ["network.capture", "network", "http"],
            "截屏": ["screenshot", "screen"],
            "屏幕": ["screenshot", "screen", "ui"],
            "网页": ["browser", "web", "url"],
            "浏览器": ["browser", "web"],
            "网页内容": ["browser.text", "browser.snapshot"],
            "文本": ["text", "content"],
            "识别": ["ocr", "recognize", "extract"],
            "文字": ["ocr", "text"],
            "注入": ["inject", "injection", "jailbreak"],
            "越狱": ["jailbreak", "ellekit", "injection.enable"],
            "越狱注入": ["injection.enable", "jailbreak"],
            "安装": ["install", "ipa"],
            "卸载": ["uninstall"],
            "启动": ["launch", "app.launch"],
            "重启": ["restart", "app.restart"],
            "进程": ["process", "ps"],
            "文件": ["fs", "file"],
            "读": ["read", "artifact"],
            "写": ["write", "artifact"],
            "目录": ["tree", "ls", "shell.exec"],
            "终端": ["shell", "exec"],
            "命令": ["shell", "exec", "command"],
            "点击": ["tap", "click"],
            "点": ["tap", "click"],
            "输入": ["type", "input"],
            "滑动": ["swipe", "scroll"],
            "滚动": ["swipe", "scroll"],
            "设备": ["device", "info"],
            "系统": ["device", "system"],
            "编译": ["build", "compile", "build.runner"],
            "构建": ["build", "compile"],
            "自写工具": ["tool.load_dylib", "self-evolution", "load_dylib"],
            "自我进化": ["tool.load_dylib", "self-evolution"],
            "加载新工具": ["tool.load_dylib", "load_dylib"],
            "写个工具": ["tool.load_dylib", "write_tool", "build"],
        ]

        let q = query.lowercased()
        var hits: [(name: String, summary: String, score: Double)] = []
        loadToolVectors()  // v3.1.3：预计算工具向量 (词袋版）

        // v3.1.3：计算查询的词袋向量
        var queryVector: [String: Double] = [:]
        if !q.isEmpty {
            let queryWords = q.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for word in queryWords {
                queryVector[word, default: 0] += 1
            }
        }

        for (_, tool) in tools {
            let def = tool.definition
            // v3.1.9: 不跳过任何工具——全部返回，AI 一次看完全部
            // 只按 iOS 版本和越狱环境过滤

            // v3.1.1：iOS 版本过滤
            if let minV = def.minIOSMajor, iosMajor < minV { continue }
            if let maxV = def.maxIOSMajor, iosMajor > maxV { continue }

            // v3.1.1：越狱环境过滤
            if def.requiresJailbreak && !isJailbroken { continue }

            let nameL = def.name.lowercased()
            let sumL = def.summary.lowercased()
            var score: Double = 0
            if !q.isEmpty {
                // v3.1.0: 类别前缀匹配——搜 "browser" 就返回所有 browser.* 工具
                if nameL.hasPrefix(q + ".") || nameL.hasPrefix(q + "_") {
                    score += 10  // 类别匹配权重最高
                }
                if nameL.contains(q) { score += 3 }
                if sumL.contains(q) { score += 2 }
                // 简单分词：每个词命中加分
                let queryWords = q.split(separator: " ").map({ String($0) }).filter { !$0.isEmpty }
                for w in queryWords {
                    if nameL.contains(w) { score += 1 }
                    if sumL.contains(w) { score += 1 }
                }
                // v3.0.99: 同义词匹配
                for (cn, enList) in synonyms {
                    if query.contains(cn) {
                        for en in enList {
                            if nameL.contains(en.lowercased()) { score += 2 }
                            if sumL.contains(en.lowercased()) { score += 1 }
                        }
                    }
                }
                // v3.1.3: 类别速查表——常见任务 → 对应的工具类别
                let categoryMap: [String: [String]] = [
                    "截图": ["ui.screenshot", "control.screenshot", "ui"],
                    "抓包": ["network.capture", "debug.dump_network_log"],
                    "注入": ["injection", "injection.enable", "control.inject"],
                    "文件": ["fs.", "bridge.", "artifact."],
                    "浏览器": ["browser."],
                    "自动化": ["automation.", "macro.", "task.run"],
                    "清理": ["cleanup.", "workspace.cleanup", "rescue."],
                    "编译": ["build.", "github."],
                    "崩溃": ["crash", "diagnose.", "log.collect"],
                    "设备": ["device.", "system.overview"],
                    "聊天": ["knowledge.", "assistant.memory"],
                    "微信": ["wechat."],
                    "定位": ["location."],
                    "备份": ["backup."],
                ]
                for (task, cats) in categoryMap {
                    if query.contains(task) {
                        for cat in cats {
                            if nameL.hasPrefix(cat) || nameL.contains(cat) {
                                score += 3
                            }
                        }
                    }
                }
                // v3.1.3: 词袋余弦相似度 (简化版，没下载模型时用）
                if let toolVec = toolVectors[def.name], !queryVector.isEmpty {
                    let sim = cosineSimilarity(queryVector, toolVec)
                    score += sim * 5  // 向量相似度权重
                }
            } else {
                score = 1
            }
            if score > 0 { hits.append((def.name, def.summary, score)) }
        }
        hits.sort { $0.score > $1.score }
        // v3.1.9: 返回全部可调用工具——AI 一次看完全部，不用反复搜
        // 只按 iOS 版本和越狱环境过滤，不过滤已授权的
        // limit=0 表示返回全部可调用工具
        if limit <= 0 {
            return hits.map { ["name": $0.0, "summary": $0.1] }
        }
        return hits.prefix(limit).map { ["name": $0.0, "summary": $0.1] }
    }

    /// 返回单个工具的完整 OpenAI function schema (供模型按名动态注入）
    public func openAISchema(for name: String) -> [String: Any]? {
        // v3.0.90：去掉锁——只读操作
        guard let tool = tools[name] else { return nil }
        let def = tool.definition
        var props: [String: [String: String]] = [:]
        for (k, v) in def.parameters {
            props[k] = ["type": "string", "description": v]
        }
        // v3.1.69：显式找 command/action 键 (见 enabledOpenAIToolSchema 注释——哈希顺序问题）
        let selectorKey = def.parameters.keys.first { $0 == "command" || $0 == "action" }
        // v7.2.3-fix19.1：tool_title 统一注入——Anthropic 通道/动态披露的 schema
        // 也走这里（OpenAI 全量在 enabledOpenAIToolSchema 注入，两套构造必须一致，
        // 否则同一请求里部分工具带 tool_title、部分不带 → 模型行为不一致）
        props["tool_title"] = ["type": "string",
            "description": "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Test network connectivity', 'List files in home directory'). Use the same language as the user. MUST always output this field."]
        return [
            "type": "function",
            "function": [
                "name": def.apiName,
                "description": def.summary,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": selectorKey.map { [$0] } ?? []
                ]
            ]
        ]
    }

    @discardableResult
    public func dispatch(name: String, params: [String: Any]) throws -> [String: Any] {
        // v6.1.5-14ai：幽灵工具别名——描述/提示词里出现的 dotted 名映射到真实实现。
        // 50 处工具 description 用 control.tap / injection.mem / reminder.create 等写法，
        // 但注册的是大工具+子命令；不加映射 AI 按描述调用必报 unknown tool → 反复试错。
        // 别名走同一 dispatch：把 params 并入 command 后递归分发（无环：映射目标均为注册名）。
        if let (realName, realCommand) = Self.ghostAlias(name) {
            var p = params
            if !realCommand.isEmpty { p["command"] = realCommand }
            return try dispatch(name: realName, params: p)
        }
        // v3.0.90：去掉锁——只读操作 (查工具）
        var tool = tools[name]
        if tool == nil, let original = apiNameToOriginal[name] {
            tool = tools[original]
        }
        // v2.9.28：兜底解析——按 apiName (下划线安全名）反向匹配所有注册工具。
        // 修复：未启用/敏感工具不在 enabledOpenAIToolSchema 的 apiNameToOriginal 映射里，
        // 模型按 schema 返回 injection_enable 时 dispatch 找不到 → unknown tool。
        if tool == nil {
            tool = tools.values.first { $0.definition.apiName == name }
        }
        // v3.0.90：去掉 lock.unlock()，因为已经去掉了 lock.lock()
        guard let t = tool else { throw MCPError.unknownTool(name) }
        // v2.9.31：去掉授权弹窗。放行 = 策略启用 (isEnabled）或会话已授权。
        // 未加载/未启用工具直接返回错误，提示 AI 换用已加载工具，而不是弹窗打扰用户。
        let originalName = t.definition.name
        // v2.9.34：放行 = 策略启用 或 会话已授权 或 常驻核心工具。
        // 修复 bug：coreToolNames 里的工具 (如 artifact.find）schema 已发给模型，
        // 但 defaultEnabledTools 未收录时 isEnabled 返回 false → 报"未加载"。
        // 常驻核心必然放行 (它本来就在初始请求里，用户开关不应对它二次拦截）。
        if isEnabled(name: originalName) || isSessionApproved(originalName) || isCore(originalName) {
            // v2.9.36：统一审计 (老 MCP 样式：OK/failed · 权限 · 耗时 · 数据量）
            let start = CFAbsoluteTimeGetCurrent()
            let perm = Self.permissionLabel(originalName)
            do {
                // v3.0.90：记录调用次数，告诉 AI 它调了几次，让 AI 自己判断
                let callCount = recordCall(name: originalName, params: params)
                // v2.9.72：工作流可视化
                WorkflowManager.shared.addStep(name: originalName, tool: originalName)

                // v3.0.90：结果缓存——5 分钟内同样的调用直接返回缓存
                // v4.3.26：有状态工具 (browser./control./device.fake/injection.mem）绕过缓存；
                // 其余工具连续第 2 次命中缓存也强制重取 (命中计数归零后真实执行)。
                let cacheKey = callKey(name: originalName, params: params)
                let bypassCache = cacheBypassPrefixes.contains { originalName.hasPrefix($0) }
                var cached: [String: Any]? = nil
                if !bypassCache {
                    cached = getCachedResult(name: originalName, params: params)
                    if cached != nil {
                        let hits = bumpHitCount(cacheKey)
                        if hits >= 2 {
                            // 连续第 2 次命中 → 强制重取：删缓存、清计数、真实执行
                            resetHitAndCache(cacheKey)
                            cached = nil
                        }
                    }
                }
                if let cached = cached {
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "cached", success: true)
                    var cachedData = Self.compactResult(cached)
                    cachedData.removeValue(forKey: "message")
                    cachedData["_call_count"] = callCount
                    cachedData["_cached"] = true
                    cachedData["_cache_hits"] = readHitCount(cacheKey)
                    return ["ok": true, "data": cachedData]
                }
                resetHit(cacheKey)   // 真实执行前清零命中计数

                // v3.0.90：工具执行超时保护——15 秒没返回就报错，防止一直卡着
                var timedOut = false
                let timeoutWorkItem = DispatchWorkItem {
                    timedOut = true
                    WorkflowManager.shared.updateStep(tool: originalName, detail: "⏱ timeout (15s)", success: false)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)

                // v3.1.5: 自动重试——网络错误/超时自动重试一次
                var result: [String: Any]
                do {
                    result = try t.invoke(params)
                } catch {
                    // 异常抛出的错误：判断能不能重试
                    let errStr = "\(error)"
                    if FailureKind.retryable(errStr) && callCount == 1 {
                        // 自动重试一次
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 auto-retrying...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        result = try t.invoke(params)
                    } else {
                        throw error
                    }
                }
                timeoutWorkItem.cancel()
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                // v4.3.25: 超时看门狗落地——timedOut 标记此前只写不读（死代码），
                // 长工具（ai_analyze 砸壳/LLM 等待可达分钟级）跑超 15s 后 AI 收不到任何
                // "慢"信号，把慢调用误判为"空结果/无输出"，导致不继续下一步。
                // 现在：超时标记进结果让 AI 可感知；慢结果不写缓存（避免把慢当常态复读）。
                if timedOut {
                    result["_slow"] = true
                    result["_slow_note"] = "this tool took >15s (\(elapsedMs)ms total). Long analysis tools (decrypt/probe/LLM) may take minutes — treat the eventual result as valid output, do not assume it is empty."
                }
                // v2.9.134：返回式错误统一识别——工具 return ["error":...] / ["ok": false] /
                // ["status": "failed"] 不再伪装OK (旧版 ok 恒为 true，AI 无法分辨成败，
                // 即"死结果"根因）。统一走 code/reason/nextStep failed路径。
                if let errMsg = Self.extractReturnedError(result) {
                    let info = FailureKind.classify(errMsg)
                    // v3.1.5: 返回式错误也自动重试一次
                    if FailureKind.retryable(errMsg) && callCount == 1 {
                        WorkflowManager.shared.updateStep(tool: originalName, detail: "🔄 auto-retrying...", success: false)
                        Thread.sleep(forTimeInterval: 1.0)  // 等 1 秒再重试
                        do {
                            result = try t.invoke(params)
                        } catch {
                            // 重试还是failed，继续走failed路径
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                            if callCount >= loopThreshold {
                                throw MCPError.failed("🚫 LOOP BLOCKED: You've called this tool \(callCount) times with same params and it keeps failing with the same error. STOP. Do NOT call it again. Try a completely different approach, or ask the user what to do. Error: \(errMsg)")
                            }
                            throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        }
                        // 重试OK了，继续走OK路径 (如果还有返回式错误，继续往下走会再检查一次）
                        if Self.extractReturnedError(result) != nil {
                            // 重试还是返回式错误，继续走failed路径
                            let newErrMsg = Self.extractReturnedError(result)!
                            let newInfo = FailureKind.classify(newErrMsg)
                            AuditLog.shared.logTool(originalName, status: .failure,
                                                    elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                    detail: newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                            WorkflowManager.shared.updateStep(tool: originalName, detail: newErrMsg, success: false)
                            throw MCPError.classified(newErrMsg, code: newInfo.code, reason: newInfo.reason, nextStep: newInfo.nextStep)
                        }
                        // 重试OK，继续往下走
                    } else {
                        AuditLog.shared.logTool(originalName, status: .failure,
                                                elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                                detail: errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                        WorkflowManager.shared.updateStep(tool: originalName, detail: errMsg, success: false)
                        // v3.1.1: 连续failed 3 次就拦截，不让 AI 继续循环
                        if callCount >= loopThreshold {
                            throw MCPError.failed("🚫 LOOP BLOCKED: You've called this tool \(callCount) times with same params and it keeps failing with the same error. STOP. Do NOT call it again. Try a completely different approach, or ask the user what to do. Error: \(errMsg)")
                        }
                        throw MCPError.classified(errMsg, code: info.code, reason: info.reason, nextStep: info.nextStep)
                    }
                }
                let bytes = Self.resultBytes(result)
                AuditLog.shared.logTool(originalName, status: .success,
                                        elapsedMs: elapsedMs, dataBytes: bytes, permission: perm)
                WorkflowManager.shared.updateStep(tool: originalName, detail: "\(elapsedMs)ms", success: true)

                // v3.0.90：存结果缓存 (OK才存，failed不缓存）
                // v4.3.25: 慢结果 (超看门狗）也不缓存——避免"慢"成为被复读的常态结果
                if !timedOut {
                    cacheResult(name: originalName, params: params, result: result)
                }

                // v2.9.125：CLI 式统一返回——顶层只留 ok/message，细节收进 data。
                // AI 读 message 一眼判成败；需要排障才展开 data。
                // v2.9.137：结果摘要化——data 内大数组 (>20）/大字符串 (>4000）
                // 递归压缩，复合工具诊断结论前置、细节按需取，防大结果占满上下文。
                // v3.1.33：截断可配置——AI 可在参数里传 limit (覆盖字符串上限，默认4000）
                // 或 full=true (不截断，返回完整结果），解决"结果被修剪看不到主体"的痛点。
                var data: [String: Any]
                if let fullFlag = params["full"] as? Bool, fullFlag {
                    data = Self.slim(result)
                } else if let lim = params["limit"] as? Int, lim > 0 {
                    // v7.2.3-fix25b：limit 同时放宽数组上限——此前 limit 只作用于字符串
                    // 字段(strLimit)，arrLimit 固定 20：输出 1000 行数组时直接砍到 20 项 +
                    // truncated:true，传 limit=50000 也无效（用户实测根因）。
                    // 数组元素多时每项仍走 compactResult 单条压缩，总量受 strLimit 约束。
                    data = Self.compactResult(result, arrLimit: min(lim, 1_000),
                                              strLimit: min(lim, 100_000), keepHeadTail: true)
                } else {
                    data = Self.compactResult(result)
                }
                data.removeValue(forKey: "message")
                // v3.0.90：告诉 AI 它调了几次，让 AI 自己判断是不是在循环
                data["_call_count"] = callCount
                if callCount >= loopThreshold {
                    data["_loop_hint"] = "⚠️ You've called this tool \(callCount) times with the same params in the last \(Int(loopWindow))s. If the result is the same, you're probably looping. Try a different approach or ask the user."
                }
                // v2.9.167：_noMessage 标记——数据自解释的工具返回里明确不需要顶层
                // message (total/tools 已自解释），省 ~10 token/次
                if result["_noMessage"] as? Bool == true {
                    data.removeValue(forKey: "_noMessage")
                    return ["ok": true, "data": data]
                }
                let msg = (result["message"] as? String)
                    ?? FailureKind.defaultSuccessMessage(name: originalName, result: result)
                // v2.9.168：全局紧凑规则——data 序列化后 >600 字节 (有实质内容自解释）
                // 时自动去掉顶层 message 省 token (201 个工具大结果统一生效）；
                // 小结果保留 message ("decrypt done: xxx"这类结论句帮 AI 秒判，不丢判断力）。
                if Self.resultBytes(data) > 600 {
                    return ["ok": true, "data": data]
                }
                return ["ok": true, "message": msg, "data": data]
            } catch {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let errDesc = (error as? MCPError)?.description ?? error.localizedDescription
                // v2.9.128：failed记录 CLI 四分类 code/reason/nextStep (供健康度聚合 + AI 自查）
                let classified: MCPError
                if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = error {
                    classified = MCPError.classified(errDesc, code: c, reason: r, nextStep: n)
                } else {
                    let info = FailureKind.classify(errDesc)
                    classified = MCPError.classified(errDesc, code: info.code, reason: info.reason, nextStep: info.nextStep)
                }
                let (cCode, cReason, cNext) = Self.unpack(classified)
                AuditLog.shared.logTool(originalName, status: .failure,
                                        elapsedMs: elapsedMs, dataBytes: 0, permission: perm,
                                        detail: errDesc, code: cCode, reason: cReason, nextStep: cNext)
                WorkflowManager.shared.updateStep(tool: originalName, detail: errDesc, success: false)
                throw classified
            }
        }
        // v3.1.9: 工具未授权 → 自动授权 + 返回"已加载，请重新调用"
        // AI 直接调用即自动加载，无需先搜索
        approveForSession(originalName)
        throw MCPError.failed("tool \(originalName) loaded, schema injected next round, call again")
    }

    // v2.9.128：解包 classified 的 code/reason/nextStep (审计记录用）
    private static func unpack(_ err: MCPError) -> (String, String, String) {
        if case MCPError.classified(_, code: let c, reason: let r, nextStep: let n) = err {
            return (c, r, n)
        }
        let info = FailureKind.classify(err.description)
        return (info.code, info.reason, info.nextStep)
    }

    /// v2.9.134：提取"返回式错误" (工具不 throw 而是 return ["error":...]/["ok":false]/
    /// ["status":"failed"]）。返回 nil 表示该结果应视为OK。
    /// v2.9.137：结果摘要化 (递归）——大数组保持数组但截断并末尾加省略标记，
    /// 大字符串截断并附总长度。返回后 AI 仍能读结论字段，细节可带 limit 重取。
    /// `content` 字段 (artifact.read_text 的文件内容）保留完整——
    /// 它们已由 max_bytes 参数控制读取量，不能再截断。
    /// v2.9.168：通用字段瘦身 (全部工具生效）——
    /// hint 截 60、summary 截 30、删空字符串值。结构信息不删，只去冗余。
    static func slim(_ d: [String: Any]) -> [String: Any] {
        var nd = d
        if let h = nd["hint"] as? String, h.count > 60 { nd["hint"] = String(h.prefix(60)) + "…" }
        if let sm = nd["summary"] as? String, sm.count > 30 { nd["summary"] = String(sm.prefix(30)) + "…" }
        for (k, v) in nd where (v as? String)?.isEmpty == true {
            nd.removeValue(forKey: k)
        }
        return nd
    }

    /// v2.9.164：大字符串落盘到工作区 tool_spill/ (完整内容保留，AI 按路径再读）
    static func spillLarge(_ key: String, _ content: String) -> String {
        let dir = Workspace.root.appendingPathComponent("tool_spill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "spill_\(Int(Date().timeIntervalSince1970))_\(key.replacingOccurrences(of: "/", with: "_")).txt"
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func compactResult(_ root: [String: Any], arrLimit: Int = 20, strLimit: Int = 4000, keepHeadTail: Bool = true) -> [String: Any] {
        var out: [String: Any] = [:]
        var truncatedAny = false
        for (k, v) in root {
            switch v {
            case let s as String:
                // v2.9.164：先压多余空行 (\n{3,}→\n\n）与行尾空格——日志/hexdump 的空行
                // 在模型侧也是 token，压缩后单次可省数百 token，且不破坏内容结构。
                var t = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                t = t.split(separator: "\n", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.joined(separator: "\n")
                if k == "content" || t.count <= strLimit {
                    out[k] = t
                } else {
                    // v3.1.33：截断策略——保留头+尾 (默认），不只留开头 (AI 诊断 P3：
                    // "只留开头最没用"）。完整内容仍落盘 tool_spill/，AI 可 cat 全量。
                    // v3.1.68：统一 truncated 标记——AI 读顶层即知结果被截断 (E items）
                    truncatedAny = true
                    let spillPath = Self.spillLarge(k, t)
                    if keepHeadTail, strLimit >= 200 {
                        let half = strLimit / 2
                        let head = String(t.prefix(half))
                        let tail = String(t.suffix(half))
                        out[k] = head + "\n…[中间省略 共\(t.count - strLimit + 40)字符，完整内容: \(spillPath)]…\n" + tail
                    } else {
                        out[k] = String(t.prefix(strLimit)) + "\n…[截断 共\(t.count)字符，完整内容: \(spillPath)]"
                    }
                }
            case let arr as [[String: Any]]:
                if arr.count > arrLimit {
                    truncatedAny = true
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append(["note": "...[total \(arr.count) items, truncated, showing first \(arrLimit) items]"])
                    out[k] = cut
                } else {
                    out[k] = arr.map { slim(compactResult($0)) }
                }
            case let arr as [Any]:
                if arr.count > arrLimit {
                    truncatedAny = true
                    var cut = Array(arr.prefix(arrLimit))
                    cut.append("…[共\(arr.count) items, truncated, showing first \(arrLimit) items]")
                    out[k] = cut
                } else {
                    out[k] = arr.map { ($0 as? [String: Any]).map { Self.slim(Self.compactResult($0)) } ?? $0 }
                }
            case let d as [String: Any]:
                out[k] = slim(compactResult(d))
            default:
                out[k] = v
            }
        }
        if truncatedAny { out["truncated"] = true }
        return out
    }

    static func extractReturnedError(_ result: [String: Any]) -> String? {
        // ① 显式 ok:false
        if result["ok"] as? Bool == false {
            return Self.errorMessage(from: result["error"], fallback: "Tool returned ok=false")
        }
        // ② error 键 (String 或 [String:Any] 字典）
        // v3.1.8：nil error 不应该被当成错误——只有 error 有值时才算
        if let errBox = result["error"], !(errBox is NSNull) {
            return Self.errorMessage(from: errBox, fallback: "Tool returned an error (no reason given)")
        }
        // ③ status failed态
        if let st = result["status"] as? String, ["failed", "error", "failure"].contains(st.lowercased()) {
            return Self.errorMessage(from: result["reason"] ?? result["error"], fallback: "Tool returned failed status \(st)")
        }
        return nil
    }

    private static func errorMessage(from box: Any?, fallback: String) -> String {
        if let s = box as? String, !s.isEmpty { return s }
        if let d = box as? [String: Any] {
            for k in ["reason", "message", "error", "detail"] {
                if let s = d[k] as? String, !s.isEmpty { return s }
            }
            if let s = d["description"] as? String, !s.isEmpty { return s }
        }
        return fallback
    }

    // v6.1.5-14ai：幽灵工具别名表——描述文本里出现但未独立注册的 dotted 名 → (真实注册工具名, 子命令)。
    // 均映射到真实实现（大工具子命令或已注册 dotted 工具），杜绝"AI 按描述调用 → unknown tool → 试错"。
    static func ghostAlias(_ name: String) -> (String, String)? {
        switch name {
        case "control.tap": return ("control", "tap")
        case "control.swipe": return ("control", "swipe")
        case "control.type": return ("control", "type")
        case "calendar.list": return ("calendar", "list")
        case "device.fake": return ("device", "fake")
        case "device.keychain_wipe": return ("inject", "keychain_wipe")
        case "device.refresh_container": return ("container", "refresh")
        case "location.clear": return ("location", "clear")
        case "artifact.write_text": return ("artifact", "write")
        case "assistant.memory_get": return ("assistant_memory", "list")
        case "reminder.create": return ("reminder", "create")
        case "reminder.schedule": return ("reminder", "schedule")
        case "automation.cron_fire": return ("automation", "cron_fire")
        case "rescue.restore_all": return ("rescue", "recover_all")
        case "injection.mem": return ("inject", "mem")
        case "debug.dump_messages": return ("debug.dump_conversation", "")
        case "debug.dump_model_configs": return ("model", "config")
        default: return nil
        }
    }

    // v2.9.36：权限标签 (对齐老 MCP readOnly/privilegedRead/write 语义，按工具名前缀粗分）
    private static func permissionLabel(_ name: String) -> String {        let write = ["open", "open_and_input", "enable", "disable", "remove", "write",
                     "set", "delete", "clear", "run", "send", "connect", "create",
                     "cancel", "fire", "schedule", "prepare", "stop", "import",
                     "generate", "config", "set_enabled", "output", "approve", "refresh"]
        for w in write where name.contains(w) { return "write" }
        if name.contains("cache") { return "privilegedRead" }
        return "readOnly"
    }

    // v2.9.36：结果数据量 (JSON 序列化字节估算）
    private static func resultBytes(_ result: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return 0 }
        return data.count
    }

    /// 全量内置工具集
    public func registerBuiltinTools() {
        // M1 文件桥 + 基础
        // v3.1.39: artifact 大工具 + 子命令 (合并 3 个 artifact.* 工具）
        register(ArtifactExecTool())
        // v3.1.39: 删旧的 3 个 artifact.* 工具 (已合并到 artifact 大工具）
        // v3.1.46: 删 ArtifactFindTool (shell.exec 可以实现：shell.exec("find xxx")）
        // v3.1.46: 删 PingTool (shell.exec 可以实现：shell.exec("ping -c 4 xxx")）
        // v3.1.40: device 大工具 + 子命令 (合并 4 个 device.* 工具）
        register(DeviceExecTool())
        // v3.1.40: 删旧的 4 个 device.* 工具 (已合并到 device 大工具）
        register(MemoryTweakTool())   // v2.9.60：H5GG式内存修改 (需先注入MemoryTweak.dylib）
        // v3.1.34: control 大工具 + 子命令 (合并 10 个 control.* 工具）
        register(ControlExecTool())
        // v3.1.34: 删旧的 10 个 control.* 工具 (已合并到 control 大工具）
        // v3.1.46: 删 WorkspaceInfoTool (shell.exec 可以实现：shell.exec("pwd")）
        // v3.1.33: 清理工具已删 (用 shell 代替）
        // 代替成：shell.exec("du -sh ...") / shell.exec("rm -rf ...")

        // M2 助理记忆 (原版命名）
        // v3.1.43: memory 大工具 + 子命令 (合并 3 个 assistant.memory.* 工具）
        register(MemoryExecTool())
        // v3.1.43: 删旧的 3 个 assistant.memory.* 工具 (已合并到 memory 大工具）

        // M2 应用与设备
        // v3.1.37: 删旧的 4 个 app.* 工具 (已合并到 app 大工具）

        // v3.0.90：系统概览工具 (AI 全局视角目录）
        // v3.1.64: 删 SystemOverviewTool (用 shell.exec("uname -a") / shell.exec("df -h") / shell.exec("free") 代替）
        // v4.4.x(优化): 重新启用 SystemOverviewTool——tool_categories 已改为从注册表动态生成
        //   (只列真实注册的大工具 + 版本从 Bundle 读)，给 AI 一个无幽灵工具名的真实目录。
        register(SystemOverviewTool())
        // v4.4.x(优化): tools.audit——工具注册表一致性审计（检测 summary/prerequisites 里引用
        //   但未注册的"幽灵工具名"，防文档漂移，AI 分不清工具的根因之一）。
        register(AuditTool())
        // v3.1.44: verify 大工具 + 子命令 (合并 2 个 verify.* 工具）
        register(VerifyExecTool())
        // v4.5.x: 大文件下载工具（URLSession + 进度条，避开 shell.exec 120s 上限）
        register(DownloadTool())
        // v7.1.107: 子代理（对齐 OpenMinis subagent_task）——委派自包含脏活到隔离会话
        register(SubAgentRunTool())
        register(SubAgentStatusTool())
        register(SubAgentStopTool())
        // v7.1.107-P0: 子代理 steer——运行中方向修正
        register(SubAgentSteerTool())
        // v3.1.44: 删旧的 2 个 verify.* 工具 (已合并到 verify 大工具）
        // fix3cy10: wifi 系统代理控制（AI 一键开/关 HTTP(S) 代理 → 本地 MITM，不断网抓包）
        register(WifiProxyExecTool())

        // v3.1.34: inject 大工具 + 子命令 (合并 7 个 injection.* 工具）
        register(InjectionExecTool())
        // v3.1.34: 删旧的 7 个 injection.* 工具 (已合并到 inject 大工具）
        // v3.1.37: 删旧的 3 个 inject.* 工具 (已合并到 inject 大工具）
        // v3.1.38: rescue 大工具 + 子命令 (合并 3 个 rescue.* 工具）
        register(RescueExecTool())
        // v3.1.38: 删旧的 3 个 rescue.* 工具 (已合并到 rescue 大工具）
        // v2.9.90：高级工具组 (类探测/配置化 Hook/设备伪装）
        // v3.1.60: 删 ProbeInspectTool / HookApplyTool (已合并到 inject 大工具）
        // v3.1.55: 删旧的 device 工具 (已合并到 DeviceExecTool）
        // v2.9.95：设备指纹 / 容器 / entitlements (对齐 Fuck 工具箱 + 绿盾式）
        // v3.1.59: 删 AppEntitlementsTool (已合并到 app 大工具：app entitlements）
        // v3.1.60: 删 KeychainWipeTool (已合并到 inject 大工具：inject keychain_wipe）
        // v3.1.62: 删 AdvertisingTool / IdfvTool (已合并到 DeviceExecTool）
        // v3.1.41: container 大工具 + 子命令 (合并 3 个 container.* 工具）
        register(ContainerExecTool())
        // v3.1.41: 删旧的 3 个 container.* 工具 (已合并到 container 大工具）
        // v4.1.0: 按需选择性绑定 App 数据容器（替代整棵 /var/mobile 绑定）
        register(BindAppTool())
        // v4.2.0: 可写就地修改 App 数据容器（绑定前强制备份）
        register(BindAppWriteTool())
        // v4.3.3: 原生可写通道——fakefs 挂载点固定只读(bind_app_write 实测写不进, Errno 30),
        // 写 App 数据容器改用 iOS 原生 FileManager 直写(绕开 Alpine), 写前自动备份。
        register(AppWriteFileTool())
        // v2.9.99：一键新机 (绿盾式组合）
        // v3.1.62: 删 NewDeviceTool (已合并到 DeviceExecTool：device new_device）
        // v2.9.100：AI 分析引擎
        // v3.1.59: 删 AiAnalyzeTool (已合并到 app 大工具：app ai_analyze）

        // v2.9.68：SSH 远程连接 + 应用解密
        // v3.1.45: ssh 大工具 + 子命令 (合并 2 个 ssh.* 工具）
        register(SshExecTool())
        // v3.1.45: 删旧的 2 个 ssh.* 工具 (已合并到 ssh 大工具）
        // v3.1.59: 删 AppDecryptTool / AppReplaceDecryptedTool / AppEncryptInfoTool (已合并到 app 大工具）

        // v2.9.69：质量与诊断工具
        // v3.1.60: 删 IPAInspectTool / DylibInspectTool / InjectionDiagnoseTool (已合并到 inject 大工具）
        // v3.1.33: 删 LogCollectTool (用 shell cat 代替）
        register(NetworkCaptureTool())
        // v3.3.0: MITM 抓包 VPN/代理（系统级抓包，覆盖自研栈 App）
        register(VpnTool())
        // v3.3.4: 解包查看别人的包（deb / ipa：列结构、解包到工作区）
        register(PackageTool())

        // v3.1.34: app 大工具 + 子命令 (合并 5 个 app.* 工具）
        register(AppExecTool())
        // v3.1.34: 删旧的 5 个 app.* 工具 (已合并到 app 大工具）
        // v3.1.56: 删 TestRunTool (shell.exec 可以实现）

        // v3.1.42: diagnose 大工具 + 子命令 (合并 2 个 diagnose.* 工具）
        register(DiagnoseExecTool())
        // v3.1.42: 删旧的 2 个 diagnose.* 工具 (已合并到 diagnose 大工具）
        // v3.1.36: server 大工具 + 子命令 (合并 3 个 server.* 工具）
        register(ServerExecTool())
        // v3.1.36: 删旧的 3 个 server.* 工具 (已合并到 server 大工具）

        // v2.9.72：知识库 + 清理 + 符号 + 插件 + 兼容矩阵 + 崩溃复现
        // v3.1.63: 删 KnowledgeBaseTool (用 shell.exec 写文件/读文件/搜索文件代替）
        // v3.1.33: 删 WorkspaceCleanupTool (用 shell rm 代替）
        // v3.1.60: 删 BinarySymbolsTool / PluginTool (已合并到 inject 大工具）
        // v3.1.63: 删 CompatibilityTool (用 shell.exec 写文件/读文件代替）
        // v3.1.33: 删 CrashReproTool (用 shell 代替）

        // v2.9.73：项目上下文 + 任务模板
        register(ProjectTool())
        // v3.1.63: 删 TaskTool (用 shell.exec 直接运行命令代替）

        // M4 Gateway + 自动化 (含原版命名）
        // v3.1.62: 删 CronFireTool (已合并到 AutomationExecTool：automation cron_fire）
        // v3.1.35: automation 大工具 + 子命令 (合并 7 个 automation.* 工具）
        register(AutomationExecTool())
        // v3.1.35: 删旧的 7 个 automation.* 工具 (已合并到 automation 大工具）

        // M5 系统能力
        // v3.1.64: 删 ContactsSearchTool (用得少，隐私敏感，用系统电话 App 搜索联系人）
        // v3.1.64: 删 CalendarExecTool (用得少，用系统日历 App）
        // v3.1.57: 删旧的日历工具 (已合并到 CalendarExecTool）
        register(ReminderExecTool())   // v3.1.57: 提醒事项大工具 (合并 create/schedule/recurring）
        // v3.1.57: 删旧的提醒事项工具 (已合并到 ReminderExecTool）
        // v3.1.61: 删 LocationGetTool (已合并到 LocationExecTool：location get）
        // v3.1.64: 删 ScanQRTool (AI 是文字对话，不能扫码）
        // v3.1.33: 删 ProcessListTool (用 shell ps 代替）
        register(ShellExecTool())   // v3.0.28：内置终端，执行 shell 命令
        register(ShellStopTool())   // v7.1.80：AI 主动中断后台/当前命令（配合 background 模式）
        register(SystemExecRootTool()) // v7.2.0：系统侧 spawn 执行 Mach-O（jroot 越狱工具）

        // M5.5 内置浏览器 (v2.9.37：AI 可控，蓝框高亮元素；v2.9.88：+wait/text/scroll/submit）
        // v3.1.47: browser 大工具 + 子命令 (合并 13 个 browser.* 工具）
        register(BrowserExecTool())
        // v3.1.47: 删旧的 13 个 browser.* 工具 (已合并到 browser 大工具）
        // v2.9.131：AI 安装/卸载 App (trollstorehelper 优先）——补全下载→安装→注入→控制链路
        // v3.1.59: 删 AppInstallTool / AppUninstallTool / AppDuplicateTool (已合并到 app 大工具）
        // v2.9.132：failed边界一条龙——注入健康检查 + 启动failed判因
        // v3.1.60: 删 InjectionVerifyTool (已合并到 inject 大工具：inject verify）
        // v3.1.59: 删 AppDiagnoseTool (已合并到 app 大工具：app diagnose）
        // v3.1.55: 删 BrowserNavigateTool (已合并到 BrowserExecTool）

        // M6 编译模式 + 模型配置 + 工作区输出 (原版命名）
        // v3.1.56: 删 BuildRunnerTokenTool (shell.exec curl 可以实现）
        // v3.1.62: 删 ProjectGenerateTweakTool (已合并到 ProjectTool：project generate_tweak）
        // v3.1.55: 删旧的 model 工具 (已合并到 ModelExecTool）
        // v4.0.0: 删 WorkspaceOutputBookmarkTool / WorkspaceOutputNameTool（已内联进 ArtifactExecTool，消除"注释称删实未删"矛盾）

        // M8 本机编译/构建 (v2.9.3，设备端编译桥）
        // v3.1.46: 删 BuildEnvironmentTool (shell.exec 可以实现：shell.exec("which clang")）
        // v3.1.56: 删 BuildRunTool (shell.exec curl 可以实现 GitHub API）

        // M9 GitHub 线上编译 (v2.9.9：账号状态 / 触发编译 / 查进度 / 下载产物）
        // v3.1.52: 删 github 大工具 (shell.exec 可以实现：shell.exec("curl https://api.github.com/...")）

        // M7 补齐缺失设备端工具
        // v3.1.57: 删 CalendarCreateEventTool (已合并到 CalendarExecTool）
        // v3.1.57: 删 ReminderScheduleTool / ReminderScheduleRecurringTool (已合并到 ReminderExecTool）
        // v3.1.62: 删 DeviceSnapshotTool (已合并到 DeviceExecTool：device snapshot）
        // v3.1.54: 删 WebSearchTool / WebFetchTool (shell.exec curl 可以实现）
        // v3.1.50: knowledge 大工具 + 子命令 (合并 4 个 knowledge.* 工具）
        register(KnowledgeExecTool())
        // v3.1.50: 删旧的 4 个 knowledge.* 工具 (已合并到 knowledge 大工具）
        // v3.1.64: 删 PhoneExecTool (用得少，用系统电话 App 打电话）
        // v3.1.61: 删旧的电话工具 (已合并到 PhoneExecTool）
        // v3.1.64: 删 SkillsSetEnabledTool (用 shell.exec 修改配置文件代替）
        // v3.6.19l: re-register skills.* — the earlier comment said "replaced by shell.exec",
        //           but shell.exec has no skills subcommand, so the AI could never obtain
        //           skills.list/read/set_enabled and would report "can't call skills".
        //           With them restored, the on-demand loading mechanism actually works.
        register(SkillsListTool())        // v2.9.17：技能可被 AI 发现（按需搜索，不塞全量）
        register(SkillsReadTool())        // v2.9.17：技能可被 AI 读取（完整指令）
        register(SkillsSetEnabledTool())  // 技能启停
        // v3.1.31: 之前 shell 是 Alpine，访问不到 iOS 文件系统，所以 fs.* 工具加回来了
        // v3.1.46: 现在 shell.exec 已经做了 iOS 原生命令，可以访问 iOS 文件系统了！
        // 删掉 12 个 fs.* 工具 (shell.exec 可以实现）
        // v3.1.64: 删 FSZipTool (用 shell.exec("zip/unzip") 代替）
        // v3.1.64: 删 FSImageInfoTool (用 shell.exec("file 图片路径") 代替）

        // v2.9.139：AI 控制任意 App (HID 触摸injected + 进度横幅 + 控制会话）
        // v3.1.55: 删旧的 control 工具 (已合并到 ControlExecTool）
        // v2.9.139：启动带参数 + 定位模拟
        // v3.1.59: 删 AppLaunchOptionsTool (已合并到 app 大工具：app launch_options）
        // v3.1.51: location 大工具 + 子命令 (合并 4 个 location.* 工具）
        register(LocationExecTool())
        // v3.1.51: 删旧的 4 个 location.* 工具 (已合并到 location 大工具）
        // v2.9.141：跨 App 数据桥 (沙箱破坏者）+ AI 操作宏录制/回放
        // v3.1.46: 删 6 个 bridge.* 工具 (shell.exec 可以实现）
        // v3.1.53: debug 大工具 + 子命令 (合并 4 个 debug.* 工具）
        // v3.1.53: 删旧的 4 个 debug.* 工具 (已合并到 debug 大工具）
        // v3.1.58: Chat 工具 (测试用，不是给用户用的！）
        // v3.1.49: model 大工具 + 子命令 (合并 6 个 model.* 工具）
        // v3.1.64: 删 ModelExecTool (是测试用的）
        // v3.1.49: 删旧的 6 个 model.* 工具 (已合并到 model 大工具）
        // v3.1.55: 删旧的 debug 工具 (已合并到 DebugExecTool）
        // v3.1.48: macro 大工具 + 子命令 (合并 6 个 macro.* 工具）
        register(MacroExecTool())
        // v3.1.48: 删旧的 6 个 macro.* 工具 (已合并到 macro 大工具）

        // v3.0.67：toolchain 工具
        // v3.1.56: 删 toolchain 工具 (shell.exec 可以实现：which clang / apt-get install clang）
        // v3.0.71：AI 自我进化——加载外部 dylib 注册新工具
        // v3.1.60: 删 ToolLoadDylibTool (已合并到 inject 大工具：inject load_dylib）
        // v3.0.72：语义化 UI 操作 + OCR
        // v3.1.62: 删 ControlTapTextTool / ControlTypeTextTool (已合并到 ControlExecTool）

        // v3.6.12 P5 高层跨环境工具 (v3.7.7: 自动 bind 直读 iOS 文件)
        register(FileExecTool())
        register(DbExecTool())
        // v4.3.65：统一工具安装（AI 自动装工具/依赖闭环）——tool.install / env.setup_re
        register(ToolInstallTool())
        register(EnvSetupRETool())
        // v4.3.65：恢复注册 web.search / web.fetch（v3.1.54 曾删，现升级回归：
        // 多 query 并行、多引擎回退 Bing→DuckDuckGo→Baidu、去重/来源分级、正文抽取、可沉淀知识库）
        register(WebSearchTool())
        register(WebFetchTool())
        // v4.3.66：注册 github 大工具（CI 触发/查进度/下载产物）——tool.install 触发 CI 后，
        // AI 需按提示调 github.fetch_runs / github.download_artifact 取产物；此前该工具漏注册导致后续断链
        register(GitHubExecTool())
        // v3.7.7c: 移除 ish.bind 注册——bind mount 已由 autoBind 全自动（命令引用 iOS 路径自动挂载+改写），
        // 手动 bind 工具对 AI 是误导（会以为要手动挂载）。类定义保留供开发者调试/真机验证。
        AuditLog.shared.log("core", detail: "Registered \(definitions.count) tools")
    }
}


// MARK: - 工作区

public enum Workspace {
    public static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Workspace", isDirectory: true)
    }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// v2.9.62：把 App bundle 内 Resources/tweaks/ 下的内置 dylib 复制到工作区 tweaks/ 目录
    /// AI 可通过 artifact.find 直接定位，无需用户手动传输
    public static func ensureBundledTweaks() {
        guard let tweaksDir = Bundle.main.url(forResource: "tweaks", withExtension: nil) else { return }
        let destDir = root.appendingPathComponent("tweaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tweaksDir, includingPropertiesForKeys: nil) else { return }
        for src in files {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    /// 防目录穿越：解析后必须仍在工作区内
    public static func resolve(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(root.standardizedFileURL.path) else {
            throw MCPError.invalidParams("path escapes workspace: \(path)")
        }
        return url
    }
}

// MARK: - v3.0.71：外部 dylib 工具注册 (AI 自我进化）

/// 外部工具包装：把 dylib 的 handler 包装成 MCPTool
public final class ExternalMCPTool: MCPTool {
    public let definition: ToolDefinition
    private let handler: ([String: Any]) throws -> [String: Any]

    public init(definition: ToolDefinition, handler: @escaping ([String: Any]) throws -> [String: Any]) {
        self.definition = definition
        self.handler = handler
    }

    public func invoke(_ params: [String: Any]) throws -> [String: Any] {
        try handler(params)
    }
}

/// C 函数签名：让外部 dylib 能注册工具
/// dylib 加载后调用 TARegisterTool(name, summary, paramsJSON, handler)
/// handler 是 C 函数指针：NSDictionary* (^)(NSDictionary*)
typealias TAExternalHandler = @convention(block) (NSDictionary) -> NSDictionary

/// 全局注册函数——dylib 里调这个
@_cdecl("TARegisterTool")
public func TARegisterTool(_ name: UnsafePointer<CChar>,
                           _ summary: UnsafePointer<CChar>,
                           _ paramsJSON: UnsafePointer<CChar>,
                           _ handler: @escaping @convention(block) (NSDictionary) -> NSDictionary) {
    let n = String(cString: name)
    let s = String(cString: summary)
    let p = String(cString: paramsJSON)

    // 解析 params JSON
    var params: [String: String] = [:]
    if let data = p.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
        params = obj
    }

    let def = ToolDefinition(name: n, summary: s, parameters: params, verified: true, category: "external")
    ToolRegistry.shared.registerExternalTool(def) { params in
        let result = handler(params as NSDictionary)
        // NSDictionary → [String: Any]
        var dict: [String: Any] = [:]
        for (k, v) in result {
            if let key = k as? String { dict[key] = v }
        }
        return dict
    }
}
