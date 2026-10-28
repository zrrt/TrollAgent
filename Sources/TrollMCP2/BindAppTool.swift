import Foundation

// MARK: - v4.1.0/v4.2.0 按需选择性绑定 App 数据容器
/// 把指定 App 的数据容器绑进 Alpine（/ios_data_<app>），让 Alpine python3/sqlite3/strings
/// 直接读写该 App 的 Documents / Library（内购票据、购买状态等）。
/// 与整棵 /var/mobile 绑定不同：只绑目标 App 容器路径、绝不绑自身容器(rootfs)，
/// 因此无自引用 → 无内核污染 → 不崩溃。
///
/// v4.2.0 双模式：
/// - bind_app（只读）：分析用。AI 可读 App 数据容器，但物理上写不进去 → 永不可能写坏目标 App。
/// - bind_app_write（可写+备份）：就地修改用。绑定前先把该 App 的 Documents+Library 备份到
///   工作区 backups/，可写后可改数据（改状态/数值），改坏了可从备份还原。

/// 只读模式：分析 App 数据容器（安全，写不进去）
final class BindAppTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app",
        summary: "Read-only bind of an app's data container → /ios_data_<app>. Param: bundle_id. Lets python3/sqlite3/strings read the app's Documents/Library (IAP receipts/purchase state/exported files) in the unified env; readable but not writable, can never corrupt the target app. To modify data in place use bind_app_write (writable + auto-backup); to read the app Bundle use /ios_containers.",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let r = TrollRuntimeEngine.bindAppContainer(bundleId: bundleId, readOnly: true)
        guard r.ok, let m = r.mountPath, let h = r.hostPath else {
            throw MCPError.failed("bind_app: \(r.error ?? "unknown error")")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "read_only",
            "mount_path": m,
            "host_path": h,
            "hint": "Read-only mount. In the unified env shell.exec / python3, use \(m) to read this app's data (e.g. \(m)/Documents, \(m)/Library/Preferences). Read-only, can't write into it.",
        ]
    }
}

/// 可写模式：就地修改 App 数据容器（绑定前强制备份到工作区）
final class BindAppWriteTool: MCPTool {
    let definition = ToolDefinition(
        name: "bind_app_write",
        summary: "Writable on-demand bind of an app's data container → /ios_data_<app>, for modifying the app's data in place (IAP state/values/settings/receipts). Before binding, Documents+Library are auto-backed up to workspace backups/; restore from backup if broken. Risk: corrupting the app's data container may stop that app from launching (only affects the target app, not the AI env). NEVER bind a container containing the alpine rootfs (self-reference crash source). For read-only analysis use bind_app. Example: bind_app_write bundle_id:com.appstudio.Jinx → /ios_data_com_appstudio_jinx + backup path.",
        parameters: [
            "bundle_id": "App bundle ID (required)"
        ], verified: true, category: "filesystem")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        let r = TrollRuntimeEngine.bindAppContainer(bundleId: bundleId, readOnly: false)
        guard r.ok, let m = r.mountPath, let h = r.hostPath else {
            throw MCPError.failed("bind_app_write: \(r.error ?? "unknown error")")
        }
        return [
            "ok": true,
            "bundle_id": bundleId,
            "mode": "read_write",
            "mount_path": m,
            "host_path": h,
            "backup_path": r.backupPath ?? "",
            "warning": "Writable: corrupting this app's data container may stop the app from launching (doesn't affect the AI env). Confirm backup before changes (see backup_path), restore from backup if broken.",
        ]
    }
}
