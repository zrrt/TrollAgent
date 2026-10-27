import Foundation

// v7.2.3-fix18: AI 正文 block 化——正文/工具强隔离（对齐 OpenMinis block 模型）。
// 模型误输出 <|DSML| invoke> / <antml:invoke> / <invoke> 文本调用时，
// 渲染前从正文剥出工具段（.tool 块），剩余文本（.text 块）正常渲染——
// 工具调用绝不混进 AI 正文。
struct ContentBlock: Equatable {
    enum Kind: Equatable { case text, tool }
    var kind: Kind
    var text: String
    var toolName: String?
    var toolArgs: String?
    var toolTitle: String?
}

enum ContentBlocks {
    static func split(_ text: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var textBuf = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "<" {
                if let (name, endIdx) = matchStartTag(chars, i),
                   let closeIdx = findCloseTag(chars, endIdx) {
                    let segment = String(chars[endIdx..<closeIdx])
                    let (args, title) = parseParams(segment)
                    if !textBuf.isEmpty {
                        blocks.append(ContentBlock(kind: .text, text: textBuf))
                        textBuf = ""
                    }
                    blocks.append(ContentBlock(
                        kind: .tool,
                        text: String(chars[i...closeIdx]),
                        toolName: name,
                        toolArgs: args,
                        toolTitle: title))
                    i = closeIdx + 1
                    continue
                }
            }
            textBuf.append(chars[i])
            i += 1
        }
        if !textBuf.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: textBuf))
        }
        if blocks.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: text))
        }
        return blocks
    }

    /// 从 startIdx 匹配文本调用起始标签，返回 (工具名, 标签结束位置)
    private static func matchStartTag(_ chars: [Character], _ startIdx: Int) -> (String, Int)? {
        let s = String(chars[startIdx...])
        let patterns = [
            #"^<\|DSML\| invoke\s+name="([^"]+)"[^>]*>"#,
            #"^<antml:invoke\s+name="([^"]+)"[^>]*>"#,
            #"^<invoke\s+name="([^"]+)"[^>]*>"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range, in: s),
               let nr = Range(m.range(at: 1), in: s) {
                return (String(s[nr]), startIdx + r.upperBound.utf16Offset(in: s))
            }
        }
        return nil
    }

    /// 从 endIdx 找闭合标签位置（三选一）
    private static func findCloseTag(_ chars: [Character], _ from: Int) -> Int? {
        var j = from
        let close1 = "</|DSML|>"
        let close2 = "</antml:invoke>"
        let close3 = "</invoke>"
        while j < chars.count {
            if chars[j] == "<" {
                let rest = String(chars[j...])
                if rest.hasPrefix(close1) || rest.hasPrefix(close2) || rest.hasPrefix(close3) {
                    let len = rest.hasPrefix(close1) ? close1.count
                        : (rest.hasPrefix(close2) ? close2.count : close3.count)
                    return j + len
                }
            }
            j += 1
        }
        return nil
    }

    /// 解析 antml parameter 段；返回 (参数串, tool_title)
    /// 字符扫描版（闭合标签用拼接，字面量闭合序列会截断外层参数）
    private static func parseParams(_ segment: String) -> (String?, String?) {
        var dict: [String: String] = [:]
        let closeTag = "</" + "parameter>"
        let marker = "<parameter name="
        let chars = Array(segment)
        var i = 0
        while i < chars.count {
            if String(chars[i...]).hasPrefix(marker) {
                var j = i + marker.count
                var pname = ""
                while j < chars.count, chars[j] != "\"" { pname.append(chars[j]); j += 1 }
                j += 1
                while j < chars.count, chars[j] != ">" { j += 1 }
                j += 1
                let tail = String(chars[j...])
                if let closeRange = tail.range(of: closeTag) {
                    let value = String(tail[..<closeRange.lowerBound])
                    dict[pname] = value
                    i = j + closeRange.lowerBound.utf16Offset(in: tail) + closeTag.count
                    continue
                }
            }
            i += 1
        }
        let title = dict["tool_title"]
        var args: String?
        if !dict.isEmpty {
            let pairs = dict.keys.sorted().map { k -> String in
                let v = dict[k] ?? ""
                return "\"\(k)\": \"\(v)\""
            }
            args = pairs.joined(separator: ",\n")
        } else {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { args = trimmed }
        }
        return (args, title)
    }
}
