import Foundation
import Combine

enum ChatResult {
    case text(String, thinking: String?)
    /// v3.5.15：toolCalls 增加 content——把模型在工具轮写的正文解说(content)透传出来。
    /// 此前只带 thinking，非流式 chat/completions 路径(parseChoice)会把模型写的解说直接丢掉
    /// (用户实测"解说还没有"的根因之一)；带出后在 runLoop 用作 visibleText 兜底。
    case toolCalls([ToolCall], thinking: String?, content: String?)
}

/// 网络调试日志 (最近 100 条，环形覆盖），用于排查中转站兼容性问题。
/// 界面上在「设置 → 关于 → 网络兼容日志」查看。
final class NetworkLog: ObservableObject {
    static let shared = NetworkLog()

    /// 最近一条兼容性日志 (供设置页副标题展示）
    static var lastCompatNote: String?

    @Published private(set) var entries: [String] = []

    func log(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(text)"
        print("[NetworkLog] \(line)")
        DispatchQueue.main.async {
            self.entries.insert(line, at: 0)
            if self.entries.count > 100 { self.entries.removeLast(self.entries.count - 100) }
        }
    }
}

/// 兼容 API 客户端 (OpenAI / DeepSeek / Anthropic / 任意兼容端点）。
///
/// v2.8.4：针对中转站 (new-api 系）"Invalid request parameter" 报错实现**自适应兼容降级**。
/// 不同中转站 / 不同模型对参数的支持差异极大 (部分不认 max_completion_tokens、
/// 部分不支持 tool_choice、部分模型族在 chat/completions 上拒绝 tools），
/// 与其猜测，不如让客户端自己逐级试探并记住可用级别：
///
/// | 级别 | 载荷 |
/// |------|------|
/// | 0 | 完整载荷 (tools + tool_choice + 推理模型参数适配） |
/// | 1 | 0 基础上互换 token key (max_completion_tokens ↔ max_tokens） |
/// | 2 | 1 基础上去掉 tool_choice |
/// | 3 | 1 基础上去掉 tools (纯对话；历史中的 tool 消息降级为普通文本） |
/// | 4 | 最小载荷 (仅 model + messages） |
///
/// OK后把可用级别持久化到 ModelConfig.compatLevel，下次直接从该级别发起。
final class OpenAIClient {
    let config: ModelConfig
    /// v2.9.0：级别 5 = Responses API + 工具
    private let maxLevel = 5
    /// v2.9.10：自定义 session——waitsForConnectivity 让切后台/网络抖动时不立即failed，
    /// 资源超时放宽到 5 分钟 (配合后台恢复后继续请求）。
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 300
        cfg.timeoutIntervalForRequest = 90
        return URLSession(configuration: cfg)
    }()
    /// v7.4.0-fix73f-5：请求超时覆盖——子代理等短时任务用它压短超时。
    /// 默认 nil（主会话保持 90s/300s 宽松超时）；设置后 sendInner 主请求用独立
    /// session（timeoutIntervalForRequest = 覆盖值），请求挂住时快速失败，由
    /// 失败回调 markFailed，配合 SubAgentManager 看门狗双保险。
    var requestTimeoutOverride: TimeInterval?
    /// v2.9.13：取消支持——置位标志 + 取消当前 in-flight 任务
    private var cancelled = false
    private weak var activeTask: URLSessionDataTask?
    /// v7.1.267-fix3：SSL 握手错误重试计数（同级别新连接重试，最多 2 次——attempt 递归共享实例计数）
    private var sslRetryCount = 0
    /// v2.9.15：本轮请求起始时间 (用于耗时统计，写入网络兼容日志）
    private var requestStart = Date()
    /// v2.9.107：本轮是否占用 HalfOpen 探测名额 (熔断记录时释放）
    private var usedHalfOpenPermit = false
    /// v2.9.299：当前请求是否已因"模型非视觉"剥离图片 (防止无限重试）
    private var imagesStrippedForVLM = false
    /// v4.3.36：思考自动升档标志——低/中档请求成功但响应无任何思考痕迹时，自动以 high 重试一次。
    /// 破甲站等中转 gpt-5.5 实测 low/medium 不触发思考 (reasoning_tokens=0)，只有 high 出思考。
    private var didAutoEscalateReasoning = false
    /// v7.1.98：本轮响应真实 usage（用量统计最近请求显示 token）——attempt 解析处捕获，end() 读取
    private var lastUsage: [String: Any]?
    /// v7.2.3-fix6：鉴权智能试探（对齐 OpenMinis BYOK）——401/403 时按安全集合
    /// (Bearer → API Key → Query api_key) 换鉴权方式重发，2xx 即纠正配置。
    private var authProbeQueue: [String] = []
    private var overrideAuthMethod: String?
    /// 鉴权纠正回调（创建方注入，用于把识别到的 authMethod 持久化）
    var onAuthCorrected: ((String) -> Void)?
    private var currentCompatLevel: Int;  // v6.0.30: 内存里的兼容级别，避免反复试探死循环
    // fix73j-p5：兼容级别三状态源职责（语义收敛）——
    // ① config.compatLevel：持久记忆（主会话用，写回共享 ModelConfig）；
    // ② client.currentCompatLevel：单请求实例内的试探状态（本请求降级链演化，防死循环）；
    // ③ compatOverride：子代理任务态覆盖（任务内 settle 级别缓存，跨轮有效，不写共享）。
    // 优先级：compatOverride > config.compatLevel（子代理场景 override 非 nil 时优先）。
    // fix73j-p4：兼容级别隔离——子代理场景（persistCompatLevel=false）降级成功/失败
    // 不写回共享 ModelConfig，避免子代理多工具大载荷触发中转拒绝 → 降级 → 主会话连带降级
    // （共享记忆双向污染）。子代理任务级用 compatOverride 缓存降级结果（每轮新 client
    // 从缓存起步，不浪费往返），resolvedLevel 暴露最终 settle 级别。
    var persistCompatLevel = true
    var compatOverride: Int?
    private(set) var resolvedLevel: Int?
    // v7.4.0-fix73c：流式请求在途标志（后台代传检测用——仅流式请求值得 cancel+非流式重发）
    private(set) var isStreamingInFlight = false
    /// v2.9.87：多级降级总预算——全链串行最坏 7 分钟+，用户感知"一直请求中"。
    /// v2.9.96：试探级 (L0-L4）超时已压到 25s，预算放宽到 220s 给 L5 流式留足时间。
    private var overallDeadline = Date.distantFuture
    private let overallBudget: TimeInterval = 220
    /// v2.9.20：本轮推理强度 (0=低 1=中 2=高 3=最高xhigh 4=极限max 5=关闭none），由 ChatView 传入并真实作用于请求。
    var currentReasoningLevel = 0  // v2.9.49：默认 low (medium/high 推理显著增加延迟，对标 Codex CLI 默认 low）
    // —— v7.3.0-scalpel：手术刀式上下文管理（对齐 Claude Code 五层压缩瀑布）——
    // 预算模型: |S系统|+|H历史|+|T工具|+|R提醒| ≤ W；S+T+R 为固定开销，H 是唯一压缩对象。
    // T1 重排保缓存：无 prompt caching 的中转不适用，稳定前缀在前即等价（现有顺序已满足）。
    // T2 归档最旧(13K 缓冲) / T3 分节渐进退化(75%+) / T4 全量摘要(窗口−13K) / T5 413 页错误恢复。
    private static let defaultContextWindow = 128_000        // W 默认（无实测窗口时）
    static let fixedOverheadTokens = 6_000           // 系统提示 + 工具定义固定开销估算
    private static let snipBufferTokens = 13_000             // T2: 超目标缓冲触发（Claude 同款）
    private static let pressureShortened: Double = 0.60      // 压力分级阈值（Claude: 60/75/90）
    private static let pressureAggressive: Double = 0.75
    private static let pressureCompact: Double = 0.90
    private static let tokenSaverMaxChars = 4_000            // tokenSaverOutput: 大结果压缩阈值
    private static let tokenSaverHeadChars = 2_000           // 保头部
    private static let tokenSaverTailChars = 1_000           // 保尾部
    private static let reactiveLastKeep = 4                  // T5: 413 只保最近 4 条（Claude 同款）
    private static let autoCompactThrottle: TimeInterval = 30  // T4 自动压缩防抖（秒）
    /// T5 单次守卫——413 激进压缩只做一次，防止重试循环
    private var hasAttemptedReactiveCompact = false
    /// T4 自动压缩防抖——同会话 30s 内不重复自动触发
    private var lastAutoCompactAt: Date? = nil

    /// —— v7.3.1-precision：精确 token 估算（对齐 Claude tokenEstimation.ts rough 层 +
    /// OpenMinis BPE 规则 + 真实 usage 校准。精度实测：散文 chars/4 误差 ~0.04%；
    /// tool 结果（代码/JSON/日志）4 chars/token 低估 2.78×（tokenauditor 实测）→ 密桶 2 bytes/token；
    /// 图片用 OpenMinis ceil(w/32)*ceil(h/32) 规则。cl100k BPE 对非 OpenAI 模型是错误词表
    /// （claude-opus-4-7 需 ×1.654 修正，tloc 实测），所以不背 1.5MB 词表——用请求后真实
    /// usage.prompt_tokens 校准（UsageRecorder.lastRealRatio），跨模型自动学习 tokenizer 系数。
    private enum TokenBucket { case prose, code, base64, chinese }

    /// 从 dataURL 解析图片像素尺寸（PNG IHDR / JPEG SOF marker），失败返回 nil
    private static func imageDimensions(_ data: Data) -> (w: Int, h: Int)? {
        if data.count >= 24, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            let w = (Int(data[16]) << 24) | (Int(data[17]) << 16) | (Int(data[18]) << 8) | Int(data[19])
            let h = (Int(data[20]) << 24) | (Int(data[21]) << 16) | (Int(data[22]) << 8) | Int(data[23])
            if w > 0, h > 0, w <= 16384, h <= 16384 { return (w, h) }
            return nil
        }
        if data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 {
            var i = 2
            while i + 9 < data.count {
                if data[i] != 0xFF { i += 1; continue }
                let marker = data[i + 1]
                if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
                if (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                    let h = (Int(data[i + 5]) << 8) | Int(data[i + 6])
                    let w = (Int(data[i + 7]) << 8) | Int(data[i + 8])
                    if w > 0, h > 0, w <= 16384, h <= 16384 { return (w, h) }
                    return nil
                }
                let len = (Int(data[i + 2]) << 8) | Int(data[i + 3])
                if len < 2 { return nil }
                i += 2 + len
            }
            return nil
        }
        return nil
    }
    /// OpenMinis 图片 token 规则：ceil(w/32)*ceil(h/32)，cap 2048×2048，min 85；解析失败 fallback 2000
    /// v7.4.0-fix69：只解码 base64 前缀 4KB（PNG IHDR 在前 24B、JPEG SOF 在头几 KB）——
    /// 不整图解码（4K 图 base64 ~10MB），否则每次 save/UI 重算/发送估算都吃整图解码
    private static func imageTokenCount(_ dataURL: String) -> Int {
        guard let b64 = dataURL.split(separator: ",").last else { return 2000 }
        let prefix = String(b64.prefix(4096))
        guard let data = Data(base64Encoded: prefix),
              let (w, h) = imageDimensions(data) else { return 2000 }
        let maxEdge = 2048.0
        let scale = max(Double(w), Double(h)) > maxEdge ? maxEdge / max(Double(w), Double(h)) : 1.0
        return max(85, Int(ceil(Double(w) * scale / 32.0) * ceil(Double(h) * scale / 32.0)))
    }
    /// 内容分桶：tool 结果一律密桶；散文含代码特征（大括号/分号/等号/换行密集）也走密桶。
    /// v7.1.267-precision：三处精确化——
    /// ① 中文/CJK 单独桶：中文在 DeepSeek/OpenAI 词表约 1-2 汉字/token，旧散文桶 4 chars/token 低估 2-4×；
    /// ② Base64/高密度长串单独桶：4 chars=3 bytes 的 Base64 实测 6-8 chars/token，旧 code 桶 2 chars/token 高估 3-4×
    ///    （工具结果大量 raw_base64——高估会提前触发历史截断，白白丢上下文）；
    /// ③ 混合内容按比例线性插值（中英混排/含 Base64 的 JSON）。
    private static func tokenBucket(_ m: ChatMessage) -> TokenBucket {
        if m.role == "tool" { return .code }
        let c = m.content
        guard !c.isEmpty else { return .prose }
        // Base64/长数字串检测：连续 base64 字母数字 +/= 占比高 → 高密度桶
        let b64chars = c.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }
        if c.count >= 64, b64chars.count * 2 > c.count {
            return .base64
        }
        let hits = c.filter { $0 == "{" || $0 == "}" || $0 == "[" || $0 == "]" || $0 == ";" || $0 == "=" || $0 == "\n" }.count
        if (hits * 12) > c.count { return .code }
        // CJK 占比检测：汉字/假名/谚文 → 混合桶（按比例插值系数在估算处计算）
        let cjk = c.filter { $0.unicodeScalars.first!.value >= 0x2E80 && $0.unicodeScalars.first!.value <= 0x9FFF }
        if cjk.count * 3 > c.count * 2 { return .chinese }
        return .prose
    }
    /// 分桶估算（static 供 UsageRecorder 复用——ratio 分母必须同源）。
    /// v7.1.267-precision：CJK 按 2 chars/token（DeepSeek 词表中文密度实测），Base64 按 6 chars/token，
    /// 混合内容按 CJK 占比在 4 与 2 之间线性插值。
    static func estimateTokensStatic(_ m: ChatMessage) -> Int {
        var tokens = 0
        let textLen = m.content.count + (m.thinking?.count ?? 0)
        if textLen > 0 {
            switch tokenBucket(m) {
            case .code:
                tokens += max(4, textLen / 2)              // 密桶：2 bytes/token（JSON/代码/日志实测密度）
            case .base64:
                tokens += max(4, textLen / 6)              // Base64/长数字串：6 chars/token（4 chars=3 bytes 实测）
            case .chinese:
                tokens += max(4, textLen / 2)              // 中文桶：2 chars/token（DeepSeek 词表中文密度）
            case .prose:
                tokens += textLen / 4 + 1                  // 散文桶：4 chars/token（英文实测误差 ~0.04%）
            }
        }
        if let calls = m.toolCalls {
            for tc in calls {
                tokens += max(4, (tc.name.count + tc.arguments.count) / 2) + 4   // tool_use: name+JSON + 结构开销
            }
        }
        if let imgs = m.imageDataURLs, !imgs.isEmpty {
            for u in imgs { tokens += imageTokenCount(u) }
        }
        return max(1, tokens)
    }
    private func estimateTokens(_ m: ChatMessage) -> Int { Self.estimateTokensStatic(m) }
    /// 总量估算 × 真实 usage 校准比（end() 从响应 prompt_tokens 学习，clamp 0.5–2.5——
    /// 跨模型自动修正 tokenizer 差异：Claude 4.7+ 自动收敛 ~1.65、中文内容自动修正）
    private func estimateTotalTokens(_ msgs: [ChatMessage]) -> Int {
        let est = msgs.reduce(0) { $0 + Self.estimateTokensStatic($1) }
        // v7.4.0-fix66：线程安全读（原直接读 lastRealRatio 与回调线程竞争）
        let cal = UsageRecorder.shared.calibratedRatio
        return cal > 0 ? max(est, Int(Double(est) * cal)) : est
    }
    /// 当前模型上下文窗口：优先实测（RuntimeWindowTracker 动态收敛），无则默认
    private func contextWindowTokens() -> Int {
        RuntimeWindowTracker.shared.measuredWindow(for: config.model) ?? Self.defaultContextWindow
    }
    /// v7.3.1-precision：输出预算预留（对齐 Claude/Codex——窗口 = input + output，
    /// 预算在发送前就给输出留位，避免"输入塞满 → 输出被截断/413"）
    private func outputReserveTokens() -> Int {
        let w = contextWindowTokens()
        return min(config.maxTokens > 0 ? config.maxTokens : 8_192, max(4_096, w / 4))
    }
    /// 历史可用预算 = W − 固定开销 − T2 缓冲 − 输出预留（T2 在超缓冲时先归档，不是到 W 才动手）
    private func historyTokenBudget() -> Int {
        max(8_000, contextWindowTokens() - Self.fixedOverheadTokens - Self.snipBufferTokens - outputReserveTokens())
    }
    /// 压力百分比（0-100），分母为「窗口 − 输出预留」（输出预留后压力提前分级）
    private func tokenPressurePercent(_ msgs: [ChatMessage]) -> Int {
        let used = Double(estimateTotalTokens(msgs) + Self.fixedOverheadTokens)
        let avail = Double(contextWindowTokens() - outputReserveTokens())
        guard avail > 0 else { return 100 }
        return min(100, Int((used / avail * 100).rounded()))
    }
    private enum ContextPressure { case normal, shortened, aggressive, compact }
    private func pressureLevel(_ msgs: [ChatMessage]) -> ContextPressure {
        let p = Double(tokenPressurePercent(msgs)) / 100.0
        if p >= Self.pressureCompact { return .compact }
        if p >= Self.pressureAggressive { return .aggressive }
        if p >= Self.pressureShortened { return .shortened }
        return .normal
    }
    /// 压力提醒注入（对齐 Claude system-reminder 的 hot 注入：不进系统提示缓存区，
    /// 附加到最新 user 消息尾部——不新增 role 序列，保持消息流自洽）
    private func appendPressureHint(to msgs: inout [ChatMessage], pct: Int) {
        guard let idx = msgs.lastIndex(where: { $0.role == "user" }),
              !msgs[idx].content.contains("[token pressure") else { return }
        let mode = pct >= 90 ? "上下文接近上限，即将自动压缩" : (pct >= 75 ? "请显著精简输出" : "请精简输出，减少无关工具调用")
        msgs[idx].content += "\n\n[token pressure \(pct)% — \(mode)]"
    }
    /// v7.3.1-precision-T3：按 user 边界切语义节（节 = user 消息 + 后续 assistant/tool，
    /// 直到下一个 user 前）——分节语义摘要的切割单位（对齐 Claude Code Context Collapse：
    /// 调试段/编辑序列/评审段各自独立摘要，渐进退化 90%→92%→94%）
    private func sections(_ msgs: [ChatMessage]) -> [[ChatMessage]] {
        var result: [[ChatMessage]] = []
        var cur: [ChatMessage] = []
        for m in msgs {
            if m.role == "user", !cur.isEmpty {
                result.append(cur)
                cur = []
            }
            cur.append(m)
        }
        if !cur.isEmpty { result.append(cur) }
        return result
    }

    init(_ config: ModelConfig) {
        currentCompatLevel = config.compatLevel  // v6.0.30: 初始化内存里的兼容级别
        // v4.4.16：API 协议自动纠偏——用户配错协议(如 deepseek 配 Responses)时，请求前自动纠正
        // (deepseek→Chat Completions, gpt-5/o系列→Responses, claude→Anthropic)，无需用户手动改
        var c = config
        let corrected = ModelConfig.autoCorrectProtocol(model: c.model, provider: c.provider, current: c.apiProtocol)
        if corrected != c.apiProtocol {
            // 协议变了, 旧的 compatLevel 记忆(尤其 L5=Responses)基于旧协议不再适用 → 重置到 L0 重新试探
            c.compatLevel = 0
            NetworkLog.shared.log("\(c.name): protocol auto-corrected \(c.apiProtocol)→\(corrected) (model=\(c.model)), compat level reset")
            c.apiProtocol = corrected
        }
        // v4.4.17：OpenAI 格式端点自动补 /v1 (用户已填 v1/含版本路径则不补)
        // v7.1.109-peers：OpenRouter 同是 OpenAI 兼容路径，纳入自动补
        if c.apiProtocol == "OpenAI Chat Completions" || c.apiProtocol == "OpenAI Responses" || c.apiProtocol == "OpenRouter" {
            let nb = ModelConfig.normalizeBaseURL(c.baseURL)
            if nb != c.baseURL {
                NetworkLog.shared.log("\(c.name): Base URL auto-appended /v1: \(c.baseURL)→\(nb)")
                c.baseURL = nb
            }
        }
        self.config = c
    }

    // MARK: - 对外入口

    /// v2.9.13：取消当前请求 (ChatView 停止按钮调用）
    func cancel() {
        cancelled = true
        activeTask?.cancel()
    }

    /// v4.3.71：LLM Compaction（对齐 Claude Code / Codex 的 context compaction）——
    /// 长会话中 messagesForAPI 裁掉了旧消息 (compactSource 非空) 时，先把被裁消息交给模型
    /// 生成结构化摘要，替换本地启发式话题摘要（"[系统] 已省略…"）后再发主请求。
    /// 摘要失败 (nil) 自动回退启发式，绝不影响主请求可用性。
    func summarize(_ compactSource: [ChatMessage], completion: @escaping (String?) -> Void) {
        guard !compactSource.isEmpty else { completion(nil); return }
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { completion(nil); return }
        // v7.3.0-scalpel：摘要模板升级 9 节（对齐 Claude Code BASE_COMPACT_PROMPT——
        // 保留的不只是"说了什么"还有"为什么"：意图、概念、文件、错误、路径、原文、待办、进行中、下一步）
        let summarySystem = "You are a conversation compression engine. Below is an old conversation between an AI assistant and the user (user questions, assistant replies, tool calls and results). Compress it into a structured Markdown summary so the assistant can seamlessly continue in later turns. The input may BEGIN with a previously generated summary of this same conversation — if so, MERGE it with the new messages below into ONE updated summary (keep earlier context that is still relevant, integrate the new state; do not duplicate or drop it). MUST include these 9 sections:\n1. Request & intent: user's core request, success criteria, constraints;\n2. Key technical concepts: domain details, technical constraints, commitments;\n3. Files & code: changed/generated files or artifacts with paths, key code sections;\n4. Errors & fixes: resolved errors, failed approaches, important decisions;\n5. Approaches: problem-solving strategies tried or chosen;\n6. User messages VERBATIM: quote every user message exactly as written, in order;\n7. Pending tasks: todos, blockers, priorities;\n8. Work in progress: current state — what's done vs in-flight;\n9. Next step: the exact next action to take.\nOutput only the summary body — no pleasantries, no restating the original conversation."
        let conversation = compactSource.map { m -> String in
            let roleLabel: String
            switch m.role {
            case "user": roleLabel = "User"
            case "assistant": roleLabel = "Assistant"
            case "tool": roleLabel = "Tool result (\(m.toolName ?? "tool"))"
            default: roleLabel = m.role
            }
            return "【\(roleLabel)】\n\(m.content)"
        }.joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": summarySystem],
                ["role": "user", "content": conversation]
            ],
            config.maxTokensKey: 1600
        ]
        if config.sendsTemperature { body["temperature"] = 0.3 }
        var request = URLRequest(url: url, timeoutInterval: 90)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let text = (choices.first?["message"] as? [String: Any])?["content"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    func send(messages: [ChatMessage], compactSource: [ChatMessage] = [], tools: [[String: Any]]? = nil, onStatus: ((String) -> Void)? = nil, onDelta: ((String) -> Void)? = nil, onThinking: ((String) -> Void)? = nil, onCompacted: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        // v7.2.3-fix6：鉴权智能试探队列——每次 send 重置候选（当前方式之外的安全集合）
        let currentAuth = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        authProbeQueue = ["Bearer", "API Key", "Query api_key"].filter { $0 != currentAuth }
        overrideAuthMethod = nil
        // v4.3.71 / v7.3.0-scalpel-T4 / v7.3.1-precision-T3：LLM Compaction 前置——先摘要被裁旧消息，
        // 替换启发式占位后再发主请求。
        //  T4 自动触发：历史 token 压力达 90%（窗口−13K 缓冲）且无手动 compactSource 时自动摘要
        //    （对齐 Claude Code auto-compact：达 effectiveContextWindow−13K）。
        //  T3 分节触发：压力 75–90%（aggressive）时只对「最旧语义节」做 LLM 单节摘要替换
        //    （对齐 Claude Code Context Collapse：分节渐进退化，不是一次性全量压缩）。
        // 防抖 30s 共用；summarize 直连 API 不走 attempt → 无递归。
        let secs = sections(messages)
        let autoNeedsCompact = compactSource.isEmpty
            && pressureLevel(messages) == .compact
            && (lastAutoCompactAt.map { Date().timeIntervalSince($0) >= Self.autoCompactThrottle } ?? true)
            && messages.contains(where: { $0.role == "user" })
        let t3NeedsSectionCompact = compactSource.isEmpty
            && pressureLevel(messages) == .aggressive
            && secs.count >= 2
            && secs[0].count >= 2
            && (lastAutoCompactAt.map { Date().timeIntervalSince($0) >= Self.autoCompactThrottle } ?? true)
        if !compactSource.isEmpty || autoNeedsCompact || t3NeedsSectionCompact {
            if autoNeedsCompact || t3NeedsSectionCompact { lastAutoCompactAt = Date() }
            let isSectionCompact: Bool
            let source: [ChatMessage]
            if !compactSource.isEmpty {
                source = compactSource; isSectionCompact = false
            } else if t3NeedsSectionCompact {
                source = secs[0]; isSectionCompact = true     // T3：只压最旧一节
            } else {
                source = messages; isSectionCompact = false   // T4：全量
            }
            summarize(source) { [weak self] summary in
                guard let self = self else {
                    completion(.failure(NSError(domain: "OpenAIClient", code: -999, userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
                    return
                }
                // v4.3.72：摘要期间用户点了停止 → 不再发主请求
                if self.cancelled {
                    completion(.failure(NSError(domain: "OpenAIClient", code: -999, userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
                    return
                }
                var msgs = messages
                if let s = summary, !s.isEmpty {
                    let newSummary = "[Long-conversation summary, model-generated]\n" + s
                    if isSectionCompact {
                        // T3：替换最旧节——删掉该节全部消息，在相同位置插摘要（消息流自洽：
                        // 该节内 assistant.toolCalls 与其 tool 结果一起被替换，无配对撕裂）
                        let dropCount = min(secs[0].count, msgs.count)
                        msgs.removeFirst(dropCount)
                        msgs.insert(ChatMessage(role: "system", content: newSummary), at: 0)
                        // v7.1.41：回调上层把压缩持久化进会话历史（对齐 Claude Code /compact 的破坏性替换）
                        onCompacted?(s)
                    } else {
                        // v7.1.41：优先更新已有摘要（增量演进——同会话多次压缩只保留一份、内容持续合并），
                        // 无则替换启发式占位，再否则插入最前
                        if let idx = msgs.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[Long-conversation summary") }) {
                            msgs[idx] = ChatMessage(role: "system", content: newSummary)
                        } else if let idx = msgs.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[System] earliest") }) {
                            msgs[idx] = ChatMessage(role: "system", content: newSummary)
                        } else {
                            msgs.insert(ChatMessage(role: "system", content: newSummary), at: 0)
                        }
                        // v7.1.41：回调上层把压缩持久化进会话历史（对齐 Claude Code /compact 的破坏性替换）
                        onCompacted?(s)
                    }
                }
                self.sendWithFallback(messages: msgs, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
            }
            return
        }
        // v7.3.0-scalpel-reminder：非 compact 压力级时注入 token 压力提醒
        // （对齐 Claude system-reminder hot 注入——不进系统提示缓存区，附加到最新 user 尾部，
        // 不新增 role 序列 → 消息流自洽；60%+ 提醒精简输出，75%+ 提醒显著精简）
        var msgs = messages
        let pct = tokenPressurePercent(msgs)
        switch pressureLevel(msgs) {
        case .shortened, .aggressive: appendPressureHint(to: &msgs, pct: pct)
        default: break
        }
        sendWithFallback(messages: msgs, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
    }

    /// v7.1.107：模型组 fallback 入口——主模型失败（网络/超时/鉴权/熔断/HTTP 4xx5xx，
    /// 且未产出任何内容）时自动按序切换到备用模型重发同一请求（对齐 OpenMinis
    /// ModelGroupRouter fallback 思想，自实现）。链长度为 1（未配置备用）时完全等价旧行为。
    private func sendWithFallback(messages: [ChatMessage], tools: [[String: Any]]? = nil,
                                  onStatus: ((String) -> Void)? = nil, onDelta: ((String) -> Void)? = nil,
                                  onThinking: ((String) -> Void)? = nil,
                                  completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let chain = ModelStore.shared.fallbackChain(from: config)
        guard chain.count > 1 else {
            sendInner(messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
            return
        }
        attemptSend(chain: chain, index: 0, messages: messages, tools: tools,
                    onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
    }

    /// v7.1.107：fallback 链单层执行——当前模型失败且可切换时递归到下一层。
    /// 安全闸：已产出内容（流式吐字）或用户取消的失败不切换（避免重复输出/打断用户）；
    /// 工具调用在失败时尚未执行，重发无副作用风险。
    private func attemptSend(chain: [ModelConfig], index: Int,
                             messages: [ChatMessage], tools: [[String: Any]]? = nil,
                             onStatus: ((String) -> Void)? = nil, onDelta: ((String) -> Void)? = nil,
                             onThinking: ((String) -> Void)? = nil,
                             completion: @escaping (Result<ChatResult, Error>) -> Void) {
        guard index < chain.count else {
            completion(.failure(NSError(domain: "OpenAIClient", code: -503,
                userInfo: [NSLocalizedDescriptionKey: "Model fallback chain exhausted — all backup models failed too. Check model configs."])))
            return
        }
        let cfg = chain[index]
        let client = index == 0 ? self : OpenAIClient(cfg)
        var producedOutput = false
        let wrappedDelta: ((String) -> Void)?
        if let onDelta = onDelta {
            wrappedDelta = { text in
                producedOutput = true
                onDelta(text)
            }
        } else {
            wrappedDelta = nil
        }
        client.sendInner(messages: messages, tools: tools, onStatus: onStatus, onDelta: wrappedDelta, onThinking: onThinking) { [weak self] result in
            switch result {
            case .success(let r):
                completion(.success(r))
            case .failure(let err):
                let nsErr = err as NSError
                let canFallback = !producedOutput
                    && nsErr.code != -999
                    && Self.isFallbackableError(nsErr)
                    && index + 1 < chain.count
                if canFallback {
                    let next = chain[index + 1]
                    NetworkLog.shared.log("\(cfg.name) failed (code \(nsErr.code), \(String(describing: nsErr.localizedDescription.prefix(80)))) → fallback to \(next.name)")
                    onStatus?("⚠️ \(cfg.name) failed, switching to backup model \(next.name)…")
                    self?.attemptSend(chain: chain, index: index + 1, messages: messages, tools: tools,
                                      onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
                } else {
                    completion(.failure(err))
                }
            }
        }
    }

    /// v7.1.107：该失败是否值得切换模型——取消/本地配置错/参数错(400/422)/流式本地错不切；
    /// 网络、超时、熔断、鉴权(401/403)、限流(429)、模型不存在(404)、服务端错(5xx)切换。
    private static func isFallbackableError(_ err: NSError) -> Bool {
        if err.domain == NSURLErrorDomain {
            return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                    NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(err.code)
        }
        guard err.domain == "OpenAIClient" else { return false }
        switch err.code {
        case -999, 0, 1, 2, -3040, -3041:
            return false   // 取消 / 本地配置错 / 协议解析错 / 流式本地错
        case -503, -1001:
            return true    // 熔断 / 超时
        default:
            let http = err.code
            if http == 400 || http == 422 { return false }   // 请求体/参数错，换模型无用
            return http >= 400   // 401/403/404/429/5xx → 换模型试
        }
    }

    /// v4.3.71：send 主流程（熔断/降级链/流式），与 compaction 前置分支分离。
    private func sendInner(messages: [ChatMessage], tools: [[String: Any]]? = nil, onStatus: ((String) -> Void)? = nil, onDelta: ((String) -> Void)? = nil, onThinking: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        cancelled = false
        requestStart = Date()
        overallDeadline = Date().addingTimeInterval(overallBudget)
        // v4.3.36：每轮请求重置思考自动升档标志 (防止跨请求残留）
        didAutoEscalateReasoning = false
        // v2.9.107：熔断检查 (对齐 cc-switch circuit_breaker）——供应商连续failed过多时直接拒绝，
        // 不再傻等超时 (用户痛点"一直请求中"）
        let gate = ModelStore.shared.breaker(for: config.id).allowRequest()
        usedHalfOpenPermit = gate.usedHalfOpenPermit
        if !gate.allowed {
            let el = Int(Date().timeIntervalSince(requestStart) * 1000)
            NetworkLog.shared.log("\(config.name) circuit-broken, request rejected (\(el)ms)")
            completion(.failure(NSError(domain: "OpenAIClient", code: -503,
                userInfo: [NSLocalizedDescriptionKey: "Provider «\(config.name)» circuit-broken (too many consecutive failures, requests paused to avoid hanging). Reset it on the model-management page, or auto-recovery probing resumes in ~60s."])))
            return
        }
        UsageRecorder.shared.begin(messages: messages)
        lastUsage = nil   // v7.1.98：本轮 usage 清零，attempt 捕获真实 usage
        // v2.9.0：级别 5 = Responses API + 工具调用 (Codex 走的端点，GPT-5.6 家族
        // 在 chat/completions 上无法用 function tools，但 /v1/responses 可以）
        // v2.9.299：VLM 错误图片剥离标志——遇到"模型不是视觉模型"时只剥离一次
        self.imagesStrippedForVLM = false
        var start = min(max(config.compatLevel, 0), maxLevel)
        // fix73j-p4：任务级降级缓存优先（子代理场景：每轮新 client 从缓存起步，不重试降级链）
        if let ov = compatOverride { start = ov }
        // 历史被记忆为"纯对话"(L3/L4) 的旧配置，给一次恢复工具调用的机会：
        // 先试 L5 (Responses API + 工具），failed自动回落 L3。
        if start == 3 || start == 4 {
            NetworkLog.shared.log("\(config.name): current memory level is pure chat, trying Responses API to restore tool calls first…")
            start = 5
        }
        // v3.5.11：带工具请求优先走 L5 (Responses API = Codex 同款端点)——对齐 Codex/Claude Code
        // "一次流式先思考后行动"。L5 原生流式 reasoning→function_call，才能让模型每步有解说/思考；
        // 一直钉在 L0 (chat/completions 完整载荷) 则模型工具轮常不发 reasoning/narration (用户实测）。
        // 若 L5 failed，降级链会回落带工具的 L2 (chat/completions) 或 L3 纯对话，不影响可用性。
        // 审计修正：只在 L0(默认未降级) 时强制试 L5；一旦降级到 L1/L2 被记住，就尊重记忆级别——
        // 否则每次工具请求都白试一次 L5 再回落 (浪费往返)。L3/L4 已由上面分支尝试 L5 恢复。
        let hasTools = tools != nil && !(tools?.isEmpty ?? true)
        // v4.4.16：L5(Responses) 强制试用只对推理系列(走 Responses 的 gpt-5/o系列)触发；
        // 此前对所有带工具请求无差别试 L5, 把 deepseek 也拉去 responses 端点(慢/支持差)并记住 L5
        if hasTools, config.apiProtocol != "OpenAI Responses", config.compatLevel == 0, config.isReasoningModel {
            NetworkLog.shared.log("\(config.name): tool-enabled request, preferring L5 Responses API (Codex-style endpoint)…")
            start = 5
        }
        if start > 0 {
            NetworkLog.shared.log("\(config.name): using remembered compat level \(start) (\(levelName(start)))")
        } else {
            NetworkLog.shared.log("\(config.name): sending request (level 0 full payload)")
        }
        // v2.9.88：请求全链路耗时可视化 —— 在外层包一层 completion，
        // 无论OK/failed/降级多少次，最终只上报一次总耗时 (首字节→流式→工具调用全含在内）。
        // 先调用原 completion (内部会清 statusText），再补报耗时，让用户看到"done用了多久"。
        let wrappedCompletion: (Result<ChatResult, Error>) -> Void = { result in
            let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
            completion(result)
            switch result {
            case .success:
                let secs = String(format: "%.1f", Double(el) / 1000.0)
                NetworkLog.shared.log("\(self.config.name) request done (\(el)ms)")
                onStatus?(L10n.t("status_response_done", secs))
                ModelStore.shared.breaker(for: self.config.id).recordSuccess(usedHalfOpenPermit: self.usedHalfOpenPermit)
                UsageRecorder.shared.end(config: self.config, ok: true, elapsedMs: el, usage: self.lastUsage)
                // v7.1.109-peers：实测自适应——成功请求把窗口上调（未收录/新迭代模型逐步收敛）
                if let u = self.lastUsage, let p = u["prompt_tokens"] as? Int {
                    RuntimeWindowTracker.shared.recordSuccess(model: self.config.model, promptTokens: p)
                }
                // v7.1.109-peers：动态监测——带图请求成功 → 持久化标记支持视觉
                if messages.contains(where: { !($0.imageDataURLs ?? []).isEmpty }) {
                    VisionTracker.shared.record(model: self.config.model, supports: true)
                }
            case .failure(let e):
                NetworkLog.shared.log("\(self.config.name) request failed (\(el)ms): \(e.localizedDescription)")
                ModelStore.shared.breaker(for: self.config.id).recordFailure(usedHalfOpenPermit: self.usedHalfOpenPermit)
                UsageRecorder.shared.end(config: self.config, ok: false, elapsedMs: el, error: e.localizedDescription)
                // v7.1.109-peers：超限错误自动下调窗口（失败信号闭环——静态表追不上迭代时的保险）
                if self.isContextOverflow(e) {
                    RuntimeWindowTracker.shared.recordExceeded(model: self.config.model,
                        promptTokens: UsageRecorder.shared.lastInputEstimate)
                }
            }
        }
        attempt(level: start, isFirst: true, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: wrappedCompletion)
    }

    /// v7.1.109-peers：上下文超限错误检测——命中时下调该模型实测窗口
    private func isContextOverflow(_ e: Error) -> Bool {
        let s = e.localizedDescription.lowercased()
        return s.contains("context_length_exceeded")
            || s.contains("maximum context")
            || s.contains("context window")
            || s.contains("prompt is too long")
            || s.contains("too many tokens")
            || s.contains("exceeds the maximum")
    }

    /// 降级顺序：L0→L1→L2→ (带 tools 时优先 L5 Responses API，保住工具调用）→L3→L4→结束
    /// 返回 > maxLevel 的哨兵值表示降级链走完，无下一级可试。
    private func nextLevel(after level: Int, hasTools: Bool, avoidL5: Bool = false) -> Int {
        if level == 2, hasTools, !avoidL5 { return 5 }
        if level == 5 { return 3 }
        if level >= 4 { return 6 }   // 哨兵：链尾，避免 L4→L5→L3 循环
        return level + 1
    }

    /// v7.2.3-fix：降级决策统一出口（病灶② 收敛）——"该不该降级/降到哪级/是否穷尽"
    /// 集中到此纯函数，watchdog/超时/retryable/回落各分支共用（此前各自 if，路径分散）。
    /// 行为与旧逻辑完全一致，只是判定单点化，便于枚举与测试。
    private func fallbackVerdict(level: Int, hasTools: Bool, avoidL5: Bool) -> (next: Int, exhausted: Bool) {
        let next = self.nextLevel(after: level, hasTools: hasTools, avoidL5: avoidL5)
        return (next, next > self.maxLevel)
    }

    // MARK: - 逐级试探

    private func attempt(level: Int, isFirst: Bool, messages: [ChatMessage], tools: [[String: Any]]?, onStatus: ((String) -> Void)?, onDelta: ((String) -> Void)?, onThinking: ((String) -> Void)? = nil, avoidL5: Bool = false, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        // v7.4.0-fix73g：已取消则不再启动新请求——子代理 abort 后，降级链的
        // L3/L2 fallback（第 667/736/762 行 re-enter attempt）不得继续发新 HTTP 请求
        // 在后台空转（此前 cancel 只掐当前 task，链仍烧到 220s 预算）。
        if self.cancelled {
            completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
            return
        }
        // v2.9.87：总预算检查——降级链整体超时直接failed，不再无限串行等
        if Date() > overallDeadline {
            let el = Int(Date().timeIntervalSince(requestStart) * 1000)
            NetworkLog.shared.log("\(config.name) multi-level fallback budget exhausted (\(Int(overallBudget))s, \(el)ms)")
            completion(.failure(NSError(domain: "OpenAIClient", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Request timeout: tried all 6 compat levels, still no response (total \(Int(overallBudget))s). The relay may be overloaded or the model name wrong — retry later or check the model config."])))
            return
        }
        if config.apiProtocol == "Anthropic Messages" {
            performAnthropic(messages: messages, tools: tools, completion: completion)
            return
        }
        // v7.1.109-peers：Gemini 原生协议（generateContent）——Google 官方与 Gemini 中转站
        if config.apiProtocol == "Gemini" {
            performGemini(messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
            return
        }
        // v4.5.x：看门狗标志与任务须在 dataTask 闭包之前声明（Swift 禁止闭包捕获未声明局部变量）。
        // 调度仍放函数尾部（asyncAfter 与超时窗口一致）；触发时 cancel dataTask → error 分支识别 watchdogFired 走降级链。
        var watchdogFired = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.cancelled || watchdogFired { return }
            watchdogFired = true
            let headersReceived = self.activeTask?.response != nil ? "yes" : "no"
            NetworkLog.shared.log("\(self.config.name) L\(level) no progress in \(Int(Self.watchdogSeconds(for: self.currentReasoningLevel)))s (response-headers-received: \(headersReceived))")
            if Date() > self.overallDeadline {
                NetworkLog.shared.log("\(self.config.name) L\(level) watchdog hit overallDeadline (\(Int(self.overallBudget))s), failing fast")
            }
            self.activeTask?.cancel()
        }
        // v2.9.0：手动选择 Responses 协议，或降级链走到 L5
        // v2.9.53：L5 默认走流式 (SSE），逐字显示 + done后解析
        if level == 5 || config.apiProtocol == "OpenAI Responses" {
            // 手动选择协议时不回落；经降级链进入 (L5）failed后回落 L3 纯对话
            let viaLadder = level == 5 && config.apiProtocol != "OpenAI Responses"
            performResponsesStream(messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking) { [weak self] result in
                guard let self = self else { return }
                if case .failure(let err) = result, viaLadder {
                    let nsErr = err as NSError
                    // v2.9.297：空响应 (中转不支持 Responses API）→ 回落 L2 带工具 chat/completions 并跳过 L5，避免死循环
                    if nsErr.code == -3040 || nsErr.code == -3041 {
                        self.attempt(level: 2, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: true, completion: completion)
                        return
                    }
                    // 其他failed：回落到已验证可用的纯对话模式
                    self.attempt(level: 3, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, completion: completion)
                    return
                }
                completion(result)
            }
            return
        }

        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = "/chat/completions"
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])))
            return
        }

        // v2.8.6：首次请求 45s；降级重试 30s。
        // 中转对完整载荷 (tools + reasoning_effort）处理极慢/卡死，尽早超时并降级。
        // v2.9.12：长会话请求体大，放宽超时——首次 90s / 降级重试 60s (配合 session 90s）
        // v2.9.96：试探级统一 25s——正常中转 5s 内响应，卡死就是永远卡死，
        // 25s 判定足够，把时间预算留给 L5 Responses 流式 (Codex 同款端点）。
        var request = URLRequest(url: url, timeoutInterval: 25)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        // v6.0.30: 试探阶段（level != 已记住的currentCompatLevel）发最小ping请求，不带历史和工具，减少token浪费
        let isTrialRequest = (level != self.currentCompatLevel)
        let trialMessages = [ChatMessage(role: "user", content: "ping")]
        var body = buildBody(level: level, messages: isTrialRequest ? trialMessages : messages, tools: isTrialRequest ? nil : tools)
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 记录发送的载荷摘要 (不含 apiKey），便于排查
        NetworkLog.shared.log("\(config.name) L\(level) \(levelName(level)) → POST \(endpoint), fields: \(body.keys.sorted().joined(separator: ","))")
        if isFirst {
            onStatus?(L10n.t("status_waiting_model"))
        } else {
            onStatus?(L10n.t("status_rejected_simplify", level, maxLevel))
        }

        // v7.4.0-fix73f-5：超时覆盖——子代理场景用短超时独立 session，请求挂住快速失败
        let sessionToUse: URLSession
        if let rt = requestTimeoutOverride, rt > 0 {
            let c = URLSessionConfiguration.default
            c.waitsForConnectivity = false
            c.timeoutIntervalForRequest = rt
            c.timeoutIntervalForResource = rt + 15
            sessionToUse = URLSession(configuration: c)
        } else {
            sessionToUse = session
        }
        let task = sessionToUse.dataTask(with: request) { data, response, error in
            watchdog.cancel()
            if self.cancelled {
                completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
                return
            }
            if let error = error {
                let err = error as NSError
                // v4.5.x：看门狗触发（响应挂起——中转返回部分响应后无更多数据，
                // URLSession timeoutInterval 不再触发 -1001）→ 与用户取消区分，走降级链
                if watchdogFired {
                    let v = self.fallbackVerdict(level: level, hasTools: tools != nil && !(tools?.isEmpty ?? true), avoidL5: avoidL5)
                    if !v.exhausted {
                        let remain = max(0, Int(self.overallDeadline.timeIntervalSinceNow))
                        NetworkLog.shared.log("\(self.config.name) L\(level) response stalled (watchdog \(Int(Self.watchdogSeconds(for: self.currentReasoningLevel)))s) → auto-fallback to L\(v.next) (\(self.levelName(v.next)))")
                        onStatus?(L10n.t("status_timeout_simplify", v.next, self.maxLevel, remain))
                        self.attempt(level: v.next, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                        return
                    }
                    let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                    completion(.failure(NSError(domain: "OpenAIClient", code: -1001,
                        userInfo: [NSLocalizedDescriptionKey: "Request stalled: no response within \(Int(Self.watchdogSeconds(for: self.currentReasoningLevel)))s, tried all compat levels (total \(el)ms). The relay may have hung — retry or check the model config."])))
                    return
                }
                // v2.8.6：网络超时 (不是 408 HTTP 状态，而是 URLSession 的 -1001）
                // 也可能是中转对完整载荷处理太慢/卡死，降级到轻量载荷很可能OK。
                // v7.2.3-audit2：坏体响应也纳入降级——中转 60s 内返回损坏响应体时
                // URLSession 报 CannotDecodeContentData(-1016)/CannotParseResponse(-1017)，
                // 中文即"无法解析响应"。此前不降级→单次 L0 死等 60s 后 failed。
                // 同一载荷偶发成功（如 Botcf 4653ms）证明是上游不稳定，轻量载荷大概率能过。
                // v7.1.267-fix3：SSL/连接层握手错误（-1202 SecureConnectionFailed / -1204 / -1205
                // 证书不受信等）——与 payload 无关（降级丢工具不值得），且主模型成功子代理失败的
                // 案例证明是瞬时/坏节点 TLS 协商（Botcf 多节点证书不一致）。
                // 同级别新连接重试（最多 2 次）——当前 0 轮 3s 直接 markFailed 是白跑。
                let isSSL = (err.code == -1202 || err.code == -1200 || err.code == -1204 || err.code == -1205
                    || error.localizedDescription.contains("SSL")
                    || error.localizedDescription.contains("安全连接"))
                if isSSL, self.sslRetryCount < 2 {
                    self.sslRetryCount += 1
                    NetworkLog.shared.log("\(self.config.name) L\(level) SSL handshake failed (\(err.code)) — retrying same level with a fresh connection (attempt \(self.sslRetryCount + 1)/3)")
                    self.attempt(level: level, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                    return
                }
                let isTimeout = (err.code == NSURLErrorTimedOut
                    || err.domain == NSURLErrorDomain && err.code == -1001
                    || err.code == NSURLErrorCannotDecodeContentData
                    || err.code == NSURLErrorCannotParseResponse
                    || error.localizedDescription.contains("timeout")
                    || error.localizedDescription.localizedLowercase.contains("timed out"))
                if isTimeout {
                    let v = self.fallbackVerdict(level: level, hasTools: tools != nil && !(tools?.isEmpty ?? true), avoidL5: avoidL5)
                    if !v.exhausted {
                        let remain = max(0, Int(self.overallDeadline.timeIntervalSinceNow))
                        NetworkLog.shared.log("\(self.config.name) L\(level) request timeout → auto-fallback to L\(v.next) (\(self.levelName(v.next)))")
                        onStatus?(L10n.t("status_timeout_simplify", v.next, self.maxLevel, remain))
                        self.attempt(level: v.next, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                        return
                    }
                }
                // 其它网络错误 (断网等）降级无意义
                let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                NetworkLog.shared.log("\(self.config.name) L\(level) network error (\(el)ms): \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0

            // v7.2.3-fix6：鉴权试探成功（2xx）→ 纠正配置并清 override（下次请求用新方式）
            if status >= 200 && status < 300, let alt = self.overrideAuthMethod {
                self.overrideAuthMethod = nil
                self.onAuthCorrected?(alt)
                NetworkLog.shared.log("\(self.config.name) authMethod auto-corrected to \(alt)")
            }

            // 部分中转站 HTTP 200 但 body 是 {"error": {...}}
            var errorPayload: String?
            if let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] {
                if let err = json["error"] as? [String: Any] {
                    errorPayload = (err["message"] as? String) ?? "\(err)"
                } else if let errStr = json["error"] as? String {
                    errorPayload = errStr
                }
            }

            // OK解析 choices
            if errorPayload == nil,
               let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first {
                // v4.3.36：思考自动升档——低/中档 (currentReasoningLevel 0/1）请求成功但响应
                // 无任何思考痕迹 (无 reasoning_content 且 completion_tokens_details.reasoning_tokens==0）时，
                // 自动以 high 重试一次。破甲站等中转 gpt-5.5 实测 low/medium 不触发思考，低中档形同关闭。
                let msgDict = firstChoice["message"] as? [String: Any]
                let hasReasoningText = (msgDict?["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let ctd = (json["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any]
                // v7.1.98：捕获真实 usage（prompt/completion/total tokens）→ 用量统计最近请求显示
                if let u = json["usage"] as? [String: Any] { self.lastUsage = u }
                let reasoningTokens = ctd?["reasoning_tokens"] as? Int ?? 0
                let lowMid = (self.currentReasoningLevel == 0 || self.currentReasoningLevel == 1)
                if !hasReasoningText, reasoningTokens <= 0, lowMid, !self.didAutoEscalateReasoning {
                    self.didAutoEscalateReasoning = true
                    let saved = self.currentReasoningLevel
                    self.currentReasoningLevel = 4   // v4.3.40：升到极限档 max (破甲站支持, 思考最多)
                    NetworkLog.shared.log("\(self.config.name): low/mid-tier response had no reasoning trace (reasoning_tokens=\(reasoningTokens)), auto-upgraded to max and retrying")
                    onStatus?(L10n.t("status_reasoning_upgraded"))
                    self.attempt(level: level, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                    self.currentReasoningLevel = saved
                    return
                }
                if level != self.currentCompatLevel {
                    let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                    NetworkLog.shared.log("\(self.config.name) level \(level) (\(self.levelName(level))) probe OK (\(el)ms), remembered this level, sending full request")
                    NetworkLog.lastCompatNote = "Model «\(self.config.name)» current compat level: \(level) (\(self.levelName(level)))"
                    self.persist(level: level)
                    self.currentCompatLevel = level;  // v6.0.30: 立刻更新内存里的兼容级别，避免递归时反复进试探分支死循环
                    // 试探成功，发完整用户请求
                    self.attempt(level: level, isFirst: true, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                    return
                }
                completion(.success(self.parseChoice(firstChoice)))
                return
            }

            // failed：判断是否可通过降级重试挽救
            let retryable = self.isRetryable(status: status, errorPayload: errorPayload)
            let failMsg = errorPayload ?? raw
            let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
            NetworkLog.shared.log("\(self.config.name) L\(level) failed (HTTP \(status), took \(el)ms): \(String(failMsg.prefix(200)))")

            // v2.9.299：模型非视觉 (VLM）错误——剥离全部图片后同级别重试一次
            let lowerErr = (errorPayload ?? "").lowercased()
            let isVLMError = lowerErr.contains("not a vlm") || lowerErr.contains("vision language model") || lowerErr.contains("vlm")
            if isVLMError, !self.imagesStrippedForVLM, messages.contains(where: { !($0.imageDataURLs ?? []).isEmpty }) {
                self.imagesStrippedForVLM = true
                // v7.1.109-peers：动态监测——模型非视觉错误 → 持久化标记不支持，
                // 下次 UI 不再让用户发图/发图前自动剥离（对齐 OpenMinis models.dev 能力表）
                VisionTracker.shared.record(model: self.config.model, supports: false)
                var stripped = messages
                for i in stripped.indices {
                    if !(stripped[i].imageDataURLs ?? []).isEmpty {
                        stripped[i].imageDataURLs = nil
                        stripped[i].content += "\n[📎 image auto-removed: current model can't see images (non-vision model)]"
                    }
                }
                NetworkLog.shared.log("\(self.config.name): model is non-vision, stripped images and retrying L\(level)")
                onStatus?(L10n.t("status_images_stripped"))
                self.attempt(level: level, isFirst: false, messages: stripped, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                return
            }

            // v7.3.0-scalpel-T5：413/上下文超限——页错误处理器（Claude Code reactiveCompact 同款）：
            // 任何估计体系都不完美，413 就是兜底层。只保最近 4 条 + 其余压成占位标记
            // （不调 LLM 摘要防递归），同级别重试一次；hasAttemptedReactiveCompact 单次守卫
            // 防重试循环，一次不够就把错误如实抛给用户。
            let overflowErr = NSError(domain: "OpenAIClient", code: status,
                userInfo: [NSLocalizedDescriptionKey: (errorPayload ?? raw) + " " + raw])
            if (status == 413 || self.isContextOverflow(overflowErr))
                && !self.hasAttemptedReactiveCompact
                && messages.count > Self.reactiveLastKeep {
                self.hasAttemptedReactiveCompact = true
                let keep = Array(messages.suffix(Self.reactiveLastKeep))
                let dropCount = messages.count - keep.count
                var compacted = keep
                if !compacted.isEmpty {
                    var last = compacted[compacted.count - 1]
                    last.content += "\n\n[context overflow recovery: \(dropCount) earlier messages compacted away]"
                    compacted[compacted.count - 1] = last
                }
                NetworkLog.shared.log("\(self.config.name) HTTP \(status) context overflow → reactive compact (keep last \(Self.reactiveLastKeep)), retrying L\(level)")
                onStatus?("⚠️ context overflow → compacted to last \(Self.reactiveLastKeep) messages, retrying…")
                self.attempt(level: level, isFirst: false, messages: compacted, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                return
            }

            if retryable {
                let v = self.fallbackVerdict(level: level, hasTools: tools != nil && !(tools?.isEmpty ?? true), avoidL5: avoidL5)
                if !v.exhausted {
                    NetworkLog.shared.log("\(self.config.name) auto-fallback → level \(v.next) (\(self.levelName(v.next)))")
                    self.attempt(level: v.next, isFirst: false, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                    return
                }
            }
            // v7.2.3-fix6：鉴权智能试探（对齐 OpenMinis BYOK）——401/403 且候选未试完：
            // 换鉴权方式重进 attempt（applyAuth 用 overrideAuthMethod），2xx 时纠正配置。
            // 只试安全集合（Bearer/API Key/Query api_key），不试 Body/Query token（罕见且易误伤）。
            if (status == 401 || status == 403) && !self.authProbeQueue.isEmpty {
                let alt = self.authProbeQueue.removeFirst()
                self.overrideAuthMethod = alt
                NetworkLog.shared.log("\(self.config.name) HTTP \(status) → auto-probing authMethod as \(alt)")
                onStatus?(L10n.t("status_auth_probing", alt))
                self.attempt(level: level, isFirst: isFirst, messages: messages, tools: tools, onStatus: onStatus, onDelta: onDelta, onThinking: onThinking, avoidL5: avoidL5, completion: completion)
                return
            }
            let hint = errorPayload != nil ? "" : "\nHint: response isn't standard OpenAI format, check that baseURL points to a /v1-compatible endpoint."
            completion(.failure(NSError(domain: "OpenAIClient", code: status,
                userInfo: [NSLocalizedDescriptionKey: "Request rejected (HTTP \(status), tried up to level \(level)·\(self.levelName(level)))\n\(String(failMsg.prefix(300)))\(hint)"])))
        }
        // v4.5.x：看门狗——响应挂起（中转半响应：响应头已到但 body 未完成）时，
        // URLSession timeoutInterval (25s) 不再触发，此看门狗到点强制 cancel → 走降级链。
        // 阈值随推理档位放宽，避免误杀 reasoning 模型正常思考期。
        // 声明已上移到函数开头（dataTask 闭包之前）；此处仅调度。
        activeTask = task
        task.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogSeconds(for: currentReasoningLevel), execute: watchdog)
    }

    // MARK: - 载荷构建

    private func buildBody(level: Int, messages: [ChatMessage], tools: [[String: Any]]?) -> [String: Any] {
        // 级别 ≥3：去掉 tools 后，历史中的 tool / tool_calls 消息必须降级为普通文本，否则请求体本身非法
        let sanitized: [ChatMessage]
        if level >= 3 {
            sanitized = messages.filter { $0.role != "tool" }.map { m in
                var mm = m
                mm.toolCalls = nil
                return mm
            }
        } else {
            // v7.2.3-audit4：运行时悬空 toolCalls 兜底——L5 Responses 回落 chat/completions、
            // 流式中断等场景会在历史里残留 assistant.toolCalls 无配对 tool 结果，
            // 服务端拒 400 ("assistant message with 'tool_calls' must be followed by tool
            // messages responding to each 'tool_call_id'")。此处补 isError 伪 tool 消息
            // 恢复序列合法（与 applyLoaded 启动恢复同法，覆盖运行中产生的悬空）。
            // v7.2.3-audit5：修复在 trimmedMessages 之后执行（裁剪会优先丢 tool 消息，
            // 先 repair 再裁剪会把刚补的伪消息裁掉又悬空）。
            sanitized = messages
        }

        // OpenAI Chat Completions / Custom Endpoint
        if level >= 4 {
            return ["model": config.model,
                    "messages": repairDanglingToolCalls(trimmedMessages(sanitized)).map { messageDict($0) }]
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": repairDanglingToolCalls(trimmedMessages(sanitized)).map { messageDict($0) },
            tokenKey(level: level): config.maxTokens
        ]
        if level < 3, config.sendsTemperature {
            body["temperature"] = config.temperature
        }
        // v2.9.20：推理强度由 UI 真实控制 (0低=low 1中=medium 2高=high）。
        // 低档仍比 none 有思考但显著提速；中档为默认。
        // 级别 4 (最小载荷）不带该字段——若中转连这个字段都不认，还有最后一级兜底。
        if config.isReasoningModel {
            body["reasoning_effort"] = reasoningEffortName()
            // v3.1.74：思考/回复语言跟随 App 设置 (设置 → 语言），不再硬编码中文
            // v3.1.33 曾强制简体中文思考；现在按 LanguageManager.shared.language 动态下发
            // Language instruction follows the App setting (Settings → Language); no narrate-before-execute requirement.
            let instr = LanguageManager.shared.isZh
                ? "你的思考过程 (reasoning/thinking)请始终使用简体中文输出。最终回复也使用简体中文，除非用户明确要求其他语言。"
                : "Always think and reply in English unless the user explicitly asks for another language."
            body["instructions"] = instr
        }
        if let tools = tools, !tools.isEmpty {
            if level < 3 {
                body["tools"] = tools
                if level < 2 {
                    body["tool_choice"] = "auto"
                }
            }
        }
        return body
    }

    /// v7.2.3-audit4：运行时悬空 toolCalls 修复——assistant.toolCalls 缺配对 tool 结果时
    /// 补 isError 伪消息（服务端要求 tool_calls 后必须有对应 tool_call_id 的 tool 消息，
    /// 且 tool 消息必须紧跟 assistant.toolCalls，不能插在末尾）。
    private func repairDanglingToolCalls(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pending: [(id: String, name: String)] = []
        func flushPending() {
            guard !pending.isEmpty else { return }
            for p in pending {
                var err = ChatMessage(role: "tool", content: "⚠️ Tool \(p.name) execution was interrupted by an app crash or protocol fallback (no result received).", isError: true)
                err.toolCallId = p.id
                err.toolName = p.name
                out.append(err)
            }
            pending = []
        }
        for m in msgs {
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                flushPending()  // 前一轮若残留先补（防御）
                pending = calls.map { ($0.id, $0.name) }
                out.append(m)
            } else if m.role == "tool", let id = m.toolCallId {
                // 只按 id 配对，不在此 flush——连续的 tool 消息各自配对不同的 toolCall，
                // 此前每处理一条就 flush，会把"还没轮到的后续 toolCall"误补成 crash 占位符
                // （多工具串行批第 2 个起结果全被顶替，正是用户实测"no result received"）。
                pending.removeAll { $0.id == id }
                out.append(m)
            } else {
                flushPending()  // user/assistant(无calls)/system 前补
                out.append(m)
            }
        }
        flushPending()
        return out
    }

    /// 级别 0 用模型偏好的 key；级别 1 互换 (中转站可能只认其中一个）
    private func tokenKey(level: Int) -> String {
        let preferred = config.maxTokensKey
        if level == 1 { return preferred == "max_completion_tokens" ? "max_tokens" : "max_completion_tokens" }
        return preferred
    }

    /// v2.9.20：推理强度名。0=low 1=medium 2=high 3=xhigh(最高) 4=max(极限) 5=none (完全不思考)
    /// v4.3.40：新增 3=xhigh——破甲站 gpt-5.5/gpt-6.1-sol 实测 xhigh 有效 (44/53 tokens, 介于 high 与 max 之间)。
    private func reasoningEffortName() -> String {
        switch currentReasoningLevel {
        case 0: return "low"
        case 2: return "high"
        case 3: return "xhigh"
        case 4: return "max"
        case 5: return "none"
        default: return "medium"
        }
    }

    /// v4.5.x：响应看门狗阈值（秒）——按推理档位放宽。
    /// reasoning 模型思考期无输出是正常状态，max 档思考可达 90s+，阈值必须分档避免误杀。
    /// none/low 45s：日志实证 low 档 119s 挂起 = 异常（中转挂起），45s 足够且不误伤。
    private static func watchdogSeconds(for reasoningLevel: Int) -> TimeInterval {
        switch reasoningLevel {
        case 0: return 45   // low
        case 1: return 60   // medium
        case 2, 3: return 90  // high / xhigh
        case 4: return 120  // max
        default: return 45  // none
        }
    }

    private func levelName(_ level: Int) -> String {
        switch level {
        case 0: return "Full payload"
        case 1: return "Swap token param names"
        case 2: return "Drop tool_choice"
        case 3: return "Drop tools, pure chat"
        case 4: return "Minimal payload"
        case 5: return "Responses API + tools"
        default: return "Unknown"
        }
    }

    /// 4xx 参数类错误可通过降级挽救；
    /// 5xx 网关/上游超时 (尤其 tools 过多导致 relay/gpt-5.6 超时或 500）降级到轻量载荷可能OK；
    /// 鉴权(401/402/403)、配额(429) 不降级。
    private func isRetryable(status: Int, errorPayload: String?) -> Bool {
        if status == 401 || status == 402 || status == 403 || status == 429 { return false }
        if status >= 400 && status < 500 { return true }
        // 502/503/504：网关错误 / 上游处理超时；500：terra 处理 tools 超限时报 server_error
        if status == 500 || status == 502 || status == 503 || status == 504 { return true }
        // HTTP 200 + error body (new-api 中转常见）：只有参数类错误才降级
        if let msg = errorPayload?.lowercased() {
            let keywords = ["invalid request parameter", "invalid_request", "unsupported parameter", "not supported",
                            "unknown parameter", "extra inputs", "参数", "invalid request"]
            return keywords.contains { msg.contains($0) }
        }
        // v7.2.3-audit2：HTTP 成功(<400)但 body 无法解析成 OpenAI 格式（中转坏体/空体/截断）→ 也降级。
        // 到此处说明 JSON 解析已失败且无 error 字段，轻量载荷大概率能绕开上游不稳定。
        if status < 400 { return true }
        return false
    }

    private func parseChoice(_ firstChoice: [String: Any]) -> ChatResult {
        if let message = firstChoice["message"] as? [String: Any] {
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                let calls: [ToolCall] = toolCalls.compactMap { tc in
                    guard let id = tc["id"] as? String,
                          let type = tc["type"] as? String, type == "function",
                          let fn = tc["function"] as? [String: Any],
                          let name = fn["name"] as? String,
                          let args = fn["arguments"] as? String else { return nil }
                    return ToolCall(id: id, name: name, arguments: args, toolTitle: ToolCall.extractTitle(from: args))
                }
                if !calls.isEmpty {
                    // v3.5.11：工具轮不再丢弃 reasoning——把 reasoning_content 存进 thinking(黄色思考气泡)。
                    // Codex/Claude Code 都是"一次流式里先思考/解说后工具"，这里补上非流式/解析路径漏接的思考。
                    // 之前 427 行直接 thinking:nil，模型在工具轮的思考被解析层扔掉。
                    let thinking = (message["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    var hasThinking = (thinking != nil && !thinking!.isEmpty)
                    if hasThinking {
                        // 去重：部分中转把完整回答写进 reasoning_content，与 content 相同则弃（避免重复展示）。
                        // 审计修复：content 可能是数组，as? String 会取到 ""，此时 rTrim.contains("") 恒为 true，
                        // 会把思考误删——只在 cText 非空时才做去重比较。
                        let cText = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = thinking!
                        if !cText.isEmpty, cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim) {
                            hasThinking = false
                        }
                    }
                    // v3.5.15：透传模型在工具轮写的正文解说(content)，供 runLoop 当 visibleText 兜底。
                    // 此前只带 thinking，非流式 chat/completions 会把模型写的解说丢光(用户实测根因)。
                    var narration = ""
                    if let content = message["content"] {
                        if let str = content as? String { narration = str }
                        else if let arr = content as? [[String: Any]] {
                            for c in arr {
                                let t = c["type"] as? String ?? ""
                                if t == "text" || t == "output_text" || t == "input_text" {
                                    if let tt = c["text"] as? String { narration += tt }
                                }
                            }
                        }
                    }
                    return .toolCalls(calls, thinking: hasThinking ? thinking : nil,
                                     content: narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : narration)
                }
            }
            // v2.9.297：content 兼容 字符串 / 数组 ([{"type":"text","text":"..."}] / [{"type":"output_text","text":"..."}]）
            var text = ""
            if let content = message["content"] {
                if let str = content as? String {
                    text = str
                }
                if let arr = content as? [[String: Any]] {
                    for c in arr {
                        let t = c["type"] as? String ?? ""
                        if t == "text" || t == "output_text" || t == "input_text" {
                            if let tt = c["text"] as? String { text += tt }
                        }
                    }
                    // 数组内没有文本 → 尝试 reasoning_content 里的总结
                    if text.isEmpty {
                        for c in arr {
                            if let rc = c["text"] as? String, !rc.isEmpty {
                                text += rc
                            }
                        }
                    }
                }
            }
            // v3.1.25：同时读取 reasoning_content 存到 thinking (之前被完全忽略了）
            let thinking = (message["reasoning_content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // v3.1.33：去重——部分中转/模型把完整回答写进 reasoning_content，与 content 完全相同
            //  (表现：思考内容和发送内容一模一样）。此时丢弃 thinking，避免重复展示。
            var hasThinking = (thinking != nil && !thinking!.isEmpty)
            if hasThinking {
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = thinking!
                if !trimmedText.isEmpty && (trimmedText == t || t.contains(trimmedText) || trimmedText.contains(t)) {
                    hasThinking = false
                }
                // 正文为空但 thinking 是完整回答 (模型把回答全放 reasoning）→ 转成正文
                if trimmedText.isEmpty, t.count > 40 {
                    text = t
                    hasThinking = false
                }
            }
            if !text.isEmpty || hasThinking {
                return .text(text, thinking: hasThinking ? thinking : nil)
            }
            return .text("", thinking: nil)
        }
        if let text = firstChoice["text"] as? String {
            return .text(text, thinking: nil)
        }
        return .text("", thinking: nil)
    }

    private func persist(level: Int) {
        // fix73j-p4：resolvedLevel 总记录（隔离场景也暴露最终 settle 级别给任务级缓存）；
        // persistCompatLevel=false（子代理）时不写回共享 ModelConfig——防双向污染。
        resolvedLevel = level
        guard persistCompatLevel else { return }
        DispatchQueue.main.async {
            guard let idx = ModelStore.shared.configs.firstIndex(where: { $0.id == self.config.id }) else { return }
            ModelStore.shared.configs[idx].compatLevel = level
            ModelStore.shared.save()
        }
    }

    // MARK: - Responses API (v2.9.0）

    /// OpenAI /v1/responses 端点 (Codex 同款）。
    /// GPT-5.6 家族的 function tools 在 chat/completions 上不可用/极慢，
    /// 但 Responses API 正常——用户在相同中转上 Codex 可运行即为证据。
    /// v2.9.48：加自动重试 (最多3次，指数退避 1s/2s）——网络错误/5xx/解析failed自动重试，不再需要手动点"继续"。
    private func performResponses(messages: [ChatMessage], tools: [[String: Any]]?, onStatus: ((String) -> Void)?, onThinking: ((String) -> Void)? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/responses") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])))
            return
        }

        /// 判断某次failed是否值得重试 (网络抖动/5xx/解析failed属于瞬时错误；4xx 参数/鉴权错误不重试）
        func shouldRetry(_ err: NSError, _ statusCode: Int) -> Bool {
            if err.domain == NSURLErrorDomain {
                let c = err.code
                // v7.2.3-audit2：+坏体响应码（中转返回损坏响应体 → 重试/降级）
                // v7.1.267-audit：+SSL 握手错误（-1202/-1200/-1204/-1205）——握手与 payload 无关，
                // 新连接重试可绕开 Botcf 坏节点（此前 SSL 直接失败→回落 L3 丢工具）
                return c == NSURLErrorTimedOut || c == NSURLErrorNetworkConnectionLost
                    || c == NSURLErrorCannotConnectToHost || c == NSURLErrorNotConnectedToInternet
                    || c == NSURLErrorCannotDecodeContentData || c == NSURLErrorCannotParseResponse
                    || c == -1202 || c == -1200 || c == -1204 || c == -1205
            }
            if statusCode >= 500 { return true }
            let d = err.localizedDescription
            if d.contains("解析failed") || d.contains("无法解析") { return true }
            return false
        }

        func fire(attempt: Int) {
            var request = URLRequest(url: url, timeoutInterval: 90)
            setHTTPMethod("POST", on: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request)

            var body: [String: Any] = [
                "model": config.model,
                "input": responsesInput(from: messages),
                "max_output_tokens": config.maxTokens
            ]
            if config.isReasoningModel {
                body["reasoning"] = ["effort": reasoningEffortName()]
            }
            if let tools = tools, !tools.isEmpty {
                body["tools"] = tools.map { responsesToolSchema($0) }
                body["tool_choice"] = "auto"
            }
            injectBodyAuth(into: &body)
            applyParamAliases(into: &body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            NetworkLog.shared.log("\(config.name) L5 Responses API+tools → POST /responses, fields: \(body.keys.sorted().joined(separator: ","))")
            if attempt > 0 {
                onStatus?(L10n.t("status_retry_responses", attempt + 1))
            } else {
                onStatus?(L10n.t("status_requesting_responses"))
            }

            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                if self.cancelled {
                    completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                        userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                // 1) 网络错误
                if let error = error {
                    let nsErr = error as NSError
                    NetworkLog.shared.log("\(self.config.name) L5 network error: \(nsErr.localizedDescription)")
                    if attempt < 2 && shouldRetry(nsErr, status) {
                        let delay = Double(1 << attempt)
                        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { fire(attempt: attempt + 1) }
                        return
                    }
                    completion(.failure(error))
                    return
                }
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"

                // 2) 解析 JSON (v2.9.46 兜底：标准 JSON / 截取 {..} / SSE data: 行）
                if let json = Self.extractJSONObject(raw) {
                    // 2a) API 显式 error
                    if let err = json["error"] as? [String: Any],
                       let msg = err["message"] as? String {
                        let nsErr = NSError(domain: "OpenAIClient", code: status,
                            userInfo: [NSLocalizedDescriptionKey: "Responses API error: \(msg)"])
                        if attempt < 2 && shouldRetry(nsErr, status) {
                            DispatchQueue.global().asyncAfter(deadline: .now() + Double(1 << attempt)) { fire(attempt: attempt + 1) }
                            return
                        }
                        let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                        NetworkLog.shared.log("\(self.config.name) L5 failed (HTTP \(status), took \(el)ms): \(msg)")
                        completion(.failure(nsErr))
                        return
                    }
                    // 2b) 正常 output
                    if let output = json["output"] as? [[String: Any]] {
                        var calls: [ToolCall] = []
                        var text = ""
                        var thinking = ""
                        for item in output {
                            let type = item["type"] as? String ?? ""
                            if type == "function_call",
                               let callId = item["call_id"] as? String,
                               let name = item["name"] as? String,
                               let args = item["arguments"] as? String {
                                calls.append(ToolCall(id: callId, name: name, arguments: args, toolTitle: ToolCall.extractTitle(from: args)))
                            }
                            if type == "reasoning" {
                                if let summary = item["summary"] as? [[String: Any]] {
                                    for sm in summary { if let st = sm["text"] as? String { thinking += st } }
                                }
                                if let contentArr = item["content"] as? [[String: Any]] {
                                    for cc in contentArr { if let st = cc["text"] as? String { thinking += st } }
                                }
                            }
                            if type == "message",
                               let content = item["content"] as? [[String: Any]] {
                                for c in content where (c["type"] as? String) == "output_text" {
                                    if let t = c["text"] as? String { text += t }
                                }
                            }
                        }
                        let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                        NetworkLog.shared.log("\(self.config.name) L5 (Responses API+工具)请求OK (\(el)ms)，已记忆该级别")
                        NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: 5 (Responses API+工具)"
                        self.persist(level: 5)
                        if !calls.isEmpty {
                            let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            completion(.success(.toolCalls(calls, thinking: t.isEmpty ? nil : t, content: n.isEmpty ? nil : n)))
                        } else {
                            let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                            completion(.success(.text(text, thinking: t.isEmpty ? nil : t)))
                        }
                        return
                    }
                }

                // 3) 解析failed (非标准 JSON / 无 output）
                let nsErr = NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Responses parse failed: \(raw.prefix(300))"])
                if attempt < 2 && shouldRetry(nsErr, status) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(1 << attempt)) { fire(attempt: attempt + 1) }
                    return
                }
                completion(.failure(nsErr))
            }
            activeTask = task
            task.resume()
        }
        fire(attempt: 0)
    }

    /// v2.9.46：从原始响应体中提取 JSON 对象 (兜底解析，解决"无法解析响应"）。
    /// 兼容：①标准 JSON；②前后夹带日志/空白；③SSE 流 (collected data: 行拼成 JSON）。
    private static func extractJSONObject(_ raw: String) -> [String: Any]? {
        // 1) 直接解析
        if let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] { return j }
        // 2) 截取第一个 { 到最后一个 } (夹带前缀/后缀）
        if let i = raw.firstIndex(of: "{"), let j = raw.lastIndex(of: "}"), i < j {
            let sub = String(raw[i...j])
            if let jj = try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [String: Any] { return jj }
        }
        // 3) SSE：collected "data: {...}" 或 "data:{...}" 行，拼接后重试
        var sseAccum = ""
        for line in raw.components(separatedBy: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("data:") {
                l = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if l == "[DONE]" { continue }
                sseAccum += l
            }
        }
        if !sseAccum.isEmpty {
            if let j = try? JSONSerialization.jsonObject(with: Data(sseAccum.utf8)) as? [String: Any] { return j }
            if let i = sseAccum.firstIndex(of: "{"), let j = sseAccum.lastIndex(of: "}"), i < j {
                let sub = String(sseAccum[i...j])
                if let jj = try? JSONSerialization.jsonObject(with: Data(sub.utf8)) as? [String: Any] { return jj }
            }
        }
        return nil
    }

    /// v7.3.0-scalpel-T2-tokenSaverOutput：大工具结果压缩视图（对齐 Claude Code BashTool
    /// tokenSaverOutput——全量输出进 UI/日志，压缩版进模型。单优化每会话可省数万 token，
    /// 且不动会话内存历史：只改发往模型的请求快照。仅截内容、不删消息 → 配对不受影响）
    private func tokenSaverView(_ m: ChatMessage) -> ChatMessage {
        var mm = m
        if mm.role == "tool", mm.content.count > Self.tokenSaverMaxChars {
            let c = mm.content
            let head = String(c.prefix(Self.tokenSaverHeadChars))
            let tail = String(c.suffix(Self.tokenSaverTailChars))
            let omitted = c.count - Self.tokenSaverHeadChars - Self.tokenSaverTailChars
            mm.content = head + "\n…[tool 输出过长：省略中间 \(omitted) 字符（完整结果已存会话日志，需要时用工具重新获取）]…\n" + tail
        }
        return mm
    }

    /// v2.9.292：历史图片裁剪——只保留最近 imageBudget 条带图消息的图片，
    /// 更早的图片置空并加文字占位。用于 chat/completions 序列化路径，
    /// 避免历史 base64 图片每次请求全量重发导致 body 巨大 → 卡住/超时。
    private func trimmedMessages(_ messages: [ChatMessage], imageBudget: Int = 2) -> [ChatMessage] {
        // v3.6.19l / v7.3.0-scalpel：上下文按 TOKEN 预算裁剪（Claude Code 手术刀三层：
        // tokenSaverOutput 压缩视图 → T2 LRU 归档最旧 → T3 渐进退化），防止超长会话
        // 撑爆模型上下文窗口导致"卡死不回复"(空 completion)。
        // 策略: 始终保留最近 6 条 + 最新 user；超预算时优先归档最旧 tool 结果(最占空间)，
        // 再归档旧 assistant/user，直到低于预算；被归档的部分在最后一条保留消息上标记。
        // v7.2.5-fix64：成对裁剪——删 tool 结果必删配对 assistant.toolCalls id（自洽，
        // 杜绝 repairDanglingToolCalls 误补 "interrupted" 伪错误）。
        let KEEP_LAST = 6                  // 始终保留的最近消息数
        var budget = imageBudget
        var out: [ChatMessage] = []
        // --- tokenSaverOutput：先压缩大工具结果视图（内容截断，不删消息）---
        var arr = messages.map { tokenSaverView($0) }
        let budgetTokens = historyTokenBudget()
        if estimateTotalTokens(arr) > budgetTokens {
            // 记录归档了多少条
            var dropped = 0
            // 保底: 找到最后一条 user 的索引，裁剪不越过它(保证当前诉求在)
            var lastUserIdx = -1
            for (i, m) in arr.enumerated() where m.role == "user" { lastUserIdx = i }
            // 优先归档最旧的 tool 消息(不越过 lastUserIdx - 1 和 保底尾巴)
            let cutFloor = max(0, lastUserIdx - 1)
            var droppedAny = true
            while estimateTotalTokens(arr) > budgetTokens && droppedAny {
                droppedAny = false
                var i = 0
                while i < arr.count {
                    if i < cutFloor || i < max(0, arr.count - 6) {
                        if arr[i].role == "tool" {
                            // v7.2.5-fix64：成对裁剪——删除 tool 结果时同步从配对 assistant.toolCalls
                            // 移除该 id（assistant 的 toolCalls 清空则连同 assistant 一起删），保证消息流
                            // 自洽。此前只删 tool 结果 → 后续 repairDanglingToolCalls 把被删旧结果误补成
                            // "interrupted by an app crash or protocol fallback" 伪错误——长会话 AI 每轮
                            // 请求都看到这条假报错，误判"通道断/App 崩溃"（工具实际一直成功）。
                            let tid = arr[i].toolCallId
                            if let tid = tid {
                                for j in stride(from: i - 1, through: 0, by: -1) where arr[j].role == "assistant" {
                                    if var calls = arr[j].toolCalls, calls.contains(where: { $0.id == tid }) {
                                        calls.removeAll { $0.id == tid }
                                        if calls.isEmpty {
                                            arr.remove(at: j)   // 整对删除（j < i，删后 i 指向的 tool 前移一位）
                                            i -= 1
                                        } else {
                                            arr[j].toolCalls = calls
                                        }
                                        break
                                    }
                                }
                            }
                            arr.remove(at: i); dropped += 1; droppedAny = true; break
                        }
                    }
                    i += 1
                }
                if !droppedAny {
                    // tool 归档完还不够 → 归档最旧 assistant/user(不越过 cutFloor 和保底)
                    for i in 0..<arr.count where i < cutFloor || i < max(0, arr.count - 6) {
                        // v7.2.5-fix64：assistant.toolCalls 与其 tool 结果成对删——删掉带调用声明的
                        // assistant 却留下孤立 tool 消息，服务端会因 tool 消息无配对 assistant 报 400。
                        if arr[i].role == "assistant", let calls = arr[i].toolCalls, !calls.isEmpty {
                            let ids = Set(calls.map { $0.id })
                            var k = i + 1
                            while k < arr.count {
                                if arr[k].role == "tool", let tid = arr[k].toolCallId, ids.contains(tid) {
                                    arr.remove(at: k)
                                } else {
                                    k += 1
                                }
                            }
                        }
                        arr.remove(at: i); dropped += 1; droppedAny = true; break
                    }
                }
            }
            // --- v4.3.66 / v7.3.0-scalpel-T3：渐进退化兜底（Claude Code 分节渐进同款——
            // 不是悬崖式一次砍完，而是多轮渐进截断）。预算循环只丢「最近 6 条之外」的消息，
            // 若保底区内本身就有超大单条（如刚 dump 的大文件/tool 结果），循环退出后仍可能
            // 超预算 → API 413。对剩余中 content 最长的一条做头部截断（保留 2/3 + 提示），
            // 每轮只截一条、最多 8 轮 → 内容渐进退化、不删消息、不丢语义锚点。
            var guardPass = 0
            while estimateTotalTokens(arr) > budgetTokens && guardPass < 8 {
                guardPass += 1
                var maxIdx = -1
                var maxLen = 0
                for (i, m) in arr.enumerated() {
                    let l = m.content.count + (m.thinking?.count ?? 0)
                    if l > maxLen { maxLen = l; maxIdx = i }
                }
                guard maxIdx >= 0, maxLen > 1000 else { break }
                var m = arr[maxIdx]
                let keep = max(1000, maxLen * 2 / 3)
                let omitted = maxLen - keep
                m.content = String(m.content.prefix(keep))
                if m.thinking != nil { m.thinking = String((m.thinking ?? "").prefix(keep)) }
                m.content += "\n\n[单条内容过长已截断: 省略约 \(omitted) 字符，如需完整内容请重新调用该工具获取]"
                arr[maxIdx] = m
            }
            if dropped > 0 && !arr.isEmpty {
                // 把截断标记加在最后一条非空内容的消息上(避免加在空回复上不可见)
                var anchor = arr.count - 1
                while anchor > 0 && arr[anchor].content.isEmpty { anchor -= 1 }
                var m = arr[anchor]
                m.content += "\n\n[早期上下文已归档: 会话过长已省略 \(dropped) 条历史消息]"
                arr[anchor] = m
            }
        }
        // --- 原图片裁剪逻辑 ---
        for m in arr.reversed() {
            var mm = m
            if let imgs = mm.imageDataURLs, !imgs.isEmpty {
                if budget > 0 {
                    budget -= 1
                } else {
                    mm.imageDataURLs = nil
                    mm.content += "\n[图片已省略：历史图片过多，仅保留最近 \(imageBudget) 条]"
                }
            }
            out.append(mm)
        }
        return out.reversed()
    }

    /// 把内部消息历史转换为 Responses API 的 input 数组。
    /// - 普通消息 → {"role": ..., "content": ...}
    /// - assistant 带 toolCalls → message + 逐个 {"type":"function_call", ...}
    /// - tool 结果 → {"type":"function_call_output", ...}
    private func responsesInput(from messages: [ChatMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        // v2.9.292：历史图片裁剪——只保留最近 2 条带图消息的图片，
        // 更早的图片替换为文字占位。否则历史里每张 base64 图每次请求全量重发，
        // body 越积越大 → AI 回消息/看图卡住 (用户实证：新对话发文字才正常）。
        var imgBudget = 2
        for m in messages {
            if m.role == "tool" {
                items.append([
                    "type": "function_call_output",
                    "call_id": m.toolCallId ?? "",
                    "output": m.content
                ])
                continue
            }
            if let calls = m.toolCalls, !calls.isEmpty {
                if !m.content.isEmpty {
                    items.append(["role": "assistant", "content": m.content])
                }
                for c in calls {
                    items.append([
                        "type": "function_call",
                        "call_id": c.id,
                        "name": c.name,
                        "arguments": c.arguments
                    ])
                }
                continue
            }
            // v2.9.9：多模态。图片消息在 Responses API 中同样用 content 数组。
            if let imgs = m.imageDataURLs, !imgs.isEmpty {
                var content: [[String: Any]] = [["type": "input_text", "text": m.content]]
                if imgBudget > 0 {
                    for u in imgs {
                        content.append(["type": "input_image", "image_url": u])
                    }
                } else {
                    content = [["type": "input_text", "text": m.content + "\n[Images omitted: too many in history, keeping only the last 2]"]]
                }
                imgBudget -= 1
                items.append(["role": m.role, "content": content])
                continue
            }
            items.append(["role": m.role, "content": m.content])
        }
        return items
    }

    /// chat/completions 的嵌套工具 schema → Responses 的扁平格式
    /// {"type":"function","function":{"name":...}} → {"type":"function","name":...}
    private func responsesToolSchema(_ chatTool: [String: Any]) -> [String: Any] {
        if let fn = chatTool["function"] as? [String: Any] {
            var flat: [String: Any] = ["type": "function"]
            if let n = fn["name"] as? String { flat["name"] = n }
            if let d = fn["description"] as? String { flat["description"] = d }
            if let p = fn["parameters"] { flat["parameters"] = p }
            return flat
        }
        return chatTool
    }

    // MARK: - Gemini (generateContent 原生协议)

    /// v7.1.109-peers：Gemini 原生协议实现——
    /// 端点 {base}/models/{model}:streamGenerateContent?alt=sse（流式）或 :generateContent（回落）
    /// 认证：预设 Query key（?key=）或 applyAuth x-goog-api-key；
    /// 请求体 contents/parts/inline_data/systemInstruction/functionDeclarations；
    /// SSE 事件 candidates[0].content.parts（text / thought / functionCall）。
    private func performGemini(messages: [ChatMessage], tools: [[String: Any]]? = nil,
                               onStatus: ((String) -> Void)?,
                               onDelta: ((String) -> Void)?,
                               onThinking: ((String) -> Void)? = nil,
                               completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encModel = config.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.model
        var urlStr = base + "/models/" + encModel + ":streamGenerateContent?alt=sse"
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        if method == "Query key" || method == "Query api_key" {
            let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // v7.1.267-audit: 去掉强制解包——编码失败回落原文（崩溃风险修）
            if !key.isEmpty {
                let encKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                urlStr += "&key=" + encKey
            }
        }
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)

        // v7.1.109-peers：消息转换——role user/model，图片 inline_data（base64），system → systemInstruction
        var contents: [[String: Any]] = []
        var systemText = ""
        for m in messages {
            if m.role == "system" {
                if !m.content.isEmpty { systemText += (systemText.isEmpty ? "" : "\n") + m.content }
                continue
            }
            var parts: [[String: Any]] = []
            if !m.content.isEmpty { parts.append(["text": m.content]) }
            for img in m.imageDataURLs ?? [] {
                // data:image/jpeg;base64,xxx → inline_data
                if let comma = img.firstIndex(of: ",") {
                    let meta = String(img[..<comma])
                    let mime = meta.replacingOccurrences(of: "data:", with: "").components(separatedBy: ";").first ?? "image/jpeg"
                    let b64 = String(img[img.index(after: comma)...])
                    parts.append(["inline_data": ["mime_type": mime, "data": b64]])
                }
            }
            // 工具轮结果：tool 消息 → functionResponse part
            if m.role == "tool", let name = m.toolName {
                let resp: Any = m.content
                parts.append(["functionResponse": ["name": name, "response": ["result": resp]]])
            }
            if !parts.isEmpty {
                let role = (m.role == "assistant" || m.role == "model") ? "model" : "user"
                contents.append(["role": role, "parts": parts])
            }
        }
        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": ["maxOutputTokens": config.maxTokens > 0 ? config.maxTokens : 4096]
        ]
        if !systemText.isEmpty { body["systemInstruction"] = ["parts": [["text": systemText]]] }
        if let tools = tools, !tools.isEmpty {
            // OpenAI function schema → Gemini functionDeclarations（name/description/parameters 同构）
            body["tools"] = [["functionDeclarations": tools]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        onStatus?(L10n.t("status_streaming_responses"))

        var fullText = ""
        var fullThinking = ""
        var toolCalls: [ToolCall] = []
        var firstByteReceived = false
        var fellBackToNonStream = false
        let completionLock = NSLock()
        var completionCalled = false
        let guardedCompletion: (Result<ChatResult, Error>) -> Void = { r in
            completionLock.lock()
            if completionCalled { completionLock.unlock(); return }
            completionCalled = true
            completionLock.unlock()
            completion(r)
        }

        let delegate = SSEStreamDelegate()
        let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let firstByteTimer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !firstByteReceived && !fellBackToNonStream {
                fellBackToNonStream = true
                NetworkLog.shared.log("\(self.config.name): Gemini 流式首字节超时 (10s)，回落非流式")
                streamSession.invalidateAndCancel()
                self.performGeminiNonStream(messages: messages, tools: tools, body: body, url: url, applyAuth: { [weak self] r in self?.applyAuth(to: &r) }, completion: guardedCompletion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: firstByteTimer)

        var idleTimer: DispatchWorkItem?
        func resetIdleWatchdog() {
            idleTimer?.cancel()
            let t = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.cancelled || fellBackToNonStream { return }
                NetworkLog.shared.log("\(self.config.name): Gemini 流式 idle 超时 (30s)，掐断")
                streamSession.invalidateAndCancel()
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3040,
                    userInfo: [NSLocalizedDescriptionKey: "Stream stalled: no SSE event for 30s"])))
            }
            idleTimer = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
        }

        delegate.onEvent = { [weak self] raw in
            guard let self = self else { return }
            if !firstByteReceived {
                firstByteReceived = true
                firstByteTimer.cancel()
                resetIdleWatchdog()
                onStatus?(L10n.t("status_connected", Double(Int(Date().timeIntervalSince(self.requestStart) * 1000)) / 1000.0))
            }
            resetIdleWatchdog()
            if fellBackToNonStream { return }
            guard let ev = self.parseSSEEvent(raw) else { return }
            // Gemini SSE: {"candidates":[{"content":{"parts":[...]},"finishReason":"..."}],"usageMetadata":{...}}
            guard let json = ev.json as? [String: Any] else { return }
            if let um = json["usageMetadata"] as? [String: Any] {
                let pt = um["promptTokenCount"] as? Int ?? 0
                let ct = um["candidatesTokenCount"] as? Int ?? 0
                self.lastUsage = ["prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct]
            }
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return }
            for part in parts {
                if let fn = part["functionCall"] as? [String: Any] {
                    let name = fn["name"] as? String ?? ""
                    let args = fn["args"] as? [String: Any] ?? [:]
                    let argsStr = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(ToolCall(id: "gemini-\(toolCalls.count)", name: name, arguments: argsStr, toolTitle: ToolCall.extractTitle(from: argsStr)))
                } else if let text = part["text"] as? String, !text.isEmpty {
                    if (part["thought"] as? Bool) == true {
                        fullThinking += text
                        let d = text
                        DispatchQueue.main.async { onThinking?(d) }
                    } else {
                        fullText += text
                        let d = text
                        DispatchQueue.main.async { onDelta?(d) }
                    }
                }
            }
        }
        delegate.onComplete = { [weak self] err in
            guard let self = self else { return }
            idleTimer?.cancel()
            if fellBackToNonStream { return }
            if let err = err {
                NetworkLog.shared.log("\(self.config.name): Gemini 流式错误 \(err.localizedDescription)")
                guardedCompletion(.failure(err))
                return
            }
            if !toolCalls.isEmpty {
                guardedCompletion(.success(.toolCalls(toolCalls, thinking: fullThinking.isEmpty ? nil : fullThinking, content: fullText.isEmpty ? nil : fullText)))
            } else if !fullText.isEmpty {
                guardedCompletion(.success(.text(fullText, thinking: fullThinking.isEmpty ? nil : fullThinking)))
            } else {
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3001,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini 空响应"])))
            }
        }
        let task = streamSession.dataTask(with: request)
        activeTask = task
        task.resume()
    }

    /// Gemini 非流式回落（首字节超时/中转不推 SSE 时）
    private func performGeminiNonStream(messages: [ChatMessage], tools: [[String: Any]]?, body: [String: Any], url: URL, applyAuth: (inout URLRequest) -> Void, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let urlStr = url.absoluteString.replacingOccurrences(of: ":streamGenerateContent?alt=sse", with: ":generateContent")
        // v7.1.267-audit: 去掉强制解包——构造失败走失败回调（崩溃风险修）
        guard let nonStreamURL = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL after replacing stream endpoint"])))
            return
        }
        var request = URLRequest(url: nonStreamURL, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let err = err {
                completion(.failure(err)); return
            }
            guard let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(NSError(domain: "OpenAIClient", code: -3001, userInfo: [NSLocalizedDescriptionKey: "Gemini 响应解析失败"])))
                return
            }
            if let um = json["usageMetadata"] as? [String: Any] {
                let pt = um["promptTokenCount"] as? Int ?? 0
                let ct = um["candidatesTokenCount"] as? Int ?? 0
                self.lastUsage = ["prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct]
            }
            guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                completion(.failure(NSError(domain: "OpenAIClient", code: -3001, userInfo: [NSLocalizedDescriptionKey: "Gemini 空响应"])))
                return
            }
            var text = ""
            var toolCalls: [ToolCall] = []
            for part in parts {
                if let fn = part["functionCall"] as? [String: Any] {
                    let name = fn["name"] as? String ?? ""
                    let args = fn["args"] as? [String: Any] ?? [:]
                    let argsStr = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(ToolCall(id: "gemini-\(toolCalls.count)", name: name, arguments: argsStr, toolTitle: ToolCall.extractTitle(from: argsStr)))
                } else if let t = part["text"] as? String { text += t }
            }
            if !toolCalls.isEmpty {
                completion(.success(.toolCalls(toolCalls, thinking: nil, content: text.isEmpty ? nil : text)))
            } else if !text.isEmpty {
                completion(.success(.text(text, thinking: nil)))
            } else {
                completion(.failure(NSError(domain: "OpenAIClient", code: -3001, userInfo: [NSLocalizedDescriptionKey: "Gemini 空响应"])))
            }
        }
        task.resume()
    }

    // MARK: - v7.4.0-fix73 后台非流式请求构建（BackgroundLLM 切后台代传用）

    /// 切后台时把在途请求转成非流式请求（复用现有 body/鉴权/别名构建）——
    /// 由 background session 系统代传（App 挂起/被杀也能完成）。
    /// 仅支持 OpenAI Chat + Responses（覆盖绝大多数中转）；Gemini/Anthropic
    /// 返回 nil → BackgroundLLM 跳过 → 由 fix72 回前台自动重试兜底。
    func makeBackgroundRequest(messages: [ChatMessage], tools: [[String: Any]]?) -> URLRequest? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if config.apiProtocol == "OpenAI Responses" {
            guard let url = URL(string: base + "/responses") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 120)
            setHTTPMethod("POST", on: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request)
            var body: [String: Any] = [
                "model": config.model,
                "input": responsesInput(from: messages),
                "max_output_tokens": config.maxTokens,
                "stream": false
            ]
            if config.isReasoningModel { body["reasoning"] = ["effort": reasoningEffortName()] }
            if let tools = tools, !tools.isEmpty {
                body["tools"] = tools.map { responsesToolSchema($0) }
                body["tool_choice"] = "auto"
            }
            injectBodyAuth(into: &body)
            applyParamAliases(into: &body)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        }
        // OpenAI Chat（默认）——chat/completions 非流式（该路径无 stream 字段）
        guard let url = URL(string: base + "/chat/completions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 120)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        // fix73b-audit：用记忆的兼容级别（而非硬编码 L0）——该中转已验证过的载荷形态
        // （如 L2 去 tool_choice）后台重发更稳，避免完整载荷被 502（用户实测 Botcf L0 502）
        var body = buildBody(level: currentCompatLevel, messages: messages, tools: tools)
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Anthropic

    private func performAnthropic(messages: [ChatMessage], tools: [[String: Any]]? = nil, completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/messages") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "messages": trimmedMessages(messages).map { messageDict($0) }
        ]
        // v2.9.175：Anthropic 协议也传工具 (此前完全没传 tools，AI 一个 schema 都看不到，
        // 只能靠 system prompt 文字描述脑补工具名——"app.decrypt 够不到"的根因之一）。
        // OpenAI function schema → Anthropic tools 格式转换。
        if let tools, !tools.isEmpty {
            var anthropicTools: [[String: Any]] = []
            for t in tools {
                guard let fn = t["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let desc = fn["description"] as? String else { continue }
                let params = fn["parameters"] as? [String: Any] ?? [:]
                var inputSchema = params
                inputSchema["type"] = "object"
                anthropicTools.append([
                    "name": name,
                    "description": desc,
                    "input_schema": inputSchema
                ])
            }
            if !anthropicTools.isEmpty {
                body["tools"] = anthropicTools
            }
        }
        // v2.9.107：Anthropic 标准协议 system 提至顶层 (此前 role=system 混在 messages 里，
        // 部分严格中转会拒；同时为 cache_control 断点注入提供 system 块）
        if var msgs = body["messages"] as? [[String: Any]] {
            let systemMsgs = msgs.filter { ($0["role"] as? String) == "system" }
            if !systemMsgs.isEmpty {
                var systemBlocks: [[String: Any]] = []
                for sm in systemMsgs {
                    if let text = sm["content"] as? String, !text.isEmpty {
                        systemBlocks.append(["type": "text", "text": text])
                    }
                }
                if !systemBlocks.isEmpty {
                    body["system"] = systemBlocks
                    msgs.removeAll { ($0["role"] as? String) == "system" }
                    body["messages"] = msgs
                }
            }
            // v2.9.107：cache_control 断点injected (对齐 cc-switch cache_injector 4 断点策略）
            CacheInjector.injectAnthropic(body: &body)
        }
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { data, response, error in
            if self.cancelled {
                completion(.failure(NSError(domain: "OpenAIClient", code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "Request cancelled"])))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
            guard let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(300))"])))
                return
            }
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                completion(.failure(NSError(domain: "OpenAIClient", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Anthropic error: \(msg)"])))
                return
            }
            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                completion(.failure(NSError(domain: "OpenAIClient", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(300))"])))
                return
            }
            completion(.success(.text(text, thinking: nil)))
        }
        activeTask = task
        task.resume()
    }

    // MARK: - 消息序列化

    private func messageDict(_ msg: ChatMessage) -> [String: Any] {
        if msg.role == "tool" {
            return [
                "role": "tool",
                "tool_call_id": msg.toolCallId ?? "",
                "content": msg.content
            ]
        }
        if let calls = msg.toolCalls, !calls.isEmpty {
            return [
                "role": "assistant",
                "content": msg.content,
                "tool_calls": calls.map { [
                    "id": $0.id,
                    "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ] }
            ]
        }
        // v2.9.9：多模态。消息带图片时 content 序列化为多模态数组。
        if let imgs = msg.imageDataURLs, !imgs.isEmpty {
            var content: [[String: Any]] = [["type": "text", "text": msg.content]]
            for u in imgs {
                content.append(["type": "image_url", "image_url": ["url": u]])
            }
            return ["role": msg.role, "content": content]
        }
        return ["role": msg.role, "content": msg.content]
    }

    // MARK: - 鉴权

    private func applyAuth(to request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // v7.2.3-fix6：鉴权智能试探——401 试探期用 override 方式；平时用配置方式
        let method = (overrideAuthMethod ?? config.authMethod).trimmingCharacters(in: .whitespacesAndNewlines)
        // v7.1.109-peers：协议级 header——
        // OpenRouter：X-Title + HTTP-Referer（官方要求，缺失会限流/不推荐）；
        // Gemini：x-goog-api-key header（Query key 走 URL 时不需要）
        if config.apiProtocol == "OpenRouter" {
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.setValue("TrollAgent", forHTTPHeaderField: "X-Title")
            request.setValue("https://github.com", forHTTPHeaderField: "HTTP-Referer")
            return
        }
        if config.apiProtocol == "Gemini" && method != "Query key" && method != "Query api_key" {
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            return
        }
        switch method {
        case "Bearer":
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case "API Key":
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        case "Query token":
            if !key.isEmpty, let u = request.url {
                request.url = Self.appendingQueryItem("token", value: key, to: u)
            }
        case "Query api_key":
            if !key.isEmpty, let u = request.url {
                request.url = Self.appendingQueryItem("api_key", value: key, to: u)
            }
        case "None":
            break
        case "Body api_key", "Body token":
            // body 认证：由 injectBodyAuth 在 httpBody 设置前注入到 JSON body 里
            break
        default:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    /// body 认证（Body api_key / Body token）：把 key 注入请求体顶层。
    private func injectBodyAuth(into body: inout [String: Any]) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return }
        switch method {
        case "Body api_key":
            body["api_key"] = key
        case "Body token":
            body["token"] = key
        default:
            break
        }
    }

    /// v3.5.13：可配置参数名别名——把 body 里"标准键"重命名为该供应商认的键。
    /// 例：config.paramAliases = {"max_tokens":"max_completion_tokens"}。
    private func applyParamAliases(into body: inout [String: Any]) {
        let aliases = config.paramAliases
        if aliases.isEmpty { return }
        for (standard, alias) in aliases {
            guard !standard.isEmpty, !alias.isEmpty, standard != alias else { continue }
            if let v = body.removeValue(forKey: standard) {
                body[alias] = v
            }
        }
    }

    /// 给 URL 追加单个 query 项（已含 ? 或 &，不重复添加同名键）。
    private static func appendingQueryItem(_ name: String, value: String, to url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents(string: url.absoluteString) ?? URLComponents()
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? url
    }

    // MARK: - v2.9.53 SSE 流式

    /// SSE 流式 delegate：接收增量数据，按 \n\n 切分事件，回调 onEvent。
    private class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
        var onEvent: ((String) -> Void)?   // 每个完整 SSE 事件的原始文本
        var onComplete: ((Error?) -> Void)?
        private var buffer = Data()

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffer.append(data)
            // SSE 事件以 \n\n 分隔
            while true {
                guard let range = buffer.range(of: Data("\n\n".utf8)) else { break }
                let eventData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if let text = String(data: eventData, encoding: .utf8) {
                    onEvent?(text)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                onEvent?(text)
                buffer.removeAll()
            }
            onComplete?(error)
        }
    }

    /// 解析单个 SSE 事件，返回 (type, delta, fullJson)。
    /// 兼容：event: xxx + data: {...}，或只有 data: {...} (type 在 JSON 里）。
    private func parseSSEEvent(_ raw: String) -> (type: String, delta: String, json: [String: Any])? {
        var eventType = ""
        var dataJson = ""
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("event:") {
                eventType = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("data:") {
                dataJson += String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !dataJson.isEmpty, dataJson != "[DONE]" else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(dataJson.utf8)) as? [String: Any] else { return nil }
        let type = eventType.isEmpty ? (json["type"] as? String ?? "") : eventType
        let delta = json["delta"] as? String ?? ""
        return (type, delta, json)
    }

    /// v2.9.53：Responses API 流式请求 (SSE）。
    /// - onDelta: 文本增量回调 (逐字显示）
    /// - completion: 响应done后回调 (完整 output 解析为 .text / .toolCalls）
    private func performResponsesStream(messages: [ChatMessage], tools: [[String: Any]]?,
                                        onStatus: ((String) -> Void)?,
                                        onDelta: ((String) -> Void)?,
                                        onThinking: ((String) -> Void)? = nil,
                                        completion: @escaping (Result<ChatResult, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/responses") else {
            completion(.failure(NSError(domain: "OpenAIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeoutOverride ?? 90)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)

        var body: [String: Any] = [
            "model": config.model,
            "input": responsesInput(from: messages),
            "max_output_tokens": config.maxTokens,
            "stream": true
        ]
        if config.isReasoningModel {
            body["reasoning"] = ["effort": reasoningEffortName()]
        }
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools.map { responsesToolSchema($0) }
            body["tool_choice"] = "auto"
        }
        injectBodyAuth(into: &body)
        applyParamAliases(into: &body)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        onStatus?(L10n.t("status_streaming_responses"))
        // v7.4.0-fix73c：流式在途标志——后台代传检测用（只有流式请求才值得 cancel+非流式重发，
        // 参数形态真的变了；非流式请求重发 = 同参数 = 纯 token 浪费，OpenMinis 同原则）
        isStreamingInFlight = true

        // 累积状态
        var fullText = ""
        var fullThinking = ""
        var toolCalls: [ToolCall] = []
        var currentCallId = ""
        var currentCallName = ""
        var currentCallArgs = ""
        var completedResponse: [String: Any]?
        // v2.9.54：首字节超时降级——中转站可能不支持 SSE 流式或缓冲响应，
        // 10 秒内没收到第一个事件就自动切回非流式 performResponses
        var firstByteReceived = false
        var fellBackToNonStream = false

        // v2.9.87：修复流式/非流式双 completion 竞态——
        // firstByteTimer 跑主线程、SSE 回调跑 URLSession 内部队列，
        // 10s 边界上可能两条路径都调 completion (后到覆盖先到 → 回复被吞/重复）。
        // 统一走 guardedCompletion，任何路径只能done一次。
        let completionLock = NSLock()
        var completionCalled = false
        let guardedCompletion: (Result<ChatResult, Error>) -> Void = { [weak self] r in
            completionLock.lock()
            if completionCalled { completionLock.unlock(); return }
            completionCalled = true
            completionLock.unlock()
            // v7.4.0-fix73c：流式结束（成功/失败/降级均经过此出口）→ 清标志
            self?.isStreamingInFlight = false
            completion(r)
        }

        let delegate = SSEStreamDelegate()
        // v7.4.0-fix73g：流式 session 也应用 requestTimeoutOverride（子代理场景），
        // 主会话 nil → .default 行为完全不变。
        let streamCfg = URLSessionConfiguration.default
        if let rt = requestTimeoutOverride, rt > 0 {
            streamCfg.waitsForConnectivity = false
            streamCfg.timeoutIntervalForRequest = rt
            streamCfg.timeoutIntervalForResource = rt + 15
        }
        let streamSession = URLSession(configuration: streamCfg, delegate: delegate, delegateQueue: nil)

        // 首字节超时定时器 (10 秒）
        // v7.4.0-fix73g：子代理流式硬上限句柄——提前声明，供 firstByteTimer / idle / onComplete 取消。
        var hardCap: DispatchWorkItem?
        let firstByteTimer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !firstByteReceived && !fellBackToNonStream {
                fellBackToNonStream = true
                NetworkLog.shared.log("\(self.config.name): 流式首字节超时 (10s)，自动降级非流式")
                hardCap?.cancel()
                streamSession.invalidateAndCancel()
                // 切回非流式 performResponses (completion 走 guardedCompletion，防双done）
                self.performResponses(messages: messages, tools: tools, onStatus: onStatus, onThinking: onThinking, completion: guardedCompletion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: firstByteTimer)

        // v4.5.x：流式 idle 看门狗——首字节后流中途挂起 (中转不关连接但不再推事件）时，
        // 每收到一个 SSE 事件重置；间隔 > 30s → 掐断并回落 (复用 guardedCompletion 防双 done）。
        var idleTimer: DispatchWorkItem?
        func resetIdleWatchdog() {
            idleTimer?.cancel()
            let t = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.cancelled || fellBackToNonStream { return }
                NetworkLog.shared.log("\(self.config.name): 流式 idle 超时 (30s 无 SSE 事件)，掐断回落")
                streamSession.invalidateAndCancel()
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3040,
                    userInfo: [NSLocalizedDescriptionKey: "Stream stalled: no SSE event for 30s"])))
            }
            idleTimer = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
        }

        // v7.4.0-fix73g：子代理流式硬上限——根因：中转持续发心跳/keepalive SSE 事件
        // （如 response.in_progress 心跳）时，idle 看门狗每事件被重置、URLRequest timeout 不触发
        // （流式持续收数据），流式可"永远挂死"。requestTimeoutOverride 下加总墙钟硬上限，
        // 到点无论 keepalive 与否都掐断走 guardedCompletion（防双 done）。主会话 nil 不受影响。
        if let rt = requestTimeoutOverride, rt > 0 {
            let cap = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.cancelled || fellBackToNonStream { return }
                NetworkLog.shared.log("\(self.config.name): 子代理流式硬上限 \(Int(rt))s 到点，强制掐断（防 keepalive 挂死）")
                streamSession.invalidateAndCancel()
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3042,
                    userInfo: [NSLocalizedDescriptionKey: "Subagent stream hard cap \(Int(rt))s reached (relay keepalive kept the stream alive without completing)"])))
            }
            hardCap = cap
            DispatchQueue.main.asyncAfter(deadline: .now() + rt, execute: cap)
        }

        delegate.onEvent = { [weak self] raw in
            guard let self = self else { return }
            if !firstByteReceived {
                firstByteReceived = true
                firstByteTimer.cancel()
                // v4.5.x：首字节到达后启用 idle 看门狗（流中途挂起保护）
                resetIdleWatchdog()
                // v2.9.88：链路可视化 —— 首字节到达即上报"已连接，开始流式接收"
                let el = Int(Date().timeIntervalSince(self.requestStart) * 1000)
                NetworkLog.shared.log("\(self.config.name): 流式首字节 (\(el)ms)")
                onStatus?(L10n.t("status_connected", Double(el) / 1000.0))
            }
            // v4.5.x：每个 SSE 事件刷新 idle 看门狗
            resetIdleWatchdog()
            if fellBackToNonStream { return }
            guard let ev = self.parseSSEEvent(raw) else { return }
            let type = ev.type

            // 文本增量 → 逐字显示
            if type == "response.text.delta", !ev.delta.isEmpty {
                fullText += ev.delta
                DispatchQueue.main.async { onDelta?(ev.delta) }
            }
            // 推理增量 → v2.9.127 实时思考 (打字机式逐句显示）
            if type == "response.reasoning.delta", !ev.delta.isEmpty {
                fullThinking += ev.delta
                let d = ev.delta
                DispatchQueue.main.async { onThinking?(d) }
            }
            // 工具调用开始
            if type == "response.output_item.added",
               let item = ev.json["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                currentCallId = callId
                currentCallName = name
                currentCallArgs = ""
            }
            // 工具参数增量
            if type == "response.function_call_arguments.delta", !ev.delta.isEmpty {
                currentCallArgs += ev.delta
            }
            // 工具调用done
            if type == "response.output_item.done",
               let item = ev.json["item"] as? [String: Any],
               item["type"] as? String == "function_call" {
                if !currentCallId.isEmpty {
                    toolCalls.append(ToolCall(id: currentCallId, name: currentCallName, arguments: currentCallArgs, toolTitle: ToolCall.extractTitle(from: currentCallArgs)))
                }
                currentCallId = ""
                currentCallName = ""
                currentCallArgs = ""
            }
            // 响应done (包含完整 response 对象）
            if type == "response.completed",
               let response = ev.json["response"] as? [String: Any] {
                completedResponse = response
            }
        }

        delegate.onComplete = { [weak self] error in
            guard let self = self else { return }
            firstByteTimer.cancel()
            idleTimer?.cancel()
            hardCap?.cancel()
            streamSession.invalidateAndCancel()
            // v2.9.54：已降级到非流式，不重复执行 completion
            if fellBackToNonStream { return }

            if let error = error {
                // v7.1.267-audit：SSL 握手错误且未收到任何首字节（握手层失败=无内容，重试安全）——
                // 同级别新连接重试（最多 2 次），绕开 Botcf 瞬时坏节点；有内容时不重试防重复输出
                let nsErr = error as NSError
                let isSSLNoContent = !firstByteReceived && (nsErr.code == -1202 || nsErr.code == -1200
                    || nsErr.code == -1204 || nsErr.code == -1205
                    || error.localizedDescription.contains("SSL")
                    || error.localizedDescription.contains("安全连接"))
                if isSSLNoContent, self.sslRetryCount < 2 {
                    self.sslRetryCount += 1
                    NetworkLog.shared.log("\(self.config.name): 流式 SSL 握手失败 (\(nsErr.code))，未收到首字节——新连接重试 (attempt \(self.sslRetryCount + 1)/3)")
                    self.performResponsesStream(messages: messages, tools: tools, onStatus: onStatus,
                                                onDelta: onDelta, onThinking: onThinking, completion: guardedCompletion)
                    return
                }
                guardedCompletion(.failure(error))
                return
            }

            // 如果 response.completed 里有完整 output，优先用它 (更准确）
            if let resp = completedResponse, let output = resp["output"] as? [[String: Any]] {
                var calls: [ToolCall] = []
                var text = ""
                var thinking = ""
                for item in output {
                    let t = item["type"] as? String ?? ""
                    if t == "function_call",
                       let callId = item["call_id"] as? String,
                       let name = item["name"] as? String,
                       let args = item["arguments"] as? String {
                        calls.append(ToolCall(id: callId, name: name, arguments: args, toolTitle: ToolCall.extractTitle(from: args)))
                    }
                    if t == "reasoning" {
                        if let summary = item["summary"] as? [[String: Any]] {
                            for sm in summary { if let st = sm["text"] as? String { thinking += st } }
                        }
                        if let contentArr = item["content"] as? [[String: Any]] {
                            for cc in contentArr { if let st = cc["text"] as? String { thinking += st } }
                        }
                    }
                    if t == "message", let content = item["content"] as? [[String: Any]] {
                        for c in content where (c["type"] as? String) == "output_text" {
                            if let tt = c["text"] as? String { text += tt }
                        }
                    }
                }
                // v4.3.36：思考自动升档 (Responses 流式)——低/中档且输出无 reasoning 项
                // (reasoning_tokens==0）时，切非流式以 high 重试一次。破甲站等中转 low/medium 不出思考。
                let hasReasoningItem = output.contains { ($0["type"] as? String) == "reasoning" }
                let outDetails = (resp["usage"] as? [String: Any])?["output_tokens_details"] as? [String: Any]
                let respReasoningTokens = outDetails?["reasoning_tokens"] as? Int ?? 0
                let lowMidResp = (self.currentReasoningLevel == 0 || self.currentReasoningLevel == 1)
                if !hasReasoningItem, respReasoningTokens <= 0, lowMidResp, !self.didAutoEscalateReasoning {
                    self.didAutoEscalateReasoning = true
                    let saved = self.currentReasoningLevel
                    self.currentReasoningLevel = 3   // v4.3.37：升到最高档 max
                    NetworkLog.shared.log("\(self.config.name): Responses 流式低/中档无思考 (reasoning_tokens=\(respReasoningTokens))，切非流式以 max 重试")
                    onStatus?(L10n.t("status_reasoning_upgraded"))
                    self.performResponses(messages: messages, tools: tools, onStatus: onStatus, onThinking: onThinking, completion: guardedCompletion)
                    self.currentReasoningLevel = saved
                    return
                }
                // v2.9.297：L5 空响应 (output 无文本无工具调用）判为failed——中转站可能不支持 Responses API
                if calls.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NetworkLog.shared.log("\(self.config.name): Responses API 返回空 output，判定不支持，回落 chat/completions")
                    guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3040,
                        userInfo: [NSLocalizedDescriptionKey: "模型返回空响应 (中转站可能不支持 Responses API)"])))
                    return
                }
                self.persist(level: 5)
                NetworkLog.lastCompatNote = "模型「\(self.config.name)」当前兼容级别: 5 (Responses API+工具，流式)"
                if !calls.isEmpty {
                    let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // v3.5.16：把完成响应里提取到的 reasoning 也带出来——推理若在 response.completed
                    // 的 reasoning 项里(而非流式 delta)，此前 thinking:nil 会把它丢掉，导致工具轮无深度思考。
                    let t = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    guardedCompletion(.success(.toolCalls(calls, thinking: t.isEmpty ? nil : t, content: n.isEmpty ? nil : n)))
                } else {
                    var th = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    // v3.1.33：去重——reasoning 与正文相同时不展示思考
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !th.isEmpty, !trimmedText.isEmpty, (trimmedText == th || th.contains(trimmedText) || trimmedText.contains(th)) {
                        th = ""
                    }
                    // 正文为空但 thinking 是完整回答 → 转成正文
                    if th.isEmpty, trimmedText.isEmpty, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       thinking.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                        text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // v2.9.127：非流式兜底——整段思考一次性推送 (降级场景也能显示思考）
                    if !th.isEmpty {
                        let whole = th
                        DispatchQueue.main.async { onThinking?(whole) }
                    }
                    guardedCompletion(.success(.text(text, thinking: th.isEmpty ? nil : th)))
                }
                return
            }

            // fallback：用流式过程中累积的数据
            // v2.9.297：流式零增量且无 completedResponse 输出 → 判failed回落
            if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty && fullThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NetworkLog.shared.log("\(self.config.name): Responses 流式无任何文本/工具增量，判定不支持，回落 chat/completions")
                guardedCompletion(.failure(NSError(domain: "OpenAIClient", code: -3041,
                    userInfo: [NSLocalizedDescriptionKey: "模型返回空响应 (中转站可能不支持 Responses API)"])))
                return
            }
            self.persist(level: 5)
            if !toolCalls.isEmpty {
                let n = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                // v3.5.16：把流式累积的 fullThinking 也带出来——工具轮深度思考不再被 thinking:nil 丢掉
                let th = fullThinking.trimmingCharacters(in: .whitespacesAndNewlines)
                guardedCompletion(.success(.toolCalls(toolCalls, thinking: th.isEmpty ? nil : th, content: n.isEmpty ? nil : n)))
            } else {
                var th = fullThinking.trimmingCharacters(in: .whitespacesAndNewlines)
                // v3.1.33：去重——思考与正文相同时不展示
                let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !th.isEmpty, !trimmedText.isEmpty, (trimmedText == th || th.contains(trimmedText) || trimmedText.contains(th)) {
                    th = ""
                }
                guardedCompletion(.success(.text(fullText, thinking: th.isEmpty ? nil : th)))
            }
        }

        let task = streamSession.dataTask(with: request)
        activeTask = task
        task.resume()
    }
}

// MARK: - Anthropic cache_control 断点injected (v2.9.107，对齐 cc-switch cache_injector 4 断点策略）
// Anthropic 缓存上限 4 个断点；已存在的标记保留 (caller-owned），budget = 4 - existing。

enum CacheInjector {
    static func injectAnthropic(body: inout [String: Any]) {
        var budget = 4
        // (a) tools 数组最后一个元素
        if budget > 0, var tools = body["tools"] as? [[String: Any]], var last = tools.last, last["cache_control"] == nil {
            last["cache_control"] = ["type": "ephemeral"]
            tools[tools.count - 1] = last
            body["tools"] = tools
            budget -= 1
        }
        // (b) system 顶层数组末尾
        if budget > 0, var system = body["system"] as? [[String: Any]], var last = system.last, last["cache_control"] == nil {
            last["cache_control"] = ["type": "ephemeral"]
            system[system.count - 1] = last
            body["system"] = system
            budget -= 1
        }
        // (c) 最新一条消息的非 thinking block
        if budget > 0, var messages = body["messages"] as? [[String: Any]] {
            for i in stride(from: messages.count - 1, through: 0, by: -1) {
                if injectMessage(&messages[i]) {
                    body["messages"] = messages
                    budget -= 1
                    break
                }
            }
            // (d) 更早的第 2 个 user 锚点 (应对长工具循环超出 20-block lookback）
            if budget > 0, messages.count >= 4 {
                var userCount = 0
                for i in stride(from: messages.count - 1, through: 0, by: -1) {
                    if messages[i]["role"] as? String == "user" {
                        userCount += 1
                        if userCount == 2 {
                            var m = messages[i]
                            if injectMessage(&m) {
                                messages[i] = m
                                body["messages"] = messages
                                budget -= 1
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    private static func injectMessage(_ message: inout [String: Any]) -> Bool {
        guard var content = message["content"] as? [Any] else { return false }
        for i in stride(from: content.count - 1, through: 0, by: -1) {
            guard var block = content[i] as? [String: Any] else { continue }
            let type = block["type"] as? String
            if type == "thinking" || type == "redacted_thinking" { continue }
            if block["cache_control"] != nil { return false }
            block["cache_control"] = ["type": "ephemeral"]
            content[i] = block
            message["content"] = content
            return true
        }
        return false
    }
}

// MARK: - 用量记录 (v2.9.107，本地 JSONL，供「用量统计」页聚合）

final class UsageRecorder {
    static let shared = UsageRecorder()

    private let fileURL: URL
    private let lock = NSLock()
    private var lastStart = Date()
    private var lastInputEst = 0
    // v7.1.109-peers：最近一次发送估算输入（供超限错误下调窗口用——失败时无真实 usage）
    var lastInputEstimate: Int { lastInputEst }
    // v7.1.109-peers：OpenMinis calibration ratio 借鉴——最近一次真实 prompt_tokens/估算 的比值，
    // 供 messagesForAPI 校准上下文预算比较（clamp 0.5–2.5，防估算器偏差导致超发或过度压缩）
    private(set) var lastRealRatio: Double = 1.0
    /// v7.4.0-fix66：线程安全读——UI/SessionStore 跨线程读（end() 写点在 lock 内，
    /// 读方必须走本访问器，避免与回调线程数据竞争；同时统一 UI 与 AI 压力判断口径）
    var calibratedRatio: Double {
        lock.lock(); defer { lock.unlock() }
        return lastRealRatio
    }

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("trollagent_usage.jsonl")
    }

    func begin(messages: [ChatMessage]) {
        lastStart = Date()
        // v7.3.1-precision：估算与 OpenAIClient 分桶估算统一（校准 ratio 分母必须同源，
        // 否则 real/est 比值失真——此前 ch/3 粗估算对 tool 结果低估 2.78×）
        // v7.1.267-precision：+ fixedOverheadTokens（system+tools）——真实 prompt_tokens 含它们，
        // 旧口径 est 不含 → ratio 恒偏 ~1.2；对齐后 ratio 直接反映分桶估算精度，EMA 校准更有意义。
        var est = 0
        for m in messages {
            est += OpenAIClient.estimateTokensStatic(m)
        }
        est += OpenAIClient.fixedOverheadTokens
        lastInputEst = est
    }

    /// v7.1.109-peers：缓存读取 token 兼容解析（中转站/API 各形态）
    static func extractCachedRead(_ u: [String: Any]) -> Int {
        if let v = u["cache_read_input_tokens"] as? Int { return v }            // Anthropic/部分中转
        if let v = u["cached_tokens"] as? Int { return v }                      // OpenAI/中转
        if let v = u["prompt_cache_hit_tokens"] as? Int { return v }            // DeepSeek 老格式
        if let v = u["cache_read_tokens"] as? Int { return v }
        if let d = u["prompt_tokens_details"] as? [String: Any] {
            if let v = d["cached_tokens"] as? Int { return v }                  // OpenAI/DeepSeek 新格式
            if let v = d["cached_tokens"] as? Double { return Int(v) }
            if let v = d["cache_read_tokens"] as? Int { return v }
        }
        if let v = u["cache_read_input_tokens"] as? Double { return Int(v) }
        return 0
    }
    /// v7.1.109-peers：缓存未命中 token（标准命中率分母用）；无该字段返回 nil
    static func extractCacheMiss(_ u: [String: Any]) -> Int? {
        if let v = u["cache_miss_input_tokens"] as? Int { return v }
        if let v = u["prompt_cache_miss_tokens"] as? Int { return v }           // DeepSeek 老格式
        if let v = u["uncached_tokens"] as? Int { return v }
        if let d = u["prompt_tokens_details"] as? [String: Any] {
            if let v = d["uncached_tokens"] as? Int { return v }
            if let v = d["cache_miss_tokens"] as? Int { return v }
        }
        return nil
    }

    func end(config: ModelConfig, ok: Bool, elapsedMs: Int, error: String = "", usage: [String: Any]? = nil) {
        lock.lock(); defer { lock.unlock() }
        var rec: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "name": config.name,
            "provider": config.provider,
            "baseURL": config.baseURL,
            "model": config.model,
            "ok": ok,
            "elapsedMs": elapsedMs,
            "error": error,
            "estInputTokens": lastInputEst
        ]
        // v7.1.98：真实 usage（API 返回的 prompt/completion/total tokens）——有则记录，
        // 用量统计最近请求优先显示真实 token，无则回退估算输入
        if let u = usage {
            rec["promptTokens"] = u["prompt_tokens"] ?? 0
            rec["completionTokens"] = u["completion_tokens"] ?? 0
            rec["totalTokens"] = u["total_tokens"] ?? 0
            // v7.1.109-peers：缓存字段直读中转站/API usage（对齐 OpenMinis TokenUsageSheet）——
            // 兼容各形态：Anthropic cache_read_input_tokens / OpenAI cached_tokens /
            // DeepSeek prompt_cache_hit_tokens / prompt_tokens_details.cached_tokens
            let cacheRead = Self.extractCachedRead(u)
            rec["cacheReadTokens"] = cacheRead
            if let miss = Self.extractCacheMiss(u) {
                rec["cacheMissTokens"] = miss
            } else if let pt = u["prompt_tokens"] as? Int {
                rec["cacheMissTokens"] = max(0, pt - cacheRead)   // 只给 cache 时，miss = 输入 - cache
            }
            // v7.1.109-peers：OpenMinis calibration ratio——真实/估算比值即时更新（lock 内，线程安全）
            // v7.1.267-precision：EMA 平滑（0.7/0.3）——单点 ratio 受工具结果大小波动跳变（clamp 0.5-2.5），
            // 平滑后校准比只随真实 tokenizer 特性缓慢收敛（中文密度/模型词表），不再被单轮抖动带偏。
            if let p = rec["promptTokens"] as? Int, p > 0, lastInputEst > 0 {
                let r = min(2.5, max(0.5, Double(p) / Double(lastInputEst)))
                if lastRealRatio == 1.0 {
                    lastRealRatio = r
                } else {
                    lastRealRatio = min(2.5, max(0.5, 0.7 * lastRealRatio + 0.3 * r))
                }
            }
        }
        guard let d = try? JSONSerialization.data(withJSONObject: rec) else { return }
        if let fh = try? FileHandle(forWritingTo: fileURL) {
            fh.seekToEndOfFile()
            fh.write(d)
            fh.write(Data("\n".utf8))
            try? fh.close()
        } else {
            try? d.write(to: fileURL)
        }
    }

    var records: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in s.split(separator: "\n").suffix(500) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
