import Foundation
import CoreGraphics

final class InputActivityGate {
    let suppressionWindow: TimeInterval

    init(suppressionWindow: TimeInterval = 0.3) {
        self.suppressionWindow = suppressionWindow
    }

    func shouldSuppress() -> Bool {
        let tKey   = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let tFlags = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
        let tLeft  = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let tRight = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        let tOther = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .otherMouseDown)
        return min(tKey, tFlags, tLeft, tRight, tOther) < suppressionWindow
    }
}
