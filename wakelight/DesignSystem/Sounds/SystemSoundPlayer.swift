import AudioToolbox
import AVFoundation

enum SystemSoundPlayer {
    static func warmUpIfNeeded() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // 探索页可能已启用麦克风（BlowDetector: playAndRecord）。
            // 录音态下显式允许系统触感与系统短音效，避免被系统策略静默。
            if session.category == .playAndRecord {
                if #available(iOS 13.0, *) {
                    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                }
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }

            try session.setActive(true, options: [])
            #if DEBUG
            print("[FeedbackDiag][Audio] category=\(session.category.rawValue) mode=\(session.mode.rawValue) silencedHint=\(session.secondaryAudioShouldBeSilencedHint) volume=\(session.outputVolume)")
            #endif
        } catch {
            #if DEBUG
            print("[FeedbackDiag][Audio] setup failed: \(error)")
            #endif
        }
        #endif
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
