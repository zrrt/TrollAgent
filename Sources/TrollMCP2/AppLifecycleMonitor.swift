import Foundation
import Network
import UIKit

// MARK: - 网络与生命周期监控（v2.9.10）
// 解决"切后台再切回来网络中断"：
// 1. NWPathMonitor 监听网络路径，恢复时通知重连
// 2. 前后台切换广播，供 GatewayClient / 会话自动重连

final class AppLifecycleMonitor {
    static let shared = AppLifecycleMonitor()

    /// 通知名：网络从不可用→可用
    static let networkRestored = Notification.Name("trollmcp2.networkRestored")
    /// 通知名：App 回到前台
    static let willEnterForeground = Notification.Name("trollmcp2.willEnterForeground")
    /// v7.4.0-fix72：最近一次回前台时间（请求失败时若落在近 5s 内 → 视为"后台挂起"而非真断网，
    /// 用于自动重试、不误报"网络连接已中断"）
    static private(set) var lastForegroundAt = Date.distantPast

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "trollmcp2.network.monitor")
    private var lastSatisfied: Bool?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 启动监听（AppDelegate didFinishLaunching 调用）
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let changed = self?.lastSatisfied != nil && self?.lastSatisfied != satisfied
            self?.lastSatisfied = satisfied
            if satisfied && changed {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.networkRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)

        // 前后台监听
        let fg = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            Self.lastForegroundAt = Date()
            NotificationCenter.default.post(name: Self.willEnterForeground, object: nil)
        }
        observers.append(fg)
    }

    var isNetworkAvailable: Bool {
        lastSatisfied ?? true
    }
}
