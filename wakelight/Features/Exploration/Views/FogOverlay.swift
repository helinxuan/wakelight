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
    private let animationDuration: TimeInterval = 0.6
    
    private var displayLink: CADisplayLink?
    private var isAnimating: Bool = false

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay = overlay as? FogOverlay else { return }
        
        // DEBUG LOG: 确认渲染器正在工作
        if fogOverlay.animatingClusterId != nil {
            print("DEBUG: Fog Draw - Animating: \(fogOverlay.animatingClusterId?.uuidString ?? "nil"), RevealedCount: \(fogOverlay.revealedClusterIds.count)")
        }

        let rect = self.rect(for: mapRect)
        context.setFillColor(fogColor.cgColor)
        context.fill(rect)

        context.setBlendMode(.destinationOut)
        context.setFillColor(UIColor.black.cgColor)

        let currentTime = CACurrentMediaTime()
        var hasActiveAnimation = false

        for cluster in fogOverlay.clusters {
            let coord = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
            let mapPoint = MKMapPoint(coord)
            let point = self.point(for: mapPoint)

            var r: CGFloat = 0
            
            if cluster.id == fogOverlay.animatingClusterId, let start = fogOverlay.animationStartTime {
                let elapsed = currentTime - start
                let progress = min(1.0, elapsed / animationDuration)
                
                // 3.1.2: 从 0 开始爆发散开成洞
                r = awakenedRadiusPoints * CGFloat(progress)
                
                if progress < 1.0 {
                    hasActiveAnimation = true
                }
            } else if fogOverlay.revealedClusterIds.contains(cluster.id) {
                r = awakenedRadiusPoints
            } else {
                r = revealRadiusPoints
            }
            
            if r > 0 {
                let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                context.fillEllipse(in: circleRect)
            }
        }

        context.setBlendMode(.normal)
        
        if hasActiveAnimation {
            isAnimating = true
            startDisplayLinkIfNeeded()
        } else {
            isAnimating = false
            stopDisplayLink()
        }
    }
    
    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func displayLinkFired() {
        setNeedsDisplay()
    }
}
