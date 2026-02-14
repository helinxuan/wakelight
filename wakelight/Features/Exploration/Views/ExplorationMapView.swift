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
        private var fogOverlay: FogOverlay?
        var parent: ExplorationMapView
        var currentAnnotations: [ClusterAnnotation] = []
        private var panGesture: UIPanGestureRecognizer?

        init(parent: ExplorationMapView) {
            self.parent = parent
        }

        func setupGestures(for mapView: MKMapView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false // 允许手势不中断其他交互
            mapView.addGestureRecognizer(pan)
            self.panGesture = pan
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.isAwakenMode else { return }

            // 只在滑动过程中命中（避免 begin/end 重复）
            guard gesture.state == .changed else { return }

            let location = gesture.location(in: gesture.view)
            let mapView = gesture.view as! MKMapView

            // 3.1.2: 扩大 hit-test 响应区
            let hitRect = CGRect(x: location.x - 22, y: location.y - 22, width: 44, height: 44)

            for annotation in currentAnnotations {
                let point = mapView.convert(annotation.coordinate, toPointTo: mapView)
                if hitRect.contains(point) {
                    let hitCluster = annotation.cluster

                    // 去重：同一个 cluster 只入队一次
                    if parent.awakenQueue.contains(where: { $0.id == hitCluster.id }) {
                        return
                    }

                    UIImpactFeedbackGenerator(style: .light).impactOccurred()

                    Task { @MainActor in
                        parent.awakenQueue.append(hitCluster)
                        parent.revealedClusterIds.insert(hitCluster.id)

                        // 3.1.2: 触发显影动画
                        if let fog = self.fogOverlay {
                            fog.animatingClusterId = hitCluster.id
                            fog.animationStartTime = CACurrentMediaTime()
                            // 找到 renderer 并通知它重绘
                            if let renderer = mapView.renderer(for: fog) as? FogOverlayRenderer {
                                renderer.setNeedsDisplay()
                            } else {
                                mapView.setNeedsDisplay()
                            }
                        }

                        // 用队列的“最新命中”作为当前选中（用于动画/锚点等）
                        parent.selectedCluster = hitCluster
                    }
                    return
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 在唤醒模式下，我们希望接管单指滑动，但允许地图自身的缩放等手势
            return true
        }

        func applyAnnotations(to mapView: MKMapView) {
            mapView.removeAnnotations(currentAnnotations)

            let annotations = parent.viewModel.clusters.map { ClusterAnnotation(cluster: $0) }
            currentAnnotations = annotations
            mapView.addAnnotations(annotations)
            
            // 更新迷雾
            if let oldFog = fogOverlay {
                mapView.removeOverlay(oldFog)
            }
            let newFog = FogOverlay(clusters: parent.viewModel.clusters, revealedClusterIds: parent.revealedClusterIds)
            fogOverlay = newFog
            mapView.addOverlay(newFog)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let fog = overlay as? FogOverlay {
                return FogOverlayRenderer(overlay: fog)
            }
            return MKOverlayRenderer(overlay: overlay)
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
            view.rightCalloutAccessoryView = nil

            view.isStoryPoint = cluster.hasStory
            view.updateStyle()
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }

            // 3.1.2: 点击光点只进入“城市级锁定/唤醒模式”，不直接打开记忆面板
            Task { @MainActor in
                parent.isAwakenMode = true
            }

            // 飞入城市级（MVP：固定缩放到一个较近的跨度）
            let region = MKCoordinateRegion(
                center: ann.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
            )
            mapView.setRegion(region, animated: true)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is ClusterAnnotation else { return }

            // 3.1.2: 唤醒模式下不因“取消选中”而关闭面板；退出由上层统一控制
            if parent.isAwakenMode {
                return
            }

            if parent.selectedCluster != nil {
                Task { @MainActor in
                    parent.selectedCluster = nil
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .none

        let span = MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.0, longitude: 103.0),
            span: span
        )
        mapView.setRegion(region, animated: false)

        context.coordinator.applyAnnotations(to: mapView)
        context.coordinator.setupGestures(for: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // 3.1.2: 唤醒模式下禁止单指拖动地图，避免与唤醒滑动冲突
        uiView.isScrollEnabled = !isAwakenMode

        // 避免每次 SwiftUI 刷新都移除/重建 annotation，导致选中状态和 callout 被打断
        if context.coordinator.currentAnnotations.count != viewModel.clusters.count {
            context.coordinator.applyAnnotations(to: uiView)
        }
    }
}
