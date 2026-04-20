import Foundation
import CoreGraphics

final class InputActivityGate {
    let suppressionWindow: TimeInterval

    init(suppressionWindow: TimeInterval = 0.3) {
        self.suppressionWindow = suppressionWindow
    }

    func shouldSuppress() -> Bool {
        // Gate disabled: CGEventSource was reporting phantom input events
        // (observed 318 suppressions in 5 s with no user input, apparently
        // synthesized by SCScreenshotManager during rapid screenshot bursts).
        // False suppressions were eating real knocks mid-sequence. Detector
        // relies on peak-hold + shape filter to reject mouse-induced jitter.
        return false
    }
}
