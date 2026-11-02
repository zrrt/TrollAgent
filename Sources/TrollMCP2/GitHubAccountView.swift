import SwiftUI
import SafariServices
import UIKit

/// GitHub 账号 + 线上编译设置页（v2.9.5）
/// 任何人的 GitHub 账号都可登录/切换，用该账号在云端 Actions 编译 tweak。
/// 注意：仅使用 iOS 14 可用 API。
struct GitHubAccountView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var showAdd = false
    @State private var tweakName = "CompileProbe"
    @State private var busyMessage: String?
    @State private var toast: String?

    var body: some View {
        List {
            currentAccountSection
            savedAccountsSection
            buildSection
            runsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("i18n_1123"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddGitHubAccountView()
        }
        .onAppear {
            store.fetchRuns { _ in }
        }
        .onChange(of: store.lastError) { err in
            if let err = err { toast = err }
        }
        .onChange(of: toast) { msg in
            if msg != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { toast = nil }
                }
            }
        }
        // busy overlay（iOS14 兼容：无 alignment 参数）
        .overlay(busyOverlay)
        .overlay(bottomToast, alignment: .bottom)
    }

    @ViewBuilder private var currentAccountSection: some View {
        Section(header: SettingSectionHeader(title: L10n.t("i18n_544"))) {
            if let acct = store.activeAccount {
                HStack(spacing: 12) {
                    AvatarView(login: acct.login, url: acct.avatarURL)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(acct.name ?? acct.login).font(.headline)
                        Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if store.isVerifying {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                .padding(.vertical, 4)

                // v7.1.292：编译就绪度自动诊断（登录成功后程序自动跑，UI 自动展示）
                if store.activeAccount != nil {
                    if store.checksReady {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.allReady ? "✅ 编译就绪，可直接触发线上编译"
                                                : "⚠️ 编译未就绪，还需处理 \(store.checks.filter { !$0.ok }.count) 项：")
                                .font(.footnote.weight(.semibold))
                            ForEach(store.checks) { c in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(c.ok ? .green : .orange)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(c.label).font(.caption)
                                        if !c.detail.isEmpty {
                                            Text(c.detail).font(.caption2).foregroundColor(.secondary)
                                        }
                                        if !c.ok && !c.hint.isEmpty {
                                            Text(c.hint).font(.caption2).foregroundColor(.orange)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("检测编译就绪度…").font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_98")).foregroundColor(.secondary)
                    Spacer()
                }
            }

            SettingRowButton(
                title: store.activeAccount == nil ? L10n.t("i18n_1124") : L10n.t("i18n_545"),
                subtitle: L10n.t("i18n_1125"),
                icon: "person.badge.plus",
                color: .blue
            ) { showAdd = true }
        }
    }

    @ViewBuilder private var savedAccountsSection: some View {
        if !store.accounts.isEmpty {
            Section(header: SettingSectionHeader(title: L10n.t("i18n_546"))) {
                ForEach(store.accounts) { acct in
                    accountRow(acct)
                }
            }
        }
    }

    private func accountRow(_ acct: GitHubAccount) -> some View {
        Button {
            store.switchTo(acct.login)
            toast = L10n.t("i18n_547", acct.login)
        } label: {
            HStack(spacing: 12) {
                AvatarView(login: acct.login, url: acct.avatarURL)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acct.name ?? acct.login).font(.body)
                    Text("@\(acct.login)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if store.activeLogin == acct.login {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Image(systemName: "person.circle").foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button {
                store.remove(acct.login)
                toast = L10n.t("i18n_548", acct.login)
            } label: {
                Label(L10n.t("i18n_549"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder private var buildSection: some View {
        Section(header: SettingSectionHeader(title: L10n.t("i18n_1126"))) {
            TextField(L10n.t("i18n_1127"), text: $tweakName)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))

            SettingRowButton(
                title: L10n.t("i18n_550"),
                subtitle: store.activeAccount == nil ? L10n.t("i18n_551") : "\(store.repoOwner)/\(store.repoName) · workflow=\(store.workflowId)",
                icon: "hammer.fill",
                color: .orange
            ) {
                guard store.activeAccount != nil else {
                    toast = L10n.t("i18n_1128"); return
                }
                busyMessage = L10n.t("i18n_552", tweakName)
                store.triggerBuild(tweak: tweakName) { ok, msg in
                    busyMessage = nil
                    toast = ok ? msg : (msg ?? L10n.t("i18n_553"))
                    if ok { store.fetchRuns { _ in } }
                }
            }
            .disabled(store.activeAccount == nil || store.isTriggering)

            if store.isTriggering {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t("ui_130")).font(.caption).foregroundColor(.secondary)
                }
            }

            NavigationLink(destination: GitHubRepoSettingsView()) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue)
                            .frame(width: 34, height: 34)
                        Image(systemName: "server.rack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("ui_23")).font(.body)
                        Text("\(store.repoOwner)/\(store.repoName) · \(store.workflowId) · \(store.branch)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var runsSection: some View {
        Section(header: SettingSectionHeader(title: L10n.t("i18n_554"))) {
            if store.runs.isEmpty {
                HStack {
                    Text(L10n.t("ui_92")).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button(L10n.t("i18n_986")) {
                        store.fetchRuns { _ in }
                    }
                    .font(.caption)
                }
            } else {
                ForEach(store.runs) { run in
                    HStack {
                        Text(run.statusText).font(.body)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(run.displayTitle).font(.caption).lineLimit(1)
                            Text("#\(run.id) · \(shortTime(run.createdAt))").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                Button(L10n.t("i18n_556")) {
                    store.fetchRuns { _ in }
                }
                .font(.footnote)
                .foregroundColor(.blue)
            }
        }
    }

    @ViewBuilder private var busyOverlay: some View {
        if let msg = busyMessage {
            VStack(spacing: 10) {
                ProgressView()
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground).opacity(0.95)))
            .shadow(radius: 8)
        }
    }

    @ViewBuilder private var bottomToast: some View {
        if let msg = toast {
            Text(msg)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color(.systemGray5)))
                .padding(.bottom, 8)
        }
    }

    private func shortTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: d)
    }
}

// MARK: - 头像（首字母兜底，避免额外网络图片依赖）

struct AvatarView: View {
    let login: String
    let url: String?

    var body: some View {
        ZStack {
            Circle().fill(avatarColor(login))
            Text(String(login.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func avatarColor(_ s: String) -> Color {
        let hue = Double(abs(s.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

// MARK: - 添加账号（PAT 登录）

struct AddGitHubAccountView: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var store = GitHubAccountStore.shared
    @State private var token = ""
    @State private var errorMsg: String?
    @State private var loading = false
    // Device Flow 状态
    @State private var deviceCode: GitHubAccountStore.DeviceCode?
    @State private var deviceStep = 0        // 0 未开始 / 1 等待授权 / 2 完成
    @State private var safariURL: URL?
    @State private var showSafari = false
    @State private var copied = false   // 验证码已自动复制

    var body: some View {
        
            Form {
                webLoginSection
                patLoginSection
            }
            .navigationTitle(L10n.t("i18n_1129"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if loading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button(L10n.t("i18n_557")) {
                            login()
                        }
                        .disabled(token.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showSafari) {
                if let url = safariURL {
                    SafariWebView(url: url)
                }
            }
            .onChange(of: store.activeAccount?.login) { _ in
                // v2.9.110：兜底——轮询成功落库（activeAccount 变化）时若还停在等待页，补一次成功反馈
                if deviceStep == 1, store.activeAccount != nil {
                    deviceStep = 2
                    showSafari = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
    }

    @ViewBuilder private var webLoginSection: some View {
        Section(header: SettingSectionHeader(title: L10n.t("i18n_558"))) {
            if deviceStep == 0 {
                SettingRowButton(
                    title: L10n.t("i18n_559"),
                    subtitle: store.clientID.isEmpty ? L10n.t("i18n_560") : "Client ID: \(store.clientID)",
                    icon: "safari.fill",
                    color: .black
                ) {
                    startDeviceFlow()
                }
            } else if deviceStep == 1, let dc = deviceCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("ui_71")).font(.footnote).foregroundColor(.secondary)
                    HStack {
                        Text(dc.user_code)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: { copyCode(dc.user_code) }) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundColor(copied ? .green : .blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    Text(L10n.t("ui_43"))
                        .font(.caption).foregroundColor(.secondary)
                    SettingRowButton(
                        title: L10n.t("i18n_561"),
                        subtitle: dc.verification_uri,
                        icon: "safari",
                        color: .blue
                    ) {
                        openVerification(dc.verification_uri)
                    }
                    // v7.1.292：卡 "Use GitHub Mobile" 时的引导框 + 系统 Safari 备选
                    //（内嵌 Safari 的 app 跳转受限；系统 Safari 跳转更完整、可走邮箱验证码）
                    VStack(alignment: .leading, spacing: 5) {
                        Text("如果卡在 Use GitHub Mobile 没反应：")
                            .font(.caption).fontWeight(.semibold).foregroundColor(.orange)
                        Text("① 点授权页的“Send a code via email”用邮箱验证码；② 或先开启 2FA 再授权；③ 或用下方“系统浏览器打开”。设备验证一次后 GitHub 不再重复要求。")
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    SettingRowButton(
                        title: "用系统浏览器打开授权页",
                        subtitle: "系统 Safari 跳转更完整，可改用邮箱验证码",
                        icon: "safari.fill",
                        color: .orange
                    ) {
                        openExternal(dc.verification_uri)
                    }
                    if store.isDevicePolling {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(L10n.t("ui_120")).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text(L10n.t("ui_113")).font(.footnote).foregroundColor(.green)
            }
        }
    }

    @ViewBuilder private var patLoginSection: some View {
        Section(header: SettingSectionHeader(title: L10n.t("i18n_562"))) {
            SecureField("ghp_…", text: $token)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { login() }
            Button {
                login()
            } label: {
                Text("登录")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BorderlessButtonStyle())
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
            if let err = errorMsg {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: - Device Flow

    private func startDeviceFlow() {
        errorMsg = nil
        deviceStep = 0
        store.startDeviceFlow { code, err in
            if let code = code {
                self.deviceCode = code
                self.deviceStep = 1
                // 自动复制验证码到剪贴板（GitHub 授权页可自动识别/粘贴，gh CLI 同款）
                UIPasteboard.general.string = code.user_code
                self.copied = true
                // 自动开始轮询 + 打开授权页
                self.openVerification(code.verification_uri)
                store.pollDeviceToken(deviceCode: code) { ok, msg in
                    if ok {
                        // v2.9.110：授权成功必须反馈——显示成功、自动关浏览器、返回账号页
                        deviceStep = 2
                        showSafari = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            presentationMode.wrappedValue.dismiss()
                        }
                    } else {
                        errorMsg = msg ?? L10n.t("i18n_563")
                        deviceStep = 0
                        showSafari = false   // 失败也自动关掉浏览器
                    }
                }
            } else {
                errorMsg = err ?? L10n.t("i18n_564")
            }
        }
    }

    private func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        copied = true
    }

    private func openVerification(_ uri: String) {
        if let url = URL(string: uri) {
            safariURL = url
            showSafari = true
        }
    }

    // v7.1.292：用系统 Safari 打开授权页（内嵌 Safari 跳转 GitHub app 受限，系统 Safari 更完整）
    private func openExternal(_ uri: String) {
        if let url = URL(string: uri) {
            UIApplication.shared.open(url)
        }
    }

    private func login() {
        loading = true
        errorMsg = nil
        store.verifyAndLogin(token: token.trimmingCharacters(in: .whitespacesAndNewlines)) { ok, msg in
            loading = false
            if ok {
                presentationMode.wrappedValue.dismiss()
            } else {
                errorMsg = msg
            }
        }
    }
}

// MARK: - 内置 Safari（Device Flow 授权页）

struct SafariWebView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - 仓库与 workflow 设置

struct GitHubRepoSettingsView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var saved = false

    var body: some View {
        Form {
            Section(header: SettingSectionHeader(title: L10n.t("i18n_1130"))) {
                TextField("OAuth App Client ID", text: $store.clientID)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                Button(L10n.t("i18n_565")) {
                    store.restoreDefaultClientID()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        saved = false
                    }
                }
            }

            Section(header: SettingSectionHeader(title: L10n.t("i18n_566"))) {
                TextField(L10n.t("i18n_567"), text: $store.repoOwner)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField(L10n.t("i18n_568"), text: $store.repoName)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField(L10n.t("i18n_1131"), text: $store.workflowId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField(L10n.t("i18n_569"), text: $store.branch)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }

            Section {
                Button(L10n.t("i18n_1166")) {
                    store.persistNow()
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        saved = false
                    }
                }
                if saved {
                    Text(store.clientID.isEmpty ? L10n.t("i18n_570") : L10n.t("i18n_571"))
                        .font(.footnote).foregroundColor(.green)
                }
            }
        }
        .navigationTitle(L10n.t("i18n_572"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
