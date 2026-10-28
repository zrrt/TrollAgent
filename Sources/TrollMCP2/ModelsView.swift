import SwiftUI
import UIKit   // v2.9.85：UIPasteboard 复制推荐链接
import UniformTypeIdentifiers  // v2.9.107：配置导入/导出

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var editing: ModelConfig?
    @State private var isNewModel = false
    // v2.9.107：用量统计 / 导入导出
    @State private var showingUsage = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc: ConfigDoc?
    @State private var importMessage = ""
    @State private var showImportMessage = false

    var body: some View {
        VStack(spacing: 0) {
            // v4.3.27：推荐卡片区——全宽直达外框（去掉 insetGrouped 内框），
            // 顺序：推荐破甲站第一、推荐中转站第二（用户要求）；面板加大加宽。
            RecommendCardArea()

            List {
                if store.configs.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text(L10n.t("ui_50"))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 40)
                            Spacer()
                        }
                    }
                } else {
                    // v2.9.107：按分组展示（默认组优先，其余按字典序）
                    let groups = groupedKeys()
                    ForEach(groups, id: \.self) { g in
                        Section(header: HStack {
                            Text(g)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(L10n.t("ui_155", count(in: g)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }) {
                            ForEach(configs(in: g)) { cfg in
                                ModelRow(config: cfg)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        isNewModel = false
                                        editing = cfg
                                    }
                            }
                            .onDelete { offsets in delete(in: g, at: offsets) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(L10n.t("i18n_1102"))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // v2.9.108：从剪贴板粘贴导入（借鉴 cc-switch ccswitch:// 一键导入思路，零 URL Scheme 风险）
                Button(action: importFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                }
                .help(L10n.t("i18n_408"))
                Button(action: { showingUsage = true }) {
                    Image(systemName: "chart.bar.fill")
                }
                .help(L10n.t("i18n_409"))
                Button(action: {
                    isNewModel = true
                    editing = ModelConfig(name: "", provider: "custom", apiProtocol: "OpenAI Chat Completions", baseURL: "", apiKey: "", model: "")
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        // v2.9.180: 用量统计用 fullScreenCover，避免 iOS 14 多 sheet 冲突闪退
        .fullScreenCover(isPresented: $showingUsage) {
            UsageStatsView()
        }
        .sheet(item: $editing, onDismiss: { editing = nil }) { cfg in
            // v2.9.14：改用 .sheet(item:) 绑定。iOS14 的 .sheet(isPresented:)+闭包捕获
            // 存在时序竞争——sheet 内容首次构建可能读到旧 editing(nil)，先用默认预设渲染，
            // 之后才切到真实配置（表现为"先显示 gpt-4o，很久才变成 5.6"）。
            // .sheet(item:) 在 item 变化时以新值重建内容，机制上消除该问题。
            // 注：iOS 14.0-14.4 多 sheet 只生效最后一个声明，因此编辑弹窗必须放最后。
            ModelEditorView(config: isNewModel ? nil : cfg) { newCfg in
                if ModelStore.shared.configs.contains(where: { $0.id == newCfg.id }) {
                    ModelStore.shared.update(newCfg)
                } else {
                    ModelStore.shared.add(newCfg)
                }
            }
            .id(cfg.id)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let r = store.importJSON(text)
                        if r.failed > 0 {
                            importMessage = L10n.t("i18n_411", r.ok, r.failed)
                        } else {
                            importMessage = L10n.t("i18n_412", r.ok)
                        }
                    } else {
                        importMessage = L10n.t("i18n_413")
                    }
                } else {
                    importMessage = L10n.t("i18n_414")
                }
            case .failure:
                importMessage = L10n.t("i18n_415")
            }
            showImportMessage = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDoc, contentType: .json, defaultFilename: "TrollAgent-models-\(Date().timeIntervalSince1970)") { _ in }
        .alert(isPresented: $showImportMessage) {
            Alert(title: Text(L10n.t("ui_100")), message: Text(importMessage), dismissButton: .default(Text(L10n.t("ui_44"))))
        }
    }

    /// v2.9.108：从剪贴板粘贴 JSON 导入（分享链接/文本一键导入）
    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importMessage = L10n.t("i18n_416")
            showImportMessage = true
            return
        }
        let r = store.importJSON(text)
        importMessage = r.failed > 0
            ? L10n.t("i18n_411", r.ok, r.failed)
            : L10n.t("i18n_412", r.ok)
        showImportMessage = true
    }

    // MARK: v2.9.107 分组辅助

    private func groupedKeys() -> [String] {
        var seen: [String] = []
        for c in store.configs where !seen.contains(c.group) { seen.append(c.group) }
        return seen.sorted {
            if $0 == L10n.t("ui_144") { return true }
            if $1 == L10n.t("ui_144") { return false }
            return $0 < $1
        }
    }

    private func configs(in group: String) -> [ModelConfig] {
        store.configs.filter { $0.group == group }
    }

    private func count(in group: String) -> Int {
        store.configs.filter { $0.group == group }.count
    }

    private func delete(in group: String, at offsets: IndexSet) {
        for i in offsets {
            let list = configs(in: group)
            if i < list.count, let idx = store.configs.firstIndex(where: { $0.id == list[i].id }) {
                store.delete(at: IndexSet(integer: idx))
            }
        }
    }
}

struct ModelRow: View {
    let config: ModelConfig
    // v2.9.107：行内测速 + 熔断状态 + 一键切换
    @State private var testing = false
    @State private var latencyText = ""
    @State private var latencyColor: Color = .secondary

    var body: some View {
        let info = ModelStore.shared.breaker(for: config.id).stateInfo
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor(for: info.state))
                    .frame(width: 34, height: 34)
                Image(systemName: info.state == .open ? "bolt.slash" : "cpu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    // v7.1.109-peers：视觉能力标记（对齐 OpenMinis 模型列表图片小图标）——
                    // 数据源 supportsVision = 动态学习记录优先 + 静态规则兜底
                    if config.supportsVision {
                        Image(systemName: "photo")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.blue)
                            .accessibilityLabel("Vision")
                    }
                    if config.isDefault {
                        Text(L10n.t("ui_144"))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    if info.state != .closed {
                        Text(info.state.label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(iconColor(for: info.state).opacity(0.15))
                            .foregroundColor(iconColor(for: info.state))
                            .cornerRadius(4)
                    }
                }
                Text("\(config.provider.capitalized) · \(config.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !latencyText.isEmpty {
                    Text(latencyText)
                        .font(.caption2)
                        .foregroundColor(latencyColor)
                }
            }
            Spacer()
            Button(action: speedTest) {
                if testing {
                    ProgressView()
                } else {
                    Image(systemName: "gauge")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(testing)
            // v2.9.108：复制为副本（借鉴 cc-switch provider duplicate）
            Button(action: duplicate) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.purple)
            }
            .buttonStyle(.plain)
            // v2.9.126：分享深链——trollagent://import?...，对方点链接即可导入
            // v4.3.48：ShareLink 在本设备侧载环境触发 ShareSheet → MobileIcons/CoreImage
            // SIGSEGV（崩溃栈实证），统一改自建分享菜单（拷贝/存储到文件）
            Button(action: {
                ShareCenter.shared.presentShareMenuText(makeDeepLink())
            }) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.teal)
            }
            .buttonStyle(.plain)
            if !config.isDefault {
                Button(action: activate) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func iconColor(for state: CircuitState) -> Color {
        switch state {
        case .closed: return Color.blue
        case .halfOpen: return Color.orange
        case .open: return Color.red
        }
    }

    /// v2.9.107：一键切换为当前使用模型
    private func activate() {
        var c = config
        c.isDefault = true
        ModelStore.shared.update(c)
        ModelStore.shared.markUsed(config.id.uuidString)
        ModelStore.shared.breaker(for: config.id).reset()
    }

    /// v2.9.108：复制为副本（快速起一个新配置改参数，借鉴 cc-switch duplicate）
    private func duplicate() {
        var c = config
        c.id = UUID()
        c.name = config.name + L10n.t("i18n_417")
        c.isDefault = false
        ModelStore.shared.add(c)
        AuditLog.shared.log("model.duplicate", detail: config.name)
    }

    /// v2.9.126：生成导入深链（v4.3.42 改为纯函数，由 ShareLink/按钮调用）
    private func makeDeepLink() -> String {
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var link = "trollagent://import?baseURL=\(enc(config.baseURL))&model=\(enc(config.model))&name=\(enc(config.name))"
        if !config.apiKey.isEmpty { link += "&apiKey=\(enc(config.apiKey))" }
        link += "&auth=\(enc(config.authMethod))&group=\(enc(config.group))&protocol=\(enc(config.apiProtocol))"
        if config.temperature != 0.2 { link += "&temperature=\(config.temperature)" }
        if config.maxTokens != 16384 { link += "&maxTokens=\(config.maxTokens)" }
        if config.contextTokens != 16000 { link += "&contextTokens=\(config.contextTokens)" }
        return link
    }

    /// v2.9.107：供应商测速（GET /models，8s 超时）
    private func speedTest() {
        testing = true
        latencyText = ""
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            latencyText = L10n.t("i18n_1103")
            latencyColor = .red
            testing = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                testing = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    latencyText = L10n.t("i18n_418", ms)
                    latencyColor = .red
                } else {
                    latencyText = L10n.t("i18n_1104", ms)
                    latencyColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - v4.3.28 推荐卡片区（圆角 + 距屏幕边缘留空隙；破甲站第一、中转站第二）
// 说明：卡片保持移出 List 内框（无分组白框），但恢复圆角并左右留边距，
// 渐变卡片距屏幕边缘约 16pt，视觉上不再贴边。

struct RecommendCardArea: View {
    var body: some View {
        VStack(spacing: 10) {
            // 推荐破甲站（第一张）
            RecommendCard(
                icon: "shield.fill",
                title: L10n.t("armor_card_title"),
                message: L10n.t("armor_card_body"),
                link: "https://caibaizz.xyz/register?aff=9MBDRSGSARN7",
                colors: [Color(red: 0.55, green: 0.28, blue: 0.85),
                         Color(red: 0.86, green: 0.30, blue: 0.55)])
            // 推荐中转站（第二张）
            RecommendCard(
                icon: "sparkles",
                title: L10n.t("relay_card_title"),
                message: L10n.t("relay_card_body"),
                link: "https://botcf.com/register?aff=bJMk",
                colors: [Color(red: 0.16, green: 0.44, blue: 0.92),
                         Color(red: 0.0, green: 0.74, blue: 0.95)])
        }
        .padding(.horizontal, 16)   // v4.3.28：左右距屏幕边缘留空隙
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// 通用推荐卡片：圆角渐变背景 + 距边缘空隙，标题+正文+可复制链接
/// 注意：正文属性命名 message——不能叫 body（与 View.body 计算属性重名，编译报
/// "invalid redeclaration of 'body'"，CI 实测踩坑）。
struct RecommendCard: View {
    let icon: String
    let title: String
    let message: String
    let link: String
    let colors: [Color]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
            }
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(link)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = link
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Label(copied ? L10n.t("relay_card_copied") : L10n.t("relay_card_copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(copied ? .white : Color(red: 0.82, green: 0.95, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)   // v4.3.28：卡片圆角（不再贴边直角）
    }
}

// MARK: - 模型 API 编辑器（原版风格）

struct ModelEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    let config: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var name: String
    @State private var provider: String
    @State private var apiProtocol: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var authMethod: String
    @State private var isDefault: Bool
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var contextTokens: Int
    @State private var group: String
    /// v3.5.13：参数名别名映射编辑（"标准键:供应商键"逗号分隔，如 max_tokens:max_completion_tokens）
    @State private var paramAliasesText: String
    /// v7.1.107：备用模型组（失败自动切换）——主模型请求失败时按序切换，见 OpenAIClient fallback
    @State private var fallbackIDs: [UUID]

    @State private var showKey = false
    @State private var showingQuickPicker = false
    @State private var testStatus = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var fetchedModels: [String] = []
    @State private var showingModelPicker = false
    @State private var savedFlag = false

    private let providers = ["openai", "deepseek", "anthropic", "custom"]

    // 在 init 中一次性初始化，避免 iOS 14 上 .onAppear 重复触发把用户输入冲回默认值
    init(config: ModelConfig?, onSave: @escaping (ModelConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let p = ModelConfig.providerPresets.first
        _name = State(initialValue: config?.name ?? (p?.name ?? ""))
        _provider = State(initialValue: config?.provider ?? (p?.provider ?? "custom"))
        _apiProtocol = State(initialValue: config?.apiProtocol ?? (p?.protocol ?? "OpenAI Chat Completions"))
        _baseURL = State(initialValue: config?.baseURL ?? (p?.baseURL ?? ""))
        _apiKey = State(initialValue: config?.apiKey ?? "")
        _model = State(initialValue: config?.model ?? (p?.model ?? ""))
        _authMethod = State(initialValue: config?.authMethod ?? (p?.auth ?? "Bearer"))
        _isDefault = State(initialValue: config?.isDefault ?? false)
        _temperature = State(initialValue: config?.temperature ?? 0.2)
        _maxTokens = State(initialValue: config?.maxTokens ?? 16384)
        _contextTokens = State(initialValue: config?.contextTokens ?? 16000)
        _group = State(initialValue: config?.group ?? L10n.t("ui_144"))
        _paramAliasesText = State(initialValue: ModelEditorView.aliasesString(config?.paramAliases))
        _fallbackIDs = State(initialValue: config?.fallbackIDs ?? [])
    }

    var body: some View {
        CompatNav {
            List {
                Section(header: sectionHeader(apiProtocol.uppercased())) {
                    quickConfigRow
                    editorRow(L10n.t("i18n_919"), text: $name, placeholder: "Botcf")
                    pickerRow(L10n.t("i18n_1105"), selection: $apiProtocol, options: ModelConfig.apiProtocols)
                }

                Section(header: sectionHeader(L10n.t("i18n_1106"))) {
                    editorRow("Base URL", text: $baseURL, placeholder: "https://botcf.com/v1")
                    editorRow(L10n.t("i18n_421"), text: $model, placeholder: "gpt-5.6-terra")
                    pickerRow(L10n.t("i18n_422"), selection: $authMethod, options: ModelConfig.authMethods)
                    // v7.2.3-fix6：新手友好——预设供应商已自动带正确鉴权（选预设即自动填）；
                    // 401 时会自动试探纠正，这里只作说明
                    Text(L10n.t("ui_auth_method_hint"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    tokenRow
                    // v6.1.5-14bk：参数别名/分组 UI 移除（用户看不懂也不需要填）——
                    // 别名兼容由 OpenAIClient compatLevel 0-4 自动降级覆盖，分组默认"默认"即可
                }

                // v7.1.107：备用模型组——主模型请求失败（网络/超时/鉴权/熔断/5xx 且未产出内容）
                // 自动按序切换重发。对齐 OpenMinis 组路由 fallback 思想。
                Section(header: sectionHeader("备用模型（失败自动切换）")) {
                    let others = ModelStore.shared.configs.filter { $0.id != (config?.id ?? UUID()) }
                    if others.isEmpty {
                        Text("先保存其他模型配置，再回来勾选备用模型")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(others) { m in
                        Toggle(isOn: Binding(
                            get: { fallbackIDs.contains(m.id) },
                            set: { on in
                                if on {
                                    if !fallbackIDs.contains(m.id) { fallbackIDs.append(m.id) }
                                } else {
                                    fallbackIDs.removeAll { $0 == m.id }
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                    .font(.subheadline)
                                Text(m.model)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // v6.1.5-14bi：参数(Temperature/Max Tokens/上下文预算)不再让用户填——
                // 按行业标准默认值自动生效(参考Codex等AI同行)：temperature 0.7 / maxTokens 2048 / 上下文预算默认，
                // 保存时沿用默认值，无需手动配置

                Section(header: sectionHeader(L10n.t("i18n_906"))) {
                    Button(action: fetchUpstreamModels) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                            Text(L10n.t("ui_128"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting && fetchedModels.isEmpty {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    Button(action: saveOnly) {
                        Text(L10n.t("ui_26"))
                            .foregroundColor(.blue)
                    }

                    Button(action: saveAndTest) {
                        HStack {
                            Text(L10n.t("ui_27"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    // v2.9.107：测速（只测延迟，不保存）
                    Button(action: speedTestOnly) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                            Text(L10n.t("ui_105"))
                                .foregroundColor(.orange)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                }

                if savedFlag {
                    Section(header: sectionHeader(L10n.t("ui_110"))) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L10n.t("ui_52"))
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                if !testStatus.isEmpty {
                    Section(header: sectionHeader(L10n.t("i18n_423"))) {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundColor(testColor)
                    }
                }

                Section(header: sectionHeader(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_138"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(config == nil ? L10n.t("i18n_424") : name)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_40")) { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { saveOnly() }
                }
            }
            .sheet(isPresented: $showingQuickPicker) {
                QuickConfigPicker { applyPreset(name: $0) }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(models: fetchedModels, selected: $model)
            }
        }
    }

    // MARK: - 子视图

    private var quickConfigRow: some View {
        Button(action: { showingQuickPicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                Text(L10n.t("ui_25"))
                    .foregroundColor(.blue)
                Spacer()
            }
        }
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }

    private func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(maxWidth: 220)
            .labelsHidden()
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(authMethod == "None" ? L10n.t("i18n_425") : "\(authMethod) Token")
                    .font(.body)
                if showKey {
                    TextField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            Button(action: { showKey.toggle() }) {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    // MARK: - 操作

    private func applyPreset(at index: Int) {
        let p = ModelConfig.providerPresets[min(index, ModelConfig.providerPresets.count - 1)]
        name = p.name
        provider = p.provider
        apiProtocol = p.protocol
        baseURL = p.baseURL
        model = p.model
        authMethod = p.auth
    }

    private func applyPreset(name presetName: String) {
        if let p = ModelConfig.providerPresets.first(where: { $0.name == presetName }) {
            name = p.name
            provider = p.provider
            apiProtocol = p.protocol
            baseURL = p.baseURL
            model = p.model
            authMethod = p.auth
        }
    }

    private func makeConfig() -> ModelConfig {
        ModelConfig(
            id: config?.id ?? UUID(),
            name: name.isEmpty ? model : name,
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            authMethod: authMethod,
            isDefault: isDefault,
            temperature: temperature,
            maxTokens: maxTokens,
            contextTokens: contextTokens,
            group: group,
            paramAliases: ModelEditorView.parseAliases(paramAliasesText),
            fallbackIDs: fallbackIDs
        )
    }

    /// v3.5.13：字典 → 编辑文本（"key:value,key2:value2"）
    private static func aliasesString(_ aliases: [String: String]?) -> String {
        guard let a = aliases, !a.isEmpty else { return "" }
        return a.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    }

    /// v3.5.13：编辑文本 → 字典（容忍中文逗号/空格，跳过非法项）
    private static func parseAliases(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",，;")) {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = p.firstIndex(of: ":") else { continue }
            let k = String(p[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let v = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty, k != v { out[k] = v }
        }
        return out
    }

    private func saveOnly() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        presentationMode.wrappedValue.dismiss()
    }

    private func saveAndTest() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = L10n.t("i18n_426")
        testColor = .secondary
        // v7.1.95：保存后只做轻量'测试连接'（GET /models 测连通+延迟）——不再 POST
        // chat/completions 完整调用（耗 token 且慢——用户要求'保存只需要测试连接'）
        speedTestCore(config: cfg)
    }

    private func fetchUpstreamModels() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = L10n.t("i18n_427")
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    testStatus = L10n.t("i18n_428")
                    testColor = .orange
                } else {
                    testStatus = L10n.t("i18n_429", models.count)
                    testColor = .green
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = error
                testColor = .red
            }
        }
    }

    /// v2.9.107：只测接口延迟（不保存）
    private func speedTestOnly() {
        isTesting = true
        testStatus = L10n.t("i18n_430")
        testColor = .secondary
        speedTestCore(config: makeConfig())
    }

    /// v7.1.95：轻量测试连接（GET {base}/models 测连通+延迟）——saveAndTest 与 speedTestOnly 共用
    private func speedTestCore(config: ModelConfig) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            isTesting = false
            testStatus = L10n.t("i18n_1103")
            testColor = .red
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                isTesting = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    testStatus = L10n.t("i18n_418", ms)
                    testColor = .red
                } else {
                    testStatus = L10n.t("i18n_431", ms)
                    testColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - 快速配置选择器

struct QuickConfigPicker: View {
    @Environment(\.presentationMode) var presentationMode
    let onSelect: (String) -> Void

    var body: some View {
        CompatNav {
            List(ModelConfig.providerPresets, id: \.name) { preset in
                Button(action: {
                    onSelect(preset.name)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                                .frame(width: 34, height: 34)
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text("\(preset.protocol) · \(preset.baseURL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("ui_25"))
            .toolbar {
                Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 模型选择 Sheet

struct ModelPickerSheet: View {
    let models: [String]
    @Binding var selected: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        CompatNav {
            List(models, id: \.self) { m in
                Button(action: {
                    selected = m
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Text(m)
                            .font(.system(.body, design: .monospaced))
                        // v7.4.0-fix73d：视觉能力标注——对齐配置列表（v7.1.109-peers photo 图标），
                        // 上游模型列表里一眼区分支持发图的模型（如 deepseek-v4-flash-vision-exp）
                        if ModelConfig.modelSupportsVision(m) {
                            Image(systemName: "photo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.blue)
                                .accessibilityLabel("Vision")
                        }
                        Spacer()
                        if selected == m {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_432"))
            .toolbar {
                Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - v2.9.107 配置导入导出（FileDocument）

struct ConfigDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - v2.9.107 用量统计页（聚合本地 usage.jsonl）

struct UsageStatsView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var records: [[String: Any]] = []

    var body: some View {
        CompatNav {
            List {
                let agg = aggregate()
                Section(header: Text(L10n.t("ui_60"))) {
                    // v7.1.109-minis：6 卡分列（对齐 OpenMinis TokenUsageSheet 的 Input/Output 分列）
                    HStack {
                        statCell(title: L10n.t("i18n_433"), value: "\(agg.total)", color: .blue)
                        statCell(title: L10n.t("i18n_434"), value: agg.total > 0 ? "\(Int(Double(agg.ok) / Double(agg.total) * 100))%" : "-", color: .green)
                        statCell(title: L10n.t("i18n_435"), value: agg.total > 0 ? "\(agg.elapsed / agg.total)ms" : "-", color: .orange)
                    }
                    // v7.1.109-peers：缓存四件套（对齐 OpenMinis TokenUsageSheet）——
                    // 总输入(含缓存)/输出/缓存读取/命中率，直读中转站 usage
                    HStack {
                        statCell(title: "总输入(含缓存)", value: "\(fmtK(agg.inputTokens + agg.cacheRead))", color: .blue)
                        statCell(title: "输出 Token", value: "\(fmtK(agg.outputTokens))", color: .purple)
                        statCell(title: "缓存读取", value: "\(fmtK(agg.cacheRead))", color: .green)
                        statCell(title: "缓存命中率", value: cacheRateText(agg.cacheRead, agg.byProvider), color: .indigo)
                    }
                }

                if !agg.byProvider.isEmpty {
                    Section(header: Text(L10n.t("ui_69"))) {
                        ForEach(agg.byProvider.sorted(by: { $0.total > $1.total }), id: \.self) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    // v7.1.109-peers：总输入(含缓存) / 输出（对齐 Minis 行右侧）
                                    Text("\(fmtK(row.inputTokens + row.cacheReadTokens)) / \(fmtK(row.outputTokens))")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.secondary)
                                }
                                // v7.1.109-peers：缓存明细行（输入(新)/输出/缓存读取/命中率）
                                HStack(spacing: 8) {
                                    Text("输入 \(fmtK(row.inputTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("输出 \(fmtK(row.outputTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("缓存 \(fmtK(row.cacheReadTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("命中率 \(Int(row.cacheHitRate * 100))%").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                }
                                // v7.1.109-peers：日均/会话均值/会话/活跃天数（对齐 Minis 明细）
                                HStack(spacing: 8) {
                                    Text("日均 \(fmtK(row.dailyTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("会话均值 \(fmtK(row.perSessionTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("会话 \(row.sessionCount)").font(.caption2).foregroundColor(.secondary)
                                    Text("活跃 \(row.activeDays.count) 天").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                }
                                // v7.1.109-minis：token 输入/输出比例条（Input 蓝 / Output 紫——同列可视）
                                if row.totalTokens > 0 {
                                    HStack(spacing: 3) {
                                        GeometryReader { geo in
                                            HStack(spacing: 0) {
                                                let inRatio = row.totalTokens > 0 ? CGFloat(row.inputTokens) / CGFloat(row.totalTokens) : 0
                                                Rectangle()
                                                    .fill(Color.purple.opacity(0.75))
                                                    .frame(width: max(4, geo.size.width * min(inRatio, 1)))
                                                Rectangle()
                                                    .fill(Color.indigo.opacity(0.5))
                                            }
                                        }
                                        .frame(height: 6)
                                        .clipShape(Capsule())
                                        Text("\(fmtK(row.inputTokens)) → \(fmtK(row.outputTokens))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                ProgressView(value: row.total > 0 ? Double(row.ok) / Double(row.total) : 0)
                                    .accentColor(.green)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !records.isEmpty {
                    Section(header: Text(L10n.t("ui_96"))) {
                        ForEach(0..<min(records.count, 30), id: \.self) { i in
                            requestRow(records[i])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_409"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("i18n_436")) {
                        UsageRecorder.shared.clear()
                        records = []
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear {
                // 后台线程读取，避免主线程卡死
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = UsageRecorder.shared.records
                    DispatchQueue.main.async {
                        records = result
                    }
                }
            }
        }
    }

    private func fmtK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }

    /// v7.1.109-peers：总缓存命中率——cache/(cache+miss) 标准口径；无 miss 时按 cache/总输入
    private func cacheRateText(_ cacheRead: Int, _ byProvider: [ProviderAgg]) -> String {
        let miss = byProvider.reduce(0) { $0 + $1.cacheMissTokens }
        if cacheRead + miss > 0 {
            return "\(Int(Double(cacheRead) / Double(cacheRead + miss) * 100))%"
        }
        return "-"
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func requestRow(_ r: [String: Any]) -> some View {
        let ts = r["ts"] as? Double ?? 0
        let ok = r["ok"] as? Bool ?? false
        let el = r["elapsedMs"] as? Int ?? 0
        let name = r["name"] as? String ?? "-"
        let model = r["model"] as? String ?? "-"
        let error = r["error"] as? String ?? ""
        // v7.1.98：token 显示——优先真实 usage total_tokens，无则回退估算输入
        let realTok = r["totalTokens"] as? Int ?? 0
        let estTok = r["estInputTokens"] as? Int ?? 0
        let tokText: String
        if realTok > 0 {
            tokText = "≈\(fmtK(realTok)) tok"
        } else if estTok > 0 {
            tokText = "≈\(fmtK(estTok)) tok(估)"
        } else {
            tokText = ""
        }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(ok ? .green : .red)
                    .font(.system(size: 13))
                Text(name).font(.subheadline).lineLimit(1)
                Spacer()
                if !tokText.isEmpty {
                    Text(tokText).font(.caption2).foregroundColor(.purple)
                }
                Text("\(el)ms").font(.caption).foregroundColor(.secondary)
                Text(f.string(from: d)).font(.caption2).foregroundColor(.secondary)
            }
            Text(model).font(.caption).foregroundColor(.secondary).lineLimit(1)
            if !ok, !error.isEmpty {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private struct ProviderAgg: Hashable {
        let name: String
        var total: Int = 0
        var ok: Int = 0
        var elapsed: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalTokens: Int = 0
        // v7.1.109-peers：缓存统计（直读中转站 usage）——缓存读取/未命中/命中率/会话/活跃天数
        var cacheReadTokens: Int = 0
        var cacheMissTokens: Int = 0
        var sessionCount: Int = 0
        var activeDays: Set<String> = []
        var lastTs: Double = 0
        /// 缓存命中率（标准口径 cache / (cache+miss)；无 miss 数据时按 cache / 总输入）
        var cacheHitRate: Double {
            let denom = cacheReadTokens + cacheMissTokens
            if denom > 0 { return Double(cacheReadTokens) / Double(denom) }
            let totalIn = inputTokens + cacheReadTokens
            return totalIn > 0 ? Double(cacheReadTokens) / Double(totalIn) : 0
        }
        var dailyTokens: Int {
            let totalInOut = inputTokens + outputTokens
            return activeDays.isEmpty ? totalInOut : totalInOut / max(1, activeDays.count)
        }
        var perSessionTokens: Int {
            let totalInOut = inputTokens + outputTokens
            return sessionCount > 0 ? totalInOut / sessionCount : totalInOut
        }
    }

    /// v7.1.109-minis：token 分列聚合（对齐 OpenMinis TokenUsageSheet / ModelStats）——
    /// 真实 usage(prompt/completion/total) 优先，无则回退估算输入(estInputTokens)；
    /// total 无真实值按 input+output 推算。
    /// v7.1.109-peers：缓存四件套直读中转站 usage；会话按时间间隔>30min 分桶，活跃天数按日期去重。
    private func aggregate() -> (total: Int, ok: Int, elapsed: Int, inputTokens: Int, outputTokens: Int, totalTokens: Int, cacheRead: Int, byProvider: [ProviderAgg]) {
        var total = 0, ok = 0, elapsed = 0, inputTokens = 0, outputTokens = 0, totalTokens = 0, cacheRead = 0
        var map: [String: ProviderAgg] = [:]
        for r in records {
            total += 1
            let o = r["ok"] as? Bool ?? false
            if o { ok += 1 }
            elapsed += r["elapsedMs"] as? Int ?? 0
            let pt = r["promptTokens"] as? Int ?? 0
            let ct = r["completionTokens"] as? Int ?? 0
            let tt = r["totalTokens"] as? Int ?? 0
            let ei = r["estInputTokens"] as? Int ?? 0
            let inT = pt > 0 ? pt : ei
            let outT = ct
            let totT = tt > 0 ? tt : (inT + outT)
            let cr = r["cacheReadTokens"] as? Int ?? 0
            let cm = r["cacheMissTokens"] as? Int ?? 0
            inputTokens += inT
            outputTokens += outT
            totalTokens += totT
            cacheRead += cr
            let name = r["name"] as? String ?? "-"
            let ts = r["ts"] as? Double ?? 0
            var a = map[name] ?? ProviderAgg(name: name)
            a.total += 1
            if o { a.ok += 1 }
            a.elapsed += r["elapsedMs"] as? Int ?? 0
            a.inputTokens += inT
            a.outputTokens += outT
            a.totalTokens += totT
            a.cacheReadTokens += cr
            a.cacheMissTokens += cm
            if ts > 0 {
                // 会话分桶：与上一条间隔 > 30 分钟 → 新会话
                if a.lastTs > 0, ts - a.lastTs > 1800 { a.sessionCount += 1 }
                a.lastTs = max(a.lastTs, ts)
                let day = String(Int(ts / 86400))
                a.activeDays.insert(day)
            }
            map[name] = a
        }
        for (k, v) in map {
            var v = v
            if v.total > 0 { v.sessionCount += 1 }   // 首条也算一个会话
            map[k] = v
        }
        return (total, ok, elapsed, inputTokens, outputTokens, totalTokens, cacheRead, Array(map.values))
    }
}
