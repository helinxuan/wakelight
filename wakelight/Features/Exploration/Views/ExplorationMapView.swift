import SwiftUI
import MapKit
import UIKit
import CoreLocation

struct ExplorationMapView: UIViewRepresentable {
    @ObservedObject var viewModel: ExploreViewModel
    @Binding var selectedCluster: PlaceCluster?
    @Binding var awakenQueue: [PlaceCluster]
    @Binding var isAwakenMode: Bool
    @Binding var revealedClusterIds: Set<UUID>
    @Binding var blowUnlockSignal: Int

    var onFirstAwakenInSession: ((PlaceCluster, CGPoint) -> Void)?

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ExplorationMapView
        var currentAnnotations: [ClusterAnnotation] = []
        private var panGesture: UIPanGestureRecognizer?
        weak var fogScreenView: FogScreenView?

        private var hitStreakCount: Int = 0
        private var lastHitTime: TimeInterval = 0
        private var lastFeedbackTime: TimeInterval = 0
        private var lastHitClusterId: UUID?


        private var didTriggerFirstAwakenCallbackInSession: Bool = false
        private let firstAwakenPanelDelay: TimeInterval = 0.18
        private var lastHandledBlowUnlockSignal: Int = 0

        private var blowSweepLayer: CAShapeLayer?
        private var blowSweepDisplayLink: CADisplayLink?
        private var blowSweepStartTime: CFTimeInterval = 0
        private let blowSweepDuration: CFTimeInterval = 1.05
        private var blowSweepMapView: MKMapView?
        private var blowSweepStartY: CGFloat = 0
        private var blowSweepEndY: CGFloat = 0
        private var blowSweepDidTriggerStartFeedback: Bool = false
        private var blowSweepDidTriggerMidFeedback: Bool = false

        init(parent: ExplorationMapView) {
            self.parent = parent
        }

        func setupGestures(for mapView: MKMapView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            mapView.addGestureRecognizer(pan)
            self.panGesture = pan

            // 预热触觉/音频/粒子资源，避免首次刮开同帧初始化导致卡顿
            HapticPlayer.warmUpIfNeeded()
            SystemSoundPlayer.warmUpIfNeeded()
            StardustEmitter.warmUpIfNeeded()
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.isAwakenMode else { return }
            let mapView = gesture.view as! MKMapView
            let location = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                didTriggerFirstAwakenCallbackInSession = false
                return
            case .changed:
                processInteraction(at: location, in: mapView)
            default:
                return
            }
        }

        private func processInteraction(at location: CGPoint, in mapView: MKMapView) {
            #if DEBUG
            let panStart = CACurrentMediaTime()
            #endif

            let hitRect = CGRect(x: location.x - 22, y: location.y - 22, width: 44, height: 44)

            for annotation in currentAnnotations {
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                if hitRect.contains(point) {
                    handleClusterHit(annotation: annotation, point: point, mapView: mapView)

                    #if DEBUG
                    let ms = (CACurrentMediaTime() - panStart) * 1000
                    print(String(format: "[Perf][AwakenPan] feedback chain %.2fms", ms))
                    #endif
                    return
                }
            }
        }

        private func handleClusterHit(annotation: ClusterAnnotation, point: CGPoint, mapView: MKMapView) {
            let hitCluster = annotation.cluster
            let isAlreadyInQueue = parent.awakenQueue.contains(where: { $0.id == hitCluster.id })

            let now = CACurrentMediaTime()
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

            if !isAlreadyInQueue {
                let shouldTriggerFirstCallback = !didTriggerFirstAwakenCallbackInSession
                if shouldTriggerFirstCallback {
                    didTriggerFirstAwakenCallbackInSession = true
                }

                Task { @MainActor in
                    parent.revealedClusterIds.insert(hitCluster.id)

                    if let view = mapView.view(for: annotation) as? LightPointAnnotationView {
                        view.isStoryPoint = hitCluster.hasStory
                        view.isHalfRevealed = true
                        view.updateStyle()
                    }

                    fogScreenView?.triggerDiffusion(for: hitCluster.id)
                    parent.selectedCluster = hitCluster

                    if shouldTriggerFirstCallback {
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.firstAwakenPanelDelay) {
                            if !self.parent.awakenQueue.contains(where: { $0.id == hitCluster.id }) {
                                self.parent.awakenQueue.append(hitCluster)
                            }
                            self.parent.onFirstAwakenInSession?(hitCluster, point)
                        }
                    } else {
                        if !parent.awakenQueue.contains(where: { $0.id == hitCluster.id }) {
                            parent.awakenQueue.append(hitCluster)
                        }
                    }
                }
            } else {
                Task { @MainActor in
                    if !parent.revealedClusterIds.contains(hitCluster.id) {
                        parent.revealedClusterIds.insert(hitCluster.id)
                        if let view = mapView.view(for: annotation) as? LightPointAnnotationView {
                            view.isStoryPoint = hitCluster.hasStory
                            view.isHalfRevealed = true
                            view.updateStyle()
                        }
                        fogScreenView?.triggerDiffusion(for: hitCluster.id)
                    }

                    if parent.selectedCluster?.id != hitCluster.id {
                        parent.selectedCluster = hitCluster
                    }
                }
            }
        }


        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if !parent.isAwakenMode {
            }
            return true
        }

        func applyAnnotations(to mapView: MKMapView) {
            mapView.removeAnnotations(currentAnnotations)
            let annotations = parent.viewModel.clusters.map { ClusterAnnotation(cluster: $0) }
            currentAnnotations = annotations
            mapView.addAnnotations(annotations)
        }

        func handleBlowUnlockIfNeeded(on mapView: MKMapView) {
            guard parent.blowUnlockSignal != lastHandledBlowUnlockSignal else { return }
            lastHandledBlowUnlockSignal = parent.blowUnlockSignal
            guard parent.isAwakenMode else { return }

            let visibleRect = mapView.bounds
            guard !visibleRect.isEmpty else { return }

            var visibleAnnotations: [ClusterAnnotation] = []
            visibleAnnotations.reserveCapacity(currentAnnotations.count)

            for annotation in currentAnnotations {
                let p = mapView.convert(annotation.coordinate, toPointTo: mapView)
                if visibleRect.contains(p) {
                    visibleAnnotations.append(annotation)
                }
            }

            guard !visibleAnnotations.isEmpty else { return }
            startBlowSweep(on: mapView, visibleAnnotations: visibleAnnotations)
        }

        private func startBlowSweep(on mapView: MKMapView, visibleAnnotations: [ClusterAnnotation]) {
            stopBlowSweepIfNeeded()
            didTriggerFirstAwakenCallbackInSession = false

            blowSweepMapView = mapView
            blowSweepStartTime = CACurrentMediaTime()
            blowSweepDidTriggerStartFeedback = false
            blowSweepDidTriggerMidFeedback = false

            let h = mapView.bounds.height
            blowSweepStartY = h + 40
            blowSweepEndY = -30

            let pathLayer = CAShapeLayer()
            pathLayer.frame = mapView.bounds
            pathLayer.fillColor = UIColor.clear.cgColor
            pathLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            pathLayer.lineWidth = 3.0
            pathLayer.lineCap = .round
            pathLayer.shadowColor = UIColor.white.cgColor
            pathLayer.shadowRadius = 12
            pathLayer.shadowOpacity = 0.95
            pathLayer.shadowOffset = .zero
            mapView.layer.addSublayer(pathLayer)
            blowSweepLayer = pathLayer

            let link = CADisplayLink(target: self, selector: #selector(handleBlowSweepFrame))
            link.add(to: .main, forMode: .common)
            blowSweepDisplayLink = link

            updateBlowSweep(at: 0, mapView: mapView)
        }

        @objc private func handleBlowSweepFrame() {
            guard let mapView = blowSweepMapView else {
                stopBlowSweepIfNeeded()
                return
            }

            let elapsed = CACurrentMediaTime() - blowSweepStartTime
            let progress = min(1, elapsed / blowSweepDuration)

            updateBlowSweep(at: progress, mapView: mapView)

            if progress >= 1 {
                stopBlowSweepIfNeeded()
            }
        }

        private func updateBlowSweep(at progress: CGFloat, mapView: MKMapView) {
            let p = easeOut(progress)
            let y = blowSweepStartY + (blowSweepEndY - blowSweepStartY) * p
            let centerX = mapView.bounds.midX
            let current = CGPoint(x: centerX, y: y)

            if let layer = blowSweepLayer {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: mapView.bounds.width, y: y))
                layer.path = path.cgPath
                layer.opacity = Float(1 - p * 0.45)
            }

            let sampleStep: CGFloat = 24
            var x: CGFloat = 0
            while x <= mapView.bounds.width {
                processInteraction(at: CGPoint(x: x, y: y), in: mapView)
                x += sampleStep
            }
            processInteraction(at: current, in: mapView)

            if !blowSweepDidTriggerStartFeedback {
                blowSweepDidTriggerStartFeedback = true
                HapticPlayer.play(forCount: max(2, hitStreakCount + 1))
                SystemSoundPlayer.playTick()
            }

            if progress >= 0.4, !blowSweepDidTriggerMidFeedback {
                blowSweepDidTriggerMidFeedback = true
                HapticPlayer.play(forCount: max(3, hitStreakCount + 1))
            }
        }

        private func stopBlowSweepIfNeeded() {
            blowSweepDisplayLink?.invalidate()
            blowSweepDisplayLink = nil
            blowSweepMapView = nil

            blowSweepLayer?.removeFromSuperlayer()
            blowSweepLayer = nil
        }

        private func easeOut(_ t: CGFloat) -> CGFloat {
            1 - pow(1 - t, 3)
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
            fogScreenView?.updateIfNeeded(interactionPhase: true)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
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

        let fogView = FogScreenView(mapView: mapView)
        fogView.clusters = viewModel.clusters
        fogView.revealedClusterIds = revealedClusterIds
        fogView.translatesAutoresizingMaskIntoConstraints = false
        fogView.isUserInteractionEnabled = false
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
            fogView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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
        
        fogView.clusters = viewModel.clusters
        fogView.revealedClusterIds = revealedClusterIds
        fogView.updateIfNeeded(interactionPhase: false)

        if context.coordinator.currentAnnotations.count != viewModel.clusters.count {
            context.coordinator.applyAnnotations(to: mapView)
        }

        context.coordinator.handleBlowUnlockIfNeeded(on: mapView)

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

final class FogScreenView: UIView {
    weak var mapView: MKMapView?

    var clusters: [PlaceCluster] = [] {
        didSet { needsFullUpdate = true }
    }

    var revealedClusterIds: Set<UUID> = [] {
        didSet { needsFullUpdate = true }
    }

    private let maxVisibleGlowLayers: Int = 180
    private let fogAlpha: CGFloat = 0.65
    private let glowOpacity: Float = 0.55
    private let storyGlowColor = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0).cgColor
    private let visiblePadding: CGFloat = 140
    private let baseGlowSize: CGFloat = 120

    private var animatingClusterId: UUID?
    private var animationStartTime: TimeInterval?
    private var displayLink: CADisplayLink?
    private let animationDuration: TimeInterval = 0.6

    private let overlayLayer = CALayer()
    private let glowContainerLayer = CALayer()
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

    func updateIfNeeded(interactionPhase: Bool) {
        if interactionPhase {
            updateActiveGlowLayerGeometryOnly()
            return
        }

        guard needsFullUpdate else {
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

    private func updateVisibleSetAndRecycle() {
        guard let mapView else { return }
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        let visibleRect = rect.insetBy(dx: -visiblePadding, dy: -visiblePadding)

        var candidates: [(id: UUID, screenPoint: CGPoint, dist2: CGFloat)] = []
        candidates.reserveCapacity(256)

        let center = CGPoint(x: rect.midX, y: rect.midY)

        for c in clusters {
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

        if candidates.count > maxVisibleGlowLayers {
            candidates.sort { $0.dist2 < $1.dist2 }
            candidates = Array(candidates.prefix(maxVisibleGlowLayers))
        }

        let keepIds = Set(candidates.map { $0.id })

        for (id, layer) in activeGlowLayers where !keepIds.contains(id) {
            layer.removeFromSuperlayer()
            activeGlowLayers.removeValue(forKey: id)
            idleGlowLayers.append(layer)
        }

        for item in candidates {
            let layer = getOrCreateGlowLayer(for: item.id)
            layer.position = item.screenPoint
        }

        updateActiveGlowLayerGeometryOnly()
    }

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
            layer.contents = c.hasStory ? storyGlowImage : glowImage

            var finalSize = size
            var finalOpacity = glowOpacity

            if id == animatingClusterId {
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

        glowContainerLayer.addSublayer(layer)
        activeGlowLayers[id] = layer
        return layer
    }
}
