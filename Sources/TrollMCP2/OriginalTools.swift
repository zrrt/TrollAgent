import Foundation
import UserNotifications

// MARK: - 自动化任务存储 (automation.* / gateway.cron_* 共用）

final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()
    let center = UNUserNotificationCenter.current()

    struct Task: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var name: String
        var schedule: String = ""       // cron 表达式或描述
        var action: String = ""         // 动作描述
        var kind: String = "reminder"   // reminder | call | cron
        var title: String = ""
        var body: String = ""
        var number: String = ""
        var delay: Int = 0
        var interval: Int = 0
        var enabled: Bool = true
        var lastRun: Date?
        var createdAt: Date = Date()
    }

    @Published var tasks: [Task] = []
    private let key = "trollmcp2.automation_tasks"

    init() { load(); requestAuth() }

    func requestAuth() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Task].self, from: data) else { return }
        tasks = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ task: Task) {
        tasks.append(task)
        save()
        schedule(task)
    }

    func update(_ task: Task) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        }
        save()
        schedule(task)
    }

    func remove(_ task: Task) {
        tasks.removeAll { $0.id == task.id }
        save()
        cancel(task)
    }

    func setEnabled(_ task: Task, enabled: Bool) {
        var t = task
        t.enabled = enabled
        update(t)
        AuditLog.shared.log("automation.set_enabled", detail: "\(task.name) \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - 真实调度

    private func trigger(for task: Task) -> UNNotificationTrigger? {
        if task.kind == "cron", task.interval > 0 {
            return UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(task.interval), repeats: true)
        }
        let secs = max(TimeInterval(task.delay), 1)
        return UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
    }

    private func schedule(_ task: Task) {
        guard task.enabled else { cancel(task); return }
        let content = UNMutableNotificationContent()
        switch task.kind {
        case "call":
            content.title = L10n.t("i18n_891")
            content.body = task.number.isEmpty ? (task.body.isEmpty ? task.name : task.body) : L10n.t("i18n_892", task.number)
        default:
            content.title = task.title.isEmpty ? (task.action.isEmpty ? task.name : task.action) : task.title
            content.body = task.body.isEmpty ? task.action : task.body
        }
        content.sound = .default
        content.userInfo = ["automationId": task.id.uuidString, "kind": task.kind]
        let req = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger(for: task))
        center.add(req) { err in
            if let err = err {
                AuditLog.shared.log("automation", detail: L10n.t("i18n_893", err.localizedDescription), level: .warning)
            }
        }
        AuditLog.shared.log("automation.schedule", detail: "\(task.name) kind=\(task.kind)")
    }

    private func cancel(_ task: Task) {
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
    }

    @discardableResult
    func run(name: String) -> Bool {
        guard var t = tasks.first(where: { $0.name == name }) else { return false }
        guard t.enabled else {
            AuditLog.shared.log("automation", detail: L10n.t("i18n_894", name), level: .warning)
            return false
        }
        let content = UNMutableNotificationContent()
        switch t.kind {
        case "call":
            content.title = L10n.t("i18n_891")
            content.body = t.number.isEmpty ? t.name : L10n.t("i18n_895", t.number)
        default:
            content.title = t.title.isEmpty ? (t.action.isEmpty ? t.name : t.action) : t.title
            content.body = t.body.isEmpty ? t.action : t.body
        }
        content.sound = .default
        content.userInfo = ["automationId": t.id.uuidString, "kind": t.kind, "manual": true]
        let req = UNNotificationRequest(identifier: t.id.uuidString + "-run-" + UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
        t.lastRun = Date()
        update(t)
        AuditLog.shared.log("automation.run_now", detail: name)
        return true
    }

    /// 取消指定通知请求 (automation.cancel）
    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    var history: [AuditLog.Entry] {
        AuditLog.shared.entries.filter { $0.category.hasPrefix("automation") || $0.category.hasPrefix("gateway.cron") }
    }
}

/// 从 cron 表达式 "*/N * * * *" 解析秒间隔 (其余返回 nil）
func cronSeconds(_ expr: String) -> Int? {
    let parts = expr.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
    guard parts.count == 5 else { return nil }
    if parts[0].hasPrefix("*/") {
        return Int(parts[0].dropFirst(2)).map { $0 * 60 }
    }
    if let m = Int(parts[0]) { return m * 60 }
    return nil
}

// MARK: - 原版缺失工具：injection.remove

final class InjectionRemoveTool: MCPTool {
    let definition = ToolDefinition(name: "injection.remove", summary: "Completely remove all injection from an app (delete dylib files + disable). Use for: totally clean up injection, restore app to original state. Don't use for: just disable injection temporarily (use injection.disable), uninstall app (use app.uninstall). Example: user says 'completely remove 小红书 injection including files' → remove injection.",
        parameters: ["bundle_id": "Target App bundle ID"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String else { throw MCPError.invalidParams("bundle_id required") }
        let result = try InjectionManager.shared.disable(bundleId: bid)
        // 尝试删除拷贝进 App 包的 dylib
        var removedFile = false
        if let app = AppCatalog.find(bid) {
            let dylib = URL(fileURLWithPath: app.path).appendingPathComponent("ControlAgent.dylib")
            if FileManager.default.fileExists(atPath: dylib.path) {
                try? FileManager.default.removeItem(at: dylib)
                removedFile = true
            }
        }
        AuditLog.shared.log("injection.remove", detail: "\(bid) dylib deleted=\(removedFile)")
        var merged = result
        merged["dylib_removed"] = removedFile
        return merged
    }
}

// MARK: - 原版缺失工具：container.delete


// MARK: - 原版缺失工具：gateway.*

// MARK: - 原版缺失工具：automation.*


// MARK: - 原版缺失工具：model.*

final class ModelAuthenticationTool: MCPTool {
    let definition = ToolDefinition(name: "model.authentication", summary: "Check AI model authentication status. Use for: verify API key is configured correctly. Don't use for: switch model (use model.selectedProfileID), update model settings (use model.update). Example: user says 'check if model API key is correct' → check auth.",
        parameters: [:])
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let config = ModelStore.shared.defaultConfig else {
            throw MCPError.failed("no model configured")
        }
        let masked: String
        if config.apiKey.count > 8 {
            masked = String(config.apiKey.prefix(4)) + "****" + String(config.apiKey.suffix(4))
        } else {
            masked = config.apiKey.isEmpty ? "(empty)" : "****"
        }
        return [
            "authMethod": config.authMethod,
            "apiKeyMasked": masked,
            "hasKey": !config.apiKey.isEmpty,
            "provider": config.provider
        ]
    }
}

final class ModelSelectedProfileIDTool: MCPTool {
    let definition = ToolDefinition(name: "model.selectedProfileID", summary: "Get or switch the current AI model. Use for: change which LLM model you're using. Don't use for: list all models (use model.config), edit model settings (use model.update). Example: user says 'switch model to deepseek' → switch model.",
        parameters: ["profile_id": "Model profile UUID (optional, to switch)"], verified: true, category: "system")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let store = ModelStore.shared
        if let newId = params["profile_id"] as? String,
           let target = store.configs.first(where: { $0.id.uuidString == newId }) {
            var updated = target
            updated.isDefault = true
            store.update(updated)
            AuditLog.shared.log("model.selectedProfileID", detail: L10n.t("i18n_896", target.name))
            return ["selected": target.name, "id": newId]
        }
        guard let current = store.defaultConfig else {
            throw MCPError.failed("no model configured")
        }
        return ["selected": current.name, "id": current.id.uuidString]
    }
}
