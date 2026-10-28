import Foundation

// v4.3.66 权威知识库扩展种子（第二批）
// 来源：Apple 官方文档 / OWASP MASTG / TrollStore 官方仓库与 DeepWiki / iSH 官方博客 /
//       USENIX Sec'22 论文 / iOSGods 教程 / Unity 官方文档。AI 遇相关问题先 knowledge.search 检索。

enum SeedKnowledgeData {
    static let v2Seeds: [(String, String)] = [
    ("内置-iOS逆向-MachO与签名.md", """
# Mach-O 结构与代码签名（逆向基础）

## Mach-O 布局
- 头部 magic: 64 位 0xFEEDFACF；还能看到 32 位 0xFEEDFACE、fat(多架构) 0xCAFEBABE。
- 三段：Header（魔数/CPU 架构/文件类型）→ Load Commands（加载指令数组）→ 数据（段与节）。
- 常见段：
  - __TEXT：只读可执行。__text(机器码)、__objc_methname(ObjC方法名)、__objc_classname、__cstring、__stubs。
  - __DATA / __DATA_CONST：可写/只读数据。__objc_classlist、__objc_protolist、__got、__la_symbol_ptr。
  - __LINKEDIT：签名/符号表/字符串表/链接信息。
- 关键 Load Commands：
  - LC_SEGMENT_64 段映射；LC_LOAD_DYLIB 依赖库（注入常改这里）；LC_ID_DYLIB；LC_RPATH。
  - LC_ENCRYPTION_INFO_64：FairPlay 加密信息（cryptid=1 加密，砸壳后改 0）。
  - LC_CODE_SIGNATURE：指向 __LINKEDIT 里的签名；LC_MAIN 入口。
- 查看：file、otool -L(依赖)、otool -l(全部 load commands)、nm(符号)、strings。

## 代码签名
- 所有可执行代码必须签名（除 Safari JIT 等少数特权例外）；签名嵌在 __LINKEDIT，由 LC_CODE_SIGNATURE 引用。
- CodeDirectory：对每 4KB 代码页算哈希，同时含 SHA-1 和 SHA-256 两套槽；entitlements 也在签名保护内。
- embedded.mobileprovision：证书/允许设备/entitlements/过期时间。
- 改二进制后必须重签（ldid -S 或 codesign），否则 code signature invalid / Killed: 9。
- ldid：无设备端苹果证书时用的假签名工具，可写 entitlements（ldid -Sxxx.plist）。

## PAC（A11 起的指针认证）
- arm64e 上代码/函数指针带 PAC 签名，直接改指针/内联补丁会崩溃；逆向时函数返回地址、虚表调用都经过 PAC。
- 补丁/ Hook 优先走 runtime 层（method swizzle / 跳板），避免硬改受 PAC 保护的指针。
"""),

    ("内置-iOS逆向-砸壳与注入.md", """
# 砸壳（解密）与代码注入

## 为什么先砸壳
- App Store 下载的二进制由 FairPlay 加密（cryptid=1），静态分析工具全无效。
- 砸壳 = 让系统正常解密后，从内存把明文镜像 dump 出来，再回填到文件并把 cryptid 改 0。

## 砸壳方法（按可行性）
1. 内存 dump（TrollStore 路线，本 App 内置）：App 运行时内核已解密，用 task_for_pid 拿任务端口，
   按 LC_ENCRYPTION_INFO_64 的 cryptoff/cryptsize 逐段 vm_read 明文，覆盖回文件 → ldid 重签。
   要求 task_for_pid-allow entitlement（TrollStore 开启编辑 Entitlements 后重装）。
2. 越狱设备：frida-ios-dumper / dumpdecrypted / bagbak 等，原理相同。
3. 电脑侧：需要已解密的 ipa（别人 dump 或自己在越狱机获取）。
- 校验：砸壳后 otool -l 看 cryptid=0；可正常被 inject binary_symbols 提取符号。

## 代码注入方式
- 静态注入（LC_LOAD_DYLIB）：在目标 Mach-O 增加一条 LC_LOAD_DYLIB 指向我们的 dylib，重签。
  需同步改 __LINKEDIT（扩大或用空闲空间），改前自动备份 .bak_macho，可一键 restore。
- 内存注入（opainject）：运行时用 task_for_pid + remote dlopen/线程创建，不改文件、重开即失效。
  可用 enable_persisted 配合静态注入实现持久化。
- TrollFools（ChOma 漏洞）：在非越狱/TrollStore 环境对其他 App 注入，利用签名链构造。
- 注入 dylib 必须与目标同架构/兼容 SDK；用 otool -L 检查 dylib 自身依赖。
- 失败常见：Killed: 9（签名）、Library not loaded（路径/依赖）、image not found（@rpath 不对）。
- 顺序：注入 dylib 用 @executable_path/Frameworks/ 或固定绝对路径，签名 entitlements 要匹配目标。
"""),

    ("内置-iOS逆向-Hook与运行时.md", """
# Hook 与运行时分析

## ObjC 动态特性（最好下手）
- 运行时改方法实现：method swizzling（交换 IMP）；class_replaceMethod / method_setImplementation。
- 类名/方法名明文存在 __objc_classname、__objc_methname，class-dump 可直接出完整接口。
- 关键 API：objc_msgSend、NSClassFromString、performSelector；动态解析是混淆/加壳特征。

## Hook 框架
- 越狱生态：CydiaSubstrate / Substitute / ElleKit；非越狱注入 dylib 内常用 fishhook + 自行实现。
- fishhook：符号懒绑定/非懒绑定指针（got/la_symbol）的 C 函数 Hook，Hook 不了静态内联函数。
- Frida：动态插桩（Interceptor.attach + Stalker），需 frida-server，TrollStore 侧无法常规跑。
- 本 App：inject hook_apply 对已定位方法做运行时替换；mem 做内存读写。

## Swift 目标的特殊性（比 ObjC 难）
- 符号修饰（name mangling）：$s 开头的长符号，需 xcrun swift-demangle 还原。
- 静态派发/泛型特化/内联：很多方法没有动态表，swizzle 无效，要改机器码或符号 Hook。
- 协议见证表（witness table）、值类型布局与 ObjC 不同；反射有限。
- 建议：Swift 目标优先找与 ObjC 桥接的边界（@objc 暴露的方法）下手。

## 混淆与加固识别
- ObjC 名混淆：类名/方法名变成随机串；字符串加密：明文全不见、运行时解密。
- 控制流平坦化、虚假分支、超高熵段、符号表缺失 → 静态分析难度高，结论降级。
- 反调试：ptrace(PT_DENY_ATTACH)、sysctl 反调试、检测调试端口；可 Hook 绕过。
- 完整性校验：自校验代码页哈希、检测二进制是否被改；注入点要在校验之后或同时 Hook 校验。
"""),

    ("内置-iOS系统-沙盒与权限.md", """
# iOS 沙盒、容器与 Entitlements

## App 容器结构（每个 App 独立）
- Bundle（.app，只读）：二进制、资源、embedded.mobileprovision、_CodeSignature。
- Data Container（可写，路径随机 UUID）：
  - Documents/：用户数据，iTunes/访达可备份共享。
  - Library/：Library/Preferences（NSUserDefaults plist）、Library/Caches（不备份可清）。
  - tmp/：临时文件，系统可清。
  - App 组共享：group.<id> 容器，同组 App 可读写（共享数据/数据库的常见点）。
- 沙盒机制：文件系统命名空间 + entitlements 限制，默认不能碰其他 App/系统数据。

## Entitlements（权限清单，签名保护）
- 逆向常用：
  - task_for_pid-allow：读/控其他进程（砸壳、注入的前提）。
  - get-task-allow：允许调试器附加（开发签名有，发布无）。
  - com.apple.private.security.* 、platform-application：平台级特权。
  - keychain-access-groups、com.apple.security.application-groups。
- TrollStore 侧载可带任意 entitlement（CoreTrust 绕过），这是它比普通签名强的根本原因。
- 普通免费/开发者签名带不上私有 entitlement，七天重签且无法 task_for_pid。

## TCC 隐私权限
- 通讯录/照片/定位/麦克风/相机等由 TCC 管，运行时弹窗授权，配置在 Info.plist 使用描述。
- 隐私数据访问 + 网络外发是安全审查重点组合（见 内置-插件安全-风险判定）。
- 关键服务：Keychain（SecItem，加密存储）、Contacts、Photos、CoreLocation、CTMessage（短信私有）。
"""),

    ("内置-巨魔-TrollStore原理与使用.md", """
# TrollStore（巨魔）原理与使用

## 一句话
- 非越狱的「永久签名」安装器：可装任意 IPA、带任意 entitlement、重启不失效、不七天重签。

## 核心原理：CoreTrust 绕过
- CVE-2023-41991：CoreTrust 验证的是 SHA-1 CodeDirectory，但系统执行时用 SHA-256 CodeDirectory。
- 构造「多个签名者」二进制：SHA-1 槽放一个合法 App Store 签名（通过验证），
  SHA-256 槽放自定义签名 + 任意 entitlements（实际执行用这套）→ 绕过。
- 它不是越狱：没有内核持久化，不碰系统分区，靠签名漏洞让侧载 App 永久驻留。

## 支持版本（务必核对，别对不支持版本白费功夫）
- TrollStore 1：iOS 14.0 beta 2 起，主要靠 CoreTrust 老路径。
- TrollStore 2：15.5 ~ 16.6.1、16.7 RC(20H18)、17.0；安装向量 MDC(Mac Dirty Cow) / KFD。
- 终点：Apple 在 iOS 17.0.1 和 16.7 修补该 CoreTrust 漏洞；17.6/18.0 再加一道锁。
- 17.0.1 及以后（含 18/26）原生不可用，只能用越狱或其他签名方案。

## 生态
- TrollFools：基于 ChOma 的「注入器」，对已装 App 注入 dylib（本 App 注入流程的参考）。
- 配套：安装后可开「编辑 Entitlements」、给 bin 工具打 setuid；改设置后需卸载重装才生效。
- 典型坑：Operation not permitted / task_for_pid failed → 没开编辑 Entitlements 或覆盖安装未重应用。
"""),

    ("内置-Alpine环境使用指南.md", """
# TrollRuntime Alpine Linux 统一环境

## 原理
- 在 iOS 上跑真实 Alpine Linux 用户态（Asbestos 指令解释器 + 系统调用翻译，类似 WSL1）。
- 统一环境：全部 shell 命令默认在此执行，无环境路由、无 runtime 参数。
- 高频重型工具已 native 化直跑（ARM64 原生）：python3（py3-native）、node（node-native）、nmap、sqlite3、plutil、jtool2 —— 不经过解释器，速度快。
- 无需越狱，iOS 13+；沙盒内始终是 root（权限=宿主 App 的权限）。

## 包管理（apk）
- apk update（刷新索引）；apk add <包>（安装，如 python3、git、nmap、curl、vim）。
- apk search <词>；apk del <包>；apk info 列已装。
- 缺命令时自己 apk add 对应包即可（Alpine 仓库工具齐全）。
- 文件可通过自动 bind 直接读写 iOS 目录（/ios_workspace /ios_containers /ios_system /ios_appdata /ios_appgroups）。

## 限制（合理使用）
- 解释器运行的工具性能低于原生；编译大工程、跑重活优先用 native 通道或 PC/云。
- 无内核模块/设备驱动（沙盒限制）；它是「脚本/工具运行环境」，不是越狱。
- 不能直接操作其他 App/系统底层（沙盒限制）；App 数据容器走 bind_app / bind_app_write。
- 原生速度场景：用 ARM64 native 工具（py3-native / node-native / nmap / jtool2）或 PC/云。
"""),

    ("内置-游戏破解-Unity与IL2CPP.md", """
# Unity 游戏与 IL2CPP 破解

## Unity iOS 结构
- 老版本 Mono：带托管 DLL，可直接提取/改 C# 程序集（最容易）。
- 现版本 IL2CPP：C# 被转成 C++ 再编原生码。
  - UnityFramework（主二进制，含 libil2cpp 代码）。
  - global-metadata.dat（元数据：类/方法名、签名、字符串，定位逻辑的关键）。
  - 路径多在 Data/Managed/Metadata/global-metadata.dat。

## 标准流程（验证过的通用路径）
1. 砸壳拿到解密 ipa（App Store 包是加密的，不解密什么都提不出来）。
2. 解包，提取 UnityFramework 与 global-metadata.dat。
3. 用 Il2CppDumper：输入二者 → 输出 dump.cs（全部类/方法名+RVA）、脚本头、il2cpp.h。
4. 在 dump.cs 里定位目标（金币/内购/解锁/校验方法），拿 RVA（相对 UnityFramework 基址）。
5. 两种改法：
   - 静态补丁：改 UnityFramework 对应偏移的指令（如返回值强制 true），重签。
   - 动态 Hook：注入 dylib，基址 + RVA 上 hook（onLeave 改返回），灵活可重开。

## 内购破解
- 纯客户端票据校验：hook VerifyReceipt / IsPremiumUser / IsSubscriptionActive / ProcessPurchase
  强制返回「成功/true」，或直接调用「发货」方法。
- Unity IAP：在购买回调/发货方法上模拟成功交易；Receipt Obfuscation 只是混淆密钥可被绕过。
- 边界：服务器端校验/网游（发货在服务端）无法客户端破解，只能改本地表现。
- 参考：USENIX Sec'22「Playing Without Paying」系统研究了可被绕过的支付验证。

## 数值与存档
- 存档常落在 Documents/Library/Preferences 的 plist、NSUserDefaults，可直接改金币/钻石。
- 内存数值：运行时搜改（需注意加密存档/签名校验）。
- 体力/广告/解锁：找对应时间戳或 bool 方法，hook 或改存档。
"""),

    ("内置-游戏破解-通用路径与防护.md", """
# iOS 游戏破解通用路径与反作弊应对

## 先判断引擎（决定打法）
- Unity IL2CPP（最常见）→ 见 内置-游戏破解-Unity与IL2CPP。
- Cocos2d-x：C++ 原生引擎，逻辑在主二进制，靠字符串/符号 + IDA/Ghidra 类工具定位，无 metadata。
- Mono/脚本引擎：找脚本/程序集；原生游戏：直接逆向二进制。

## 通用突破口清单（按易到难）
1. 存档文件（plist/json/sqlite/二进制）：改数值，注意存档签名/加密。
2. 本地开关 bool（去广告/已解锁/会员）：NSUserDefaults 或方法 hook。
3. 时间类（体力/签到/试玩）：改本地时间戳或 hook 时间获取。
4. 内购发货/校验：客户端校验可绕（见 Unity 篇）。
5. 游戏逻辑：金币消耗、伤害、掉落等函数 hook/补丁。

## 反作弊 / 防护与应对
- 越狱/注入检测：查 Cydia/可疑文件路径、fork、动态库、task_for_pid；
  OWASP MASTG-TECH-0152 给出绕过方法（定位检测点后 Hook 或补丁）。
- 反调试：ptrace(PT_DENY_ATTACH)、sysctl P_TRACED、计时检测；Hook 对应调用。
- 完整性/重签校验：代码页哈希、签名校验、检测修改；先找校验逻辑一并处理。
- 字符串/符号加密、逻辑混淆：动态 hook 往往比静态补丁省事。
- 联机反作弊：数据/判定在服务端，客户端改了会被回滚或封号，不在可破解范围。

## 边界与合规
- 仅限自己设备/自有测试；破解内购不等于服务端授权；网游改动有封号风险。
- 安全研究与教学用途；不用于分发盗版/牟利。
"""),

    ("内置-逆向-抓包与网络分析.md", """
# 抓包与网络流量分析

## 三条抓包路径
1. 应用内 network.capture（NetworkTweak + TLSHook）：对目标 App 注入网络 Hook，
   直接拦截 NSURLSession/原生 socket，能看到明文请求/响应，适合 pinned 连接。
2. vpn.capture：VPN 层 + 本地 mitm 代理（仍在开发/半成品，部分 App/QUIC 可能不全）。
3. WiFi 代理（电脑 Charles/mitmproxy）：同网段设代理 + 装证书；系统级但会被 pinning 挡。

## 证书绑定（SSL Pinning）与绕过
- 表现：代理抓不到/握手失败，但 App 自己能用 → 大概率 pinning。
- 类型：证书/公钥固定（NSURLSession delegate 的 didReceiveChallenge）、AFNetworking 内置。
- 绕过：Hook 证书校验（SecTrustEvaluateWithError / 挑战回调）强制信任；或走注入式 Hook 抓取。
- 绕过 pinning 后仍要在受信环境装根证书；只做自己测试。

## 协议识别
- QUIC/HTTP3（HTTP/3 over UDP/443）：普通 HTTP 代理抓不到，需支持 QUIC 的代理，或让 App 回退 HTTP/2。
- 看请求特征：Bearer token、自定义签名头（HMAC/timestamp/nonce）、加密 body（proto/JSON+AES）。
- 分析顺序：先抓明文接口 → 定位鉴权/签名方法（逆向）→ 用 knowledge/基础工具复现请求。

## 常见结论
- 外连域名/上传内容决定「是否窃取回传」；连接官方域名 + 正常 SDK 多为低危。
- 非白名单域名 + 隐私数据上传 = 高危证据（引用抓到的请求原文）。
"""),

    ("内置-逆向-环境工具选择.md", """
# 工具选择与环境边界（统一环境——无路由）

## 先判断设备/环境能做什么
- 手机端（本 App / TrollStore）：侦察、静态提取、砸壳、注入、运行时 Hook、抓包、归档。
- TrollRuntime（Alpine 用户态）：脚本、轻量命令行、apk 装工具；不能编译大工程/无内核能力。
- 电脑/云（Linux/macOS/Windows）：完整重编译、深度反编译、长时跑工具、装任意依赖。

## 深度分析该去哪
- 反编译/深度反汇编：电脑侧 Ghidra / IDA / rizin / llvm-objdump。
- 全量重签/改包：电脑侧 codesign/ldid + 完整构建链更稳。
- 手机端完成：triage + 静态提取 + 动态观察 + 风险判定 + 补丁/Hook 落地。
- 到边界时明确告诉用户「需电脑侧某工具深挖」，不要在手机上硬跑。

## 缺工具时的正确做法（重点）
- 命令行工具：先在统一环境（TrollRuntime/Alpine）用 apk add；或在电脑/云用包管理器（apt/brew/pip/npm）安装。
- 本 App 自身：tool.install 走 GitHub CI 构建/下载工具；env.setup_re 准备逆向环境。
- 装依赖只在 PC / Linux 类完整环境可行；iOS 沙盒内不能随意装系统级依赖。
- 装完即继续，不把「请你手动安装」甩给用户；确实无权限才说明。

## 结论交付习惯
- 先给结论（安全/可改/不可破），再给证据行；标注哪些是验证事实、哪些需进一步验证。
- 涉及丢失数据/改系统/高风险动作先报再做；本地可逆操作可直接做。
""")
    ]
}
