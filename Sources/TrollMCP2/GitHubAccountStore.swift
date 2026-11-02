import Foundation
import Combine

// MARK: - GitHub 账号模型

struct GitHubAccount: Codable, Identifiable, Equatable {
    var login: String
    var name: String?
    var avatarURL: String?
    var token: String
    var id: String { login }
}

/// GitHub Actions run 摘要 (用于线上编译状态展示）
struct GitHubRun: Identifiable {
    let id: Int
    let status: String          // queued / in_progress / completed
    let conclusion: String?     // success / failure / null
    let createdAt: String
    let headBranch: String
    let displayTitle: String

    var statusText: String {
        switch status {
        case "completed":
            return (conclusion ?? "unknown") == "success" ? "✅ done" : "❌ \(conclusion ?? "failed")"
        case "in_progress": return "⏳ building"
        default: return "🕐 queued"
        }
    }
}

/// 自动诊断项 (v7.1.292)：登录后程序自动检测编译就绪度，逐项展示 ok / hint
struct GHCheck: Identifiable, Equatable {
    let id: String        // token / 2fa / email / repo / actions
    let ok: Bool
    let label: String
    let detail: String
    let hint: String
}

// MARK: - GitHub 账号 + 线上编译 (v2.9.5）

/// 管理多个 GitHub 账号：PAT 登录 / 切换 / 删除 / 触发线上编译 workflow / 查询 run 状态。
/// Token 存 UserDefaults (与项目 GatewayClient 同款策略；TrollStore 下 Keychain 受 entitlements 限制不可靠）。
final class GitHubAccountStore: ObservableObject {
    static let shared = GitHubAccountStore()

    @Published private(set) var accounts: [GitHubAccount] = []
    @Published var activeLogin: String?
    @Published var isVerifying = false
    @Published var isTriggering = false
    @Published var lastError: String?
    @Published private(set) var runs: [GitHubRun] = []

    // v7.1.292：编译就绪度自动诊断（登录成功后程序自动跑，UI 自动展示）
    @Published private(set) var checks: [GHCheck] = []
    @Published private(set) var checksReady = false
    @Published private(set) var allReady = false

    // 目标仓库 (可在设置页修改；默认 trollmcp2 仓库 + build-tweak workflow）
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var workflowId: String
    @Published var branch: String

    // Device Flow 用 OAuth App client_id。
    // 默认值 = 内置共享 Client ID (origina47487lhe-droid 注册的 "TrollAgent 线上编译" OAuth App，
    // Device Flow 已启用）。任意 GitHub 用户都可借此授权，各自拿自己的 token——新手零配置。
    // 高级用户可在「仓库设置」覆盖为自己的 OAuth App。
    @Published var clientID: String

    // Device Flow 轮询状态
    @Published var deviceFlowState: String?   // 提示文案 (含 user_code）
    @Published var isDevicePolling = false
    private var pollTimer: DispatchSourceTimer?   // 持有强引用，防止局部变量被释放导致轮询停止

    private let accountsKey = "trollmcp2.github_accounts"
    private let activeKey = "trollmcp2.github_active"
    private let ownerKey = "trollmcp2.github_repo_owner"
    private let repoKey = "trollmcp2.github_repo_name"
    private let workflowKey = "trollmcp2.github_workflow_id"
    private let branchKey = "trollmcp2.github_branch"
    private let clientIDKey = "trollmcp2.github_client_id"

    /// 内置默认 OAuth App Client ID (origina47487lhe-droid 注册的 "TrollAgent 线上编译"，Device Flow 实测有效）
    static let defaultClientID = "Ov23li890n3hM15edlcw"

    private let apiBase = "https://api.github.com"
    private let loginBase = "https://github.com"

    init() {
        let def = UserDefaults.standard
        repoOwner = def.string(forKey: ownerKey) ?? "zrrt"
        repoName = def.string(forKey: repoKey) ?? "TrollAgent"
        workflowId = def.string(forKey: workflowKey) ?? "build-trollmcp2.yml"
        branch = def.string(forKey: branchKey) ?? "main"
        // v2.9.117：空字符串也回退内置默认 (旧版删空保存会覆盖默认值，导致"未设置 Client ID"）
        let savedCID = def.string(forKey: clientIDKey) ?? ""
        clientID = savedCID.isEmpty ? Self.defaultClientID : savedCID
        load()
    }

    // MARK: - 账号访问

    var activeAccount: GitHubAccount? {
        guard let login = activeLogin else { return nil }
        return accounts.first { $0.login == login }
    }

    var activeToken: String? { activeAccount?.token }

    func token(for login: String) -> String? {
        accounts.first { $0.login == login }?.token
    }

    // MARK: - 持久化

    private func load() {
        // v2.9.110：旧配置自动迁移——早期默认指向 origina47487lhe-droid (Actions 配额已耗尽）与
        // build-tweak workflow (已更名 build-trollmcp2.yml）。覆盖安装会保留旧 UserDefaults，
        // 这里检测到旧值自动纠正，避免线上编译 404 / 触发到错误仓库。
        let def = UserDefaults.standard
        if def.string(forKey: ownerKey) == "origina47487lhe-droid" {
            repoOwner = "zrrt"
        }
        if def.string(forKey: workflowKey) == "build-tweak" {
            workflowId = "build-trollmcp2.yml"
        }
        // v7.1.285：仓库 trollmcp2 → TrollAgent 迁移（旧名 API 301 / jsDelivr CDN 404，检测更新收不到新版）
        if def.string(forKey: repoKey) == "trollmcp2" {
            repoName = "TrollAgent"
        }
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let saved = try? JSONDecoder().decode([GitHubAccount].self, from: data) {
            accounts = saved
        }
        activeLogin = UserDefaults.standard.string(forKey: activeKey)
        if let l = activeLogin, !accounts.contains(where: { $0.login == l }) {
            activeLogin = accounts.first?.login
        }
        persist()   // v2.9.110：迁移后的值落盘，一次性纠正旧配置
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        UserDefaults.standard.set(activeLogin, forKey: activeKey)
        let def = UserDefaults.standard
        def.set(repoOwner, forKey: ownerKey)
        def.set(repoName, forKey: repoKey)
        def.set(workflowId, forKey: workflowKey)
        def.set(branch, forKey: branchKey)
        // v2.9.123：留空 = 使用内置默认，且删除旧的自定义值 (根治"清空无效"——旧错误值残留 UserDefaults 导致重启后仍 404）
        let trimmedCID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCID.isEmpty {
            def.removeObject(forKey: clientIDKey)
        } else {
            def.set(trimmedCID, forKey: clientIDKey)
        }
    }

    /// v2.9.124：一键恢复内置默认 (内存立即生效 + 持久化，避免"恢复后不重启仍报空值"）
    func restoreDefaultClientID() {
        clientID = Self.defaultClientID
        persistNow()
    }

    // MARK: - Device Flow (内置浏览器登录，gh CLI 同款）

    /// 设备授权码模型
    struct DeviceCode: Codable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    /// 第一步：请求设备授权码。回调返回验证 URL 与 user_code。
    func startDeviceFlow(completion: @escaping (DeviceCode?, String?) -> Void) {
        // v2.9.124：空值一律回退内置默认 (恢复默认/手动清空后即使不重启 App 也能直接登录）
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultClientID
            : clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "\(loginBase)/login/device/code")!, timeoutInterval: 30)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // scope：repo (读仓库+触发 workflow）+ workflow (workflow dispatch 必须）+ user:email (诊断邮箱是否已验证）
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&scope=repo%20workflow%20user:email"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = L10n.t("i18n_807", err.localizedDescription)
                    completion(nil, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data,
                      let code = try? JSONDecoder().decode(DeviceCode.self, from: data) else {
                    let raw = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""
                    self.lastError = status == 404 ? L10n.t("i18n_1189") : L10n.t("i18n_809", status, String(raw.prefix(200)))
                    completion(nil, self.lastError)
                    return
                }
                self.deviceFlowState = L10n.t("i18n_810", code.user_code)
                NetworkLog.shared.log(L10n.t("i18n_811", code.user_code))
                completion(code, nil)
            }
        }.resume()
    }

    /// 第二步：轮询换取 access_token (interval 秒一次，最长 expires_in 秒）。
    func pollDeviceToken(deviceCode: DeviceCode, completion: @escaping (Bool, String?) -> Void) {
        isDevicePolling = true
        deviceFlowState = L10n.t("i18n_812", deviceCode.user_code)

        let deadline = Date().addingTimeInterval(Double(deviceCode.expires_in))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        pollTimer = timer
        timer.schedule(deadline: .now() + Double(deviceCode.interval), repeating: Double(deviceCode.interval))
        timer.setEventHandler { [weak self] in
            guard let self = self else { timer.cancel(); return }
            if Date() > deadline {
                timer.cancel()
                self.pollTimer = nil
                DispatchQueue.main.async {
                    self.isDevicePolling = false
                    self.deviceFlowState = nil
                    completion(false, L10n.t("i18n_813"))
                }
                return
            }
            self.exchangeDeviceToken(deviceCode: deviceCode) { token, error in
                if let token = token {
                    timer.cancel()
                    self.pollTimer = nil
                    DispatchQueue.main.async {
                        self.isDevicePolling = false
                        self.deviceFlowState = nil
                        // 用拿到的 token 走统一验证流程 (GET /user + 存储）
                        self.finishLoginWith(token: token) { ok, msg in
                            completion(ok, msg)
                        }
                    }
                } else if let error = error {
                    // v3.0.42：只有"终止性"错误才停轮询；网络错误/解析failed/authorization_pending/slow_down
                    // 一律继续等下一次——之前网络错误会 cancel timer，移动网络一抖授权流程就死，卡"等待授权"。
                    let terminalErrors = ["access_denied", "expired_token",
                                          "incorrect_client_credentials", "invalid_grant"]
                    if terminalErrors.contains(error) {
                        timer.cancel()
                        self.pollTimer = nil
                        DispatchQueue.main.async {
                            self.isDevicePolling = false
                            self.deviceFlowState = nil
                            completion(false, error)
                        }
                    }
                    // 可重试错误：继续轮询 (timer 按 interval 再次触发）
                }
            }
        }
        timer.resume()
    }

    private func exchangeDeviceToken(deviceCode: DeviceCode,
                                     completion: @escaping (String?, String?) -> Void) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "\(loginBase)/login/oauth/access_token")!, timeoutInterval: 20)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cid)&device_code=\(deviceCode.device_code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? deviceCode.device_code)&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { data, _, err in
            if err != nil { completion(nil, L10n.t("i18n_814")); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, L10n.t("i18n_815"))
                return
            }
            if let token = json["access_token"] as? String {
                completion(token, nil)
            } else if let err = json["error"] as? String {
                completion(nil, err)   // authorization_pending / slow_down / expired_token / access_denied
            } else {
                completion(nil, L10n.t("i18n_816"))
            }
        }.resume()
    }

    /// 统一登录落库：验证 token 身份 → 加入/更新账号
    private func finishLoginWith(token: String, completion: @escaping (Bool, String?) -> Void) {
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.lastError = L10n.t("i18n_807", err.localizedDescription)
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = L10n.t("i18n_817", status)
                    completion(false, self.lastError)
                    return
                }
                let acct = GitHubAccount(login: login,
                                         name: json["name"] as? String,
                                         avatarURL: json["avatar_url"] as? String,
                                         token: token)
                // v2.9.117：全新账号授权OK后，若 Owner 仍是内置默认值 → 自动填入当前登录账号
                let isDefaultOwner = (self.repoOwner == "zrrt" || self.repoOwner == "origina47487lhe-droid")
                if isDefaultOwner && self.repoOwner != login {
                    self.repoOwner = login
                    self.persist()
                }
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log(L10n.t("i18n_818", login))
                self.persist()
                self.runDiagnostics()   // v7.1.292：登录成功自动诊断编译就绪度
                completion(true, L10n.t("i18n_819", login))
            }
        }.resume()
    }

    // MARK: - PAT 登录 / 验证

    /// 用 GitHub PAT 验证并登录/更新账号。OK回调 true + 账号 login。
    func verifyAndLogin(token: String, completion: @escaping (Bool, String?) -> Void) {
        guard !token.isEmpty else {
            lastError = L10n.t("i18n_820")
            completion(false, lastError)
            return
        }
        isVerifying = true
        var req = URLRequest(url: URL(string: "\(apiBase)/user")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVerifying = false
                if let err = err {
                    self.lastError = L10n.t("i18n_807", err.localizedDescription)
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let login = json["login"] as? String else {
                    self.lastError = status == 401 ? L10n.t("i18n_821")
                        : L10n.t("i18n_822", status)
                    completion(false, self.lastError)
                    return
                }
                let name = json["name"] as? String
                let avatar = json["avatar_url"] as? String
                let acct = GitHubAccount(login: login, name: name, avatarURL: avatar, token: token)
                // v2.9.117：全新账号授权OK后，若 Owner 仍是内置默认值 → 自动填入当前登录账号
                let isDefaultOwner = (self.repoOwner == "zrrt" || self.repoOwner == "origina47487lhe-droid")
                if isDefaultOwner && self.repoOwner != login {
                    self.repoOwner = login
                    self.persist()
                }
                if let idx = self.accounts.firstIndex(where: { $0.login == login }) {
                    self.accounts[idx] = acct
                } else {
                    self.accounts.append(acct)
                }
                self.activeLogin = login
                NetworkLog.shared.log(L10n.t("i18n_823", login, status))
                self.persist()
                self.runDiagnostics()   // v7.1.292：PAT 登录成功同样自动诊断
                completion(true, login)
            }
        }.resume()
    }

    func switchTo(_ login: String) {
        guard accounts.contains(where: { $0.login == login }) else { return }
        activeLogin = login
        persist()
    }

    func remove(_ login: String) {
        accounts.removeAll { $0.login == login }
        if activeLogin == login {
            activeLogin = accounts.first?.login
        }
        persist()
    }

    /// 手动触发持久化 (仓库设置页保存按钮）
    func persistNow() {
        persist()
    }

    // MARK: - 线上编译 (触发 GitHub Actions）

    func triggerBuild(tweak: String, completion: @escaping (Bool, String?) -> Void) {
        guard let token = activeToken else {
            lastError = L10n.t("i18n_824")
            completion(false, lastError)
            return
        }
        guard !tweak.isEmpty else {
            lastError = L10n.t("i18n_825")
            completion(false, lastError)
            return
        }
        isTriggering = true
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/workflows/\(workflowId)/dispatches")!, timeoutInterval: 60)
        setHTTPMethod("POST", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "ref": branch,
            "inputs": ["tweak": tweak]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTriggering = false
                if let err = err {
                    self.lastError = L10n.t("i18n_807", err.localizedDescription)
                    completion(false, self.lastError)
                    return
                }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 204 {
                    NetworkLog.shared.log("Triggered online build \(self.repoOwner)/\(self.repoName) tweak=\(tweak) (HTTP 204)")
                    self.fetchRuns { _ in }
                    completion(true, L10n.t("i18n_827", tweak))
                } else if status == 404 {
                    self.lastError = L10n.t("i18n_828", self.workflowId)
                    completion(false, self.lastError)
                } else if status == 401 {
                    self.lastError = L10n.t("i18n_829")
                    completion(false, self.lastError)
                } else {
                    self.lastError = L10n.t("i18n_830", status)
                    completion(false, self.lastError)
                }
            }
        }.resume()
    }

    func fetchRuns(completion: ((Bool) -> Void)? = nil) {
        guard let token = activeToken else { completion?(false); return }
        var req = URLRequest(url: URL(string: "\(apiBase)/repos/\(repoOwner)/\(repoName)/actions/runs?per_page=10&event=workflow_dispatch")!, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self = self else { completion?(false); return }
                if err != nil || data == nil { completion?(false); return }
                guard let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any],
                      let arr = json["workflow_runs"] as? [[String: Any]] else {
                    completion?(false)
                    return
                }
                self.runs = arr.compactMap { d in
                    guard let id = d["id"] as? Int else { return nil }
                    return GitHubRun(
                        id: id,
                        status: d["status"] as? String ?? "unknown",
                        conclusion: d["conclusion"] as? String,
                        createdAt: d["created_at"] as? String ?? "",
                        headBranch: d["head_branch"] as? String ?? "",
                        displayTitle: d["display_title"] as? String ?? "run"
                    )
                }
                completion?(true)
            }
        }.resume()
    }

    // MARK: - v7.1.292：编译就绪度自动诊断（程序自动判断，非 AI 判断）
    // 登录成功后自动跑 4 项：token/2FA、邮箱验证、仓库可写、Actions 可用。结果写入 checks，UI 自动展示。

    private func ghGet(_ path: String, token: String,
                       completion: @escaping (Int, [String: Any]?, Data?) -> Void) {
        guard let url = URL(string: "\(apiBase)\(path)") else { completion(0, nil, nil); return }
        var req = URLRequest(url: url, timeoutInterval: 25)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion(code, json, data)
        }.resume()
    }

    /// 自动诊断：token/2FA + 邮箱 + 仓库权限 + Actions，全并行，结果固定顺序写入 checks
    func runDiagnostics() {
        guard let token = activeToken else {
            checks = [GHCheck(id: "login", ok: false, label: "未登录 GitHub", detail: "",
                              hint: "Settings → GitHub 账号 → 登录 GitHub（Device Flow 输码即可）")]
            allReady = false
            checksReady = true
            return
        }
        checksReady = false
        let owner = repoOwner
        let repo = repoName
        let workflow = workflowId
        let group = DispatchGroup()
        var result: [GHCheck] = []
        let lock = NSLock()

        group.enter()
        ghGet("/user", token: token) { code, json, _ in
            if code == 200, let u = json {
                let twofa = u["two_factor_authentication"] as? Bool ?? false
                lock.lock(); result.append(GHCheck(id: "token", ok: true,
                    label: "Token 有效 · \(u["login"] as? String ?? "")",
                    detail: twofa ? "2FA 已开" : "2FA 未开", hint: "")); lock.unlock()
                lock.lock(); result.append(GHCheck(id: "2fa", ok: twofa, label: "2FA",
                    detail: twofa ? "已开启" : "未开启",
                    hint: twofa ? "" : "网页 GitHub → Settings → Password and authentication → 开启 2FA")); lock.unlock()
            } else if code == 401 {
                lock.lock(); result.append(GHCheck(id: "token", ok: false, label: "Token 无效/过期",
                    detail: "", hint: "Settings → GitHub 账号 → 重新登录")); lock.unlock()
            } else {
                lock.lock(); result.append(GHCheck(id: "token", ok: false, label: "Token 校验失败 (HTTP \(code))",
                    detail: "", hint: "检查网络后重试")); lock.unlock()
            }
            group.leave()
        }

        group.enter()
        ghGet("/user/emails", token: token) { code, _, data in
            if code == 200, let d = data,
               let emails = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                let primary = emails.first { ($0["primary"] as? Bool) == true }
                let verified = primary?["verified"] as? Bool ?? false
                lock.lock(); result.append(GHCheck(id: "email", ok: verified, label: "邮箱已验证",
                    detail: primary?["email"] as? String ?? "",
                    hint: verified ? "" : "去邮箱点 GitHub 发的验证链接（新账号必须）")); lock.unlock()
            } else if code == 403 {
                lock.lock(); result.append(GHCheck(id: "email", ok: false, label: "邮箱状态不可读",
                    detail: "token 缺 user:email scope",
                    hint: "重新 Device Flow 登录（已自动带 user:email）")); lock.unlock()
            } else {
                lock.lock(); result.append(GHCheck(id: "email", ok: false, label: "邮箱读取失败 (HTTP \(code))",
                    detail: "", hint: "检查网络后重试")); lock.unlock()
            }
            group.leave()
        }

        group.enter()
        ghGet("/repos/\(owner)/\(repo)", token: token) { code, json, _ in
            if code == 200, let r = json {
                let push = (r["permissions"] as? [String: Any] ?? [:])["push"] as? Bool ?? false
                lock.lock(); result.append(GHCheck(id: "repo", ok: push, label: "仓库 \(owner)/\(repo) 可写",
                    detail: "push=\(push)",
                    hint: push ? "" : "把账号加为该仓库协作者，或 fork 后在设置页改 repoOwner/repoName")); lock.unlock()
            } else {
                lock.lock(); result.append(GHCheck(id: "repo", ok: false, label: "仓库访问失败 (HTTP \(code))",
                    detail: code == 404 ? "仓库不存在或无权限" : "",
                    hint: code == 404 ? "核对 repoOwner/repoName，或联系仓库主人加协作者" : "检查网络后重试")); lock.unlock()
            }
            group.leave()
        }

        group.enter()
        ghGet("/repos/\(owner)/\(repo)/actions/workflows", token: token) { code, json, _ in
            if code == 200 {
                let has = (json?["workflows"] as? [[String: Any]])?.contains { ($0["path"] as? String) == workflow } ?? false
                lock.lock(); result.append(GHCheck(id: "actions", ok: true, label: "Actions 可用",
                    detail: has ? "workflow \(workflow) 存在" : "workflow \(workflow) 未找到",
                    hint: has ? "" : "仓库 .github/workflows 下应存在 \(workflow)")); lock.unlock()
            } else if code == 403 {
                lock.lock(); result.append(GHCheck(id: "actions", ok: false, label: "Actions 未启用或无权限",
                    detail: "HTTP 403",
                    hint: "仓库 Settings → Actions → General → 选择 Allow 并保存")); lock.unlock()
            } else {
                lock.lock(); result.append(GHCheck(id: "actions", ok: false, label: "Actions 状态读取失败 (HTTP \(code))",
                    detail: "", hint: "检查网络后重试")); lock.unlock()
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let order = ["token", "2fa", "email", "repo", "actions"]
            self.checks = order.compactMap { key in result.first { $0.id == key } }
            self.allReady = self.checks.allSatisfy { $0.ok }
            self.checksReady = true
        }
    }
}
