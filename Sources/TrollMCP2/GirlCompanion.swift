import SwiftUI
import UIKit
import Combine

// MARK: - 可爱助手 · 状态

/// v4.5.0：可爱助手全局开关 + 角色（设置里可选开/关、切换角色，UserDefaults 持久化）
/// 角色：小萝莉(girl_*) / 兔娘(rabit_*) / 猫娘(cat_*)
enum GirlCharacter: String, CaseIterable, Identifiable {
    case loli
    case rabit
    case cat
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .loli: return L10n.t("i18n_837")
        case .rabit: return L10n.t("i18n_838")
        case .cat: return L10n.t("i18n_839")
        }
    }
    var iconPrefix: String {
        switch self {
        case .loli: return "girl"
        case .rabit: return "rabit"
        case .cat: return "cat"
        }
    }
}

extension GirlCharacter {
    /// v6.0.12：从 UserDefaults 读回角色的统一入口（GirlCompanion.init 与 HUDManager 共用）。
    /// 枚举 rawValue 已由旧值"御姐兔女郎"更名为"兔娘"——老用户升级后本地仍存"御姐兔女郎"，
    /// 直接 GirlCharacter(rawValue:) 会拿到 nil 静默回退 .loli，这里做一次旧值→.rabit 兼容映射。
    static func stored(rawValue: String?) -> GirlCharacter {
        guard let raw = rawValue, !raw.isEmpty else { return .loli }
        if raw == L10n.t("i18n_840") { return .rabit }   // 旧 rawValue 迁移：御姐兔女郎 → 兔娘
        return GirlCharacter(rawValue: raw) ?? .loli
    }
}

final class GirlCompanion: ObservableObject {
    static let shared = GirlCompanion()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "trollmcp2.girl_companion_enabled") }
    }
    @Published var selectedCharacter: GirlCharacter {
        didSet { UserDefaults.standard.set(selectedCharacter.rawValue, forKey: "trollmcp2.girl_character") }
    }
    // v7.2.3：悬浮角色姿态——麦克风按钮只在 .standing 显示
    // （吸附 wallSnap / 攀爬 climbing / 惊恐 fear 时自动隐藏，见 setPose）
    @Published var pose: GirlPose = .standing
    // v6.0.28：悬浮尺寸可调
    @Published var floatSize: Double {
        didSet { UserDefaults.standard.set(floatSize, forKey: "trollmcp2.girl_float_size") }
    }
    // v6.0.28：气泡样式（0=经典圆角 1=椭圆 2=方形硬边 3=爆炸形）
    // v7.1.74：didSet 额外写全局文件 /var/mobile/Documents/bubble_style.txt——
    // HUD 是独立进程读不到本进程 UserDefaults（同 fanMenuStyle 坑），之前只写 standard
    // 导致 HUD 永远读默认 0，"切换样式不生效"。HUD 侧改读全局文件优先。
    @Published var bubbleStyle: Int {
        didSet {
            UserDefaults.standard.set(bubbleStyle, forKey: "trollmcp2.bubble_style")
            try? "\(bubbleStyle)".write(toFile: "/var/mobile/Documents/bubble_style.txt",
                                        atomically: true, encoding: .utf8)
        }
    }
    private init() {
        enabled = UserDefaults.standard.bool(forKey: "trollmcp2.girl_companion_enabled")
        selectedCharacter = GirlCharacter.stored(rawValue: UserDefaults.standard.string(forKey: "trollmcp2.girl_character"))
        // 默认200，范围170-300
        let savedSize = UserDefaults.standard.double(forKey: "trollmcp2.girl_float_size")
        floatSize = (savedSize > 0) ? savedSize : 200
        bubbleStyle = UserDefaults.standard.integer(forKey: "trollmcp2.bubble_style")
    }

    /// v7.2.3：设置角色姿态。非站立姿态（吸附/攀爬/惊恐）→ 麦克风按钮自动隐藏。
    /// 吸附检测 / 攀爬 / 惊吓交互接入时调用此方法切换，其余逻辑不动。
    func setPose(_ newPose: GirlPose) {
        guard pose != newPose else { return }
        pose = newPose
    }
}

/// v7.2.3：悬浮角色姿态。当前仅有站立（吸附/攀爬/惊恐由未来交互接入触发）。
enum GirlPose {
    case standing    // 站立 → 显示麦克风
    case wallSnap    // 吸附墙壁 → 隐藏麦克风
    case climbing    // 攀爬 → 隐藏麦克风
    case fear        // 高空惊恐 → 隐藏麦克风
}

// MARK: - 表情帧（对应 Resources/girl_*.png 或 rabit_*.png，build-ipa.sh 打进 App 根，Bundle.main 读）

extension GirlCharacter {
    /// v7.2.2：每个角色固定音色（语音对话自动跟随，不做手动切换）
    var voicePreset: VoicePreset {
        switch self {
        case .loli: return .loli
        case .rabit: return .bunny
        case .cat: return .cat
        }
    }

    /// v7.2.3：语音角色人设提示词——角色性格 + 轻量环境 facts，明确无工具调用
    /// （voice mode 只对话；要操作必须引导去文字聊天）
    var personaPrompt: String {
        let envFacts = """
        Environment: iOS 16.3, TrollStore sideload (no jailbreak, no /var/jb). App: TrollAgent.
        You speak through voice TTS, so keep replies SHORT (1-2 sentences).
        NO TOOLS: voice mode has no tool access. You cannot run commands, open apps, or inspect the system.
        If the user asks for an operation (inject an app, run a command, check logs), say it must be done in the text chat and offer to phrase it for them.
        """
        switch self {
        case .loli:
            return "You are Chibi, a cute innocent little girl companion. Cheerful, playful, calls the user \"master\". Short cute sentences. " + envFacts
        case .cat:
            return "You are Catgirl, an elegant magnetic ojou-sama companion. Lazy, teasing, calls the user \"master\", ends sentences with \"喵~\" (meow). Calm magnetic tone. " + envFacts
        case .rabit:
            return "You are Rabbit-girl, a shy soft gentle companion. Warm, caring, calls the user \"master\", ends sentences with \"呜~\" (soft whimper). " + envFacts
        }
    }
}

enum GirlExpression: String {
    case idle    // 正常/待机
    case happy   // 开心（点击）
    case think   // 思考
    case talk    // 说话口型（语音时）
    /// 按角色取帧图名：小萝莉 girl_*，兔娘 rabit_*
    func imageName(for character: GirlCharacter) -> String {
        return "\(character.iconPrefix)_\(rawValue)"
    }
}

// MARK: - 角色视图

struct GirlCompanionView: View {
    @ObservedObject private var companion = GirlCompanion.shared
    @ObservedObject private var tts = TTSService.shared
    @ObservedObject private var voice = GirlVoice.shared

    @State private var expression: GirlExpression = .idle
    @State private var breathing = false      // 呼吸（scale 缓动）
    @State private var floating = false       // 浮动（上下轻飘）
    @State private var tapFlash: Int = 0      // 点击触发随机表情的计时
    @State private var deniedHint = false     // 权限被拒提示

    private let frameHeight: CGFloat = 148    // 全身立绘显示高度（右下角悬浮，不宜过大）

    // v6.0.12：与 HUD 完全一致的角色放大系数（girl 1.0 / rabit 1.4 / cat 1.2）——
    // 兔娘/猫娘身高修长，同高 148 下比萝莉窄，按系数放大显示高度，保持右下角助手整体大小协调。
    private var charScale: CGFloat {
        switch companion.selectedCharacter {
        case .rabit: return 1.4
        case .cat: return 1.2
        case .loli: return 1.0
        }
    }

    // v7.2.3 设计原则（用户拍板）：麦克风按钮【只在站立姿态显示】。
    // 吸附/攀爬/惊恐（wallSnap/climbing/fear）→ isStanding=false → 按钮隐藏。
    // 真实来源 = companion.pose（交互接入 setPose 即自动切换）。
    private var isStanding: Bool { companion.pose == .standing }

    var body: some View {
        VStack(spacing: 8) {   // v7.2.2：角色脚底 8pt 放麦克风角标
            // 小女孩本体
            Group {
                if let img = UIImage(named: expression.imageName(for: companion.selectedCharacter)) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(height: frameHeight * charScale)
                        .scaleEffect(breathing ? 1.03 : 0.99)
                        .offset(y: floating ? -7 : 7)
                        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: breathing)
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                        .onTapGesture { reactToTap() }
                } else {
                    Circle().fill(Color.pink.opacity(0.25)).frame(width: 60, height: 60)
                }
            }
            .onAppear {
                breathing = true
                floating = true
                voice.onFinalText = { [self] text in self.askAI(text) }
                voice.onPermissionDenied = { [self] in self.deniedHint = true }
            }

            // 说话按钮（麦克风）——v7.2.3：只在站立姿态显示
            if isStanding {
                micButton
            }
        }
        .onReceive(tts.$isSpeaking) { speaking in
            withAnimation(.easeInOut(duration: 0.25)) {
                expression = speaking ? .talk : (voice.isListening ? .talk : .idle)
            }
        }
        .onReceive(voice.$isListening) { listening in
            withAnimation(.easeInOut(duration: 0.25)) {
                if listening { expression = .talk }
            }
        }
        .onReceive(Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()) { _ in
            if tapFlash > 0 {
                tapFlash -= 1
                if tapFlash == 0 { expression = .idle }
            }
        }
        .alert(L10n.t("i18n_841"), isPresented: $deniedHint) {
            Button(L10n.t("ui_44"), role: .cancel) {}
        } message: {
            Text(L10n.t("i18n_842"))
        }
    }

    // MARK: - 麦克风说话按钮（v7.2.2：圆形脚底角标——常态 35% 透明，说话青色 + 波纹扩散）

    private var micButton: some View {
        Button(action: toggleMic) {
            ZStack {
                // 波纹（录音时向外扩散）
                if voice.isListening {
                    Circle()
                        .stroke(Color.cyan.opacity(0.55), lineWidth: 2.5)
                        .frame(width: 40, height: 40)
                        .scaleEffect(voice.isListening ? 1.7 : 1.0)
                        .opacity(voice.isListening ? 0 : 0.7)
                        .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: voice.isListening)
                }
                // 底圆
                Circle()
                    .fill(voice.isListening ? Color.cyan.opacity(0.9) : Color.black.opacity(0.35))
                    .frame(width: 40, height: 40)
                // 麦克风图标
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("语音说话")
    }

    // MARK: - 交互

    /// 点击切表情：随机 开心/思考，短暂后回待机
    private func reactToTap() {
        let r = Int.random(in: 0...1)
        withAnimation(.easeInOut(duration: 0.25)) {
            expression = r == 0 ? .happy : .think
        }
        tapFlash = 2   // 约 1.6s 后回待机
    }

    /// 麦克风：开始听 / 停止发送
    private func toggleMic() {
        if voice.isListening {
            voice.stop()
        } else {
            voice.start()
        }
    }

    /// 识别到文本 → 发 AI（复用聊天发送链路，回复自动流式显示 + 朗读 → 口型帧）
    private func askAI(_ text: String) {
        guard let cfg = ModelStore.shared.defaultConfig else { return }
        // v7.2.2：音色随当前角色固定（萝莉/猫娘御姐/兔娘各自绑定）
        tts.voicePreset = companion.selectedCharacter.voicePreset
        // 语音对话需要听到回复 → 若喇叭关着自动打开
        if !tts.speakerEnabled {
            tts.speakerEnabled = true
        }
        let store = ConversationStore.shared
        if store.selectedId == nil {
            store.newConversation()
        }
        store.send(text, using: cfg, reasoningLevel: 3, smartSearch: true, personaPrompt: companion.selectedCharacter.personaPrompt)
    }
}
