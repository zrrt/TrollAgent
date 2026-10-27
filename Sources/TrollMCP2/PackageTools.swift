// PackageTool：解包查看别人的包（deb / ipa）— v3.3.4
// 子命令：inspect（列结构）/ unpack（解包到工作区）
// deb = ar 归档（control.tar.* + data.tar.*）；ipa = zip。
// 压缩支持：gzip（zlib）、xz/lzma（Compression）；zstd 暂不支持（提示电脑端处理）。

import Foundation
import Compression
import zlib
import ZIPFoundation

final class PackageTool: MCPTool {
    let definition = ToolDefinition(
        name: "package",
        summary: "Inspect & unpack .deb/.ipa packages. Commands: inspect (list members: deb→ar entries+control text+data.tar list; ipa→zip entries+main Info.plist path) / unpack (extract to workspace dir, read via artifact). Params: command, path, dest. Formats: deb=ar+tar(gz/lzma; Apple LZMA only .lzma-alone); ipa=zip(stored/deflate). NOT supported: xz container & zstd/bzip2 data.tar → tell user unpack on PC with 7-Zip/bsdtar. Use for: see inside deb/ipa, list structure, read control/info, extract files. Required: command+path.",
        parameters: [
            "command": "inspect / unpack",
            "path": "absolute path to .deb or .ipa",
            "dest": "required for unpack — output directory (will be created)"
        ],
        verified: false, category: "package", prerequisites: [
            "path must be a real file (locate with shell.exec); ensure enough free space for the extracted size; after unpack read inner files with artifact read"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("package: missing command (inspect / unpack)")
        }
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("package: missing path")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.classified("package: file not found: \(path)",
                                      code: "NOT_FOUND", reason: "path",
                                      nextStep: "use shell.exec / shell ls to locate the file first")
        }

        switch command {
        case "inspect": return try inspect(path)
        case "unpack":
            guard let dest = params["dest"] as? String, !dest.isEmpty else {
                throw MCPError.invalidParams("package unpack: missing dest (output directory)")
            }
            return try unpack(path, dest: dest)
        default:
            throw MCPError.invalidParams("package: unknown command '\(command)' (inspect / unpack)")
        }
    }

    // MARK: - Inspect

    private func inspect(_ path: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            return try inspectDeb(data, path: path)
        }
        // zip magic: PK\x03\x04 (local) or PK\x05\x06 (empty)
        if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            return try inspectIpa(path)
        }
        throw MCPError.classified("package: unsupported format (not deb/ipa) — magic mismatch",
                                  code: "BAD_FORMAT", reason: "format",
                                  nextStep: "only .deb (ar archive) and .ipa (zip) supported")
    }

    private func inspectDeb(_ data: Data, path: String) throws -> [String: Any] {
        var offset = 8 // skip "!<arch>\n"
        var members: [[String: Any]] = []
        var dataTarName: String?
        var controlText: String?
        var dataFileList: [String] = []
        var dataCompressionNote: String?

        while offset + 60 <= data.count {
            let hdr = safeSlice(data, offset..<offset + 60)
            guard hdr.count >= 60 else { break }
            let name = String(data: safeSlice(hdr, 0..<16), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sizeStr = String(data: safeSlice(hdr, 48..<58), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let size = Int(sizeStr) ?? 0
            let contentStart = offset + 60
            // v3.6.16: 防御——ar size 异常(0/超界)时跳过该成员并前移, 避免 subdata 越界
            guard size > 0, contentStart <= data.count else {
                ShellDiag.log("package inspectDeb: member '\(name)' size=\(size) abnormal → skipped (offset=\(offset), total=\(data.count))")
                offset = contentStart
                continue
            }
            // v3.6.19e: 用 safeSlice 切（恶意 ar size 使 contentStart+size 溢出为负时也不 trap，safeSlice 会钳到安全区间）
            let content = safeSlice(data, contentStart..<contentStart + size)

            // skip symbol table members
            if name != "/" && name != "//" && !name.hasSuffix("/") {
                members.append([
                    "name": name,
                    "size": size,
                    "type": name.hasPrefix("data.tar") ? "data archive" : (name.hasPrefix("control.tar") ? "control archive" : "member")
                ])
                ShellDiag.log("package inspectDeb member: \(name) size=\(size)")
                if name.hasPrefix("data.tar") {
                    dataTarName = name
                    // v3.6.19g: xz container 无法解析(Apple LZMA 仅 .lzma-alone)，标注提示，避免 data_file_count=0 误导
                    if content.count >= 6 && content[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
                        dataCompressionNote = "data.tar is an xz container — iOS Apple LZMA only supports .lzma-alone, can't parse the file list; unpack it with 7-Zip/bsdtar"
                        ShellDiag.log("package inspectDeb: data.tar=\(name) xz container — can't parse, tell the user to handle it on a PC")
                    } else {
                        dataFileList = tarFileList(content) ?? []
                        ShellDiag.log("package inspectDeb data.tar=\(name) files=\(dataFileList.count)")
                    }
                }
                if name.hasPrefix("control.tar") {
                    controlText = controlFromTar(content)
                    ShellDiag.log("package inspectDeb control.tar=\(name) textLen=\((controlText ?? "").count)")
                }
            }
            offset = contentStart + size + (size % 2) // ar aligns to even
        }

        return [
            "format": "deb (ar archive)",
            "path": path,
            "file_size": data.count,
            "members": members,
            "control": controlText ?? "(no control)",
            "data_archive": dataTarName ?? "(none)",
            "data_file_count": dataFileList.count,
            "data_compression_note": dataCompressionNote ?? "(none)",
            "data_files_sample": Array(dataFileList.prefix(80)),
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then artifact inner files"
        ]
    }

    private func inspectIpa(_ path: String) throws -> [String: Any] {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
            throw MCPError.failed("package: cannot open ipa as zip: \(path)")
        }
        let names = archive.map { $0.path }
        var payloadInfoPath: String?
        if let p = names.first(where: { $0.hasSuffix("/Info.plist") && $0.hasPrefix("Payload/") }) {
            payloadInfoPath = p
        }
        var appNames = Set<String>()
        for n in names where n.hasPrefix("Payload/") {
            let parts = n.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 { appNames.insert(String(parts[1])) }
        }
        return [
            "format": "ipa (zip)",
            "path": path,
            "file_size": (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0,
            "entry_count": names.count,
            "entries_sample": Array(names.prefix(120)),
            "app_names": Array(appNames),
            "main_info_plist": payloadInfoPath ?? "(none)",
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then artifact Payload/<App>.app/Info.plist"
        ]
    }

    // MARK: - Unpack

    private func unpack(_ path: String, dest: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let destURL = URL(fileURLWithPath: dest).standardizedFileURL

        var extracted = 0
        var list: [String] = []
        var format = "unknown"

        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            format = "deb"
            // unpack data.tar.* fully; control.tar content too (control file readable)
            var offset = 8
            while offset + 60 <= data.count {
                let hdr = data[offset..<offset + 60]
                let name = String(data: hdr[0..<16], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sizeStr = String(data: hdr[48..<58], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                let size = Int(sizeStr) ?? 0
                let contentStart = offset + 60
                guard contentStart + size <= data.count else { break }
                let content = data.subdata(in: contentStart..<contentStart + size)
                if name != "/" && name != "//" && !name.hasSuffix("/") {
                    if name.hasPrefix("data.tar") {
                        let n = try extractTar(content, into: destURL)
                        extracted += n
                        list.append(contentsOf: tarFileList(content) ?? [])
                    } else if name.hasPrefix("control.tar") {
                        let n = try extractTar(content, into: destURL.appendingPathComponent("_control"))
                        extracted += n
                    }
                }
                offset = contentStart + size + (size % 2)
            }
        } else if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            format = "ipa"
            guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
                throw MCPError.failed("package: cannot open ipa as zip: \(path)")
            }
            var count = 0
            for entry in archive {
                do {
                    _ = try archive.extract(entry, to: destURL.appendingPathComponent(entry.path))
                    count += 1
                } catch { /* skip unreadable entry */ }
            }
            extracted = count
            list = archive.map { $0.path }
        } else {
            throw MCPError.classified("package: unsupported format (not deb/ipa)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "only .deb (ar) and .ipa (zip) supported")
        }

        return [
            "command": "unpack",
            "format": format,
            "dest": destURL.path,
            "extracted_count": extracted,
            "top_files_sample": Array(list.prefix(100)),
            "next": "read inner files with artifact read"
        ]
    }

    // MARK: - tar

    /// List file paths inside a possibly-compressed tar (data.tar.gz/.xz/.lzma/plain).
    private func tarFileList(_ raw: Data) -> [String]? {
        guard let tar = decompressTar(raw) else { return nil }
        return parseTar(tar).map { $0.name }
    }

    private func controlFromTar(_ raw: Data) -> String? {
        guard let tar = decompressTar(raw) else { return nil }
        for (name, data) in parseTar(tar) where name == "./control" || name == "control" {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
        return nil
    }

    private func decompressTar(_ raw: Data) -> Data? {
        // detect by magic
        if raw.count >= 2 && raw[0] == 0x1F && raw[1] == 0x8B { return gunzip(raw) }       // gzip
        // xz container magic \xFD7zXZ\x00：Apple COMPRESSION_LZMA 只支持 .lzma-alone(13字节头)，不支持 xz 容器，
        // 直接喂 decodeLZMA 必失败(实测解不出)。v3.6.19g 改为明确不支持，调用方(extractTar/inspectDeb)给出清晰提示。
        if raw.count >= 6 && raw[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return nil }
        if raw.count >= 3 && raw[0] == 0x5D && raw[1] == 0x00 && raw[2] == 0x00 { return lzmaAloneDecode(raw) }   // .lzma
        if raw.count >= 4 && raw[0..<4].elementsEqual(Array("28 BZ".utf8)) { return nil } // bzip2 unsupported
        if raw.count >= 4 && raw[0..<4].elementsEqual(Array("\u{28}\u{B5}\u{2F}\u{FD}".utf8)) { return nil } // zstd
        if raw.count >= 512 { return raw } // plain tar
        return nil
    }

    private func gunzip(_ data: Data) -> Data? {
        // skip 10-byte gzip header (+ optional extra fields)
        var start = 10
        if data.count > start + 2 && (data[start] & 0x04) != 0 { // FEXTRA
            let xlen = Int(data[start + 1]) | (Int(data[start + 2]) << 8)
            start += 2 + xlen
        }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard start < data.count, let base = src.baseAddress else { return nil }
            let srcPtr = base.advanced(by: start)
            let srcLen = data.count - start
            var out = Data()
            let chunk = 64 * 1024
            var dst = [UInt8](repeating: 0, count: chunk)
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr.bindMemory(to: UInt8.self, capacity: srcLen))
            stream.avail_in = UInt32(srcLen)
            let ok = inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard ok == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            while stream.avail_in > 0 || stream.avail_out == 0 {
                stream.next_out = dst.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress }
                stream.avail_out = UInt32(chunk)
                let r = inflate(&stream, Z_NO_FLUSH)
                if r == Z_STREAM_END {
                    out.append(dst, count: chunk - Int(stream.avail_out))
                    break
                } else if r == Z_OK {
                    out.append(dst, count: chunk - Int(stream.avail_out))
                } else {
                    return nil
                }
            }
            return out
        }
    }

    /// 用 compression_decode_buffer 单次解压（LZMA/xz），容量不足时倍增重试。
    /// 绕开 compression_stream 结构体构造的 Swift 兼容坑 (CI 实测 2026-09-24）。
    private func decodeLZMA(_ data: Data, skipHeader: Int) -> Data? {
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard skipHeader < data.count, let base = src.baseAddress else { return nil }
            let srcPtr = base.advanced(by: skipHeader).bindMemory(to: UInt8.self, capacity: data.count - skipHeader)
            let srcLen = data.count - skipHeader
            let scratchSize = compression_decode_scratch_buffer_size(COMPRESSION_LZMA)
            // v3.6.19e: 防崩溃——scratch 大小为 0/异常时直接返回 nil，避免空 scratch 传给压缩 API
            guard scratchSize > 0, scratchSize < (1 << 20) else { return nil }
            var scratch = [UInt8](repeating: 0, count: scratchSize)
            var capacity = max(64 * 1024, srcLen * 4)
            while capacity < 512 * 1024 * 1024 {
                var dst = [UInt8](repeating: 0, count: capacity)
                let n = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    compression_decode_buffer(dstRaw.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              srcPtr, srcLen,
                                              &scratch, COMPRESSION_LZMA)
                }
                if n > 0 {
                    return Data(dst[0..<n])
                }
                // 容量不够时（0 返回且数据非空）翻倍重试；容量过大仍失败则放弃，防 capacity 溢出
                if capacity >= (512 * 1024 * 1024) / 2 { return nil }
                capacity *= 2
            }
            return nil
        }
    }

    private func lzmaAloneDecode(_ data: Data) -> Data? {
        // .lzma alone: 13-byte header then LZMA stream
        return decodeLZMA(data, skipHeader: 13)
    }

    private func parseTar(_ data: Data) -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        var offset = 0
        var longName: String?
        while offset + 512 <= data.count {
            let block = safeSlice(data, offset..<offset + 512)
            guard block.count >= 512 else { break }
            if block.allSatisfy({ $0 == 0 }) { break }
            var name = String(data: safeSlice(block, 0..<100), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            if name.isEmpty { offset += 512; continue }
            let sizeStr = String(data: safeSlice(block, 124..<136), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0"
            let size = Int(sizeStr, radix: 8) ?? 0
            let typeByte = safeByte(block, 156) ?? 0
            let type = typeByte == 0 ? "0" : String(UnicodeScalar(typeByte))
            let linkName = String(data: safeSlice(block, 157..<257), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            let contentStart = offset + 512
            let contentEnd = min(contentStart + size, data.count)
            guard contentStart <= contentEnd else { break }
            let content = data.subdata(in: contentStart..<contentEnd)

            if type == "L" { // GNU longname
                longName = String(data: content, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            } else {
                let finalName = longName ?? name
                longName = nil
                if type == "0" || type == "\u{0}" || type == "" {
                    out.append((finalName, content))
                }
            }
            let aligned = contentStart + size + ((512 - (size % 512)) % 512)
            if aligned <= offset { break } // 防死循环
            offset = aligned
        }
        return out
    }

    /// 越界安全切片：永远不 trap（返回实际可读部分，越界处截断为空）。
    private func safeSlice(_ data: Data, _ range: Range<Int>) -> Data {
        let lo = Swift.max(0, Swift.min(range.lowerBound, data.count))
        let hi = Swift.max(lo, Swift.min(range.upperBound, data.count))
        return data.subdata(in: lo..<hi)
    }

    /// 越界安全单字节读取。
    private func safeByte(_ data: Data, _ i: Int) -> UInt8? {
        guard i >= 0 && i < data.count else { return nil }
        return data[i]
    }

    /// Extract a (possibly compressed) tar into dest, path-traversal safe. Returns file count.
    private func extractTar(_ raw: Data, into destURL: URL) throws -> Int {
        guard let tar = decompressTar(raw) else {
            // v3.6.19g: xz container 明确报错(Apple LZMA 仅 .lzma-alone)，避免静默解不出
            if raw.count >= 6 && raw[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
                throw MCPError.classified("package: data.tar uses xz container — iOS Apple LZMA only supports .lzma-alone, xz not supported. unpack on PC with 7-Zip / bsdtar",
                                          code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                          nextStep: "unpack on PC with 7-Zip / bsdtar, or re-pack data.tar as gzip")
            }
            // detect zstd/bz2 to give a precise message
            if raw.count >= 4 && raw[0..<4].elementsEqual(Array("\u{28}\u{B5}\u{2F}\u{FD}".utf8)) {
                throw MCPError.classified("package: data.tar uses zstd compression — not supported on iOS yet",
                                          code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                          nextStep: "unpack on PC with 7-Zip / bsdtar, or ask to add zstd support")
            }
            if raw.count >= 4 && raw[0..<4].elementsEqual(Array("28 BZ".utf8)) {
                throw MCPError.classified("package: data.tar uses bzip2 — not supported on iOS",
                                          code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                          nextStep: "unpack on PC with 7-Zip")
            }
            throw MCPError.failed("package: cannot decompress data.tar")
        }
        let fm = FileManager.default
        var count = 0
        for (name, content) in parseTar(tar) {
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            guard !clean.isEmpty else { continue }
            let target = destURL.appendingPathComponent(clean).standardizedFileURL
            guard target.path.hasPrefix(destURL.path + "/") else { continue } // zip-slip guard
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
            count += 1
        }
        return count
    }
}
