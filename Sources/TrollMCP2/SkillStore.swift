import Foundation

// MARK: - 技能存储 (v2.9.17）
// 让技能从"只显示在列表里的摆设"变成"AI 可发现、可读取、可启用"的真实能力。
// 存储位置：KnowledgeBase/skills.json
// 启用状态：UserDefaults "trollmcp2.skills_enabled"

struct SkillItem: Identifiable, Equatable {
    var id = UUID()
    let name: String
    let summary: String      // summary: what the AI uses to decide when to use this skill
    let instruction: String  // 完整指令：AI 按此执行

    var dict: [String: String] { ["name": name, "summary": summary, "instruction": instruction] }

    init(name: String, summary: String, instruction: String) {
        self.name = name
        self.summary = summary
        self.instruction = instruction
    }

    init(dict: [String: String]) {
        self.name = dict["name"] ?? ""
        self.summary = dict["summary"] ?? ""
        self.instruction = dict["instruction"] ?? ""
    }
}

final class SkillStore {
    static let shared = SkillStore()
    private init() {
        seedIfEmpty()
        mergeBuiltins()
    }

    /// 内置技能版本：升级内置技能时递增，触发对已存在 skills.json 的合并补全
    /// v4 变更：mergeBuiltins 由"补全缺失"改为"补全+覆盖同名内置技能"，同步 v3.7.7 bind 新架构措辞
    /// v7 变更：v7.1.77 边界参考技能名 L10n.t→固定英文 "Shell & Env Boundaries"——bump 触发合并：
    ///   补新名技能 + 用 prevNames 清理旧名 "Shell & Env 边界参考"（否则设备残留旧名，
    ///   AI 按提示词新名 skills.read 找不到技能）
    private static let builtinsVersion = 8

    private var enabledKey = "trollmcp2.skills_enabled"

    private var kbURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase")
            .appendingPathComponent("skills.json")
    }

    /// 全部技能 (含未启用的）
    var all: [SkillItem] {
        guard let data = try? Data(contentsOf: kbURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return json.map { SkillItem(dict: $0) }
    }

    /// 内置技能全集（reverse-skill 风格骨架）
    static let builtinSkills: [[String: String]] = [
            [
                "name": "Translate & Polish",
                "summary": "multilingual translation and text polishing between Chinese/English etc., removing stiff translationese to fit target language habits",
                "instruction": "当用户要求翻译或润色文字时执行本技能：\n1. 先确认源语言与目标语言；\n2. 翻译时以自然、地道为目标，避免逐字直译和机翻腔；\n3. 涉及专业术语时保留原文并附注；\n4. 润色时保持原意，调整句式与用词，使其更通顺、更符合目标读者习惯。",
            ],
            [
                "name": "Code Review",
                "summary": "review code for security, performance, readability and logic correctness, output issue list",
                "instruction": "当用户提供代码片段或要求审查时执行本技能：\n1. 先识别语言与用途；\n2. 按 安全漏洞(注入/XSS/越权)、性能、可读性、边界情况 四类检查；\n3. 每个问题给出 位置、风险等级、修复建议；\n4. 最后给出总体结论与优先级排序。",
            ],
            [
                "name": "Tweak Dev Assistant",
                "summary": "Theos Tweak development full-flow guide: project structure, Makefile, packaging, GitHub Actions online build",
                "instruction": "当用户涉及 Tweak 开发时执行本技能：\n1. 工程需包含 Makefile / Tweak.x / .plist；\n2. 提示 Theos 需 submodules: recursive 克隆，GitHub Actions 用 macos-14 runner + brew install ldid；\n3. 打包用 make clean package FINALPACKAGE=1；\n4. 产物为 .deb/.dylib，可用 TrollFools 注入测试。",
            ],
            // ===== TrollAgent 逆向/取证技能（reverse-skill 风格） =====
            [
                "name": L10n.t("i18n_880"),
                "summary": "inject a dylib into an iOS app, check injection status, remove injection. Use for: enable/disable/verify tweak injection into target app. Don't use for: package inspection (use package), memory hacking (use memory). Example: user wants to inject a tweak dylib into a game.",
                "instruction": "当用户要求对 iOS App 做 dylib 注入/查看注入状态/移除注入时执行本技能：\n## 适用范围\n- 注入 .dylib 到指定 App、查询注入状态、移除注入、注入后验证\n## 工作流\n1. 先只读探测，不直接动手：inject status（或 inject list）确认目标与已注入项；app status bundle_id:<目标> 确认 App 存在\n2. 明确目标 App 的 bundle_id 与 dylib 的绝对路径（勿用占位符/相对路径）\n3. 执行注入：inject enable bundle_id:<目标> ...；参数不确定先 tool.describe name:\"inject\"\n4. 若需签名/信任处理：确认 Resources/bin/ldid 可用；bundle 内工具 shell 直接调不通时，从 App 进程或经自动 bind 处理（iOS 路径会被挂载为 /ios_* 供 Alpine 直读），不要硬跑\n5. 验证：重启目标 App（app restart bundle_id:<目标>），用 inject verify 或 inject status 检查是否生效\n## 输出要求\n- 给出注入目标 bundle_id、dylib 绝对路径、注入结果、验证证据（状态/日志）\n## 禁止事项\n- 未确认目标与 dylib 路径前禁止注入\n- 禁止覆盖原二进制；注入/替换前保留备份\n- 禁止静默跨环境手动改文件（走自动 bind 直读直写，勿手动 cp 进 Alpine /tmp）\n## 自检\n- [ ] 注入前是否只读探测了状态？ [ ] 是否用绝对路径？ [ ] 是否验证了注入结果？",
            ],
            [
                "name": L10n.t("i18n_881"),
                "summary": "capture and analyze HTTP/HTTPS traffic of a target app via MITM or local proxy. Use for: see what network requests an app makes, analyze API, headers, plaintext. Don't use for: VPN connection itself (use vpn.capture). Example: user wants to see what the app sends to its server.",
                "instruction": "当用户要求抓包/分析某 App 的网络请求时执行本技能：\n## 适用范围\n- HTTP/HTTPS 抓包、分析 API 请求/响应/明文、定位证书校验\n## 工作流\n1. 确认抓包方式：network.capture（HTTP/HTTPS 代理）或 vpn.capture（系统级 MITM 隧道；TrollStore 环境受限时会退化到本地代理，按提示走）\n2. 先看当前抓包状态（status），再启动；明确目标 App 与过滤条件\n3. 触发目标 App 的网络行为（可结合 app launch bundle_id:<目标>）\n4. 从抓包结果定位关键请求：URL/域名/header/参数/明文响应；需要证书时确认抓包证书已安装\n5. 结束抓包并导出/整理结果\n## 输出要求\n- 给出抓包方式、目标 App、捕获到的关键请求（URL/方法/参数/响应摘要）、证书/明文要点\n## 禁止事项\n- 抓包失败时不要谎称捕获成功；先看状态/日志\n- 系统未弹允许窗/隧道未连时，说明环境限制并改用本地代理，不硬撑\n## 自检\n- [ ] 是否先看了抓包状态？ [ ] 是否明确了目标 App？ [ ] 是否给出了关键请求证据？",
            ],
            [
                "name": L10n.t("i18n_882"),
                "summary": "analyze SQLite databases (alipay/wechat/etc) using the built-in db tool which auto-bridges the iOS .db into Alpine and runs sqlite3. Use for: list tables, query rows, find credentials/messages. Example: user wants to inspect a chat/transaction database.",
                "instruction": "当用户要求分析 iOS 上的 SQLite 数据库（如 alipay.db / wechat.db）时执行本技能：\n## 适用范围\n- 列表、查表结构、条件查询、统计行数、定位关键数据\n## 工作流\n1. 用 db 工具（自动 bind 直读 iOS .db 进 Alpine 跑 sqlite3）打开数据库；参数参考 db 工具说明\n2. 先列表：sqlite3 <db_path> '.tables'；再查关键表结构 schema\n3. 按需条件查询（注意 SQL 含单引号时工具已支持，不用手工转义）；统计行数确认数据完整\n4. 定位用户关心的字段/记录，给出证据（表名/行数/关键行）\n## 输出要求\n- 给出 db 绝对路径、表清单、关键表结构、查询结果与行数\n## 禁止事项\n- 禁止用原生 grep -a 对 .db 二进制做分析（不可靠）；用 db / sqlite3\n- 跨环境数据走自动 bind 直读直写（/var/mobile 等 iOS 路径会自动挂载为 /ios_*）\n## 自检\n- [ ] 是否用 db / sqlite3 而非二进制 grep？ [ ] 是否给出了表结构与行数？",
            ],
            [
                "name": L10n.t("i18n_883"),
                "summary": "inspect and unpack package files (.deb / .ipa) to see contents, control metadata, injected dylibs, bundles. Use for: what's inside a deb/ipa, extract files. Don't use for: injecting (use inject), analyzing db (use db). Example: user wants to know what a tweak deb contains.",
                "instruction": "当用户要求解剖 .deb / .ipa 包时执行本技能：\n## 适用范围\n- 查看包元数据（control/Info.plist）、列出内容、解包提取、定位注入 dylib\n## 工作流\n1. 用 package 工具检查包；参数参考 package 工具说明\n2. 先看包标识/版本/依赖/描述（control 或 Info.plist）\n3. 列出包内文件，定位关键文件：DynamicLibraries/*.dylib、Bundle/*.plist、二进制、资源\n4. 如需解包：明确输出目录，提取后核对文件大小/哈希\n## 输出要求\n- 给出包路径、元数据（标识/名称/版本/依赖/架构）、文件清单、关键文件说明\n## 禁止事项\n- 包内二进制用 package 或桥接解析，不用不可靠的原生 grep\n- 不要随意改包内容；只读分析时保持原包不变\n## 自检\n- [ ] 是否先看了包元数据？ [ ] 是否列出了文件清单？ [ ] 是否说明了关键文件用途？",
            ],
            [
                "name": L10n.t("i18n_884"),
                "summary": "access iOS files from the TrollRuntime (Alpine) unified env via the automatic bind (Alpine reads/writes iOS paths under the app WORKSPACE, /var/containers bundle, /System, or a specific app's data container via bind_app). Use for: run strings/file/nm/sqlite3/python on an iOS file, or write results back. Example: run strings on an iOS binary via Alpine.",
                "instruction": "当用户需要让 iOS 文件被 Alpine 工具链（strings/file/nm/sqlite3/python）处理时执行本技能：\n## 适用范围\n- 让 iOS 文件被 Alpine 工具直读直写（自动 bind 挂载，无 2MB 限制）、把 Alpine 处理结果写回 iOS 侧\n## 工作流\n1. Alpine 命令里引用以下 iOS 路径时系统会自动 bind 并改写：工作区 /var/mobile/Documents/Workspace → /ios_workspace、/var/containers（App Bundle）→ /ios_containers、/System → /ios_system（只读）、/var/mobile/Containers/Data/Application → /ios_appdata（只读）、/var/mobile/Containers/Shared/AppGroup → /ios_appgroups（只读），Alpine 直接读写\n2. 要读某 App 的【数据容器】（Documents/Library：内购票据、购买状态、导出文件）：调 `bind_app bundle_id:<该App>`（【只读】）→ 返回 /ios_data_<app>，然后 Alpine 命令用该路径（如 `python3 /ios_data_<app>/...`、`sqlite3 /ios_data_<app>/Documents/x.db '.tables'`）直读。bind_app 只绑该容器、只读，绝不绑自身 rootfs 与整棵 /var/mobile，无自引用污染、写不进去\n3. 要【就地修改】某 App 数据（改状态/数值/设置/票据）：调 `bind_app_write bundle_id:<该App>`（【可写】）→ 绑定前自动把该 App 的 Documents+Library 备份到工作区 backups/，改坏了可从备份还原；注意写坏该 App 数据容器→该 App 可能无法启动（仅影响目标App，不影响AI环境），改动前确认备份\n4. 也可直接用原生 iOS 工具（file inspect / fs / shell 原生模式）读数据容器\n5. 需要 Alpine 工具缺时显式 apk add 安装；DNS 已自动配置，网络即开即用\n## 禁止事项\n- /var/mobile 整棵【不】自动绑定——自身 rootfs 在 /var/mobile 内，绑定会自引用→内核污染→崩溃。读 App 数据容器走 bind_app 或原生工具，绝不直接 Alpine 引用 /var/mobile/Documents（rootfs 所在）\n- /System 只读，不要尝试在 Alpine 写系统目录；要写目标 App 容器走 bind_app_write\n## 自检\n- [ ] 读 App 数据容器是否用了 bind_app（返回 /ios_data_<app>）或原生工具？ [ ] 是否避免直接 Alpine 引用 /var/mobile/Documents？ [ ] 是否校验了结果？",
            ],
            [
                "name": L10n.t("i18n_885"),
                "summary": "modify process memory of a running app (coins, values) like GameGuardian/H5GG. Use for: change numeric values in games/apps at runtime. Don't use for: static dylib injection (use inject). Example: user wants to modify a game's coin count.",
                "instruction": "当用户要求修改运行中进程的内存值（如游戏金币/数值）时执行本技能：\n## 适用范围\n- 搜索内存数值、修改、锁定，作用于指定进程\n## 工作流\n1. 用 memory 工具操作；参数参考 tool.describe name:\"memory\"\n2. 先确认目标进程在运行（app status bundle_id:<目标> 或 memory status）\n3. 搜索当前值 → 触发数值变化 → 再次搜索缩小范围（经典 fuzzy 流程）\n4. 确认目标地址后修改/锁定；验证修改生效（回读或观察游戏内变化）\n## 输出要求\n- 给出目标进程、搜索过程、修改地址/值、验证结果\n## 禁止事项\n- 目标进程未运行时不硬搜；先启动\n- 修改前后记录原值，便于回退\n## 自检\n- [ ] 是否确认了目标进程在运行？ [ ] 是否验证了修改生效？",
            ],
            [
                "name": L10n.t("i18n_886"),
                "summary": "get device info, probe, fake/restore location, advertising ID, IDFV. Use for: device details, spoofing location, manage device state. Example: user wants to check device info or fake location.",
                "instruction": "当用户要求查看设备信息/模拟定位/设备状态时执行本技能：\n## 适用范围\n- 设备信息查询、定位模拟/还原、广告标识、设备探测\n## 工作流\n1. 用 device / location 工具；参数参考 tool.describe name:\"device\" / name:\"location\"\n2. 查询：device info（设备信息）、location get（当前定位）\n3. 需要模拟定位：先记录当前状态，再设置新位置；用完可还原\n4. 涉及广告标识/IDFV 时按工具子命令操作\n## 输出要求\n- 给出查询结果（设备/定位）或修改前后对比\n## 禁止事项\n- 模拟定位前先记录原状态，便于还原\n- 不擅自改设备全局配置，围绕用户明确要求操作\n## 自检\n- [ ] 是否记录了修改前状态？ [ ] 是否验证了修改生效？",
            ],
            [
                "name": L10n.t("i18n_887"),
                "summary": "manage apps: launch/stop/restart/status, install/uninstall, cache, dependencies, duplicate, diagnose startup/injection. Use for: control and troubleshoot a target app. Example: user wants to restart an app or check why it crashes on launch.",
                "instruction": "当用户要求启动/停止/重启/安装/诊断某个 App 时执行本技能：\n## 适用范围\n- 启动、停止、重启、状态查询、安装卸载、缓存/依赖、启动诊断\n## 工作流\n1. 用 app 工具管理；参数参考 tool.describe name:\"app\"\n2. 明确目标 App 的 bundle_id\n3. 常规操作：app launch/stop/restart/status bundle_id:<目标>\n4. 崩溃/启动失败：diagnose startup bundle_id:<目标>（或 injection）定位原因\n5. 安装/卸载走 app install/uninstall，涉及替换先备份\n## 输出要求\n- 给出目标 App、执行的操作、返回状态、诊断证据\n## 禁止事项\n- 未确认 bundle_id 前不批量误操作\n- 诊断崩溃用 diagnose，不用不可靠的二进制 grep\n## 自检\n- [ ] 是否明确了 bundle_id？ [ ] 是否验证了操作结果？",
            ],
            // v4.4.11(P0): 环境提示词瘦身——SHELL 段"实测边界知识"拆到此技能, 遇到时 skills.read 按需加载
            // v7.1.77: name 固定英文标识（不再 L10n.t）——提示词/搜索按固定名引用，避免中文界面=中文名、
            // 英文界面=英文名导致提示词引用匹配失败（技能名是内部标识，不该随 UI 语言变）
            [
                "name": "Shell & Env Boundaries",
                "summary": "Unified env (TrollRuntime) measured edge-case conclusions (query on demand): objdump/tree/git/python3 limits, nscan/llvm usage, installer/auto-bind. Use for: querying conclusions when shell tools error out or hit env boundary limits.",
                "instruction": "遇到 shell/环境边界问题先查这里(由环境提示词按需加载)：\n## 工具边界\n- tree 在统一环境（Alpine GNU tree）支持 -L/-d 等参数; 轻量列目录树也可用 find <dir> -maxdepth N\n- Mach-O 反汇编/分析用统一环境 objdump -m mach-o / llvm-objdump（Alpine apk add llvm），反汇编可用 r2 兜底\n- shell.exec 默认 limit=16000; 结果出现\"输出太长已截断\"提示时, 必须先读 <path> 完整内容再分析, 绝不基于截断片段下结论; 逆向/分析类命令建议 full=true 或 limit=50000\n## 统一环境\n- shell.exec 无 runtime 参数：全部命令默认在 TrollRuntime（Alpine 完整工具链）执行；iOS 路径自动 bind 为 /ios_* 直读直写\n- python3 在统一环境（Alpine）运行——完整 CPython + pip（apk add python3 py3-numpy 等任意装包）\n- 长任务(装包/下载/编译)默认 20s 会 SIGKILL——必须 shell.exec 显式 timeout=120, 或 background=true 后台跑+轮询+shell.stop; 被杀先查 timeout_used 是否 20\n- python3 子进程/脚本全支持（Alpine 完整 shell）\n- 装完先冒烟验证(工具名 --version 或 --help, 确认 exit 0 且有输出); exit 0 空输出=缓冲问题, 用文件重定向确认\n## git\n- 统一环境（Alpine）直接使用——rootfs 预装 git 2.x, clone/pull/push/log/status 全支持\n## 网络/安装\n- 端口扫描: nmap 已随 app 内置(native), 直接 `nmap <host>`; 网络受限时用 python3 <app>/bin/nscan.py <host> 1-1000 或 -p 22,80 <host> 兜底\n- tool.install name:<pkg> 走 apk→pip→CI; 大包(pandas/numpy等) 1-3min 属正常; 手工 apk add/pip 用 timeout=120 或 background\n- apk 自动切中国镜像+装证书; 安装失败读结构化诊断, 重试一次或说明真因, 不盲重试\n- iOS 构建工具链(Theos+clang)不可装, 用 PC 交叉编译 / GitHub Actions\n## 统一环境 bind\n- iOS↔Alpine 自动 bind: /var/mobile/Documents/Workspace→/ios_workspace, /var/containers→/ios_containers, /System→/ios_system(只读), /var/mobile/Containers/Data/Application→/ios_appdata(只读), /var/mobile/Containers/Shared/AppGroup→/ios_appgroups(只读), 共 5 个; 环境内直读, 无 2MB 限制\n- /var/mobile 整棵【不】自动绑定(自引用→内核污染→崩溃); 读 App 数据容器用 bind_app bundle_id:<id> 返回 /ios_data_<app>, 写用 bind_app_write(先自动备份)\n- auto-bind 只改命令行不改脚本内路径: sh/heredoc/python3 脚本里直接用 /ios_* 路径\n## 禁止\n- 缺工具显式 apk add, 不未确认就 which; shell.exec 无 runtime 参数, 直接调\n- 未确认命令可用前不要重复试错, 先 skills.read 本参考",
            ],
        ]

    /// 首次启动：无 skills.json 时写入内置技能，开箱即用（UI 也会调用）
    func seedIfEmpty() {
        guard !FileManager.default.fileExists(atPath: kbURL.path) else { return }
        save(Self.builtinSkills.map { SkillItem(dict: $0) })
    }

    /// 版本化合并：已存在 skills.json 时，把内置技能中缺失的补全（不删用户自定义）
    /// 并删除"曾经是内置、现在已从内置移除"的同名技能（避免废弃技能残留）
    private func mergeBuiltins() {
        let appliedVersion = UserDefaults.standard.integer(forKey: "trollmcp2.skills_builtins_version")
        guard appliedVersion < Self.builtinsVersion else { return }
        let builtinNames = Set(Self.builtinSkills.compactMap { $0["name"] })
        var list = all
        // 1) 补全缺失的内置技能 + 覆盖已存在的同名内置技能内容（版本升级时同步内置技能改动，
        //    如 v3.7.7 的 bind 新架构措辞；保留用户自定义技能不动）
        for s in Self.builtinSkills {
            guard let name = s["name"], !name.isEmpty else { continue }
            if let idx = list.firstIndex(where: { $0.name == name }) {
                list[idx] = SkillItem(dict: s)   // 覆盖内置技能内容
            } else {
                list.append(SkillItem(dict: s))
            }
        }
        // 2) 仅清理"曾被本 App 内置、现已从内置移除"的同名技能（用上次已应用版本的记录判定）
        if appliedVersion > 0 {
            let prevKey = "trollmcp2.skills_builtins_prev_names"
            let prevNames = (UserDefaults.standard.array(forKey: prevKey) as? [String]) ?? []
            let removedBuiltin = prevNames.filter { !builtinNames.contains($0) }
            if !removedBuiltin.isEmpty {
                list.removeAll { removedBuiltin.contains($0.name) }
            }
        }
        save(list)
        UserDefaults.standard.set(Array(builtinNames), forKey: "trollmcp2.skills_builtins_prev_names")
        UserDefaults.standard.set(Self.builtinsVersion, forKey: "trollmcp2.skills_builtins_version")
    }

    /// 写入全部技能 (覆盖式）
    func save(_ items: [SkillItem]) {
        try? FileManager.default.createDirectory(
            at: kbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = items.map { $0.dict }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: kbURL)
        }
        AuditLog.shared.log("skills", detail: L10n.t("i18n_889", items.count))
    }

    func upsert(_ item: SkillItem) {
        var list = all
        if let idx = list.firstIndex(where: { $0.name == item.name }) {
            list[idx] = item
        } else {
            list.append(item)
        }
        save(list)
    }

    func delete(named name: String) {
        save(all.filter { $0.name != name })
    }

    func item(named name: String) -> SkillItem? {
        all.first { $0.name == name }
    }

    /// 技能是否启用 (默认启用；仅显式禁用才关）
    func isEnabled(_ name: String) -> Bool {
        let dict = UserDefaults.standard.object(forKey: enabledKey) as? [String: Bool] ?? [:]
        if let v = dict[name] { return v }
        return true
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        var dict = UserDefaults.standard.object(forKey: enabledKey) as? [String: Bool] ?? [:]
        if enabled {
            dict.removeValue(forKey: name)
        } else {
            dict[name] = false
        }
        UserDefaults.standard.set(dict, forKey: enabledKey)
        AuditLog.shared.log("skills", detail: "\(name) \(enabled ? "启用" : "停用")")
    }
}

// MARK: - AI 技能工具 (模型可发现/读取/启用）

/// skills.list：列出已启用技能 (名称+摘要），供模型判断何时使用
final class SkillsListTool: MCPTool {
    // v2.9.42：检索式——query 按名称/摘要搜索，只返回命中项，不再全量塞技能
    let definition = ToolDefinition(
        name: "skills.list",
        summary: "Search/list available skills (pre-built prompt templates). Use for: find a skill that matches user's task, see what skills exist. Don't use for: execute a skill (use skills.read to load it), disable/enable skills (use skills.set_enabled). Example: user says 'is there a capture skill' → search '抓包' in skills.",
        parameters: ["query": "Search keyword (skill name or description, optional). e.g. 'capture' / 'inject' / 'build'"], verified: true, category: "skills")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let all = SkillStore.shared.all.filter { SkillStore.shared.isEnabled($0.name) }
        let q = (params["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items: [SkillItem]
        if q.isEmpty {
            items = Array(all.prefix(20))
        } else {
            items = all.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
            }
        }
        return [
            "total": all.count,
            "matched": items.count,
            "query": q,
            "skills": items.map { ["name": $0.name, "summary": $0.summary] },
            "hint": q.isEmpty
                ? "total \(all.count) 个技能，只返回前 20 条；请用 query 按名称/摘要搜索 (如 query=\"注入\")，需要执行时用 skills.read 读完整指令"
                : "matched \(items.count) 个；需要执行时用 skills.read 读取该技能完整指令"
        ]
    }
}

/// skills.read：读取某技能的完整指令
final class SkillsReadTool: MCPTool {
    let definition = ToolDefinition(
        name: "skills.read",
        summary: "Read the full instructions of a skill. Use for: load a skill's step-by-step guide to follow. Don't use for: search skills (use skills.list), enable/disable skills (use skills.set_enabled). Example: user says 'read the capture skill steps' → read skill.",
        parameters: ["name": "Skill name to read"], verified: true, category: "skills")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            throw MCPError.invalidParams("name required")
        }
        guard let item = SkillStore.shared.item(named: name) else {
            throw MCPError.invalidParams("skill does not exist: \(name)")
        }
        return ["name": item.name, "summary": item.summary, "instruction": item.instruction]
    }
}
