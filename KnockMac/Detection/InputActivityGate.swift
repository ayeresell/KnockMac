import Foundation
import CoreGraphics

final class InputActivityGate {
    let suppressionWindow: TimeInterval

    init(suppressionWindow: TimeInterval = 0.3) {
        self.suppressionWindow = suppressionWindow
    }

    func shouldSuppress() -> Bool {
        return secondsSinceLastInput() < suppressionWindow
    }

    func secondsSinceLastInput() -> TimeInterval {
        // Query both session- and HID-level event sources: some build/entitlement
        // configurations return unreliable values from .combinedSessionState but
        // work correctly on .hidSystemState (closer to hardware).
        let sources: [CGEventSourceStateID] = [.combinedSessionState, .hidSystemState]
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        var minVal: TimeInterval = .infinity
        for src in sources {
            for t in types {
                let v = CGEventSource.secondsSinceLastEventType(src, eventType: t)
                if v < minVal { minVal = v }
            }
        }
        return minVal
    }

    func debugSnapshot() -> String {
        let sessionKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let hidKey     = CGEventSource.secondsSinceLastEventType(.hidSystemState,       eventType: .keyDown)
        let sessionClk = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let hidClk     = CGEventSource.secondsSinceLastEventType(.hidSystemState,       eventType: .leftMouseDown)
        return String(format: "keyDown session=%.2fs hid=%.2fs | leftClick session=%.2fs hid=%.2fs",
                      sessionKey, hidKey, sessionClk, hidClk)
    }
}
