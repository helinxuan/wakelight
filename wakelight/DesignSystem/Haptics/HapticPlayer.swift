import UIKit

enum HapticPlayer {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    private static var didWarmUp = false

    static func warmUpIfNeeded() {
        guard !didWarmUp else { return }
        didWarmUp = true

        lightGenerator.prepare()
        mediumGenerator.prepare()
        heavyGenerator.prepare()
    }

    static func play(forCount count: Int) {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - start) * 1000
            print(String(format: "[Perf][Haptic] play(forCount:) %.2fms", ms))
        }
        #endif

        let generator: UIImpactFeedbackGenerator
        if count < 3 {
            generator = lightGenerator
        } else if count < 6 {
            generator = mediumGenerator
        } else {
            generator = heavyGenerator
        }

        generator.impactOccurred()
        generator.prepare()
    }

    static func light() {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - start) * 1000
            print(String(format: "[Perf][Haptic] light() %.2fms", ms))
        }
        #endif

        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }
}
