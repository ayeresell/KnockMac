import SwiftUI
import Combine

@MainActor
final class KnockController: ObservableObject {
    @Published var isActive = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Published var lastKnockTime: Date?
    @Published var sensorAvailable = false

    private let accelReader = AccelerometerReader()
    private let knockDetector = KnockDetector()
    private let audioPlayer = AudioPlayer()
    private var cancellables = Set<AnyCancellable>()

    init() {
        knockDetector.onKnock = { [weak self] in
            self?.handleKnock()
        }

        accelReader.onSample = { [weak self] sample in
            guard let self, self.isActive else { return }
            guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
            self.knockDetector.feed(sample)
            if !self.sensorAvailable { self.sensorAvailable = true }
        }

        NotificationCenter.default.publisher(for: NSNotification.Name("OnboardingCompleted"))
            .sink { [weak self] _ in
                self?.knockDetector.reloadSettings()
                self?.isActive = true
                // The calibration reader overwrites the HID callback — rebind to restore it.
                self?.accelReader.rebind()
            }
            .store(in: &cancellables)
    }

    func toggle() {
        isActive.toggle()
    }

    private func handleKnock() {
        lastKnockTime = Date()
        audioPlayer.playKnockSound()
        ScreenshotAction.captureFullScreen()
    }
}
