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
    /// AppDelegate 的 handleEventsForBackgroundURLSession completionHandler（全部任务结束后调用）
    var onAllTasksFinished: (() -> Void)?
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
