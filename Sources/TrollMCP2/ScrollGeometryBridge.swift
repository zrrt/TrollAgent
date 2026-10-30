import SwiftUI
import UIKit

/// v7.4.1-fix73h：UIKit 桥接滚动检测（替代 SwiftUI preference + named coordinateSpace 方案）。
///
/// 背景：原方案在 iOS 16.0-16.3 的 ScrollView 下不可靠——内容视图的 frame(in: .named(...)) 在滚动时
/// 不重新计算、preference 不重新提交 → chatScrollOffset 恒为初始值 → ↑ 按钮永不显示、⬇️ 按钮永不隐藏
/// （用户实测 7.1.212-7.1.215 连续四个版本修复无效的根因）。
/// 修复：直接 KVO 监听底层 UIScrollView 的 contentOffset / contentSize / bounds——UIKit 精确数值，
/// 无惰性渲染、无坐标系竞态、无 preference 时序问题，iOS 15-17 通吃（对齐 OpenMinis 的
/// UICollectionView contentSize/bounds 精确计算思路）。
///
/// 用法：作为 ScrollView 的第一个内容子视图（frame height 0，不撑内容），superview 链直达
/// 底层 UIScrollView；滚动/内容变化时经 KVO 回调上报三个状态。
struct ScrollGeometryBridge: UIViewRepresentable {
    /// 滚动偏移（对齐原 marker 语义：顶部=0，向下滚为负）
    var onOffset: (CGFloat) -> Void
    /// 内容总高
    var onContentHeight: (CGFloat) -> Void
    /// 视口高度
    var onViewportHeight: (CGFloat) -> Void

    func makeUIView(context: Context) -> BridgeView {
        let v = BridgeView()
        v.onOffset = onOffset
        v.onContentHeight = onContentHeight
        v.onViewportHeight = onViewportHeight
        return v
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        // SwiftUI 每次 body 重算会用新的闭包（捕获新的 self），必须刷新到已存在的 view 上，
        // 否则 @State 永远写进旧副本。
        uiView.onOffset = onOffset
        uiView.onContentHeight = onContentHeight
        uiView.onViewportHeight = onViewportHeight
    }

    final class BridgeView: UIView {
        var onOffset: ((CGFloat) -> Void)?
        var onContentHeight: ((CGFloat) -> Void)?
        var onViewportHeight: ((CGFloat) -> Void)?

        private weak var scrollView: UIScrollView?
        private var offsetObs: NSKeyValueObservation?
        private var contentSizeObs: NSKeyValueObservation?
        private var boundsObs: NSKeyValueObservation?
        private var attachAttempts = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attach(to: findScrollView())
            } else {
                detach()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // didMoveToWindow 时 SwiftUI 可能尚未把内容挂进 UIScrollView，兜底重试（最多 5 次）
            if scrollView == nil, window != nil, attachAttempts < 5 {
                attachAttempts += 1
                attach(to: findScrollView())
            }
        }

        /// 从自身沿 superview 链向上找最近的 UIScrollView（SwiftUI ScrollView 底层即 UIScrollView）
        private func findScrollView() -> UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView { return sv }
                v = cur.superview
            }
            return nil
        }

        private func attach(to sv: UIScrollView?) {
            guard let sv else { return }
            // fix73j-审计 M-6：attach 成功复位重试计数——否则后续 detach/重建（视图复用、
            // 会话切换）后 attachAttempts 已到 5，layoutSubviews 兜底重试永久失效，
            // KVO 桥接再也装不上 → 滚动按钮静默失效。
            attachAttempts = 0
            scrollView = sv
            offsetObs = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                // UIKit offset.y：顶部=0（或 -adjustedInset.top），向下滚为正。
                // 转回原 marker 语义（顶部=0，向下为负），ChatView 的显示矩阵判断完全不用改。
                self?.onOffset?(-sv.contentOffset.y)
            }
            contentSizeObs = sv.observe(\.contentSize, options: [.initial, .new]) { [weak self] sv, _ in
                self?.onContentHeight?(sv.contentSize.height)
            }
            boundsObs = sv.observe(\.bounds, options: [.initial, .new]) { [weak self] sv, _ in
                self?.onViewportHeight?(sv.bounds.height)
            }
        }

        private func detach() {
            offsetObs = nil
            contentSizeObs = nil
            boundsObs = nil
            scrollView = nil
        }

        deinit { detach() }
    }
}
