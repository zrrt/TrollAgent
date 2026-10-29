import Foundation
import UserNotifications
import UIKit
import AVFoundation
import AudioToolbox

// v2.9.82：任务完成通知 + 后台执行延长
// - iOS 无越狱下 TrollStore App 无法真正后台常驻（受系统后台机制限制），
//   这里做两层补偿：beginBackgroundTask 尽量延长切后台后的执行时间；
//   请求结束（成功/失败/中断）时若 App 在后台，发本地通知提醒用户。
final class TaskNotify {
    static let shared = TaskNotify()
    private let defaults = UserDefaults.standard
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?

    var enabled: Bool {
        get { defaults.object(forKey: "taskNotify.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "taskNotify.enabled") }
    }

    // v7.4.0-fix73d：AI 完成任务提示音开关（默认开）+ 所选提示音下标（默认 0 = 三全音）
    var soundEnabled: Bool {
        get { defaults.object(forKey: "taskNotify.soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "taskNotify.soundEnabled") }
    }
    var soundIndex: Int {
        get {
            let v = defaults.integer(forKey: "taskNotify.soundIndex")
            return v >= 0 && v < Self.soundOptions.count ? v : 0
        }
        set { defaults.set(newValue, forKey: "taskNotify.soundIndex") }
    }
    /// 当前所选提示音的 bundle 文件名（含扩展名，UNNotificationSound 用）
    var soundFileName: String {
        Self.soundOptions[soundIndex].file + ".caf"
    }

    /// v7.4.0-fix73d：可选提示音清单（bundle 内置 CAF——iOS 14 提取的系统音效，
    /// 短信/邮件同款经典短音，前台 AVAudioPlayer 与后台通知声音共用同一文件，
    /// 保证前后台音色完全一致）。
    static let soundOptions: [(file: String, name: String)] = [
        ("sms-received1", "三全音（经典短信）"),
        ("sms-received2", "铃声（Chime）"),
        ("sms-received3", "玻璃音"),
        ("sms-received4", "号角音"),
        ("sms-received5", "铃铛音"),
        ("sms-received6", "电子音"),
        ("Tink", "叮咚声"),
        ("new-mail", "新邮件声"),
    ]

    /// 首次请求通知权限（App 启动 / 首次发送消息时调用）
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 仅在 App 处于后台/挂起时发本地通知（前台不打扰）——声音用所选提示音文件
    func notifyIfBackground(title: String, body: String) {
        guard enabled else { return }
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = UNNotificationSound(named: UNNotificationSoundName(self.soundFileName))
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    /// v7.4.0-fix73d：AI 完成任务时前台播放所选提示音（bundle 文件，与后台通知同音色；
    /// 后台/锁屏场景由 notifyIfBackground 的通知声音负责）
    func playCompletionSoundIfForeground() {
        guard soundEnabled else { return }
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState == .active else { return }
            self.playFile(Self.soundOptions[self.soundIndex].file)
        }
    }

    /// v7.4.0-fix73d：试听提示音（设置页点选时播放）
    func previewSound(_ index: Int) {
        let i = min(max(index, 0), Self.soundOptions.count - 1)
        playFile(Self.soundOptions[i].file)
    }

    /// 播放 bundle 内提示音文件（ambient 类别：不打断正在播放的音乐/视频）
    /// v7.4.0-fix73e：AVAudioPlayer 失败（CAF 未进 bundle / 音频会话异常）→
    /// 兜底播系统音 1001（三全音）——保证"任务完成提示音"任何情况都有声音。
    private func playFile(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else {
            NetworkLog.shared.log("[sound] CAF missing in bundle: \(name).caf — fallback system sound 1001")
            fallbackSystemSound()
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NetworkLog.shared.log("[sound] AVAudioSession failed: \(error.localizedDescription)")
        }
        player?.stop()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            NetworkLog.shared.log("[sound] played \(name).caf")
        } catch {
            NetworkLog.shared.log("[sound] AVAudioPlayer failed for \(name).caf: \(error.localizedDescription) — fallback")
            fallbackSystemSound()
        }
    }

    /// v7.4.0-fix73e：系统音兜底（AudioServices 不依赖 bundle 资源）
    private func fallbackSystemSound() {
        AudioServicesPlaySystemSound(1001)
    }

    /// 开始后台任务（切后台后尽量延长执行，系统上限约 30 秒）
    func beginBackground() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    func endBackground() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
}
