import SwiftUI
import UIKit

final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var drawerOpen = false
    @Published var settingsPresented = false
    @Published var settingsJumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并跳到系统指令(SystemPromptsView)页
    @Published var settingsJumpToSystemPrompts = false
    @Published var controlPresented = false
    @Published var macroPresented = false
    // v3.0.76：输入框上方快捷标签
    @Published var quickTerminalPresented = false
    @Published var quickToolsPresented = false
    @Published var quickSkillsPresented = false
    @Published var quickFilesPresented = false
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var lang = LanguageManager.shared   // v2.9.76：语言切换全局刷新
    // v2.9.78：首次启动引导；v2.9.83：改为按版本展示——每次安装新版本/覆盖老版本都重新展现引导页
    @State private var showOnboarding = RootView.onboardingNeeded()
    // v2.9.126：深链导入确认页（trollagent://import?...）
    @ObservedObject private var pendingImport = PendingImport.shared
    @State private var importResult: String?
    // v4.3.44：QuickLook 分享中间层状态（侧载环境分享面板安全路径）
    @ObservedObject private var shareCenter = ShareCenter.shared

    private static func onboardingNeeded() -> Bool {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return UserDefaults.standard.string(forKey: "trollmcp2.onboarding_last_version") != v
    }

    private func markOnboardingDone() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        UserDefaults.standard.set(v, forKey: "trollmcp2.onboarding_last_version")
    }

    var body: some View {
        ZStack {
            ChatView()
                .disabled(ui.drawerOpen)

            if ui.drawerOpen {
                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { ui.drawerOpen = false } }
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ConversationDrawerView()
                        .frame(width: drawerWidth(for: geo))
                        .offset(x: ui.drawerOpen ? 0 : -drawerWidth(for: geo))
                        .animation(.easeInOut)
                        .edgesIgnoringSafeArea(.vertical)
                        .allowsHitTesting(ui.drawerOpen)
                    Spacer()
                }
            }
        }
        // v2.9.39：内置浏览器悬浮窗（所有界面之上，可缩小到右侧边缘，AI 操作自动浮现）
        // 注意：trailing-closure 版 overlay 仅 iOS15+，项目部署目标 iOS14，用 view 参数版
        .overlay(FloatingBrowserOverlay())
        // v2.9.76：设置改全屏（去掉 sheet 半屏 + 顶部 grabber），子页面头部对齐
        .fullScreenCover(isPresented: Binding(
            get: { ui.settingsPresented },
            set: { ui.settingsPresented = $0 }
        )) {
            SettingsView()
        }
        // v2.9.78：引导页（v2.9.83：每个新版本展示一次）
        .fullScreenCover(isPresented: $showOnboarding, onDismiss: {
            markOnboardingDone()
        }) {
            OnboardingView {
                markOnboardingDone()
                showOnboarding = false
            }
        }
        // v2.9.139：AI 控制中心（控制任意 App 时的计划/进度/日志/结果页）
        .fullScreenCover(isPresented: Binding(
            get: { ui.controlPresented },
            set: { ui.controlPresented = $0 }
        )) {
            ControlCenterView()
        }
        // v2.9.142：宏管理页（聊天输入框「🎬 宏」入口）
        .fullScreenCover(isPresented: Binding(
            get: { ui.macroPresented },
            set: { ui.macroPresented = $0 }
        )) {
            MacroView()
        }
        // v2.9.76：语言切换后全局重建视图
        .id(lang.language.rawValue)
        // v2.9.126：深链导入确认页——暂存配置后弹窗，确认才写入
        .onReceive(NotificationCenter.default.publisher(for: PendingImport.didStageNotification)) { note in
            if let result = note.userInfo?["result"] as? String {
                importResult = result == "imported" ? L10n.t("i18n_1013") : L10n.t("i18n_1014")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { importResult = nil }
            }
        }
        .alert(isPresented: Binding(
            get: { pendingImport.staged != nil },
            set: { if !$0 { pendingImport.cancel() } }
        )) {
            if let cfg = pendingImport.staged {
                return Alert(
                    title: Text(L10n.t("ui_49")),
                    message: Text(L10n.t("ui_170", cfg.name, cfg.model, cfg.baseURL)),
                    primaryButton: .default(Text(L10n.t("ui_48")), action: { pendingImport.confirm() }),
                    secondaryButton: .cancel(Text(L10n.t("ui_40")), action: { pendingImport.cancel() })
                )
            }
            return Alert(title: Text(""), dismissButton: .default(Text("OK")))
        }
        .overlay(Group {
            if let result = importResult {
                Text(result)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }
        }, alignment: .bottom)
        // v4.3.44：剪贴板/写入提示（分享降级或失败时的用户反馈）
        .overlay(alignment: .bottom) {
            if let notice = shareCenter.clipboardNotice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 100)
                    .transition(.opacity)
            }
        }
    }

    private func drawerWidth(for geo: GeometryProxy) -> CGFloat {
        min(geo.size.width * 0.78, 320)
    }
}

struct ConversationDrawerView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var probe = DeviceProbe.shared
    @State private var searchText = ""
    @State private var showDevice = false
    // v2.9.166：deviceReady 改为计算属性直接读 DeviceProbe.shared.lastReport——
    // 旧版 @State 只在 onAppear 读一次：用户点开检测页跑完（全绿）返回后，
    // 左下角仍是旧感叹号，这就是"环境通过了还显示感叹号"的根因。
    // @ObservedObject 观察 lastReport @Published，检测页/启动检测完成自动同步。
    private var deviceReady: Bool? { probe.lastReport?.ready }

    private var filtered: [ChatConversation] {
        if searchText.isEmpty { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            countLabel
            // v7.4.0-contextui：上下文占用条（当前会话 token/窗口 + 压力着色，点击看详情）
            ContextUsageBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            conversationList
            bottomWorkbench
        }
        .background(Color(.systemBackground))
        .onAppear(perform: refreshReadiness)
        .sheet(isPresented: $showDevice) {
            CompatNav { DeviceDetectionView(showsDismissButton: true) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [.blue, .tmCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(9)
            Text(L10n.t("drawer_title"))
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
            Button(action: { withAnimation { ui.drawerOpen = false } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeArea + 8)
        .padding(.bottom, 12)
    }

    /// v2.9.12：状态栏安全区高度（抽屉 ignoredSafeArea 后需手动避让系统时间）
    private var topSafeArea: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
            TextField(L10n.t("drawer_search"), text: $searchText)
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
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(searchText.isEmpty ? 0 : 0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var countLabel: some View {
        HStack {
            Text(L10n.t("drawer_count").replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var conversationList: some View {
        // 用 ScrollView + LazyVStack 替代 List，去掉行间分隔线（v2.9.9）
        // v2.9.10：选中行加渐变圆角卡片
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filtered) { conv in
                    Button(action: {
                        store.select(conv.id)
                        withAnimation { ui.drawerOpen = false }
                    }) {
                        conversationRow(conv)
                            .background(
                                Group {
                                    if store.selectedId == conv.id {
                                        LinearGradient(colors: [Color.blue.opacity(0.16), Color.blue.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        // iOS14 兼容：不用 Button(role:)
                        Button(action: { deleteSingle(conv.id) }) {
                            Label(L10n.t("drawer_delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
    }

    private func conversationRow(_ conv: ChatConversation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(store.selectedId == conv.id ? Color.blue : Color(.secondarySystemBackground))
                    .frame(width: 34, height: 34)
                Image(systemName: store.selectedId == conv.id ? "bubble.left.fill" : "message.fill")
                    .font(.system(size: 15))
                    .foregroundColor(store.selectedId == conv.id ? .white : .blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title)
                    .font(.body)
                    .fontWeight(store.selectedId == conv.id ? .semibold : .regular)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(Self.formatter.string(from: conv.updatedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { filtered[$0].id }
        let idxSet = IndexSet(store.conversations.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        store.delete(at: idxSet)
    }

    private var deviceReadinessBar: some View {
        // 已并入 bottomWorkbench 精简入口（v2.9.9），此实现保留备用
        EmptyView()
    }

    private var readinessText: String {
        if let ready = deviceReady { return ready ? L10n.t("drawer_ready") : L10n.t("drawer_env_limited") }
        return L10n.t("drawer_probe")
    }

    /// v2.9.166：环境未就绪时显示首个失败项简短原因（如"Entitlements 未生效"），
    /// 而不是笼统感叹号——用户要求"不打X✔只做简单提醒"。
    private var failureHint: String {
        if deviceReady == true { return L10n.t("drawer_ready_short") }
        if let report = probe.lastReport {
            for c in report.checks where !c.passed && !c.infoOnly {
                return c.label
            }
        }
        return L10n.t("i18n_1015")
    }

    private func refreshReadiness() {
        // 轻量读取缓存报告，避免每次打开抽屉都全量扫描
        // （@ObservedObject 已自动同步，此方法仅用于首次出现时兜底）
        _ = probe.lastReport?.ready
    }

    private var bottomWorkbench: some View {
        // v2.9.10：圆角卡片式底部工具栏（环境入口 + 设置齿轮）
        // v2.9.76：就绪图标美化——渐变圆环 + 脉冲点 + 波浪扫描
        HStack(spacing: 12) {
            Button(action: { showDevice = true }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill((deviceReady == true ? Color.green : Color.orange).opacity(0.14))
                            .frame(width: 44, height: 44)
                        Circle()
                            .stroke(
                                (deviceReady == true ? Color.green : Color.orange).opacity(0.35),
                                lineWidth: 2.5
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: deviceReady == true ? "checkmark" : "exclamationmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(deviceReady == true ? .green : .orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(readinessText)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(deviceReady == true ? .green : .orange)
                        Text(failureHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            Spacer()
            Button(action: {
                withAnimation { ui.drawerOpen = false }
                ui.settingsPresented = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(14)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 24)
    }

    // v7.0.5：会话时间格式改为动态读取（static let 启动缓存后切语言不刷新，会残留"M月d日"）
    static var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = L10n.t("i18n_1016")
        return f
    }
}
