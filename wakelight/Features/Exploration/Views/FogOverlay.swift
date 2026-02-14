import MapKit
import UIKit

/// 覆盖全球的迷雾 Overlay
final class FogOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D
    var boundingMapRect: MKMapRect

    var clusters: [PlaceCluster]
    var revealedClusterIds: Set<UUID>
    
    // 性能优化：缓存 MapPoints 避免每次重绘都进行坐标转换
    private(set) var clusterMapPoints: [UUID: MKMapPoint] = [:]

    // 动画状态
    var animatingClusterId: UUID?
    var animationStartTime: TimeInterval?

    // 刮痕（用于滑动“刮开”迷雾效果）。由 MapView 在 overlay 重建时拷贝保持状态。
    var scratchPaths: [UIBezierPath] = []
    var scratchLineWidthPoints: CGFloat = 22

    init(
        clusters: [PlaceCluster],
        revealedClusterIds: Set<UUID>,
        boundingMapRect: MKMapRect
    ) {
        self.clusters = clusters
        self.revealedClusterIds = revealedClusterIds
        self.boundingMapRect = boundingMapRect

        let center = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY)
        self.coordinate = center.coordinate
        
        // 预计算坐标
        var points: [UUID: MKMapPoint] = [:]
        for c in clusters {
            points[c.id] = MKMapPoint(CLLocationCoordinate2D(latitude: c.centerLatitude, longitude: c.centerLongitude))
        }
        self.clusterMapPoints = points

        super.init()
    }

    func updateBoundingMapRect(_ newRect: MKMapRect) {
        boundingMapRect = newRect
        let center = MKMapPoint(x: newRect.midX, y: newRect.midY)
        coordinate = center.coordinate
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
        
        let rect = self.rect(for: mapRect)
        context.setFillColor(fogColor.cgColor)
        context.fill(rect)

        let currentTime = CACurrentMediaTime()
        var hasActiveAnimation = false

        // 核心修复：
        // 1. MapKit 的 draw 是按 tile 调用的，这里的 context 坐标系已经通过 zoomScale 缩放过了
        // 2. 如果要实现“屏幕固定大小”的洞，我们需要把“期望的屏幕点半径”乘以 (1.0 / zoomScale)
        //    因为在渲染器的 context 中，1个单位 = 1个地图点，而 1个屏幕点 = (1.0 / zoomScale) 个地图点
        let scaleFactor = 1.0 / zoomScale

        for cluster in fogOverlay.clusters {
            guard let mapPoint = fogOverlay.clusterMapPoints[cluster.id] else { continue }
            
            // 快速剔除不在当前 tile 的点
            let maxExpectedRadius = (holeMaxRadiusPoints + 20) * scaleFactor
            let expandedTileRect = mapRect.insetBy(dx: -maxExpectedRadius, dy: -maxExpectedRadius)
            if !expandedTileRect.contains(mapPoint) { continue }

            let point = self.point(for: mapPoint)
            var rPoints: CGFloat = 0
            var opacity: CGFloat = 1.0
            var isSpecialHole = false
            
            if cluster.id == fogOverlay.animatingClusterId, let start = fogOverlay.animationStartTime {
                let elapsed = currentTime - start
                let progress = min(1.0, elapsed / burstDuration)
                
                let easeOutProgress = 1 - pow(1 - progress, 3)
                rPoints = holeBaseRadiusPoints + (holeMaxRadiusPoints - holeBaseRadiusPoints) * CGFloat(easeOutProgress)
                opacity = CGFloat(easeOutProgress)
                isSpecialHole = true
                
                if progress < 1.0 { hasActiveAnimation = true }
            } else if fogOverlay.revealedClusterIds.contains(cluster.id) {
                rPoints = holeMaxRadiusPoints
                isSpecialHole = true
            } else {
                rPoints = 15 // 未解锁的小洞基础半径
            }

            // 最终绘图半径转为地图点单位
            let rMapPoints = rPoints * scaleFactor

            if rMapPoints > 0 {
                context.saveGState()
                context.setBlendMode(.destinationOut)
                
                if isSpecialHole {
                    // 对已解锁或正在动画的洞使用径向渐变，实现柔和边缘
                    let colors = [
                        UIColor.black.withAlphaComponent(opacity).cgColor,
                        UIColor.black.withAlphaComponent(0).cgColor
                    ] as CFArray
                    let locations: [CGFloat] = [0.6, 1.0]
                    
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                        context.drawRadialGradient(gradient, 
                                                startCenter: point, startRadius: 0, 
                                                endCenter: point, endRadius: rMapPoints, 
                                                options: .drawsAfterEndLocation)
                    }
                } else {
                    // 对大量默认小洞使用简单的 fillEllipse，极大降低渲染开销
                    context.setFillColor(UIColor.black.cgColor)
                    let holeRect = CGRect(x: point.x - rMapPoints, y: point.y - rMapPoints, 
                                        width: rMapPoints * 2, height: rMapPoints * 2)
                    context.fillEllipse(in: holeRect)
                }
                context.restoreGState()
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
