import UIKit

enum HapticPlayer {
    static func play(forCount count: Int) {
        let generator: UIImpactFeedbackGenerator
        if count < 3 {
            generator = UIImpactFeedbackGenerator(style: .light)
        } else if count < 6 {
            generator = UIImpactFeedbackGenerator(style: .medium)
        } else {
            generator = UIImpactFeedbackGenerator(style: .heavy)
        }
        generator.prepare()
        generator.impactOccurred()
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
