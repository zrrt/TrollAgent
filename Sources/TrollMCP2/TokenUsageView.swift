import SwiftUI

// MARK: - v7.4.0-contextui：上下文占用可视化（对齐 Claude /context、OpenMinis TokenUsageSheet）
// 数据源：SessionStore SQLite 索引（元数据先行秒开）+ 当前会话内存实时估算。
// 注：文案暂硬编码中文（未入 L10n i18n key 体系），后续可补 key。

/// 侧边栏顶部紧凑占用条：当前会话 token / 窗口进度 + 压力分级着色，点击打开详情
struct ContextUsageBar: View {
    @ObservedObject private var store = ConversationStore.shared
    @State private var showDetail = false
    // 对齐 OpenAIClient 默认窗口；有实测窗口时用实测值（RuntimeWindowTracker）
    private var windowTokens: Int {
        RuntimeWindowTracker.shared.measuredWindow(for: ModelStore.shared.defaultConfig?.model ?? "") ?? 128_000
    }

    private var currentTokens: Int {
        guard let idx = store.selectedIndex, idx < store.conversations.count else { return 0 }
        return store.conversations[idx].messages.reduce(0) { $0 + OpenAIClient.estimateTokensStatic($1) }
    }
    private var pct: Double { windowTokens > 0 ? min(1.0, Double(currentTokens) / Double(windowTokens)) : 0 }

    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(spacing: 6) {
                HStack {
                    Text("上下文占用")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(currentTokens / 1000)K / \(windowTokens / 1000)K")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(pct > 0.9 ? .red : pct > 0.75 ? .orange : .secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemGray5))
                        Capsule()
                            .fill(pct > 0.9 ? Color.red : pct > 0.75 ? Color.orange : Color.blue)
                            .frame(width: max(4, geo.size.width * CGFloat(pct)))
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showDetail) {
            CompatNav { TokenUsageDetailView(showsDismissButton: true) }
        }
    }
}

/// 详情面板：当前会话占用 + 全局总览 + 最大会话排行
struct TokenUsageDetailView: View {
    @ObservedObject private var store = ConversationStore.shared
    @Environment(\.presentationMode) private var presentationMode
    var showsDismissButton = false
    private var windowTokens: Int {
        RuntimeWindowTracker.shared.measuredWindow(for: ModelStore.shared.defaultConfig?.model ?? "") ?? 128_000
    }

    @State private var indexRows: [[String: Any]] = []
    @State private var stats: [String: Any] = [:]
    @State private var loaded = false

    private var currentTokens: Int {
        guard let idx = store.selectedIndex, idx < store.conversations.count else { return 0 }
        return store.conversations[idx].messages.reduce(0) { $0 + OpenAIClient.estimateTokensStatic($1) }
    }
    private var currentPct: Double { windowTokens > 0 ? min(1.0, Double(currentTokens) / Double(windowTokens)) : 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                currentCard
                overviewCard
                rankingCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("上下文占用")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if showsDismissButton {
                    Button(L10n.t("i18n_1180")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .onAppear {
            if !loaded {
                loaded = true
                indexRows = SessionStore.shared.listSessions(limit: 8)
                stats = SessionStore.shared.stats()
            }
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前会话")
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack {
                Text("\(currentTokens) tokens")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Text(String(format: "%.1f%%", currentPct * 100))
                    .font(.caption)
                    .foregroundColor(currentPct > 0.9 ? .red : currentPct > 0.75 ? .orange : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5))
                    Capsule()
                        .fill(currentPct > 0.9 ? Color.red : currentPct > 0.75 ? Color.orange : Color.blue)
                        .frame(width: max(4, geo.size.width * CGFloat(currentPct)))
                }
            }
            .frame(height: 8)
            Text("压力分级：<60% 正常 · ≥60% 压缩输出 · ≥75% 激进摘要 · ≥90% 自动 compact")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("总览")
                .font(.subheadline)
                .fontWeight(.semibold)
            HStack(spacing: 0) {
                statCell(title: "会话", value: "\(stats["sessionCount"] as? Int64 ?? 0)")
                statCell(title: "消息", value: "\(stats["totalMessages"] as? Int64 ?? 0)")
                statCell(title: "总 token", value: fmtK(stats["totalTokenEstimate"] as? Int64 ?? 0))
                statCell(title: "最大会话", value: fmtK(stats["maxSessionTokenEstimate"] as? Int64 ?? 0))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最大会话 TOP\(indexRows.count)")
                .font(.subheadline)
                .fontWeight(.semibold)
            ForEach(Array(indexRows.enumerated()), id: \.offset) { i, row in
                HStack {
                    Text("\(i + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Text(row["title"] as? String ?? "")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(fmtK(row["tokenEstimate"] as? Int64 ?? 0))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Text("\(row["messageCount"] as? Int64 ?? 0)条")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if indexRows.isEmpty {
                Text("暂无会话数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fmtK(_ n: Int64) -> String {
        n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }
}
