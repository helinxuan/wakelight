import AudioToolbox
import AVFoundation

enum SystemSoundPlayer {
    static func playTick() {
        // 使用 ambient，遵从静音键；但确保会话激活，避免部分机型不响
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default)
        try? session.setActive(true, options: [])

        // 1057: "Tink"，更清脆
        AudioServicesPlaySystemSound(1057)
    }
}
