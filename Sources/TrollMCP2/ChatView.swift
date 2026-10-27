import SwiftUI
import UIKit
import RSKGrowingTextView
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared
    @ObservedObject private var tts = TTSService.shared

    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 36
    // v7.2.3-fix14：工具卡参数行折叠——默认一行+▽，点击展开完整命令/参数
    /// v7.2.3-fix20：连续工具折叠展开状态（按组 id）
    @State private var toolsRunExpanded: Set<String> = []
    // v2.9.234：推理强度/智能搜索持久化(@AppStorage)——之前纯@State,关app重开必丢
    @AppStorage("chat_reasoning") private var reasoning = 0   // 0=低 1=中 2=高 3=最高(xhigh) 4=极限(max)
    @AppStorage("chat_smart_search") private var smartSearch = true
    // v3.1.25：思考模型总开关——关闭时完全不思考，直接回复（reasoning_effort=none）
    @AppStorage("chat_think_enabled") private var thinkEnabled = true
    @State private var keyboardHeight: CGFloat = 0   // v2.9.234：键盘高度(消息列表跟随上移)
    @State private var attachmentSheet: AttachmentSheet?
    // v3.1.67：文件选择改用 UIKit UIDocumentPickerViewController（asCopy: true）从顶层 VC present——
    // .fileImporter 在真机 iPhone 上有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    // UIKit 方案真机稳定。标记位 + sheet onDismiss 触发，保证面板完全关闭后再 present（不再猜时间延迟）。
    @State private var pendingFilePick = false
    @State private var showModelPicker = false  // v2.9.36：聊天框切换上游模型
    @State private var showVoicePicker = false  // v7.2.4：长按全局喇叭切音色（萝莉/猫娘御姐/兔娘）——聊天界面可改，HUD 角色音色固定不变
    @State private var showToolCenter = false  // v6.1.5-14bm：/tools 打开工具中心
    @State private var showTerminal = false  // v7.0.4：终端按钮 → 简易终端
    // v3.3.4：输入框 + 号展开"应用/相册/文件/浏览器"快捷行（点 + 变 x 收起）
    @State private var attachExpanded = false

    // v2.9.9：多模态图片（data URL）。选择相册图片后转 base64 暂存，发送时随消息传给模型
    @State private var pendingImages: [String] = []
    // v2.9.10：统一待发送附件（图片缩略图 / 应用图标 / 文件），输入栏上方预览
    @State private var pendingAttachments: [PendingAttachment] = []

    // v2.9.2：多选模式（勾选会话内容 → 复制 / 分享到其他 App）
    @State private var selectionMode = false
    @State private var selectedIds = Set<UUID>()
    @State private var showToast = false
    @State private var toastText = L10n.t("i18n_1197")
    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else if store.currentMessages.isEmpty {
                    homeState
                } else {
                    messageList
                }
                // v2.9.72：工作流可视化步骤条
                WorkflowProgressView()
            }
            // v2.9.244：输入框改用 safeAreaInset 挂底部——标准键盘避让，不再手动 padding 双重压缩内容区
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationTitle(selectionMode ? L10n.t("i18n_1031", selectedIds.count) : store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v3.4.3：标题 + 模型名（🟢 deepseek v4 ▽）与右侧图标放同一平行线（导航栏 principal）
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(selectionMode ? L10n.t("i18n_1031", selectedIds.count) : store.currentTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Button(action: { showModelPicker = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(.green)
                                Text(modelStore.defaultConfig?.name ?? L10n.t("i18n_1032"))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectionMode {
                        Button(L10n.t("ui_40")) { exitSelection() }
                    } else {
                        HStack(spacing: 14) {
                            Button(action: { withAnimation { AppUIState.shared.drawerOpen.toggle() } }) {
                                Image(systemName: "line.horizontal.3")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            // v6.0.28：加号按钮放在左边（三横线后面，新建会话）
                            Button(action: { store.newConversation() }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        HStack(spacing: 14) {
                            Button(action: copySelected) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(selectedIds.isEmpty)
                            SharePresenter.toolbarShare(text: exportText())
                                .disabled(selectedIds.isEmpty)
                        }
                    } else {
                        HStack(spacing: 14) {
                            // v4.4.18：全局朗读开关——开着时 AI 流式回复自动朗读
                            // v7.2.4：长按弹音色切换（萝莉/猫娘御姐/兔娘）；点按仍切换开关。HUD 角色音色固定，聊天界面独立可改。
                            Button(action: { withAnimation { tts.speakerEnabled.toggle() } }) {
                                Image(systemName: tts.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")   // v6.1.5-14bg：关闭态用带斜杠喇叭（标准静音图标），不再普通喇叭灰显
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(tts.speakerEnabled ? .tmCyan : .secondary)
                            }
                            .simultaneousGesture(LongPressGesture().onEnded { _ in showVoicePicker = true })
                            .confirmationDialog("音色：\(tts.voicePreset.displayName)", isPresented: $showVoicePicker, titleVisibility: .visible) {
                                ForEach(VoicePreset.allCases, id: \.self) { v in
                                    Button(v.displayName) { withAnimation { tts.voicePreset = v } }
                                }
                                // v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——AI 摘要替换旧历史，持久化
                                Button("压缩当前会话") { compactNow() }
                                Button("取消", role: .cancel) {}
                            }
                            // 勾选/选择按钮
                            Button(action: enterSelection) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(store.currentMessages.isEmpty)
                        }
                    }
                }
            }
            // v2.9.244：删除手动 keyboardHeight padding（会与键盘避让叠加导致内容区被拉高/压缩），键盘避让交给 safeAreaInset
            // v2.9.235：键盘监听仍保留——用于键盘弹出时消息列表滚到底部

            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = h }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
            }
            .overlay(Group {
                if showToast {
                    Text(toastText)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.top, 8)
                }
            }, alignment: .top)
            // v6.0.7：去掉聊天页右下角小女孩 overlay——桌面悬浮 HUD 已是小女孩，再叠一个会重复成两个。
            // （原 v4.5.0 的 GirlCompanionView 悬浮已移除；GirlCompanion.enabled 仍用于 AppMain 自动拉起桌面悬浮）
        }
        .navigationViewStyle(.stack)
        // v2.9.31：授权弹窗已整体移除（工具搜索即自动授权，无弹窗）。
        .sheet(item: $attachmentSheet, onDismiss: {
            // v3.1.67：面板完全关闭后再触发文件选择（UIKit 从顶层 VC present，真机稳定）
            // v3.1.70：延迟 0.6s 再 present——onDismiss 触发时 SwiftUI sheet 的关闭动画
            // （约 0.5s）还没完全结束，立即 present 的 UIDocumentPicker 会被 sheet 收尾逻辑
            // 顶掉，表现为"弹出 0.5 秒后自动退回聊天界面"（真机实测 bug）
            if pendingFilePick {
                pendingFilePick = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Self.presentDocumentPicker { urls in
                        handlePickedFiles(urls)
                    }
                }
            }
        }) { sheet in
            switch sheet {
            case .panel:
                // v2.9.35：传已选数量，面板右上角显示"已选 N"（对齐老 MCP）
                // 紧凑半屏（老 MCP"添加内容"卡片式）；presentationDetents 需 iOS16+
                if #available(iOS 16.0, *) {
                    AttachmentPanelView(onPick: { pick in
                        // v2.9.39：浏览器入口直接开悬浮窗（不占 sheet）
                        // v3.1.67：文件入口不再用 .fileImporter（真机有 bug），改记 pendingFilePick，
                        // 由 sheet onDismiss 在面板完全关闭后触发 UIKit 文档选择器
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                        .sheetDetentsHeight(340)   // v2.9.37：4 入口 2×2 网格需更高
                } else {
                    AttachmentPanelView(onPick: { pick in
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                }
            case .browser:
                // v2.9.39：浏览器已改为悬浮窗，面板入口在 onPick 闭包里直接开悬浮窗
                EmptyView()
            case .appPicker:
                AppPickerView { app in
                    // v2.9.10：应用选择 → 附件预览（图标 + 名称 + bundleId）
                    let icon = Self.appIcon(for: app.path)
                    let att = PendingAttachment(
                        kind: .app,
                        displayName: app.name,
                        dataURL: nil,
                        thumbnail: icon,
                        bundleId: app.bundleId,
                        fileURL: nil
                    )
                    self.pendingAttachments.append(att)
                    // v2.9.61：不再往输入框塞 [📱应用] 标签，附件只在上方预览条显示（微信风格），发送时自动生成描述
                }
            case .photoPicker:
                PhotoPickerView { urls in
                    // v2.9.9：真正把图片内容转 base64 传给模型（不再只是文件名）
                    var dataURLs: [String] = []
                    var names: [String] = []
                    for u in urls {
                        if let d = Self.imageDataURL(for: u) {
                            dataURLs.append(d)
                            names.append(u.lastPathComponent)
                            // v2.9.10：同时生成带缩略图的附件，输入栏预览
                            let thumb = UIImage(contentsOfFile: u.path)
                            self.pendingAttachments.append(PendingAttachment(
                                kind: .image,
                                displayName: u.lastPathComponent,
                                dataURL: d,
                                thumbnail: thumb,
                                bundleId: nil,
                                fileURL: u
                            ))
                        }
                    }
                    // v2.9.61：图片缩略图在预览条显示，不再往输入框塞 [🖼图片] 标签
                    if dataURLs.isEmpty {
                        self.pendingImages = []
                    } else {
                        self.pendingImages = dataURLs
                    }
                }
            case .documentPicker:
                // v3.1.67：文件选择已改用 UIKit UIDocumentPickerViewController（见 onDismiss + presentDocumentPicker），
                // .fileImporter 在真机 iPhone 有已知 bug，弃用
                EmptyView()
            }
        }
        // v2.9.36：聊天框切换上游模型（点"当前模型"弹出，老 MCP 风格半屏）
        .sheet(isPresented: $showModelPicker) {
            // 老 MCP 半屏；presentationDetents 需 iOS16+
            if #available(iOS 16.0, *) {
                ChatModelPickerSheet { cfg in
                    // 点选即切换默认模型
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast(L10n.t("i18n_1033", cfg.name))
                }
                .sheetDetentsHeight(360)
            } else {
                ChatModelPickerSheet { cfg in
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast(L10n.t("i18n_1033", cfg.name))
                }
            }
        }
        // v3.0.76：快捷标签 sheet
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickTerminalPresented }, set: { AppUIState.shared.quickTerminalPresented = $0 })) {
            RemoteTerminalView()
        }
        // v7.0.4：聊天框终端按钮 → 简易终端（统一环境 shell.exec）
        .sheet(isPresented: $showTerminal) {
            TerminalView()
        }
        // v6.1.5-14bm：/tools → 工具中心（三层工具总览，给用户看）
        .sheet(isPresented: $showToolCenter) {
            ToolCenterView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickToolsPresented }, set: { AppUIState.shared.quickToolsPresented = $0 })) {
            ToolCenterView()   // v6.1.5-14bo：快捷"工具"入口统一到工具中心（原 ToolsView 分类浏览与工具中心重复）
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickSkillsPresented }, set: { AppUIState.shared.quickSkillsPresented = $0 })) {
            AgentsAndSkillsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickFilesPresented }, set: { AppUIState.shared.quickFilesPresented = $0 })) {
            WorkspaceBrowserView()
        }
        // v2.9.10：网络恢复 / 回前台提示（配合后台自动重连）
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            showToast(L10n.t("i18n_1034"))
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.willEnterForeground)) { _ in
            if AppLifecycleMonitor.shared.isNetworkAvailable {
                showToast(L10n.t("i18n_1035"))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.t("home_empty_title"))
                .font(.headline)
            Text(L10n.t("home_empty_sub"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var homeState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 30)
                // v6.0.28：首页直接显示App图标，去掉外面的蓝色圆环，避免两层蓝色叠在一起
                ZStack {
                    Group {
                        if let appIcon = UIImage(named: "AppIcon60x60@3x") ?? UIImage(named: "AppIcon1024x1024") {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 8)
                        } else {
                            Image(systemName: "cpu")
                                .font(.system(size: 56))
                                .foregroundColor(.white)
                                .frame(width: 140, height: 140)
                                .background(
                                    LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .cornerRadius(26)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Text(L10n.t("home_greeting"))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(L10n.t("home_subtitle"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 28)
                }

                // 两大主卡
                VStack(spacing: 12) {
                    QuickActionCard(
                        icon: "square.grid.2x2",
                        title: L10n.t("home_analyze_apps"),
                        subtitle: L10n.t("home_analyze_apps_sub"),
                        colors: [.tmCyan, .blue]
                    ) {
                        runQuickPrompt(L10n.t("i18n_1243"))
                    }
                    QuickActionCard(
                        icon: "memorychip",
                        title: L10n.t("home_check_device"),
                        subtitle: L10n.t("home_check_device_sub"),
                        colors: [.green, .tmTeal]
                    ) {
                        runQuickPrompt(L10n.t("i18n_1244"))
                    }
                }
                .padding(.horizontal, 20)

                // v2.9.78：快速开始引导区（能力卡片，点击即发示例指令）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.tmCyan)
                        Text(L10n.t("home_quick_title"))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    Text(L10n.t("home_quick_sub"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    miniCard("hammer.fill", L10n.t("home_quick_compile"), L10n.t("home_quick_compile_sub"), [.orange, .tmBrown], promptId: "developer") {
                        runQuickPrompt(L10n.t("i18n_1233"))
                    }
                    miniCard("syringe.fill", L10n.t("home_quick_inject"), L10n.t("home_quick_inject_sub"), [.green, .tmTeal], promptId: "reverse") {
                        runQuickPrompt(L10n.t("i18n_1234"))
                    }
                    miniCard("memorychip.fill", L10n.t("home_quick_memory"), L10n.t("home_quick_memory_sub"), [.purple, .tmIndigo], promptId: "gamehacker") {
                        runQuickPrompt(L10n.t("i18n_1235"))
                    }
                    miniCard("cursorarrow.click.2", L10n.t("home_quick_ui"), L10n.t("home_quick_ui_sub"), [.tmCyan, .blue], promptId: "uicontrol") {
                        runQuickPrompt(L10n.t("i18n_1236"))
                    }
                    miniCard("stethoscope", L10n.t("home_quick_env"), L10n.t("home_quick_env_sub"), [.tmCyan, .teal], promptId: "qa") {
                        runQuickPrompt(L10n.t("i18n_1237"))
                    }
                    miniCard("antenna.radiowaves.left.and.right", L10n.t("home_quick_capture"), L10n.t("home_quick_capture_sub"), [.orange, .red], promptId: "pentester") {
                        runQuickPrompt(L10n.t("i18n_1238"))
                    }
                    miniCard("trash.circle.fill", L10n.t("home_quick_clean"), L10n.t("home_quick_clean_sub"), [.purple, .blue], promptId: "privacy") {
                        runQuickPrompt(L10n.t("i18n_1239"))
                    }
                    miniCard("globe", L10n.t("home_quick_browser"), L10n.t("home_quick_browser_sub"), [.red, .orange], promptId: "default") {
                        runQuickPrompt(L10n.t("i18n_1240"))
                    }
                    miniCard("bolt.fill", L10n.t("home_quick_automation"), L10n.t("home_quick_automation_sub"), [.blue, .purple], promptId: "default") {
                        runQuickPrompt(L10n.t("i18n_1241"))
                    }
                    miniCard("wrench.and.screwdriver.fill", L10n.t("home_quick_dev"), L10n.t("home_quick_dev_sub"), [.green, .blue], promptId: "developer") {
                        runQuickPrompt(L10n.t("i18n_1242"))
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
    }

    /// v2.9.78：首页能力小卡片（两列网格）
    /// v3.1.1: 点卡片时自动切换到对应的系统指令模式
    private func miniCard(_ icon: String, _ title: String, _ subtitle: String, _ colors: [Color], promptId: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            // 自动切换到对应的系统指令模式
            if let pid = promptId {
                SystemPrompts.shared.select(pid)
            }
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors[0].opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func runQuickPrompt(_ text: String) {
        guard let cfg = modelStore.defaultConfig else { return }
        if store.selectedId == nil { store.newConversation() }
        inputText = ""
        store.send(text, using: cfg, reasoningLevel: thinkEnabled ? reasoning : 5, smartSearch: smartSearch)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // v7.2.3-fix20：连续工具折叠——相邻已完成工具消息聚合成组，
                    // 组默认一行"运行了 N 个工具"，展开显示各工具卡
                    ForEach(ChatListGrouping.group(store.currentMessages), id: \.id) { item in
                        switch item {
                        case .msg(let msg):
                            MessageBubble(
                                message: msg,
                                selectionMode: selectionMode,
                                isSelected: selectedIds.contains(msg.id),
                                onToggleSelect: { toggleSelect(msg.id) },
                                onCopy: { copyMessage(msg) },
                                onShare: { shareMessage(msg) },
                                isStreaming: store.streamingMessageId == msg.id,
                                forceType: store.liveProducedID == msg.id,
                                thinkEnabled: thinkEnabled
                            )
                            .id(msg.id)
                        case .tools(let msgs):
                            toolsRunGroup(msgs)
                        }
                    }
                    if store.isLoading {
                        // v2.9.34：请求过程可视化（对齐老 MCP 的"正在思考"面板）
                        // v2.9.127：改为实时执行轨迹（豆包工作任务/Codex 式步骤流）
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack {
                                Spacer()
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(L10n.t("home_thinking"))
                                        .font(.footnote.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                // v3.1.66：tertiarySystemBackground 浅色模式≈白看不见，改 systemGray5
                                .background(Color(.systemGray5).opacity(0.9))
                                .cornerRadius(14)
                                .padding(.trailing, 16)
                            }
                            if store.isLoading, !store.liveTrail.isEmpty {
                                LiveTrailCard(steps: store.liveTrail)
                                    .padding(.trailing, 16)
                            }
                            if let status = store.statusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 16)
                            }
                            if store.requestRound > 0 {
                                // v4.3.71：无轮次上限 (requestRounds==0) 只显示"第 N 轮"
                                if store.requestRounds > 0 {
                                    Text(L10n.t("ui_157", store.requestRound, store.requestRounds))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.trailing, 16)
                                } else {
                                    Text(L10n.t("i18n_1036", store.requestRound))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.trailing, 16)
                                }
                            }
                        }
                    }
                }
                // v3.4.0：去掉整行水平 padding —— AI 气泡改为真正占满左右屏边缘；
                // 用户气泡的右留白由 MessageBubble 内部按 isUser 处理
                .padding(.vertical, 12)
            }
            // 点击聊天区空白处收起键盘（v2.9.9）
            .simultaneousGesture(
                TapGesture().onEnded { dismissKeyboard() }
            )
            .onChange(of: store.currentMessages.count) { _ in
                if let last = store.currentMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // v2.9.12：打开/切换会话时自动滚到底（老会话不再停在顶部）
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: store.selectedId) { _ in
                scrollToBottom(proxy)
            }
            // v2.9.72：AI 回复完成时结束工作流
            .onChange(of: store.isLoading) { loading in
                if !loading {
                    WorkflowManager.shared.finishRun(success: true)
                }
                // v7.1.109-peers：请求完成 → 刷新上下文环形指示器（records 读文件，仅此刻读一次）
                if !loading { refreshRingTok() }
            }
            .onAppear { refreshRingTok() }
            // v2.9.235：键盘高度变化→自动滚到底（高度本身由外层 VStack 监听，空会话也能避让键盘）
            .onChange(of: keyboardHeight) { _ in
                if keyboardHeight > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let last = store.currentMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// v2.9.12：滚到当前会话最新一条
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if let last = store.currentMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// v3.4.3：模型名已移入导航栏 principal（与标题、右侧图标同一平行线），此处不再占用正文顶部
    private var chatModeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // v3.4.5：六个胶囊统一同宽同高（76×32），比例完全一致、长度略长
                // v3.4.7：推理用"大脑"图标、思考用"灯泡"图标（用户指定，勿对调）
                ChatChip(label: L10n.t("i18n_1037", reasoningLabel()), action: {
                    reasoning = (reasoning + 1) % 5
                }, accent: true, icon: "brain").frame(height: 36)
                ChatChip(label: L10n.t("i18n_1086", thinkEnabled ? L10n.t("i18n_1088") : L10n.t("i18n_1089")), action: {
                    thinkEnabled.toggle()
                }, accent: thinkEnabled, icon: "lightbulb").frame(height: 36)
                ChatChip(label: L10n.t("i18n_1087", smartSearch ? L10n.t("i18n_1088") : L10n.t("i18n_1089")), action: {
                    smartSearch.toggle()
                }, accent: smartSearch, icon: "magnifyingglass").frame(height: 36)
                QuickTabButton(icon: "bolt", label: L10n.t("i18n_1038")) {
                    AppUIState.shared.quickSkillsPresented = true
                }.frame(height: 36)
                QuickTabButton(icon: "doc.text", label: L10n.t("i18n_1039")) {
                    // v4.4.16：点"指令"→ 打开设置并真正跳到系统指令页(此前只打开设置,未定位到 SystemPromptsView, 用户实测'没真正跳到')
                    AppUIState.shared.settingsJumpToModels = false
                    AppUIState.shared.settingsJumpToSystemPrompts = true
                    AppUIState.shared.settingsPresented = true
                }.frame(height: 36)
                QuickTabButton(icon: "folder", label: L10n.t("i18n_1040")) {
                    AppUIState.shared.quickFilesPresented = true
                }.frame(height: 36)
                // v7.1.109-peers：上下文指示（Minis 式文字 + Cursor 式圆环）——行尾，不占胶囊位
                contextText
                    .padding(.leading, 4)
                contextRing
                    .padding(.leading, 2)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }
            // v3.4.5：功能行（推理/思考/搜索/系统指令/技能/工作区）——胶囊与输入框、与上方都留
            // 等距 16pt 间隙（上下对称，间距比之前加大）
            // v7.1.109-peers：环形指示器并入行尾（用户去掉了输出模式胶囊条，保留 token 占用环）
            chatModeBar
                // v4.4.11：左边距 12→16（用户反馈推理贴左无空格）
                .padding(.horizontal, 16)
                // v3.4.7：顶部间距减半(16→8)，用户反馈上方空太多；底部 16 保留(胶囊到输入框的加大间距)
                .padding(.top, 8)
                .padding(.bottom, 16)

            // v3.0.83：输入栏 —— 终端键 + 输入框 + +号 + 发送键 统一放进同一个大圆角框
            HStack(spacing: 6) {
                Button(action: {
                    showTerminal = true   // v7.0.4：打开简易终端（原为远程终端设置页）
                }) {
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                ChatInputTextView(text: $inputText, onSend: { send() }, height: $inputHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: inputHeight)

                // v3.3.4：+ 号 → 展开"应用/相册/文件/浏览器"快捷行；再点变 x 收起
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        attachExpanded.toggle()
                    }
                }) {
                    Image(systemName: attachExpanded ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(attachExpanded ? Color.gray : Color.blue)
                        .clipShape(Circle())
                }
                // v2.9.35：+号 → 半屏"添加内容"面板（对齐老 MCP 设计），不再用 actionSheet
                // （iOS16 actionSheet 偶发点击无响应 + 无"已选 N"徽标）
                // v2.9.36：移除麦克风按钮（语音无实际作用）

                // v2.9.13：请求中时按钮变为"停止"，点击取消当前请求 (v4.5.8：仅当前选中会话在请求时显示，
                // 切到别的会话不误显示停止）
                if store.selectedIsRequesting {
                    Button(action: { store.cancelCurrent() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(inputText.isEmpty ? Color.gray : Color.blue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // v3.3.4：整行放进一个大圆角框（终端键/输入框/+号/发送键 一体）
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            // v3.4.5：输入框外阴影渐变，往外扩散越来越淡（多层 shadow 叠加模拟渐变发光）
            // v3.4.7：改为灰色扩散、且收敛——用户反馈蓝色扩散太多，应偏灰
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 12)
            // v6.1.5-14bl：/命令 与 @提及 快捷菜单（输入框上方弹出）
            .overlay(alignment: .bottom) {
                if inputText.hasPrefix("/") {
                    commandQuickMenu
                } else if inputText.hasPrefix("@") {
                    appMentionQuickMenu
                }
            }

            // v3.4.2：点 + 底部弹出 应用/相册/文件/浏览器，把聊天框顶起来（位于输入框下方）
            if attachExpanded {
                attachQuickRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        // v2.9.30：授权弹窗已移出到 NavigationView 外层（见 body 链），
        // 此处不再挂 actionSheet，避免与上方 +号 的 actionSheet 同 view 覆盖。
    }

    private func reasoningLabel() -> String {
        // v4.3.40：档位扩为 低/中/高/最高/极限——最高档=xhigh, 极限档=max (破甲站 gpt-6.1-sol 实测支持 low/medium/high/xhigh/max)
        let labels = [L10n.t("i18n_1041"), L10n.t("i18n_1042"), L10n.t("i18n_1043"), L10n.t("i18n_1044"), L10n.t("i18n_1045")]
        return reasoning >= 0 && reasoning < labels.count ? labels[reasoning] : L10n.t("i18n_1043")
    }

    // v7.1.109-peers：上下文环形指示器（Cursor 式）+ 文字指示（Minis 式"5%·53.7k/1000k"）——
    // 最近请求真实/估算 token 占当前模型实际上下文窗口比例
    // 数据缓存于 @State（audit：records 每次读全文件，不能在 body 渲染里高频读）
    @State private var ringTok = 0
    private func refreshRingTok() {
        let rec = UsageRecorder.shared.records.last
        let total = rec?["totalTokens"] as? Int ?? 0
        let est = rec?["estInputTokens"] as? Int ?? 0
        ringTok = total > 0 ? total : est
    }
    // v7.1.109-peers：上下文指示总量——与压缩预算同源（effectiveContextTokens：收录模型=真实窗口，
    // 未收录=用户配置 contextTokens），避免"UI 显示 200k、实际预算 16k"的显示/行为矛盾
    private var currentContextWindow: Int {
        modelStore.defaultConfig?.effectiveContextTokens ?? 200_000
    }
    private func fmtTok(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1000 { return String(format: "%.1fk", Double(t) / 1000) }
        return "\(t)"
    }
    // v7.1.109-peers：Minis 式上下文文字——"5%·53.7k/1000k"（百分比·当前/总量）
    private var contextText: some View {
        let tok = ringTok
        let window = currentContextWindow
        let pct = window > 0 ? min(100, Int(Double(tok) / Double(window) * 100)) : 0
        return Text("\(pct)%·\(fmtTok(tok))/\(fmtTok(window))")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .accessibilityLabel(L10n.t("i18n_1254"))
    }
    private var contextRing: some View {
        let tok = ringTok
        let window = currentContextWindow
        let ratio: CGFloat = tok > 0 ? min(1.0, CGFloat(tok) / CGFloat(window)) : 0
        return ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(tokText(tok))
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(L10n.t("i18n_1254"))
    }

    private func tokText(_ t: Int) -> String {
        if t >= 1000 { return String(format: "%.0fk", Double(t) / 1000) }
        return "\(t)"
    }

    /// v3.3.4：+ 展开的快捷附件行（应用 / 相册 / 文件 / 浏览器），对齐微信式附件栏
    /// v3.4.2：从左屏幕边缘到右屏幕边缘均匀分布——四格等宽、间隙一致（含两侧边缘间隙）
    private var attachQuickRow: some View {
        HStack(spacing: 12) {
            attachQuickButton("apps.iphone", L10n.t("i18n_1046")) {
                withAnimation { attachExpanded = false }
                attachmentSheet = .appPicker
            }
            .frame(maxWidth: .infinity)
            attachQuickButton("photo.on.rectangle", L10n.t("i18n_1047")) {
                withAnimation { attachExpanded = false }
                attachmentSheet = .photoPicker
            }
            .frame(maxWidth: .infinity)
            attachQuickButton("folder", L10n.t("i18n_1048")) {
                withAnimation { attachExpanded = false }
                // v3.3.4：快捷行直接弹 UIKit 文档选择器（无需半屏面板中转）
                Self.presentDocumentPicker { urls in
                    handlePickedFiles(urls)
                }
            }
            .frame(maxWidth: .infinity)
            attachQuickButton("globe", L10n.t("i18n_1049")) {
                withAnimation { attachExpanded = false }
                attachmentSheet = nil
                FloatingBrowser.shared.show()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        // v3.4.8：附件行与输入框之间留出明显间隔（参考图）
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func attachQuickButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // v3.4.8：方形圆角瓦片（参考图：相机/图片/文件/打电话样式），不再是圆形
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// v2.9.93：按模型名识别供应商图标
    private func modelIcon(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("deepseek") { return "d.circle.fill" }
        if m.contains("claude") { return "c.circle.fill" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return "sparkles" }
        if m.contains("glm") || m.contains("qwen") || m.contains("kimi") { return "brain" }
        if m.contains("gemini") { return "sparkle.magnifyingglass" }
        return "cpu"
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig,
              (!inputText.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty) else { return }
        // v3.1.5: 自动提取关键信息（App 名、bundle id、文件路径等）
        AutoContextExtractor.shared.extract(from: inputText)
        // v3.1.1: 模型不支持视觉时，自动 OCR 识别图片文字，拼到消息里
        var imagesToSend = pendingImages
        if !pendingImages.isEmpty && !cfg.supportsVision {
            // 自动 OCR：把图片文字识别出来，拼到消息里
            var ocrTexts: [String] = []
            for (i, imgData) in pendingImages.enumerated() {
                if let data = Data(base64Encoded: imgData.replacingOccurrences(of: "data:image/png;base64,", with: "").replacingOccurrences(of: "data:image/jpeg;base64,", with: "")) {
                    let tmpPath = NSTemporaryDirectory() + "ocr_\(i).png"
                    try? data.write(to: URL(fileURLWithPath: tmpPath))
                    if let ocrResult = try? OCRImageTool().invoke(["path": tmpPath]),
                       let text = ocrResult["text"] as? String, !text.isEmpty {
                        ocrTexts.append(L10n.t("i18n_1050", i+1, text))
                    }
                    try? FileManager.default.removeItem(atPath: tmpPath)
                }
            }
            if !ocrTexts.isEmpty {
                inputText = inputText + "\n\n" + ocrTexts.joined(separator: "\n\n")
                imagesToSend = [] // 去掉图片，只发文字
                showToast(L10n.t("i18n_1051"))
            }
        }
        // v2.9.72：启动工作流可视化
        WorkflowManager.shared.startRun(L10n.t("i18n_1052"))
        if store.selectedId == nil { store.newConversation() }
        var text = inputText
        let imgs = pendingImages
        // v2.9.61：输入框不再有 [📱应用] 占位标签，发送时自动把应用/文件附件拼成描述文字
        let appAtts = pendingAttachments.filter { if case .app = $0.kind { return true }; return false }
        let fileAtts = pendingAttachments.filter { if case .file = $0.kind { return true }; return false }
        var attDesc: [String] = []
        for att in appAtts {
            let bid = att.bundleId ?? "unknown"
            attDesc.append(L10n.t("i18n_1053", att.displayName, bid))
        }
        for att in fileAtts {
            // v2.9.291：文件附件自动复制到工作区 uploads/ 并附加路径——
            // 之前只发 [📎文件：xxx] 描述，AI 根本没有文件内容/路径可读，
            // 导致"找不到 .deb"（文件在用户本地文件App里，AI 视野外）
            let saved = Self.saveAttachmentToWorkspace(att)
            if let sp = saved {
                // v3.1.70：去掉"可用 artifact / shell.exec 读取分析"工具残留（用户反馈），
                // 只保留路径——AI 的 fs 工具集本身就能读，无需在消息里提示
                attDesc.append(L10n.t("i18n_1054", att.displayName, sp))
            } else {
                attDesc.append(L10n.t("i18n_1055", att.displayName, Workspace.root.path))
            }
        }
        if !attDesc.isEmpty {
            text = text.isEmpty ? attDesc.joined(separator: " ") : text + " " + attDesc.joined(separator: " ")
        }
        inputText = ""
        pendingImages = []
        // v2.9.10：附件预览与发送联动——从附件里取图片 dataURL（若预览被删则不再发送）
        let attImgs = pendingAttachments.compactMap { $0.dataURL }
        pendingAttachments = []
        let finalImgs = attImgs.isEmpty ? imagesToSend : attImgs
        // v3.4.1：思考总开关接入主发送路径（此前漏传，思考·开/关在输入框无效）
        store.send(text, using: cfg, imageDataURLs: finalImgs, reasoningLevel: thinkEnabled ? reasoning : 3, smartSearch: smartSearch)
        AuditLog.shared.log("chat", detail: L10n.t("i18n_1056"))
    }

    /// v2.9.9：图片文件 → base64 data URL
    /// v2.9.292：降采样到最长边 1200px + JPEG q60 压缩——之前只限 3MB 不压缩，
    /// 单张原图 base64 可达 2-4MB，历史里每张图每次请求全量重发 → 卡住/超时。
    /// 压缩后单张 ~100-250KB，省 token 且不卡。
    static func imageDataURL(for url: URL) -> String? {
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let maxDim: CGFloat = 1200
        var out = img
        if max(img.size.width, img.size.height) > maxDim {
            let scale = maxDim / max(img.size.width, img.size.height)
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            out = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
        }
        guard let data = out.jpegData(compressionQuality: 0.6) else { return nil }
        let limit = 3 * 1024 * 1024
        if data.count > limit { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// v2.9.291：把聊天文件附件复制到工作区 uploads/ 目录，返回保存后的绝对路径
    /// - 处理 security-scoped URL（UIDocumentPicker 返回的 URL 需 startAccessing）
    /// - 文件名冲突时追加时间戳，避免覆盖
    static func saveAttachmentToWorkspace(_ att: PendingAttachment) -> String? {
        guard let src = att.fileURL else { return nil }
        var scoped = false
        if src.startAccessingSecurityScopedResource() { scoped = true }
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src), data.count > 0 else { return nil }
        let uploads = Workspace.root.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        var name = src.lastPathComponent
        if name.isEmpty { name = att.displayName }
        var dest = uploads.appendingPathComponent(name)
        // 重名冲突：追加 -<时间戳>
        if FileManager.default.fileExists(atPath: dest.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            dest = uploads.appendingPathComponent("\(base)-\(ts).\(ext)")
        }
        do {
            try data.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// v2.9.10：读取应用图标（用于输入栏附件预览）
    // v6.0.30: app图标内存缓存，所有用到图标的地方自动秒开
    private static let iconCache = NSCache<NSString, UIImage>()
    static func appIcon(for path: String) -> UIImage? {
        // 先查缓存
        if let cached = iconCache.object(forKey: path as NSString) {
            return cached
        }
        guard let info = Bundle(path: path)?.infoDictionary,
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        let p = (path as NSString).appendingPathComponent(last + "@2x.png")
        let img = UIImage(contentsOfFile: p) ?? UIImage(contentsOfFile: (path as NSString).appendingPathComponent(last + ".png"))
        if let img = img {
            iconCache.setObject(img, forKey: path as NSString)
        }
        return img
    }

    // MARK: - v3.1.67：UIKit 文档选择器（真机稳定方案，替代 .fileImporter）

    /// 从顶层 VC present UIDocumentPickerViewController（asCopy: true）。
    /// - 真机 iPhone 上 .fileImporter 有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    ///   UIKit 方案在真机完全正常（最早版本能打开文件就是用的 UIKit 方案）。
    /// - asCopy: true 让系统把所选文件复制进 App 沙盒，返回的 URL 直接可读、不会失效，
    ///   无需 startAccessingSecurityScopedResource，也彻底绕开"临时 URL 失效"问题。
    static func presentDocumentPicker(onPick: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .formSheet
        // coordinator 必须被强引用，否则 delegate 回调不触发
        let coordinator = DocumentPickerCoordinator(onPick: onPick)
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// 找到当前最顶层的 UIViewController（绕开 SwiftUI sheet 层级问题，直接往 key window 上 present）
    private static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    /// 选择完成：复制到工作区 uploads/（asCopy 已复制进沙盒，这里再落到 uploads 统一管理 + 防重名）
    private func handlePickedFiles(_ urls: [URL]) {
        for u in urls {
            let att = PendingAttachment(
                kind: .file,
                displayName: u.lastPathComponent,
                dataURL: nil,
                thumbnail: nil,
                bundleId: nil,
                fileURL: u
            )
            if let saved = Self.saveAttachmentToWorkspace(att) {
                self.pendingAttachments.append(PendingAttachment(
                    kind: .file,
                    displayName: u.lastPathComponent,
                    dataURL: nil,
                    thumbnail: nil,
                    bundleId: nil,
                    fileURL: URL(fileURLWithPath: saved)
                ))
            } else {
                self.pendingAttachments.append(att)
            }
        }
    }

    // MARK: - 多选 / 复制 / 分享（v2.9.2）

    private func enterSelection() {
        selectionMode = true
        selectedIds = []
    }

    private func exitSelection() {
        selectionMode = false
        selectedIds = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func copyMessage(_ m: ChatMessage) {
        UIPasteboard.general.string = m.content
        showToast(L10n.t("i18n_1197"))
    }

    /// v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——AI 摘要替换旧历史并持久化，不发主请求
    private func compactNow() {
        store.compactNow { ok, msg in
            DispatchQueue.main.async {
                self.showToast(msg)
            }
        }
    }

    private func shareMessage(_ m: ChatMessage) {
        presentShareSheet(text: m.content)
    }

    private func copySelected() {
        let count = selectedIds.count
        UIPasteboard.general.string = exportText()
        exitSelection()
        showToast(count > 0 ? L10n.t("i18n_1057", count) : L10n.t("i18n_1197"))
    }

    private func shareSelected() {
        presentShareSheet(text: exportText())
    }

    // v4.3.46：文字分享 → 自建分享菜单（拷贝 / 存储到文件），绕开 ShareSheet
    private func presentShareSheet(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast(L10n.t("i18n_1058"))
            return
        }
        ShareCenter.shared.presentShareMenuText(content)
    }

    /// 把勾选的消息拼成可读文本（按会话内顺序），用于复制 / 分享。
    private func exportText() -> String {
        let msgs = store.currentMessages.filter { selectedIds.contains($0.id) }
        guard !msgs.isEmpty else { return "" }
        var parts: [String] = []
        let title = store.currentTitle
        if !title.isEmpty && title != L10n.t("i18n_1059") {
            parts.append("【\(title)】")
        }
        for m in msgs {
            parts.append(formatted(m))
        }
        return parts.joined(separator: "\n\n")
    }

    private func formatted(_ m: ChatMessage) -> String {
        switch m.role {
        case "user":
            return L10n.t("i18n_1060", m.content)
        case "tool":
            let name = m.toolName.map { "（\($0)）" } ?? ""
            return L10n.t("i18n_1061", name, m.content)
        default:
            return m.content
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showToast = false }
        }
    }

    // v6.1.5-14bl：/命令 快捷菜单
    private var commandQuickMenu: some View {
        let items: [(String, String, String)] = [
            ("/clear", "trash", L10n.t("i18n_1062")),
            ("/new", "square.and.pencil", L10n.t("i18n_1063")),
            ("/model", "cpu", L10n.t("i18n_1064")),
            ("/tools", "wrench.and.screwdriver", L10n.t("i18n_1065")),
        ]
        return VStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                Button(action: { runQuickCommand(item.0) }) {
                    HStack(spacing: 10) {
                        Image(systemName: item.1)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 22)
                        Text(item.0)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(item.2)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                if item.0 != items.last!.0 {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // v6.1.5-14bl：@提及 应用快捷菜单（复用 AppCatalog 已装应用列表）
    private var appMentionQuickMenu: some View {
        let apps = AppCatalog.list()
        return VStack(spacing: 0) {
            ForEach(Array(apps.prefix(24).enumerated()), id: \.element.bundleId) { _, app in
                Button(action: { mentionApp(app) }) {
                    HStack(spacing: 10) {
                        if let ic = Self.appIcon(for: app.path) {
                            Image(uiImage: ic)
                                .resizable()
                                .frame(width: 22, height: 22)
                                .cornerRadius(5)
                        } else {
                            Image(systemName: "app.fill")
                                .foregroundColor(.secondary)
                        }
                        Text(app.name)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(app.bundleId)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func runQuickCommand(_ name: String) {
        switch name {
        case "/clear": store.clearCurrent(); showToast(L10n.t("i18n_1066"))
        case "/new": store.newConversation(); showToast(L10n.t("i18n_1067"))
        case "/model": showModelPicker = true
        case "/tools": showToolCenter = true
        default: break
        }
        inputText = ""
    }

    private func mentionApp(_ app: AppCatalog.AppEntry) {
        let icon = Self.appIcon(for: app.path)
        let att = PendingAttachment(kind: .app, displayName: app.name, dataURL: nil, thumbnail: icon, bundleId: app.bundleId, fileURL: nil)
        pendingAttachments.append(att)
        inputText = inputText.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces)
        showToast(L10n.t("i18n_1068", app.name))
    }
    @ViewBuilder
    private func toolsRunGroup(_ msgs: [ChatMessage]) -> some View {
        let gid = "t-" + (msgs.first?.id.uuidString ?? "") + "-" + String(msgs.count)
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if toolsRunExpanded.contains(gid) {
                        toolsRunExpanded.remove(gid)
                    } else {
                        toolsRunExpanded.insert(gid)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text(String(format: L10n.t("i18n_1260"), msgs.count))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    if let d = ChatListGrouping.Item.tools(msgs).totalDuration {
                        Text(String(format: "%.1fs", d))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Image(systemName: toolsRunExpanded.contains(gid) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                // v7.2.3-fix26：去 Spacer——此前 HStack 内 Spacer 把 Button 撑满整行，
                // 灰色背景条贴屏幕两端；改内容自适应宽度（对齐灰色气泡/胶囊样式）
                // v7.2.3-fix31：纯内容宽度太窄（≈150pt）+ footnote 小字 → 加最小宽度
                // 160pt + 字号整体放大（footnote13→subheadline15、caption2 11→caption12）
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minWidth: 160)
                .background(Color(.systemGray5).opacity(0.6))
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            if toolsRunExpanded.contains(gid) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(msgs) { msg in
                        MessageBubble(
                            message: msg,
                            selectionMode: selectionMode,
                            isSelected: selectedIds.contains(msg.id),
                            onToggleSelect: { toggleSelect(msg.id) },
                            onCopy: { copyMessage(msg) },
                            onShare: { shareMessage(msg) },
                            isStreaming: store.streamingMessageId == msg.id,
                            forceType: store.liveProducedID == msg.id,
                            thinkEnabled: thinkEnabled
                        )
                        .id(msg.id)
                    }
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(width: 3)
                        .cornerRadius(1.5)
                }
            }
        }
    }
}

struct ChatChip: View {
    let label: String
    let action: () -> Void
    // v2.9.36：浅蓝=开启/强调，灰=关闭（老 MCP 风格）
    var accent: Bool = true
    // v2.9.79：前置小图标（推理强度 / 智能搜索）
    var icon: String = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(accent ? Color.blue.opacity(0.14) : Color(.systemGray5))
            .foregroundColor(accent ? Color.blue : Color.secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accent ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v3.0.76：输入框上方快捷标签按钮
struct QuickTabButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(height: 36)
            // v3.4.4：与 ChatChip 统一内边距/圆角，保证滑动模块比例一致
            .padding(.horizontal, 10)
            .background(Color(.secondarySystemBackground))
            .foregroundColor(.secondary)
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v2.9.36：聊天框"当前模型"点击弹出的上游模型选择（老 MCP 风格半屏）
struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    let onSelect: (ModelConfig) -> Void
    // v7.1.95：首页切换模型弹窗直接获取上游模型并切换（用户要求）
    @State private var fetchedModels: [String] = []
    @State private var showingUpstreamModelPicker = false
    @State private var isFetchingModels = false
    @State private var fetchError = ""

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: L10n.t("i18n_1069"))) {
                    ForEach(modelStore.configs) { cfg in
                        Button(action: { onSelect(cfg) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cfg.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("\(cfg.model) · \(cfg.provider)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if cfg.isDefault {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                // v7.1.95：直接获取当前默认配置的上游模型列表并切换（用户要求：
                // '获取上游模型可以在首页顶部切换模型里点击就能获取上游模型进行切换'）
                if let cfg = modelStore.defaultConfig {
                    Section {
                        Button(action: {
                            isFetchingModels = true
                            fetchError = ""
                            ModelAPIClient.shared.fetchModelList(config: cfg) { result in
                                isFetchingModels = false
                                switch result {
                                case .success(let models):
                                    fetchedModels = models
                                    if models.isEmpty {
                                        fetchError = L10n.t("i18n_428")
                                    } else {
                                        showingUpstreamModelPicker = true
                                    }
                                case .failure(let error):
                                    fetchError = error
                                }
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                                Text(L10n.t("ui_128"))
                                    .foregroundColor(.blue)
                                Spacer()
                                if isFetchingModels { ProgressView() }
                            }
                            .font(.footnote)
                        }
                        .disabled(isFetchingModels)
                        if !fetchError.isEmpty {
                            Text(fetchError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .sheet(isPresented: $showingUpstreamModelPicker) {
                        ModelPickerSheet(models: fetchedModels, selected: Binding(
                            get: { modelStore.defaultConfig?.model ?? "" },
                            set: { newModel in
                                if var c = modelStore.defaultConfig {
                                    c.model = newModel
                                    modelStore.update(c)   // 保持默认 + 同步共享文件（HUD 语音同用）
                                    onSelect(c)            // 外层关 sheet + toast 提示已切换
                                }
                            }
                        ))
                    }
                }
                Section {
                    // v7.1.97：弹窗内直接 push 模型 API 页（原"开设置再跳"链路：
                    // 半屏 sheet 挂着 → 根 fullScreenCover 排队延迟呈现 + 0.25s 跳转延迟
                    // ——用户实测'点了半天才跳过去'。push 零切换零延迟，返回回弹窗）
                    NavigationLink(destination: ModelsView()) {
                        Label(L10n.t("i18n_1070"), systemImage: "gearshape.fill")
                            .font(.footnote)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_1064"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { }
                        .hidden()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = [.blue, .tmCyan]   // v2.9.78：渐变图标底
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors[0])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(colors[0].opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v4.4.15：气泡点击手势——仅 tool 折叠 / 多选模式注册 onTapGesture；
// 纯文本气泡(非tool非selection)不注册任何点击手势，否则父级 contentShape+onTapGesture
// 的手势识别器会抢占内部 Text 的 textSelection 长按 → AI 回复一大段文字长按选字失效(用户实测)
private struct MessageTapModifier: ViewModifier {
    let isTool: Bool
    let selectionMode: Bool
    let onToggleSelect: (() -> Void)?
    let onToolToggle: () -> Void
    func body(content: Content) -> some View {
        if isTool || selectionMode {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectionMode { onToggleSelect?() }
                    else { onToolToggle() }
                }
        } else {
            content
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    // v4.3.77：安装进度——工具"执行中"气泡渲染实时进度条（引用处位于本 struct）
    @ObservedObject private var installRegistry = InstallationRegistry.shared
    // v7.2.3-fix23.1：参数展开状态每气泡自管（原 ChatView 级 @State 在独立 struct 内
    // 无法访问——编译错误根因；每气泡独立布尔天然隔离）
    @State private var argsExpanded = false
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    // v3.4.5：当前正在流式生成的 AI 消息 → 打字机逐字显示
    var isStreaming: Bool = false
    // v3.4.9：本轮刚生成完成的消息（工具解说/整段到达的回复）也要逐字打出——
    // 这些消息 isStreaming=false 且内容在出现前已定好，靠 onAppear 强制启动打字机
    var forceType: Bool = false
    // v3.5.31：思考开关——思考关时隐藏思考块（API 仍可能返回 thinking，UI 一律不显示）
    var thinkEnabled: Bool = true
    // v7.2.2：引用角标 [N] 点击 → 来源卡浮层（Perplexity/Kimi 式点击跳原文）
    @State private var sourceCardURL: URL?
    @State private var showSourceCard = false

    // v6.0.28：工具结果默认折叠，用户手动点才展开
    @State private var expanded = false
    @State private var expandedToolIds: Set<String> = []
    // v3.4.5：打字机效果——已显示字符数 + 定时器（显示与网络解耦，逐字稳定刷出）
    // v3.4.7：降速到 25 字/秒(0.04s/字)让打字感清晰可见；且不依赖 isStreaming——
    // 只要内容在增长就持续打字到完整，兼容"整段一次性到达"的中转
    // v3.5.4：用户反馈太慢 → 提速到 ~133 字/秒 (0.015s/tick × 2 字符），快但仍看得出打字感
    @State private var revealedCount = 0
    @State private var typeTimer: Timer?
    // v4.4.18：流式自动朗读——记录已朗读到的字符位置，content 增长时只把新增整句送 TTS
    @State private var autoSpokenUpTo = 0
    // v7.1.109-peers：打字机"已打完"持久化标记（UserDefaults by messageId）——
    // 修切后台/LazyVStack 重建后 forceType 消息 revealedCount 归 0 重新打字、
    // 打完不渲染块（杀后台重进才正常）的问题。打过一次即永久视为已显示完整：
    // 视图重建时直接全文渲染（表格/黑底立即可见），不再重打。
    private static var doneTypingCache: [String: Bool] = [:]
    private static func doneTyping(for id: UUID) -> Bool {
        let key = id.uuidString
        if let v = doneTypingCache[key] { return v }
        let v = (UserDefaults.standard.dictionary(forKey: "ui.doneTyping")?[key] as? Bool) ?? false
        doneTypingCache[key] = v
        return v
    }
    private static func markDoneTyping(_ id: UUID) {
        let key = id.uuidString
        doneTypingCache[key] = true
        var d = UserDefaults.standard.dictionary(forKey: "ui.doneTyping") ?? [:]
        d[key] = true
        UserDefaults.standard.set(d, forKey: "ui.doneTyping")
    }
    private static func clearDoneTyping(_ id: UUID) {
        let key = id.uuidString
        doneTypingCache[key] = false
        var d = UserDefaults.standard.dictionary(forKey: "ui.doneTyping") ?? [:]
        d[key] = false
        UserDefaults.standard.set(d, forKey: "ui.doneTyping")
    }

    // v3.5.4：自适应打字机（业界：平时 ~50 字/秒舒适，积压多自动提速追平网络，标点/换行稍停顿更自然）。
    // 不像固定 133 字/秒那样一快到底；也不像 25 字/秒那样拖沓。
    private func startTypeTimer() {
        guard typeTimer == nil else { return }
        // v7.1.109-peers：非流式(forceType)消息且已打完过 → 直接显示全文，不重打
        if !isStreaming, Self.doneTyping(for: message.id) {
            revealedCount = message.content.count
            return
        }
        // v3.5.4：MessageBubble 是 SwiftUI 结构体(值类型)，不能用 [weak self]；定时器 onDisappear 会 invalidate
        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.revealedCount < self.message.content.count else {
                    self.stopTypeTimer()
                    // v7.1.109-peers：打完了——持久化标记（流式消息不标记，流式由内容增长驱动）
                    if !self.isStreaming { Self.markDoneTyping(self.message.id) }
                    return
                }
                let total = self.message.content.count
                let backlog = total - self.revealedCount
                let idx = self.message.content.index(self.message.content.startIndex, offsetBy: self.revealedCount)
                let ch = self.message.content[idx]
                let isPause = ch == "\n" || "，。；：！？、,.。;:!?… ".contains(ch)
                // v7.1.109-peers：大厂式打字速度——基础 3 字符/tick(150字/秒)不拖沓，
                // 积压大幅提速追平网络/整段到达，标点/换行 1 字符停顿更有呼吸感
                let step: Int
                if backlog > 200 { step = 12 }       // 大量积压 → 追平
                else if backlog > 100 { step = 8 }   // 积压多 → 提速
                else if backlog > 40 { step = 5 }    // 稍积压 → 中快
                else if isPause { step = 1 }         // 标点/换行 → 停顿
                else { step = 3 }                    // 常规 ~150 字/秒
                self.revealedCount = min(total, self.revealedCount + step)
            }
        }
    }
    private func stopTypeTimer() {
        typeTimer?.invalidate()
        typeTimer = nil
    }
    // v4.4.20：自动朗读——用 autoSpokenUpTo 增量读"没读过"的部分；流式/非流式 onAppear+onChange 双触发共用，防重复
    // 句子边界：句末标点切分；无标点长段攒够 60 字也强制读（防一直憋着不读）
    // v7.1.38：朗读位置改全局持久化（UserDefaults by messageId）——修 v4.5.7 移除 onAppear 后
    // 非流式/先完成的消息 onChange 不触发导致"顶部自动朗读完全不发声"；持久化+时间窗防历史消息复读。
    private static var spokenPosCache: [String: Int] = [:]
    private static func spokenPos(for id: UUID) -> Int {
        let key = id.uuidString
        if let c = spokenPosCache[key] { return c }
        let v = (UserDefaults.standard.dictionary(forKey: "tts.spokenPositions")?[key] as? Int) ?? 0
        spokenPosCache[key] = v
        return v
    }
    private static func setSpoken(_ n: Int, for id: UUID) {
        let key = id.uuidString
        spokenPosCache[key] = n
        var d = UserDefaults.standard.dictionary(forKey: "tts.spokenPositions") ?? [:]
        d[key] = n
        UserDefaults.standard.set(d, forKey: "tts.spokenPositions")
    }
    private func autoSpeak(_ full: String, for id: UUID) {
        var spoken = Self.spokenPos(for: id)
        let chars = Array(full)
        if spoken >= chars.count { return }
        var boundary = spoken
        while boundary < chars.count {
            let isPunct = "。！？!?\n…".contains(chars[boundary])
            let overLimit = (boundary - spoken) >= 60
            if isPunct || overLimit {
                let sentence = String(chars[spoken...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { TTSService.shared.speak(sentence) }
                // v7.1.40 fix：切完一句必须前移 spoken，否则循环继续用旧起点切片 →
                // 多句回复入队「句1 / 句1+2 / 句1+2+3…」全部重复第一句（用户实测「循环重复第一句话」根因）
                spoken = boundary + 1
                Self.setSpoken(boundary + 1, for: id)
            }
            boundary += 1
        }
    }
    // v3.5.4：思考黄泡——思考进行中(isStreaming)自动展开让用户看到模型在动；
    // 思考结束自动收起(除非用户手动展开)。业界(掘金/Koder/DeepSeek Harness)一致做法。
    private var thinkingExpanded: Bool {
        isStreaming ? true : expandedToolIds.contains(message.id.uuidString)
    }
    private func toggleThinking() {
        let id = message.id.uuidString
        if expandedToolIds.contains(id) { expandedToolIds.remove(id) }
        else { expandedToolIds.insert(id) }
    }

    private var isUser: Bool { message.role == "user" }
    private var isTool: Bool { message.isTool }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                if selectionMode { selectionBadge }
                Spacer(minLength: 50)
            }

            if isTool {
                toolBubble
            } else {
                textBubble
            }

            if !isUser {
                // v3.4.0：AI 输出不追加右侧 Spacer —— 气泡随 .frame(maxWidth:.infinity) 填满整个可用宽度
                if selectionMode { selectionBadge }
            }
        }
        // v3.4.4：AI/工具气泡左右各留 16 边距（用户反馈 10 仍太小）；用户气泡右侧留白 12
        .padding(.horizontal, isUser ? 12 : 16)
        // v4.4.15：条件点击手势——tool/多选才注册，纯文本气泡不注册(让 textSelection 长按生效)
        .modifier(MessageTapModifier(
            isTool: isTool,
            selectionMode: selectionMode,
            onToggleSelect: onToggleSelect,
            onToolToggle: { withAnimation { expanded.toggle() } }
        ))
        // v4.4.13：移除 contextMenu——长按文字改为系统选择手柄(.textSelection)，可拖选部分复制。
        // 此前外层 contextMenu(复制全文/分享)抢占长按, 导致内层 Text 的 .textSelection(.enabled) 永远触发不了
        // 文字选择。全量复制/分享走多选工具栏(selectionMode: copySelected/shareMessage)。
        // v3.4.5：打字机效果——内容增长即逐字显示，直到完整
        // v7.1.109-peers：forceType 已完成消息视图重建时直接全文（不重打）；
        // 流式消息实时跟随网络（onChange(content) 同步 revealedCount），不启动限速 timer
        .onAppear {
            if isStreaming { Self.clearDoneTyping(message.id) }
            if !isStreaming, forceType, revealedCount < message.content.count { startTypeTimer() }
        }
        .onDisappear { stopTypeTimer() }
        .onChange(of: isStreaming) { streaming in
            if streaming {
                // v7.1.109-peers：流式开始——实时跟随网络，不启动限速 timer
                revealedCount = message.content.count
            }
            // v7.1.109-peers：流式结束且已显示完整 → 标记已打完（防切后台回来重打）
            else if revealedCount >= message.content.count { Self.markDoneTyping(message.id) }
        }
        .onChange(of: message.content) { _ in
            // v7.1.109-peers：流式中实时同步（网络到哪渲染哪，大厂式流式）；forceType 落后时启动打字机
            if isStreaming {
                revealedCount = message.content.count
                Self.clearDoneTyping(message.id)
            } else if revealedCount < message.content.count { startTypeTimer() }
        }
    }

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundColor(isSelected ? .blue : Color.secondary)
            .padding(.bottom, 10)
    }

    // v4.4.11：AI 正文行内代码(反引号)→橙色(与"已深度思考"同色)。手动正则解析，
    // 容错流式打字机未闭合反引号(不配对则视为普通文本)。仅 assistant 生效, user 保持纯文本。
    // v4.4.12：正文 markdown 加粗(**xx**)→粗体(semibold)。代码段优先(橙色)，代码段外再匹配粗体。
    /// v4.4.21：消息文本视图——流式/打字机/用户消息用轻量 Text（避免 UITextView 高频刷新闪跳）；assistant 完成消息用 SelectableText(UITextView) 长按选字/划词/复制
    /// v7.1.109-minis：assistant 完成消息改 Markdown 块渲染（表格/代码块/文本，对齐 OpenMinis
    /// SelectableMarkdownView）——表格 LazyVGrid 栅格、代码块黑底等宽命令行样式、文本沿用正则着色。
    /// 选择能力用 .textSelection(.enabled) 保留（v4.4.13 已验证 Text 拖选可用）。
    @ViewBuilder
    private func messageTextView(_ shown: String) -> some View {
        // v7.1.109-peers：流式/打字机也走块渲染（消除"打完才渲染"跳变矛盾）——
        // shown 是 revealedCount 截断文本：文本块随打字逐字增长（打字机保留）、
        // 代码块黑底从 fence 出现即渲染并随打字增长、表格在分隔行打全后渲染完整行；
        // 未闭合的 fence/表格自动回退纯文本。用户消息保持纯文本。
        if isUser {
            Text(AttributedString(shown))
                .font(.body)
                .textSelection(.enabled)
        } else {
            // v7.2.3-fix18：正文 block 化——文本/工具强隔离（对齐 OpenMinis block 模型）。
            // 模型误输出 DSML/antml 文本调用时，剥出工具段渲染为内联胶囊，
            // 工具调用绝不混进 AI 正文（原样文本只按代码块显示的旧行为废除）。
            let blocks = ContentBlocks.split(shown)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.kind == .text {
                        MarkdownBlocksView(
                            text: block.text,
                            coloredBody: { self.coloredBody($0) },
                            // v7.2.2：联网计数——本条 assistant 消息的 toolCalls 里 web_search/web_fetch 次数
                            // v7.2.3-fix：shell_exec 里的 curl 拉取也算联网
                            webSearchCount: (message.toolCalls ?? []).filter {
                                $0.name.contains("web_search") || $0.name.contains("web.search")
                                    || $0.name.contains("web_fetch") || $0.name.contains("web.fetch")
                                    || Self.toolCallIsCurlFetch($0)
                            }.count
                        )
                            // v7.2.2：引用角标 [N] 可点击 → 来源卡浮层（拦截 minis://source?n= 链接）
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "minis" && url.host == "source",
                                   let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                                   let nItem = comps.queryItems?.first(where: { $0.name == "n" }),
                                   let n = Int(nItem.value ?? ""),
                                   let src = CitationExtractor.extract(block.text).sources.first(where: { $0.index == n }) {
                                    sourceCardURL = src.url
                                    showSourceCard = true
                                    return .handled
                                }
                                return .systemAction
                            })
                    } else {
                        inlineToolCapsule(block)
                    }
                }
            }
            .overlay(sourceCardOverlay)
        }
    }

    /// v7.2.3-fix18：内联工具胶囊——DSML/antml 文本调用段渲染
    /// （只渲染不执行，明确标注未执行，避免"看起来调用了"的假象）
    @ViewBuilder
    private func inlineToolCapsule(_ block: ContentBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text(block.toolTitle ?? block.toolName ?? "tool")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text(L10n.t("i18n_1259"))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if let args = block.toolArgs, !args.isEmpty {
                Text(args)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
    }

    /// v7.2.3-fix20：连续工具折叠组——默认一行胶囊（运行了 N 个工具 + 总耗时），
    /// 点击展开显示各工具卡（左侧竖线标示为折叠组）

    // v7.2.2：来源卡浮层——底部卡片：host + URL + 打开按钮
    /// v7.2.3-fix11：ANSI 剥离（对齐 Open Minis 终端——"乱码少"的关键）——
    /// shell 工具输出常带 \x1b[...m 颜色码 / OSC 序列（\x1b]...\x07），纯文本
    /// Text 直接渲染会显示成乱码/方块。显示层剥离，不写回 content——
    /// 链接提取（LinkExtractor）仍用原始 content，功能不受影响。
    private static func stripANSI(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var j = 0
        while j < chars.count {
            if chars[j] == "\u{1B}" {
                if j + 1 < chars.count && chars[j + 1] == "[" {
                    j += 2
                    while j < chars.count {
                        let c = chars[j]
                        j += 1
                        if c >= "@" && c <= "~" { break }
                    }
                } else if j + 1 < chars.count && chars[j + 1] == "]" {
                    j += 2
                    while j < chars.count {
                        if chars[j] == "\u{07}" { j += 1; break }
                        if chars[j] == "\u{1B}" && j + 1 < chars.count && chars[j + 1] == "\\" { j += 2; break }
                        j += 1
                    }
                } else {
                    j += 1
                }
            } else {
                out.append(chars[j])
                j += 1
            }
        }
        return out
    }

    /// v7.2.3-fix13：终端 tab 展开（Open Minis 像素网格对齐的关键）——
    /// \t → 补空格到 8 列边界（终端标准），中文按 2 列宽估算。
    /// SwiftUI 的 Text 不保证渲染 tab 对齐，shell 表格输出（tabulate 等）
    /// 的列会全乱——必须先展开成空格。
    private static func expandTabs(_ text: String) -> String {
        var out = ""
        var col = 0
        for ch in text {
            if ch == "\t" {
                let pad = 8 - (col % 8)
                out.append(String(repeating: " ", count: pad))
                col += pad
            } else if ch == "\n" {
                out.append(ch)
                col = 0
            } else {
                out.append(ch)
                col += ch.isASCII ? 1 : 2
            }
        }
        return out
    }

    /// v7.2.3-fix12：Open Minis 终端配色（attributedShellLine 对齐）——
    /// 纯文本工具结果：白字 + URL 蓝色下划线高亮（其余无色，终端风）。
    private static func terminalStyled(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..., in: text)
        ns.addAttribute(.foregroundColor, value: UIColor.white, range: full)
        Self.blueURLs(in: ns, string: text)
        return AttributedString(ns)
    }

    /// URL → 蓝 + 下划线（Open Minis 唯一高亮；fix4 裸 URL 规则复用）
    private static func blueURLs(in ns: NSMutableAttributedString, string: String) {
        let pattern = #"https?://[^\s"'\(\)\]\}，。；：,;]+"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(string.startIndex..., in: string)
            for m in re.matches(in: string, range: full) {
                ns.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: m.range)
                ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            }
        }
    }

    /// v7.2.3-fix3：工具结果 JSON 格式化——解析成功 → prettyPrinted 缩进；
    /// v7.2.3-fix10：配色收敛——只要顶层"头"键（data/cwd 等）绿色，
    /// 其余全部白色（用户实测三色太花）。解析失败返回 nil → 调用方回退原文纯文本。
    /// 限长 20000 字符，超大 JSON 截断标注，避免渲染卡顿。
    private static func jsonHighlighted(from text: String) -> AttributedString? {
        // v7.2.3-fix11：先剥 ANSI——shell 输出带颜色码时 JSONSerialization 无法解析
        let cleaned = Self.stripANSI(text)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else { return nil }
        let limited = pretty.count > 20000
            ? String(pretty.prefix(20000)) + "\n… (truncated)"
            : pretty
        let ns = NSMutableAttributedString(string: limited)
        let full = NSRange(limited.startIndex..., in: limited)
        let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ns.addAttribute(.font, value: mono, range: full)
        ns.addAttribute(.foregroundColor, value: UIColor.white, range: full)
        // v7.2.3-fix27：顶层键绿色——此前正则 ^" 匹配行首引号，但 JSONSerialization
        // prettyPrinted 的顶层键前有 2 空格缩进（"  key":），正则从未命中 → 全白。
        // 改为 ^ {2}" 精确匹配顶层缩进（嵌套键 4+ 空格不命中，保持"头键绿"预期）
        if let re = try? NSRegularExpression(pattern: #"(?m)^ {2}"((?:[^"\\]|\\.)*)"\s*:"#) {
            for m in re.matches(in: limited, range: full) {
                ns.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: m.range)
            }
        }
        // v7.2.3-fix12：JSON 内的 URL 值 → 蓝色（Open Minis 终端配色）
        Self.blueURLs(in: ns, string: limited)
        return AttributedString(ns)
    }

    /// v7.2.3-fix：shell_exec 命令里含 curl 拉取 → 计为联网（工具参数 JSON 解析，
    /// 识别 command 字段的 curl 调用；下载 -o/-O 也是联网行为，一并计入用户视角的"用了网络"）
    private static func toolCallIsCurlFetch(_ call: ToolCall) -> Bool {
        guard call.name == "shell_exec",
              let data = call.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["command"] as? String else { return false }
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = c.lowercased()
        return lower.hasPrefix("curl") || lower.hasPrefix("env") && lower.contains(" curl ")
            || lower.contains(" curl ")
    }

    // v7.2.2：来源卡浮层——底部卡片：host + URL + 打开按钮
    @ViewBuilder
    private var sourceCardOverlay: some View {
        if showSourceCard, let url = sourceCardURL {
            ZStack {
                Color.black.opacity(0.25)
                    .onTapGesture { withAnimation { showSourceCard = false } }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "link")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                        Text(url.host ?? url.absoluteString)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            withAnimation { showSourceCard = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button {
                        BrowserManager.shared.open(url.absoluteString)
                        withAnimation { showSourceCard = false }
                    } label: {
                        Label(L10n.t("i18n_1256"), systemImage: "safari")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(10)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
                .padding(.horizontal, 40)
            }
            .transition(.opacity)
        }
    }

    private func coloredBody(_ text: String) -> AttributedString {
        var out = AttributedString()
        // v7.1.109-peers：引用角标 [N] 蓝色上标（Perplexity/Kimi 式）——优先于反引号着色
        // 顺序：块公式 > 行内公式 > 反引号 > [N] 角标 > 加粗（在 styledBody 内做 [N]）
        // v7.2.3-fix21：$...$/$$...$$ 数学公式等宽着色（LaTeX 源码保留可读，
        // 与反引号代码区分：公式紫色、代码橙色；真 KaTeX 图像渲染需 TextKit 改造，留后续）
        // v7.2.3-fix21.1：行内公式收紧为无空格/换行——`$100 和 $200` 这类货币
        // 文本不再被误判为公式（含空格即非公式）；块级 $$...$$ 保持宽松
        let pattern = "`([^`]+)`|(\\$\\$[^$]+\\$\\$)|(\\$[^ $\\n]+\\$)|(\\[(\\d+)\\])"
        var pos = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: pos..<text.endIndex) {
            let seg = text[range]
            if pos < range.lowerBound { out += styledBody(text[pos..<range.lowerBound]) }
            if seg.hasPrefix("$$") {
                // 块级公式 $$...$$ —— 等宽紫色
                var inner = seg
                inner.removeFirst(2)
                inner.removeLast(2)
                var c = AttributedString(inner)
                c.foregroundColor = .purple
                c.font = .system(.body, design: .monospaced)
                out += c
            } else if seg.hasPrefix("`") {
                let inner = text[text.index(after: range.lowerBound)..<text.index(before: range.upperBound)]
                var c = AttributedString(inner)
                c.foregroundColor = .orange
                c.font = .system(.body, design: .monospaced)
                out += c
            } else if seg.hasPrefix("$") {
                // 行内公式 $...$ —— 等宽蓝色斜体
                var inner = seg
                inner.removeFirst()
                inner.removeLast()
                var c = AttributedString(inner)
                c.foregroundColor = .blue
                c.font = .system(.body, design: .monospaced).italic()
                out += c
            } else if seg.hasPrefix("[") {
                // [N] → 蓝色上标
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.font = .system(size: 12, weight: .semibold)
                c.baselineOffset = 6
                out += c
            }
            pos = range.upperBound
        }
        if pos < text.endIndex { out += styledBody(text[pos..<text.endIndex]) }
        return out
    }

    // v4.4.12：代码段外的 markdown 加粗(**xx**)→粗体；未闭合的 ** 容错为普通文本
    // v7.1.109-peers：同名 styledBody（替换 styledBold），内部处理 **加粗** + [N] 角标（跨段）
    private func styledBody(_ s: Substring) -> AttributedString {
        var out = AttributedString()
        let boldPat = "\\*\\*([^*]+)\\*\\*"
        var pos = s.startIndex
        while let r = s.range(of: boldPat, options: .regularExpression, range: pos..<s.endIndex) {
            if pos < r.lowerBound { out += styledMarks(s[pos..<r.lowerBound]) }
            let inner = s[s.index(after: r.lowerBound)..<s.index(before: r.upperBound)]
            var b = AttributedString(inner)
            b.font = .system(size: 17, weight: .semibold) // v4.4.14: .system(_:weight:) 需 iOS16+, 改 system(size:weight:) 兼容更低部署目标
            out += b
            pos = r.upperBound
        }
        if pos < s.endIndex { out += styledMarks(s[pos..<s.endIndex]) }
        return out
    }

    // v7.2.1：段内富文本——~~删除线~~ / ==高亮== / *斜体* / $行内公式$ / [N] 角标（跨段）
    // v7.2.3-fix4：段内富文本 + [text](url) 链接 / 裸 URL（蓝色可点）
    private func styledMarks(_ s: Substring) -> AttributedString {
        var out = AttributedString()
        let richPat = #"~~([^~]+)~~|==([^=]+)==|\*([^*]+)\*|\$([^$\n]+)\$|\[(\d+)\]|\[([^\]\n]+)\]\((https?://[^)\s]+)\)|(https?://[^\s)\]），。；：,;]+)"#
        var pos = s.startIndex
        while let r = s.range(of: richPat, options: .regularExpression, range: pos..<s.endIndex) {
            if pos < r.lowerBound { out += AttributedString(s[pos..<r.lowerBound]) }
            let seg = String(s[r])
            let innerStart = s.index(after: r.lowerBound)
            let innerEnd = s.index(before: r.upperBound)
            let inner = String(s[innerStart..<innerEnd])
            if seg.hasPrefix("~~") {
                var a = AttributedString(inner)
                a.strikethroughStyle = .single
                a.foregroundColor = .secondary
                out += a
            } else if seg.hasPrefix("==") {
                var a = AttributedString(inner)
                a.backgroundColor = Color.yellow.opacity(0.22)
                out += a
            } else if seg.hasPrefix("*") {
                var a = AttributedString(inner)
                a.font = .system(size: 17).italic()
                out += a
            } else if seg.hasPrefix("$") {
                // v7.2.2-audit：仅当内部含 LaTeX 特征（\ ^ _ { }）才当公式——
                // 否则"$5 and $10"等货币会被误判成斜体公式、$ 符号丢失
                if inner.contains("\\") || inner.contains("^") || inner.contains("_")
                    || inner.contains("{") || inner.contains("}") {
                    var a = AttributedString(MathText.render(inner))
                    a.font = .system(size: 17).italic()
                    out += a
                } else {
                    out += AttributedString(seg)
                }
            } else if seg.hasPrefix("[") {
                // v7.2.3-fix4：[text](url) Markdown 链接 vs [N] 角标——含 "](" 即链接
                if seg.contains("]("),
                   let te = seg.range(of: "](")?.lowerBound,
                   let us = seg.range(of: "](")?.upperBound,
                   te > seg.startIndex, us < seg.endIndex {
                    let linkText = String(seg[seg.index(after: seg.startIndex)..<te])
                    let linkURL = String(seg[us..<seg.index(before: seg.endIndex)])
                    var c = AttributedString(linkText)
                    c.foregroundColor = .blue
                    c.underlineStyle = .single
                    c.link = URL(string: linkURL)
                    out += c
                } else {
                    out += AttributedString(seg)
                }
            } else if seg.hasPrefix("http") {
                // v7.2.3-fix4：裸 URL 自动链接化（尾随标点已由正则排除；
                // 用 seg 而非 inner——URL 无包裹字符，inner 会剥首尾各一字符）
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.underlineStyle = .single
                c.link = URL(string: seg)
                out += c
            } else {
                // [N] → 蓝色上标（可点击：minis://source?n=N 由 openURL 拦截弹出来源卡）
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.font = .system(size: 12, weight: .semibold)
                c.baselineOffset = 6
                if let n = Int(inner) {
                    c.link = URL(string: "minis://source?n=\(n)")
                }
                out += c
            }
            pos = r.upperBound
        }
        if pos < s.endIndex { out += AttributedString(s[pos..<s.endIndex]) }
        return out
    }

    // v4.5.0：原生 NSAttributedString 富文本——给 SelectableText(UITextView) 用。
    // 解析 **加粗** 与 `代码`(橙色)；直接写 UIKit font + UIColor（动态 .label 适配暗黑模式），
    // 不走 SwiftUI AttributedString 桥接（会丢橙色/加粗样式，导致暗黑下看不清、字体变小）。
    private func attributedBody(_ text: String) -> NSAttributedString {
        let baseColor = UIColor.label
        let orangeColor = UIColor.systemOrange
        let regular = UIFont.systemFont(ofSize: 17)
        let bold = UIFont.boldSystemFont(ofSize: 17)
        let mono = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)

        let base: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: baseColor]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: baseColor]
        let orangeAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: orangeColor]

        let ns = text as NSString
        let pattern = #"\*\*([^*]+)\*\*|`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let ms = NSMutableAttributedString()
        var pos = 0
        for m in matches {
            if m.range.location > pos {
                ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), attributes: base))
            }
            // 捕获组编号：组1 = **加粗** 内容，组2 = `代码` 内容（共2组，无组3）
            let boldGroup = m.range(at: 1)
            if boldGroup.location != NSNotFound {
                ms.append(NSAttributedString(string: ns.substring(with: boldGroup), attributes: boldAttrs))
            } else {
                ms.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: orangeAttrs))
            }
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: ns.length - pos)), attributes: base))
        }
        return ms
    }

    private var textBubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            // v2.9.10：消息内图片缩略图（用户选择相册图片后，气泡里直接显示图片）
            if let imgs = message.imageDataURLs, !imgs.isEmpty {
                messageImageStrip(imgs)
            }
            // v2.9.20：思考记录（reasoning）可展开显示
            // v3.5.31：加 thinkEnabled —— 思考关时即使 API 返回 thinking 也一律不显示
            if !isUser, thinkEnabled, let th = message.thinking, !th.isEmpty {
                // v7.1.109-peers：思考耗时秒数传入（DeepSeek 式"已深度思考（用时 X 秒）"）
                thinkingView(th, seconds: message.thinkingSeconds)
            }
            // v3.0.2: 去掉旧的 TrailCard，改用 toolBubble 显示工具调用
            // v3.0.2e：如果 content 是空的，就不显示气泡（避免空白气泡）
            // v3.5.12 修订：解说=单独长气泡(一长)。模型"先解说后执行"的正文就作为普通 assistant 气泡
            // 显示在工具卡上方；工具卡标题=机械短标签(一短,见 toolShortLabel)，两者分开、不重复。
            // 模型本轮没写解说(content空)则无气泡，卡片标题仍显示机械短标签，不落空。
            if !message.content.isEmpty {
                // v7.1.109-peers：打字机——isStreaming 或 forceType 都按 revealedCount 逐字显示；
                // 此前只有 isStreaming 才走前缀，forceType(内容在出现前已定好、isStreaming=false)走了全文分支，
                // 导致"打字机一下有一下没有"(用户实测反馈)。修复后非流式完成的消息也逐字打出来。
                // v7.1.109-peers：已打完标记(doneTyping)的消息——即使 forceType 仍 true、revealedCount
                // 视图重建归 0，也直接渲染全文（切后台回来不重打、表格/黑底立即可见）
                // v7.1.109-peers：流式跟随网络实时渲染（大厂式：delta 到哪渲染哪，代码块/表格/
                // 链接结构到达即出现，不再字符限速）；forceType(整段到达)保留逐字打字机+结构即时化
                let typedDone = !isStreaming && Self.doneTyping(for: message.id)
                // v7.1.109-peers：ViewBuilder 不允许赋值语句（a9ac7ea 引入的
                // let shown + 三路赋值导致 CI 编译失败）→ 改声明式表达式
                let shown = isStreaming ? message.content
                    : (forceType && !typedDone ? String(message.content.prefix(revealedCount)) : message.content)
                // v4.4.11：assistant 行内代码橙色高亮, user 纯文本
                VStack(alignment: .leading, spacing: 3) {
                    // v4.4.21：完成消息用 SelectableText(UITextView) 长按划词/复制；流式打字机+用户消息用 Text(轻量)
                    messageTextView(shown)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // v3.3.4：AI 回复气泡从左拉伸到右（全宽）；用户气泡保持靠右自适应
                        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                        // v2.9.93：用户气泡改巨魔蓝渐变（浅青→蓝，品牌化），助手保持系统色
                        .background(
                            Group {
                                    if isUser {
                                        LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    } else if message.isError {
                                        Color.red.opacity(0.15)
                                    } else {
                                        Color(.secondarySystemBackground)
                                    }
                                }
                        )
                        .foregroundColor(isUser ? .white : .primary)
                        .cornerRadius(18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(isSelected ? (isUser ? Color.white : Color.blue) : Color.clear, lineWidth: 2)
                        )
                    // v4.4.18：朗读喇叭按钮（assistant 消息）——点一下朗读这条全文；长按仍保留选字复制
                    // v7.1.40：正在播这条时再点 = 停止（关闭声音）
                    // v7.1.43：与顶部全局开关解耦——顶部管自动朗读，气泡管手动点读（点读/再点停），互不影响
                    if !isUser && !message.isTool {
                        HStack(spacing: 6) {
                            let isSpeakingThis = TTSService.shared.speakingId == message.id.uuidString
                            Button(action: {
                                if isSpeakingThis {
                                    TTSService.shared.stop()
                                } else {
                                    TTSService.shared.speakForced(id: message.id.uuidString, message.content)
                                }
                            }) {
                                Image(systemName: isSpeakingThis ? "speaker.wave.2.fill" : "speaker.wave.2")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(isSpeakingThis ? .tmCyan : .secondary)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                // v7.1.38：自动朗读双触发——onAppear 补读（非流式/挂载前已完成的回复）+ onChange 流式增量；
                // 全局持久化朗读位置 + 5 分钟时间窗，历史消息（重开 App/切会话）不复读。
                .onAppear {
                    if message.role == "assistant", !message.isTool, TTSService.shared.speakerEnabled,
                       Date().timeIntervalSince(message.timestamp) < 300 {
                        autoSpeak(message.content, for: message.id)
                    }
                }
                .onChange(of: message.content) { newContent in
                    guard message.role == "assistant", !message.isTool, TTSService.shared.speakerEnabled else { return }
                    autoSpeak(newContent, for: message.id)
                }
            }
        }
    }

    /// v2.9.20：思考记录（reasoning）折叠视图
    private func thinkingView(_ text: String, seconds: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: thinkingExpanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 14))
                    // v3.5.4：思考中→"思考中…"；思考完→"已深度思考 N 字"(业界一致)
                    // v7.1.109-peers：加耗时秒数（DeepSeek/元宝式"已深度思考（用时 X 秒）"）
                    // v7.2.3-fix15：字数/用时缩小灰色——主文字橙色，数字部分 caption2 灰
                    if isStreaming {
                        Text(L10n.t("i18n_1071"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    } else if let s = seconds, s > 0 {
                        HStack(spacing: 4) {
                            Text(L10n.t("i18n_1072"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(L10n.t("i18n_1248", Int(s.rounded())))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text(L10n.t("i18n_1072"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if thinkingExpanded {
                        Button(action: { UIPasteboard.general.string = text }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// v2.9.10：data URL → UIImage
    private func messageImageStrip(_ dataURLs: [String]) -> some View {
        let images = dataURLs.compactMap { Self.uiImage(fromDataURL: $0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .cornerRadius(12)
                        .clipped()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    /// v2.9.10：data URL → UIImage（用于消息气泡图片显示）
    static func uiImage(fromDataURL s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    /// v3.5.16：卡片标题只显示工具名（去掉"命令符/命令"），像 Minis 步骤标签那样简洁。
    /// 具体命令/参数仍在卡片下方 args 等宽行完整显示，标题不再拼命令，避免命令符状态占据标题。
    private func toolShortLabel() -> String {
        // v7.2.3-fix19：AI 传的 tool_title 优先（5-10 字行为摘要，不带工具名，
        // 对齐 OpenMinis）；旧消息/模型未输出时 fallback 工具名
        message.toolTitle ?? message.toolName ?? L10n.t("i18n_1073")
    }

    /// v7.2.3-fix16：工具族标签（对齐三层架构：封装/原生/Alpine）——
    /// 副行小字显示"封装工具/原生工具/Alpine 工具"。
    /// 规则：shell.exec（默认 Alpine 环境）→ Alpine；原生 bin 清单 → 原生；
    /// 其余 MCP 注册工具（web.*/device.*/app.* 等带点前缀）→ 封装。
    private func toolFamilyLabel(for toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return L10n.t("i18n_244") }
        let nativeSet: Set<String> = ["sqlite3", "plutil", "ta", "jtool2", "py3-native",
                                      "node-native", "git.py", "nscan.py", "ldid", "insert_dylib",
                                      "optool", "ct_bypass", "opainject", "install_name_tool"]
        let packagedPrefixes = ["web.", "device.", "app.", "container.", "injection.", "location.",
                                "macro.", "knowledge.", "automation.", "model.", "reminder", "calendar",
                                "contacts", "phone", "scan.", "skills.", "project.", "build.", "rescue.",
                                "cron.", "file.", "network."]
        if name == "shell.exec" || name == "shell_exec" {
            return L10n.t("i18n_1177")      // Alpine 工具（默认 shell 环境）
        }
        if nativeSet.contains(name) {
            return L10n.t("i18n_245")       // 原生工具
        }
        if packagedPrefixes.contains(where: { name.hasPrefix($0) }) {
            return L10n.t("i18n_244")       // 封装工具
        }
        return L10n.t("i18n_244")
    }

    /// v7.2.3-fix28/fix28b：工具卡图标按工具名映射（OpenMinis 风格，覆盖全部真实工具族）
    /// 对齐 OpenMinis sfSymbol(forTool:) 表并扩展：photo/brain/bubble/lightbulb/pencil/code 等
    /// 不再落默认灰图标。AI 只传 tool_name，图标与颜色全在客户端映射（与 OpenMinis 一致）。
    private func toolCardSymbol(_ toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return "wrench.and.screwdriver" }
        if name == "shell.exec" || name == "shell_exec" || name == "bash" { return "terminal.fill" }
        if name.hasPrefix("web.") || name == "web_search" { return "magnifyingglass" }
        if name.hasPrefix("browser.") { return "safari" }
        if name.hasPrefix("knowledge.") || name.hasPrefix("skills.") || name.hasPrefix("learn.") { return "book.closed" }
        if name.hasPrefix("device.") { return "iphone" }
        if name.hasPrefix("app.") { return "app.badge" }
        if name.hasPrefix("inject") { return "wand.and.stars" }
        if name.hasPrefix("control.") { return "hand.tap" }
        if name.hasPrefix("container.") || name.hasPrefix("package.") || name.hasPrefix("build.") { return "shippingbox" }
        if name.hasPrefix("file.read") || name.hasPrefix("fs.read") || name.hasPrefix("file.inspect") { return "doc.text" }
        if name.hasPrefix("file.write") || name.hasPrefix("fs.write") { return "doc.text.fill" }
        if name.hasPrefix("file.") || name.hasPrefix("fs.") || name.hasPrefix("artifact.") || name.hasPrefix("project.") { return "folder" }
        if name.hasPrefix("vision.") || name == "read_image" || name == "image" { return "photo" }
        // OpenMinis delegate=person.2（子agent是人形）；thinking 才是 brain——不撞
        if name.hasPrefix("memory") { return "brain.head.profile" }
        if name.hasPrefix("subagent.") || name == "agent" || name.hasPrefix("delegate") { return "person.2.fill" }
        if name == "text" || name == "plaintext" || name.hasPrefix("model.") { return "bubble.left" }
        if name == "think" || name == "thinking" { return "lightbulb.max" }
        if name.hasPrefix("code") || name.hasPrefix("py3-native") || name.hasPrefix("node-native") { return "chevron.left.forwardslash.chevron.right" }
        if name.hasPrefix("network.") { return "network" }
        if name == "db" || name == "sqlite3" { return "cylinder.fill" }
        if name.hasPrefix("system.") || name.hasPrefix("tools.") || name == "verify" { return "gearshape" }
        if name.hasPrefix("cron.") || name.hasPrefix("reminder") || name.hasPrefix("calendar") { return "clock" }
        if name.hasPrefix("location.") { return "location" }
        if name.hasPrefix("rescue.") { return "cross.case" }
        if name.hasPrefix("automation.") || name.hasPrefix("macro.") { return "play.circle" }
        return "wrench.and.screwdriver"
    }

    /// v7.2.3-fix28/fix28b：图标配色（同工具名映射）
    private func toolCardColor(_ toolName: String?) -> Color {
        guard let name = toolName, !name.isEmpty else { return .gray }
        if name == "shell.exec" || name == "shell_exec" || name == "bash" { return .blue }
        if name.hasPrefix("web.") || name == "web_search" { return .blue }
        if name.hasPrefix("browser.") { return .orange }
        if name.hasPrefix("knowledge.") || name.hasPrefix("skills.") || name.hasPrefix("learn.") { return .green }
        if name.hasPrefix("device.") || name.hasPrefix("network.") || name.hasPrefix("location.") { return .teal }
        if name.hasPrefix("app.") || name.hasPrefix("inject") || name.hasPrefix("control.") { return .purple }
        if name.hasPrefix("subagent.") || name == "agent" || name.hasPrefix("delegate") { return Self.agentAccent }
        if name.hasPrefix("container.") || name.hasPrefix("package.") || name.hasPrefix("build.") { return .orange }
        if name.hasPrefix("vision.") || name == "read_image" || name == "image" { return .blue }
        if name.hasPrefix("memory") { return .purple }
        if name == "text" || name == "plaintext" || name.hasPrefix("model.") { return .gray }
        if name == "think" || name == "thinking" { return .orange }
        if name.hasPrefix("code") || name.hasPrefix("py3-native") || name.hasPrefix("node-native") || name == "db" || name == "sqlite3" { return .blue }
        if name.hasPrefix("cron.") || name.hasPrefix("reminder") || name.hasPrefix("calendar") { return .pink }
        if name.hasPrefix("rescue.") { return .red }
        if name.hasPrefix("automation.") || name.hasPrefix("macro.") { return .green }
        return .gray
    }

    /// v7.2.3-fix28：副行族标签/工具名着色——Alpine 工具蓝色（用户要求），其余保持灰
    private func toolFamilyTint(_ toolName: String?) -> Color {
        if toolName == "shell.exec" || toolName == "shell_exec" { return .blue }
        return .secondary
    }

    /// v7.2.3-fix30：子 agent/delegate 电紫 accent——OpenMinis HelperAccent 原色
    /// （亮 #734DED / 暗 #A385FF，"AI/tech"语义色，不撞红=错误、绿=成功）
    private static let agentAccent = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.52, blue: 1.00, alpha: 1)
            : UIColor(red: 0.45, green: 0.30, blue: 0.93, alpha: 1)
    })

    private var toolBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 📝 1. 思考过程（独立橙色气泡）
            // v3.5.31：加 thinkEnabled —— 思考关时不显示思考气泡
            if thinkEnabled, let thinking = message.thinking, !thinking.isEmpty {
                thinkingMiniBubble(thinking)
            }

            // 🔧✅ 2. 工具调用 + 工具结果（同一个灰色大气泡）
            VStack(alignment: .leading, spacing: 6) {
                        // 工具调用胶囊（工具名 + 执行命令，边做边说可见；结果在下方展开）
                VStack(alignment: .leading, spacing: 3) {
                    // v7.2.3-fix16：主行=图标+大标题；状态徽章/耗时移到副行小字
                    HStack(spacing: 6) {
                        // v7.2.3-fix28：工具卡图标按工具族映射（对齐 OpenMinis 多彩）——
                        // 此前全部写死 terminal.fill+蓝，不同工具无法一眼区分
                        Image(systemName: toolCardSymbol(message.toolName))
                            .font(.system(size: 13))
                            .foregroundColor(toolCardColor(message.toolName))
                        // v3.5.13：卡片标题=机械短标签(一短,像Minis)——从工具名+关键参数提炼(如
                        // "shell.exec: ls -la" / "browser: dnf.qq.com")，简短稳定、次次一致，客观陈述跑了哪个
                        // 工具干了什么，不代表模型说话；真正的解说由单独的 assistant 气泡(一长)承载。
                        Text(toolShortLabel())
                            .font(.subheadline)
                            .fontWeight(.medium)
                            // v7.2.3-fix17：主标题日间黑/夜间白（自适应），不再固定蓝
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .layoutPriority(1)
                        Spacer()
                    }
                    // v7.2.3-fix23：点击标题区展开/收起参数（渲染传参默认隐藏后的入口）
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if argsExpanded {
                                argsExpanded = false
                            } else {
                                argsExpanded = true
                            }
                        }
                    }
                    // v7.2.3-fix16：副行小字（括号信息）——工具族·工具名·状态·耗时
                    HStack(spacing: 5) {
                        // v7.2.3-fix28：副行字号 10→12；Alpine 工具族标签+工具名蓝色（用户要求）
                        Text(toolFamilyLabel(for: message.toolName))
                            .foregroundColor(toolFamilyTint(message.toolName))
                        if let tn = message.toolName, !tn.isEmpty {
                            Text(tn)
                                .foregroundColor(toolFamilyTint(message.toolName))
                                .textSelection(.enabled)
                        }
                        // v3.5.7：工具状态徽章（机制级：由真实执行结果渲染）——移到副行缩小
                        if message.isRunning {
                            ProgressView().scaleEffect(0.55)
                            Text(L10n.t("ui_64")).foregroundColor(.blue)
                        } else {
                            Text(message.isError ? L10n.t("i18n_1074") : L10n.t("i18n_1075"))
                                .foregroundColor(message.isError ? .red : .green)
                        }
                        // v3.3.4：工具执行耗时
                        if let dur = message.toolDuration {
                            Text(String(format: "%.1fs", dur))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    // v3.5.13：标题已是"工具名: 关键参数"机械短标签，无需再补一行副标题工具名。
                    // v7.2.3-fix23：渲染传参提示词默认完全隐藏（对齐用户诉求——标题已说明
                    // 意图、显示的命令 AI 不一定真执行，界面渲染多余）。点击卡片标题区
                    // 切换展开/收起完整命令/参数。
                    if let args = message.toolArgs, !args.isEmpty {
                        if argsExpanded {
                            HStack(alignment: .top, spacing: 4) {
                                Text(args)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    argsExpanded = false
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                // 工具结果（可折叠）
                toolResultMiniBubble
            }
            .padding(10)
            // v3.1.66：修复"工具气泡浅色模式不显示"——tertiarySystemBackground 在浅色模式≈纯白，
            // 与聊天背景融为一体；改用 secondarySystemBackground（与 AI 回复气泡同色，浅色=浅灰白/深色=深灰）
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }

    // 📝 思考过程迷你气泡
    private func thinkingMiniBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    // v7.2.3-fix15：字数缩小灰色（与思考气泡一致）
                    HStack(spacing: 4) {
                        Text(isStreaming ? L10n.t("i18n_1071") : L10n.t("i18n_1072"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                        if !isStreaming {
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
    }

    // ✅ 工具结果迷你气泡
    private var toolResultMiniBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { if !message.isRunning { expanded.toggle() } } }) {
                HStack(spacing: 6) {
                    if message.isRunning {
                        // v4.3.75：有活动安装任务 → 迷你气泡显示实时进度（阶段+包数+最近行）
                        if let prog = installRegistry.active, prog.ok == nil {
                            VStack(alignment: .leading, spacing: 2) {
                                ProgressView(value: prog.fraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 130)
                                Text(prog.progressText)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                if !prog.lastLine.isEmpty {
                                    Text(prog.lastLine)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 160, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8)
                                Text(L10n.t("i18n_1076"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // v7.2.3-fix30：成功态蓝→绿（对齐 OpenMinis completed=green + 副行徽章已是绿）
                        Image(systemName: message.isError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(message.isError ? .red : .green)
                        Text(expanded ? L10n.t("i18n_1077") : L10n.t("i18n_1078"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(message.isError ? .red : .green)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            // v3.5.10：执行中不展示结果区（content 为空）
            if !message.isRunning && expanded {
                // v7.2.3-fix3：JSON 结果 → 缩进+头键着色；否则等宽纯文本
                // v7.2.3-fix11：纯文本先剥 ANSI（乱码根因）
                // v7.2.3-fix13：tab 展开到 8 列（空格对齐根因）
                Group {
                    if let json = Self.jsonHighlighted(from: message.content) {
                        Text(json)
                    } else {
                        Text(Self.terminalStyled(Self.expandTabs(Self.stripANSI(message.content))))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )

                // v3.1.6: 工具结果里的文件 → 可点击卡片
                let files = FilePathExtractor.extractFiles(from: message.content)
                if !files.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            FileCardRow(url: url)
                        }
                    }
                }
                // v7.1.109-minis：工具结果里的链接 → 链接卡（URL / minis://open?url= 标记）
                // 对齐 Minis：shell stdout 带 OSC minis-open 标记时 UI 渲染打开入口
                let links = LinkExtractor.extractLinks(from: message.content)
                if !links.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(links, id: \.self) { LinkCardView(url: $0) }
                    }
                }
            }
        }
    }
}

// v3.1.6: 聊天里的文件卡片 —— 点了直接 QuickLook 预览
struct FileCardRow: View {
    let url: URL
    @State private var showPreview = false

    private var fileName: String { url.lastPathComponent }
    private var ext: String { (fileName as NSString).pathExtension.lowercased() }
    private var isImage: Bool { ["png","jpg","jpeg","gif","webp","heic"].contains(ext) }

    private var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "ipa","tipa": return "shippingbox"
        case "deb","zip","tar","gz": return "archivebox"
        case "dylib","framework": return "hammer"
        case "plist","json": return "doc.text"
        case "pdf": return "doc.richtext"
        case "swift","h","m","c","cpp": return "chevron.left.slash.chevron.right"
        default: return "doc"
        }
    }

    private var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        if size > 1024*1024 { return String(format: "%.1f MB", Double(size)/1024/1024) }
        if size > 1024 { return String(format: "%.0f KB", Double(size)/1024) }
        return "\(size) B"
    }

    @ViewBuilder
    var body: some View {
        // v7.1.109-minis：图片文件直显缩略图（对齐 Minis ZoomableImageView——工具结果/正文里的
        // 图片路径不再只显示图标行，直接渲染图；点击 QuickLook 放大）
        if isImage, let img = UIImage(contentsOfFile: url.path) {
            Button(action: { showPreview = true }) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(8)
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(.tmCyan)
                        Text(fileName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(sizeText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.systemGray5))
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                SharePresenter.menuShare(url: url)
            }
            .sheet(isPresented: $showPreview) {
                QLFilePreview(urls: [url])
            }
        } else {
        Button(action: { showPreview = true }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.tmCyan.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundColor(.tmCyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(fileName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // v7.1.109-peers：文件解析状态卡（元宝式）——已解析绿勾徽标
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                    Text(sizeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundColor(.tmCyan)
            }
            .padding(10)
            // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
            .background(Color(.systemGray5))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            SharePresenter.menuShare(url: url)
            // v4.3.46：用 TrollStore 安装 → 打开方式（UIDocumentInteractionController）。
            // TrollStore 注册了 .tipa/.ipa 的打开方式，不经过 ShareSheet（系统分享面板
            // 在本设备侧载环境 MobileIcons/CoreImage SIGSEGV，任何路径都崩）。
            // v4.3.51：URL scheme 直调 TrollStore 安装（不渲染 App 图标列表，安全）
            if ext == "tipa" || ext == "ipa" {
                Button(action: { ShareCenter.shared.openInTrollStore(url) }) {
                    Label(L10n.t("i18n_1079"), systemImage: "shippingbox")
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            QLFilePreview(urls: [url])
        }
        }
    }
}

struct TypingIndicator: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.secondary)
                    .offset(y: offset)
                    .animation(Animation.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15), value: offset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
        .onAppear { offset = -4 }
    }
}

// MARK: - v2.9.127 执行轨迹组件（豆包工作任务/Codex 式过程流）

/// 实时轨迹卡片：请求进行中，在"正在思考"下方竖排显示步骤流
struct LiveTrailCard: View {
    let steps: [TrailStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // v7.1.109-peers：Manus 式任务计数——N/M（完成/总步骤），三态一眼可见
            let done = steps.filter { $0.status == .success }.count
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                Text(L10n.t("i18n_1249", done, steps.count))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.blue)
                Spacer()
            }
            ForEach(steps) { step in
                TrailRow(step: step)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
        .background(Color(.systemGray5).opacity(0.85))
        .cornerRadius(12)
    }
}

/// 历史轨迹卡片：assistant 消息气泡内，可折叠展开执行全过程
struct TrailCard: View {
    let steps: [TrailStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 13))
                    Text(L10n.t("ui_158", steps.count))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.blue)
                    Spacer()
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        TrailRow(step: step)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
    }

    private var summaryText: String {
        let ok = steps.filter { $0.status == .success }.count
        let fail = steps.filter { $0.status == .failed }.count
        if fail > 0 { return "✅\(ok) ❌\(fail)" }
        return L10n.t("i18n_1080", ok)
    }
}

/// 单步行：图标 + 名称 + 状态色 + 可展开 detail
struct TrailRow: View {
    let step: TrailStep
    @State private var detailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconFor)
                .font(.system(size: 12))
                .foregroundColor(colorFor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.caption)
                    .fontWeight(step.status == .running ? .medium : .regular)
                    .foregroundColor(step.status == .running ? .primary : (step.status == .failed ? .red : .primary))
                    .lineLimit(1)
                if step.status == .running {
                    Text(L10n.t("ui_64"))
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if !step.detail.isEmpty {
                    if detailExpanded {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(6)
                            .onTapGesture { detailExpanded = false }
                    } else {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .onTapGesture { detailExpanded = true }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var iconFor: String {
        switch step.kind {
        case .think: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .result: return step.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .note: return "flag"
        }
    }

    private var colorFor: Color {
        switch step.status {
        case .running: return .blue
        case .success: return .blue
        case .failed: return .red
        }
    }
}

// MARK: - v2.9.234 输入框：UITextView 包装(检测 markedText，修复"没打完自动回车")
// SwiftUI TextField 读不到输入法 markedText(拼音未上屏)，iOS16+第三方输入法组合下
// 按回车会直接 submit → 发出去一串拼音。UITextView delegate 可读 markedTextRange：
// 组词中按回车=上屏候选词(return true)，无组词按回车=发送(return false)。

struct ChatInputTextView: UIViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> RSKGrowingTextView {
        let tv = RSKGrowingTextView()
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = UIColor.label
        tv.placeholder = L10n.t("input_placeholder") as NSString
        tv.placeholderColor = .gray
        tv.minimumNumberOfLines = 1
        tv.maximumNumberOfLines = 4
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: RSKGrowingTextView, context: Context) {
        uiView.text = text
        height = uiView.intrinsicContentSize.height
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, RSKGrowingTextViewDelegate {
        var parent: ChatInputTextView
        init(_ p: ChatInputTextView) { parent = p }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.height = textView.intrinsicContentSize.height
        }
    }
}

// MARK: - v3.1.67：UIKit 文档选择器 delegate（真机稳定，替代 .fileImporter）

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static var assocKey = "DocumentPickerCoordinatorKey"
    let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消，无操作
    }
}
