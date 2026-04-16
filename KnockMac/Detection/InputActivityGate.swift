import Foundation
import CoreGraphics

final class InputActivityGate {
    let suppressionWindow: TimeInterval

    init(suppressionWindow: TimeInterval = 0.3) {
        self.suppressionWindow = suppressionWindow
    }

    func shouldSuppress() -> Bool {
        let tKey   = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let tClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return min(tKey, tClick) < suppressionWindow
    }
}
