import Foundation
import CoreGraphics

enum ScreenCapturePermission {
    // Snapshot taken once at first access (app launch). Screen Recording
    // permission changes require a full app restart to take effect — macOS
    // prompts "Quit & Reopen" when the TCC entry is toggled. Treating this
    // value as immutable for the process lifetime keeps the System Check in
    // sync with the effective runtime permission: it only flips after the
    // user actually restarts the app.
    static let launchTimeGranted: Bool = CGPreflightScreenCaptureAccess()
}
