import SwiftUI
import UIKit

// MARK: - 设置项数据（列表/卡片双视图共用，永不脱节）

struct SettingsItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var destination: AnyView?
    var action: (() -> Void)?
    var isOn: (() -> Bool)?
    var onToggle: ((Bool) -> Void)?
    /// v4.3.39：行尾红点（新版提醒等），闭包返回是否显示
    var redDot: (() -> Bool)?
    /// v6.1.5-14bf：行尾右侧数值（如版本号）——14ax 移除副标题渲染后版本号丢失，用独立 value 恢复且保持灰色可见
    var value: String?
}

struct SettingsGroup {
    let header: String
    var items: [SettingsItem]
}

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // v2.9.72：开发者模式开关，开启后显示高级选项
    // v6.0.28：默认开启，去掉开关UI
    @AppStorage("developer_mode") private var developerMode = true
    // v2.9.76：语言选择弹窗
    @State private var showLanguagePicker = false
    // v2.9.84：聊天框「在设置中管理模型」→ 打开设置并自动跳到模型 API 页
    @State private var jumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并自动跳到系统指令(SystemPromptsView)页
    @State private var jumpToSystemPrompts = false
    // v3.3.2：抓包 VPN 开关失败提示
    @State private var vpnToggleError = ""
    // v4.3.29：订阅更新管理器，副标题实时显示 检查中/下载进度/发现新版本
    @ObservedObject private var updateManager = UpdateManager.shared
    // v4.3.30：更新镜像源编辑器
    @State private var showMirrorEditor = false
    @State private var mirrorsText = ""
    // v4.5.1：桌面悬浮开关结果刷新触发器（HUDManager.lastStartError 非 @Published，用它触发 body 重建显示原因）
    @State private var hudRefresh = false

    var body: some View {
        // v2.9.247：GeometryReader 拿真实全屏尺寸——fullScreenCover+NavigationStack 组合下 List 高度被解析为内容高度(内容不满一屏时列表只占上半屏、下半空白),外层 frame 也无效;改用几何尺寸显式强制 List 与 NavigationStack 铺满全屏,所有机型一致
        GeometryReader { geo in
            CompatNav {
                listBody
                    .frame(minHeight: geo.size.height)
                    .navigationTitle(L10n.t("settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        // v2.9.241：全屏设置页左上角返回按钮（v7.0.4：'完成'→'返回'箭头样式，语义更清晰）
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                Text(L10n.t("back"))
                            }
                            .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    // v2.9.245：移除右上角卡片/列表切换按钮——卡片模式在部分机型(iPhone XS等小屏)渲染不稳定(图标/文字显示不全/内容裁剪),统一为列表模式
                }
                // v2.9.234：跳转模型API页——iOS16 navigationDestination(修被弹回), iOS15 NavigationLink兜底
                // v4.4.16：追加"跳系统指令"跳转(底部"指令"胶囊)——与模型跳转对称的 iOS16/iOS15 双兜底
                .background(
                    Group {
                        if #available(iOS 16.0, *) {
                            EmptyView()
                        } else {
                            NavigationLink(destination: ModelsView(), isActive: $jumpToModels) { EmptyView() }.hidden()
                            NavigationLink(destination: SystemPromptsView(), isActive: $jumpToSystemPrompts) { EmptyView() }.hidden()
                        }
                    }
                )
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $jumpToModels) { ModelsView() }
                Color.clear.navigationDestination(isPresented: $jumpToSystemPrompts) { SystemPromptsView() }
            }
        }
            .frame(width: geo.size.width, height: geo.size.height)   // NavigationStack 显式全屏
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // v2.9.242：进设置页彻底隐藏悬浮浏览器（不只是收成胶囊），杜绝任何遮挡
            FloatingBrowser.shared.hide()
            triggerProbe()   // v2.9.18：进入设置页自动探测一次，更新环境状态色
            // v7.1.74：push 返回（角色选择页等）强制重渲染——SwiftUI NavigationLink 快照会恢复
            // 旧 Toggle 状态，导致"开关明明开着、返回却显示关"（用户实测闪烁）
            hudRefresh.toggle()
        }
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                // v7.1.94：同 v4.4.21 修复——iOS16 navigationDestination(isPresented:)
                // 在设置页首帧出现时目标未注册，立即设 true 会被 SwiftUI 吞掉不跳
                // （用户实测"在设置中管理模型"点了没跳到模型 API 页）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToModels = true
                }
            }
            // v4.4.16：底部"指令"胶囊 → 跳到系统指令页
            // v4.4.21：延迟一帧触发——iOS16 navigationDestination(isPresented:) 在设置页首帧出现时目标未注册,
            // 立即设 true 会被 SwiftUI 吞掉不跳(用户实测'点指令没真正跳到系统指令页'); 延迟到下一帧目标注册后再跳
            if AppUIState.shared.settingsJumpToSystemPrompts {
                AppUIState.shared.settingsJumpToSystemPrompts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToSystemPrompts = true
                }
            }
        }
    }

    // MARK: - 数据源（两种视图共用）

    private func makeGroups() -> [SettingsGroup] {
        var groups: [SettingsGroup] = []

        // v7.1.75：MCP 服务器（外部工具接入）
        groups.append(SettingsGroup(header: L10n.t("mcp_servers"), items: [
            SettingsItem(title: L10n.t("mcp_servers"),
                         subtitle: "\(MCPClientManager.shared.servers.count) server\(MCPClientManager.shared.servers.count == 1 ? "" : "s")",
                         icon: "server.rack", color: .purple,
                         destination: AnyView(MCPManagerView()))
        ]))

        // 模型
        groups.append(SettingsGroup(header: L10n.t("sec_models"), items: [
            SettingsItem(title: L10n.t("row_model_api"),
                         subtitle: L10n.t("i18n_198", ModelStore.shared.configs.count, modelProviderName()),
                         icon: "rectangle.stack.badge.person.crop", color: .blue,
                         destination: AnyView(ModelsView())),
            SettingsItem(title: L10n.t("row_sys_prompts"),
                         subtitle: SystemPrompts.shared.selected.name,
                         icon: "text.book.closed.fill", color: .purple,
                         destination: AnyView(SystemPromptsView())),
            SettingsItem(title: L10n.t("row_dev_instructions"),
                         subtitle: devInstructionsSubtitle(),
                         icon: "doc.text.magnifyingglass", color: .orange,
                         destination: AnyView(DeveloperInstructionsView()))
        ]))

        // v6.1.5-14bm：工具中心——给用户看的分层工具总览（iOS/原生/Alpine）
        groups.append(SettingsGroup(header: L10n.t("i18n_1073"), items: [
            SettingsItem(title: L10n.t("i18n_200"),
                         subtitle: L10n.t("i18n_1162", ToolRegistry.shared.toolCount),
                         icon: "wrench.and.screwdriver.fill", color: .green,
                         destination: AnyView(ToolCenterView(inSheet: false)))
        ]))

        // 网络与抓包（v3.3.1：独立分组，不依赖开发者模式——普通用户也能直接看到抓包入口）
        groups.append(SettingsGroup(header: L10n.t("i18n_201"), items: [
            // v3.3.2：开关 + 点击进详情（Toggle 一键开/关，NavigationLink 进详情页）
            SettingsItem(title: L10n.t("i18n_1163"),
                         subtitle: vpnActiveSubtitle(),
                         icon: "antenna.radiowaves.left.and.right", color: .tmCyan,
                         destination: AnyView(VpnCaptureView()),
                         isOn: { VpnManager.shared.vpnActive },
                         onToggle: { on in
                             VpnManager.shared.toggleVpn { err in
                                 if let e = err {
                                     DispatchQueue.main.async {
                                         vpnToggleError = e
                                     }
                                 }
                             }
                         }),
            SettingsItem(title: L10n.t("row_netlog"),
                         subtitle: NetworkLog.lastCompatNote ?? L10n.t("i18n_202"),
                         icon: "network", color: .orange,
                         destination: AnyView(NetworkDebugView()))
        ]))

        // 线上编译
        groups.append(SettingsGroup(header: L10n.t("sec_build"), items: [
            SettingsItem(title: L10n.t("row_github"),
                         subtitle: L10n.t("i18n_203", githubAccountSubtitle()),
                         icon: "person.crop.circle.fill.badge.checkmark", color: .black,
                         destination: AnyView(GitHubAccountView())),
            SettingsItem(title: L10n.t("row_downloads"),
                         subtitle: L10n.t("i18n_204"),
                         icon: "arrow.down.circle.fill", color: .green,
                         destination: AnyView(DownloadsView()))
        ]))

        // 控制（远程控制/控制中心/操作宏 + 开发者模式开关）
        var controlItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("row_remote"),
                         subtitle: L10n.t("row_remote_sub"),
                         icon: "cursorarrow.click.2", color: .blue,
                         destination: AnyView(RemoteControlView())),
            // v2.9.144：AI 控制中心 + 操作宏（从聊天框移入设置，退出设置页后全屏弹出）
            SettingsItem(title: L10n.t("ui_172"),
                         subtitle: L10n.t("i18n_205"),
                         icon: "target", color: .indigo,
                         action: {
                             presentationMode.wrappedValue.dismiss()
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                 AppUIState.shared.controlPresented = true
                             }
                         })
        ]
        // v4.5.0：可爱助手开关（聊天页右下角悬浮 + 语音/点击互动，可切换角色）
        controlItems.append(SettingsItem(
            title: L10n.t("i18n_841"),
            subtitle: HUDManager.shared.lastStartError
                ?? (HUDManager.shared.isRunning ? L10n.t("i18n_207") : L10n.t("i18n_208")),
            icon: "heart.fill",
            color: .pink,
            // 点击进入角色选择页（v6.0.2：角色选择直接放进可爱助手）
            destination: AnyView(GirlCharacterPickerView()),
            isOn: { GirlCompanion.shared.enabled },
            onToggle: { on in
                GirlCompanion.shared.enabled = on
                // 打开可爱助手即自动拉起桌面悬浮 HUD（HUD 显示当前角色小女孩）
                if on { _ = HUDManager.shared.start() }
                else { _ = HUDManager.shared.stop() }
                hudRefresh.toggle()
                // v7.1.74：start/stop 异步（launchctl load / posix_spawn 需要时间），
                // 延迟再刷一次，副标题 isRunning 与真实进程状态对齐（避免显示"未运行"闪烁）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { hudRefresh.toggle() }
            }
        ))
        groups.append(SettingsGroup(header: L10n.t("sec_control"), items: controlItems))

        // 开发者（v6.0.28：默认开启，去掉开关）
        var devItems: [SettingsItem] = [
                // v4.3.53：图标主题功能彻底移除（含 Resources 残留图标文件）。
                // 侧载环境下动态图标注册可能干扰 MobileIcons 图标缓存（分享面板崩溃嫌疑项）。
                SettingsItem(title: L10n.t("row_device_fake"),
                             subtitle: L10n.t("i18n_209"),
                             icon: "iphone.gen3.radiowaves.left.and.right", color: .pink,
                             destination: AnyView(FakeDeviceView())),
                SettingsItem(title: L10n.t("row_transcripts"),
                             subtitle: L10n.t("i18n_210"),
                             icon: "text.book.closed.fill", color: .tmBrown,
                             destination: AnyView(ConversationTranscriptView())),
                SettingsItem(title: L10n.t("i18n_610"),
                             subtitle: L10n.t("i18n_212"),
                             icon: "terminal.fill", color: .teal,
                             destination: AnyView(RemoteAccessView())),
                SettingsItem(title: L10n.t("row_browser"),
                             subtitle: L10n.t("i18n_213"),
                             icon: "globe.asia.australia.fill", color: .cyan,
                             action: {
                                 presentationMode.wrappedValue.dismiss()
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                     FloatingBrowser.shared.show()
                                 }
                             }),
                SettingsItem(title: L10n.t("row_agents"),
                             subtitle: L10n.t("i18n_214"),
                             icon: "person.3.fill", color: .indigo,
                             destination: AnyView(AgentsAndSkillsView())),
                SettingsItem(title: L10n.t("row_kb"),
                             subtitle: L10n.t("i18n_215"),
                             icon: "books.vertical.fill", color: .brown,
                             destination: AnyView(KnowledgeBaseView()))
            ]
            groups.append(SettingsGroup(header: L10n.t("i18n_216"), items: devItems))

        // 安全
        groups.append(SettingsGroup(header: L10n.t("sec_security"), items: [
            SettingsItem(title: L10n.t("row_audit"),
                         subtitle: L10n.t("i18n_217"),
                         icon: "list.bullet.rectangle", color: .tmIndigo,
                         destination: AnyView(AuditLogView())),
            SettingsItem(title: L10n.t("row_workspace"),
                         subtitle: L10n.t("i18n_218"),
                         icon: "folder", color: .blue,
                         destination: AnyView(WorkspaceBrowserView())),
            SettingsItem(title: L10n.t("i18n_219"),
                         subtitle: L10n.t("i18n_220"),
                         icon: "sparkles.rectangle.stack", color: .orange,
                         destination: AnyView(CleanupCenterView())),
            SettingsItem(title: L10n.t("i18n_1164"),
                         subtitle: L10n.t("i18n_221"),
                         icon: "shield.lefthalf.filled", color: .green,
                         destination: AnyView(CorunaShieldView())),
        ]))

        // v7.4.0-fix73d：提示音——AI 完成任务提示音开关 + 点击进子页选音色
        // （复用"开关优先"模式：isOn 开关键 + destination 子页，NavigationLink 包 Toggle）
        groups.append(SettingsGroup(header: "提示音", items: [
            SettingsItem(title: "任务完成提示音",
                         subtitle: TaskNotify.shared.soundEnabled ? "已开启 · 点击选择音色" : "已关闭",
                         icon: "bell.badge.fill", color: .orange,
                         destination: AnyView(SoundSettingsView()),
                         isOn: { TaskNotify.shared.soundEnabled },
                         onToggle: { on in TaskNotify.shared.soundEnabled = on }),
        ]))

        // 关于
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var aboutItems: [SettingsItem] = [
            SettingsItem(title: L10n.t("about_title"),
                         subtitle: L10n.t("i18n_1165"),
                         icon: "person.crop.circle.fill", color: .blue,
                         destination: AnyView(AboutAuthorView())),
            SettingsItem(title: L10n.t("row_lang"),
                         subtitle: LanguageManager.shared.language.displayName,
                         icon: "globe", color: .purple,
                         action: { showLanguagePicker = true }),
            // v4.3.29：一键更新——单行点击即进入更新页面（里面包含检查更新和镜像源设置）
            // v4.3.39：发现新版时行尾显示红点提醒
            SettingsItem(title: L10n.t("row_check_update"),
                         subtitle: updateSubtitle(),
                         icon: "arrow.triangle.2.circlepath.circle.fill", color: .green,
                         destination: AnyView(UpdateView()),
                         redDot: { UpdateManager.shared.hasUpdateRedDot }),
            SettingsItem(title: L10n.t("version"),
                         subtitle: ver, icon: "number.circle.fill", color: .gray,
                         destination: nil,
                         value: ver)   // v6.1.5-14bf：版本号行尾恢复显示（14ax 移除副标题后丢失）
        ]
        groups.append(SettingsGroup(header: L10n.t("sec_about"), items: aboutItems))

        return groups
    }

    // MARK: - 列表模式

    // v4.3.64：已移除 testShareSheet（系统分享面板在本设备侧载环境必崩，无诊断价值）

    private var listBody: some View {
        List {
            // v4.3.64：移除"测试系统分享面板（Debug）"——本设备侧载环境任何系统分享面板
            // 都崩（MobileIcons/CoreImage SIGSEGV，v4.3.43-63 全部真机证伪），
            // 该按钮只会闪退，无诊断价值。分享统一走 ShareCenter 自建菜单（存储到文件/拷贝）。
            ForEach(makeGroups(), id: \.header) { group in
                Section(header: SettingSectionHeader(title: group.header)) {
                    ForEach(group.items) { item in
                        listRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .actionSheet(isPresented: $showLanguagePicker) {
            ActionSheet(
                title: Text(L10n.t("row_lang")),
                buttons: AppLanguage.allCases.map { lang in
                    .default(Text(lang.displayName)) {
                        LanguageManager.shared.language = lang
                    }
                } + [.cancel(Text(L10n.t("cancel")))]
            )
        }
        .alert(L10n.t("i18n_1163"), isPresented: Binding(
            get: { !vpnToggleError.isEmpty },
            set: { if !$0 { vpnToggleError = "" } }
        )) {
            Button(L10n.t("ui_44"), role: .cancel) { vpnToggleError = "" }
        } message: {
            Text(vpnToggleError)
        }
        // v4.3.30：更新镜像源编辑（GitHub 被墙时的备用通道，每行一个前缀，逗号分隔）
        .sheet(isPresented: $showMirrorEditor) {
            NavigationView {
                Form {
                    Section {
                        TextEditor(text: $mirrorsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                }
                .navigationTitle(L10n.t("i18n_243"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("ui_40")) { showMirrorEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("i18n_1166")) {
                            UpdateManager.shared.saveMirrors(mirrorsText)
                            showMirrorEditor = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func listRow(_ item: SettingsItem) -> some View {
        // 开关优先：Toggle 项同时带 destination 时用 NavigationLink 包 Toggle（如抓包 VPN 开关）
        if let isOn = item.isOn, let onToggle = item.onToggle {
            let toggle = Toggle(isOn: Binding(get: isOn, set: onToggle)) {
                SettingRowContent(item: item)
            }
            .accentColor(.tmCyan)
            if let dest = item.destination {
                NavigationLink(destination: dest) { toggle }
            } else {
                toggle
            }
        } else if let dest = item.destination {
            NavigationLink(destination: dest) {
                SettingRowContent(item: item)
            }
        } else if let action = item.action {
            Button(action: action) {
                SettingRowContent(item: item)
            }
        } else {
            SettingRowContent(item: item)
        }
    }

    // MARK: - 动态值

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        if let r = lastProbe {
            let failed = r.checks.filter { !$0.passed }.count
            return r.ready ? L10n.t("i18n_1167") : L10n.t("i18n_223", failed)
        }
        return L10n.t("i18n_224")
    }

    private func envIcon() -> String {
        if let r = lastProbe {
            return r.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private func envColor() -> Color {
        if let r = lastProbe {
            return r.ready ? .green : .red
        }
        return .gray
    }

    // v2.9.144：探测含 spawnRoot/文件遍历，主线程同步会卡死被看门狗杀（表现为闪退）
    private func triggerProbe() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async {
                self.lastProbe = r
            }
        }
    }

    private func modelProviderName() -> String {
        ModelStore.shared.configs.first(where: { $0.isDefault })?.provider ?? ModelStore.shared.configs.first?.provider ?? L10n.t("i18n_1168")
    }

    private func permissionCount() -> Int {
        7
    }

    private func githubAccountSubtitle() -> String {
        if let login = GitHubAccountStore.shared.activeLogin {
            return "@\(login)"
        }
        let count = GitHubAccountStore.shared.accounts.count
        return count == 0 ? L10n.t("i18n_225") : L10n.t("i18n_226", count)
    }

    private func devInstructionsSubtitle() -> String {
        let count = DeveloperInstructionStore.shared.list().count
        return L10n.t("i18n_227", count)
    }

    private func sshConfigSubtitle() -> String {
        let host = UserDefaults.standard.string(forKey: "ssh.host") ?? ""
        return host.isEmpty ? L10n.t("i18n_1168") : host
    }

    // v4.3.29：副标题实时反映更新状态（检查中/下载进度/发现新版本/错误/已是最新）
    // v4.3.30：已是最新时附带检查源（GitHub / jsDelivr / 镜像）
    private func updateSubtitle() -> String {
        let m = updateManager
        if m.isChecking {
            return L10n.t("i18n_228")
        }
        if m.isDownloading {
            let pct = Int(m.downloadProgress * 100)
            return L10n.t("i18n_229", m.latestVersion ?? "", pct)
        }
        if m.updateAvailable, let v = m.latestVersion {
            return L10n.t("i18n_230", v)
        }
        if let s = m.installMessage, !s.isEmpty {
            return s
        }
        if let e = m.errorMessage, !e.isEmpty {
            return e
        }
        if let s = m.lastSource {
            return L10n.t("i18n_231", s)
        }
        return L10n.t("i18n_232")
    }

    // v4.3.30：镜像源副标题（显示当前生效的镜像，去协议前缀）
    private func mirrorSubtitle() -> String {
        let list = UpdateManager.shared.mirrors
            .map { $0.replacingOccurrences(of: "https://", with: "")
                      .replacingOccurrences(of: "http://", with: "")
                      .replacingOccurrences(of: "/", with: "") }
        return L10n.t("i18n_1169") + list.joined(separator: ", ")
    }

    // v3.3.2：抓包 VPN 开关副标题
    private func vpnActiveSubtitle() -> String {
        VpnManager.shared.vpnActive ? L10n.t("i18n_233") : L10n.t("i18n_234")
    }
}

/// 行内容（列表/卡片共用视觉）
struct SettingRowContent: View {
    let item: SettingsItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.color)
                    .frame(width: 40, height: 40)
                Image(systemName: item.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)   // v6.1.5-14ay：去掉灰色副标题后黑色标题放大（body→headline）
                    .foregroundColor(.primary)
                // v6.1.5-14ax：灰色副标题介绍已按用户要求移除
            }
            Spacer(minLength: 0)
            // v6.1.5-14bf：行尾数值（版本号等）——灰字但字号足够可见
            if let value = item.value {
                Text(value)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.secondary)
            }
            // v4.3.39：行尾红点提醒（新版更新等）——红点在行尾右侧，点击行即处理
            if let redDot = item.redDot, redDot() {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
            }
        }
        .padding(.vertical, 5)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}

// v6.0.28：更新页面（包含检查更新和更新镜像源设置）
struct UpdateView: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var showMirrorEditor = false
    @State private var mirrorsText = ""
    
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
    
    private var updateSubtitle: String {
        if updateManager.isChecking { return L10n.t("i18n_235") }
        if updateManager.downloadProgress > 0 { return L10n.t("i18n_236", updateManager.latestVersion ?? "", Int(updateManager.downloadProgress*100)) }
        if updateManager.updateAvailable, let v = updateManager.latestVersion {
            return L10n.t("i18n_237", v)
        }
        if let s = updateManager.installMessage, !s.isEmpty { return s }
        return L10n.t("i18n_238")
    }
    
    var body: some View {
        List {
            Section(header: Text(L10n.t("i18n_239"))) {
                HStack {
                    Text(L10n.t("i18n_240"))
                    Spacer()
                    Text(currentVersion)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(L10n.t("ui_110"))
                    Spacer()
                    Text(updateSubtitle)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button(action: { updateManager.updateNow(currentVersion: currentVersion) }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L10n.t("i18n_241"))
                    }
                }
            }
            
            Section(header: Text(L10n.t("i18n_242"))) {
                Button(action: {
                    mirrorsText = UpdateManager.shared.mirrorsText
                    showMirrorEditor = true
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.orange)
                        Text(L10n.t("i18n_243"))
                        Spacer()
                        Text(mirrorHost())
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("i18n_1170"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMirrorEditor) {
            NavigationView {
                Form {
                    Section {
                        TextEditor(text: $mirrorsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 110)
                    }
                }
                .navigationTitle(L10n.t("i18n_243"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("ui_40")) { showMirrorEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("i18n_1166")) {
                            UpdateManager.shared.saveMirrors(mirrorsText)
                            showMirrorEditor = false
                        }
                    }
                }
            }
        }
    }
    
    private func mirrorHost() -> String {
        let m = UpdateManager.shared.mirrorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return L10n.t("i18n_1171") }
        let first = m.components(separatedBy: [",", "\n"]).first(where: { !$0.isEmpty }) ?? ""
        return first.isEmpty ? L10n.t("ui_144") : first
    }
}

// v2.9.68：SSH 远程连接设置
struct SSHSettingsView: View {
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var keyPath: String = ""
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Form {
            Section(header: Text(L10n.t("ui_137"))) {
                HStack {
                    Text(L10n.t("ui_20")).frame(width: 80, alignment: .leading)
                    TextField(L10n.t("i18n_1172"), text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text(L10n.t("ui_119")).frame(width: 80, alignment: .leading)
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text(L10n.t("ui_112")).frame(width: 80, alignment: .leading)
                    TextField(L10n.t("i18n_1173"), text: $user)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text(L10n.t("ui_131"))) {
                HStack {
                    Text(L10n.t("ui_46")).frame(width: 80, alignment: .leading)
                    SecureField(L10n.t("ui_46"), text: $password)
                }
                HStack {
                    Text(L10n.t("ui_117")).frame(width: 80, alignment: .leading)
                    TextField(L10n.t("i18n_1174"), text: $keyPath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section {
                Button(L10n.t("ui_28")) {
                    let defaults = UserDefaults.standard
                    defaults.set(host, forKey: "ssh_host")
                    defaults.set(Int(port) ?? 22, forKey: "ssh_port")
                    defaults.set(user, forKey: "ssh_user")
                    defaults.set(password, forKey: "ssh_password")
                    defaults.set(keyPath, forKey: "ssh_key_path")
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.blue)
            }
            // v6.1.5-14ax：SSH 配置说明区块已整体移除（原 ui_140 灰色介绍）
        }
        .navigationTitle(L10n.t("i18n_1175"))
        .onAppear {
            let defaults = UserDefaults.standard
            host = defaults.string(forKey: "ssh_host") ?? ""
            port = "\(defaults.integer(forKey: "ssh_port") == 0 ? 22 : defaults.integer(forKey: "ssh_port"))"
            user = defaults.string(forKey: "ssh_user") ?? ""
            password = defaults.string(forKey: "ssh_password") ?? ""
            keyPath = defaults.string(forKey: "ssh_key_path") ?? ""
        }
    }
}
