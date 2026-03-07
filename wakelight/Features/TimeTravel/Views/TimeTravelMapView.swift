import SwiftUI
import MapKit
import UIKit

struct TimeTravelMapView: UIViewRepresentable {
    let nodes: [TimeRouteNode]
    let selectedIndex: Int

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TimeTravelMapView

        private var currentOverlays: [MKOverlay] = []
        private var currentAnnotations: [TimeTravelNodeAnnotation] = []
        private var lastRouteSignature: [String] = []

        init(parent: TimeTravelMapView) {
            self.parent = parent
            super.init()
        }

        func rebuildOverlaysAndAnnotations(on mapView: MKMapView) {
            let coords: [CLLocationCoordinate2D] = parent.nodes.compactMap { node in
                guard let cluster = node.placeCluster else { return nil }
                return CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            }

            let routeSignature = coords.map { "\(round($0.latitude * 10_000) / 10_000),\(round($0.longitude * 10_000) / 10_000)" }
            let routeChanged = routeSignature != lastRouteSignature

            if routeChanged {
                if !currentOverlays.isEmpty {
                    mapView.removeOverlays(currentOverlays)
                }

                currentOverlays = buildRouteOverlays(from: coords)
                if !currentOverlays.isEmpty {
                    mapView.addOverlays(currentOverlays)
                }

                lastRouteSignature = routeSignature
            }

            mapView.removeAnnotations(currentAnnotations)
            currentAnnotations = parent.nodes.enumerated().compactMap { idx, node in
                guard let cluster = node.placeCluster else { return nil }
                return TimeTravelNodeAnnotation(
                    index: idx,
                    node: node,
                    coordinate: CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
                )
            }
            mapView.addAnnotations(currentAnnotations)
        }

        private func buildRouteOverlays(from coords: [CLLocationCoordinate2D]) -> [MKOverlay] {
            guard coords.count >= 2 else { return [] }
            // 稳定优先：使用 MKPolyline，避免 geodesic 在高纬和缩放时出现段重算抖动
            let flowLine = MKPolyline(coordinates: coords, count: coords.count)
            flowLine.title = "route_flow_dashed_stable"
            return [flowLine]
        }

        func updateSelection(on mapView: MKMapView) {
            mapView.selectedAnnotations.removeAll()
            for ann in currentAnnotations where ann.index == parent.selectedIndex {
                mapView.selectAnnotation(ann, animated: true)
            }

            if parent.nodes.indices.contains(parent.selectedIndex),
               let cluster = parent.nodes[parent.selectedIndex].placeCluster {
                let focus = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)

                // 统一缩放级别，避免不同故事点出现忽远忽近
                var region = MKCoordinateRegion(
                    center: focus,
                    span: MKCoordinateSpan(latitudeDelta: 3.0, longitudeDelta: 3.0)
                )
                region = mapView.regionThatFits(region)

                UIView.animate(withDuration: 1.0, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    mapView.setRegion(region, animated: false)

                    // 把焦点提到上半屏约 1/3，给底部故事卡片腾位置
                    let desiredY = mapView.bounds.height * 0.33
                    let desiredPoint = CGPoint(x: mapView.bounds.midX, y: desiredY)
                    let coordAtDesiredPoint = mapView.convert(desiredPoint, toCoordinateFrom: mapView)

                    let adjustedCenter = CLLocationCoordinate2D(
                        latitude: region.center.latitude + (focus.latitude - coordAtDesiredPoint.latitude),
                        longitude: region.center.longitude + (focus.longitude - coordAtDesiredPoint.longitude)
                    )
                    mapView.setCenter(adjustedCenter, animated: false)
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.strokeColor = UIColor(red: 0xA8 / 255.0, green: 0xEE / 255.0, blue: 0xFF / 255.0, alpha: 0.84)
            renderer.lineWidth = 2.5
            renderer.lineDashPattern = [4, 8]
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard annotation is TimeTravelNodeAnnotation else { return nil }

            let reuseId = "timeTravelLightPoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? LightPointAnnotationView
                ?? LightPointAnnotationView(annotation: annotation, reuseIdentifier: reuseId)

            view.annotation = annotation
            view.canShowCallout = false
            view.isHalfRevealed = false
            view.isStoryPoint = true
            view.updateStyle()
            return view
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.userTrackingMode = .none

        let span = MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.0, longitude: 103.0), span: span)
        mapView.setRegion(region, animated: false)

        context.coordinator.rebuildOverlaysAndAnnotations(on: mapView)
        context.coordinator.updateSelection(on: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuildOverlaysAndAnnotations(on: uiView)
        context.coordinator.updateSelection(on: uiView)
    }
}

final class TimeTravelNodeAnnotation: NSObject, MKAnnotation {
    let index: Int
    let node: TimeRouteNode
    let coordinate: CLLocationCoordinate2D

    init(index: Int, node: TimeRouteNode, coordinate: CLLocationCoordinate2D) {
        self.index = index
        self.node = node
        self.coordinate = coordinate
        super.init()
    }

    var title: String? {
        if let location = node.displayLocation, !location.isEmpty {
            return Self.clip(location, maxLength: 16)
        }
        if let summary = node.displaySummary, !summary.isEmpty {
            return Self.clip(summary, maxLength: 16)
        }
        return "第\(index + 1)站"
    }

    var subtitle: String? {
        node.displayTitle
    }

    private static func clip(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end]) + "…"
    }
}
