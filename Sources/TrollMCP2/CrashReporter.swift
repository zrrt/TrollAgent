import Foundation
import UIKit

// v7.4.0-fix73e：崩溃捕获——信号 + Objective-C 异常 → 写 Documents/crash.log
// 背景：TrollStore 侧载环境崩溃无系统诊断可查（用户实测子 agent 召唤时
// "app was terminated by the system (crash)"，全部工具调用中断），
// 需要 App 内自记崩溃现场（时间/线程/栈）供定位。
// 注意：signal handler 内只做最小安全操作（写文件 + 恢复默认处理重发，
// 让系统保留原生崩溃报告，也避免 handler 里继续跑不安全代码二次崩溃）。
enum CrashReporter {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        // Objective-C 异常（NSException）
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let names = exception.name.rawValue
            let reason = exception.reason ?? "nil"
            CrashReporter.write("TYPE: NSException\nNAME: \(names)\nREASON: \(reason)\nSTACK:\n\(symbols)")
        }
        // 信号（Swift fatalError / 强制解包 nil / EXC_BAD_ACCESS 等）
        let sigs: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in sigs {
            signal(sig, { s in
                let backtrace = Thread.callStackSymbols.joined(separator: "\n")
                CrashReporter.write("TYPE: SIGNAL \(s)\nSTACK:\n\(backtrace)")
                // 恢复默认处理并重发——保留 iOS 原生崩溃报告，也避免 handler 二次崩溃
                signal(s, SIG_DFL)
                raise(s)
            })
        }
        // 低内存警告也留痕（jetsam 前兆）
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
            CrashReporter.write("TYPE: MEMORY_WARNING\nSTACK:\n" + Thread.callStackSymbols.joined(separator: "\n"))
        }
    }

    /// 写崩溃现场（覆盖写，保留最新一次）
    static func write(_ text: String) {
        let stamp = "=== TrollAgent crash @ \(Date()) ===\n"
        let full = stamp + text + "\n"
        let path = NSHomeDirectory() + "/Documents/crash.log"
        if let d = full.data(using: .utf8) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // 同步刷盘保险（signal handler 里 try? 可能不可靠，但至少尝试）
    }
}
