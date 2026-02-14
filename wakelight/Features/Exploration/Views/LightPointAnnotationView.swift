import UIKit
import MapKit

final class LightPointAnnotationView: MKAnnotationView {
    private let glowLayer = CALayer()
    private let coreLayer = CALayer()
    
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
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupLayers()
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupLayers() {
        self.backgroundColor = .clear
        
        glowLayer.masksToBounds = false
        coreLayer.masksToBounds = true
        
        layer.addSublayer(glowLayer)
        layer.addSublayer(coreLayer)
        
        startBreathingAnimation()
    }
    
    func updateStyle() {
        let style = AppConfig.default.lightPointStyle
        let color: UIColor?
        if isStoryPoint {
            color = UIColor(hex: style.highlightedColorHex)
        } else if isHalfRevealed {
            color = UIColor(hex: "FFD54A")
        } else {
            color = UIColor(hex: style.defaultColorHex)
        }

        let size = isStoryPoint ? style.highlightedSize : style.defaultSize
        
        // 增加点击区域
        let tapSize = max(size * 3, 44.0)
        self.frame = CGRect(x: 0, y: 0, width: tapSize, height: tapSize)
        self.centerOffset = CGPoint(x: 0, y: 0)
        
        let pointOrigin = (tapSize - size) / 2
        coreLayer.frame = CGRect(x: pointOrigin, y: pointOrigin, width: size, height: size)
        coreLayer.cornerRadius = size / 2
        coreLayer.backgroundColor = color?.cgColor
        
        glowLayer.frame = coreLayer.frame
        glowLayer.cornerRadius = coreLayer.cornerRadius
        glowLayer.backgroundColor = color?.cgColor
        glowLayer.shadowColor = color?.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = CGFloat(style.glowIntensity * 10)
        glowLayer.shadowOpacity = Float(style.glowIntensity)
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
