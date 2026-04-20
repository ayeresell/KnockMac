import Foundation

final class KnockDetector {
    // Public API preserved for compatibility with existing call sites.
    var onKnock: (() -> Void)?
    var onSingleKnock: ((Double) -> Void)?
    var onDoubleKnockWithGap: ((Double, Double) -> Void)?
    var singleKnockOnly: Bool = false {
        didSet { matcher.singleKnockOnly = singleKnockOnly }
    }
    var cooldown: TimeInterval = 0.35

    private let gate: InputActivityGate
    private let baseline: AdaptiveBaseline
    private let tracker: CandidateTracker
    private let shape: ShapeAnalyzer
    private let matcher: DoubleKnockMatcher

    private var lastDoubleTriggerTime: TimeInterval = 0
    private var unfreezeAfter: TimeInterval = 0
    private var lastStatusLog: TimeInterval = 0
    private var lastNearMissLog: TimeInterval = 0
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
            absoluteFloor: 0.038
        )
        self.tracker = CandidateTracker()
        self.shape = ShapeAnalyzer(
            maxAttackSamples: 20,
            minDecaySamples: 2,
            decayFraction: 0.5,
            minZDominance: 0.0,
            maxPreQuietDeviation: 0.020,
            minPeakDeviation: 0.060,
            minSignedDy: -0.002
        )
        self.matcher = DoubleKnockMatcher(minGap: 0.15, maxGap: 0.5, maxAmpRatio: 4.0, maxAttackRatio: 4.0)

        wire()
        print("[Detector] v2 initialized — k=5.0 absFloor=0.038 attack≤20 minPeak=0.060g zDom=disabled sdy≥-0.002 ampRatio≤4.0 gap=[0.15,0.5]s gate=0.5s cooldown=0.35s")
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

        // Early baseline freeze. Without this, the rising edge of every knock
        // (which crosses ~0.3×threshold before reaching threshold) leaks into
        // the rolling-mean σ. Five rapid knocks were enough to nearly double
        // σ in field testing — threshold then climbed past 0.07g and weaker
        // knocks were silently dropped before tracker.feed.
        // Each leading-edge sample also bumps unfreezeAfter so the freeze
        // outlives the impulse and prevents follow-up samples from contaminating.
        let edgeBand = 0.3 * threshold
        if dev > edgeBand {
            baseline.freeze()
            unfreezeAfter = max(unfreezeAfter, now + 0.3)
        }

        // Visibility for near-miss samples: the tracker silently ignores any
        // sample with dev ≤ threshold, so a weak knock looks identical to no
        // knock in the log. Surface anything in the [0.6, 1.0] × threshold band
        // (rate-limited) so missed knocks become diagnosable.
        if dev > 0.6 * threshold && dev <= threshold && now - lastNearMissLog > 0.1 {
            lastNearMissLog = now
            print("[Detector] near-miss dev=\(String(format: "%.3f", dev))g threshold=\(String(format: "%.3f", threshold))g — sample below threshold, not tracked")
        }

        tracker.feed(sample, deviation: dev, threshold: threshold, baseline: baseline.baseline)
    }

    // No-op kept for call-site compatibility.
    func reloadSettings() {}

    // Kept for compatibility; v2 has no single-threshold concept.
    func setCalibrationMode(threshold: Double) {}

    private func findImpulseStart(_ w: CandidateTracker.ImpulseWindow) -> Int {
        // 0.020g matches ShapeAnalyzer.maxPreQuietDeviation. The previous
        // 0.010g threshold was too sensitive to between-knock chassis
        // resonance (0.026–0.038g per the near-miss log) and counted that
        // residual ringing as part of the new impulse — inflating attack
        // and causing the matcher to reject otherwise-valid pairs as
        // "shape mismatch".
        for (i, s) in w.samples.enumerated() {
            if abs(s.magnitude - w.baseline) > 0.020 {
                return i
            }
        }
        return 0
    }
}
