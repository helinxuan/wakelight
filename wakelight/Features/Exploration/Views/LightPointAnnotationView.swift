import UIKit
import MapKit

final class LightPointAnnotationView: MKAnnotationView {
    private let storyGlowLayer = CALayer()
    private let halfGlowLayer = CALayer()
    private let glowLayer = CALayer()
    private let coreLayer = CALayer()
    private let centerHighlightLayer = CALayer()

    private let storyGlowImage = UIImage(named: "FogHoleSoftYellow")?.cgImage
    private let halfGlowImage = UIImage(named: "FogHoleSoft")?.cgImage
    
    var isStoryPoint: Bool = false {
        didSet {
            updateStyle()
        }
    }

    var isHalfRevealed: Bool = false {
        didSet {
            updateStyle()
        }
    }

    // 仅用于缩小视角时弱化锁定灰点，避免遮挡高亮点
    var lockedOverviewAttenuation: CGFloat = 1.0 {
        didSet {
            updateStyle()
        }
    }

    var mapZoomLongitudeDelta: Double = 40 {
        didSet {
            guard abs(mapZoomLongitudeDelta - oldValue) > 0.001 else { return }
            updateStyle()
        }
    }
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupLayers()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupLayers() {
        self.backgroundColor = .clear

        storyGlowLayer.masksToBounds = false
        storyGlowLayer.contents = storyGlowImage
        storyGlowLayer.contentsGravity = .resizeAspect
        storyGlowLayer.opacity = 0
        storyGlowLayer.compositingFilter = "screenBlendMode"
        storyGlowLayer.shadowColor = UIColor(red: 1.0, green: 0.72, blue: 0.2, alpha: 1.0).cgColor
        storyGlowLayer.shadowOpacity = 0.75
        storyGlowLayer.shadowRadius = 16
        storyGlowLayer.shadowOffset = .zero

        halfGlowLayer.masksToBounds = false
        halfGlowLayer.contents = halfGlowImage
        halfGlowLayer.contentsGravity = .resizeAspect
        halfGlowLayer.opacity = 0
        halfGlowLayer.compositingFilter = "screenBlendMode"
        halfGlowLayer.shadowColor = UIColor.white.cgColor
        halfGlowLayer.shadowOpacity = 0.7
        halfGlowLayer.shadowRadius = 10
        halfGlowLayer.shadowOffset = .zero

        glowLayer.masksToBounds = false
        coreLayer.masksToBounds = true

        layer.addSublayer(storyGlowLayer)
        layer.addSublayer(halfGlowLayer)
        layer.addSublayer(glowLayer)
        layer.addSublayer(coreLayer)
        layer.addSublayer(centerHighlightLayer)

        startStoryGlowBreathing()
    }
    
    func updateStyle() {
        let style = AppConfig.default.lightPointStyle

        let highlightedScale = highlightedScaleForZoom(longitudeDelta: mapZoomLongitudeDelta)
        let lockedScale = lockedScaleForZoom(longitudeDelta: mapZoomLongitudeDelta)

        let color: UIColor
        let size: CGFloat
        let glowRadius: CGFloat
        let glowOpacity: Float

        if isStoryPoint {
            // 状态 3: 完全解锁 (Story) -> 更偏金色
            color = UIColor(red: 1.0, green: 0.72, blue: 0.15, alpha: 1.0)
            size = style.highlightedSize * highlightedScale
            glowRadius = CGFloat(style.glowIntensity * 12 * highlightedScale)
            glowOpacity = Float(min(0.96, style.glowIntensity + 0.06))
        } else if isHalfRevealed {
            // 状态 2: 半解锁 (Half-Revealed) -> 纯白色
            color = .white
            size = style.highlightedSize * highlightedScale
            glowRadius = CGFloat(style.glowIntensity * 10 * highlightedScale)
            glowOpacity = Float(min(0.9, style.glowIntensity))
        } else {
            // 状态 1: 未解锁 (Locked) -> 灰色/暗淡，弱光晕
            color = .lightGray
            size = style.defaultSize * lockedScale
            glowRadius = CGFloat(style.glowIntensity * 4 * lockedScale)
            glowOpacity = 0.24
        }

        // 增加点击区域
        let tapSize = max(size * 3.2, 36.0)
        self.frame = CGRect(x: 0, y: 0, width: tapSize, height: tapSize)

        let pointOrigin = (tapSize - size) / 2
        coreLayer.frame = CGRect(x: pointOrigin, y: pointOrigin, width: size, height: size)
        coreLayer.cornerRadius = size / 2
        coreLayer.backgroundColor = color.cgColor

        glowLayer.frame = coreLayer.frame
        glowLayer.cornerRadius = coreLayer.cornerRadius
        glowLayer.backgroundColor = color.cgColor
        glowLayer.shadowColor = color.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = glowRadius
        glowLayer.shadowOpacity = glowOpacity

        if isStoryPoint || isHalfRevealed {
            coreLayer.opacity = 0
            glowLayer.opacity = 0
        } else {
            coreLayer.opacity = 1
            glowLayer.opacity = 1
        }

        // Story 点中心不再叠加白核，避免偏离黄光材质观感
        centerHighlightLayer.opacity = 0.0

        // 白色半解锁点不再使用 AnnotationView 叠加柔光，交给 FogScreenView
        let halfGlowSize = max(size * 2.2, 72)
        halfGlowLayer.frame = CGRect(
            x: (tapSize - halfGlowSize) / 2,
            y: (tapSize - halfGlowSize) / 2,
            width: halfGlowSize,
            height: halfGlowSize
        )
        halfGlowLayer.cornerRadius = halfGlowSize / 2
        halfGlowLayer.opacity = 0.0

        if isStoryPoint {
            let minGlow: CGFloat = mapZoomLongitudeDelta >= 60 ? 46 : (mapZoomLongitudeDelta >= 30 ? 56 : 70)
            let storyGlowSize = max(size * 2.05, minGlow)
            storyGlowLayer.frame = CGRect(
                x: (tapSize - storyGlowSize) / 2,
                y: (tapSize - storyGlowSize) / 2,
                width: storyGlowSize,
                height: storyGlowSize
            )
            storyGlowLayer.cornerRadius = storyGlowSize / 2
            storyGlowLayer.opacity = mapZoomLongitudeDelta >= 60 ? 0.78 : 0.9
        } else {
            storyGlowLayer.opacity = 0.0
        }
    }

    private func highlightedScaleForZoom(longitudeDelta: Double) -> CGFloat {
        if longitudeDelta >= 90 { return 0.58 }
        if longitudeDelta >= 60 { return 0.64 }
        if longitudeDelta >= 30 { return 0.76 }
        if longitudeDelta >= 15 { return 0.88 }
        return 1.0
    }

    private func lockedScaleForZoom(longitudeDelta: Double) -> CGFloat {
        if longitudeDelta >= 90 { return 0.72 }
        if longitudeDelta >= 60 { return 0.78 }
        if longitudeDelta >= 30 { return 0.88 }
        if longitudeDelta >= 15 { return 0.94 }
        return 1.0
    }
    
    private func startBreathingAnimation() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.4
        animation.toValue = 1.0
        animation.duration = 2.0
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(animation, forKey: "breathing")
    }

    private func startStoryGlowBreathing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.6
        animation.toValue = 0.95
        animation.duration = 2.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        storyGlowLayer.add(animation, forKey: "storyGlowBreathing")
    }
}

fileprivate extension UIColor {
    convenience init?(hex: String) {
        var cString: String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cString.hasPrefix("#") { cString.remove(at: cString.startIndex) }
        if cString.count != 6 { return nil }
        var rgbValue: UInt64 = 0
        Scanner(string: cString).scanHexInt64(&rgbValue)
        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
