import Foundation

// v7.4.0-fix73：后台非流式代传——切后台时把在途流式请求转交 iOS background session 系统代传
// （App 挂起/被杀也能传完，完成后唤醒 App 收结果）——iOS 唯一保证后台传输的机制。
// 对齐微信式保活的"拉模式"版；不支持非流式的中转按 baseURL 记忆并自动跳过（fix72 前台重试兜底）。
final class BackgroundLLM: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundLLM()

    /// 后台请求结果（App 回前台读取后清空）
    struct HandoffResult {
        let text: String
        let thinking: String?
        let toolCalls: [ToolCall]
        let model: String
        let error: String?
    }

    private(set) var pendingResult: HandoffResult?
    private(set) var isHandoffInFlight = false

    private let bgID = "com.trollagent.llm.bg"
    private var backgroundSession: URLSession?
    /// v7.4.0-fix73e：session 失效中标志——cancelHandoff 置 true，0.5s 后重建完成置 false；
    /// handoff() 若撞上失效中 session（新任务加进正在 invalidate 的 session = 未定义行为）则跳过
    private var sessionInvalidating = false
    /// AppDelegate 的 handleEventsForBackgroundURLSession completionHandler（全部任务结束后调用）
    var onAllTasksFinished: (() -> Void)?
    /// v7.4.0-fix73b：结果就绪时的主动推送（主线程）——App 前台或被系统唤醒时直接消费，
    /// 不再只依赖 willEnterForeground 一次快照（根治"回前台太早 → 结果无人收 → 永久请求中"）
    var onResultAvailable: ((HandoffResult) -> Void)?
    private let lock = NSLock()
    /// 非流式能力缓存 key（按 baseURL 记忆；默认假设支持，失败后标记跳过）
    private let capKey = "background.llm.nonstream.supported"
    private var capCache: [String: Bool] = [:]

    override private init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: bgID)
        cfg.isDiscretionary = false          // 尽快传输（不等系统"最佳时机"）
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 300
        cfg.timeoutIntervalForRequest = 90
        backgroundSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: - 能力缓存（运行时自适应：第一次尝试转 → 成功记住 / 失败标记跳过）

    func allowsNonStreaming(baseURL: String) -> Bool {
        let host = URL(string: baseURL)?.host ?? baseURL
        lock.lock(); defer { lock.unlock() }
        if let cached = capCache[host] { return cached }
        if UserDefaults.standard.object(forKey: capKey) == nil { return true }   // 默认支持
        let v = UserDefaults.standard.bool(forKey: capKey)
        capCache[host] = v
        return v
    }

    func markNonStreaming(_ supported: Bool, baseURL: String) {
        let host = URL(string: baseURL)?.host ?? baseURL
        lock.lock(); defer { lock.unlock() }
        capCache[host] = supported
        UserDefaults.standard.set(supported, forKey: capKey)
    }

    // MARK: - 提交

    /// 提交后台非流式请求。返回 true = 已接管（上层应把原请求静默 cancel）。
    func handoff(messages: [ChatMessage], tools: [[String: Any]]?, config: ModelConfig) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isHandoffInFlight,
              !sessionInvalidating,
              allowsNonStreaming(baseURL: config.baseURL),
              let session = backgroundSession else { return false }
        // 请求构建复用 OpenAIClient（body/鉴权/参数别名同源）
        let client = OpenAIClient(config)
        guard let request = client.makeBackgroundRequest(messages: messages, tools: tools) else { return false }
        isHandoffInFlight = true
        pendingResult = nil
        let task = session.downloadTask(with: request)
        task.resume()
        return true
    }

    /// App 回前台读取结果（读取后清空）
    func consumeResult() -> HandoffResult? {
        lock.lock(); defer { lock.unlock() }
        defer { pendingResult = nil; isHandoffInFlight = false }
        return pendingResult
    }

    /// fix73j-审计 M-7：后台代传在途判定——主请求被 handoff 取消时，URLSession 的
    /// -999 取消回调会无条件清 isLoading，而后台结果消费的 guard isLoading 依赖它
    /// → 后台结果被静默丢弃。回调侧用本方法区分"handoff 在途（保留 isLoading）"
    /// 与"用户手动停止（正常清理）"。
    func hasPendingHandoff() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isHandoffInFlight || pendingResult != nil
    }

    /// v7.4.0-fix73b：用户发新消息/手动停止时取消后台等待（放弃旧结果，避免结果覆盖新会话）
    /// fix73b-audit：无在途任务且无结果时不重建 session（send() 每轮都会调用，避免无谓 invalidate）
    /// v7.4.0-fix73e：同 identifier 重建竞态加固——URLSession.invalidateAndCancel 是异步生效，
    /// 立即用同一 bgID 新建 session 会短暂出现"同 identifier 双 session"（未定义行为/崩溃风险）。
    /// 改为：延迟到旧 session 失效后再重建（send() 高频调用时仅重建一次）。
    func cancelHandoff() {
        lock.lock()
        let hasWork = isHandoffInFlight || pendingResult != nil
        pendingResult = nil
        isHandoffInFlight = false
        lock.unlock()
        guard hasWork else { return }
        let old = backgroundSession
        lock.lock()
        sessionInvalidating = true
        lock.unlock()
        old?.invalidateAndCancel()
        // 旧 session 异步失效，延迟 0.5s 后再重建同 identifier session
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // 重建前再确认没有新任务已提交（理论上不可能，双保险）
            if !self.isHandoffInFlight {
                let cfg = URLSessionConfiguration.background(withIdentifier: self.bgID)
                cfg.isDiscretionary = false
                cfg.waitsForConnectivity = true
                cfg.timeoutIntervalForResource = 300
                cfg.timeoutIntervalForRequest = 90
                self.backgroundSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            }
            self.sessionInvalidating = false
            self.lock.unlock()
        }
    }

    /// 结果就绪统一出口（存 + 主动推送主线程）
    private func deliver(_ result: HandoffResult) {
        lock.lock(); defer { lock.unlock() }
        pendingResult = result
        DispatchQueue.main.async {
            self.onResultAvailable?(result)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 下载完成回调在 didFinishDownloadingTo（成功时 error 为 nil）；这里处理失败
        guard let error = error else { return }
        let nsErr = error as NSError
        // 用户取消（回前台主动取消）不标记能力
        if nsErr.code == -999 { return }
        // 非流式被拒（HTTP 400/401 类）→ 标记该 host 不支持，下次跳过 handoff
        if nsErr.code == -1011 || nsErr.code == -1012 {
            let host = URL(string: task.originalRequest?.url?.absoluteString ?? "")?.host ?? ""
            markNonStreaming(false, baseURL: host)
        }
        lock.lock(); defer { lock.unlock() }
        pendingResult = HandoffResult(text: "", thinking: nil, toolCalls: [], model: "", error: "Background request failed: \(nsErr.localizedDescription.prefix(120))")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 读完整响应 JSON → 解析（OpenAI Chat / Responses 两种格式）
        guard let data = try? Data(contentsOf: location),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lock.lock(); defer { lock.unlock() }
            pendingResult = HandoffResult(text: "", thinking: nil, toolCalls: [], model: "", error: "Background response parse failed")
            return
        }
        var text = ""
        var thinking: String?
        var toolCalls: [ToolCall] = []
        // 1) Responses API：output[].message.content[] / function_call
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let msg = item["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    for c in content {
                        if let t = c["text"] as? String { text += t }
                    }
                }
                if let fc = item["function_call"] as? [String: Any],
                   let name = fc["name"] as? String,
                   let args = fc["arguments"] as? String {
                    toolCalls.append(ToolCall(id: "", name: name, arguments: args))
                }
            }
        }
        // 2) chat/completions：choices[0].message.content / tool_calls
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let msg = first["message"] as? [String: Any] {
                if let c = msg["content"] as? String, !c.isEmpty { text += c }
                if let reasoning = msg["reasoning_content"] as? String { thinking = reasoning }
                if let tcs = msg["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        guard let fn = tc["function"] as? [String: Any],
                              let name = fn["name"] as? String else { continue }
                        let args = fn["arguments"] as? String ?? ""
                        let id = tc["id"] as? String ?? ""
                        var call = ToolCall(id: id, name: name, arguments: args)
                        call.toolTitle = (fn["tool_title"] as? String) ?? ToolCall.extractTitle(from: args)
                        toolCalls.append(call)
                    }
                }
            }
        }
        let model = json["model"] as? String ?? ""
        lock.lock(); defer { lock.unlock() }
        pendingResult = HandoffResult(text: text, thinking: thinking, toolCalls: toolCalls, model: model, error: nil)
    }

    /// 全部后台任务结束（系统回调后调 AppDelegate 的 completionHandler）
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.onAllTasksFinished?()
        }
    }
}
