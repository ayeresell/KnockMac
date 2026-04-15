import Foundation
import AudioToolbox

final class AudioPlayer {
    init() {
        print("[AudioPlayer] Initialized")
    }
    
    func playKnockSound() {
        // System camera shutter sound as a fallback for knock
        AudioServicesPlaySystemSound(1108)
    }
}
