import UIKit

enum StardustEmitter {
    private static var didWarmUp = false
    private static var cachedDotImage: UIImage?

    static func warmUpIfNeeded() {
        guard !didWarmUp else { return }
        didWarmUp = true
        cachedDotImage = makeDotImage()
    }

    static func emit(at point: CGPoint, in view: UIView) {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - start) * 1000
            print(String(format: "[Perf][Particle] emit() %.2fms", ms))
        }
        #endif

        warmUpIfNeeded()

        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .point
        emitter.emitterSize = CGSize(width: 2, height: 2)
        emitter.renderMode = .additive

        let cell = CAEmitterCell()
        cell.contents = cachedDotImage?.cgImage
        // 收短粒子可见时长，避免“拖尾停留太久”的观感
        cell.birthRate = 135
        cell.lifetime = 0.26
        cell.lifetimeRange = 0.08
        cell.velocity = 115
        cell.velocityRange = 45
        cell.emissionRange = .pi * 2
        cell.scale = 0.03
        cell.scaleRange = 0.02
        cell.alphaSpeed = -4.2
        cell.yAcceleration = 170
        cell.spin = 1.6
        cell.spinRange = 2.2

        emitter.emitterCells = [cell]
        view.layer.addSublayer(emitter)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
            emitter.birthRate = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            emitter.removeFromSuperlayer()
        }
    }

    private static func makeDotImage() -> UIImage? {
        let size = CGSize(width: 10, height: 10)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.cgContext.setFillColor(UIColor.systemYellow.withAlphaComponent(0.95).cgColor)
            ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
        }
    }
}
