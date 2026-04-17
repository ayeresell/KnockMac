import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    // CGPreflightScreenCaptureAccess caches a `true` result for the process
    // lifetime, so permission revoked in System Settings mid-session still
    // reads as granted. Fetching SCShareableContent surfaces the live TCC
    // state — it throws when access has been revoked.
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
