import SwiftUI
import Combine

// MARK: - 审批中心（ApprovalSheet / OperationView 共用）

final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Pending: Identifiable, Hashable {
        var id = UUID()
        var toolName: String
        var summary: String
        var params: String
        var submittedAt = Date()
        var decision: Decision = .pending

        enum Decision { case pending, approved, denied }
    }

    @Published var pending: [Pending] = []

    func submit(tool: String, summary: String, params: String) {
        pending.insert(Pending(toolName: tool, summary: summary, params: params), at: 0)
        AuditLog.shared.log("approval", detail: L10n.t("i18n_899", tool))
    }

    func approve(_ item: Pending) {
        if let idx = pending.firstIndex(where: { $0.id == item.id }) { pending[idx].decision = .approved }
        AuditLog.shared.log("approval", detail: L10n.t("i18n_900", item.toolName))
    }

    func deny(_ item: Pending) {
        if let idx = pending.firstIndex(where: { $0.id == item.id }) { pending[idx].decision = .denied }
        AuditLog.shared.log("approval", detail: L10n.t("i18n_901", item.toolName), level: .warning)
    }
}

// MARK: - 操作中枢（原版 OperationView）

struct OperationView: View {
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var automations = AutomationStore.shared
    @ObservedObject private var audit = AuditLog.shared

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_902"))) {
                    if approvals.pending.filter({ $0.decision == .pending }).isEmpty {
                        Text(L10n.t("ui_85"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(approvals.pending.filter { $0.decision == .pending }) { item in
                            NavigationLink(destination: ApprovalSheet(item: item)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.toolName)
                                        .font(.system(.body, design: .monospaced))
                                    Text(item.summary)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_903"))) {
                    let running = automations.tasks.filter { $0.enabled }
                    if running.isEmpty {
                        Text(L10n.t("ui_81"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(running) { t in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name)
                                    Text(t.schedule)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(L10n.t("i18n_904")) {
                                    _ = AutomationStore.shared.run(name: t.name)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_905"))) {
                    ForEach(audit.entries.prefix(10)) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.detail)
                                .font(.subheadline)
                            Text("\(e.category) · \(Self.timeFormatter.string(from: e.timestamp))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_906"))
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - 审批表单（原版 ApprovalSheet）

struct ApprovalSheet: View {
    @ObservedObject private var center = ApprovalCenter.shared
    let item: ApprovalCenter.Pending

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_907"))) {
                    LabeledRow(label: L10n.t("i18n_1073"), value: item.toolName)
                    LabeledRow(label: L10n.t("ui_132"), value: item.summary)
                    LabeledRow(label: L10n.t("i18n_909"), value: OperationView.timeFormatter.string(from: item.submittedAt))
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_910"))) {
                    Text(item.params)
                        .font(.system(.caption, design: .monospaced))
                }
                Section {
                    Button(action: { center.approve(item) }) {
                        Text(L10n.t("ui_65")).foregroundColor(.green)
                    }
                    Button(action: { center.deny(item) }) {
                        Text(L10n.t("ui_68")).foregroundColor(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_911"))
        }
    }
}

// MARK: - 会话完整记录（原版 ConversationTranscriptView）

struct ConversationTranscriptView: View {
    @ObservedObject private var store = ConversationStore.shared
    @State private var showingClearConfirm = false

    private var messages: [ChatMessage] {
        guard let idx = store.selectedIndex else { return [] }
        return store.conversations[idx].messages
    }

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "text.bubble.fill",
                title: L10n.t("page_transcripts"),
                subtitle: L10n.t("page_transcripts_sub"),
                colors: [.blue, .tmCyan]
            )
            .padding(.vertical, 8)

            List {
                if messages.isEmpty {
                    Text(L10n.t("ui_80"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(messages) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(msg.role == "user" ? L10n.t("i18n_912") : (msg.role == "assistant" ? L10n.t("i18n_913") : L10n.t("i18n_979")))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(msg.role == "user" ? .blue : .green)
                                Spacer()
                                Text(Self.tf.string(from: msg.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(msg.content)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                if !messages.isEmpty {
                    // v7.1.72：清空按钮=清掉全部会话（聊天框侧边栏同步清空，用户要求联动）
                    Button(L10n.t("btn_clear")) { showingClearConfirm = true }
                }
            }
            .confirmationDialog(L10n.t("i18n_400"), isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button(L10n.t("btn_clear"), role: .destructive) { store.clearAll() }
                Button(L10n.t("ui_40"), role: .cancel) {}
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_transcripts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static let tf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

// MARK: - 助手角色配置（原版 AssistantProfilesView）

struct AssistantProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var systemPrompt: String
    var modelConfigId: UUID?
    var temperature: Double = 0.7
}

final class AssistantProfileStore: ObservableObject {
    static let shared = AssistantProfileStore()
    @Published var profiles: [AssistantProfile] = []
    private let key = "trollmcp2.assistant_profiles"

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AssistantProfile].self, from: data) {
            profiles = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct AssistantProfilesView: View {
    @ObservedObject private var store = AssistantProfileStore.shared
    @State private var editing: AssistantProfile?

    var body: some View {
        CompatNav {
            List {
                if store.profiles.isEmpty {
                    Text(L10n.t("ui_79"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.profiles) { p in
                        NavigationLink(destination: AssistantProfileEditor(profile: p)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(p.systemPrompt)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.profiles.remove(atOffsets: offsets)
                        store.save()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_915"))
            .toolbar {
                Button(action: {
                    editing = AssistantProfile(name: L10n.t("i18n_916"), systemPrompt: L10n.t("i18n_917"))
                }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { profile in
                AssistantProfileEditor(profile: profile)
            }
        }
    }
}

struct AssistantProfileEditor: View {
    @ObservedObject private var store = AssistantProfileStore.shared
    @ObservedObject private var models = ModelStore.shared
    @State var profile: AssistantProfile
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        
            Form {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_918"))) {
                    TextField(L10n.t("i18n_919"), text: $profile.name)
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_920"))) {
                    TextEditor(text: $profile.systemPrompt)
                        .frame(minHeight: 120)
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_921"))) {
                    Picker(L10n.t("i18n_922"), selection: $profile.modelConfigId) {
                        Text(L10n.t("ui_144")).tag(UUID?.none)
                        ForEach(models.configs) { c in
                            Text(c.name).tag(UUID?.some(c.id))
                        }
                    }
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_910"))) {
                    HStack {
                        Text(L10n.t("ui_108"))
                        Slider(value: $profile.temperature, in: 0...2, step: 0.1)
                        Text(String(format: "%.1f", profile.temperature))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 32)
                    }
                }
                Section {
                    Button(L10n.t("i18n_1166")) {
                        if let idx = store.profiles.firstIndex(where: { $0.id == profile.id }) {
                            store.profiles[idx] = profile
                        } else {
                            store.profiles.append(profile)
                        }
                        store.save()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(profile.name.isEmpty ? L10n.t("i18n_916") : profile.name)
        
        .navigationViewStyle(.stack)
    }
}

// MARK: - 附件面板（原版 AttachmentBottomPanel）

final class AttachmentStore: ObservableObject {
    static let shared = AttachmentStore()
    @Published var items: [String] = []

    func add(_ name: String) {
        items.append(name)
        AuditLog.shared.log("attachment", detail: name)
    }
}

struct AttachmentBottomPanel: View {
    @ObservedObject private var store = AttachmentStore.shared
    @State private var showImporter = false
    @Binding var isPresented: Bool

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_924"))) {
                    Button(action: { showImporter = true }) {
                        Label(L10n.t("i18n_925"), systemImage: "folder")
                    }
                    Button(action: { store.add(L10n.t("i18n_926")) }) {
                        Label(L10n.t("i18n_927"), systemImage: "camera")
                    }
                    Button(action: { store.add(L10n.t("i18n_928")) }) {
                        Label(L10n.t("i18n_929"), systemImage: "photo.on.rectangle")
                    }
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_930", store.items.count))) {
                    if store.items.isEmpty {
                        Text(L10n.t("ui_95")).foregroundColor(.secondary)
                    } else {
                        ForEach(store.items, id: \.self) { name in
                            Label(name, systemImage: "paperclip")
                        }
                        Button(action: { store.items.removeAll() }) {
                            Text(L10n.t("ui_107")).foregroundColor(.red)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_931"))
            .toolbar {
                Button(L10n.t("i18n_1180")) { isPresented = false }
            }
            .sheet(isPresented: $showImporter) {
                DocumentImporter { url in
                    store.add(url.lastPathComponent)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 自动化中心（原版 AutomationCenterView）

struct AutomationCenterView: View {
    @ObservedObject private var store = AutomationStore.shared
    @State private var editing: AutomationStore.Task?

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "bolt.fill",
                title: L10n.t("page_automation"),
                subtitle: L10n.t("page_automation_sub"),
                colors: [.orange, .tmBrown]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_932"))) {
                    if store.tasks.isEmpty {
                        Text(L10n.t("ui_90"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.tasks) { t in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name)
                                    Text("\(t.schedule) · \(t.action)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { t.enabled },
                                    set: { AutomationStore.shared.setEnabled(t, enabled: $0) }
                                )).labelsHidden()
                                .accentColor(.tmCyan)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = t }
                        }
                        .onDelete { offsets in
                            let tasks = offsets.map { store.tasks[$0] }
                            tasks.forEach { AutomationStore.shared.remove($0) }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: L10n.t("i18n_933"))) {
                    let history = store.history.prefix(20)
                    if history.isEmpty {
                        Text(L10n.t("ui_86")).foregroundColor(.secondary)
                    } else {
                        ForEach(Array(history), id: \.id) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.detail).font(.subheadline)
                                Text("\(e.category) · \(ConversationTranscriptView.tf.string(from: e.timestamp))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                Button(action: {
                    editing = AutomationStore.Task(name: "", schedule: "*/5 * * * *", action: "ping")
                }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { task in
                AutomationTaskEditor(task: task)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_automation"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AutomationTaskEditor: View {
    @ObservedObject private var store = AutomationStore.shared
    @State var task: AutomationStore.Task
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        
            Form {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_934"))) {
                    TextField(L10n.t("i18n_919"), text: $task.name)
                    TextField(L10n.t("i18n_935"), text: $task.schedule)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    TextField(L10n.t("i18n_936"), text: $task.action)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Toggle(L10n.t("i18n_897"), isOn: $task.enabled)
                }
                Section {
                    Button(L10n.t("i18n_1166")) {
                        if let idx = store.tasks.firstIndex(where: { $0.id == task.id }) {
                            store.tasks[idx] = task
                        } else {
                            store.tasks.append(task)
                        }
                        store.save()
                        AuditLog.shared.log("automation", detail: L10n.t("i18n_937", task.name))
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(task.name.isEmpty ? L10n.t("i18n_938") : task.name)
        
        .navigationViewStyle(.stack)
    }
}

// MARK: - 自动化权限（原版 AutomationPermissionsView）

struct AutomationPermissionsView: View {
    @ObservedObject private var store = AutomationStore.shared
    @State private var globalEnabled = true

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_939"))) {
                    Toggle(L10n.t("i18n_940"), isOn: $globalEnabled)
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_941"))) {
                    if store.tasks.isEmpty {
                        Text(L10n.t("ui_78")).foregroundColor(.secondary)
                    } else {
                        ForEach(store.tasks) { t in
                            Toggle(t.name, isOn: Binding(
                                get: { t.enabled },
                                set: { AutomationStore.shared.setEnabled(t, enabled: $0) }
                            ))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_942"))
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Gateway 设置（原版 GatewaySettingsView / GatewayEditorView）

struct GatewayServer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var token: String = ""
}

final class GatewayServerStore: ObservableObject {
    static let shared = GatewayServerStore()
    @Published var servers: [GatewayServer] = []
    private let key = "trollmcp2.gateway_servers"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GatewayServer].self, from: data) {
            servers = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct GatewaySettingsView: View {
    @ObservedObject private var store = GatewayServerStore.shared
    @State private var editing: GatewayServer?

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "arrow.triangle.branch",
                title: L10n.t("page_gateway"),
                subtitle: L10n.t("page_gateway_sub"),
                colors: [.purple, .tmIndigo]
            )
            .padding(.vertical, 8)

            List {
                if store.servers.isEmpty {
                    Text(L10n.t("ui_76"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.servers) { s in
                        NavigationLink(destination: GatewayEditorView(server: s)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text(s.url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.servers.remove(atOffsets: offsets)
                        store.save()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                Button(action: { editing = GatewayServer(name: "", url: "ws://") }) { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { server in
                GatewayEditorView(server: server)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_gateway"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GatewayEditorView: View {
    @ObservedObject private var store = GatewayServerStore.shared
    @State var server: GatewayServer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        
            Form {
                Section(header: SettingSectionHeader(title: L10n.t("ui_97"))) {
                    TextField(L10n.t("i18n_919"), text: $server.name)
                    TextField("ws://host:port", text: $server.url)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField(L10n.t("i18n_943"), text: $server.token)
                }
                Section {
                    Button(L10n.t("i18n_944")) {
                        if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
                            store.servers[idx] = server
                        } else {
                            store.servers.append(server)
                        }
                        store.save()
                        GatewayClient.shared.pairedToken = server.token.isEmpty ? nil : server.token
                        GatewayClient.shared.connect(url: server.url)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(server.name.isEmpty ? L10n.t("i18n_945") : server.name)
        
        .navigationViewStyle(.stack)
    }
}

// MARK: - 注入详情（原版 InjectionDetailView）

struct InjectionDetailView: View {
    @State var bundleId: String
    @State private var info: [String: Any] = [:]
    @State private var message = ""

    init(bundleId: String = "") {
        _bundleId = State(initialValue: bundleId)
    }

    var body: some View {
        CompatNav {
            List {
                if bundleId.isEmpty {
                    Section(header: SettingSectionHeader(title: L10n.t("i18n_946"))) {
                        ForEach(AppCatalog.list().prefix(100)) { app in
                            Button(action: {
                                bundleId = app.bundleId
                                reload()
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.bundleId)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    detailBody
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_947"))
        }
        .navigationViewStyle(.stack)
    }

    private var detailBody: some View {
        Group {
                Section(header: SettingSectionHeader(title: "App")) {
                    LabeledRow(label: "Bundle ID", value: bundleId)
                    if let app = AppCatalog.find(bundleId) {
                        LabeledRow(label: L10n.t("i18n_919"), value: app.name)
                        LabeledRow(label: L10n.t("i18n_948"), value: app.path)
                    }
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_949"))) {
                    if info.isEmpty {
                        Text(L10n.t("ui_35")).foregroundColor(.secondary)
                    } else {
                        ForEach(info.keys.sorted(), id: \.self) { key in
                            LabeledRow(label: key, value: String(describing: info[key] ?? "-"))
                        }
                    }
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_906"))) {
                    Button(action: {
                        do {
                            _ = try InjectionManager.shared.enable(bundleId: bundleId, dylibName: "@executable_path/ControlAgent.dylib")
                            message = L10n.t("i18n_950")
                            reload()
                        } catch { message = L10n.t("i18n_951", error.localizedDescription) }
                    }) { Text(L10n.t("ui_42")).foregroundColor(.green) }
                    Button(action: {
                        do {
                            _ = try InjectionManager.shared.disable(bundleId: bundleId)
                            message = L10n.t("i18n_952")
                            reload()
                        } catch { message = L10n.t("i18n_951", error.localizedDescription) }
                    }) { Text(L10n.t("ui_116")).foregroundColor(.orange) }
                    Button(action: {
                        do {
                            _ = try InjectionRemoveTool().invoke(["bundle_id": bundleId])
                            message = L10n.t("i18n_953")
                            reload()
                        } catch { message = L10n.t("i18n_951", error.localizedDescription) }
                    }) { Text(L10n.t("ui_57")).foregroundColor(.red) }
                }
                if !message.isEmpty {
                    Section { Text(message).font(.caption).foregroundColor(.secondary) }
                }
            }
            .onAppear(perform: reload)
        }

    private func reload() {
        info = InjectionManager.shared.inspect(bundleId)
    }
}

// MARK: - 设置活动记录（原版 SettingsActivityView）

struct SettingsActivityView: View {
    @ObservedObject private var audit = AuditLog.shared
    @State private var filter = ""

    var body: some View {
        CompatNav {
            List {
                Section {
                    TextField(L10n.t("i18n_954"), text: $filter)
                        .autocapitalization(.none)
                }
                Section(header: SettingSectionHeader(title: L10n.t("i18n_955"))) {
                    let entries = filter.isEmpty ? audit.entries : audit.entries.filter { $0.category.contains(filter) }
                    if entries.isEmpty {
                        Text(L10n.t("ui_92")).foregroundColor(.secondary)
                    } else {
                        ForEach(entries) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(e.category)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(e.level == .error ? .red : (e.level == .warning ? .orange : .blue))
                                    Spacer()
                                    Text(ConversationTranscriptView.tf.string(from: e.timestamp))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(e.detail).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_955"))
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Skill / Agent 编辑器（原版 SkillEditorView / AgentEditorView）

struct SkillEditorView: View {
    @State private var name = ""
    @State private var summary = ""
    @State private var instruction = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            Form {
                Section(header: SettingSectionHeader(title: "Skill")) {
                    TextField(L10n.t("i18n_919"), text: $name)
                    TextField(L10n.t("i18n_956"), text: $summary)
                    TextEditor(text: $instruction)
                        .frame(minHeight: 120)
                }
                Section {
                    Button(L10n.t("i18n_1166")) {
                        SkillStore.shared.upsert(SkillItem(name: name, summary: summary, instruction: instruction))
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                Section(header: SettingSectionHeader(title: L10n.t("ui_132"))) {
                    Text(L10n.t("ui_66"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("i18n_957"))
        }
        .navigationViewStyle(.stack)
    }
}

/// Agent 保存（独立实现）
enum AgentJSONStore {
    static func upsert(file: String, entry: [String: String]) {
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("KnowledgeBase")
        try? FileManager.default.createDirectory(at: kb, withIntermediateDirectories: true)
        let url = kb.appendingPathComponent(file)
        var list: [[String: String]] = []
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            list = json
        }
        if let name = entry["name"], let idx = list.firstIndex(where: { $0["name"] == name }) {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        AuditLog.shared.log("agents", detail: L10n.t("i18n_958", (entry["name"] as? String) ?? ""))
    }
}

struct AgentEditorView: View {
    @State private var name = ""
    @State private var systemPrompt = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            Form {
                Section(header: SettingSectionHeader(title: "Agent")) {
                    TextField(L10n.t("i18n_919"), text: $name)
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                }
                Section {
                    Button(L10n.t("i18n_959")) {
                        AgentJSONStore.upsert(file: "agents.json", entry: ["name": name, "systemPrompt": systemPrompt])
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(L10n.t("i18n_960"))
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Webhook 编辑器（原版 WebhookEditorView）

struct WebhookEditorView: View {
    @State private var url = ""
    @State private var secret = ""
    @State private var events = "audit,tool_call"
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            Form {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_961"))) {
                    TextField("https://example.com/webhook", text: $url)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField(L10n.t("i18n_962"), text: $secret)
                    TextField(L10n.t("i18n_963"), text: $events)
                        .autocapitalization(.none)
                }
                Section {
                    Button(L10n.t("i18n_1166")) {
                        UserDefaults.standard.set(["url": url, "secret": secret, "events": events], forKey: "trollmcp2.webhook")
                        AuditLog.shared.log("webhook", detail: L10n.t("i18n_964", url))
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle(L10n.t("i18n_965"))
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - API Key 恢复表（原版 APIKeyRecoverySheet）

struct APIKeyRecoverySheet: View {
    @ObservedObject private var models = ModelStore.shared
    @State private var revealed: UUID?
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_966"))) {
                    if models.configs.isEmpty {
                        Text(L10n.t("ui_88")).foregroundColor(.secondary)
                    } else {
                        ForEach(models.configs) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    Text(masked(c))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if revealed == c.id {
                                    Button(L10n.t("i18n_967")) { revealed = nil }.font(.caption)
                                } else {
                                    Button(L10n.t("i18n_968")) { revealed = c.id }.font(.caption)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text(L10n.t("ui_47"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("API Key")
            .toolbar { Button(L10n.t("i18n_1180")) { presentationMode.wrappedValue.dismiss() } }
        }
        .navigationViewStyle(.stack)
    }

    private func masked(_ c: ModelConfig) -> String {
        guard !c.apiKey.isEmpty else { return "(empty)" }
        if revealed == c.id { return c.apiKey }
        if c.apiKey.count > 8 {
            return String(c.apiKey.prefix(4)) + "****" + String(c.apiKey.suffix(4))
        }
        return "****"
    }
}

// MARK: - 上游模型选择（原版 UpstreamModelPickerView）

struct UpstreamModelPickerView: View {
    @ObservedObject private var models = ModelStore.shared
    @State private var upstream: [String] = []
    @State private var loading = false
    @State private var errorText = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if !errorText.isEmpty {
                    Text(errorText).foregroundColor(.red).font(.caption)
                } else if upstream.isEmpty {
                    Text(L10n.t("ui_109")).foregroundColor(.secondary)
                } else {
                    Section(header: SettingSectionHeader(title: L10n.t("i18n_969"))) {
                        ForEach(upstream, id: \.self) { id in
                            Button(action: {
                                if var c = models.defaultConfig {
                                    c.model = id
                                    models.update(c)
                                }
                            }) {
                                HStack {
                                    Text(id).font(.system(.subheadline, design: .monospaced))
                                    // v7.4.0-fix73d：视觉能力标注（对齐配置列表 photo 图标）
                                    if ModelConfig.modelSupportsVision(id) {
                                        Image(systemName: "photo")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.blue)
                                            .accessibilityLabel("Vision")
                                    }
                                    Spacer()
                                    if models.defaultConfig?.model == id {
                                        Image(systemName: "checkmark").foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_969"))
            .toolbar {
                Button(action: fetch) { Image(systemName: "arrow.clockwise") }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func fetch() {
        guard let config = models.defaultConfig else {
            errorText = L10n.t("i18n_970")
            return
        }
        loading = true
        errorText = ""
        ModelAPIClient.shared.fetchModelList(config: config) { result in
            loading = false
            switch result {
            case .success(let list): upstream = list
            case .failure(let err): errorText = err
            }
        }
    }
}
