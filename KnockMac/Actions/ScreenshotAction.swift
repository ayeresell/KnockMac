import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import AudioToolbox

enum ScreenshotAction {

    // Native macOS screenshot "Grab" sound. Registered once and reused —
    // AudioServicesCreateSystemSoundID is cheap to call repeatedly but the
    // sound ID itself is persistent for the process lifetime.
    private static let grabSoundID: SystemSoundID = {
        var id: SystemSoundID = 0
        let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif")
        AudioServicesCreateSystemSoundID(url as CFURL, &id)
        return id
    }()

    static func captureFullScreen() {
        print("[Screenshot] Starting capture...")

        if !CGPreflightScreenCaptureAccess() {
            print("[Screenshot] Requesting screen capture access...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                print("[Screenshot] Screen capture access denied. Please enable it in System Settings.")
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    )
                }
                return
            }
        }

        Task {
            do {
                let image = try await captureViaScreenCaptureKit()
                print("[Screenshot] Captured: \(image.width)×\(image.height)px")
                saveImage(image)
            } catch {
                print("[Screenshot] ERROR: \(error)")
                // Open Screen Recording settings
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
            }
        }
    }

    private static func captureViaScreenCaptureKit() async throws -> CGImage {
        print("[Screenshot] Requesting shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            print("[Screenshot] No display found")
            throw CaptureError.noDisplay
        }
        print("[Screenshot] Display: \(display.width)×\(display.height), id=\(display.displayID)")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width  = Int(display.width)
        config.height = Int(display.height)
        config.capturesAudio = false
        config.showsCursor = true

        print("[Screenshot] Calling SCScreenshotManager.captureImage...")
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func saveImage(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("[Screenshot] Failed to convert image to PNG")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let url = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnockMac-\(timestamp).png")

        do {
            try data.write(to: url)
            print("[Screenshot] Saved to \(url.lastPathComponent)")
            // Play system camera shutter sound
            AudioServicesPlaySystemSound(1108)
        } catch {
            print("[Screenshot] Save failed: \(error)")
        }
    }

    private enum CaptureError: Error { case noDisplay }
}
