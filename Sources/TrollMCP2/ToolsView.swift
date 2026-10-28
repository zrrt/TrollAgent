import SwiftUI

struct ToolsView: View {
    private let defs = ToolRegistry.shared.definitions

    private var grouped: [(String, [ToolDefinition])] {
        let categories: [(String, String, [String])] = [
            (L10n.t("i18n_276"), "folder", ["artifact.read_text", "artifact.write_text", "artifact.list"]),
            (L10n.t("i18n_277"), "syringe", ["injection.enable", "injection.disable", "injection.mem", "injection.restore", "rescue.scan", "rescue.recover_all", "rescue.cleanup", "injection.status", "injection.inspect", "injection.list", "container.write_text"]),
            (L10n.t("i18n_278"), "scope", ["probe.inspect", "hook.apply", "device.fake", "device.restore"]),
            ("Gateway", "network", ["gateway.status", "gateway.connect", "gateway.node_invoke", "cron.fire"]),
            (L10n.t("i18n_1193"), "bolt", ["automation.run", "automation.list", "automation.stop", "automation.status"]),
            (L10n.t("i18n_341"), "gearshape.2", ["calendar.list", "reminder.create", "location.get"]),
            (L10n.t("i18n_280"), "hammer", ["project.generate_tweak", "model.config", "ping", "device.info"])
        ]
        let map = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0) })
        return categories.compactMap { cat, _, names in
            let items = names.compactMap { map[$0] }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        CompatNav {
            List {
                ForEach(grouped, id: \.0) { section in
                    Section(header: SettingSectionHeader(title: section.0)) {
                        ForEach(section.1, id: \.name) { def in
                            VStack(alignment: .leading, spacing: 4) {
                                // v2.9.252: 真机实测通过的工具显示 ✅已检验(绿色),未验证保持原色
                                Text(def.verifiedMark + def.name)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(def.verified ? Color(red: 0.25, green: 0.65, blue: 0.35) : .primary)
                                Text(def.summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_1194", defs.count))
        }
        .navigationViewStyle(.stack)
    }
}
