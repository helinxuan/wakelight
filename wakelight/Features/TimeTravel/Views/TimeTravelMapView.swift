import SwiftUI
import MapKit
import UIKit

struct TimeTravelMapView: UIViewRepresentable {
    let nodes: [TimeRouteNode]
    let selectedIndex: Int

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TimeTravelMapView

        private var currentPolyline: MKPolyline?
        private var currentAnnotations: [TimeTravelNodeAnnotation] = []

        init(parent: TimeTravelMapView) {
            self.parent = parent
        }

        func rebuildOverlaysAndAnnotations(on mapView: MKMapView) {
            if let poly = currentPolyline {
                mapView.removeOverlay(poly)
            }
            mapView.removeAnnotations(currentAnnotations)

            let coords: [CLLocationCoordinate2D] = parent.nodes.compactMap { node in
                guard let cluster = node.placeCluster else { return nil }
                return CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            }

            if coords.count >= 2 {
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                currentPolyline = polyline
                mapView.addOverlay(polyline)
            } else {
                currentPolyline = nil
            }

            currentAnnotations = parent.nodes.enumerated().compactMap { idx, node in
                guard let cluster = node.placeCluster else { return nil }
                return TimeTravelNodeAnnotation(index: idx, node: node, coordinate: CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude))
            }
            mapView.addAnnotations(currentAnnotations)
        }

        func updateSelection(on mapView: MKMapView) {
            for ann in currentAnnotations {
                if ann.index == parent.selectedIndex {
                    mapView.selectAnnotation(ann, animated: true)
                }
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
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.85)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let ttAnn = annotation as? TimeTravelNodeAnnotation else { return nil }

            let reuseId = "timeTravelNode"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)

            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = (ttAnn.index == parent.selectedIndex) ? UIColor.systemOrange : UIColor.systemGray
            view.glyphImage = UIImage(systemName: "sparkle")
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
        node.displayTitle ?? "Story"
    }

    var subtitle: String? {
        node.displaySummary
    }
}
