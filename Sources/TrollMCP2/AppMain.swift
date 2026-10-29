import UIKit
import SwiftUI

// 桌面悬浮 HUD 单可执行双模式（TrollSpeed 正解）：主 App 可执行（TrollStore 有效签名）
// 由 HUDManager 以 root persona 拉起，argv 带 -hud 进悬浮模式；-exit/-check 关闭/查存活。
// 符号由 libHUD.a 提供（HUD/sources 编出的 ObjC++ 悬浮核心，HUDApp.mm extern "C" 导出）。
@_silgen_name("HUDMainStart") func HUDMainStart()
@_silgen_name("HUDExit") func HUDExit()
@_silgen_name("HUDCheck") func HUDCheck() -> Int32
// v7.0.4: 自动启用 JIT——wrapper.c 的 ptrace 自开（免闪切）；失败时 fallback apple-magnifier URL
@_silgen_name("troll_self_enable_jit") func troll_self_enable_jit() -> Int32
@_silgen_name("troll_jit_probe") func troll_jit_probe() -> Int32
// v6.6.0: troll_request_jit/have_jit 已删（CELF/elf-runner 退役——统一环境 Asbestos 无 JIT）

@main
struct TrollAgentApp {
    static func main() {
        let args = CommandLine.arguments
        fputs("[appmain] entry args=\(args)\n", stderr)
        if args.contains("-hud") {
            HUDMainStart()        // 进悬浮模式（内部 runloop，不返回）
        } else if args.contains("-exit") {
            HUDExit()             // 关闭悬浮（读 pid 杀）
        } else if args.contains("-check") {
            exit(HUDCheck())      // 查悬浮存活（EXIT_FAILURE=存活 / EXIT_SUCCESS=未跑）
        } else {
            // v6.6.0: 移除 --elf-runner 分支（CELF 退役——统一环境由 TrollRuntime/Asbestos 提供）
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(AppDelegate.self)
            )
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // v6.1.5-14n：键盘状态落盘（HUD 独立进程轮询）
    static func writeKeyboardState(_ visible: Bool) {
        do {
            try (visible ? "1" : "0").write(to: URL(fileURLWithPath: "/var/mobile/Documents/keyboard_state.json"),
                                            atomically: true, encoding: .utf8)
        } catch {}
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // v7.4.0-fix73e：崩溃捕获先于一切安装——TrollStore 侧载无系统诊断，
        // 崩溃现场写 Documents/crash.log（复现后直接取日志定位）
        CrashReporter.install()

        // v2.9.368：全局 UITextView 零内边距——TextEditor 默认有 8pt 上下内边距，
        // 导致输入框高度过大；全局清零后 TextEditor 高度紧贴文字。
        UITextView.appearance().textContainerInset = .zero

        // v7.4.0-fix71：导航栏滚动边缘固定不透明——修复 AI 发消息/执行命令自动滚动时
        // 列表处于顶部边缘 → iOS 15 默认 scrollEdgeAppearance 透明导致导航栏闪变透明
        // v7.4.0-fix73d：configureWithOpaqueBackground 默认带底部 hairline shadow（深色模式=黑线）——
        // 用户反馈聊天框顶部栏多一条黑线 → 显式清 shadow（导航栏更干净，全局统一）
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.shadowColor = .clear
            appearance.shadowImage = UIImage()
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }

        // v7.0.4.5: 自举 root helper 开 JIT（照抄 TrollStore RootHelper/jit.m——PT_ATTACHEXC+100ms+PT_DETACH）。
        // jit_helper 是独立 root 进程（spawnRoot persona uid 0），外部 attach 主进程 = 有效（区别于 self-attach）。
        // 成功（rc=0，等价 TrollStore 手动开 JIT）→ 不调 URL（零闪切）；失败 → TrollStore URL 兜底。
        // probe（mmap MAP_JIT）实测不可靠（mmap 成功≠执行放行）已废弃。
        let pidStr = String(ProcessInfo.processInfo.processIdentifier)
        if let helperPath = Bundle.main.url(forResource: "jit_helper", withExtension: nil, subdirectory: "bin")?.path {
            logJIT("[JIT] helperPath=\(helperPath) pid=\(pidStr)\n")
            let spawnResult = InjectionManager.shared.spawnRootDetailed(helperPath, args: [pidStr], timeout: 10)
            logJIT("[JIT] jit_helper rc=\(spawnResult.code) timedOut=\(spawnResult.timedOut) signaled=\(spawnResult.signaled) stderr=\(spawnResult.stderr.prefix(200))\n")
            if spawnResult.code == 0 {
                ("[appmain] JIT helper rc=0; still scheduling URL as double-insurance (rc=0 ≠ kernel released JIT, proven by v7.0.4.5 SIGBUS)\n" as NSString).utf8String.map { fputs($0, stderr) }
            } else {
                ("[appmain] jit_helper rc=\(spawnResult.code) — falling back to TrollStore URL\n" as NSString).utf8String.map { fputs($0, stderr) }
            }
            // v7.0.4.7: 无论 helper rc 都无条件调 URL（v7.0.4.5 实测 rc=0 但 JIT 未生效 → SIGBUS；URL 是 v7.0.3 验证的可靠路径）
            scheduleTrollStoreJITURL()
        } else {
            logJIT("[JIT] WARN jit_helper not found in bundle\n")
            fputs("[appmain] WARN: jit_helper not found in bundle — falling back to TrollStore URL\n", stderr)
            scheduleTrollStoreJITURL()
        }

        CrashCatcher.install()  // v2.9.145c：最先注册崩溃捕获，闪退自动落盘 crash/ 可查
        Workspace.ensure()
        Workspace.ensureBundledTweaks()  // v2.9.62：把内置 dylib（MemoryTweak 等）复制到工作区，AI 可直接 artifact.find 定位
        ConfigMigration.migrateIfNeeded()  // v2.9.126：配置 schema 迁移（防模块脱节：升级后旧配置结构自动搬运）
        // v7.1.51：强制初始化 ModelStore——static let 是懒加载，用户只开关于页不碰聊天/模型页时
        // load() 永不执行 → 共享配置文件不写 → HUD 读 sharedFile=NO 401 无回复（17:21 实测根因）
        _ = ModelStore.shared
        ToolRegistry.shared.registerBuiltinTools()
        // v7.1.75：注册 MCP 入口工具（user.mcp_list / user.mcp_call，AI 调用时动态发现工具）
        MCPClientManager.shared.registerEntryTools()
        // v7.1.75：启动后台连接已启用的 MCP 服务器（缓存工具清单，AI 开箱即用）
        DispatchQueue.global(qos: .userInitiated).async {
            let mcp = MCPClientManager.shared
            for i in 0..<mcp.servers.count where mcp.servers[i].enabled {
                var cfg = mcp.servers[i]
                _ = mcp.refreshServer(&cfg)
                mcp.servers[i] = cfg
            }
        }
        // v2.9.145：启动探测移到后台——DeviceProbe.run() 含 spawnRoot/文件遍历，
        // 主线程同步跑会卡死启动被看门狗杀（表现为"装完打开就闪退"）
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DeviceProbe.shared.run()
        }
        LocationProvider.shared.start()
        // v2.9.10：网络与生命周期监控（切后台重连 / 网络恢复提示）
        AppLifecycleMonitor.shared.start()
        // fix3cy8：启动即清理残留 VPN 配置（上次异常退出/旧版关 VPN 没删配置 → 残留隧道路由
        // 会把局域网 8790 黑洞；启动时后台查一次，存在残留即删，保证远程通道可靠）
        DispatchQueue.global(qos: .utility).async {
            VpnManager.cleanupStaleConfig()
        }
        // v6.0.x：可爱助手开启则启动自动拉起桌面悬浮 HUD。
        // 直接读 UserDefaults（不经 GirlCompanion.shared 时序），延迟 2s 确保 UI/进程就绪再拉起。
        // v6.1.5-5：覆盖安装后旧 HUD 进程仍在跑（launchd KeepAlive 不换新二进制），
        // 启动先做版本同步：检测到二进制更新则强制重启换新
        HUDManager.shared.syncAfterUpdate()
        let girlEnabled = UserDefaults.standard.bool(forKey: "trollmcp2.girl_companion_enabled")
        if girlEnabled {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                _ = HUDManager.shared.start()
            }
        }
        // v4.3.39：启动静默检查更新——后台跑，不打扰；发现新版点亮设置页"检查更新"红点
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
            UpdateManager.shared.checkForUpdate(currentVersion: ver)
        }
        // v2.9.66：启动时上报设备信息到统计后台（安装量/机型分布，需在设置中开启并配置服务器地址）
        DeviceReporter.shared.reportIfNeeded()
        // v2.9.180：远程诊断——启动即开始轮询云端指令；上报安装信息 + 上次崩溃未上报的日志。
        // 只读白名单执行，无危险操作；配置在 设置 → 远程诊断。
        RemoteAgent.shared.start()
        RemoteAgent.shared.reportInstallIfNeeded()
        RemoteAgent.shared.reportPendingCrashes()

        // 14de: 去掉启动自动 JIT 请求（App 切后台被杀→回前台重启→重复闪切 TrollStore 烦人）。
        // v6.6.0: elf-runner 退役后无 JIT 需求（统一环境 Asbestos 纯解释），此路径保留仅作诊断。

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIHostingController(rootView: RootView())
        window?.makeKeyAndVisible()
        // v6.1.5-14n：键盘弹出/收起 → 写全局文件 /var/mobile/Documents/keyboard_state.json
        // （HUD 是独立进程收不到键盘通知，由主 App 监听并落盘，HUD 轮询读取——键盘弹起时隐藏桌宠）
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            Self.writeKeyboardState(true)
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            Self.writeKeyboardState(false)
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
            Self.writeKeyboardState(true)
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            Self.writeKeyboardState(false)
        }

        // v2.9.136：全局后台常驻开关（设置页「后台常驻」）——开启后 App 启动即启动静音保活引擎，
        // 与远程控制的临时保活互补，长任务/后台等待 AI 结果时不挂起。
        if UserDefaults.standard.bool(forKey: "trollagent.keepalive_global") {
            BackgroundKeepAlive.shared.start()
        }
        // v2.9.136：BGTask 周期唤醒（双保险，系统调度允许时后台刷新）
        BackgroundKeepAlive.registerBGTask()

        return true
    }

    // v7.0.4.5: TrollStore URL 兜底（jit_helper 失败时）——外部 root attach，已验证可靠路径
    private func scheduleTrollStoreJITURL() {
        logJIT("[scheduleTrollStoreJITURL] entering\n")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            let bid = Bundle.main.bundleIdentifier ?? "com.trollagent.app"
            if let url = URL(string: "apple-magnifier://enable-jit?bundle-id=\(bid)"),
               UIApplication.shared.canOpenURL(url) {
                self.logJIT("[scheduleTrollStoreJITURL] canOpenURL=true, opening \(url.absoluteString)\n")
                fputs("[appmain] opening TrollStore JIT URL (fallback)\n", stderr)
                UIApplication.shared.open(url)
                Thread.sleep(forTimeInterval: 2.5)  // 等 TrollStore RootHelper 完成 attach（JIT 授权持续进程生命周期）
                self.logJIT("[scheduleTrollStoreJITURL] after 2.5s sleep (URL opened)\n")
            } else {
                self.logJIT("[scheduleTrollStoreJITURL] WARN canOpenURL=false (no TrollStore? bid=\(bid))\n")
                fputs("[appmain] WARN: TrollStore URL unavailable (no TrollStore?)\n", stderr)
            }
        }
    }

    // v7.0.4.5: JIT 诊断日志落盘（Documents/jit_log.txt）——确认走了哪条路（helper/URL），远程 /api/file 可拉
    private func logJIT(_ msg: String) {
        let path = NSHomeDirectory() + "/Documents/jit_log.txt"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(msg.data(using: .utf8) ?? Data())
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: msg.data(using: .utf8), attributes: nil)
        }
    }

    // v2.9.10：进后台时申请后台任务，让正在进行的请求有保活窗口（最多 3 分钟）
    func applicationDidEnterBackground(_ application: UIApplication) {
        // v7.4.0-fix73c：后台代传**绑到窗口耗尽时刻**（不是 3 秒延迟）——
        // iOS 事实：beginBackgroundTask 窗口内普通 URLSession 继续正常传输（Apple Forums 确认：
        // app remains running until you complete the request or run out of background time）。
        // 因此原请求在窗口内（最长 180s）一直活着，过早 cancel = 杀活请求、白白重发。
        // 正确时机：窗口耗尽（expirationHandler）→ 系统即将冻结 → 此刻原请求必死 → 代传保住。
        // 窗口内完成/回前台 → 零浪费；系统内存强杀（Jetsam）→ handler 不触发 → fix72 前台兜底。
        backgroundTask = application.beginBackgroundTask(withName: "trollmcp2.network") {
            // 窗口耗尽前一刻（系统在主线程同步调用，短暂阻止暂停）→ 轻量代传
            ConversationStore.shared.handoffActiveRequestToBackground()
            // v7.4.0-fix73d：子代理请求不在主会话 currentClient 管辖内（独立 OpenAIClient），
            // 代传覆盖不到——标记"后台挂起"，失败回调判 interrupted（可重派发）而非误报 failed
            SubAgentManager.shared.suspendAllForBackground()
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            if self.backgroundTask != .invalid {
                application.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        // v2.9.136：切后台提交 BGTask 周期刷新（系统调度窗口内保持存活）
        BackgroundKeepAlive.scheduleRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        BackgroundKeepAlive.cancelRefresh()
        // v7.4.0-fix73：收取后台代传结果（完整回复/工具调用继续执行）
        ConversationStore.shared.consumeBackgroundResult()
        // v6.1.5-5：回前台先做 HUD 版本同步（覆盖安装后自动换新 HUD 进程）
        HUDManager.shared.syncAfterUpdate()
        // v6.0.7：锁屏久了 HUD 进程可能被系统清理；回前台自动检查，若可爱助手开着但悬浮没跑则拉起
        if GirlCompanion.shared.enabled && !HUDManager.shared.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                _ = HUDManager.shared.start()
            }
        }
    }

    // MARK: v2.9.126 —— 深链导入模型 API 配置（对齐 cc-switch DeepLinkImportDialog）
    // 链接格式: trollagent://import?baseURL=...&apiKey=...&model=...&name=...&auth=Bearer&group=默认
    // 解析后存 pendingImport 并发通知，由 SwiftUI 层弹确认页（防误导入）
    /// v7.4.0-fix73：background session 全部任务结束的系统回调——必须实现并保存 completionHandler，
    /// 否则后台代传结果不会回调（App 挂起期间由系统代传，完成后唤醒执行）
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundLLM.shared.onAllTasksFinished = completionHandler
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {        guard url.scheme?.lowercased() == "trollagent" else { return false }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return false }

        func value(_ k: String) -> String? {
            items.first { $0.name == k }?.value?.removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let path = comps.host ?? ""
        // v6.1.5-14b：HUD 快捷菜单——AI 聊天（主界面即聊天，唤起即达）
        if path == "chat" {
            return true
        }
        // v6.1.5-14b：HUD 快捷菜单——主 App 代开目标 app（HUD 权限失效时的可靠兜底）
        // 链接格式: trollagent://open?bid=<bundleId>&url=<scheme>
        if path == "open" {
            let bid = value("bid") ?? ""
            let urlStr = value("url") ?? ""
            if !bid.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    _ = ProcessHelper.launchApp(bundleId: bid)
                }
                return true
            }
            if !urlStr.isEmpty, let u = URL(string: urlStr) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    _ = UIThreadBridge.openURL(u, timeout: 3)
                }
                return true
            }
            return false
        }
        if path == "import" {
            let baseURL = value("baseURL") ?? ""
            let apiKey = value("apiKey") ?? ""
            let model = value("model") ?? ""
            guard !baseURL.isEmpty, !model.isEmpty else { return false }
            let name = value("name") ?? model
            let auth = value("auth") ?? "Bearer"
            let group = value("group") ?? "default"
            let temp = value("temperature").flatMap(Double.init) ?? 0.7
            let maxTokens = value("maxTokens").flatMap(Int.init) ?? 2048
            let context = value("contextTokens").flatMap(Int.init) ?? 16000
            let protocolName = value("protocol") ?? "OpenAI Chat Completions"

            let config = ModelConfig(
                id: UUID(),
                name: name,
                provider: value("provider") ?? "custom",
                apiProtocol: protocolName,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                authMethod: auth.isEmpty ? "Bearer" : auth,
                isDefault: false,
                temperature: temp,
                maxTokens: maxTokens,
                compatLevel: 0,
                contextTokens: context,
                group: group.isEmpty ? "default" : group
            )
            PendingImport.shared.stage(config)
            return true
        }
        return false
    }
}
