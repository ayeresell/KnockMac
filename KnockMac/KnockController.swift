import SwiftUI
import Combine
import CoreGraphics

@MainActor
final class KnockController: ObservableObject {
    // Weak singleton so the onboarding System Check can read sensorAvailable
    // without spawning a second AccelerometerReader (which races for the HID
    // callback and falsely reports "not found").
    nonisolated(unsafe) static private(set) weak var current: KnockController?

    @Published var isActive: Bool
    @Published var lastKnockTime: Date?
    @Published var sensorAvailable = false

    private let accelReader = AccelerometerReader()
    private let knockDetector = KnockDetector()
    private let audioPlayer = AudioPlayer()
    private var cancellables = Set<AnyCancellable>()

    static func hasRequiredPermissions() -> Bool {
        let onboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        return onboarded && hasScreenCapture
    }

    init() {
        self.isActive = KnockController.hasRequiredPermissions()

        knockDetector.onKnock = { [weak self] in
            self?.handleKnock()
        }

        accelReader.onSample = { [weak self] sample in
            guard let self else { return }
            // Track sensor availability regardless of isActive so the onboarding
            // System Check can verify the IMU even before permissions are granted.
            if !self.sensorAvailable { self.sensorAvailable = true }
            guard self.isActive else { return }
            self.knockDetector.feed(sample)
        }

        // Pause main reader when calibration starts to prevent double-processing.
        // During recalibration isActive is still true, but calibrationReader steals the
        // HID callback — both would fire simultaneously without this guard.
        NotificationCenter.default.publisher(for: NSNotification.Name("OnboardingStarted"))
            .sink { [weak self] _ in
                self?.isActive = false
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("OnboardingCompleted"))
            .sink { [weak self] _ in
                self?.knockDetector.reloadSettings()
                self?.isActive = true
                // The calibration reader overwrites the HID callback — rebind to restore it.
                self?.accelReader.rebind()
            }
            .store(in: &cancellables)

        // Hook for future pre-warming (e.g. caching shortcut metadata).
        // No-op in v1 — ActionRegistry.current() reads UserDefaults on every knock.
        NotificationCenter.default.publisher(for: NSNotification.Name("ActionChanged"))
            .sink { _ in }
            .store(in: &cancellables)

        Self.current = self
    }

    func toggle() {
        isActive.toggle()
    }

    private func handleKnock() {
        lastKnockTime = Date()
        KnockGlowWindowController.shared.flash()
        audioPlayer.playKnockSound()
        ActionRegistry.current().perform()
    }
}
