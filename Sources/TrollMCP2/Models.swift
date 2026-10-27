import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var apiProtocol: String       // OpenAI Chat Completions / OpenAI Responses / Anthropic / Custom
    var baseURL: String           // https://api.openai.com/v1
    var apiKey: String
    var model: String             // gpt-4o-mini
    var authMethod: String        // Bearer / API Key / Body api_key / Body token / Query token / None
    var isDefault: Bool = false
    var temperature: Double = 0.2   // v6.1.5-14bj：执行任务型AI标准(参考Claude Agent SDK默认0/代码工具类0.1-0.3)，原0.7偏高输出飘
    var maxTokens: Int = 16384      // v6.1.5-14bj：Agent场景需大输出(BytePlus官方推荐≥128000, 手机端取16384平衡; 原2048会截断长任务)
    /// v7.1.107：备用模型组（fallback 链）——主模型请求失败（网络/超时/鉴权/熔断/5xx，
    /// 且未产出任何内容）时，OpenAIClient 自动按序切换到备用模型重发同一请求
    /// （对齐 OpenMinis ModelGroupRouter fallback 思想，自实现不搬码）。空数组=不启用。
    var fallbackIDs: [UUID] = []
    /// v2.9.11：输入上下文预算 (token 估算）。发送前按预算自动裁剪最旧消息，
    /// 避免长会话请求体无限增长导致"一直请求中"。
    /// v7.1.109-peers：默认值 16000 → 128000（2026 主流模型最小窗口档；16k 会让
    /// 未匹配模型掉进 <32K 硬停档，是历史遗留坑）。
    var contextTokens: Int = 128000
    /// v7.1.107：模型能力表匹配后的实际压缩预算——命中已知模型用真实 context window
    /// （大窗口多留历史、小窗口不撑爆）。
    /// v7.1.109-peers：兜底链升级——显式后缀 > 实测记录 > 静态表 > 代际推断 > 128k 安全默认。
    /// contextTokens 默认值（128000/老默认 16000）视为"未配置"→ 用智能窗口；
    /// 用户显式设置过 → 作为上限尊重（防止小窗口模型被撑爆）。
    var effectiveContextTokens: Int {
        let resolved = ModelCapability.resolvedWindow(for: model)
        if contextTokens == 128_000 || contextTokens == 16_000 { return resolved }
        return min(resolved, contextTokens)
    }
    /// v7.1.109-peers：OpenMinis ContextPolicy 分档阈值借鉴——按窗口大小分档自动压缩触发线：
    /// <32K 不自动压缩（压不起，超限硬停）；32K–128K 剩 10K 触发；≥128K 剩 20K 触发。
    /// 相比旧"70%×窗口"一刀切：小窗口不硬压、大窗口多留历史余量。
    static func contextCompactLine(for window: Int) -> Int {
        if window < 32_000 { return 0 }              // 硬停档
        if window < 128_000 { return window - 10_000 }
        return window - 20_000
    }
    /// v2.8.4：中转站兼容级别 (由 OpenAIClient 自适应降级时写入并持久化）
    /// 0=完整载荷 1=互换token参数名 2=去掉tool_choice 3=去掉tools纯对话 4=最小载荷
    var compatLevel: Int = 0
    /// v2.9.107：分组名 (供应商分组管理，对齐 cc-switch provider groups）
    var group: String = "default"
    /// v3.5.13：可配置的参数名别名映射（标准键 → 该供应商认的键），如
    /// {"max_tokens":"max_completion_tokens", "reasoning_effort":"reasoning"}。
    /// 覆盖"不同中转对同一参数名接受度不同"的场景，不只内置 max_tokens 互换。
    var paramAliases: [String: String] = [:]
    /// v3.1.1：是否支持视觉 (VLM）——v7.1.109-peers 动态监测优先
    /// （对齐 OpenMinis models.dev 能力表思路，本地学习版）：发图请求成功 → 标记支持，
    /// 模型非视觉错误 → 标记不支持（持久化）；未知才走静态模型名规则。
    var supportsVision: Bool {
        if let learned = VisionTracker.shared.learned(for: model) { return learned }
        let m = model.lowercased()
        // 明确支持视觉的模型
        if m.contains("gpt-4o") || m.contains("gpt-4-vision") || m.contains("gpt-4v") { return true }
        if m.contains("claude-3") || m.contains("claude 3") { return true }
        if m.contains("gemini") { return true }
        if m.contains("qwen-vl") || m.contains("qwen2-vl") { return true }
        if m.contains("glm-4v") || m.contains("glm4v") { return true }
        if m.contains("vision") || m.contains("vl-") { return true }
        // 明确不支持的
        if m.contains("deepseek") { return false }
        if m.contains("gpt-3.5") || m.contains("gpt-35") { return false }
        // 默认：不支持 (保守策略，避免 API 报错）
        return false
    }

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.2, maxTokens: Int = 16384, compatLevel: Int = 0,
         contextTokens: Int = 128000, group: String = "default", paramAliases: [String: String] = [:],
         fallbackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.authMethod = authMethod
        self.isDefault = isDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.compatLevel = compatLevel
        self.contextTokens = contextTokens
        self.group = group
        self.paramAliases = paramAliases
        self.fallbackIDs = fallbackIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        let decodedProtocol = (try? c.decode(String.self, forKey: .apiProtocol)) ?? "OpenAI Chat Completions"
        // v2.9.2：OpenAI Completions (旧版文本补全）已移除，旧配置迁移到 Chat Completions
        apiProtocol = decodedProtocol == "OpenAI Completions" ? "OpenAI Chat Completions" : decodedProtocol
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        let decodedAuthMethod = (try? c.decode(String.self, forKey: .authMethod)) ?? "Bearer"
        authMethod = decodedAuthMethod.trimmingCharacters(in: .whitespaces).isEmpty ? "Bearer" : decodedAuthMethod
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.2
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 16384
        contextTokens = (try? c.decode(Int.self, forKey: .contextTokens)) ?? 128000
        compatLevel = (try? c.decode(Int.self, forKey: .compatLevel)) ?? 0
        group = (try? c.decode(String.self, forKey: .group)) ?? "default"
        paramAliases = (try? c.decode([String: String].self, forKey: .paramAliases)) ?? [:]
        fallbackIDs = (try? c.decode([UUID].self, forKey: .fallbackIDs)) ?? []   // v7.1.107：旧配置缺失时默认无备用
    }
}

// MARK: - 模型协议与鉴权方式

/// v7.1.109-peers：模型能力表（2026-10 全量核对）——覆盖 20+ 厂商主流模型真实 context window，
/// 用于压缩预算自动匹配。数值按各厂商公开文档/Azure/Bedrock 模型卡核对；
/// 未收录模型返回 nil → 走 ModelConfig.contextTokens 兜底。
/// 对齐 OpenMinis models.dev 能力表的思路（本地静态版，不依赖网络注册表）。
enum ModelCapability {
    static func contextWindow(for model: String) -> Int? {
        let m = model.lowercased()
        // Anthropic Claude：全系 200k（3.5/3.7/4.x/4.5/5 系列维持 200k 窗口）
        if m.contains("claude") {
            return 200_000
        }
        // OpenAI GPT-6 系（sol/astra/luna）：API 原生 1.05M / 产品默认 500k~1M，取保守 1M
        if m.contains("gpt-6.1") || m.contains("gpt-6") { return 1_000_000 }
        // GPT-5.6 系（sol/terra/luna）：1M（Azure 1050k / Bedrock 1M / API 1.05M）
        if m.contains("gpt-5.6") { return 1_000_000 }
        // GPT-5 系：400k；GPT-4.1：1M；GPT-4o/o1/o3/o4：200k；GPT-4：128k
        if m.contains("gpt-5") { return 400_000 }
        if m.contains("gpt-4.1") { return 1_000_000 }
        if m.contains("gpt-4o") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return 200_000 }
        if m.contains("gpt-4") { return 128_000 }
        // GPT-OSS 开源系：128k
        if m.contains("gpt-oss") { return 128_000 }
        // DeepSeek：V3/R1/V4 及 chat(reasoner API 名)=128k，其余（老 chat 类）64k
        if m.contains("deepseek") {
            if m.contains("v3") || m.contains("r1") || m.contains("v4") || m.contains("chat") { return 128_000 }
            return 64_000
        }
        // 智谱 GLM：GLM-4.6 200k，其余（4.5/4.7/5 系）128k
        if m.contains("glm") {
            if m.contains("4.6") { return 200_000 }
            return 128_000
        }
        // Kimi / Moonshot：K3 系列 1,048,576（官方确认），K2/带256 256k，其余 128k
        if m.contains("kimi") || m.contains("moonshot") {
            if m.contains("k3") { return 1_048_576 }
            if m.contains("k2") || m.contains("256") { return 256_000 }
            return 128_000
        }
        // 通义 Qwen：3-Max/3.7/3.8-Max 262144（256k），其余 131072（128k）
        if m.contains("qwen") {
            if m.contains("3-max") || m.contains("3.7") || m.contains("3.8") { return 262_144 }
            return 131_072
        }
        // MiniMax：M2 204800（官方/Bedrock 205k），Text-01/M1 1M，其余 131072
        if m.contains("minimax") {
            if m.contains("m2") { return 204_800 }
            if m.contains("text-01") || m.contains("m1") { return 1_000_000 }
            return 131_072
        }
        // 豆包 / 火山 Ark：Seed 全系 256k（1.6/1.8/2.x），pro 按型号后缀 32k/128k/256k，默认 128k
        if m.contains("doubao") || m.contains("ark") || m.contains("volc") {
            if m.contains("seed") { return 256_000 }
            if m.contains("32k") { return 32_000 }
            if m.contains("128k") { return 128_000 }
            if m.contains("256k") { return 256_000 }
            return 128_000
        }
        // Gemini：1M（Pro/Flash 系）
        if m.contains("gemini") { return 1_000_000 }
        // Grok：Fast/4.20 2M，4.7 500k，4.6 200k，其余（grok-3/4 标准）256k
        if m.contains("grok") {
            if m.contains("fast") || m.contains("4.20") { return 2_000_000 }
            if m.contains("4.7") { return 500_000 }
            if m.contains("4.6") { return 200_000 }
            return 256_000
        }
        // Mistral：Large-3 / Medium-3.5 256k，其余 128k
        if m.contains("mistral") {
            if m.contains("large-3") || m.contains("medium-3") || m.contains("256") { return 256_000 }
            return 128_000
        }
        // 阶跃 Step：带16k 变体 16384，preview/5 系 1M，3 系 256k，其余（step-2 系）128k
        if m.contains("step") || m.contains("stepfun") {
            if m.contains("16k") { return 16_384 }
            if m.contains("preview") || m.contains("step-5") { return 1_000_000 }
            if m.contains("3.") || m.contains("3-") { return 262_144 }
            return 128_000
        }
        // 开源 / 国产系固定档
        if m.contains("llama") { return 128_000 }
        if m.contains("ernie") || m.contains("文心") { return 128_000 }
        if m.contains("hunyuan") || m.contains("混元") { return 128_000 }
        if m.contains("spark") || m.contains("星火") { return 128_000 }
        if m.contains("baichuan") || m.contains("百川") { return 128_000 }
        if m.contains("yi-") || m.contains("01-ai") || m.contains("zero-one") { return 200_000 }
        if m.contains("internlm") || m.contains("书生") { return 128_000 }
        if m.contains("command") { return 128_000 }
        if m.contains("phi") { return 128_000 }
        if m.contains("nemotron") { return 128_000 }
        if m.contains("sensechat") || m.contains("商量") { return 128_000 }
        return nil
    }

    /// v7.1.109-peers：显式长度后缀解析——模型名自带窗口（128k/256k/32k/16k/1m 等），
    /// 比静态表更可靠（模型名是厂商自己标的），优先级最高。
    static func explicitSuffix(for model: String) -> Int? {
        let m = model.lowercased()
        let patterns: [(String, Int)] = [
            ("1048576", 1_048_576), ("1.048m", 1_048_576), ("1.05m", 1_050_000),
            ("2m", 2_000_000), ("1m", 1_000_000), ("512k", 512_000), ("256k", 256_000),
            ("200k", 200_000), ("131072", 131_072), ("128k", 128_000), ("64k", 64_000),
            ("32k", 32_000), ("16k", 16_384), ("8k", 8_192)
        ]
        for (pat, val) in patterns where m.contains(pat) { return val }
        return nil
    }

    /// v7.1.109-peers：代际推断——静态表未收录时按家族+版本号规律估窗口（保守档）。
    /// 规律基于各厂公开历史：GPT-N 4→128k 5→400k 6+→1M；Claude 3+→200k；
    /// Qwen 2→128k 3+→256k；GLM 4.5→128k 5+→256k；DeepSeek 2+→128k；
    /// Kimi K2→256k K3+→1M；Gemini→1M；Llama/Mistral/Phi→128k
    static func inferGeneration(for model: String) -> Int? {
        let m = model.lowercased()
        if let g = modelGenNumber(m, prefix: "gpt") {
            if g >= 6 { return 1_000_000 }
            if g >= 5 { return 400_000 }
            if g >= 4 { return 128_000 }
        }
        if let g = modelGenNumber(m, prefix: "claude") { return g >= 3 ? 200_000 : 100_000 }
        if let g = modelGenNumber(m, prefix: "qwen") { return g >= 3 ? 256_000 : 131_072 }
        if let g = modelGenNumber(m, prefix: "glm") { return g >= 5 ? 256_000 : 128_000 }
        if let g = modelGenNumber(m, prefix: "deepseek") { return g >= 2 ? 128_000 : 64_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("llama") || m.contains("mistral") || m.contains("phi") || m.contains("ernie") { return 128_000 }
        // Kimi K 系列（k2/k3…，字母+数字命名）
        if let r = m.range(of: "k[0-9]", options: .regularExpression) {
            let g = Int(String(m[r]).suffix(1)) ?? 0
            if g >= 3 { return 1_000_000 }
            if g >= 2 { return 256_000 }
            return 128_000
        }
        return nil
    }
    private static func modelGenNumber(_ m: String, prefix: String) -> Int? {
        guard let r = m.range(of: prefix + "-?[0-9]+", options: .regularExpression) else { return nil }
        let digits = String(m[r]).filter { $0.isNumber }
        return Int(digits)
    }

    /// v7.1.109-peers：最终兜底链——显式后缀 > 实测记录 > 静态表 > 代际推断 > 128k 安全默认。
    /// 模型迭代太快静态表追不上：实测自适应（成功上调/超限下调）保证新模型逐步收敛真实窗口。
    static func resolvedWindow(for model: String) -> Int {
        if let explicit = explicitSuffix(for: model) { return explicit }
        if let measured = RuntimeWindowTracker.shared.measuredWindow(for: model) { return measured }
        if let known = contextWindow(for: model) { return known }
        if let inferred = inferGeneration(for: model) { return inferred }
        return 128_000
    }
}

/// v7.1.109-peers：实测窗口自适应——模型迭代太快静态表追不上：
/// 成功请求把窗口上调到实际用量以上（留 10k 余量），超限错误把窗口下调到实际用量以下，
/// 持久化 UserDefaults（按模型名），未收录/新迭代模型也能逐步收敛到真实窗口。
final class RuntimeWindowTracker {
    static let shared = RuntimeWindowTracker()
    private let key = "trollagent_measured_windows_v1"   // [String: Int]

    func measuredWindow(for model: String) -> Int? {
        UserDefaults.standard.dictionary(forKey: key)?[model.lowercased()] as? Int
    }
    func recordSuccess(model: String, promptTokens: Int) {
        let m = model.lowercased()
        let p = promptTokens + 10_000   // 成功 = 窗口至少这么大，留余量
        guard p > 8_000 else { return }
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        if (d[m] ?? 0) < p { d[m] = p; UserDefaults.standard.set(d, forKey: key) }
    }
    func recordExceeded(model: String, promptTokens: Int) {
        let m = model.lowercased()
        let p = max(4_000, promptTokens - 5_000)   // 超限 = 窗口没这么大，下调并留余量
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        if (d[m] ?? Int.max) > p { d[m] = p; UserDefaults.standard.set(d, forKey: key) }
    }
}

/// v7.1.109-peers：视觉能力动态监测（对齐 OpenMinis models.dev 能力表思路，本地学习版）——
/// 发图请求成功 → 标记支持；模型非视觉错误 → 标记不支持。持久化 UserDefaults 按模型名，
/// 优先于静态规则：新迭代模型/自建模型自动收敛真实视觉能力，不靠猜。
final class VisionTracker {
    static let shared = VisionTracker()
    private let key = "trollagent_vision_caps_v1"   // [String: Bool]

    func learned(for model: String) -> Bool? {
        UserDefaults.standard.dictionary(forKey: key)?[model.lowercased()] as? Bool
    }
    func record(model: String, supports: Bool) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        d[model.lowercased()] = supports
        UserDefaults.standard.set(d, forKey: key)
    }
}

extension ModelConfig {
    /// v7.1.109-peers：协议面扩充——OpenRouter（OpenAI 兼容+专用 header/vendor 命名）、
    /// Gemini（原生 generateContent，覆盖 Google 官方与 Gemini 中转）
    static let apiProtocols = [
        "OpenAI Chat Completions",
        "OpenAI Responses",
        "Anthropic Messages",
        "OpenRouter",
        "Gemini",
        "Custom Endpoint"
    ]

    static let authMethods = ["Bearer", "API Key", "Body api_key", "Body token", "Query token", "None"]

    static let providerPresets: [(name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String)] = [
        ("OpenAI", "openai", "OpenAI Chat Completions", "https://api.openai.com/v1", "gpt-4o-mini", "Bearer"),
        ("DeepSeek", "deepseek", "OpenAI Chat Completions", "https://api.deepseek.com", "deepseek-chat", "Bearer"),
        ("Anthropic", "anthropic", "Anthropic Messages", "https://api.anthropic.com/v1", "claude-3-5-sonnet-20240620", "API Key"),
        ("Botcf", "custom", "OpenAI Responses", "https://botcf.com/v1", "gpt-5.6-terra", "Bearer"),
        // v4.4.17：扩充主流 OpenAI 兼容预设 (GLM/Kimi/Qwen/MiniMax/阶跃/豆包)。模型名可在模型管理页改。
        ("智谱GLM", "zhipu", "OpenAI Chat Completions", "https://open.bigmodel.cn/api/paas/v4", "glm-4.5", "Bearer"),
        ("Kimi(Moonshot)", "moonshot", "OpenAI Chat Completions", "https://api.moonshot.cn/v1", "kimi-k3", "Bearer"),
        ("通义千问(Qwen)", "qwen", "OpenAI Chat Completions", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-max", "Bearer"),
        ("MiniMax", "minimax", "OpenAI Chat Completions", "https://api.minimax.chat/v1", "MiniMax-Text-01", "Bearer"),
        ("阶跃星辰(Step)", "step", "OpenAI Chat Completions", "https://api.stepfun.com/v1", "step-2-mini", "Bearer"),
        ("豆包(火山)", "doubao", "OpenAI Chat Completions", "https://ark.cn-beijing.volces.com/api/v3", "doubao-pro-32k", "Bearer"),
        // v7.1.109-peers：协议面扩充预设——OpenRouter / xAI / Groq / Mistral / Ollama / Azure / Gemini
        // (OpenAI 兼容的配 Chat Completions 即用；Gemini 原生协议走 generateContent)
        ("OpenRouter", "openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "deepseek/deepseek-chat", "Bearer"),
        ("xAI", "xai", "OpenAI Chat Completions", "https://api.x.ai/v1", "grok-4", "Bearer"),
        ("Groq", "groq", "OpenAI Chat Completions", "https://api.groq.com/openai/v1", "llama-4-70b", "Bearer"),
        ("Mistral", "mistral", "OpenAI Chat Completions", "https://api.mistral.ai/v1", "mistral-large-latest", "Bearer"),
        ("Ollama(本地)", "ollama", "OpenAI Chat Completions", "http://127.0.0.1:11434/v1", "llama3", "None"),
        ("Azure OpenAI", "azure", "OpenAI Chat Completions", "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT", "gpt-4o", "API Key"),
        ("Gemini", "google", "Gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-pro", "Query key")
    ]

    /// v4.4.17：Base URL 规范化——OpenAI 格式端点 (Chat/Responses) 自动补 /v1，
    /// 用户已填 v1/含版本路径(如 /api/paas/v4、/compatible-mode/v1) 则不重复补。
    /// Anthropic(/anthropic) 与自定义端点不自动补。
    static func normalizeBaseURL(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed) else { return base }
        let path = url.path
        // 纯主机级 (path 空 或 "/") → 补 /v1；已含路径段则尊重用户
        if path.isEmpty || path == "/" {
            return trimmed + "/v1"
        }
        return base
    }

    /// 推理系列模型 (GPT-5.x / o1 / o3 / o4）不接受 temperature 参数，
    /// 中转站会返回 "Invalid request parameter"。
    var sendsTemperature: Bool { !isReasoningModel && !model.lowercased().contains("reasoning") }

    /// v2.8.5：是否推理系列模型 (GPT-5.x / o1 / o3 / o4）。
    /// 这类模型默认 reasoning_effort=medium，回复前会长时间思考 (聊天转圈半天的主因），
    /// 请求时显式携带 reasoning_effort=none 提速。
    var isReasoningModel: Bool {
        let m = model.lowercased()
        let prefixes = ["gpt-5.", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        return prefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning")
    }

    /// 推理系列模型使用 max_completion_tokens 而非 max_tokens
    var maxTokensKey: String {
        let m = model.lowercased()
        let reasoningPrefixes = ["gpt-5.", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) { return "max_completion_tokens" }
        return "max_tokens"
    }

    /// v4.4.16：API 协议自动纠偏——用户配错协议(如把 deepseek 配成 OpenAI Responses)时，
    /// 请求前自动纠正到正确协议，无需用户手动调整(大部分用户不会去改配置)。
    /// 规则参考 Codex 端点分配：
    ///  - claude/anthropic → Anthropic Messages
    ///  - gpt-5.x / o1/o3/o4 (推理系列, Codex 走 responses) → OpenAI Responses
    ///  - deepseek → OpenAI Chat Completions (deepseek 在 chat/completions 就能用 tools, 走 responses 反而慢)
    ///  - Custom Endpoint 一律尊重用户, 不自动改
    static func autoCorrectProtocol(model: String, provider: String, current: String) -> String {
        let m = model.lowercased()
        let p = provider.lowercased()
        // 显式选的自定义端点尊重用户, 不自动纠正
        if current == "Custom Endpoint" { return current }
        // Anthropic 模型
        if p.contains("anthropic") || m.hasPrefix("claude") || m.contains("claude") { return "Anthropic Messages" }
        // Gemini 模型（原生 generateContent 协议）
        if p.contains("google") || p.contains("gemini") || m.hasPrefix("gemini") || m.contains("gemini") { return "Gemini" }
        // OpenRouter（vendor/model 命名 + 专用 header）——仅限供应商匹配，避免误伤
        // 普通中转站的 vendor/model 命名模型
        if p.contains("openrouter") { return "OpenRouter" }
        // 推理系列 (Codex 同款 responses 端点)
        let reasoningPrefixes = ["gpt-5.", "gpt-6.", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning") { return "OpenAI Responses" }
        // v7.1.109-peers：智能匹配全覆盖——以下 OpenAI 兼容系一律 Chat Completions
        let chatPrefixes = [
            "deepseek", "grok-", "llama", "mixtral", "mistral", "codestral",
            "qwen", "glm", "chatglm", "kimi", "moonshot", "minimax",
            "step-", "doubao", "ernie", "hunyuan", "spark", "baichuan",
            "yi-", "internlm", "command", "phi-", "nemotron", "sensechat",
            "gpt-4", "gpt-4o", "gpt-4.1", "gpt-5", "gpt-6", "o3-mini", "o4-mini"
        ]
        if chatPrefixes.contains(where: { m.hasPrefix($0) }) { return "OpenAI Chat Completions" }
        let chatProviders = ["deepseek", "xai", "groq", "mistral", "ollama", "azure",
                             "moonshot", "kimi", "zhipu", "glm", "minimax", "stepfun",
                             "doubao", "ark", "baidu", "qwen", "aliyun", "volcengine",
                             "openai", "together", "fireworks", "novita", "siliconflow"]
        if chatProviders.contains(where: { p.contains($0) }) { return "OpenAI Chat Completions" }
        // 其余尊重当前
        return current
    }
}

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var configs: [ModelConfig] = []
    private let key = "trollmcp2.model_configs"    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个 (旧 gpt4o）
    private let lastUsedKey = "trollmcp2.last_used_config_id"

    // v7.1.40：模型配置双写 App Group（group.com.ai.iosxcode）——HUD 是独立进程
    // （bundle ch.xxtou.hudapp），读 standardUserDefaults 只能拿到进程自己的域，拿不到
    // 主 App 写入的 model_configs → _askAI 兜底到 deepseek 但 apiKey 为空 → 401 静默无回复。
    // 两侧 entitlements 都含 application-groups，suite 通道可用；读优先 suite，回退 standard（兼容老版本）。
    // v7.1.47 修正：实测两侧都是 no-sandbox 进程——UserDefaults(suiteName:) 的 suite 文件
    // 落在各自 data 容器的 Library/Preferences/group.com.ai.iosxcode.plist（物理隔离，互不可见），
    // HUD 读 suite 一直是 cfgData=NO。改 App Group 容器【文件】通道。
    // v7.1.49 再修正：containerURLForSecurityApplicationGroupIdentifier 在 no-sandbox + no-container
    // 进程返回 nil/不可写（实测 sharedFile=NO，主 App 写入静默失败）——App Group 容器通道不可用。
    // 最终通道：绝对路径共享文件 /var/mobile/Documents/trollmcp2_model_configs.json
    // （主 App 有 absolute-path read-write "/" + no-sandbox 可写；HUD no-sandbox 可读，实证可写 tts_debug.log）。
    private var suitePrefs: UserDefaults? { UserDefaults(suiteName: "group.com.ai.iosxcode") }

    /// v7.1.49：绝对路径共享配置文件（App Group 容器不可用时的可靠通道）
    private var sharedConfigFileURL: URL? {
        URL(fileURLWithPath: "/var/mobile/Documents/trollmcp2_model_configs.json")
    }

    private struct SharedConfigPayload: Codable {
        var configs: [ModelConfig]
        var last_used_config_id: String?
    }

    /// v7.1.47/49：把当前配置同步到共享文件（HUD 独立进程可靠读取通道）
    /// v7.1.50：后台异步写——主线程同步磁盘 IO 会卡死 UI（用户实测 7.1.49：开关 HUD/关于页假死黑屏，
    /// 根因即 load/save/markUsed 每次同步写文件 + 关于页同步读大日志，主线程被 IO 阻塞）
    private func syncSharedConfigFile() {
        guard let url = sharedConfigFileURL else { return }
        let payload = SharedConfigPayload(configs: configs, last_used_config_id: lastUsedConfigId)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // v7.1.51：atomic（临时文件+rename）在 /var/mobile/Documents 可能被拒 → 直接写兜底
                try? data.write(to: url)
            }
        }
    }

    init() { load() }

    var lastUsedConfigId: String? {
        get { suitePrefs?.string(forKey: lastUsedKey) ?? UserDefaults.standard.string(forKey: lastUsedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: lastUsedKey)
            suitePrefs?.set(newValue, forKey: lastUsedKey)
            syncSharedConfigFile()   // v7.1.47：切换模型立即同步共享文件（HUD 下次语音即用新配置）
        }
    }

    func markUsed(_ id: String) {
        lastUsedConfigId = id
    }

    /// v7.1.107：模型组 fallback 链——主模型 + fallbackIDs 按序展开。
    /// credential gate（对齐 OpenMinis）：过滤掉 apiKey 为空（未配凭据）的项，避免
    /// 空凭据配置抢跑导致 401 空转；去重防循环；链长上限 8 防极端配置。
    func fallbackChain(from config: ModelConfig) -> [ModelConfig] {
        var ids = [config.id]
        ids.append(contentsOf: config.fallbackIDs)
        var seen: Set<UUID> = []
        var chain: [ModelConfig] = []
        for id in ids {
            guard seen.count < 8 else { break }
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            guard let c = configs.first(where: { $0.id == id }) else { continue }
            if c.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            chain.append(c)
        }
        return chain
    }

    func load() {
        let suite = suitePrefs
        let std = UserDefaults.standard
        let suiteData = suite?.data(forKey: key)
        // suite 主数据（HUD 同源）优先；缺失时回退 standard（老版本主 App 写入）
        let data = suiteData ?? std.data(forKey: key)
        if let d = data, let decoded = try? JSONDecoder().decode([ModelConfig].self, from: d) {
            configs = decoded
            // v7.1.43：老用户升级场景——数据此前只在 standard 域（主 App 进程级），App Group 域是空的，
            // HUD 独立进程读 suite 读不到（要等下次改配置 save 才双写）→ HUD 长按语音无回复。
            // 启动时一次性把 standard 数据补写进 suite（幂等；后续 save() 继续双写）。
            if suiteData == nil { suite?.set(d, forKey: key) }
            migrateLegacyPrefs(suite: suite, std: std)
            syncSharedConfigFile()   // v7.1.47：启动即同步共享文件（老用户升级后 HUD 立即可用，不等下次 save）
            return
        }
        // v2.9.107：主数据损坏时从备份restored (最多试 4 份）——suite 优先，standard 兜底
        for i in 0...3 {
            let bak = suite?.data(forKey: "\(key).bak.\(i)") ?? std.data(forKey: "\(key).bak.\(i)")
            if let bak, let decoded = try? JSONDecoder().decode([ModelConfig].self, from: bak) {
                configs = decoded
                if suiteData == nil { suite?.set(bak, forKey: key) }
                migrateLegacyPrefs(suite: suite, std: std)
                syncSharedConfigFile()
                break
            }
        }
    }

    /// v7.1.43：老配置迁移——standard 域有而 suite 域无的 lastUsedConfigId 一次性补写（HUD 读 suite 侧）
    private func migrateLegacyPrefs(suite: UserDefaults?, std: UserDefaults) {
        if suite?.string(forKey: lastUsedKey) == nil, let oldId = std.string(forKey: lastUsedKey) {
            suite?.set(oldId, forKey: lastUsedKey)
        }
    }

    /// v2.9.107：原子写前备份轮换 (保留最近 4 份）——备份域与 save 写入域一致（suite）
    private func rotateBackup() {
        let suite = suitePrefs
        let std = UserDefaults.standard
        guard let current = suite?.data(forKey: key) ?? std.data(forKey: key) else { return }
        for i in stride(from: 2, through: 0, by: -1) {
            let old = suite?.data(forKey: "\(key).bak.\(i)") ?? std.data(forKey: "\(key).bak.\(i)")
            if let old { suite?.set(old, forKey: "\(key).bak.\(i + 1)") }
        }
        suite?.set(current, forKey: "\(key).bak.0")
    }

    func save() {
        if let data = try? JSONEncoder().encode(configs) {
            rotateBackup()
            UserDefaults.standard.set(data, forKey: key)
            suitePrefs?.set(data, forKey: key)   // v7.1.40：双写 App Group 供 HUD 独立进程读取
            syncSharedConfigFile()               // v7.1.47：同步 App Group 容器文件（HUD 可靠通道）
        }
    }

    // MARK: v2.9.107 —— 熔断器注册表 (运行时，不持久化；对齐 cc-switch circuit_breaker）

    private(set) var breakers: [UUID: CircuitBreaker] = [:]
    // v2.9.150：熔断器字典锁——ModelRow 渲染(主线程)与 AI 请求回调(后台线程)
    // 并发调 breaker(for:) 写同一字典 → 字典并发修改 SIGSEGV ("模型 API 页闪退"根因）
    private let breakerLock = NSLock()

    func breaker(for id: UUID) -> CircuitBreaker {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: configs.first { $0.id == id }?.name ?? "model")
        breakers[id] = b
        return b
    }

    // MARK: v2.9.107 —— 配置导入 / 导出 (对齐 cc-switch import/export）

    func exportJSON() -> String {
        var items: [Any] = []
        for c in configs {
            if let d = try? JSONEncoder().encode(c),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                items.append(obj)
            }
        }
        let payload: [String: Any] = [
            "app": "TrollAgent", "type": "model_configs", "version": 1,
            "exportedAt": Int(Date().timeIntervalSince1970),
            "configs": items
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return ""
    }

    @discardableResult
    func importJSON(_ text: String) -> (ok: Int, failed: Int) {
        guard let data = text.data(using: .utf8) else { return (0, 0) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["configs"] as? [[String: Any]] {
            var ok = 0, failed = 0
            for item in arr {
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let c = try? JSONDecoder().decode(ModelConfig.self, from: d) {
                    add(c); ok += 1
                } else { failed += 1 }
            }
            return (ok, failed)
        }
        // 兼容纯数组
        if let arr = try? JSONDecoder().decode([ModelConfig].self, from: data) {
            for c in arr { add(c) }
            return (arr.count, 0)
        }
        return (0, 0)
    }

    var defaultConfig: ModelConfig? {
        if let d = configs.first(where: { $0.isDefault }) { return d }
        // v2.9.97：其次取最近使用，最后回退第一个
        if let last = lastUsedConfigId, let m = configs.first(where: { $0.id.uuidString == last }) {
            return m
        }
        return configs.first
    }

    func add(_ config: ModelConfig) {
        var c = config
        if c.isDefault {
            for i in configs.indices { configs[i].isDefault = false }
        }
        if configs.isEmpty { c.isDefault = true }
        configs.append(c)
        save()
    }

    /// v2.9.126：深链导入专用——同 baseURL+model 去重 (重复导入不再堆积配置）
    func importFromDeepLink(_ config: ModelConfig) -> Bool {
        let dup = configs.contains { $0.baseURL == config.baseURL && $0.model == config.model }
        guard !dup else { return false }
        add(config)
        markUsed(config.id.uuidString)
        return true
    }

    func update(_ config: ModelConfig) {
        if config.isDefault {
            for i in configs.indices { configs[i].isDefault = (configs[i].id == config.id) }
        }
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        configs.remove(atOffsets: offsets)
        if !configs.contains(where: { $0.isDefault }) && !configs.isEmpty {
            configs[0].isDefault = true
        }
        save()
    }
}

// MARK: - 模型列表获取与连接测试

enum ModelListResult {
    case success([String])
    case failure(String)
}

final class ModelAPIClient {
    static let shared = ModelAPIClient()

    func fetchModelList(config: ModelConfig, completion: @escaping (ModelListResult) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            completion(.failure("Invalid Base URL"))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyAuth(config: config, to: &request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error.localizedDescription))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                    completion(.failure("parse failed: \(raw.prefix(200))"))
                    return
                }
                let ids = models.compactMap { $0["id"] as? String }.sorted()
                completion(.success(ids))
            }
        }.resume()
    }

    func testConnection(config: ModelConfig, completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // v2.9.0：支持 Responses API 协议
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        // v2.8.4：测试连接使用最小载荷 (仅 model + messages）。
        // 旧版发送 max_completion_tokens=8，推理模型 (gpt-5.x 默认 medium 推理）
        // 的推理 token 预算远超 8，会直接报参数错误，导致误判为连接failed。
        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            // Anthropic 协议要求必须传 max_tokens
            body = [
                "model": config.model,
                "max_tokens": 64,
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else if config.apiProtocol == "OpenAI Responses" {
            body = [
                "model": config.model,
                "input": [["role": "user", "content": "hi"]]
            ]
        } else {
            body = [
                "model": config.model,
                "messages": [["role": "user", "content": "hi"]]
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        completion(.success("Connection OK (HTTP \(http.statusCode))"))
                    } else {
                        let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        completion(.failure(NSError(domain: "ModelAPIClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw.prefix(200))"])))
                    }
                } else {
                    completion(.success("Response received"))
                }
            }
        }.resume()
    }


    // v2.9.100：通用轻量 chat 调用 (AI 分析引擎等内部工具用）。
    // 按 apiProtocol 自动选端点 (chat/completions / responses / messages），不触发工具循环。
    func sendChat(config: ModelConfig, messages: [[String: Any]],
                  timeout: TimeInterval = 90,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            body = ["model": config.model, "max_tokens": 4096, "messages": messages]
        } else if config.apiProtocol == "OpenAI Responses" {
            var msgs: [[String: Any]] = []
            for m in messages {
                msgs.append([
                    "role": (m["role"] as? String) ?? "user",
                    "content": [[ "type": "input_text", "text": (m["content"] as? String) ?? "" ]]
                ])
            }
            body = ["model": config.model, "input": msgs]
        } else {
            body = ["model": config.model, "messages": messages, "temperature": 0.3]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "no response data"])))
                    return
                }
                var text = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let msg = first["message"] as? [String: Any],
                       let content = msg["content"] as? String {
                        text = content
                    } else if let output = json["output"] as? [[String: Any]] {
                        for item in output {
                            if let content = item["content"] as? [[String: Any]] {
                                for cc in content {
                                    if let t = cc["text"] as? String { text += t }
                                }
                            }
                        }
                    } else if let content = json["content"] as? [[String: Any]] {
                        for cc in content {
                            if let t = cc["text"] as? String { text += t }
                        }
                    }
                }
                if !text.isEmpty {
                    completion(.success(text))
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "(no data)"
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(200))"])))
                }
            }
        }.resume()
    }

    private func applyAuth(config: ModelConfig, to request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "Bearer":
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "API Key":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            // 空/未知鉴权方式但填了 key 时，默认按 Bearer 发送 (兼容旧配置或 UI 异常）
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

// MARK: - 聊天消息

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    /// v7.2.3-fix19：模型输出的 tool_title（5-10 字行为摘要，对齐 OpenMinis）——
    /// 工具卡主标题优先用它；旧消息无该字段时 fallback 工具名
    var toolTitle: String? = nil

    /// v7.2.3-fix19：从 arguments JSON 提取 tool_title（模型每次调用输出）
    static func extractTitle(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["tool_title"] as? String else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: String         // user / assistant / system / tool
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolName: String?
    /// v7.2.3-fix19：模型输出的 tool_title——工具卡主标题优先用（fallback toolName）
    var toolTitle: String? = nil
    /// v3.1.26：工具调用参数摘要 (tool 消息专用），UI 里用特殊颜色显示
    var toolArgs: String? = nil
    /// v3.3.4：工具执行耗时（秒），UI 气泡显示 (如 0.3s）
    var toolDuration: Double? = nil
    /// v2.9.9：多模态附件。存 data URL (如 "data:image/jpeg;base64,..."）。
    /// 发送时若非空，OpenAIClient 把 content 序列化为多模态数组。
    var imageDataURLs: [String]? = nil
    /// v2.9.20：思考记录 (reasoning）。Responses API 返回的 reasoning 摘要，气泡内可展开。
    var thinking: String? = nil
    /// v7.1.109-peers：思考耗时（秒）——从首个思考 delta 到首个正文 delta，DeepSeek 式"已深度思考（用时 X 秒）"
    var thinkingSeconds: Double? = nil
    /// v2.9.127：执行轨迹 (对齐豆包工作任务/Codex turn 流）——AI 本次回复的
    /// 思考→工具调用→工具结果 全过程，随消息持久化，可展开回看。
    var trail: [TrailStep]? = nil
    /// v3.5.8：工具解说（模型写的"先解说后执行"正文）——Minis 式工具卡把它当步骤标题，
    /// 单独存在 tool 消息上，避免解说既出现在 assistant 气泡又出现在卡片里导致重复。
    var toolNarration: String? = nil
    /// v3.5.10：工具是否仍在执行中——true 表示这是一张"启动即上屏"的 running 步骤卡，
    /// 结果回来后置 false 并填内容。UI 据此在徽章处显示"执行中…/转圈"而非"✓完成/✗出错"。
    var isRunning: Bool = false

    var isTool: Bool { role == "tool" }
}

/// v2.9.127：执行轨迹单步 (思考/工具调用/工具结果/备注）
struct TrailStep: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var status: Status
    var detail: String
    var ts: Date = Date()

    enum Kind: String, Codable { case think, tool, result, note }
    enum Status: String, Codable { case running, success, failed }

    static func running(_ kind: Kind, _ name: String, detail: String = "") -> TrailStep {
        TrailStep(kind: kind, name: name, status: .running, detail: detail)
    }
    static func done(_ kind: Kind, _ name: String, detail: String = "", ok: Bool = true) -> TrailStep {
        TrailStep(kind: kind, name: name, status: ok ? .success : .failed, detail: detail)
    }
}

// MARK: - 单个会话

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

// MARK: - 会话管理

final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published var conversations: [ChatConversation] = []
    @Published var selectedId: UUID?
    @Published var isLoading = false
    /// v2.8.5：当前请求的实时状态文案 (等待响应/降级重试中），展示在输入指示器旁
    @Published var statusText: String?
    /// v2.9.34：请求过程可视化——当前第几轮 (v4.3.71 起无轮次上限)
    @Published var requestRound = 0
    /// v4.3.71：0 = 无轮次上限（已移除 60 轮机制），UI 只显示"第 N 轮"
    @Published var requestRounds = 0
    /// v2.9.34：正在执行的工具名 (展示"正在执行工具 xxx…"）
    @Published var runningTool: String?
    /// v3.5.10：正在上屏的"工具启动即显示 running 步骤卡"的消息 id——
    /// 工具启动先 append 一张 isRunning=true 的占位卡（真实工具名+命令，机制保证每步可见，
    /// 不依赖模型解说），结果回来后在 handleDispatchResult 原地更新成完成/出错卡。
    /// v7.1.106：单槽改多槽（toolCallId → 消息 id）——真并行批会同时有多张 running 卡，
    /// 串行路径同样用此字典（每批一个 toolCallId 唯一），resolvePendingTool 按 callId 定位。
    var pendingToolMsgIDs: [String: UUID] = [:]
    /// v2.9.127：执行轨迹 (实时）——当前请求的 思考→工具调用→工具结果 步骤流，
    /// 请求结束时随最后一条 assistant 消息持久化 (message.trail）。
    @Published var liveTrail: [TrailStep] = []

    // v3.0.3：保存当前请求的思考内容 (onThinking 流式累加），
    // toolCalls 时传到 tool 消息，前端在 toolBubble 顶部显示
    private var thinkBuffer: String = ""
    /// v7.1.109-peers：思考计时起点（首个 onThinking delta 时间），首个正文 delta 时结算 thinkingSeconds
    private var thinkingStartAt: Date? = nil

    // v2.9.87：网络恢复自动重试 ("切后台回来网络中断"补偿）——
    // 网络类错误且当前确认为断网时，等 AppLifecycleMonitor 广播 networkRestored 后自动重发一次。
    private var retryObserver: NSObjectProtocol?
    private var retriedNetworkOnce = false
    /// v2.9.13：当前正在进行的 OpenAIClient (支持取消）
    private var currentClient: OpenAIClient?
    /// v2.9.53：当前流式输出的消息 ID (逐字显示时跟踪，done后更新或清理）
    /// v3.4.5：改为 internal（ChatView 用它标记打字机效果的消息）
    var streamingMessageId: UUID?
    /// v3.4.9：本轮刚"生成完成"的 assistant 消息 ID（工具解说/整段到达的回复）。
    /// ChatView 用它给这些消息开打字机——它们 isStreaming=false 且内容在出现前已定好，
    /// 只能靠"本轮刚产出"这一信号触发逐字显示。请求整体结束后清空。
    var liveProducedID: UUID?
    /// v3.5.6：工具参数 schema 预校验——模型调工具但缺必填参数时，不执行，注入纠正消息重跑
    /// 一轮逼它补齐再调（对齐 harness "机制决定行为"，治"invalid params required 盲试"老毛病）。
    private var pendingParamCorrection: String? = nil
    /// v3.5.6：参数纠正连续次数——同一 tool 决策最多纠正 2 次仍缺参就放行执行，避免死循环。
    private var paramCorrectionCount = 0
    /// v4.3.25：空回复纠正——工具结果回来、模型最终却输出空文本时，注入"请给结论"纠正
    /// 重跑一轮，不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
    private var pendingEmptyReplyCorrection: String? = nil
    /// v4.3.25：空回复纠正连续次数——最多 2 次仍空就停止，避免无限重跑。
    private var emptyReplyCorrectionCount = 0
    /// v3.1.70：活动请求绑定的会话 ID——请求由哪个会话发起就写回哪个会话。
    /// 修复"请求进行中切换会话，AI 输出错位/写错会话" (用户实测：老会话未暂停，切换新会话后输出仍乱）。
    private var activeConvId: UUID?
    /// v4.5.8：永不清除的"发起请求的会话"锁定——activeConvId 会在停止/请求结束时清 nil，
    /// 若此刻流式仍在回调，activeConvIndex 兜底 selectedIndex 就会把 AI 输出写进切换后的会话 (用户实测)。
    /// requestSessionId 只在下一次 send() 时覆盖，不受停止/切换影响，保证流式始终写回发起会话。
    private var requestSessionId: UUID?
    /// v3.5.16：用户点了「停止」——设 true 后 runLoop 每轮开头检查，若已停止则不再继续递归
    /// (修复"点了暂停/停止还在继续发消息"：此前进度只取消当前 client，递归会新建 client 接着跑)。
    private(set) var stopRequested = false  // v4.3.77：工具批量循环需读（停止后跳出，不再装剩余包）

    private let key = "trollmcp2.conversations"

    init() { load() }

    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedId }
    }

    /// v3.1.70：活动请求的会话 index (优先活动会话，兜底当前选中会话）
    private var activeConvIndex: Int? {
        if let id = activeConvId ?? requestSessionId, let i = conversations.firstIndex(where: { $0.id == id }) {
            return i
        }
        return selectedIndex
    }

    var currentMessages: [ChatMessage] {
        guard let idx = selectedIndex else { return [] }
        return conversations[idx].messages
    }

    var currentTitle: String {
        guard let idx = selectedIndex else { return "Conversation" }
        return conversations[idx].title
    }

    /// v4.5.8：当前选中会话是否正在请求——右下角"停止"按钮据此显示。
    /// 此前用全局 isLoading：请求中切到别的会话，新会话右下角也显示红色"停止"(该会话并无请求)，困惑。
    var selectedIsRequesting: Bool {
        isLoading && selectedIndex == activeConvIndex
    }

    func newConversation(title: String? = nil) {
        let conv = ChatConversation(title: title ?? L10n.t("i18n_1059"), createdAt: Date(), updatedAt: Date(), messages: [])
        conversations.insert(conv, at: 0)
        selectedId = conv.id
        // v2.9.22：新会话清空工具会话授权 (AI 需重新搜索/决定）
        ToolRegistry.shared.clearSessionApproval()
        // v6.0.28：新会话清空TTS队列，不要读上一段的内容
        TTSService.shared.stop()
        save()
    }

    func select(_ id: UUID) {
        // v2.9.12：打开会话即视为"最近使用"，刷新 updatedAt 并重排到最前
        if selectedId != id, let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].updatedAt = Date()
        }
        selectedId = id
        // v6.0.28：切换会话清空TTS队列，不要读上一段的内容
        TTSService.shared.stop()
        sortAndSave()
    }

    /// v3.1.70：写入活动请求的会话 (无活动请求时写入当前选中会话）
    func appendToCurrent(_ message: ChatMessage) {
        guard let idx = activeConvIndex else { return }
        var conv = conversations[idx]
        if conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    /// v3.1.70：更新活动请求会话内消息内容 (无活动请求时用当前选中会话）
    func updateMessageContent(id: UUID, content: String) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages[mi].content = content
        conversations[idx].updatedAt = Date()
    }

    /// v3.1.70：删除活动请求会话内的消息 (无活动请求时用当前选中会话）
    func removeMessage(id: UUID) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.remove(at: mi)
    }

    /// v2.9.13：取消当前进行中的请求 (ChatView 停止按钮）
    func cancelCurrent() {
        stopRequested = true          // v3.5.16：设停止标志，runLoop 递归到下一轮即停
        // v4.3.77：立即中断正在跑的 Alpine 命令/安装（否则 apkAdd 会闷头跑到 240s 且占着串行锁）
        TrollRuntimeEngine.interruptCurrent()
        cancelNetworkRetry()
        currentClient?.cancel()
        currentClient = nil
        isLoading = false
        statusText = nil
        // v2.9.82：回收后台任务
        TaskNotify.shared.endBackground()
        // v3.1.70：停止——解除活动会话绑定
        activeConvId = nil
    }

    func clearCurrent() {
        guard let idx = selectedIndex else { return }
        var conv = conversations[idx]
        conv.messages.removeAll()
        conv.title = L10n.t("i18n_1059")
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    /// v7.1.72：清空全部会话——设置→会话记录"清空"同时清掉聊天框侧边栏全部会话（同一数据源）
    func clearAll() {
        conversations.removeAll()
        selectedId = nil
        save()
        // v6.0.28：清空会话同样停掉 TTS 队列，避免残留音频读旧内容
        TTSService.shared.stop()
    }

    func delete(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        if selectedId != nil && !conversations.contains(where: { $0.id == selectedId }) {
            selectedId = conversations.first?.id
        }
        sortAndSave()
    }

    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true, personaPrompt: String? = nil) {
        // v7.2.3：personaPrompt 非空 = 语音角色对话模式——系统提示词替换为角色人设，且不带任何工具调用

        // v2.9.97：记住最近使用的模型，顶栏/下次启动立即恢复
        ModelStore.shared.markUsed(config.id.uuidString)
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()
        TaskNotify.shared.beginBackground()
        // v2.9.87：新一轮请求重置网络重试状态
        retriedNetworkOnce = false
        cancelNetworkRetry()
        // v3.1.70：请求绑定到发起时的会话——中途切换会话，输出仍写回该会话 (修复输出错位）
        activeConvId = selectedId
        requestSessionId = selectedId   // v4.5.8：永不清除的锁定兜底 (防 activeConvId 清 nil 后写错会话）
        // v3.4.9：新请求开始，清掉上一轮的"刚产出"标记（避免旧消息被重新打字）
        liveProducedID = nil
        // v3.5.16：新请求开始，清除上次的停止标志（让 runLoop 可继续）
        stopRequested = false
        // v3.5.6：重置工具参数预校验纠正状态
        paramCorrectionCount = 0
        pendingParamCorrection = nil
        // v4.3.25：重置空回复纠正状态（跨任务不残留）
        emptyReplyCorrectionCount = 0
        pendingEmptyReplyCorrection = nil
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        appendToCurrent(msg)
        isLoading = true

        // v3.1.66：全量加载所有工具 (tool_search 已删除，不再渐进式披露）
        var baseTools: [[String: Any]]? = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.enabledOpenAIToolSchema()
        // v7.2.3：语音角色模式不带工具（人设对话，无 schema 注入）
        if personaPrompt != nil {
            baseTools = nil
        }
        // v2.9.20：智能搜索开关真实生效——关闭时从工具集移除 web.search / knowledge.search / web.fetch
        if !smartSearch {
            let exclude = Set(["web.search", "knowledge.search", "web.fetch"])
            baseTools = baseTools?.filter { t in
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    return !exclude.contains(n)
                }
                return true
            }
        }
        // v3.1.66：全量加载，disclosed 机制已不再新增工具 (tool_search 已删），
        // 保留仅为兼容会话内已授权工具 schema 的持久注入。
        let preDisclosed: [String] = personaPrompt == nil ? ToolRegistry.shared.approvedToolNames() : []
        runLoop(config: config, tools: baseTools, disclosed: preDisclosed, depth: 0, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
    }

    // MARK: - v2.9.87 网络恢复自动重试

    private func shouldRetryOnNetworkRestore(_ err: NSError) -> Bool {
        guard !retriedNetworkOnce, err.code != -999 else { return false }
        // 网络类错误码：断网/找不到主机/网络连接丢失/连接重置
        let networkCodes: Set<Int> = [-1009, -1003, -1005, -1004, -1001]
        let isNetworkError = err.domain == NSURLErrorDomain && networkCodes.contains(err.code)
        // 只对"当前确实断网"的情况等待重试 (确认不是中转站问题）
        return isNetworkError && !AppLifecycleMonitor.shared.isNetworkAvailable
    }

    private func scheduleRetryAfterNetworkRestore(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int, personaPrompt: String? = nil) {
        retriedNetworkOnce = true
        retryObserver = NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.networkRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let o = self.retryObserver {
                NotificationCenter.default.removeObserver(o)
                self.retryObserver = nil
            }
            self.statusText = "Network restored, auto-retrying…"
            self.isLoading = true
            self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
        }
    }

    private func cancelNetworkRetry() {
        if let o = retryObserver {
            NotificationCenter.default.removeObserver(o)
            retryObserver = nil
        }
    }

    /// v2.9.127：新一轮请求开始——清空实时轨迹
    func beginTrail() {
        DispatchQueue.main.async {
            self.liveTrail = []
        }
    }

    /// v2.9.127：追加一条实时轨迹步骤
    func trailStep(_ step: TrailStep) {
        DispatchQueue.main.async {
            self.liveTrail.append(step)
        }
    }

    /// v2.9.127：把实时轨迹持久化到最后一条 assistant 消息 (AI 回复done后调用）
    /// thinking 非空时把"已思考"插到轨迹最前 (对齐豆包流程第一步）。
    /// 收尾：残留 running 步骤统一标OK/failed (消息报错则标failed）。
    func attachTrail(to messageId: UUID?, thinking: String? = nil) {
        guard let sid = messageId, !liveTrail.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.activeConvIndex,
               let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) {
                var trail = self.liveTrail
                let isErr = self.conversations[idx].messages[mi].isError
                for i in 0..<trail.count where trail[i].status == .running {
                    var s = trail[i]
                    s.status = isErr ? .failed : .success
                    trail[i] = s
                }
                // 思考去重：实时流已产生 think 步骤则不重复插入
                if let th = thinking, !th.isEmpty, !trail.contains(where: { $0.kind == .think }) {
                    trail.insert(TrailStep.done(.think, "Thought", detail: String(th.prefix(300))), at: 0)
                }
                self.conversations[idx].messages[mi].trail = trail
                self.save()
            }
        }
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int = 0, personaPrompt: String? = nil) {
        // v3.5.16：用户点了「停止」——立即停，不再继续递归 (修复"停止后还在发消息")
        if stopRequested {
            isLoading = false
            statusText = nil
            requestRound = 0
            runningTool = nil
            currentClient?.cancel()
            currentClient = nil
            TaskNotify.shared.endBackground()
            activeConvId = nil
            self.liveTrail = []
            return
        }
        // v2.9.25：不再限制工具调用轮次 (用户可手动点「停止」）。
        // v4.3.71：移除 60 轮极端安全上限——长会话已由 LLM Compaction 控制上下文体积，
        // 不再需要轮次硬停（用户仍可随时点「停止」按钮中断；工具死循环仍由 _loop_hint 提示）。
        // v2.9.34：请求过程可视化
        DispatchQueue.main.async {
            self.requestRound = depth + 1
            self.requestRounds = 0   // v4.3.71：无轮次上限
            self.statusText = "Request ready (organizing conversation and available tools)"
            self.liveTrail = []   // v2.9.127：新一轮清空实时轨迹
        }

        // 动态合并：白名单 schema + 已披露工具的 schema (去重）
        // v2.9.175：tools 为 nil (Anthropic 协议）时也走空数组合并——Anthropic 通道
        // 现在同样能拿到 coreTools + 已披露工具的 schema (OpenAIClient 已支持转换）。
        var effectiveTools = tools ?? []
        if !disclosed.isEmpty {
            var existing = Set<String>()
            for t in effectiveTools {
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    existing.insert(n)
                }
            }
            for name in disclosed {
                let apiName = name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted).joined(separator: "_")
                if existing.contains(apiName) { continue }
                if let schema = ToolRegistry.shared.openAISchema(for: name) {
                    effectiveTools.append(schema)
                    existing.insert(apiName)
                }
            }
        }

        let client = OpenAIClient(config)
        // v7.2.3-fix6：鉴权智能试探成功 → 持久化纠正（对齐 OpenMinis BYOK 智能匹配）
        client.onAuthCorrected = { [weak self] method in
            guard let self = self else { return }
            let cfg = config
            var corrected = cfg
            corrected.authMethod = method
            ModelStore.shared.update(corrected)
            self.statusText = L10n.t("status_auth_corrected", method)
        }
        client.currentReasoningLevel = reasoningLevel
        currentClient = client
        let prepared = messagesForAPI(budget: config.effectiveContextTokens)
        // v7.1.109-peers：硬停不适配 Agent 长任务（OpenMinis 是消费级对话可卡住，
        // 我们长任务/工具链会被硬停打断）——改为极限压缩后的非阻断提示：
        // 即便仍超窗也继续发送（API 兜底 + 用户可见错误），不再 return 卡住。
        let window = config.effectiveContextTokens
        if window > 0 {
            let finalTotal = prepared.messages.reduce(0) { $0 + Self.estimateTokens($1) }
            if finalTotal > window {
                self.statusText = "⚠️ 上下文已极限压缩仍接近窗口上限(≈\(finalTotal)/\(window))，已继续发送——若失败请新建会话"
            }
        }
        var history = prepared.messages
        // v2.9.138：模块化 system prompt 组装 (稳定前缀工程）——
        // 稳定块 (系统指令→开发者指令）在前、动态状态块 (设备/App/工作区/会话）在后，
        // 稳定前缀保持字节一致 → 官方 API 前缀缓存可直接matched (Anthropic/OpenAI）。
        // v7.2.3：语音角色模式用 persona 替换主系统提示词（角色人设 + 轻量环境 facts，无工具说明）
        if let persona = personaPrompt, !persona.isEmpty {
            history.insert(ChatMessage(role: "system", content: persona), at: 0)
        } else {
            history.insert(ChatMessage(role: "system", content: SystemPrompts.shared.selected.content), at: 0)
            if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
                history.insert(ChatMessage(role: "system", content: "Developer instructions below, always follow:\n" + devInstr), at: 0)
            }
        }
        // 动态状态块：最新信息放最后，不影响稳定前缀缓存
        history.insert(ChatMessage(role: "system", content: Self.dynamicStatePrompt()), at: 0)
        // Tool-param prevalidation correction injection: missing required params blocked last round, append likewise.
        if let pcorr = self.pendingParamCorrection, !pcorr.isEmpty {
            history.append(ChatMessage(role: "user", content: pcorr))
            self.pendingParamCorrection = nil
        }
        // Empty-reply correction injection: if the model output blank after running tools last round, append this to force a conclusion.
        if let ecorr = self.pendingEmptyReplyCorrection, !ecorr.isEmpty {
            history.append(ChatMessage(role: "user", content: ecorr))
            self.pendingEmptyReplyCorrection = nil
        }

        client.send(messages: history, compactSource: prepared.compactSource, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async {
                // v2.9.34：带轮次前缀；v4.3.71 无上限 (requestRounds==0) 时不显示 "/0"
                if self.requestRound > 0 && !status.contains("Round ") {
                    if self.requestRounds > 0 {
                        self.statusText = L10n.t("status_requesting_model_rounds", self.requestRound, self.requestRounds) + " · " + status
                    } else {
                        self.statusText = L10n.t("status_requesting_model_round", self.requestRound) + " · " + status
                    }
                } else {
                    self.statusText = status
                }
            }
        }, onDelta: { delta in
            // v2.9.53：流式逐字显示
            DispatchQueue.main.async {
                if let sid = self.streamingMessageId {
                    // 追加到已有流式消息 (v3.1.70：按活动会话定位，切换会话不丢增量）
                    guard let idx = self.activeConvIndex,
                          let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) else { return }
                    self.conversations[idx].messages[mi].content += delta
                } else {
                    // 第一次 delta：创建流式消息
                    var msg = ChatMessage(role: "assistant", content: delta)
                    // v7.1.109-peers：思考计时结算——首个正文 delta 到达，思考结束
                    if let st = self.thinkingStartAt {
                        msg.thinkingSeconds = Date().timeIntervalSince(st)
                        self.thinkingStartAt = nil
                    }
                    self.streamingMessageId = msg.id
                    self.liveProducedID = msg.id
                    self.appendToCurrent(msg)
                }
            }
        }, onThinking: { delta in
            // v3.5.4：思考只进黄泡(message.thinking) + thinkBuffer(供 toolCalls 装配)，
            // 不再写 liveTrail——否则实时轨迹卡也渲染思考，导致同一思考出现两次 (用户实测截图)。
            // 实时轨迹卡(liveTrail)只显示"工具执行步骤"：工具名/命令/结果，绝不显示思考文字。
            DispatchQueue.main.async {
                // v7.1.109-peers：思考计时——首个思考 delta 记起点
                if self.thinkingStartAt == nil { self.thinkingStartAt = Date() }
                self.thinkBuffer += delta
                // v3.5.4：思考实时写入流式消息的 thinking(黄色气泡)，随模型思考逐段填充、不打字机。
                // 若无流式消息(思考先于正文到达)，先建一条空 assistant 消息，把思考挂上去。
                if let sid = self.streamingMessageId {
                    if let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        let existing = self.conversations[ci].messages[mi].thinking ?? ""
                        self.conversations[ci].messages[mi].thinking = existing + delta
                    }
                } else {
                    // v3.5.16：防"思考重复两次"——.text 最终化(streamingMessageId=nil)后又来一段 onThinking 时，
                    // 会在这里再建一条空正文+思考消息，与上一条已含相同思考的 assistant 消息重复
                    // (顶部"已深度思考"+ 底部"思考中…"两遍)。新建前先查上一条是否已含这段思考，是则跳过。
                    var skipDup = false
                    if let ci = self.activeConvIndex, let li = self.conversations[ci].messages.indices.last {
                        let last = self.conversations[ci].messages[li]
                        if last.role == "assistant", let ex = last.thinking, !ex.isEmpty {
                            if ex == delta || ex.contains(delta) || delta.contains(ex) {
                                skipDup = true
                            }
                        }
                    }
                    if !skipDup {
                        var msg = ChatMessage(role: "assistant", content: "")
                        msg.thinking = delta
                        self.streamingMessageId = msg.id
                        self.liveProducedID = msg.id
                        self.appendToCurrent(msg)
                    }
                }
            }
        }, onCompacted: { summary in
            // v7.1.41：LLM Compaction 持久化——摘要写回会话历史（对齐 Claude Code /compact 的破坏性替换），
            // 下次请求不再重复压缩同一堆旧消息，而是增量合并
            DispatchQueue.main.async {
                self.applyCompaction(summary: summary, droppedCount: prepared.droppedCount)
            }
        }) { result in
            DispatchQueue.main.async {
                self.statusText = nil
                switch result {
                case .success(.text(let text, let thinking)):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    // v2.9.138：自动会话记忆——一轮完整回复后落库 (供下会话 BM25 检索）
                    if let idx = self.activeConvIndex {
                        let msgs = self.conversations[idx].messages
                        let lastUser = msgs.last { $0.role == "user" }?.content ?? ""
                        let usedTools = msgs.compactMap { $0.toolName }
                        KnowledgeStore.shared.appendSessionMemory(
                            user: String(lastUser.prefix(80)),
                            reply: String(text.prefix(150)),
                            tools: Array(Set(usedTools)).sorted().suffix(8))
                    }
                    // v2.9.127：轨迹——回复done，附到消息持久化
                    self.trailStep(.done(.note, "AI reply done", detail: String(text.prefix(80))))
                    // v2.9.82：done通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "✅ AI replied", body: String(text.prefix(60)))
                    if let sid = self.streamingMessageId {
                        // 流式已显示，更新最终文本 + thinking
                        self.updateMessageContent(id: sid, content: text)
                        if let idx = self.activeConvIndex,
                           let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }),
                           let th = thinking, !th.isEmpty {
                            self.conversations[idx].messages[mi].thinking = th
                        }
                        self.attachTrail(to: sid, thinking: thinking)
                        self.streamingMessageId = nil
                    } else {
                        // v3.5.16：修复"思考显示两次"——流式中 onThinking 可能已建了一条"空正文+思考"消息
                        // (思考先于正文到、且正文没进它），此时若直接 appendToCurrent 会再建第二条
                        // (顶部"已深度思考" + 底部"思考中"重复)。改为复用那条空思考消息填正文。
                        var reused = false
                        if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               msgs[li].thinking?.isEmpty == false {
                                msgs[li].content = text
                                if let th = thinking, !th.isEmpty { msgs[li].thinking = th }
                                self.conversations[ci].messages = msgs
                                self.streamingMessageId = nil
                                self.liveProducedID = nil
                                self.attachTrail(to: msgs[li].id, thinking: thinking)
                                reused = true
                            }
                        }
                        if !reused {
                            var am = ChatMessage(role: "assistant", content: text)
                            if let th = thinking, !th.isEmpty { am.thinking = th }
                            self.appendToCurrent(am)
                            self.liveProducedID = am.id
                            self.attachTrail(to: am.id, thinking: thinking)
                        }
                    }
                    // v4.3.25：空回复兜底——工具结果回来、模型最终却输出空文本时，
                    // 不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
                    // 若会话末尾是 tool 结果消息且本条回复为空白，注入纠正重跑一轮逼模型给结论；
                    // 最多 2 次仍空就停止，避免无限重跑。
                    let trimmedFinal = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var lastMsgIsTool = false
                    if let ci = self.activeConvIndex {
                        if let last = self.conversations[ci].messages.last {
                            lastMsgIsTool = (last.role == "tool")
                        }
                    }
                    if trimmedFinal.isEmpty && lastMsgIsTool && self.emptyReplyCorrectionCount < 2 {
                        self.emptyReplyCorrectionCount += 1
                        self.pendingEmptyReplyCorrection = "You just ran tools but your reply body is empty. Based on the returned tool results, give the user a clear 1-2 sentence conclusion (or say what to do next) — don't reply blank or just 'Done'."
                        self.trailStep(.done(.note, "Empty-reply correction", detail: "Model returned empty text, injected a correction and reran", ok: false))
                        // 清掉刚渲染的空 assistant 消息，避免界面残留空白气泡
                        if let sid = self.streamingMessageId {
                            self.removeMessage(id: sid)
                        } else if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                msgs.remove(at: li)
                                self.conversations[ci].messages = msgs
                            }
                        }
                        self.streamingMessageId = nil
                        self.liveProducedID = nil
                        self.thinkBuffer = ""
                        self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                        return
                    }
                    self.emptyReplyCorrectionCount = 0
                    // v3.5.3：文本工具调用兜底——模型把 shell.exec("...")/shell_exec(...) 写成文本
                    // (而非结构化 tool_call) 时，系统本不执行、任务卡死。这里检测最终文本里的文本式
                    // shell 调用，提取命令并真正执行，继续 agent 循环（提示词兜底不住，代码兜底保证）。
                    self.runTextualShellIfNeeded(text: text, config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                    // v3.1.70：整条请求链 (含工具递归）结束——解除活动会话绑定
                    self.activeConvId = nil
                case .success(.toolCalls(let calls, let thinking, let narrationContent)):
                    // v3.5.2：系统级"一次一个工具"硬约束——模型一次批几个 toolCalls，
                    // 都裁成第一个：assistant 消息与执行只带这一个，执行完回模型让它看到
                    // 结果再决定下一步（一个接一个）。依赖调用必须等前一个结果才能决定下一步，
                    // 合批执行会让模型猜结果(违规)；提示词不可靠，代码兜底强制一次一个。
                    // v7.1.99：按工具分类放开——只读/查询类（system_overview/tools_audit/verify、
                    // shell_exec 只读命令、browser 只读子命令）可一次多条依次执行（省 N-1 轮往返，
                    // 用户实测效率慢）；副作用/写类（inject/app/control/artifact 等）保持一次一条
                    // 回模型等结果（依赖安全）。判断见 Self.isParallelSafeTool。
                    // v7.1.108-minis：废除批截断（prefix 1/4 会静默丢弃模型已生成的调用——
                    // 只读批>4 丢剩余造成漏检、混合批只做第一个造成 N 轮往返重发）。
                    // 对齐 OpenMinis：全批执行，并发上限用分波(≤4 一波自动续，等价 in-flight
                    // 排队)，混合批 writer(副作用)依次 + reader(只读)并发(读后写天然满足)。
                    // 分流见 processToolCalls 内 index==0 处。
                    // v3.1.72：思考(reasoning)与可见输出(content)分开存放——
                    // 旧逻辑把流式可见文本+思考合并成 thinkText 塞进 assistant.content，
                    // 又把同一 thinkText 塞进 tool 消息 thinking，导致 UI 上"回复内容"和
                    // "思考内容"显示一模一样、每轮工具调用重复一次 (用户实测反馈）。
                    var visibleText = ""
                    var reasoningText = self.thinkBuffer
                    if let th = thinking, !th.isEmpty {
                        reasoningText = reasoningText.isEmpty ? th : "\(reasoningText)\n\(th)"
                    }
                    // 先取流式可见文本（模型若已发解说则以其为准）
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        visibleText = self.conversations[ci].messages[mi].content
                    }
                    // v3.5.15：兜底——非流式 chat/completions 没有 streamingMessageId，
                    // 但模型写的正文解说已由 .toolCalls 的 content 透传出来，直接用当 visibleText。
                    if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let nc = narrationContent, !nc.isEmpty {
                        visibleText = nc
                    }
                    // v4.5.x：去掉"解说纠正"硬门槛（对齐大厂事件流方案）——
                    // 旧实现(v3.5.5/v3.5.10)：模型发 tool_calls 但没写正文解说时，不执行工具，
                    // 注入纠正消息重跑一轮，上限 4 次。实测模型(L0 chat/completions)工具轮
                    // content 为空是 API 层常态 → 永远重跑到上限 → 每次请求固定 5 轮、token 烧 5 倍。
                    // 大厂(Claude Code/Codex)不惩罚：模型说什么就做什么，工具照常执行，
                    // 解说由 thinking 黄泡 + 工具步骤卡片事件流呈现。这里直接放行。
                    // v3.5.4：正文解说只取模型自己写在 content 里的文本；模型若光思考没写正文解说，
                    // 正文就保持空(6.A)——不再用 reasoning 自动合成解说（用户明确：▶ 开始执行那种
                    // 机械合成是误解；思考归思考进黄泡，正文只放 AI 自己说的话，空就空着）。
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        // 保留流式可见文本作为回复内容，思考进 thinking 字段，toolCalls 挂上 (不删除重建）
                        // 模型没写正文解说时 visibleText 为空 → content 保持空，只显示思考黄泡 + 工具步骤 (6.A)
                        if self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.conversations[ci].messages[mi].content = visibleText
                        }
                        self.conversations[ci].messages[mi].toolCalls = calls
                        // v3.5.4：思考始终写入黄色气泡(message.thinking)，不再要求 content 为空——
                        // 此前 reasoning 被 v3.5.1 打进正文使 content 非空，导致 thinking 永不写入、黄泡为空。
                        // 与正文去重：部分中转把完整回答写进 reasoning_content，与 content 相同则不展示思考。
                        let cText = self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim.isEmpty, !(cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim)) {
                            self.conversations[ci].messages[mi].thinking = reasoningText
                        } else if !rTrim.isEmpty {
                            // 思考与正文重复(中转把完整回答写进 reasoning_content) → 清掉黄泡，避免重复展示
                            self.conversations[ci].messages[mi].thinking = nil
                        }
                    } else {
                        // 无流式消息 (流式未开始就被 toolCalls 打断）：新建 assistant 消息
                        var am = ChatMessage(role: "assistant", content: visibleText, toolCalls: calls)
                        let vTrim = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim2 = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim2.isEmpty, !(vTrim == rTrim2 || rTrim2.contains(vTrim) || vTrim.contains(rTrim2)) {
                            am.thinking = reasoningText
                        }
                        self.appendToCurrent(am)
                        self.liveProducedID = am.id
                    }
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    self.streamingMessageId = nil
                    // v2.9.127：轨迹——AI 决定调用一批工具
                    self.trailStep(.done(.tool, "AI chose to call \(calls.count) tools",
                                         detail: calls.map { $0.name }.joined(separator: "、")))
                    // v2.9.31：递归处理一批工具调用 (后台执行，无授权弹窗）
                    // v3.1.72：thinkText 传可见文本 (工具调用前的说明），不再写入 tool 消息 thinking
                    self.processToolCalls(calls, index: 0, toolMessages: [], newlyDisclosed: [],
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: visibleText)
                case .failure(let error):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    self.liveProducedID = nil
                    // v2.9.13：用户主动取消 (-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        self.streamingMessageId = nil
                        // v2.9.82：取消也算结束，回收后台任务但不通知
                        TaskNotify.shared.endBackground()
                        // v3.1.70：用户取消——解除活动会话绑定
                        self.activeConvId = nil
                        return
                    }
                    // v2.9.87：网络类错误 + 当前确认断网 → 等网络恢复自动重试一次
                    if self.shouldRetryOnNetworkRestore(nsErr) {
                        self.statusText = "Network unavailable, auto-retrying after recovery…"
                        self.scheduleRetryAfterNetworkRestore(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                        return
                    }
                    // v2.9.82：failed通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "⚠️ Task error", body: String(error.localizedDescription.prefix(60)))
                    // 流式failed时保留已输出的部分文本，追加错误提示
                    if self.streamingMessageId != nil {
                        self.streamingMessageId = nil
                    }
                    let errMsg = ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true)
                    self.appendToCurrent(errMsg)
                    self.trailStep(.done(.note, "Request failed", detail: String(error.localizedDescription.prefix(200)), ok: false))
                    self.attachTrail(to: errMsg.id)
                    // v3.1.70：请求链结束——解除活动会话绑定
                    self.activeConvId = nil
                }
            }
        }
    }

    /// v2.9.127：轨迹摘要——取 JSON 里 ok/message/status 等关键字段，超长截断
    static func trailSummary(_ json: String) -> String {
        let trimmed = json.count > 300 ? String(json.prefix(300)) : json
        // 去掉换行压扁，便于步骤行内展示
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    /// v3.1.26：把参数 JSON 转成简短摘要 (比如 "url: https://xxx"）
    /// UI 里用特殊颜色显示，太长就截断
    static func summarizeArgs(_ argsString: String) -> String? {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 只取前 2 个参数，每个值截断到 50 字符
        let entries = json.prefix(2).map { key, value -> String in
            let val: String
            if let s = value as? String {
                val = s
            } else {
                val = "\(value)"
            }
            let truncated = val.count > 50 ? String(val.prefix(50)) + "..." : val
            return "\(key): \(truncated)"
        }
        return entries.joined(separator: ", ")
    }

    /// v2.9.31：递归处理一批工具调用。工具在后台线程执行 (避免耗时操作阻塞主线程），
    /// 结果经 handleDispatchResult 回主线程继续。
    /// v3.5.3：文本工具调用兜底——从最终文本里提取文本式 shell 调用命令（shell.exec("...") /
    /// shell_exec(command="...") 等）。模型把调用写成文本(而非结构化 tool_call)时系统不执行，
    /// 这里兜底提取出真实命令让 runTextualShellIfNeeded 真正执行。
    private static func extractTextualShellCommand(from text: String) -> String? {
        let patterns = [
            #"shell\.exec\s*\(\s*["']([^"']+?)["']\s*\)"#,          // shell.exec("cmd") / shell.exec('cmd')
            #"shell_exec\s*\(\s*command\s*[:=]\s*["']([^"']+?)["']"#, // shell_exec(command="cmd")
            #"shell_exec\s*\(\s*["']([^"']+?)["']\s*\)"#           // shell_exec("cmd")
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let ns = text as NSString
            if let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let c = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
            }
        }
        return nil
    }

    /// v3.5.3：执行文本兜底提取出的 shell 命令，把结果作为 tool 消息上屏并继续 agent 循环，
    /// 让模型看到结果后能继续下一步（而非卡死在"写了文本没执行"）。
    private func runTextualShellIfNeeded(text: String, config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int, personaPrompt: String? = nil) {
        guard let cmd = Self.extractTextualShellCommand(from: text) else { return }
        let cmdCopy = cmd
        DispatchQueue.global().async {
            let params: [String: Any] = ["command": cmdCopy]
            let result: Result<[String: Any], Error>
            do { result = .success(try ToolRegistry.shared.dispatch(name: "shell.exec", params: params)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                var tm = ChatMessage(role: "tool", content: "", toolCallId: UUID().uuidString, toolName: "shell.exec")
                switch result {
                case .success(let r):
                    let raw = Self.jsonString(r)
                    // v7.2.3-fix25：工具结果硬截断上限 8000 → 48000（旧 16k 窗口时代的值；
                    // contextTokens 默认已 128k，8000 会把工具完整结果（即使显式 limit=50000）
                    // 砍到 8k——用户实测 1000 行输出仍 truncated 根因）
                    tm.content = raw.count > 48000 ? raw.prefix(48000) + "\n... [tool result truncated, total \(raw.count) chars]" : raw
                    tm.toolArgs = String("Command: \(cmdCopy.prefix(120))")
                    tm.toolDuration = 0.01
                case .failure(let e):
                    tm.content = "Execution failed: \(e.localizedDescription)"
                    tm.isError = true
                    tm.toolArgs = String("Command: \(cmdCopy.prefix(120))")
                }
                self.appendToCurrent(tm)
                self.liveProducedID = tm.id
                // 继续 agent 循环，模型看到结果后可决定下一步
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
            }
        }
    }

    private func processToolCalls(_ calls: [ToolCall],
                                  index: Int,
                                  toolMessages: [ChatMessage],
                                  newlyDisclosed: [String],
                                  config: ModelConfig,
                                  tools: [[String: Any]]?,
                                  disclosed: [String],
                                  depth: Int,
                                  reasoningLevel: Int,
                                  thinkText: String = "",
                                  personaPrompt: String? = nil) {
        // 批耗尽出口：calls 全量（v7.1.108-minis 起不再截断）。串行路径（混合/全副作用批）
        // 在这里按原序依次执行全部调用后回模型；纯只读批在下方 index==0 分流走分波并发。
        if index >= calls.count {
            // v3.4.1：工具气泡已在 handleDispatchResult 逐条实时上屏（对齐 OpenMinis 逐步展示），
            // 不再攒批到最后统一追加 —— 边做边说更接近"直播"。
            let merged = Array(Set(disclosed + newlyDisclosed))
            self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
            return
        }
        // v7.1.106：真并行分流——只读/独立工具批（count>1）走 DispatchGroup 并发执行，
        // 全部完成后按 tool_use 原序回填 tool 消息（API 要求 assistant toolCalls 与结果顺序配对）。
        // 并行安全判定见 isParallelSafeTool。
        // v7.1.108-minis：废除截断后全量批进这里——全安全批 → 分波并发（≤4 一波自动续，
        // 等价 OpenMinis in-flight 排队）；混合/全副作用批 → 落到下方串行路径（calls 全量
        // 原序依次执行，index+1 循环天然支持）。v7.1.109-fix(审计)：曾用 ordered 两阶段
        // "全部 writer 先跑"——违背模型原序意图（[grep,rm] 被执行为先删后查，grep 读到
        // 删除后状态）。Minis BatchToolOrder 只让 reader 等原序前序 writer，writer 不提前；
        // 本地保守策略 = 混合批严格原序串行，纯只读批才并发。
        if index == 0, calls.count > 1, Self.isParallelSafeTool(calls) {
            self.processToolCallsParallel(calls, toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: thinkText, personaPrompt: personaPrompt)
            return
        }
        let call = calls[index]
        let params = Self.parseArgs(call.arguments)
        // v3.5.6：工具参数 schema 预校验（机制级，治"缺参盲试"老毛病）——
        // 调工具前先用工具 schema 校验必填参数，缺了就不执行，注入纠正消息重跑一轮逼模型补齐。
        // 不再像以前那样直接执行→报"invalid params required"→靠提示词让模型自己改（常盲试好几次）。
        if let schema = ToolRegistry.shared.openAISchema(for: call.name),
           let fn = schema["function"] as? [String: Any],
           let ps = fn["parameters"] as? [String: Any],
           let required = ps["required"] as? [String] {
            let missing = required.filter { params[$0] == nil }
            if !missing.isEmpty && self.paramCorrectionCount < 2 {
                self.paramCorrectionCount += 1
                self.pendingParamCorrection = "The tool \(call.name) you want to call is missing required params: \(missing.joined(separator: ", ")). Fill them in and call again; don't keep retrying the same missing-param call in the same way."
                self.trailStep(.done(.note, "Missing tool params", detail: "\(call.name) missing: \(missing.joined(separator: ", "))", ok: false))
                // v7.1.101：缺参不再剥离回模型——v7.1.99 多条合批后，剥离会留下
                // "assistant 带 N 条 toolCalls 却只有部分 tool 结果"的非法序列（API 拒）。
                // 改为：缺参作为错误 tool 消息 append（toolCallId 匹配），继续执行下一条，
                // 全部执行完再回模型——模型看到错误消息自己补齐，序列始终完整合法。
                var next = toolMessages
                let body: [String: Any] = [
                    "ok": false,
                    "message": "Missing required params for \(call.name): \(missing.joined(separator: ", ")). Fill them in and call again."
                ]
                var failMsg = ChatMessage(role: "tool", content: Self.jsonString(body), isError: true,
                                          toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
                failMsg.toolArgs = Self.summarizeArgs(call.arguments)
                next.append(failMsg)
                self.appendToCurrent(failMsg)   // 对话可见（缺参步骤卡）
                self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                      config: config, tools: tools, disclosed: disclosed, depth: depth,
                                      reasoningLevel: reasoningLevel, thinkText: thinkText, personaPrompt: personaPrompt)
                return
            }
            self.paramCorrectionCount = 0
        }
        // v2.9.34：展示"正在执行工具 xxx…"
        self.runningTool = call.name
        // v3.5.10：工具启动即上屏一张 running 步骤卡（机制保证每步可见，不依赖模型解说）。
        // 先把真实工具名+命令+解说(若有)做成 isRunning=true 的占位卡立即上屏；
        // 结果回来后在 handleDispatchResult 原地更新成完成/出错卡（同一张，不新增第二条）。
        do {
            var runMsg = ChatMessage(role: "tool", content: "", toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            runMsg.toolArgs = Self.summarizeArgs(call.arguments)
            let nar = thinkText.trimmingCharacters(in: .whitespacesAndNewlines)
            runMsg.toolNarration = nar.isEmpty ? nil : thinkText
            runMsg.isRunning = true
            self.appendToCurrent(runMsg)
            self.pendingToolMsgIDs[call.id] = runMsg.id
        }
        // v3.3.4：记录工具执行耗时（UI 气泡显示，对齐 OpenMinis 步骤耗时样式）
        let toolStart = CFAbsoluteTimeGetCurrent()
        // v2.9.127：轨迹——单工具开始执行 (参数序列化展示）
        self.trailStep(.running(.tool, call.name, detail: Self.jsonString(params)))
        do {
            // v2.9.29：工具执行放后台线程，避免注入/文件操作等耗时调用阻塞主线程
            //  (授权恢复后Run injection导致一直转圈 + 聊天框/输入框无响应）。
            // dispatch 在后台执行，结果/授权/错误统一回主线程继续递归。
            DispatchQueue.global().async {
                let result: Result<[String: Any], Error>
                do { result = .success(try ToolRegistry.shared.dispatch(name: call.name, params: params)) }
                catch { result = .failure(error) }
                let toolDuration = CFAbsoluteTimeGetCurrent() - toolStart
                DispatchQueue.main.async {
                    self.runningTool = nil
                    self.handleDispatchResult(result, call: call, calls: calls, index: index,
                                              toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                              config: config, tools: tools,
                                              disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                              thinkText: thinkText, toolDuration: toolDuration, personaPrompt: personaPrompt)
                }
            }
        }
    }

    /// v7.1.106：真并行执行只读工具批（DispatchGroup）。
    /// 语义对齐串行路径但并发：schema 预校验（缺参生成错误消息、位置保留）→ 全部工具并发执行 →
    /// 主线程按原序回填 tool 消息 → 一次性回模型。UI：每工具一张 running 卡（多槽 pendingToolMsgIDs），
    /// 完成后原地更新。线程安全：dispatch 内部可变字典已由 ToolRegistry.stateLock 串行化，
    /// 本函数只收集结果（resultsLock 保护），UI 操作全部在主线程。
    private func processToolCallsParallel(_ calls: [ToolCall],
                                          toolMessages: [ChatMessage],
                                          newlyDisclosed: [String],
                                          config: ModelConfig,
                                          tools: [[String: Any]]?,
                                          disclosed: [String],
                                          depth: Int,
                                          reasoningLevel: Int,
                                          thinkText: String,
                                          personaPrompt: String?) {
        // 0) schema 预校验：缺必填参的 call 不执行，生成错误 tool 消息占位（顺序保留，v7.1.101 语义）
        var preErrors: [Int: ChatMessage] = [:]
        for (i, call) in calls.enumerated() {
            if let schema = ToolRegistry.shared.openAISchema(for: call.name),
               let fn = schema["function"] as? [String: Any],
               let ps = fn["parameters"] as? [String: Any],
               let required = ps["required"] as? [String] {
                let params = Self.parseArgs(call.arguments)
                let missing = required.filter { params[$0] == nil }
                if !missing.isEmpty && self.paramCorrectionCount < 2 {
                    self.paramCorrectionCount += 1
                    let body: [String: Any] = [
                        "ok": false,
                        "message": "Missing required params for \(call.name): \(missing.joined(separator: ", ")). Fill them in and call again."
                    ]
                    var failMsg = ChatMessage(role: "tool", content: Self.jsonString(body), isError: true,
                                              toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
                    failMsg.toolArgs = Self.summarizeArgs(call.arguments)
                    preErrors[i] = failMsg
                }
            }
        }
        // 1) 每工具上屏一张 running 卡（主线程；结果回来后在原地更新成完成/出错卡）
        self.runningTool = calls.first?.name
        let nar = thinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        for call in calls {
            var runMsg = ChatMessage(role: "tool", content: "", toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            runMsg.toolArgs = Self.summarizeArgs(call.arguments)
            runMsg.toolNarration = nar.isEmpty ? nil : thinkText
            runMsg.isRunning = true
            self.appendToCurrent(runMsg)
            self.pendingToolMsgIDs[call.id] = runMsg.id
        }
        self.trailStep(.running(.tool, "parallel batch", detail: calls.map { $0.name }.joined(separator: "、")))
        // 2) 分波并发执行（v7.1.108-minis：全执行不截断，≤4 个一波自动续，等价 OpenMinis
        // in-flight 排队；结果按 (index, result, duration) 收集，最终按原序回填）
        let allIndices = calls.indices.filter { preErrors[$0] == nil }
        let step = 4
        var collected: [(index: Int, result: Result<[String: Any], Error>, duration: Double)] = []
        let resultsLock = NSLock()

        func runWave(_ indices: [Int]) {
            guard !indices.isEmpty else {
                // 3) 全部完成 → 主线程按原序合并 tool 消息（与 assistant toolCalls 顺序一致），一次性回模型
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.runningTool = nil
                    var next = toolMessages
                    for (i, call) in calls.enumerated() {
                        if let pre = preErrors[i] {
                            // 缺参：错误消息直接进序列（toolCallId 匹配，序列始终完整合法），并更新对应 running 卡
                            next.append(pre)
                            self.resolvePendingTool(callId: call.id, content: pre.content, toolDuration: 0, isError: true, narration: nil)
                            self.trailStep(.done(.note, "Missing tool params",
                                                 detail: "\(call.name) missing required params", ok: false))
                            continue
                        }
                        let entry = collected.first { $0.index == i }
                        let r = entry?.result ?? .failure(MCPError.failed("parallel tool result missing for \(call.name)"))
                        next = self.applyParallelResult(r, call: call, toolMessages: next,
                                                        toolDuration: entry?.duration ?? 0, thinkText: thinkText)
                    }
                    let merged = Array(Set(disclosed + newlyDisclosed))
                    self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1,
                                 reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                }
                return
            }
            let wave = Array(indices.prefix(step))
            let rest = Array(indices.dropFirst(step))
            let group = DispatchGroup()
            for i in wave {
                let call = calls[i]
                group.enter()
                DispatchQueue.global().async {
                    let start = CFAbsoluteTimeGetCurrent()
                    let r: Result<[String: Any], Error>
                    do { r = .success(try ToolRegistry.shared.dispatch(name: call.name, params: Self.parseArgs(call.arguments))) }
                    catch { r = .failure(error) }
                    let duration = CFAbsoluteTimeGetCurrent() - start
                    resultsLock.lock()
                    collected.append((i, r, duration))
                    resultsLock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                runWave(rest)
            }
        }
        runWave(allIndices)
    }

    /// v7.1.106：并行批的单条工具结果处理（三分支与 handleDispatchResult 一致，但非递归——
    /// 只返回更新后的 toolMessages，由 processToolCallsParallel 主线程循环按原序调用）。
    @discardableResult
    private func applyParallelResult(_ result: Result<[String: Any], Error>,
                                     call: ToolCall,
                                     toolMessages: [ChatMessage],
                                     toolDuration: Double,
                                     thinkText: String) -> [ChatMessage] {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            let content: String
            // v7.2.3-fix25：同上——并行批路径同步提升到 48000
            if rawContent.count > 48000 {
                content = rawContent.prefix(48000) + "\n... [tool result truncated, total \(rawContent.count) chars. For full data, call the tool with params like limit/filter/query to narrow the range.]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            toolMsg.toolDuration = toolDuration
            toolMsg.toolNarration = thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : thinkText
            next.append(toolMsg)
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: false, narration: toolMsg.toolNarration)
            self.trailStep(.done(.result, call.name, detail: Self.trailSummary(rawContent), ok: true))
            return next
        case .failure(let err as MCPError):
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name, detail: Self.trailSummary(content), ok: false))
            return next
        case .failure(let err):
            var next = toolMessages
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with shell.exec. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            next.append(errMsg)
            self.resolvePendingTool(callId: call.id, content: Self.jsonString(errBody), toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name, detail: "❌ \(err.localizedDescription.prefix(200))", ok: false))
            return next
        }
    }

    /// v2.9.29：在主线程处理一次工具执行结果，然后继续递归调用链
    /// v2.9.31：去掉授权弹窗分支 (工具搜索即自动授权，无需暂停等待用户选择）。
    private func handleDispatchResult(_ result: Result<[String: Any], Error>,
                                      call: ToolCall, calls: [ToolCall], index: Int,
                                      toolMessages: [ChatMessage], newlyDisclosed: [String],
                                      config: ModelConfig, tools: [[String: Any]]?,
                                      disclosed: [String], depth: Int, reasoningLevel: Int,
                                      thinkText: String = "", toolDuration: Double = 0,
                                      personaPrompt: String? = nil) {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            // v2.9.49：工具结果截断 (>8000字符），防止单条工具结果 (如 browser.snapshot / injection.list）
            // 撑爆上下文导致后续请求巨慢。截断后加提示，模型可调用带分页/过滤参数的工具获取完整数据。
            let content: String
            // v7.2.3-fix25：同上——并行批路径同步提升到 48000
            if rawContent.count > 48000 {
                content = rawContent.prefix(48000) + "\n... [tool result truncated, total \(rawContent.count) chars. For full data, call the tool with params like limit/filter/query to narrow the range.]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.26：存参数摘要，UI 里用特殊颜色显示
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            // v3.3.4：耗时显示
            toolMsg.toolDuration = toolDuration
            // v3.5.8：存解说（模型写的"先解说后执行"正文）到工具消息——Minis 式工具卡当步骤标题
            toolMsg.toolNarration = thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : thinkText
            // v3.1.72：不再写 toolMsg.thinking——思考已在 assistant 消息的 thinking 字段显示一次，
            // 旧逻辑把同一文本又塞进 tool 消息导致"回复内容和思考内容一模一样" (用户实测反馈）
            next.append(toolMsg)
            // v3.5.10：原地更新"启动即上屏"的 running 步骤卡 → 完成卡（同一张，不再新增第二条）
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: false, narration: toolMsg.toolNarration)
            // v2.9.127：轨迹——工具执行OK (结果摘要 200 字符，完整结果在 tool 消息里）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(rawContent),
                                 ok: true))
            var nextDisclosed = newlyDisclosed
            // v3.1.66：tool_search 已删除，全量加载所有工具，无需披露机制。
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: nextDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        case .failure(let err as MCPError):
            // v2.9.125：failed也输出结构化 JSON (对齐 CLI 返回协议），AI 可直接解析分类与下一步
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.72：不再写 failMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            // v3.3.4：耗时显示
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: true, narration: nil)
            // v2.9.127：轨迹——工具执行failed (四分类错误摘要）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(Self.jsonString(failureBody)),
                                 ok: false))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        case .failure(let err):
            var next = toolMessages
            // v3.0.77：智能错误诊断——AI 看到错误就知道为什么failed、下一步该做什么
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with shell.exec or shell.exec. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.72：不再写 errMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            next.append(errMsg)
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(callId: call.id, content: Self.jsonString(errBody), toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name,
                                 detail: "❌ \(err.localizedDescription.prefix(200))",
                                 ok: false))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        }
    }

    /// v3.5.10：工具结果回来后，原地更新"启动即上屏"的 running 步骤卡（同一张卡变完成/出错）。
    /// v7.1.106：按 toolCallId 定位多槽（真并行批每工具一张卡），完成后移除该槽。
    private func resolvePendingTool(callId: String, content: String, toolDuration: Double, isError: Bool, narration: String?) {
        guard let mid = self.pendingToolMsgIDs[callId], let ci = self.activeConvIndex,
              let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == mid }) else {
            self.pendingToolMsgIDs.removeValue(forKey: callId)
            return
        }
        self.conversations[ci].messages[mi].content = content
        self.conversations[ci].messages[mi].toolDuration = toolDuration
        self.conversations[ci].messages[mi].isError = isError
        self.conversations[ci].messages[mi].isRunning = false
        if let n = narration, !n.isEmpty {
            self.conversations[ci].messages[mi].toolNarration = n
        }
        self.pendingToolMsgIDs.removeValue(forKey: callId)
    }

    /// v2.9.138：动态会话状态块——设备/App/工作区/当前会话，injected system 最前
    ///  (位于稳定块之后，最新状态放最后）。让 AI 始终感知当前环境，不靠猜。
    private static func dynamicStatePrompt() -> String {
        var device = "iPhone"
        var os = ""
        #if canImport(UIKit)
        device = UIDevice.current.model
        os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #endif
        var appVer = ""
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { appVer = v }
        var parts = ["[Current env] device: \(device)\(os.isEmpty ? "" : " · \(os)")"]
        if !appVer.isEmpty { parts.append("App: TrollAgent \(appVer)") }
        parts.append("Workspace: \(Workspace.root.path)")
        if let idx = ConversationStore.shared.selectedIndex,
           idx < ConversationStore.shared.conversations.count {
            parts.append("Current conversation: \(ConversationStore.shared.conversations[idx].title)")
        }
        // v3.1.5: 自动提取的关键信息 (App 名、bundle id、文件路径等）
        if let hint = AutoContextExtractor.shared.contextHint() {
            parts.append(hint)
        }
        return parts.joined(separator: " | ")
    }

    /// v4.3.71：返回 (messages, compactSource, droppedCount) —— compactSource 是被裁掉的旧消息原文，
    /// 供 OpenAIClient 在发送主请求前交给模型生成结构化摘要 (LLM Compaction)。
    /// v7.1.41：旧摘要（[Long-conversation summary 前缀）单独拎出——不参与裁剪、永远保留在结果最前；
    /// 压缩时旧摘要作为 compactSource 的第一条输入（增量演进：合并更新而非重复压缩）。
    /// v7.1.109-peers：分档预算（OpenMinis ContextPolicy）+ 校准系数（calibration ratio）。
    private func messagesForAPI(budget: Int) -> (messages: [ChatMessage], compactSource: [ChatMessage], droppedCount: Int) {
        var all = currentMessages.filter { !$0.isError }
        guard !all.isEmpty else { return ([], [], 0) }
        var priorSummary: ChatMessage?
        if let i = all.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[Long-conversation summary") }) {
            priorSummary = all.remove(at: i)
        }
        // v2.9.138：工具结果修剪 (Claude Code Precision Forgetting Layer 1）——
        // 非最近 3 条 tool 消息、内容 > 300 字符的旧工具结果替换为紧凑占位符。
        // 零 LLM 成本回收上下文：AI 需要细节时可重新调用该工具。
        // v3.1.68：阈值 300 → 2000 (AI 实测"377 字符不该被截"属实，小结果不再替换）；
        // 替换时保留原内容前 500 字符 ("截空看不到主体"根因——占位符不再整条顶替，
        // 且后续预算裁剪/sanitize 删占位符时头部仍在，AI 不至于完全失去线索）。
        let toolIdx = all.enumerated().filter { $0.element.isTool }.map { $0.offset }
        let keepTool = Set(toolIdx.suffix(3))
        for (i, m) in all.enumerated() where m.isTool && !keepTool.contains(i) && m.content.count > 2000 {
            var nm = m
            let toolName = m.toolName ?? "tool"
            let head = String(m.content.prefix(500))
            nm.content = "[Tool result trimmed: \(toolName), original \(m.content.count) chars, head below]\n\(head)\n…for the full result re-call the tool with limit=20000 or full=true"
            all[i] = nm
        }
        // v7.1.109-peers：分档压缩线（OpenMinis ContextPolicy 借鉴）+ 校准系数——
        // compactLine = 窗口按档位减余量（<32K=0 硬停档；32-128K 减 10K；≥128K 减 20K）；
        // 校准：估算总 token 乘最近真实 usage 的 ratio（clamp 0.5–2.5），防估算器偏差。
        let compactLine = ModelConfig.contextCompactLine(for: budget)
        let ratio = UsageRecorder.shared.lastRealRatio
        // 预算预留 20% 给 tools schema + 系统/开发者指令 + 请求开销（分档线已含余量，0.7→0.8）
        let theBudget = max(Int(Double(compactLine) * 0.8), 2000)
        // 估算总 token（校准后）；低于预算直接返回 (短会话，无需压缩）
        let total = Int(Double(all.reduce(0) { $0 + Self.estimateTokens($1) }) * ratio)
        if total <= theBudget {
            var short = all
            if let s = priorSummary { short.insert(s, at: 0) }   // 旧摘要永远保留
            return (short, [], 0)
        }
        // 长会话：从旧到新裁剪，但始终保留最后 N 条核心消息
        // v7.1.109-peers：极限压缩（对齐 OpenMinis 硬停思想但适配 Agent 长任务）——
        // 保底 6 条仍超预算时降为 2 条（只留最新提问），宁可裁到极限也不硬停卡住任务。
        var keepMin = 6
        var suffix = Array(all.suffix(keepMin))
        var prefix = Array(all.prefix(all.count - keepMin))
        var used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        if used > theBudget, all.count > 2 {
            keepMin = 2
            suffix = Array(all.suffix(keepMin))
            prefix = Array(all.prefix(all.count - keepMin))
            used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        }
        var kept: [ChatMessage] = []
        // 从旧到新累计到「预算 - suffix」内 (v2.9.16：suffix 计入预算，避免超发）
        for m in prefix {
            let t = Self.estimateTokens(m)
            if used + t > theBudget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示 (v2.9.88：本地生成话题摘要，而非简单丢弃 —— 不用额外请求，
        // 从被裁消息里提取用户提问/工具名作为"旧会话记忆"，AI 仍能感知上下文主题）
        let dropped = all.count - result.count
        // v4.3.71：被裁旧消息原文交给 LLM Compaction 生成结构化摘要（替换下方启发式摘要）
        // v7.1.41：旧摘要作为 compactSource 的第一条——增量演进（合并更新），而非重复压缩同一堆旧消息
        var compactSource: [ChatMessage] = []
        if dropped > 0 {
            compactSource = Array(all.prefix(dropped))
            if let s = priorSummary { compactSource.insert(s, at: 0) }
        }
        if dropped > 0 {
            let droppedMsgs = compactSource
            var topics: [String] = []
            var toolNames: Set<String> = []
            var idx = 0
            for m in droppedMsgs {
                idx += 1
                if m.role == "tool" { continue }
                if m.role == "system" { continue }   // 旧摘要不参与话题提取
                if let calls = m.toolCalls, !calls.isEmpty {
                    for c in calls {
                        if !c.name.isEmpty {
                            toolNames.insert(c.name)
                        }
                    }
                    if topics.count < 8, idx % 4 == 0 { topics.append("Tool calls") }
                    continue
                }
                if m.role == "user" || m.role == "assistant" {
                    let text = m.content.replacingOccurrences(of: "\n", with: " ")
                    if !text.isEmpty, topics.count < 8 {
                        topics.append(String(text.prefix(24)))
                    }
                }
            }
            var summaryParts: [String] = ["earliest \(dropped) history messages omitted"]
            if !topics.isEmpty {
                summaryParts.append("Topics: " + topics.prefix(6).joined(separator: " / "))
            }
            if !toolNames.isEmpty {
                summaryParts.append("Tools involved: " + toolNames.sorted().prefix(10).joined(separator: ", "))
            }
            summaryParts.append("For old details, just ask — AI will re-run the relevant tools to get them.")
            // v7.1.41：已有旧摘要时不再插启发式占位（send 会直接增量更新旧摘要）
            if priorSummary == nil {
                let hint = ChatMessage(role: "system", content: "[System] " + summaryParts.joined(separator: ". "))
                result.insert(hint, at: 0)
            }
        }
        // v7.1.41：旧摘要永远保留在结果最前（增量演进的基底）
        if let s = priorSummary { result.insert(s, at: 0) }
        return (result, compactSource, dropped)
    }

    // MARK: - v7.1.41 LLM Compaction 持久化（对齐 Claude Code /compact：摘要替换进会话历史，增量演进）

    /// 压缩确认后应用——删除被裁消息、替换/插入摘要 system 消息（破坏性替换，写回并持久化）
    func applyCompaction(summary: String, droppedCount: Int) {
        guard droppedCount > 0, let idx = activeConvIndex ?? selectedIndex else { return }
        var conv = conversations[idx]
        // 删除头部 droppedCount 条非 error 消息（isError 消息保留不删——与 messagesForAPI 的过滤口径一致）
        var remaining = droppedCount
        var i = 0
        while i < conv.messages.count && remaining > 0 {
            if !conv.messages[i].isError {
                conv.messages.remove(at: i)
                remaining -= 1
            } else {
                i += 1
            }
        }
        let newSummary = "[Long-conversation summary, model-generated]\n" + summary
        if let si = conv.messages.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[Long-conversation summary") }) {
            conv.messages[si] = ChatMessage(role: "system", content: newSummary)   // 增量：更新旧摘要
        } else {
            conv.messages.insert(ChatMessage(role: "system", content: newSummary), at: 0)
        }
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
        // v7.1.109-peers：OpenMinis 压缩后重测借鉴——摘要写回后重算（用校准系数），
        // 仍超窗则提示（防"压缩白做"导致的连环压缩误读）
        if let cfg = ConversationStore.currentModelConfig() {
            let win = cfg.effectiveContextTokens
            let ratio = UsageRecorder.shared.lastRealRatio
            let after = Int(Double(conv.messages.reduce(0) { $0 + Self.estimateTokens($1) }) * ratio)
            if win > 0, after > win {
                self.statusText = "⚠️ 压缩后仍超出窗口(≈\(after)/\(win))——建议新建会话"
            }
        }
    }

    /// v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——只生成摘要并持久化，不发主请求
    func compactNow(completion: @escaping (Bool, String) -> Void) {
        guard let config = ConversationStore.currentModelConfig() else {
            completion(false, "未找到模型配置")
            return
        }
        let prepared = messagesForAPI(budget: config.effectiveContextTokens)
        guard !prepared.compactSource.isEmpty else {
            completion(false, "会话不长，无需压缩")
            return
        }
        let client = OpenAIClient(config)
        client.summarize(prepared.compactSource) { [weak self] summary in
            DispatchQueue.main.async {
                guard let self else { return }
                if let s = summary, !s.isEmpty {
                    self.applyCompaction(summary: s, droppedCount: prepared.droppedCount)
                    completion(true, "已压缩 \(prepared.droppedCount) 条历史消息")
                } else {
                    completion(false, "摘要生成失败（网络或模型问题），未压缩")
                }
            }
        }
    }

    /// 当前使用的模型配置（最近使用优先，兜底第一个）
    private static func currentModelConfig() -> ModelConfig? {
        let store = ModelStore.shared
        if let id = store.lastUsedConfigId, let c = store.configs.first(where: { $0.id.uuidString == id }) {
            return c
        }
        return store.configs.first
    }

    /// 粗估 token：中文/日文等约 1 字≈1.5 token；ASCII 约 4 字符≈1 token；图片按固定值计
    private static func estimateTokens(_ m: ChatMessage) -> Int {
        var t = 0
        let content = m.content
        var cjk = 0
        for ch in content.unicodeScalars {
            if (ch.value >= 0x4E00 && ch.value <= 0x9FFF) || (ch.value >= 0x3040 && ch.value <= 0x30FF) || (ch.value >= 0xAC00 && ch.value <= 0xD7AF) {
                cjk += 1
            }
        }
        let ascii = content.count - cjk
        // v2.9.87：CJK 1.5→2.0 保守估算 (中文实际约 1.5~2 token/字），
        // 低估会让请求体超预算 → 中转处理慢。
        t += Int(Double(cjk) * 2.0) + ascii / 3
        t += (m.imageDataURLs?.count ?? 0) * 600   // 每张图约 600 token (低分辨率近似）
        return max(t, 8)
    }

    /// 保证 assistant tool_calls 与其 tool 结果成对存在；删掉孤立的 tool 消息
    private static func sanitizeToolSequence(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pendingToolCalls = false
        for m in msgs {
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                pendingToolCalls = true
                out.append(m)
            } else if m.role == "tool" {
                // 只有前面有未配对的 assistant tool_calls 才保留 tool 结果
                if pendingToolCalls {
                    out.append(m)
                }
                // 忽略孤立的 tool 消息
            } else {
                pendingToolCalls = false
                out.append(m)
            }
        }
        return out
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - v7.1.99 工具合批分类（只读可合批 / 副作用一次一条）

    /// v7.1.103：shell 只读命令白名单（首词）
    private static let readOnlyShellCmds: Set<String> = [
        "cat", "ls", "find", "grep", "ps", "df", "free", "uname", "echo", "pwd", "which",
        "uptime", "netstat", "ifconfig", "head", "tail", "wc", "du", "date", "env", "printenv",
        "curl", "ping", "mount", "id", "whoami", "sysctl", "defaults", "plutil", "strings",
        "file", "stat", "readlink"
        // v7.1.103：kill 移出白名单——真实副作用(杀进程)，合批语义不成立，应一次一条
    ]

    /// v7.1.103：curl 写文件排除（-o/-O/--output/--download → 副作用，不可合批）
    private static func curlWritesFile(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        return c.contains("-o ") || c.contains("-o\t") || c.contains("--output")
            || c.contains("-o\"") || c.contains(" -o") || c.contains("-O ") || c.contains("--download")
    }

    /// 一批 toolCalls 是否全部可合批（依次执行，不回模型重生成）
    static func isParallelSafeTool(_ calls: [ToolCall]) -> Bool {
        calls.allSatisfy { isParallelSafeTool($0) }
    }

    /// 单个工具是否可合批：只读/查询类（无副作用、互相独立）→ true；
    /// 副作用/写类/未知（inject、app、control、artifact、shell 写命令等）→ false（保持一次一条）
    static func isParallelSafeTool(_ call: ToolCall) -> Bool {
        let name = call.name
        // 纯只读/验证大工具（内部只读 ToolRegistry/Bundle，无共享可变状态）
        // v7.2.1：扩充白名单——web.search/web.fetch/knowledge.search/device.* 等
        // 确定性只读工具加入可合批（此前模型按提示词批量发也会被强制一条条跑，
        // 用户实测"AI 还是一条或两条发命令"）。browser 共享 WebView 仍串行。
        let readOnlyTools: Set<String> = [
            "system_overview", "tools_audit", "verify",
            "web_search", "web_fetch", "knowledge_search",
            "device_info", "device_probe"
        ]
        if readOnlyTools.contains(name) { return true }
        // shell_exec：仅【单命令】纯只读命令可并行（ls/cat/grep/ps/find/stat...）。
        // v7.1.107：复合命令（; && || | > >> < 等）无法静态确认只读——例如
        // `ls && rm x`、`cat a | tee out` 首词只读但实际有副作用，并行会互相踩，保守不并行。
        if name == "shell_exec" {
            let cmd = (parseArgs(call.arguments)["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.contains(";") || cmd.contains("&&") || cmd.contains("||")
                || cmd.contains("|") || cmd.contains(">") || cmd.contains("<") {
                return false
            }
            let first = cmd.components(separatedBy: .whitespacesAndNewlines).first(where: { !$0.isEmpty }) ?? ""
            let base = first.hasPrefix("-") ? "" : first
            // v7.1.103：env VAR=1 cmd 包装 → 递归判断真实命令（裸 env 列环境变量才只读）
            if base == "env" {
                let after = cmd.components(separatedBy: .whitespacesAndNewlines).dropFirst()
                let realFirst = after.first(where: { !$0.isEmpty && !$0.contains("=") }) ?? ""
                if realFirst.isEmpty { return true }   // 裸 env
                return isShellCmdReadOnly(realFirst, cmd: cmd)
            }
            return isShellCmdReadOnly(base, cmd: cmd)
        }
        // v7.1.107：browser 只读子命令（text/snapshot/status...）共享同一 WebView——
        // 并发 evaluateJavaScript 有导航/状态竞态，保守不并行（一次一条，防闪退优先）
        return false
    }

    /// v7.1.103：shell 首词 + 写特征统一判定（env 包装/curl 写文件共用）
    private static func isShellCmdReadOnly(_ base: String, cmd: String) -> Bool {
        if readOnlyShellCmds.contains(base) {
            // curl 写文件（-o/-O/--output）→ 副作用，不可合批
            if base == "curl" && curlWritesFile(cmd) { return false }
            return true
        }
        // v7.2.3-audit3：sed 无就地写（-i/--in-place）→ 纯只读可合批
        // `sed -n '1,400p' file` / `sed -e 's/x/y/'` 无重定向都只读；-i 就地写拦截。
        // 复合符(;&&|||><)已在前置检查拦截，此处只需防 -i。
        if base == "sed" {
            if cmd.contains("-i") || cmd.contains("--in-place") { return false }
            return true
        }
        // v7.1.102：解释器命令（python3/node/perl/ruby/php/bash -c...）——
        // 合批后依次执行（非并行，副作用有序、依赖可见、错误可恢复），
        // 用脚本内容黑名单兜底：含写/危险 API 特征 → 一次一条，纯只读脚本 → 可合批。
        // v7.1.103：sed/awk 移出——sed -i 就地写/awk 重定向无法静态区分，保守一次一条
        let interpreters: Set<String> = [
            "python3", "python", "node", "perl", "ruby", "php", "bash", "sh", "zsh", "lua", "jq"
        ]
        if interpreters.contains(base) {
            return !scriptHasWriteRisk(cmd)
        }
        return false
    }

    /// v7.1.102：解释器命令脚本内容黑名单——含写/危险特征视为副作用（一次一条），
    /// 纯只读脚本才可合批。保守原则：宁可多几轮往返，不放过写操作。
    static func scriptHasWriteRisk(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let dangerous: [String] = [
            "open(", "open ", "write", "write_text", "writefile", "remove", "unlink", "rmdir",
            "os.system", "system(", "popen", "subprocess", "exec(", "eval(", "spawn",
            "makedirs", "chmod", "chown", "shutil", "truncate", "replace(", "save", "dump",
            "append", "rm ", "rm -", "mv ", "cp ", "mkdir", "touch ", "touch(", "tee ",
            ">>", "> ", "| tee", "curl -o", "wget -o", "install", "apt", "apk add",
            "pip install", "npm i ", "npm install", "delete", "drop ", "insert into",
            "update ", "alter "
        ]
        return dangerous.contains { c.contains($0) }
    }

    // v2.9.171：工具结果序列化去掉 prettyPrinted → 紧凑 JSON (无缩进空格）。
    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func sortAndSave() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    private func title(from text: String) -> String {
        // v2.9.293：剔除附件描述，避免标题变成 "[📎 文件：全局加速+...2.deb]已保存到 /var/..."
        // 用正则兼容 [📎文件：/ [📎 文件：/ 中文冒号/英文冒号 所有变体
        var clean = text
        func stripTag(_ pattern: String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = clean as NSString
            let range = NSRange(location: 0, length: ns.length)
            clean = rx.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        stripTag("\\[📎\\s*文件\\s*[：:][^\\]]*\\]")
        stripTag("\\[📱\\s*应用\\s*[：:][^\\]]*\\]")
        // 去掉 "已保存到 <路径>，可用..." 路径描述
        if let r = clean.range(of: "已保存到 ") {
            clean = String(clean[..<r.lowerBound])
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "📎 File" }
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(line.prefix(30))
    }

    // v4.3.66：会话存储从 UserDefaults 全量迁移到独立文件（对齐微信/WCDB：大对象不进
    // UserDefaults 同步 IO；文件原子写 + 备份轮换，编码/写盘放后台串行队列，不阻塞主线程）
    private var storeDir: String {
        let p = NSHomeDirectory().appending("/Documents/Workspace/store")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private var storeFile: String { storeDir.appending("/conversations.json") }
    private let saveQueue = DispatchQueue(label: "trollmcp2.conversations.save", qos: .utility)

    private func save() {
        let snapshot = conversations
        let dir = storeDir
        let path = storeFile
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let fm = FileManager.default
            let bak1 = dir.appending("/conversations.bak.1.json")
            let bak2 = dir.appending("/conversations.bak.2.json")
            // 备份轮换：旧 bak1 → bak2，旧主文件 → bak1
            if fm.fileExists(atPath: bak1) {
                try? fm.removeItem(atPath: bak2)
                try? fm.moveItem(atPath: bak1, toPath: bak2)
            }
            if fm.fileExists(atPath: path) {
                try? fm.moveItem(atPath: path, toPath: bak1)
            }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func decodeFile(_ path: String) -> [ChatConversation]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode([ChatConversation].self, from: data)
    }

    private func applyLoaded(_ decoded: [ChatConversation]) {
        var convs = decoded.sorted { $0.updatedAt > $1.updatedAt }
        // v6.1.5-14bp3：App 被系统终止（闪退）时工具调用卡"执行中…"且永不返回——
        // 重启加载后把残留 running 工具消息统一标记为中断失败，避免 UI 永远挂着无结果。
        // v7.2.1：恢复文案通用化（不再特指 git/vim/curl 历史崩溃），并记录崩溃时正在跑的工具名
        var cleaned = false
        for ci in convs.indices {
            for mi in convs[ci].messages.indices where convs[ci].messages[mi].isRunning {
                convs[ci].messages[mi].isRunning = false
                convs[ci].messages[mi].isError = true
                let c = convs[ci].messages[mi].content
                if c.isEmpty || c == "…" {
                    let toolName = convs[ci].messages[mi].toolName ?? ""
                    convs[ci].messages[mi].content = "⚠️ Execution interrupted: the app was terminated by the system (crash) while tool \(toolName.isEmpty ? "was running" : "「\(toolName)」was running"). Please resend the command."
                }
                cleaned = true
            }
            // v7.2.1：崩溃残留非法序列——assistant 带 toolCalls 但对应 tool 结果缺失
            // （崩溃发生在 tool 卡异步写盘前，盘上只剩 assistant toolCalls）。
            // 后续请求把 [assistant(toolCalls), user] 直接发给 API → toolCalls 无配对
            // tool 结果 = 非法序列 → 中转 400 或挂起 → 表现"无论发什么 AI 都不回复"。
            // 补一条中断伪 tool 结果，恢复序列合法（对齐 OpenAI tool_calls 配对约束）。
            var seqFixed = false
            for mi in convs[ci].messages.indices {
                guard convs[ci].messages[mi].role == "assistant",
                      let tcs = convs[ci].messages[mi].toolCalls, !tcs.isEmpty else { continue }
                for tc in tcs {
                    let hasResult = convs[ci].messages.contains { $0.role == "tool" && $0.toolCallId == tc.id }
                    if !hasResult {
                        var im = ChatMessage(role: "tool",
                                             content: "⚠️ Tool \(tc.name) execution was interrupted by an app crash; result unavailable. You may retry this tool call.",
                                             isError: true, toolCallId: tc.id, toolName: tc.name)
                        convs[ci].messages.insert(im, at: mi + 1)
                        seqFixed = true
                        break
                    }
                }
                if seqFixed { break }
            }
            if seqFixed { cleaned = true }
        }
        conversations = convs
        selectedId = conversations.first?.id
        if cleaned { save() }   // 持久化清理结果，避免下次启动重复标记
    }

    private func load() {
        let fm = FileManager.default
        // 1. 文件主数据
        if fm.fileExists(atPath: storeFile), let d = decodeFile(storeFile), !d.isEmpty {
            applyLoaded(d); return
        }
        // 2. 文件备份
        for i in 1...2 {
            let bak = storeDir.appending("/conversations.bak.\(i).json")
            if fm.fileExists(atPath: bak), let d = decodeFile(bak), !d.isEmpty {
                applyLoaded(d); save(); return
            }
        }
        // 3. 一次性迁移：旧 UserDefaults 主数据 + 其备份（迁移后写入文件，旧数据保留不删）
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatConversation].self, from: data),
           !decoded.isEmpty {
            applyLoaded(decoded); save(); return
        }
        for i in 1...2 {
            if let bak = UserDefaults.standard.data(forKey: key + ".bak.\(i)"),
               let decoded = try? JSONDecoder().decode([ChatConversation].self, from: bak),
               !decoded.isEmpty {
                applyLoaded(decoded); save(); return
            }
        }

        // 从旧版单一会话记录迁移
        if let oldData = UserDefaults.standard.data(forKey: "trollmcp2.transcript"),
           let messages = try? JSONDecoder().decode([ChatMessage].self, from: oldData),
           !messages.isEmpty {
            let first = messages.first!
            let title = String(first.content.prefix(30))
            let conv = ChatConversation(
                title: title,
                createdAt: first.timestamp,
                updatedAt: messages.last?.timestamp ?? Date(),
                messages: messages
            )
            conversations = [conv]
            selectedId = conv.id
            save()
            UserDefaults.standard.removeObject(forKey: "trollmcp2.transcript")
        } else {
            newConversation()
        }
    }
}

// MARK: - 熔断器 (v2.9.107，对齐 cc-switch circuit_breaker 三态机）

enum CircuitState: String {
    case closed = "closed", open = "open", halfOpen = "half_open"
    var label: String {
        switch self {
        case .closed: return "Normal"
        case .open: return "Open (tripped)"
        case .halfOpen: return "Probing"
        }
    }
}

final class CircuitBreaker {
    private let lock = NSLock()
    private var state: CircuitState = .closed
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var totalRequests = 0
    private var failedRequests = 0
    private var lastOpenedAt: Date?
    private var halfOpenRequests = 0

    var failureThreshold = 4          // 连续failed阈值 → Open
    var successThreshold = 2          // HalfOpen OK次数 → Closed
    var timeoutSeconds: TimeInterval = 60  // Open 后多久尝试 HalfOpen
    var errorRateThreshold = 0.6      // 错误率阈值 → Open
    var minRequests = 10              // 计算错误率前最少请求数

    let name: String
    init(name: String) { self.name = name }

    var stateInfo: (state: CircuitState, failures: Int, total: Int, failRate: Double) {
        lock.lock(); defer { lock.unlock() }
        let rate = totalRequests > 0 ? Double(failedRequests) / Double(totalRequests) : 0
        return (state, consecutiveFailures, totalRequests, rate)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        totalRequests = 0
        failedRequests = 0
        halfOpenRequests = 0
        lastOpenedAt = nil
    }

    /// 路由可用性判断 (不占 HalfOpen 探测名额）
    func isAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
                return true
            }
            return false
        }
    }

    /// 请求前调用：是否放行 (HalfOpen 限流 1 个探测请求）
    func allowRequest() -> (allowed: Bool, usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            return (true, false)
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
            } else {
                return (false, false)
            }
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        case .halfOpen:
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        }
    }

    func recordSuccess(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures = 0
        totalRequests += 1
        if state == .halfOpen {
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= successThreshold {
                state = .closed
                consecutiveSuccesses = 0
                totalRequests = 0
                failedRequests = 0
                halfOpenRequests = 0
            }
        }
    }

    func recordFailure(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures += 1
        consecutiveSuccesses = 0
        totalRequests += 1
        failedRequests += 1
        switch state {
        case .halfOpen:
            state = .open
            lastOpenedAt = Date()
            consecutiveFailures = 0
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open
                lastOpenedAt = Date()
                consecutiveFailures = 0
            } else if totalRequests >= minRequests {
                let rate = Double(failedRequests) / Double(totalRequests)
                if rate >= errorRateThreshold {
                    state = .open
                    lastOpenedAt = Date()
                    consecutiveFailures = 0
                }
            }
        case .open:
            break
        }
    }
}

// MARK: - v2.9.126 深链导入暂存 (对齐 cc-switch DeepLinkImportDialog）

/// AppDelegate 收到 trollagent://import?... 后暂存配置，发通知；SwiftUI 层弹确认页。
/// 确认才写入 ModelStore (防误导入），取消即丢弃。
final class PendingImport: ObservableObject {
    static let shared = PendingImport()
    static let didStageNotification = Notification.Name("trollagent.pendingImport.staged")

    @Published var staged: ModelConfig?

    private init() {}

    func stage(_ config: ModelConfig) {
        staged = config
        NotificationCenter.default.post(name: Self.didStageNotification, object: config)
    }

    func confirm() {
        guard let c = staged else { return }
        let ok = ModelStore.shared.importFromDeepLink(c)
        staged = nil
        // 通知 UI 显示结果 (导入OK/已存在重复）
        NotificationCenter.default.post(name: Self.didStageNotification,
                                        object: nil,
                                        userInfo: ["result": ok ? "imported" : "duplicate"])
    }

    func cancel() {
        staged = nil
    }
}
