import Foundation
import UIKit

// MARK: - v2.9.3 本机编译 / 构建能力
//
// 在 TrollAgent 内原生实现"设备端编译桥" (此前是独立injected dylib 的 TMBuildAgent 方案）。
// 工具链约定 (用户手动放置到工作区，符合"编译依赖可手动下载/删除"）：
//   Documents/Workspace/toolchain/
//     bin/clang, bin/ld, bin/make, bin/perl, bin/ldid
//     theos/                 —— 完整 Theos (makefiles、lib、bin）
//     sdk/iPhoneOS*.sdk      —— iOS SDK 头文件
// 工程约定 (与 project.generate_tweak 一致）：
//   Documents/Workspace/projects/<name>/  (Makefile + Tweak.x + <name>.plist)

/// 进程执行结果
struct BuildProcessResult {
    let exitCode: Int32      // 0=OK；-1=spawn/内部错误；-2=超时被杀
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let spawnError: String?
}

/// posix_spawn 执行器：支持工作目录、自定义环境变量、超时杀进程。
/// 相比 InjectionManager.spawn 扩展了 cwd/env/timeout，供编译这类长任务使用。
final class BuildRunner {
    static let shared = BuildRunner()

    private let maxOutputBytes = 4 * 1024 * 1024   // 输出截断上限 4MB

    /// 执行一条命令。
    /// iOS SDK 限制：posix_spawn 无法设置工作目录 (无 posix_spawnattr_setworkingdir_np）、
    /// fork() 被标记 unavailable，因此需要工作目录时用 `/bin/sh -c "cd '<dir>' && exec ..."` 包装。
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径
    ///   - args: 参数 (不含可执行文件本身）
    ///   - workingDir: 工作目录 (nil = 直接 spawn）
    ///   - env: 追加/覆盖的环境变量
    ///   - timeout: 超时秒数 (0 = 不超时）
    func run(executable: String, args: [String], workingDir: String? = nil,
             env: [String: String] = [:], timeout: TimeInterval = 300) -> BuildProcessResult {
        guard FileManager.default.fileExists(atPath: executable) else {
            return BuildProcessResult(exitCode: -1, stdout: "", stderr: "executable not found: \(executable)", timedOut: false, spawnError: "not found")
        }

        if let wd = workingDir {
            var cmd = "cd \(shellQuote(wd)) && exec \(shellQuote(executable))"
            for a in args { cmd += " " + shellQuote(a) }
            return spawnPosix(path: "/bin/sh", args: ["-c", cmd], env: env, timeout: timeout)
        }
        return spawnPosix(path: executable, args: args, env: env, timeout: timeout)
    }

    /// posix_spawn + 输出落临时文件 + 超时杀进程
    private func spawnPosix(path: String, args: [String], env: [String: String], timeout: TimeInterval) -> BuildProcessResult {
        let argvList = [path] + args
        var argv: [UnsafeMutablePointer<CChar>?] = argvList.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        // 环境：继承当前 + 覆盖
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        if mergedEnv["PATH"] == nil { mergedEnv["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if mergedEnv["HOME"] == nil { mergedEnv["HOME"] = "/var/mobile" }
        var cenv: [UnsafeMutablePointer<CChar>?] = mergedEnv.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for p in cenv where p != nil { free(p) } }

        // 输出落临时文件 (避免管道缓冲死锁，适合大输出）
        let outPath = NSTemporaryDirectory() + "tmcp_build_out_\(UUID().uuidString).log"
        let errPath = NSTemporaryDirectory() + "tmcp_build_err_\(UUID().uuidString).log"

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, outPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, errPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, path, &fileActions, nil, &argv, &cenv)
        posix_spawn_file_actions_destroy(&fileActions)

        if spawnStatus != 0 {
            let msg = "posix_spawn failed: \(String(cString: strerror(spawnStatus)))"
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: errPath)
            return BuildProcessResult(exitCode: -1, stdout: "", stderr: msg, timedOut: false, spawnError: msg)
        }

        // 等待 + 超时杀进程
        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w == -1 && errno != EINTR { break }
            if Date() > deadline {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                timedOut = true
                break
            }
            usleep(200_000)
        }

        // 读回输出 (截断）
        var outStr = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        var errStr = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        if outStr.count > maxOutputBytes { outStr = String(outStr.prefix(maxOutputBytes)) }
        if errStr.count > maxOutputBytes { errStr = String(errStr.prefix(maxOutputBytes)) }
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: errPath)

        let exitCode: Int32
        if timedOut {
            exitCode = -2
        } else {
            // fix3cl6: 之前只取 WEXITSTATUS(status>>8)——被信号杀死的进程(崩溃/被 SIGKILL)status 低 8 位是信号号、
            // 高 8 位为 0，导致"崩溃显示 exit 0"（r2 的 dyld abort、python3 的静默被杀全部被误读为正常退出）。
            // 现在按 POSIX 惯例：WIFSIGNALED → 128+signum（崩溃可见），否则 WEXITSTATUS。
            let wstatus = UInt32(bitPattern: status)
            let sig = wstatus & 0x7f
            if sig != 0 && (wstatus & 0x7f) != 0x7f {
                exitCode = Int32(128 + Int32(sig))
            } else {
                exitCode = Int32((wstatus >> 8) & 0xff)
            }
        }
        return BuildProcessResult(exitCode: exitCode, stdout: outStr, stderr: errStr, timedOut: timedOut, spawnError: nil)
    }

    /// shell 单引号转义 (用于安全拼接 `cd '<dir>'` 等）
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 通过 /bin/sh -c 执行一条命令 (用于版本探测等）
    func shell(_ command: String, workingDir: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 30) -> BuildProcessResult {
        run(executable: "/bin/sh", args: ["-c", command], workingDir: workingDir, env: env, timeout: timeout)
    }
}
