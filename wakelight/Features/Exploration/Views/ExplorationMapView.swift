import SwiftUI
import MapKit
import UIKit

struct ExplorationMapView: UIViewRepresentable {
    @ObservedObject var viewModel: ExploreViewModel
    @Binding var selectedCluster: PlaceCluster?
    @Binding var awakenQueue: [PlaceCluster]
    @Binding var isAwakenMode: Bool
    @Binding var revealedClusterIds: Set<UUID>

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ExplorationMapView
        var currentAnnotations: [ClusterAnnotation] = []
        private var panGesture: UIPanGestureRecognizer?
        weak var fogScreenView: FogScreenView?

        private var hitStreakCount: Int = 0
        private var lastHitTime: TimeInterval = 0
        private var lastFeedbackTime: TimeInterval = 0
        private var lastHitClusterId: UUID?

        init(parent: ExplorationMapView) {
            self.parent = parent
        }

        func setupGestures(for mapView: MKMapView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            mapView.addGestureRecognizer(pan)
            self.panGesture = pan
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.isAwakenMode else { return }
            let mapView = gesture.view as! MKMapView
            let location = gesture.location(in: mapView)
            guard gesture.state == .changed else { return }

            let hitRect = CGRect(x: location.x - 22, y: location.y - 22, width: 44, height: 44)

            for annotation in currentAnnotations {
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                if hitRect.contains(point) {
                    let hitCluster = annotation.cluster
                    let isAlreadyInQueue = parent.awakenQueue.contains(where: { $0.id == hitCluster.id })

                    // 1. 视觉/触觉反馈控制
                    let now = CACurrentMediaTime()
                    
                    // 只有切换了 Cluster，或者在同一个 Cluster 上停留超过 0.1s 才再次触发反馈
                    // 这样可以避免手指微颤导致的高频触发（rateLimit=32hz 问题）
                    let shouldTriggerFeedback = hitCluster.id != lastHitClusterId || (now - lastFeedbackTime > 0.5)

                    if shouldTriggerFeedback {
                        if now - lastHitTime > 0.8 {
                            hitStreakCount = 0
                        }
                        lastHitTime = now
                        lastFeedbackTime = now
                        lastHitClusterId = hitCluster.id
                        hitStreakCount += 1

                        HapticPlayer.play(forCount: hitStreakCount)
                        SystemSoundPlayer.playTick()

                        if let fogView = fogScreenView {
                            let screenPoint = mapView.convert(annotation.coordinate, toPointTo: fogView)
                            StardustEmitter.emit(at: screenPoint, in: fogView)
                        } else {
                            StardustEmitter.emit(at: point, in: mapView)
                        }
                    }

                    // 2. 业务逻辑
                    if !isAlreadyInQueue {
                        Task { @MainActor in
                            parent.awakenQueue.append(hitCluster)
                            parent.revealedClusterIds.insert(hitCluster.id)

                            if let view = mapView.view(for: annotation) as? LightPointAnnotationView {
                                view.isStoryPoint = hitCluster.hasStory
                                view.isHalfRevealed = true
                                view.updateStyle()
                            }

                            // 通知屏幕层启动扩散动画
                            fogScreenView?.triggerDiffusion(for: hitCluster.id)
                            parent.selectedCluster = hitCluster

                            // Session-only 半显影：不落库
                        }
                    } else {
                        // 如果已经在队列中，滑动滑过时也要更新 selectedCluster 以触发面板置顶
                        if parent.selectedCluster?.id != hitCluster.id {
                            Task { @MainActor in
                                parent.selectedCluster = hitCluster
                            }
                        }
                    }
                    return
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func applyAnnotations(to mapView: MKMapView) {
            mapView.removeAnnotations(currentAnnotations)
            let annotations = parent.viewModel.clusters.map { ClusterAnnotation(cluster: $0) }
            currentAnnotations = annotations
            mapView.addAnnotations(annotations)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let clusterAnnotation = annotation as? ClusterAnnotation else { return nil }
            let cluster = clusterAnnotation.cluster

            let reuseId = "lightPoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? LightPointAnnotationView
                ?? LightPointAnnotationView(annotation: annotation, reuseIdentifier: reuseId)

            view.annotation = annotation
            view.canShowCallout = false
            view.isStoryPoint = cluster.hasStory
            view.isHalfRevealed = parent.revealedClusterIds.contains(cluster.id) && parent.isAwakenMode
            view.updateStyle()
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // 跟手：交互中只做轻量更新（只更新 glow 的 position/bounds），禁止重建 path / setNeedsDisplay
            fogScreenView?.updateIfNeeded(interactionPhase: true)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // 地图交互结束后再做一次完整可见集重算 + 回收
            fogScreenView?.updateIfNeeded(interactionPhase: false)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            Task { @MainActor in
                parent.isAwakenMode = true
                parent.selectedCluster = ann.cluster
            }
            let region = MKCoordinateRegion(center: ann.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25))
            mapView.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is ClusterAnnotation else { return }
            // 唤醒模式下点击空白处不退出，必须通过 UI 按钮明确退出
            if parent.isAwakenMode { return }
            if parent.selectedCluster != nil {
                Task { @MainActor in parent.selectedCluster = nil }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mapView)

        // 添加屏幕空间迷雾视图
        let fogView = FogScreenView(mapView: mapView)
        fogView.clusters = viewModel.clusters
        fogView.revealedClusterIds = revealedClusterIds
        fogView.translatesAutoresizingMaskIntoConstraints = false
        fogView.isUserInteractionEnabled = false // 穿透交互
        container.addSubview(fogView)
        context.coordinator.fogScreenView = fogView

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: container.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            fogView.topAnchor.constraint(equalTo: container.topAnchor),
            fogView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fogView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fogView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let span = MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.0, longitude: 103.0), span: span)
        mapView.setRegion(region, animated: false)

        context.coordinator.applyAnnotations(to: mapView)
        context.coordinator.setupGestures(for: mapView)
        
        return container
    }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.parent = self
            guard let mapView = uiView.subviews.first(where: { $0 is MKMapView }) as? MKMapView,
                  let fogView = uiView.subviews.first(where: { $0 is FogScreenView }) as? FogScreenView else { return }

            mapView.isScrollEnabled = !isAwakenMode
            
            // 同步数据到迷雾视图
            fogView.clusters = viewModel.clusters
            fogView.revealedClusterIds = revealedClusterIds
            fogView.updateIfNeeded(interactionPhase: false)

            // 1. 检查数量变化
            if context.coordinator.currentAnnotations.count != viewModel.clusters.count {
                context.coordinator.applyAnnotations(to: mapView)
            }

            // 2. 每次 update 都强制同步可见点状态（解决 MKAnnotationView 复用导致的残留样式）
            //    这样在退出唤醒模式后，白点会立刻恢复为灰点。
            for annotation in context.coordinator.currentAnnotations {
                guard let cluster = viewModel.clusters.first(where: { $0.id == annotation.cluster.id }) else { continue }
                guard let view = mapView.view(for: annotation) as? LightPointAnnotationView else { continue }

                let shouldHalfReveal = isAwakenMode && revealedClusterIds.contains(cluster.id)

                if view.isStoryPoint != cluster.hasStory || view.isHalfRevealed != shouldHalfReveal {
                    view.isStoryPoint = cluster.hasStory
                    view.isHalfRevealed = shouldHalfReveal
                    view.updateStyle()
                }
            }
        }
}

/// 迷雾遮罩（GPU 合成）：用 `CAShapeLayer` 作为 mask，通过 even-odd 规则在黑色遮罩上“挖洞”。
///
/// 设计目标：
/// - 禁止 `draw(_:)` / `CGGradient` / `blendMode(.destinationOut)` 这类 CPU 像素级绘制路径
/// - 只在交互结束（regionDidChange）或数据变更时更新 mask（节流）
/// - 使用 PNG 纹理叠加实现柔边光晕（Glow），解决硬边圈圈感
final class FogScreenView: UIView {
    weak var mapView: MKMapView?

    var clusters: [PlaceCluster] = [] {
        didSet { needsFullUpdate = true }
    }

    var revealedClusterIds: Set<UUID> = [] {
        didSet { needsFullUpdate = true }
    }

    // MARK: - Tunables (per ARCHITECTURE_WAKELIGHT.md 7.1)

    /// 硬上限：屏幕内同时可见的 glow layer 数量
    private let maxVisibleGlowLayers: Int = 180

    /// 全屏静态迷雾不透明度
    private let fogAlpha: CGFloat = 0.65

    /// Glow 纹理 alpha（视觉上是“照亮变薄”，不是挖洞）
    /// 地图底图较暗时，screenBlendMode 下需要更高的 alpha 才能明显体现“太阳式长尾”。
    private let glowOpacity: Float = 0.55
    
    /// 解锁后的金黄色 (对齐 ARCHITECTURE_WAKELIGHT.md)
    private let storyGlowColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0).cgColor

    /// 交互结束后完整更新时的可见范围缓冲（减少边缘 pop）
    private let visiblePadding: CGFloat = 140

    /// 根据缩放计算 glow 尺寸的基准（可看作文档里 B 参数的工程落点）
    private let baseGlowSize: CGFloat = 120

    // MARK: - Animation state (optional diffusion)

    private var animatingClusterId: UUID?
    private var animationStartTime: TimeInterval?
    private var displayLink: CADisplayLink?
    private let animationDuration: TimeInterval = 0.6

    // MARK: - Layers

    /// 静态迷雾：1 个半透明 CALayer，不做 mask、不重绘
    private let overlayLayer = CALayer()

    /// Glow 容器层：内部放若干个 contents=PNG 的 CALayer，由 GPU 合成
    private let glowContainerLayer = CALayer()

    /// 复用池：active + idle
    private var activeGlowLayers: [UUID: CALayer] = [:]
    private var idleGlowLayers: [CALayer] = []

    private let glowImage = UIImage(named: "FogHoleSoft")?.cgImage
    private let storyGlowImage = UIImage(named: "FogHoleSoftYellow")?.cgImage

    private var needsFullUpdate: Bool = true

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear

        overlayLayer.backgroundColor = UIColor.black.withAlphaComponent(fogAlpha).cgColor
        layer.addSublayer(overlayLayer)

        layer.addSublayer(glowContainerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlayLayer.frame = bounds
        glowContainerLayer.frame = bounds
        needsFullUpdate = true
        updateIfNeeded(interactionPhase: false)
    }

    /// 外部入口：
    /// - interactionPhase=true：跟手期，只更新 position/bounds（禁止 rebuild path / setNeedsDisplay）
    /// - interactionPhase=false：交互结束，重算可见集 + 回收
    func updateIfNeeded(interactionPhase: Bool) {
        if interactionPhase {
            updateActiveGlowLayerGeometryOnly()
            return
        }

        guard needsFullUpdate else {
            // 即使不需要 full update，也要确保 animating 的 frame 更新
            updateActiveGlowLayerGeometryOnly()
            return
        }

        needsFullUpdate = false
        updateVisibleSetAndRecycle()
    }

    func triggerDiffusion(for clusterId: UUID) {
        animatingClusterId = clusterId
        animationStartTime = CACurrentMediaTime()
        needsFullUpdate = true
        startDisplayLink()
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onDisplayLink() {
        // 动画期间不做 full rebuild，只做轻量几何更新 + opacity 变化
        updateActiveGlowLayerGeometryOnly()

        if let start = animationStartTime {
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= animationDuration {
                animatingClusterId = nil
                animationStartTime = nil
                displayLink?.invalidate()
                displayLink = nil
                needsFullUpdate = true
            }
        }
    }

    // MARK: - Core update

    private func updateVisibleSetAndRecycle() {
        guard let mapView else { return }
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        let visibleRect = rect.insetBy(dx: -visiblePadding, dy: -visiblePadding)

        // 1) 先筛选屏幕内 & revealed/animating
        var candidates: [(id: UUID, screenPoint: CGPoint, dist2: CGFloat)] = []
        candidates.reserveCapacity(256)

        let center = CGPoint(x: rect.midX, y: rect.midY)

        for c in clusters {
            // 三段状态对应的迷雾光晕显示逻辑：
            // - locked: 无光晕
            // - half-revealed (session): 显示白色光晕 (FogHoleSoft)
            // - fully revealed (story): 显示黄色光晕 (FogHoleSoftYellow)
            let isHalfRevealed = revealedClusterIds.contains(c.id)
            let isFullyRevealed = c.hasStory
            let isAnimating = c.id == animatingClusterId
            
            guard isHalfRevealed || isFullyRevealed || isAnimating else { continue }

            let coord = CLLocationCoordinate2D(latitude: c.centerLatitude, longitude: c.centerLongitude)
            let p = mapView.convert(coord, toPointTo: self)
            guard visibleRect.contains(p) else { continue }

            let dx = p.x - center.x
            let dy = p.y - center.y
            candidates.append((c.id, p, dx * dx + dy * dy))
        }

        // 2) 硬上限：取最近的 maxVisibleGlowLayers 个（靠屏幕中心）
        if candidates.count > maxVisibleGlowLayers {
            candidates.sort { $0.dist2 < $1.dist2 }
            candidates = Array(candidates.prefix(maxVisibleGlowLayers))
        }

        let keepIds = Set(candidates.map { $0.id })

        // 3) 回收不需要的 active layers
        for (id, layer) in activeGlowLayers where !keepIds.contains(id) {
            layer.removeFromSuperlayer()
            activeGlowLayers.removeValue(forKey: id)
            idleGlowLayers.append(layer)
        }

        // 4) 确保 keepIds 都有 layer
        for item in candidates {
            let layer = getOrCreateGlowLayer(for: item.id)
            layer.position = item.screenPoint
        }

        // 5) 统一更新一次几何（bounds/opacity/filter）
        updateActiveGlowLayerGeometryOnly()
    }

    /// 跟手期：只更新 active glow layers 的 position/bounds/opacity（不增不减）
    private func updateActiveGlowLayerGeometryOnly() {
        guard let mapView else { return }

        let span = Double(mapView.region.span.longitudeDelta)
        let zoomFactor = glowZoomFactor(span: span)
        let size = max(44, baseGlowSize * zoomFactor)

        let now = CACurrentMediaTime()
        let animProgress: CGFloat
        if let start = animationStartTime {
            let p = min(1.0, (now - start) / animationDuration)
            animProgress = CGFloat(1 - pow(1 - p, 3))
        } else {
            animProgress = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for (id, layer) in activeGlowLayers {
            guard let c = clusters.first(where: { $0.id == id }) else { continue }
            
            let coord = CLLocationCoordinate2D(latitude: c.centerLatitude, longitude: c.centerLongitude)
            layer.position = mapView.convert(coord, toPointTo: self)

            // 根据状态切换纹理 (Story 黄色 vs Session 白色)
            layer.contents = c.hasStory ? storyGlowImage : glowImage

            var finalSize = size
            var finalOpacity = glowOpacity

            if id == animatingClusterId {
                // 扩散时稍微放大&增亮一点点
                finalSize = size * (1.0 + 0.35 * animProgress)
                finalOpacity = min(0.52, glowOpacity + Float(0.18 * animProgress))
            }

            layer.bounds = CGRect(x: 0, y: 0, width: finalSize, height: finalSize)
            layer.opacity = finalOpacity

            if layer.compositingFilter == nil {
                layer.compositingFilter = "screenBlendMode"
            }
        }

        CATransaction.commit()
    }

    private func glowZoomFactor(span: Double) -> CGFloat {
        // span 越大（越远），factor 越小
        // 经验函数：平滑、单调、避免极端
        let f = 1.0 / (1.0 + pow(span / 18.0, 0.85))
        return CGFloat(max(0.25, min(1.0, f)))
    }

    private func getOrCreateGlowLayer(for id: UUID) -> CALayer {
        if let existing = activeGlowLayers[id] { return existing }

        let layer: CALayer
        if let reused = idleGlowLayers.popLast() {
            layer = reused
        } else {
            layer = CALayer()
        }

        layer.contents = glowImage
        layer.contentsGravity = .resizeAspect
        // contentsScale 可以让纹理在 retina 下更锐，但会增加显存；这里用系统默认即可

        glowContainerLayer.addSublayer(layer)
        activeGlowLayers[id] = layer
        return layer
    }
}
