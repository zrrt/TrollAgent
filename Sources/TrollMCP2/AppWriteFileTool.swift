import Foundation

// MARK: - v4.3.3 原生可写通道（绕开 bind 只读挂载）
/// 背景：bind_app_write 的"可写"绑定实测写不进（bind mount 对 iOS 真实文件固定只读，
/// 即使 cish_bind_mount 传 read_only=0，写仍报 Errno 30 Read-only file system —— guest 内核
/// 无法在内核层修复）。
/// 根治：写 App 数据容器【不走 guest 挂载】，直接用 iOS 原生 FileManager 写（TrollStore root
/// 权限可写任意容器路径）。本工具即该原生写通道：解析 bundle_id 容器 → 写容器内文件，写前
/// 自动把目标文件备份到 Workspace/backups/，改坏可还原。与 bind_app/bind_app_write(只读) 配套。
final class AppWriteFileTool: MCPTool {
    let definition = ToolDefinition(
        name: "app_write_file",
        summary: "Native direct write to a file inside an app's data container (iOS write channel, not limited by bind's read-only mount). Params: bundle_id + rel_path (container-relative path, e.g. Library/Preferences/x.plist) + content_b64 (base64 full file content). Auto-backup to Workspace/backups/ before writing. Use for modifying IAP/settings/receipt data in place; read via bind_app, actually-writable file changes via this tool.",
        parameters: [
            "bundle_id": "App bundle ID (required)",
            "rel_path": "Container-relative path, e.g. Library/Preferences/x.plist (required, no absolute paths or ../)",
            "content_b64": "Full file content to write, base64-encoded (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let relPath = params["rel_path"] as? String, !relPath.isEmpty else {
            throw MCPError.invalidParams("rel_path required")
        }
        guard let contentB64 = params["content_b64"] as? String, !contentB64.isEmpty else {
            throw MCPError.invalidParams("content_b64 required")
        }
        // 路径安全校验：相对路径，禁止绝对路径与父目录逃逸
        if relPath.hasPrefix("/") {
            throw MCPError.invalidParams("rel_path must be a container-relative path, not starting with /")
        }
        let parts = relPath.split(separator: "/").map(String.init)
        if parts.contains("..") || parts.contains(".") {
            throw MCPError.invalidParams("rel_path must not contain .. / . segments")
        }
        // 解析 App 数据容器
        guard let app = AppCatalog.list().first(where: { $0.bundleId == bundleId }),
              let cp = AppCatalog.lookupContainer(bundleId: app.bundleId), !cp.isEmpty else {
            throw MCPError.failed("app or data container not found: \(bundleId)")
        }
        // 铁律：绝不写自身容器（Documents/alpine-rootfs 是 rootfs，写坏即毁 AI 环境）
        if FileManager.default.fileExists(atPath: cp + "/Documents/alpine-rootfs") {
            throw MCPError.failed("refusing to write own rootfs host: \(cp)")
        }
        let host = (cp as NSString).appendingPathComponent(relPath)
        // base64 解码
        guard let data = Data(base64Encoded: contentB64) else {
            throw MCPError.invalidParams("content_b64 isn't valid base64")
        }
        // 写前备份目标文件
        let backupPath = backupFile(host, app: app.bundleId)
        let fm = FileManager.default
        let parent = (host as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
            catch { throw MCPError.failed("cannot create parent dir \(parent): \(error.localizedDescription)") }
        }
        do {
            try data.write(to: URL(fileURLWithPath: host), options: .atomic)
        } catch {
            throw MCPError.failed("write failed: \(error.localizedDescription)")
        }
        let sz = (try? fm.attributesOfItem(atPath: host)[.size] as? Int) ?? data.count
        return [
            "ok": true,
            "bundle_id": bundleId,
            "host_path": host,
            "backup_path": backupPath ?? "",
            "bytes_written": sz,
            "warning": "Written natively (not an Alpine mount). Backup at \(backupPath ?? "(none)"), restore from backup if broken.",
        ]
    }

    /// 写前备份目标文件到 Workspace/backups/<app>_<ts>/<relPath>
    private func backupFile(_ host: String, app: String) -> String? {
        let fm = FileManager.default
        let backupRoot = "/var/mobile/Documents/Workspace/backups"
        let ts = Int(Date().timeIntervalSince1970)
        let dest = "\(backupRoot)/\(app)_\(ts)"
        guard (try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)) != nil else { return nil }
        let rel = host.replacingOccurrences(of: "/var/mobile/Containers/Data/Application/", with: "")
        let target = (dest as NSString).appendingPathComponent(rel.replacingOccurrences(of: "/", with: "_"))
        do {
            try fm.copyItem(atPath: host, toPath: target)
        } catch { return nil }
        return target
    }
}
