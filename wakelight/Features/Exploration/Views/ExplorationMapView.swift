import SwiftUI
import MapKit
import UIKit

struct ExplorationMapView: UIViewRepresentable {
    @ObservedObject var viewModel: ExploreViewModel
    @Binding var selectedCluster: PlaceCluster?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ExplorationMapView
        private var currentAnnotations: [ClusterAnnotation] = []

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

            if cluster.hasStory {
                let reuseId = "story"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? StoryAnnotationView
                    ?? StoryAnnotationView(annotation: annotation, reuseIdentifier: reuseId)

                view.annotation = annotation
                view.canShowCallout = true
                
                // 添加“阅读故事”详情按钮
                let detailButton = UIButton(type: .detailDisclosure)
                view.rightCalloutAccessoryView = detailButton
                
                let localId = parent.viewModel.storyThumbnails[cluster.id]
                view.configure(with: localId)
                return view
            } else {
                let reuseId = "cluster"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseId)

                view.annotation = annotation
                view.canShowCallout = true
                
                // 普通光点也添加详情按钮，以便点击打开记忆面板
                let detailButton = UIButton(type: .detailDisclosure)
                view.rightCalloutAccessoryView = detailButton
                
                view.markerTintColor = UIColor.systemYellow
                view.glyphImage = UIImage(systemName: "sparkle")
                return view
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            parent.selectedCluster = ann.cluster
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            if parent.selectedCluster?.id != ann.cluster.id {
                Task { @MainActor in
                    parent.selectedCluster = ann.cluster
                }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
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
        context.coordinator.applyAnnotations(to: uiView)
    }
}
