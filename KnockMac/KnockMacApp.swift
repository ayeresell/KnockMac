import SwiftUI

@main
struct KnockMacApp: App {
    @StateObject private var appState = KnockController()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        #endif
        
        // Single-instance guard
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if running.count > 1 {
            print("[KnockMac] Another instance already running — quitting.")
            NSApplication.shared.terminate(nil)
        }
        
        // Show onboarding if needed
        DispatchQueue.main.async {
            OnboardingWindowManager.shared.showIfNeeded()
        }
    }

    var body: some Scene {
        MenuBarExtra("KnockMac", systemImage: appState.isActive ? "hand.tap.fill" : "hand.tap", isInserted: $hasCompletedOnboarding) {
            MenuBarView(appState: appState)
        }
    }
}
