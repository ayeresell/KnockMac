import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isActive = true
    @Published var lastKnockTime: Date?
    @Published var sensorAvailable = false

    private let accelReader = AccelerometerReader()
    private var knockDetector: KnockDetector?

    init() {
        let detector = KnockDetector { [weak self] in
            self?.handleDoubleTap()
        }
        knockDetector = detector

        accelReader.onSample = { [weak self] sample in
            guard let self, self.isActive else { return }
            self.knockDetector?.feed(sample)
            self.sensorAvailable = true
        }
    }

    func toggle() {
        isActive.toggle()
    }

    private func handleDoubleTap() {
        lastKnockTime = Date()
        ScreenshotAction.captureFullScreen()
    }
}
