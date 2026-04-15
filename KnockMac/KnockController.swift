import SwiftUI
import Combine

@MainActor
final class KnockController: ObservableObject {
    @Published var isActive = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @Published var lastKnockTime: Date?
    @Published var sensorAvailable = false

    private let accelReader = AccelerometerReader()
    private let lidSensor = LidAngleSensor()
    private let knockDetector = KnockDetector()
    private let usbWatcher = USBWatcher()
    private let audioPlayer = AudioPlayer()
    private let settingsStore = SettingsStore()
    private var cancellables = Set<AnyCancellable>()

    init() {
        knockDetector.onKnock = { [weak self] in
            self?.handleKnock()
        }

        accelReader.onSample = { [weak self] sample in
            guard let self, self.isActive else { return }
            // Do not listen to knocks if onboarding is not done
            guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
            
            if self.lidSensor.isOpen {
                self.knockDetector.feed(sample)
            }
            self.sensorAvailable = true
        }

        usbWatcher.onEvent = { event in
            print("[USBWatcher] \(event)")
        }
        
        NotificationCenter.default.publisher(for: NSNotification.Name("OnboardingCompleted"))
            .sink { [weak self] _ in
                self?.knockDetector.reloadSettings()
                self?.isActive = true
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
