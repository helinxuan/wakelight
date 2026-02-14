import MapKit
import UIKit

/// 覆盖全球的迷雾 Overlay
final class FogOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var boundingMapRect: MKMapRect = .world

    var clusters: [PlaceCluster]
    var revealedClusterIds: Set<UUID>


    // 动画状态
    var animatingClusterId: UUID?
    var animationStartTime: TimeInterval?

    // 刮痕（用于滑动“刮开”迷雾效果）。由 MapView 在 overlay 重建时拷贝保持状态。
    var scratchPaths: [UIBezierPath] = []
    var scratchLineWidthPoints: CGFloat = 22

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

    private let holeBaseRadiusPoints: CGFloat = 34
    private let holeMaxRadiusPoints: CGFloat = 170
    private let burstDuration: TimeInterval = 0.6
    private let burstRingCount: Int = 2

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
                let progress = min(1.0, elapsed / burstDuration)

                // 统一屏幕半径策略：爆发时从 18 扩大大 60
                let baseR = holeBaseRadiusPoints + (holeMaxRadiusPoints - holeBaseRadiusPoints) * CGFloat(progress)
                r = (max(18, min(baseR, 60))) / zoomScale

                if progress < 1.0 {
                    hasActiveAnimation = true
                }

                if r > 0 {
                    let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                    context.fillEllipse(in: circleRect)
                }

                context.setBlendMode(.normal)
                context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
                context.setLineWidth(max(1.0, 4.0 / zoomScale))

                for i in 0..<burstRingCount {
                    let ringP = min(1.0, progress + Double(i) * 0.12)
                    let ringR = (max(20, min(holeBaseRadiusPoints + (holeMaxRadiusPoints * 1.1 - holeBaseRadiusPoints) * CGFloat(ringP), 70))) / zoomScale
                    let alpha = CGFloat(max(0.0, 1.0 - ringP))
                    context.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.35 * alpha).cgColor)
                    let ringRect = CGRect(x: point.x - ringR, y: point.y - ringR, width: ringR * 2, height: ringR * 2)
                    context.strokeEllipse(in: ringRect)
                }

                context.setBlendMode(.destinationOut)
                context.setFillColor(UIColor.black.cgColor)
            } else if fogOverlay.revealedClusterIds.contains(cluster.id) {
                // 常驻洞屏幕半径固定在 55 左右
                r = 55 / zoomScale

                if r > 0 {
                    let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                    context.fillEllipse(in: circleRect)
                }
            } else {
                // 默认小洞屏幕半径固定在 15
                r = 15 / zoomScale

                if r > 0 {
                    let circleRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
                    context.fillEllipse(in: circleRect)
                }
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
