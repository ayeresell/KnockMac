import SwiftUI

@main
struct KnockMacApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Single-instance guard
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if running.count > 1 {
            print("[KnockMac] Another instance already running — quitting.")
            NSApplication.shared.terminate(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra("KnockMac", systemImage: appState.isActive ? "hand.tap.fill" : "hand.tap") {
            MenuBarView(appState: appState)
        }
    }
}
