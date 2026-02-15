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
                    let shouldTriggerFeedback = hitCluster.id != lastHitClusterId || (now - lastFeedbackTime > 0.1)

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
                                view.isHalfRevealed = true
                            }

                            // 通知屏幕层启动扩散动画
                            fogScreenView?.triggerDiffusion(for: hitCluster.id)
                            parent.selectedCluster = hitCluster

                            Task {
                                await parent.viewModel.markClusterHalfRevealed(placeClusterId: hitCluster.id)
                            }
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
            view.updateStyle()
            return view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // 地图每一帧变动都让屏幕迷雾重绘，屏幕空间渲染极快且无缝
            fogScreenView?.setNeedsDisplay()
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
            fogView.setNeedsDisplay()

            // 1. 检查数量变化
            if context.coordinator.currentAnnotations.count != viewModel.clusters.count {
                context.coordinator.applyAnnotations(to: mapView)
            } else {
                // 2. 数量没变时，检查 hasStory 状态是否变化并同步颜色
                for annotation in context.coordinator.currentAnnotations {
                    if let cluster = viewModel.clusters.first(where: { $0.id == annotation.cluster.id }) {
                        // 如果内存态变黄了，但 annotation view 还没刷，就手动刷一下
                        if cluster.hasStory != annotation.cluster.hasStory {
                            if let view = mapView.view(for: annotation) as? LightPointAnnotationView {
                                view.isStoryPoint = cluster.hasStory
                                view.updateStyle()
                            }
                        }
                    }
                }
            }
        }
}

/// 屏幕空间迷雾视图：直接在 UIView 上绘制，解决 MapKit Overlay 的拼接和刷新延迟问题
final class FogScreenView: UIView {
    weak var mapView: MKMapView?
    var clusters: [PlaceCluster] = []
    var revealedClusterIds: Set<UUID> = []
    
    // 扩散动画状态
    private var animatingClusterId: UUID?
    private var animationStartTime: TimeInterval?
    private var displayLink: CADisplayLink?
    
    private let fogAlpha: CGFloat = 0.65
    private let baseHoleRadius: CGFloat = 15
    private let revealedHoleRadius: CGFloat = 65
    private let animationDuration: TimeInterval = 0.6

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func triggerDiffusion(for clusterId: UUID) {
        animatingClusterId = clusterId
        animationStartTime = CACurrentMediaTime()
        startDisplayLink()
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func onDisplayLink() {
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let mapView = mapView else { return }
        
        // 1. 填充背景迷雾
        context.setFillColor(UIColor.black.withAlphaComponent(fogAlpha).cgColor)
        context.fill(rect)

        context.saveGState()
        context.setBlendMode(.destinationOut)
        
        let currentTime = CACurrentMediaTime()
        var hasActiveAnimation = false

        // 优化缩放曲线：
        // span 越小（越近），factor 接近 1.0
        // span 越大（越远），factor 迅速下降，但在极远距离保持一个可见的最小值
        let span = Double(mapView.region.span.longitudeDelta)
        // 连续函数：当 span=0 时为 1.0，当 span=180 (全球) 时约为 0.25
        let zoomFactor = CGFloat(1.0 / (1.0 + pow(span / 20.0, 0.8)))
        
        // 限制收缩下限，确保世界级别下洞口变小但不消失（最小约 20pt）
        let minRadius: CGFloat = 14.0
        let currentBaseRadius = max(6.0, baseHoleRadius * zoomFactor)
        let currentRevealedRadius = max(minRadius, revealedHoleRadius * zoomFactor)

        for cluster in clusters {
            let coord = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            let screenPoint = mapView.convert(coord, toPointTo: self)
            
            // 剔除屏幕外的点（留出 100pt 缓冲）
            guard rect.insetBy(dx: -100, dy: -100).contains(screenPoint) else { continue }

            var radius: CGFloat = currentBaseRadius
            var opacity: CGFloat = 1.0
            var isSpecial = false

            if cluster.id == animatingClusterId, let start = animationStartTime {
                let elapsed = currentTime - start
                let progress = min(1.0, elapsed / animationDuration)
                let easeOut = 1 - pow(1 - progress, 3)
                
                radius = currentBaseRadius + (currentRevealedRadius - currentBaseRadius) * CGFloat(easeOut)
                opacity = CGFloat(easeOut)
                isSpecial = true
                if progress < 1.0 { hasActiveAnimation = true }
            } else if revealedClusterIds.contains(cluster.id) {
                radius = currentRevealedRadius
                isSpecial = true
            }

            if isSpecial {
                // 柔和边缘渐变
                let colors = [
                    UIColor.black.withAlphaComponent(opacity).cgColor,
                    UIColor.black.withAlphaComponent(0).cgColor
                ] as CFArray
                let locations: [CGFloat] = [0.6, 1.0]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                    context.drawRadialGradient(gradient, startCenter: screenPoint, startRadius: 0, endCenter: screenPoint, endRadius: radius, options: .drawsAfterEndLocation)
                }
            } else {
                // 普通小洞
                context.setFillColor(UIColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: screenPoint.x - radius, y: screenPoint.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        
        context.restoreGState()

        if !hasActiveAnimation {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
}
