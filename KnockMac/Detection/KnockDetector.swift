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
    private var lastStatusLog: TimeInterval = 0
    private var gateSuppressCount: Int = 0

    init() {
        // Lowered k and absoluteFloor from defaults so lighter knocks register.
        // Relaxed attack window and Z-dominance so real-world impulses pass.
        self.gate = InputActivityGate(suppressionWindow: 0.5)
        self.baseline = AdaptiveBaseline(
            windowSize: 200,
            k: 5.0,
            sigmaFloor: 0.003,
            sigmaCeiling: 0.03,
            absoluteFloor: 0.030
        )
        self.tracker = CandidateTracker()
        self.shape = ShapeAnalyzer(
            maxAttackSamples: 20,
            minDecaySamples: 2,
            decayFraction: 0.5,
            minZDominance: 0.3,
            maxPreQuietDeviation: 0.020,
            minPeakDeviation: 0.070
        )
        self.matcher = DoubleKnockMatcher(minGap: 0.15, maxGap: 0.5, maxAmpRatio: 4.0)

        wire()
        print("[Detector] v2 initialized — k=5.0 absFloor=0.030 attack≤20 minPeak=0.070g zDom≥0.3 ampRatio≤4.0 gap=[0.15,0.5]s")
    }

    private func wire() {
        tracker.onImpulse = { [weak self] window in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let peakDev = abs(window.samples[window.peakIndex].magnitude - window.baseline)
            let impulseStart = self.findImpulseStart(window)
            let attack = max(0, window.peakIndex - impulseStart)
            print("[Tracker] impulse emitted: peak=\(String(format: "%.3f", peakDev))g attack=\(attack) samples=\(window.samples.count) baseline=\(String(format: "%.3f", window.baseline))g")

            switch self.shape.classify(window) {
            case .accept(let peak):
                print("[Shape] ✅ accept peak=\(String(format: "%.3f", peak))g attack=\(attack)")
                self.matcher.submit(KnockEvent(time: now, peak: peak, attackSamples: attack))
            case .reject(let reason):
                print("[Shape] ❌ reject: \(reason)")
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
                print("[Detector] double suppressed by cooldown (\(String(format: "%.2f", now - self.lastDoubleTriggerTime))s < \(self.cooldown)s)")
                return
            }
            self.lastDoubleTriggerTime = now
            print("[Detector] 🎯 DOUBLE KNOCK gap=\(String(format: "%.3f", gap))s peak=\(String(format: "%.3f", peak))g")
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
            gateSuppressCount += 1
            return
        }

        baseline.feed(sample.magnitude)
        let dev = abs(sample.magnitude - baseline.baseline)
        let threshold = baseline.thresholdDeviation

        // Periodic status log every 5s so user can watch baseline/threshold drift
        // without drowning in output.
        if now - lastStatusLog > 5.0 {
            lastStatusLog = now
            print("[Detector] status: baseline=\(String(format: "%.3f", baseline.baseline))g σ=\(String(format: "%.4f", baseline.sigma)) threshold=\(String(format: "%.3f", threshold))g gateSuppressed=\(gateSuppressCount)/5s")
            gateSuppressCount = 0
        }

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
            if abs(s.magnitude - w.baseline) > 0.010 {
                return i
            }
        }
        return 0
    }
}
