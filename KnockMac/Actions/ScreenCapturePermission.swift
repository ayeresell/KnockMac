import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapturePermission {
    enum Status: Equatable {
        case granted
        case denied
        case restartRequired
    }

    // Snapshot of the TCC entry at app launch. Any later divergence from
    // this value means the user toggled Screen Recording in System Settings
    // and the app needs to be relaunched for capture to work correctly.
    static let launchTimeGranted: Bool = CGPreflightScreenCaptureAccess()

    // Live probe — SCShareableContent throws when access has been revoked.
    // Compared against the launch-time snapshot to detect pending restarts.
    static func currentStatus() async -> Status {
        let current: Bool
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            current = true
        } catch {
            current = false
        }
        if current != launchTimeGranted {
            return .restartRequired
        }
        return current ? .granted : .denied
    }

    // Relaunches the app bundle in a detached shell, then terminates the
    // current process so the new instance picks up the updated TCC state.
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
