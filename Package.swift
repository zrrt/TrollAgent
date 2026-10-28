// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollAgent",
    // v2.9.250: 部署目标 16→15 治本——按16编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS15.6 dyld 启动崩;15 避开 iOS16+ API 且保留全部 iOS15 API(safeAreaInset 等),降14过度会报 iOS15 API 编译错误
    platforms: [.iOS(.v15)],
    dependencies: [
        // v2.9.370：RSKGrowingTextView——成熟开源聊天输入框，自动高度+占位符，替代手写 UIViewRepresentable
        .package(url: "https://github.com/ruslanskorb/RSKGrowingTextView.git", from: "7.0.0"),
        // v3.0.37：ZIPFoundation——iSH rootfs 首次启动解压（OpenMinis 同款）
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        // v3.0.37：iSH-ARM64 C 包装层。头文件由 CI 的 build_ish.sh 生成到 ish-stage/include，
        // 静态库在 ish-stage/libs（CI 产物；本地构建需先跑 scripts/ish-build/*.sh 生成）
        .target(
            name: "TrollRuntime",
            path: "CISH",   // v6.6.0-fix27: fix18 改名漏改 path——目录实际叫 CISH
            cSettings: [
                // 头文件由 CI 复制到 CISH/include/（build_ish.sh 产物 ish-stage/include/ish）——target 名 TrollRuntime（iSH 血统引擎）
                // 双根：wrapper.c 用 "ish/..."，iSH 源码内部用 "fs/.../kernel/.../misc.h" 等
                .headerSearchPath("include"),
                .headerSearchPath("include/ish"),
                .define("GUEST_ARM64", to: "1"),
                .define("ISH_INTERNAL", to: "1")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "ish-stage/libs"]),
                .linkedLibrary("ish"),
                .linkedLibrary("ish_emu"),
                .linkedLibrary("fakefs"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z")
            ]
        ),
        // v3.3.0：MITM 内核 C 桥接层（OpenSSL）。依赖 scripts/build-openssl.sh 产出的 openssl-stage/
        .target(
            name: "CMitm",
            path: "CMitm",
            cSettings: [
                .headerSearchPath("../openssl-stage/include")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "openssl-stage/lib"]),
                .linkedLibrary("ssl"),
                .linkedLibrary("crypto")
            ]
        ),
        // v3.3.0：MITM 代理内核（主 App 本地代理模式 + VpnTunnel appex 共用）
        .target(
            name: "MitmCore",
            dependencies: ["CMitm"],
            path: "Sources/MitmCore"
        ),
        // v6.0.4：桌面悬浮 HUD 提权 spawn C 层。persona 99 提权放 C（posix_spawnattr_t 在 C 是 void*，
        // 无 Swift 类型混乱）。Swift 主 App import CLaunch 调 troll_launch_hud()。
        .target(
            name: "CLaunch",
            path: "CLaunch",
            publicHeadersPath: ".",
            linkerSettings: [
                // 14db: objc runtime（LSApplicationWorkspace 私有类）
                .linkedLibrary("objc")
            ]
        ),
        // v6.6.0: CELF（emu.c+elf-runner）退役——被 rcarmo Asbestos 统一环境取代（GOALS P5）。
        //   历史参考 git log（14c8 引入）；文件保留于 git 历史。
        // fix3cy16 (P1)：CHev——hev-socks5-tunnel 桥接层（iOS 真机 slice 手动链接，
        //   避开 SwiftPM binaryTarget 平台选择问题）。依赖 scripts/build-ipa.sh 下载解压的
        //   hev-stage/lib/libhev-socks5-tunnel.a（ios-arm64 slice，Tun2SocksKit 5.16.0 release）
        .target(
            name: "CHev",
            path: "CHev",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", "hev-stage/lib"]),
                .linkedLibrary("hev-socks5-tunnel")
            ]
        ),
        // v3.3.0：VPN 抓包模式 appex（PacketTunnelProvider，P1 hev 转发内核）
        .executableTarget(
            name: "VpnTunnel",
            dependencies: ["MitmCore", "CMitm", "CHev"],
            path: "Sources/VpnTunnel",
            linkerSettings: [
                .linkedFramework("NetworkExtension")
            ]
        ),
        .executableTarget(
            name: "TrollAgent",
            dependencies: [
                .product(name: "RSKGrowingTextView", package: "RSKGrowingTextView"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "TrollRuntime",
                "MitmCore",
                "CMitm",
                "CLaunch"   // v6.6.0: 移除 CELF（退役）
            ],
            path: "Sources/TrollMCP2",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedLibrary("z"),
                // v7.4.0-sessionstore：SQLite3 系统库（SessionStore 双层持久化——JSONL 真源 + SQLite 索引）
                .linkedLibrary("sqlite3"),
                .linkedFramework("NetworkExtension"),
                // v6.6.0: CoreServices 保留（LSApplicationWorkspace 等 LaunchServices 调用——HUD/App 管理用）
                .linkedFramework("CoreServices"),
                // v4.5.2：桌面悬浮 HUD 单可执行双模式（TrollSpeed 正解）——链接 libHUD.a
                //（HUD/sources 编出的 ObjC++ 悬浮核心）+ 私有 framework tbd（HUD/libraries）。
                // build-ipa.sh 在 swift build 前先编 libHUD.a → hud-stage/lib/libHUD.a。
                .unsafeFlags([
                    "-L", "hud-stage/lib", "-lHUD",
                    "-F", "HUD/libraries",
                    // v4.5.3：私有 framework 全部 weak 链接（-Xlinker 透传，swiftc 不认 -weak_framework）——
                    // 正常 App 启动时即使 dyld 加载这些 framework 受限也不致崩溃；HUD 只在 -hud 分支真正调用。
                    "-Xlinker", "-weak_framework", "-Xlinker", "BackBoardServices",
                    "-Xlinker", "-weak_framework", "-Xlinker", "GraphicsServices",
                    "-Xlinker", "-weak_framework", "-Xlinker", "SpringBoardServices",
                    "-Xlinker", "-weak_framework", "-Xlinker", "AssertionServices",
                    "-Xlinker", "-weak_framework", "-Xlinker", "IOKit",
                    "-lc++",
                ])
            ]
        ),
        // v7.2.3-fix9：回归测试基线（病灶⑥）——纯逻辑单测：Markdown 解析/
        // 引用提取/并行安全判定。CI 以 `swift build --build-tests` 编译验证
        // （运行需 iOS destination，编译绿即进入回归基线）。
        .testTarget(
            name: "TrollAgentTests",
            dependencies: ["TrollAgent"]
        ),
    ]
)
