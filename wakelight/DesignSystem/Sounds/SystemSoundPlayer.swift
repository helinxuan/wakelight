import AudioToolbox
import AVFoundation

enum SystemSoundPlayer {
    private static var didWarmUp = false

    static func warmUpIfNeeded() {
        guard !didWarmUp else { return }
        didWarmUp = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(true, options: [])
    }

    static func playTick() {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - start) * 1000
            print(String(format: "[Perf][Sound] playTick() %.2fms", ms))
        }
        #endif

        warmUpIfNeeded()

        // 1057: "Tink"，更清脆
        AudioServicesPlaySystemSound(1057)
    }
}
