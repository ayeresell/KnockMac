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
    //
    // Captured explicitly from applicationDidFinishLaunching (not lazily at
    // first read) so a slow TCC probe during onboarding can't freeze the
    // snapshot at a stale value and trap the user in a .restartRequired loop.
    nonisolated(unsafe) private static var capturedLaunchState: Bool?

    static var launchTimeGranted: Bool {
        capturedLaunchState ?? CGPreflightScreenCaptureAccess()
    }

    static func captureLaunchState() {
        if capturedLaunchState == nil {
            capturedLaunchState = CGPreflightScreenCaptureAccess()
        }
    }

    // Live probe — SCShareableContent throws when access has been revoked.
    // SCShareableContent is the source of truth: if it succeeds, the process
    // has functional capture regardless of what CGPreflight reports. A
    // successful probe also upgrades the launch snapshot so later calls can't
    // revert to .restartRequired after TCC slowly propagates post-grant.
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

        if current && capturedLaunchState != true {
            capturedLaunchState = true
        }

        if current != launchTimeGranted {
            return .restartRequired
        }
        return current ? .granted : .denied
    }

    // Relaunches the app via LaunchServices, then terminates the current
    // process only after the new instance has successfully spawned. The
    // previous Process + `open -n` approach could silently fail under
    // hardened runtime, leaving the user with a terminated app and no new
    // instance. NSWorkspace.openApplication surfaces the failure via the
    // completion handler so we don't exit on a broken launch.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, _ in
            guard app != nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
