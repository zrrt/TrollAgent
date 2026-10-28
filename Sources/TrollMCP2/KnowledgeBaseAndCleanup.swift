import Foundation
import SQLite3

// v2.9.72：崩溃知识库 + 工作区清理
// 1. FailureKnowledgeBase — 存储错误模式和修复方案，下次自动匹配
// 2. WorkspaceCleanupTool — 按天数/大小清理工作区临时文件

// MARK: - 崩溃知识库

final class FailureKnowledgeBase {
    static let shared = FailureKnowledgeBase()
    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        let docs = NSHomeDirectory().appending("/Documents/Workspace")
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        dbPath = docs.appending("/failure_kb.db")
        openDB()
        createTable()
        seedBuiltinPatterns()
    }

    private func openDB() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            db = nil
        }
    }

    private func createTable() {
        guard let db = db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS patterns (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            category TEXT NOT NULL,
            cause TEXT NOT NULL,
            fix TEXT NOT NULL,
            hit_count INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_keyword ON patterns(keyword);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func insertPattern(_ kw: String, _ cat: String, _ cause: String, _ fix: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO patterns (keyword, category, cause, fix) VALUES (?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kw, -1, nil)
        sqlite3_bind_text(stmt, 2, cat, -1, nil)
        sqlite3_bind_text(stmt, 3, cause, -1, nil)
        sqlite3_bind_text(stmt, 4, fix, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func keywordExists(_ kw: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT 1 FROM patterns WHERE keyword=? LIMIT 1", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, kw, -1, nil)
        let found = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return found
    }

    // v1 种子（15 条，仅空库时插入）
    private let v1Patterns: [(String, String, String, String)] = [
        ("Operation not permitted", "Permission", "TrollStore 'Edit Entitlements' not enabled; sideloaded apps lack root write permission", "Enable 'Edit Entitlements' in TrollStore, then uninstall/reinstall (overwriting the install won't re-apply it)"),
        ("bin-setuid=0", "Permission", "Injection tools lack the setuid root bit", "Confirm TrollStore applied setuid to bin/ tools, uninstall/reinstall the app"),
        ("Failed to parse plist", "Signing", "ldid failed to parse the entitlements plist", "Check the entitlements file format, or re-sign with ct_bypass"),
        ("link edit information does not fill", "Mach-O", "install_name_tool can't handle the __LINKEDIT segment", "Non-blocking error, ct_bypass signing done, injection still OK"),
        ("Library not loaded", "Dependency", "A dylib dependency's dynamic library doesn't exist", "Check deps with otool -L, confirm all dependencies exist on the target device"),
        ("code signature invalid", "Signing", "Code signature invalid", "Re-sign with ldid -S, or reinstall via TrollStore"),
        ("dyld: Symbol not found", "Dependency", "The dylib references a symbol that doesn't exist", "Check the SDK version the dylib was built with, ensure iOS compatibility"),
        ("task_for_pid failed", "Permission", "Missing task_for_pid-allow entitlement", "Enable 'Edit Entitlements' in TrollStore, then uninstall/reinstall"),
        ("cannot create regular file", "Permission", "Can't write to the target app's Bundle directory", "Confirm the target app is closed and root permission is active"),
        ("Killed: 9", "Crash", "App killed by the system (usually signing or memory issues)", "Check crash logs, analyze with diagnose.crash"),
        ("SSL/TLS connection failed", "Network", "GitHub connection timeout", "Retry or configure a proxy; network issue, not an app bug"),
        ("unable to type-check", "Compile", "Swift expression too complex, compiler timeout", "Split complex dictionaries/expressions into standalone variables"),
        ("is inaccessible due to private", "Compile", "Accessed a private member", "Change the target method/property to public or internal"),
        ("cannot find in scope", "Compile", "Symbol undefined (usually a missing import)", "Add the missing import or check spelling"),
    ]

    // v2 种子（v4.3.66 追加，覆盖游戏/注入/系统崩溃/环境）
    private let v2Patterns: [(String, String, String, String)] = [
        ("Image not found", "Dependency", "dylib @rpath/@executable_path wrong or file not bundled", "Use otool -L to see actual load paths, confirm the dylib is inside the target app and the path is right"),
        ("EXC_BAD_ACCESS", "Crash", "Accessing freed/null/invalid memory (incl. wrong hook edits)", "Check hook offsets and function signatures, confirm patches/pointers aren't PAC-protected, locate with diagnose"),
        ("Segmentation fault", "Crash", "Illegal memory access (usually an injected dylib or wrong static patch)", "Verify RVA/offsets match the target version, roll back .bak_macho and retry"),
        ("Permission denied", "Permission", "Target path read-only or not running as root", "Confirm TrollStore 'Edit Entitlements' is on and setuid is applied; Bundle dir needs root write"),
        ("No space left on device", "Storage", "Sandbox is full", "Clear old files/logs with workspace.cleanup, or clean app storage in system settings"),
        ("Connection refused", "Network", "No service on the target port / proxy not started", "Confirm the server started and the port is right; start the local proxy/capture tool first"),
        ("Could not inspect the application package", "Install", "IPA structure incomplete or not a valid app package", "Check the package structure with package.unpack, confirm Info.plist and the main binary are complete"),
        ("0x8badf00d", "Crash", "Killed by the system watchdog on launch (startup too slow, usually heavy injection)", "Reduce dylibs/checks loaded at startup, defer heavy work until after launch"),
        ("0xdead10cc", "Crash", "System judged the app as stuck/held (usually background locks/IO stall)", "Investigate main-thread blocking, full serialization of large files, dead loops"),
        ("candidate should have a different linkedit", "Mach-O", "Static injection conflicts with the original signature when changing __LINKEDIT", "Must ldid re-sign after injection; 优先使用注入器自带的签名流程"),
        ("Unsupported iOS version", "TrollStore", "TrollStore unsupported on this system (17.0.1+/16.7 patched)", "Check the support table; for unsupported versions use jailbreak or another signing route"),
        ("apk: command not found", "TrollRuntime", "apk index stale or broken in the env", "Run apk update first; confirm you're in the unified env (TrollRuntime/Alpine), not the target app's environment"),
        ("Illegal instruction", "TrollRuntime", "Interpreter doesn't implement this instruction (common with Node.js etc.)", "Use a lighter/older build, or run via SSH to a PC/cloud"),
        ("address already in use", "Network", "Local service port in use", "Check occupancy via server.status, change the port or stop the old instance"),
    ]

    private func seedBuiltinPatterns() {
        guard let db = db else { return }
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v INTEGER)", nil, nil, nil)

        // v1：仅空库时插入
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM patterns", -1, &stmt, nil)
        sqlite3_step(stmt)
        let count = sqlite3_column_int(stmt, 0)
        sqlite3_finalize(stmt)
        if count == 0 {
            for (kw, cat, cause, fix) in v1Patterns { insertPattern(kw, cat, cause, fix) }
        }

        // v2：版本迁移，缺失的才插入（老用户也能拿到新种子）
        sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k='seed_version'", -1, &stmt, nil)
        var v = 0
        if sqlite3_step(stmt) == SQLITE_ROW { v = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if v < 2 {
            for (kw, cat, cause, fix) in v2Patterns where !keywordExists(kw) {
                insertPattern(kw, cat, cause, fix)
            }
            sqlite3_exec(db, "INSERT OR REPLACE INTO meta(k,v) VALUES('seed_version',2)", nil, nil, nil)
        }
    }

    func match(_ errorText: String) -> [(keyword: String, category: String, cause: String, fix: String)] {
        guard let db = db else { return [] }
        var results: [(String, String, String, String)] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT keyword, category, cause, fix FROM patterns ORDER BY hit_count DESC", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kw = String(cString: sqlite3_column_text(stmt, 0))
            if errorText.localizedCaseInsensitiveContains(kw) {
                let cat = String(cString: sqlite3_column_text(stmt, 1))
                let cause = String(cString: sqlite3_column_text(stmt, 2))
                let fix = String(cString: sqlite3_column_text(stmt, 3))
                results.append((kw, cat, cause, fix))
                // 递增命中计数
                incrementHit(kw)
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    private func incrementHit(_ keyword: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE patterns SET hit_count = hit_count + 1 WHERE keyword = ?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, keyword, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func addPattern(keyword: String, category: String, cause: String, fix: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO patterns (keyword, category, cause, fix) VALUES (?,?,?,?)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, keyword, -1, nil)
        sqlite3_bind_text(stmt, 2, category, -1, nil)
        sqlite3_bind_text(stmt, 3, cause, -1, nil)
        sqlite3_bind_text(stmt, 4, fix, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func allPatterns() -> [[String: Any]] {
        guard let db = db else { return [] }
        var results: [[String: Any]] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT keyword, category, cause, fix, hit_count FROM patterns ORDER BY hit_count DESC", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "keyword": String(cString: sqlite3_column_text(stmt, 0)),
                "category": String(cString: sqlite3_column_text(stmt, 1)),
                "cause": String(cString: sqlite3_column_text(stmt, 2)),
                "fix": String(cString: sqlite3_column_text(stmt, 3)),
                "hit_count": Int(sqlite3_column_int(stmt, 4))
            ])
        }
        sqlite3_finalize(stmt)
        return results
    }
}

// MARK: - 知识库查询工具

final class KnowledgeBaseTool: MCPTool {
    let definition = ToolDefinition(
        name: "kb.query",
        summary: "Query the crash/error knowledge base. Use for: look up known error patterns, find out what an error means and how to fix it. Don't use for: diagnose crash (use diagnose.crash), collect logs (use log.collect). Example: user says 'what does this error mean' → query knowledge base.",
        parameters: [
            "error": "Error text to look up (required)",
            "action": "query (default) or add new pattern",
            "keyword": "Keyword (when adding new pattern)",
            "cause": "Cause description (when adding)",
            "fix": "Fix solution (when adding)"
        ],
    verified: true, category: "knowledge")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = (params["action"] as? String) ?? "query"

        if action == "add" {
            guard let kw = params["keyword"] as? String,
                  let cause = params["cause"] as? String,
                  let fix = params["fix"] as? String else {
                throw MCPError.invalidParams("add requires keyword, cause, fix")
            }
            let category = params["category"] as? String ?? "custom"
            FailureKnowledgeBase.shared.addPattern(keyword: kw, category: category, cause: cause, fix: fix)
            return ["added": true, "keyword": kw]
        }

        guard let error = params["error"] as? String, !error.isEmpty else {
            // 返回所有模式
            return ["patterns": FailureKnowledgeBase.shared.allPatterns()]
        }

        let matches = FailureKnowledgeBase.shared.match(error)
        return [
            "query": error,
            "matches": matches.map { ["keyword": $0.keyword, "category": $0.category, "cause": $0.cause, "fix": $0.fix] },
            "match_count": matches.count
        ]
    }
}
