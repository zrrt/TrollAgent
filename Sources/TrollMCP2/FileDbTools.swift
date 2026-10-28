import Foundation

// MARK: - v3.6.12 P5 高层跨环境工具 (v3.7.7: 复用 TrollRuntimeEngine 自动 bind——Alpine 直接读写 iOS 文件)

/// 高层文件检查/分析工具。inspect 走原生读元信息；analyze 走 Alpine (自动 bind 直读 iOS 文件) 跑 file+strings。
final class FileExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "file",
        summary: "High-level file inspection (unified env reads iOS files directly). Subcommands: inspect / analyze. inspect=native metadata: size, magic type (sqlite/zip/macho/elf/text); Mach-O additionally gives fat/thin, arch(arm64/x86_64), filetype(executable/dylib). analyze=in-env `file`+`strings` (first 80 lines). REQUIRED: path (iOS absolute path). Use for: identify file type / extract strings from a decrypted binary or db; for editing files use shell.",
        parameters: [
            "command": "Subcommand (required): inspect / analyze",
            "path": "iOS absolute file path (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: inspect / analyze")
        }
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let norm = ShellExecTool.normalizePath(path)
        let fm = FileManager.default
        switch command {
        case "inspect":
            guard fm.fileExists(atPath: norm) else { throw MCPError.failed("file: no such file \(norm)") }
            guard let size = (try? fm.attributesOfItem(atPath: norm)[.size]) as? Int else {
                throw MCPError.failed("file: cannot stat \(norm)")
            }
            var result: [String: Any] = ["path": norm, "size_bytes": size]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: norm), options: .mappedIfSafe) {
                let head = [UInt8](data.prefix(128))
                let type = FileExecTool.detectType(head)
                result["type"] = type
                // v4.3.70: Mach-O 附带架构/类型细分（FAT/thin、arm64/x86_64、executable/dylib），
                // 一次给全，AI 不再需要另猜/换工具。
                if type == "macho-binary", let m = FileExecTool.machoInfo(head) {
                    result["macho"] = m
                }
            }
            return result
        case "analyze":
            guard fm.fileExists(atPath: norm) else { throw MCPError.failed("file: no such file \(norm)") }
            // v3.7.7: 先 autoBind 改写为 Alpine 可见路径(/ios_*)，再 base64 传路径。
            // （直接用明文 iOS 路径会被 autoBind 改写；base64 保护仍防 shell 元字符注入，但改写须先发生）
            let boundPath = TrollRuntimeEngine.autoBind(norm)
            let pb = Data(boundPath.utf8).base64EncodedString()
            let out = TrollRuntimeEngine.exec("P=$(echo '\(pb)' | base64 -d); file \"$P\"; echo '--- strings (first 80) ---'; strings -a \"$P\" 2>/dev/null | head -80", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: inspect / analyze")
        }
    }

    /// 依据文件头魔数推断类型
    static func detectType(_ head: [UInt8]) -> String {
        if head.count >= 4 {
            let u = Array(head.prefix(4))
            let macho: [(UInt8, UInt8, UInt8, UInt8)] = [(0xFE,0xED,0xFA,0xCE),(0xFE,0xED,0xFA,0xCF),(0xCE,0xFA,0xED,0xFE),(0xCF,0xFA,0xED,0xFE)]
            for m in macho where u == [m.0, m.1, m.2, m.3] { return "macho-binary" }
            if u[0] == 0x50 && u[1] == 0x4B { return "zip/ipa" }
            if u[0] == 0x7F && u[1] == 0x45 && u[2] == 0x4C && u[3] == 0x46 { return "elf-binary" }
        }
        let magic = String(decoding: head.prefix(15), as: UTF8.self)
        if magic.hasPrefix("SQLite format 3") { return "sqlite-db" }
        if magic.hasPrefix("fTyp") { return "font" }
        if head.count > 0, head.allSatisfy({ $0 == 10 || $0 == 13 || $0 == 9 || ($0 >= 32 && $0 < 127) }) { return "text" }
        return "binary"
    }

    /// v4.3.70: 解析 Mach-O 头，返回架构/类型细分（FAT/thin、arm64/x86_64、executable/dylib）。
    /// 修复实测痛点：旧版只给 "macho-binary"，AI 无法判断架构/是 App 还是 dylib，只能瞎猜。
    static func machoInfo(_ head: [UInt8]) -> [String: Any]? {
        guard head.count >= 32 else { return nil }
        let u32be = { (i: Int) -> UInt32 in
            UInt32(head[i]) << 24 | UInt32(head[i+1]) << 16 | UInt32(head[i+2]) << 8 | UInt32(head[i+3])
        }
        let u32le = { (i: Int) -> UInt32 in
            UInt32(head[i]) | UInt32(head[i+1]) << 8 | UInt32(head[i+2]) << 16 | UInt32(head[i+3]) << 24
        }
        let magic = Array(head.prefix(4))
        // FAT / universal：CA FE BA BE（大端）或 BE BA FE CA（字节序翻转）
        if magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA] {
            let n = Int(u32be(4))
            guard head.count >= 8 + n * 20 else { return ["fat": true, "archs": [], "filetype": "universal"] }
            var archs: [String] = []
            for i in 0..<min(n, 16) {
                archs.append(cpuName(u32be(8 + i * 20)))
            }
            return ["fat": true, "archs": archs, "filetype": "universal (fat binary)"]
        }
        // thin：host 序（FE ED FA CE/CF）或翻转序（CE FA ED FE/CF FA ED FE）
        let beMagic = magic == [0xFE, 0xED, 0xFA, 0xCE] || magic == [0xFE, 0xED, 0xFA, 0xCF]
        let leMagic = magic == [0xCE, 0xFA, 0xED, 0xFE] || magic == [0xCF, 0xFA, 0xED, 0xFE]
        guard beMagic || leMagic else { return nil }
        let is64 = magic == [0xFE, 0xED, 0xFA, 0xCF] || magic == [0xCF, 0xFA, 0xED, 0xFE]
        let read = beMagic ? u32be : u32le
        let cputype = read(4)
        let filetype = read(12)
        return ["fat": false, "archs": [cpuName(cputype)], "bits": is64 ? 64 : 32,
                "filetype": filetypeName(filetype), "filetype_raw": filetype]
    }

    /// CPU type → 可读名（arm64_32=0x0200000C 需特判；去掉 ABI64/ABI64_32 高位再映射基本名）
    private static func cpuName(_ cputype: UInt32) -> String {
        if cputype == 0x0200_000C { return "arm64_32" }
        let abi64 = cputype & 0x0100_0000
        let base = cputype & 0x00FF_FFFF
        switch base {
        case 7:  return abi64 != 0 ? "x86_64" : "i386"
        case 12: return abi64 != 0 ? "arm64" : "arm"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"   // 不会被走到（abi 位已剥离），保留兜底
        default: return String(format: "cpu_0x%X", cputype)
        }
    }

    /// Mach-O filetype → 可读名
    private static func filetypeName(_ t: UInt32) -> String {
        switch t {
        case 0x1: return "object (.o)"
        case 0x2: return "executable (app main binary)"
        case 0x6: return "dylib (dynamic library)"
        case 0x8: return "bundle"
        case 0x9: return "dylib stub"
        case 0xA: return "dSYM (debug symbols)"
        case 0xB: return "kext bundle"
        case 0xE: return "fileset"
        default: return String(format: "mh_0x%X", t)
        }
    }
}

/// 高层 SQLite 分析工具。自动 bind 直读 iOS .db 文件进 Alpine，跑 sqlite3。子命令 list / schema / query。
final class DbExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "db",
        summary: "SQLite analysis (run sqlite3 in the unified env). Subcommands: list / schema / query. list=table names; schema=CREATE statements; query=run SQL SELECT. REQUIRED: path; query needs sql. Use for: inspect/query .db files on iOS (WeChat/Alipay etc.); don't use this tool to alter schema/data.",
        parameters: [
            "command": "Subcommand (required): list / schema / query",
            "path": "iOS absolute db path (required, auto-bind Alpine reads directly)",
            "sql": "SQL for query (required when command=query)"
        ], verified: true, category: "data")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: list / schema / query")
        }
        guard let path = params["path"] as? String else {
            throw MCPError.invalidParams("path required")
        }
        let norm = ShellExecTool.normalizePath(path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: norm) else { throw MCPError.failed("db: no such file \(norm)") }
        switch command {
        case "list":
            let out = TrollRuntimeEngine.exec("sqlite3 '\(norm)' \".tables\"", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        case "schema":
            let out = TrollRuntimeEngine.exec("sqlite3 '\(norm)' \".schema\"", timeout: 60)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        case "query":
            guard let sql = params["sql"] as? String, !sql.isEmpty else {
                throw MCPError.invalidParams("sql required for query")
            }
            // v3.6.19h: 修复命令注入——原实现把 SQL 直接拼进 shell 双引号，单引号转义成 '"'"' 含双引号，
            // 在双引号上下文反破引号平衡，含 ;/$/` 等元字符的 SQL 可执行任意命令。改为 base64 编码 SQL
            // (仅 [A-Za-z0-9+/=] 安全字符)，Alpine 侧解码写临时文件，sqlite3 从 stdin 读，彻底绕开 shell 解析。
            let b64 = Data(sql.utf8).base64EncodedString()
            let out = TrollRuntimeEngine.exec("echo '\(b64)' | base64 -d > /tmp/_db_q.sql; sqlite3 -header -column '\(norm)' < /tmp/_db_q.sql", timeout: 90)
            return ["env": "alpine", "exit_code": Int(out.exitCode), "output": out.output]
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: list / schema / query")
        }
    }
}
