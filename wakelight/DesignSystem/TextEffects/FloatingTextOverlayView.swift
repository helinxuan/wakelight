import UIKit

/// A lightweight, non-interactive overlay that displays ephemeral floating text.
///
/// Design goals:
/// - Does not block map gestures (`isUserInteractionEnabled = false`)
/// - Very cheap to animate (UILabel + UIView animations)
/// - Optional blend mode for a "glow-through" feel
final class FloatingTextOverlayView: UIView {
    struct Style {
        var font: UIFont = .systemFont(ofSize: 15, weight: .semibold)
        var textColor: UIColor = UIColor.white.withAlphaComponent(0.92)
        var shadowColor: UIColor = UIColor.white.withAlphaComponent(0.55)
        var shadowRadius: CGFloat = 10
        var shadowOffset: CGSize = .zero

        /// A gentle upward drift during the lifetime.
        var driftUp: CGFloat = 16

        /// Fade in/out timings.
        var fadeIn: TimeInterval = 0.18
        var hold: TimeInterval = 1.7
        var fadeOut: TimeInterval = 0.28

        /// Optional blend mode (nil = normal).
        var compositingFilter: String? = "screenBlendMode"
    }

    var style = Style() {
        didSet { layer.compositingFilter = style.compositingFilter }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        layer.compositingFilter = style.compositingFilter
    }

    /// Shows a single piece of floating text around the given point (in this view's coordinate space).
    /// If called frequently, it will simply spawn multiple labels; caller should rate-limit.
    func show(text: String, at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let label = PaddingLabel(insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        label.text = text
        label.font = style.font
        label.textColor = style.textColor
        label.numberOfLines = 2
        label.textAlignment = .center
        label.backgroundColor = .clear

        // Soft glow
        label.layer.shadowColor = style.shadowColor.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = style.shadowRadius
        label.layer.shadowOffset = style.shadowOffset

        label.alpha = 0
        addSubview(label)

        let maxWidth = min(bounds.width - 24, 260)
        let targetSize = label.sizeThatFits(CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
        label.bounds = CGRect(origin: .zero, size: CGSize(width: min(maxWidth, targetSize.width), height: targetSize.height))

        // Keep inside bounds, avoid being clipped/covered:
        // - Prefer showing above the point with a larger offset.
        // - If near the top, flip to below.
        // - Clamp within safe area.
        let margin: CGFloat = 8
        let safeTop = safeAreaInsets.top + margin
        let safeBottom = safeAreaInsets.bottom + margin
        let safeLeft = safeAreaInsets.left + margin
        let safeRight = safeAreaInsets.right + margin
        
        let halfW = label.bounds.width / 2
        let halfH = label.bounds.height / 2
        
        let minX = safeLeft + halfW
        let maxX = bounds.width - safeRight - halfW
        let minY = safeTop + halfH
        let maxY = bounds.height - safeBottom - halfH
        
        let x = max(minX, min(maxX, point.x))
        
        let offset: CGFloat = 50
        let preferredAboveY = point.y - offset
        let wouldClipAbove = (preferredAboveY - halfH) < safeTop
        let rawY = wouldClipAbove ? (point.y + offset) : preferredAboveY
        let y = max(minY, min(maxY, rawY))
        
        label.center = CGPoint(x: x, y: y)

        let startCenter = label.center
        let endCenter = CGPoint(x: startCenter.x, y: startCenter.y - style.driftUp)

        UIView.animate(withDuration: style.fadeIn, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            label.alpha = 1
        }

        UIView.animate(withDuration: style.hold + style.fadeOut, delay: style.fadeIn, options: [.curveEaseOut, .allowUserInteraction]) {
            label.center = endCenter
        }

        UIView.animate(withDuration: style.fadeOut, delay: style.fadeIn + style.hold, options: [.curveEaseIn, .allowUserInteraction]) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

private final class PaddingLabel: UILabel {
    private let insets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.insets = .zero
        super.init(coder: coder)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(
            CGSize(
                width: size.width - insets.left - insets.right,
                height: size.height - insets.top - insets.bottom
            )
        )
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
