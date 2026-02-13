import SwiftUI
import MapKit
import UIKit

struct ExplorationMapView: UIViewRepresentable {
    @ObservedObject var viewModel: ExploreViewModel
    @Binding var selectedCluster: PlaceCluster?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ExplorationMapView
        var currentAnnotations: [ClusterAnnotation] = []

        init(parent: ExplorationMapView) {
            self.parent = parent
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
            view.canShowCallout = true

            // 点击打开记忆面板
            let detailButton = UIButton(type: .detailDisclosure)
            view.rightCalloutAccessoryView = detailButton

            view.isStoryPoint = cluster.hasStory
            view.updateStyle()
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            parent.selectedCluster = ann.cluster
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            print("DEBUG: Map didSelect - cluster: \((view.annotation as? ClusterAnnotation)?.cluster.id.uuidString ?? "unknown")")
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            if parent.selectedCluster?.id != ann.cluster.id {
                Task { @MainActor in
                    parent.selectedCluster = ann.cluster
                }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            print("DEBUG: Map didDeselect")
            guard view.annotation is ClusterAnnotation else { return }
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
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // 避免每次 SwiftUI 刷新都移除/重建 annotation，导致选中状态和 callout 被打断
        if context.coordinator.currentAnnotations.count != viewModel.clusters.count {
            context.coordinator.applyAnnotations(to: uiView)
        }
    }
}
