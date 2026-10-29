import SwiftUI

// fix73j：子代理详情页——独立界面，像主会话一样展示子代理的完整轨迹
// 入口：主会话"子代理完成卡"点击。数据源：SubAgentManager.status(taskID) 的
// task.trace（终态快照）；App 重启后 tasks 丢失 → 回退渲染消息内的摘要 JSON。

/// [SUBAGENT-RUNNING]/[SUBAGENT-DONE] 前缀消息解析（子代理状态载荷）
struct SubAgentCompleteCard {
    static func parse(_ content: String) -> [String: Any] {
        guard content.hasPrefix("[SUBAGENT-") else { return [:] }
        let markerLen = content.hasPrefix("[SUBAGENT-RUNNING]")
            ? "[SUBAGENT-RUNNING]".count : "[SUBAGENT-DONE]".count
        let json = String(content.dropFirst(markerLen))
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    static func summary(_ d: [String: Any]) -> String {
        let agent = d["agent_type"] as? String ?? "?"
        let rounds = d["rounds"] as? Int ?? 0
        let elapsed = d["elapsed_secs"] as? Int ?? 0
        let result = (d["result"] as? String)?
            .replacingOccurrences(of: "\n", with: " ")
        return "\(agent) · \(rounds) 轮 · \(elapsed)s\(result.map { " · " + String($0.prefix(80)) } ?? "")"
    }
}

struct SubAgentDetailView: View {
    let taskID: String
    let fallbackJSON: String?
    @Environment(\.dismiss) private var dismiss
    @State private var task: SubAgentTask?
    // fix73j：运行中打开详情页 → 2s 轮询刷新（实时进度；终态后自动停止）
    @State private var pollTimer: Timer?

    var body: some View {
        NavigationView {
            Group {
                if let task {
                    taskContent(task)
                } else if let fb = fallbackJSON {
                    fallbackContent(SubAgentCompleteCard.parse(fb))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("子代理任务不存在或已过期")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("子代理 \(taskID)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                DispatchQueue.main.async { self.refresh() }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func refresh() {
        let t = SubAgentManager.shared.status(id: taskID)
        task = t
        if let t, !t.isRunning() {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - 完整任务视图（内存中有 task，含轨迹快照）

    private func taskContent(_ t: SubAgentTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SubAgentStatusHeader(task: t)
                SubAgentResultCard(task: t)
                SubAgentTraceList(task: t)
            }
            .padding(16)
        }
    }

    // MARK: - 回退视图（重启后 tasks 丢失，仅消息内摘要）

    private func fallbackContent(_ d: [String: Any]) -> some View {
        let status = SubAgentStatusText.zh(d["status"] as? String ?? "?")
        let agent = d["agent_type"] as? String ?? "?"
        let rounds = d["rounds"] as? Int ?? 0
        let elapsed = d["elapsed_secs"] as? Int ?? 0
        let result = d["result"] as? String ?? ""
        let err = d["error"] as? String ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: status == "done" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(status == "done" ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent).font(.headline)
                        Text("\(status) · \(rounds) 轮 · \(elapsed)s").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
                if !result.isEmpty {
                    Text("最终结果").font(.subheadline).fontWeight(.semibold)
                    Text(result)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(12)
                }
                if !err.isEmpty {
                    Text("错误").font(.subheadline).fontWeight(.semibold)
                    Text(err).font(.footnote).foregroundColor(.red).textSelection(.enabled)
                }
                Text("完整轨迹仅在任务存活期间可查看（App 重启后仅保留此摘要）。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(16)
        }
    }
}

// MARK: - 任务视图子组件（独立 struct 避免大函数类型推断问题）

private struct SubAgentStatusHeader: View {
    let task: SubAgentTask
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.status == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(task.status == .done ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.personaName).font(.headline)
                Text("\(SubAgentStatusText.zh(task.status.rawValue)) · \(task.rounds)/\(task.maxRounds) 轮 · \(Int(task.elapsed))s · send \(task.sendState)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }
}

private struct SubAgentResultCard: View {
    let task: SubAgentTask
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最终结果").font(.subheadline).fontWeight(.semibold)
            Text(task.result.isEmpty ? "(空——子代理未产出交付内容)" : task.result)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(12)
            if !task.error.isEmpty {
                Text("错误: \(task.error)").font(.footnote).foregroundColor(.red).textSelection(.enabled)
            }
        }
    }
}

private struct SubAgentTraceList: View {
    let task: SubAgentTask
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("执行轨迹（\(task.trace.count) 条）")
                .font(.subheadline)
                .fontWeight(.semibold)
            if task.trace.isEmpty {
                Text("无轨迹记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(task.trace.enumerated()), id: \.offset) { _, entry in
                    let role = entry["role"] as? String ?? "?"
                    let content = entry["content"] as? String ?? ""
                    let tool = entry["tool"] as? String ?? ""
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            roleBadge(role, tool: tool)
                            Spacer()
                        }
                        Text(role == "tool" ? String(content.prefix(600)) : content)
                            .font(.caption)
                            .foregroundColor(role == "tool" ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(role == "tool" ? 6 : 12)
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                }
            }
        }
    }

    private func roleBadge(_ role: String, tool: String) -> some View {
        let label: String
        let color: Color
        if role == "system" { label = "系统"; color = .gray }
        else if role == "user" { label = "指令"; color = .blue }
        else if role == "assistant" { label = "模型"; color = .primary }
        else if role == "tool" { label = tool.isEmpty ? "工具" : tool; color = .orange }
        else { label = role; color = .secondary }
        return Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}
