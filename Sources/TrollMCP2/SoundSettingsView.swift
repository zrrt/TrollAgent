import SwiftUI

// v7.4.0-fix73d：提示音设置页——AI 完成任务提示音开关 + 8 种系统音可选（点选即试听）
// 入口：设置 → 提示音（Toggle 开关 + NavigationLink 进本页，复用 SettingsView 的
// "开关优先"模式：Toggle 项同时带 destination 时用 NavigationLink 包 Toggle）
// v7.4.0-fix73d-音色文件版：8 种音为 bundle 内置 CAF（iOS 系统音效提取），
// 前台 AVAudioPlayer 与后台通知声音共用同一文件，前后台音色一致
struct SoundSettingsView: View {
    @AppStorage("taskNotify.soundEnabled") private var soundEnabled = true
    @AppStorage("taskNotify.soundIndex") private var soundIndex = 0

    var body: some View {
        CompatNav {
            List {
                Section {
                    Toggle(isOn: $soundEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("任务完成提示音")
                                .font(.body)
                            Text("AI 完成回复时响提示音（后台/锁屏由系统通知声音负责，同一音色）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accentColor(.tmCyan)
                }
                Section(header: Text("提示音选择"),
                        footer: Text("共 \(TaskNotify.soundOptions.count) 种系统提示音，点选即试听；前台与后台通知使用同一音色。")) {
                    ForEach(TaskNotify.soundOptions.indices, id: \.self) { idx in
                        let opt = TaskNotify.soundOptions[idx]
                        Button(action: {
                            soundIndex = idx
                            // 点选即试听
                            TaskNotify.shared.previewSound(idx)
                        }) {
                            HStack {
                                Image(systemName: "music.note")
                                    .font(.system(size: 14))
                                    .foregroundColor(.tmCyan)
                                    .frame(width: 24)
                                Text(opt.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if soundIndex == idx {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .disabled(!soundEnabled)
                        .opacity(soundEnabled ? 1 : 0.45)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("提示音")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
