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

        private weak var flowRenderer: MKPolylineRenderer?
        private var displayLink: CADisplayLink?
        private var dashPhase: CGFloat = 0
        private var lastFrameTime: CFTimeInterval = 0

        private let dashGap: CGFloat = 12
        private let cycleDuration: CFTimeInterval = 3.0

        init(parent: TimeTravelMapView) {
            self.parent = parent
            super.init()
        }

        deinit {
            stopFlowAnimation()
        }

        func rebuildOverlaysAndAnnotations(on mapView: MKMapView) {
            if !currentOverlays.isEmpty {
                mapView.removeOverlays(currentOverlays)
            }
            mapView.removeAnnotations(currentAnnotations)

            let coords: [CLLocationCoordinate2D] = parent.nodes.compactMap { node in
                guard let cluster = node.placeCluster else { return nil }
                return CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            }

            currentOverlays = buildRouteOverlays(from: coords)
            if !currentOverlays.isEmpty {
                mapView.addOverlays(currentOverlays)
                startFlowAnimationIfNeeded()
            } else {
                stopFlowAnimation()
            }

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
            let flowLine = MKGeodesicPolyline(coordinates: coords, count: coords.count)
            flowLine.title = "route_flow_dashed"
            return [flowLine]
        }

        private func startFlowAnimationIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            dashPhase = 0
            lastFrameTime = 0
        }

        private func stopFlowAnimation() {
            displayLink?.invalidate()
            displayLink = nil
            dashPhase = 0
            lastFrameTime = 0
        }

        @objc private func handleDisplayLink(_ link: CADisplayLink) {
            guard let renderer = flowRenderer else { return }

            if lastFrameTime == 0 {
                lastFrameTime = link.timestamp
                return
            }

            let delta = link.timestamp - lastFrameTime
            lastFrameTime = link.timestamp

            let speed = dashGap / CGFloat(cycleDuration)
            dashPhase = (dashPhase + CGFloat(delta) * speed).truncatingRemainder(dividingBy: dashGap)

            renderer.lineDashPhase = dashPhase
            renderer.setNeedsDisplay()
        }

        func updateSelection(on mapView: MKMapView) {
            mapView.selectedAnnotations.removeAll()
            for ann in currentAnnotations where ann.index == parent.selectedIndex {
                mapView.selectAnnotation(ann, animated: true)
            }

            if parent.nodes.indices.contains(parent.selectedIndex),
               let cluster = parent.nodes[parent.selectedIndex].placeCluster {
                let center = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
                let camera = MKMapCamera(lookingAtCenter: center, fromDistance: 1_200_000, pitch: 50, heading: 0)

                UIView.animate(withDuration: 1.1, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                    mapView.setCamera(camera, animated: false)
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
            renderer.strokeColor = UIColor(red: 0xA8 / 255.0, green: 0xEE / 255.0, blue: 0xFF / 255.0, alpha: 0.88)
            renderer.lineWidth = 4
            renderer.lineDashPattern = [6, 12]
            renderer.lineDashPhase = dashPhase

            flowRenderer = renderer
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
