import Foundation
import ZIPFoundation
import TrollRuntime
import CommonCrypto

/// TrollRuntime 统一环境引擎（TrollAgent 版——核心 = rcarmo Asbestos，iSH 血统）
/// - boot：首次调用时把 bundle 内 alpine-rootfs.zip 解压到 Documents，再 cish_boot 挂载 fakefs
/// - exec：每次调用在 guest 内 fork 独立 /bin/sh -c，串行执行（全局锁）
/// - 超时：cish_killpg 回收 guest 进程组，靠 exit_hook 通知管道收尾
/// - 会话 cwd：命令前缀 `cd '<cwd>' &&`；纯 cd 命令额外跑 pwd 更新会话目录
enum TrollRuntimeEngine {
    enum BootState {
        case idle, booting, booted, failed(String)
    }

    private static let lock = NSLock()
    private static var state: BootState = .idle

    /// v7.0.4.2: 首次 shell.exec 前等待自动 JIT 就绪（TrollStore URL 处理完成），只等一次。
    private static var jitReadyWaitDone = false

    /// v4.0.4: 内核已根治污染——build_ish.sh 在编译期删掉 fakefs_bind_mount 写 meta.db 权限的两段
    /// （symlink+bind 表已足够映射，meta.db 写入冗余有害），bind 不再污染后续 spawn（rc=-13 消失）。
    /// 故恢复自动 bind（autoBindEnabled=true）重新启用 bind 大文件直读；autoBridge 仍作兜底处理未 bind 的 iOS 路径。
    static var autoBindEnabled = true

    /// 已成功挂载的 bind 点集合（幂等保护）。bind 成功后才加入；autoBind 只对未挂载点 bind 一次，
    /// 避免每次命令反复 bind 同一 iOS 顶层目录而污染 iSH 内核（v3.7.3 bindMountForCommand 验证过的做法）。
    private static var mountedBindPoints: Set<String> = []

    /// v4.0.0 内核自愈：连续 spawn 失败（rc=-13）达阈值时，自动重置 state→.idle 并下次重新 boot，
    /// 清除 bind mount 污染造成的损坏内核态。计数器在 boot 成功后清零。
    private static var spawnFailCount = 0
    private static let spawnFailThreshold = 3

    /// iSH 会话 cwd（guest 路径，与旧 ios_system 的 iOS 沙箱路径隔离）
    private static var guestCwd = "/root"
    /// v4.3.79：类型修正——cish_spawn 返回 long(Swift Int)=pid；cish_killpg(long,int) 导入后
    /// pid 是 Int、sig 是 Int32（C int→Swift Int32）。v4.3.78 误把 sig 也改成 Int 导致反方向报错。
    private static var currentPid: Int = -1

    /// v4.3.77：用户点停止时立即中断当前命令/安装（不再让 apkAdd 闷头跑到 timeout、
    /// 也释放串行锁让后续命令能立刻执行）。在主线程调用。
    static func interruptCurrent() {
        // 注意：此处不能用 lock——exec 正持锁阻塞，加锁即主线程死锁。
        // Int32 读写天然原子，直接读；最坏读到旧值，kill 无效 pid 无害。
        let p = currentPid
        guard p > 0 else { return }
        ShellDiag.log("user stop: interrupt pid \(p)")
        cish_killpg(p, Int32(SIGTERM))
        Thread.sleep(forTimeInterval: 0.5)
        cish_killpg(p, Int32(SIGKILL))
    }

    /// v7.1.80: shell.stop 工具——AI 主动中断后台任务（background=true 启动的 pid）。
    /// 与 interruptCurrent 不同：可杀任意 guest pid（后台 job），不依赖 currentPid。
    static func stopPid(_ pid: Int) {
        ShellDiag.log("shell.stop: pid \(pid)")
        cish_killpg(pid, Int32(SIGTERM))
        Thread.sleep(forTimeInterval: 0.5)
        cish_killpg(pid, Int32(SIGKILL))
    }

    private static var rootfsDir: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alpine-rootfs").path
    }
    private static var dataPath: String { rootfsDir + "/data" }

    static var isBooted: Bool {
        if case .booted = state { return true }
        return false
    }

    /// 当前 guest 会话目录（返回给 shell.exec 的 cwd 字段）
    static var cwd: String { guestCwd }

    /// v3.6.8: 重置会话目录到真实存在的 /root（Alpine 纯隔离，无 /workspace 桥接）
    /// v6.5.2：计算文件 MD5（rootfs bundle 版本比对用）
    private static func fileMD5(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func resetCwd() {
        lock.lock()
        defer { lock.unlock() }
        guestCwd = "/root"
    }

    // MARK: - iOS 目录 bind mount（v3.7.0）
    /// 把 iOS 真实目录挂进 Alpine。挂载点需为 "/ios_xxx" 形式。
    /// @return C 错误码（0 成功）
    static func bindMount(_ linuxPath: String, _ hostPath: String, readOnly: Bool) -> Int32 {
        guard isBooted else { return -1000 }
        return linuxPath.withCString { lp in
            hostPath.withCString { hp in
                cish_bind_mount(lp, hp, readOnly ? 1 : 0)
            }
        }
    }

    /// 卸载一个 bind mount
    @discardableResult
    static func bindUnmount(_ linuxPath: String) -> Int32 {
        guard isBooted else { return -1000 }
        return linuxPath.withCString { lp in
            cish_bind_unmount(lp)
        }
    }

    // MARK: - v4.1.0 按需选择性绑定 App 数据容器（替代整棵 /var/mobile 绑定）
    /// 把指定 App 的数据容器（LSApplicationWorkspace 私有 API 解析 dataContainerURL）
    /// 绑进 Alpine → /ios_data_<app>，让 Alpine 的 python3/sqlite3/strings 直接读该 App 的
    /// Documents / Library（内购票据、购买状态等）。
    /// 铁律：绝【不】绑自身容器（其 Documents/alpine-rootfs 是 rootfs → 自引用→内核污染崩溃），
    /// 也绝【不】绑整棵 /var/mobile。只绑目标 App 的容器路径，无自引用 → 无污染 → 不崩。
    /// 幂等：已绑过则直接返回 mount。返回 (ok, mountPath, hostPath, error)。
    /// v4.2.0: readOnly=true 分析用(安全只读); readOnly=false 就地修改用, 且【先备份】到工作区。
    static func bindAppContainer(bundleId: String, readOnly: Bool = true)
        -> (ok: Bool, mountPath: String?, hostPath: String?, backupPath: String?, error: String?) {
        guard autoBindEnabled else { return (false, nil, nil, nil, "autoBind disabled") }
        guard let app = AppCatalog.list().first(where: { $0.bundleId == bundleId }),
              let cp = AppCatalog.lookupContainer(bundleId: app.bundleId), !cp.isEmpty else {
            return (false, nil, nil, nil, "app or data container not found: \(bundleId)")
        }
        // 真正的自引用源：目标容器里含本 App 的 rootfs (Documents/alpine-rootfs) 才拒绝。
        // 不再用 NSHomeDirectory() 前缀判"自己容器"——它在 TrollStore/iSH 环境下返回异常，
        // 会把所有 app 容器都误判为自身(实测微信/抖音/小红书全被拒, bind_app 完全不可用)。
        // jinx 等普通 App 容器不含 alpine-rootfs → 允许绑定。
        let fm = FileManager.default
        if fm.fileExists(atPath: cp + "/Documents/alpine-rootfs") {
            return (false, nil, nil, nil, "refusing to bind own rootfs host (contains Documents/alpine-rootfs): \(cp)")
        }
        let host = cp
        let mount = "/ios_data_" + bindAppSanitize(bundleId)
        guard fm.fileExists(atPath: host) else { return (false, nil, nil, nil, "container path missing: \(host)") }
        // 可写绑定：必须先备份（就地修改可还原）
        var backupPath: String? = nil
        if !readOnly {
            backupPath = backupAppContainer(host, app: app.bundleId)
            if backupPath == nil {
                return (false, nil, nil, nil, "backup failed before writable bind — abort to protect \(bundleId)")
            }
        }
        // v4.3.1.1: 挂载前确保 iSH 内核已 boot(否则 bindMount 返回 -1000 = isBooted false)
        if let bootErr = ensureBooted() {
            return (false, nil, nil, nil, bootErr)
        }
        if !mountedBindPoints.contains(mount) {
            let rc = bindMount(mount, host, readOnly: readOnly)
            if rc != 0 { return (false, nil, nil, nil, "bind failed rc=\(rc)") }
            mountedBindPoints.insert(mount)
            ShellDiag.log("bindAppContainer: \(bundleId) \(host) → \(mount) ro=\(readOnly) rc=0 (on-demand container bind)\(backupPath.map{" backup="+$0} ?? "")")
        }
        return (true, mount, host, backupPath, nil)
    }

    /// 可写绑定前，把 App 容器的 Documents + Library（不含 Caches/tmp）备份到工作区 backups/。
    private static func backupAppContainer(_ host: String, app: String) -> String? {
        let backupRoot = "/var/mobile/Documents/Workspace/backups"
        let ts = Int(Date().timeIntervalSince1970)
        let dest = "\(backupRoot)/\(bindAppSanitize(app))_\(ts)"
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)) != nil else { return nil }
        for sub in ["Documents", "Library"] {
            let src = host + "/" + sub
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue {
                do {
                    try fm.copyItem(atPath: src, toPath: dest + "/" + sub)
                } catch { /* individual file failures aren't fatal, best-effort */ }
            }
        }
        return fm.fileExists(atPath: dest) ? dest : nil
    }

    /// 容器挂点名安全化：非字母数字 → '_'，小写。com.appstudio.Jinx → com_appstudio_jinx
    private static func bindAppSanitize(_ s: String) -> String {
        let alnum = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { alnum.contains($0) ? Character($0) : "_" }).lowercased()
    }

    // MARK: - v3.7.7 自动 bind：Alpine 命令引用 iOS 路径时自动挂载并改写
    /// 在 Alpine 命令执行前调用：识别命令中的 iOS 顶层目录（/var/mobile、/var/containers、
    /// /System、/private/var/mobile），对存在且未挂载的顶层 bind 进 Alpine（/ios_xxx），
    /// 并把命令里的 iOS 路径改写为 Alpine 可见路径（/var/mobile/X → /ios_mobile/X）。
    /// 返回改写后的命令（未改动原命令时原样返回）。bind 保持挂载（进程生命周期内有效）。
    /// 幂等：用 mountedBindPoints 集合记录已挂载点，已挂载的顶层跳过 bind（只 bind 一次），
    /// 避免每次命令反复 bind 同一 iOS 顶层目录而污染 iSH 内核（v3.7.3 bindMountForCommand 验证）。
    static func autoBind(_ command: String) -> String {
        // 顶层目录 → Alpine 挂载点映射 + 是否只读。
        // v4.1.0: 【不整棵绑 /var/mobile】。自身 rootfs(Documents/alpine-rootfs) 位于
        // /var/mobile 内，整棵绑定会把自身 rootfs 暴露回 Alpine → 自引用成环 →
        // 内核污染 → cpu_run_to_interrupt 段错误（4.0.6~4.0.9 守卫均未根治）。
        // 根治：只绑工作区(=/var/mobile/Documents/Workspace，rootfs 的兄弟目录，非 rootfs 本身)
        // + /var/containers(bundle 读，已验证不污染) + 只读 /System。
        // v4.4.0(14c0): 追加 App 数据容器绑定——用户明确需要"访问其他 App 数据"：
        //   /var/mobile/Containers/Data/Application → /ios_appdata（所有 App 数据容器，只读）
        //   /var/mobile/Containers/Shared/AppGroup  → /ios_appgroups（Files 共享容器，只读）
        //   两者均不含 /var/mobile/Documents（rootfs 所在）→ 无自引用 → 不污染内核。
        //   只读绑定保证安全（分析/读取用）；要写其他 App 容器走 bindAppContainer(带备份)。
        let roots: [(String, String, Bool)] = [
            ("/var/mobile/Documents/Workspace", "/ios_workspace", false),
            ("/var/containers", "/ios_containers", false),
            ("/System", "/ios_system", true),
            ("/var/mobile/Containers/Data/Application", "/ios_appdata", true),
            ("/var/mobile/Containers/Shared/AppGroup", "/ios_appgroups", true),
        ]
        let fm = FileManager.default
        var result = command
        // v4.3.77：先规整 /private/var（iOS 上 /var 是 /private/var 的软链）。
        // 否则 /private/var/mobile/Documents/Workspace/x 会被替换成 /private/ios_workspace/x
        // （Alpine 里不存在 /private/ios_workspace），文件读不到。
        result = result.replacingOccurrences(of: "/private/var", with: "/var")
        for (iosRoot, mount, readOnly) in roots {
            // 命令里是否引用该 iOS 根目录
            let hasRef = result.contains(iosRoot)
            guard hasRef else { continue }
            // iOS 侧根目录存在才 bind
            guard fm.fileExists(atPath: iosRoot) else { continue }
            // v4.0.1 幂等：已成功挂载过则跳过 bind，只做路径改写（不重复 bind，防污染内核）。
            // 注意：此处【不加锁】——autoBind 可能在 exec 持锁后被调用(NSLock 不可重入，加锁即死锁)；
            // FileDbTools/ShellTool 独立调用时不持锁，至多轻微竞态(重复 bind 一次)，远优于死锁。
            if !mountedBindPoints.contains(mount) {
                let rc = bindMount(mount, iosRoot, readOnly: readOnly)
                if rc == 0 {
                    mountedBindPoints.insert(mount)
                    ShellDiag.log("autoBind: \(iosRoot) → \(mount) ro=\(readOnly) rc=0 (first mount)")
                } else {
                    ShellDiag.log("autoBind: \(iosRoot) bind rc=\(rc) skip rewrite")
                    continue
                }
            }
            // 改写命令：iosRoot 前缀 → mount 前缀（已挂载也需改写，命令引用的是挂载后的 Alpine 路径）
            result = result.replacingOccurrences(of: iosRoot, with: mount)
        }
        return result
    }

    // MARK: - v3.7.5 启动自愈 DNS
    /// iSH fakefs 不持久化 /etc/resolv.conf（rootfs 预置的 DNS 不会呈现给 guest，
    /// 导致 Alpine 无网络 → apk add/python/git 全装不上，即"环境漂移"根因）。
    /// boot 后调用，强制向 guest /etc/resolv.conf 写入国内可达公共 DNS。
    /// 幂等、失败不致命（仅记录日志）；不复用 exec（避免在 ensureBooted 持锁时死锁），
    /// 直接用 cish_spawn + read 循环执行写文件。
    static func ensureDNS() {
        let cmd = "echo nameserver 223.5.5.5 > /etc/resolv.conf; echo nameserver 119.29.29.29 >> /etc/resolv.conf; echo nameserver 8.8.8.8 >> /etc/resolv.conf; cat /etc/resolv.conf"
        var outFds: [Int32] = [-1, -1], errFds: [Int32] = [-1, -1], notifyFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0, pipe(&notifyFds) == 0 else {
            ShellDiag.log("ensureDNS: pipe fail")
            return
        }
        let argvBuf = buildCStringArray(["/bin/sh", "-c", cmd])
        let envpBuf = buildDefaultEnvp()
        let pid = argvBuf.withCString { av in
            envpBuf.withCString { ev in
                cmd.withCString { _ in
                    "/bin/sh".withCString { p in
                        cish_spawn(p, av, ev, 3, -1, outFds[1], errFds[1], notifyFds[1])
                    }
                }
            }
        }
        close(outFds[1]); close(errFds[1]); close(notifyFds[1])
        if pid <= 0 {
            close(outFds[0]); close(errFds[0]); close(notifyFds[0])
            ShellDiag.log("ensureDNS: spawn fail pid=\(pid)")
            return
        }
        // 后台读输出 + 等待退出
        let done = DispatchSemaphore(value: 0)
        var out = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            var b = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(outFds[0], &b, b.count)
                if n <= 0 { break }
                out.append(contentsOf: b[0..<n])
            }
            close(outFds[0]); close(errFds[0]); close(notifyFds[0])
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)  // 最多等 5s，超时不致命
        ShellDiag.log("ensureDNS: pid=\(pid) out=\(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "|"))")
    }

    /// 确保内核已 boot（首次解压 rootfs + 挂载）。线程安全，重复调用幂等。
    static func ensureBooted() -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .booted:
            return nil
        case .booting:
            return "[runtime] kernel initializing, try again later"
        case .failed(let msg):
            return "[runtime] kernel init failed: \(msg)"
        case .idle:
            break
        }
        state = .booting

        // 1. rootfs 解压（首次）/ 版本校验（覆盖安装后 bundle rootfs 更新则自动重解压）
        // v6.5.2：记录 bundle zip 的 MD5 到 .rootfs-version；启动比对不一致 → 备份旧系统区后重解压，
        // 根治"覆盖安装后仍用旧精简 rootfs"（缺 git/curl/ca-certificates/https 证书）。
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: rootfsDir).deletingLastPathComponent()
        let versionFile = URL(fileURLWithPath: rootfsDir).appendingPathComponent(".rootfs-version").path
        if !fm.fileExists(atPath: dataPath) {
            guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
                state = .failed("alpine-rootfs.zip missing from bundle")
                return "[runtime] kernel init failed: alpine-rootfs.zip missing from bundle"
            }
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.unzipItem(at: zipURL, to: parent)
            } catch {
                state = .failed("rootfs extraction failed: \(error.localizedDescription)")
                return "[runtime] kernel init failed: rootfs extraction failed \(error.localizedDescription)"
            }
            if !fm.fileExists(atPath: dataPath) {
                state = .failed("rootfs lacks the data dir after extraction")
                return "[runtime] kernel init failed: rootfs lacks the data dir after extraction"
            }
            if let h = Self.fileMD5((Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip")?.path) ?? "") {
                try? h.write(toFile: versionFile, atomically: true, encoding: .utf8)
            }
        } else if let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip"),
                  let newHash = Self.fileMD5(zipURL.path),
                  let oldHash = try? String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !oldHash.isEmpty, newHash != oldHash {
            // bundle rootfs 已更新——备份旧系统区，重解压（保留备份供回滚）
            let backup = dataPath + ".old"
            do {
                try? fm.removeItem(atPath: backup)
                try fm.moveItem(atPath: dataPath, toPath: backup)
                try fm.unzipItem(at: zipURL, to: parent)
                try newHash.write(toFile: versionFile, atomically: true, encoding: .utf8)
                NSLog("[runtime] rootfs version update: re-extract done (old rootfs backed up at .old)")
            } catch {
                // 重解压失败——回滚备份
                try? fm.removeItem(atPath: dataPath)
                try? fm.moveItem(atPath: backup, toPath: dataPath)
                NSLog("[runtime] rootfs re-extract failed, rolled back to the old rootfs: \(error.localizedDescription)")
            }
        }

        // 2. cish_boot（v3.6.8: 实测确认 fakefs 挂载时不解析跨 iOS 路径的 symlink，
        //    Alpine 为纯隔离 rootfs，不再预建 /workspace、/ios 桥接）
        let rc = dataPath.withCString { cish_boot($0) }
        if rc != 0 {
            state = .failed("cish_boot rc=\(rc)")
            return "[runtime] kernel init failed: cish_boot rc=\(rc)"
        }

        // v3.7.1：bind mount 默认关闭（v3.7.0 在 cish_boot 自动挂载会污染 meta.db 权限
        // 记录导致 Alpine spawn rc=-13）。需要时用 bindMount/bindUnmount 显式按需挂载。
        ShellDiag.log("ISH boot ok data=\(dataPath) (bind-mount disabled by default; use bindMount on demand)")

        spawnFailCount = 0  // v4.0.0: boot 成功即清零 spawn 失败计数
        mountedBindPoints.removeAll()  // v4.0.1: reboot 后旧 bind 点失效, 清空使 autoBind 重新挂载
        state = .booted

        // v3.7.5: 启动自愈 DNS——iSH fakefs 不持久化 /etc/resolv.conf（guest 内无 DNS，
        // apk add/python/git 全装不上 = 环境漂移根因）。boot 后强制写入，使 Alpine 网络即开即用。
        ensureDNS()

        // 3. 默认 cwd 为真实存在的 /root（避免名义 /workspace 误导）
        guestCwd = "/root"

        ShellDiag.log("ISH boot ok data=\(dataPath) (isolated rootfs, no file bridge)")
        return nil
    }

    /// v4.3.69：apk 统一安装入口（tool.install / shell.exec 自动补给共用）。
    /// 解决实测三连：①官方源 dl-cdn.alpinelinux.org 在手机网络下 HTTPS 被断(SSL unexpected eof/Permission
    /// denied)→索引拉不下→误报 "no such package"；②无 ca-certificates 时 HTTPS 握手必失败；
    /// ③大包(openblas/numpy 等 16 依赖)下载慢，默认 20s 超时必被 SIGKILL。
    /// 做法：先幂等切国内镜像源(阿里云 HTTPS，按 /etc/alpine-release 动态版本号)，再补 ca-certificates，
    /// 最后 apk add。超时默认 240s（大包可 1-3 分钟），由调用方按需调整。
    static func apkAdd(_ pkgs: [String], timeout: TimeInterval = 90, onLine: ((String) -> Void)? = nil) -> (output: String, exitCode: Int32, timedOut: Bool) {   // v6.1.5-14bs: 默认超时 240→90s
        let pk = pkgs.joined(separator: " ")
        // fix3bq: 根治"进度条卡死/单源挂死等 240s"——多镜像顺序快速失败切换 + 阶段化进度：
        //   ①ca-certificates（HTTPS 握手必需，失败不阻塞后续）②逐镜像 apk update（50s 无进展即换源）
        //   ③选定源 apk add（输出解析成 下载/安装/完成 阶段喂给进度条）
        let mirrors = ["mirrors.aliyun.com", "mirrors.ustc.edu.cn", "mirrors.tuna.tsinghua.edu.cn", "mirrors.cloud.tencent.com"]
        _ = exec("apk add --no-cache ca-certificates >/dev/null 2>&1", timeout: 45, onLine: onLine)
        var usedMirror = ""
        var lastErr = ""
        for m in mirrors {
            let sedExpr = "s#https://dl-cdn.alpinelinux.org/alpine/v[^/]*#https://\(m)/alpine/v$V#g; s#http://dl-cdn.alpinelinux.org/alpine/v[^/]*#https://\(m)/alpine/v$V#g"
            let pre = "V=$(cut -d. -f1-2 /etc/alpine-release 2>/dev/null); "
                + "grep -q '\(m)' /etc/apk/repositories 2>/dev/null || sed -i \"\(sedExpr)\"/etc/apk/repositories 2>/dev/null; "
            onLine?("Updating package index (\(m))…")
            let upd = exec(pre + "apk update", timeout: 50, onLine: { line in onLine?(line) })
            if upd.exitCode == 0 {
                usedMirror = m
                onLine?("Package source ready: \(m)")
                break
            }
            lastErr = upd.output
            onLine?("\(m) source unavailable, switching to the next mirror…")
        }
        guard !usedMirror.isEmpty else {
            return (lastErr.isEmpty ? "all mirrors failed" : lastErr, 1, false)
        }
        let add = exec("apk add --no-cache " + pk, timeout: timeout, onLine: { line in
            var stage = ""
            if line.contains("Downloading") { stage = "Downloading… " }
            else if line.contains("Installing") { stage = "Installing… " }
            else if line.contains("Fetching") { stage = "Fetching package info… " }
            else if line.contains("OK:") { stage = "Done✓ " }
            onLine?(stage + line)
        })
        return add
    }

    /// v4.3.75：安装失败结构化诊断——AI 可直接转述给用户，替代一坨 apk 日志。
    static func installDiagnose(_ output: String, timedOut: Bool, exitCode: Int32) -> String {
        if timedOut {
            return "Install timed out (interpreter installing a big package/slow network); retry later or split the install"
        }
        let o = output
        if o.contains("unable to select package") || o.contains("No such package") {
            return "Not in the Alpine repo (may not be an Alpine package name); confirm the name or use tool.install with name/source"
        }
        if o.contains("SSL routines") || o.contains("unexpected eof") || o.contains("Permission denied")
            || o.contains("IO ERROR") || o.contains("fetch ") {
            return "Network/package-source issue (auto-switched to a domestic mirror), retry later"
        }
        if o.contains("ERROR:") {
            return "apk install error (mirror auto-switched); full log returned for troubleshooting"
        }
        return "Install failed exit=\(exitCode); full log returned for troubleshooting"
    }

    /// 执行命令。返回 (输出, 退出码, 是否超时)。未 boot 时自动尝试 boot，失败返回错误串。
    /// v3.7.7: 命令引用 iOS 路径时自动 bind 挂载顶层并改写为 /ios_*（见 autoBind），Alpine 直接读写；
    /// 未 bind 的 iOS 路径由 autoBridge(字节拷贝) 兜底。
    /// v4.3.75: 新增 onLine 逐行回调（后台读线程触发，调用方负责线程安全）——供安装进度条使用。
    static func exec(_ command: String, timeout: TimeInterval, onLine: ((String) -> Void)? = nil) -> (output: String, exitCode: Int32, timedOut: Bool) {
        if case .booted = state {} else {
            if let e = ensureBooted() { return (e, -1, false) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard case .booted = state else { return ("[runtime] kernel not ready", -1, false) }

        // v7.0.4.2: 首次执行前等 JIT 就绪（双保险——AppMain 已计划 0.5s 后调 TrollStore URL + 2.5s 处理）。
        // fix7.0.4.2：若远程/终端在 URL 完成前就执行 shell.exec，JIT 授权未生效 → SIGBUS(10) 崩 cpu_run_to_interrupt。
        // 只等首次（后续命令 JIT 已生效），锁内执行保证原子。
        if !jitReadyWaitDone {
            Thread.sleep(forTimeInterval: 3.0)
            jitReadyWaitDone = true
        }

        // v3.7.7: 自动 bind——命令引用 iOS 主流目录(/var/mobile、/var/containers、/System)时
        // 自动挂载顶层并改写路径(/var/mobile/X → /ios_mobile/X)，Alpine 直接读写 iOS 文件。
        // 优先于 autoBridge(字节拷贝)兜底。bind 后 autoBridge 只处理未 bind 的 iOS 路径。
        // v4.0.1 修正: autoBind 已带 mountedBindPoints 幂等保护(只 bind 一次), 保留 bind 大文件直读能力。
        let bound = autoBindEnabled ? autoBind(command) : command

        // autoBridge（字节拷贝兜底）：处理 autoBind 未覆盖的 iOS 路径（非 /var/mobile、/var/containers、
        // /System 顶层）。读 iOS 文件→stdin 管道喂字节→Alpine 写 /tmp/_bridge_N_name→替换路径。
        let (bridged, bridgePrefix, bridgeStdin) = autoBridge(bound)
        ShellDiag.log("ISH exec bridge: prefixEmpty=\(bridgePrefix.isEmpty) stdin=\(bridgeStdin.count)B execCmd=\(String(bridged.prefix(100)))")

        let cwdRaw = guestCwd
        // v4.0.0: cwd 若存的是 iOS 路径（如 Alpine 里 `cd /var/mobile/X` 后 guestCwd 记录为
        // /var/mobile/X），但 Alpine guest 里该路径经 bind 只存在于 /ios_mobile/X——直接用它做
        // `cd '...'` 前缀会在 Alpine 里失败(2>/dev/null 静默) 而掉回 /root，造成"文件夹乱跳/环境偏移"。
        // 修复：构造前缀前也对 cwd 做 autoBind 改写，把 iOS 路径同步改写为 Alpine 可见挂载点。
        // v4.0.1 修正: 构造 cwd 前缀前同样 autoBind 改写(幂等, 只 bind 一次), 避免 iOS 路径在 Alpine 里不可见。
        let cwd = autoBindEnabled ? autoBind(cwdRaw) : cwdRaw
        let tStart = Date()
        ShellDiag.log("ISH exec start cmd=\(command.prefix(80)) timeout=\(timeout) cwdRaw=\(cwdRaw) cwd=\(cwd)")

        // 纯 cd 命令：执行后额外取真实路径
        let trimmed = bridged.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPureCd = trimmed.range(of: "^cd\\s+\\S+(\\s+.*)?$", options: .regularExpression) != nil
            && !trimmed.contains("&&") && !trimmed.contains(";")

        // cd 失败不阻断命令执行（cwd 为真实 /root，但容错）
        var fullCommand = "cd '\(shellQuote(cwd))' 2>/dev/null; \(bridgePrefix)\(bridged)"
        if isPureCd {
            fullCommand += " && pwd"
        }

        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        var notifyFds: [Int32] = [-1, -1]
        var stdinFds: [Int32] = [-1, -1]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0, pipe(&notifyFds) == 0 else {
            ShellDiag.log("ISH exec pipe fail")
            return ("[runtime] pipe creation failed", -1, false)
        }
        // v3.6.14: 有桥文件时建 stdin 管道，guest stdin 接读端，host 写原始字节
        if !bridgeStdin.isEmpty {
            guard pipe(&stdinFds) == 0 else {
                ShellDiag.log("ISH exec stdin pipe fail")
                return ("[runtime] stdin pipe creation failed", -1, false)
            }
        }

        let argvBuf = buildCStringArray(["/bin/sh", "-c", fullCommand])
        let envpBuf = buildDefaultEnvp()
        let pid = argvBuf.withCString { av in
            envpBuf.withCString { ev in
                fullCommand.withCString { _ in
                    "/bin/sh".withCString { p in
                        cish_spawn(p, av, ev, 3, stdinFds[0], outFds[1], errFds[1], notifyFds[1])
                    }
                }
            }
        }

        // 父进程关写端（guest 已 dup）
        close(outFds[1]); close(errFds[1]); close(notifyFds[1])
        // v4.3.77：登记当前 pid——用户点停止时 interruptCurrent() 可立即中断（不必等 timeout）
        Self.currentPid = pid

        if pid <= 0 {
            close(outFds[0]); close(errFds[0]); close(notifyFds[0])
            if stdinFds[0] >= 0 { close(stdinFds[0]); close(stdinFds[1]) }
            ShellDiag.log("ISH exec spawn fail pid=\(pid)")

            // v4.0.0 内核自愈：连续 spawn 失败(rc=-13，bind mount 污染/内核态损坏)达阈值，
            // 重置 state→.idle 使下一次 exec 的 ensureBooted 重新 cish_boot，清除损坏内核态。
            // 锁已持有(exec 顶部 lock.lock)，此处直接改 state 安全。boot 成功后 spawnFailCount 清零。
            spawnFailCount += 1
            if spawnFailCount >= spawnFailThreshold {
                ShellDiag.log("ISH kernel degraded: \(spawnFailCount) consecutive spawn failures, scheduling re-boot (state→idle)")
                state = .idle
                spawnFailCount = 0
                // guestCwd 保留 /root 默认值即可，reboot 后 /root 仍存在
            }
            return ("[runtime] process creation failed rc=\(pid)", -1, false)
        }
        ShellDiag.log("ISH spawned pid=\(pid)")

        // v3.6.14: host 侧把桥文件原始字节经 stdin 管道写进 guest（guest 侧 head -c N 消费）。
        // guest 已从读端 dup fd0；host 关闭读端，保留写端写数据后关闭。
        if !bridgeStdin.isEmpty, stdinFds[1] >= 0 {
            close(stdinFds[0])
            let expect = bridgeStdin.count
            ShellDiag.log("ISH bridge stdin: pipe created, expect \(expect)B")
            DispatchQueue.global(qos: .userInitiated).async {
                let wfd = stdinFds[1]
                var written = 0
                bridgeStdin.withUnsafeBytes { buf in
                    while written < buf.count {
                        let n = write(wfd, buf.baseAddress!.advanced(by: written), buf.count - written)
                        if n <= 0 { break }
                        written += n
                    }
                }
                close(wfd)
                ShellDiag.log("ISH bridge stdin: wrote \(written)/\(expect)B")
            }
        }

        // 后台读 stdout/stderr + 退出通知
        let outBuf = NSMutableString()
        let errBuf = NSMutableString()
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = -1
        DispatchQueue.global(qos: .userInitiated).async {
            var out = Data()
            var b = [UInt8](repeating: 0, count: 16384)
            var lineBuffer = ""
            let emitLines = { (chunk: String) in
                lineBuffer += chunk
                while let nl = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<nl])
                    lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                    onLine?(line)
                }
            }
            while true {
                let n = read(outFds[0], &b, b.count)
                if n <= 0 { break }
                out.append(contentsOf: b[0..<n])
                if onLine != nil { emitLines(String(decoding: b[0..<n], as: UTF8.self)) }
            }
            close(outFds[0])
            outBuf.append(String(decoding: out, as: UTF8.self))

            var err = Data()
            while true {
                let n = read(errFds[0], &b, b.count)
                if n <= 0 { break }
                err.append(contentsOf: b[0..<n])
                if onLine != nil { emitLines(String(decoding: b[0..<n], as: UTF8.self)) }
            }
            close(errFds[0])
            errBuf.append(String(decoding: err, as: UTF8.self))

            // 退出通知：8 字节 (pid, code)
            var notify = Data()
            while notify.count < 8 {
                let n = read(notifyFds[0], &b, b.count)
                if n <= 0 { break }
                notify.append(contentsOf: b[0..<n])
            }
            close(notifyFds[0])
            if notify.count >= 8 {
                exitCode = notify.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
            }
            done.signal()
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // OpenMinis 语义：先 SIGTERM 让命令善后/落盘，1 秒后 SIGKILL 兜底
            _ = cish_killpg(pid, Int32(SIGTERM))
            _ = done.wait(timeout: .now() + 1)
            _ = cish_killpg(pid, Int32(SIGKILL))
            // 最多再等 3 秒收尾（guest 退出 → exit_hook 通知 → 读线程完成）
            _ = done.wait(timeout: .now() + 3)
            exitCode = 137
            ShellDiag.log("ISH TIMEOUT pid=\(pid)")
        }

        var stdout = outBuf as String
        let stderr = errBuf as String
        if !stderr.isEmpty {
            if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
            stdout += stderr
        }

        // 纯 cd：从 pwd 输出解析新会话目录（guest 路径）
        if isPureCd {
            let lines = stdout.components(separatedBy: "\n").filter { $0.hasPrefix("/") }
            if let p = lines.last, p.hasPrefix("/") {
                guestCwd = p
            }
        }

        // P5b v3.6.11: Alpine 命令向 /tmp 写了文件 → 附带 iOS 映射提示，agent 知道去哪取
        if bridged.range(of: "[>]+\\s*/tmp/", options: .regularExpression) != nil {
            if !stdout.isEmpty && !stdout.hasSuffix("\n") { stdout += "\n" }
            stdout += "[bridge] Alpine-written /tmp/* synced back to iOS: Documents/alpine-rootfs/data/tmp/*"
        }

        ShellDiag.log("ISH exec end elapsed=\(Int(Date().timeIntervalSince(tStart) * 1000))ms exit=\(exitCode) timedOut=\(timedOut) out=\(stdout.prefix(80))")
        Self.currentPid = -1
        return (stdout, exitCode, timedOut)
    }

    /// autoBridge（字节拷贝兜底）：autoBind 未覆盖的 iOS 路径，原生读文件→stdin 管道喂字节→
    /// Alpine 写 /tmp/_bridge_N_name→替换路径。返回 (替换后命令, 建文件前缀片段, stdin 原始字节)。
    /// 不用 base64 内联进命令串（大文件会超 iSH 命令长度）。>maxBytes 跳过（走 inject binary_symbols 等）。
    private static func autoBridge(_ command: String, maxBytes: Int = 2 * 1024 * 1024) -> (String, String, Data) {
        let fm = FileManager.default
        var result = command
        var prefix = ""
        var stdinData = Data()
        let prefixes = ["/var/mobile/", "/private/var/mobile/", "/System/", "/var/containers/"]
        let alt = prefixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // v3.6.16: 修复正则 bug——[^\s...]+ 必须应用到整个交替，否则只拼到最后一个分支，
        // 导致 /var/mobile/ 等前缀分支只匹配到目录(如 /var/mobile/)而非完整文件路径。
        // v3.6.19c: 排除集补全 shell 分隔符/标点(; | & , = : [ ] { } ` )，避免命令分隔符被吞进
        // 路径导致"文件找不到→桥接静默跳过→Alpine 对 iOS 文件失效"；`/` 本身保留以便路径继续延伸。
        let pattern = "(^|[\\s\"'=>(])((?:" + alt + ")[^\\s\"'<>\\);|&,=:\\[\\]{}`]+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (command, "", Data()) }
        let ns = result as NSString
        var seen = Set<String>()
        var pending: [(String, String)] = []   // (iosPath, bridgeFile)
        var counter = 0
        for m in re.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let raw = ns.substring(with: m.range(at: 2))
            guard !seen.contains(raw) else { continue }
            seen.insert(raw)
            let norm = ShellExecTool.normalizePath(raw)
            if norm.contains("/alpine-rootfs/") { continue }   // rootfs 自身落盘，Alpine 命令里无意义
            // 详细诊断：定位桥到底在哪一步断（命中/不存在/超限/读取失败）
            if !fm.fileExists(atPath: norm) {
                ShellDiag.log("autoBridge HIT: \(norm) exists=false → skipped")
                continue
            }
            // v3.6.19c: 仅桥接 regular file（目录/symlink/设备不桥），杜绝目录 token 误读浪费。
            if (try? fm.attributesOfItem(atPath: norm)[.type]) as? FileAttributeType != .typeRegular {
                ShellDiag.log("autoBridge HIT: \(norm) not a regular file (dir?) → skipped")
                continue
            }
            guard let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int else {
                ShellDiag.log("autoBridge HIT: \(norm) stat failed → skipped")
                continue
            }
            if size <= 0 || size > maxBytes {
                ShellDiag.log("autoBridge HIT: \(norm) size=\(size)B over limit(>\(maxBytes)) → skipped")
                continue
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: norm)) else {
                ShellDiag.log("autoBridge HIT: \(norm) size=\(size)B read failed → skipped")
                continue
            }
            counter += 1
            let safeName = URL(fileURLWithPath: raw).lastPathComponent
                .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            let bridgeFile = "/tmp/_bridge_\(counter)_" + (safeName.isEmpty ? "f" : safeName)
            // 原始字节经 stdin 管道喂给 guest，head -c N 精确写文件（命令串短，无长度限制）
            stdinData.append(data)
            prefix += "head -c \(data.count) > \(bridgeFile); "
            pending.append((raw, bridgeFile))
            ShellDiag.log("autoBridge OK: \(norm) → \(bridgeFile) (\(data.count)B)")
        }
        for (iosPath, bridgeFile) in pending.sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: iosPath, with: bridgeFile)
        }
        if counter > 0 {
            ShellDiag.log("autoBridge: bridged \(counter) file(s), stdin=\(stdinData.count)B; files=[\(pending.map { $0.1 }.joined(separator: ","))]")
        } else if !seen.isEmpty {
            ShellDiag.log("autoBridge: hit \(seen.count) iOS paths but all skipped (see above)")
        } else {
            ShellDiag.log("autoBridge: no iOS paths matched → command runs as-is: \(String(command.prefix(80)))")
        }
        return (result, prefix, stdinData)
    }

    /// P3 按需补给：从 Alpine 命令输出检测缺失工具("X: not found" / "command not found")，
    /// 命中白名单则返回对应 apk 包名供自动安装；否则 nil。避免 agent 反复试探缺什么工具。
    static func missingToolPkg(_ output: String) -> String? {
        let map: [(cmd: String, pkg: String)] = [
            ("python3", "python3"), ("python", "python3"), ("pip", "py3-pip"),
            ("tar", "tar"), ("dpkg", "dpkg"), ("strings", "binutils"), ("hexdump", "binutils"),
            ("nm", "binutils"), ("objdump", "binutils"), ("readelf", "binutils"),
            ("size", "binutils"), ("addr2line", "binutils"),
            ("rabin2", "radare2"), ("r2", "radare2"), ("radare2", "radare2"),
            ("xxd", "xxd"), ("jq", "jq"), ("gdb", "gdb"),
            ("git", "git"), ("wget", "wget"), ("make", "make"), ("cmake", "cmake"),
            ("gcc", "build-base"), ("clang", "clang"), ("openssl", "openssl"),
            ("unzip", "unzip"), ("sqlite3", "sqlite"),  // v4.3.77: Alpine 包名是 sqlite（命令名 sqlite3）
        ]
        for (cmd, pkg) in map {
            if hasNotFound(output, cmd) {
                return pkg
            }
        }
        // v3.6.14 兜底：白名单外的任意工具名也直接返回该名作为包名（Alpine 绝大多数包名=命令名），
        // 让"AI 需要任何新工具"都能自动 apk add 并配合自动桥分析 iOS 文件，无需维护穷举清单。
        return inferPkgFromNotFound(output)
    }

    /// v4.3.73：自动装包决策——只对白名单内已知包自动 apk add；
    /// 白名单外（如 jtool2 这类 iOS 逆向工具，Alpine 无此包）返回 unknown，
    /// 调用方跳过自动装包并给 AI 明确提示，避免 apk 拉索引卡网络/假死。
    /// v6.1.5-14bp：重包禁止自动装——git/wget/make/cmake/gcc/clang/build-base/emacs 等
    /// 体积大/依赖深，apk add 时 guest 解释器高 CPU，实测触发 iOS watchdog(≈13s CPU)杀 App=闪退。
    /// 改为 known=false 跳过自动装，调用方给明确提示（手动 tool.install / 手动 apk add）。
    static func autoProvision(_ output: String) -> (pkg: String?, known: Bool) {
        let map: [(cmd: String, pkg: String)] = [
            ("python3", "python3"), ("python", "python3"), ("pip", "py3-pip"),
            ("tar", "tar"), ("dpkg", "dpkg"), ("strings", "binutils"), ("hexdump", "binutils"),
            ("nm", "binutils"), ("objdump", "binutils"), ("readelf", "binutils"),
            ("size", "binutils"), ("addr2line", "binutils"),
            ("rabin2", "radare2"), ("r2", "radare2"), ("radare2", "radare2"),
            ("xxd", "xxd"), ("jq", "jq"), ("gdb", "gdb"),
            ("git", "git"), ("wget", "wget"), ("make", "make"), ("cmake", "cmake"),
            ("gcc", "build-base"), ("clang", "clang"), ("openssl", "openssl"),
            ("unzip", "unzip"), ("sqlite3", "sqlite"),  // v4.3.77: Alpine 包名是 sqlite（命令名 sqlite3）
        ]
        // v6.1.5-14bp：高 CPU 重包——即使命中白名单也不自动装（防 watchdog 杀 App）
        let heavyPackages: Set<String> = ["git", "wget", "make", "cmake", "build-base", "clang", "gcc", "openssl", "radare2"]
        for (cmd, pkg) in map {
            if hasNotFound(output, cmd) {
                if heavyPackages.contains(pkg) {
                    return (pkg, false)   // 重包：不自动装，调用方给手动安装提示
                }
                return (pkg, true)
            }
        }
        let inferred = inferPkgFromNotFound(output)
        return (inferred, false)
    }

    /// 从 "not found" 输出推断缺失工具的命令名（白名单兜底）。
    /// v4.3.77：not found 行首匹配（标准 shell 报错格式），避免命令输出文本误判。
    private static func hasNotFound(_ output: String, _ cmd: String) -> Bool {
        let forms = ["\(cmd): not found", "\(cmd): command not found", "command not found: \(cmd)"]
        for f in forms {
            if output.hasPrefix(f) || output.contains("\n" + f) { return true }
        }
        return false
    }

    private static func inferPkgFromNotFound(_ output: String) -> String? {
        // v4.3.77：收紧为行首匹配——只有输出里独立成行的标准 "sh: <cmd>: not found" 才算，
        // 避免命令输出文本（如 grep 搜到 "xxx: not found" 内容）被误判成缺工具而触发安装。
        let patterns = [
            "(?:^|\\n)\\s*(?:sh: /bin/sh: bash: busybox: )?([a-z0-9][a-z0-9._+-]*): (?:command )?not found",
            "(?:^|\\n)\\s*command not found: ([a-z0-9][a-z0-9._+-]*)",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = output as NSString
            for m in re.matches(in: output, options: [], range: NSRange(location: 0, length: ns.length)) {
                let cmd = ns.substring(with: m.range(at: 1))
                if isSafePkgName(cmd) { return cmd }
            }
        }
        return nil
    }

    /// 兜底安装的安全校验：只允许纯字母数字 . _ + - 的小写标识符，且非 shell 关键字/常见误报。
    private static func isSafePkgName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 40,
              s.first?.isLetter == true || s.first?.isNumber == true else { return false }
        let blocked = ["cd","fi","then","else","do","done","case","esac","test","true","false",
                       "exit","echo","printf","read","source","time","which","type","break","continue","pwd","ls","cat"]
        if blocked.contains(s) { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "+" || $0 == "-" }
    }

    /// shell 单引号转义
    private static func shellQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// 构造 NUL 分隔 + 末尾双 NUL 的 argv 块
    private static func buildCStringArray(_ args: [String]) -> String {
        args.joined(separator: "\0") + "\0\0"
    }

    /// 内置默认环境（参考 OpenMinis envp）
    private static func buildDefaultEnvp() -> String {
        var vars: [String] = []
        vars.append("TERM=xterm-256color")
        vars.append("HOME=/root")
        vars.append("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        vars.append("LANG=C.UTF-8")
        vars.append("CHARSET=UTF-8")
        vars.append("ENV=/etc/profile")
        vars.append("OPENSSL_armcap=0")
        vars.append("NO_COLOR=1")
        vars.append("PYTHONDONTWRITEBYTECODE=1")
        // 设备时区（POSIX TZ，musl 兼容）
        let secs = TimeZone.current.secondsFromGMT()
        let hrs = secs / 3600
        let mins = abs(secs % 3600) / 60
        let tz = mins != 0 ? String(format: "LCL%+ld:%02ld", -hrs, mins) : String(format: "LCL%+ld", -hrs)
        vars.append("TZ=\(tz)")
        return vars.joined(separator: "\0") + "\0\0"
    }
}
