import SwiftUI

/// v7.1.109-minis：AI 正文 Markdown 块渲染（对齐 OpenMinis SelectableMarkdownView 能力子集——
/// 用户要求"AI 能输出表格展示、命令行文本展示"）。
/// 覆盖：fenced 代码块（黑底等宽命令行样式，与工具结果同视觉）、Markdown 表格（LazyVGrid 栅格）、
/// 普通文本（沿用 ChatView 反引号橙色 + **加粗** 正则着色）。
/// 流式打字机路径不启用（打字机下表格/代码块会跳动），完成消息才块渲染。
enum MarkdownBlocks {

    enum Block: Equatable {
        case text(String)
        case codeBlock(code: String, language: String?)
        case table(header: [String], rows: [[String]])
        case tasks(items: [TaskItem])
        case quote(String)
        case hr
        case list(items: [ListItem])
        case image(alt: String, url: String)
        case math(String)
        case heading(level: Int, text: String)
    }

    /// v7.1.109-peers：任务清单项（tuple 数组不自动合成 Equatable，需 struct）
    struct TaskItem: Equatable {
        var done: Bool
        var text: String
    }

    /// v7.2.1：有序/无序列表项
    struct ListItem: Equatable {
        var ordered: Bool
        var marker: String   // "•"（无序）或 "1."（有序原文编号）
        var text: String
        var level: Int = 0   // v7.2.3-fix5：嵌套级别（行首 2 空格 = 1 级，tab = 1 级）
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var i = 0
        var textBuf: [String] = []
        func flushText() {
            if !textBuf.isEmpty {
                blocks.append(.text(textBuf.joined(separator: "\n")))
                textBuf = []
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // fenced 代码块：``` 开头，语言标记提取（```swift → swift）
            if trimmed.hasPrefix("```") {
                flushText()
                let langMarker = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = langMarker.isEmpty ? nil : langMarker
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    code.append(l)
                    i += 1
                }
                blocks.append(.codeBlock(code: code.joined(separator: "\n"), language: language))
                continue
            }
            // v7.2.3-audit4：DSML/antml 工具调用文本块 → 代码块样式渲染。
            // 模型误输出 <|DSML| invoke…> 而非结构化 function call 时，至少按代码块
            // 显示（等宽+背景），避免一片纯文本难以阅读。注意：只渲染不执行。
            if trimmed.hasPrefix("<|DSML|") || trimmed.hasPrefix("<antml:") || trimmed.hasPrefix("<antml ") || trimmed.hasPrefix("<invoke") {
                flushText()
                var code: [String] = [line]
                i += 1
                while i < lines.count {
                    let dl = lines[i]
                    code.append(dl)
                    i += 1
                    if dl.hasPrefix("</|DSML|") || dl.hasPrefix("</antml:") || dl.hasPrefix("</invoke")
                        || dl.trimmingCharacters(in: .whitespaces).isEmpty { break }
                }
                blocks.append(.codeBlock(code: code.joined(separator: "\n"), language: "xml"))
                continue
            }
            // v7.1.109-peers：任务清单三态（Cursor To-dos / Manus 计数式）——
            // 连续 "- [ ]" / "- [x]" 行识别为任务块
            if trimmed.hasPrefix("- [") || trimmed.hasPrefix("* [") {
                flushText()
                var items: [TaskItem] = []
                while i < lines.count {
                    let dl = lines[i].trimmingCharacters(in: .whitespaces)
                    if dl.hasPrefix("- [") || dl.hasPrefix("* [") {
                        let rest = String(dl.dropFirst(3))
                        let done = rest.hasPrefix("x]") || rest.hasPrefix("X]")
                        let body = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        items.append(TaskItem(done: done, text: body))
                        i += 1
                    } else { break }
                }
                if !items.isEmpty {
                    blocks.append(.tasks(items: items))
                    continue
                }
            }
            // 表格：当前行 | 开头结尾 && 下一行是分隔行（|---|---|）→ 表头 + 数据行
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushText()
                let header = cells(of: line)
                i += 2
                var rows: [[String]] = []
                // v7.1.109-peers：不完整行（流式/打字中途无结尾 |）也进表格容器——
                // 内容在单元格内流式填充（大厂式表格内打字），不再跳回纯文本
                while i < lines.count {
                    let dl = lines[i].trimmingCharacters(in: .whitespaces)
                    if dl.hasPrefix("|") {
                        rows.append(cells(of: lines[i]))
                        i += 1
                    } else { break }
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // v7.2.1：块级数学公式 $$...$$（同行或跨行闭合）
            if trimmed.hasPrefix("$$") {
                flushText()
                let startLine = line
                var latexLines: [String] = []
                var body = String(trimmed.dropFirst(2))
                var closed = false
                // 同行闭合 $$...$$
                if body.hasSuffix("$$") {
                    latexLines.append(String(body.dropLast(2)).trimmingCharacters(in: .whitespaces))
                    i += 1
                    closed = true
                } else {
                    // 跨行：$$ 开头行之后收集到 $$ 结束行
                    i += 1
                    while i < lines.count {
                        let dl = lines[i]
                        let dlt = dl.trimmingCharacters(in: .whitespaces)
                        if dlt.hasSuffix("$$") {
                            let inner = String(dlt.dropLast(2))
                            if !inner.isEmpty { latexLines.append(inner) }
                            i += 1
                            closed = true
                            break
                        }
                        latexLines.append(dl)
                        i += 1
                    }
                }
                // v7.2.2-audit：未闭合 $$ 回退纯文本（打字机中途 $$ 出现不能吞掉剩余内容）
                if closed, !latexLines.isEmpty {
                    blocks.append(.math(latexLines.joined(separator: "\n")))
                    continue
                } else if !closed {
                    textBuf.append(startLine)
                    textBuf.append(contentsOf: latexLines)
                    continue
                }
            }
            // v7.2.3-fix4：标题——# ～ ###### 开头行 → heading 块（大字号加粗）。
            // 连续 # 无空格也接受（模型常写 "##标题"）；### 及以上缩进逐级减小。
            if trimmed.hasPrefix("#") {
                let hashCount = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(hashCount).trimmingCharacters(in: .whitespaces)
                if hashCount <= 6 && !rest.isEmpty {
                    flushText()
                    blocks.append(.heading(level: hashCount, text: rest))
                    i += 1
                    continue
                }
            }
            // v7.2.1：引用块——连续 > 前缀行（> 或 > 文本）
            // v7.2.3-fix：按引用内空行分段——单引用特别长时避免拼成
            // 一个巨型块（LazyVStack 单 cell 过高/滚动卡），空行切分语义不变
            if trimmed.hasPrefix(">") {
                flushText()
                var segments: [[String]] = [[]]
                while i < lines.count {
                    let dl = lines[i].trimmingCharacters(in: .whitespaces)
                    if dl.hasPrefix(">") {
                        var rest = String(dl.dropFirst())
                        if rest.hasPrefix(" ") { rest.removeFirst() }
                        segments[segments.count - 1].append(rest)
                        i += 1
                    } else if dl.isEmpty {
                        segments.append([])
                        i += 1
                    } else { break }
                }
                for seg in segments where !seg.isEmpty {
                    blocks.append(.quote(seg.joined(separator: "\n")))
                }
                continue
            }
            // v7.2.1：有序/无序列表——连续 - / * / + / 1. 行首
            // v7.2.3-fix5：支持嵌套——按行首缩进算级别（2 空格 = 1 级，tab = 1 级，clamp 0-4）
            if isListMarker(trimmed) {
                flushText()
                var items: [ListItem] = []
                while i < lines.count {
                    let raw = lines[i]
                    let indent = Self.leadingIndent(of: raw)
                    let dl = raw.trimmingCharacters(in: .whitespaces)
                    guard let m = listMarker(of: dl) else { break }
                    items.append(ListItem(ordered: m.ordered, marker: m.marker, text: m.text, level: min(indent / 2, 4)))
                    i += 1
                }
                if !items.isEmpty {
                    blocks.append(.list(items: items))
                    continue
                }
            }
            // v7.2.1：分隔线 —— 单独一行全由 - / _ / * 组成（≥3 个）
            if isHrLine(trimmed) {
                flushText()
                blocks.append(.hr)
                i += 1
                continue
            }
            // v7.2.1：行首图片 ![alt](url)
            if let (alt, url) = imageMarkup(of: trimmed) {
                flushText()
                blocks.append(.image(alt: alt, url: url))
                i += 1
                continue
            }
            textBuf.append(line)
            i += 1
        }
        flushText()
        return blocks
    }

    /// v7.2.1：无序（- / * / +）或有序（数字.）列表行首
    /// v7.2.3-fix5：行首缩进计数（2 空格 = 1 级，tab = 2 空格计）
    private static func leadingIndent(of line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 2 }
            else { break }
        }
        return n
    }

    private static func isListMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        // 有序：数字 + "." + 空格
        let pat = #"^\d+\.\s"#
        if let regex = try? NSRegularExpression(pattern: pat),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        return false
    }

    private static func listMarker(of trimmed: String) -> ListItem? {
        if trimmed.hasPrefix("- ") {
            return ListItem(ordered: false, marker: "•", text: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("* ") {
            return ListItem(ordered: false, marker: "•", text: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("+ ") {
            return ListItem(ordered: false, marker: "•", text: String(trimmed.dropFirst(2)))
        }
        // 有序：数字. 原文编号
        let pat = #"^(\d+)\.\s+(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pat),
           let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let nR = Range(m.range(at: 1), in: trimmed),
           let tR = Range(m.range(at: 2), in: trimmed) {
            return ListItem(ordered: true, marker: String(trimmed[nR]) + ".", text: String(trimmed[tR]))
        }
        return nil
    }

    /// v7.2.1：分隔线——trimmed 非空且全由 - / _ / * 组成（≥3），且不是表格分隔行
    private static func isHrLine(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let allowed: Set<Character> = ["-", "_", "*"]
        return trimmed.allSatisfy { allowed.contains($0) }
    }

    /// v7.2.1：行首图片 ![alt](url)
    private static func imageMarkup(of trimmed: String) -> (String, String)? {
        guard trimmed.hasPrefix("!["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let alt = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let after = trimmed[trimmed.index(after: close)...]
        guard after.hasPrefix("("), let urlEnd = after.firstIndex(of: ")") else { return nil }
        let url = String(after[after.index(after: after.startIndex)..<urlEnd]).trimmingCharacters(in: .whitespaces)
        // 只处理整行是图片的情况（行内图片留给行内解析）
        let rest = after[after.index(after: urlEnd)...]
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (alt, url)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let inner = t.dropFirst().dropLast()
        guard inner.contains("-") else { return false }
        return inner.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " || $0 == "|" }
    }

    private static func cells(of line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        let body = t.hasPrefix("|") ? String(t.dropFirst()) : t
        let end = body.hasSuffix("|") ? String(body.dropLast()) : body
        return end.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// v7.1.109-minis：提取正文/工具结果里的可打开链接——
/// 1) minis://open?url=<目标>（AI 主动推送标记，对齐 Minis OSC minis-open 语义：
///    shell 输出/正文带此标记 → UI 渲染链接卡一键打开）
/// 2) 裸 http/https URL（点击开内置浏览器，对齐 Minis LinkPreviewView 能力）
enum LinkExtractor {

    /// 返回去重后的可打开链接
    static func extractLinks(from text: String) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        // 1) minis://open?url= 标记（支持 URL 编码或裸 URL）
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: "minis://open?url=", range: searchRange) {
            let rest = text[r.upperBound...]
            let end = rest.firstIndex { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ")" || $0 == "]" || $0 == "，" || $0 == "。" } ?? rest.endIndex
            var u = String(rest[..<end])
            if u.contains("%") { u = u.removingPercentEncoding ?? u }
            if let url = URL(string: u), !seen.contains(u) {
                urls.append(url)
                seen.insert(u)
            }
            searchRange = end..<text.endIndex
        }
        // 2) 裸 http/https URL
        let pattern = #"https?://[^\s"'\(\)\]\}，。；：,;]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match = match, let r = Range(match.range, in: text) else { return }
                var u = String(text[r])
                while let last = u.last, "。，；：,.;:)）]】".contains(last) { u.removeLast() }
                if seen.contains(u) { return }
                guard let url = URL(string: u) else { return }
                urls.append(url)
                seen.insert(u)
            }
        }
        return urls
    }
}

/// 链接卡：点击开内置浏览器（对齐 Minis LinkPreviewView 的"点击 → 应用内打开"）
struct LinkCardView: View {
    let url: URL

    var body: some View {
        Button {
            BrowserManager.shared.open(url.absoluteString)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text(url.host ?? url.absoluteString)
                    // v7.1.109-peers：链接卡字体 12→13pt（用户反馈链接文字较小）
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                Text(url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

/// 完成消息的块组合渲染视图
struct MarkdownBlocksView: View {
    let text: String
    /// ChatView 的正则着色闭包（反引号橙色 + **粗体**），普通文本块复用
    let coloredBody: (String) -> AttributedString
    /// v7.2.2：本条回复的联网搜索次数（assistant.toolCalls 里 web_search/web_fetch 计数）——"已联网搜索 N 次"
    var webSearchCount: Int = 0
    /// v7.2.2：资料折叠条展开态（"已参考 N 篇资料"点击展开来源列表）
    @State private var sourcesExpanded = false

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        // v7.1.109-peers：引用来源列表（Perplexity/Kimi 式）——正文里的 [N] 角标 + 文末 [N]: URL 来源行
        let citations = CitationExtractor.extract(text)
        VStack(alignment: .leading, spacing: 8) {
            // v7.2.2：顶部资料折叠条——"已参考 N 篇资料 · 已联网搜索 M 次"（Kimi 式灰色可折叠条）
            if !citations.sources.isEmpty || webSearchCount > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { sourcesExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                            if !citations.sources.isEmpty {
                                Text(L10n.t("i18n_1257", citations.sources.count))
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.primary)
                            }
                            if !citations.sources.isEmpty && webSearchCount > 0 {
                                Text("·")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if webSearchCount > 0 {
                                Text(L10n.t("i18n_1258", webSearchCount))
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.primary)
                            }
                            Spacer()
                            Image(systemName: sourcesExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    if sourcesExpanded && !citations.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(citations.sources, id: \.index) { src in
                                LinkCardView(url: src.url)
                            }
                        }
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
                }
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .text(let t):
                    // v7.1.109-minis：文本块下方附加链接卡（URL / minis:// 标记 → 一键开内置浏览器）
                    VStack(alignment: .leading, spacing: 4) {
                        // v7.1.109-peers：正文剥离来源行（[1]: URL），避免原文里露出一长串 URL；
                        // 来源 URL 也不重复渲染链接卡（Sources 卡统一呈现）
                        let cleanBody = CitationExtractor.stripSourceLines(t)
                        Text(coloredBody(cleanBody))
                            .font(.body)
                            .textSelection(.enabled)
                        let links = LinkExtractor.extractLinks(from: cleanBody)
                        if !links.isEmpty {
                            ForEach(links, id: \.self) { LinkCardView(url: $0) }
                        }
                    }
                case .codeBlock(let code, let language):
                    MarkdownCodeBlockView(code: code, language: language)
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                case .tasks(let items):
                    // v7.1.109-peers：任务清单三态——空心圈待办 / 绿勾完成（Cursor To-dos / Manus 三态）
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundColor(item.done ? .green : .secondary)
                                Text(item.text)
                                    .font(.callout)
                                    .foregroundColor(item.done ? .secondary : .primary)
                                    .strikethrough(item.done, color: .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                case .quote(let q):
                    // v7.2.1：引用块——左侧竖线 + 缩进 + 浅色底（Kimi/豆包式）
                    // v7.1.278-fix：同列表项——HStack 内 AttributedString 换行 bug，正文 Text 明确宽度
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: 3)
                        Text(coloredBody(q))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground).opacity(0.6))
                    .cornerRadius(8)
                case .heading(let level, let title):
                    // v7.2.3-fix4：标题——字号随级别递减（H1=21 → H6=15），粗体、行内样式保留
                    Text(coloredBody(title))
                        .font(.system(size: CGFloat(max(22 - level, 16)), weight: .bold))
                        .padding(.top, level <= 2 ? 10 : 6)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .hr:
                    Divider()
                        .overlay(Color(.separator))
                        .padding(.vertical, 4)
                case .list(let items):
                    // v7.2.1：有序/无序列表——marker 列 + 正文（首行基线对齐）
                    // v7.2.3-fix5：嵌套缩进——按 item.level 每级 16pt 左移
                    // v7.1.278-fix：列表项正文 HStack 内 AttributedString 换行 bug（iOS16 多 run 文本
                    // 不换行单行截断加"…"，勾选触发布局重建才显示完整）——正文 Text 加 maxWidth 明确
                    // 宽度传播强制换行，marker fixedSize 防压缩。
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker)
                                    .font(.body.weight(item.ordered ? .semibold : .bold))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Text(coloredBody(item.text))
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, CGFloat(item.level) * 16)
                        }
                    }
                case .image(let alt, let url):
                    MarkdownInlineImageView(alt: alt, url: url)
                case .math(let latex):
                    // v7.2.1：块级公式——LaTeX → Unicode 近似渲染（居中斜体）
                    Text(MathText.render(latex))
                        .font(.system(size: 17).italic())
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// v7.1.109-peers：引用角标 + 来源提取（Perplexity/Kimi 三层渐进的第一、三层）
/// 第一层：正文句末 [1][2] 角标（渲染为蓝色上标）
/// 第三层：文末 [1]: https://... 来源列表 → Sources 计数 + 来源卡
enum CitationExtractor {

    struct Source: Equatable {
        let index: Int
        let url: URL
    }

    struct Result {
        /// 正文里的角标数（[N] 出现次数，去重）
        var markerCount: Int = 0
        /// 文末来源列表（[N]: URL 行解析出的有序来源）
        var sources: [Source] = []
    }

    static func extract(_ text: String) -> Result {
        var r = Result()
        // 角标：形如 [1] 或 [1][2]，紧跟句尾
        let markerPattern = #"\[\d+\]"#
        if let regex = try? NSRegularExpression(pattern: markerPattern) {
            let range = NSRange(text.startIndex..., in: text)
            var seen = Set<Int>()
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let m = match, let rng = Range(m.range, in: text) else { return }
                let n = Int(String(text[rng]).dropFirst().dropLast()) ?? 0
                if n > 0 { seen.insert(n) }
            }
            r.markerCount = seen.count
        }
        // 来源行：[N]: URL（文末或行内）
        let srcPattern = #"(?:^|\n)\s*\[(\d+)\]:\s*(https?://[^\s"'\(\)\]\}，。；：,;]+)"#
        if let regex = try? NSRegularExpression(pattern: srcPattern) {
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let m = match,
                      let iR = Range(m.range(at: 1), in: text),
                      let uR = Range(m.range(at: 2), in: text) else { return }
                let idx = Int(String(text[iR])) ?? 0
                var u = String(text[uR])
                while let last = u.last, "。，；：,.;:)）]】".contains(last) { u.removeLast() }
                if let url = URL(string: u), idx > 0, !r.sources.contains(where: { $0.index == idx }) {
                    r.sources.append(Source(index: idx, url: url))
                }
            }
            r.sources.sort { $0.index < $1.index }
        }
        return r
    }

    /// v7.1.109-peers：从正文剥离来源行（[1]: URL），避免原文露出一长串 URL
    static func stripSourceLines(_ text: String) -> String {
        let pattern = #"(?:^|\n)\s*\[\d+\]:\s*https?://[^\s"'\(\)\]\}，。；：,;]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

/// v7.1.109-peers：代码块操作条（Gemini/Kimi 式）——左上语言标签 + 右上复制按钮
struct MarkdownCodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if language != nil || !code.isEmpty {
                HStack(spacing: 8) {
                    if let lang = language {
                        Text(lang)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18))
                            .cornerRadius(4)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label(L10n.t("i18n_1255"), systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black)
            }
            Text(code)
                // v7.1.109-peers：代码块字体 12→14pt（用户反馈黑底渲染文字较小）
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .textSelection(.enabled)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }
}

/// Markdown 表格渲染（LazyVGrid，iOS 14+ 兼容；部署目标 iOS 15 不能使用 Grid）
/// v7.1.109-peers：大厂式滚动——列均分屏宽（≤3 列满宽自适应，>3 列固定 3 列宽 → 横向可滑）、
/// 内容多时限高垂直内部滚动（不再把气泡撑无限高），对齐豆包/Kimi 表格交互
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columns = max(1, header.count)
        // 列宽：≤3 列均分可用宽度满宽；>3 列按 3 列均分宽度 → 总宽溢出 → 横向滑动
        let screenW = UIScreen.main.bounds.width
        let colWidth: CGFloat = max(96, (screenW - 64) / CGFloat(min(columns, 3)))
        let gridCols = (0..<columns).map { _ in GridItem(.fixed(colWidth), spacing: 8) }
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollView(.vertical, showsIndicators: rows.count > 4) {
                VStack(alignment: .leading, spacing: 0) {
                    // 表头（蓝 + 半粗等宽）
                    LazyVGrid(columns: gridCols, spacing: 6) {
                        ForEach(0..<columns, id: \.self) { i in
                            Text(i < header.count ? header[i] : "")
                                // v7.2.3-fix39：表格字体 13→15pt（用户仍反馈表格文字小）
                                .font(.system(size: 15, design: .monospaced).weight(.semibold))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 4)
                    // 数据行
                    ForEach(rows, id: \.self) { row in
                        LazyVGrid(columns: gridCols, spacing: 6) {
                            ForEach(0..<columns, id: \.self) { i in
                                Text(i < row.count ? row[i] : "")
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )
            }
            // v7.1.109-peers：行数多限高内部滚动（<4 行不触发，自适应高度）
            // v7.1.278-fix：表格随内容变长而变长——移除 300pt 硬限高（用户实测长表格
            // 只能看到正方形窗口、内容要一直内部滑动）；表格直接在消息流完整展开，
            // 随页面滚动阅读。仅极端超长（>60 行）保留内部滚动，防单 cell 过高卡顿。
            .frame(maxHeight: rows.count > 60 ? 480 : .infinity)
        }
    }
}

/// v7.2.1：行内图片渲染——data URI（base64 直接解码）与 http(s)（异步加载 + 内存缓存）
struct MarkdownInlineImageView: View {
    let alt: String
    let url: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                    )
            } else if failed {
                HStack(spacing: 5) {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("\(alt)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(6)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("loading image…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard image == nil, !failed else { return }
        if url.hasPrefix("data:image/") {
            // data URI：data:image/png;base64,<payload>
            if let comma = url.firstIndex(of: ",") {
                let payload = String(url[url.index(after: comma)...])
                if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                   let img = UIImage(data: data) {
                    image = img
                    return
                }
            }
            failed = true
            return
        }
        guard let u = URL(string: url) else { failed = true; return }
        // 内存缓存
        if let cached = MarkdownImageCache.shared.image(for: url) {
            image = cached
            return
        }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data = data, let img = UIImage(data: data) else {
                DispatchQueue.main.async { failed = true }
                return
            }
            MarkdownImageCache.shared.set(img, for: url)
            DispatchQueue.main.async { image = img }
        }.resume()
    }
}

/// v7.2.1：图片内存缓存（NSCache，避免同一 URL 重复下载）
final class MarkdownImageCache {
    static let shared = MarkdownImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {}

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ img: UIImage, for key: String) { cache.setObject(img, forKey: key as NSString) }
}

/// v7.2.1：LaTeX → Unicode 近似渲染（无第三方库、iOS 15 手动体系）
/// 覆盖测试项 ⑧：常见命令映射 + 上标/下标 + \frac/\sqrt。
enum MathText {

    static func render(_ latex: String) -> String {
        var s = latex
        // 顺序：frac ↔ sqrt 交替循环（frac 的嵌套参数可能是 sqrt 产物，反之亦然）→
        // 命令映射（\infty 等先变 Unicode，避免 ^\infty 残留）→ 上下标
        var prev: String?
        repeat {
            prev = s
            s = replaceFrac(s)
            s = replaceSqrt(s)
        } while s != prev
        let cmds: [(String, String)] = [
            (#"\infty"#, "∞"), (#"\pi"#, "π"), (#"\alpha"#, "α"), (#"\beta"#, "β"),
            (#"\gamma"#, "γ"), (#"\delta"#, "δ"), (#"\theta"#, "θ"), (#"\lambda"#, "λ"),
            (#"\mu"#, "μ"), (#"\sigma"#, "σ"), (#"\omega"#, "ω"), (#"\phi"#, "φ"),
            (#"\epsilon"#, "ε"), (#"\Delta"#, "Δ"), (#"\Sigma"#, "Σ"), (#"\Omega"#, "Ω"),
            (#"\sum"#, "∑"), (#"\int"#, "∫"), (#"\prod"#, "∏"), (#"\partial"#, "∂"),
            (#"\nabla"#, "∇"), (#"\forall"#, "∀"), (#"\exists"#, "∃"), (#"\in"#, "∈"),
            (#"\subset"#, "⊂"), (#"\cup"#, "∪"), (#"\cap"#, "∩"), (#"\cdot"#, "·"),
            (#"\times"#, "×"), (#"\pm"#, "±"), (#"\leq"#, "≤"), (#"\geq"#, "≥"),
            (#"\neq"#, "≠"), (#"\approx"#, "≈"), (#"\rightarrow"#, "→"), (#"\leftarrow"#, "←"),
            (#"\dots"#, "…"), (#"\ldots"#, "…"), (#"\qquad"#, "   "), (#"\quad"#, "  "),
            (#"\,"#, " "), (#"\ "#, " "), (#"\left"#, ""), (#"\right"#, ""),
            (#"\{", "{"), (#"\}"#, "}"),
        ]
        for (k, v) in cmds { s = s.replacingOccurrences(of: k, with: v) }
        s = replaceSupSub(s)
        // 清理残留反斜杠命令
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// \frac{a}{b} → (a)/(b)（嵌套逐步处理；iOS 15 用 enumerateMatches 手动重建）
    private static func replaceFrac(_ s: String) -> String {
        let pat = #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pat) else { return s }
        var out = s
        var prev: String?
        repeat {
            prev = out
            let nsRange = NSRange(out.startIndex..., in: out)
            var result = ""
            var lastEnd = out.startIndex
            regex.enumerateMatches(in: out, range: nsRange) { m, _, _ in
                guard let m = m, let fr = Range(m.range, in: out) else { return }
                result += String(out[lastEnd..<fr.lowerBound])
                // substring 内部已对 NSNotFound/越界容错返回 ""
                let num = substring(out, m.range(at: 1))
                let den = substring(out, m.range(at: 2))
                result += "(\(num))/(\(den))"
                lastEnd = fr.upperBound
            }
            result += String(out[lastEnd..<out.endIndex])
            out = result
        } while out != prev
        return out
    }

    /// \sqrt{...} → √(...)
    private static func replaceSqrt(_ s: String) -> String {
        let pat = #"\\sqrt\{([^{}]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pat) else { return s }
        var out = s
        var prev: String?
        repeat {
            prev = out
            let nsRange = NSRange(out.startIndex..., in: out)
            var result = ""
            var lastEnd = out.startIndex
            regex.enumerateMatches(in: out, range: nsRange) { m, _, _ in
                guard let m = m, let fr = Range(m.range, in: out) else { return }
                result += String(out[lastEnd..<fr.lowerBound])
                let body = substring(out, m.range(at: 1))  // substring 内部容错 NSNotFound
                result += "√(\(body))"
                lastEnd = fr.upperBound
            }
            result += String(out[lastEnd..<out.endIndex])
            out = result
        } while out != prev
        return out
    }

    /// 上标 ^{...} / ^x 与下标 _{...} / _x → Unicode 近似
    private static func replaceSupSub(_ s: String) -> String {
        var out = s
        let supPat = #"\^\{([^{}]*)\}|\^([^\s^])"#
        let subPat = #"_\{([^{}]*)\}|_([^\s_])"#
        if let regex = try? NSRegularExpression(pattern: supPat) {
            let nsRange = NSRange(out.startIndex..., in: out)
            var result = ""
            var lastEnd = out.startIndex
            regex.enumerateMatches(in: out, range: nsRange) { m, _, _ in
                guard let m = m, let fr = Range(m.range, in: out) else { return }
                result += String(out[lastEnd..<fr.lowerBound])
                if m.range(at: 1).location != NSNotFound {
                    result += unicodeSup(substring(out, m.range(at: 1)))
                } else if m.range(at: 2).location != NSNotFound {
                    result += unicodeSup(substring(out, m.range(at: 2)))
                }
                lastEnd = fr.upperBound
            }
            result += String(out[lastEnd..<out.endIndex])
            out = result
        }
        if let regex = try? NSRegularExpression(pattern: subPat) {
            let nsRange = NSRange(out.startIndex..., in: out)
            var result = ""
            var lastEnd = out.startIndex
            regex.enumerateMatches(in: out, range: nsRange) { m, _, _ in
                guard let m = m, let fr = Range(m.range, in: out) else { return }
                result += String(out[lastEnd..<fr.lowerBound])
                if m.range(at: 1).location != NSNotFound {
                    result += unicodeSub(substring(out, m.range(at: 1)))
                } else if m.range(at: 2).location != NSNotFound {
                    result += unicodeSub(substring(out, m.range(at: 2)))
                }
                lastEnd = fr.upperBound
            }
            result += String(out[lastEnd..<out.endIndex])
            out = result
        }
        return out
    }

    private static func unicodeSup(_ t: String) -> String {
        let map: [Character: String] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
                                        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
                                        "+": "⁺", "-": "⁻", "(": "⁽", ")": "⁾", "=": "⁼"]
        if t.count == 1, let u = map[t.first!] { return u }
        return "^(\(t))"
    }

    private static func unicodeSub(_ t: String) -> String {
        let map: [Character: String] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
                                        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
                                        "+": "₊", "-": "₋", "(": "₍", ")": "₎", "=": "₌"]
        if t.count == 1, let u = map[t.first!] { return u }
        return "_(\(t))"
    }

    /// NSRange → Range 安全转换（NSNotFound 时返回 nil）
    private static func substring(_ s: String, _ r: NSRange) -> String {
        guard let rng = Range(r, in: s) else { return "" }
        return String(s[rng])
    }
}
