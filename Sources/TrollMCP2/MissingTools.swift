import Foundation
import UIKit
import EventKit
import UserNotifications

// MARK: - 日历：创建事件

final class CalendarCreateEventTool: MCPTool {
    let definition = ToolDefinition(name: "calendar.create_event",
        summary: "Create a new calendar event (meeting/appointment). Use for: schedule a meeting, add event to iPhone Calendar. Don't use for: list upcoming events (use calendar.list), create reminder (use reminder.create). Example: user says 'add a meeting at 3pm tomorrow' → create calendar event.",
        parameters: ["title": "Event title (e.g. 'Team Meeting')", "start": "Start time (ISO8601 format)", "end": "End time (optional, default +1 hour)", "notes": "Optional notes for the event"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        guard let startStr = params["start"] as? String,
              let start = ISO8601DateFormatter().date(from: startStr) else {
            throw MCPError.invalidParams("start must be ISO8601")
        }
        let end = (params["end"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: start)!

        var result: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let store = EKEventStore()
            store.requestAccess(to: .event) { granted, err in
                defer { sem.signal() }
                guard granted else {
                    result = ["created": false, "error": "calendar not authorized: \(err?.localizedDescription ?? "")"]
                    return
                }
                let ev = EKEvent(eventStore: store)
                ev.title = title
                ev.startDate = start
                ev.endDate = end
                ev.notes = params["notes"] as? String
                do {
                    try store.save(ev, span: .thisEvent, commit: true)
                    result = ["created": true, "title": title, "start": startStr,
                              "eventIdentifier": ev.eventIdentifier ?? ""]
                } catch {
                    result = ["created": false, "error": error.localizedDescription]
                }
            }
        }
        sem.wait()
        AuditLog.shared.log("calendar.create_event", detail: title)
        return result
    }
}


final class ReminderScheduleRecurringTool: MCPTool {
    let definition = ToolDefinition(name: "reminder.schedule_recurring",
        summary: "Schedule a repeating reminder. Use for: periodic alerts (hourly/daily/etc). Don't use for: one-time reminder (use reminder.schedule), create calendar event (use calendar.create_event). Example: user says 'remind me to drink water every hour' → recurring reminder.",
        parameters: ["title": "Reminder title", "body": "Reminder content", "interval_seconds": "Repeat interval in seconds"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let title = params["title"] as? String else { throw MCPError.invalidParams("title required") }
        let interval = max(params["interval_seconds"] as? Int ?? 3600, 1)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = params["body"] as? String ?? ""
        content.sound = .default
        let id = UUID().uuidString
        let req = UNNotificationRequest(identifier: id,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(interval), repeats: true))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        AuditLog.shared.log("reminder.schedule_recurring", detail: "\(title) every \(interval)s")
        return ["scheduled": true, "id": id, "interval_seconds": interval]
    }
}

final class DeviceSnapshotTool: MCPTool {
    let definition = ToolDefinition(name: "device.snapshot", summary: "Quick device status snapshot: battery level, memory usage, disk space, iOS version. Use for: check device health, see how much free space, monitor performance. Don't use for: detailed device info (use device.info), spoof device info (use device.fake). Example: user says 'how much memory is left' → device snapshot.")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let fm = FileManager.default
        var freeBytes: Int64 = 0
        if let url = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            freeBytes = Int64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return [
            "model": UIDevice.current.model,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "batteryLevel": battery >= 0 ? String(format: "%.0f%%", battery * 100) : "unknown",
            "freeStorageBytes": freeBytes,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}

final class WebSearchTool: MCPTool {
    let definition = ToolDefinition(name: "web.search",
        summary: "Search the web with multi-engine fallback (Bing → DuckDuckGo → Baidu) and multi-query support. Use for: find information online, look up facts, search tutorials/docs. Don't use for: open a specific website (use browser.open), search saved knowledge (use knowledge.search). queries:[...] runs split keywords in parallel, auto-dedupes and merges; sort=true ranks official/media sources first; save=true auto-saves to the knowledge base.Example: user says 'when was iPhone 16 released' → search web.",
        parameters: ["query": "Search keywords (e.g. 'iOS 17 jailbreak guide')",
                     "queries": "Array of search terms to run in parallel & merge (optional, preferred for complex topics)",
                     "limit": "Max results per query (default 8)",
                     "sort": "true=official/third-party sources first (default false, keep engine relevance)",
                     "save": "true=auto-save top results to knowledge base (default false)"],
        verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // v4.3.65：多 query 并行 + 多引擎回退（Bing→DuckDuckGo→Baidu）+ 去重/来源分级 + 可选沉淀知识库
        let queries: [String]
        if let qs = params["queries"] as? [String], !qs.isEmpty {
            queries = qs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let qstr = params["queries"] as? String, !qstr.isEmpty {
            // fix3cl6: 容错——第三方客户端(Botcf 等)可能把数组序列化成字符串("[\"a\",\"b\"]" 或 "a,b")，
            // as? [String] 失败会误报 "query or queries required"。手动解析字符串数组形态。
            var parts: [String] = []
            let t = qstr.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                let inner = String(t.dropFirst().dropLast())
                for it in inner.components(separatedBy: ",") {
                    let s = it.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: "'", with: "")
                    if !s.isEmpty { parts.append(s) }
                }
            } else {
                parts = t.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            queries = parts
        } else if let q = params["query"] as? String, !q.isEmpty {
            queries = [q.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            throw MCPError.invalidParams("query or queries required")
        }
        let limit = min(max(params["limit"] as? Int ?? 8, 1), 30)
        let sortBySource = params["sort"] as? Bool ?? false   // true=官方/媒体优先
        let save = params["save"] as? Bool ?? false           // true=结果自动沉淀知识库

        var all: [[String: String]] = []
        var engineCounts: [String: Int] = [:]
        for q in queries {
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            var res = fetchBing(query: enc, limit: limit)
            if res.isEmpty {
                res = fetchDuckDuckGo(query: enc, limit: limit)
                engineCounts["DuckDuckGo", default: 0] += res.count
            } else {
                engineCounts["Bing", default: 0] += res.count
            }
            if res.isEmpty {
                res = fetchBaidu(query: enc, limit: limit)
                engineCounts["Baidu", default: 0] += res.count
            }
            all += res
        }

        // 去重（按 URL 保留首个）+ 截断摘要（防 token 爆炸）
        var seen = Set<String>()
        var deduped: [[String: String]] = []
        for r in all {
            if let u = r["url"], seen.insert(u).inserted {
                deduped.append(r)
            }
        }
        for i in deduped.indices {
            if var sn = deduped[i]["snippet"], sn.count > 300 {
                sn = String(sn.prefix(300)) + "…"
                deduped[i]["snippet"] = sn
            }
        }
        // 来源分级排序（可选，默认保持引擎相关性顺序）
        if sortBySource {
            deduped.sort { Self.sourceRank($0["source_type"] ?? "") < Self.sourceRank($1["source_type"] ?? "") }
        }
        let results = Array(deduped.prefix(limit * queries.count))
        let officialCount = results.filter { $0["source_type"] == "official" }.count
        let engines = engineCounts.filter { $0.value > 0 }.keys.sorted()

        var out: [String: Any] = [
            "query": queries.count == 1 ? queries[0] : queries,
            "engine": engines.isEmpty ? "none" : engines.joined(separator: "+"),
            "count": results.count, "results": results,
            "official_count": officialCount,
            "source_note": Self.sourceNote,
        ]
        if save && !results.isEmpty {
            out["saved_to_knowledge"] = saveToKnowledge(queries: queries, results: results)
        }
        AuditLog.shared.log("web.search", detail: "\(queries.joined(separator: "|")) → \(engines.joined(separator: "+")) \(results.count) 条")
        return out
    }

    private static func sourceRank(_ t: String) -> Int {
        t == "official" ? 0 : (t == "third_party" ? 1 : 2)
    }

    /// v4.3.65：结果自动沉淀到知识库（供后续 knowledge.search 免搜复用）
    private func saveToKnowledge(queries: [String], results: [[String: String]]) -> String {
        KnowledgeStore.shared.ensure()
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let safeQ = String(queries.joined(separator: "_").replacingOccurrences(of: " ", with: "-").prefix(30))
        let name = "web-\(date)-\(safeQ).md"
        var md = "# Search results: \(queries.joined(separator: " | "))\n\n"
        for (i, r) in results.prefix(10).enumerated() {
            md += "\(i + 1). [\(r["title"] ?? "")](\(r["url"] ?? ""))\n   \(r["snippet"] ?? "")\n"
        }
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name)
        try? md.write(to: file, atomically: true, encoding: .utf8)
        return name
    }

    /// v4.3.26：来源分级说明——AI 看到 unknown 小站应交叉验证，不直接采信
    private static let sourceNote = "source_type grading: official=official/authoritative sites (prefer); third_party=media/known communities/wikis (referenc参考，但与官方文档冲突时以官方为准）；unknown=未知名小站/个人页（可信度低，勿直接采信，需交叉验证）。"

    /// v4.3.26：按域名分级搜索结果来源——official / third_party / unknown
    private static func sourceType(for urlString: String) -> String {
        let host = (URL(string: urlString)?.host ?? "").lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare.isEmpty { return "unknown" }
        // 官方权威域名：政府/教育/官方文档子域
        if bare.hasSuffix(".gov") || bare.hasSuffix(".gov.cn") || bare.hasSuffix(".edu") ||
           bare.hasSuffix(".edu.cn") || bare.hasSuffix(".ac.cn") || bare.hasSuffix(".mil") { return "official" }
        if bare.contains("official") { return "official" }
        // 官方产品/公司域名
        let officialDomains: Set<String> = [
            "apple.com", "google.com", "microsoft.com", "openai.com", "anthropic.com", "meta.com",
            "amazon.com", "tencent.com", "qq.com", "alibaba.com", "taobao.com", "tmall.com",
            "bytedance.com", "douyin.com", "xiaomi.com", "huawei.com", "baidu.com", "aliyun.com",
            "jd.com", "weibo.com", "github.com", "gitlab.com", "gitee.com", "linux.org", "python.org",
            "developer.apple.com", "learn.microsoft.com", "cloud.google.com", "aws.amazon.com",
            "x.com", "twitter.com", "youtube.com", "netflix.com", "spotify.com", "telegram.org",
            "whatsapp.com", "paypal.com", "stripe.com", "binance.com", "coinbase.com",
            "nytimes.com", "wsj.com", "reuters.com", "bloomberg.com", "cnn.com", "bbc.com",
            "ft.com", "theguardian.com", "economist.com", "forbes.com", "time.com", "cctv.com",
            "people.com.cn", "xinhuanet.com", "gov.cn", "china.com.cn", "cas.cn", "cuhk.edu.hk"
        ]
        if officialDomains.contains(bare) { return "official" }
        // fix3cl8: 子域归属——dnf.qq.com / aid.qq.com 等官方产品子域应归属 qq.com(official)。
        // 旧实现精确匹配白名单，子域全部落 unknown → 官网标 unknown、official_count=0、sort 失效。
        for d in officialDomains where bare.hasSuffix("." + d) { return "official" }
        // 媒体 / 知名社区 / 百科（可参考但非官方）
        let thirdPartyDomains: Set<String> = [
            "wikipedia.org", "zhihu.com", "zhuanlan.zhihu.com", "xiaohongshu.com", "xhs.cn",
            "bilibili.com", "douban.com", "quora.com", "reddit.com", "stackoverflow.com",
            "stackexchange.com", "medium.com", "csdn.net", "cnblogs.com", "juejin.cn",
            "segmentfault.com", "36kr.com", "ithome.com", "sina.com.cn", "sohu.com", "163.com",
            "toutiao.com", "sspai.com", "v2ex.com", "huxiu.com", "pingwest.com", "leiphone.com",
            "ifanr.com", "engadget.com", "theverge.com", "techcrunch.com", "wired.com",
            "arstechnica.com", "news.ycombinator.com", "baike.baidu.com", "zh.wikipedia.org",
            "wikiwand.com", "gitbooks.io", "readthedocs.io", "mdn.mozilla.org", "freecodecamp.org",
            "geekpark.net", "jiqizhixin.com", "qbitai.com", "wanqu.co", "solidot.org", "cnbeta.com",
            "colg.cn", "bbs.colg.cn", "ali213.net", "gamersky.com", "3dmgame.com", "17173.com", "duowan.com"
        ]
        if thirdPartyDomains.contains(bare) { return "third_party" }
        for d in thirdPartyDomains where bare.hasSuffix("." + d) { return "third_party" }
        return "unknown"
    }

    private func fetchBing(query: String, limit: Int) -> [[String: String]] {
        guard let url = URL(string: "https://www.bing.com/search?q=\(query)") else { return [] }
        guard let html = fetchHTML(url) else { return [] }
        return parseBing(html: html, limit: limit)
    }

    private func fetchDuckDuckGo(query: String, limit: Int) -> [[String: String]] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(query)") else { return [] }
        guard let html = fetchHTML(url) else { return [] }
        return parseDuckDuckGo(html: html, limit: limit)
    }

    /// v4.3.65：Baidu 回退引擎（返回 GBK，需 GB18030 解码）
    private func fetchBaidu(query: String, limit: Int) -> [[String: String]] {
        guard let url = URL(string: "https://www.baidu.com/s?wd=\(query)") else { return [] }
        guard let data = fetchData(url) else { return [] }
        return parseBaidu(html: decodeHTMLText(data), limit: limit)
    }

    /// v4.3.65：Baidu 结果解析——h3.t + a 标题 + c-abstract 摘要；跳转链接剥回真实 URL
    /// v7.2.1：解析前截断（>800KB），防超大 GBK 页正则回溯/内存压力
    private func parseBaidu(html: String, limit: Int) -> [[String: String]] {
        let html = html.count > 800_000 ? String(html.prefix(800_000)) : html
        guard let re = try? NSRegularExpression(
            pattern: "<h3[^>]*class=\"[^\"]*t[^\"]*\"[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?</h3>",
            options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        var seen = Set<String>()
        for m in matches {
            var url = capture(ns, m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            let title = capture(ns, m.range(at: 2)).stripHTMLTags()
            if let real = Self.realBaiduURL(url) { url = real }
            guard !title.isEmpty, !url.isEmpty, seen.insert(url).inserted else { continue }
            let blockRange = NSRange(location: m.range.location, length: min(ns.length - m.range.location, 800))
            let block = ns.substring(with: blockRange)
            let snippet = (block.firstCapture(pattern: "class=\"c-abstract\"[^>]*>([\\s\\S]*?)</div>") ?? "")
                .stripHTMLTags()
            out.append(["title": title, "url": url, "snippet": snippet, "source_type": Self.sourceType(for: url)])
            if out.count >= limit { break }
        }
        return out
    }

    /// Baidu 跳转链接（www.baidu.com/link?url=xxx）→ 真实 URL；解不出时返回 nil 保留原样
    private static func realBaiduURL(_ url: String) -> String? {
        guard url.contains("baidu.com/link?url="),
              let comps = URLComponents(string: url),
              let u = comps.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return u.removingPercentEncoding ?? u
    }

    /// v4.3.65：GB18030 优先解码（Baidu/GBK 站点），失败回退 UTF-8
    private func decodeHTMLText(_ data: Data) -> String {
        let enc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: enc)) { return s }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 同步抓取原始数据 (15 秒超时，桌面 Chrome UA）
    /// v7.2.1：崩溃加固——① URLSession.shared 回调派发主队列，改自定义后台队列 session
    /// （不依赖主线程，切后台/主线程忙碌时回调也能进）；② 响应上限 2MB，超大 HTML
    /// （百度反爬页/异常页）防内存暴涨触发 jetsam 杀进程；③ wait 加超时，杜绝永久阻塞。
    private func fetchData(_ url: URL) -> Data? {
        var data: Data?
        let sem = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: OperationQueue())
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: req) { d, resp, _ in
            if let d = d {
                // 响应上限 2MB：超出丢弃（大页面对解析无增益，防内存）
                if d.count <= 2_000_000 {
                    data = d
                } else if let resp = resp as? HTTPURLResponse {
                    AuditLog.shared.log("web.search", detail: "response too large: \(d.count)B from \(resp.url?.host ?? "") (\(resp.statusCode))")
                }
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)
        session.invalidateAndCancel()
        return data
    }

    /// 同步抓取网页并 UTF-8 解码 (15 秒超时）
    /// v2.9.129：UA 改桌面 Chrome —— Bing 移动版 HTML 结构与桌面版不同且不稳定，
    /// 桌面版 b_algo 结构多年稳定，解析命中率高
    private func fetchHTML(_ url: URL) -> String? {
        guard let data = fetchData(url) else {
            AuditLog.shared.log("web.search", detail: "fetch failed: \(url.absoluteString)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// v2.9.129：Bing 解析增强——三级兜底，不再"只出一条"
    /// 1) 严格 b_algo 块  2) 宽松 b_algo 块(class 带附加项)  3) 通用 h2>a 兜底
    /// v7.2.1：解析前截断（>800KB 只取头部，防超大 HTML 正则回溯/内存压力）
    private func parseBing(html: String, limit: Int) -> [[String: String]] {
        let html = html.count > 800_000 ? String(html.prefix(800_000)) : html
        var out = parseBingBlocks(html: html, pattern: "<li class=\"b_algo\">(.*?)</li>", limit: limit)
        if out.count < limit {
            out += parseBingBlocks(html: html, pattern: "<li class=\"b_algo[^\"]*\">(.*?)</li>", limit: limit - out.count)
        }
        if out.isEmpty {
            out = parseBingGeneric(html: html, limit: limit)
        }
        return out
    }

    private func parseBingBlocks(html: String, pattern: String, limit: Int) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        for m in matches {
            let block = capture(ns, m.range(at: 1))
            // 标题：<h2> 下第一个 <a>，容许多行/嵌套 span
            let head = block.firstMatch(pattern: "<h2[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>")
            // 摘要：取 b_caption 或第一个 <p> (去除标签）
            // fix3cl8: Bing 新版 HTML 摘要常不在 <p> 而在 b_caption/div.caption——多标签兜底
            let snippet = (block.firstCapture(pattern: "<p[^>]*>([\\s\\S]*?)</p>")
                           ?? block.firstCapture(pattern: "<div[^>]*class=\"[^\"]*b_caption[^\"]*\"[^>]*>([\\s\\S]*?)</div>")
                           ?? block.firstCapture(pattern: "<div[^>]*class=\"[^\"]*caption[^\"]*\"[^>]*>([\\s\\S]*?)</div>")
                           ?? "").stripHTMLTags()
            if let caps = head, caps.count == 2 {
                let title = caps[1].stripHTMLTags()
                if !title.isEmpty {
                    out.append(["title": title, "url": caps[0], "snippet": snippet, "source_type": Self.sourceType(for: caps[0])])
                }
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// 通用兜底：任意 <h2><a href="...">标题</a></h2> (Bing 改版时仍能出结果）
    private func parseBingGeneric(html: String, limit: Int) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: "<h2[^>]*>[\\s\\S]*?<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>[\\s\\S]*?</h2>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        var seen = Set<String>()
        for m in matches {
            let url = capture(ns, m.range(at: 1))
            let title = capture(ns, m.range(at: 2)).stripHTMLTags()
            guard !title.isEmpty, !url.hasPrefix("javascript:"), seen.insert(url).inserted else { continue }
            out.append(["title": title, "url": url, "snippet": "", "source_type": Self.sourceType(for: url)])
            if out.count >= limit { break }
        }
        return out
    }

    private func parseDuckDuckGo(html: String, limit: Int) -> [[String: String]] {
        guard let re = try? NSRegularExpression(pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [[String: String]] = []
        for m in matches.prefix(limit) {
            let url = capture(ns, m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            let title = capture(ns, m.range(at: 2)).stripHTMLTags()
            if url.hasPrefix("//") { continue }
            // 摘要 (紧随其后的 result__snippet）
            let snipRange = NSRange(location: m.range.location, length: min(ns.length - m.range.location, 600))
            let snipBlock = ns.substring(with: snipRange)
            let snippet = snipBlock.firstCapture(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>")?.stripHTMLTags() ?? ""
            if !title.isEmpty {
                out.append(["title": title, "url": url, "snippet": snippet, "source_type": Self.sourceType(for: url)])
            }
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - 网页抓取 (web.fetch，对齐 OpenClaw web_fetch 设计：搜索结果 → 抓原文）

final class WebFetchTool: MCPTool {
    // v7.2.3-fix24：fallback 路径共享 BrowserManager 单例 WKWebView——web.fetch 在
    // 可合批白名单（并发），多个并发批同时 fallback 会竞争同一 WebView 崩溃/错乱。
    // 全局串行锁把 navigate+sleep+text 整段锁住（直接 fetch 成功路径不受影响）。
    private static let browserFallbackLock = NSLock()
    let definition = ToolDefinition(name: "web.fetch",
        summary: "Fetch and read text content from a web page URL. Use for: read an article/webpage without opening browser, scrape page text. Don't use for: search web (use web.search), interact with page (use browser.open). Extracts main content (article/main first, noise removed); if direct fetch fails it automatically falls back to the built-in browser. Example: user says 'read this webpage content' → fetch web page.",
        parameters: ["url": "Web page URL to read", "maxChars": "Max characters to return (default 4000)"], verified: true, category: "browser")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw MCPError.invalidParams("url required")
        }
        let maxChars = params["maxChars"] as? Int ?? 4000
        var html: String?
        // v7.2.1：崩溃加固同 web.search——后台队列 session + 响应上限 4MB + wait 超时
        let sem = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: OperationQueue())
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: req) { data, _, err in
            defer { sem.signal() }
            guard err == nil, let data = data, data.count <= 4_000_000 else { return }
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)?.description
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 25)
        session.invalidateAndCancel()
        
        // v3.1.21: web.fetch failed自动 fallback 到内置浏览器
        // AI 根本不需要知道这个逻辑，直接调用 web.fetch 就能得到结果
        // v7.2.3-fix24：fallback 整段串行化（BrowserManager 单例 WebView 非并发安全）
        if html == nil {
            Self.browserFallbackLock.lock()
            defer { Self.browserFallbackLock.unlock() }
            AuditLog.shared.log("web.fetch", detail: "Direct fetch failed, falling back to the built-in browser: \(urlString)")
            do {
                // 1. 用内置浏览器打开网页
                if let navTool = ToolRegistry.shared.tool(named: "browser.navigate") {
                    _ = try navTool.invoke(["url": urlString])
                }
                // 2. 等 2 秒加载
                Thread.sleep(forTimeInterval: 2.0)
                // 3. 读取网页内容
                if let textTool = ToolRegistry.shared.tool(named: "browser.text") {
                    let result = try textTool.invoke([:])
                    if let text = result["text"] as? String, !text.isEmpty {
                        AuditLog.shared.log("web.fetch", detail: "fallback OK: \(urlString) → \(text.count) chars")
                        return [
                            "url": urlString,
                            "title": result["title"] as? String ?? "",
                            "text": String(text.prefix(maxChars)),
                            "fallback_used": true,
                            "note": "Direct fetch failed, used built-in browser as fallback"
                        ]
                    }
                }
            } catch {
                AuditLog.shared.log("web.fetch", detail: "Fallback also failed: \(error.localizedDescription)")
            }
        }
        
        guard let raw = html else {
            throw MCPError.failed("fetch failed: \(urlString) (direct fetch and browser fallback both failed)")
        }
        // 提取标题 + 正文纯文本（v4.3.65：article/main 优先抽取、去噪块，不再整页倾倒）
        let title = raw.firstCapture(pattern: "<title[^>]*>(.*?)</title>")?.stripHTMLTags() ?? ""
        var text = extractMainText(raw, maxChars: maxChars)
        if !text.isEmpty {
            text = String(text.prefix(maxChars))
        }
        AuditLog.shared.log("web.fetch", detail: "\(urlString) → \(text.count) chars")
        return ["url": urlString, "title": title, "text": text]
    }

    /// v4.3.65：正文抽取——先去噪块（nav/header/footer/aside/iframe/form/svg），
    /// 优先 <article> 区块，其次 <main>，最后回退全文；避免把导航/页脚灌给 AI
    private func extractMainText(_ html: String, maxChars: Int) -> String {
        var s = html
        for tag in ["nav", "header", "footer", "aside", "iframe", "form", "noscript", "svg", "script", "style"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: .regularExpression)
        }
        if let article = s.firstCapture(pattern: "<article[^>]*>([\\s\\S]*?)</article>") {
            let t = stripHTML(article)
            if t.count > 200 { return String(t.prefix(maxChars)) }
        }
        if let main = s.firstCapture(pattern: "<main[^>]*>([\\s\\S]*?)</main>") {
            let t = stripHTML(main)
            if t.count > 200 { return String(t.prefix(maxChars)) }
        }
        return String(stripHTML(s).prefix(maxChars))
    }

    /// HTML → 纯文本 (去注释/script/style/标签，压缩空白）
    private func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<![\\s\\S]*?>", with: " ", options: .regularExpression)   // 注释/DOCTYPE
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// v7.2.1：NSRegularExpression 捕获组安全取值——range(at:) 可能返回 NSNotFound
/// （可选组未参与/交替未选中分支），NSString.substring(with:) 对 NSNotFound 越界
/// → EXC_BAD_ACCESS/SIGSEGV（崩溃日志 sig_1793071502 实证候选）。统一防护。
/// 全局函数：供 WebSearchTool 成员函数与 String extension 共用。
fileprivate func capture(_ ns: NSString, _ r: NSRange) -> String {
    guard r.location != NSNotFound, r.location >= 0,
          r.location + r.length <= ns.length else { return "" }
    return ns.substring(with: r)
}

extension String {
    /// 返回所有捕获组 (不含整串）——带 NSNotFound 防护
    fileprivate func firstMatch(pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) else { return nil }
        var groups: [String] = []
        let ns = self as NSString
        for i in 1..<m.numberOfRanges {
            groups.append(capture(ns, m.range(at: i)))
        }
        return groups
    }

    /// 返回第一个捕获组
    fileprivate func firstCapture(pattern: String) -> String? {
        firstMatch(pattern: pattern)?.first
    }

    /// v2.9.79：去除 HTML 标签与常见实体，用于搜索标题/摘要清洗
    fileprivate func stripHTMLTags() -> String {
        var s = self
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 本机知识库 (文件存储）

final class KnowledgeStore {
    static let shared = KnowledgeStore()
    var dir: URL { Workspace.root.appendingPathComponent("knowledge", isDirectory: true) }
    func ensure() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); seedBuiltinIfNeeded() }

    // MARK: v4.3.33 内置知识种子——逆向分析方法论
    // AI 遇"分析二进制/插件安不安全"类问题先 knowledge.search 检索这里, 再 web.search 补资料, 最后组合基础工具自主分析。
    // 版本迁移: 种子版本变更时删内置条目重新播种; 只删固定前缀的文件, 保留用户自建。
    private let seedVersionKey = "trollmcp2.knowledge_seed_version"
    private let currentSeedVersion = 2
    private func seedBuiltinIfNeeded() {
        let fm = FileManager.default
        let saved = UserDefaults.standard.integer(forKey: seedVersionKey)
        if saved != currentSeedVersion {
            // v4.3.66：前缀列表扩展，覆盖第二批种子；只删固定前缀，保留用户自建
            for prefix in ["内置-逆向分析", "内置-插件安全", "内置-iOS逆向", "内置-iOS系统",
                           "内置-巨魔", "内置-运行时", "内置-游戏破解", "内置-逆向",
                       "builtin-reverse-analysis", "builtin-plugin-security"] {
                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files where f.lastPathComponent.hasPrefix(prefix) {
                        try? fm.removeItem(at: f)
                    }
                }
            }
            UserDefaults.standard.set(currentSeedVersion, forKey: seedVersionKey)
        }
        let seeds: [(String, String)] = [
            ("builtin-reverse-analysis-methodology.md", """
# Binary Reverse-Engineering Analysis Methodology

Overall flow: triage → static (read code without running) → dynamic (observe runtime behavior) → conclusion. Cross-validate static and dynamic findings.

## 0 Triage (classify first, don't rush into code)
- Format identification: use `file` / check header magic — Mach-O (64-bit magic 0xFEEDFACF) / ELF / ipa / deb / text.
- Encryption state: cryptid=1 means an encrypted binary; all static tools are ineffective — decrypt (crack the shell) before analysis.
- Dependencies/architecture: read LC_LOAD_DYLIB from the Mach-O load commands. Abnormal dependencies (a pure-JSON library linked against WebKit/Metal/Network) are a strong signal of repackaging/tampering.
- Hash + size: SHA256 + file size for cross-version comparison.

## 1 Static (don't run; read code and data)
- Symbols/strings/ObjC classes: extract with binary.symbols / inject binary_symbols (nm global symbols + strings + _OBJC_CLASS_$_ class names).
- Targeted filtering: search keywords (class names / methods / suspicious APIs).
- String leads: after extraction look for URLs/domains/IPs/keychain/API names/error copy. Extract text first, then analyze — don't grep the binary directly.
- Structure/paging: hexdump for raw bytes; package to unpack ipa/deb and list structure.
- ObjC is more precise: read __TEXT,__objc_methname (method selectors) and __TEXT,__objc_classname (class names) sections directly.
- Obfuscation/packing signs: many random symbols, ultra-high entropy, missing symbol table, overly long junk strings, abnormal compressed sections → obfuscated/packed; downgrade the conclusion to "needs deeper digging".

## 2 Dynamic (observe runtime behavior; needs the target app running on a real device)
- Network: capture traffic — check outbound domains / uploaded content / exfiltration.
- Data access: read the container — check whether the target reads contacts/SMS/files/keychain/photo library.
- Processes: check whether it spawns extra processes/daemons/auto-starts.

## 3 Boundaries
- Deep disassembly/decompilation/license-logic recovery → do on a computer with Ghidra/rizin/llvm-objdump.
- In-app scope: triage + static extraction + dynamic observation + risk verdict. For deeper work, explicitly say "needs deeper Ghidra digging on a computer".
"""),
            ("builtin-plugin-security-assessment.md", """
# Plugin / Binary Security Review Risk Assessment

First list "hits + evidence lines (which string / which class / which dependency)", then give the verdict. No conclusion without evidence.

## High-risk hits (any one = high risk)
- Privacy APIs (contacts CNContact/AddressBook, SMS CTMessage, location CLLocation, photo library PHPhotoLibrary) combined with network upload / callbacks.
- Dynamic load then execute: dlopen / dlsym / NSClassFromString / performSelector.
- Connecting to non-whitelisted domains; decryption/heavy obfuscation combined with exfiltration traits.
- Persistence: DYLD_INSERT_LIBRARIES / LaunchDaemons / LaunchAgents / self-starting daemons.

## Medium risk
- keychain/SecItem read-write, cookie/token extraction, large base64 blobs, raw socket connections.

## Low risk (notes)
- Only reading its own bundle path, normal system SDK dependencies, standard UI libraries, ad/analytics SDKs (confirm data only goes to their official domains).

## Whitelist direction
- Apple: apple.com / icloud.com / mzstatic.com.
- Common ad/analytics: google/facebook/unity/ironsource/applovin/kochava/adjust/appsflyer/bugly/firebase etc. official domains.
- Big-tech SDKs: tencent/aliyun/bytedance/baidu/xiaomi etc. official domains.

## Verdict format
Trusted / needs real-device verification (network.capture to check actual callbacks) / suspicious / malicious traits. Cite the extracted original text for any hit.
""")
        ]
        for (name, content) in seeds + SeedKnowledgeData.v2Seeds {
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    func list() -> [String] {
        ensure()
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// v3.6.19l：清空整个知识库目录（删除所有条目，含 session_memory.md，随后自动重建）
    func clearAll() -> Int {
        ensure()
        let names = list()
        for name in names {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        AuditLog.shared.log("knowledge.clear", detail: "Cleared \(names.count) knowledge entries")
        return names.count
    }

    /// v2.9.138：自动会话记忆 (类 code-session-memory）——AI 每done一轮文字回复，
    /// 把「用户提问 + AI 结论 + 涉及工具」追加到 knowledge/session_memory.md，
    /// 供后续会话用 knowledge.search (BM25）检索。行数上限 300，自动滚动。
    func appendSessionMemory(user: String, reply: String, tools: [String]) {
        ensure()
        let url = dir.appendingPathComponent("session_memory.md")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        var entry = "- \(formatter.string(from: Date())) 问: \(user)"
        if !reply.isEmpty { entry += " → AI: \(reply)" }
        if !tools.isEmpty { entry += " [工具: \(tools.joined(separator: "、"))]" }
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        lines.append(entry)
        if lines.count > 300 { lines = Array(lines.suffix(300)) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// v2.9.138：BM25 本地加权检索 (零依赖，中英混合分词）
    /// 返回按相关性排序的命中行；无命中返回空数组 (调用方回退 contains）
    func bm25Search(query: String, limit: Int = 15) -> [(file: String, line: Int, snippet: String, score: Double)] {
        let qTokens = BM25Tokenizer.tokenize(query)
        guard !qTokens.isEmpty else { return [] }
        // 文档 = 行。一次扫描所有知识库文件构建索引 (本地文件小，查询频率低）
        var docs: [(file: String, line: Int, text: String, tokens: [String])] = []
        var df: [String: Int] = [:]      // 含 token 的行数
        var totalLines = 0
        var totalTokens = 0
        for file in list() {
            let url = dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() {
                let toks = BM25Tokenizer.tokenize(line)
                guard !toks.isEmpty else { continue }
                docs.append((file, i + 1, line, toks))
                totalLines += 1
                totalTokens += toks.count
                for t in Set(toks) { df[t, default: 0] += 1 }
            }
        }
        guard !docs.isEmpty else { return [] }
        let avgdl = Double(totalTokens) / Double(totalLines)
        let N = Double(totalLines)
        let k1 = 1.5, b = 0.75
        // 查询 token 只取出现过的 (避免全零）
        let querySet = Set(qTokens).filter { df[$0] != nil }
        guard !querySet.isEmpty else { return [] }
        // idf 预计算
        var idf: [String: Double] = [:]
        for t in querySet {
            let n = Double(df[t] ?? 0)
            idf[t] = log(1 + (N - n + 0.5) / (n + 0.5))
        }
        // 逐行打分
        var scored: [(file: String, line: Int, snippet: String, score: Double)] = []
        for d in docs {
            var score = 0.0
            let dl = Double(d.tokens.count)
            var tf: [String: Int] = [:]
            for t in d.tokens { tf[t, default: 0] += 1 }
            for t in querySet {
                let f = Double(tf[t] ?? 0)
                guard f > 0 else { continue }
                score += (idf[t] ?? 0) * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
            }
            if score > 0 {
                scored.append((d.file, d.line, d.text.trimmingCharacters(in: .whitespaces), score))
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }
}

/// v2.9.137：BM25 分词器——ASCII 词 + 中文 bigram/单字，零依赖
enum BM25Tokenizer {
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        let ns = s as NSString
        if let ascii = try? NSRegularExpression(pattern: "[a-zA-Z0-9][a-zA-Z0-9_\\-]{1,}") {
            ascii.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range, r.location != -1 {
                    tokens.append(ns.substring(with: r).lowercased())
                }
            }
        }
        if let cjk = try? NSRegularExpression(pattern: "[\\u4e00-\\u9fff]+") {
            cjk.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let r = m?.range, r.location != -1 else { return }
                let chars = Array(ns.substring(with: r))
                if chars.count == 1 {
                    tokens.append(String(chars[0]))
                }
                for i in 0..<(chars.count - 1) {
                    tokens.append(String(chars[i]) + String(chars[i + 1]))
                }
                for c in chars { tokens.append(String(c)) }
            }
        }
        return tokens
    }
}

final class KnowledgeImportTextTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_text",
        summary: "Save text content to the knowledge base. Use for: store notes/reference material for later retrieval. Don't use for: write file to workspace (use artifact), search saved knowledge (use knowledge.search). Example: user says 'save this note' → import to knowledge base.",
        parameters: ["name": "Entry name/title", "content": "Text content to save"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, let content = params["content"] as? String else {
            throw MCPError.invalidParams("name, content required")
        }
        KnowledgeStore.shared.ensure()
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name.hasSuffix(".md") ? name : name + ".md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        AuditLog.shared.log("knowledge.import_text", detail: name)
        return ["imported": true, "name": file.lastPathComponent, "bytes": content.utf8.count]
    }
}

final class KnowledgeImportFileTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.import_file",
        summary: "Import a file into the knowledge base. Use for: store documents for later search/retrieval. Don't use for: import text content directly (use knowledge.import_text), search knowledge (use knowledge.search). Example: user says 'store this PDF in knowledge base' → import file.",
        parameters: ["path": "File path (workspace-relative)", "name": "Entry name (optional)"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        let src = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: src.path) else { throw MCPError.failed("not found: \(path)") }
        KnowledgeStore.shared.ensure()
        let name = params["name"] as? String ?? src.lastPathComponent
        let dst = KnowledgeStore.shared.dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        AuditLog.shared.log("knowledge.import_file", detail: name)
        return ["imported": true, "name": name]
    }
}

final class KnowledgeSearchTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.search",
        summary: "Search the knowledge base (saved documents/notes). Use for: find information you previously saved, search through imported documents. Don't use for: search the web (use web.search), search contacts (use contacts.search). Example: user says 'where is the document I saved' → search knowledge base.",
        parameters: ["query": "Search query / keywords", "limit": "Max results to return (default 15, max 50)"], verified: true, category: "knowledge")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let query = params["query"] as? String, !query.isEmpty else { throw MCPError.invalidParams("query required") }
        KnowledgeStore.shared.ensure()
        let limit = min(max(params["limit"] as? Int ?? 15, 1), 50)
        // 主路径：BM25 加权检索
        let scored = KnowledgeStore.shared.bm25Search(query: query, limit: limit)
        if !scored.isEmpty {
            AuditLog.shared.log("knowledge.search", detail: "\(query) → BM25 \(scored.count) hits")
            return ["query": query, "engine": "bm25", "count": scored.count,
                    "hits": scored.map { ["file": $0.file, "line": $0.line, "snippet": $0.snippet, "score": Double(round($0.score * 1000) / 1000)] }]
        }
        // 回退：关键词 contains
        var hits: [[String: Any]] = []
        for file in KnowledgeStore.shared.list() {
            let url = KnowledgeStore.shared.dir.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(query) {
                hits.append(["file": file, "line": i + 1, "snippet": line.trimmingCharacters(in: .whitespaces)])
                if hits.count >= limit { break }
            }
        }
        AuditLog.shared.log("knowledge.search", detail: "\(query) → contains \(hits.count) hits")
        return ["query": query, "engine": "contains", "count": hits.count, "hits": hits]
    }
}

final class KnowledgeDeleteTool: MCPTool {
    let definition = ToolDefinition(name: "knowledge.delete", summary: "Delete an entry from knowledge base. Use for: remove outdated info you saved before. Don't use for: search knowledge (use knowledge.search), save new knowledge (use knowledge.import_text). Warning: irreversible! Example: user says 'delete the note I saved before' → delete knowledge entry.",
        parameters: ["name": "Entry name to delete"], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let file = KnowledgeStore.shared.dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw MCPError.failed("not found: \(name)") }
        try FileManager.default.removeItem(at: file)
        AuditLog.shared.log("knowledge.delete", detail: name)
        return ["deleted": true, "name": name]
    }
}


// MARK: - 技能开关

final class SkillsSetEnabledTool: MCPTool {
    let definition = ToolDefinition(name: "skills.set_enabled",
        summary: "Enable or disable a skill (prompt template). Use for: turn on/off specific skills so AI only sees relevant ones. Don't use for: list all skills (use skills.list), read skill instructions (use skills.read). Example: user says 'turn off the capture skill' → disable it.",
        parameters: ["name": "Skill name", "enabled": "true (enable) or false (disable)"], verified: true, category: "skills")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPError.invalidParams("name required") }
        let enabled = params["enabled"] as? Bool ?? true
        SkillStore.shared.setEnabled(name, enabled)
        return ["name": name, "enabled": enabled]
    }
}
