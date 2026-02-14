import MapKit
import UIKit

/// 覆盖全球的迷雾 Overlay
final class FogOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var boundingMapRect: MKMapRect = .world

    var clusters: [PlaceCluster]
    var revealedClusterIds: Set<UUID>
    
    // 3.1.2: 动画状态
    var animatingClusterId: UUID?
    var animationStartTime: TimeInterval?

    init(clusters: [PlaceCluster], revealedClusterIds: Set<UUID>) {
        self.clusters = clusters
        self.revealedClusterIds = revealedClusterIds
        super.init()
    }
}

/// 迷雾渲染器：支持动态显影动画
final class FogOverlayRenderer: MKOverlayRenderer {
    private let fogColor = UIColor.black.withAlphaComponent(0.65)
    private let revealRadiusPoints: CGFloat = 60
    private let awakenedRadiusPoints: CGFloat = 120
    private let animationDuration: TimeInterval = 0.5
    
    private var displayLink: CADisplayLink?

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay = overlay as? FogOverlay else { return }

        let rect = self.rect(for: mapRect)
        context.setFillColor(fogColor.cgColor)
        context.fill(rect)

        context.setBlendMode(.clear)

        let currentTime = CACurrentMediaTime()

        for cluster in fogOverlay.clusters {
            let coord = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            let mapPoint = MKMapPoint(coord)
            let point = self.point(for: mapPoint)

            var r = revealRadiusPoints
            
            if cluster.id == fogOverlay.animatingClusterId, let start = fogOverlay.animationStartTime {
                let progress = min(1.0, (currentTime - start) / animationDuration)
                r = revealRadiusPoints + (awakenedRadiusPoints - revealRadiusPoints) * CGFloat(progress)
                
                if progress < 1.0 {
                    // 如果还在动画中，确保下一帧继续重绘
                    startDisplayLinkIfNeeded()
                } else {
                    // 动画结束，状态落位
                    stopDisplayLinkIfDone()
                }
            } else if fogOverlay.revealedClusterIds.contains(cluster.id) {
                r = awakenedRadiusPoints
            }
            
            let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            context.fillEllipse(in: circleRect)
        }

        context.setBlendMode(.normal)
    }
    
    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopDisplayLinkIfDone() {
        // 这里只是停止，具体的状态清理由外部 handlePan 后的状态机决定或等待下一次 redraw
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func displayLinkFired() {
        setNeedsDisplay()
    }
}
