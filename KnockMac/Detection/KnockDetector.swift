import Foundation

final class KnockDetector {
    // Public API preserved for compatibility with existing call sites.
    var onKnock: (() -> Void)?
    var onSingleKnock: ((Double) -> Void)?
    var onDoubleKnockWithGap: ((Double, Double) -> Void)?
    var singleKnockOnly: Bool = false {
        didSet { matcher.singleKnockOnly = singleKnockOnly }
    }
    var cooldown: TimeInterval = 1.0

    private let gate: InputActivityGate
    private let baseline: AdaptiveBaseline
    private let tracker: CandidateTracker
    private let shape: ShapeAnalyzer
    private let matcher: DoubleKnockMatcher

    private var lastDoubleTriggerTime: TimeInterval = 0
    private var unfreezeAfter: TimeInterval = 0

    init() {
        self.gate = InputActivityGate()
        self.baseline = AdaptiveBaseline()
        self.tracker = CandidateTracker()
        self.shape = ShapeAnalyzer()
        self.matcher = DoubleKnockMatcher()

        wire()
    }

    private func wire() {
        tracker.onImpulse = { [weak self] window in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch self.shape.classify(window) {
            case .accept(let peak):
                let impulseStart = self.findImpulseStart(window)
                let attack = max(0, window.peakIndex - impulseStart)
                self.matcher.submit(KnockEvent(time: now, peak: peak, attackSamples: attack))
            case .reject(let reason):
                print("[Detector] reject: \(reason)")
            }
            self.unfreezeAfter = now + 0.5
        }

        matcher.onSingle = { [weak self] peak in
            self?.onSingleKnock?(peak)
        }
        matcher.onDouble = { [weak self] gap, peak in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastDoubleTriggerTime > self.cooldown else {
                print("[Detector] double suppressed by cooldown")
                return
            }
            self.lastDoubleTriggerTime = now
            print("[Detector] ✅ DOUBLE KNOCK gap=\(String(format: "%.3f", gap))s peak=\(String(format: "%.3f", peak))g")
            self.onDoubleKnockWithGap?(gap, peak)
            self.onKnock?()
        }
    }

    func feed(_ sample: AccelSample) {
        let now = ProcessInfo.processInfo.systemUptime

        if unfreezeAfter > 0 && now >= unfreezeAfter {
            baseline.unfreeze()
            unfreezeAfter = 0
        }

        if gate.shouldSuppress() {
            baseline.feed(sample.magnitude)
            return
        }

        baseline.feed(sample.magnitude)
        let dev = abs(sample.magnitude - baseline.baseline)
        let threshold = baseline.thresholdDeviation

        if dev > threshold {
            baseline.freeze()
        }
        tracker.feed(sample, deviation: dev, threshold: threshold, baseline: baseline.baseline)
    }

    // No-op kept for call-site compatibility.
    func reloadSettings() {}

    // Kept for compatibility; v2 has no single-threshold concept.
    func setCalibrationMode(threshold: Double) {}

    private func findImpulseStart(_ w: CandidateTracker.ImpulseWindow) -> Int {
        for (i, s) in w.samples.enumerated() {
            if abs(s.magnitude - w.baseline) > 0.025 {
                return i
            }
        }
        return 0
    }
}
