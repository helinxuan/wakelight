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
        // 适当拉回可见时间，保证“看得见但不拖尾”
        cell.birthRate = 120
        cell.lifetime = 0.34
        cell.lifetimeRange = 0.10
        cell.velocity = 108
        cell.velocityRange = 42
        cell.emissionRange = .pi * 2
        cell.scale = 0.032
        cell.scaleRange = 0.02
        cell.alphaSpeed = -3.6
        cell.yAcceleration = 160
        cell.spin = 1.5
        cell.spinRange = 2.0

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
