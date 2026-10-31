import Foundation
import SQLite3

// MARK: - 子代理全链路诊断日志（fix73k-p3g）
/// 用户反馈"发出的消息根本没记录日志"：subagent 内部（loop/send/回调/工具/watchdog/终态）
/// 此前零埋点——subagent_run dispatch 后 diagnostic.log 一片空白，卡在哪（首轮请求挂住？
/// 工具执行卡死？watchdog 未触发？）完全不可见。本函数与主会话 diag 写同一文件，
/// 前缀 SUBAGENT-DIAG 区分，让子代理每个关键环节留痕。
func subagentDiag(_ s: String) {
    let p = NSHomeDirectory().appending("/Documents/Workspace/store/diagnostic.log")
    let line = "[\(Date())] SUBAGENT-DIAG: " + s + "\n"
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: p)) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: p), options: .atomic)
    }
}

// MARK: - 子代理身份注册表（v7.4.1-fix73j：对齐 Claude Code .claude/agents 声明式身份）
/// 身份 = 预定义 {name, description, 工具集, 纪律特化}。主 agent 按任务语义选 agent_type，
/// 身份决定"是谁+能用什么"，instruction 决定"做什么"。每个身份独立上下文天然不交错。
/// 安全边界：默认工具集一律不含高风险改写簇（hook.apply / injection.mem / device.fake /
/// keychain_wipe / system.exec_root / app.install / app.uninstall / control.inject）——
/// 子代理后台自主执行无人工确认，写操作必须经 subagent.run 的 tools 白名单显式放开。
struct SubAgentPersona {
    let name: String
    let description: String
    let tools: Set<String>
    let systemPrompt: String
    let defaultRounds: Int
    let defaultTimeout: TimeInterval
}

enum SubAgentPersonas {
    static let webResearcher = SubAgentPersona(
        name: "web-researcher",
        description: "多源网页调研、查证资料、比较方案、输出带来源的报告。用于需要 web.search/web.fetch 链式检索的调研任务（政策、比价、开源方案调查）。不适合：需要操作手机 App 的任务。",
        tools: ["web.search", "web.fetch", "shell.exec", "artifact", "skills.read"],
        systemPrompt: """
        You are a WEB RESEARCHER. Work in chains: search → fetch → cross-verify. Every factual claim in \
        your final summary MUST carry a source URL (plain http(s) URLs are fine; the UI auto-links them). \
        Distinguish verified facts from claims you could not confirm; when sources conflict, report the \
        disagreement explicitly. Prefer primary/official sources.
        """,
        defaultRounds: 12, defaultTimeout: 180)
    static let appAuditor = SubAgentPersona(
        name: "app-auditor",
        description: "审计已安装 App：砸壳解密、entitlements 权限、二进制符号、依赖关系、注入点、缓存结构、崩溃复现。用于逆向与分析任务。不适合：网页调研、UI 操作。",
        tools: ["app.decrypt", "app.entitlements", "app.deps", "binary.symbols", "probe.inspect",
                "apps.cache_inspect", "shell.exec", "artifact", "device.info"],
        systemPrompt: """
        You are an APP AUDITOR (read-only by default). Survey first: device.info → app entitlements → \
        binary symbols → deps → cache layout. Record a baseline before deep inspection. Write findings to \
        the workspace via artifact. You must NOT modify, inject, hook, install or uninstall anything unless \
        the tools whitelist explicitly granted those capabilities.
        """,
        defaultRounds: 15, defaultTimeout: 240)
    static let shellWorker = SubAgentPersona(
        name: "shell-worker",
        description: "批量文件操作、日志处理、数据加工、下载解压整理、脚本执行。用于纯命令类脏活。不适合：需要 LLM 深度判断的任务。",
        tools: ["shell.exec", "artifact", "skills.read"],
        systemPrompt: """
        You are a SHELL WORKER. Commands must be idempotent where possible. Write large outputs to files \
        instead of printing them. If a command fails, diagnose and try a different approach (up to 3 \
        attempts), then move on. Keep commands under 1000 chars; for longer scripts write them to a file \
        first, then run the file.
        fix73k df rule: `df` MUST be run alone (`df -h /`) and NEVER combined with | ; && (the env \
        intercepts compound df). A standalone `df -h /` always returns disk info successfully; do not \
        retry compound df variants — go straight to the standalone form.
        """,
        defaultRounds: 10, defaultTimeout: 180)
    static let general = SubAgentPersona(
        name: "general",
        description: "通用综合任务兜底（shell/文件/设备/联网/技能）。",
        // fix73j-审计：原 "device" 是前缀匹配（hasPrefix("device.")），会把 device.fake
        // /device.keychain_wipe/device.restore 等高危工具一起放行——改为精确 "device.info"。
        tools: ["shell.exec", "artifact", "device.info", "web.search", "web.fetch", "skills.read"],
        systemPrompt: "",
        defaultRounds: 12, defaultTimeout: 180)
    static let all: [SubAgentPersona] = [webResearcher, appAuditor, shellWorker, general]
    /// agent_type 解析：未知/空 → general（兜底，不报错）
    static func find(_ name: String?) -> SubAgentPersona {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return general }
        return all.first { $0.name == n } ?? general
    }

    /// fix73j-审计 M-8：高危工具簇硬排除名单——子代理默认禁，除非 tools 白名单
    /// 显式包含具体工具名（精确命中才放行，前缀/大工具名一律不放行）。
    /// 覆盖：改机/注入/伪造/清钥/装卸载/系统执行/控制台等改写型工具。
    static func isHighRisk(_ name: String) -> Bool {
        if name.hasPrefix("hook.") || name.hasPrefix("injection.") { return true }
        if name.hasPrefix("device.fake") || name.hasPrefix("device.restore")
            || name.hasPrefix("device.keychain_wipe") { return true }
        if name.hasPrefix("system.exec_root") || name.hasPrefix("app.install")
            || name.hasPrefix("app.uninstall") || name.hasPrefix("control.inject") { return true }
        if name == "device.advertising" || name == "device.idfv" || name == "device.refresh_container" { return true }
        return false
    }
}

/// fix73j：子代理状态文案（中英）——主界面卡片/详情页统一映射
enum SubAgentStatusText {
    static func zh(_ status: String) -> String {
        switch status {
        case "running": return "执行中"
        case "done": return "已完成"
        case "failed": return "失败"
        case "stopped": return "已停止"
        case "interrupted": return "已中断"
        default: return status
        }
    }
    static func en(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "done": return "Completed"
        case "failed": return "Failed"
        case "stopped": return "Stopped"
        case "interrupted": return "Interrupted"
        default: return status
        }
    }
}

// MARK: - 子代理任务模型（v7.1.107：对齐 OpenMinis subagent_task 思想，自实现）
/// 子代理 = 隔离的隐藏会话跑自己的工具循环：主模型把自包含"脏活"委派出去，
/// 子代理独立上下文执行（不污染主线），完成后把结果 JSON 回传给主模型。
/// 主模型用 subagent.status 轮询、subagent.stop 停止。

final class SubAgentTask: Identifiable {
    let id: String
    let instruction: String
    /// v7.1.108: 预算信息存入任务（status 返回可算剩余轮次/剩余时间）
    let maxRounds: Int
    let timeoutSecs: TimeInterval
    private(set) var status: Status
    private(set) var createdAt: Date
    private(set) var rounds: Int
    private(set) var toolTrace: [String]
    /// v7.4.0-fix73f-6：请求生命周期诊断——idle(未发) → sent(已发出等待响应) → replied(收到响应)。
    /// status 返回 send_state，父模型一眼区分"worker 没启动"(idle) vs "请求挂住"(sent) vs 正常(replied)。
    private(set) var sendState: String = "idle"
    private(set) var result: String
    private(set) var error: String
    private(set) var elapsed: Double
    /// v7.1.107-P0: 完成但无交付内容（模型总结为空/被截断）——对齐 OpenMinis
    /// "finished callback whose body is empty carries no deliverable" 语义
    private(set) var noDeliverable: Bool = false
    /// v7.4.0-fix73d：后台挂起标记——窗口耗尽时由 suspendAllForBackground 设置；
    /// 请求失败回调据此判 interrupted（可重派发）而非误报 failed。
    /// 请求若窗口内完成/回前台恢复成功 → 正常 done，标记残留无影响。
    private(set) var backgroundSuspended: Bool = false
    /// v7.1.108-fix: 状态锁——runner 后台线程写状态（markDone/Failed/Stopped/addRound），
    /// 工具线程读（toDict/status）。无锁多线程读写是数据竞争（UB），全部可变状态读写统一走 stateLock。
    private let stateLock = NSLock()
    /// fix73j-审计：详情页展示快照——后台 runner 线程并发写 status/rounds/elapsed/
    /// trace 等属性，UI 直读同一属性是 Swift 数据竞争（UB）。快照在 stateLock 内
    /// 拷贝全部展示字段，UI 只读快照（终态后无写、运行中读到一致点即可）。
    struct SubAgentSnapshot {
        let status: Status
        let rounds: Int
        let maxRounds: Int
        let elapsed: TimeInterval
        let sendState: String
        let personaName: String
        let result: String
        let error: String
        let trace: [[String: Any]]
        let hasTrace: Bool
    }
    func snapshot() -> SubAgentSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return SubAgentSnapshot(status: status, rounds: rounds, maxRounds: maxRounds,
                                elapsed: elapsed, sendState: sendState, personaName: personaName,
                                result: result, error: error, trace: trace, hasTrace: hasTrace)
    }

    /// fix73j：身份名（agent_type），详情页/回传展示用
    private(set) var personaName: String
    /// fix73j-审计 M-1：runner 弱引用——finalizeSubAgent 不经 manager.lock 取快照
    /// （terminateWithAbort 持 manager.lock 时，traceSnapshotFor 的 lock.lock() 同线程
    /// 重入非递归 NSLock → 100% 自死锁）。runner 由 manager.runners 强持有，终态时必活；
    /// releaseRunner 在 finalizeSubAgent 尾部调用，弱引用解包安全。
    weak var runnerRef: SubAgentRunner?
    /// fix73j：派发时的会话 id——回传写回该会话（防用户切换会话后跨会话污染）
    let sessionID: UUID?
    /// fix73j-p5h：UI 显示名（A/B/C/D…，用户要求界面不用十六进制 task_id）
    let displayName: String
    /// fix73j：轨迹快照（终态时从 runner 导出，供详情页回看）——[{role, content, tool}]
    private(set) var trace: [[String: Any]] = []
    private(set) var hasTrace = false

    // MARK: - 轨迹持久化（fix73j-p5g：独立 SQLite 库 subagent_index.sqlite——
    // 与主会话 session_index.sqlite 完全分离，经 session_id 关联主会话）

    /// 每轮/终态写入轨迹（覆盖式，保持当前快照语义）
    static func persistTrace(id: String, trace: [[String: Any]]) {
        SubAgentStore.shared.replaceTraces(taskID: id, trace: trace)
    }

    /// 详情页读轨迹（运行中实时/重启后均从 SQLite 读）
    static func loadTrace(id: String) -> [[String: Any]]? {
        let t = SubAgentStore.shared.loadTraces(taskID: id)
        return t.isEmpty ? nil : t
    }

    enum Status: String { case running, done, failed, stopped, interrupted }

    /// v7.4.0-fix73f-7：绝对截止时刻（createdAt + timeoutSecs）——status 软超时与
    /// 看门狗共用，status 轮询路径检查它，解决"time_left_secs 归零也不 abort"。
    let deadlineDate: Date
    init(id: String, displayName: String, instruction: String, maxRounds: Int, timeoutSecs: TimeInterval,
         personaName: String = "general", sessionID: UUID? = nil) {
        self.id = id
        self.displayName = displayName
        self.instruction = instruction
        self.maxRounds = maxRounds
        self.timeoutSecs = timeoutSecs
        self.deadlineDate = Date().addingTimeInterval(timeoutSecs)
        self.personaName = personaName
        self.sessionID = sessionID
        self.status = .running
        self.createdAt = Date()
        self.rounds = 0
        self.toolTrace = []
        self.result = ""
        self.error = ""
        self.elapsed = 0
    }

    func markDone(result: String) {
        stateLock.lock()
        // fix73j：幂等——终态后不再改（watchdog 与 status 软超时竞态窗口防双重回传）
        guard status == .running else { stateLock.unlock(); return }
        status = .done
        // 防结果撑爆主线：截断到 4000 字符（子代理最终总结应简短，超长说明模型把工具输出写进了总结）
        self.result = result.count > 4000 ? String(result.prefix(4000)) + "\n... [result truncated]" : result
        // v7.1.107-P0: 空总结 = 无交付——父模型拿到后知道要去子代理轨迹里挖结果
        noDeliverable = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        elapsed = Date().timeIntervalSince(createdAt)
        stateLock.unlock()
        subagentDiag("FINAL: task=\(id) status=done errLen=0 resultLen=\(result.count)")
        // fix73j：finalize 移出持锁区间——traceSnapshotFor 内部取 manager.lock，
        // 若在 stateLock 内调用会与 status/stop 的 manager.lock→stateLock 反向死锁。
        finalizeSubAgent()
    }

    func markFailed(_ err: String) {
        stateLock.lock()
        guard status == .running else { stateLock.unlock(); return }
        status = .failed
        error = err
        elapsed = Date().timeIntervalSince(createdAt)
        stateLock.unlock()
        subagentDiag("FINAL: task=\(id) status=failed err=\(err.prefix(120))")
        finalizeSubAgent()
    }

    func markStopped() {
        stateLock.lock()
        guard status == .running else { stateLock.unlock(); return }
        status = .stopped
        elapsed = Date().timeIntervalSince(createdAt)
        stateLock.unlock()
        subagentDiag("FINAL: task=\(id) status=stopped")
        finalizeSubAgent()
    }

    /// v7.4.0-fix73d：后台挂起中断——区别于 failed（误报）与 stopped（用户手动），
    /// 语义 = "app 切后台窗口耗尽，请求被冻结中断"，父模型应重新派发而非诊断失败。
    func markInterrupted() {
        stateLock.lock()
        guard status == .running else { stateLock.unlock(); return }
        status = .interrupted
        error = "interrupted by app backgrounding (background window expired) — re-dispatch to resume"
        elapsed = Date().timeIntervalSince(createdAt)
        stateLock.unlock()
        subagentDiag("FINAL: task=\(id) status=interrupted")
        finalizeSubAgent()
    }

    /// fix73j：任务终态统一收尾——轨迹快照 + 完成回传 + 释放 runner。
    /// 必须在 stateLock 释放后调用（mark* 已重构为"锁内改状态 + 锁外 finalize"，
    /// 防 traceSnapshotFor 取 manager.lock 与 status/stop 的 manager.lock→stateLock 反向死锁）。
    /// 回传 = user 消息（API 序列合法，主 agent 下一轮请求必然携带；
    /// UI 检测 [SUBAGENT-DONE] 前缀渲染为可点开的子代理完成卡）。
    private func finalizeSubAgent() {
        // 1) 轨迹快照：经 task 弱引用的 runner 直接取（M-1：不经 manager.lock——
        // terminateWithAbort/watchdog/status/stop 持 manager.lock 调 mark* → finalize →
        // traceSnapshotFor 的 lock.lock() 同线程重入非递归 NSLock 必死锁）。
        // runner 消息只被其自身线程写，终态时写已停止，读快照安全（诊断数据）。
        // fix73j-审计 M-5：trace 写必须持 stateLock（fix9 只修读侧，finalize 写 trace
        // 无锁与详情页 snapshot() 锁内读竞争 = 数据竞争 UB）。
        stateLock.lock()
        if let msgs = runnerRef?.snapshotMessages() {
            trace = msgs.prefix(200).map { m in
                ["role": m.role, "content": String(m.content.prefix(2000)), "tool": m.toolName ?? ""]
            }
            hasTrace = !trace.isEmpty
        }
        stateLock.unlock()
        // fix73j-p5g：轨迹持久化——trace 是内存态，落盘独立 SQLite（subagent_index.sqlite），
        // 详情页重启后从库读回完整轨迹；终态一并写入任务行。
        // fix73k：SQLite 写改后台异步——watchdog/status/stop 持 manager.lock 调 mark* →
        // finalize 若同步写库，磁盘满时写卡会连带锁住 manager.lock（status 轮询全卡，
        // 主 AI 永远"执行中"）。异步 + busy_timeout 2s + 事务化 = 终态写不阻塞任何路径。
        let finSnapshot = (status: status.rawValue, rounds: rounds, elapsed: elapsed,
                           result: result, error: error, trace: hasTrace ? trace : [])
        let tid = id
        DispatchQueue.global(qos: .utility).async {
            if !finSnapshot.trace.isEmpty {
                Self.persistTrace(id: tid, trace: finSnapshot.trace)
            }
            SubAgentStore.shared.finalizeTask(taskID: tid, status: finSnapshot.status,
                                              rounds: finSnapshot.rounds, elapsed: finSnapshot.elapsed,
                                              result: finSnapshot.result, error: finSnapshot.error)
        }
        // 2) 完成回传
        var payload: [String: Any] = [
            "ok": true, "task_id": id, "display_name": displayName, "agent_type": personaName,
            "status": status.rawValue, "rounds": rounds,
            "elapsed_secs": Int(elapsed),
            "result": String(result.prefix(2000)),
        ]
        if !error.isEmpty { payload["error"] = String(error.prefix(500)) }
        var body = ""
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            body = String(data: d, encoding: .utf8) ?? ""
        }
        let content = "[SUBAGENT-DONE] " + body
        DispatchQueue.main.async {
            var m = ChatMessage(role: "user", content: content)
            m.toolTitle = "子代理 \(self.displayName) · \(self.personaName) \(SubAgentStatusText.zh(self.status.rawValue))"
            m.toolName = "subagent.complete"
            if let sid = self.sessionID {
                ConversationStore.shared.appendToSession(id: sid, message: m, generateTitle: false)
            } else {
                ConversationStore.shared.appendToCurrent(m)
            }
        }
        // 3) fix73i：任务终态 → 释放 runner 保活引用（异步，幂等）
        SubAgentManager.shared.releaseRunner(id: id)
    }

    /// v7.4.0-fix73d：标记"可能被后台挂起"（窗口耗尽时对所有 running 任务设置）
    func markBackgroundSuspended() {
        stateLock.lock(); defer { stateLock.unlock() }
        backgroundSuspended = true
    }

    /// v7.4.0-fix73d：读取挂起标记（失败回调判定用）
    func isBackgroundSuspended() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return backgroundSuspended
    }

    func addRound(tools: [String]) {
        stateLock.lock(); defer { stateLock.unlock() }
        rounds += 1
        toolTrace.append(contentsOf: tools)
    }

    /// v7.4.0-fix73f-6：请求已发出（loop 调 send 前标记）——区分"worker 没启动"与"请求挂住"
    func markSendStarted() {
        stateLock.lock(); defer { stateLock.unlock() }
        sendState = "sent"
    }

    /// v7.4.0-fix73f-6：请求收到响应（成功/失败回调都算）——worker 与上游链路正常
    /// v7.4.0-fix73g：只允许 sent → replied。watchdog/stop 先置 aborted 再 cancel，
    /// 迟到的 cancel 回调不得把 aborted 覆盖回 replied（否则 send_state 又撒谎）。
    func markSendReplied() {
        stateLock.lock(); defer { stateLock.unlock() }
        if sendState == "sent" { sendState = "replied" }
    }

    /// v7.4.0-fix73g：请求被强制中止（看门狗到点 / stop / 软超时 / loop 内超时）——
    /// 先置此标记再 cancel 在途请求，父模型一眼看到"请求是被掐断的"而非"挂住/sent"。
    func markSendAborted() {
        stateLock.lock(); defer { stateLock.unlock() }
        sendState = "aborted"
    }

    /// v7.1.108-fix: 线程安全的状态读取（runner 后台线程/stop 工具线程共用）
    func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return status == .running
    }

    /// 工具返回值 JSON（subagent.status / 完成回传用）
    func toDict() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        var d: [String: Any] = [
            "task_id": id,
            "status": status.rawValue,
            "rounds": rounds,
            "elapsed_secs": Int(elapsed),
            "tool_trace": toolTrace,
        ]
        // v7.1.108: 进度可视化——模型/用户在工具流里直接看到"还剩几轮/还剩几秒/最近在干嘛"
        // （对齐 OpenMinis SubAgentRunDigest 的信息密度，但走工具流呈现，零 UI 改动）
        // v7.1.108-fix: 修复逻辑矛盾——running 时 elapsed 字段从未更新（只在 markDone/Failed/Stopped
        // 赋值），旧代码显示 elapsed_secs=0 / "0s elapsed" / time_left=满值。running 一律实时计算。
        let liveElapsed = Date().timeIntervalSince(createdAt)
        if status == .running {
            d["rounds_left"] = max(0, maxRounds - rounds)
            d["time_left_secs"] = max(0, Int(timeoutSecs - liveElapsed))
            let recent = toolTrace.suffix(3).joined(separator: ", ")
            if !recent.isEmpty { d["recent_tools"] = recent }
            d["elapsed_secs"] = Int(liveElapsed)
            d["progress_hint"] = "working... \(rounds)/\(maxRounds) rounds, \(Int(liveElapsed))s elapsed"
        // v7.4.0-fix73f-6：请求生命周期诊断
        d["send_state"] = sendState
        }
        if !result.isEmpty { d["result"] = result }
        if !error.isEmpty { d["error"] = error }
        // v7.1.107-P0: 无交付标记——父模型拿到 done 但 result 空时，知道该去查看轨迹而非重跑
        if status == .done && noDeliverable { d["no_deliverable"] = true }
        return d
    }
}

// MARK: - 子代理管理器（单例，一次最多 1 个运行中——防工具资源争抢/上下文混乱）

final class SubAgentManager {
    static let shared = SubAgentManager()

    private var tasks: [String: SubAgentTask] = [:]
    /// fix73j：并发子代理计数（替代 v7.1.107 的 activeTaskID 单任务独占锁）。
    /// fix73j-p5e：仅作统计展示（subagent.status），不再作为派发限制——
    /// 子代理槽位各自独立，不共享配额上限。
    private var runningCount = 0
    /// fix73j-p5h：UI 显示名分配（A→B→C…→Z→A1→B1…）
    /// fix73k-根因修复：调用者必须已持 lock（唯一调用点 start() 已持 lock）——
    /// 原实现内部 lock.lock() 与 start() 的 lock 同线程重入非递归 NSLock → 永久死锁 →
    /// start() 永不返回 → subagent.run invoke 卡 → 主会话占位卡永不填充 → 杀后台重启
    /// CRASH-REWRITE（用户实测"执行中几小时"的真正根因，p5h 加 displayName 引入的回归）。
    private var letterCounter = 0
    func nextDisplayName() -> String {
        // 无锁：调用方持锁（start()）。不可自行加锁（重入死锁）。
        let n = letterCounter
        letterCounter += 1
        if n < 26 { return String(Character(UnicodeScalar(65 + n)!)) }
        return String(Character(UnicodeScalar(65 + (n % 26))!)) + String(n / 26)
    }
    /// fix73j-p5h：按 task_id 查 UI 显示名（invoke 侧构造 RUNNING 卡用）
    func displayNameFor(id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tasks[id]?.displayName
    }
    /// v7.4.0-fix73g：在途 LLM 请求的真 abort 处理器——watchdog/stop/软超时到点必须
    /// cancel 掉 runner 的 OpenAIClient（此前只改任务状态，请求永远在后台挂住 → send_state 卡 sent）。
    private var cancellers: [String: () -> Void] = [:]
    /// v7.1.107-P0: steer 方向修正队列——父模型可运行中给子代理注入新指令，
    /// 在循环边界以"用户消息"送达（对齐 OpenMinis pendingSteerMessages 语义）
    private var pendingSteers: [String: [String]] = [:]
    /// v7.4.1-fix73i：runner 强引用保活——run() 里首轮 client.send 是异步的，loop() 直接返回，
    /// 若无强引用，GCD 闭包结束后 runner 被释放 → completion 闭包的 [weak self] 失效 → 执行链
    /// 永久丢失（markSendReplied/execute/下一轮全部不执行 → send_state 卡 sent、rounds 恒 0、
    /// 只能等 watchdog 兜底，用户实测 7.1.215 子代理"能启动但跑不起来"的根因）。
    /// 任务达到终态（done/failed/stopped/interrupted）由 releaseRunner 异步移除。
    private var runners: [String: SubAgentRunner] = [:]
    private let lock = NSLock()

    /// fix73i：任务终态后释放 runner（异步——mark* 可能在 manager.lock / stateLock 持锁路径
    /// 调用，同步移除会重入 NSLock 死锁；幂等，重复调用无害）。
    /// fix73j：同时归还并发配额（runningCount - 1）。
    func releaseRunner(id: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // fix73j：仅当 removeValue 命中非 nil 才归还配额——无条件递减会在
            // releaseRunner 重复调用（watchdog/软超时/stop 多路径）时多减，
            // 导致 runningCount 失真、上限 4 失效。
            if self.runners.removeValue(forKey: id) != nil {
                self.runningCount = max(0, self.runningCount - 1)
            }
            // fix73j-审计 M-3：abort 处理器随终态统一清理（run() 返回时删会让后续轮
            // 在途请求失去 cancel 能力；终态后请求已无意义，清理防字典残留）
            self.cancellers.removeValue(forKey: id)
            self.lock.unlock()
            self.trimFinishedTasks()
        }
    }

    /// fix73j：终态任务保留上限——tasks 字典从不清理会让内存无限膨胀
    /// （每个终态任务 trace 可达 200 条×2000 字符）。保留最近 maxRetainedTasks
    /// 个终态任务（按 deadlineDate 即开始时间，最早先淘汰）；running 任务不受影响。
    private static let maxRetainedTasks = 20
    private func trimFinishedTasks() {
        lock.lock()
        let finished = tasks.filter { !$0.value.isRunning() }
        if finished.count > SubAgentManager.maxRetainedTasks {
            let sorted = finished.sorted { $0.value.deadlineDate < $1.value.deadlineDate }
            let overflow = sorted.prefix(finished.count - SubAgentManager.maxRetainedTasks)
            for (id, _) in overflow { tasks.removeValue(forKey: id) }
        }
        lock.unlock()
    }

    /// fix73j：终态时取 runner 当前 messages 快照（详情页回看轨迹用）。
    /// 先取引用再读——避免 stateLock → manager.lock 与 terminateWithAbort 的
    /// manager.lock → stateLock 锁序相反导致死锁；runner 消息只被其自身线程写，
    /// 终态时写已停止，读快照安全（诊断数据，不要求强一致）。
    func traceSnapshotFor(id: String) -> [ChatMessage]? {
        var runner: SubAgentRunner?
        lock.lock(); runner = runners[id]; lock.unlock()
        return runner?.snapshotMessages()
    }

    /// 启动子代理。成功返回 task_id；并发达到上限（4）则 throw（模型应等待/停止旧任务）。
    /// fix73j：personaName 选身份（agent_type），并发计数取代单任务独占。
    /// v7.1.108-fix: Result<String,String> 改为 throws——Swift 要求 Result.Failure: Error，
    /// String 不满足协议，这是子代理系列构建失败的根因。
    func start(instruction: String, allowedTools: [String]?, maxRounds: Int,
               timeout: TimeInterval, personaName: String = "general",
               sessionID: UUID? = nil) throws -> String {
        lock.lock()
        // fix73j-p5e：去掉派发配额上限（用户确认：子代理槽位各自独立，不共享配额——
        // iOS 不会因并发数/线程多杀 App，历史杀后台已定位为落盘 bug p3e）。
        // runningCount 仅作统计供 subagent.status 展示，不再作为派发限制。
        runningCount += 1
        let id = String(UUID().uuidString.prefix(8))
        let displayName = nextDisplayName()
        let persona = SubAgentPersonas.find(personaName)
        let clampedRounds = max(2, min(maxRounds, 30))
        let clampedTimeout = max(30, min(timeout, 600))
        let task = SubAgentTask(id: id, displayName: displayName, instruction: instruction,
                                maxRounds: clampedRounds, timeoutSecs: clampedTimeout,
                                personaName: persona.name, sessionID: sessionID)
        tasks[id] = task
        lock.unlock()
        // fix73j-p5g：独立 SQLite 建行（记录关联主会话 id）
        // fix73k-p3g：insertTask 改后台异步——此前同步 SQLite 写在磁盘满/锁竞争时阻塞
        // subagent_run invoke → dispatch 不返回 → 主会话占位卡（空+isRunning）永不填充 →
        // 杀后台重启 repairCrashResidue 判 wasEmpty=true → CRASH-REWRITE 误判"Execution
        // interrupted"（用户"完成变失败"根因）。异步后 invoke 立即返回，占位卡秒填。
        DispatchQueue.global(qos: .userInitiated).async {
            SubAgentStore.shared.insertTask(taskID: id, sessionID: sessionID?.uuidString,
                                            agentType: persona.name, maxRounds: clampedRounds)
        }

        let runner = SubAgentRunner(task: task, allowedTools: allowedTools,
                                    maxRounds: clampedRounds, timeout: clampedTimeout,
                                    persona: persona)
        // v7.4.1-fix73i：强引用保活 runner（见 runners 注释）——否则首轮 send 后即释放，
        // 执行链断在起点。
        runners[id] = runner
        // fix73j-审计 M-1：task 弱引 runner——终态 finalize 直接取快照（无锁），
        // 修 terminateWithAbort 持 manager.lock 时 traceSnapshotFor 同锁重入自死锁。
        task.runnerRef = runner
        // v7.4.0-fix73g：注册真 abort——watchdog/软超时/stop 到点 cancel 在途请求，
        // 弱引用防循环；幂等（cancelInflight 内部置空 client，重复调用无害）。
        cancellers[id] = { [weak runner] in runner?.cancelInflight() }
        DispatchQueue.global(qos: .userInitiated).async {
            runner.run()
            // fix73j-审计 M-3：不再在 run() 返回时删 cancellers——run() 返回只代表首轮
            // 请求已发出，后续轮次的在途请求仍需真 abort（stop/watchdog 到点 cancel）；
            // 提前删除使后续轮 stop 无法取消请求（fix73g 真 abort 架空）。
            // cancellers 由终态 releaseRunner 统一清理（防字典残留）。
        }
        // v7.4.0-fix73f-4：超时看门狗——loop() 的超时检查只在"发出请求前"执行，
        // 请求异步挂住（网络卡死/上游无响应/回调丢失）时回调不来 → loop 不再被驱动 →
        // v7.4.0-fix73f-6：看门狗精确到点（去掉 +5 余量）——实测 timeout_secs=60 的任务
        // 64s 仍 running（旧逻辑 65s 才触发，用户观察点恰好没到）。deadline 到点立即
        // 强制中断，不依赖请求回调；已 done/failed/stopped 的任务 isRunning()=false 不受影响。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + clampedTimeout) {
            subagentDiag("WATCHDOG: task=\(id) deadline-hit, checking trigger")
            self.lock.lock()
            if let t = self.tasks[id], t.isRunning() {
                self.terminateWithAbort(id) { $0.markFailed("timeout after \(Int($0.timeoutSecs))s (watchdog — request hung without callback; in-flight tool call may still finish but the task is terminated and the LLM request is aborted)") }
            }
            self.lock.unlock()
        }
        return id
    }

    /// v7.4.0-fix73g：真 abort 指定任务的在途 LLM 请求并清理处理器（幂等）。
    /// 必须在持有 lock 时调用（watchdog/status/stop 都已加锁）。
    private func abortInflight(_ id: String) {
        if let c = cancellers.removeValue(forKey: id) { c() }
    }

    /// v7.4.0-fix73g：任务终止时统一收尾——置 send_state=aborted → 真 cancel → 标记状态。
    /// 顺序关键：先 aborted 后 cancel，迟到的 cancel 回调走 markSendReplied（已只允许 sent→replied）
    /// 不会把 aborted 覆盖回 replied。
    private func terminateWithAbort(_ id: String, mark: (SubAgentTask) -> Void) {
        guard let t = tasks[id] else { return }
        t.markSendAborted()
        abortInflight(id)
        mark(t)
    }

    func status(id: String) -> SubAgentTask? {
        lock.lock()
        defer { lock.unlock() }
        // v7.4.0-fix73f-7：软超时——status 是父模型轮询路径，必然高频执行。
        // 看门狗（asyncAfter）若因任何原因未触发（全局队列繁忙/时序偏差），
        // 这里在到点后首次轮询即强制中断，杜绝"time_left 归零仍 running"。
        // v7.4.0-fix73g：顺带真 cancel 在途请求，不再让它后台挂死。
        if let t = tasks[id], t.isRunning(), Date() >= t.deadlineDate {
            terminateWithAbort(id) { $0.markFailed("timeout after \(Int($0.timeoutSecs))s (checked on status poll — request did not complete in time)") }
        }
        return tasks[id]
    }

    func stop(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tasks[id], t.isRunning() else { return false }
        terminateWithAbort(id) { $0.markStopped() }
        return true
    }

    /// v7.1.107-P0: 给运行中的子代理注入方向修正（steer）。仅 running 可注入；
    /// 消息排队在循环边界消费。返回是否成功入队。
    func steer(id: String, instruction: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tasks[id], t.isRunning() else { return false }
        pendingSteers[id, default: []].append(instruction)
        return true
    }

    /// v7.1.107-P0: 消费子代理的待送达 steer（循环边界调用）。线程安全。
    func drainSteers(id: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingSteers.removeValue(forKey: id) ?? []
    }

    /// v7.4.0-fix73d：窗口耗尽时标记全部 running 子代理"可能被后台挂起"。
    /// 子代理请求用独立 OpenAIClient（不在主会话 currentClient 管辖内，fix73 代传覆盖不到）——
    /// 冻结后请求失败回调据此判 interrupted（可重派发）而非误报 failed。
    /// 请求若窗口内完成/回前台恢复成功 → 正常 done，标记残留无影响。
    func suspendAllForBackground() {
        lock.lock()
        let running = tasks.values.filter { $0.isRunning() }
        lock.unlock()
        for t in running { t.markBackgroundSuspended() }
    }

    /// fix73j：全部 running 任务 id（subagent.wait_all 省略 task_ids 时等待的对象）。
    /// 锁序 manager.lock → stateLock（与 terminateWithAbort 一致，无反向路径）。
    func allRunningTaskIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tasks.compactMap { $0.value.isRunning() ? $0.key : nil }
    }
}

// MARK: - 子代理执行循环（隔离会话 + 工具循环，独立于主 runLoop，不碰主线状态）

final class SubAgentRunner {
    private let task: SubAgentTask
    private let allowedTools: [String]?
    /// fix73j：身份（决定默认工具集 + 纪律特化）
    private let persona: SubAgentPersona
    private let maxRounds: Int
    private let deadline: Date
    private var messages: [ChatMessage] = []
    /// fix73k：完整轨迹归档（append-only）——折叠只压缩"模型看到的请求上下文"（messages），
    /// 被折叠的早期轮次原文归档到这里，详情页轨迹（snapshotMessages）据此显示完整历史
    /// （对齐 DeepSeek Harness append-only 事件流思路：请求用折叠版、回放用完整版）。
    private var fullTrace: [ChatMessage] = []
    private var client: OpenAIClient?
    /// fix73j-P2：模型首轮按纪律输出的 📋 PLAN 段（计划锚定——每轮 send 注入上下文末尾，
    /// 对齐 Manus "把计划念到上下文末尾"防目标漂移；不写进 messages，避免折叠污染）。
    private var planText: String?
    /// fix73j-p4：任务级模型配置快照 + 兼容级别缓存——子代理请求失败触发的降级
    /// （OpenAIClient.persistCompatLevel=false）不写回共享 ModelConfig，主会话不被
    /// 连带降级；快照保证任务内不受主会话中途降级影响；compatOverride 缓存子代理
    /// 任务内 settle 的级别，每轮新 client 从缓存起步（不重试降级链）。
    private var taskConfig: ModelConfig?
    private var compatOverride: Int?
    private var lastTool = ""
    private var sameToolRepeat = 0
    /// v7.1.107-P0: 轮次预警已注入（剩 2-3 轮时，工具仍可用）
    private var turnWarningInjected = false
    /// v7.1.107-P0: wrap-up 已注入（最后一轮收回工具，强制写交付总结）
    private var wrapUpInjected = false
    // fix73j-审计：historyFolded 已移除——长任务可重复折叠（30 轮任务折叠一次后
    // 继续累积会再次超窗），每次保留最近 6 轮即可稳定。

    init(task: SubAgentTask, allowedTools: [String]?, maxRounds: Int, timeout: TimeInterval,
         persona: SubAgentPersona) {
        self.task = task
        self.allowedTools = allowedTools
        self.persona = persona
        self.maxRounds = max(2, min(maxRounds, 30))
        self.deadline = Date().addingTimeInterval(max(30, min(timeout, 600)))
    }

    /// 子代理系统提示词——通用执行纪律 + 身份纪律特化（persona.systemPrompt）+ 工具集
    private func systemPrompt() -> String {
        var p = """
        You are a subagent of TrollAgent executing a delegated task in an isolated session.
        Your ONLY job is to complete the task below precisely, autonomously, using tools.
        RULES:
        1. The ONLY way to call a tool is an explicit structured function call. Never write calls as plain text.
        2. NEVER end your turn with a promise of future action ("I'll continue later"). Work until the task is
           actually done; if a step needs waiting, chain short polling calls (timeout≈5) and decide from each result.
        3. If a tool fails, diagnose from the error and try a different approach (up to 3 attempts), then move on.
        4. Do not ask the user questions — decide autonomously. Do not chat about the task; just do it.
        5. You are a LEAF worker — never delegate further (no subagent.run/status/stop). Do everything yourself.
        6. To surface a URL to the user's UI, include a line `minis://open?url=<URL>` in your text — the app renders it
           as a tappable link card. Plain http(s) URLs in your text are auto-detected the same way.
        7. When finished, your final text must be a concise structured summary of what was done and the key result.
        8. SECURITY: your tool set is restricted by design. Never use shell.exec (or any command alias such as
           `ta`) to invoke other tools or bypass your tool whitelist — call restricted capabilities through the
           tools actually provided to you, or conclude that you cannot do it. Do not attempt hook/injection/
           fake/install/keychain operations unless a tool for them was explicitly given to you.
        9. TASK PLANNING (long-task discipline): judge the task once at the start. If it needs ≥2 tool calls,
           a dependency chain, or an ambiguous goal — FIRST output a plain-text plan in your first narration:
           a line "📋 PLAN" followed by numbered steps (step / expected tool / completion criterion).
           Then execute step by step; update the plan as reality diverges (mark done, drop, or revise).
           For trivial single-step tasks skip the plan and just do it — never plan for planning's sake.
        """
        if !persona.systemPrompt.isEmpty {
            p += "\n\n" + persona.systemPrompt
        }
        if let wl = allowedTools, !wl.isEmpty {
            p += "\nTOOL WHITELIST (use ONLY these): \(wl.joined(separator: ", "))"
        } else {
            let names = persona.tools.sorted().joined(separator: ", ")
            p += "\nTools: \(names) (use these; others may exist in schema — stay within your allowed set)"
        }
        return p
    }

    /// fix73k：persona 白名单是原名（shell.exec），schema 用 apiName（shell_exec，
    /// 点/空格等非法字符→下划线）——原名直接匹配必失败 → 子代理工具集只剩无点号工具
    /// （artifact），shell-worker 看不到 shell.exec（用户实测"本会话仅暴露 artifact、
    /// skills.read"）。这里做 apiName 归一化：原名 → 同名 apiName 后精确+前缀双路匹配。
    private func apiSafe(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var s = name.components(separatedBy: allowed.inverted).joined(separator: "_")
        if s.isEmpty { s = "tool" }
        if s.first?.isNumber ?? false { s = "t_\(s)" }
        return s
    }

    /// 过滤后的工具 schema：身份默认集 ∪ 白名单（apiName 前缀匹配大工具）
    private func subAgentTools() -> [[String: Any]]? {
        var allowed = persona.tools
        if let wl = allowedTools, !wl.isEmpty {
            for w in wl { allowed.insert(w) }
        }
        let all = ToolRegistry.shared.enabledOpenAIToolSchema()
        var picked: [[String: Any]] = []
        for schema in all {
            guard let fn = schema["function"] as? [String: Any],
                  let n = fn["name"] as? String else { continue }
            // fix73j-审计 M-8：高危工具硬排除——白名单前缀/大工具名（如 "device"）会
            // 放行全家（device.fake/restore/keychain_wipe）。高危簇默认禁，除非白名单
            // 显式包含具体工具名（如 "hook.apply" 精确命中才放行）。
            if SubAgentPersonas.isHighRisk(n),
               !allowed.contains(n),
               !allowed.contains(where: { n == apiSafe($0) }) {
                continue
            }
            // 匹配：精确 apiName 或大工具名（如 "artifact" 匹配 "artifact.read"）
            let matched = allowed.contains(n)
                || allowed.contains { n.hasPrefix($0 + ".") }
                // fix73k：原名→apiName 归一化（shell.exec ↔ shell_exec）
                || allowed.contains { n == apiSafe($0) || n.hasPrefix(apiSafe($0) + "_") }
            if matched { picked.append(schema) }
        }
        return picked.isEmpty ? nil : picked
    }

    func run() {
        messages.append(ChatMessage(role: "system", content: systemPrompt()))
        messages.append(ChatMessage(role: "user", content: task.instruction))
        loop()
    }

    /// v7.4.0-fix73g：真 abort 在途 LLM 请求（OpenAIClient.cancel → activeTask.cancel()）。
    /// watchdog/stop/软超时经 manager 的 cancellers 调用；loop 内超时直接调用。
    /// 幂等：置空 client 后重复调用无害；cancel 后 completion 回调走 markSendReplied
    /// （已限 sent→replied）不会覆盖 aborted。
    func cancelInflight() {
        let c = client
        client = nil
        c?.cancel()
    }

    /// v7.4.0-fix73d：多轮中间折叠——对齐大厂子任务上下文管理（Claude Code subagent compaction /
    /// OpenMinis 子会话压缩）。子代理默认 12 轮、上限 30 轮，每轮 assistant+tool 结果全量累积，
    /// 后期请求 token 膨胀（浪费 + 可能超窗）。本地折叠（不做网络摘要——循环内加 summarize
    /// 请求会引入新失败点，且执行型任务的历史工具结果价值低）：保留 system + instruction +
    /// 最近 K 轮完整配对，更早轮次折叠成一条紧凑说明（含已执行工具名轨迹，供模型感知进度）。
    private func foldHistoryIfNeeded() {
        // fix73j-审计：去掉"只折叠一次"限制——30 轮长任务折叠后继续累积（每轮
        // 3 工具×8000 字符 ≈ 6k+ token/轮），10 轮后再次超窗 → 超窗口失败。
        // 改为可重复折叠：每次保留 system+instruction+最近 6 轮完整配对，
        // 更早轮次（含上次折叠说明）折成一条紧凑说明。稳定态 ≈ 6 轮 + notes。
        let est = messages.reduce(0) { $0 + ConversationStore.estimateTokens($1) }
        // 阈值 6000 token ≈ 常见窗口(8k-32k)的一半；超过才折，折完骤降
        guard est > 6000 else { return }
        guard messages.count > 6 else { return }  // system+instruction+至少几轮才值得折
        // 从尾部保留最近 K 轮完整配对（assistant tool_calls ↔ tool 结果不能拆散——sanitize 语义）
        let keepTail = 6
        var keepStart = messages.count
        var keptRounds = 0
        var i = messages.count - 1
        while i >= 0 && keptRounds < keepTail {
            if messages[i].role == "tool" {
                keptRounds += 1
            }
            i -= 1
        }
        keepStart = i + 1
        // fix73d 审计：keepStart 若正好落在 tool 消息上，它的配对 assistant(tool_calls) 会留在折叠段
        // → 保留段出现孤儿 tool（无前导 tool_calls），API 校验/模型理解都会出问题。
        // fix73j-审计 M-11：不只退一位——多工具批（assistant 带 N 个 toolCalls + N 条 tool 结果）
        // 边界落在批内第 2+ 个 tool 时退一位仍在该批内。退到最近一个 assistant(tool_calls)
        // （批起点），保证保留段从完整配对开始。
        if keepStart < messages.count, messages[keepStart].role == "tool", keepStart > 2 {
            var p = keepStart
            while p > 2, messages[p - 1].role != "assistant" { p -= 1 }
            if p > 2 { keepStart = p - 1 }
        }
        // 折叠段：从 index 1（instruction 之后）到 keepStart 之前——只折"轮次消息"，
        // 绝不折 system(0) 与 instruction(1)（那是任务的根，丢了任务就废了）
        var folded: [ChatMessage] = []
        var foldCount = 0
        if keepStart > 2 {
            folded = Array(messages[2..<keepStart])
            foldCount = folded.count
        }
        guard foldCount > 0 else { return }
        // fix73k：归档被折叠段到完整轨迹（详情页回放用）——折叠只压缩模型上下文，
        // 完整执行历史不丢；重复折叠时归档段不重叠（每次归档的是上次 fold 后保留的轮次）。
        fullTrace.append(contentsOf: folded)
        // 折叠说明：列出被折轮次用过的工具名（来自消息里的 tool 角色 title/name，简化取 role==tool 的 toolName）
        var used = Set<String>()
        for m in folded where m.role == "tool" {
            if let name = m.toolName, !name.isEmpty { used.insert(name) }
        }
        let toolsLine = used.isEmpty ? "various tools" : used.sorted().joined(separator: ", ")
        let foldNote = ChatMessage(role: "user", content:
            "[HISTORY FOLDED — \(foldCount) earlier tool-round messages summarized away to save context. " +
            "Completed so far (tools used): \(toolsLine). Key findings persist in the later rounds below; " +
            "continue the task; your final summary must still cover the whole task including folded work.]")
        messages = Array(messages[..<2]) + [foldNote] + Array(messages[keepStart...])
    }

    private func loop() {
        subagentDiag("LOOP: task=\(task.id) round=\(task.rounds + 1)/\(maxRounds) remaining=\(Int(deadline.timeIntervalSinceNow))s")
        // 停止检查（线程安全读取——stop 可能由工具线程随时触发）
        if !task.isRunning() { return }
        // v7.4.0-fix73d：多轮中间折叠（对齐大厂子任务 compaction）——在轮次预算/超时检查之后、
        // 请求组装之前执行，保证折叠结果进入本轮请求
        foldHistoryIfNeeded()
        // 超时
        if Date() > deadline {
            // v7.4.0-fix73g：先置 aborted + 真 cancel 在途请求，再标记失败——
            // 此前只 markFailed，LLM 请求在后台挂死、send_state 永久卡 sent。
            task.markSendAborted()
            cancelInflight()
            task.markFailed("timeout after \(Int(deadline.timeIntervalSince(task.createdAt)))s")
            return
        }
        // v7.1.107-P0: 轮次生命周期（对齐 OpenMinis 预算警告 + wrap-up）：
        // 剩 1 轮 → 收回工具，注入"写交付"（tools=nil 模型只能文本总结，不会再有 toolCalls）
        // 剩 2-3 轮 → 注入"还剩 N 轮"预警（工具仍可用，可行动而非墓碑）
        let roundsLeft = maxRounds - task.rounds
        if !wrapUpInjected {
            if roundsLeft <= 1 {
                wrapUpInjected = true
                messages.append(ChatMessage(role: "user", content: """
                ⏰ TURN BUDGET EXPIRED — you have NO tool rounds left. You must now produce your FINAL summary \
                as plain text (this turn has no tools). Write the deliverable: what you did, the key results, \
                and any files/paths involved. If you have not finished, state exactly what remains and what you \
                found so far — the delegating agent will read this text only.
                """))
            } else if roundsLeft <= 3, !turnWarningInjected {
                turnWarningInjected = true
                messages.append(ChatMessage(role: "user", content: """
                ⚠️ TURN BUDGET WARNING: you have \(roundsLeft - 1) tool rounds left (this one included you may still use tools).
                Finish what you are doing and plan for a concise final summary next — do not start long new work.
                """))
            }
        }
        // v7.1.107-P0: 轮次硬上限（wrap-up 轮发完总结即 done；若仍进入下一轮则失败）
        if task.rounds >= maxRounds {
            if wrapUpInjected {
                // wrap-up 轮应已产出文本；能走到这说明模型回了 toolCalls（工具已收回，理论不可达）
                task.markFailed("reached max rounds (\(maxRounds)) without a final summary")
            } else {
                task.markFailed("reached max rounds (\(maxRounds))")
            }
            return
        }
        // v7.1.107-P0: 消费 steer 方向修正（循环边界，作为子会话真实用户消息送达）
        let steers = SubAgentManager.shared.drainSteers(id: task.id)
        if !steers.isEmpty {
            let note = steers
                .map { "[Course correction from the delegating agent] \($0)" }
                .joined(separator: "\n")
            messages.append(ChatMessage(role: "user", content: note))
        }
        // 取当前模型配置（与主会话一致）
        let store = ModelStore.shared
        // fix73j-p4：任务级配置快照——首次取共享 config 值拷贝，任务内不受主会话
        // 中途降级/切换影响；子代理降级不写回共享（persistCompatLevel=false）。
        if taskConfig == nil {
            taskConfig = store.lastUsedConfigId
                .flatMap { id in store.configs.first { $0.id.uuidString == id } }
                ?? store.configs.first
        }
        guard let config = taskConfig else {
            task.markFailed("no model config available")
            return
        }
        let client = OpenAIClient(config)
        // fix73j-p4：子代理降级隔离——不写回共享 ModelConfig；任务级缓存起步避免重试降级链
        client.persistCompatLevel = false
        if let ov = compatOverride { client.compatOverride = ov }
        self.client = client
        // v7.4.0-fix73f-5：子代理请求短超时——默认 session 90s 对 timeout_secs=30 的任务
        // 太长（实测第一个请求挂住 30-90s、rounds=0 的根因）。压到任务剩余时间的合理比例：
        // 请求挂住 → 快速失败回调 markFailed，配合看门狗双保险，不再无限等待。
        let remaining = deadline.timeIntervalSinceNow
        client.requestTimeoutOverride = min(max(remaining * 0.4, 15), 45)
        // v7.1.107-P0: wrap-up 轮不传工具 schema → 模型只能文本总结
        let tools = wrapUpInjected ? nil : subAgentTools()
        // fix73j-P2：计划锚定——模型已输出 📋 PLAN 时，每轮把计划+进度检查点注入上下文
        // 末尾（system role 结尾合法，不污染 messages、不被折叠），对齐 Manus "把全局计划
        // 念到最近注意力区"防目标漂移；进度提示促使模型在事实变化时修订计划。
        var sendMessages = messages
        if let plan = planText, !plan.isEmpty {
            let anchor = """
            [PLAN ANCHOR — keep executing against this plan; revise it if the evidence no longer fits]
            \(plan)
            Progress: round \(task.rounds + 1)/\(maxRounds). If this plan is outdated, output a new "📋 PLAN" \
            with revised steps before the next tool call.
            """
            sendMessages.append(ChatMessage(role: "system", content: anchor))
        }
        task.markSendStarted()   // v7.4.0-fix73f-6：请求已发出——status 可见 send_state=sent
        subagentDiag("SEND: task=\(task.id) round=\(task.rounds + 1) tools=\(tools?.count ?? -1) reqTimeout=\(Int(client.requestTimeoutOverride ?? 0))s")
        client.send(messages: sendMessages, tools: tools) { [weak self] result in
            guard let self = self else { return }
            // v7.4.0-fix73f-6：收到响应（成功/失败都算）——send_state=replied
            self.task.markSendReplied()
            var failCode = 0
            if case .failure(let e) = result { failCode = (e as NSError).code }
            var okFlag = "false"
            if case .success = result { okFlag = "true" }
            subagentDiag("REPLY: task=\(self.task.id) round=\(self.task.rounds + 1) ok=\(okFlag) errCode=\(failCode)")
            // fix73j-p4：任务级降级缓存——本请求 settle 的兼容级别记入任务缓存，
            // 下一轮新 client 从缓存起步（不重试降级链），且不污染主会话 config。
            if let lv = self.client?.resolvedLevel { self.compatOverride = lv }
            // v7.4.0-fix73f-4：看门狗已中断（markFailed）后，迟到的回调不得覆盖状态——
            // 否则超时任务会"复活"成 done（用户实测超时后仍 running 的同类竞态）。
            guard self.task.isRunning() else { return }
            switch result {
            case .success(let cr):
                switch cr {
                case .text(let text, _):
                    // fix73j-P2：首轮模型若只输出 📋 PLAN 计划（按纪律第 9 条"先规划再执行"）
                    // 而无工具调用——绝不能当最终总结 markDone（否则"规划即结束"回归）。
                    // 提取计划为锚定源，计一轮后继续 loop，下一轮带工具按计划执行。
                    if self.planText == nil, let r = text.range(of: "📋 PLAN") {
                        self.planText = String(text[r.lowerBound...].prefix(900))
                        self.task.addRound(tools: [])
                        self.loop()
                        return
                    }
                    self.task.markDone(result: text)
                case .toolCalls(let calls, _, let content):
                    self.execute(calls: calls, narration: content)
                }
            case .failure(let err):
                let nsErr = err as NSError
                // v7.4.0-fix73d：后台挂起优先判定——窗口耗尽冻结导致请求失败 ≠ 任务真实失败。
                // 主代理看到 interrupted 应重新派发（长任务可能已白跑，但状态语义准确、不误报 failed）。
                if self.task.isBackgroundSuspended() {
                    self.task.markInterrupted()
                } else if nsErr.code == -999 {
                    self.task.markStopped()
                } else {
                    self.task.markFailed(String(err.localizedDescription.prefix(200)))
                }
            }
        }
    }

    /// 执行工具（fix73j：单轮并发 ≤3 + 结果按 calls 原序回填）。
    /// v7.4.1 前为纯串行；现对齐主会话 processToolCallsParallel 的波次并发思想：
    /// DispatchSemaphore(3) 限制在途，DispatchGroup 等待全部完成，结果按 index 原序合并
    /// （Anthropic/OpenAI API 要求 tool 结果顺序镜像 tool_calls 顺序——乱序会 400）。
    private func execute(calls: [ToolCall], narration: String? = nil) {
        subagentDiag("TOOLS: task=\(task.id) round=\(task.rounds + 1) calls=\(calls.map { $0.name }.joined(separator: ","))")
        // fix73j-P2：提取模型首轮输出的 📋 PLAN 段（纪律第 9 条）——作为计划锚定源，
        // 之后每轮注入上下文末尾（send 层，不污染 messages）。
        if planText == nil, let n = narration, let r = n.range(of: "📋 PLAN") {
            planText = String(n[r.lowerBound...].prefix(900))
        }
        var msgs = messages
        var executed: [String] = []
        // 关键：API 要求 tool 结果必须跟在"带 tool_calls 的 assistant 消息"之后——
        // 先追加 assistant 消息挂上 toolCalls（content 用模型解说或空串，与主循环一致），
        // 否则 "tool" role message must follow a message with tool_calls → 400。
        msgs.append(ChatMessage(role: "assistant", content: narration ?? "", toolCalls: calls))
        // 1) 熔断检查（顺序执行——lastTool/sameToolRepeat 状态是顺序语义）+ 收集待执行 index
        var loopBlocked: [Int] = []
        for (i, call) in calls.enumerated() {
            if call.name == lastTool {
                sameToolRepeat += 1
                if sameToolRepeat >= 3 {
                    loopBlocked.append(i)
                    continue
                }
            } else {
                lastTool = call.name
                sameToolRepeat = 1
            }
        }
        // 2) 并发执行（fix73j-p5e：每个子代理独立并发槽，一次最多 4 个命令在途），结果按 index 收集
        var results: [Int: ChatMessage] = [:]
        let resultsLock = NSLock()
        let semaphore = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        let indices = calls.indices.filter { !loopBlocked.contains($0) }
        for i in indices {
            let call = calls[i]
            // fix73j-p5c：group.enter() 必须在提交前——旧代码 enter 在 semaphore.wait() 之后
            //（闭包内），主流程 group.wait() 时若任务尚未被调度执行（系统繁忙/磁盘满/低电量
            // 时 global 队列调度延迟），group 计数=0 → wait 立即返回 → results 全空 →
            // 全部落 "concurrent slot lost" 兜底（用户实测：子代理工具调用全失败，串行单跑
            // 也一样）。enter 提前后 group.wait() 必定等待所有任务（含等槽任务）。
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                defer { semaphore.signal(); group.leave() }
                let params = Self.parseArgs(call.arguments)
                let msg: ChatMessage
                do {
                    let r = try ToolRegistry.shared.dispatch(name: call.name, params: params)
                    var content = Self.json(r)
                    if content.count > 8000 {
                        content = content.prefix(8000) + "\n... [tool result truncated, total \(content.count) chars]"
                    }
                    var m = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name)
                    m.toolArgs = Self.summarizeArgs(call.arguments)
                    msg = m
                } catch {
                    var m = ChatMessage(role: "tool", content: Self.json(["ok": false, "message": String(describing: error)]),
                                        isError: true, toolCallId: call.id, toolName: call.name)
                    m.toolArgs = Self.summarizeArgs(call.arguments)
                    msg = m
                }
                resultsLock.lock()
                results[i] = msg
                resultsLock.unlock()
            }
        }
        group.wait()
        // 3) 按原序合并（熔断消息 + 执行结果，顺序镜像 calls）
        for (i, call) in calls.enumerated() {
            if loopBlocked.contains(i) {
                let body: [String: Any] = [
                    "ok": false,
                    "message": "🚫 LOOP BLOCKED: You've called \(call.name) \(sameToolRepeat) times with the same pattern and it keeps repeating. STOP. Try a completely different approach or conclude the task."
                ]
                var m = ChatMessage(role: "tool", content: Self.json(body), isError: true,
                                    toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            } else if let m = results[i] {
                msgs.append(m)
            } else {
                // fix73j-审计 M-4：results[i] 缺失（并发闭包未及执行/异常路径）时兜底——
                // 静默丢条会让 tool_calls 消息缺对应 tool 结果 → API 400（序列非法）。
                var m = ChatMessage(role: "tool",
                                    content: Self.json(["ok": false, "message": "tool execution did not produce a result (concurrent slot lost)"]),
                                    isError: true, toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            }
            executed.append(call.name)
        }
        task.addRound(tools: executed)
        messages = msgs
        // fix73j-p5f/p5g：实时轨迹落盘——每轮结束覆盖写 SQLite（运行中详情页实时可见；
        // 重启后失效页回看失效前轨迹）；rounds 同步更新。
        // fix73k：改后台异步 fire-and-forget——此前同步写卡住 execute → 循环停 →
        // 任务 running（磁盘满/WAL checkpoint 失败时全量覆盖写放大，写几秒到几十秒）；
        // 异步后写盘慢/失败不影响子代理执行，busy_timeout 2s + 事务化兜底不卡。
        let snap = messages.prefix(200).map { m in
            ["role": m.role, "content": String(m.content.prefix(2000)), "tool": m.toolName ?? ""]
        }
        let rds = task.rounds
        let tid = task.id
        DispatchQueue.global(qos: .utility).async {
            SubAgentTask.persistTrace(id: tid, trace: snap)
            SubAgentStore.shared.touchTask(taskID: tid, rounds: rds)
        }
        loop()
    }

    /// fix73j：当前消息快照（终态时由 manager 取，存 task.trace 供详情页回看）
    /// fix73k：完整轨迹——system+instruction + 全部被折叠轮次（fullTrace）+ 当前保留轮次。
    /// 折叠只影响模型请求上下文；详情页回放用完整版（对齐 DSH append-only 事件流）。
    func snapshotMessages() -> [ChatMessage] {
        guard !fullTrace.isEmpty else { return messages }
        let head = Array(messages.prefix(2))          // system + instruction
        let tail = Array(messages.dropFirst(2))       // foldNote + 最近 K 轮
        return head + fullTrace + tail
    }

    // MARK: - 工具小工具
    private static func parseArgs(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func summarizeArgs(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let entries = o.prefix(2).map { k, v -> String in
            let val = "\(v)"
            return "\(k): \(val.count > 50 ? String(val.prefix(50)) + "..." : val)"
        }
        return entries.isEmpty ? nil : entries.joined(separator: ", ")
    }
}

// MARK: - 子代理工具注册（subagent.run / subagent.status / subagent.stop）

final class SubAgentRunTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.run",
        summary: "Delegate a self-contained task to an isolated subagent that runs its own tool loop in a separate context (won't pollute the main conversation). Use for: long multi-step dirty work — batch file analysis, multi-file audits, repetitive processing, web research chains. Don't use for: quick single calls (call the tool directly). Params: instruction(required), agent_type(optional persona: web-researcher/app-auditor/shell-worker/general, default general — pick by task semantics), tools(optional comma-separated whitelist), max_rounds(optional default 12 max 30), timeout_secs(optional default 180 max 600). Up to 4 subagents can run concurrently; completion is pushed back to the main conversation as a tappable card. After dispatching several subagents, call subagent.wait_all (task_ids=...) to block until they all finish, then synthesize their consolidated results — do NOT summarize from partial results while any subagent is still running. Returns task_id immediately (async); poll with subagent.status until status=done, stop with subagent.stop if it misbehaves.",
        parameters: [
            "instruction": "The complete task to execute (required). Be specific about the goal, inputs, and expected output format.",
            "agent_type": "Optional subagent persona: web-researcher (multi-source web research, cite URLs), app-auditor (read-only app reverse/audit: decrypt/entitlements/symbols/deps/cache), shell-worker (batch file/script dirty work), general (default all-round). Pick the persona matching the task; default general.",
            "tools": "Optional comma-separated tool whitelist ADDED to the persona's default set (e.g. 'shell.exec,artifact'). High-risk tools (hook.apply/injection.mem/device.fake/keychain_wipe/system.exec_root/app.install/app.uninstall/control.inject) are denied unless explicitly listed here.",
            "max_rounds": "Optional max tool rounds (default 12, max 30)",
            "timeout_secs": "Optional timeout seconds (default 180, max 600)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["instruction"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("instruction required")
        }
        // 指令截断（对齐 OpenMinis 子会话指令 4000 字上限的防护精神）
        let instruction = raw.count > 8000 ? String(raw.prefix(8000)) + "\n... [instruction truncated]" : raw
        let agentType = params["agent_type"] as? String
        let persona = SubAgentPersonas.find(agentType)
        let wl = (params["tools"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 宽松解析：模型可能传字符串数字（"12"）——Int/Double 都兼容
        let rounds: Int = {
            if let i = params["max_rounds"] as? Int { return i }
            if let s = params["max_rounds"] as? String, let i = Int(s) { return i }
            return persona.defaultRounds
        }()
        let timeout: TimeInterval = {
            if let d = params["timeout_secs"] as? Double { return d }
            if let i = params["timeout_secs"] as? Int { return Double(i) }
            if let s = params["timeout_secs"] as? String, let d = Double(s) { return d }
            return persona.defaultTimeout
        }()
        // fix73j：记录派发时的会话 id——回传写回该会话（用户切换会话不污染）
        let sessionID = ConversationStore.shared.currentSessionID()
        let id = try SubAgentManager.shared.start(instruction: instruction, allowedTools: wl,
                                                  maxRounds: rounds, timeout: timeout,
                                                  personaName: persona.name, sessionID: sessionID)
        // fix73j-p5h：displayName 由 start 内部分配（task.displayName），此处查回供 RUNNING 卡显示
        let displayName = SubAgentManager.shared.displayNameFor(id: id) ?? id
        // fix73j：主界面立即可见"执行中"卡（派发即上屏，完成时再补 [SUBAGENT-DONE] 完成卡）
        let runningBody: [String: Any] = [
            "ok": true, "task_id": id, "display_name": displayName,
            "agent_type": persona.name, "status": "running", "rounds": 0,
        ]
        let runningContent = "[SUBAGENT-RUNNING] "
            + ((try? String(data: JSONSerialization.data(withJSONObject: runningBody), encoding: .utf8)) ?? "")
        DispatchQueue.main.async {
            var m = ChatMessage(role: "user", content: runningContent)
            m.toolTitle = "子代理 \(displayName) · \(persona.name) \(SubAgentStatusText.zh("running"))"
            m.toolName = "subagent.running"
            if let sid = sessionID {
                ConversationStore.shared.appendToSession(id: sid, message: m, generateTitle: false)
            } else {
                ConversationStore.shared.appendToCurrent(m)
            }
        }
        return ["ok": true, "task_id": id, "agent_type": persona.name,
                "message": "subagent \(id) (\(persona.name)) started. Poll with subagent.status task_id=\(id); steer with subagent.steer task_id=\(id); stop with subagent.stop task_id=\(id). Completion is pushed back as a card in the conversation."]
    }
}

final class SubAgentStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.status",
        summary: "Check the status of a running/finished subagent task. Use for: polling after subagent.run (loop: status → if still running, continue polling with short delay). Returns status (running/done/failed/stopped), rounds, tool_trace, and the final result when done.",
        parameters: [
            "task_id": "The subagent task id returned by subagent.run (required)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["task_id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParams("task_id required")
        }
        guard let task = SubAgentManager.shared.status(id: id) else {
            return ["ok": false, "message": "no subagent task with id \(id)"]
        }
        var d = task.toDict()
        d["ok"] = true
        return d
    }
}

final class SubAgentStopTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.stop",
        summary: "Stop a running subagent task immediately (marks it stopped; in-flight tool call may finish but no further rounds run). Use for: subagent misbehaving, looping, or the task is no longer needed.",
        parameters: [
            "task_id": "The subagent task id returned by subagent.run (required)",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["task_id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParams("task_id required")
        }
        if SubAgentManager.shared.stop(id: id) {
            return ["ok": true, "task_id": id, "status": "stopped"]
        }
        return ["ok": false, "message": "task \(id) not running (already finished/stopped or unknown id)"]
    }
}

/// fix73j：阻塞等待所有指定子代理完成并返回汇总——主 agent 派发多个子代理后
/// 用此工具同步等待，避免"还有子代理在跑就提前总结"（用户需求：主会话等齐
/// 所有子代理结果再统一总结）。轮询由本工具实现，不依赖主 agent 轮询纪律。
final class SubAgentWaitAllTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.wait_all",
        summary: "Block until all specified subagent tasks reach a terminal state, then return a consolidated summary of every result. Use for: after dispatching multiple subagents, when the main agent needs ALL their results to synthesize a final answer — call this INSTEAD of summarizing from partial results. Params: task_ids(optional comma-separated; omit = wait for ALL currently running subagents), timeout_secs(optional default 180, max 600). Returns each task's status/rounds/elapsed/result-or-error; tasks still running when the timeout hits are reported with status=running so you can decide whether to keep waiting or summarize partial results.",
        parameters: [
            "task_ids": "Optional comma-separated task ids to wait for (e.g. 'ABCD1234,EFGH5678'). Omit to wait for all currently running subagents.",
            "timeout_secs": "Optional max wait seconds (default 180, max 600).",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // 解析 task_ids（省略 = 等待全部 running）
        var ids: [String]
        if let raw = params["task_ids"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            ids = SubAgentManager.shared.allRunningTaskIDs()
        }
        guard !ids.isEmpty else {
            return ["ok": true, "all_complete": true, "subagents": [],
                    "message": "no subagent tasks to wait for"]
        }
        let timeout: TimeInterval = {
            if let d = params["timeout_secs"] as? Double { return d }
            if let i = params["timeout_secs"] as? Int { return Double(i) }
            if let s = params["timeout_secs"] as? String, let d = Double(s) { return d }
            return 180
        }()
        let clamped = max(5, min(timeout, 600))
        let deadline = Date().addingTimeInterval(clamped)
        let start = Date()
        var summaries: [[String: Any]] = []
        var allComplete = false
        while Date() < deadline {
            let tasks = ids.compactMap { SubAgentManager.shared.status(id: $0) }
            summaries = tasks.map { $0.toDict() }
            if tasks.isEmpty { allComplete = true; break }
            allComplete = tasks.allSatisfy { !$0.isRunning() }
            if allComplete { break }
            Thread.sleep(forTimeInterval: 3)
        }
        let waited = Int(Date().timeIntervalSince(start))
        let stillRunning = summaries.filter { ($0["status"] as? String) == "running" }
        var result: [String: Any] = [
            "ok": true,
            "waited_secs": waited,
            "all_complete": allComplete,
            "subagents": summaries,
        ]
        if !stillRunning.isEmpty {
            result["message"] = "\(stillRunning.count) subagent(s) still running after \(waited)s — call subagent.wait_all again to keep waiting, or summarize the partial results."
        }
        return result
    }
}

/// v7.1.107-P0: subagent.steer——父模型运行中给子代理注入方向修正
/// （对齐 OpenMinis pendingSteerMessages：循环边界以子会话真实用户消息送达）
final class SubAgentSteerTool: MCPTool {
    let definition = ToolDefinition(
        name: "subagent.steer",
        summary: "Send a mid-run course correction to a RUNNING subagent (appended to its transcript as a user message; it takes effect at the next loop boundary). Use for: the subagent went in the wrong direction, you learned new info, or you want to change its output format mid-task. Does NOT stop it. Returns ok=false if the task is not running.",
        parameters: [
            "task_id": "The subagent task id returned by subagent.run (required)",
            "instruction": "The new direction/instruction to inject (required). Be specific: what to change, what to keep, output format.",
        ],
        verified: true, category: "system")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let id = params["task_id"] as? String, !id.isEmpty else {
            throw MCPError.invalidParams("task_id required")
        }
        guard let instruction = params["instruction"] as? String,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("instruction required")
        }
        if SubAgentManager.shared.steer(id: id, instruction: instruction) {
            return ["ok": true, "task_id": id, "message": "steer queued for \(id) (takes effect at next loop boundary)"]
        }
        return ["ok": false, "message": "task \(id) not running (already finished/stopped or unknown id)"]
    }
}

// MARK: - 子代理独立 SQLite 存储（fix73j-p5g）
/// 独立库 subagent_index.sqlite——与主会话 session_index.sqlite 完全分离；
/// subagent_tasks.session_id 关联主会话 UUID（派发时记录，支持按会话回溯）。
/// 线程安全：FULLMUTEX + 单连接串行锁（runner 后台线程写、详情页主线程读）。
final class SubAgentStore {
    static let shared = SubAgentStore()
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = NSHomeDirectory().appending("/Documents/Workspace/store")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/subagent_index.sqlite"
        let walPath = path + "-wal"
        let shmPath = path + "-shm"
        // fix73k：孤儿 WAL/SHM 清理——主文件被删/损坏但 -wal/-shm 残留时，SQLite 打开
        // 新主文件会触发 WAL recovery，残留与文件不匹配 → recovery 挂起 → 后续
        // sqlite3_step 永久卡（用户实测"删 db 后子代理卡住"的候选根因）。主文件不存在
        // 但有 -wal/-shm = 残留，先删再 open，杜绝 recovery 卡死路径。
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: walPath)
            try? FileManager.default.removeItem(atPath: shmPath)
        }
        var h: OpaquePointer?
        func openDB() -> Bool {
            sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        }
        if openDB() {
            db = h
            // fix73k：损坏检测——quick_check 非 "ok" → 关闭删除重建（防损坏库后续
            // step 挂起/读错数据；小库每次启动毫秒级，可接受）。
            var healthy = true
            var check: OpaquePointer?
            if sqlite3_prepare_v2(h, "PRAGMA quick_check;", -1, &check, nil) == SQLITE_OK {
                if sqlite3_step(check) == SQLITE_ROW, let r = sqlite3_column_text(check, 0) {
                    healthy = (String(cString: r) == "ok")
                }
                sqlite3_finalize(check)
            }
            if !healthy {
                sqlite3_close(h)
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: walPath)
                try? FileManager.default.removeItem(atPath: shmPath)
                h = nil; db = nil
                if openDB() { db = h }
            }
        }
        guard let db else { return }
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            let schema = """
            CREATE TABLE IF NOT EXISTS subagent_tasks (
                task_id TEXT PRIMARY KEY,
                session_id TEXT,
                agent_type TEXT,
                status TEXT,
                rounds INTEGER DEFAULT 0,
                max_rounds INTEGER DEFAULT 0,
                elapsed_secs REAL DEFAULT 0,
                result TEXT DEFAULT '',
                error TEXT DEFAULT '',
                created_at TEXT,
                updated_at TEXT,
                finished_at TEXT
            );
            CREATE TABLE IF NOT EXISTS subagent_traces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT,
                seq INTEGER,
                role TEXT,
                content TEXT,
                tool TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_sub_traces_task ON subagent_traces(task_id);
            CREATE INDEX IF NOT EXISTS idx_sub_tasks_session ON subagent_tasks(session_id);
            """
            _ = sqlite3_exec(db, schema, nil, nil, nil)
            // fix73k-p3g：busy_timeout 2s——磁盘满/锁竞争时写事务最多等 2s 立即返回失败，
            // 不再无限阻塞（此前 insertTask/finalizeTask 同步写卡住 → subagent_run dispatch
            // 不返回 → 主会话占位卡永远空 → 杀后台重启 CRASH-REWRITE 误判失败）。
            sqlite3_busy_timeout(h, 2000)
    }
    deinit { if let db { sqlite3_close(db) } }

    private func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// 派发时建行（status=running，记录关联主会话 id）
    func insertTask(taskID: String, sessionID: String?, agentType: String, maxRounds: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO subagent_tasks (task_id,session_id,agent_type,status,rounds,max_rounds,created_at,updated_at) VALUES (?1,?2,?3,'running',0,?4,?5,?5)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
        if let sid = sessionID {
            sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, transient)
        } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_text(stmt, 3, (agentType as NSString).utf8String, -1, transient)
        sqlite3_bind_int(stmt, 4, Int32(maxRounds))
        sqlite3_bind_text(stmt, 5, (nowISO() as NSString).utf8String, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// 每轮结束更新 rounds（实时进度）
    func touchTask(taskID: String, rounds: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        let sql = "UPDATE subagent_tasks SET rounds=?2, updated_at=?3 WHERE task_id=?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(rounds))
        sqlite3_bind_text(stmt, 3, (nowISO() as NSString).utf8String, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// 终态写入（status/result/error/elapsed/finished_at）
    func finalizeTask(taskID: String, status: String, rounds: Int, elapsed: TimeInterval,
                      result: String, error: String) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        let sql = "UPDATE subagent_tasks SET status=?2, rounds=?3, elapsed_secs=?4, result=?5, error=?6, finished_at=?7, updated_at=?7 WHERE task_id=?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 2, (status as NSString).utf8String, -1, transient)
        sqlite3_bind_int(stmt, 3, Int32(rounds))
        sqlite3_bind_double(stmt, 4, elapsed)
        sqlite3_bind_text(stmt, 5, (result as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 6, (error as NSString).utf8String, -1, transient)
        sqlite3_bind_text(stmt, 7, (nowISO() as NSString).utf8String, -1, transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// 覆盖式写轨迹（保持当前快照语义，防无限增长）
    /// fix73k：单事务包裹（BEGIN IMMEDIATE → DELETE+逐行 INSERT → COMMIT）——
    /// 此前每行自动提交（无事务），WAL 膨胀快 + 磁盘满时 checkpoint 失败写放大；
    /// 事务化后写放大降一个数量级，busy_timeout 2s 保证写失败快速静默（不卡）。
    func replaceTraces(taskID: String, trace: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM subagent_traces WHERE task_id=?1", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, (taskID as NSString).utf8String, -1, transient)
            sqlite3_step(del)
            sqlite3_finalize(del)
        }
        for (i, e) in trace.enumerated() {
            let role = e["role"] as? String ?? ""
            let content = e["content"] as? String ?? ""
            let tool = e["tool"] as? String ?? ""
            let sql = "INSERT INTO subagent_traces (task_id,seq,role,content,tool) VALUES (?1,?2,?3,?4,?5)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
            sqlite3_bind_int(stmt, 2, Int32(i))
            sqlite3_bind_text(stmt, 3, (role as NSString).utf8String, -1, transient)
            sqlite3_bind_text(stmt, 4, (content as NSString).utf8String, -1, transient)
            sqlite3_bind_text(stmt, 5, (tool as NSString).utf8String, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func loadTraces(taskID: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        var out: [[String: Any]] = []
        let sql = "SELECT role,content,tool FROM subagent_traces WHERE task_id=?1 ORDER BY seq"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let role = String(cString: sqlite3_column_text(stmt, 0))
            let content = String(cString: sqlite3_column_text(stmt, 1))
            let tool = String(cString: sqlite3_column_text(stmt, 2))
            out.append(["role": role, "content": content, "tool": tool])
        }
        sqlite3_finalize(stmt)
        return out
    }

    func loadTask(taskID: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return nil }
        let sql = "SELECT session_id,agent_type,status,rounds,max_rounds,elapsed_secs,result,error,created_at,finished_at FROM subagent_tasks WHERE task_id=?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (taskID as NSString).utf8String, -1, transient)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var d: [String: Any] = [:]
        if sqlite3_column_type(stmt, 0) != SQLITE_NULL { d["session_id"] = String(cString: sqlite3_column_text(stmt, 0)) }
        if sqlite3_column_type(stmt, 1) != SQLITE_NULL { d["agent_type"] = String(cString: sqlite3_column_text(stmt, 1)) }
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL { d["status"] = String(cString: sqlite3_column_text(stmt, 2)) }
        d["rounds"] = Int(sqlite3_column_int(stmt, 3))
        d["max_rounds"] = Int(sqlite3_column_int(stmt, 4))
        d["elapsed_secs"] = sqlite3_column_double(stmt, 5)
        if sqlite3_column_type(stmt, 6) != SQLITE_NULL { d["result"] = String(cString: sqlite3_column_text(stmt, 6)) }
        if sqlite3_column_type(stmt, 7) != SQLITE_NULL { d["error"] = String(cString: sqlite3_column_text(stmt, 7)) }
        if sqlite3_column_type(stmt, 8) != SQLITE_NULL { d["created_at"] = String(cString: sqlite3_column_text(stmt, 8)) }
        if sqlite3_column_type(stmt, 9) != SQLITE_NULL { d["finished_at"] = String(cString: sqlite3_column_text(stmt, 9)) }
        return d
    }
}
