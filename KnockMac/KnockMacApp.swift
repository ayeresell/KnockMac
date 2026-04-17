import SwiftUI

@main
struct KnockMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = KnockController()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    // Separate key so macOS's two-way write-back through MenuBarExtra never
    // clobbers the onboarding flag (which would make Quit & Reopen skip onboarding).
    @AppStorage("menuBarInserted") private var menuBarInserted = true

    init() {
        // Reset onboarding only when launched with --reset-onboarding argument.
        // Never wipes state in release builds.
        #if DEBUG
        if CommandLine.arguments.contains("--reset-onboarding") {
            UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra("KnockMac", systemImage: appState.isActive ? "hand.tap.fill" : "hand.tap", isInserted: $menuBarInserted) {
            MenuBarView(appState: appState)
        }

        // Keeps the app alive while MenuBarExtra is hidden during onboarding.
        // Without this SwiftUI sees zero active scenes and auto-terminates,
        // which would also block macOS "Quit & Reopen" after permission grants.
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate all other running instances, keep only this one.
        let current = NSRunningApplication.current
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != current.processIdentifier }
            .forEach {
                print("[KnockMac] Terminating previous instance (pid \($0.processIdentifier))")
                $0.terminate()
            }

        // Show onboarding window if first launch.
        OnboardingWindowManager.shared.showIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
