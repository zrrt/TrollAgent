import SwiftUI

// v2.9.75：远程控制设置页面
// ControlAgent 通用 UI 控制的使用说明和状态展示
// v2.9.77：界面美化——PageHeader + 卡片化 + 双语

struct RemoteControlView: View {
    @State private var connectionStatus: String = L10n.t("status_disconnected")
    @State private var isChecking = false
    @State private var appInfo: String = ""
    @State private var keepAliveOn = UserDefaults.standard.bool(forKey: "trollagent.keepalive")

    var body: some View {
        PageContainer {
            PageHeader(
                icon: "cursorarrow.click.2",
                title: L10n.t("page_remote"),
                subtitle: L10n.t("page_remote_sub"),
                colors: [.tmCyan, .blue]
            )

            // 连接状态卡
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.15))
                                .frame(width: 34, height: 34)
                            Circle()
                                .stroke(statusColor.opacity(0.4), lineWidth: 2)
                                .frame(width: 34, height: 34)
                            Image(systemName: isChecking ? "arrow.triangle.2.circlepath" : (connectionStatus == L10n.t("status_connected") ? "checkmark" : "xmark"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(statusColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ControlAgent")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(connectionStatus)
                                .font(.caption)
                                .foregroundColor(statusColor)
                        }
                        Spacer()
                        Button(action: checkConnection) {
                            HStack(spacing: 6) {
                                if isChecking {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text(isChecking ? "" : L10n.t("btn_check_connection"))
                                    .font(.footnote)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.tmCyan.opacity(0.15))
                            .foregroundColor(.tmCyan)
                            .cornerRadius(10)
                        }
                        .disabled(isChecking)
                    }
                    if !appInfo.isEmpty {
                        Divider()
                        HStack {
                            Text("Bundle ID")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(appInfo)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    Divider()
                    Text("127.0.0.1:4789 · localhost only")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // v2.9.109：真后台保活卡（借鉴 ImmortalizerJailed 机制）
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: keepAliveOn ? "bolt.heart.fill" : "bolt.heart")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(keepAliveOn ? .tmCyan : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("ui_114"))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(keepAliveOn ? L10n.t("i18n_450") : L10n.t("i18n_451"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $keepAliveOn)
                            .labelsHidden()
                            .onChange(of: keepAliveOn) { on in
                                toggleKeepAlive(on)
                            }
                    }
                    Text(L10n.t("ui_8"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // 能力
            CardSectionHeader(icon: "sparkles", title: L10n.t("page_remote_sub"))
            CardBox {
                VStack(alignment: .leading, spacing: 10) {
                    capabilityRow("tree", L10n.t("i18n_452"))
                    capabilityRow("camera", L10n.t("i18n_453"))
                    capabilityRow("hand.tap", L10n.t("i18n_454"))
                    capabilityRow("keyboard", L10n.t("i18n_455"))
                    capabilityRow("checkmark.circle", L10n.t("i18n_1108"))
                }
            }

            // 使用流程
            CardSectionHeader(icon: "list.number", title: L10n.t("i18n_456"))
            CardBox {
                VStack(alignment: .leading, spacing: 12) {
                    stepView(1, L10n.t("i18n_502"))
                    stepView(2, L10n.t("i18n_1109"))
                    stepView(3, L10n.t("i18n_458"))
                    stepView(4, L10n.t("i18n_1110"))
                    stepView(5, L10n.t("i18n_459"))
                }
            }

            // 工具列表
            CardSectionHeader(icon: "wrench.and.screwdriver", title: L10n.t("i18n_460"))
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    toolRow("control.inject", L10n.t("i18n_1111"))
                    toolRow("control.status", L10n.t("i18n_461"))
                    toolRow("control.ui_tree", L10n.t("i18n_1112"))
                    toolRow("control.screenshot", L10n.t("i18n_462"))
                    toolRow("control.tap", L10n.t("i18n_463"))
                    toolRow("control.swipe", L10n.t("i18n_1113"))
                    toolRow("control.type", L10n.t("i18n_464"))
                    toolRow("control.key", L10n.t("i18n_1114"))
                }
            }

            // 注意事项
            CardSectionHeader(icon: "exclamationmark.triangle", title: L10n.t("i18n_465"), color: .orange)
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    noteRow(L10n.t("i18n_1115"))
                    noteRow(L10n.t("i18n_1116"))
                    noteRow(L10n.t("i18n_466"))
                    noteRow(L10n.t("i18n_1090"))
                    noteRow(L10n.t("i18n_1118"))
                    // v7.1.286：控制进度实时推送系统通知（前台可见）
                    noteRow(L10n.t("i18n_1261"))
                }
            }
        }
        .navigationTitle(L10n.t("page_remote"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusColor: Color {
        if isChecking { return .orange }
        return connectionStatus == L10n.t("status_connected") ? .green : .secondary
    }

    private func stepView(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func toolRow(_ name: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.tmCyan)
                .frame(width: 120, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func capabilityRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.tmCyan)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func noteRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    /// v2.9.109：切换真后台保活（目标 App + TrollAgent 自身）
    private func toggleKeepAlive(_ on: Bool) {
        postKeepAliveNotification(on)
        if on {
            BackgroundKeepAlive.shared.start()
        } else {
            BackgroundKeepAlive.shared.stop()
        }
    }

    private func checkConnection() {
        isChecking = true
        connectionStatus = L10n.t("status_checking")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ControlAgentTools.shared.status()
            DispatchQueue.main.async {
                isChecking = false
                if result["connected"] as? Bool == true {
                    connectionStatus = L10n.t("status_connected")
                    appInfo = (result["app"] as? String) ?? (result["app_name"] as? String) ?? ""
                } else {
                    connectionStatus = L10n.t("status_disconnected")
                    appInfo = ""
                }
            }
        }
    }
}
