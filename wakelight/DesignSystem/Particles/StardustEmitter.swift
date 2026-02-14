import UIKit

enum StardustEmitter {
    static func emit(at point: CGPoint, in view: UIView) {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 2, height: 2)
        emitter.renderMode = .additive

        let cell = CAEmitterCell()
        cell.contents = StardustEmitter.dotImage()?.cgImage
        cell.birthRate = 140
        cell.lifetime = 0.65
        cell.lifetimeRange = 0.25
        cell.velocity = 120
        cell.velocityRange = 60
        cell.emissionRange = .pi * 2
        cell.scale = 0.035
        cell.scaleRange = 0.03
        cell.alphaSpeed = -1.8
        cell.yAcceleration = 140
        cell.spin = 2.0
        cell.spinRange = 3.0

        emitter.emitterCells = [cell]
        view.layer.addSublayer(emitter)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            emitter.birthRate = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            emitter.removeFromSuperlayer()
        }
    }

    private static func dotImage() -> UIImage? {
        let size = CGSize(width: 10, height: 10)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.cgContext.setFillColor(UIColor.systemYellow.withAlphaComponent(0.95).cgColor)
            ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
        }
    }
}
