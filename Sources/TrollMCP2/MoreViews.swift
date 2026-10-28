import SwiftUI
import UniformTypeIdentifiers

struct AuditLogView: View {
    @ObservedObject private var log = AuditLog.shared
    @State private var exportPath: String?
    @State private var showExportAlert = false
    @State private var tab = 0
    @State private var fileLogText = ""
    @State private var sortOrder: SortOrder = .newest
    @State private var sortBy: SortBy = .time
    // v6.0.28：崩溃日志tab
    @State private var crashPaths: [String] = []
    // v4.3.43：Alert 按钮里不再直接 present 分享页（Alert dismiss 转场中 present 会崩溃），
    // 改为先记录待分享路径，等 Alert 完全消失后再由 onChange 触发。
    @State private var pendingSharePath: String?

    enum SortBy { case time, status, elapsed, category }
    enum SortOrder { case newest, oldest }

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "list.bullet.rectangle",
                title: L10n.t("page_audit"),
                subtitle: L10n.t("page_audit_sub"),
                colors: [.tmIndigo, .blue]
            )
            .padding(.vertical, 8)

            // v6.0.28：四 Tab——调用记录 / 健康度（失败归因）/ 文件日志 / 崩溃日志
            Picker("", selection: $tab) {
                Text(L10n.t("ui_135")).tag(0)
                Text(L10n.t("ui_29")).tag(1)
                Text(L10n.t("ui_75")).tag(2)
                Text(L10n.t("i18n_316")).tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            if tab == 0 {
                sortBar
                callLogList
            } else if tab == 1 {
                healthView
            } else if tab == 2 {
                fileLogView
            } else {
                crashLogView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_audit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: exportLog) { Label(L10n.t("btn_export"), systemImage: "square.and.arrow.up") }
                Button(L10n.t("btn_clear")) {
                    if tab == 0 { log.clear() }
                    else if tab == 2 { loadFileLog() }
                    else if tab == 3 { CrashCatcher.clear(); crashPaths = CrashCatcher.list() }
                }
            }
        }
        .onAppear { loadFileLog(); crashPaths = CrashCatcher.list() }
        .alert(isPresented: $showExportAlert) {
            // v4.3.43：Alert 按钮只记录待分享路径，等 Alert dismiss 完成后
            // 由 onChange(showExportAlert) 触发分享——避免在 Alert dismiss 转场中
            // present UIActivityViewController 导致崩溃。
            if let p = exportPath, p.hasPrefix("/") {
                return Alert(title: Text(L10n.t("ui_45")),
                             message: Text(p),
                             primaryButton: .default(Text(L10n.t("i18n_871"))) {
                                 pendingSharePath = p
                             },
                             secondaryButton: .cancel(Text(L10n.t("ui_44"))))
            } else {
                return Alert(title: Text(L10n.t("ui_45")),
                             message: Text(exportPath ?? ""),
                             dismissButton: .default(Text(L10n.t("ui_44"))))
            }
        }
        // v4.3.43：Alert 完全消失后再弹分享页（转场安全）
        .onChange(of: showExportAlert) { shown in
            if !shown, let p = pendingSharePath {
                pendingSharePath = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    SharePresenter.present([URL(fileURLWithPath: p)])
                }
            }
        }
    }

    // v6.0.28：崩溃日志tab
    private var crashLogView: some View {
        List {
            if crashPaths.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(.green)
                        Text(L10n.t("i18n_318"))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(crashPaths, id: \.self) { path in
                    VStack(alignment: .leading, spacing: 4) {
                        Text((path as NSString).lastPathComponent)
                            .font(.body)
                        Text(CrashCatcher.preview(path, maxChars: 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: 排序栏
    private var sortBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.t("i18n_319")) { sortBy = .time }
                Button(L10n.t("i18n_320")) { sortBy = .status }
                Button(L10n.t("i18n_321")) { sortBy = .elapsed }
                Button(L10n.t("i18n_322")) { sortBy = .category }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                    Text(sortByTitle).font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            Button {
                sortOrder = sortOrder == .newest ? .oldest : .newest
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sortOrder == .newest ? "clock.fill" : "clock.arrow.circlepath")
                    Text(sortOrder == .newest ? L10n.t("i18n_856") : L10n.t("i18n_857")).font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var sortByTitle: String {
        switch sortBy {
        case .time: return L10n.t("i18n_325")
        case .status: return L10n.t("ui_110")
        case .elapsed: return L10n.t("i18n_326")
        case .category: return L10n.t("i18n_327")
        }
    }

    private var sortedEntries: [AuditLog.Entry] {
        var result = log.entries
        switch sortBy {
        case .time:
            result.sort { $0.timestamp < $1.timestamp }
        case .status:
            result.sort { ($0.status?.rawValue ?? "zzz") < ($1.status?.rawValue ?? "zzz") }
        case .elapsed:
            result.sort { ($0.elapsedMs ?? 0) < ($1.elapsedMs ?? 0) }
        case .category:
            result.sort { $0.category < $1.category }
        }
        if sortOrder == .newest, sortBy == .time {
            result.reverse()
        } else if sortOrder == .newest, sortBy == .elapsed {
            result.reverse()
        }
        return result
    }

    // MARK: Tab1 调用记录（原列表 + errorCode 徽标）
    private var callLogList: some View {
        List {
            if sortedEntries.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(L10n.t("ui_83"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                }
            } else {
                ForEach(sortedEntries) { entry in
                    if let status = entry.status {
                        Section {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.category)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        // v2.9.128：CLI 错误码徽标（env/target/param/tool）
                                        if status == .failure, let code = entry.errorCode {
                                            Text(code)
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(codeColor(code).opacity(0.15))
                                                .foregroundColor(codeColor(code))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    HStack(spacing: 6) {
                                        Text(status == .success ? L10n.t("i18n_328") : L10n.t("i18n_329"))
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundColor(status == .success ? .green : .red)
                                        if let p = entry.permission, !p.isEmpty {
                                            Text(p)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Text("\(timeString(entry.timestamp))·\(durationLabel(entry.elapsedMs))·\(bytesLabel(entry.dataBytes))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if status == .failure, let reason = entry.errorReason, !reason.isEmpty {
                                        Text(L10n.t("ui_148", reason))
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                            .lineLimit(2)
                                        if let next = entry.nextStep, !next.isEmpty {
                                            Text(L10n.t("ui_149", next))
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                                .lineLimit(2)
                                        }
                                    } else if !entry.detail.isEmpty {
                                        Text(entry.detail)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Image(systemName: status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(status == .success ? .green : .red)
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Section(header: SettingSectionHeader(title: timeString(entry.timestamp))) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.category)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(levelColor(entry.level))
                                    Spacer()
                                    Text(entry.level.rawValue.uppercased())
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(levelColor(entry.level))
                                }
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Tab2 健康度——失败归因（用户/AI 都能看到"哪些工具有问题、为什么"）
    private var healthView: some View {
        let summary = log.healthSummary(limit: 40)
        let dist = log.codeDistribution()
        return List {
            Section(header: SettingSectionHeader(title: L10n.t("i18n_331"))) {
                if dist.isEmpty {
                    Text(L10n.t("ui_82")).font(.footnote).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(dist) { d in
                            HStack(spacing: 4) {
                                Text(d.code)
                                    .font(.caption2).fontWeight(.bold)
                                    .foregroundColor(codeColor(d.code))
                                Text("×\(d.count)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(codeColor(d.code).opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            Section(header: SettingSectionHeader(title: L10n.t("i18n_332"))) {
                if summary.isEmpty {
                    Text(L10n.t("ui_84")).font(.footnote).foregroundColor(.secondary)
                } else {
                    ForEach(summary) { h in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(h.tool)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .fontWeight(.semibold)
                                Spacer()
                                if h.failure > 0 {
                                    Text(L10n.t("ui_150", h.failure))
                                        .font(.caption2).fontWeight(.bold)
                                        .foregroundColor(.red)
                                } else {
                                    Text(L10n.t("ui_30"))
                                        .font(.caption2).fontWeight(.semibold)
                                        .foregroundColor(.green)
                                }
                                Text(String(format: "%.0f%%", h.failureRate * 100))
                                    .font(.caption2)
                                    .foregroundColor(h.failureRate > 0.5 ? .red : (h.failureRate > 0 ? .orange : .green))
                            }
                            HStack(spacing: 6) {
                                Text(L10n.t("ui_151", h.success))
                                    .font(.caption2).foregroundColor(.secondary)
                                Text(L10n.t("ui_152", h.avgMs))
                                    .font(.caption2).foregroundColor(.secondary)
                                if h.failure > 0 {
                                    Text(L10n.t("ui_153", h.topCode))
                                        .font(.caption2).fontWeight(.semibold)
                                        .foregroundColor(codeColor(h.topCode))
                                }
                            }
                            if h.failure > 0 && !h.lastFailureDetail.isEmpty {
                                Text(L10n.t("ui_154", h.lastFailureDetail))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Tab3 文件日志（按天滚动，读当天）
    private var fileLogView: some View {
        ScrollView {
            Text(fileLogText.isEmpty ? L10n.t("i18n_333") : fileLogText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func loadFileLog() {
        let logsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        let file = logsDir.appendingPathComponent("audit-\(df.string(from: Date())).log")
        fileLogText = (try? String(contentsOf: file, encoding: .utf8)) ?? L10n.t("i18n_334")
    }

    private func codeColor(_ code: String) -> Color {
        switch code {
        case "env": return .orange
        case "target": return .red
        case "param": return .purple
        case "tool": return .blue
        default: return .gray
        }
    }

    private func exportLog() {
        let dir = Workspace.root.appendingPathComponent("audit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent("audit_\(df.string(from: Date())).txt")
        var lines: [String] = []
        for e in log.entries {
            let status = e.status?.rawValue ?? e.level.rawValue
            lines.append("[\(timeString(e.timestamp))] \(e.category) | \(status) | \(e.permission ?? "-") | \(e.elapsedMs ?? 0)ms | \(e.dataBytes ?? 0)B | \(e.detail)")
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            exportPath = url.path
            showExportAlert = true
            AuditLog.shared.log("audit.export", detail: url.path)
        } catch {
            exportPath = L10n.t("i18n_335", error.localizedDescription)
            showExportAlert = true
        }
    }

    private func levelColor(_ level: AuditLog.Entry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy, h:mm:ss a"
        return f.string(from: date)
    }

    private func durationLabel(_ ms: Int?) -> String {
        guard let ms = ms else { return "-" }
        return "\(ms) ms"
    }

    private func bytesLabel(_ bytes: Int?) -> String {
        guard let b = bytes else { return "-" }
        if b < 1024 { return "\(b) B" }
        return String(format: "%.1f KB", Double(b) / 1024.0)
    }
}


struct SystemCapabilitiesView: View {
    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "cpu.fill",
                title: L10n.t("page_capabilities"),
                subtitle: L10n.t("page_capabilities_sub"),
                colors: [.tmIndigo, .purple]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_341"))) {
                    capRow(L10n.t("i18n_343"), "calendar.list", "calendar", .red)
                    capRow(L10n.t("i18n_344"), "reminder.create", "checkmark.square", .green)
                    capRow(L10n.t("i18n_345"), "location.get", "location", .tmIndigo)
                }

                Section(header: SettingSectionHeader(title: L10n.t("ui_132"))) {
                    Text(L10n.t("ui_143"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_capabilities"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capRow(_ name: String, _ tool: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text(tool)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 工具权限策略

struct ToolPermissionPoliciesView: View {
    @ObservedObject private var registry = ToolRegistry.shared
    @State private var searchText = ""
    // v2.9.23：并入原"本机工具审计"的真实实现清单（标记哪些工具有真实实现 vs 占位）
    @State private var showOnlyReal = false

    private let realTools: Set<String> = [
        "ping",
        "device.info",
        "device.probe",
        "artifact.read_text",
        "artifact.write_text",
        "artifact.list",
        "assistant.memory_set",
        "assistant.memory_list",
        "assistant.memory_delete",
        "apps.cache_inspect",
        "apps.cache_clear",
        "apps.open",
        "apps.open_and_input",
        "wechat.prepare_message",
        "container.write_text",
        "container.delete",
        "calendar.list",
        "reminder.create",
        "location.get",
        "project.generate_tweak",
        "model.config",
        "model.selectedProfileID",
        "workspace.outputBookmark",
        "workspace.outputName",
        // v2.9.21：注入执行工具真实可用
        "injection.enable",
        "injection.disable",
        "injection.status",
        "injection.inspect",
        "injection.list",
        "injection.remove",
        // v2.9.17：技能真实可用
        "skills.list",
        "skills.read",
        "skills.set_enabled"
    ]

    private var filtered: [ToolDefinition] {
        var defs = registry.definitions
        if showOnlyReal {
            defs = defs.filter { realTools.contains($0.name) }
        }
        if searchText.isEmpty { return defs }
        return defs.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.summary.localizedCaseInsensitiveContains(searchText) }
    }

    /// category 显示中文名
    private let categoryNames: [String: String] = [
        "injection": L10n.t("i18n_349"),
        "app_control": L10n.t("i18n_1095"),
        "ui_control": L10n.t("i18n_1096"),
        "device": L10n.t("i18n_350"),
        "filesystem": L10n.t("i18n_351"),
        "shell": "💻 Shell",
        "browser": L10n.t("i18n_352"),
        "build": L10n.t("i18n_353"),
        "backup": L10n.t("i18n_354"),
        "cleanup": L10n.t("i18n_355"),
        "macro": L10n.t("i18n_356"),
        "knowledge": L10n.t("i18n_357"),
        "system": L10n.t("i18n_358"),
        "diagnose": L10n.t("i18n_359"),
        "analysis": L10n.t("i18n_360"),
        "automation": L10n.t("i18n_361"),
        "skills": L10n.t("i18n_362"),
        "debug": L10n.t("i18n_363"),
        "misc": L10n.t("i18n_364"),
    ]

    /// 固定 category 排序
    private let categoryOrder: [String] = [
        "injection", "app_control", "ui_control", "device",
        "filesystem", "shell", "browser",
        "build", "backup", "cleanup",
        "diagnose", "analysis", "automation",
        "macro", "knowledge", "system",
        "skills", "debug", "misc",
    ]

    /// 按 category 分组，保持固定顺序
    private var groupedByCategory: [(category: String, label: String, tools: [ToolDefinition])] {
        let groups = Dictionary(grouping: filtered, by: { $0.category })
        var result: [(String, String, [ToolDefinition])] = []
        for cat in categoryOrder {
            if let tools = groups[cat], !tools.isEmpty {
                result.append((cat, categoryNames[cat] ?? cat, tools))
            }
        }
        // 未知 category 兜底
        for (cat, tools) in groups where !categoryOrder.contains(cat) {
            result.append((cat, categoryNames[cat] ?? cat, tools))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "lock.shield.fill",
                title: L10n.t("page_tool_policy"),
                subtitle: L10n.t("page_tool_policy_sub"),
                colors: [.green, .tmTeal]
            )
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                TextField(L10n.t("i18n_365"), text: $searchText)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            List {
                Section {
                    NavigationLink(destination: SystemCapabilitiesView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("i18n_1192"))
                                    .foregroundColor(.primary)
                                Text(L10n.t("i18n_366"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    NavigationLink(destination: AutomationCenterView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("i18n_1193"))
                                    .foregroundColor(.primary)
                                Text(L10n.t("i18n_367"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_368"))) {
                    // v2.9.31：工具按需加载——初始请求只带常驻核心（标★），其余靠搜索加载；
                    // v2.9.32：去掉授权弹窗，AI 搜索到工具即自动放行本会话。
                    // v2.9.36：去掉开关——勾选不再影响速度与放行，此页改为只读清单。
                    Text(L10n.t("ui_32"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // v2.9.23：并入原"本机工具审计"的过滤
                Section(header: SettingSectionHeader(title: L10n.t("i18n_369"))) {
                    Toggle(L10n.t("i18n_370"), isOn: $showOnlyReal)
                        .accentColor(.tmCyan)
                    Text(L10n.t("ui_17"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_371", filtered.count))) {
                    Text(L10n.t("i18n_372", groupedByCategory.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(groupedByCategory, id: \.category) { group in
                    Section(header: SettingSectionHeader(title: "\(group.label)（\(group.tools.count)）")) {
                        ForEach(group.tools, id: \.name) { def in
                            let isCore = registry.isCore(def.name)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(isCore ? "★ " : "")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.blue)
                                        + Text(def.name)
                                            .font(.system(.body, design: .monospaced))
                                        Text(realTools.contains(def.name) ? L10n.t("i18n_373") : L10n.t("i18n_313"))
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background((realTools.contains(def.name) ? Color.green : Color.orange).opacity(0.15))
                                            .foregroundColor(realTools.contains(def.name) ? .green : .orange)
                                            .cornerRadius(4)
                                        // v2.9.252: 真机 HTTP 实测通过的工具加 ✅已检验 徽标
                                        if def.verified {
                                            Text(L10n.t("i18n_374"))
                                                .font(.caption2)
                                                .fontWeight(.medium)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color(red: 0.25, green: 0.65, blue: 0.35).opacity(0.15))
                                                .foregroundColor(Color(red: 0.25, green: 0.65, blue: 0.35))
                                                .cornerRadius(4)
                                        }
                                    }
                                    Text(def.displaySummary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                // v2.9.36：去掉开关——按需加载下勾选已无实际作用（AI 搜索到即可调用）。
                                // 常驻核心标 ★，其余由 AI 按需搜索加载。
                                if isCore {
                                    Text(L10n.t("ui_56"))
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(6)
                                } else {
                                    Text(L10n.t("ui_70"))
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(6)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_tool_policy"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据管理

struct DataManagementView: View {
    @State private var files: [WorkspaceItem] = []
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "internaldrive.fill",
                title: L10n.t("page_data"),
                subtitle: L10n.t("page_data_sub"),
                colors: [.green, .tmTeal]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_1040"))) {
                    LabeledRow(label: L10n.t("i18n_948"), value: Workspace.root.path)
                    SettingRowButton(
                        title: L10n.t("i18n_377"),
                        subtitle: L10n.t("i18n_1097"),
                        icon: "folder",
                        color: .blue
                    ) {
                        AuditLog.shared.log("data.open_workspace", detail: Workspace.root.path)
                    }
                    SettingRowButton(
                        title: L10n.t("i18n_378"),
                        subtitle: L10n.t("i18n_1098"),
                        icon: "trash",
                        color: .red
                    ) {
                        try? FileManager.default.removeItem(at: Workspace.root)
                        Workspace.ensure()
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_1048"))) {
                    ForEach(files) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.body)
                                Text(item.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            try? FileManager.default.removeItem(at: files[i].url)
                        }
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("ui_48"))) {
                    SettingRowButton(
                        title: L10n.t("i18n_380"),
                        subtitle: L10n.t("i18n_381"),
                        icon: "doc.badge.plus",
                        color: .green
                    ) {
                        showingImporter = true
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            }
            .sheet(isPresented: $showingImporter) {
                DocumentImporter { url in
                    _ = try? FileManager.default.copyItem(at: url, to: Workspace.root.appendingPathComponent(url.lastPathComponent))
                    refresh()
                }
            }
            .onAppear(perform: refresh)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_data"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() {
        Workspace.ensure()
        var items: [WorkspaceItem] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    items.append(WorkspaceItem(name: url.lastPathComponent, size: byteString(size), url: url))
                }
            }
        }
        files = items.sorted { $0.name < $1.name }
    }

    private func byteString(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

struct WorkspaceItem: Identifiable {
    var id = UUID()
    let name: String
    let size: String
    let url: URL
}

// MARK: - 文档导入器

struct DocumentImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.first.map(onPick)
        }
    }
}

// MARK: - 开发者指令（v2.9.19：可自建/编辑/设默认）

struct DeveloperInstructionsView: View {
    @State private var items: [DeveloperInstructionStore.Item] = []
    @State private var editing: DevInstrEditorPayload?
    @State private var creating = false
    // v2.9.24：一键复制提示
    @State private var copiedName: String?

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "doc.text.magnifyingglass",
                title: L10n.t("page_dev_instr"),
                subtitle: L10n.t("page_dev_instr_sub"),
                colors: [.orange, .tmBrown]
            )
            .padding(.vertical, 8)

            List {
                // 破甲测试说明卡
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.t("i18n_382"), systemImage: "hammer.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.orange)
                        Text(L10n.t("i18n_383"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(L10n.t("i18n_384"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if items.isEmpty {
                    Section {
                        Text(L10n.t("ui_136"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                // 开关按钮
                                Button(action: { toggleEnabled(item) }) {
                                    Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24))
                                        .foregroundColor(item.enabled ? .tmCyan : Color(.systemGray4))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(BorderlessButtonStyle())

                                Text(item.name)
                                    .font(.body)
                                    .foregroundColor(item.enabled ? .primary : .secondary)
                                Spacer()
                                // 一键复制按钮
                                Button(action: { copyItem(item) }) {
                                    Image(systemName: copiedName == item.name ? "checkmark" : "doc.on.doc")
                                        .font(.subheadline)
                                        .foregroundColor(copiedName == item.name ? .green : .blue)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            Text(preview(item.content))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        // v3.1.10: 去掉外层 onTapGesture——会吃掉按钮的点击事件
                        // 点开关按钮直接 toggle，点其他地方用 contextMenu 编辑
                        .contextMenu {
                            Button(action: { copyItem(item) }) {
                                Label(L10n.t("i18n_385"), systemImage: "doc.on.doc")
                            }
                            Button(action: {
                                editing = DevInstrEditorPayload(name: item.name, content: item.content)
                            }) {
                                Label(L10n.t("i18n_386"), systemImage: "pencil")
                            }
                            Button(action: { remove(item) }) {
                                Label(L10n.t("ui_195"), systemImage: "trash")
                            }
                        }
                    }
                    Section {
                        Text(L10n.t("i18n_387"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onAppear(perform: reload)
            .toolbar {
                Button(action: { creating = true }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { payload in
                DevInstructionEditorView(name: payload.name, initialContent: payload.content, mode: .edit)
            }
            .sheet(isPresented: $creating) {
                DevInstructionEditorView(name: "", initialContent: "", mode: .create)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_dev_instr"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func preview(_ c: String) -> String {
        let lines = c.split(separator: "\n").map(String.init)
        // 取第一个非空、非标题行作摘要
        for ln in lines {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") { return String(t.prefix(60)) }
        }
        return c.isEmpty ? L10n.t("i18n_388") : String(c.prefix(60))
    }

    private func reload() {
        items = DeveloperInstructionStore.shared.list()
    }

    private func makeDefault(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.setDefault(name: item.name)
        reload()
    }

    /// v2.9.20：复制指令内容到剪贴板
    private func copyItem(_ item: DeveloperInstructionStore.Item) {
        UIPasteboard.general.string = item.content
        // v2.9.24：复制成功反馈（图标变绿 checkmark，1.5s 后恢复）
        withAnimation { copiedName = item.name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedName == item.name {
                withAnimation { copiedName = nil }
            }
        }
    }

    private func toggleEnabled(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.setEnabled(name: item.name, enabled: !item.enabled)
        reload()
    }

    private func remove(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.delete(name: item.name)
        reload()
    }
}

struct DevInstrEditorPayload: Identifiable {
    var id: String { name }
    let name: String
    let content: String
}

struct DevInstructionEditorView: View {
    enum Mode { case create, edit }
    let name: String
    let initialContent: String
    let mode: Mode

    @State private var title = ""
    @State private var content = ""
    @State private var keyboardHeight: CGFloat = 0
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            // v2.9.22：Form 里 TextEditor 滚动冲突/键盘遮挡导致"难往下滑"，
            // 改为 ScrollView + 大高度 TextEditor + 键盘高度避让
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: L10n.t("i18n_390"))
                        TextField(L10n.t("i18n_391"), text: $title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: L10n.t("i18n_1099"))
                        TextEditor(text: $content)
                            .frame(minHeight: 520)
                            .font(.system(.body, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color(.separator), lineWidth: 0.5)
                            )
                            .cornerRadius(10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: L10n.t("ui_132"))
                        Text(L10n.t("ui_145"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // v3.3.0：隐藏标记说明——标记内的内容只给用户看，不注入 AI
                        Text(L10n.t("i18n_392"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // v2.9.22：iOS14 兼容的收起键盘按钮
                    Button(action: hideKeyboard) {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard.chevron.compact.down")
                            Text(L10n.t("ui_74"))
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding()
                // 键盘弹出时底部留白，确保能滚到末尾
                .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 16 : 24)
            }
            .navigationTitle(mode == .create ? L10n.t("i18n_393") : L10n.t("i18n_394"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_40")) { presentationMode.wrappedValue.dismiss() }
                }
                // v2.9.24：编辑时一键复制当前内容
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: copyContent) {
                            Image(systemName: "doc.on.doc")
                        }
                        Button(L10n.t("i18n_1166")) { save() }
                    }
                }
            }
            .onAppear {
                if mode == .edit && title.isEmpty {
                    title = name
                    content = initialContent
                }
                observeKeyboard()
            }
        }
        .navigationViewStyle(.stack)
    }

    /// v2.9.22：监听键盘高度（iOS14 兼容，不用 scrollDismissesKeyboard）
    private func observeKeyboard() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            if let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height {
                keyboardHeight = h
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            keyboardHeight = 0
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .create {
            DeveloperInstructionStore.shared.create(name: trimmed, content: content)
        } else {
            DeveloperInstructionStore.shared.update(name: trimmed, content: content)
        }
        presentationMode.wrappedValue.dismiss()
    }

    /// v2.9.24：编辑器一键复制当前内容
    private func copyContent() {
        UIPasteboard.general.string = content
    }
}

// MARK: - 本机知识库

struct KnowledgeBaseView: View {
    @State private var files: [WorkspaceItem] = []
    @State private var showingImporter = false
    @State private var showingClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "books.vertical.fill",
                title: L10n.t("page_kb"),
                subtitle: L10n.t("page_kb_sub"),
                colors: [.tmBrown, .orange]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_395"))) {
                    SettingRowButton(
                        title: L10n.t("i18n_396"),
                        subtitle: "Markdown / TXT / JSON / PDF",
                        icon: "doc.badge.plus",
                        color: .blue
                    ) {
                        showingImporter = true
                    }
                    SettingRowButton(
                        title: L10n.t("i18n_397"),
                        subtitle: L10n.t("i18n_1100"),
                        icon: "folder.badge.plus",
                        color: .green
                    ) {
                        importFromWorkspace()
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_398"))) {
                    if files.isEmpty {
                        Text(L10n.t("ui_89"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(files) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet {
                                try? FileManager.default.removeItem(at: files[i].url)
                            }
                            refresh()
                        }
                    }

                    Button {
                        showingClearConfirm = true
                    } label: {
                        Label(L10n.t("i18n_399"), systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .disabled(files.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            }
            .sheet(isPresented: $showingImporter) {
                DocumentImporter { url in
                    let dest = knowledgeBaseDir.appendingPathComponent(url.lastPathComponent)
                    _ = try? FileManager.default.copyItem(at: url, to: dest)
                    refresh()
                }
            }
            .confirmationDialog(L10n.t("i18n_400"), isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button(L10n.t("i18n_399"), role: .destructive) {
                    clearAll()
                }
                Button(L10n.t("ui_40"), role: .cancel) {}
            }
            .onAppear(perform: refresh)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_kb"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var knowledgeBaseDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func refresh() {
        var items: [WorkspaceItem] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: knowledgeBaseDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                items.append(WorkspaceItem(name: url.lastPathComponent, size: byteString(size), url: url))
            }
        }
        files = items.sorted { $0.name < $1.name }
    }

    /// v3.6.19l：清空已导入的全部知识库文件
    private func clearAll() {
        let fm = FileManager.default
        for file in files {
            try? fm.removeItem(at: file.url)
        }
        refresh()
    }

    private func importFromWorkspace() {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let dest = knowledgeBaseDir.appendingPathComponent(url.lastPathComponent)
                _ = try? fm.copyItem(at: url, to: dest)
            }
        }
        refresh()
    }

    private func byteString(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

// MARK: - Webhooks 设置

struct WebhooksView: View {
    @State private var url = ""
    @State private var secret = ""
    @State private var events = ""
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "link.circle.fill",
                title: L10n.t("page_webhooks"),
                subtitle: L10n.t("page_webhooks_sub"),
                colors: [.purple, .tmIndigo]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_961"))) {
                    editorRow("URL", text: $url, placeholder: "https://example.com/webhook")
                    editorRow("Secret", text: $secret, placeholder: L10n.t("i18n_402"))
                    editorRow(L10n.t("i18n_403"), text: $events, placeholder: "audit,tool_call")
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_906"))) {
                    Button(action: save) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                            Text(L10n.t("ui_28"))
                                .foregroundColor(.blue)
                        }
                    }
                    Button(action: test) {
                        HStack {
                            Image(systemName: "paperplane")
                            Text(L10n.t("ui_39"))
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                }

                if !status.isEmpty {
                    Section(header: SettingSectionHeader(title: L10n.t("ui_110"))) {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_webhooks"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        UserDefaults.standard.set(["url": url, "secret": secret, "events": events], forKey: "trollmcp2.webhook")
        status = L10n.t("i18n_405")
    }

    private func test() {
        guard let target = URL(string: url), !url.isEmpty else {
            status = L10n.t("i18n_1101")
            return
        }
        var req = URLRequest(url: target, timeoutInterval: 15)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["event": "test", "timestamp": ISO8601DateFormatter().string(from: Date()), "app": "TrollAgent"] as [String: Any]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    status = L10n.t("i18n_951", error.localizedDescription)
                } else if let http = response as? HTTPURLResponse {
                    status = "HTTP \(http.statusCode)"
                } else {
                    status = L10n.t("i18n_407")
                }
            }
        }.resume()
    }
}

// MARK: - Agents 与 Skills

struct AgentsAndSkillsView: View {
    @State private var skills: [SkillItem] = []
    @State private var agents: [AgentItem] = []
    @State private var showSkillEditor = false
    @State private var showAgentEditor = false

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "person.2.fill",
                title: L10n.t("page_agents"),
                subtitle: L10n.t("page_agents_sub"),
                colors: [.tmCyan, .blue]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: "Skills")) {
                    if skills.isEmpty {
                        Text(L10n.t("ui_87"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(skills) { s in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                        .font(.body)
                                        .foregroundColor(SkillStore.shared.isEnabled(s.name) ? .primary : .secondary)
                                    Text(s.summary.isEmpty ? s.instruction : s.summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { SkillStore.shared.isEnabled(s.name) },
                                    set: { SkillStore.shared.setEnabled(s.name, $0); reload() }
                                ))
                                .labelsHidden()
                                .accentColor(.tmCyan)
                                .frame(width: 46)
                                Button(action: {
                                    SkillStore.shared.delete(named: s.name)
                                    reload()
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "Agents")) {
                    if agents.isEmpty {
                        Text(L10n.t("ui_91"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(agents) { a in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name)
                                        .font(.body)
                                    Text(a.systemPrompt)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("ui_132"))) {
                    Text(L10n.t("ui_67"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_2"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .onAppear {
                SkillStore.shared.seedIfEmpty()
                reload()
            }
            .toolbar {
                Button(action: { showSkillEditor = true }) { Image(systemName: "plus.square.on.square") }
                Button(action: { showAgentEditor = true }) { Image(systemName: "person.badge.plus") }
            }
            .sheet(isPresented: $showSkillEditor) { SkillEditorView() }
            .sheet(isPresented: $showAgentEditor) { AgentEditorView() }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_agents"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reload() {
        skills = SkillStore.shared.all
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        if let data = try? Data(contentsOf: kb.appendingPathComponent("agents.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            agents = json.map { AgentItem(name: $0["name"] ?? "", systemPrompt: $0["systemPrompt"] ?? "") }
        }
    }
}

struct AgentItem: Identifiable {
    var id = UUID()
    let name: String
    let systemPrompt: String
}
