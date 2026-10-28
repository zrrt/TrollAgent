import Foundation
import SQLite3

// MARK: - v7.4.0-sessionstore：会话持久化双层（JSONL 真源 + SQLite 索引）
// 对齐 Codex rollout(JSONL 真源)+state.sqlite(索引)、Cursor 元数据先行：
//  - 写路径增量：只 append 新消息行 + upsert 索引行 → 根治"每次变更全量重写整个会话数组 O(N²)"
//    （长会话卡顿/白屏的写路径根因；对齐 Claude Code transcript append-only）
//  - 读路径：列表走 SQLite 索引秒开（token 占用可视化数据源）；打开会话按需读 JSONL
//  - 失败可降级：任何 SQLite/写盘失败返回 false，ConversationStore 回退旧全量 JSON（不丢数据）
final class SessionStore {
    static let shared = SessionStore()

    private let storeDir: String
    private let sessionsDir: String
    private let indexPath: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var opened = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let base = NSHomeDirectory().appending("/Documents/Workspace/store")
        storeDir = base
        sessionsDir = base + "/sessions"
        indexPath = base + "/session_index.sqlite"
    }

    // MARK: - 打开/建表

    /// 打开 SQLite（幂等）。失败返回 false——调用方降级回退全量 JSON。
    private func open() -> Bool {
        if opened, db != nil { return true }
        do {
            try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        } catch { return false }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(indexPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = handle else {
            if let h = handle { sqlite3_close(h) }
            return false
        }
        db = h
        // WAL：崩溃安全 + 读写不互斥（Cursor state.vscdb 同款；列表读不阻塞追加写）
        _ = sqlite3_exec(h, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            message_count INTEGER NOT NULL DEFAULT 0,
            token_estimate INTEGER NOT NULL DEFAULT 0
        );
        """
        let ok = sqlite3_exec(h, schema, nil, nil, nil) == SQLITE_OK
        opened = ok
        return ok
    }

    // MARK: - 查询

    /// 会话目录是否已有 JSONL 数据（决定 load() 走新双层还是旧 JSON 迁移）
    func hasData() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir),
              let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return false }
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// 索引里的消息数（权威持久化水位，用于增量 diff——无跨线程状态）
    func messageCount(id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return -1 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT message_count FROM sessions WHERE id=?1", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// SQLite TEXT 列 → Swift String（column_text 返回 UInt8 指针，显式 rebind 到 CChar）
    private func cstr(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
    }

    /// 元数据先行：会话列表只查 SQLite 索引（秒开），不读消息体
    func listSessions(limit: Int) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id,title,created_at,updated_at,message_count,token_estimate FROM sessions ORDER BY updated_at DESC LIMIT ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(limit))
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = cstr(stmt, 0)
            let title = cstr(stmt, 1)
            let createdAt = sqlite3_column_int64(stmt, 2)
            let updatedAt = sqlite3_column_int64(stmt, 3)
            let count = sqlite3_column_int64(stmt, 4)
            let tokens = sqlite3_column_int64(stmt, 5)
            out.append([
                "id": id,
                "title": title,
                "createdAt": createdAt,
                "updatedAt": updatedAt,
                "messageCount": count,
                "tokenEstimate": tokens
            ])
        }
        return out
    }

    /// 上下文占用可视化数据源：聚合统计（总会话/总消息/总 token/最大会话）
    func stats() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT COUNT(*), IFNULL(SUM(message_count),0), IFNULL(SUM(token_estimate),0), IFNULL(MAX(token_estimate),0) FROM sessions",
            -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [:] }
        return [
            "sessionCount": sqlite3_column_int64(stmt, 0),
            "totalMessages": sqlite3_column_int64(stmt, 1),
            "totalTokenEstimate": sqlite3_column_int64(stmt, 2),
            "maxSessionTokenEstimate": sqlite3_column_int64(stmt, 3)
        ]
    }

    /// 全量重建（启动 load()）：索引拿元数据，JSONL 拿消息体
    func loadAll() -> [ChatConversation] {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        var metas: [String: (String, Int64, Int64)] = [:]   // id → (title, created, updated)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id,title,created_at,updated_at FROM sessions", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = cstr(stmt, 0)
                let title = cstr(stmt, 1)
                metas[id] = (title, sqlite3_column_int64(stmt, 2), sqlite3_column_int64(stmt, 3))
            }
            sqlite3_finalize(stmt)
        }
        var out: [ChatConversation] = []
        for f in files.sorted() where f.hasSuffix(".jsonl") {
            let id = String(f.dropLast(".jsonl".count))
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionsDir + "/" + f)) else { continue }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            var msgs: [ChatMessage] = []
            for line in lines {
                if let m = try? JSONDecoder().decode(ChatMessage.self, from: Data(String(line).utf8)) {
                    msgs.append(m)
                }
            }
            var conv = ChatConversation(
                title: metas[id]?.0 ?? (msgs.first?.content.prefix(30)).map { String($0) } ?? "Conversation",
                createdAt: metas[id].map { Date(timeIntervalSince1970: TimeInterval($0.1)) } ?? Date(),
                updatedAt: metas[id].map { Date(timeIntervalSince1970: TimeInterval($0.2)) } ?? (msgs.last?.timestamp ?? Date()),
                messages: msgs
            )
            if let uuid = UUID(uuidString: id) { conv.id = uuid }
            out.append(conv)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 写入

    /// 增量持久化：dirty 会话整会话重写（中间修改），否则尾部追加新消息；都 upsert 索引。
    /// 返回 false 表示失败——调用方降级回退旧全量 JSON。
    /// 一致性闭环（v7.4.0-fix65 深度审计）：
    ///  - persist 失败写 .fallback_flag；下次成功先全量重建 JSONL（对齐内存）再删标记——
    ///    防降级窗口内的删除/编辑在增量 append 路径下"复活"（count>last 只补尾部，删过的头部仍在）
    ///  - last==0 但文件已存在（索引丢失/降级部分写入）→ 整会话重写，防尾部重复
    func persist(snapshot: [ChatConversation], dirty: Set<UUID>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open() else { writeFlag(); return false }
        let flag = storeDir + "/.fallback_flag"
        // 一致性修复路径：上次降级过 → 全量重建 JSONL（对齐内存快照），全成功才删标记
        if FileManager.default.fileExists(atPath: flag) {
            var rebuilt = true
            for conv in snapshot {
                if !rewriteConversation(conv, to: sessionsDir + "/" + conv.id.uuidString + ".jsonl") {
                    rebuilt = false; break
                }
                if !upsertIndexLocked(conv) { rebuilt = false; break }
            }
            if rebuilt {
                try? FileManager.default.removeItem(atPath: flag)
                return true
            }
            writeFlag()
            return false
        }
        var ok = true
        for conv in snapshot {
            let id = conv.id.uuidString
            let file = sessionsDir + "/" + id + ".jsonl"
            let last = messageCountLocked(id: conv.id)
            let fileExists = FileManager.default.fileExists(atPath: file)
            // last==0 但文件已存在且有消息 = 索引丢失/从未 upsert → 整会话重写防重复
            let needFull = dirty.contains(conv.id) || !fileExists || (last == 0 && !conv.messages.isEmpty)
            if needFull {
                if !rewriteConversation(conv, to: file) { ok = false; continue }
            } else if conv.messages.count < last {
                // 消息数回退（降级/并发窗口内删除消息）→ 整会话重写，防已删消息从 JSONL 复活
                if !rewriteConversation(conv, to: file) { ok = false; continue }
            } else if conv.messages.count > last {
                let newMsgs = Array(conv.messages.suffix(conv.messages.count - last))
                if !appendMessages(newMsgs, to: file) { ok = false; continue }
            }
            if !upsertIndexLocked(conv) { ok = false }
        }
        if !ok { writeFlag() }
        return ok
    }

    private func writeFlag() {
        _ = open()
        try? Data().write(to: URL(fileURLWithPath: storeDir + "/.fallback_flag"))
    }

    /// 清空全部会话（对齐 ConversationStore.clearAll）
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        _ = open()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) {
            for f in files where f.hasSuffix(".jsonl") {
                try? FileManager.default.removeItem(atPath: sessionsDir + "/" + f)
            }
        }
        if db != nil {
            _ = sqlite3_exec(db, "DELETE FROM sessions;", nil, nil, nil)
        }
        // 清空后状态一致，降级标记一并清除
        try? FileManager.default.removeItem(atPath: storeDir + "/.fallback_flag")
    }

    /// 删除单个会话（JSONL 文件 + 索引行）——v7.4.0-fix65：delete 会话必须同步清双层，否则重启复活
    func removeConversation(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        _ = open()
        try? FileManager.default.removeItem(atPath: sessionsDir + "/" + id.uuidString + ".jsonl")
        guard db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id=?1", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        _ = sqlite3_step(stmt)
    }

    // MARK: - 私有

    private func messageCountLocked(id: UUID) -> Int {
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT message_count FROM sessions WHERE id=?1", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// 整会话重写——先写 .tmp 再原子替换（rename）：失败时旧文件保留，不丢数据
    private func rewriteConversation(_ conv: ChatConversation, to file: String) -> Bool {
        let tmp = file + ".tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        guard appendMessages(conv.messages, to: tmp) else {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: file) {
                try FileManager.default.removeItem(atPath: file)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: file)
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
    }

    /// 追加消息行（append-only，逐行一条 ChatMessage JSON；空消息也落盘为空文件——空会话可持久化）
    private func appendMessages(_ msgs: [ChatMessage], to file: String) -> Bool {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: file)
        if !fm.fileExists(atPath: file) {
            guard fm.createFile(atPath: file, contents: nil) else { return false }
        }
        guard !msgs.isEmpty else { return true }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let enc = JSONEncoder()
        for m in msgs {
            guard let d = try? enc.encode(m) else { continue }
            handle.write(d)
            handle.write(Data("\n".utf8))
        }
        // v7.4.0-fix65：本次会话保存末尾 fsync——崩溃最多丢本次未完成行，不丢已确认消息
        //（旧全量路径 .atomic 有同步，增量 append 必须补上同等保证）
        handle.synchronizeFile()
        return true
    }

    /// upsert 会话索引（v7.4.0：SQLite UPSERT——iOS 15 系统 SQLite 3.32+ 支持 ON CONFLICT DO UPDATE）
    @discardableResult
    private func upsertIndexLocked(_ conv: ChatConversation) -> Bool {
        guard db != nil else { return false }
        let tokens = tokenEstimate(conv)
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO sessions(id,title,created_at,updated_at,message_count,token_estimate)
        VALUES(?1,?2,?3,?4,?5,?6)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,
            updated_at=excluded.updated_at,
            message_count=excluded.message_count,
            token_estimate=excluded.token_estimate
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, conv.id.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, conv.title, -1, transient)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(conv.createdAt.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(conv.updatedAt.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 5, sqlite3_int64(conv.messages.count))
        sqlite3_bind_int64(stmt, 6, sqlite3_int64(tokens))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// 会话 token 估算（与 OpenAIClient 分桶估算同源，乘真实 usage 校准比——
    /// UI 索引口径与 AI 压力判断一致：Claude 模型自动收敛 ~1.65，不乘会显示偏低 40%）
    private func tokenEstimate(_ conv: ChatConversation) -> Int {
        var total = 0
        for m in conv.messages {
            total += OpenAIClient.estimateTokensStatic(m)
        }
        let cal = UsageRecorder.shared.calibratedRatio
        return cal > 0 ? max(total, Int(Double(total) * cal)) : total
    }
}
