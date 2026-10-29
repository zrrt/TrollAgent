import Foundation

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

    enum Status: String { case running, done, failed, stopped, interrupted }

    init(id: String, instruction: String, maxRounds: Int, timeoutSecs: TimeInterval) {
        self.id = id
        self.instruction = instruction
        self.maxRounds = maxRounds
        self.timeoutSecs = timeoutSecs
        self.status = .running
        self.createdAt = Date()
        self.rounds = 0
        self.toolTrace = []
        self.result = ""
        self.error = ""
        self.elapsed = 0
    }

    func markDone(result: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        status = .done
        // 防结果撑爆主线：截断到 4000 字符（子代理最终总结应简短，超长说明模型把工具输出写进了总结）
        self.result = result.count > 4000 ? String(result.prefix(4000)) + "\n... [result truncated]" : result
        // v7.1.107-P0: 空总结 = 无交付——父模型拿到后知道要去子代理轨迹里挖结果
        noDeliverable = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        elapsed = Date().timeIntervalSince(createdAt)
    }

    func markFailed(_ err: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        status = .failed
        error = err
        elapsed = Date().timeIntervalSince(createdAt)
    }

    func markStopped() {
        stateLock.lock(); defer { stateLock.unlock() }
        status = .stopped
        elapsed = Date().timeIntervalSince(createdAt)
    }

    /// v7.4.0-fix73d：后台挂起中断——区别于 failed（误报）与 stopped（用户手动），
    /// 语义 = "app 切后台窗口耗尽，请求被冻结中断"，父模型应重新派发而非诊断失败。
    func markInterrupted() {
        stateLock.lock(); defer { stateLock.unlock() }
        status = .interrupted
        error = "interrupted by app backgrounding (background window expired) — re-dispatch to resume"
        elapsed = Date().timeIntervalSince(createdAt)
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
    private var activeTaskID: String?
    /// v7.1.107-P0: steer 方向修正队列——父模型可运行中给子代理注入新指令，
    /// 在循环边界以"用户消息"送达（对齐 OpenMinis pendingSteerMessages 语义）
    private var pendingSteers: [String: [String]] = [:]
    private let lock = NSLock()

    /// 启动子代理。成功返回 task_id；已有任务在跑则 throw（模型应轮询/停止旧任务）。
    /// v7.1.108-fix: Result<String,String> 改为 throws——Swift 要求 Result.Failure: Error，
    /// String 不满足协议，这是子代理系列构建失败的根因。
    func start(instruction: String, allowedTools: [String]?,
               maxRounds: Int, timeout: TimeInterval) throws -> String {
        lock.lock()
        if let active = activeTaskID {
            lock.unlock()
            throw MCPError.failed("已有子代理 \(active) 在运行。先 subagent.status 等待它完成，或 subagent.stop 停止后再委派新任务。")
        }
        let id = String(UUID().uuidString.prefix(8))
        let clampedRounds = max(2, min(maxRounds, 30))
        let clampedTimeout = max(30, min(timeout, 600))
        let task = SubAgentTask(id: id, instruction: instruction,
                                maxRounds: clampedRounds, timeoutSecs: clampedTimeout)
        tasks[id] = task
        activeTaskID = id
        lock.unlock()

        let runner = SubAgentRunner(task: task, allowedTools: allowedTools,
                                    maxRounds: clampedRounds, timeout: clampedTimeout)
        DispatchQueue.global(qos: .userInitiated).async {
            runner.run()
            self.lock.lock()
            if self.activeTaskID == id { self.activeTaskID = nil }
            self.lock.unlock()
        }
        // v7.4.0-fix73f-4：超时看门狗——loop() 的超时检查只在"发出请求前"执行，
        // 请求异步挂住（网络卡死/上游无响应/回调丢失）时回调不来 → loop 不再被驱动 →
        // 超时检查永不触发 → 任务永远 running（用户真机实测 timeout_secs=30 但 101s
        // 仍 running、rounds=0、tool_trace=[] 的根因）。
        // 看门狗独立于请求回调：deadline 到时强制中断，真正兑现超时语义。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + clampedTimeout + 5) {
            if let t = self.tasks[id], t.isRunning() {
                t.markFailed("timeout after \(Int(clampedTimeout))s (watchdog — request hung without callback; in-flight tool call may still finish but the task is terminated)")
                self.lock.lock()
                if self.activeTaskID == id { self.activeTaskID = nil }
                self.lock.unlock()
            }
        }
        return id
    }

    func status(id: String) -> SubAgentTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]
    }

    func stop(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tasks[id], t.isRunning() else { return false }
        t.markStopped()
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
}

// MARK: - 子代理执行循环（隔离会话 + 工具循环，独立于主 runLoop，不碰主线状态）

final class SubAgentRunner {
    private let task: SubAgentTask
    private let allowedTools: [String]?
    private let maxRounds: Int
    private let deadline: Date
    private var messages: [ChatMessage] = []
    private var client: OpenAIClient?
    private var lastTool = ""
    private var sameToolRepeat = 0
    /// v7.1.107-P0: 轮次预警已注入（剩 2-3 轮时，工具仍可用）
    private var turnWarningInjected = false
    /// v7.1.107-P0: wrap-up 已注入（最后一轮收回工具，强制写交付总结）
    private var wrapUpInjected = false
    /// v7.4.0-fix73d：历史折叠已执行（只折叠一次——折叠后 token 骤降，重复触发无意义）
    private var historyFolded = false

    /// 子代理默认工具集——通用干活三件套 + 只读信息工具（全量 schema 太大，注入精简集）
    private let defaultTools: Set<String> = [
        "shell.exec", "artifact", "device", "web.search", "web.fetch", "skills.read"
    ]

    init(task: SubAgentTask, allowedTools: [String]?, maxRounds: Int, timeout: TimeInterval) {
        self.task = task
        self.allowedTools = allowedTools
        self.maxRounds = max(2, min(maxRounds, 30))
        self.deadline = Date().addingTimeInterval(max(30, min(timeout, 600)))
    }

    /// 子代理系统提示词——精简版执行纪律（不承诺收尾/结构化调用/自主决策）
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
        """
        if let wl = allowedTools, !wl.isEmpty {
            p += "\nTOOL WHITELIST (use ONLY these): \(wl.joined(separator: ", "))"
        } else {
            p += "\nTools: \(defaultTools.sorted().joined(separator: ", ")) (use these; others may exist in schema — stay within your allowed set)"
        }
        return p
    }

    /// 过滤后的工具 schema：默认集 ∪ 白名单（apiName 前缀匹配大工具）
    private func subAgentTools() -> [[String: Any]]? {
        var allowed = Set(defaultTools)
        if let wl = allowedTools, !wl.isEmpty {
            for w in wl { allowed.insert(w) }
        }
        let all = ToolRegistry.shared.enabledOpenAIToolSchema()
        var picked: [[String: Any]] = []
        for schema in all {
            guard let fn = schema["function"] as? [String: Any],
                  let n = fn["name"] as? String else { continue }
            // 匹配：精确 apiName 或大工具名（如 "artifact" 匹配 "artifact.read"）
            let matched = allowed.contains(n) || allowed.contains { n.hasPrefix($0 + ".") }
            if matched { picked.append(schema) }
        }
        return picked.isEmpty ? nil : picked
    }

    func run() {
        messages.append(ChatMessage(role: "system", content: systemPrompt()))
        messages.append(ChatMessage(role: "user", content: task.instruction))
        loop()
    }

    /// v7.4.0-fix73d：多轮中间折叠——对齐大厂子任务上下文管理（Claude Code subagent compaction /
    /// OpenMinis 子会话压缩）。子代理默认 12 轮、上限 30 轮，每轮 assistant+tool 结果全量累积，
    /// 后期请求 token 膨胀（浪费 + 可能超窗）。本地折叠（不做网络摘要——循环内加 summarize
    /// 请求会引入新失败点，且执行型任务的历史工具结果价值低）：保留 system + instruction +
    /// 最近 K 轮完整配对，更早轮次折叠成一条紧凑说明（含已执行工具名轨迹，供模型感知进度）。
    private func foldHistoryIfNeeded() {
        guard !historyFolded else { return }
        let est = messages.reduce(0) { $0 + ConversationStore.estimateTokens($1) }
        // 阈值 6000 token ≈ 常见窗口(8k-32k)的一半；折叠一次后骤降，无需再触发
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
        // → 保留段出现孤儿 tool（无前导 tool_calls），API 校验/模型理解都会出问题。前移一位纳入配对。
        if keepStart < messages.count, messages[keepStart].role == "tool", keepStart > 2 {
            keepStart -= 1
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
        historyFolded = true
    }

    private func loop() {
        // 停止检查（线程安全读取——stop 可能由工具线程随时触发）
        if !task.isRunning() { return }
        // v7.4.0-fix73d：多轮中间折叠（对齐大厂子任务 compaction）——在轮次预算/超时检查之后、
        // 请求组装之前执行，保证折叠结果进入本轮请求
        foldHistoryIfNeeded()
        // 超时
        if Date() > deadline {
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
        let config = store.lastUsedConfigId
            .flatMap { id in store.configs.first { $0.id.uuidString == id } }
            ?? store.configs.first
        guard let config else {
            task.markFailed("no model config available")
            return
        }
        let client = OpenAIClient(config)
        self.client = client
        // v7.4.0-fix73f-5：子代理请求短超时——默认 session 90s 对 timeout_secs=30 的任务
        // 太长（实测第一个请求挂住 30-90s、rounds=0 的根因）。压到任务剩余时间的合理比例：
        // 请求挂住 → 快速失败回调 markFailed，配合看门狗双保险，不再无限等待。
        let remaining = deadline.timeIntervalSinceNow
        client.requestTimeoutOverride = min(max(remaining * 0.4, 15), 45)
        // v7.1.107-P0: wrap-up 轮不传工具 schema → 模型只能文本总结
        let tools = wrapUpInjected ? nil : subAgentTools()
        client.send(messages: messages, tools: tools) { [weak self] result in
            guard let self = self else { return }
            // v7.4.0-fix73f-4：看门狗已中断（markFailed）后，迟到的回调不得覆盖状态——
            // 否则超时任务会"复活"成 done（用户实测超时后仍 running 的同类竞态）。
            guard self.task.isRunning() else { return }
            switch result {
            case .success(let cr):
                switch cr {
                case .text(let text, _):
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

    /// 逐条执行工具（子代理内串行——简单安全，不做并行），结果回填后继续循环
    private func execute(calls: [ToolCall], narration: String? = nil) {
        var msgs = messages
        var executed: [String] = []
        // 关键：API 要求 tool 结果必须跟在"带 tool_calls 的 assistant 消息"之后——
        // 先追加 assistant 消息挂上 toolCalls（content 用模型解说或空串，与主循环一致），
        // 否则 "tool" role message must follow a message with tool_calls → 400。
        msgs.append(ChatMessage(role: "assistant", content: narration ?? "", toolCalls: calls))
        for call in calls {
            // 同工具同参数重复 3 次熔断（防死循环，对齐 ToolLoopDetector 思想）
            if call.name == lastTool {
                sameToolRepeat += 1
                if sameToolRepeat >= 3 {
                    let body: [String: Any] = [
                        "ok": false,
                        "message": "🚫 LOOP BLOCKED: You've called \(call.name) \(sameToolRepeat) times with the same pattern and it keeps repeating. STOP. Try a completely different approach or conclude the task."
                    ]
                    var m = ChatMessage(role: "tool", content: Self.json(body), isError: true,
                                        toolCallId: call.id, toolName: call.name)
                    m.toolArgs = Self.summarizeArgs(call.arguments)
                    msgs.append(m)
                    continue
                }
            } else {
                lastTool = call.name
                sameToolRepeat = 1
            }
            // 执行工具
            let params = Self.parseArgs(call.arguments)
            do {
                let r = try ToolRegistry.shared.dispatch(name: call.name, params: params)
                var content = Self.json(r)
                if content.count > 8000 {
                    content = content.prefix(8000) + "\n... [tool result truncated, total \(content.count) chars]"
                }
                var m = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            } catch {
                var m = ChatMessage(role: "tool", content: Self.json(["ok": false, "message": String(describing: error)]),
                                    isError: true, toolCallId: call.id, toolName: call.name)
                m.toolArgs = Self.summarizeArgs(call.arguments)
                msgs.append(m)
            }
            executed.append(call.name)
        }
        task.addRound(tools: executed)
        messages = msgs
        loop()
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
        summary: "Delegate a self-contained task to an isolated subagent that runs its own tool loop in a separate context (won't pollute the main conversation). Use for: long multi-step dirty work — batch file analysis, multi-file audits, repetitive processing, web research chains. Don't use for: quick single calls (call the tool directly). Params: instruction(required), tools(optional comma-separated whitelist, default shell.exec/artifact/device/web.search/web.fetch/skills.read), max_rounds(optional default 12 max 30), timeout_secs(optional default 180 max 600). Returns task_id immediately (async); poll with subagent.status until status=done, stop with subagent.stop if it misbehaves.",
        parameters: [
            "instruction": "The complete task to execute (required). Be specific about the goal, inputs, and expected output format.",
            "tools": "Optional comma-separated tool whitelist, e.g. 'shell.exec,artifact'. Default: shell.exec/artifact/device/web.search/web.fetch/skills.read",
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
        let wl = (params["tools"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 宽松解析：模型可能传字符串数字（"12"）——Int/Double 都兼容
        let rounds: Int = {
            if let i = params["max_rounds"] as? Int { return i }
            if let s = params["max_rounds"] as? String, let i = Int(s) { return i }
            return 12
        }()
        let timeout: TimeInterval = {
            if let d = params["timeout_secs"] as? Double { return d }
            if let i = params["timeout_secs"] as? Int { return Double(i) }
            if let s = params["timeout_secs"] as? String, let d = Double(s) { return d }
            return 180
        }()
        let id = try SubAgentManager.shared.start(instruction: instruction, allowedTools: wl,
                                                  maxRounds: rounds, timeout: timeout)
        return ["ok": true, "task_id": id,
                "message": "subagent \(id) started. Poll with subagent.status task_id=\(id); steer with subagent.steer task_id=\(id); stop with subagent.stop task_id=\(id)."]
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
