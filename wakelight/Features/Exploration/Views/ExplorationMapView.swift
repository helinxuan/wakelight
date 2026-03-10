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
    @Binding var isBlowSweepRunning: Bool
    @Binding var exploreGuideTrigger: Int

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
        private let firstAwakenCallbackDelayAfterPanel: TimeInterval = 0.42
        private var lastHandledBlowUnlockSignal: Int = 0

        private var blowSweepContainerLayer: CALayer?
        private var blowSweepGlowGradient: CAGradientLayer?
        private var blowSweepCoreGradient: CAGradientLayer?
        private var blowSweepGlowMask: CAShapeLayer?
        private var blowSweepCoreMask: CAShapeLayer?
        private var blowSweepDisplayLink: CADisplayLink?
        private var blowSweepStartTime: CFTimeInterval = 0
        private let blowSweepDuration: CFTimeInterval = 2.4
        private var blowSweepMapView: MKMapView?
        private var blowSweepStartY: CGFloat = 0
        private var blowSweepEndY: CGFloat = 0
        private var blowSweepDidTriggerStartFeedback: Bool = false
        private var blowSweepDidTriggerMidFeedback: Bool = false
        private var blowSweepFrameIndex: Int = 0
        private var blowSweepPreviousY: CGFloat = 0
        private var blowSweepHitClusterIds: Set<UUID> = []
        private var didPrewarmBlowSweep: Bool = false
        private var isBlowSweepRunning: Bool = false
        private var lastBlowSweepStartTime: CFTimeInterval = 0
        private let blowSweepTriggerCooldown: CFTimeInterval = 0.9
        private var blowSweepHitTargets: [(annotation: ClusterAnnotation, point: CGPoint)] = []

        weak var scratchGuideView: ScratchGuideOverlayView?
        weak var blowGuideView: BlowGuideBarView?
        weak var exploreGuideView: ExploreTapGuideView?
        private var didShowBlowGuideInSession: Bool = false
        private var lastHandledExploreGuideTrigger: Int = -1
        private var awakenSessionHitCount: Int = 0
        private var awakenSessionStartWorkItem: DispatchWorkItem?
        private var previousAwakenMode: Bool = false

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

        func handleAwakenModeTransitionIfNeeded() {
            let isEnteringAwaken = parent.isAwakenMode && !previousAwakenMode
            let isExitingAwaken = !parent.isAwakenMode && previousAwakenMode
            previousAwakenMode = parent.isAwakenMode

            if isEnteringAwaken {
                exploreGuideView?.hideGuide(animated: true)
                resetAwakenGuidesSession()
                scratchGuideView?.showGuide()

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard self.parent.isAwakenMode else { return }
                    self.showBlowGuideIfNeeded(triggeredByTimeout: true)
                }
                awakenSessionStartWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
            }

            if isExitingAwaken {
                awakenSessionStartWorkItem?.cancel()
                awakenSessionStartWorkItem = nil
                scratchGuideView?.hideGuide(animated: true)
                blowGuideView?.hideGuide(animated: true)
                didShowBlowGuideInSession = false
                awakenSessionHitCount = 0
                didTriggerFirstAwakenCallbackInSession = false
            }
        }

        private func resetAwakenGuidesSession() {
            awakenSessionStartWorkItem?.cancel()
            awakenSessionStartWorkItem = nil
            didShowBlowGuideInSession = false
            awakenSessionHitCount = 0
            didTriggerFirstAwakenCallbackInSession = false
            scratchGuideView?.hideGuide(animated: false)
            blowGuideView?.hideGuide(animated: false)
        }

        private func showBlowGuideIfNeeded(triggeredByTimeout: Bool = false) {
            guard parent.isAwakenMode else { return }
            guard !didShowBlowGuideInSession else { return }
            if !triggeredByTimeout && awakenSessionHitCount < 2 { return }

            didShowBlowGuideInSession = true
            blowGuideView?.showGuide()
        }

        func showExploreGuideIfNeeded() {
            guard !parent.isAwakenMode else { return }
            guard parent.exploreGuideTrigger != lastHandledExploreGuideTrigger else { return }
            guard !parent.viewModel.clusters.isEmpty else { return }

            lastHandledExploreGuideTrigger = parent.exploreGuideTrigger
            exploreGuideView?.showGuide()
        }

        func prewarmBlowSweepIfNeeded(on mapView: MKMapView) {
            guard !didPrewarmBlowSweep else { return }
            didPrewarmBlowSweep = true

            let prewarmPath = UIBezierPath()
            let y = mapView.bounds.height * 0.78
            prewarmPath.move(to: CGPoint(x: -20, y: y))
            prewarmPath.addQuadCurve(
                to: CGPoint(x: mapView.bounds.width + 20, y: y),
                controlPoint: CGPoint(x: mapView.bounds.midX, y: y - 90)
            )

            let container = CALayer()
            container.frame = mapView.bounds
            container.opacity = 0.0
            mapView.layer.addSublayer(container)

            let mask = CAShapeLayer()
            mask.frame = container.bounds
            mask.fillColor = UIColor.clear.cgColor
            mask.strokeColor = UIColor.white.cgColor
            mask.lineWidth = 14
            mask.lineCap = .round
            mask.lineJoin = .round
            mask.path = prewarmPath.cgPath

            let gradient = CAGradientLayer()
            gradient.frame = container.bounds
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = [
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.25).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
            gradient.locations = [0, 0.5, 1]
            gradient.mask = mask

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.addSublayer(gradient)
            CATransaction.commit()

            container.removeFromSuperlayer()
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
                print("[Exploration][Feedback] hit streak=\(hitStreakCount) cluster=\(hitCluster.id)")

                if let fogView = fogScreenView {
                    let screenPoint = mapView.convert(annotation.coordinate, toPointTo: fogView)
                    StardustEmitter.emit(at: screenPoint, in: fogView)
                } else {
                    StardustEmitter.emit(at: point, in: mapView)
                }
            }

            if !isAlreadyInQueue {
                awakenSessionHitCount += 1
                showBlowGuideIfNeeded()

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

                            // 首次唤醒流程按顺序串行：先扫光与入队，再触发首光文案/弹层逻辑
                            DispatchQueue.main.asyncAfter(deadline: .now() + self.firstAwakenCallbackDelayAfterPanel) {
                                self.parent.onFirstAwakenInSession?(hitCluster, point)
                            }
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
            // 刮擦手势只在 Awake 模式生效，避免与地图点击选点竞争
            return parent.isAwakenMode
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
            guard !isBlowSweepRunning else { return }

            let now = CACurrentMediaTime()
            guard now - lastBlowSweepStartTime >= blowSweepTriggerCooldown else { return }

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

            isBlowSweepRunning = true
            parent.isBlowSweepRunning = true
            blowSweepMapView = mapView
            blowSweepStartTime = CACurrentMediaTime()
            lastBlowSweepStartTime = blowSweepStartTime
            blowSweepDidTriggerStartFeedback = false
            blowSweepDidTriggerMidFeedback = false
            blowSweepFrameIndex = 0
            blowSweepPreviousY = 0
            blowSweepHitClusterIds.removeAll(keepingCapacity: true)
            blowSweepHitTargets = visibleAnnotations.map { ann in
                (annotation: ann, point: mapView.convert(ann.coordinate, toPointTo: mapView))
            }

            let h = mapView.bounds.height
            blowSweepStartY = h + 40
            blowSweepEndY = -30

            let container = CALayer()
            container.frame = mapView.bounds
            container.masksToBounds = false
            mapView.layer.addSublayer(container)
            blowSweepContainerLayer = container

            let glowMask = CAShapeLayer()
            glowMask.frame = container.bounds
            glowMask.fillColor = UIColor.clear.cgColor
            glowMask.strokeColor = UIColor.white.cgColor
            glowMask.lineWidth = 18.0
            glowMask.lineCap = .round
            glowMask.lineJoin = .round
            blowSweepGlowMask = glowMask

            let glowGradient = CAGradientLayer()
            glowGradient.frame = container.bounds
            glowGradient.startPoint = CGPoint(x: 0, y: 0.5)
            glowGradient.endPoint = CGPoint(x: 1, y: 0.5)
            glowGradient.colors = [
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.16).cgColor,
                UIColor.white.withAlphaComponent(0.34).cgColor,
                UIColor.white.withAlphaComponent(0.50).cgColor,
                UIColor.white.withAlphaComponent(0.34).cgColor,
                UIColor.white.withAlphaComponent(0.16).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
            glowGradient.locations = [0.0, 0.18, 0.36, 0.5, 0.64, 0.82, 1.0]
            glowGradient.mask = glowMask
            container.addSublayer(glowGradient)
            blowSweepGlowGradient = glowGradient

            let coreMask = CAShapeLayer()
            coreMask.frame = container.bounds
            coreMask.fillColor = UIColor.clear.cgColor
            coreMask.strokeColor = UIColor.white.cgColor
            coreMask.lineWidth = 5.0
            coreMask.lineCap = .round
            coreMask.lineJoin = .round
            blowSweepCoreMask = coreMask

            let coreGradient = CAGradientLayer()
            coreGradient.frame = container.bounds
            coreGradient.startPoint = CGPoint(x: 0, y: 0.5)
            coreGradient.endPoint = CGPoint(x: 1, y: 0.5)
            coreGradient.colors = [
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.28).cgColor,
                UIColor.white.withAlphaComponent(0.52).cgColor,
                UIColor.white.withAlphaComponent(0.74).cgColor,
                UIColor.white.withAlphaComponent(0.88).cgColor,
                UIColor.white.withAlphaComponent(0.74).cgColor,
                UIColor.white.withAlphaComponent(0.52).cgColor,
                UIColor.white.withAlphaComponent(0.28).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
            coreGradient.locations = [0.0, 0.14, 0.28, 0.42, 0.5, 0.58, 0.72, 0.86, 1.0]
            coreGradient.mask = coreMask
            coreGradient.shadowColor = UIColor.white.cgColor
            coreGradient.shadowRadius = 12
            coreGradient.shadowOpacity = 0.9
            coreGradient.shadowOffset = .zero
            container.addSublayer(coreGradient)
            blowSweepCoreGradient = coreGradient

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

            let left = CGPoint(x: -24, y: y)
            let right = CGPoint(x: mapView.bounds.width + 24, y: y)

            let baseArcHeight = max(72, min(140, mapView.bounds.width * 0.18))
            let arcBreath = 0.9 + 0.24 * sin(progress * .pi)
            let arcDriftX = sin(progress * .pi * 1.2) * mapView.bounds.width * 0.03
            let control = CGPoint(x: mapView.bounds.midX + arcDriftX, y: y - baseArcHeight * arcBreath)

            let path = UIBezierPath()
            path.move(to: left)
            path.addQuadCurve(to: right, controlPoint: control)

            let fade = Float(1 - p * 0.38)
            let pulse = Float(0.92 + 0.08 * sin(progress * .pi * 1.6))

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            blowSweepGlowMask?.path = path.cgPath
            blowSweepCoreMask?.path = path.cgPath
            blowSweepGlowGradient?.opacity = fade * pulse
            blowSweepCoreGradient?.opacity = min(1.0, (fade + 0.12) * pulse)
            CATransaction.commit()

            blowSweepFrameIndex += 1
            let frameStride: Int
            if progress < 0.35 {
                frameStride = 2
            } else if progress < 0.62 {
                frameStride = 3
            } else if progress < 0.80 {
                frameStride = 5
            } else {
                frameStride = 8
            }

            // 顶部收尾阶段最容易抖：仅在弧线真正扫过目标纵向区间时判定命中，且每个 cluster 只触发一次。
            let lowY = min(blowSweepPreviousY, y)
            let highY = max(blowSweepPreviousY, y)
            let shouldRunHitTestThisFrame = (blowSweepFrameIndex % frameStride == 0)

            if shouldRunHitTestThisFrame {
                let arcBandHalfWidth: CGFloat
                if progress < 0.35 {
                    arcBandHalfWidth = 34
                } else if progress < 0.62 {
                    arcBandHalfWidth = 28
                } else if progress < 0.80 {
                    arcBandHalfWidth = 22
                } else {
                    arcBandHalfWidth = 18
                }

                for target in blowSweepHitTargets {
                    if blowSweepHitClusterIds.contains(target.annotation.cluster.id) { continue }
                    if target.point.y < lowY - arcBandHalfWidth || target.point.y > highY + arcBandHalfWidth { continue }

                    let d = distanceFromPoint(target.point, toLineSegmentStart: left, end: right)
                    if d <= arcBandHalfWidth {
                        blowSweepHitClusterIds.insert(target.annotation.cluster.id)
                        handleClusterHit(annotation: target.annotation, point: target.point, mapView: mapView)
                    }
                }
            }

            blowSweepPreviousY = y

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
            isBlowSweepRunning = false
            parent.isBlowSweepRunning = false
            blowSweepHitTargets.removeAll(keepingCapacity: true)
            blowSweepHitClusterIds.removeAll(keepingCapacity: true)
            blowSweepPreviousY = 0

            blowSweepCoreGradient?.removeFromSuperlayer()
            blowSweepGlowGradient?.removeFromSuperlayer()
            blowSweepContainerLayer?.removeFromSuperlayer()

            blowSweepCoreGradient = nil
            blowSweepGlowGradient = nil
            blowSweepCoreMask = nil
            blowSweepGlowMask = nil
            blowSweepContainerLayer = nil
        }

        private func easeOut(_ t: CGFloat) -> CGFloat {
            1 - pow(1 - t, 3)
        }

        private func pointOnQuadratic(from p0: CGPoint, control p1: CGPoint, to p2: CGPoint, t: CGFloat) -> CGPoint {
            let u = 1 - t
            let tt = t * t
            let uu = u * u
            let x = uu * p0.x + 2 * u * t * p1.x + tt * p2.x
            let y = uu * p0.y + 2 * u * t * p1.y + tt * p2.y
            return CGPoint(x: x, y: y)
        }

        private func distanceFromPoint(_ p: CGPoint, toLineSegmentStart a: CGPoint, end b: CGPoint) -> CGFloat {
            let abx = b.x - a.x
            let aby = b.y - a.y
            let apx = p.x - a.x
            let apy = p.y - a.y
            let ab2 = abx * abx + aby * aby
            guard ab2 > 0.0001 else {
                let dx = p.x - a.x
                let dy = p.y - a.y
                return sqrt(dx * dx + dy * dy)
            }

            let t = max(0, min(1, (apx * abx + apy * aby) / ab2))
            let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
            let dx = p.x - proj.x
            let dy = p.y - proj.y
            return sqrt(dx * dx + dy * dy)
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

        let scratchGuideView = ScratchGuideOverlayView()
        scratchGuideView.translatesAutoresizingMaskIntoConstraints = false
        scratchGuideView.isUserInteractionEnabled = false
        container.addSubview(scratchGuideView)
        context.coordinator.scratchGuideView = scratchGuideView

        let blowGuideView = BlowGuideBarView()
        blowGuideView.translatesAutoresizingMaskIntoConstraints = false
        blowGuideView.isUserInteractionEnabled = false
        container.addSubview(blowGuideView)
        context.coordinator.blowGuideView = blowGuideView

        let exploreGuideView = ExploreTapGuideView()
        exploreGuideView.translatesAutoresizingMaskIntoConstraints = false
        exploreGuideView.isUserInteractionEnabled = false
        container.addSubview(exploreGuideView)
        context.coordinator.exploreGuideView = exploreGuideView

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: container.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            fogView.topAnchor.constraint(equalTo: container.topAnchor),
            fogView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fogView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fogView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scratchGuideView.topAnchor.constraint(equalTo: container.topAnchor),
            scratchGuideView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scratchGuideView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scratchGuideView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            blowGuideView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            blowGuideView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            blowGuideView.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            blowGuideView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),

            exploreGuideView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            exploreGuideView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 82),
            exploreGuideView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.82),
            exploreGuideView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])

        let span = MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.0, longitude: 103.0), span: span)
        mapView.setRegion(region, animated: false)

        context.coordinator.applyAnnotations(to: mapView)
        context.coordinator.setupGestures(for: mapView)
        context.coordinator.prewarmBlowSweepIfNeeded(on: mapView)

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        guard let mapView = uiView.subviews.first(where: { $0 is MKMapView }) as? MKMapView,
              let fogView = uiView.subviews.first(where: { $0 is FogScreenView }) as? FogScreenView else { return }

        context.coordinator.handleAwakenModeTransitionIfNeeded()
        context.coordinator.showExploreGuideIfNeeded()

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

            let coord = GeoCoordinateTransform.wgs84ToGcj02IfNeeded(latitude: c.centerLatitude, longitude: c.centerLongitude)
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

            let coord = GeoCoordinateTransform.wgs84ToGcj02IfNeeded(latitude: c.centerLatitude, longitude: c.centerLongitude)
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

final class ScratchGuideOverlayView: UIView {
    private let badgeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let label = UILabel()
    private let traceLayer = CAShapeLayer()
    private var badgeTopConstraint: NSLayoutConstraint?
    private var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        alpha = 0

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.layer.cornerRadius = 14
        badgeView.clipsToBounds = true
        badgeView.alpha = 0.95
        addSubview(badgeView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "划过光点，解锁记忆"
        label.textColor = UIColor.white.withAlphaComponent(0.96)
        label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        badgeView.contentView.addSubview(label)

        badgeTopConstraint = badgeView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 84)

        NSLayoutConstraint.activate([
            badgeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeTopConstraint!,

            label.leadingAnchor.constraint(equalTo: badgeView.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: badgeView.contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: badgeView.contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: badgeView.contentView.bottomAnchor, constant: -8)
        ])

        traceLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        traceLayer.fillColor = UIColor.clear.cgColor
        traceLayer.lineWidth = 3
        traceLayer.lineCap = .round
        traceLayer.lineJoin = .round
        traceLayer.lineDashPattern = [8, 8]
        traceLayer.opacity = 0
        layer.addSublayer(traceLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        traceLayer.frame = bounds
        updateTracePath()
    }

    func showGuide() {
        guard !isShowing else { return }
        isShowing = true
        alpha = 0

        badgeTopConstraint?.constant = 84
        label.transform = .identity

        traceLayer.removeAllAnimations()
        traceLayer.opacity = 0.95
        updateTracePath()

        UIView.animate(withDuration: 0.24) {
            self.alpha = 1
        }

        startTraceAnimationLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pinToTopAsAwakeIndicator()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.fadeOutTraceOnly()
        }
    }

    func hideGuide(animated: Bool) {
        isShowing = false
        let animations = {
            self.alpha = 0
            self.traceLayer.opacity = 0
        }
        let completion: (Bool) -> Void = { _ in
            self.traceLayer.removeAllAnimations()
            self.badgeTopConstraint?.constant = 84
            self.label.transform = .identity
        }

        if animated {
            UIView.animate(withDuration: 0.22, animations: animations, completion: completion)
        } else {
            animations()
            completion(true)
        }
    }

    private func pinToTopAsAwakeIndicator() {
        guard isShowing else { return }
        badgeTopConstraint?.constant = 10

        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut]) {
            self.label.transform = CGAffineTransform(scaleX: 0.84, y: 0.84)
            self.layoutIfNeeded()
        }
    }

    private func fadeOutTraceOnly() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = traceLayer.presentation()?.opacity ?? traceLayer.opacity
        fade.toValue = 0
        fade.duration = 0.24
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        traceLayer.add(fade, forKey: "trace.fadeout")
        traceLayer.opacity = 0
    }

    private func updateTracePath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let y = bounds.height * 0.55
        let start = CGPoint(x: bounds.width * 0.24, y: y)
        let end = CGPoint(x: bounds.width * 0.76, y: y)
        let control = CGPoint(x: bounds.width * 0.5, y: y - 52)

        let path = UIBezierPath()
        path.move(to: start)
        path.addQuadCurve(to: end, controlPoint: control)
        traceLayer.path = path.cgPath
    }

    private func startTraceAnimationLoop() {
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.toValue = 1
        stroke.duration = 1.0
        stroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 0.95
        fade.duration = 1.0
        fade.autoreverses = true

        let group = CAAnimationGroup()
        group.animations = [stroke, fade]
        group.duration = 1.0
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        traceLayer.add(group, forKey: "trace.loop")
    }
}

final class BlowGuideBarView: UIView {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let iconView = UIImageView(image: UIImage(systemName: "wind"))
    private let textLabel = UILabel()
    private let pulseLayer = CAGradientLayer()
    private var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        layer.cornerRadius = 16
        layer.masksToBounds = true

        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = UIColor.white.withAlphaComponent(0.92)
        iconView.contentMode = .scaleAspectFit

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.text = "试试吹一口气，一键解锁当前屏幕光点"
        textLabel.textColor = UIColor.white.withAlphaComponent(0.94)
        textLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        textLabel.numberOfLines = 2

        addSubview(iconView)
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8)
        ])

        layer.addSublayer(pulseLayer)
        pulseLayer.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(0.22).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        pulseLayer.startPoint = CGPoint(x: 0, y: 0.5)
        pulseLayer.endPoint = CGPoint(x: 1, y: 0.5)
        pulseLayer.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        pulseLayer.frame = bounds
    }

    func showGuide() {
        guard !isShowing else { return }
        isShowing = true

        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 10)

        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.06
        anim.toValue = 0.35
        anim.duration = 1.1
        anim.autoreverses = true
        anim.repeatCount = .infinity
        pulseLayer.add(anim, forKey: "pulse.opacity")

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.hideGuide(animated: true)
        }
    }

    func hideGuide(animated: Bool) {
        isShowing = false
        let animations = {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 10)
        }
        let completion: (Bool) -> Void = { _ in
            self.transform = .identity
            self.pulseLayer.removeAllAnimations()
        }

        if animated {
            UIView.animate(withDuration: 0.22, animations: animations, completion: completion)
        } else {
            animations()
            completion(true)
        }
    }
}

final class ExploreTapGuideView: UIView {
    private let badgeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let iconWrapView = UIView()
    private let iconView = UIImageView(image: UIImage(systemName: "hand.tap.fill"))
    private let label = UILabel()
    private let rippleLayer = CAShapeLayer()
    private var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        layer.cornerRadius = 14
        layer.masksToBounds = true

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)

        iconWrapView.translatesAutoresizingMaskIntoConstraints = false
        iconWrapView.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        iconWrapView.layer.cornerRadius = 12
        badgeView.contentView.addSubview(iconWrapView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = UIColor.white.withAlphaComponent(0.95)
        iconWrapView.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "点击光点，进入唤醒模式"
        label.textColor = UIColor.white.withAlphaComponent(0.96)
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        badgeView.contentView.addSubview(label)

        NSLayoutConstraint.activate([
            badgeView.topAnchor.constraint(equalTo: topAnchor),
            badgeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            badgeView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconWrapView.leadingAnchor.constraint(equalTo: badgeView.contentView.leadingAnchor, constant: 12),
            iconWrapView.centerYAnchor.constraint(equalTo: badgeView.contentView.centerYAnchor),
            iconWrapView.widthAnchor.constraint(equalToConstant: 24),
            iconWrapView.heightAnchor.constraint(equalToConstant: 24),

            iconView.centerXAnchor.constraint(equalTo: iconWrapView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconWrapView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.topAnchor.constraint(equalTo: badgeView.contentView.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: badgeView.contentView.bottomAnchor, constant: -11),
            label.leadingAnchor.constraint(equalTo: iconWrapView.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: badgeView.contentView.trailingAnchor, constant: -14)
        ])

        rippleLayer.fillColor = UIColor.clear.cgColor
        rippleLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        rippleLayer.lineWidth = 1.8
        rippleLayer.opacity = 0
        iconWrapView.layer.addSublayer(rippleLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        rippleLayer.frame = iconWrapView.bounds
        let d = min(iconWrapView.bounds.width, iconWrapView.bounds.height) - 6
        rippleLayer.path = UIBezierPath(ovalIn: CGRect(
            x: (iconWrapView.bounds.width - d) * 0.5,
            y: (iconWrapView.bounds.height - d) * 0.5,
            width: d,
            height: d
        )).cgPath
    }

    func showGuide() {
        guard !isShowing else { return }
        isShowing = true

        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 10)
        iconWrapView.layer.removeAllAnimations()
        iconView.layer.removeAllAnimations()
        rippleLayer.removeAllAnimations()

        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }

        startTapAnimationLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.hideGuide(animated: true)
        }
    }

    func hideGuide(animated: Bool) {
        isShowing = false
        let animations = {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 10)
        }
        let completion: (Bool) -> Void = { _ in
            self.transform = .identity
            self.iconWrapView.layer.removeAllAnimations()
            self.iconView.layer.removeAllAnimations()
            self.rippleLayer.removeAllAnimations()
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: animations, completion: completion)
        } else {
            animations()
            completion(true)
        }
    }

    private func startTapAnimationLoop() {
        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = 1.0
        press.toValue = 0.84
        press.duration = 0.22
        press.autoreverses = true
        press.repeatCount = .infinity
        press.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconWrapView.layer.add(press, forKey: "tap.press")

        let hand = CABasicAnimation(keyPath: "transform.scale")
        hand.fromValue = 1.0
        hand.toValue = 0.9
        hand.duration = 0.22
        hand.autoreverses = true
        hand.repeatCount = .infinity
        hand.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        iconView.layer.add(hand, forKey: "tap.hand")

        let rippleScale = CABasicAnimation(keyPath: "transform.scale")
        rippleScale.fromValue = 0.55
        rippleScale.toValue = 1.55
        rippleScale.duration = 0.8
        rippleScale.repeatCount = .infinity
        rippleScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let rippleOpacity = CABasicAnimation(keyPath: "opacity")
        rippleOpacity.fromValue = 0.9
        rippleOpacity.toValue = 0.0
        rippleOpacity.duration = 0.8
        rippleOpacity.repeatCount = .infinity

        let group = CAAnimationGroup()
        group.animations = [rippleScale, rippleOpacity]
        group.duration = 0.8
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        rippleLayer.add(group, forKey: "tap.ripple")
    }
}
