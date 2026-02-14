import AudioToolbox

enum SystemSoundPlayer {
    static func playTick() {
        // 1104: Tock
        AudioServicesPlaySystemSound(1104)
    }
}
