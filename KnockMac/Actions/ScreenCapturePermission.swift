import Foundation
import CoreGraphics
import ScreenCaptureKit

enum ScreenCapturePermission {
    // Snapshot of the TCC state at app launch. During first-run onboarding
    // the System Check displays this frozen value so the user is forced to
    // "Quit & Reopen" after granting permission — granting mid-session does
    // not produce a working capture pipeline until the process restarts.
    static let launchTimeGranted: Bool = CGPreflightScreenCaptureAccess()

    // Live probe. Fetching SCShareableContent surfaces the current TCC state
    // — it throws when access has been revoked. Use after onboarding
    // completes, where we want the Settings view to reflect mid-session
    // revocations without requiring a relaunch.
    static func probe() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
    }
}
