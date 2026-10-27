import Foundation

// v7.2.3-fix20：连续工具折叠——相邻的已完成 tool 消息聚合成一组
// （对齐 OpenMinis "连续工具调用折叠为一行运行了 N 个工具 + 总耗时"）。
// 规则：连续 isTool 且 !isRunning（已完成）的消息，≥2 条折叠成组；
// running 中的工具卡不折叠（避免流式过程布局跳动），单条不折叠。
enum ChatListGrouping {
    enum Item: Equatable {
        case msg(ChatMessage)
        case tools([ChatMessage])

        var id: String {
            switch self {
            case .msg(let m): return "m-" + m.id.uuidString
            case .tools(let ms):
                // v7.2.3-fix20.1：组 id 只用首条 UUID（去掉条数）——
                // 并发波内工具增量完成（A → A+B → A+B+C）时组 id 保持稳定，
                // 用户已展开的组不会因条数变化而折叠回去
                return "t-" + (ms.first?.id.uuidString ?? "")
            }
        }

        /// 组内总耗时（秒）——各工具卡耗时之和
        var totalDuration: Double? {
            if case .tools(let ms) = self {
                let sum = ms.reduce(0.0) { $0 + ($1.toolDuration ?? 0) }
                return sum > 0 ? sum : nil
            }
            return nil
        }
    }

    static func group(_ messages: [ChatMessage]) -> [Item] {
        var out: [Item] = []
        var run: [ChatMessage] = []
        func flush() {
            if run.count >= 2 {
                out.append(.tools(run))
            } else {
                out.append(contentsOf: run.map { .msg($0) })
            }
            run = []
        }
        for m in messages {
            if m.isTool && !m.isRunning {
                run.append(m)
            } else {
                flush()
                out.append(.msg(m))
            }
        }
        flush()
        return out
    }
}
