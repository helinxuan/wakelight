import MapKit
import UIKit

/// 覆盖全球的迷雾 Overlay
final class FogOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var boundingMapRect: MKMapRect = .world

    var clusters: [PlaceCluster]

    init(clusters: [PlaceCluster]) {
        self.clusters = clusters
        super.init()
    }
}

/// 迷雾渲染器：半透明黑底 + 光点附近“稀薄/退散”的洞
final class FogOverlayRenderer: MKOverlayRenderer {
    private let fogColor = UIColor.black.withAlphaComponent(0.65)

    // 这里用「像素半径」更直观：随缩放变化自然变大变小
    private let revealRadiusPoints: CGFloat = 60

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay = overlay as? FogOverlay else { return }

        let rect = self.rect(for: mapRect)
        context.setFillColor(fogColor.cgColor)
        context.fill(rect)

        // 用 clear 挖洞
        context.setBlendMode(.clear)

        for cluster in fogOverlay.clusters {
            let coord = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            let mapPoint = MKMapPoint(coord)

            // mapPoint -> view point
            let point = self.point(for: mapPoint)

            let r = revealRadiusPoints
            let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            context.fillEllipse(in: circleRect)
        }

        context.setBlendMode(.normal)
    }
}
